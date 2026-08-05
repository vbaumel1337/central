local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)

local CentralClient = {}

local hasStarted = false

function CentralClient.Start()
	if not RunService:IsClient() then
		warn("CentralClient.Start can only be called on the client")
		return
	end

	if hasStarted then
		warn("CentralClient.Start can only be called once")
		return
	end
	hasStarted = true

	local Folder = workspace:FindFirstChild('CharacterLatency')
	while not Folder do
		task.wait()
		Folder = workspace:FindFirstChild("CharacterLatency")
	end
	local Remote = Folder:WaitForChild("CharacterLatencyRemote") :: RemoteEvent

	local Dummy = Folder:WaitForChild("LatencyDummy")
	local root = Dummy:WaitForChild("HumanoidRootPart") :: Part

	local Platform = Folder:WaitForChild("Platform")
	local Part1 = Platform:WaitForChild("Part1")
	local Part2 = Platform:WaitForChild("Part2")

	task.wait(4.125)

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
						Remote:FireServer(Dummy:GetAttribute("Count"), t)
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
end

return CentralClient
