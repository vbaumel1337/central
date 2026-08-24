--!strict
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Settings = require(script.Parent.Parent.Settings)
local SpinNPC = require(script.Parent.Parent.SpinNPC)

local CharacterLatency = {}

local hasStarted = false

local function setDummyCollisionGroup(dummy: Model, group: string)
	for _, part in dummy:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = group
		end
	end
end

local function unanchorDummy(dummy: Model)
	for _, part in dummy:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end
end

function CharacterLatency.Start()
	if not RunService:IsServer() then
		warn("CharacterLatency.Start can only be called on the server")
		return
	end

	if hasStarted then
		warn("CharacterLatency.Start can only be called once")
		return
	end
	hasStarted = true

	local Folder = script:WaitForChild("CharacterLatency")

	local Remote = Folder:WaitForChild("CharacterLatencyRemote") :: RemoteEvent
	local dummy1, dummy2 = Folder:WaitForChild("LatencyDummyPredicted"), Folder:WaitForChild("LatencyDummyDelayed")
	local torso1, torso2 = dummy1:WaitForChild("Torso") :: Part, dummy2:WaitForChild("Torso") :: Part
	local platformPart = Folder:WaitForChild("Platform"):WaitForChild("Part") :: Part

	local LATENCY_ATTRIBUTE = Settings.LATENCY_ATTRIBUTE
	local LATENCY_OFFSET = Settings.LATENCY_OFFSET
	local MAX_LATENCY = Settings.MAX_LATENCY
	local LATENCY_CEILING = Settings.LATENCY_CEILING
	local LATENCY_SAMPLE_WINDOW = Settings.LATENCY_SAMPLE_WINDOW

	-- MAX_LATENCY is the authored, security-relevant knob (see README); LATENCY_CEILING is what
	-- the history ring can actually service. MAX_LATENCY can only ever lower the effective value,
	-- never raise it past what the ring supports.
	local EFFECTIVE_MAX_LATENCY = math.min(MAX_LATENCY, LATENCY_CEILING)
	if MAX_LATENCY > LATENCY_CEILING then
		warn(string.format(
			"Central: Settings.MAX_LATENCY (%.3fs) exceeds LATENCY_CEILING (%.3fs); rewind is capped at %.3fs. "
				.. "Lower MAX_LATENCY, or raise UNIONS_PER_PART/UNION_SIZE, to silence this.",
			MAX_LATENCY, LATENCY_CEILING, EFFECTIVE_MAX_LATENCY
		))
	end

	local latencySamples = {} :: {[Player]: {number}}

	Players.PlayerRemoving:Connect(function(player)
		latencySamples[player] = nil
	end)

	local delta = Settings.LATENCY_DUMMY_HIDE_OFFSET
	torso1.CFrame += delta
	torso2.CFrame += delta
	platformPart.CFrame += delta

	Folder.Parent = workspace

	PhysicsService:RegisterCollisionGroup("LatencyDummy1")
	PhysicsService:RegisterCollisionGroup("LatencyDummy2")
	PhysicsService:CollisionGroupSetCollidable("LatencyDummy1", "LatencyDummy2", false)

	setDummyCollisionGroup(dummy1, "LatencyDummy1")
	setDummyCollisionGroup(dummy2, "LatencyDummy2")
	unanchorDummy(dummy1)
	unanchorDummy(dummy2)

	SpinNPC(dummy1)
	SpinNPC(dummy2)

	Remote.OnServerEvent:Connect(function(player: Player, elapsed: number)
		--NaN is dropped rather than clamped: math.clamp propagates it, and a single NaN
		--sample would poison the averaged attribute and disable rewinding for this player
		if typeof(elapsed) ~= "number" or elapsed ~= elapsed then
			return
		end

		local sample = math.clamp(elapsed + LATENCY_OFFSET, 0, EFFECTIVE_MAX_LATENCY)

		local samples = latencySamples[player]
		if not samples then
			samples = {}
			latencySamples[player] = samples
		end

		table.insert(samples, sample)
		if #samples > LATENCY_SAMPLE_WINDOW then
			table.remove(samples, 1)
		end

		local sum = 0
		for _, value in samples do
			sum += value
		end

		player:SetAttribute(LATENCY_ATTRIBUTE, sum / #samples)
	end)
end

return CharacterLatency
