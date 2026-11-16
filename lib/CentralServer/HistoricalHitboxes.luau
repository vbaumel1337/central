--!native
--!strict
--!optimize 2
-- Hitbox history behind every lag-compensated query, built on Bolt's temporal tree addon.
--
-- Broad phase: ONE tree for the whole history. Each part owns a single leaf whose bounds are the
-- union of everywhere it has been inside the window, maintained by the temporal tree (bucketed, so
-- old history retires without rebuilding the union). A candidate out of that tree only means "this
-- part was near the query at some point in the window".
--
-- Narrow phase: the exact per-frame record (CFrame, size, CanCollide, tight AABB) PartRegister
-- already keeps in its ring, read by frame index. A candidate is rejected against that frame's
-- tight AABB first, then resolved with the oriented exact test.
--
-- Timestamps handed to the temporal tree are frame numbers, not seconds: the window, the buckets
-- and the rewind depth are then all in the same unit as the ring index queries are addressed by.
local bolt = require(script.Parent.Parent.bolt)
local temporal = require(script.Parent.Parent.temporal_tree)
local Settings = require(script.Parent.Parent.Settings)
local PartRegister = require(script.Parent.Registers.PartRegister)
local CollisionCache = require(script.Parent.CollisionCache)

local gjk = bolt.dispatch.gjk
local collision = bolt.collision
local shapeAABB = bolt.shape_aabb
local shapeMap = require(script.Parent.Parent.bolt.shape_map)

local GJK_TOLERANCE = Settings.GJK_TOLERANCE
local PREFER_NEAREST_FRAME = Settings.PREFER_NEAREST_FRAME
local TREE_REBUILD_CHECK_FRAMES = Settings.TREE_REBUILD_CHECK_FRAMES
local DEFAULT_GROUP = Settings.DEFAULT_HITBOX_QUERY_GROUP

local NEG_INF_VEC = -vector.one * math.huge
local POS_INF_VEC = vector.one * math.huge

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
	aabbMin: Vector3,
	aabbMax: Vector3,
}

type PartData = PartRegister.PartData

type PartInfo = {
	id: number,
	part: BasePart,
	register: PartRegister.PartRegister,
	frames: {[number]: PartData},
	listIndex: number,
	owner: string,
	collisionGroup: string,

	-- the box the part currently has, shared by every frame record written while its size holds
	shape: bolt.BoxShape,
	size: Vector3,

	-- last pose handed to the temporal tree, and its tight AABB. nil until the first sample, and
	-- again after a long absence has dropped the part's history.
	lastCFrame: CFrame?,
	aabbMin: Vector3,
	aabbMax: Vector3,

	lastPresent: number, -- last frame the part was in the world
	lastSnapshot: number, -- last frame a sample was recorded for
	lastMoved: number, -- last frame its pose or size changed
}

local HistoricalHitboxes = {}
HistoricalHitboxes.__index = HistoricalHitboxes

