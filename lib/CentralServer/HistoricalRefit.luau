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
local PhysicsService = game:GetService("PhysicsService")

local bolt = require(script.Parent.Parent.bolt)
local Settings = require(script.Parent.Parent.Settings)
local PartRegister = require(script.Parent.Registers.PartRegister)

local gjk = bolt.dispatch.gjk
local collision = bolt.collision
local shapeMap = require(script.Parent.Parent.bolt.shape_map)

local GJK_TOLERANCE = Settings.GJK_TOLERANCE
local PREFER_NEAREST_FRAME = Settings.PREFER_NEAREST_FRAME
local TREE_REBUILD_CHECK_INTERVAL = Settings.TREE_REBUILD_CHECK_INTERVAL
local REFIT_BUDGET = Settings.HISTORY_REFIT_BUDGET

local NULL = 0

--an inverted box is the identity for union, so an inactive leaf contributes nothing to its
--ancestors' bounds. it does report a false positive to the slab tests, but only for subtrees
--that are entirely inactive, and the narrow phase filters those out on the hitbox lookup
--anyway, exactly as it already does for a missing hitbox.
local EMPTY_MIN = vector.create(math.huge, math.huge, math.huge)
local EMPTY_MAX = vector.create(-math.huge, -math.huge, -math.huge)

--the closest-hit tree queries work in fractions of the cast, not studs, so narrow phase
--distances get scaled by this. a zero length sweep collapses every hit onto fraction 0.
local function fractionScale(direction: Vector3): number
	local length = direction.Magnitude
	return if length > 0 then 1 / length else 0
end

--every hitbox is a box, so the general shape_aabb dispatch inside bolt is not needed here
local function boxAABB(cf: CFrame, halfExtents: Vector3): (vector, vector)
	local center = cf.Position
	local right, up, look = cf.RightVector, cf.UpVector, cf.LookVector

	local e = vector.abs(right :: any) * halfExtents.X +
		vector.abs(up :: any) * halfExtents.Y +
		vector.abs(look :: any) * halfExtents.Z

	return center - e :: any, center + e :: any
end

export type Hitbox = {
	id: number,
	cframe: CFrame,
	shape: bolt.BoxShape,
	size: Vector3,
	instance: BasePart,
	owner: string,
	collisionGroup: string,
	canCollide: boolean,
	frameOffset: number,
	active: boolean,
}

type PartInfo = {id: number, part: BasePart, register: PartRegister.PartRegister, listIndex: number}

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
		topologyDirty: boolean,
		nextRebuildCheck: number,
		hitboxes: {[number]: {[number]: Hitbox}},
		parts: {[BasePart]: PartInfo},
		partList: {PartInfo},
		nextPartId: number,
		AddPart: (self: any, register: PartRegister.PartRegister) -> (),
		RemovePart: (self: any, part: BasePart) -> (),
		UpdateFrame: (self: any, index: number) -> (),
		QueryRaycast: (self: any, player: Player, centerIndex: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QueryShapecast: (self: any, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QuerySimpleShapecast: (self: any, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?) -> (Hitbox?, number?),
		QueryShape: (self: any, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?) -> {[BasePart]: Hitbox},
		GetHitboxesForOwner: (self: any, index: number, ownerName: string) -> {Hitbox},
		Destroy: (self: any) -> (),
	},
	HistoricalRefit
))

local DEFAULT_GROUP = Settings.DEFAULT_HITBOX_QUERY_GROUP

local function wrapIndex(index: number, frameCap: number): number
	return ((index - 1) % frameCap) + 1
end

local function isFilteredOut(hitbox: Hitbox, params: (RaycastParams | OverlapParams)?): boolean

	if not params then
		return false
	end

	if params.RespectCanCollide and not hitbox.canCollide then
		return true
	end

	if not PhysicsService:CollisionGroupsAreCollidable(params.CollisionGroup or DEFAULT_GROUP, hitbox.collisionGroup) then
		return true
	end

	local exclude = params.ExcludeInstances :: {Instance}?
	if exclude then
		for _, excluded in ipairs(exclude) do
			if hitbox.instance == excluded or hitbox.instance:IsDescendantOf(excluded) then
				return true
			end
		end
	end

	local include = params.IncludeInstances :: {Instance}?
	if include and #include > 0 then
		for _, included in ipairs(include) do
			if hitbox.instance == included or hitbox.instance:IsDescendantOf(included) then
				return false
			end
		end
		return true
	end

	return false
