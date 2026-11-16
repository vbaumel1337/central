--!strict
-- Reusable benchmark harness for HistoricalHitboxes-shaped implementations. Two things live
-- here:
--   Benchmark.Run       -- focused UpdateFrame/query comparison of two implementations at a few hitbox counts
--   Benchmark.RunSheets -- the full hitboxCount x queryCount "% of server CPU" matrix, split by
--                          query kind (Raycast / SimpleShapecast) and by whether the cast
--                          connects
-- Pure module: dependencies (and, for RunSheets, an Adapter per implementation under test) are
-- passed in rather than required by a fixed path -- same portability convention as
-- tests/DifferentialHarness.luau. Kept in the repo (not thrown away after one use) so future
-- perf work has a ready-made comparison tool; see RunBenchmarkSheets.luau in a consumer project
-- for a runnable example wiring this up against the vendored package.
--
-- TWO THINGS THIS HARNESS LEARNED THE HARD WAY, both of which quietly corrupt results:
--
-- 1. Part motion must stay OUTSIDE the timed region. An earlier version timed a step() that
--    moved every part and *then* called UpdateFrame, so the "0 queries" column measured
--    moveAll + UpdateFrame. moveAll costs about as much as Ref's entire UpdateFrame at 100
--    hitboxes, and it is identical work for both implementations, so including it dragged every
--    ratio toward 1.0 -- it reported a 1.26x UpdateFrame speedup where the true figure was
--    1.70x. Timing is now per-frame around UpdateFrame + queries only.
--
-- 2. Only the FIRST sheet run in a Play session is trustworthy. A second run in the same session
--    has been observed reporting Ref's own SimpleShapecast cell at 155% against 22% in run one,
--    with both implementations inflated together. Restart the session between runs.
--
-- A cheap self-check for (2): with motion hoisted out, the queryCount=0 column is now purely
-- UpdateFrame, so it should match a standalone UpdateFrame measurement at the same hitbox count.
-- If it doesn't, the session is polluted and the whole sheet should be thrown away.
-- One HistoricalHitboxes-shaped implementation under test: how deep its ring is, and how to build
-- a fresh instance. Every implementation shares the AddPart/UpdateFrame/Query* surface, so this is
-- all the harness needs to know to drive one.
export type Implementation = {
	name: string,
	frameCap: number,
	new: () -> any,
}

export type Deps = {
	PartRegister: any,
	ref: Implementation,
	new: Implementation,
	hitboxCounts: {number},
	warmupFrames: number,
	measureFrames: number,
	raycastSamples: number,
	parentFolder: Instance,
}

export type CellResult = {
	hitboxCount: number,
	refUpdateFrameUs: number,
	refPerHitboxUs: number,
	newUpdateFrameUs: number,
	newPerHitboxUs: number,
	updateFrameSpeedup: number, -- ref / new
	refRaycastUs: number,
	newRaycastUs: number,
}

-- An Adapter wraps one HistoricalHitboxes-shaped implementation behind a uniform interface, so
-- RunSheets can drive every implementation through the same matrix logic.
export type Adapter = {
	name: string,
	frameCap: number,
	new: () -> any,
	addPart: (hh: any, register: any) -> (),
	updateFrame: (hh: any, index: number) -> (),
	queryRaycast: (hh: any, index: number, origin: Vector3, direction: Vector3) -> (),
	querySimpleShapecast: (hh: any, index: number, cframe: CFrame, shape: any, direction: Vector3) -> (),
	-- returns whether a raycast along this geometry finds anything; used to assert that the
	-- "hit" case really hits and the "miss" case really misses before anything is timed
	probeRaycast: (hh: any, index: number, origin: Vector3, direction: Vector3) -> boolean,
	destroy: (hh: any) -> (),
}

-- Whether the cast connects turns out to be the axis that separates these two implementations,
-- so it is a first-class dimension rather than an accident of the geometry:
--   * a HIT bounds the search, so PREFER_NEAREST_FRAME stops after the first frame and exactly
--     one tree is walked. This is where union hitboxes pay for fatter leaves.
--   * a MISS has to resolve every offset in frameRange, which is where sharing a tree across
--     frames wins: Ref walks (2*frameRange + 1) distinct trees, a shared tree is walked once.
-- Measuring only one of them (the old sheet aimed every cast at a part) hides half the story.
export type Case = "rayHit" | "rayMiss" | "shapeHit" | "shapeMiss"

local CASES: {Case} = {"rayHit", "rayMiss", "shapeHit", "shapeMiss"}