export type HistoricalHitboxes = typeof(setmetatable(
	{} :: {
		frameCap: number,
		frame: number,
		tracker: temporal.TemporalTree,
		tree: bolt.DynamicTree,
		window: number,
		refitInterval: number,
		settleFrames: number,
		parts: {[BasePart]: PartInfo},
		partList: {PartInfo},
		infos: {[number]: PartInfo},
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

local function wrapIndex(index: number, frameCap: number): number
	return ((index - 1) % frameCap) + 1
end

--the closest-hit tree queries work in fractions of the cast, not studs, so narrow phase
--distances get scaled by this. a zero length sweep collapses every hit onto fraction 0.
local function fractionScale(direction: Vector3): number
	local length = direction.Magnitude
	return if length > 0 then 1 / length else 0
end

-- ============================ query pre-filter ============================
-- A leaf covers the part's whole window of motion, so a tree candidate is a weak signal. These
-- test the query against the candidate's tight AABB at the one frame being resolved, and reject it
-- before the oriented test (bolt.raycast.box / GJK) runs.
--
-- Same idiom as Bolt's own private swept_aabb in aabb_tree.luau, reimplemented since it isn't part
-- of Bolt's public API. Sweeping a shape along a segment against a box is the same as growing the
-- box by the shape's half extents and casting a ray from the shape's centre; a ray is the case
-- where those extents are zero. The vector.max/min against the infinity constants keeps a 0 * inf
-- NaN, on an axis the cast runs parallel to, from poisoning the comparison.
local function sweptAABB(castCenter: Vector3, castExtents: Vector3, invDir: Vector3, min: Vector3, max: Vector3, maxFraction: number): boolean
	local t1 = vector.max(NEG_INF_VEC, (min - castExtents - castCenter) * invDir)
	local t2 = vector.min(POS_INF_VEC, (max + castExtents - castCenter) * invDir)

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

-- ============================ candidate-list pool ============================
-- Every frame a cast query resolves shares the one tree, so only the first frame walks it. That
-- walk records the ids it visits and the remaining frames replay the list, reading a different
-- frame's record per candidate.
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

-- The part of the params filter that doesn't depend on which frame is being resolved.
-- RespectCanCollide does, so callers test that one against the frame record themselves.
local function isFilteredOut(info: PartInfo, params: (RaycastParams | OverlapParams)?): boolean
	if not params then
		return false
	end

	if not CollisionCache.IsCollidable(params.CollisionGroup or DEFAULT_GROUP, info.collisionGroup) then
		return true
	end

	local instance = info.part

	local exclude = params.ExcludeInstances :: {Instance}?
	if exclude then
		for _, excluded in ipairs(exclude) do
			if instance == excluded or instance:IsDescendantOf(excluded) then
				return true
			end
		end
	end

	local include = params.IncludeInstances :: {Instance}?
	if include and #include > 0 then
		for _, included in ipairs(include) do
			if instance == included or instance:IsDescendantOf(included) then
				return false
			end
		end
		return true
	end

	return false
end

local function makeHitbox(info: PartInfo, data: PartData, frameOffset: number): Hitbox
	return {
		id = info.id,
		cframe = data.cframe :: CFrame,
		shape = data.shape :: bolt.BoxShape,
		size = data.size,
		instance = info.part,
		owner = info.owner,
		collisionGroup = info.collisionGroup,
		canCollide = data.canCollide,
		frameOffset = frameOffset,
		active = true,
		aabbMin = data.aabbMin,
		aabbMax = data.aabbMax,
	}
end

-- frameCap: depth of the history ring, in frames. Queries are addressed by ring index.
-- padding:  slack around each leaf, so a part can move a little before its leaf is rewritten.
-- buckets:  how many slots the temporal tree cuts its window into (see its fold_buckets).
function HistoricalHitboxes.new(frameCap: number, padding: number, buckets: number): HistoricalHitboxes
	assert(buckets >= 2, "the temporal tree needs at least two buckets")

	local self = setmetatable({}, HistoricalHitboxes) :: HistoricalHitboxes
	self.frameCap = frameCap
	self.frame = 0
	self.parts = {}
	self.partList = {}
	self.infos = {}
	self.nextPartId = 0

	-- The temporal tree keeps `buckets` slots live, the newest of which has only just started
	-- filling, so the history it is guaranteed to bound is (buckets - 1) slots deep rather than
	-- the full window. The window is sized so that those (buckets - 1) slots are the whole ring.
	local bucketFrames = frameCap / (buckets - 1)
	local window = bucketFrames * buckets

	self.tracker = temporal.new({
		window = window,
		rate = 1,
		buckets = buckets,
		aabb_padding = padding,
	})
	self.tree = self.tracker.tree
	self.window = window

	-- at most one slot apart, so every slot sees a sample from a part that is still settling
	self.refitInterval = math.max(1, math.floor(bucketFrames))
	-- long enough for every slot holding motion to have expired by the last refit
	self.settleFrames = math.ceil(window) + self.refitInterval

	return self
end

function HistoricalHitboxes.AddPart(self: HistoricalHitboxes, register: PartRegister.PartRegister)
	local part = register.part
	if self.parts[part] then
		return
	end

	self.nextPartId += 1
	local id = self.nextPartId
	local size = part.Size
	local shape = bolt.create_box(size)

	local info: PartInfo = {
		id = id,
		part = part,
		register = register,
		frames = register.frameData,
		listIndex = #self.partList + 1,
		owner = register.owner,
		collisionGroup = part.CollisionGroup,
		shape = shape,
		size = size,
		lastCFrame = nil,
		aabbMin = Vector3.zero,
		aabbMax = Vector3.zero,
		lastPresent = 0,
		lastSnapshot = 0,
		lastMoved = 0,
	}

	self.parts[part] = info
	self.infos[id] = info
	table.insert(self.partList, info)
	self.tracker:track(id, shape)
end

function HistoricalHitboxes.RemovePart(self: HistoricalHitboxes, part: BasePart)
	local info = self.parts[part]
	if not info then
		return
	end

	self.tracker:untrack(info.id)

	local lastIndex = #self.partList
	local listIndex = info.listIndex
	if listIndex ~= lastIndex then
		local lastInfo = self.partList[lastIndex]
		self.partList[listIndex] = lastInfo
		lastInfo.listIndex = listIndex
	end
	self.partList[lastIndex] = nil

	self.infos[info.id] = nil
	self.parts[part] = nil
end

-- Records this frame for every part. `index` is the ring slot the frame lands in.
--
-- A part only reaches the temporal tree when something about it changed. One that sits still
-- keeps the leaf it already has: that leaf bounds the pose it is still in, so there is nothing to
-- add, and a resting hitbox costs a ring write and a CFrame comparison per frame.
--
-- The temporal tree never shrinks a leaf in place (set_bounds leaves it alone while the new bounds
-- still fit inside the old), so a part that stopped, or one still moving around inside the box a
-- teleport left behind, would keep an oversized leaf indefinitely. Hence the refit: on a staggered
-- tick, a part that changed within the last `settleFrames` has its leaf dropped just before the
-- sample, and the temporal tree inserts a fresh one at exactly the bounds it currently needs.
function HistoricalHitboxes.UpdateFrame(self: HistoricalHitboxes, index: number)
	local frame = self.frame + 1
	self.frame = frame

	local tracker = self.tracker
	local tree = self.tree
	local trackedMap = tracker.tracked
	local window = self.window
	local refitInterval = self.refitInterval
	local settleFrames = self.settleFrames

	for _, info in self.partList do
		info.register:Step()

		local data = info.frames[index]
		local cf = data.cframe
		local id = info.id

		if not cf then
			-- Out of the world. Its leaf stays put, still bounding the frames it was present for,
			-- until those have aged out of the ring; then its history goes.
			if info.lastCFrame and frame - info.lastPresent > window then
				tracker:reset(id)
				info.lastCFrame = nil
			end
			continue
		end

		local lastCFrame = info.lastCFrame
		local size = data.size
		local resized = size ~= info.size
		local changed = resized or cf ~= lastCFrame

		if changed then
			-- The pose history is only samples. If the part rested (or was away) since its last
			-- one, record where that stretch ended first, with the shape it had then, so the
			-- stretch isn't reconstructed as a slow glide into the new pose.
			if lastCFrame and info.lastPresent > info.lastSnapshot then
				tracker:snapshot(id, lastCFrame, info.lastPresent)
			end

			if resized then
				-- The temporal tree takes a shape once, at track(). Swapping it on the tracked
				-- record is the supported-by-inspection way to resize: both fields are read fresh
				-- on every snapshot, and bounds already folded into a slot keep the old size.
				local shape = bolt.create_box(size)
				info.shape = shape
				info.size = size

				local tracked = trackedMap[id]
				tracked.shape = shape
				tracked.radius = bolt.circumradius(shape)
			end

			info.aabbMin, info.aabbMax = shapeAABB(cf, info.shape)
			info.lastCFrame = cf
			info.lastMoved = frame
		end

		info.lastPresent = frame

		local refit = (frame + id) % refitInterval == 0 and frame - info.lastMoved <= settleFrames

		if changed or refit then
			if refit then
				local tracked = trackedMap[id]
				if tracked.registered then
					tree:remove(id)
					tracked.registered = false
				end
			end

			tracker:snapshot(id, cf, frame)
			info.lastSnapshot = frame
		end

		data.shape = info.shape
		data.aabbMin = info.aabbMin
		data.aabbMax = info.aabbMax
	end

	if frame % TREE_REBUILD_CHECK_FRAMES == 0 and tree:should_rebuild() then
		tree:partial_rebuild()
	end
end

-- Shared by the three cast queries. `shape == nil` is a raycast from castOrigin.Position;
-- otherwise the shape is swept from castOrigin, with `simple` picking the cheaper GJK variant
-- that reports no point or normal.
local function queryCast(
	self: HistoricalHitboxes,
	player: Player,
	centerIndex: number,
	frameRange: number,
	castOrigin: CFrame,
	shape: bolt.Shape?,
	simple: boolean,
	direction: Vector3,
	params: RaycastParams?,
	check: ((BasePart) -> boolean)?
): (Hitbox?, Vector3?, number?, Vector3?)
	local playerName = player.Name
	local invLength = fractionScale(direction)
	local frameCap = self.frameCap
	local tree = self.tree
	local infos = self.infos
	local respectCanCollide = params ~= nil and params.RespectCanCollide

	-- 1/0 is +-inf in Luau floats, not an error, so an axis-aligned cast is handled the same way
	-- sweptAABB's own inf clamps handle it
	local invDir = 1 / direction
	local rayOrigin = castOrigin.Position
	local castCenter = rayOrigin
	local castExtents = Vector3.zero
	if shape then
		-- the shape's bounds need not be centred on its origin, so both come from its AABB
		local castMin, castMax = shapeAABB(castOrigin, shape)
		castCenter = (castMin + castMax) * 0.5
		castExtents = (castMax - castMin) * 0.5
	end

	local bestDistance = math.huge
	local bestInfo: PartInfo? = nil
	local bestData: PartData? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil
	local bestOffset = 0

	local recorded = acquireIdList()
	local recordedCount = 0
	local recording = false
	local replayable = false
	--frameRange 0 resolves exactly one frame, so there is never a second one to replay to and
	--recording it would be pure overhead
	local canRecord = frameRange > 0

	-- narrow is built once per query and reaches the frame under test through these two upvalues,
	-- rather than being rebuilt for every frame walked. Recording is folded into it instead of
	-- wrapped around it so a candidate never pays for an extra call.
	local frameIndex = 0
	local frameOffset = 0

	-- rejection cascade for one candidate. `limit` is the traversal's live best fraction, so the
	-- pre-filter prunes against the best hit so far, not just the cast's own end.
	local function narrow(id: number, limit: number): number?
		if recording then
			recordedCount += 1
			recorded[recordedCount] = id
		end

		local info = infos[id]
		local data = info.frames[frameIndex]
		local cf = data.cframe
		if not cf or info.owner == playerName or (respectCanCollide and not data.canCollide) then
			return nil
		end

		if not sweptAABB(castCenter, castExtents, invDir, data.aabbMin, data.aabbMax, limit) then
			return nil
		end

		if isFilteredOut(info, params) or (check and not check(info.part)) then
			return nil
		end

		local hitPoint: Vector3?, distance: number?, hitNormal: Vector3? = nil, nil, nil
		local box = data.shape :: bolt.BoxShape

		if shape == nil then
			hitPoint, distance, hitNormal = bolt.raycast.box(rayOrigin, direction, cf, box)
		elseif simple then
			local hit, hitDistance = gjk.shapecast_simple(castOrigin, direction, shape, cf, box, GJK_TOLERANCE)
			if hit then
				distance = hitDistance
			end
		else
			hitPoint, distance, hitNormal = gjk.shapecast(castOrigin, direction, shape, cf, box, GJK_TOLERANCE)
		end

		if distance == nil then
			return nil
		end

		if distance < bestDistance then
			bestDistance = distance
			bestInfo = info
			bestData = data
			bestPoint = hitPoint
			bestNormal = hitNormal
			bestOffset = frameOffset
		end

		return distance * invLength
	end

	local function queryFrame(offset: number)
		frameIndex = wrapIndex(centerIndex + offset, frameCap)
		frameOffset = offset

		if replayable then
			--the recorded walk found nothing, so its bound never tightened and it visited every
			--candidate the tree admits; re-walking could only reach a subset
			for i = 1, recordedCount do
				narrow(recorded[i], if bestDistance < math.huge then bestDistance * invLength else 1)
			end
			return
		end

		--anything the cast reaches after the current best is pruned before its narrow phase runs
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		recordedCount = 0
		recording = canRecord
		if shape == nil then
			tree:query_ray_closest(rayOrigin, direction, narrow, maxFraction)
		else
			tree:query_shapecast_closest(shape, castOrigin, direction, narrow, maxFraction)
		end
		recording = false

		--only a walk that found nothing recorded a complete list; one that hit pruned by distance
		replayable = canRecord and bestInfo == nil
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
		if PREFER_NEAREST_FRAME and bestInfo then
			break
		end
	end

	releaseIdList(recorded)

	if not bestInfo then
		return nil, nil, nil, nil
	end

	return makeHitbox(bestInfo, bestData :: PartData, bestOffset), bestPoint, bestDistance, bestNormal
end

function HistoricalHitboxes.QueryRaycast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	return queryCast(self, player, centerIndex, frameRange, CFrame.new(rayOrigin), nil, false, rayDirection, params, check)
end

function HistoricalHitboxes.QueryShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	if direction.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end

	return queryCast(self, player, centerIndex, frameRange, cframe, shape, false, direction, params, check)
end

function HistoricalHitboxes.QuerySimpleShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, number?)
	if direction.Magnitude < 1e-6 then
		return nil, nil
	end

	local hitbox, _, distance = queryCast(self, player, centerIndex, frameRange, cframe, shape, true, direction, params, check)
	return hitbox, distance
end

local function collides(hitboxCFrame: CFrame, hitboxShape: bolt.BoxShape, cframe: CFrame, shape: bolt.Shape): boolean
	if shape.type == shapeMap.BOX then
		return collision.box_box(hitboxCFrame, hitboxShape, cframe, shape :: bolt.BoxShape)
	elseif shape.type == shapeMap.SPHERE then
		return collision.box_sphere(hitboxCFrame, hitboxShape, cframe, shape :: bolt.SphereShape)
	elseif shape.type == shapeMap.CAPSULE then
		return collision.box_capsule(hitboxCFrame, hitboxShape, cframe, shape :: bolt.CapsuleShape)
	end

	return gjk.intersects(hitboxCFrame, hitboxShape, cframe, shape, GJK_TOLERANCE)
end

function HistoricalHitboxes.QueryShape(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?): {[BasePart]: Hitbox}
	local playerName = player.Name
	local results: {[BasePart]: Hitbox} = {}
	local partCount = 0
	local maxParts = (params and params.MaxParts) or math.huge
	maxParts = if maxParts <= 0 then math.huge else maxParts

	local frameCap = self.frameCap
	local infos = self.infos
	local respectCanCollide = params ~= nil and params.RespectCanCollide
	local castMin, castMax = shapeAABB(cframe, shape)

	-- One walk covers every requested frame. Each candidate then keeps the frame nearest to
	-- centerIndex it actually overlaps in, the earlier of the two on a tie.
	for _, id in self.tree:query_shape(cframe, shape) do
		if partCount >= maxParts then
			break
		end

		local info = infos[id]
		if info.owner == playerName or isFilteredOut(info, params) or (check and not check(info.part)) then
			continue
		end

		local frames = info.frames

		for step = 0, frameRange * 2 do
			-- 0, -1, +1, -2, +2, ...
			local offset = if step % 2 == 1 then -(step + 1) // 2 else step // 2
			local data = frames[wrapIndex(centerIndex + offset, frameCap)]
			local cf = data.cframe

			if not cf or (respectCanCollide and not data.canCollide) then
				continue
			end
			if not aabbOverlap(castMin, castMax, data.aabbMin, data.aabbMax) then
				continue
			end
			if not collides(cf, data.shape :: bolt.BoxShape, cframe, shape) then
				continue
			end

			partCount += 1
			results[info.part] = makeHitbox(info, data, offset)
			break
		end
	end

	return results
end

function HistoricalHitboxes.GetHitboxesForOwner(self: HistoricalHitboxes, index: number, ownerName: string): {Hitbox}
	local frameIndex = wrapIndex(index, self.frameCap)
	local results: {Hitbox} = {}
	for _, info in self.partList do
		if info.owner == ownerName then
			local data = info.frames[frameIndex]
			if data.cframe then
				table.insert(results, makeHitbox(info, data, 0))
			end
		end
	end
	return results
end

function HistoricalHitboxes.Destroy(self: HistoricalHitboxes)
	self.tracker:clear()
	table.clear(self.parts)
	table.clear(self.partList)
	table.clear(self.infos)
end

return HistoricalHitboxes
