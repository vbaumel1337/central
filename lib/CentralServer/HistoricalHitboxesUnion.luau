--!native
--!strict
--!optimize 2
local bolt = require(script.Parent.Parent.bolt)
local Settings = require(script.Parent.Parent.Settings)
local PartRegister = require(script.Parent.Registers.PartRegister)
local UnionRegister = require(script.Parent.Registers.UnionRegister)
local CollisionCache = require(script.Parent.CollisionCache)

local gjk = bolt.dispatch.gjk
local collision = bolt.collision
local shapeMap = require(script.Parent.Parent.bolt.shape_map)

local GJK_TOLERANCE = Settings.GJK_TOLERANCE
local PREFER_NEAREST_FRAME = Settings.PREFER_NEAREST_FRAME

local NEG_INF_VEC = -vector.one * math.huge
local POS_INF_VEC = vector.one * math.huge

--the closest-hit tree queries work in fractions of the cast, not studs, so narrow phase
--distances get scaled by this. a zero length sweep collapses every hit onto fraction 0.
local function fractionScale(direction: Vector3): number
	local length = direction.Magnitude
	return if length > 0 then 1 / length else 0
end

-- ============================ query pre-filter ============================
-- A union leaf's envelope can cover up to UNION_SIZE frames of sweep, so a tree candidate is a
-- much weaker signal of relevance than it was with one leaf per frame: measurably ~2x the
-- candidates reach the exact test. Each of these tests the cast against the candidate's *tight
-- per-frame* AABB -- already computed as a byproduct of the union math, so it costs nothing to
-- keep -- and rejects it before the oriented test (bolt.raycast.box / GJK) runs.
--
-- Same idioms as Bolt's own private ray_aabb/swept_aabb in aabb_tree.luau, reimplemented rather
-- than called since they aren't part of Bolt's public API and lib/bolt/ isn't patched. The
-- vector.max/min against the infinity constants is what keeps a 0 * inf NaN on an axis the cast
-- runs parallel to from poisoning the comparison.

local function rayAABB(rayOrigin: Vector3, rayInvDir: Vector3, min: Vector3, max: Vector3, maxFraction: number): boolean
	local t1 = vector.max(NEG_INF_VEC, (min - rayOrigin) * rayInvDir)
	local t2 = vector.min(POS_INF_VEC, (max - rayOrigin) * rayInvDir)

	local tMin = vector.min(t1, t2)
	local tMax = vector.max(t1, t2)

	local tmin = math.max(0, tMin.X, tMin.Y, tMin.Z)
	local tmax = math.min(maxFraction, tMax.X, tMax.Y, tMax.Z)

	return tmin <= tmax
end

-- Bolt's identity: sweeping a shape along a segment against a box is the same as expanding the
-- box by the shape's half extents and casting a ray from the shape's center through it.
local function sweptAABB(castOrigin: Vector3, castExtents: Vector3, rayInvDir: Vector3, min: Vector3, max: Vector3, maxFraction: number): boolean
	local t1 = vector.max(NEG_INF_VEC, (min - castExtents - castOrigin) * rayInvDir)
	local t2 = vector.min(POS_INF_VEC, (max + castExtents - castOrigin) * rayInvDir)

	local tMin = vector.min(t1, t2)
	local tMax = vector.max(t1, t2)

	local tmin = math.max(0, tMin.X, tMin.Y, tMin.Z)
	local tmax = math.min(maxFraction, tMax.X, tMax.Y, tMax.Z)

	return tmin <= tmax
end

local function aabbOverlap(aMin: Vector3, aMax: Vector3, bMin: Vector3, bMax: Vector3): boolean
	return aMin.X <= bMax.X and aMax.X >= bMin.X
		and aMin.Y <= bMax.Y and aMax.Y >= bMin.Y
		and aMin.Z <= bMax.Z and aMax.Z >= bMin.Z
end

