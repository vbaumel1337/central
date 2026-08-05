--!strict
local Settings = require(script.Parent.Parent.Parent.Settings)
local Observers = require(script.Parent.Parent.Parent.Parent.Packages.Observers)
local FrameRegister = require(script.Parent.FrameRegister)

local PartRegister = setmetatable({}, FrameRegister)
PartRegister.__index = PartRegister

export type PartData = {
    cframe: CFrame | false,
    size: Vector3,
    canCollide: boolean,
}

export type PartRegister = FrameRegister.FrameRegister<PartData> & typeof(setmetatable(
    {} :: {
        _observers: {() -> ()},
        part: BasePart,
        owner: string,
        _currentSize: Vector3,
        _inWorld: boolean,
    },
    PartRegister
))

local partCache: {PartRegister} = {}

local function SaveData(self: PartRegister, data: PartData)
    if self._inWorld then
        data.cframe = self.part.CFrame
    else
        data.cframe = false
    end
    data.size = self._currentSize
    data.canCollide = self.part.CanCollide
end

function PartRegister.new(part: BasePart, frameCap: number, callback: ((self: PartRegister) -> ())?): PartRegister
    local self: PartRegister

    if #partCache > 0 then
        self = table.remove(partCache) :: PartRegister
        
        self.index = 0
        self._isDestroyed = false
        self._pendingDestroy = false
        self._destroyTargetIndex = -1
        self.callback = callback :: any
        
        for i = 1, frameCap do
            local fd = self.frameData[i]
            fd.cframe = false
            fd.size = part.Size
            fd.canCollide = part.CanCollide
        end
    else
        local defaultData: PartData = {
            cframe = false,
            size = part.Size,
            canCollide = part.CanCollide,
        }

        local config = {
            initialIndex = 0,
            frameCap = frameCap,
            defaultData = defaultData,
            callback = callback :: any,
            SaveData = SaveData :: any,
        } :: FrameRegister.Config<PartData>

        self = setmetatable(FrameRegister.new(config), PartRegister) :: any & PartRegister
        self.SaveData = SaveData :: any 
    end

    self.part = part
    self._currentSize = part.Size
    self._inWorld = part.Parent ~= nil

    local owner = part:GetAttribute(Settings.OWNER_ATTRIBUTE)
    self.owner = if typeof(owner) == "string" then owner else "Server"

    self._observers = self._observers or {}
    
    table.insert(self._observers, Observers.observeProperty(part, "Size", function(size)
        self._currentSize = (size :: Vector3)
        return
    end))

    table.insert(self._observers, Observers.observeProperty(part, "Parent", function(parent)
        self._inWorld = parent ~= nil
        return
    end))

    return self
end

function PartRegister.Destroy(self: PartRegister)
    if self._isDestroyed then return end

    for _, observer in self._observers do
        observer()
    end
    table.clear(self._observers)

    self.part = nil :: any
    
    self._isDestroyed = true
    self._pendingDestroy = false
    
    if self.callback then
        self.callback(self :: any)
    end

    table.insert(partCache, self)
end

return PartRegister