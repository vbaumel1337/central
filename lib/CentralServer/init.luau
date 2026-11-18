--!native
--!strict
--!optimize 2
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")
local CollectionService = game:GetService("CollectionService")

local Registers = script.Registers
local TimeRegister = require(Registers.TimeRegister)
local Observers = require(script.Parent.Parent.Observers)
local HistoricalHitboxes = require(script.HistoricalHitboxes)
local PartRegister = require(script.Registers.PartRegister)
local Settings = require(script.Parent.Settings)
local CollisionCache = require(script.CollisionCache)
export type Hitbox = HistoricalHitboxes.Hitbox

local bolt = require(script.Parent.bolt)

local FRAME_CAP = Settings.FRAME_CAP
local DEFAULT_RAYCAST_RANGE = Settings.RAYCAST_FRAME_RANGE
local DEFAULT_COLLISION_RANGE = Settings.COLLISION_FRAME_RANGE

local CentralServer = {Settings = Settings}

local HITBOX_GROUPS: {string} = {}
local QUERY_GROUPS: {string} = {}
local DEFAULT_HITBOX_COLLISIONGROUP = Settings.DEFAULT_HITBOX_COLLISIONGROUP

function CentralServer.AddQueryGroup(name: string)
	if table.find(QUERY_GROUPS, name) then
		return
	end

	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
	for _, hitboxGroup in HITBOX_GROUPS do
		PhysicsService:CollisionGroupSetCollidable(hitboxGroup, name, false)
	end
	table.insert(QUERY_GROUPS, name)
	CollisionCache.Invalidate()
end

function CentralServer.RemoveQueryGroup(name: string)
	local index = table.find(QUERY_GROUPS, name)
	if not index then
		return
	end

	for _, hitboxGroup in HITBOX_GROUPS do
		PhysicsService:CollisionGroupSetCollidable(hitboxGroup, name, true)
	end
	table.remove(QUERY_GROUPS, index)
	CollisionCache.Invalidate()
end

function CentralServer.IsQueryGroup(name: string): boolean
	return table.find(QUERY_GROUPS, name) ~= nil
end

function CentralServer.AddCollisionGroup(name: string)
	if table.find(HITBOX_GROUPS, name) then
		return
	end

	pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
	for _, queryGroup in QUERY_GROUPS do
		PhysicsService:CollisionGroupSetCollidable(name, queryGroup, false)
	end
	table.insert(HITBOX_GROUPS, name)
	CollisionCache.Invalidate()
end

function CentralServer.RemoveCollisionGroup(name: string)
	local index = table.find(HITBOX_GROUPS, name)
	if not index then
		return
	end

	for _, queryGroup in QUERY_GROUPS do
		PhysicsService:CollisionGroupSetCollidable(name, queryGroup, true)
	end
	table.remove(HITBOX_GROUPS, index)
	CollisionCache.Invalidate()
end

local GlobalTimeRegister = TimeRegister.new(FRAME_CAP, 0)
--local CharacterRegisters = {} :: {[Player]: CharacterRegister.CharacterRegister}
local PartRegisters = {} :: {[BasePart]:PartRegister.PartRegister}
local HistoricalIndex = HistoricalHitboxes.new(FRAME_CAP, Settings.AABB_PADDING, Settings.TEMPORAL_BUCKETS)

local RegistersPending:{PartRegister.PartRegister} = {}

-- A tagged Model's hitboxes are its Parts and MeshParts, except an accessory's: those are the
-- handles of things worn, and are not part of the body that is hit.
local function isModelMember(instance: Instance): boolean
	return (instance:IsA("Part") or instance:IsA("MeshPart")) and instance:FindFirstAncestorWhichIsA("Accoutrement") == nil
end

