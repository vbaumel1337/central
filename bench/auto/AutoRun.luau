--!strict
-- In-Studio half of bench/autobench.py. Runs inside the place that script builds, started by the
-- plugin it installs, and reports through print(): Studio writes output to its log file, which is
-- where the script reads results back from. Each line is
--     CENTRAL_BENCH|<token>|<kind>|<json>
-- The token is unique per launch, so lines from other Studio windows or earlier runs are ignored.
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = script.Parent :: any
local config = require(folder.RunConfig) :: any
local central = (ReplicatedStorage :: any).Packages.central

local AutoRun = {}

local function emit(kind: string, payload: any)
	print(("CENTRAL_BENCH|%s|%s|%s"):format(config.token, kind, HttpService:JSONEncode(payload)))
end

local function median(values: {number}): number?
	if #values == 0 then
		return nil
	end
	table.sort(values)
	local n = #values
	if n % 2 == 1 then
		return values[(n + 1) // 2]
	end
	return (values[n // 2] + values[n // 2 + 1]) / 2
end

local function runDifferential(implementations: any)
	local Harness = require(folder.DifferentialHarness) :: any
	local bolt = require(central.bolt)
	local PartRegister = require(central.CentralServer.Registers.PartRegister)

	local root = Instance.new("Folder")
	root.Name = "DifferentialHarnessRoot"
	root.Parent = workspace

	local ok, result = pcall(Harness.Run, {
		bolt = bolt,
		PartRegister = PartRegister,
		ref = implementations.Ref,
		new = implementations.Current,
		framesToRun = config.differentialFrames,
		parentFolder = root,
	})
	root:Destroy()

	if not ok then
		error("differential harness failed: " .. tostring(result))
	end

	local first = {}
	for i = 1, math.min(5, #result.mismatches) do
		first[i] = result.mismatches[i]
	end
	emit("differential", {
		frames = result.framesRun,
		queries = result.queriesRun,
		mismatches = #result.mismatches,
		first = first,
	})
end

-- The querying player's own hitboxes are answered at the newest frame, not the rewound one; the
-- differential harness never gives a part an owner, so tests/OwnedHitboxTest covers that.
local function runOwnedTest(implementations: any)
	local Test = require(folder.OwnedHitboxTest) :: any
	local bolt = require(central.bolt)
	local PartRegister = require(central.CentralServer.Registers.PartRegister)
	local Settings = require(central.Settings) :: any

	local root = Instance.new("Folder")
	root.Name = "OwnedHitboxTestRoot"
	root.Parent = workspace

	local ok, result = pcall(Test.Run, {
		bolt = bolt,
		PartRegister = PartRegister,
		implementation = implementations.Current,
		ownerAttribute = Settings.OWNER_ATTRIBUTE,
		parentFolder = root,
	})
	root:Destroy()

	if not ok then
		error("owned hitbox test failed to run: " .. tostring(result))
	end

	emit("owned", {checks = result.checks, failures = result.failures})
end

-- The parts of a tagged Model are one group with one leaf in the tree; the differential harness
-- proves the answers match the reference, and tests/GroupHitboxTest covers the rest (the leaf
-- count, the Model's owner, per-member filters, and the group going away with its last member).
local function runGroupTest(implementations: any)
	local Test = require(folder.GroupHitboxTest) :: any
	local bolt = require(central.bolt)
	local PartRegister = require(central.CentralServer.Registers.PartRegister)
	local Settings = require(central.Settings) :: any

	local root = Instance.new("Folder")
	root.Name = "GroupHitboxTestRoot"
	root.Parent = workspace

	local ok, result = pcall(Test.Run, {
		bolt = bolt,
		PartRegister = PartRegister,
		implementation = implementations.Current,
		ownerAttribute = Settings.OWNER_ATTRIBUTE,
		parentFolder = root,
	})
	root:Destroy()

	if not ok then
		error("group hitbox test failed to run: " .. tostring(result))
	end

	emit("group", {checks = result.checks, failures = result.failures})
end

-- One row = one implementation at one hitbox count: UpdateFrame alone, and the cost of one query
-- of each kind, all in microseconds. Per-query cost is the slope between 0 and `queryCount`
-- queries per frame, so UpdateFrame is not counted into it.
local function runRow(implementation: any, hitboxCount: number)
	local Sheets = require(folder.RunBenchmarkSheets) :: any
	local PartRegister = require(central.CentralServer.Registers.PartRegister)
	local queryCount = config.queryCount
	local budget = config.stepBudgetUs

	local root = Instance.new("Folder")
	root.Name = "BenchmarkSheetsRoot"
	root.Parent = workspace

	-- what a game typically passes: something to exclude (a character, never in the way here) and
	-- a collision group. Exercises isFilteredOut for every candidate that reaches it.
	local queryParams: RaycastParams? = nil
	if config.withParams then
		local excluded = Instance.new("Folder")
		excluded.Name = "BenchmarkExcluded"
		excluded.Parent = root
		local built = RaycastParams.new()
		built.ExcludeInstances = {excluded}
		built.CollisionGroup = "Default"
		queryParams = built
	end

	local ok, result = pcall(Sheets.Run, {
		PartRegister = PartRegister,
		implementations = {implementation},
		hitboxCounts = {hitboxCount},
		queryCounts = {0, queryCount},
		warmupFrames = config.warmupFrames,
		framesPerBatch = config.framesPerBatch,
		numBatches = config.numBatches,
		stepBudgetUs = budget,
		timeoutMultiple = config.timeoutMultiple,
		movingFraction = config.movingFraction,
		groupSize = config.groupSize,
		groupLayout = config.groupLayout,
		queryParams = queryParams,
		parentFolder = root,
	})
	root:Destroy()

	if not ok then
		error(("benchmark failed for %s at %d hitboxes: %s"):format(implementation.name, hitboxCount, tostring(result)))
	end

	local set = result.byAdapter[implementation.name]
	local row: {[string]: any} = {
		implementation = implementation.name,
		hitboxes = hitboxCount,
		notes = set.notes,
	}

	-- every case measures UpdateFrame alone in its 0-query column; the median of the four is
	-- steadier than any one of them
	local updates = {}
	for _, sheet in set.sheets do
		local base, top = sheet.cellsPct[hitboxCount][0], sheet.cellsPct[hitboxCount][queryCount]
		if type(base) == "number" then
			table.insert(updates, base / 100 * budget)
			if type(top) == "number" then
				row[sheet.case .. "Us"] = (top - base) / 100 * budget / queryCount
			end
		end
	end
	row.updateFrameUs = median(updates)

	emit("row", row)
end

function AutoRun.Run()
	local ok, message = pcall(function()
		local implementations = require(folder.Implementations)(central)

		for _, name in config.implementations do
			if not implementations[name] then
				local known = {}
				for key in implementations do
					table.insert(known, key)
				end
				table.sort(known)
				error(("unknown implementation %q (available: %s)"):format(name, table.concat(known, ", ")))
			end
		end

		emit("start", {implementations = config.implementations})

		if config.differential then
			runDifferential(implementations)
			task.wait()
			runOwnedTest(implementations)
			task.wait()
			runGroupTest(implementations)
			task.wait()
		end

		for _, name in config.implementations do
			for _, hitboxCount in config.hitboxCounts do
				runRow(implementations[name], hitboxCount)
				-- yields so Studio stays responsive and the log line is flushed between rows
				task.wait()
			end
		end
	end)

	if not ok then
		emit("error", {message = tostring(message)})
	end
	emit("done", {})
end

return AutoRun