end

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

--the whole per-frame cost of this backend: one forward pass, two vector ops per internal node
local function refitSlot(self: HistoricalRefit, index: number)
	local tree = self.tree
	local child1 = tree.child1
	local child2 = tree.child2
	local order = self.order
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

--point the tree at a slot's bounds so bolt's own traversals run against that frame.
--returns false when the slot holds nothing worth traversing.
local function bind(self: HistoricalRefit, index: number): boolean
	if self.slotCount[index] == 0 then
		return false
	end

	--RemovePart runs from an Observer and a rebuild lands at the end of UpdateFrame, so a query
	--can arrive while `order` still describes the previous topology
	if self.topologyDirty then
		relinearize(self)
		for slot = 1, self.frameCap do
			self.slotDirty[slot] = true
		end
	end

	if self.slotDirty[index] then
		refitSlot(self, index)
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
--SAH builder reads stay finite.
local function refreshEnvelope(self: HistoricalRefit)
	local tree = self.tree
	local envMin = self.envMin
	local envMax = self.envMax
	local slotMin = self.slotMin
	local slotMax = self.slotMax
	local hitboxes = self.hitboxes
	local frameCap = self.frameCap

	for id, node in tree.leaf_map do
		local mn: vector? = nil
		local mx: vector? = nil

		for slot = 1, frameCap do
			if hitboxes[slot][id] then
				local a = slotMin[slot][node]
				local b = slotMax[slot][node]
				if mn then
					mn = vector.min(mn :: vector, a)
					mx = vector.max(mx :: vector, b)
				else
					mn = a
					mx = b
				end
			end
		end

		if mn then
			envMin[node] = mn :: vector
			envMax[node] = mx :: vector
		end
	end
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
	self.topologyDirty = false
	self.nextRebuildCheck = os.clock() + TREE_REBUILD_CHECK_INTERVAL

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
	local info: PartInfo = {id = self.nextPartId, part = part, register = register, listIndex = #self.partList + 1}
	self.parts[part] = info
	table.insert(self.partList, info)

	local tree = self.tree
	unbind(self)

	--seeded at the part's current pose so the topology is sensible before any frame is captured;
	--refreshEnvelope widens it to the window once there is history to widen it with
	tree:insert(info.id, part.CFrame, bolt.create_box(part.Size))

	--every leaf must have bounds in every slot before that slot can be refit, even the slots
	--this part has not been captured into yet
	local node = tree.leaf_map[info.id]
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
		relinearize(self)
	end

	local tree = self.tree
	local leafMap = tree.leaf_map
	local frameHitboxes = self.hitboxes[index]
	local mn = self.slotMin[index]
	local mx = self.slotMax[index]
	local count = self.slotCount[index]

	for _, info in self.partList do
		info.register:Step()
		local data = info.register:AtIndex(index)
		local id = info.id
		local node = leafMap[id]
		local hitbox = frameHitboxes[id]

		if not data.cframe then
			if hitbox then
				frameHitboxes[id] = nil
				count -= 1
			end
			mn[node] = EMPTY_MIN
			mx[node] = EMPTY_MAX
			continue
		end

		local current: Hitbox
		if not hitbox then
			current = {
				id = id,
				cframe = data.cframe,
				shape = bolt.create_box(data.size),
				size = data.size,
				instance = info.part,
				owner = info.register.owner,
				collisionGroup = info.part.CollisionGroup,
				canCollide = data.canCollide,
				frameOffset = 0,
				active = true,
			}
			frameHitboxes[id] = current
			count += 1
		else
			current = hitbox
			if data.size ~= current.size then
				current.size = data.size
				current.shape = bolt.create_box(data.size)
			end
			current.cframe = data.cframe
			current.canCollide = data.canCollide
		end

		local boxMin, boxMax = boxAABB(current.cframe, current.shape.half_extents)
		mn[node] = boxMin
		mx[node] = boxMax
	end

	self.slotCount[index] = count
	refitSlot(self, index)

	--a structural change dirties every slot at once. draining a few per frame keeps that cost
	--off whichever query happens to land on a stale slot first.
	local budget = REFIT_BUDGET
	local slotDirty = self.slotDirty
	for offset = 1, self.frameCap do
		if budget <= 0 then
			break
		end
		local slot = wrapIndex(index + offset, self.frameCap)
		if slotDirty[slot] then
			refitSlot(self, slot)
			budget -= 1
		end
	end

	local now = os.clock()
	if now >= self.nextRebuildCheck then
		self.nextRebuildCheck = now + TREE_REBUILD_CHECK_INTERVAL

		unbind(self)
		refreshEnvelope(self)

		--should_rebuild needs a baseline to compare against, and only establishes one on its own
		--above bolt's proxy threshold. this tree is never restructured by movement, so without
		--the first rebuild small part counts would keep their insertion-order topology forever.
		if tree.base_cost_ratio == nil or tree:should_rebuild() then
			tree:full_rebuild()
			self.topologyDirty = true
			for slot = 1, self.frameCap do
				slotDirty[slot] = true
			end
		end
	end
end

function HistoricalRefit.QueryRaycast(self: HistoricalRefit, player: Player, centerIndex: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	local playerName = player.Name
	local invLength = fractionScale(rayDirection)

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil
	local bestOffset = 0

	local function queryFrame(offset: number)
		local index = wrapIndex(centerIndex + offset, self.frameCap)
		if not bind(self, index) then
			return
		end

		local frameHitboxes = self.hitboxes[index]
		--anything the cast reaches after the current best is pruned before its narrow phase runs
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		self.tree:query_ray_closest(rayOrigin, rayDirection, function(id: number): number?
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
				return nil
			end

			local hitPoint, distance, hitNormal = bolt.raycast.box(rayOrigin, rayDirection, hitbox.cframe, hitbox.shape)
			if distance == nil then
				return nil
			end

			if distance < bestDistance then
				bestDistance = distance
				bestHitbox = hitbox
				bestPoint = hitPoint
				bestNormal = hitNormal
				bestOffset = offset
			end

			return distance * invLength
		end, maxFraction)

		unbind(self)
	end

	--walk outward from the player's estimated frame, so the nearest frame is always resolved first
	for absOffset = 0, frameRange do
		if absOffset == 0 then
			queryFrame(0)
		else
			queryFrame(-absOffset)
			queryFrame(absOffset)
		end

		--both peers in the band are compared before stopping, so equal offsets resolve by distance
		if PREFER_NEAREST_FRAME and bestHitbox then
			break
		end
	end

	if not bestHitbox then
		return nil, nil, nil, nil
	end

	local resultHitbox = table.clone(bestHitbox :: Hitbox)
	resultHitbox.frameOffset = bestOffset

	return resultHitbox, bestPoint, bestDistance, bestNormal
end

function HistoricalRefit.QueryShapecast(self: HistoricalRefit, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	if direction.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end

	local playerName = player.Name
	local invLength = fractionScale(direction)

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil
	local bestOffset = 0

	local function queryFrame(offset: number)
		local index = wrapIndex(centerIndex + offset, self.frameCap)
		if not bind(self, index) then
			return
		end

		local frameHitboxes = self.hitboxes[index]
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		self.tree:query_shapecast_closest(shape, cframe, direction, function(id: number): number?
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
				return nil
			end

			local hitPoint, distance, hitNormal = gjk.shapecast(cframe, direction, shape, hitbox.cframe, hitbox.shape, GJK_TOLERANCE)
			if distance == nil then
				return nil
			end

			if distance < bestDistance then
				bestDistance = distance
				bestHitbox = hitbox
				bestPoint = hitPoint
				bestNormal = hitNormal
				bestOffset = offset
			end

			return distance * invLength
		end, maxFraction)

		unbind(self)
	end

	for absOffset = 0, frameRange do
		if absOffset == 0 then
			queryFrame(0)
		else
			queryFrame(-absOffset)
			queryFrame(absOffset)
		end

		if PREFER_NEAREST_FRAME and bestHitbox then
			break
		end
	end

	if not bestHitbox then
		return nil, nil, nil, nil
	end

	local resultHitbox = table.clone(bestHitbox :: Hitbox)
	resultHitbox.frameOffset = bestOffset

	return resultHitbox, bestPoint, bestDistance, bestNormal
end

function HistoricalRefit.QuerySimpleShapecast(self: HistoricalRefit, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, number?)
	if direction.Magnitude < 1e-6 then
		return nil, nil
	end

	local playerName = player.Name
	local invLength = fractionScale(direction)

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestOffset = 0

	local function queryFrame(offset: number)
		local index = wrapIndex(centerIndex + offset, self.frameCap)
		if not bind(self, index) then
			return
		end

		local frameHitboxes = self.hitboxes[index]
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		self.tree:query_shapecast_closest(shape, cframe, direction, function(id: number): number?
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
				return nil
			end

			local hit, distance = gjk.shapecast_simple(cframe, direction, shape, hitbox.cframe, hitbox.shape, GJK_TOLERANCE)
			if not hit or distance == nil then
				return nil
			end

			if distance < bestDistance then
				bestDistance = distance
				bestHitbox = hitbox
				bestOffset = offset
			end

			return distance * invLength
		end, maxFraction)

		unbind(self)
	end

	for absOffset = 0, frameRange do
		if absOffset == 0 then
			queryFrame(0)
		else
			queryFrame(-absOffset)
			queryFrame(absOffset)
		end

		if PREFER_NEAREST_FRAME and bestHitbox then
			break
		end
	end

	if not bestHitbox then
		return nil, nil
	end

	local resultHitbox = table.clone(bestHitbox :: Hitbox)
	resultHitbox.frameOffset = bestOffset

	return resultHitbox, bestDistance
end

local function collides(hitbox: Hitbox, cframe: CFrame, shape: bolt.Shape): boolean
	if shape.type == shapeMap.BOX then
		return collision.box_box(hitbox.cframe, hitbox.shape, cframe, shape :: bolt.BoxShape)
	elseif shape.type == shapeMap.SPHERE then
		return collision.box_sphere(hitbox.cframe, hitbox.shape, cframe, shape :: bolt.SphereShape)
	elseif shape.type == shapeMap.CAPSULE then
		return collision.box_capsule(hitbox.cframe, hitbox.shape, cframe, shape :: bolt.CapsuleShape)
	end

	return gjk.intersects(hitbox.cframe, hitbox.shape, cframe, shape, GJK_TOLERANCE)
end

function HistoricalRefit.QueryShape(self: HistoricalRefit, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?): {[BasePart]: Hitbox}
	local playerName = player.Name
	local results: {[BasePart]: Hitbox} = {}
	local partCount = 0
	local maxParts = (params and params.MaxParts) or math.huge
	maxParts = if maxParts <= 0 then math.huge else maxParts

	for offset = -frameRange, frameRange do
		local index = wrapIndex(centerIndex + offset, self.frameCap)
		if bind(self, index) then
			local frameHitboxes = self.hitboxes[index]
			for _, id in self.tree:query_shape(cframe, shape) do
				local hitbox = frameHitboxes[id]
				if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) or not collides(hitbox, cframe, shape) then
					continue
				end

				local previous = results[hitbox.instance]
				if not previous then
					if partCount >= maxParts then
						continue
					end
					partCount += 1
				end

				if not previous or math.abs(offset) < math.abs(previous.frameOffset) then
					local resultHitbox = table.clone(hitbox)
					resultHitbox.frameOffset = offset
					results[hitbox.instance] = resultHitbox
				end
			end
			unbind(self)
		end
	end
	return results
end

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
	table.clear(self.parts)
	table.clear(self.partList)
end

return HistoricalRefit
