--!strict
local FrameRegister = require(script.Parent.FrameRegister)

local TimeRegister = setmetatable({}, FrameRegister)
TimeRegister.__index = TimeRegister

type TimeData = {
	time: number
}

export type TimeRegister = FrameRegister.FrameRegister<TimeData> & {
	GetIndexAtTime: (self: TimeRegister, t:number) -> number
}

function TimeRegister.new(frameCap: number, initialIndex:number): TimeRegister
	local config: FrameRegister.Config<TimeData> = {
		initialIndex =  initialIndex,
		frameCap = frameCap,
		defaultData = { time = 0 },
		SaveData = function(self, data)
			data.time = time()
		end
	}

	local baseObject = FrameRegister.new(config)

	local self = setmetatable(baseObject, TimeRegister) :: any
	return self :: TimeRegister
end

function TimeRegister.GetIndexAtTime(self: TimeRegister, t: number): number?
	if self.index == 0 then
		return nil
	end

	local searchIndex = self.index
	local newerIndex: number? = nil

	for i = 1, self.frameCap do
		local frameTime = self.frameData[searchIndex].time

		if frameTime <= t then
			if newerIndex then
				local newerTime = self.frameData[newerIndex].time
				if (newerTime - t) < (t - frameTime) then
					return newerIndex
				end
			end
			return searchIndex
		end

		newerIndex = searchIndex
		searchIndex -= 1
		if searchIndex < 1 then
			searchIndex = self.frameCap
		end
	end

	return nil
end

return TimeRegister