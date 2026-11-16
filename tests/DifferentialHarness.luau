--!strict
-- Differential harness: drives two HistoricalHitboxes-shaped implementations (normally the frozen
-- one-tree-per-frame HistoricalHitboxesRef and the implementation under test) from the same live
-- part trajectories, and asserts identical query results. A broad phase that bounds history too
-- tightly surfaces as a silently missed hit, which no benchmark would catch, so this is the gate:
-- nothing ships without it passing clean.
--
-- Pure module: dependencies are passed in rather than required by a fixed path, so the same
-- file runs whether central is tested directly (its own Rojo place) or vendored into a consumer.
export type Implementation = {
	name: string,
	frameCap: number, -- depth of the ring this implementation is addressed by
	new: () -> any, -- builds a fresh instance
}

export type Deps = {
	bolt: any,
	PartRegister: any, -- .new(part, frameCap, callback?)
	ref: Implementation,
	new: Implementation,
	framesToRun: number,
	parentFolder: Instance,
}

export type Report = {
	mismatches: {string},
	framesRun: number,
	queriesRun: number,
}

local Harness = {}

local EPS = 1e-3

local function near(a: number, b: number, eps: number): boolean
	return math.abs(a - b) <= eps
end

local function vnear(a: Vector3?, b: Vector3?, eps: number): boolean
	if a == nil and b == nil then
		return true
	end
	if a == nil or b == nil then
		return false
	end
	return (a - b).Magnitude <= eps
end

type Motion = (frame: number) -> (CFrame?, Vector3, boolean) -- nil cframe = absent this frame

type TestPart = {
	part: BasePart,
	motion: Motion,
	activationFrame: number?, -- nil = added on frame 1; otherwise AddPart happens on this frame
	added: boolean,
	registers: {any}?, -- one PartRegister per implementation, once added
}