-- Registers a part as a hitbox, as a member of `group` (the tagged Model it belongs to) or, with
-- none, on its own. A register that is already there is kept: one that is waiting to be destroyed
-- is only given back its life when it is for the same group the part is being registered for.
local function registerPart(part: BasePart, group: Instance?): PartRegister.PartRegister
	local existing = PartRegisters[part]
	if existing and not existing._isDestroyed then
		if existing.group == group then
			existing:UnscheduleDestroy()
		end
		return existing
	end

	if not table.find(HITBOX_GROUPS, part.CollisionGroup) then
		part.CollisionGroup = DEFAULT_HITBOX_COLLISIONGROUP
	end

	local register = PartRegister.new(part, FRAME_CAP, function()
		PartRegisters[part] = nil
		HistoricalIndex:RemovePart(part)
	end, group)

	-- known from the moment it is made, not when the next step adds it to the history, so the same
	-- part met again before then (tagged on its own and inside a tagged Model, say) is one hitbox
	PartRegisters[part] = register
	table.insert(RegistersPending, register)
	return register
end

local warnedNested = setmetatable({} :: {[Instance]: boolean}, {__mode = "k"})

-- A part tagged on its own.
local function observePart(part: BasePart): (() -> ())?
	local existing = PartRegisters[part]
	if existing and existing.group ~= nil and not existing._isDestroyed and not existing._pendingDestroy then
		-- a member of a tagged Model already, and that Model's register is the one that counts
		return nil
	end

	local register = registerPart(part, nil)
	return function()
		register:ScheduleDestroy()
	end
end

-- A tagged Model: every Part and MeshPart in it, now and later, is a member of one group.
local function observeModel(model: Model): (() -> ())?
	local outer = model:FindFirstAncestorWhichIsA("Model")
	while outer do
		if CollectionService:HasTag(outer, Settings.HITBOX_TAG) then
			if not warnedNested[model] then
				warnedNested[model] = true
				warn(`Central: {model:GetFullName()} is tagged inside {outer:GetFullName()}, which is tagged too. The outer Model owns all of its parts; tag only one of them.`)
			end
			return nil
		end
		outer = outer:FindFirstAncestorWhichIsA("Model")
	end

	local members: {[Instance]: PartRegister.PartRegister} = {}

	local function addMember(instance: Instance)
		if not isModelMember(instance) then
			return
		end

		local part = instance :: BasePart
		local existing = PartRegisters[part]
		if existing and not existing._isDestroyed and existing.group ~= model and not existing._pendingDestroy then
			-- already a hitbox, tagged on its own or through another Model: the first one wins
			return
		end
		members[part] = registerPart(part, model)
	end

	local addedConnection = model.DescendantAdded:Connect(addMember)
	local removingConnection = model.DescendantRemoving:Connect(function(instance)
		local register = members[instance]
		if register then
			members[instance] = nil
			register:ScheduleDestroy()
		end
	end)

	for _, descendant in model:GetDescendants() do
		addMember(descendant)
	end

	return function()
		addedConnection:Disconnect()
		removingConnection:Disconnect()
		for _, register in members do
			register:ScheduleDestroy()
		end
		table.clear(members)
	end
end

local PlayerLatencies = {} :: {[Player]: number}
local PlayerIndices = {} :: {[Player]: number}

local hasStarted = false

