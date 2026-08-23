--!native
--!strict
--!optimize 2
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")

local Registers = script.Registers
local TimeRegister = require(Registers.TimeRegister)
local Observers = require(script.Parent.Parent.Observers)
local HistoricalHitboxes = require(script.HistoricalHitboxes)
local HistoricalRefit = require(script.HistoricalRefit)
local OwnedQueries = require(script.OwnedQueries)
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

--keyed by owner name (the string PartRegister.owner holds) rather than by Player instance, so
--this and the compensated pass's `hitbox.owner == playerName` test agree by construction: a part
--tagged before its owning Player exists still lands here, instead of falling into neither pass
local OwnedHitboxRegisters = {} :: {[string]: {PartRegister.PartRegister}}

local PlayerLatencies = {} :: {[Player]: number}
local stepsSinceCapture = 0

--the ring index is 0 until the first capture and every history slot is 1-based, so anything
--resolving to "now" has to land on a real slot. Slot 1 is empty before the first capture, which
--is the right answer at that point anyway. UpdateFrame is exempt: it runs straight after Step.
local function newestIndex(): number
	local index = GlobalTimeRegister.index
	return if index == 0 then 1 else index
end

--resolved per query rather than per step: most players are not querying on any given frame, and
--sampling at query time is if anything fresher than sampling at the last step boundary.
--Returns the older sample, the newer one to blend toward, and how far between them the rewind is.
local function resolveRewind(player: Player): (number, number?, number)
	local latency = PlayerLatencies[player]
	if not latency then
		return newestIndex(), nil, 0
	end

	local older, newer, alpha = GlobalTimeRegister:GetBracketAtTime(time() - latency)
	if not older then
		return newestIndex(), nil, 0
	end

	return older, newer, alpha
end

function CentralServer.GetOwnedHitboxParts(player: Player): {BasePart}
	local registers = OwnedHitboxRegisters[player.Name]
	if not registers then
		return {}
	end

	local parts = table.create(#registers)
	for _, register in registers do
		table.insert(parts, register.part)
	end
	return parts
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

		--keyed by the same owner string PartRegister already resolved (defaults to "Server" when
		--unattributed), not by looking up a live Player instance - a part tagged before its owning
		--Player exists still lands here, and the compensated pass's `hitbox.owner == playerName`
		--test already keys off this same string, so the two passes agree by construction
		local ownerName = register.owner
		local owned = OwnedHitboxRegisters[ownerName]
		if not owned then
			owned = {}
			OwnedHitboxRegisters[ownerName] = owned
		end
		table.insert(owned, register)

		return function()
			register:ScheduleDestroy()

			local stillOwned = OwnedHitboxRegisters[ownerName]
			if stillOwned then
				local index = table.find(stillOwned, register)
				if index then
					table.remove(stillOwned, index)
				end
				if #stillOwned == 0 then
					OwnedHitboxRegisters[ownerName] = nil
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

		--history is sampled on its own cadence; a rewind lands between samples and is blended.
		--carrying the remainder instead of resetting to 0 is what makes a fractional divisor
		--(1.5, say) average out to the right rate over time rather than rounding up to ceil(it)
		--every single period.
		stepsSinceCapture += 1
		if stepsSinceCapture < CAPTURE_DIVISOR then
			return
		end
		stepsSinceCapture -= CAPTURE_DIVISOR

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

--The querying player's own hitboxes are the other half of a merged result: everyone else is
--rewound to what this player saw, but their own character is not, so these resolve at its live
--CFrame - a flat scan over the player's own registers, not a history lookup at all.
function CentralServer.QueryOwnedRaycast(player: Player, ray_origin: Vector3, ray_direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (HistoricalHitboxes.Hitbox?, Vector3?, number?, Vector3?)
	local registers = OwnedHitboxRegisters[player.Name]
	if not registers then
		return nil, nil, nil, nil
	end
	return OwnedQueries.QueryRaycast(registers, ray_origin, ray_direction, params, check)
end

function CentralServer.QueryOwnedShapecast(player: Player, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (HistoricalHitboxes.Hitbox?, Vector3?, number?, Vector3?)
	local registers = OwnedHitboxRegisters[player.Name]
	if not registers then
		return nil, nil, nil, nil
	end
	return OwnedQueries.QueryShapecast(registers, cframe, shape, direction, params, check)
end

function CentralServer.QueryOwnedSimpleShapecast(player: Player, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (HistoricalHitboxes.Hitbox?, number?)
	local registers = OwnedHitboxRegisters[player.Name]
	if not registers then
		return nil, nil
	end
	return OwnedQueries.QuerySimpleShapecast(registers, cframe, shape, direction, params, check)
end

function CentralServer.QueryOwnedShape(player: Player, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?): {[BasePart]: HistoricalHitboxes.Hitbox}
	local registers = OwnedHitboxRegisters[player.Name]
	if not registers then
		return {}
	end
	return OwnedQueries.QueryShape(registers, cframe, shape, params, check)
end

function CentralServer.HasOwnedHitboxes(player: Player): boolean
	local owned = OwnedHitboxRegisters[player.Name]
	return owned ~= nil and #owned > 0
end

function CentralServer.GetPredictedHitboxes(player: Player, ownerName: string) : {HistoricalHitboxes.Hitbox}
	local centerIndex = resolveRewind(player)
	return HistoricalIndex:GetHitboxesForOwner(centerIndex, ownerName)
end

return CentralServer