function Harness.Run(deps: Deps): Report
	local mismatches: {string} = {}
	local queriesRun = 0

	local refFrameCap = deps.ref.frameCap
	local newFrameCap = deps.new.frameCap

	local refHH = deps.ref.new()
	local newHH = deps.new.new()

	local function report(msg: string)
		table.insert(mismatches, msg)
	end

	local function makePart(name: string, size: Vector3): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = true
		p.Size = size
		p.Parent = deps.parentFolder
		return p
	end

	-- parked well clear of anything else in the place
	local BASE = Vector3.new(0, 2000, 0)

	local testParts: {TestPart} = {}

	table.insert(testParts, {part = makePart("Static", Vector3.new(4, 4, 4)), motion = function(f)
		return CFrame.new(BASE), Vector3.new(4, 4, 4), true
	end, added = false})

	table.insert(testParts, {part = makePart("SlowMover", Vector3.new(4, 4, 4)), motion = function(f)
		return CFrame.new(BASE + Vector3.new(20, 0, 0) + Vector3.new(f * 0.2, 0, 0)), Vector3.new(4, 4, 4), true
	end, added = false})

	-- circle stays within x=[35,85], clear of every stationary/other-ranged test part
	table.insert(testParts, {part = makePart("FastMover", Vector3.new(4, 4, 4)), motion = function(f)
		return CFrame.new(BASE + Vector3.new(60, 0, 0) + Vector3.new(math.sin(f * 0.05) * 25, 0, math.cos(f * 0.05) * 25)), Vector3.new(4, 4, 4), true
	end, added = false})

	-- jumps every 37 frames -- deliberately not aligned to UNION_SIZE (16), to catch a block
	-- boundary landing mid-teleport. Hops stay within [100,112], well clear of every other test
	-- part's position so two parts never land in the exact same spot (an exact tie is a genuine
	-- ambiguity for a closest-hit query -- which of two equidistant hits wins can depend on tree
	-- topology/insertion history, so it's not something this harness should be asserting on).
	table.insert(testParts, {part = makePart("Teleporter", Vector3.new(4, 4, 4)), motion = function(f)
		local hop = f // 37
		return CFrame.new(BASE + Vector3.new(100, 0, 0) + Vector3.new((hop % 4) * 4, 0, 0)), Vector3.new(4, 4, 4), true
	end, added = false})

	-- present 10 frames, absent 10, repeating: exercises "the absent branch is a pure continue"
	-- seeding rule and the seal's drop-if-absent-all-block path
	table.insert(testParts, {part = makePart("Intermittent", Vector3.new(4, 4, 4)), motion = function(f)
		if (f // 10) % 2 == 0 then
			return CFrame.new(BASE + Vector3.new(140, 0, 0) + Vector3.new(f * 0.1, 0, 0)), Vector3.new(4, 4, 4), true
		end
		return nil, Vector3.new(4, 4, 4), true
	end, added = false})

	-- absent for over a block-and-a-half, then returns near its old spot: the rotation
	-- containment+ratio test exists specifically for this case
	table.insert(testParts, {part = makePart("Wanderer", Vector3.new(4, 4, 4)), motion = function(f)
		if f >= 20 and f < 100 then
			return nil, Vector3.new(4, 4, 4), true
		end
		return CFrame.new(BASE + Vector3.new(180, 0, 0)), Vector3.new(4, 4, 4), true
	end, added = false})

	table.insert(testParts, {part = makePart("Resizer", Vector3.new(4, 4, 4)), motion = function(f)
		local size = if f % 50 < 25 then Vector3.new(4, 4, 4) else Vector3.new(8, 2, 6)
		return CFrame.new(BASE + Vector3.new(220, 0, 0)), size, true
	end, added = false})

	table.insert(testParts, {part = makePart("Collider", Vector3.new(4, 4, 4)), motion = function(f)
		return CFrame.new(BASE + Vector3.new(260, 0, 0)), Vector3.new(4, 4, 4), (f % 20) < 10
	end, added = false})

	-- added mid-cycle: goes through its first block while the tree it lands in has already
	-- been running for a while, and only gets a leaf in every tree after its first full rotation
	table.insert(testParts, {part = makePart("Latecomer", Vector3.new(4, 4, 4)), motion = function(f)
		return CFrame.new(BASE + Vector3.new(300, 0, 0) + Vector3.new(0, 0, f * 0.15)), Vector3.new(4, 4, 4), true
	end, activationFrame = 90, added = false})

	-- Second row, 30 studs up: clear of every ray aimed along the first row, still inside the
	-- overlap probe. These target a broad phase whose leaf bounds a whole window of history.
	local ROW2 = BASE + Vector3.new(0, 30, 0)

	-- a long thin box tumbling on the spot: its bounds have to cover every orientation it swept
	-- through between samples, not just the two it was sampled at
	table.insert(testParts, {part = makePart("Spinner", Vector3.new(12, 1, 1)), motion = function(f)
		return CFrame.new(ROW2 + Vector3.new(20, 0, 0)) * CFrame.Angles(f * 0.31, f * 0.17, f * 0.4), Vector3.new(12, 1, 1), true
	end, added = false})

	-- runs, then rests for longer than the whole history, then runs again: a resting part stops
	-- being sampled, and its leaf must still bound it, then pick the motion back up correctly
	table.insert(testParts, {part = makePart("Sprinter", Vector3.new(4, 4, 4)), motion = function(f)
		local phase = f % 260
		local travelled = (f // 260) * 30 + math.min(phase, 60) * 0.5
		return CFrame.new(ROW2 + Vector3.new(60, 0, 0) + Vector3.new(0, 0, travelled % 40)), Vector3.new(4, 4, 4), true
	end, added = false})

	-- jumps 150 studs and back: the frames either side of a teleport are both still in history
	table.insert(testParts, {part = makePart("Blinker", Vector3.new(4, 4, 4)), motion = function(f)
		local far = (f // 45) % 2 == 1
		return CFrame.new(ROW2 + Vector3.new(100, 0, if far then 150 else 0)), Vector3.new(4, 4, 4), true
	end, added = false})

	-- away for much longer than the history, returning somewhere else each time: its history is
	-- dropped while it is gone and has to start over cleanly
	table.insert(testParts, {part = makePart("Hibernator", Vector3.new(4, 4, 4)), motion = function(f)
		local cycle = f // 200
		if f % 200 >= 40 then
			return nil, Vector3.new(4, 4, 4), true
		end
		return CFrame.new(ROW2 + Vector3.new(140, 0, 0) + Vector3.new(0, 0, (cycle % 3) * 12 + (f % 200) * 0.1)), Vector3.new(4, 4, 4), true
	end, added = false})

	-- shrinks while resting: the frames recorded at the larger size must stay hittable at that size
	table.insert(testParts, {part = makePart("Shrinker", Vector3.new(10, 10, 10)), motion = function(f)
		local size = if f % 140 < 100 then Vector3.new(10, 10, 10) else Vector3.new(2, 2, 2)
		return CFrame.new(ROW2 + Vector3.new(180, 0, 0)), size, true
	end, added = false})

	local dummyPlayer = {Name = "__DifferentialHarnessProbe__"} :: any

	local function compareRay(label: string, refCenter: number, newCenter: number, frameRange: number, origin: Vector3, direction: Vector3)
		queriesRun += 1
		local rHitbox, rPoint, rDist, _rNormal = refHH:QueryRaycast(dummyPlayer, refCenter, frameRange, origin, direction)
		local nHitbox, nPoint, nDist, _nNormal = newHH:QueryRaycast(dummyPlayer, newCenter, frameRange, origin, direction)

		local rInst = rHitbox and rHitbox.instance
		local nInst = nHitbox and nHitbox.instance
		if rInst ~= nInst then
			-- Two candidates the cast reaches at the same distance are a genuine ambiguity:
			-- which one a closest-hit query returns falls out of tree topology and insertion
			-- history, so it isn't a property either implementation promises. Only disagreement
			-- about *how far* the cast got is a real mismatch. (The test parts try to keep out of
			-- each other's way -- see the Teleporter's boxed-in hop range -- but a drifting part
			-- crossing a stationary one is only a matter of how long the run is: Intermittent
			-- lands exactly on Wanderer at f=400.)
			if rHitbox and nHitbox and near(rDist :: number, nDist :: number, EPS) then
				return
			end
			report(("%s: raycast instance mismatch: ref=%s new=%s"):format(label, tostring(rInst), tostring(nInst)))
			return
		end
		if rHitbox and nHitbox then
			if not near(rDist :: number, nDist :: number, EPS) then
				report(("%s: raycast distance mismatch: ref=%.4f new=%.4f"):format(label, rDist :: number, nDist :: number))
			end
			if not vnear(rPoint, nPoint, EPS) then
				report(("%s: raycast point mismatch"):format(label))
			end
		end
	end

	local function compareSimpleShapecast(label: string, refCenter: number, newCenter: number, frameRange: number, cframe: CFrame, shape: any, direction: Vector3)
		queriesRun += 1
		local rHitbox, rDist = refHH:QuerySimpleShapecast(dummyPlayer, refCenter, frameRange, cframe, shape, direction)
		local nHitbox, nDist = newHH:QuerySimpleShapecast(dummyPlayer, newCenter, frameRange, cframe, shape, direction)

		local rInst = rHitbox and rHitbox.instance
		local nInst = nHitbox and nHitbox.instance
		if rInst ~= nInst then
			-- equidistant candidates are an ambiguity, not a mismatch; see compareRay
			if rHitbox and nHitbox and near(rDist :: number, nDist :: number, EPS) then
				return
			end
			report(("%s: simple shapecast instance mismatch: ref=%s new=%s"):format(label, tostring(rInst), tostring(nInst)))
			return
		end
		if rHitbox and nHitbox and not near(rDist :: number, nDist :: number, EPS) then
			report(("%s: simple shapecast distance mismatch: ref=%.4f new=%.4f"):format(label, rDist :: number, nDist :: number))
		end
	end

	local function compareShape(label: string, refCenter: number, newCenter: number, frameRange: number, cframe: CFrame, shape: any)
		queriesRun += 1
		local rResults = refHH:QueryShape(dummyPlayer, refCenter, frameRange, cframe, shape)
		local nResults = newHH:QueryShape(dummyPlayer, newCenter, frameRange, cframe, shape)

		local rCount, nCount = 0, 0
		for _ in rResults do
			rCount += 1
		end
		for _ in nResults do
			nCount += 1
		end

		if rCount ~= nCount then
			report(("%s: shape overlap candidate-count mismatch: ref=%d new=%d"):format(label, rCount, nCount))
		end

		for inst in rResults do
			if not nResults[inst] then
				report(("%s: shape overlap candidate set mismatch (%s in ref only, refOffset=%d)"):format(label, inst:GetFullName(), rResults[inst].frameOffset))
			end
		end
		for inst in nResults do
			if not rResults[inst] then
				report(("%s: shape overlap candidate set mismatch (%s in new only, newOffset=%d)"):format(label, inst:GetFullName(), nResults[inst].frameOffset))
			end
		end
	end

	-- where each part was on each frame (nil while absent), for aiming probes at the past
	local history: {[TestPart]: {[number]: CFrame}} = {}
	for _, tp in testParts do
		history[tp] = {}
	end

	local function applyMotion(tp: TestPart, f: number)
		local cf, size, canCollide = tp.motion(f)
		history[tp][f] = cf :: any
		tp.part.Size = size
		tp.part.CanCollide = canCollide
		if cf then
			tp.part.Parent = deps.parentFolder
			tp.part.CFrame = cf
		else
			tp.part.Parent = nil
		end

		-- PartRegister learns about Size and Parent through property-changed signals. Under
		-- deferred signal behaviour those don't fire until this thread yields, and the harness
		-- never does, so every size change and absence would silently never happen. Write what
		-- the observers would have written, so the run doesn't depend on the place's settings.
		for _, register in tp.registers :: {any} do
			register._currentSize = size
			register._inWorld = cf ~= nil
		end
	end

	for f = 1, deps.framesToRun do
		local refIndex = ((f - 1) % refFrameCap) + 1
		local newIndex = ((f - 1) % newFrameCap) + 1

		for _, tp in testParts do
			if not tp.added and (tp.activationFrame == nil or f >= tp.activationFrame) then
				local regRef = deps.PartRegister.new(tp.part, refFrameCap)
				local regNew = deps.PartRegister.new(tp.part, newFrameCap)
				-- Mirror CentralServer/init.luau's `register.index = GlobalTimeRegister.index`:
				-- a fresh PartRegister's internal ring position must be seeded to one behind the
				-- target index, so its first Step() (below, inside UpdateFrame) lands exactly on
				-- it. Skipping this desyncs the part's own ring from HistoricalHitboxes' ring --
				-- AtIndex(frame) then silently reads whatever stale slot that offset happens to
				-- land on, which is a real bug class this harness exists to catch, not something
				-- to reproduce by omission.
				regRef.index = ((refIndex - 2) % refFrameCap) + 1
				regNew.index = ((newIndex - 2) % newFrameCap) + 1
				refHH:AddPart(regRef)
				newHH:AddPart(regNew)
				tp.added = true
				tp.registers = {regRef, regNew}
			end
			if tp.added then
				applyMotion(tp, f)
			end
		end

		refHH:UpdateFrame(refIndex)
		newHH:UpdateFrame(newIndex)

		-- probe "now" every frame. frameRange=0 deliberately: centerIndex here is the literal
		-- just-written ring slot, so a nonzero range's +1 side would read "current+1" -- a slot
		-- that hasn't been written yet this rotation, which silently returns whatever stale data
		-- sat there frameCap frames ago. Two rings of different depths would then be comparing
		-- two unrelated historical snapshots, not testing anything meaningful. The
		-- real system never queries an unrewound "now" with frameRange > 0 for the same reason --
		-- callers always pass a lag-rewound centerIndex, which the "past" probes below model.
		for _, tp in testParts do
			if tp.added and tp.part.Parent then
				local cf = tp.part.CFrame
				local origin = cf.Position + Vector3.new(15, 0.3, 0.2)
				compareRay(("f=%d %s now"):format(f, tp.part.Name), refIndex, newIndex, 0, origin, (cf.Position - origin).Unit * 30)
			end
		end

		-- probe a historical offset periodically, well within both rings' valid depth -- this is
		-- what exercises frameRange > 0 safely, since backBy keeps both the -1 and +1 sides
		-- pointing at frames that are genuinely already written for both rings. The depth cycles
		-- from shallow to nearly the whole of the shorter ring, since the far end of the history
		-- is where a bound that retires old motion too early would show.
		local shallowestRing = math.min(refFrameCap, newFrameCap)
		if f % 5 == 0 and f > shallowestRing then
			local backBy = 2 + (f // 5 * 7) % (shallowestRing - 4)
			local refPast = ((refIndex - 1 - backBy) % refFrameCap) + 1
			local newPast = ((newIndex - 1 - backBy) % newFrameCap) + 1

			for _, tp in testParts do
				if tp.added and tp.part.Parent then
					local cf = tp.part.CFrame
					local origin = cf.Position + Vector3.new(-15, 0.4, 0.1)
					local direction = (cf.Position - origin).Unit * 30
					compareRay(("f=%d %s past(%d)"):format(f, tp.part.Name, backBy), refPast, newPast, 1, origin, direction)
					compareSimpleShapecast(("f=%d %s past(%d) simple"):format(f, tp.part.Name, backBy), refPast, newPast, 1, CFrame.new(origin), deps.bolt.create_box(Vector3.new(2, 2, 2)), direction)
				end

				-- and where it was back then, which a part that has since moved away (or left the
				-- world) is no longer anywhere near: only its history can answer this one
				local pastCF = history[tp][f - backBy]
				if tp.added and pastCF then
					local pastOrigin = pastCF.Position + Vector3.new(0.3, 15, -0.2)
					compareRay(("f=%d %s rewound(%d)"):format(f, tp.part.Name, backBy), refPast, newPast, 1, pastOrigin, (pastCF.Position - pastOrigin).Unit * 30)
				end
			end

			-- one overlap probe sweeping the whole cluster
			compareShape(("f=%d overlap(%d)"):format(f, backBy), refPast, newPast, 1, CFrame.new(BASE + Vector3.new(150, 0, 0)), deps.bolt.create_box(Vector3.new(400, 100, 100)))
		end
	end

	return {mismatches = mismatches, framesRun = deps.framesToRun, queriesRun = queriesRun}
end

return Harness
