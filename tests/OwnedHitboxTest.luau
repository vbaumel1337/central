--!strict
-- The querying player's own hitboxes are answered by HistoricalHitboxes at the NEWEST frame, while
-- everyone else's are answered at the rewound frame. The differential harness never gives a part
-- an owner, so nothing there exercises that; this does.
--
-- One part owned by "Alice" runs along +X at 10 studs a frame, so the frame a query is aimed at can
-- be read off its x. Alice must find it where it is NOW; Bob must find it where it WAS at his
-- rewound frame; and the params filters (exclude / include / RespectCanCollide / check) must
-- still apply to the owner's hit, since the engine no longer does it for them.
--
-- Pure module like tests/DifferentialHarness.luau: dependencies passed in.
export type Implementation = {
	name: string,
	frameCap: number,
	new: () -> any,
}

export type Deps = {
	bolt: any,
	PartRegister: any,
	implementation: Implementation,
	ownerAttribute: string,
	parentFolder: Instance,
}

export type Report = {
	failures: {string},
	checks: number,
}

local Test = {}

local STEP = 10 -- studs per frame
local LIVE_FRAME = 40
local REWIND = 3

function Test.Run(deps: Deps): Report
	local failures: {string} = {}
	local checks = 0

	local function check(ok: boolean, label: string)
		checks += 1
		if not ok then
			table.insert(failures, label)
		end
	end

	local cap = deps.implementation.frameCap
	local hh = deps.implementation.new()

	local function newPart(name: string, owner: string, position: Vector3): BasePart
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.Size = Vector3.new(4, 4, 4)
		part.CFrame = CFrame.new(position)
		part:SetAttribute(deps.ownerAttribute, owner)
		part.Parent = deps.parentFolder
		return part
	end

	local mover = newPart("OwnedMover", "Alice", Vector3.new(STEP, 0, 0))
	-- somebody else's, far away from everything below, for the include-list check
	local bystander = newPart("Bystander", "Server", Vector3.new(0, 500, 0))

	local moverRegister = deps.PartRegister.new(mover, cap)
	local bystanderRegister = deps.PartRegister.new(bystander, cap)
	hh:AddPart(moverRegister)
	hh:AddPart(bystanderRegister)

	local index = 0
	local function step(frame: number, moverX: number)
		mover.CFrame = CFrame.new(moverX, 0, 0)
		index = (index % cap) + 1
		hh:UpdateFrame(index)
	end

	for frame = 1, LIVE_FRAME do
		step(frame, frame * STEP)
	end

	local alice = {Name = "Alice"} :: any
	local bob = {Name = "Bob"} :: any
	local liveX = LIVE_FRAME * STEP
	local pastX = (LIVE_FRAME - REWIND) * STEP
	local centerIndex = ((LIVE_FRAME - REWIND - 1) % cap) + 1 -- the frame Bob's latency rewinds to

	-- a ray crossing the lane x = `x` along z, through the part's middle
	local function ray(player: any, x: number, frameRange: number, params: RaycastParams?, callback: ((BasePart) -> boolean)?)
		return hh:QueryRaycast(player, centerIndex, frameRange, Vector3.new(x, 0, 50), Vector3.new(0, 0, -100), params, callback)
	end

	local probe = deps.bolt.create_sphere(1)
	local function overlap(player: any, x: number, frameRange: number, params: OverlapParams?)
		return hh:QueryShape(player, centerIndex, frameRange, CFrame.new(x, 0, 0), probe, params, nil)
	end

	-- ---- who sees the part where ----
	local hit = ray(alice, liveX, 2)
	check(hit ~= nil and hit.instance == mover, "owner raycast should hit their own part at its live pose")
	check(hit ~= nil and hit.frameOffset == 0, "an owner's hit should be reported as frameOffset 0")

	check(ray(alice, pastX, 2) == nil, "owner raycast should NOT hit where their part used to be")
	check(ray(bob, liveX, 0) == nil, "another player should NOT hit the part at its live pose when rewound")

	hit = ray(bob, pastX, 0)
	check(hit ~= nil and hit.instance == mover and hit.frameOffset == 0, "another player should hit the part at their rewound pose")

	-- ---- the params filters now run here, not in the engine ----
	local params = RaycastParams.new()
	params.ExcludeInstances = {mover}
	check(ray(alice, liveX, 0, params) == nil, "ExcludeInstances should reject the owner's own part")

	params = RaycastParams.new()
	params.ExcludeInstances = {deps.parentFolder}
	check(ray(alice, liveX, 0, params) == nil, "ExcludeInstances naming an ancestor should reject the owner's own part")

	params = RaycastParams.new()
	params.IncludeInstances = {bystander}
	check(ray(alice, liveX, 0, params) == nil, "IncludeInstances not naming the owner's part should reject it")

	params = RaycastParams.new()
	params.IncludeInstances = {mover}
	hit = ray(alice, liveX, 0, params)
	check(hit ~= nil and hit.instance == mover, "IncludeInstances naming the owner's part should keep it")

	check(ray(alice, liveX, 0, nil, function() return false end) == nil, "the check callback should be able to reject the owner's own part")

	-- ---- shapes: tested once, at the newest frame ----
	local found = overlap(alice, liveX, 2)
	check(found[mover] ~= nil and found[mover].frameOffset == 0, "owner overlap should find their own part at its live pose")
	check(next(overlap(alice, pastX, 2)) == nil, "owner overlap should NOT find where their part used to be")
	check(overlap(bob, pastX, 1)[mover] ~= nil, "another player's overlap should find the part at their rewound pose")
	check(next(overlap(bob, liveX, 1)) == nil, "another player's overlap should NOT find the part at its live pose")

	local overlapParams = OverlapParams.new()
	overlapParams.ExcludeInstances = {mover}
	check(next(overlap(alice, liveX, 2, overlapParams)) == nil, "ExcludeInstances should reject the owner's own part in an overlap")

	-- ---- RespectCanCollide follows the live record ----
	mover.CanCollide = false
	-- PartRegister learns CanCollide through a property signal, which is deferred and so never fires
	-- while this thread runs; write what the observer would have
	moverRegister._canCollide = false
	step(LIVE_FRAME + 1, (LIVE_FRAME + 1) * STEP)
	local nowX = (LIVE_FRAME + 1) * STEP

	params = RaycastParams.new()
	params.RespectCanCollide = true
	check(ray(alice, nowX, 0, params) == nil, "RespectCanCollide should reject a non-collidable part of the owner's")
	params = RaycastParams.new()
	params.RespectCanCollide = false
	check(ray(alice, nowX, 0, params) ~= nil, "without RespectCanCollide a non-collidable part of the owner's should still hit")

	-- ---- a part that has rested far longer than the history is deep is still found, live ----
	mover.CanCollide = true
	moverRegister._canCollide = true
	for frame = LIVE_FRAME + 2, LIVE_FRAME + 2 + cap * 3 do
		step(frame, nowX)
	end
	hit = ray(alice, nowX, 2)
	check(hit ~= nil and hit.instance == mover, "owner raycast should still find a part that came to rest long ago")

	hh:Destroy()
	mover:Destroy()
	bystander:Destroy()

	return {failures = failures, checks = checks}
end

return Test
