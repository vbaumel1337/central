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
	PartRegister: any, -- .new(part, frameCap, callback?, group?)
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
	if a == nil or b == nil then
		return a == b -- both nil is a match, exactly one nil is not
	end
	return (a - b).Magnitude <= eps
end

type Motion = (frame: number) -> (CFrame?, Vector3, boolean) -- nil cframe = absent this frame

type TestPart = {
	part: BasePart,
	motion: Motion,
	activationFrame: number?, -- nil = added on frame 1; otherwise AddPart happens on this frame
	removalFrame: number?, -- nil = never; otherwise RemovePart happens on this frame
	added: boolean,
	removed: boolean?,
	registers: {any}?, -- one PartRegister per implementation, once added
	group: Instance?, -- the Model it is registered as a member of; implementations that predate groups ignore it
	parent: Instance?, -- where it lives while it is in the world; nil = the harness's folder
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

	local function makePart(name: string, size: Vector3, parent: Instance?): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.CanCollide = true
		p.Size = size
		p.Parent = parent or deps.parentFolder
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

	-- ---- Models: every part of a rig is registered as a member of one group ----
	-- A third row, 60 studs up, clear of both rows above (the cluster-wide overlap probe near the
	-- bottom of this file spans only the first two). Each rig keeps to its own stretch of x, and
	-- the rigs' parts are the ones the group's box has to bound without losing any of them.
	local ROW3 = BASE + Vector3.new(0, 60, 0)

	local function addRig(name: string): Model
		local model = Instance.new("Model")
		model.Name = name
		model.Parent = deps.parentFolder
		return model
	end

	local function addMember(model: Model, name: string, size: Vector3, motion: Motion, activationFrame: number?, removalFrame: number?)
		local testPart: TestPart = {
			part = makePart(name, size, model),
			motion = motion,
			activationFrame = activationFrame,
			removalFrame = removalFrame,
			added = false,
			group = model,
			parent = model,
		}
		table.insert(testParts, testPart)
	end

	-- six parts moving together on a circle and turning, with limbs swinging about the torso: the
	-- members move relative to each other, and the head resizes
	local walker = addRig("Walker")
	local function walkerRoot(f: number): CFrame
		local around = Vector3.new(math.sin(f * 0.03) * 15, 0, math.cos(f * 0.03) * 15)
		return CFrame.new(ROW3 + Vector3.new(40, 0, 0) + around) * CFrame.Angles(0, f * 0.05, 0)
	end
	local function swing(f: number): number
		return math.sin(f * 0.2)
	end
	addMember(walker, "WalkerTorso", Vector3.new(2, 2, 1), function(f)
		return walkerRoot(f), Vector3.new(2, 2, 1), true
	end)
	addMember(walker, "WalkerHead", Vector3.new(1.2, 1.2, 1.2), function(f)
		local size = if f % 50 < 25 then Vector3.new(1.2, 1.2, 1.2) else Vector3.new(1.6, 0.8, 1.2)
		return walkerRoot(f) * CFrame.new(0, 1.8, 0), size, true
	end)
	addMember(walker, "WalkerArmL", Vector3.new(0.6, 2, 0.6), function(f)
		return walkerRoot(f) * CFrame.new(-1.6, 0.8, 0) * CFrame.Angles(swing(f), 0, 0) * CFrame.new(0, -1, 0), Vector3.new(0.6, 2, 0.6), true
	end)
	addMember(walker, "WalkerArmR", Vector3.new(0.6, 2, 0.6), function(f)
		return walkerRoot(f) * CFrame.new(1.6, 0.8, 0) * CFrame.Angles(-swing(f), 0, 0) * CFrame.new(0, -1, 0), Vector3.new(0.6, 2, 0.6), true
	end)
	addMember(walker, "WalkerLegL", Vector3.new(0.8, 2, 0.8), function(f)
		return walkerRoot(f) * CFrame.new(-0.5, -1, 0) * CFrame.Angles(-swing(f) * 0.8, 0, 0) * CFrame.new(0, -1, 0), Vector3.new(0.8, 2, 0.8), true
	end)
	addMember(walker, "WalkerLegR", Vector3.new(0.8, 2, 0.8), function(f)
		return walkerRoot(f) * CFrame.new(0.5, -1, 0) * CFrame.Angles(swing(f) * 0.8, 0, 0) * CFrame.new(0, -1, 0), Vector3.new(0.8, 2, 0.8), true
	end)

	-- one member comes and goes (10 frames in, 10 out) while the rest of the group stays
	local flicker = addRig("Flicker")
	addMember(flicker, "FlickerAnchor", Vector3.new(4, 4, 4), function(f)
		return CFrame.new(ROW3 + Vector3.new(120, 0, 0)), Vector3.new(4, 4, 4), true
	end)
	addMember(flicker, "FlickerBlink", Vector3.new(4, 4, 4), function(f)
		if (f // 10) % 2 == 0 then
			return CFrame.new(ROW3 + Vector3.new(128, 0, 0) + Vector3.new(0, 0, f * 0.05)), Vector3.new(4, 4, 4), true
		end
		return nil, Vector3.new(4, 4, 4), true
	end)
	addMember(flicker, "FlickerDrifter", Vector3.new(3, 3, 3), function(f)
		return CFrame.new(ROW3 + Vector3.new(120, 0, 8) + Vector3.new(math.sin(f * 0.07) * 3, 0, 0)), Vector3.new(3, 3, 3), true
	end)

	-- members joining and leaving a group that lives on: one arrives late, one is registered from
	-- the start and removed mid-run, one comes and goes within the run
	local growing = addRig("Growing")
	addMember(growing, "GrowingCore", Vector3.new(4, 4, 4), function(f)
		return CFrame.new(ROW3 + Vector3.new(200, 0, 0)), Vector3.new(4, 4, 4), true
	end)
	addMember(growing, "GrowingMover", Vector3.new(3, 3, 3), function(f)
		return CFrame.new(ROW3 + Vector3.new(200, 0, 7) + Vector3.new(math.sin(f * 0.05) * 6, 0, 0)), Vector3.new(3, 3, 3), true
	end)
	addMember(growing, "GrowingLate", Vector3.new(3, 3, 3), function(f)
		return CFrame.new(ROW3 + Vector3.new(200, 0, -7) + Vector3.new(math.sin(f * 0.02) * 10, 0, 0)), Vector3.new(3, 3, 3), true
	end, 90)
	addMember(growing, "GrowingLeaver", Vector3.new(3, 3, 3), function(f)
		return CFrame.new(ROW3 + Vector3.new(210, 0, 0) + Vector3.new(0, f * 0.02, 0)), Vector3.new(3, 3, 3), true
	end, nil, 150)
	addMember(growing, "GrowingVisitor", Vector3.new(3, 3, 3), function(f)
		return CFrame.new(ROW3 + Vector3.new(192, 0, 0) + Vector3.new(0, 0, f * 0.05)), Vector3.new(3, 3, 3), true
	end, 70, 130)

	-- a group whose only member is removed (the group goes with it), then another joins the same
	-- Model and the group starts over
	local fleeting = addRig("Fleeting")
	addMember(fleeting, "FleetingFirst", Vector3.new(4, 4, 4), function(f)
		return CFrame.new(ROW3 + Vector3.new(250, 0, 0)), Vector3.new(4, 4, 4), true
	end, nil, 100)
	addMember(fleeting, "FleetingSecond", Vector3.new(4, 4, 4), function(f)
		return CFrame.new(ROW3 + Vector3.new(250, 0, 12)), Vector3.new(4, 4, 4), true
	end, 120)

	-- the whole group is away for much longer than the history is deep and comes back somewhere
	-- else each time: its history is dropped while it is gone and has to start over cleanly
	local vanisher = addRig("Vanisher")
	for i, offset in {Vector3.new(0, 0, 0), Vector3.new(6, 0, 0), Vector3.new(0, 5, 0)} do
		addMember(vanisher, "Vanisher" .. i, Vector3.new(4, 4, 4), function(f)
			if f % 200 >= 40 then
				return nil, Vector3.new(4, 4, 4), true
			end
			local cycle = f // 200
			return CFrame.new(ROW3 + Vector3.new(300, 0, 0) + offset + Vector3.new(0, 0, (cycle % 3) * 12 + (f % 200) * 0.1)), Vector3.new(4, 4, 4), true
		end)
	end

	-- the whole group jumps 75 studs and back, so the frames either side of a teleport are both
	-- in history, and a group's box has to cover members that are far from where they just were
	local blinkers = addRig("GroupBlinker")
	for i, offset in {Vector3.new(0, 0, 0), Vector3.new(7, 0, 0), Vector3.new(0, 4, 5)} do
		addMember(blinkers, "GroupBlinker" .. i, Vector3.new(4, 4, 4), function(f)
			local hop = f // 37
			return CFrame.new(ROW3 + Vector3.new(350, 0, 0) + offset + Vector3.new(0, 0, (hop % 4) * 25)), Vector3.new(4, 4, 4), true
		end)
	end

	-- runs, then rests for longer than the whole history, then runs again; every member rests
	-- together, and the group's leaf has to keep bounding it
	local sprinters = addRig("GroupSprinter")
	for i, offset in {Vector3.new(0, 0, 0), Vector3.new(5, 0, 0)} do
		addMember(sprinters, "GroupSprinter" .. i, Vector3.new(4, 4, 4), function(f)
			local phase = f % 260
			local travelled = (f // 260) * 30 + math.min(phase, 60) * 0.5
			return CFrame.new(ROW3 + Vector3.new(400, 0, 0) + offset + Vector3.new(0, 0, travelled % 40)), Vector3.new(4, 4, 4), true
		end)
	end

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
			tp.part.Parent = tp.parent or deps.parentFolder
			tp.part.CFrame = cf
		else
			tp.part.Parent = nil
		end

		-- PartRegister learns about Size, CanCollide and Parent through property-changed signals. Under
		-- deferred signal behaviour those don't fire until this thread yields, and the harness
		-- never does, so every size change and absence would silently never happen. Write what
		-- the observers would have written, so the run doesn't depend on the place's settings.
		for _, register in tp.registers :: {any} do
			register._currentSize = size
			register._canCollide = canCollide
			register._inWorld = cf ~= nil
		end
	end

	for f = 1, deps.framesToRun do
		local refIndex = ((f - 1) % refFrameCap) + 1
		local newIndex = ((f - 1) % newFrameCap) + 1

		for _, tp in testParts do
			if tp.added and tp.removalFrame and f >= tp.removalFrame then
				-- gone from both implementations at once
				refHH:RemovePart(tp.part)
				newHH:RemovePart(tp.part)
				tp.part.Parent = nil
				tp.added = false
				tp.removed = true
			end
			if not tp.added and not tp.removed and (tp.activationFrame == nil or f >= tp.activationFrame) then
				local regRef = deps.PartRegister.new(tp.part, refFrameCap, nil, tp.group)
				local regNew = deps.PartRegister.new(tp.part, newFrameCap, nil, tp.group)
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

			-- and one over the Models' row. They are in a row of their own so the probe above stays
			-- what it was, and a group's box sees every part of every rig
			compareShape(("f=%d rigs overlap(%d)"):format(f, backBy), refPast, newPast, 1, CFrame.new(BASE + Vector3.new(210, 60, 40)), deps.bolt.create_box(Vector3.new(440, 40, 140)))

			-- a small probe where each part was back then: a group that is only partly in the way
			-- has to be resolved part by part, and the parts that are not in it left out
			for _, tp in testParts do
				local pastCF = history[tp][f - backBy]
				if tp.added and pastCF then
					compareShape(("f=%d %s overlap-where-it-was(%d)"):format(f, tp.part.Name, backBy), refPast, newPast, 1, CFrame.new(pastCF.Position), deps.bolt.create_box(Vector3.new(5, 5, 5)))
				end
			end
		end
	end

	return {mismatches = mismatches, framesRun = deps.framesToRun, queriesRun = queriesRun}
end

return Harness
