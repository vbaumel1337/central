--!native
--!strict
--!optimize 2
--[[
	Prototype history backend: one shared topology, per-frame bounds.

	The shipping backend (HistoricalHitboxes) keeps `frameCap` independent dynamic trees and
	rewrites one of them every frame. A slot is only rewritten once every `frameCap` frames,
	so by the time it comes around again every part in it has moved far more than the tree's
	padding, and `move` always falls through to the remove + reinsert path
	(aabb_tree.luau:715). That makes UpdateFrame O(parts x log parts) of tree restructuring
	every frame, which is where the per-frame cost in the README goes.

	This backend separates the two things a BVH stores:

	  * topology - which leaves are siblings. Expensive to compute, changes slowly.
	  * bounds   - the boxes themselves. Cheap, change every frame.

	One bolt tree owns the topology and the node index space. It is mutated only when a part
	is added or removed, plus an occasional full rebuild for quality. Per historical frame we
	store nothing but a pair of {vector} arrays indexed by that tree's node indices. Capturing
	a frame writes each part's exact AABB into its leaf slot and then runs one bottom-up pass
	to fill the internal nodes: O(nodes) of pure arithmetic, no restructuring, no allocation.

	Queries reuse bolt's traversals unmodified, by pointing the tree's aabb_min/aabb_max at
	the slot being queried, so the broad phase is the same code that runs today.

	Only the *grouping* is shared across frames. The boxes a query tests against are still
	each frame's exact per-part AABBs, refit bottom-up, so they are as tight as the per-frame
	trees are. What a shared topology costs is grouping quality: two parts that are siblings
	because they were near each other across the window may not be near each other in one
	particular frame. That is the tradeoff to measure.
]]

local bolt = require(script.Parent.Parent.bolt)
local Settings = require(script.Parent.Parent.Settings)
local PartRegister = require(script.Parent.Registers.PartRegister)
local HistoryQueries = require(script.Parent.HistoryQueries)

local TREE_REBUILD_CHECK_INTERVAL = Settings.TREE_REBUILD_CHECK_INTERVAL
local PARTIAL_REBUILD_RATIO_THRESHOLD = Settings.PARTIAL_REBUILD_RATIO_THRESHOLD
local FULL_REBUILD_RATIO_THRESHOLD = Settings.FULL_REBUILD_RATIO_THRESHOLD
local NODE_REFIT_BUDGET = Settings.NODE_REFIT_BUDGET
local ENVELOPE_CELL_BUDGET = Settings.ENVELOPE_CELL_BUDGET

local NULL = 0

--an inverted box is the identity for union, so an inactive leaf contributes nothing to its
--ancestors' bounds. it does report a false positive to the slab tests, but only for subtrees
--that are entirely inactive, and the narrow phase filters those out on the hitbox lookup
--anyway, exactly as it already does for a missing hitbox.
local EMPTY_MIN = vector.create(math.huge, math.huge, math.huge)
local EMPTY_MAX = vector.create(-math.huge, -math.huge, -math.huge)

--every hitbox is a box, so the general shape_aabb dispatch inside bolt is not needed here
local function boxAABB(cf: CFrame, halfExtents: Vector3): (vector, vector)
	local center = cf.Position
	local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector

	local e = vector.abs(right :: any) * halfExtents.X +
		vector.abs(up :: any) * halfExtents.Y +
		vector.abs(look :: any) * halfExtents.Z

	return center - e :: any, center + e :: any
end

export type Hitbox = HistoryQueries.Hitbox

type PartInfo = {id: number, part: BasePart, register: PartRegister.PartRegister, listIndex: number, node: number}

local HistoricalRefit = {}
HistoricalRefit.__index = HistoricalRefit