-- Conservative world-axis half extents of a query shape, computed once per query. Only ever
-- over-estimates: a too-large box costs a candidate that survives to the exact test, a too-small
-- one would silently drop a real hit. Returns nil for a shape this doesn't know how to bound,
-- which disables the pre-filter for that query rather than guessing.
local function castExtents(cframe: CFrame, shape: bolt.Shape): Vector3?
	local shapeType = shape.type
	local extents: Vector3

	if shapeType == shapeMap.SPHERE then
		extents = vector.one * (shape :: bolt.SphereShape).radius
	elseif shapeType == shapeMap.CAPSULE or shapeType == shapeMap.CYLINDER then
		--both are a radius swept around a RightVector-aligned axis; a cylinder is contained by
		--the capsule with the same radius and half height, so one branch bounds both
		local swept = shape :: bolt.CapsuleShape
		extents = vector.abs(cframe.RightVector) * swept.half_height + vector.one * swept.radius
	elseif shapeType == shapeMap.HULL then
		--the one shape carrying no half_extents; its scaled original bounds it
		local hull = shape :: bolt.HullShape
		local h = hull.original_half_extents * hull.scale
		extents = vector.abs(cframe.RightVector) * h.X
			+ vector.abs(cframe.UpVector) * h.Y
			+ vector.abs(cframe.LookVector) * h.Z
	elseif shapeType == shapeMap.BOX or shapeType == shapeMap.ELLIPSOID
		or shapeType == shapeMap.WEDGE or shapeType == shapeMap.CORNER_WEDGE then
		--exact for BOX; the other three are strictly contained by the box half_extents describes
		local h = (shape :: bolt.BoxShape).half_extents
		extents = vector.abs(cframe.RightVector) * h.X
			+ vector.abs(cframe.UpVector) * h.Y
			+ vector.abs(cframe.LookVector) * h.Z
	else
		return nil
	end

	--the broad phase has to agree with the narrow phase about how big a shape is, same rule
	--shape_aabb applies: only a positive margin counts
	local margin = shape.margin
	if margin ~= nil and margin > 0 then
		return extents + vector.one * margin
	end

	return extents
end

-- ============================ candidate-list pool ============================
-- With the default frameRange every requested offset lands in the same block, so the three
-- "frames" a cast query walks are the same tree queried three times over: identical geometry,
-- identical candidate set, only a different frame's Hitbox read per candidate. The first
-- traversal records the ids it visits so the rest can replay that list instead of re-walking.
--
-- Pooled rather than allocated per query for the same reason Bolt pools its traversal stacks: a
-- `check` callback can issue its own Central query from inside a narrow phase, and a nested
-- query must not scribble over the list of the one that called it.
local idListPool: {{number}} = {}
local pooledCount = 0

local function acquireIdList(): {number}
	if pooledCount > 0 then
		local list = idListPool[pooledCount]
		pooledCount -= 1
		return list
	end
	return table.create(32) :: {number}
end

local function releaseIdList(list: {number})
	pooledCount += 1
	idListPool[pooledCount] = list
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
	-- tight per-frame world AABB; a byproduct UnionRegister already computes for the union math,
	-- reused here as the query rejection cascade's pre-filter ahead of the oriented exact test
	aabbMin: Vector3,
	aabbMax: Vector3,
}

type PartInfo = {id: number, part: BasePart, register: PartRegister.PartRegister, listIndex: number}

local HistoricalHitboxes = {}
HistoricalHitboxes.__index = HistoricalHitboxes

