--!native
--!strict
--!optimize 2
--[[
	The owned-hitbox pass: a flat scan over the querying player's own registers, posed at their
	live CFrame.

	HistoryQueries answers "who else is here, rewound to what this player saw". This answers
	"where is the querier's own character right now" - a different question with a much smaller
	answer set, one player's own tagged parts, character-sized - so it skips the broad-phase tree
	that pass needs and just walks the list the tag observer already keeps.

	What HistoryQueries carries that this drops, because a live scan has no use for it: the
	hitbox.owner == playerName test (the list is already the owner's), posedCFrame and bracket
	blending, the tested memo, the frame-range widening loop, PREFER_NEAREST_FRAME, and
	bindSlot/unbindSlot.

	The linear scan is unconditionally better while a player's owned set stays character-sized. It
	would lose to a tree somewhere in the low hundreds of owned parts per player - a player owning
	a large fleet of tagged vehicles or projectiles. Not this project, and not worth a fallback.
]]

local bolt = require(script.Parent.Parent.bolt)
local Settings = require(script.Parent.Parent.Settings)
local QueryFilter = require(script.Parent.QueryFilter)
local HistoryQueries = require(script.Parent.HistoryQueries)
local PartRegister = require(script.Parent.Registers.PartRegister)

local gjk = bolt.dispatch.gjk

local GJK_TOLERANCE = Settings.GJK_TOLERANCE

--shared with HistoryQueries rather than re-declared, so the narrow phase can't drift between the
--two owned paths
local castBoundingRadius = HistoryQueries.castBoundingRadius
local collides = HistoryQueries.collides

export type Hitbox = HistoryQueries.Hitbox

local OwnedQueries = {}

--reused across candidates within a single query; QueryFilter.rejects only ever reads these three
--fields, so one table rewritten per candidate replaces one allocation per candidate. Safe against
--a check() callback re-entering a query: every iteration rewrites all three fields before this
--table is read again.
local scratchFilterable = {
	instance = nil,
	canCollide = false,
	collisionGroup = "",
} :: QueryFilter.Filterable

local function buildHitbox(register: PartRegister.PartRegister, cframe: CFrame): Hitbox
	return {
		id = 0,
		cframe = cframe,
		shape = register.shape,
		size = register.size,
		boundingRadius = register.boundingRadius,
		instance = register.part,
		owner = register.owner,
		collisionGroup = register.collisionGroup,
		canCollide = register.canCollide,
		frameOffset = 0,
		active = true,
	}
end

function OwnedQueries.QueryRaycast(registers: {PartRegister.PartRegister}, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	local filter = QueryFilter.resolve(params)
	local originX, originY, originZ = rayOrigin.X, rayOrigin.Y, rayOrigin.Z

	local bestDistance = math.huge
	local bestRegister: PartRegister.PartRegister? = nil
	local bestCFrame: CFrame? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil

	for _, register in registers do
		if register._isDestroyed or not register.inWorld then
			continue
		end

		scratchFilterable.instance = register.part
		scratchFilterable.canCollide = register.canCollide
		scratchFilterable.collisionGroup = register.collisionGroup
		if QueryFilter.rejects(filter, scratchFilterable) then
			continue
		end

		if check and not check(register.part) then
			continue
		end

		local cframe = register.part.CFrame
		local pos = cframe.Position
		local gx, gy, gz = pos.X - originX, pos.Y - originY, pos.Z - originZ
		--the running best stands in for the tree's own per-candidate bound: there is no tree to
		--tighten as we go, but the prune shrinks the same way as bestDistance falls
		local reach = register.boundingRadius + bestDistance
		if gx * gx + gy * gy + gz * gz > reach * reach then
			continue
		end

		local hitPoint, distance, hitNormal = bolt.raycast.box(rayOrigin, rayDirection, cframe, register.shape)
		if distance == nil or distance >= bestDistance then
			continue
		end

		bestDistance = distance
		bestRegister = register
		bestCFrame = cframe
		bestPoint = hitPoint
		bestNormal = hitNormal
	end

	if not bestRegister then
		return nil, nil, nil, nil
	end

	return buildHitbox(bestRegister, bestCFrame :: CFrame), bestPoint, bestDistance, bestNormal
end

function OwnedQueries.QueryShapecast(registers: {PartRegister.PartRegister}, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, Vector3?, number?, Vector3?)
	if direction.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end

	local filter = QueryFilter.resolve(params)
	local castRadius = castBoundingRadius(shape)
	local castOrigin = cframe.Position
	local originX, originY, originZ = castOrigin.X, castOrigin.Y, castOrigin.Z

	local bestDistance = math.huge
	local bestRegister: PartRegister.PartRegister? = nil
	local bestCFrame: CFrame? = nil
	local bestPoint: Vector3? = nil
	local bestNormal: Vector3? = nil

	for _, register in registers do
		if register._isDestroyed or not register.inWorld then
			continue
		end

		scratchFilterable.instance = register.part
		scratchFilterable.canCollide = register.canCollide
		scratchFilterable.collisionGroup = register.collisionGroup
		if QueryFilter.rejects(filter, scratchFilterable) then
			continue
		end

		if check and not check(register.part) then
			continue
		end

		local partCFrame = register.part.CFrame
		local pos = partCFrame.Position
		local gx, gy, gz = pos.X - originX, pos.Y - originY, pos.Z - originZ
		local reach = castRadius + register.boundingRadius + bestDistance
		if gx * gx + gy * gy + gz * gz > reach * reach then
			continue
		end

		local hitPoint, distance, hitNormal = gjk.shapecast(cframe, direction, shape, partCFrame, register.shape, GJK_TOLERANCE)
		if distance == nil or distance >= bestDistance then
			continue
		end

		bestDistance = distance
		bestRegister = register
		bestCFrame = partCFrame
		bestPoint = hitPoint
		bestNormal = hitNormal
	end

	if not bestRegister then
		return nil, nil, nil, nil
	end

	return buildHitbox(bestRegister, bestCFrame :: CFrame), bestPoint, bestDistance, bestNormal
end

function OwnedQueries.QuerySimpleShapecast(registers: {PartRegister.PartRegister}, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?): (Hitbox?, number?)
	if direction.Magnitude < 1e-6 then
		return nil, nil
	end

	local filter = QueryFilter.resolve(params)
	local castRadius = castBoundingRadius(shape)
	local castOrigin = cframe.Position
	local originX, originY, originZ = castOrigin.X, castOrigin.Y, castOrigin.Z

	local bestDistance = math.huge
	local bestRegister: PartRegister.PartRegister? = nil
	local bestCFrame: CFrame? = nil

	for _, register in registers do
		if register._isDestroyed or not register.inWorld then
			continue
		end

		scratchFilterable.instance = register.part
		scratchFilterable.canCollide = register.canCollide
		scratchFilterable.collisionGroup = register.collisionGroup
		if QueryFilter.rejects(filter, scratchFilterable) then
			continue
		end

		if check and not check(register.part) then
			continue
		end

		local partCFrame = register.part.CFrame
		local pos = partCFrame.Position
		local gx, gy, gz = pos.X - originX, pos.Y - originY, pos.Z - originZ
		local reach = castRadius + register.boundingRadius + bestDistance
		if gx * gx + gy * gy + gz * gz > reach * reach then
			continue
		end

		local hit, distance = gjk.shapecast_simple(cframe, direction, shape, partCFrame, register.shape, GJK_TOLERANCE)
		if not hit or distance == nil or distance >= bestDistance then
			continue
		end

		bestDistance = distance
		bestRegister = register
		bestCFrame = partCFrame
	end

	if not bestRegister then
		return nil, nil
	end

	return buildHitbox(bestRegister, bestCFrame :: CFrame), bestDistance
end

function OwnedQueries.QueryShape(registers: {PartRegister.PartRegister}, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?): {[BasePart]: Hitbox}
	local filter = QueryFilter.resolve(params)
	local results: {[BasePart]: Hitbox} = {}
	local partCount = 0
	local maxParts = (params and params.MaxParts) or math.huge
	maxParts = if maxParts <= 0 then math.huge else maxParts

	for _, register in registers do
		if register._isDestroyed or not register.inWorld then
			continue
		end

		scratchFilterable.instance = register.part
		scratchFilterable.canCollide = register.canCollide
		scratchFilterable.collisionGroup = register.collisionGroup
		if QueryFilter.rejects(filter, scratchFilterable) then
			continue
		end

		if check and not check(register.part) then
			continue
		end

		local partCFrame = register.part.CFrame
		if not collides(register.shape, partCFrame, cframe, shape) then
			continue
		end

		if partCount >= maxParts then
			break
		end

		results[register.part] = buildHitbox(register, partCFrame)
		partCount += 1
	end

	return results
end

return OwnedQueries
