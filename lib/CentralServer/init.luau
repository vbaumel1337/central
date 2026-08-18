--!native
--!strict
--!optimize 2
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local Registers = script.Registers
local TimeRegister = require(Registers.TimeRegister)
local Observers = require(script.Parent.Parent.Observers)
local HistoricalHitboxes = require(script.HistoricalHitboxes)
local HistoricalRefit = require(script.HistoricalRefit)
local PartRegister = require(script.Registers.PartRegister)
local Settings = require(script.Parent.Settings)
export type Hitbox = HistoricalHitboxes.Hitbox

local bolt = require(script.Parent.bolt)

local FRAME_CAP = Settings.FRAME_CAP
local DEFAULT_RAYCAST_RANGE = Settings.RAYCAST_FRAME_RANGE
local DEFAULT_COLLISION_RANGE = Settings.COLLISION_FRAME_RANGE
local CAPTURE_DIVISOR = math.max(1, Settings.HISTORY_CAPTURE_DIVISOR)

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
end

local GlobalTimeRegister = TimeRegister.new(FRAME_CAP, 0)
--local CharacterRegisters = {} :: {[Player]: CharacterRegister.CharacterRegister}
local PartRegisters = {} :: {[BasePart]:PartRegister.PartRegister}
--both backends expose the same interface; the cast keeps every use site below typed against the
--shipping one instead of degrading to any
local HistoricalIndex: HistoricalHitboxes.HistoricalHitboxes = if Settings.HISTORY_BACKEND == "refit"
	then (HistoricalRefit.new(FRAME_CAP, Settings.AABB_PADDING) :: any)
	else HistoricalHitboxes.new(FRAME_CAP, Settings.AABB_PADDING)

local RegistersPending:{PartRegister.PartRegister} = {}

local OwnedHitboxParts = {} :: {[Player]: {BasePart}}

local PlayerLatencies = {} :: {[Player]: number}
local stepsSinceCapture = 0

--resolved per query rather than per step: most players are not querying on any given frame, and
--sampling at query time is if anything fresher than sampling at the last step boundary.
--Returns the older sample, the newer one to blend toward, and how far between them the rewind is.
local function resolveRewind(player: Player): (number, number?, number)
	local latency = PlayerLatencies[player]
	if not latency then
		return GlobalTimeRegister.index, nil, 0
	end

	local older, newer, alpha = GlobalTimeRegister:GetBracketAtTime(time() - latency)
	if not older then
		return GlobalTimeRegister.index, nil, 0
	end

	return older, newer, alpha
end

function CentralServer.GetOwnedHitboxParts(player: Player): {BasePart}
	return OwnedHitboxParts[player] or {}
end

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

	Observers.observeTag(Settings.HITBOX_TAG, function(part:BasePart)
		if not part:IsA("BasePart") then
			return
		end
		local register = PartRegisters[part]
		if not register or register._isDestroyed then

			if not table.find(HITBOX_GROUPS, part.CollisionGroup) then
				part.CollisionGroup = DEFAULT_HITBOX_COLLISIONGROUP
			end

			register = PartRegister.new(part, FRAME_CAP, function()
					PartRegisters[part] = nil
					HistoricalIndex:RemovePart(part)
			end)

			table.insert(RegistersPending, register:: PartRegister.PartRegister)
		else
			register:UnscheduleDestroy()
		end

		local owner: Player? = nil
		local ownerName = part:GetAttribute(Settings.OWNER_ATTRIBUTE)
		if typeof(ownerName) == "string" then
			local ownerInstance = Players:FindFirstChild(ownerName)
			if ownerInstance and ownerInstance:IsA("Player") then
				owner = ownerInstance
			end
		end

		if owner then
			local owned = OwnedHitboxParts[owner]
			if not owned then
				owned = {}
				OwnedHitboxParts[owner] = owned
			end
			table.insert(owned, part)
		end

		return function()
			register:ScheduleDestroy()

			if owner then
				local owned = OwnedHitboxParts[owner]
				if owned then
					local index = table.find(owned, part)
					if index then
						table.remove(owned, index)
					end
					if #owned == 0 then
						OwnedHitboxParts[owner] = nil
					end
				end
			end
		end
	end, {workspace})

	if Settings.AUTO_ADD_CHARACTERS then
		Observers.observeCharacter(function(player, charcter)
			for _, part in charcter:GetChildren() do
				if part:IsA("Part") then
					part:SetAttribute(Settings.OWNER_ATTRIBUTE, player.Name)
					part:AddTag(Settings.HITBOX_TAG)
				end
			end
			return nil
		end)
	end

	Observers.observePlayer(function(player)
		return Observers.observeAttribute(player, Settings.LATENCY_ATTRIBUTE, function(latency)
			PlayerLatencies[player] = latency :: number

			return function()
				PlayerLatencies[player] = nil
			end
		end, function(value)
			return typeof(value) == "number"
		end)
	end)

	RunService:BindToSimulation(function(delta)

		for _, register in ipairs(RegistersPending) do
			PartRegisters[register.part] = register
			HistoricalIndex:AddPart(register)

		end
		table.clear(RegistersPending)

		--history is sampled on its own cadence; a rewind lands between samples and is blended
		stepsSinceCapture += 1
		if stepsSinceCapture < CAPTURE_DIVISOR then
			return
		end
		stepsSinceCapture = 0

		GlobalTimeRegister:Step()

		HistoricalIndex:UpdateFrame(GlobalTimeRegister.index)

	end, Settings.StepFrequency, Settings.HitboxStepPriority)
