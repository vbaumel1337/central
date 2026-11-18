--!strict
-- The parts of a tagged Model are one group in HistoricalHitboxes: one leaf in the tree, one box
-- per frame, and the members tested one by one only once the box is hit. The differential harness
-- proves the answers match the one-leaf-per-part reference; this covers what it cannot see: that
-- there really is a single leaf, that the group's owner is the Model's, that every filter still
-- applies to each member separately, and that a group is dropped when its last member goes.
--
-- Three parts (A, B, C) of a Model owned by "Alice" run along +X at 10 studs a frame, side by side,
-- so the frame a query is aimed at can be read off x, and a cast along z through one lane touches
-- exactly one member. A fourth, "D", is in a second Model nobody owns.
--
-- Pure module like tests/OwnedHitboxTest.luau: dependencies passed in.
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
local LANE = 20 -- studs between the members, along z

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

	local function newModel(name: string, owner: string?): Model
		local model = Instance.new("Model")
		model.Name = name
		if owner then
			model:SetAttribute(deps.ownerAttribute, owner)
		end
		model.Parent = deps.parentFolder
		return model
	end

	local function newPart(model: Model, name: string, position: Vector3): BasePart
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.Size = Vector3.new(4, 4, 4)
		part.CFrame = CFrame.new(position)
		part.Parent = model
		return part
	end

	-- how many leaves the history has in its tree, i.e. how many tracked records hold one
	local function leafCount(): number
		local count = 0
		for _, tracked in hh.tracker.tracked do
			if tracked.registered then
				count += 1
			end
		end
		return count
	end

	local rig = newModel("Rig", "Alice")
	local other = newModel("Other", nil)

	local movers: {BasePart} = {}
	local registers: {[BasePart]: any} = {}
	for i, name in {"A", "B", "C"} do
		local part = newPart(rig, name, Vector3.new(STEP, 0, (i - 1) * LANE))
		movers[i] = part
		registers[part] = deps.PartRegister.new(part, cap, nil, rig)
		hh:AddPart(registers[part])
	end
	local partA, partB, partC = movers[1], movers[2], movers[3]

	-- somebody else's group, far away from everything below
	local bystander = newPart(other, "D", Vector3.new(0, 500, 0))
	registers[bystander] = deps.PartRegister.new(bystander, cap, nil, other)
	hh:AddPart(registers[bystander])

	local index = 0
	local function step(x: number)
		for _, part in movers do
			part.CFrame = CFrame.new(x, 0, part.Position.Z)
		end
		index = (index % cap) + 1
		hh:UpdateFrame(index)
	end

	for frame = 1, LIVE_FRAME do
		step(frame * STEP)
	end

	local alice = {Name = "Alice"} :: any
	local bob = {Name = "Bob"} :: any
	local liveX = LIVE_FRAME * STEP
	local pastX = (LIVE_FRAME - REWIND) * STEP
	local centerIndex = ((LIVE_FRAME - REWIND - 1) % cap) + 1 -- the frame Bob's latency rewinds to

	-- a ray across lane `x`, along z, through the middle of one member
	local function ray(player: any, x: number, member: BasePart, frameRange: number, params: RaycastParams?, callback: ((BasePart) -> boolean)?)
		local z = member.Position.Z
		return hh:QueryRaycast(player, centerIndex, frameRange, Vector3.new(x, 0, z + 10), Vector3.new(0, 0, -20), params, callback)
	end

	local probe = deps.bolt.create_sphere(1)
	local function overlap(player: any, x: number, member: BasePart, frameRange: number, params: OverlapParams?, callback: ((BasePart) -> boolean)?)
		return hh:QueryShape(player, centerIndex, frameRange, CFrame.new(x, 0, member.Position.Z), probe, params, callback)
	end

	-- ---- one leaf per Model, not per part ----
	check(leafCount() == 2, ("two Models should be two leaves, got %d"):format(leafCount()))

	-- a part added after the history has started has to be told which ring slot it starts in, as
	-- CentralServer does (`register.index = GlobalTimeRegister.index`)
	local function addLate(part: BasePart, group: Instance?)
		local register = deps.PartRegister.new(part, cap, nil, group)
		register.index = index
		registers[part] = register
		hh:AddPart(register)
	end

	-- a part tagged on its own is a group of one, with a leaf of its own
	local lone = newPart(other, "Lone", Vector3.new(0, 600, 0))
	addLate(lone, nil)
	step(liveX)
	check(leafCount() == 3, ("a part tagged on its own should add a leaf, got %d in all"):format(leafCount()))

	-- a part joining a group that exists adds no leaf
	-- its own owner attribute does not matter, the Model's is the one that counts
	local joiner = newPart(rig, "Joiner", Vector3.new(liveX, 0, 3 * LANE))
	joiner:SetAttribute(deps.ownerAttribute, "Bob")
	addLate(joiner, rig)
	table.insert(movers, joiner)
	step(liveX)
	check(leafCount() == 3, ("a part joining a Model should not add a leaf, got %d in all"):format(leafCount()))

	local aliceProbe = {Name = "Alice"} :: any
	local bobProbe = {Name = "Bob"} :: any
	local joined = hh:QueryRaycast(aliceProbe, index, 0, Vector3.new(liveX, 0, 3 * LANE + 10), Vector3.new(0, 0, -20), nil, nil)
	check(joined ~= nil and joined.instance == joiner, "a part that joined a Model should be found at its live pose by the Model's owner")
	check(joined ~= nil and joined.owner == "Alice", "a part that joined a Model should report the Model's owner")
	-- rewound to a frame from before it existed, nobody but its Model's owner can see it
	joined = hh:QueryRaycast(bobProbe, index - 1, 0, Vector3.new(liveX, 0, 3 * LANE + 10), Vector3.new(0, 0, -20), nil, nil)
	check(joined == nil, "a member's own owner attribute should not make it the attribute's owner's")

	hh:RemovePart(lone)
	check(leafCount() == 2, ("removing a lone part should drop its leaf, got %d"):format(leafCount()))
	hh:RemovePart(joiner)
	table.remove(movers, #movers)

	local function advance(x: number)
		step(x)
	end

	-- ---- who sees the group where ----
	local hit = ray(alice, liveX, partA, 2)
	check(hit ~= nil and hit.instance == partA, "the Model's owner should hit member A at its live pose")
	hit = ray(alice, liveX, partC, 2)
	check(hit ~= nil and hit.instance == partC and hit.frameOffset == 0, "the Model's owner should hit member C at its live pose, as frameOffset 0")
	check(ray(alice, pastX, partB, 2) == nil, "the Model's owner should NOT hit where member B used to be")

	check(ray(bob, liveX, partA, 0) == nil, "another player should NOT hit a member at its live pose when rewound")
	for _, member in {partA, partB, partC} do
		hit = ray(bob, pastX, member, 0)
		check(hit ~= nil and hit.instance == member, ("another player should hit member %s at their rewound pose"):format(member.Name))
	end

	-- ---- the params filters apply to each member, not to the group ----
	local params = RaycastParams.new()
	params.ExcludeInstances = {partA}
	check(ray(bob, pastX, partA, 0, params) == nil, "ExcludeInstances should reject the member it names")
	hit = ray(bob, pastX, partB, 0, params)
	check(hit ~= nil and hit.instance == partB, "ExcludeInstances naming one member should leave the others of its Model")

	params = RaycastParams.new()
	params.ExcludeInstances = {rig}
	check(ray(bob, pastX, partB, 0, params) == nil, "ExcludeInstances naming the Model should reject its members")

	params = RaycastParams.new()
	params.IncludeInstances = {partB}
	check(ray(bob, pastX, partA, 0, params) == nil, "IncludeInstances not naming a member should reject it")
	hit = ray(bob, pastX, partB, 0, params)
	check(hit ~= nil and hit.instance == partB, "IncludeInstances naming a member should keep it")

	check(ray(bob, pastX, partA, 0, nil, function(part) return part ~= partA end) == nil, "the check callback should be able to reject one member")
	hit = ray(bob, pastX, partC, 0, nil, function(part) return part ~= partA end)
	check(hit ~= nil and hit.instance == partC, "the check callback rejecting one member should leave the others")

	-- the owner's own hits are filtered the same way
	params = RaycastParams.new()
	params.ExcludeInstances = {partC}
	check(ray(alice, liveX, partC, 0, params) == nil, "ExcludeInstances should reject the owner's member")
	hit = ray(alice, liveX, partA, 0, params)
	check(hit ~= nil and hit.instance == partA, "ExcludeInstances naming one member should leave the owner's others")

	-- ---- shapes: member by member ----
	local found = overlap(bob, pastX, partB, 1)
	check(found[partB] ~= nil and found[partA] == nil and found[partC] == nil, "an overlap over one member should find that member only")
	check(next(overlap(bob, liveX, partB, 0)) == nil, "another player's overlap should NOT find a member at its live pose")
	found = overlap(alice, liveX, partB, 1)
	check(found[partB] ~= nil and found[partB].frameOffset == 0, "the owner's overlap should find a member at its live pose")
	check(next(overlap(alice, pastX, partB, 0)) == nil, "the owner's overlap should NOT find where a member used to be")

	local overlapParams = OverlapParams.new()
	overlapParams.ExcludeInstances = {partB}
	check(next(overlap(bob, pastX, partB, 1, overlapParams)) == nil, "ExcludeInstances should reject the member it names in an overlap")
	check(next(overlap(bob, pastX, partB, 1, nil, function(part) return part ~= partB end)) == nil, "the check callback should reject a member in an overlap")

	-- MaxParts counts parts, not groups
	local everything = deps.bolt.create_box(Vector3.new(40, 40, 200))
	local limited = OverlapParams.new()
	limited.MaxParts = 2
	local count = 0
	for _ in hh:QueryShape(bob, centerIndex, 0, CFrame.new(pastX, 0, LANE), everything, limited, nil) do
		count += 1
	end
	check(count == 2, ("MaxParts = 2 should stop an overlap after two parts of a group, got %d"):format(count))

	-- ---- RespectCanCollide follows each member's own record ----
	partA.CanCollide = false
	-- PartRegister learns CanCollide through a property signal, which is deferred and so never fires
	-- while this thread runs; write what the observer would have
	registers[partA]._canCollide = false
	advance(liveX + STEP)
	local nowX = liveX + STEP

	params = RaycastParams.new()
	params.RespectCanCollide = true
	check(ray(alice, nowX, partA, 0, params) == nil, "RespectCanCollide should reject a non-collidable member")
	hit = ray(alice, nowX, partB, 0, params)
	check(hit ~= nil and hit.instance == partB, "RespectCanCollide should leave the collidable members of the same Model")
	params = RaycastParams.new()
	params.RespectCanCollide = false
	check(ray(alice, nowX, partA, 0, params) ~= nil, "without RespectCanCollide a non-collidable member should still hit")
	partA.CanCollide = true
	registers[partA]._canCollide = true

	-- ---- a group that has rested far longer than the history is deep is still found ----
	for _ = 1, cap * 3 do
		step(nowX)
	end
	for _, member in {partA, partB, partC} do
		hit = ray(alice, nowX, member, 2)
		check(hit ~= nil and hit.instance == member, ("a group that came to rest long ago should still be found: %s"):format(member.Name))
	end

	-- ---- removing every member drops the group ----
	hh:RemovePart(partA)
	check(leafCount() == 2, "removing one member of a group should keep the group's leaf")
	hit = ray(alice, nowX, partB, 0)
	check(hit ~= nil and hit.instance == partB, "the members left after a removal should still be found")
	check(ray(alice, nowX, partA, 0) == nil, "a removed member should no longer be found")
	hh:RemovePart(partB)
	hh:RemovePart(partC)
	check(leafCount() == 1, ("removing every member should untrack the group, %d leaves left"):format(leafCount()))
	check(ray(alice, nowX, partC, 0) == nil, "nothing should be found once every member is removed")
	check(hh.groupsByKey[rig] == nil, "the Model should be gone from the history's groups once emptied")

	-- a Model that lost every member and got one back starts a fresh group
	local fresh = newPart(rig, "Fresh", Vector3.new(nowX, 0, 0))
	addLate(fresh, rig)
	table.insert(movers, fresh)
	step(nowX)
	hit = ray(alice, nowX, fresh, 0)
	check(hit ~= nil and hit.instance == fresh, "a Model that got a member back after being emptied should be found again")
	check(leafCount() == 2, ("an emptied Model that got a member back should have one leaf again, got %d"):format(leafCount()))

	hh:Destroy()
	rig:Destroy()
	other:Destroy()

	return {failures = failures, checks = checks}
end

return Test
