--!native
--!strict
--!optimize 2
--[[
	When each history slot was captured, so a rewind can be resolved back to a slot.
	One number per slot; this used to be a FrameRegister of single field tables.
]]
local TimeRegister = {}
TimeRegister.__index = TimeRegister

export type TimeRegister = typeof(setmetatable(
	{} :: {
		index: number,
		frameCap: number,
		times: {number},
		Step: (self: any) -> (),
		GetIndexAtTime: (self: any, t: number) -> number?,
		GetBracketAtTime: (self: any, t: number) -> (number?, number?, number),
	},
	TimeRegister
))

function TimeRegister.new(frameCap: number, initialIndex: number): TimeRegister
	local self = setmetatable({}, TimeRegister) :: TimeRegister
	self.index = initialIndex
	self.frameCap = frameCap
	self.times = table.create(frameCap, 0)
	return self
end

function TimeRegister.Step(self: TimeRegister)
	local index = self.index + 1
	if index > self.frameCap then
		index = 1
	end

	self.index = index
	self.times[index] = time()
end

function TimeRegister.GetIndexAtTime(self: TimeRegister, t: number): number?
	if self.index == 0 then
		return nil
	end

	local times = self.times
	local searchIndex = self.index
	local newerIndex: number? = nil

	for _ = 1, self.frameCap do
		local frameTime = times[searchIndex]

		if frameTime <= t then
			if newerIndex then
				local newerTime = times[newerIndex]
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

--the two slots `t` falls between, plus how far along it is between them. Snapping to the nearest
--slot quantises a rewind to the capture interval; with the bracket the caller can resolve the
--pose at the exact time instead, which matters more now that captures are not every step.
--Returns (older, newer, alpha). `newer` is nil when t is at or past the most recent capture.
function TimeRegister.GetBracketAtTime(self: TimeRegister, t: number): (number?, number?, number)
	if self.index == 0 then
		return nil, nil, 0
	end

	local times = self.times
	local searchIndex = self.index
	local newerIndex: number? = nil

	for _ = 1, self.frameCap do
		local frameTime = times[searchIndex]

		if frameTime <= t then
			if not newerIndex then
				--t is at or past the newest capture, so there is nothing to interpolate toward
				return searchIndex, nil, 0
			end

			local newerTime = times[newerIndex]
			local span = newerTime - frameTime
			local alpha = if span > 0 then (t - frameTime) / span else 0

			return searchIndex, newerIndex, math.clamp(alpha, 0, 1)
		end

		newerIndex = searchIndex
		searchIndex -= 1
		if searchIndex < 1 then
			searchIndex = self.frameCap
		end
	end

	--t is older than everything stored; clamp to the oldest slot we still have
	return newerIndex, nil, 0
end

return TimeRegister
