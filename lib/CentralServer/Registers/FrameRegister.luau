--!native
--!strict
--!optimize 2
local FrameRegister = {}
FrameRegister.__index = FrameRegister

export type FrameRegister<T = {[string]:any}> = {
    index:number,
    frameCap:number,
    defaultData:T,
    frameData:{[number]:(T) & {active:boolean}},
    
    _pendingDestroy: boolean,
    _destroyTargetIndex: number,
    _isDestroyed: boolean,

    Step: (self: FrameRegister<T>) -> (),
    SaveData: (self: FrameRegister<T>, data:T) -> (),
    AtIndex: (self: FrameRegister<T>, index: number) -> T,
    GetDataInRange: (self: FrameRegister<T>, i: number, r: number) -> {[number]:T},
    
    ScheduleDestroy: (self: FrameRegister<T>) -> (),
    UnscheduleDestroy: (self: FrameRegister<T>) -> (),
    Destroy: (self: FrameRegister<T>) -> (),

	callback: ((self:FrameRegister<T>)->())?,
}

export type Config<T = {[string]:any}> = {
    initialIndex:number,
    frameCap:number,
    defaultData:T,

    SaveData: (self: FrameRegister<T>, data:T) -> (),

	callback: (()->())?,
}

local function deepCopy(tbl: any): any
    local clone = table.clone(tbl)
    for key, value in clone do
        if type(value) == "table" then
            clone[key] = deepCopy(value)
        end
    end
    return clone
end

function FrameRegister.new<T>(config:Config<T>) : FrameRegister<T>
    local self = setmetatable({}, FrameRegister)
    self.index = config.initialIndex
    self.frameCap = config.frameCap
    self.defaultData = deepCopy(config.defaultData)
    self.SaveData = config.SaveData
	self.callback = config.callback

    self._pendingDestroy = false
    self._destroyTargetIndex = -1
    self._isDestroyed = false

    self.frameData = table.create(self.frameCap)
    for i = 1, self.frameCap do
        self.frameData[i] = deepCopy(config.defaultData :: any)
    end

    return (self :: any)
end

function FrameRegister.Step<T>(self:FrameRegister<T>)
    if self._isDestroyed then return end

    self.index += 1
    if self.index > self.frameCap then
        self.index = 1
    end
    
    self:SaveData(self.frameData[self.index])
    
    if self._pendingDestroy and self.index == self._destroyTargetIndex then
        task.defer(function()
            if self._pendingDestroy and not self._isDestroyed then
                self:Destroy()
            end
        end)
    end
end

function FrameRegister.AtIndex<T>(self:FrameRegister<T>, index:number):T
    while index > self.frameCap do
        index -= self.frameCap
    end
    
    while index <= 0 do
        index += self.frameCap
    end
    
    return self.frameData[index]
end

function FrameRegister.GetDataInRange<T>(self: FrameRegister<T>, i: number, r: number): {[number]: T}
    local result = {}

    if self.index == 0 or self._isDestroyed then
        return result
    end

    local oldestIndex = (self.index % self.frameCap) + 1

    local backwardSteps = 0
    local currBackward = i
    while backwardSteps < r and currBackward ~= oldestIndex do
        backwardSteps += 1
        currBackward = ((currBackward - 2) % self.frameCap) + 1
    end

    local forwardSteps = 0
    local currForward = i
    while forwardSteps < r and currForward ~= self.index do
        forwardSteps += 1
        currForward = (currForward % self.frameCap) + 1
    end

    for offset = -backwardSteps, forwardSteps do
        local idx = ((i + offset - 1) % self.frameCap) + 1
        result[offset] = self.frameData[idx]
    end

    return result
end

function FrameRegister.ScheduleDestroy<T>(self: FrameRegister<T>)
    if self._isDestroyed or self._pendingDestroy then return end
    
    self._pendingDestroy = true
    self._destroyTargetIndex = self.index
end

function FrameRegister.UnscheduleDestroy<T>(self: FrameRegister<T>)
    if self._isDestroyed or not self._pendingDestroy then return end
    
    self._pendingDestroy = false
    self._destroyTargetIndex = -1
end

function FrameRegister.Destroy<T>(self: FrameRegister<T>)
    if self._isDestroyed then return end
    
    self._isDestroyed = true
    
    if self.frameData then
        table.clear(self.frameData)
    end

	if self.callback then
		self.callback(self)
	end
    
    setmetatable(self :: any, nil)

end

return FrameRegister