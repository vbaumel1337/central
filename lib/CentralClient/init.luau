--!strict
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)
local SpinNPC = require(script.Parent.SpinNPC)

local CentralClient = {}

local hasStarted = false

-- Finds the torso part, handling both R6 ("Torso") and R15 ("UpperTorso") rigs.
local function getTorso(model: Model): BasePart
	local part = model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
	if part and part:IsA("BasePart") then
		return part
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local root = humanoid.RootPart
		if root then
			return root
		end
	end
	error(("%s has no Torso/UpperTorso and no HumanoidRootPart"):format(model:GetFullName()))
end

-- Angle (radians) of `pos` around `centerPos`, in the XZ (horizontal) plane.
local function getAngle(pos: Vector3, centerPos: Vector3): number
	return math.atan2(pos.Z - centerPos.Z, pos.X - centerPos.X)
end

-- Wraps an angle into (-pi, pi].
local function normalizeAngle(angle: number): number
	angle = angle % (2 * math.pi)
	if angle > math.pi then
		angle -= 2 * math.pi
	end
	return angle
end

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

	local Folder = workspace:FindFirstChild("CharacterLatency")
	while not Folder do
		task.wait()
		Folder = workspace:FindFirstChild("CharacterLatency")
	end
	local Remote = Folder:WaitForChild("CharacterLatencyRemote") :: RemoteEvent

	local dummy1, dummy2 = Folder:WaitForChild("LatencyDummyPredicted"), Folder:WaitForChild("LatencyDummyDelayed")
	local torso1, torso2 = dummy1:WaitForChild("Torso"), dummy2:WaitForChild("Torso")
	local center = dummy1:WaitForChild("RadiusCenter").Value

	SpinNPC(dummy1)
	SpinNPC(dummy2)

	RunService:SetPredictionMode(torso1, Enum.PredictionMode.On)
	RunService:SetPredictionMode(torso2, Enum.PredictionMode.Off)

	local ANGLE_EPSILON = Settings.LATENCY_ANGLE_EPSILON
	local TIMEOUT = Settings.LATENCY_MEASURE_TIMEOUT
	local PAUSE_BETWEEN_MEASUREMENTS = Settings.LATENCY_MEASURE_PAUSE

	-- measurement state, carried across frames
	local measuring = false
	local startTime = 0
	local targetAngle = 0
	local prevDiff: number? = nil
	local nextMeasureTime = 0 -- time() at which we're allowed to start the next measurement

	RunService.PostSimulation:Connect(function()
		local now = time()

		if not measuring then
			if now < nextMeasureTime then
				return
			end

			-- start a new measurement: record dummy1's torso position right now
			local recordedPosition = getTorso(dummy1).Position
			targetAngle = getAngle(recordedPosition, center)
			startTime = now
			prevDiff = nil
			measuring = true
			return
		end

		-- currently measuring
		if now - startTime > TIMEOUT then
			measuring = false
			nextMeasureTime = now + PAUSE_BETWEEN_MEASUREMENTS
			return
		end

		local torso2Position = getTorso(dummy2).Position
		local angle2 = getAngle(torso2Position, center)
		local rawDiff = normalizeAngle(angle2 - targetAngle)

		-- within the tolerance band, or a sign change (crossed over) since last frame
		local withinMargin = math.abs(rawDiff) <= ANGLE_EPSILON
		local crossed = prevDiff ~= nil and (
			((prevDiff :: number) > 0 and rawDiff <= 0) or ((prevDiff :: number) < 0 and rawDiff >= 0)
		)

		if withinMargin or crossed then
			local elapsed = now - startTime
			Remote:FireServer(elapsed - 1 / 60)

			measuring = false
			nextMeasureTime = now + PAUSE_BETWEEN_MEASUREMENTS
			return
		end

		prevDiff = rawDiff
	end)
end

return CentralClient