end

function CentralServer.QueryPlayerRaycast(player:Player, ray_origin:Vector3, ray_direction:Vector3, frameRange:number?, params: RaycastParams?, check: ((BasePart) -> boolean)?) : (HistoricalHitboxes.Hitbox?, Vector3?, number?, Vector3?)
	local range = frameRange or DEFAULT_RAYCAST_RANGE
	local centerIndex, blendIndex, blendAlpha = resolveRewind(player)
	local hitbox, hitPoint, distance, hitNormal = HistoricalIndex:QueryRaycast(player, centerIndex, blendIndex, blendAlpha, range, ray_origin, ray_direction, params, check)

	return hitbox, hitPoint, distance, hitNormal
end

function CentralServer.QueryPlayerShapecast(player:Player, cframe:CFrame, shape:bolt.Shape, direction:Vector3, frameRange:number?, params: RaycastParams?, check: ((BasePart) -> boolean)?) : (HistoricalHitboxes.Hitbox?, Vector3?, number?, Vector3?)
	local range = frameRange or DEFAULT_COLLISION_RANGE
	local centerIndex, blendIndex, blendAlpha = resolveRewind(player)
	local hitbox, hitPoint, distance, hitNormal = HistoricalIndex:QueryShapecast(player, centerIndex, blendIndex, blendAlpha, range, cframe, shape, direction, params, check)

	return hitbox, hitPoint, distance, hitNormal
end

function CentralServer.QueryPlayerSimpleShapecast(player:Player, cframe:CFrame, shape:bolt.Shape, direction:Vector3, frameRange:number?, params: RaycastParams?, check: ((BasePart) -> boolean)?) : (HistoricalHitboxes.Hitbox?, number?)
	local range = frameRange or DEFAULT_COLLISION_RANGE
	local centerIndex, blendIndex, blendAlpha = resolveRewind(player)
	local hitbox, distance = HistoricalIndex:QuerySimpleShapecast(player, centerIndex, blendIndex, blendAlpha, range, cframe, shape, direction, params, check)

	return hitbox, distance
end

function CentralServer.QueryPlayerShape(player:Player, cframe:CFrame, shape:bolt.Shape, frameRange:number?, params: OverlapParams?, check: ((BasePart) -> boolean)?) : {[BasePart]:HistoricalHitboxes.Hitbox}
	local range = frameRange or DEFAULT_COLLISION_RANGE
	local centerIndex, blendIndex, blendAlpha = resolveRewind(player)
	local results = HistoricalIndex:QueryShape(player, centerIndex, blendIndex, blendAlpha, range, cframe, shape, params, check)

	return results
end

function CentralServer.GetPredictedHitboxes(player: Player, ownerName: string) : {HistoricalHitboxes.Hitbox}
	local centerIndex = resolveRewind(player)
	return HistoricalIndex:GetHitboxesForOwner(centerIndex, ownerName)
end

return CentralServer
