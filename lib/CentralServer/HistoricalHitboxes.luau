--!native
--!strict
--!optimize 2

local bolt = require(script.Parent.Parent.bolt)
local Settings = require(script.Parent.Parent.Settings)
local PartRegister = require(script.Parent.Registers.PartRegister)
local HistoryQueries = require(script.Parent.HistoryQueries)

local TREE_REBUILD_CHECK_INTERVAL = Settings.TREE_REBUILD_CHECK_INTERVAL
local TREE_REBUILD_CHECK_JITTER = Settings.TREE_REBUILD_CHECK_INTERVAL * Settings.TREE_REBUILD_CHECK_JITTER

--own generator, so staggering the trees never disturbs the global math.random sequence
local rng = Random.new()

export type Hitbox = HistoryQueries.Hitbox

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
		QueryRaycast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QueryShapecast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> (Hitbox?, Vector3?, number?, Vector3?),
		QuerySimpleShapecast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> (Hitbox?, number?),
		QueryShape: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> {[BasePart]: Hitbox},
		GetHitboxesForOwner: (self: any, index: number, ownerName: string) -> {Hitbox},
		Destroy: (self: any) -> (),
	},
	HistoricalHitboxes
))

local wrapIndex = HistoryQueries.wrapIndex

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
				shape = register.shape,
				size = size,
				boundingRadius = register.boundingRadius,
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
				hitbox.shape = register.shape
				hitbox.boundingRadius = register.boundingRadius
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

--the traversals themselves live in HistoryQueries. this backend's whole contribution to a query
--is that a slot's candidates come from that slot's own tree: nothing to set up, nothing to undo.
local queries = HistoryQueries.create(function(self: HistoricalHitboxes, index: number): bolt.DynamicTree?
	return self.trees[index]
end, function() end)

HistoricalHitboxes.QueryRaycast = queries.QueryRaycast
HistoricalHitboxes.QueryShapecast = queries.QueryShapecast
HistoricalHitboxes.QuerySimpleShapecast = queries.QuerySimpleShapecast
HistoricalHitboxes.QueryShape = queries.QueryShape

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
