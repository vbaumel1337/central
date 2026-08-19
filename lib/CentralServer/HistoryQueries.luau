--!native
--!strict
--!optimize 2
--[[
	The query half of a history backend, written once.

	Both backends hold the same two things: `frameCap` slots of `{[id]: Hitbox}`, and a bolt tree
	to walk for candidates. They differ in exactly one step. "trees" keeps a tree per slot and
	hands the slot's own tree straight over; "refit" keeps a single shared topology and has to
	point it at the slot's bounds first, then put it back afterwards. That step is the
	`bindSlot`/`unbindSlot` pair passed to `create`.

	Everything downstream of it is identical in both and lives here: the ownership/filter/check
	rejection, the bracket blend that turns a slot's pose into the pose at the rewind time, the
	narrow phase, the bracket-then-widen walk over frames, and the result assembly.
]]

local bolt = require(script.Parent.Parent.bolt)
local Settings = require(script.Parent.Parent.Settings)
local QueryFilter = require(script.Parent.QueryFilter)

local gjk = bolt.dispatch.gjk
local collision = bolt.collision
local shapeMap = require(script.Parent.Parent.bolt.shape_map)

local GJK_TOLERANCE = Settings.GJK_TOLERANCE
local PREFER_NEAREST_FRAME = Settings.PREFER_NEAREST_FRAME

export type Hitbox = {
	id: number,
	cframe: CFrame,
	shape: bolt.BoxShape,
	size: Vector3,
	instance: BasePart,
	owner: string,
	collisionGroup: string,
	canCollide: boolean,
	frameOffset: number,
	active: boolean,
}

--all the shared traversals read off a backend. both backends are supersets of this.
export type State = {
	frameCap: number,
	hitboxes: {[number]: {[number]: Hitbox}},
}

--hands back the tree to walk for one slot, or nil when the slot holds nothing worth traversing.
--`unbindSlot` runs after the traversal, and only when a tree came back.
export type BindSlot = (self: any, index: number) -> bolt.DynamicTree?
export type UnbindSlot = (self: any) -> ()

export type Queries = {
	QueryRaycast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> (Hitbox?, Vector3?, number?, Vector3?),
	QueryShapecast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> (Hitbox?, Vector3?, number?, Vector3?),
	QuerySimpleShapecast: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> (Hitbox?, number?),
	QueryShape: (self: any, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?) -> {[BasePart]: Hitbox},
}

local HistoryQueries = {}

--the closest-hit tree queries work in fractions of the cast, not studs, so narrow phase
--distances get scaled by this. a zero length sweep collapses every hit onto fraction 0.
local function fractionScale(direction: Vector3): number
	local length = direction.Magnitude
	return if length > 0 then 1 / length else 0
end

local function wrapIndex(index: number, frameCap: number): number
	return ((index - 1) % frameCap) + 1
end
HistoryQueries.wrapIndex = wrapIndex

--the pose at the exact rewind time. The bracketing pair is blended rather than snapped to,
--which is what lets a capture interval longer than a simulation step stay accurate. Falls back
--to whichever slot actually holds the hitbox when the other one does not.
local function posedCFrame(
	centerHitboxes: {[number]: Hitbox},
	blendHitboxes: {[number]: Hitbox}?,
	alpha: number,
	id: number,
	fallback: Hitbox
): CFrame
	local anchor = centerHitboxes[id]
	if not anchor then
		return fallback.cframe
	end

	if not blendHitboxes then
		return anchor.cframe
	end

	local other = blendHitboxes[id]
	if not other then
		return anchor.cframe
	end

	return anchor.cframe:Lerp(other.cframe, alpha)
end

local function collides(hitbox: Hitbox, hitboxCFrame: CFrame, cframe: CFrame, shape: bolt.Shape): boolean
	if shape.type == shapeMap.BOX then
		return collision.box_box(hitboxCFrame, hitbox.shape, cframe, shape :: bolt.BoxShape)
	elseif shape.type == shapeMap.SPHERE then
		return collision.box_sphere(hitboxCFrame, hitbox.shape, cframe, shape :: bolt.SphereShape)
	elseif shape.type == shapeMap.CAPSULE then
		return collision.box_capsule(hitboxCFrame, hitbox.shape, cframe, shape :: bolt.CapsuleShape)
	end

	return gjk.intersects(hitboxCFrame, hitbox.shape, cframe, shape, GJK_TOLERANCE)
end

