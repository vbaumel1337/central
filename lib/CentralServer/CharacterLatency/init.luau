local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Settings = require(script.Parent.Parent.Settings)

local CharacterLatency = {}

local hasStarted = false

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

	local Platform = Folder:WaitForChild("Platform")
	local PlatformPart = Platform:WaitForChild("Part")
	local Part1 = Platform:WaitForChild("Part1")
	local Part2 = Platform:WaitForChild("Part2")
	local Remote = Folder:WaitForChild("CharacterLatencyRemote")

	local Dummy = Folder:WaitForChild("LatencyDummy")
	Dummy:SetAttribute("Count", 1)
	Dummy:SetAttribute("Moving", false)
	Dummy:SetAttribute("State", 1)

	local LATENCY_ATTRIBUTE = Settings.LATENCY_ATTRIBUTE

	local humanoid = Dummy:WaitForChild("Humanoid") :: Humanoid
	local root = humanoid.RootPart :: Part

	local delta = Vector3.new(0,13337,0)
	PlatformPart.CFrame += delta
	Part1.CFrame += delta
	Part2.CFrame += delta
	root.CFrame += delta

	Folder.Parent = workspace

	PhysicsService:RegisterCollisionGroup("LatencyDummy")
	PhysicsService:CollisionGroupSetCollidable("LatencyDummy", "Default", false)
	PhysicsService:CollisionGroupSetCollidable("LatencyDummy", "LatencyDummy", true)

	local LATENCY_MULTIPLIER = Settings.LATENCY_MULTIPLIER

	local atStart = true

	local MAX_SERVER_STAMPS = 3
	local MAX_AVERAGE_SAMPLES = 1

	local CountTimes = {} :: {[number]: number}
	local PlayerLatencies = {} :: {[Player]: {number}}

	local position1 = Part1.Position
	local position2 = Part2.Position
	local x1,x2 = position1.X, position2.X
	local half  = math.abs(x1-x2)/2

	local hasUpdated = false

	task.defer(function()
		while true do
			while Dummy:GetAttribute("Moving") do
				task.wait()
			end

			hasUpdated = false
			local startX =  if Dummy:GetAttribute("State") == 1 then x1 else x2
			local con: RBXScriptConnection
			con = RunService:BindToSimulation(function()
				if hasUpdated then
					con:Disconnect()
					return
				end

				if math.abs(root.Position.X - startX) >= half then
					local t = workspace:GetServerTimeNow()
					task.defer(function()
						local currentCount = Dummy:GetAttribute("Count")
						CountTimes[ Dummy:GetAttribute("Count")] = t

						local oldestCount = currentCount - MAX_SERVER_STAMPS
						if CountTimes[oldestCount] then
							CountTimes[oldestCount] = nil
						end
					end)

					hasUpdated = true
					con:Disconnect()
				end
			end, Settings.StepFrequency)

			while con.Connected do
				task.wait()
			end
		end
	end)

	local DT = 0.5

	task.defer(function()
		while true do
			local start = if atStart then position1 else position2
			local destination = if atStart then position2 else position1
			root.CFrame = CFrame.lookAt(start, destination)
			Dummy:SetAttribute("Moving", true)
			task.wait(DT)
			humanoid:MoveTo(destination)
			humanoid.MoveToFinished:Wait()
			root.AssemblyLinearVelocity = Vector3.zero
			atStart = not atStart
			Dummy:SetAttribute("State", if atStart then 1 else 2)
			task.wait(DT)
			Dummy:SetAttribute("Moving", false)
			Dummy:SetAttribute("Count", Dummy:GetAttribute("Count") + 1)
			task.wait(DT)
		end
	end)

	Remote.OnServerEvent:Connect(function(player: Player, count: number, t: number)
		if not CountTimes[count] then
			warn("Latency stamp expired or invalid for count: " .. tostring(count))
			return

		end

		local currentLatency = t - CountTimes[count]

		if not PlayerLatencies[player] then
			PlayerLatencies[player] = {}
		end

		local history = PlayerLatencies[player]

		table.insert(history, currentLatency)

		if #history > MAX_AVERAGE_SAMPLES then
			table.remove(history, 1)
		end

		local sum = 0
		for _, sample in ipairs(history) do
			sum += sample
		end
		local averageLatency = sum / #history

		local remoteLatency = workspace:GetServerTimeNow() - t
		local networkLatency = player:GetNetworkPing()/2


		player:SetAttribute(LATENCY_ATTRIBUTE, averageLatency*LATENCY_MULTIPLIER)
		--player:SetAttribute("RemoteLatency", remoteLatency)
		--player:SetAttribute("Latency", networkLatency)

	end)

	Players.PlayerRemoving:Connect(function(player)
		PlayerLatencies[player] = nil
	end)
end

return CharacterLatency
