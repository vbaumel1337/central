--!native
--!strict
--!optimize 2
--[[
	Live state for one tagged hitbox part.

	This used to keep a ring of `frameCap` PartData tables per part, written every step and read
	back one entry later by UpdateFrame. That ring duplicated `hitboxes[slot]` field for field, so
	the history structure now reads the part's state straight off this object instead.

	Everything except CFrame is mirrored here by an Observer rather than polled, so a capture costs
	one property read per part instead of one per field.
]]
local Settings = require(script.Parent.Parent.Parent.Settings)
local Observers = require(script.Parent.Parent.Parent.Parent.Observers)
local bolt = require(script.Parent.Parent.Parent.bolt)

local PartRegister = {}
PartRegister.__index = PartRegister

export type PartRegister = typeof(setmetatable(
	{} :: {
		part: BasePart,
		owner: string,
		frameCap: number,

		--mirrored from the instance by observers
		size: Vector3,
		canCollide: boolean,
		collisionGroup: string,
		inWorld: boolean,

		--rebuilt alongside size; cached here so both history backends and the owned-hitbox
		--scan can read them straight off the register instead of each keeping their own copy
		shape: bolt.BoxShape,
		boundingRadius: number,

		_observers: {() -> ()},
		_pendingDestroy: boolean,
		_destroyCountdown: number,
		_isDestroyed: boolean,
		callback: ((self: any) -> ())?,

		Step: (self: any) -> (),
		ScheduleDestroy: (self: any) -> (),
		UnscheduleDestroy: (self: any) -> (),
		Destroy: (self: any) -> (),
	},
	PartRegister
))

function PartRegister.new(part: BasePart, frameCap: number, callback: ((self: PartRegister) -> ())?): PartRegister
	local self = setmetatable({}, PartRegister) :: PartRegister

	self.part = part
	self.frameCap = frameCap
	self.callback = callback :: any

	self.size = part.Size
	self.canCollide = part.CanCollide
	self.collisionGroup = part.CollisionGroup
	self.inWorld = part.Parent ~= nil

	self.shape = bolt.create_box(self.size)
	self.boundingRadius = self.size.Magnitude / 2

	self._pendingDestroy = false
	self._destroyCountdown = 0
	self._isDestroyed = false

	local owner = part:GetAttribute(Settings.OWNER_ATTRIBUTE)
	self.owner = if typeof(owner) == "string" then owner else "Server"

	self._observers = {}

	table.insert(self._observers, Observers.observeProperty(part, "Size", function(size)
		self.size = (size :: Vector3)
		self.shape = bolt.create_box(self.size)
		self.boundingRadius = self.size.Magnitude / 2
		return
	end))

	table.insert(self._observers, Observers.observeProperty(part, "Parent", function(parent)
		self.inWorld = parent ~= nil
		return
	end))

	--a runtime CollisionGroup change used to be invisible to historical queries, which kept
	--filtering against whatever the group was when the first hitbox record was built, while the
	--live workspace query saw the current one. The two halves of a merged result disagreed.
	table.insert(self._observers, Observers.observeProperty(part, "CollisionGroup", function(group)
		self.collisionGroup = (group :: string)
		return
	end))

	table.insert(self._observers, Observers.observeProperty(part, "CanCollide", function(canCollide)
		self.canCollide = (canCollide :: boolean)
		return
	end))

	return self
end

--only drives the deferred destroy now; the history structure reads state directly
function PartRegister.Step(self: PartRegister)
	if self._isDestroyed or not self._pendingDestroy then
		return
	end

	self._destroyCountdown -= 1
	if self._destroyCountdown > 0 then
		return
	end

	task.defer(function()
		if self._pendingDestroy and not self._isDestroyed then
			self:Destroy()
		end
	end)
end

--an untagged part keeps its history for one full window before it is dropped
function PartRegister.ScheduleDestroy(self: PartRegister)
	if self._isDestroyed or self._pendingDestroy then
		return
	end

	self._pendingDestroy = true
	self._destroyCountdown = self.frameCap
end

function PartRegister.UnscheduleDestroy(self: PartRegister)
	if self._isDestroyed or not self._pendingDestroy then
		return
	end

	self._pendingDestroy = false
	self._destroyCountdown = 0
end

function PartRegister.Destroy(self: PartRegister)
	if self._isDestroyed then
		return
	end

	for _, disconnect in self._observers do
		disconnect()
	end
	table.clear(self._observers)

	self._isDestroyed = true
	self._pendingDestroy = false
	self.part = nil :: any

	if self.callback then
		self.callback(self)
	end
end

return PartRegister
