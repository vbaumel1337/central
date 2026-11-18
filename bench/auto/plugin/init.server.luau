-- Installed into Studio's local Plugins folder by bench/autobench.py for the duration of a run,
-- and removed afterwards. It does nothing unless the open place is one that script built: those
-- carry a ServerScriptService.CentralAutoBench folder, and that is the only thing this looks for.
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

if RunService:IsRunning() then
	return
end

local marker = ServerScriptService:FindFirstChild("CentralAutoBench")
if not marker or not marker:GetAttribute("AutoRun") then
	return
end

local autoRun = marker:WaitForChild("AutoRun", 10)
if not autoRun then
	warn("CentralAutoBench: marker folder has no AutoRun module")
	return
end

-- let Studio finish opening the place before it is frozen by the first measurement
task.wait(3)

local ok, message = pcall(function()
	require(autoRun).Run()
end)
if not ok then
	warn("CentralAutoBench: " .. tostring(message))
end