export type SheetDeps = {
	PartRegister: any,
	hitboxCounts: {number},
	queryCounts: {number},
	warmupFrames: number,
	framesPerBatch: number, -- frames timed per batch
	numBatches: number, -- odd is best; a cell's value is the MEDIAN batch, not the mean -- an
	-- incremental GC pause landing inside one batch inflates that batch alone, and taking the
	-- mean over one long run lets a single such pause skew the whole cell. Several short batches
	-- plus a median throws the unlucky one out instead of averaging it in.
	stepBudgetUs: number, -- 16667 at Hz60; cell value is measured-cost / this, as a percentage
	timeoutMultiple: number, -- abort a cell (and every costlier cell in its row) past this many step budgets
	parentFolder: Instance,
}

export type Sheet = {
	adapterName: string,
	queryKind: string,
	case: Case,
	hitboxCounts: {number},
	queryCounts: {number},
	-- cellsPct[hitboxCount][queryCount] -> percent of stepBudgetUs, or "over" if aborted
	cellsPct: {[number]: {[number]: number | string}},
}

local Benchmark = {}

local SPACING = 7 -- studs; matches the README's original methodology
local RAY_LENGTH = 200 -- studs; matches LasergunManager's RAYCAST_DISTANCE

local function buildGrid(count: number, parentFolder: Instance): {BasePart}
	local parts = {}
	if count <= 0 then
		return parts
	end
	local side = math.ceil(count ^ (1 / 3))
	local i = 0
	for x = 1, side do
		for y = 1, side do
			for z = 1, side do
				i += 1
				if i > count then
					return parts
				end
				local p = Instance.new("Part")
				p.Name = "Bench" .. i
				p.Anchored = true
				p.CanCollide = true
				p.Size = Vector3.new(2, 2, 2)
				p.CFrame = CFrame.new(x * SPACING, 3000 + y * SPACING, z * SPACING)
				p.Parent = parentFolder
				table.insert(parts, p)
			end
		end
	end
	return parts
end

-- Y is overwritten rather than offset, so every part in an (x, z) column collapses into the same
-- 32-stud band and only its phase differs. X and Z never change, which is what lets the miss
-- geometry below sit in a guaranteed-empty lane.
local function moveAll(parts: {BasePart}, t: number)
	for i, p in parts do
		local base = p.CFrame.Position
		p.CFrame = CFrame.new(base.X, 3000 + math.sin(t + i) * 16, base.Z)
	end
end

