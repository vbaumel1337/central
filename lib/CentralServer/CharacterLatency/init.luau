--!strict
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
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
	local PlatformPart = Platform:WaitForChild("Part") :: Part
	local Part1 = Platform:WaitForChild("Part1") :: Part
	local Part2 = Platform:WaitForChild("Part2") :: Part
	local Remote = Folder:WaitForChild("CharacterLatencyRemote") :: RemoteEvent

	local Dummy = Folder:WaitForChild("LatencyDummy")
	Dummy:SetAttribute("Count", 1)
	Dummy:SetAttribute("Moving", false)
	Dummy:SetAttribute("State", 1)

	local LATENCY_ATTRIBUTE = Settings.LATENCY_ATTRIBUTE

	local humanoid = Dummy:WaitForChild("Humanoid") :: Humanoid
	local root = humanoid.RootPart :: Part

	local delta = Settings.LATENCY_DUMMY_HIDE_OFFSET
	PlatformPart.CFrame += delta
	Part1.CFrame += delta
	Part2.CFrame += delta
	root.CFrame += delta

	Folder.Parent = workspace

	PhysicsService:RegisterCollisionGroup("LatencyDummy")
	PhysicsService:CollisionGroupSetCollidable("LatencyDummy", "Default", false)
	PhysicsService:CollisionGroupSetCollidable("LatencyDummy", "LatencyDummy", true)

	local LATENCY_MULTIPLIER = Settings.LATENCY_MULTIPLIER
	local MAX_LATENCY = Settings.MAX_LATENCY

	local atStart = true

	local MAX_SERVER_STAMPS = Settings.LATENCY_STAMP_HISTORY

	local CountTimes = {} :: {[number]: number}

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

	local DT = Settings.LATENCY_DUMMY_STEP_INTERVAL

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
		if typeof(count) ~= "number" or typeof(t) ~= "number" then
			warn("Invalid latency stamp payload from player: " .. player.Name)
			return
		end

		if not CountTimes[count] then
			warn("Latency stamp expired or invalid for count: " .. tostring(count))
			return

		end

		local now = workspace:GetServerTimeNow()
		if t > now then
			warn("Latency stamp from the future for player: " .. player.Name)
			return
		end

		local currentLatency = math.clamp(t - CountTimes[count], 0, MAX_LATENCY)

		player:SetAttribute(LATENCY_ATTRIBUTE, currentLatency * LATENCY_MULTIPLIER)
	end)
end

return CharacterLatency
