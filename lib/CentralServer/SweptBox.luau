--!native
--!strict
--!optimize 2
--[[
	Closed-form swept tests against an oriented box.

	Every historical hitbox is a box - they are only ever built by `bolt.create_box` - and the
	cast shape comes from `create_from_part`, which refuses meshes and unions. So every narrow
	phase test a shapecast query runs is some primitive swept against an OBB, yet all of them go
	through `gjk.shapecast`, whose conservative-advancement loop costs 3-8 iterations of support
	mapping. That is affordable when a hit bounds the search and prunes everything behind it, and
	it is what makes a shapecast that *misses* an order of magnitude dearer than one that hits:
	nothing establishes the bound, so every broad phase candidate pays the full loop.

	The routines here answer the same question in closed form, and return exactly what the gjk
	entry points return so callers need no new branches:

	  full   -> (world contact point on the box, distance in studs, outward world normal on the
	            box), or nil, nil, nil on a miss
	  simple -> (hit, distance in studs), or false, nil

	They deliberately do not cover every case. A sweep that starts already overlapping, and any
	shape carrying a collision margin, are handed back to gjk: both are rare on the query path and
	both are where matching gjk's witness-point choice exactly is hardest. A cast shape with no
	specialization resolves to the gjk entry point itself, so a caller holds one routine either
	way and never branches.

	This module lives outside lib/bolt so the vendored tree stays a clean drop-in for upstream
	updates.
]]

local bolt = require(script.Parent.Parent.bolt)
local shapeMap = require(script.Parent.Parent.bolt.shape_map)

local gjk = bolt.dispatch.gjk

local SweptBox = {}

export type Full = (CFrame, Vector3, any, CFrame, any, number) -> (Vector3?, number?, Vector3?)
export type Simple = (CFrame, Vector3, any, CFrame, any, number) -> (boolean, number?)

--the gjk entries are generic in both shape parameters; pinned here to the one signature the
--specializations share, so a caller can hold either behind a single type
local gjkFull: Full = gjk.shapecast :: any
local gjkSimple: Simple = gjk.shapecast_simple :: any

--a shape only reaches the closed forms if it is the plain primitive they solve for. anything
--carrying a margin is a rounded shape and belongs to gjk.
local function hasMargin(shape: any): boolean
	local m = shape.margin
	return m ~= nil and m > 0
end

