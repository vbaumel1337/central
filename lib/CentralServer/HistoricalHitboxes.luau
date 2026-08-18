--!native
--!strict
--!optimize 2

local bolt = require(script.Parent.Parent.bolt)
local Settings = require(script.Parent.Parent.Settings)
local PartRegister = require(script.Parent.Registers.PartRegister)
local QueryFilter = require(script.Parent.QueryFilter)

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
		QueryRaycast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QueryShapecast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QuerySimpleShapecast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?) -> (Hitbox?, number?),
		QueryShape: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?) -> {[BasePart]: Hitbox},
		GetHitboxesForOwner: (self: any, index: number, ownerName: string) -> {Hitbox},
		Destroy: (self: any) -> (),
	},
	HistoricalHitboxes
))

local function wrapIndex(index: number, frameCap: number): number
	return ((index - 1) % frameCap) + 1
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

--the pose at the exact rewind time. The bracketing pair is blended rather than snapped to,
--which is what lets a capture interval longer than a simulation step stay accurate. Falls back
--to whichever slot actually holds the hitbox when the other one does not.
local function posedCFrame(
	centerHitboxes: {[number]: Hitbox},
	blendHitboxes: {[number]: Hitbox}?,
	alpha: number,
	id: number,
	fallback: Hitbox
): CFrame
	local anchor = centerHitboxes[id]
	if not anchor then
		return fallback.cframe
	end

	if not blendHitboxes then
		return anchor.cframe
	end

	local other = blendHitboxes[id]
	if not other then
		return anchor.cframe
	end

	return anchor.cframe:Lerp(other.cframe, alpha)
end