export type HistoricalHitboxes = typeof(setmetatable(
	{} :: {
		frameCap: number,
		unionSize: number,
		unionsPerPart: number,
		trees: {[number]: bolt.DynamicTree},
		unions: UnionRegister.UnionRegister,
		hitboxes: {[number]: {[number]: Hitbox}}, -- [frame][partId]
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
	HistoricalHitboxes
))

local DEFAULT_GROUP = Settings.DEFAULT_HITBOX_QUERY_GROUP

local function wrapIndex(index: number, frameCap: number): number
	return ((index - 1) % frameCap) + 1
end

-- 1-indexed frame -> 1-indexed block. UNION_SIZE frames per block.
local function blockOf(index: number, unionSize: number): number
	return ((index - 1) // unionSize) + 1
end

local function isFilteredOut(hitbox: Hitbox, params: (RaycastParams | OverlapParams)?): boolean

	if not params then
		return false
	end

	if params.RespectCanCollide and not hitbox.canCollide then
		return true
	end

	if not CollisionCache.IsCollidable(params.CollisionGroup or DEFAULT_GROUP, hitbox.collisionGroup) then
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

function HistoricalHitboxes.new(unionsPerPart: number, unionSize: number, padding: number, predictionFrames: number, updateFraction: number): HistoricalHitboxes
	local self = setmetatable({}, HistoricalHitboxes) :: HistoricalHitboxes
	self.unionsPerPart = unionsPerPart
	self.unionSize = unionSize
	self.frameCap = unionsPerPart * unionSize
	self.trees = {}
	self.hitboxes = {}
	self.parts = {}
	self.partList = {}
	self.nextPartId = 0
	self.unions = UnionRegister.new(unionsPerPart, unionSize, padding, predictionFrames, updateFraction)

	for block = 1, unionsPerPart do
		-- aabb_padding = 0: padding is folded into each leaf's half_extents by UnionRegister's
		-- writeLeaf instead, which (unlike the tree's own padding, frozen at construction) can
		-- vary per part and be re-tuned at runtime
		self.trees[block] = bolt.aabb_tree.new({aabb_padding = 0})
	end

	-- keyed [frame][partId], so every query path can hoist one table lookup out of its
	-- per-candidate loop and index it by id directly
	for index = 1, self.frameCap do
		self.hitboxes[index] = {}
	end

	return self
end

function HistoricalHitboxes.AddPart(self: HistoricalHitboxes, register: PartRegister.PartRegister)
	local part = register.part
	if self.parts[part] then
		return
	end

	self.nextPartId += 1
	local id = self.nextPartId
	local info: PartInfo = {id = id, part = part, register = register, listIndex = #self.partList + 1}
	self.parts[part] = info
	table.insert(self.partList, info)
	self.unions:AddPart(id)
end

function HistoricalHitboxes.RemovePart(self: HistoricalHitboxes, part: BasePart)
	local info = self.parts[part]
	if not info then
		return
	end

	local id = info.id
	for index = 1, self.frameCap do
		self.hitboxes[index][id] = nil
	end
	for block = 1, self.unionsPerPart do
		self.trees[block]:remove(id)
	end
	self.unions:RemovePart(id)

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

function HistoricalHitboxes.UpdateFrame(self: HistoricalHitboxes, index: number)
	local unionSize = self.unionSize
	local block = blockOf(index, unionSize)
	local slot = (index - 1) % unionSize
	local tree = self.trees[block]

	-- steps info.register:Step() for every part, and maintains the union/envelope/tree state
	self.unions:UpdateFrame(index, block, slot, tree, self.partList)

	-- build/update the exact per-frame Hitbox record. Uses info.register:AtIndex(index), the
	-- same data UnionRegister just stepped -- Step() must run exactly once per part per frame,
	-- so this reads it rather than stepping again.
	local frameHitboxes = self.hitboxes[index]
	for _, info in self.partList do
		local data = info.register:AtIndex(index)
		local id = info.id
		local hitbox = frameHitboxes[id]

		if not data.cframe then
			if hitbox then
				frameHitboxes[id] = nil
			end
			continue
		end

		if not hitbox then
			frameHitboxes[id] = {
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
				aabbMin = data.aabbMin,
				aabbMax = data.aabbMax,
			}
		else
			if data.size ~= hitbox.size then
				hitbox.size = data.size
				hitbox.shape = bolt.create_box(data.size)
			end
			hitbox.cframe = data.cframe
			hitbox.canCollide = data.canCollide
			hitbox.aabbMin = data.aabbMin
			hitbox.aabbMax = data.aabbMax
		end
	end

	if slot == unionSize - 1 then
		self.unions:Seal(block, tree, self.partList)
	end
end

function HistoricalHitboxes.QueryRaycast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	local playerName = player.Name
	local invLength = fractionScale(rayDirection)
	local frameCap, unionSize = self.frameCap, self.unionSize
	local trees, hitboxes = self.trees, self.hitboxes
	-- 1/0 is +-inf in Luau floats, not an error, so an axis-aligned ray is handled the same
	-- way rayAABB's own inf clamps handle it
	local rayInvDir = 1 / rayDirection

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil
	local bestOffset = 0

	local recorded = acquireIdList()
	local recordedBlock: number? = nil
	local recordedCount = 0
	local recording = false
	--frameRange 0 walks exactly one frame, so there is never a second offset to replay to and
	--recording it would be pure overhead
	local canRecord = frameRange > 0

	-- narrow is built once per query and reaches the frame under test through these two upvalues.
	-- Closing over a per-offset local instead would rebuild the closure for every frame walked,
	-- which is pure overhead on the (common) query that walks several. Recording is folded into
	-- narrow rather than wrapped around it for the same reason at candidate granularity: a
	-- wrapper meant every candidate paid an extra call, which the raycast's cheap narrow phase
	-- can't absorb.
	local frameHitboxes: {[number]: Hitbox} = nil :: any
	local frameOffset = 0

	-- rejection cascade for one candidate. `limit` is the traversal's live best_fraction, so the
	-- pre-filter prunes against the best hit so far, not just the ray's own end.
	local function narrow(id: number, limit: number): number?
		if recording then
			recordedCount += 1
			recorded[recordedCount] = id
		end

		local hitbox = frameHitboxes[id]
		if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
			return nil
		end

		-- most tree candidates only clip the fat union envelope, not this exact frame's tight
		-- box. Reject those before paying for the oriented test below.
		if not rayAABB(rayOrigin, rayInvDir, hitbox.aabbMin, hitbox.aabbMax, limit) then
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
			bestOffset = frameOffset
		end

		return distance * invLength
	end

	local function queryFrame(offset: number)
		local index = wrapIndex(centerIndex + offset, frameCap)
		local block = blockOf(index, unionSize)
		frameHitboxes = hitboxes[index]
		frameOffset = offset
		--anything the cast reaches after the current best is pruned before its narrow phase runs
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		if block == recordedBlock then
			recording = false
			--the recorded walk ran with its bound pinned at 1 (it found nothing), so it visited
			--every candidate this block's geometry admits; re-walking can only reach a subset
			for i = 1, recordedCount do
				narrow(recorded[i], if bestDistance < math.huge then bestDistance * invLength else 1)
			end
			return
		end

		recordedCount = 0
		recording = canRecord
		trees[block]:query_ray_closest(rayOrigin, rayDirection, narrow, maxFraction)
		recording = false
		--only a walk that found nothing recorded a complete list; one that hit pruned by distance
		recordedBlock = if bestHitbox or not canRecord then nil else block
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

	releaseIdList(recorded)

	if not bestHitbox then
		return nil, nil, nil, nil
	end

	local resultHitbox = table.clone(bestHitbox :: Hitbox)
	resultHitbox.frameOffset = bestOffset

	return resultHitbox, bestPoint, bestDistance, bestNormal
end

function HistoricalHitboxes.QueryShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	if direction.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end

	local playerName = player.Name
	local invLength = fractionScale(direction)
	local frameCap, unionSize = self.frameCap, self.unionSize
	local trees, hitboxes = self.trees, self.hitboxes
	local castOrigin = cframe.Position
	local castExt = castExtents(cframe, shape)
	local invDir = 1 / direction

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil
	local bestOffset = 0

	local recorded = acquireIdList()
	local recordedBlock: number? = nil
	local recordedCount = 0
	local recording = false
	--frameRange 0 walks exactly one frame, so there is never a second offset to replay to and
	--recording it would be pure overhead
	local canRecord = frameRange > 0

	-- built once per query, recording folded in; see QueryRaycast
	local frameHitboxes: {[number]: Hitbox} = nil :: any
	local frameOffset = 0

	local function narrow(id: number, limit: number): number?
		if recording then
			recordedCount += 1
			recorded[recordedCount] = id
		end

		local hitbox = frameHitboxes[id]
		if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
			return nil
		end

		if castExt and not sweptAABB(castOrigin, castExt, invDir, hitbox.aabbMin, hitbox.aabbMax, limit) then
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
			bestOffset = frameOffset
		end

		return distance * invLength
	end

	local function queryFrame(offset: number)
		local index = wrapIndex(centerIndex + offset, frameCap)
		local block = blockOf(index, unionSize)
		frameHitboxes = hitboxes[index]
		frameOffset = offset
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		if block == recordedBlock then
			recording = false
			for i = 1, recordedCount do
				narrow(recorded[i], if bestDistance < math.huge then bestDistance * invLength else 1)
			end
			return
		end

		recordedCount = 0
		recording = canRecord
		trees[block]:query_shapecast_closest(shape, cframe, direction, narrow, maxFraction)
		recording = false
		recordedBlock = if bestHitbox or not canRecord then nil else block
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

	releaseIdList(recorded)

	if not bestHitbox then
		return nil, nil, nil, nil
	end

	local resultHitbox = table.clone(bestHitbox :: Hitbox)
	resultHitbox.frameOffset = bestOffset

	return resultHitbox, bestPoint, bestDistance, bestNormal
end

function HistoricalHitboxes.QuerySimpleShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, number?)
	if direction.Magnitude < 1e-6 then
		return nil, nil
	end

	local playerName = player.Name
	local invLength = fractionScale(direction)
	local frameCap, unionSize = self.frameCap, self.unionSize
	local trees, hitboxes = self.trees, self.hitboxes
	local castOrigin = cframe.Position
	local castExt = castExtents(cframe, shape)
	local invDir = 1 / direction

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestOffset = 0

	local recorded = acquireIdList()
	local recordedBlock: number? = nil
	local recordedCount = 0
	local recording = false
	--frameRange 0 walks exactly one frame, so there is never a second offset to replay to and
	--recording it would be pure overhead
	local canRecord = frameRange > 0

	-- built once per query, recording folded in; see QueryRaycast
	local frameHitboxes: {[number]: Hitbox} = nil :: any
	local frameOffset = 0

	local function narrow(id: number, limit: number): number?
		if recording then
			recordedCount += 1
			recorded[recordedCount] = id
		end

		local hitbox = frameHitboxes[id]
		if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
			return nil
		end

		if castExt and not sweptAABB(castOrigin, castExt, invDir, hitbox.aabbMin, hitbox.aabbMax, limit) then
			return nil
		end

		local hit, distance = gjk.shapecast_simple(cframe, direction, shape, hitbox.cframe, hitbox.shape, GJK_TOLERANCE)
		if not hit or distance == nil then
			return nil
		end

		if distance < bestDistance then
			bestDistance = distance
			bestHitbox = hitbox
			bestOffset = frameOffset
		end

		return distance * invLength
	end

	local function queryFrame(offset: number)
		local index = wrapIndex(centerIndex + offset, frameCap)
		local block = blockOf(index, unionSize)
		frameHitboxes = hitboxes[index]
		frameOffset = offset
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		if block == recordedBlock then
			recording = false
			for i = 1, recordedCount do
				narrow(recorded[i], if bestDistance < math.huge then bestDistance * invLength else 1)
			end
			return
		end

		recordedCount = 0
		recording = canRecord
		trees[block]:query_shapecast_closest(shape, cframe, direction, narrow, maxFraction)
		recording = false
		recordedBlock = if bestHitbox or not canRecord then nil else block
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

	releaseIdList(recorded)

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

function HistoricalHitboxes.QueryShape(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?): {[BasePart]: Hitbox}
	local playerName = player.Name
	local results: {[BasePart]: Hitbox} = {}
	local partCount = 0
	local maxParts = (params and params.MaxParts) or math.huge
	maxParts = if maxParts <= 0 then math.huge else maxParts

	local frameCap, unionSize = self.frameCap, self.unionSize
	local trees, hitboxes = self.trees, self.hitboxes

	local castExt = castExtents(cframe, shape)
	local castMin, castMax = Vector3.zero, Vector3.zero
	if castExt then
		local castOrigin = cframe.Position
		castMin, castMax = castOrigin - castExt, castOrigin + castExt
	end

	-- A block whose tree covers several requested offsets is walked exactly once, not once per
	-- offset. This is why MaxParts truncation order can differ from the old per-frame
	-- implementation: the *set* of candidates is the same, only the order results accumulate in
	-- has changed. The offsets are re-scanned per block rather than grouped into a table of
	-- lists up front, which keeps the whole query allocation-free -- frameRange is 1 by default,
	-- so these scans are three iterations.
	for offset = -frameRange, frameRange do
		local index = wrapIndex(centerIndex + offset, frameCap)
		local block = blockOf(index, unionSize)

		local alreadyWalked = false
		for earlier = -frameRange, offset - 1 do
			if blockOf(wrapIndex(centerIndex + earlier, frameCap), unionSize) == block then
				alreadyWalked = true
				break
			end
		end
		if alreadyWalked then
			continue
		end

		for _, id in trees[block]:query_shape(cframe, shape) do
			-- this candidate's leaf covers every frame in the block; keep whichever requested
			-- offset for this id is nearest to centerIndex among the ones that actually collide
			local best: Hitbox? = nil
			local bestOffset = 0

			for inner = -frameRange, frameRange do
				local innerIndex = wrapIndex(centerIndex + inner, frameCap)
				if blockOf(innerIndex, unionSize) ~= block then
					continue
				end
				if best and math.abs(inner) >= math.abs(bestOffset) then
					continue -- can't beat what we already have; skip the exact test entirely
				end

				local hitbox = hitboxes[innerIndex][id]
				if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
					continue
				end
				if castExt and not aabbOverlap(castMin, castMax, hitbox.aabbMin, hitbox.aabbMax) then
					continue
				end
				if not collides(hitbox, cframe, shape) then
					continue
				end

				best = hitbox
				bestOffset = inner
			end

			if not best then
				continue
			end

			local previous = results[best.instance]
			if not previous then
				if partCount >= maxParts then
					continue
				end
				partCount += 1
			end

			if not previous or math.abs(bestOffset) < math.abs(previous.frameOffset) then
				local resultHitbox = table.clone(best)
				resultHitbox.frameOffset = bestOffset
				results[best.instance] = resultHitbox
			end
		end
	end

	return results
end

function HistoricalHitboxes.GetHitboxesForOwner(self: HistoricalHitboxes, index: number, ownerName: string): {Hitbox}
	local frameHitboxes = self.hitboxes[wrapIndex(index, self.frameCap)]
	local results: {Hitbox} = {}
	for _, hitbox in frameHitboxes do
		if hitbox.owner == ownerName then
			table.insert(results, hitbox)
		end
	end
	return results
end

function HistoricalHitboxes.Destroy(self: HistoricalHitboxes)
	for block = 1, self.unionsPerPart do
		self.trees[block]:clear()
	end
	for index = 1, self.frameCap do
		table.clear(self.hitboxes[index])
	end
	table.clear(self.parts)
	table.clear(self.partList)
end

return HistoricalHitboxes