export type HistoricalRefit = typeof(setmetatable(
	{} :: {
		frameCap: number,
		padding: number,
		tree: bolt.DynamicTree,
		--the tree's own bounds. every structural mutation and every rebuild runs against these,
		--never against a slot, so a slot can never be corrupted by an insert refitting ancestors
		envMin: {vector},
		envMax: {vector},
		--[slot][nodeIndex]. leaves are written on capture, internals by refitSlot
		slotMin: {{vector}},
		slotMax: {{vector}},
		--a slot's internal nodes are stale until refit; leaves are always current
		slotDirty: {boolean},
		--how many hitboxes are live in a slot, so an empty slot skips traversal entirely
		slotCount: {number},
		--internal node indices, children before parents, so refit is a forward loop
		order: {number},
		--subsequence of order whose child pair (or a descendant's) changed since prevC1/prevC2 was
		--last snapshotted. what a dirty slot actually needs refit over, instead of all of order
		dirtyOrder: {number},
		--child1/child2 as of the last moment every slot was fully consistent with the topology.
		--only advances once a drain fully catches up (see UpdateFrame); frozen while one is in
		--flight, so a second change mid-drain diffs against the same baseline as the first
		prevC1: {number},
		prevC2: {number},
		--scratch reused by computeDirtyOrder's validity walk; entries are always written before
		--they're read within the same call, so it never needs clearing between calls
		validScratch: {boolean},
		topologyDirty: boolean,
		nextRebuildCheck: number,
		--slotCostRatio's reading as of the last rebuild; nil forces the first rebuild, since bolt's
		--own should_rebuild bootstrap only fires above its proxy threshold and this tree is never
		--restructured by movement
		baseCostRatio: number?,
		--the rebuild check staged across captures so its three costs (the cheap ratio check, the
		--envelope sweep, and the rebuild itself) never land in the same frame. idle is the default:
		--nothing runs until nextRebuildCheck trips a fresh ratio check, at which point it either
		--stays idle (ratio's fine) or moves to sweeping.
		stage: "idle" | "sweeping" | "rebuilding",
		--how far the sweep has cursored into partList; reset to 0 on entering "sweeping"
		envSweepCursor: number,
		hitboxes: {[number]: {[number]: Hitbox}},
		parts: {[BasePart]: PartInfo},
		partList: {PartInfo},
		nextPartId: number,
		AddPart: (self: any, register: PartRegister.PartRegister) -> (),
		RemovePart: (self: any, part: BasePart) -> (),
		UpdateFrame: (self: any, index: number) -> (),
		QueryRaycast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QueryShapecast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QuerySimpleShapecast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> (Hitbox?, number?),
		QueryShape: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> {[BasePart]: Hitbox},
		GetHitboxesForOwner: (self: any, index: number, ownerName: string) -> {Hitbox},
		Destroy: (self: any) -> (),
	},
	HistoricalRefit
))

local wrapIndex = HistoryQueries.wrapIndex

--flatten the tree's internal nodes into an order where a node always follows both its children.
--a preorder walk always emits a parent before its descendants, so reversing one gives exactly that.
local function relinearize(self: HistoricalRefit)
	local tree = self.tree
	local child1 = tree.child1
	local child2 = tree.child2
	local order = self.order

	table.clear(order)
	self.topologyDirty = false

	local root = tree.root
	if root == NULL or child1[root] == NULL then
		--empty tree, or a lone leaf that owns its own bounds
		return
	end

	local stack = {root}
	local top = 1
	local count = 0

	while top > 0 do
		local node = stack[top]
		top -= 1

		count += 1
		order[count] = node

		local c1 = child1[node]
		if child1[c1] ~= NULL then
			top += 1
			stack[top] = c1
		end

		local c2 = child2[node]
		if child1[c2] ~= NULL then
			top += 1
			stack[top] = c2
		end
	end

	local i, j = 1, count
	while i < j do
		order[i], order[j] = order[j], order[i]
		i += 1
		j -= 1
	end
end

--the whole per-frame cost of this backend: one forward pass, two vector ops per internal node.
--the slot just captured this frame passes self.order (every leaf's box just changed, so every
--internal node needs recomputing); a stale slot being caught up to a topology change instead
--passes self.dirtyOrder, since its leaf boxes are untouched and only the nodes actually affected
--by the change can have gone stale
local function refitSlot(self: HistoricalRefit, index: number, order: {number})
	local tree = self.tree
	local child1 = tree.child1
	local child2 = tree.child2
	local mn = self.slotMin[index]
	local mx = self.slotMax[index]

	for k = 1, #order do
		local node = order[k]
		local c1 = child1[node]
		local c2 = child2[node]
		mn[node] = vector.min(mn[c1], mn[c2])
		mx[node] = vector.max(mx[c1], mx[c2])
	end

	self.slotDirty[index] = false
end

--diffs order against the last fully-consistent snapshot (prevC1/prevC2), walking
--children-before-parents so a parent's validity can reuse its children's just-computed answer.
--a node is valid - unaffected by whatever changed - only if its own child pair is unchanged and
--both children are either leaves or themselves valid; leaves are unconditionally valid, since the
--capture loop (or AddPart's EMPTY seeding) writes every live leaf's box directly, every slot,
--regardless of topology. dirtyOrder ends up as just the nodes actually touched: the insertion
--path plus rotations, not the whole tree.
local function computeDirtyOrder(self: HistoricalRefit)
	local tree = self.tree
	local child1 = tree.child1
	local child2 = tree.child2
	local order = self.order
	local prevC1 = self.prevC1
	local prevC2 = self.prevC2
	local valid = self.validScratch
	local dirtyOrder = self.dirtyOrder

	local count = 0
	for k = 1, #order do
		local node = order[k]
		local c1 = child1[node]
		local c2 = child2[node]
		local c1Valid = child1[c1] == NULL or valid[c1]
		local c2Valid = child1[c2] == NULL or valid[c2]
		local nodeValid = c1 == prevC1[node] and c2 == prevC2[node] and c1Valid and c2Valid
		valid[node] = nodeValid
		if not nodeValid then
			count += 1
			dirtyOrder[count] = node
		end
	end

	for k = #dirtyOrder, count + 1, -1 do
		dirtyOrder[k] = nil
	end
end

--a topology change invalidates internal bounds tree-wide, but computeDirtyOrder's diff against
--the last consistent snapshot usually shows only a small fraction actually changed - the drain
--and bind's lazy fallback both refit dirtyOrder instead of every slot's full order. prevC1/prevC2
--only advance once every slot has actually caught up (see UpdateFrame's snapshotTopology call):
--while a drain is in flight, a second change here diffs against that same old snapshot, so
--dirtyOrder grows to the union of every change since the last time every slot was consistent.
local function handleTopologyChange(self: HistoricalRefit)
	relinearize(self)
	computeDirtyOrder(self)
	for slot = 1, self.frameCap do
		self.slotDirty[slot] = true
	end
end

--only called once a drain fully catches every slot up to the current topology (UpdateFrame), so
--the diff the next topology change computes starts from a baseline every slot actually matches.
--only order's entries matter: computeDirtyOrder only ever looks up prevC1/prevC2 for node indices
--drawn from order. an entry for an index that falls out of order (freed by a rebuild) is simply
--never read again - and if that index is later recycled, a coincidental match is still correct,
--per the invariant computeDirtyOrder relies on: matching children means the same subtree.
local function snapshotTopology(self: HistoricalRefit)
	local tree = self.tree
	local child1 = tree.child1
	local child2 = tree.child2
	local order = self.order
	local prevC1 = self.prevC1
	local prevC2 = self.prevC2

	for k = 1, #order do
		local node = order[k]
		prevC1[node] = child1[node]
		prevC2[node] = child2[node]
	end

	table.clear(self.dirtyOrder)
end

--point the tree at a slot's bounds so bolt's own traversals run against that frame.
--returns false when the slot holds nothing worth traversing.
local function bind(self: HistoricalRefit, index: number): boolean
	if self.slotCount[index] == 0 then
		return false
	end

	--RemovePart runs from an Observer and a rebuild lands at the end of UpdateFrame, so a query
	--can arrive while `order` still describes the previous topology
	if self.topologyDirty then
		handleTopologyChange(self)
	end

	if self.slotDirty[index] then
		refitSlot(self, index, self.dirtyOrder)
	end

	local tree = self.tree
	tree.aabb_min = self.slotMin[index]
	tree.aabb_max = self.slotMax[index]
	return true
end

local function unbind(self: HistoricalRefit)
	local tree = self.tree
	tree.aabb_min = self.envMin
	tree.aabb_max = self.envMax
end

--the topology is shared by every frame, so the boxes it is built from should describe the whole
--window rather than any single frame: each leaf gets the union of its own bounds across the slots
--it is live in. leaves with no live slot keep whatever they were inserted with, so the arrays the
--SAH builder reads stay finite. The sweep itself lives in UpdateFrame's "sweeping" stage, cursored
--over partList a budget at a time; this bottom-up pass is its last step, run once the cursor
--finishes a full pass. Without it, internal env bounds would keep whatever they were at the last
--rebuild - the sweep only ever writes LEAF env boxes - so should_rebuild-style checks against the
--envelope would end up biased toward "nothing changed". It mirrors bolt's own refit() rule
--(aabb_tree.luau:596-599) for
--`enlarged`: a node's env box only ever grows here (it's a running union across the whole window),
--so growth is flagged and never cleared. That flag is what lets partial_rebuild respond to
--envelope drift and not just to inserts - without it, a box that only ever shrank (a player who
--stopped moving) would never get flagged, and nothing would ever dissolve its subtree.
local function refitEnvelopeInternals(self: HistoricalRefit)
	local tree = self.tree
	local child1 = tree.child1
	local child2 = tree.child2
	local enlarged = tree.enlarged
	local envMin = self.envMin
	local envMax = self.envMax
	local order = self.order

	for k = 1, #order do
		local node = order[k]
		local c1 = child1[node]
		local c2 = child2[node]
		local prevMin = envMin[node]
		local prevMax = envMax[node]
		local newMin = vector.min(envMin[c1], envMin[c2])
		local newMax = vector.max(envMax[c1], envMax[c2])
		envMin[node] = newMin
		envMax[node] = newMax

		local prevSize = prevMax - prevMin
		local newSize = newMax - newMin
		if vector.dot(newSize :: vector, newSize :: vector) > vector.dot(prevSize :: vector, prevSize :: vector) then
			enlarged[node] = true
		end
	end
end

--bolt's own aabb_sah (aabb_tree.luau:50-53), reimplemented here since it isn't exported: half the
--surface area of a box, the standard SAH proxy. d.x*d.y + d.y*d.z + d.z*d.x for size d = max - min.
local function aabbSAH(mn: vector, mx: vector): number
	local d = mx - mn
	return d.x * d.y + d.y * d.z + d.z * d.x
end

--queries traverse a SLOT's bounds, not the envelope, so the rebuild trigger should measure what a
--query actually pays for - consistent by construction, since refitSlot just ran on this slot this
--frame (whichever slot `index` is: the one just captured). Sampling a single slot trades a little
--noise (a given frame's grouping may happen to be unusually good or bad) for that consistency: a
--spurious rebuild costs one paced spike, not a wrong answer.
local function slotCostRatio(self: HistoricalRefit, index: number): number
	local order = self.order
	local mn = self.slotMin[index]
	local mx = self.slotMax[index]

	local cost = 0
	for k = 1, #order do
		local node = order[k]
		cost += aabbSAH(mn[node], mx[node])
	end

	--EMPTY_MIN/EMPTY_MAX boxes (not-yet-captured or not-inWorld leaves) would corrupt the ratio,
	--so sum leaf cost from the slot's own live hitboxes rather than every node in leaf_map
	local leafCost = 0
	for _, info in self.partList do
		if self.hitboxes[index][info.id] then
			leafCost += aabbSAH(mn[info.node], mx[info.node])
		end
	end

	return cost / leafCost
end

function HistoricalRefit.new(frameCap: number, padding: number): HistoricalRefit
	local self = setmetatable({}, HistoricalRefit) :: HistoricalRefit
	self.frameCap = frameCap
	--kept for interface parity with HistoricalHitboxes. this backend stores exact per-frame
	--boxes and never re-tests containment, so there is nothing for padding to buy.
	self.padding = padding

	local tree = bolt.aabb_tree.new({aabb_padding = 0})
	self.tree = tree
	self.envMin = tree.aabb_min
	self.envMax = tree.aabb_max

	self.slotMin = {}
	self.slotMax = {}
	self.slotDirty = {}
	self.slotCount = {}
	self.hitboxes = {}
	self.order = {}
	self.dirtyOrder = {}
	self.prevC1 = {}
	self.prevC2 = {}
	self.validScratch = {}
	self.topologyDirty = false
	self.nextRebuildCheck = os.clock() + TREE_REBUILD_CHECK_INTERVAL
	self.baseCostRatio = nil
	self.stage = "idle"
	self.envSweepCursor = 0

	for index = 1, frameCap do
		self.slotMin[index] = {}
		self.slotMax[index] = {}
		self.slotDirty[index] = false
		self.slotCount[index] = 0
		self.hitboxes[index] = {}
	end

	self.parts = {}
	self.partList = {}
	self.nextPartId = 0

	return self
end

function HistoricalRefit.AddPart(self: HistoricalRefit, register: PartRegister.PartRegister)
	local part = register.part
	if self.parts[part] then
		return
	end

	self.nextPartId += 1
	local id = self.nextPartId

	local tree = self.tree
	unbind(self)

	--seeded at the part's current pose so the topology is sensible before any frame is captured;
	--refreshEnvelope widens it to the window once there is history to widen it with
	tree:insert(id, part.CFrame, bolt.create_box(part.Size))
	--leaf indices survive both rebuild kinds, so caching it once here avoids a leaf_map lookup
	--per part in every capture
	local node = tree.leaf_map[id]

	local info: PartInfo = {id = id, part = part, register = register, listIndex = #self.partList + 1, node = node}
	self.parts[part] = info
	table.insert(self.partList, info)

	--every leaf must have bounds in every slot before that slot can be refit, even the slots
	--this part has not been captured into yet
	for index = 1, self.frameCap do
		self.slotMin[index][node] = EMPTY_MIN
		self.slotMax[index][node] = EMPTY_MAX
		self.slotDirty[index] = true
	end

	self.topologyDirty = true
end

function HistoricalRefit.RemovePart(self: HistoricalRefit, part: BasePart)
	local info = self.parts[part]
	if not info then
		return
	end

	local tree = self.tree
	unbind(self)

	local node = tree.leaf_map[info.id]
	for index = 1, self.frameCap do
		if self.hitboxes[index][info.id] then
			self.hitboxes[index][info.id] = nil
			self.slotCount[index] -= 1
		end
		if node then
			self.slotMin[index][node] = EMPTY_MIN
			self.slotMax[index][node] = EMPTY_MAX
		end
		self.slotDirty[index] = true
	end

	tree:remove(info.id)
	self.topologyDirty = true

	local lastIndex = #self.partList
	local listIndex = info.listIndex
	if listIndex ~= lastIndex then
		local lastInfo = self.partList[lastIndex]
		self.partList[listIndex] = lastInfo
		lastInfo.listIndex = listIndex
	end
	self.partList[lastIndex] = nil

	self.parts[part] = nil
end

function HistoricalRefit.UpdateFrame(self: HistoricalRefit, index: number)
	if self.topologyDirty then
		handleTopologyChange(self)
	end

	local tree = self.tree
	local frameHitboxes = self.hitboxes[index]
	local mn = self.slotMin[index]
	local mx = self.slotMax[index]
	local count = self.slotCount[index]

	for _, info in self.partList do
		local register = info.register
		register:Step()
		local id = info.id
		local node = info.node
		local hitbox = frameHitboxes[id]

		if not register.inWorld then
			if hitbox then
				frameHitboxes[id] = nil
				count -= 1
			end
			mn[node] = EMPTY_MIN
			mx[node] = EMPTY_MAX
			continue
		end

		--CFrame is the only field still worth reading off the instance every capture
		local cframe = register.part.CFrame
		local size = register.size

		local current: Hitbox
		if not hitbox then
			current = {
				id = id,
				cframe = cframe,
				shape = bolt.create_box(size),
				size = size,
				boundingRadius = size.Magnitude / 2,
				instance = info.part,
				owner = register.owner,
				collisionGroup = register.collisionGroup,
				canCollide = register.canCollide,
				frameOffset = 0,
				active = true,
			}
			frameHitboxes[id] = current
			count += 1
		else
			current = hitbox
			if size ~= current.size then
				current.size = size
				current.shape = bolt.create_box(size)
				current.boundingRadius = size.Magnitude / 2
			end
			current.cframe = cframe
			current.canCollide = register.canCollide
			current.collisionGroup = register.collisionGroup
		end

		local boxMin, boxMax = boxAABB(current.cframe, current.shape.half_extents)
		mn[node] = boxMin
		mx[node] = boxMax
	end

	self.slotCount[index] = count
	refitSlot(self, index, self.order)

	--the drain doesn't have to guarantee termination on its own: the capture above already cleared
	--`index`'s own flag unconditionally, so every slot is refit at least once every frameCap
	--captures for free, and the backlog - one boolean per slot - can never grow past the ring. The
	--drain only shortens the wait for a slot that would otherwise be queried before its natural
	--rewrite, so it can be capped hard without ever failing to finish; no wall clock needed.
	local slotDirty = self.slotDirty
	local remaining = 0
	for slot = 1, self.frameCap do
		if slotDirty[slot] then
			remaining += 1
		end
	end

	if remaining > 0 then
		--budgeted in units of work (node refits), not slots, so it scales on the size of the
		--change (post-Step-2, #dirtyOrder) rather than part count: a small AddPart diff drains the
		--whole ring in one capture, while a full_rebuild at 800 parts paces itself over several.
		local maxSlots = math.max(1, NODE_REFIT_BUDGET // math.max(1, #self.dirtyOrder))

		local drained = 0
		--newest-first: slot index+1 is overwritten by the very next capture, so refitting it here
		--would be wasted work; slot index-1 survives frameCap-1 more captures, maximising the
		--useful life of every refit this loop spends
		for offset = 1, self.frameCap do
			if drained >= maxSlots then
				break
			end
			local slot = wrapIndex(index - offset, self.frameCap)
			if slotDirty[slot] then
				refitSlot(self, slot, self.dirtyOrder)
				drained += 1
			end
		end

		remaining -= drained
	end

	--checked unconditionally, not nested in the branch above: the ring can also reach fully-clean
	--through natural per-frame captures alone, with no drain ever running this frame (`remaining`
	--already 0 at the top) - that still means every slot has caught up, so the next topology
	--change's diff should start from a baseline every slot actually matches. `remaining > 0` above
	--covers most of it, but nesting this in there would miss a backlog whose last slot happened to
	--heal on its own natural turn.
	if remaining == 0 and #self.dirtyOrder > 0 then
		snapshotTopology(self)
	end

	--staged so the three costs below never share a frame: idle's own check is one slotCostRatio
	--(O(nodes)); sweeping is the O(#partList * frameCap) envelope union, paid only once a check
	--actually trips, not on every idle check; rebuilding is the SAH build itself. Each capture does
	--at most one stage's worth of work.
	if self.stage == "idle" then
		local now = os.clock()
		if now >= self.nextRebuildCheck then
			self.nextRebuildCheck = now + TREE_REBUILD_CHECK_INTERVAL

			--baseCostRatio nil forces the first rebuild - see its declaration for why. Otherwise
			--this is exactly the cheap check that lets most intervals skip the sweep entirely: no
			--envelope work happens unless the slot just captured already reads as degraded.
			local shouldSweep = self.baseCostRatio == nil
				or slotCostRatio(self, index) > self.baseCostRatio * PARTIAL_REBUILD_RATIO_THRESHOLD

			if shouldSweep then
				self.stage = "sweeping"
				self.envSweepCursor = 0
			end
		end
	elseif self.stage == "sweeping" then
		--the same union refreshEnvelope did in one shot, cursored over partList instead of
		--leaf_map so a mutation mid-sweep (AddPart/RemovePart landing between captures) is just an
		--array whose current length this reads fresh each capture, never something unsafe to walk.
		--this unions boxes from slots that may be mid-rewrite underneath it - fine, since the
		--envelope is a heuristic SAH input, not a correctness bound.
		local partList = self.partList
		local total = #partList
		local slotMin = self.slotMin
		local slotMax = self.slotMax
		local hitboxes = self.hitboxes
		local envMin = self.envMin
		local envMax = self.envMax
		local frameCap = self.frameCap

		local partsPerCapture = math.max(1, ENVELOPE_CELL_BUDGET // frameCap)
		local cursor = self.envSweepCursor
		local upto = math.min(cursor + partsPerCapture, total)

		for i = cursor + 1, upto do
			local info = partList[i]
			local id = info.id
			local node = info.node
			local leafMn: vector? = nil
			local leafMx: vector? = nil

			for slot = 1, frameCap do
				if hitboxes[slot][id] then
					local a = slotMin[slot][node]
					local b = slotMax[slot][node]
					if leafMn then
						leafMn = vector.min(leafMn :: vector, a)
						leafMx = vector.max(leafMx :: vector, b)
					else
						leafMn = a
						leafMx = b
					end
				end
			end

			if leafMn then
				envMin[node] = leafMn :: vector
				envMax[node] = leafMx :: vector
			end
		end

		self.envSweepCursor = upto

		if upto >= total then
			--RemovePart's swap-removal can move an unswept part to an already-swept index; it then
			--keeps the env box AddPart seeded from its current pose for one generation. harmless.
			refitEnvelopeInternals(self)
			self.stage = "rebuilding"
		end
	elseif self.stage == "rebuilding" then
		unbind(self)

		--partial_rebuild is the routine path: it only touches subtrees bolt already flagged
		--enlarged (an insert, or refitEnvelopeInternals' envelope-growth marking), so it pays for a
		--smaller SAH build and, via Step 2's dirtyOrder, a smaller refit backlog too. full_rebuild
		--is the floor for the case partial can't fix: a box that only ever shrank never gets
		--flagged, so nothing dissolves its subtree and grouping can drift regardless. idle already
		--established that a rebuild is warranted, so only the full/partial split is decided here,
		--against however this capture's own slot reads now - sweeping may have taken several
		--captures, so this is a fresher sample than the one idle tripped on.
		if self.baseCostRatio == nil or slotCostRatio(self, index) > self.baseCostRatio * FULL_REBUILD_RATIO_THRESHOLD then
			tree:full_rebuild()
		else
			tree:partial_rebuild()
		end

		--relinearize + a real diff, rather than just flagging dirty, because slotCostRatio below
		--needs this frame's own slot refit under the new topology to mean anything - self.order
		--(and this slot's internal bounds) still describe the topology from before the rebuild
		--until this runs. dirtyOrder-scoped, so a partial_rebuild's cost here stays proportional to
		--what it actually touched; only a full_rebuild makes this a full refit.
		handleTopologyChange(self)
		refitSlot(self, index, self.dirtyOrder)
		self.baseCostRatio = slotCostRatio(self, index)
		self.stage = "idle"
	end
end

--the traversals themselves live in HistoryQueries. this backend's whole contribution to a query
--is aiming the one shared tree at a slot's bounds before the walk, and back at the envelope after.
local queries = HistoryQueries.create(function(self: HistoricalRefit, index: number): bolt.DynamicTree?
	if not bind(self, index) then
		return nil
	end

	return self.tree
end, unbind)

HistoricalRefit.QueryRaycast = queries.QueryRaycast
HistoricalRefit.QueryShapecast = queries.QueryShapecast
HistoricalRefit.QuerySimpleShapecast = queries.QuerySimpleShapecast
HistoricalRefit.QueryShape = queries.QueryShape

function HistoricalRefit.GetHitboxesForOwner(self: HistoricalRefit, index: number, ownerName: string): {Hitbox}
	local frameHitboxes = self.hitboxes[wrapIndex(index, self.frameCap)]
	local results: {Hitbox} = {}
	for _, hitbox in frameHitboxes do
		if hitbox.owner == ownerName then
			table.insert(results, hitbox)
		end
	end
	return results
end

function HistoricalRefit.Destroy(self: HistoricalRefit)
	local tree = self.tree
	unbind(self)
	tree:clear()
	--clear() swaps in fresh arrays, so the cached envelope references have to follow
	self.envMin = tree.aabb_min
	self.envMax = tree.aabb_max

	for index = 1, self.frameCap do
		table.clear(self.slotMin[index])
		table.clear(self.slotMax[index])
		table.clear(self.hitboxes[index])
		self.slotDirty[index] = false
		self.slotCount[index] = 0
	end

	table.clear(self.order)
	table.clear(self.dirtyOrder)
	table.clear(self.prevC1)
	table.clear(self.prevC2)
	table.clear(self.validScratch)
	table.clear(self.parts)
	table.clear(self.partList)
end

return HistoricalRefit
