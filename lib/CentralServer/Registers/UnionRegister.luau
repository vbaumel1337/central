--!native
--!strict
--!optimize 2
-- Owns the union/envelope/prediction state behind the block trees in HistoricalHitboxes, and
-- the per-frame maintenance loop that keeps them in sync. Knows how to talk to a Bolt tree,
-- knows nothing about queries or Hitbox records -- see the "Union Hitboxes" design notes.
--
-- One instance for the whole system, not one per part or per (part, block): the state is flat
-- parallel arrays indexed by part id so the hot loop stays a hoisted local plus an array index,
-- not a pointer-chase through per-leaf objects.
local bolt = require(script.Parent.Parent.Parent.bolt)
local PartRegister = require(script.Parent.PartRegister)

-- bounds how many part-sizes of inflation a single measured sweep may contribute to the next
-- block's prediction, so one teleport frame can't poison the block that follows it
local PREDICTION_CLAMP_MULTIPLE = 4

-- unionBlock[id] starts here: matches no real block (blocks are 1..unionsPerPart), so a part's
-- very first present frame always takes the "rotation" (seed) branch, with no prior sweep to predict from
local NO_BLOCK = 0

type PartInfo = {id: number, register: PartRegister.PartRegister}

local UnionRegister = {}
UnionRegister.__index = UnionRegister

type ActiveState = {
	min: {[number]: Vector3}, max: {[number]: Vector3},
	seedMin: {[number]: Vector3}, seedMax: {[number]: Vector3},
	predLow: {[number]: Vector3}, predHigh: {[number]: Vector3},
	block: {[number]: number},
	present: {[number]: boolean},
}

type LeafState = {
	envMin: {[number]: Vector3},
	envMax: {[number]: Vector3},
	shape: {[number]: bolt.BoxShape},
}

export type UnionRegister = typeof(setmetatable(
	{} :: {
		unionsPerPart: number,
		unionSize: number,
		padding: Vector3,
		predictionFrames: number,
		updateFraction: number,
		active: ActiveState,
		leaf: {[number]: LeafState},
	},
	UnionRegister
))

local function clampPred(delta: Vector3, size: Vector3): Vector3
	local limit = size * PREDICTION_CLAMP_MULTIPLE
	return vector.max(vector.min(delta, limit), -limit)
end

-- the two-op vector idiom Bolt's own aabb_contains uses: does [envMin,envMax] contain [min,max]
local function contains(envMin: Vector3, envMax: Vector3, min: Vector3, max: Vector3): boolean
	return envMin.X <= min.X and envMax.X >= max.X
		and envMin.Y <= min.Y and envMax.Y >= max.Y
		and envMin.Z <= min.Z and envMax.Z >= max.Z
end

local function volumeOf(min: Vector3, max: Vector3): number
	local size = max - min
	return size.X * size.Y * size.Z
end

-- the only place that talks to Bolt. remove-while-registered is forbidden (see the design notes'
-- "HARD RULE"), so a leaf is always detached before its shape table is mutated, then reinserted.
local function writeLeaf(
	tree: bolt.DynamicTree,
	shapeB: {[number]: bolt.BoxShape},
	envMinB: {[number]: Vector3},
	envMaxB: {[number]: Vector3},
	padding: Vector3,
	id: number,
	nmin: Vector3,
	nmax: Vector3,
	hasLeaf: boolean
)
	local pmin, pmax = nmin - padding, nmax + padding

	if hasLeaf then
		tree:remove(id)
	end

	local shape = shapeB[id]
	shape.half_extents = (pmax - pmin) * 0.5
	tree:insert(id, CFrame.new((pmax + pmin) * 0.5), shape)

	envMinB[id], envMaxB[id] = pmin, pmax
end

function UnionRegister.new(unionsPerPart: number, unionSize: number, padding: number, predictionFrames: number, updateFraction: number): UnionRegister
	local self = setmetatable({}, UnionRegister) :: any

	self.unionsPerPart = unionsPerPart
	self.unionSize = unionSize
	self.padding = vector.one * padding
	self.predictionFrames = predictionFrames
	self.updateFraction = updateFraction

	self.active = {
		min = {}, max = {},
		seedMin = {}, seedMax = {},
		predLow = {}, predHigh = {},
		block = {}, present = {},
	}

	self.leaf = {}
	for block = 1, unionsPerPart do
		self.leaf[block] = {envMin = {}, envMax = {}, shape = {}}
	end

	return self :: UnionRegister
end

function UnionRegister.AddPart(self: UnionRegister, id: number)
	local active = self.active
	active.block[id] = NO_BLOCK
	active.present[id] = false
	active.predLow[id] = Vector3.zero
	active.predHigh[id] = Vector3.zero

	-- a placeholder box: writeLeaf always sets half_extents before this table is ever
	-- registered in a tree, so the initial size here is never observed
	for block = 1, self.unionsPerPart do
		self.leaf[block].shape[id] = bolt.create_box(Vector3.zero)
	end
end

function UnionRegister.RemovePart(self: UnionRegister, id: number)
	local active = self.active
	active.min[id] = nil
	active.max[id] = nil
	active.seedMin[id] = nil
	active.seedMax[id] = nil
	active.predLow[id] = nil
	active.predHigh[id] = nil
	active.block[id] = nil
	active.present[id] = nil

	for block = 1, self.unionsPerPart do
		local leaf = self.leaf[block]
		leaf.envMin[id] = nil
		leaf.envMax[id] = nil
		leaf.shape[id] = nil
	end
end

