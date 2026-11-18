--!native
--!strict
--!optimize 2
-- Hitbox history behind every lag-compensated query, built on Bolt's temporal tree addon.
--
-- Broad phase: ONE tree for the whole history. Each GROUP owns a single leaf whose bounds are the
-- union of everywhere it has been inside the window, maintained by the temporal tree (bucketed, so
-- old history retires without rebuilding the union). A candidate out of that tree only means "this
-- group was near the query at some point in the window".
--
-- A group is either a part that was tagged on its own, or every part of a tagged Model (the
-- register's `group` key). The first is a group of one and keeps the leaf it always had: the part's
-- own pose and shape go to the temporal tree. A Model's group has one leaf for all its members: each
-- frame the members' tight AABBs are unioned into one box, and that box is what the temporal tree
-- is sampled with, so a whole character costs one leaf and one sample instead of one per part.
--
-- Narrow phase: the exact per-frame record (CFrame, size, CanCollide, tight AABB) PartRegister
-- already keeps in its ring, read by frame index. A Model's group first checks the query against
-- that frame's group box, then each member goes through the same cascade a lone part does: tight
-- AABB first, then the oriented exact test.
--
-- The querying player's own hitboxes are tested here too, at the newest recorded frame instead of
-- the rewound one (a player's own hitboxes are not lag compensated). Their leaves already span the
-- present, so they need no tree of their own and no engine query.
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

-- A group's box is sampled as centre +- half extents, and Vector3 is 32-bit, so the rebuilt edges can
-- land a hair inside the true box. AABB_PADDING normally hides that, but it may be 0.
local BOX_EPSILON = Vector3.one * 1e-3

-- every step of a group's frame walk is allowed, see QueryShape
local ALL_STEPS = -1
local MAX_MASKED_STEPS = 32

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

-- The members of one tagged Model. A part tagged on its own is not in one: it is its own leaf, and
-- is told apart from a Model's by its tree id being positive where a group's is negative.
type Group = {
	id: number, -- the temporal tree's id for this group's leaf; negative, -id is the groups index
	key: Instance, -- the tagged Model
	owner: string, -- shared by every member
	members: {PartInfo},

	listIndex: number, -- position in groupList
	boxShape: bolt.BoxShape, -- resized in place every time the group box is sampled

	-- the union of the present members' tight AABBs this frame
	curMin: Vector3,
	curMax: Vector3,
	present: boolean, -- whether any member is in the world this frame
	-- the same per frame, indexed like the register rings. Written every frame the ring slot is reused.
	frameMin: {Vector3},
	frameMax: {Vector3},
	framePresent: {boolean},
	dirty: boolean, -- a member moved, resized, appeared, vanished, joined or left since the last sample

	-- last box handed to the temporal tree. nil until the first sample, and again after a long
	-- absence has dropped the group's history.
	lastMin: Vector3?,
	lastMax: Vector3?,
	lastPresent: number, -- last frame any member was in the world
	lastSnapshot: number, -- last frame a sample was recorded for
	lastMoved: number, -- last frame the box changed
}

type PartInfo = {
	id: number, -- Hitbox.id; for a part tagged on its own, also its tree id
	part: BasePart,
	register: PartRegister.PartRegister,
	frames: {[number]: PartData},
	listIndex: number,
	owner: string,
	collisionGroup: string,
	group: Group?, -- the tagged Model's group, nil for a part tagged on its own
	memberIndex: number, -- position in group.members
	keyed: boolean, -- a member of a tagged Model, as opposed to a part tagged on its own

	-- the box the part currently has, shared by every frame record written while its size holds
	shape: bolt.BoxShape,
	size: Vector3,

	-- last pose recorded for the part, and its tight AABB. For a part tagged on its own, nil until
	-- the first sample, and again after a long absence has dropped its history.
	lastCFrame: CFrame?,
	aabbMin: Vector3,
	aabbMax: Vector3,

	present: boolean, -- in the world on the last frame it was stepped (Model members only)
	lastPresent: number, -- last frame the part was in the world (parts tagged on their own only)
	lastSnapshot: number, -- last frame a sample was recorded for (parts tagged on their own only)
	lastMoved: number, -- last frame its pose or size changed (parts tagged on their own only)
}

local HistoricalHitboxes = {}
HistoricalHitboxes.__index = HistoricalHitboxes

export type HistoricalHitboxes = typeof(setmetatable(
	{} :: {
		frameCap: number,
		frame: number,
		liveIndex: number,
		tracker: temporal.TemporalTree,
		tree: bolt.DynamicTree,
		window: number,
		refitInterval: number,
		settleFrames: number,
		parts: {[BasePart]: PartInfo},
		partList: {PartInfo},
		infos: {[number]: PartInfo}, -- parts tagged on their own, by tree id
		groups: {[number]: Group}, -- tagged Models, by the negative of their tree id
		groupsByKey: {[Instance]: Group},
		groupList: {Group},
		nextId: number,
		nextGroupId: number,
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
	-- Vector3 and `vector` are the same value at runtime but unrelated types to the checker; the
	-- casts go through unknown so the vector.max/min calls keep their fastcall.
	local t1 = vector.max(NEG_INF_VEC, (((min - castExtents - castCenter) * invDir) :: unknown) :: vector)
	local t2 = vector.min(POS_INF_VEC, (((max + castExtents - castCenter) * invDir) :: unknown) :: vector)

	local tMin = vector.min(t1, t2)
	local tMax = vector.max(t1, t2)

	local tmin = math.max(0, tMin.x, tMin.y, tMin.z)
	local tmax = math.min(maxFraction, tMax.x, tMax.y, tMax.z)

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
	self.liveIndex = 1
	self.parts = {}
	self.partList = {}
	self.infos = {}
	self.groups = {}
	self.groupsByKey = {}
	self.groupList = {}
	self.nextId = 0
	self.nextGroupId = 0

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

-- The tight AABB of a part's box at `cf`. Bolt types its vectors `vector`, which the type checker
-- does not treat as Vector3 although they are the same value.
local function tightBox(cf: CFrame, shape: bolt.Shape): (Vector3, Vector3)
	local min, max = shapeAABB(cf, shape)
	return (min :: unknown) :: Vector3, (max :: unknown) :: Vector3
end

function HistoricalHitboxes.AddPart(self: HistoricalHitboxes, register: PartRegister.PartRegister)
	local part = register.part
	if self.parts[part] then
		return
	end

	self.nextId += 1
	local id = self.nextId
	local size = part.Size
	local shape = bolt.create_box(size)
	local key = register.group

	local group: Group? = nil
	if key then
		group = self.groupsByKey[key]
		if not group then
			-- A Model's group is a box of its own, resized each time it is sampled
			self.nextGroupId += 1
			local groupId = -self.nextGroupId
			local boxShape = bolt.create_box(Vector3.one)
			local frameCap = self.frameCap

			local newGroup: Group = {
				id = groupId,
				key = key,
				owner = register.owner,
				members = {},
				listIndex = #self.groupList + 1,
				boxShape = boxShape,
				curMin = Vector3.zero,
				curMax = Vector3.zero,
				present = false,
				frameMin = table.create(frameCap, Vector3.zero),
				frameMax = table.create(frameCap, Vector3.zero),
				framePresent = table.create(frameCap, false),
				dirty = true,
				lastMin = nil,
				lastMax = nil,
				lastPresent = 0,
				lastSnapshot = 0,
				lastMoved = 0,
			}

			table.insert(self.groupList, newGroup)
			self.groupsByKey[key] = newGroup
			self.groups[-groupId] = newGroup
			self.tracker:track(groupId, boxShape)
			group = newGroup
		end
	end

	local info: PartInfo = {
		id = id,
		part = part,
		register = register,
		frames = register.frameData,
		listIndex = #self.partList + 1,
		owner = register.owner,
		collisionGroup = part.CollisionGroup,
		group = group,
		memberIndex = if group then #group.members + 1 else 0,
		keyed = group ~= nil,
		shape = shape,
		size = size,
		lastCFrame = nil,
		aabbMin = Vector3.zero,
		aabbMax = Vector3.zero,
		present = false,
		lastPresent = 0,
		lastSnapshot = 0,
		lastMoved = 0,
	}

	if group then
		table.insert(group.members, info)
		group.dirty = true
	else
		-- tagged on its own: the part's own pose and shape go to the temporal tree
		self.infos[id] = info
		self.tracker:track(id, shape)
	end

	self.parts[part] = info
	table.insert(self.partList, info)
end

function HistoricalHitboxes.RemovePart(self: HistoricalHitboxes, part: BasePart)
	local info = self.parts[part]
	if not info then
		return
	end

	local lastIndex = #self.partList
	local listIndex = info.listIndex
	if listIndex ~= lastIndex then
		local lastInfo = self.partList[lastIndex]
		self.partList[listIndex] = lastInfo
		lastInfo.listIndex = listIndex
	end
	self.partList[lastIndex] = nil
	self.parts[part] = nil

	local group = info.group
	if not group then
		self.tracker:untrack(info.id)
		self.infos[info.id] = nil
		return
	end

	local members = group.members
	local lastMember = #members
	local memberIndex = info.memberIndex
	if memberIndex ~= lastMember then
		local moved = members[lastMember]
		members[memberIndex] = moved
		moved.memberIndex = memberIndex
	end
	members[lastMember] = nil

	if lastMember > 1 then
		group.dirty = true
		return
	end

	-- the last member is gone, and with it the group
	self.tracker:untrack(group.id)
	self.groups[-group.id] = nil
	self.groupsByKey[group.key] = nil

	local lastGroup = #self.groupList
	local groupIndex = group.listIndex
	if groupIndex ~= lastGroup then
		local movedGroup = self.groupList[lastGroup]
		self.groupList[groupIndex] = movedGroup
		movedGroup.listIndex = groupIndex
	end
	self.groupList[lastGroup] = nil
end

-- Samples the temporal tree with a group's box. The temporal tree wants a pose and a shape, so the
-- box goes in as an unrotated box at its own centre: with no rotation between samples the temporal
-- tree's rotation padding is exactly zero and the leaf is the plain union of the boxes sampled.
local function sampleGroupBox(tracker: temporal.TemporalTree, id: number, boxShape: bolt.BoxShape, min: Vector3, max: Vector3, timestamp: number)
	boxShape.half_extents = (max - min) * 0.5 + BOX_EPSILON
	tracker:snapshot(id, CFrame.new((min + max) * 0.5), timestamp)
end

-- Records this frame for every part and group. `index` is the ring slot the frame lands in.
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
--
-- That is the whole story for a part tagged on its own. A Model's members are not sampled one by
-- one: the first loop only records each member's frame and tight AABB and notes that its group
-- changed, and the second loop does what the first does for a lone part, but for the group's box.
function HistoricalHitboxes.UpdateFrame(self: HistoricalHitboxes, index: number)
	local frame = self.frame + 1
	self.frame = frame
	self.liveIndex = index

	local tracker = self.tracker
	local tree = self.tree
	local trackedMap = tracker.tracked
	local window = self.window
	local refitInterval = self.refitInterval
	local settleFrames = self.settleFrames

	for _, info in self.partList do
		info.register:Step()

		local data = info.frames[index]
		local cf: CFrame | false = data.cframe

		if info.keyed then
			local group = info.group :: Group

			if cf == false then
				if info.present then
					info.present = false
					group.dirty = true
				end
				continue
			end

			local size = data.size
			local resized = size ~= info.size
			if resized then
				info.shape = bolt.create_box(size)
				info.size = size
			end

			if resized or not info.present or cf ~= info.lastCFrame then
				info.lastCFrame = cf
				info.present = true
				info.aabbMin, info.aabbMax = tightBox(cf, info.shape)
				group.dirty = true
			end

			data.shape = info.shape
			data.aabbMin = info.aabbMin
			data.aabbMax = info.aabbMax
			continue
		end

		local id = info.id

		if cf == false then
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

			info.lastCFrame = cf
			info.lastMoved = frame
		end

		info.lastPresent = frame

		local refit = (frame + id) % refitInterval == 0 and frame - info.lastMoved <= settleFrames

		if changed or refit then
			local tracked = trackedMap[id]

			if refit and tracked.registered then
				tree:remove(id)
				tracked.registered = false
			end

			tracker:snapshot(id, cf, frame)
			info.lastSnapshot = frame

			if changed then
				-- snapshot just computed this pose's tight AABB and kept it as last_min/last_max,
				-- so it is read back here rather than computed a second time
				info.aabbMin = tracked.last_min :: Vector3
				info.aabbMax = tracked.last_max :: Vector3
			end
		end

		data.shape = info.shape
		data.aabbMin = info.aabbMin
		data.aabbMax = info.aabbMax
	end

	for _, group in self.groupList do
		local id = group.id
		local wasDirty = group.dirty

		if wasDirty then
			-- the union of the members' tight boxes this frame
			local min: vector = POS_INF_VEC
			local max: vector = NEG_INF_VEC
			local anyPresent = false

			for _, member in group.members do
				if member.present then
					anyPresent = true
					min = vector.min(min, (member.aabbMin :: unknown) :: vector)
					max = vector.max(max, (member.aabbMax :: unknown) :: vector)
				end
			end

			group.present = anyPresent
			if anyPresent then
				group.curMin = (min :: unknown) :: Vector3
				group.curMax = (max :: unknown) :: Vector3
			end
			group.dirty = false
		end

		local present = group.present
		group.framePresent[index] = present
		group.frameMin[index] = group.curMin
		group.frameMax[index] = group.curMax

		if not present then
			-- Out of the world. Its leaf stays put, still bounding the frames it was present for,
			-- until those have aged out of the ring; then its history goes.
			if group.lastMin and frame - group.lastPresent > window then
				tracker:reset(id)
				group.lastMin = nil
				group.lastMax = nil
			end
			continue
		end

		local curMin, curMax = group.curMin, group.curMax
		local lastMin, lastMax = group.lastMin, group.lastMax
		local changed = lastMin == nil or lastMax == nil or (wasDirty and (curMin ~= lastMin or curMax ~= lastMax))

		if changed then
			-- same as for a lone part: if the group rested (or was away) since its last sample,
			-- record where that stretch ended first
			if lastMin and lastMax and group.lastPresent > group.lastSnapshot then
				sampleGroupBox(tracker, id, group.boxShape, lastMin, lastMax, group.lastPresent)
			end

			group.lastMin = curMin
			group.lastMax = curMax
			group.lastMoved = frame
		end

		group.lastPresent = frame

		local refit = (frame + id) % refitInterval == 0 and frame - group.lastMoved <= settleFrames

		if changed or refit then
			if refit then
				local tracked = trackedMap[id]
				if tracked.registered then
					tree:remove(id)
					tracked.registered = false
				end
			end

			sampleGroupBox(tracker, id, group.boxShape, curMin, curMax, frame)
			group.lastSnapshot = frame
		end
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
	local groups = self.groups
	local liveIndex = self.liveIndex
	local respectCanCollide = params ~= nil and params.RespectCanCollide

	-- 1/0 is +-inf in Luau floats, not an error, so an axis-aligned cast is handled the same way
	-- sweptAABB's own inf clamps handle it
	local invDir = 1 / direction
	local rayOrigin = castOrigin.Position
	local castCenter = rayOrigin
	local castExtents = Vector3.zero
	if shape then
		-- the shape's bounds need not be centred on its origin, so both come from its AABB
		local castMin, castMax = tightBox(castOrigin, shape)
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

	-- the exact test of one part against the cast, once it has got past the cheaper rejections.
	-- `limit` is the traversal's live best fraction.
	local function resolvePart(info: PartInfo, data: PartData, cf: CFrame): number?
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

	-- what the tree hands back is a part tagged on its own (a positive id), or the group of a
	-- tagged Model (a negative one)
	local function narrow(id: number, limit: number): number?
		if recording then
			recordedCount += 1
			recorded[recordedCount] = id
		end

		if id > 0 then
			local info = infos[id]
			local data: PartData
			if info.owner == playerName then
				-- The player's own hitbox: where it is now, not where it was. It is tested once, on
				-- the walk that resolves the player's own frame, rather than again for every frame
				-- replayed.
				if frameOffset ~= 0 then
					return nil
				end
				data = info.frames[liveIndex]
			else
				data = info.frames[frameIndex]
			end

			local cf: CFrame | false = data.cframe
			if cf == false or (respectCanCollide and not data.canCollide) then
				return nil
			end

			if not sweptAABB(castCenter, castExtents, invDir, data.aabbMin, data.aabbMax, limit) then
				return nil
			end

			if isFilteredOut(info, params) or (check and not check(info.part)) then
				return nil
			end

			return resolvePart(info, data, cf)
		end

		-- a Model: its box at this frame first, then each member
		local group = groups[-id]
		local index = frameIndex
		if group.owner == playerName then
			if frameOffset ~= 0 then
				return nil
			end
			index = liveIndex
		end

		if not group.framePresent[index] then
			return nil
		end
		if not sweptAABB(castCenter, castExtents, invDir, group.frameMin[index], group.frameMax[index], limit) then
			return nil
		end

		-- each member goes through the same rejections a part on its own does. `limit` tightens as
		-- members hit: anything the cast reaches after a hit can no longer be the closest one.
		local best: number? = nil
		for _, member in group.members do
			local data = member.frames[index]
			local cf: CFrame | false = data.cframe
			if cf == false or (respectCanCollide and not data.canCollide) then
				continue
			end

			if not sweptAABB(castCenter, castExtents, invDir, data.aabbMin, data.aabbMax, limit) then
				continue
			end

			if isFilteredOut(member, params) or (check and not check(member.part)) then
				continue
			end

			local fraction = resolvePart(member, data, cf)
			if fraction and (best == nil or fraction < best) then
				best = fraction
				if fraction < limit then
					limit = fraction
				end
			end
		end

		return best
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

-- The ring offset for step 0, 1, 2, ... of the walk 0, -1, +1, -2, +2, ...
local function stepOffset(step: number): number
	return if step % 2 == 1 then -(step + 1) // 2 else step // 2
end

-- The frame a part overlaps the query shape in that is nearest centerIndex, the earlier of the two
-- on a tie, and its offset from it. `steps` restricts the walk to the steps a bit is set for, which
-- is how a group tells its members which frames its own box already ruled out.
local function overlapFrame(
	info: PartInfo,
	owned: boolean,
	lastStep: number,
	steps: number,
	centerIndex: number,
	frameCap: number,
	liveIndex: number,
	respectCanCollide: boolean,
	castMin: Vector3,
	castMax: Vector3,
	cframe: CFrame,
	shape: bolt.Shape
): (PartData?, number)
	local frames = info.frames

	for step = 0, lastStep do
		if steps ~= ALL_STEPS and not bit32.btest(steps, bit32.lshift(1, step)) then
			continue
		end

		local offset = stepOffset(step)
		local data = if owned then frames[liveIndex] else frames[wrapIndex(centerIndex + offset, frameCap)]
		local cf: CFrame | false = data.cframe

		if cf == false or (respectCanCollide and not data.canCollide) then
			continue
		end
		if not aabbOverlap(castMin, castMax, data.aabbMin, data.aabbMax) then
			continue
		end
		if not collides(cf, data.shape :: bolt.BoxShape, cframe, shape) then
			continue
		end

		return data, offset
	end

	return nil, 0
end

function HistoricalHitboxes.QueryShape(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?): {[BasePart]: Hitbox}
	local playerName = player.Name
	local results: {[BasePart]: Hitbox} = {}
	local partCount = 0
	local maxParts = (params and params.MaxParts) or math.huge
	maxParts = if maxParts <= 0 then math.huge else maxParts

	local frameCap = self.frameCap
	local infos = self.infos
	local groups = self.groups
	local liveIndex = self.liveIndex
	local respectCanCollide = params ~= nil and params.RespectCanCollide
	local castMin, castMax = tightBox(cframe, shape)

	-- One walk covers every requested frame. Each candidate then keeps the frame nearest to
	-- centerIndex it actually overlaps in, the earlier of the two on a tie.
	for _, id in self.tree:query_shape(cframe, shape) do
		if partCount >= maxParts then
			break
		end

		if id > 0 then
			local info = infos[id]
			-- the player's own hitbox is tested at the newest frame only, see the header comment
			local owned = info.owner == playerName

			if isFilteredOut(info, params) or (check and not check(info.part)) then
				continue
			end

			local data, offset = overlapFrame(info, owned, if owned then 0 else frameRange * 2, ALL_STEPS, centerIndex, frameCap, liveIndex, respectCanCollide, castMin, castMax, cframe, shape)
			if data then
				partCount += 1
				results[info.part] = makeHitbox(info, data, offset)
			end
			continue
		end

		local group = groups[-id]
		local owned = group.owner == playerName
		local lastStep = if owned then 0 else frameRange * 2

		-- A Model: work out once which of the frames the query can reach have its box overlapping
		-- the query, so a frame the group as a whole misses costs none of its members anything, and
		-- a group missed in every frame is dropped before a single member is filtered.
		local steps = ALL_STEPS
		if lastStep < MAX_MASKED_STEPS then
			steps = 0
			for step = 0, lastStep do
				local index = if owned then liveIndex else wrapIndex(centerIndex + stepOffset(step), frameCap)
				if group.framePresent[index] and aabbOverlap(castMin, castMax, group.frameMin[index], group.frameMax[index]) then
					steps = bit32.bor(steps, bit32.lshift(1, step))
				end
			end
			if steps == 0 then
				continue
			end
		end

		for _, member in group.members do
			if partCount >= maxParts then
				break
			end
			if isFilteredOut(member, params) or (check and not check(member.part)) then
				continue
			end

			local data, offset = overlapFrame(member, owned, lastStep, steps, centerIndex, frameCap, liveIndex, respectCanCollide, castMin, castMax, cframe, shape)
			if data then
				partCount += 1
				results[member.part] = makeHitbox(member, data, offset)
			end
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
	table.clear(self.groups)
	table.clear(self.groupsByKey)
	table.clear(self.groupList)
end

return HistoricalHitboxes
