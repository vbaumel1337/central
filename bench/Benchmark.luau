--!strict
-- Compares HistoricalHitboxesRef (pre-union-hitboxes) against the new union-tree
-- HistoricalHitboxes: UpdateFrame cost (the thing this redesign targets) and query cost (the
-- thing it must not regress), at a few hitbox counts. Pure module -- deps are passed in, same
-- portability convention as tests/DifferentialHarness.luau.
--
-- This is a focused comparison, not the full hitboxCount x castCount matrix with per-cell
-- timeout handling described in the design notes' step 4 -- that's a larger build than this
-- pass covers. What's here answers the load-bearing question directly: does UpdateFrame get
-- cheaper, and by how much, at realistic hitbox counts.
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

local Benchmark = {}

local SPACING = 7 -- studs; matches the README's existing methodology

local function buildGrid(count: number, parentFolder: Instance): {BasePart}
	local parts = {}
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

return Benchmark