--the sphere's centre at the moment it first touches the box, as a fraction of the sweep.
--
--the centres in contact with a box form that box grown by the radius: faces pushed out by r,
--quarter-cylinders along the twelve edges, eighth-spheres at the eight corners. So this is a ray
--against that rounded box, and the answer is the earliest entry over its features.
--
--picking one feature from where the ray enters the (h + r) bounding box is not enough, and that
--is worth spelling out because it looks like it should be: a sweep can enter the bounding box
--beside an edge, miss that edge's cylinder, and still touch a face further along - and a cylinder
--is infinite while the edge it stands for is not, so an unchecked solve reports contacts past the
--end of the edge that belong to a corner. Each feature here is solved and then validated against
--its own extent, and the earliest survivor wins.
--
--returns the fraction, or nil for a miss. `startsInside` reports the case this cannot answer.
local function sweepFraction(
	c0x: number, c0y: number, c0z: number,
	dx: number, dy: number, dz: number,
	r: number,
	hx: number, hy: number, hz: number
): (number?, boolean)
	--already touching at t = 0: gjk reports lambda 0 with a zero normal, and picks its contact
	--point off the simplex. Not worth reproducing here.
	local qx = if c0x < -hx then -hx elseif c0x > hx then hx else c0x
	local qy = if c0y < -hy then -hy elseif c0y > hy then hy else c0y
	local qz = if c0z < -hz then -hz elseif c0z > hz then hz else c0z
	local ex, ey, ez = c0x - qx, c0y - qy, c0z - qz
	if ex * ex + ey * ey + ez * ez <= r * r then
		return nil, true
	end

	--cheap reject: the whole sweep has to reach the grown box at all
	local ehx, ehy, ehz = hx + r, hy + r, hz + r
	local lo, hi = 0, 1
	if dx ~= 0 then
		local inv = 1 / dx
		local ta, tb = (-ehx - c0x) * inv, (ehx - c0x) * inv
		lo = math.max(lo, math.min(ta, tb))
		hi = math.min(hi, math.max(ta, tb))
	elseif c0x < -ehx or c0x > ehx then
		return nil, false
	end
	if dy ~= 0 then
		local inv = 1 / dy
		local ta, tb = (-ehy - c0y) * inv, (ehy - c0y) * inv
		lo = math.max(lo, math.min(ta, tb))
		hi = math.min(hi, math.max(ta, tb))
	elseif c0y < -ehy or c0y > ehy then
		return nil, false
	end
	if dz ~= 0 then
		local inv = 1 / dz
		local ta, tb = (-ehz - c0z) * inv, (ehz - c0z) * inv
		lo = math.max(lo, math.min(ta, tb))
		hi = math.min(hi, math.max(ta, tb))
	elseif c0z < -ehz or c0z > ehz then
		return nil, false
	end
	if lo > hi then
		return nil, false
	end

	local best = math.huge
	local rr = r * r

	--faces: the sphere centre reaches the plane offset by r while staying over the face
	local function face(c0i: number, di: number, ei: number, hi_: number,
		c0j: number, dj: number, hj: number, c0k: number, dk: number, hk: number)
		if di == 0 then
			return
		end
		local plane = if di > 0 then -ei else ei
		local t = (plane - c0i) / di
		if t < 0 or t > 1 or t >= best then
			return
		end
		local pj = c0j + dj * t
		if pj < -hj or pj > hj then
			return
		end
		local pk = c0k + dk * t
		if pk < -hk or pk > hk then
			return
		end
		best = t
	end

	face(c0x, dx, ehx, hx, c0y, dy, hy, c0z, dz, hz)
	face(c0y, dy, ehy, hy, c0x, dx, hx, c0z, dz, hz)
	face(c0z, dz, ehz, hz, c0x, dx, hx, c0y, dy, hy)

	--solves |A + t*B|^2 = r^2 and returns the entry root, or nil
	local function entryRoot(a1: number, b1: number, a2: number, b2: number, a3: number, b3: number): number?
		local a = b1 * b1 + b2 * b2 + b3 * b3
		if a <= 0 then
			return nil
		end
		local b = a1 * b1 + a2 * b2 + a3 * b3
		local c = a1 * a1 + a2 * a2 + a3 * a3 - rr
		local disc = b * b - a * c
		if disc < 0 then
			return nil
		end
		return (-b - math.sqrt(disc)) / a
	end

	--edges: a cylinder of radius r about the edge line, valid only along the edge's own extent
	local function edge(cf: number, df: number, hf: number,
		c1: number, d1: number, e1: number, c2: number, d2: number, e2: number)
		local t = entryRoot(c1 - e1, d1, c2 - e2, d2, 0, 0)
		if t == nil or t < 0 or t > 1 or t >= best then
			return
		end
		local pf = cf + df * t
		if pf < -hf or pf > hf then
			return
		end
		best = t
	end

	for _, sj in {-1, 1} do
		for _, sk in {-1, 1} do
			edge(c0x, dx, hx, c0y, dy, sj * hy, c0z, dz, sk * hz)
			edge(c0y, dy, hy, c0x, dx, sj * hx, c0z, dz, sk * hz)
			edge(c0z, dz, hz, c0x, dx, sj * hx, c0y, dy, sk * hy)
		end
	end

	--corners: a sphere of radius r at the corner, valid everywhere it is hit
	for _, sx in {-1, 1} do
		for _, sy in {-1, 1} do
			for _, sz in {-1, 1} do
				local t = entryRoot(c0x - sx * hx, dx, c0y - sy * hy, dy, c0z - sz * hz, dz)
				if t ~= nil and t >= 0 and t <= 1 and t < best then
					best = t
				end
			end
		end
	end

	if best == math.huge then
		return nil, false
	end

	return best, false