function CentralServer.Start()
	if not RunService:IsServer() then
		warn("CentralServer.Start can only be called on the server")
		return
	end

	if hasStarted then
		warn("CentralServer.Start can only be called once")
		return
	end
	hasStarted = true

	require(script.CharacterLatency).Start()

	for _, name in Settings.INITIAL_QUERY_GROUPS do
		CentralServer.AddQueryGroup(name)
	end

	for _, name in Settings.INITIAL_COLLISION_GROUPS do
		CentralServer.AddCollisionGroup(name)
	end

	Observers.observeTag(Settings.HITBOX_TAG, function(instance: Instance): (() -> ())?
		if instance:IsA("BasePart") then
			return observePart(instance)
		elseif instance:IsA("Model") then
			return observeModel(instance)
		end
		return nil
	end, {workspace})

	if Settings.AUTO_ADD_CHARACTERS then
		-- the character Model is the hitbox group, so a whole character is one leaf in the history.
		-- The owner goes on first: it is read when the Model's parts are registered.
		Observers.observeCharacter(function(player, character)
			character:SetAttribute(Settings.OWNER_ATTRIBUTE, player.Name)
			character:AddTag(Settings.HITBOX_TAG)
			return function()
				character:RemoveTag(Settings.HITBOX_TAG)
			end
		end)
	end

	Observers.observePlayer(function(player)
		return Observers.observeAttribute(player, Settings.LATENCY_ATTRIBUTE, function(latency)
			PlayerLatencies[player] = latency :: number

			return function()
				PlayerLatencies[player] = nil
				PlayerIndices[player] = nil
			end
		end, function(value)
			return typeof(value) == "number"
		end)
	end)

	RunService:BindToSimulation(function(delta)

		for _, register in ipairs(RegistersPending) do
			register.index = GlobalTimeRegister.index
			PartRegisters[register.part] = register
			HistoricalIndex:AddPart(register)

		end
		table.clear(RegistersPending)

		GlobalTimeRegister:Step()

		HistoricalIndex:UpdateFrame(GlobalTimeRegister.index)

		for player, characterLatency in PlayerLatencies do
			PlayerIndices[player] = GlobalTimeRegister:GetIndexAtTime(time() - characterLatency) or GlobalTimeRegister.index
		end

	end, Settings.StepFrequency, Settings.HitboxStepPriority)
end

function CentralServer.QueryPlayerRaycast(player:Player, ray_origin:Vector3, ray_direction:Vector3, frameRange:number?, params: RaycastParams?, check: ((BasePart) -> boolean)?) : (HistoricalHitboxes.Hitbox?, Vector3?, number?, Vector3?)
	local range = frameRange or DEFAULT_RAYCAST_RANGE
	local playerIndex = PlayerIndices[player] or GlobalTimeRegister.index
	local hitbox, hitPoint, distance, hitNormal = HistoricalIndex:QueryRaycast(player, playerIndex, range, ray_origin, ray_direction, params, check)

	return hitbox, hitPoint, distance, hitNormal
end

function CentralServer.QueryPlayerShapecast(player:Player, cframe:CFrame, shape:bolt.Shape, direction:Vector3, frameRange:number?, params: RaycastParams?, check: ((BasePart) -> boolean)?) : (HistoricalHitboxes.Hitbox?, Vector3?, number?, Vector3?)
	local range = frameRange or DEFAULT_COLLISION_RANGE
	local playerIndex = PlayerIndices[player] or GlobalTimeRegister.index
	local hitbox, hitPoint, distance, hitNormal = HistoricalIndex:QueryShapecast(player, playerIndex, range, cframe, shape, direction, params, check)

	return hitbox, hitPoint, distance, hitNormal
end

function CentralServer.QueryPlayerSimpleShapecast(player:Player, cframe:CFrame, shape:bolt.Shape, direction:Vector3, frameRange:number?, params: RaycastParams?, check: ((BasePart) -> boolean)?) : (HistoricalHitboxes.Hitbox?, number?)
	local range = frameRange or DEFAULT_COLLISION_RANGE
	local playerIndex = PlayerIndices[player] or GlobalTimeRegister.index
	local hitbox, distance = HistoricalIndex:QuerySimpleShapecast(player, playerIndex, range, cframe, shape, direction, params, check)

	return hitbox, distance
end

function CentralServer.QueryPlayerShape(player:Player, cframe:CFrame, shape:bolt.Shape, frameRange:number?, params: OverlapParams?, check: ((BasePart) -> boolean)?) : {[BasePart]:HistoricalHitboxes.Hitbox}
	local range = frameRange or DEFAULT_COLLISION_RANGE
	local playerIndex = PlayerIndices[player] or GlobalTimeRegister.index
	local results = HistoricalIndex:QueryShape(player, playerIndex, range, cframe, shape, params, check)

	return results
end

function CentralServer.GetPredictedHitboxes(player: Player, ownerName: string) : {HistoricalHitboxes.Hitbox}
	local playerIndex = PlayerIndices[player] or GlobalTimeRegister.index
	return HistoricalIndex:GetHitboxesForOwner(playerIndex, ownerName)
end

return CentralServer
