--!strict
local RunService = game:GetService("RunService")

local Settings = require(script.Parent.Settings)

local isClient = RunService:IsClient()

local radius = Settings.LATENCY_ORBIT_RADIUS

local function makeValue(model: Model, root: Part): Vector3Value
	local val = Instance.new("Vector3Value")
	val.Value = Vector3.new(0, 0, radius) + root.Position
	val.Name = "RadiusCenter"
	val.Parent = model
	return val
end

return function(model: Model)
	local humanoid = model:WaitForChild("Humanoid") :: Humanoid
	local rootPart = model:WaitForChild("Torso") :: Part

	local value: Vector3Value = if isClient then model:WaitForChild("RadiusCenter") :: Vector3Value else makeValue(model, rootPart)

	local center = value.Value

	local connection
	connection = RunService:BindToSimulation(function()
		local offset = Vector3.new(rootPart.Position.X - center.X, 0, rootPart.Position.Z - center.Z)
		local tangent = Vector3.new(-offset.Z, 0, offset.X).Unit
		humanoid:Move(tangent)
	end, Settings.StepFrequency)

	return connection
end
