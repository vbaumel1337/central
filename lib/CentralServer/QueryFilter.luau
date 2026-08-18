--!native
--!strict
--!optimize 2
--[[
	Params resolved once per query instead of once per candidate.

	The filter used to run inside the narrow phase callback, so every broad phase candidate, in
	every frame in range, paid a PhysicsService:CollisionGroupsAreCollidable call plus an
	IsDescendantOf walk for each entry in ExcludeInstances. Those are C boundary crossings, and
	IsDescendantOf is O(depth).

	Neither answer depends on the candidate beyond its collision group and its instance, and a
	query sees the same parts over and over across frames, so both memoise. Steady state cost per
	candidate drops to two hash lookups.
]]
local PhysicsService = game:GetService("PhysicsService")

local Settings = require(script.Parent.Parent.Settings)

local DEFAULT_GROUP = Settings.DEFAULT_HITBOX_QUERY_GROUP

local QueryFilter = {}

--the fields of a Hitbox this module actually reads
export type Filterable = {
	instance: BasePart,
	canCollide: boolean,
	collisionGroup: string,
}

export type ResolvedFilter = {
	respectCanCollide: boolean,
	queryGroup: string,
	--collidability by the candidate's collision group. There are only ever a handful of groups,
	--so this converges after the first candidate or two.
	collidable: {[string]: boolean},
	exclude: {Instance}?,
	include: {Instance}?,
	--nil when neither list is set, which is the common case and skips the ancestry walk entirely
	ancestry: {[BasePart]: boolean}?,
}

--nil means "nothing to filter", so a query with no params allocates nothing at all
function QueryFilter.resolve(params: (RaycastParams | OverlapParams)?): ResolvedFilter?
	if not params then
		return nil
	end

	local exclude = params.ExcludeInstances :: {Instance}?
	if exclude and #exclude == 0 then
		exclude = nil
	end

	local include = params.IncludeInstances :: {Instance}?
	if include and #include == 0 then
		include = nil
	end

	local queryGroup = params.CollisionGroup or DEFAULT_GROUP
	local respectCanCollide = params.RespectCanCollide == true

	return {
		respectCanCollide = respectCanCollide,
		queryGroup = queryGroup,
		collidable = {},
		exclude = exclude,
		include = include,
		ancestry = if exclude or include then {} else nil,
	}
end

local function walkAncestry(filter: ResolvedFilter, part: BasePart): boolean
	local exclude = filter.exclude
	if exclude then
		for _, excluded in ipairs(exclude) do
			if part == excluded or part:IsDescendantOf(excluded) then
				return true
			end
		end
	end

	local include = filter.include
	if include then
		for _, included in ipairs(include) do
			if part == included or part:IsDescendantOf(included) then
				return false
			end
		end
		return true
	end

	return false
end

function QueryFilter.rejects(filter: ResolvedFilter?, hitbox: Filterable): boolean
	if not filter then
		return false
	end

	if filter.respectCanCollide and not hitbox.canCollide then
		return true
	end

	local group = hitbox.collisionGroup
	local collidable = filter.collidable
	local isCollidable = collidable[group]
	if isCollidable == nil then
		isCollidable = PhysicsService:CollisionGroupsAreCollidable(filter.queryGroup, group)
		collidable[group] = isCollidable
	end

	if not isCollidable then
		return true
	end

	local ancestry = filter.ancestry
	if not ancestry then
		return false
	end

	local part = hitbox.instance
	local cached = ancestry[part]
	if cached == nil then
		cached = walkAncestry(filter, part)
		ancestry[part] = cached
	end

	return cached
end

return QueryFilter
