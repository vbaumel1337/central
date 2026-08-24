--!strict
-- Builds Ref and New adapters for Benchmark.RunSheets and runs the full hitboxCount x
-- queryCount matrix for both, for Raycast and SimpleShapecast. Pure module (dependencies passed
-- in) -- see a consumer project's server tree for a thin wrapper that requires the vendored
-- package and calls Run() with concrete values.
local Benchmark = require(script.Parent.Benchmark)

export type Config = {
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

function RunBenchmarkSheets.Run(config: Config): {
	refRaycast: Benchmark.Sheet,
	refShapecast: Benchmark.Sheet,
	newRaycast: Benchmark.Sheet,
	newShapecast: Benchmark.Sheet,
}
	local refAdapter: Benchmark.Adapter = {
		name = "Ref",
		frameCap = config.refFrameCap,
		new = function()
			return config.HistoricalHitboxesRef.new(config.refFrameCap, config.refPadding)
		end,
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
		destroy = function(hh)
			hh:Destroy()
		end,
	}

	local newFrameCap = config.newUnionsPerPart * config.newUnionSize
	local newAdapter: Benchmark.Adapter = {
		name = "New",
		frameCap = newFrameCap,
		new = function()
			return config.HistoricalHitboxesNew.new(config.newUnionsPerPart, config.newUnionSize, config.newPadding, config.newPredictionFrames, config.newUpdateFraction)
		end,
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
		destroy = function(hh)
			hh:Destroy()
		end,
	}

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

	-- Ref and New rows are interleaved (see RunSheets' doc comment) rather than run as two
	-- separate full passes, so neither adapter is systematically favored by going first.
	local sheets = Benchmark.RunSheets({refAdapter, newAdapter}, sheetDeps)

	return {
		refRaycast = sheets.Ref.raycast,
		refShapecast = sheets.Ref.shapecast,
		newRaycast = sheets.New.raycast,
		newShapecast = sheets.New.shapecast,
	}
end

-- Renders a Sheet as a GitHub-flavored markdown table: rows = hitboxCounts, columns =
-- queryCounts, cells = "12.3%" or "over".
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
			local cell = sheet.cellsPct[hitboxCount][q]
			if type(cell) == "number" then
				table.insert(row, ("%.2f%%"):format(cell))
			else
				table.insert(row, tostring(cell))
			end
		end
		table.insert(lines, "| " .. table.concat(row, " | ") .. " |")
	end

	return table.concat(lines, "\n")
end

return RunBenchmarkSheets
