--!strict
-- Builds an adapter per implementation for Benchmark.RunSheets and runs the full hitboxCount x
-- queryCount matrix for each, for every query kind / hit-or-miss case. Pure module (dependencies
-- passed in) -- see a consumer project's server tree for a thin wrapper that requires the
-- vendored package and calls Run() with concrete values.
local Benchmark = require(script.Parent.Benchmark)

export type Config = {
	PartRegister: any,
	-- the first one is the baseline every other is summarised against
	implementations: {Benchmark.Implementation},
	hitboxCounts: {number},
	queryCounts: {number},
	warmupFrames: number,
	framesPerBatch: number,
	numBatches: number,
	stepBudgetUs: number,
	timeoutMultiple: number,
	parentFolder: Instance,
}

local RunBenchmarkSheets = {}

local dummyPlayer = {Name = "__SheetBenchProbe__"} :: any

export type Result = {
	byAdapter: {[string]: Benchmark.SheetSet},
	adapterNames: {string},
	hitboxCounts: {number},
	queryCounts: {number},
	stepBudgetUs: number,
}

function RunBenchmarkSheets.Run(config: Config): Result
	local adapters: {Benchmark.Adapter} = {}
	local adapterNames: {string} = {}

	for _, implementation in config.implementations do
		table.insert(adapterNames, implementation.name)
		table.insert(adapters, {
			name = implementation.name,
			frameCap = implementation.frameCap,
			new = implementation.new,
			addPart = function(hh, register)
				hh:AddPart(register)
			end,
			updateFrame = function(hh, index)
				hh:UpdateFrame(index)
			end,
			queryRaycast = function(hh, index, origin, direction)
				hh:QueryRaycast(dummyPlayer, index, 1, origin, direction)
			end,
			querySimpleShapecast = function(hh, index, cframe, shape, direction)
				hh:QuerySimpleShapecast(dummyPlayer, index, 1, cframe, shape, direction)
			end,
			probeRaycast = function(hh, index, origin, direction)
				return (hh:QueryRaycast(dummyPlayer, index, 1, origin, direction)) ~= nil
			end,
			destroy = function(hh)
				hh:Destroy()
			end,
		})
	end

	local sheetDeps: Benchmark.SheetDeps = {
		PartRegister = config.PartRegister,
		hitboxCounts = config.hitboxCounts,
		queryCounts = config.queryCounts,
		warmupFrames = config.warmupFrames,
		framesPerBatch = config.framesPerBatch,
		numBatches = config.numBatches,
		stepBudgetUs = config.stepBudgetUs,
		timeoutMultiple = config.timeoutMultiple,
		parentFolder = config.parentFolder,
	}

	-- Rows are interleaved across implementations (see RunSheets' doc comment) rather than run
	-- as separate full passes, so none is systematically favored by going first.
	local byAdapter = Benchmark.RunSheets(adapters, sheetDeps)

	return {
		byAdapter = byAdapter,
		adapterNames = adapterNames,
		hitboxCounts = config.hitboxCounts,
		queryCounts = config.queryCounts,
		stepBudgetUs = config.stepBudgetUs,
	}
end

local function fmtCell(cell: (number | string)?): string
	if type(cell) == "number" then
		return ("%.2f%%"):format(cell)
	end
	return tostring(cell or "-")
end

-- Renders a Sheet as a GitHub-flavored markdown table: rows = hitboxCounts, columns =
-- queryCounts, cells = "12.3%" of one simulation step, or "over".
function RunBenchmarkSheets.ToMarkdown(sheet: Benchmark.Sheet): string
	local lines = {}
	table.insert(lines, ("**%s -- %s**"):format(sheet.adapterName, sheet.queryKind))
	table.insert(lines, "")

	local header = {"hitboxes"}
	for _, q in sheet.queryCounts do
		table.insert(header, tostring(q))
	end
	table.insert(lines, "| " .. table.concat(header, " | ") .. " |")
	table.insert(lines, "|" .. string.rep("---|", #header))

	for _, hitboxCount in sheet.hitboxCounts do
		local row = {tostring(hitboxCount)}
		for _, q in sheet.queryCounts do
			table.insert(row, fmtCell(sheet.cellsPct[hitboxCount][q]))
		end
		table.insert(lines, "| " .. table.concat(row, " | ") .. " |")
	end

	return table.concat(lines, "\n")
end

-- The comparison the sheets exist to support: per-query microseconds for each implementation,
-- derived as (cost at maxQueries - cost at 0 queries) / maxQueries, plus the UpdateFrame column
-- and the resulting break-even -- how many queries per frame before an implementation's
-- per-frame saving over the baseline (the first implementation) is cancelled by its per-query
-- cost. One table per non-baseline implementation.
function RunBenchmarkSheets.ToSummary(result: Result): string
	local lines = {}
	local budget = result.stepBudgetUs
	local queryCounts = result.queryCounts
	local maxQ = queryCounts[#queryCounts]

	local baseName = result.adapterNames[1]
	local baseSheets = result.byAdapter[baseName].sheets

	for n = 2, #result.adapterNames do
		local name = result.adapterNames[n]
		local sheets = result.byAdapter[name].sheets

		table.insert(lines, ("%s vs %s: per-query cost and break-even (queryCount=%d slope, %d us step budget)"):format(name, baseName, maxQ, budget))
		table.insert(lines, "")
		table.insert(lines, ("| case | hitboxes | UpdateFrame %s | UpdateFrame %s | speedup | us/query %s | us/query %s | ratio | break-even Q |"):format(baseName, name, baseName, name))
		table.insert(lines, "|---|---|---|---|---|---|---|---|---|")

		for i, baseSheet in baseSheets do
			local sheet = sheets[i]
			for _, h in result.hitboxCounts do
				local rBase, rTop = baseSheet.cellsPct[h][0], baseSheet.cellsPct[h][maxQ]
				local nBase, nTop = sheet.cellsPct[h][0], sheet.cellsPct[h][maxQ]
				if type(rBase) ~= "number" or type(rTop) ~= "number" or type(nBase) ~= "number" or type(nTop) ~= "number" then
					continue
				end
				local rUpd, nUpd = rBase / 100 * budget, nBase / 100 * budget
				local rPer = (rTop - rBase) / 100 * budget / maxQ
				local nPer = (nTop - nBase) / 100 * budget / maxQ
				local delta = nPer - rPer
				local breakEven = if delta <= 0 then "never" else ("%.0f"):format((rUpd - nUpd) / delta)
				table.insert(lines, ("| %s | %d | %.1f us | %.1f us | %.2fx | %.3f | %.3f | %.2fx | %s |")
					:format(baseSheet.queryKind, h, rUpd, nUpd, rUpd / math.max(nUpd, 1e-9), rPer, nPer, nPer / math.max(rPer, 1e-9), breakEven))
			end
		end

		table.insert(lines, "")
	end

	return table.concat(lines, "\n")
end

function RunBenchmarkSheets.AllMarkdown(result: Result): string
	local parts = {}
	for _, name in result.adapterNames do
		for _, sheet in result.byAdapter[name].sheets do
			table.insert(parts, RunBenchmarkSheets.ToMarkdown(sheet))
		end
	end
	return table.concat(parts, "\n\n")
end

return RunBenchmarkSheets
