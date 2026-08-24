--!strict
-- Caches PhysicsService:CollisionGroupsAreCollidable results, so the hot narrow-phase
-- filter (isFilteredOut, called per query candidate) doesn't cross the C++ boundary
-- every time. Invalidated whenever group collidability can change.
local PhysicsService = game:GetService("PhysicsService")

local CollisionCache = {}

local cache: {[string]: {[string]: boolean}} = {}

function CollisionCache.IsCollidable(a: string, b: string): boolean
	local rowA = cache[a]
	local cached = rowA and rowA[b]
	if cached ~= nil then
		return cached
	end

	local result = PhysicsService:CollisionGroupsAreCollidable(a, b)

	if not rowA then
		rowA = {}
		cache[a] = rowA
	end
	rowA[b] = result

	local rowB = cache[b]
	if not rowB then
		rowB = {}
		cache[b] = rowB
	end
	rowB[a] = result

	return result
end

function CollisionCache.Invalidate()
	table.clear(cache)
end

return CollisionCache