local function median(values: {number}): number
	table.sort(values)
	local n = #values
	if n % 2 == 1 then
		return values[(n + 1) // 2]
	end
	return (values[n // 2] + values[n // 2 + 1]) / 2
end

-- `work` advances the world untimed and returns the microseconds its timed region took. Runs it
-- in `numBatches` separate batches of `framesPerBatch` frames and returns the median per-frame
-- cost across batches -- see the numBatches doc comment on SheetDeps for why median-of-batches.
local function measureBatched(work: () -> number, numBatches: number, framesPerBatch: number): number
	local batchUs = table.create(numBatches)
	for b = 1, numBatches do
		local total = 0
		for _ = 1, framesPerBatch do
			total += work()
		end
		batchUs[b] = total / framesPerBatch
	end
	return median(batchUs)
end

function Benchmark.Run(deps: Deps): {CellResult}
	local results: {CellResult} = {}

	for _, count in deps.hitboxCounts do
		local folder = Instance.new("Folder")
		folder.Name = "BenchmarkParts_" .. count
		folder.Parent = deps.parentFolder

		local parts = buildGrid(count, folder)

		-- ---- Ref ----
		local refFrameCap = deps.ref.frameCap
		local refHH = deps.ref.new()
		local refRegs = {}
		for i, p in parts do
			refRegs[i] = deps.PartRegister.new(p, refFrameCap)
			refHH:AddPart(refRegs[i])
		end

		local refIndex = 0
		for f = 1, deps.warmupFrames do
			moveAll(parts, f * 0.05)
			refIndex = (refIndex % refFrameCap) + 1
			refHH:UpdateFrame(refIndex)
		end

		--motion stays outside the accumulator; see the header note
		local refTotal = 0
		for f = 1, deps.measureFrames do
			moveAll(parts, (deps.warmupFrames + f) * 0.05)
			refIndex = (refIndex % refFrameCap) + 1
			local t0 = os.clock()
			refHH:UpdateFrame(refIndex)
			refTotal += (os.clock() - t0)
		end
		local refUpdateFrameUs = refTotal / deps.measureFrames * 1e6

		local rayOrigin = Vector3.new(SPACING * 0.5, 3000, SPACING * 0.5)
		local rayDir = (parts[math.max(1, #parts // 2)].Position - rayOrigin)
		local dummyPlayer = {Name = "__BenchProbe__"} :: any
		local t1 = os.clock()
		for _ = 1, deps.raycastSamples do
			refHH:QueryRaycast(dummyPlayer, refIndex, 1, rayOrigin, rayDir)
		end
		local refRaycastUs = (os.clock() - t1) / deps.raycastSamples * 1e6

		refHH:Destroy()

		-- ---- New ----
		local newHH = deps.new.new()
		local newFrameCap = deps.new.frameCap
		local newRegs = {}
		for i, p in parts do
			newRegs[i] = deps.PartRegister.new(p, newFrameCap)
			newHH:AddPart(newRegs[i])
		end

		local newIndex = 0
		for f = 1, deps.warmupFrames do
			moveAll(parts, f * 0.05)
			newIndex = (newIndex % newFrameCap) + 1
			newHH:UpdateFrame(newIndex)
		end

		local newTotal = 0
		for f = 1, deps.measureFrames do
			moveAll(parts, (deps.warmupFrames + f) * 0.05)
			newIndex = (newIndex % newFrameCap) + 1
			local t0 = os.clock()
			newHH:UpdateFrame(newIndex)
			newTotal += (os.clock() - t0)
		end
		local newUpdateFrameUs = newTotal / deps.measureFrames * 1e6

		local t3 = os.clock()
		for _ = 1, deps.raycastSamples do
			newHH:QueryRaycast(dummyPlayer, newIndex, 1, rayOrigin, rayDir)
		end
		local newRaycastUs = (os.clock() - t3) / deps.raycastSamples * 1e6

		newHH:Destroy()
		folder:Destroy()

		table.insert(results, {
			hitboxCount = count,
			refUpdateFrameUs = refUpdateFrameUs,
			refPerHitboxUs = refUpdateFrameUs / count,
			newUpdateFrameUs = newUpdateFrameUs,
			newPerHitboxUs = newUpdateFrameUs / count,
			updateFrameSpeedup = refUpdateFrameUs / newUpdateFrameUs,
			refRaycastUs = refRaycastUs,
			newRaycastUs = newRaycastUs,
		})
	end

	return results
end

export type RowResult = {[Case]: {[number]: number | string}}

-- Measures one row (every queryCount, every case) for one adapter at one hitboxCount.
-- Split out of RunSheets so multiple adapters can be interleaved row-by-row -- see RunSheets'
-- doc comment for why that ordering matters.
local function runRow(adapter: Adapter, hitboxCount: number, deps: SheetDeps, boxShape: any): (RowResult, {string})
	local rows: RowResult = {}
	local notes: {string} = {}
	for _, case in CASES do
		rows[case] = {}
	end

	local folder = Instance.new("Folder")
	folder.Name = "SheetParts_" .. adapter.name .. "_" .. hitboxCount
	folder.Parent = deps.parentFolder

	local parts = buildGrid(hitboxCount, folder)
	local hh = adapter.new()

	-- Stagger registration across a full ring rotation instead of adding every part on frame 1.
	-- Parts added together can share a phase forever (an implementation that does periodic
	-- per-part work would do all of it on the exact same frame), which is both unrealistic (a
	-- real game's hitboxes appear at staggered times: players spawning, projectiles firing) and
	-- creates a synchronized cost spike that skews a short measurement window depending on pure
	-- luck of where it lands relative to that spike.
	local partsPerFrame = math.max(1, math.ceil(#parts / adapter.frameCap))
	local nextToAdd = 1

	local index = 0
	local t = 0
	--advances the world; deliberately NOT timed (see the header note on moveAll)
	local function advance()
		if #parts > 0 then
			moveAll(parts, t)
		end
		t += 0.05
		index = (index % adapter.frameCap) + 1
		for _ = 1, partsPerFrame do
			if nextToAdd > #parts then
				break
			end
			adapter.addPart(hh, deps.PartRegister.new(parts[nextToAdd], adapter.frameCap))
			nextToAdd += 1
		end
	end

	for _ = 1, deps.warmupFrames do
		advance()
		adapter.updateFrame(hh, index)
	end

	local hitOrigin = Vector3.new(SPACING * 0.5, 3000, SPACING * 0.5)
	local hitDir = if #parts > 0
		then (parts[math.max(1, #parts // 2)].Position - hitOrigin).Unit * RAY_LENGTH
		else Vector3.new(RAY_LENGTH, 0, 0)

	-- A miss that has to actually traverse the tree, not one the root AABB rejects outright.
	-- Parts never move in X or Z, so the half-spacing lane between columns is empty forever;
	-- casting straight up it crosses the whole cluster's height and connects with nothing.
	local side = math.max(1, math.ceil(math.max(hitboxCount, 1) ^ (1 / 3)))
	local lane = math.max(1, side // 2) * SPACING + SPACING * 0.5
	local missOrigin = Vector3.new(lane, 2900, lane)
	local missDir = Vector3.new(0, 400, 0)

	-- assert the two cases are what they claim before anything is timed; a "miss" that quietly
	-- starts hitting (or vice versa) would silently turn the sheet into two copies of one case
	if hitboxCount > 0 then
		if not adapter.probeRaycast(hh, index, hitOrigin, hitDir) then
			table.insert(notes, ("%s@%d: HIT geometry did not connect"):format(adapter.name, hitboxCount))
		end
		if adapter.probeRaycast(hh, index, missOrigin, missDir) then
			table.insert(notes, ("%s@%d: MISS geometry connected"):format(adapter.name, hitboxCount))
		end
	end

	local hitCF, missCF = CFrame.new(hitOrigin), CFrame.new(missOrigin)
	local abortBudget = deps.stepBudgetUs * deps.timeoutMultiple
	local aborted: {[Case]: boolean} = {}

	for _, queryCount in deps.queryCounts do
		for _, case in CASES do
			if aborted[case] then
				rows[case][queryCount] = "over"
				continue
			end

			local perFrameUs = measureBatched(function(): number
				advance()
				local t0 = os.clock()
				adapter.updateFrame(hh, index)
				if case == "rayHit" then
					for _ = 1, queryCount do adapter.queryRaycast(hh, index, hitOrigin, hitDir) end
				elseif case == "rayMiss" then
					for _ = 1, queryCount do adapter.queryRaycast(hh, index, missOrigin, missDir) end
				elseif case == "shapeHit" then
					for _ = 1, queryCount do adapter.querySimpleShapecast(hh, index, hitCF, boxShape, hitDir) end
				else
					for _ = 1, queryCount do adapter.querySimpleShapecast(hh, index, missCF, boxShape, missDir) end
				end
				return (os.clock() - t0) * 1e6
			end, deps.numBatches, deps.framesPerBatch)

			if perFrameUs > abortBudget then
				aborted[case] = true
				rows[case][queryCount] = "over"
			else
				rows[case][queryCount] = perFrameUs / deps.stepBudgetUs * 100
			end
		end
	end

	adapter.destroy(hh)
	folder:Destroy()

	return rows, notes
end

export type SheetSet = {
	sheets: {Sheet},
	notes: {string},
}

-- Builds a sheet per (adapter, case) for every adapter given, measured with rows interleaved
-- across adapters rather than running one adapter's whole sheet then the next's. Measuring
-- adapter A's complete sheet before adapter B's means B's every cell is timed after however much
-- GC pressure/heap fragmentation A's (often heavier) full run left behind -- a real, measured
-- effect in this harness, not a hypothetical one, and it systematically favors whichever adapter
-- goes first. Interleaving at the row level means both adapters hit each hitboxCount under
-- comparable accumulated session state.
--
-- Row 0 hitboxes isolates pure query overhead against empty trees; column 0 queries isolates
-- UpdateFrame (genuinely, now that motion is hoisted out of the timed region). Query counts
-- within a row are tried in increasing order; once one blows past stepBudgetUs * timeoutMultiple,
-- every costlier column in that row is recorded "over" without being attempted (query cost only
-- grows with count, so there's nothing to learn by trying).
function Benchmark.RunSheets(adapters: {Adapter}, deps: SheetDeps): {[string]: SheetSet}
	local boxShape = {type = 2 ^ 0, half_extents = Vector3.new(1, 1, 1)} -- shapeMap.BOX; avoids depending on bolt just for this

	local cells: {[string]: {[Case]: {[number]: {[number]: number | string}}}} = {}
	local notes: {[string]: {string}} = {}
	for _, adapter in adapters do
		cells[adapter.name] = {}
		notes[adapter.name] = {}
		for _, case in CASES do
			cells[adapter.name][case] = {}
		end
	end

	for _, hitboxCount in deps.hitboxCounts do
		for _, adapter in adapters do
			local row, rowNotes = runRow(adapter, hitboxCount, deps, boxShape)
			for _, case in CASES do
				cells[adapter.name][case][hitboxCount] = row[case]
			end
			for _, n in rowNotes do
				table.insert(notes[adapter.name], n)
			end
		end
	end

	local kindOf: {[Case]: string} = {
		rayHit = "Raycast (hit)",
		rayMiss = "Raycast (miss)",
		shapeHit = "SimpleShapecast (hit)",
		shapeMiss = "SimpleShapecast (miss)",
	}

	local result: {[string]: SheetSet} = {}
	for _, adapter in adapters do
		local sheets: {Sheet} = {}
		for _, case in CASES do
			table.insert(sheets, {
				adapterName = adapter.name,
				queryKind = kindOf[case],
				case = case,
				hitboxCounts = deps.hitboxCounts,
				queryCounts = deps.queryCounts,
				cellsPct = cells[adapter.name][case],
			})
		end
		result[adapter.name] = {sheets = sheets, notes = notes[adapter.name]}
	end
	return result
end

return Benchmark