function HistoryQueries.create(bindSlot: BindSlot, unbindSlot: UnbindSlot): Queries
	local Queries = {}

	function Queries.QueryRaycast(self: State, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, rayOrigin: Vector3, rayDirection: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?): (Hitbox?, Vector3?, number?, Vector3?)
		local playerName = player.Name
		local filter = QueryFilter.resolve(params)
		--the querying player's own hitboxes are the other half of a merged result, never both
		local wantOwned = ownedOnly == true
		local invLength = fractionScale(rayDirection)

		local centerHitboxes = self.hitboxes[centerIndex]
		local blendHitboxes = if blendIndex then self.hitboxes[blendIndex] else nil

		local bestDistance = math.huge
		local bestHitbox: Hitbox? = nil
		local bestCFrame: CFrame? = nil
		local bestPoint: Vector3? = nil
		local bestNormal: Vector3? = nil
		local bestOffset = 0

		local function queryFrame(index: number, offset: number)
			local tree = bindSlot(self, index)
			if not tree then
				return
			end

			local frameHitboxes = self.hitboxes[index]
			--anything the cast reaches after the current best is pruned before its narrow phase runs
			local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

			tree:query_ray_closest(rayOrigin, rayDirection, function(id: number): number?
				local hitbox = frameHitboxes[id]
				if not hitbox or (hitbox.owner == playerName) ~= wantOwned or QueryFilter.rejects(filter, hitbox) or (check and not check(hitbox.instance)) then
					return nil
				end

				--the slot decides candidacy, the rewind time decides the pose
				local posed = posedCFrame(centerHitboxes, blendHitboxes, blendAlpha, id, hitbox)
				local hitPoint, distance, hitNormal = bolt.raycast.box(rayOrigin, rayDirection, posed, hitbox.shape)
				if distance == nil then
					return nil
				end

				if distance < bestDistance then
					bestDistance = distance
					bestHitbox = hitbox
					bestCFrame = posed
					bestPoint = hitPoint
					bestNormal = hitNormal
					bestOffset = offset
				end

				return distance * invLength
			end, maxFraction)

			unbindSlot(self)
		end

		--the bracketing pair describes one instant, so both halves are resolved before widening
		queryFrame(centerIndex, 0)
		if blendIndex then
			queryFrame(blendIndex, 0)
		end

		if not (PREFER_NEAREST_FRAME and bestHitbox) then
			for absOffset = 1, frameRange do
				queryFrame(wrapIndex(centerIndex - absOffset, self.frameCap), -absOffset)
				queryFrame(wrapIndex(centerIndex + absOffset, self.frameCap), absOffset)

				if PREFER_NEAREST_FRAME and bestHitbox then
					break
				end
			end
		end

		if not bestHitbox then
			return nil, nil, nil, nil
		end

		local resultHitbox = table.clone(bestHitbox :: Hitbox)
		resultHitbox.frameOffset = bestOffset
		resultHitbox.cframe = bestCFrame :: CFrame

		return resultHitbox, bestPoint, bestDistance, bestNormal
	end

	function Queries.QueryShapecast(self: State, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?): (Hitbox?, Vector3?, number?, Vector3?)
		if direction.Magnitude < 1e-6 then
			return nil, nil, nil, nil
		end

		local playerName = player.Name
		local filter = QueryFilter.resolve(params)
		--the querying player's own hitboxes are the other half of a merged result, never both
		local wantOwned = ownedOnly == true
		local invLength = fractionScale(direction)

		local centerHitboxes = self.hitboxes[centerIndex]
		local blendHitboxes = if blendIndex then self.hitboxes[blendIndex] else nil

		local bestDistance = math.huge
		local bestHitbox: Hitbox? = nil
		local bestCFrame: CFrame? = nil
		local bestPoint: Vector3? = nil
		local bestNormal: Vector3? = nil
		local bestOffset = 0

		local function queryFrame(index: number, offset: number)
			local tree = bindSlot(self, index)
			if not tree then
				return
			end

			local frameHitboxes = self.hitboxes[index]
			local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

			tree:query_shapecast_closest(shape, cframe, direction, function(id: number): number?
				local hitbox = frameHitboxes[id]
				if not hitbox or (hitbox.owner == playerName) ~= wantOwned or QueryFilter.rejects(filter, hitbox) or (check and not check(hitbox.instance)) then
					return nil
				end

				local posed = posedCFrame(centerHitboxes, blendHitboxes, blendAlpha, id, hitbox)
				local hitPoint, distance, hitNormal = gjk.shapecast(cframe, direction, shape, posed, hitbox.shape, GJK_TOLERANCE)
				if distance == nil then
					return nil
				end

				if distance < bestDistance then
					bestDistance = distance
					bestHitbox = hitbox
					bestCFrame = posed
					bestPoint = hitPoint
					bestNormal = hitNormal
					bestOffset = offset
				end

				return distance * invLength
			end, maxFraction)

			unbindSlot(self)
		end

		queryFrame(centerIndex, 0)
		if blendIndex then
			queryFrame(blendIndex, 0)
		end

		if not (PREFER_NEAREST_FRAME and bestHitbox) then
			for absOffset = 1, frameRange do
				queryFrame(wrapIndex(centerIndex - absOffset, self.frameCap), -absOffset)
				queryFrame(wrapIndex(centerIndex + absOffset, self.frameCap), absOffset)

				if PREFER_NEAREST_FRAME and bestHitbox then
					break
				end
			end
		end

		if not bestHitbox then
			return nil, nil, nil, nil
		end

		local resultHitbox = table.clone(bestHitbox :: Hitbox)
		resultHitbox.frameOffset = bestOffset
		resultHitbox.cframe = bestCFrame :: CFrame

		return resultHitbox, bestPoint, bestDistance, bestNormal
	end

	function Queries.QuerySimpleShapecast(self: State, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, direction: Vector3, params: RaycastParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?): (Hitbox?, number?)
		if direction.Magnitude < 1e-6 then
			return nil, nil
		end

		local playerName = player.Name
		local filter = QueryFilter.resolve(params)
		--the querying player's own hitboxes are the other half of a merged result, never both
		local wantOwned = ownedOnly == true
		local invLength = fractionScale(direction)

		local centerHitboxes = self.hitboxes[centerIndex]
		local blendHitboxes = if blendIndex then self.hitboxes[blendIndex] else nil

		local bestDistance = math.huge
		local bestHitbox: Hitbox? = nil
		local bestCFrame: CFrame? = nil
		local bestOffset = 0

		local function queryFrame(index: number, offset: number)
			local tree = bindSlot(self, index)
			if not tree then
				return
			end

			local frameHitboxes = self.hitboxes[index]
			local maxFraction = if bestDistance < math.huge then bestDistance * invLength else nil

			tree:query_shapecast_closest(shape, cframe, direction, function(id: number): number?
				local hitbox = frameHitboxes[id]
				if not hitbox or (hitbox.owner == playerName) ~= wantOwned or QueryFilter.rejects(filter, hitbox) or (check and not check(hitbox.instance)) then
					return nil
				end

				local posed = posedCFrame(centerHitboxes, blendHitboxes, blendAlpha, id, hitbox)
				local hit, distance = gjk.shapecast_simple(cframe, direction, shape, posed, hitbox.shape, GJK_TOLERANCE)
				if not hit or distance == nil then
					return nil
				end

				if distance < bestDistance then
					bestDistance = distance
					bestHitbox = hitbox
					bestCFrame = posed
					bestOffset = offset
				end

				return distance * invLength
			end, maxFraction)

			unbindSlot(self)
		end

		queryFrame(centerIndex, 0)
		if blendIndex then
			queryFrame(blendIndex, 0)
		end

		if not (PREFER_NEAREST_FRAME and bestHitbox) then
			for absOffset = 1, frameRange do
				queryFrame(wrapIndex(centerIndex - absOffset, self.frameCap), -absOffset)
				queryFrame(wrapIndex(centerIndex + absOffset, self.frameCap), absOffset)

				if PREFER_NEAREST_FRAME and bestHitbox then
					break
				end
			end
		end

		if not bestHitbox then
			return nil, nil
		end

		local resultHitbox = table.clone(bestHitbox :: Hitbox)
		resultHitbox.frameOffset = bestOffset
		resultHitbox.cframe = bestCFrame :: CFrame

		return resultHitbox, bestDistance
	end

	function Queries.QueryShape(self: State, player: Player, centerIndex: number, blendIndex: number?, blendAlpha: number, frameRange: number, cframe: CFrame, shape: bolt.Shape, params: OverlapParams?, check: ((BasePart) -> boolean)?, ownedOnly: boolean?): {[BasePart]: Hitbox}
		local playerName = player.Name
		local filter = QueryFilter.resolve(params)
		--the querying player's own hitboxes are the other half of a merged result, never both
		local wantOwned = ownedOnly == true
		local results: {[BasePart]: Hitbox} = {}
		local partCount = 0
		local maxParts = (params and params.MaxParts) or math.huge
		maxParts = if maxParts <= 0 then math.huge else maxParts

		local centerHitboxes = self.hitboxes[centerIndex]
		local blendHitboxes = if blendIndex then self.hitboxes[blendIndex] else nil

		local function queryFrame(index: number, offset: number)
			local tree = bindSlot(self, index)
			if not tree then
				return
			end

			local frameHitboxes = self.hitboxes[index]
			for _, id in tree:query_shape(cframe, shape) do
				local hitbox = frameHitboxes[id]
				if not hitbox or (hitbox.owner == playerName) ~= wantOwned or QueryFilter.rejects(filter, hitbox) or (check and not check(hitbox.instance)) then
					continue
				end

				local posed = posedCFrame(centerHitboxes, blendHitboxes, blendAlpha, id, hitbox)
				if not collides(hitbox, posed, cframe, shape) then
					continue
				end

				local previous = results[hitbox.instance]
				if not previous then
					if partCount >= maxParts then
						continue
					end
					partCount += 1
				end

				if not previous or math.abs(offset) < math.abs(previous.frameOffset) then
					local resultHitbox = table.clone(hitbox)
					resultHitbox.frameOffset = offset
					resultHitbox.cframe = posed
					results[hitbox.instance] = resultHitbox
				end
			end

			unbindSlot(self)
		end

		queryFrame(centerIndex, 0)
		if blendIndex then
			queryFrame(blendIndex, 0)
		end

		for absOffset = 1, frameRange do
			queryFrame(wrapIndex(centerIndex - absOffset, self.frameCap), -absOffset)
			queryFrame(wrapIndex(centerIndex + absOffset, self.frameCap), absOffset)
		end

		return results
	end

	return Queries
end

return HistoryQueries