end

--swept sphere against an oriented box, matching gjk.shapecast
function SweptBox.sphere(castCFrame: CFrame, direction: Vector3, castShape: any, boxCFrame: CFrame, boxShape: any, tolerance: number): (Vector3?, number?, Vector3?)
	if hasMargin(castShape) or hasMargin(boxShape) then
		return gjkFull(castCFrame, direction, castShape, boxCFrame, boxShape, tolerance)
	end

	local c0 = boxCFrame:PointToObjectSpace(castCFrame.Position)
	local d = boxCFrame:VectorToObjectSpace(direction)
	local h = boxShape.half_extents
	local r = castShape.radius

	local t, startsInside = sweepFraction(c0.X, c0.Y, c0.Z, d.X, d.Y, d.Z, r, h.X, h.Y, h.Z)
	if startsInside then
		return gjkFull(castCFrame, direction, castShape, boxCFrame, boxShape, tolerance)
	end
	if t == nil then
		return nil, nil, nil
	end

	--the contact point is where the box is closest to the sphere's centre at impact, and the
	--normal points from there back out to that centre, which is gjk's outward-on-b convention
	local cx, cy, cz = c0.X + d.X * t, c0.Y + d.Y * t, c0.Z + d.Z * t
	local hx, hy, hz = h.X, h.Y, h.Z
	local qx = if cx < -hx then -hx elseif cx > hx then hx else cx
	local qy = if cy < -hy then -hy elseif cy > hy then hy else cy
	local qz = if cz < -hz then -hz elseif cz > hz then hz else cz

	local nx, ny, nz = cx - qx, cy - qy, cz - qz
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)
	local normal = if len > 0
		then boxCFrame:VectorToWorldSpace(Vector3.new(nx / len, ny / len, nz / len))
		else Vector3.zero

	return boxCFrame:PointToWorldSpace(Vector3.new(qx, qy, qz)), t * direction.Magnitude, normal
end

--swept sphere against an oriented box, matching gjk.shapecast_simple
function SweptBox.sphereSimple(castCFrame: CFrame, direction: Vector3, castShape: any, boxCFrame: CFrame, boxShape: any, tolerance: number): (boolean, number?)
	if hasMargin(castShape) or hasMargin(boxShape) then
		return gjkSimple(castCFrame, direction, castShape, boxCFrame, boxShape, tolerance)
	end

	local c0 = boxCFrame:PointToObjectSpace(castCFrame.Position)
	local d = boxCFrame:VectorToObjectSpace(direction)
	local h = boxShape.half_extents

	local t, startsInside = sweepFraction(c0.X, c0.Y, c0.Z, d.X, d.Y, d.Z, castShape.radius, h.X, h.Y, h.Z)
	if startsInside then
		return gjkSimple(castCFrame, direction, castShape, boxCFrame, boxShape, tolerance)
	end
	if t == nil then
		return false, nil
	end

	return true, t * direction.Magnitude
end

--the cast shape is fixed for a whole query and the hitbox is always a box, so a caller resolves
--the routine once at the top of a query rather than once per candidate. an unspecialized shape
--resolves to the gjk entry point itself, so the caller never needs a branch of its own.
function SweptBox.resolveFull(shapeType: number): Full
	if shapeType == shapeMap.SPHERE then
		return SweptBox.sphere
	end

	return gjkFull
end

function SweptBox.resolveSimple(shapeType: number): Simple
	if shapeType == shapeMap.SPHERE then
		return SweptBox.sphereSimple
	end

	return gjkSimple
end

return SweptBox