function HistoricalHitboxes.QueryRaycast(self: HistoricalHitboxes, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	local playerName = player.Name
	local filter = QueryFilter.resolve(params)
	local invLength = fractionScale(rayDirection)

	local centerHitboxes = self.hitboxes[centerIndex]
	local blendHitboxes = if blendIndex then self.hitboxes[blendIndex] else nil

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestCFrame: CFrame? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil
	local bestOffset = 0

	local function queryFrame(index: number, offset: number)
		local frameHitboxes = self.hitboxes[index]
		--anything the cast reaches after the current best is pruned before its narrow phase runs
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		self.trees[index]:query_ray_closest(rayOrigin, rayDirection, function(id: number): number?
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or QueryFilter.rejects(filter, hitbox) or (check and not check(hitbox.instance)) then
				return nil
			end

			--the slot decides candidacy, the rewind time decides the pose
			local posed = posedCFrame(centerHitboxes, blendHitboxes, blendAlpha, id, hitbox)
			local hitPoint, distance, hitNormal = bolt.raycast.box(rayOrigin, rayDirection, posed, hitbox.shape)
			if distance == nil then
				return nil
			end

			if distance < bestDistance then
				bestDistance = distance
				bestHitbox = hitbox
				bestCFrame = posed
				bestPoint = hitPoint
				bestNormal = hitNormal
				bestOffset = offset
			end

			return distance * invLength
		end, maxFraction)
	end

	--the bracketing pair describes one instant, so both halves are resolved before widening
	queryFrame(centerIndex, 0)
	if blendIndex then
		queryFrame(blendIndex, 0)
	end

	if not (PREFER_NEAREST_FRAME and bestHitbox) then
		for absOffset = 1, frameRange do
			queryFrame(wrapIndex(centerIndex - absOffset, self.frameCap), -absOffset)
			queryFrame(wrapIndex(centerIndex + absOffset, self.frameCap), absOffset)

			if PREFER_NEAREST_FRAME and bestHitbox then
				break
			end
		end
	end

	if not bestHitbox then
		return nil, nil, nil, nil
	end

	local resultHitbox = table.clone(bestHitbox :: Hitbox)
	resultHitbox.frameOffset = bestOffset
	resultHitbox.cframe = bestCFrame :: CFrame

	return resultHitbox, bestPoint, bestDistance, bestNormal
end

function HistoricalHitboxes.QueryShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	if direction.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end

	local playerName = player.Name
	local filter = QueryFilter.resolve(params)
	local invLength = fractionScale(direction)

	local centerHitboxes = self.hitboxes[centerIndex]
	local blendHitboxes = if blendIndex then self.hitboxes[blendIndex] else nil

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestCFrame: CFrame? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil
	local bestOffset = 0

	local function queryFrame(index: number, offset: number)
		local frameHitboxes = self.hitboxes[index]
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		self.trees[index]:query_shapecast_closest(shape, cframe, direction, function(id: number): number?
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or QueryFilter.rejects(filter, hitbox) or (check and not check(hitbox.instance)) then
				return nil
			end

			local posed = posedCFrame(centerHitboxes, blendHitboxes, blendAlpha, id, hitbox)
			local hitPoint, distance, hitNormal = gjk.shapecast(cframe, direction, shape, posed, hitbox.shape, GJK_TOLERANCE)
			if distance == nil then
				return nil
			end

			if distance < bestDistance then
				bestDistance = distance
				bestHitbox = hitbox
				bestCFrame = posed
				bestPoint = hitPoint
				bestNormal = hitNormal
				bestOffset = offset
			end

			return distance * invLength
		end, maxFraction)
	end

	queryFrame(centerIndex, 0)
	if blendIndex then
		queryFrame(blendIndex, 0)
	end

	if not (PREFER_NEAREST_FRAME and bestHitbox) then
		for absOffset = 1, frameRange do
			queryFrame(wrapIndex(centerIndex - absOffset, self.frameCap), -absOffset)
			queryFrame(wrapIndex(centerIndex + absOffset, self.frameCap), absOffset)

			if PREFER_NEAREST_FRAME and bestHitbox then
				break
			end
		end
	end

	if not bestHitbox then
		return nil, nil, nil, nil
	end

	local resultHitbox = table.clone(bestHitbox :: Hitbox)
	resultHitbox.frameOffset = bestOffset
	resultHitbox.cframe = bestCFrame :: CFrame

	return resultHitbox, bestPoint, bestDistance, bestNormal
end

function HistoricalHitboxes.QuerySimpleShapecast(self: HistoricalHitboxes, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, number?)
	if direction.Magnitude < 1e-6 then
		return nil, nil
	end

	local playerName = player.Name
	local filter = QueryFilter.resolve(params)
	local invLength = fractionScale(direction)

	local centerHitboxes = self.hitboxes[centerIndex]
	local blendHitboxes = if blendIndex then self.hitboxes[blendIndex] else nil

	local bestDistance = math.huge
	local bestHitbox: Hitbox? = nil
	local bestCFrame: CFrame? = nil
	local bestOffset = 0

	local function queryFrame(index: number, offset: number)
		local frameHitboxes = self.hitboxes[index]
		local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

		self.trees[index]:query_shapecast_closest(shape, cframe, direction, function(id: number): number?
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or QueryFilter.rejects(filter, hitbox) or (check and not check(hitbox.instance)) then
				return nil
			end

			local posed = posedCFrame(centerHitboxes, blendHitboxes, blendAlpha, id, hitbox)
			local hit, distance = gjk.shapecast_simple(cframe, direction, shape, posed, hitbox.shape, GJK_TOLERANCE)
			if not hit or distance == nil then
				return nil
			end

			if distance < bestDistance then
				bestDistance = distance
				bestHitbox = hitbox
				bestCFrame = posed
				bestOffset = offset
			end

			return distance * invLength
		end, maxFraction)
	end

	queryFrame(centerIndex, 0)
	if blendIndex then
		queryFrame(blendIndex, 0)
	end

	if not (PREFER_NEAREST_FRAME and bestHitbox) then
		for absOffset = 1, frameRange do
			queryFrame(wrapIndex(centerIndex - absOffset, self.frameCap), -absOffset)
			queryFrame(wrapIndex(centerIndex + absOffset, self.frameCap), absOffset)

			if PREFER_NEAREST_FRAME and bestHitbox then
				break
			end
		end
	end

	if not bestHitbox then
		return nil, nil
	end

	local resultHitbox = table.clone(bestHitbox :: Hitbox)
	resultHitbox.frameOffset = bestOffset
	resultHitbox.cframe = bestCFrame :: CFrame

	return resultHitbox, bestDistance
end

local function collides(hitbox: Hitbox, hitboxCFrame: CFrame, cframe: CFrame, shape: bolt.Shape): boolean
	if shape.type == shapeMap.BOX then
		return collision.box_box(hitboxCFrame, hitbox.shape, cframe, shape :: bolt.BoxShape)
	elseif shape.type == shapeMap.SPHERE then
		return collision.box_sphere(hitboxCFrame, hitbox.shape, cframe, shape :: bolt.SphereShape)
	elseif shape.type == shapeMap.CAPSULE then
		return collision.box_capsule(hitboxCFrame, hitbox.shape, cframe, shape :: bolt.CapsuleShape)
	end

	return gjk.intersects(hitboxCFrame, hitbox.shape, cframe, shape, GJK_TOLERANCE)
end

function HistoricalHitboxes.QueryShape(self: HistoricalHitboxes, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?): {[BasePart]: Hitbox}
	local playerName = player.Name
	local filter = QueryFilter.resolve(params)
	local results: {[BasePart]: Hitbox} = {}
	local partCount = 0
	local maxParts = (params and params.MaxParts) or math.huge
	maxParts = if maxParts <= 0 then math.huge else maxParts

	local centerHitboxes = self.hitboxes[centerIndex]
	local blendHitboxes = if blendIndex then self.hitboxes[blendIndex] else nil

	local function queryFrame(index: number, offset: number)
		local frameHitboxes = self.hitboxes[index]
		for _, id in self.trees[index]:query_shape(cframe, shape) do
			local hitbox = frameHitboxes[id]
			if not hitbox or hitbox.owner == playerName or QueryFilter.rejects(filter, hitbox) or (check and not check(hitbox.instance)) then
				continue
			end

			local posed = posedCFrame(centerHitboxes, blendHitboxes, blendAlpha, id, hitbox)
			if not collides(hitbox, posed, cframe, shape) then
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
				resultHitbox.cframe = posed
				results[hitbox.instance] = resultHitbox
			end
		end
	end

	queryFrame(centerIndex, 0)
	if blendIndex then
		queryFrame(blendIndex, 0)
	end

	for absOffset = 1, frameRange do
		queryFrame(wrapIndex(centerIndex - absOffset, self.frameCap), -absOffset)
		queryFrame(wrapIndex(centerIndex + absOffset, self.frameCap), absOffset)
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
