--!native
--!strict
--!optimize 2
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
local TREE_REBUILD_CHECK_JITTER = Settings.TREE_REBUILD_CHECK_INTERVAL * Settings.TREE_REBUILD_CHECK_JITTER

--own generator, so staggering the trees never disturbs the global math.random sequence
local rng = Random.new()

--the closest-hit tree queries work in fractions of the cast, not studs, so narrow phase
--distances get scaled by this. a zero length sweep collapses every hit onto fraction 0.
local function fractionScale(direction: Vector3): number
	local length = direction.Magnitude
	return if length > 0 then 1 / length else 0
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

local HistoricalHitboxes = {}
HistoricalHitboxes.__index = HistoricalHitboxes

export type HistoricalHitboxes = typeof(setmetatable(
	{} :: {
		frameCap: number,
		padding: number,
		trees: {[number]: bolt.DynamicTree},
		nextRebuildCheck: {[number]: number},
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
	HistoricalHitboxes
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

function HistoricalHitboxes.new(frameCap: number, padding: number): HistoricalHitboxes
	local self = setmetatable({}, HistoricalHitboxes) :: HistoricalHitboxes
	self.frameCap = frameCap
	self.padding = padding
	self.trees = {}
	self.nextRebuildCheck = {}
	self.hitboxes = {}
	self.parts = {}
	self.partList = {}
	self.nextPartId = 0

	local now = os.clock()
	for index = 1, frameCap do
		self.trees[index] = bolt.aabb_tree.new({aabb_padding = padding})
		self.hitboxes[index] = {}
		--first check is spread evenly across the interval so the trees don't all come due together
		self.nextRebuildCheck[index] = now + TREE_REBUILD_CHECK_INTERVAL * (index - 1) / frameCap
	end

	return self
end

function HistoricalHitboxes.AddPart(self: HistoricalHitboxes, register: PartRegister.PartRegister)
	local part = register.part
	if self.parts[part] then
		return
	end

	self.nextPartId += 1
	local info: PartInfo = {id = self.nextPartId, part = part, register = register, listIndex = #self.partList + 1}
	self.parts[part] = info
	table.insert(self.partList, info)
end

function HistoricalHitboxes.RemovePart(self: HistoricalHitboxes, part: BasePart)
	local info = self.parts[part]
	if not info then
		return
	end

	for index = 1, self.frameCap do
		local hitbox = self.hitboxes[index][info.id]
		if hitbox then
			self.trees[index]:remove(info.id)
			self.hitboxes[index][info.id] = nil
		end
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
end

function HistoricalHitboxes.UpdateFrame(self: HistoricalHitboxes, index: number)
	local tree = self.trees[index]
	local frameHitboxes = self.hitboxes[index]

	for _, info in self.partList do
		local register = info.register
		register:Step()
		local hitbox = frameHitboxes[info.id]

		if not register.inWorld then
			if hitbox then
				tree:remove(info.id)
				frameHitboxes[info.id] = nil
			end
			continue
		end

		--CFrame is the only field still worth reading off the instance every capture
		local cframe = register.part.CFrame
		local size = register.size

		if not hitbox then
			local newHitbox: Hitbox = {
				id = info.id,
				cframe = cframe,
				shape = bolt.create_box(size),
				size = size,
				instance = info.part,
				owner = register.owner,
				collisionGroup = register.collisionGroup,
				canCollide = register.canCollide,
				frameOffset = 0,
				active = true,
			}
			frameHitboxes[info.id] = newHitbox
			tree:insert(info.id, newHitbox.cframe, newHitbox.shape)
		else
			if size ~= hitbox.size then
				hitbox.size = size
				hitbox.shape = bolt.create_box(size)
				tree:resize(info.id, hitbox.shape)
			end
			hitbox.cframe = cframe
			hitbox.canCollide = register.canCollide
			hitbox.collisionGroup = register.collisionGroup
			tree:move(info.id, hitbox.cframe)
		end
	end

	--should_rebuild is a full scan over the tree's nodes, so each tree only checks on its own
	--schedule. the jitter keeps the trees from drifting into checking on the same frame.
	local now = os.clock()
	if now >= self.nextRebuildCheck[index] then
		self.nextRebuildCheck[index] = now + TREE_REBUILD_CHECK_INTERVAL
			+ rng:NextNumber(-TREE_REBUILD_CHECK_JITTER, TREE_REBUILD_CHECK_JITTER)

		if tree:should_rebuild() then
			tree:partial_rebuild()
		end
	end
end

function HistoricalHitboxes.QueryRaycast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	local playerName = player.Name
	local invLength = fractionScale(rayDirection)

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil
	local bestOffset = 0

	local function queryFrame(offset: number)
		local index = wrapIndex(centerIndex + offset, self.frameCap)
		local frameHitboxes = self.hitboxes[index]
		--anything the cast reaches after the current best is pruned before its narrow phase runs
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		self.trees[index]:query_ray_closest(rayOrigin, rayDirection, function(id: number): number?
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

function HistoricalHitboxes.QueryShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
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
		local frameHitboxes = self.hitboxes[index]
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		self.trees[index]:query_shapecast_closest(shape, cframe, direction, function(id: number): number?
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

function HistoricalHitboxes.QuerySimpleShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, number?)
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
		local frameHitboxes = self.hitboxes[index]
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		self.trees[index]:query_shapecast_closest(shape, cframe, direction, function(id: number): number?
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

function HistoricalHitboxes.QueryShape(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?): {[BasePart]: Hitbox}
	local playerName = player.Name
	local results: {[BasePart]: Hitbox} = {}
	local partCount = 0
	local maxParts = (params and params.MaxParts) or math.huge
	maxParts = if maxParts <= 0 then math.huge else maxParts

	for offset = -frameRange, frameRange do
		local index = wrapIndex(centerIndex + offset, self.frameCap)
		local frameHitboxes = self.hitboxes[index]
		for _, id in self.trees[index]:query_shape(cframe, shape) do
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
	for index = 1, self.frameCap do
		self.trees[index]:clear()
		table.clear(self.hitboxes[index])
	end
	table.clear(self.parts)
	table.clear(self.partList)
end

return HistoricalHitboxes