-- frame: absolute 1-indexed ring position. block: 1..unionsPerPart. slot: 0-indexed position
-- within the block (0 == first frame). Caller derives block/slot from frame and Settings.UNION_SIZE.
function UnionRegister.UpdateFrame(self: UnionRegister, frame: number, block: number, slot: number, tree: bolt.DynamicTree, partList: {PartInfo})
	local active = self.active
	local unionMin, unionMax = active.min, active.max
	local seedMin, seedMax = active.seedMin, active.seedMax
	local predLow, predHigh = active.predLow, active.predHigh
	local unionBlock = active.block
	local present = active.present

	local leaf = self.leaf[block] -- block is loop-invariant, hoisted out of the part loop
	local envMinB, envMaxB, shapeB = leaf.envMin, leaf.envMax, leaf.shape
	local leafMap = tree.leaf_map

	local unionSize = self.unionSize
	local predictionFrames = self.predictionFrames
	local updateFraction = self.updateFraction
	local padding = self.padding
	local scale = math.min(unionSize - slot, predictionFrames) / unionSize

	for _, info in partList do
		info.register:Step()
		local data = info.register:AtIndex(frame)
		local id = info.id

		if not data.cframe then
			-- absent this frame: leaf (if any) stays put, narrow phase skips it via cframe == false.
			-- unionBlock[id] is deliberately left untouched so the block's first PRESENT frame --
			-- whenever it comes -- is what triggers the rotation branch below.
			continue
		end
		present[id] = true

		-- OBB -> world AABB, once per part per frame. Same math as Bolt's unmargined_shape_aabb
		-- BOX branch; the result doubles as the tight per-frame cache the query path reads.
		local cf: CFrame, h = data.cframe, data.size * 0.5
		local e = vector.abs(cf.RightVector) * h.X
			+ vector.abs(cf.UpVector) * h.Y
			+ vector.abs(cf.LookVector) * h.Z
		local bmin, bmax = cf.Position - e, cf.Position + e
		data.aabbMin, data.aabbMax = bmin, bmax

		local hasLeaf = leafMap[id] ~= nil

		if unionBlock[id] ~= block then
			-- ============ ROTATION: first present frame of this block ============
			local previousBlock = unionBlock[id]
			if previousBlock ~= NO_BLOCK then
				-- read union/seed BEFORE overwriting -- they still hold the previous block
				predLow[id] = clampPred(unionMin[id] - seedMin[id], data.size)
				predHigh[id] = clampPred(unionMax[id] - seedMax[id], data.size)
			end
			-- else: first block this part has ever seen. predLow/predHigh stay at the
			-- vector.zero AddPart set them to -- no prior sweep, no inflation.

			unionBlock[id] = block
			seedMin[id], seedMax[id] = bmin, bmax
			unionMin[id], unionMax[id] = bmin, bmax -- union NEVER mixes blocks

			local nmin = bmin + predLow[id] * scale
			local nmax = bmax + predHigh[id] * scale

			-- Reuse the ~FRAME_CAP-frame-stale leaf only if it contains the new envelope AND
			-- isn't wastefully larger than it. Containment alone would let an old leaf sit at
			-- many times the needed volume for the whole block.
			if hasLeaf
				and contains(envMinB[id], envMaxB[id], nmin, nmax)
				and volumeOf(nmin - padding, nmax + padding) >= volumeOf(envMinB[id], envMaxB[id]) * updateFraction then
				continue
			end

			writeLeaf(tree, shapeB, envMinB, envMaxB, padding, id, nmin, nmax, hasLeaf)
			continue
		end

		-- ============ GROW: containment only, no ratio ============
		-- The envelope was sized deliberately from the prediction; shrinking it mid-block
		-- would fight that. This path runs ~95% of the time.
		local umin = vector.min(unionMin[id], bmin)
		local umax = vector.max(unionMax[id], bmax)
		unionMin[id], unionMax[id] = umin, umax

		if hasLeaf and contains(envMinB[id], envMaxB[id], umin, umax) then
			continue
		end

		writeLeaf(tree, shapeB, envMinB, envMaxB, padding, id,
			umin + predLow[id] * scale, umax + predHigh[id] * scale, hasLeaf)
	end
end

-- last frame of a block: shrink overshot predictions, drop leaves for parts absent all block,
-- and let the tree rebalance while it's at its most degraded, right before 64 dormant-but-queryable frames.
function UnionRegister.Seal(self: UnionRegister, block: number, tree: bolt.DynamicTree, partList: {PartInfo})
	local active = self.active
	local unionMin, unionMax = active.min, active.max
	local present = active.present

	local leaf = self.leaf[block]
	local envMinB, envMaxB, shapeB = leaf.envMin, leaf.envMax, leaf.shape
	local leafMap = tree.leaf_map
	local padding = self.padding
	local updateFraction = self.updateFraction

	for _, info in partList do
		local id = info.id

		if not present[id] then
			-- absent the whole block: dropping it costs a wasted candidate at worst, but
			-- leaving it pollutes tree quality for the ~64 frames this tree sits dormant
			if leafMap[id] then
				tree:remove(id)
			end
			continue
		end
		present[id] = false -- reset for the next cycle

		-- shrink on ratio, same test as the rotation branch applied at the other end of the
		-- block: the prediction term is dropped entirely since there's no remaining sweep to cover
		local umin, umax = unionMin[id], unionMax[id]
		if volumeOf(umin - padding, umax + padding) < volumeOf(envMinB[id], envMaxB[id]) * updateFraction then
			writeLeaf(tree, shapeB, envMinB, envMaxB, padding, id, umin, umax, true)
		end
	end

	if tree:should_rebuild() then
		tree:partial_rebuild()
	end
end

return UnionRegister
