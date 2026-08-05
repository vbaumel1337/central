--!strict
local PhysicsService = game:GetService("PhysicsService")

local bolt = require(script.Parent.Parent.bolt)
local Settings = require(script.Parent.Parent.Settings)
local PartRegister = require(script.Parent.Registers.PartRegister)

local gjk = bolt.dispatch.gjk
local collision = bolt.collision
local shapeMap = bolt.shape_map

local GJK_TOLERANCE = 1e-4

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

type PartInfo = {id: number, part: BasePart, register: PartRegister.PartRegister}

local HistoricalHitboxes = {}
HistoricalHitboxes.__index = HistoricalHitboxes

export type HistoricalHitboxes = typeof(setmetatable(
	{} :: {
		frameCap: number,
		padding: number,
		trees: {[number]: bolt.DynamicTree},
		hitboxes: {[number]: {[number]: Hitbox}},
		parts: {[BasePart]: PartInfo},
		nextPartId: number,
		AddPart: (self: any, register: PartRegister.PartRegister) -> (),
		RemovePart: (self: any, part: BasePart) -> (),
		UpdateFrame: (self: any, index: number) -> (),
		QueryRaycast: (self: any, player: Player, centerIndex: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QueryShapecast: (self: any, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QuerySimpleShapecast: (self: any, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?) -> (Hitbox?, number?),
		QueryShape: (self: any, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?) -> {[BasePart]: Hitbox},
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
	self.hitboxes = {}
	self.parts = {}
	self.nextPartId = 0

	for index = 1, frameCap do
		self.trees[index] = bolt.aabb_tree.new({aabb_padding = padding})
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
	self.parts[part] = {id = self.nextPartId, part = part, register = register}
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

	self.parts[part] = nil
end

function HistoricalHitboxes.UpdateFrame(self: HistoricalHitboxes, index: number)
	local tree = self.trees[index]
	local frameHitboxes = self.hitboxes[index]

	for _, info in self.parts do
		local data = info.register:AtIndex(index)
		local hitbox = frameHitboxes[info.id]
		if not data.cframe then
			if hitbox then
				tree:remove(info.id)
				frameHitboxes[info.id] = nil
			end
			continue
		end

		if not hitbox then
			local newHitbox: Hitbox = {
				id = info.id,
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
			frameHitboxes[info.id] = newHitbox
			tree:insert(info.id, newHitbox.cframe, newHitbox.shape)
		else
			if data.size ~= hitbox.size then
				hitbox.size = data.size
				hitbox.shape = bolt.create_box(data.size)
				tree:resize(info.id, hitbox.shape)
			end
			hitbox.cframe = data.cframe
			hitbox.canCollide = data.canCollide
			tree:move(info.id, hitbox.cframe)
		end
	end

	if tree:should_rebuild() then
		tree:partial_rebuild()
	end
end

function HistoricalHitboxes.QueryRaycast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	local playerName = player.Name
	local minDistance = math.huge
	local minOffset = math.huge
	local resultHitbox: Hitbox? = nil
	local resultPoint: Vector3? = nil
	local resultDistance: number? = nil
	local resultNormal: Vector3? = nil

	for offset = -frameRange, frameRange do
		local index = wrapIndex(centerIndex + offset, self.frameCap)
		local frameHitboxes = self.hitboxes[index]
		for _, id in self.trees[index]:query_ray(rayOrigin, rayDirection) do
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
				continue
			end

			local hitPoint, distance, hitNormal = bolt.raycast.box(rayOrigin, rayDirection, hitbox.cframe, hitbox.shape)
			local absOffset = math.abs(offset)
			if distance and (distance < minDistance or absOffset < minOffset) then
				minDistance = distance
				minOffset = absOffset
				local clonedHitbox = table.clone(hitbox)
				clonedHitbox.frameOffset = offset
				resultHitbox = clonedHitbox
				resultPoint = hitPoint :: Vector3
				resultDistance = distance
				resultNormal = hitNormal :: Vector3
			end
		end
	end

	return resultHitbox, resultPoint, resultDistance, resultNormal
end

function HistoricalHitboxes.QueryShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	if direction.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end

	local playerName = player.Name
	local minDistance = math.huge
	local minOffset = math.huge
	local resultHitbox: Hitbox? = nil
	local resultPoint: Vector3? = nil
	local resultDistance: number? = nil
	local resultNormal: Vector3? = nil

	for offset = -frameRange, frameRange do
		local index = wrapIndex(centerIndex + offset, self.frameCap)
		local frameHitboxes = self.hitboxes[index]
		for _, id in self.trees[index]:query_shapecast(shape, cframe, direction) do
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
				continue
			end

			local hitPoint, distance, hitNormal = gjk.shapecast(cframe, direction, shape, hitbox.cframe, hitbox.shape, GJK_TOLERANCE)
			local absOffset = math.abs(offset)
			if distance and (distance < minDistance or absOffset < minOffset) then
				minDistance = distance
				minOffset = absOffset
				local clonedHitbox = table.clone(hitbox)
				clonedHitbox.frameOffset = offset
				resultHitbox = clonedHitbox
				resultPoint = hitPoint :: Vector3
				resultDistance = distance
				resultNormal = hitNormal :: Vector3
			end
		end
	end

	return resultHitbox, resultPoint, resultDistance, resultNormal
end

function HistoricalHitboxes.QuerySimpleShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, number?)
	if direction.Magnitude < 1e-6 then
		return nil, nil
	end

	local playerName = player.Name
	local minDistance = math.huge
	local minOffset = math.huge
	local resultHitbox: Hitbox? = nil
	local resultDistance: number? = nil

	for offset = -frameRange, frameRange do
		local index = wrapIndex(centerIndex + offset, self.frameCap)
		local frameHitboxes = self.hitboxes[index]
		for _, id in self.trees[index]:query_shapecast(shape, cframe, direction) do
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or isFilteredOut(hitbox, params) or (check and not check(hitbox.instance)) then
				continue
			end

			local hit, distance = gjk.shapecast_simple(cframe, direction, shape, hitbox.cframe, hitbox.shape, GJK_TOLERANCE)
			local absOffset = math.abs(offset)
			if hit and distance and (distance < minDistance or absOffset < minOffset) then
				minDistance = distance
				minOffset = absOffset
				local clonedHitbox = table.clone(hitbox)
				clonedHitbox.frameOffset = offset
				resultHitbox = clonedHitbox
				resultDistance = distance
			end
		end
	end

	return resultHitbox, resultDistance
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
				local resultHitbox = hitbox
				resultHitbox.frameOffset = offset
				results[hitbox.instance] = resultHitbox
			end
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
end

return HistoricalHitboxes
