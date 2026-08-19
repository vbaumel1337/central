# Central

Server-authoritative hitbox, raycast, and shapecast querying for Roblox, with
built-in client latency compensation.

Central keeps a short rolling history of tagged hitbox parts on the server so
that raycasts/shapecasts issued against a player are resolved against where
that player actually saw the world, not just the current frame. It measures
each player's perceived replication delay automatically (see
[How Character Latency Is Measured](#how-character-latency-is-measured)) and
rewinds hitbox history to match. History is sampled on its own cadence rather
than every simulation step, and a rewind is blended between the two samples it
falls between rather than snapped to the nearest one. Queries are resolved
against an AABB tree per historical sample, using the
[Bolt](https://github.com/unityjaeger/Bolt) library for the collision-detection
math.

## Installation

Add to your `wally.toml`:

```toml
[dependencies]
Central = "vbaumel1337/central@^0.2.0"
```

Then `wally install`.

## Examples

A runnable example place is included at
[`examples/Server Authoritative Hitboxes Demo.rbxl`](<examples/Server Authoritative Hitboxes Demo.rbxl>),
and playable live on Roblox:
[Server-Authoritative Hitboxes Demo](https://www.roblox.com/games/92062322926252/Server-Authoritative-Hitboxes-Demo).

**Commands**: F fires a projectile, E fires a laser gun, Q does a super jump.
(This game can lag/error occasionally, since Roblox's instance streaming is
buggy right now.)

## Usage

Central is a single module required from both the server and the client; it
gates its own behavior based on `RunService`. Call `Central.Start()` once,
early, on both realms, before using any of the functions below. Calling it
twice, or from the wrong realm, warns and no-ops.

```lua
local Central = require(ReplicatedStorage.Packages.Central)
Central.Start()
```

### Queries

Every query takes the `player` it's being cast on behalf of and an optional
`querySettings`. On the client these are a plain pass-through to their Roblox
counterpart, no compensation happens.

On the server each call resolves in three parts and merges them, with the cast
functions returning whichever hit is closest and the overlap functions unioning
the result sets:

1. **The world**, queried live through `workspace` with every compensated
   hitbox filtered out by collision group.
2. **The querying player's own hitboxes**, at the newest history sample. A
   player sees their own character where the server has it, so these are never
   rewound. `Settings.OWNED_HITBOX_SOURCE = "live"` resolves them with a second
   `workspace` query against true engine geometry instead.
3. **Everyone else's hitboxes**, rewound to what this player actually saw, and
   blended between the two history samples their latency falls between.

Each pass bounds the next: a hit from the world shortens the cast the owned
pass searches, and a hit from either shortens the compensated pass.

```lua
Central.Raycast(player, origin, direction, raycastParams?, querySettings?)          -- workspace:Raycast               -> distance, instance, position, normal
Central.Shapecast(player, part, direction, raycastParams?, querySettings?)          -- workspace:Shapecast             -> distance, instance, position, normal
Central.SimpleShapecast(player, part, direction, raycastParams?, querySettings?)    -- workspace:Shapecast, cheaper    -> distance, instance
Central.GetBoundsInRadius(player, position, radius, overlapParams?, querySettings?) -- workspace:GetPartBoundsInRadius -> {BasePart}
Central.GetPartBoundsInBox(player, cframe, size, overlapParams?, querySettings?)    -- workspace:GetPartBoundsInBox    -> {BasePart}
Central.GetPartsInPart(player, part, overlapParams?, querySettings?)                -- workspace:GetPartsInPart        -> {BasePart}
```

Only these `RaycastParams`/`OverlapParams` properties are honored:
`CollisionGroup`, `RespectCanCollide`, `ExcludeInstances`,
`IncludeInstances`, and (overlap only) `MaxParts`.

`querySettings` (server only): `{ frameRange: number?, check: ((BasePart) -> boolean)? }`
- `frameRange`: extra history samples either side of the pair the player's
  latency resolves between. The rewind is already blended to the exact time
  between those two samples, so this only matters for hitboxes that move far
  enough within one capture interval that neither sample's bounds contain them.
  Defaults to `Settings.RAYCAST_FRAME_RANGE` for `Raycast`,
  `Settings.COLLISION_FRAME_RANGE` for the rest.
- `check`: a `(part: BasePart) -> boolean` filter for candidate hits. On
  `Raycast`/`Shapecast`/`SimpleShapecast` it also makes the live cast pierce
  through failing parts instead of stopping on them.

### Collision group registration (server only)

Central keeps hitbox parts and queries in two separate, always mutually
non-collidable, families of `PhysicsService` collision group: a **hitbox**
group (for the parts) never collides with a **query** group (for the
casts). That's what lets a live query skip right past a hitbox part instead
of hitting its current position; the historical pass is what checks
hitboxes.

```lua
Central.AddCollisionGroup(name)    -- registers a hitbox group, non-collidable with every query group
Central.RemoveCollisionGroup(name) -- reverses that; leaves the PhysicsService group registered
Central.AddQueryGroup(name)        -- registers a query group, non-collidable with every hitbox group
Central.RemoveQueryGroup(name)     -- reverses that; leaves the PhysicsService group registered
```

A tagged hitbox part or query whose `CollisionGroup` isn't a registered
hitbox/query group is silently forced onto
`Settings.DEFAULT_HITBOX_COLLISIONGROUP` / `Settings.DEFAULT_HITBOX_QUERY_GROUP`.
`Settings.INITIAL_COLLISION_GROUPS` / `Settings.INITIAL_QUERY_GROUPS`
(default: just those two) are registered automatically by `Central.Start()`.

### Creating a hitbox

Tag a `BasePart` with `Settings.HITBOX_TAG` (`"CompensatedHitbox"` by
default) to have the server start recording its `CFrame`, size, and
`CanCollide` every frame. Set the attribute and collision group *before*
adding the tag. Central only reads them once, at the moment the tag is
added:

```lua
-- server
part:SetAttribute(Settings.OWNER_ATTRIBUTE, player.Name) -- optional
part.CollisionGroup = "EnemyHitbox" -- must already be registered
part:AddTag(Settings.HITBOX_TAG)
```

- **Owner** (`Settings.OWNER_ATTRIBUTE`): the player who already sees this
  part in the right place on their own screen (e.g. their own character).
  Set to that player's `Name`, their own queries check it live instead of
  rewinding it. Everyone else still gets it lag-compensated.
- Each recorded frame is just a `CFrame`/size/`CanCollide` snapshot, not a
  simulated body, the history has no physics of its own. The live part
  still behaves normally in `workspace` under Roblox's own physics.

### Debug hitbox visualization (server only)

No-ops unless `Settings.DEBUG_MODE` is `true`; when on, every query also
draws its ray/shape and hit via the vendored Bolt visualizer.

```lua
Central.ShowHitboxes(player, owner)         -- draw owner's hitboxes at player's rewound frame, i.e. what Central resolves player's queries against
Central.HideHitboxes(player, owner)         -- stop that draw
Central.ShowAllPlayerHitboxes(player)       -- like ShowHitboxes, for every other player + "Server"-owned hitboxes, recomputed live
Central.RemoveAllPlayerHitboxes(player)     -- stop that draw
```

`owner` is a player's `Name`, or `"Server"` for hitboxes with no owner
attribute. All four clean up automatically on `Players.PlayerRemoving`.

## Getting synced client/server results under `BindToSimulation`

For gameplay code like shooting, bind the *same* function to
`RunService:BindToSimulation` on both the client and server, and call
Central's query functions from inside it:

```lua
RunService:BindToSimulation(function(delta)
    local origin, direction = getAimRay()
    local distance, instance, position = Central.Raycast(player, origin, direction)

    if instance and isServer then
        applyDamage(instance)
    end
end, Settings.StepFrequency, Settings.HitboxStepPriority + 100)
```

Both sides run off the same input for a step; the client sees it instantly,
the server after a network delay. On the client, `Central.Raycast` is a
plain live raycast. On the server it rewinds to the frame matching the
firing player's own latency, so both sides usually land on the same hit
(not always, jitter and latency variance keep it approximate).

- Only apply real effects (damage, destroying a part) `if isServer`. The
  client's call is just local feedback.
- `querySettings.frameRange` defaults to `0`, because a rewind is blended to
  the exact time between two samples rather than snapped to the nearest one.
  Widen it only for hitboxes that move far enough within one capture interval
  to escape the bounds of both samples either side.
- A hitbox owned by the querying player is never rewound: it resolves at the
  newest history sample rather than at that player's latency. Set
  `Settings.OWNED_HITBOX_SOURCE = "live"` to resolve it with a second
  `workspace` query against true engine geometry instead.
- Something that moves every step (e.g. a projectile shapecast each frame)
  should use a registered **query** group, not a hitbox group, so it
  doesn't physically collide with hitboxes and all its hit detection goes
  through Central.
- Your binding's step priority must be **higher** than
  `Settings.HitboxStepPriority`. Central captures history at that priority, so
  on the steps where a capture happens a lower or equal priority binding
  resolves against the previous sample instead of the one just taken.

## How Character Latency Is Measured

Instead of raw network ping, Central measures perceived replication delay
directly. Two dummies, far away from the playing area (make sure to set `Settings.LATENCY_DUMMY_HIDE_OFFSET` to a value that ensures that, but not too far to be affected by floating point), spin around a circle. In the server, they share the exact same positions and velocities. However, in the client, one of them is set to `Enum.PredictionMode.On`, and the other `Enum.PredictionMode.Off`. Roblox has to know the part interpolation delay to use it on the prediction, so the time the unpredicted dummy is behind the predicted dummy, *is the part interpolation delay*.

Each cycle, the client records the predicted dummy's current angle, waits
for the unpredicted dummy to sweep to that same angle, and reports the time
that took over a `RemoteEvent`, that's how far behind the player's
replicated view is running, including Roblox's own interpolation buffering.
The server discards invalid samples, adds `Settings.LATENCY_OFFSET` (change this value if you feel the measures are a bit off, by default its 0), clamps
into `[0, Settings.MAX_LATENCY]`, and averages the last
`Settings.LATENCY_SAMPLE_WINDOW` samples into `Settings.LATENCY_ATTRIBUTE`,
the number hitbox history gets rewound by.

**The measurement is client-reported.** The server clamps and sanity-checks
it but doesn't independently verify it, so a modified client can influence
how far back its own shots are rewound, bounded by `MAX_LATENCY`. That bound
is not a knob: it is derived from the history window (see
[History storage](#history-storage)), so shrinking how far a client can push
its own rewind means lowering `FRAME_CAP` or `HISTORY_CAPTURE_DIVISOR`, which
shortens the window itself rather than clamping against one that outlasts it.

## History storage

History is sampled on its own cadence, not once per simulation step. Roblox
replicates player characters at roughly 20 Hz, so capturing at 60 stored two
duplicates for every real sample. `Settings.HISTORY_CAPTURE_DIVISOR` (default
`3`) captures one sample every N steps, and `FRAME_CAP` (default `20`) is how
many samples are kept.

`Settings.MAX_LATENCY` is derived from those two rather than set by hand, so
the clamp on a rewind can never outrun the history it has to resolve against.
The reachable span is `FRAME_CAP - 1` capture intervals, not `FRAME_CAP`: the
worst case is the instant after a capture, when the oldest slot has just been
overwritten. That is
`(FRAME_CAP - 1) * HISTORY_CAPTURE_DIVISOR / StepFrequency`, or `19 * 3 / 60`
= **0.95s** at the defaults. Widen the window by raising `FRAME_CAP`, and
`MAX_LATENCY` follows.

A stamp older than the oldest surviving sample is the failure this prevents:
it has no pair of samples to bracket between, so the rewind lands on the end
of the window instead of where the client actually was, and nothing reports
that it happened.

A longer interval only works because a rewind no longer snaps to a sample. The
player's latency resolves to the two samples it falls between plus how far
along it is, and the hitbox is evaluated at that blended pose. The sample
decides which hitboxes are candidates; the rewind time decides where they were.
That is strictly more accurate than picking a nearest frame, and it is most of
what `RAYCAST_FRAME_RANGE` / `COLLISION_FRAME_RANGE` existed to compensate for.
Both still default to `1` rather than `0`, for two reasons worth keeping apart.

**The rewind index is only as good as the latency estimate behind it, and that
estimate is never exact.** Blending resolves a stamp to the two samples it
falls between and interpolates, which is exact only if the stamp is. When the
estimate is off, the true bracket is an adjacent pair — and at range `0` those
samples are never traversed at all. No amount of blending recovers a sample the
query did not look at. This is the reason the range cannot be `0`.

**The broad phase bounds each sample's own pose, not the swept interval between
samples.** A hitbox that moves far enough within one capture interval can be a
candidate in neither bracket sample and so be missed at a blended pose it
genuinely occupies. Storing swept bounds per sample is the real fix; widening
the range, or dropping `HISTORY_CAPTURE_DIVISOR` to `1`, is the workaround.

The range is not free: a query that finds nothing walks every sample in range,
so it is the missing and grazing queries that pay for it, not the hits.
`PREFER_NEAREST_FRAME` stops the widening as soon as a hit exists.

### Backends

`Settings.HISTORY_BACKEND` picks how the samples are stored. Both expose
identical query semantics and results; they differ only in what they keep per
sample.

**`"refit"`** (default) separates the two things a BVH holds. Topology — which
leaves are siblings — is expensive and changes slowly, so one tree owns it and
is mutated only when a part is added or removed, plus an occasional rebuild for
quality. Bounds are cheap and change every capture, so each sample stores
nothing but a pair of `{vector}` arrays indexed by that tree's node indices. A
capture writes each part's exact AABB into its leaf slot and runs one bottom-up
pass to fill the internal nodes: linear, no restructuring, no allocation.
Queries point the tree's bounds arrays at the sample being queried, so the
broad phase is bolt's own traversal, unmodified.

**`"trees"`** keeps one bolt dynamic tree per sample, and each capture rewrites
one of them with the current pose of every hitbox. This is the original
implementation, kept as an escape hatch and as the reference `"refit"` is
differentially tested against.

Both backends answer queries with the same code. Filtering, the bracket blend,
the narrow phase, the widening walk over samples and result assembly live once
in `CentralServer/HistoryQueries.luau`; a backend supplies only the step that
genuinely differs, namely how a sample's traversal gets a tree to walk —
`"trees"` hands over that sample's own, `"refit"` points the shared one at the
sample's bounds and puts it back afterwards. So the two cannot drift apart in
query semantics, which is also what makes differential testing them meaningful.

Only the grouping is shared across samples. The boxes a query tests are still
each sample's exact per-part AABBs, so they are as tight as the per-sample
trees'. What a shared topology costs is grouping quality: two parts that are
siblings because they were near each other across the window may not be near
each other in the one sample being queried. `"refit"` also ignores
`AABB_PADDING`, since it stores exact bounds and never re-tests containment.

## Performance

Measured server-side in Roblox Studio against `perf/refit-history` at
`f2bdb18`, calling the backends and `HistoryQueries` directly rather than
through `Central.Raycast`/friends (which add a live `workspace` cast on top),
with a stub player and history filled by hand instead of through play mode.
Settings are the shipped defaults unless a table says otherwise:
`FRAME_CAP = 20`, `HISTORY_CAPTURE_DIVISOR = 3`,
`RAYCAST_FRAME_RANGE = COLLISION_FRAME_RANGE = 1`, `GJK_TOLERANCE = 1e-3`,
`PREFER_NEAREST_FRAME = true`. Every number is the median (minimum, where
noted, to filter out the rebuild stall described below) of dozens of timed
batches with a warmup pass discarded first.

`"refit"` was checked against `"trees"` before being timed: 300 randomized
grazing shapecasts spanning offsets from a clean hit to a clean miss produced
zero disagreements, and a further 500 trials concentrated in a ±0.02-stud band
around exact geometric tangency — deliberately the hardest case for two
independently-computed bounding boxes to agree on — found 36 (7%) hit/miss
classification disagreements, but the distance always matched exactly on the
trials where both backends agreed there was a hit at all. That's a
floating-point boundary effect confined to a razor-thin band around exact
tangency, not the systematic divergence the `GJK_TOLERANCE = 0.01` note in
`Settings.luau` warns about from an earlier, looser value. At `1e-3` the two
backends are interchangeable for every practical query, so the figures below
compare like with like.

### Capture cost

**This did not reproduce.** The previous version of this table measured
`"trees"` climbing from 1.06 to 1.71 µs/hitbox while `"refit"` held flat at
~0.18 µs, a 6-9× speedup credited to `"refit"` never reinserting into a tree.
Re-measured against `f2bdb18`, with every hitbox genuinely moved (3 studs,
well past `AABB_PADDING`'s 1-stud slack, so `tree:move()` takes the real
remove-and-reinsert path instead of its cheap contained-in-padding no-op)
between every capture, the two backends cost the same:

| hitboxes | `"trees"` per capture | `"refit"` per capture | `"trees"` per hitbox | `"refit"` per hitbox |
|---|---|---|---|---|
| 50 | 12.2 µs | 10.5 µs | 0.243 µs | 0.210 µs |
| 100 | 22.1 µs | 21.3 µs | 0.221 µs | 0.213 µs |
| 200 | 43.4 µs | 47.1 µs | 0.217 µs | 0.235 µs |
| 400 | 100.7 µs | 94.6 µs | 0.252 µs | 0.237 µs |
| 800 | 199.3 µs | 204.8 µs | 0.249 µs | 0.256 µs |

Both backends sit flat around 0.21-0.26 µs/hitbox regardless of count — not
just similar, genuinely flat for `"trees"` too, which is the part the old
table said shouldn't happen. Isolating just the property reads `UpdateFrame`
does (`part.CFrame`, `part.Size`) accounts for ~40 µs of a 400-hitbox capture
on its own; sweeping the movement distance from 0 to 10 studs changes the
total capture cost by less than measurement noise. Tree reinsertion genuinely
isn't the bottleneck at this scale on the bolt version this branch already
shipped (`6fe0b49`, before any of the query-path commits) — the remaining
~55-85 µs is per-part Lua bookkeeping (`register:Step()`, hitbox table field
writes) that both backends pay identically, since it sits outside the one
step that actually differs between them. Nothing on this branch touched that
bookkeeping, so this isn't a regression from these commits — the old numbers
were never re-verified against `6fe0b49`'s bolt update, and the advantage
described doesn't hold up now that they have been.

One thing the old section got right: `"refit"`'s shared tree does pay a real,
rare periodic-rebuild spike — observed up to ~2-5× a typical capture (500+ µs
against a ~110-260 µs steady state at 800 hitboxes) in this session's own
measurements. The table above is the minimum across many batches specifically
to filter that stall out and report steady-state cost; it's real, it's just
in the tail, not the typical frame.

`HISTORY_CAPTURE_DIVISOR` (default `3`) still divides amortised per-frame cost
by roughly another factor of three on top of whichever of these numbers
applies.

### Capture cost against `master`, and a live-simulation check

Two follow-up questions worth keeping separate from the table above, since
each answers something the `6fe0b49`-vs-`f2bdb18` comparison above can't.

**Is capture cost better than what's actually shipping on `master`?** Yes,
consistently, but not for a reason this branch can take credit for.
`master` predates this branch entirely — it has no `"refit"` backend at
all, only the original `HistoricalHitboxes.luau` — and its `PartRegister`
is a different design: a ring buffer of `frameCap` `PartData` tables per
part (a `FrameRegister` class, since deleted), rather than the direct
instance-mirroring the current one uses. Extracting `master`'s whole
capture pipeline (its `HistoricalHitboxes.luau`, its `PartRegister.luau`
and `FrameRegister.luau`, and its pre-`0.9.0` copy of `lib/bolt`, wired up
as an isolated parallel backend) and timing it the same way as the table
above:

| hitboxes | `master` | current (`f2bdb18`) | ratio |
|---|---|---|---|
| 50 | 19.3 µs (0.385/hitbox) | 11.6 µs (0.233/hitbox) | 1.66× |
| 100 | 37.7 µs (0.377/hitbox) | 22.4 µs (0.224/hitbox) | 1.68× |
| 200 | 76.8 µs (0.384/hitbox) | 46.7 µs (0.233/hitbox) | 1.64× |
| 400 | 169.8 µs (0.425/hitbox) | 102.9 µs (0.257/hitbox) | 1.65× |
| 800 | 375.4 µs (0.469/hitbox) | 230.5 µs (0.288/hitbox) | 1.63× |

A consistent ~1.6-1.7× improvement over `master`, at every count. But this
number conflates whatever changed in the bolt update with the `PartRegister`
redesign — both predate `6fe0b49`, both apply equally to `"trees"` and
`"refit"` on current `HEAD`, and neither is work this branch did. It answers
"has capture gotten cheaper since main" (yes), not "did `refit` make capture
cheaper" (the table above already answered that one: no).

**Does any of this hold up with the actual simulation running**, rather than
driven synchronously in Edit mode? Re-ran the same 400/800-hitbox capture
test — real per-part movement, `RunService:BindToSimulation` at
`Settings.StepFrequency`/`Settings.HitboxStepPriority`, exactly how
`CentralServer.Start()` wires it up — with Play mode actually running,
timing each live call over 5 real seconds (~300 samples) instead of a tight
synchronous loop:

| | Edit mode (isolated, min) | Play mode (live, min) | Play mode (median) | Play mode (max) |
|---|---|---|---|---|
| `"trees"` @400 | 100.7 µs | 121.2 µs | 139.6 µs | 745.7 µs |
| `"refit"` @400 | 94.6 µs | 102.7 µs | 133.6 µs | 218.5 µs |
| `master` @400 | 169.8 µs | 197.0 µs | 240.5 µs | 1004.2 µs |
| `"trees"` @800 | 199.3 µs | 202.9 µs | 286.3 µs | 1463.1 µs |
| `"refit"` @800 | 204.8 µs | 228.8 µs | 284.2 µs | 377.3 µs |
| `master` @800 | 375.4 µs | 383.1 µs | 469.7 µs | 2092.1 µs |

Both headline findings hold under real simulation: `master` stays ~1.6-1.9×
more expensive than current `HEAD`, and `"trees"`/`"refit"` stay roughly tied
with each other. The minimums track the isolated Edit-mode numbers closely
(within ~10-25%, plausible engine-scheduling overhead). What the isolated
harness *couldn't* show: the worst-case spike is considerably worse live —
`master`@800 hit 2092 µs, over 10× its own steady-state minimum, against the
~2-5× spike ratio measured in Edit mode. Plausibly the periodic full-rebuild
stall is landing on top of whatever else a real running simulation is doing
that frame (physics, GC, everything else in the test place) rather than in
isolation. Worth weighing if tail latency matters to you more than the
steady-state median — the number above the table optimizes for typical cost
and will understate the tail.

**Whole-frame cost with N raycasts**, as a share of one 60 Hz frame
(16667 µs) — `"refit"`, capture and N direct-hit raycasts timed together in
place (same cache-locality conditions the queries below were *not* measured
under), one capture assumed per sampled frame (matching how the equivalent
table used to be measured, before `HISTORY_CAPTURE_DIVISOR` existed):

| hitboxes | 0 | 1 | 5 | 10 | 25 | 50 | 100 |
|---|---|---|---|---|---|---|---|
| 50 | 0.07% | 0.07% | 0.09% | 0.11% | 0.17% | 0.27% | 0.49% |
| 100 | 0.12% | 0.16% | 0.17% | 0.27% | 0.23% | 0.35% | 0.70% |
| 200 | 0.24% | 0.29% | 0.28% | 0.29% | 0.45% | 0.46% | 0.69% |
| 400 | 0.68% | 0.63% | 0.57% | 0.59% | 0.93% | 1.00% | 1.09% |
| 800 | 1.31% | 1.16% | 1.22% | 1.11% | 1.43% | 1.53% | 2.02% |

Sharply lower than the old table at every cell (that one topped out at 13.2%
for 800 hitboxes/100 casts; this one tops out at 2.02%) — same caveat as
`master` above applies: this is stacking every generation of change since
that table was measured, not something to credit to this branch alone.

Getting a clean version of this table took a real methodology lesson worth
recording. An earlier pass, timing longer batches (30 iterations × 21
batches, several seconds per cell) for supposed extra statistical stability,
came back with 800-hitbox cells spuriously elevated 2-5× — not from a bigger
workload, but because `os.clock()` in this environment is a wall clock, not
this-script's own CPU time: it keeps advancing through real elapsed seconds
regardless of what's executing. `TREE_REBUILD_CHECK_INTERVAL` is a real
10 *seconds*, checked against that same clock. A cell whose own measurement
loop happens to run long enough to approach that threshold has a real chance
of a rebuild firing mid-measurement, landing inside every batch and making
`min()` unable to filter it out — confirmed directly: an isolated 800-hitbox
run with the longer batch parameters measured its own total wall time at
3.8s and came back clean (no spike) purely because it stayed under 10s;
another otherwise-identical run didn't. The table above uses shorter batches
(15 × 9, verified at well under a second per cell, 6.2s total for the whole
sheet) specifically to stay clear of that window. The lesson: a longer
benchmark run isn't automatically a more stable one if the thing you're
measuring has its own real-time-triggered periodic cost — it can manufacture
the exact spike it was trying to average away.

### Query cost

Closest-hit raycast, by hitbox count:

| hitboxes | `"trees"` | `"refit"` |
|---|---|---|
| 50 | 1.39 µs | 0.95 µs |
| 100 | 2.08 µs | 0.94 µs |
| 200 | 1.90 µs | 0.96 µs |
| 400 | 1.26 µs | 1.72 µs |
| 800 | 1.27 µs | 1.40 µs |

Both stay flat in hitbox count — the closest-hit pruning still does its job
regardless of backend — and neither is consistently faster than the other for
this easy case; the differences above are within run-to-run noise.

**What the query-path commits actually bought is backend-dependent.**
Isolating the code changes from the settings changes (`6fe0b49`, the branch
point, against `f2bdb18`, both reading the same current `Settings.luau` so
`GJK_TOLERANCE`/frame ranges are identical on both sides) on a grazing
shapecast — the case `93e0b7a`'s bound-based rejection and `8abdb0a`'s bracket
memo specifically target:

| | `"trees"` old → new | `"refit"` old → new |
|---|---|---|
| 400 hitboxes | 140.5 → 76.8 µs (1.77×) | 4.09 → 4.57 µs (0.90×) |
| 800 hitboxes | 192.3 → 111.1 µs (1.73×) | 3.10 → 3.32 µs (0.93×) |

`"trees"` got the predicted ~1.75× speedup. `"refit"` got very slightly
*slower* — a consistent 7-10% regression across both sizes, not noise. The
likely reason: `"refit"`'s shared, well-maintained topology already prunes a
grazing query down to a handful of candidates (3, measured directly by
instrumenting the candidate count on this exact rig) via the tree's own
bound-based traversal, so the additional per-candidate bookkeeping the bracket
memo adds (a hash table allocated and populated per query) has almost nothing
redundant left to save, and shows up as pure overhead instead. `"trees"`, with
20 independently-built, never-rebuilt-by-movement per-slot trees, has more
redundant candidates for the memo to actually skip. Put in absolute terms,
this regression barely matters: `"refit"`'s grazing query is still 20-40×
cheaper than `"trees"`'s regardless of which side of this table it's on,
because a single well-maintained topology out-prunes 20 mediocre ones far
more than a memo table costs — but the plan's premise, that the query-path
work would make both backends faster, is only half true, and the numbers say
so plainly rather than being folded into a "faster" headline.

**Cast outcome — does the cast connect** (400 hitboxes, `"refit"`). Raycast's
narrow phase (`bolt.raycast.box`) is a closed-form slab test; shapecast's
(`gjk.shapecast`) is iterative. "Grazing" for raycast is a single target
offset to exact tangency; a single candidate either way, so it isolates pure
narrow-phase cost. Shapecast/SimpleShapecast's "grazing" instead sweeps a wide
flat shape tangent to a whole layer of a packed grid, so several candidates
(3, confirmed by instrumentation, against 1 for a direct hit) sit at
comparable distance and none of them lets the closest-hit bound prune the
others early — the mechanism the code comments describe, reproduced directly
rather than assumed:

| | `Raycast` | `Shapecast` | `SimpleShapecast` |
|---|---|---|---|
| direct hit | 0.88 µs | 1.72 µs | 1.58 µs |
| grazing contact | 0.86 µs | 4.26 µs (2.5×) | 5.42 µs (3.4×) |
| empty space | 1.95 µs | 2.62 µs | 2.59 µs |

Raycast barely moves between direct and grazing — the closed-form test really
is cheap regardless of how marginal the contact is. Shapecast and
SimpleShapecast pay a real 2.5-3.4× for a grazing contact over a direct one;
smaller than the 10× the previous profile reported (measured on a different,
older grid and cast-shape construction — see the note on that profile below),
but the same shape of result, and this session's own rig, not an inherited
number. One surprise worth stating rather than smoothing over: empty space
costs *more* than a direct hit here, not less, for all three cast types. A
direct hit finds its candidate almost immediately and prunes the rest of the
tree via `maxFraction`; an empty-space cast never finds anything to prune
with, so the traversal has nothing to shortcut on. This is the opposite
ordering from the previous profile's table, which was measured on a different
grid and library version — flagged rather than reconciled, since re-deriving
that old rig's exact construction wasn't practical this session.

**The frame range's cost is real and it is paid by misses, not hits.**
`RAYCAST_FRAME_RANGE`/`COLLISION_FRAME_RANGE` moved from `0` to `1` on this
branch as a correctness fix (see [History storage](#history-storage)), and
the settings comment already says this doubles broad-phase work on the
expensive path. Measured directly (`"refit"`, 400 hitboxes, `frameRange` `0`
vs `1`):

| | `frameRange = 0` | `frameRange = 1` |
|---|---|---|
| grazing (a hit) | 4.85 µs | 4.83 µs |
| empty space (a miss) | 0.65 µs | 0.99 µs (+52%) |

A grazing contact that resolves inside the bracket pays nothing extra —
`PREFER_NEAREST_FRAME` stops the widening walk the moment a hit exists, and
the paddle rig's contact is found in the bracket both times. A genuine miss
walks the extra samples in full, +52% here. That's the honest cost of the
correctness fix: it doesn't touch the hit path, and it isn't free on the miss
path, exactly as documented, now with a number attached.

**`GJK_TOLERANCE` (`1e-4` → `1e-3`): no measurable win either way.** Timing
the same grazing shapecast rig (3 candidates) against `"refit"` at both
tolerances across several trials produced no consistent direction — results
for `1e-3` fell anywhere from 15% faster to 18% slower than `1e-4`, run to
run, which is measurement noise at a candidate count this small, not a trend.
Distance agreement between the two tolerances was exact on every configuration
tested. This branch's premise that a looser tolerance trades hit precision for
narrow-phase speed may still hold at higher candidate counts or in aggregate
over real traffic, but this session's rig can't confirm a win at either
speed or accuracy, and says so rather than picking whichever trial looked
better.

**The `QueryRaycast` bracket-memo question: measured, and the answer is no.**
The code leaves `QueryRaycast`'s narrow phase un-memoized across the bracket,
reasoning that a closed-form slab test might not cost more than the hash
lookup that would replace it. Comparing memoized and un-memoized `"refit"`
against a bracketed (`blendIndex` set) raycast, hit and miss, across several
trials: no consistent direction, results split roughly evenly between the
memo being faster and slower by amounts smaller than run-to-run noise. Left
un-memoized, confirmed rather than assumed.

### Older detailed profile

The previous version of this section carried a much more granular breakdown —
per-cast-type percentages of a 60 Hz frame, and a per-overlap-shape routine
table (`box_box`/`box_sphere`/`box_capsule` vs. the GJK fallback) — measured
at settings this branch no longer ships (`FRAME_CAP = 60`, a capture every
simulation step, `"trees"` as the only backend that existed yet). None of
those numbers were re-measured this session, and per the standard the rest of
this section holds itself to, they're dropped rather than carried forward
stale. The overlap-query dispatch itself is untouched by this branch and the
qualitative claim (dedicated routines beat the GJK fallback) is still
architecturally true — but quote a fresh measurement, not this paragraph, if
the exact multiplier matters.

## Settings

Every tunable lives on the table at `lib/Settings.luau`
(`Central.Settings`/`CentralServer.Settings` are the same table). Several
fields are captured into locals the moment the package is first required,
so editing `lib/Settings.luau` directly, not mutating `Central.Settings` at
runtime, is the safe way to change a default.

| Setting | Default | What it controls |
|---|---|---|
| `DEBUG_MODE` | `false` | Draws rays/hitboxes for every query, and gates the `Show`/`Hide`Hitboxes functions. Costs performance, leave off outside debugging. |
| `DEBUG_LIFETIME` | `1.5` | Seconds a debug draw stays visible before clearing. |
| `StepFrequency` | `Hz60` | How often Central's `BindToSimulation` loop runs. History is captured every `HISTORY_CAPTURE_DIVISOR` of those steps. |
| `HitboxStepPriority` | `1000` | Priority Central's internal binding runs at; your own query-calling bindings need a higher number. |
| `AUTO_ADD_CHARACTERS` | `true` | Auto-tags every part of a spawning player's character as an owned hitbox. |
| `DEFAULT_HITBOX_QUERY_GROUP` | `"HitboxQuery"` | Fallback query group for an unregistered `CollisionGroup`. |
| `INITIAL_QUERY_GROUPS` | `{DEFAULT_HITBOX_QUERY_GROUP}` | Query groups auto-registered by `Central.Start()`. |
| `DEFAULT_HITBOX_COLLISIONGROUP` | `"HitboxCollison"` | Fallback hitbox group for an unregistered `CollisionGroup`. |
| `INITIAL_COLLISION_GROUPS` | `{DEFAULT_HITBOX_COLLISIONGROUP}` | Hitbox groups auto-registered by `Central.Start()`. |
| `HITBOX_TAG` | `"CompensatedHitbox"` | `CollectionService` tag marking a part as lag-compensated. |
| `OWNER_ATTRIBUTE` | `"HitboxOwner"` | Attribute holding a hitbox's owning player's `Name`. |
| `LATENCY_ATTRIBUTE` | `"PartLatency"` | Attribute Central writes each player's averaged latency to. |
| `FRAME_CAP` | `20` | How many history samples are kept. The rewind window they span is `(FRAME_CAP - 1) * HISTORY_CAPTURE_DIVISOR / StepFrequency` (19 × 3 @ 60 Hz = 0.95s), and `MAX_LATENCY` is derived from it. |
| `HISTORY_CAPTURE_DIVISOR` | `3` | Capture one history sample every N simulation steps. Roblox replicates characters at ~20 Hz, so capturing every step at 60 stored duplicates. A rewind blends the two samples it falls between, so a longer interval only costs accuracy for parts that move far within it. `1` captures every step. |
| `OWNED_HITBOX_SOURCE` | `"history"` | Where the querying player's own hitboxes resolve. `"history"` uses the history structure's newest sample; `"live"` uses a second `workspace` query against true engine geometry. Prefer `"live"` if you tag fast movers or non-box shapes. |
| `HISTORY_BACKEND` | `"refit"` | `"refit"` keeps one shared topology with per-sample bounds refit bottom-up; capture cost stays flat per hitbox. `"trees"` keeps one AABB tree per history sample, the original implementation. Identical query semantics either way. |
| `HISTORY_REFIT_BUDGET` | `4` | `refit` backend only. How many stale samples each capture re-refits, spreading the cost of a topology change. |
| `RAYCAST_FRAME_RANGE` | `1` | Default `querySettings.frameRange` for `Raycast`. One sample either side of the resolved bracket, because the latency estimate that picks the bracket is never exact. |
| `COLLISION_FRAME_RANGE` | `1` | Default `querySettings.frameRange` for `Shapecast`/`SimpleShapecast`/overlap. Same reason. |
| `PREFER_NEAREST_FRAME` | `true` | Tie-break when `frameRange` widens the search and several samples produce a hit: `true` = the sample nearer the rewind wins regardless of distance; `false` = spatially closest wins, ties to the nearer sample. It also stops the widening early, which is what keeps a non-zero `frameRange` cheap on the hit path. |
| `TREE_REBUILD_CHECK_INTERVAL` | `10` | Seconds between balance checks on a historical AABB tree. Under `"trees"` that is per sample tree; under `"refit"` there is only one tree, and the check also refreshes the bounds it is rebuilt from. |
| `TREE_REBUILD_CHECK_JITTER` | `0.2` | `"trees"` backend only. Fraction of the interval used to randomize each tree's next check, so they don't all come due together. |
| `LATENCY_OFFSET` | `0` | Seconds added to each raw latency sample before clamp/average; bias compensation earlier/later. |
| `LATENCY_SAMPLE_WINDOW` | `5` | How many recent client reports are averaged into `LATENCY_ATTRIBUTE`. |
| `MAX_LATENCY` | *derived* (`0.95`) | Read-only. Upper clamp (s) on a reported latency sample, and the bound on how far a modified client can push its own rewind. Computed as `(FRAME_CAP - 1) * HISTORY_CAPTURE_DIVISOR / StepFrequency` on every read, so it tracks those three. Assigning to it warns and is ignored. |
| `LATENCY_DUMMY_HIDE_OFFSET` | `Vector3.new(0, 13337, 0)` | Where the latency measurement rig is parked, off-map. |
| `LATENCY_ORBIT_RADIUS` | `25` | Radius (studs) of the circle the two latency dummies walk. |
| `LATENCY_ANGLE_EPSILON` | `math.rad(0.1)` | How close the delayed dummy must get to the predicted dummy's recorded angle to count as caught up. |
| `LATENCY_MEASURE_TIMEOUT` | `1` | Seconds before an unconverged measurement cycle is abandoned. |
| `LATENCY_MEASURE_PAUSE` | `0.5` | Seconds between measurement cycles. |
| `RAYCAST_MARGIN` | `1e-4` | Slack added to the live-hit distance before the historical query runs, so a flush hitbox still registers. |
| `GJK_TOLERANCE` | `1e-3` | Convergence tolerance for the GJK shapecast/intersection routines. It is a stopping threshold, not an accuracy guarantee: a looser value ends the advancement loop in fewer iterations, trading hit precision for narrow phase cost. |
| `AABB_PADDING` | `1` | Padding (studs) around each hitbox's bounding box in the AABB tree, giving queries slack before a partial rebuild is needed. Ignored by the `refit` backend, which stores exact bounds. |

## Third-party code

`lib/bolt` and `lib/visualizer.luau` from
[unityjaeger/Bolt](https://github.com/unityjaeger/Bolt)

[Observers](https://sleitnick.github.io/RbxObservers/api/Observers/)
(`sleitnick/observers`), pulled in as a regular Wally dependency
