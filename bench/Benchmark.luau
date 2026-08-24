--!strict
-- Reusable benchmark harness for HistoricalHitboxes-shaped implementations. Two things live
-- here:
--   Benchmark.Run       -- focused Ref-vs-New UpdateFrame/query comparison at a few hitbox counts
--   Benchmark.RunSheets -- the full hitboxCount x queryCount "% of server CPU" matrix from the
--                          design notes' step 4, for Raycast and SimpleShapecast
-- Pure module: dependencies (and, for RunSheets, an Adapter per implementation under test) are
-- passed in rather than required by a fixed path -- same portability convention as
-- tests/DifferentialHarness.luau. Kept in the repo (not thrown away after one use) so future
-- perf work has a ready-made comparison tool; see RunBenchmarkSheets.luau in a consumer project
-- for a runnable example wiring this up against the vendored package.
export type Deps = {
	bolt: any,
	PartRegister: any,
	HistoricalHitboxesRef: any,
	HistoricalHitboxesNew: any,
	refFrameCap: number,
	refPadding: number,
	newUnionsPerPart: number,
	newUnionSize: number,
	newPadding: number,
	newPredictionFrames: number,
	newUpdateFraction: number,
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
-- RunSheets can drive Ref and New (different .new() signatures) through the same matrix logic.
export type Adapter = {
	name: string,
	frameCap: number,
	new: () -> any,
	addPart: (hh: any, register: any) -> (),
	updateFrame: (hh: any, index: number) -> (),
	queryRaycast: (hh: any, index: number, origin: Vector3, direction: Vector3) -> (),
	querySimpleShapecast: (hh: any, index: number, cframe: CFrame, shape: any, direction: Vector3) -> (),
	destroy: (hh: any) -> (),
}

export type SheetDeps = {
	PartRegister: any,
	hitboxCounts: {number}, -- e.g. {0, 1, 10, 100, 1000}. The design notes suggest going up to
	-- 10000, but that crashed a live Studio session in practice (likely just the sheer Instance
	-- count -- 10000 real parts, built and torn down per adapter per hitboxCount row, on top of
	-- whatever else the place is running); if you want that row, try it in a disposable place.
	queryCounts: {number}, -- e.g. {0, 1, 10, 100, 1000}
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

-- runs `work` in `numBatches` separate timed batches of `framesPerBatch` calls each, and returns
-- the median per-call microsecond cost across batches -- see the numBatches doc comment on
-- SheetDeps for why median-of-batches instead of one long average.
local function measureBatched(work: () -> (), numBatches: number, framesPerBatch: number): number
	local batchUs = table.create(numBatches)
	for b = 1, numBatches do
		local t0 = os.clock()
		for _ = 1, framesPerBatch do
			work()
		end
		batchUs[b] = (os.clock() - t0) / framesPerBatch * 1e6
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
		local refHH = deps.HistoricalHitboxesRef.new(deps.refFrameCap, deps.refPadding)
		local refRegs = {}
		for i, p in parts do
			refRegs[i] = deps.PartRegister.new(p, deps.refFrameCap)
			refHH:AddPart(refRegs[i])
		end

		local refIndex = 0
		for f = 1, deps.warmupFrames do
			moveAll(parts, f * 0.05)
			refIndex = (refIndex % deps.refFrameCap) + 1
			refHH:UpdateFrame(refIndex)
		end

		local t0 = os.clock()
		for f = 1, deps.measureFrames do
			moveAll(parts, (deps.warmupFrames + f) * 0.05)
			refIndex = (refIndex % deps.refFrameCap) + 1
			refHH:UpdateFrame(refIndex)
		end
		local refUpdateFrameUs = (os.clock() - t0) / deps.measureFrames * 1e6

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
		local newHH = deps.HistoricalHitboxesNew.new(deps.newUnionsPerPart, deps.newUnionSize, deps.newPadding, deps.newPredictionFrames, deps.newUpdateFraction)
		local newFrameCap = deps.newUnionsPerPart * deps.newUnionSize
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

		local t2 = os.clock()
		for f = 1, deps.measureFrames do
			moveAll(parts, (deps.warmupFrames + f) * 0.05)
			newIndex = (newIndex % newFrameCap) + 1
			newHH:UpdateFrame(newIndex)
		end
		local newUpdateFrameUs = (os.clock() - t2) / deps.measureFrames * 1e6

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

-- Builds one (Raycast, SimpleShapecast) pair of sheets for a single adapter. Row 0 hitboxes
-- isolates pure query overhead against empty trees; column 0 queries isolates UpdateFrame.
-- Query counts within a row are tried in increasing order; once one blows past
-- stepBudgetUs * timeoutMultiple, every costlier column in that row is recorded "over" without
-- being attempted (query cost only grows with count, so there's nothing to learn by trying).
function Benchmark.RunSheets(adapter: Adapter, deps: SheetDeps): (Sheet, Sheet)
	local raycastCells: {[number]: {[number]: number | string}} = {}
	local shapecastCells: {[number]: {[number]: number | string}} = {}

	local boxShape = {type = 2 ^ 0, half_extents = Vector3.new(1, 1, 1)} -- shapeMap.BOX; avoids depending on bolt just for this

	for _, hitboxCount in deps.hitboxCounts do
		raycastCells[hitboxCount] = {}
		shapecastCells[hitboxCount] = {}

		local folder = Instance.new("Folder")
		folder.Name = "SheetParts_" .. adapter.name .. "_" .. hitboxCount
		folder.Parent = deps.parentFolder

		local parts = buildGrid(hitboxCount, folder)
		local hh = adapter.new()
		local regs = {}
		for i, p in parts do
			local reg = deps.PartRegister.new(p, adapter.frameCap)
			regs[i] = reg
			adapter.addPart(hh, reg)
		end

		local index = 0
		local t = 0
		local function step()
			if #parts > 0 then
				moveAll(parts, t)
			end
			t += 0.05
			index = (index % adapter.frameCap) + 1
			adapter.updateFrame(hh, index)
		end

		for _ = 1, deps.warmupFrames do
			step()
		end

		local rayOrigin = Vector3.new(SPACING * 0.5, 3000, SPACING * 0.5)
		local rayDir = if #parts > 0
			then (parts[math.max(1, #parts // 2)].Position - rayOrigin).Unit * RAY_LENGTH
			else Vector3.new(RAY_LENGTH, 0, 0)
		local shapeOrigin = CFrame.new(rayOrigin)

		local abortBudget = deps.stepBudgetUs * deps.timeoutMultiple
		local raycastAborted, shapecastAborted = false, false

		for _, queryCount in deps.queryCounts do
			if raycastAborted then
				raycastCells[hitboxCount][queryCount] = "over"
			else
				local perFrameUs = measureBatched(function()
					step()
					for _ = 1, queryCount do
						adapter.queryRaycast(hh, index, rayOrigin, rayDir)
					end
				end, deps.numBatches, deps.framesPerBatch)
				if perFrameUs > abortBudget then
					raycastAborted = true
					raycastCells[hitboxCount][queryCount] = "over"
				else
					raycastCells[hitboxCount][queryCount] = perFrameUs / deps.stepBudgetUs * 100
				end
			end

			if shapecastAborted then
				shapecastCells[hitboxCount][queryCount] = "over"
			else
				local perFrameUs = measureBatched(function()
					step()
					for _ = 1, queryCount do
						adapter.querySimpleShapecast(hh, index, shapeOrigin, boxShape, rayDir)
					end
				end, deps.numBatches, deps.framesPerBatch)
				if perFrameUs > abortBudget then
					shapecastAborted = true
					shapecastCells[hitboxCount][queryCount] = "over"
				else
					shapecastCells[hitboxCount][queryCount] = perFrameUs / deps.stepBudgetUs * 100
				end
			end
		end

		adapter.destroy(hh)
		folder:Destroy()
	end

	local raycastSheet: Sheet = {
		adapterName = adapter.name,
		queryKind = "Raycast",
		hitboxCounts = deps.hitboxCounts,
		queryCounts = deps.queryCounts,
		cellsPct = raycastCells,
	}
	local shapecastSheet: Sheet = {
		adapterName = adapter.name,
		queryKind = "SimpleShapecast",
		hitboxCounts = deps.hitboxCounts,
		queryCounts = deps.queryCounts,
		cellsPct = shapecastCells,
	}
	return raycastSheet, shapecastSheet
end

return Benchmark
