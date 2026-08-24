# Central

Server-authoritative hitbox, raycast, and shapecast querying for Roblox, with
built-in client latency compensation.

Central keeps a short rolling history of tagged hitbox parts on the server so
that raycasts/shapecasts issued against a player are resolved against where
that player actually saw the world, not just the current frame. It measures
each player's perceived replication delay automatically (see
[How Character Latency Is Measured](#how-character-latency-is-measured)) and
rewinds hitbox history to match. History frames are grouped into blocks, each
backed by one AABB tree whose leaves are the *union* of a part's boxes across
the block (see [Union Hitboxes](#union-hitboxes)); the exact per-frame box is
still what every query is ultimately resolved against, using the
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

Every query takes the `player` it's being cast on behalf of (used to
lag-compensate against, and to resolve that player's own hitboxes live) and
an optional `querySettings`. On the client these are a plain pass-through to
their Roblox counterpart, no compensation happens. On the server, each call
runs a normal **live** query against the world right now plus a
**historical** query against that player's rewound hitbox history, and
merges them: the cast functions return whichever hit is closer, the overlap
functions union both result sets.

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
- `frameRange`: extra frames around the player's latency-resolved frame to
  search. Defaults to `Settings.RAYCAST_FRAME_RANGE` for `Raycast`,
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
- Widen `querySettings.frameRange` if jitter is causing disagreements.
- A hitbox owned by the querying player is checked live instead of
  historically, on both realms.
- Something that moves every step (e.g. a projectile shapecast each frame)
  should use a registered **query** group, not a hitbox group, so it
  doesn't physically collide with hitboxes and all its hit detection goes
  through Central.
- Your binding's step priority must be **higher** than
  `Settings.HitboxStepPriority`. Central records that step's hitbox frame
  at that priority, so a lower/equal-priority binding queries last step's
  data instead of the current one.

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
how far back its own shots are rewound, bounded by `MAX_LATENCY`. Treat
`MAX_LATENCY` as the security-relevant knob if that matters for your game.

## Union Hitboxes

`FRAME_CAP` history frames aren't each backed by their own AABB tree anymore.
They're grouped into `UNIONS_PER_PART` blocks of `UNION_SIZE` frames
(defaults: 5 × 16 = 80), each with one tree whose leaves are the *union* of a
part's boxes across the whole block, padded and (for a moving part)
extrapolated a little ahead using its previous block's measured sweep. A
query still resolves against the exact per-frame box — the union tree only
decides which parts are worth checking at all.

The old one-tree-per-frame design meant every tracked part paid for a full
`remove_leaf` + `insert_leaf` on **every** history frame: Bolt's tree has a
fast path that skips that work when a part's motion stays inside its previous
padded bounds, but a moving part almost never does across a single frame, so
the fast path essentially never fired. Grouping frames into blocks means only
the currently-active block's tree is touched per frame, and the padding
actually gets a chance to absorb a frame or two of motion before a leaf needs
rewriting.

`MAX_LATENCY` (the security-relevant rewind-distance knob, see
[above](#how-character-latency-is-measured)) is now also clamped to a derived
`LATENCY_CEILING`: the block currently being refilled holds a mix of fresh and
~`FRAME_CAP`-frame-stale data, so it's kept out of query range, capping how far
back a rewind can reach to `(UNIONS_PER_PART - 1) * UNION_SIZE` frames. At
defaults that's ~1.067s — above the authored `MAX_LATENCY` default of 1s, so
out-of-the-box behavior is unchanged. `MAX_LATENCY` can still lower the
effective cap; it can no longer author a value the ring can't honor, and
`CharacterLatency.Start` warns once at startup if it tries to.

## Performance

Measured server-side in a Studio Play session: a grid of anchored hitbox
parts (7 studs apart), all moved every frame, at default settings
(`FRAME_CAP = 80`, `UNION_SIZE = 16`, `UNIONS_PER_PART = 5`, frame range `1`,
`PREFER_NEAREST_FRAME = true`), compared against `HistoricalHitboxesRef` — the
pre-union-hitboxes implementation, kept frozen for exactly this comparison
(see `tests/DifferentialHarness.luau`, `bench/Benchmark.luau`). A Studio Play
session has more overhead than a packaged dedicated server, so treat absolute
numbers as directional; the ratios between old and new are what to trust.
Absolute numbers will also move with hardware.

**`UpdateFrame`** (the cost this redesign targets, paid once per simulation
step regardless of querying) drops 25–40%:

| hitboxes | ref (µs/hitbox) | new (µs/hitbox) | speedup |
|---|---|---|---|
| 100 | 3.71 | 2.82 | 1.32× |
| 400 | 4.13 | 2.98 | 1.39× |
| 1000 | 4.60 | 3.28 | 1.40× |

That's a real win, but smaller than the naive "every frame pays for a tree
op that should almost never fire" framing suggests: property reads
(`part.CFrame`/`part.CanCollide`, unavoidable by any tree design) are roughly
half of `UpdateFrame`'s cost, not the tree operations, so the redesign can
only ever attack the other half.

**Raycast query cost** gets measurably *worse* before accounting for one
more thing: a union leaf's envelope can cover up to `UNION_SIZE` frames of
sweep, so a tree candidate is a much weaker signal of relevance than it was
with one leaf per frame, meaning more candidates now reach the expensive
oriented test (`bolt.raycast.box`/GJK) per query. A cheap AABB pre-filter
against each candidate's exact per-frame box (already computed as a
byproduct of the union math, just reused) claws most of that back for
`Raycast`. It isn't implemented for `Shapecast`/`SimpleShapecast`/
`QueryShape` yet (would need the same idea: a swept-AABB or shape-AABB test
ahead of the GJK call), which shows in the sheets below.

**Whole-frame cost sheets**: each cell is `UpdateFrame` plus the stated
number of queries that frame, as % of one Hz60 step (16667 µs), median of 7
batches of 20 timed frames (median rather than mean specifically so one
GC pause landing in a batch doesn't skew the cell — see
`bench/Benchmark.luau`'s `measureBatched`). Row 0 hitboxes isolates query
overhead against empty trees; column 0 queries isolates `UpdateFrame` alone.
Generated with `bench/RunBenchmarkSheets.luau` — the design notes suggest a
10000-hitbox row too, but that crashed a live Studio session in practice, so
it's not included here; rerun with a larger `hitboxCounts` list in a
disposable place if you want it. Cells still carry noticeable run-to-run
variance at the high-query-count corner (a Studio Play session isn't a clean
room), so read these as directional, like the rest of this section.

**Raycast**

*Ref (pre-union-hitboxes):*

| hitboxes | 0 | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|---|
| 0 | 0.00% | 0.00% | 0.02% | 0.62% | 4.90% |
| 1 | 0.02% | 0.03% | 0.10% | 0.75% | 6.77% |
| 10 | 0.21% | 0.19% | 0.29% | 1.23% | 10.05% |
| 100 | 2.33% | 2.33% | 2.40% | 3.30% | 12.03% |
| 1000 | 27.68% | 27.42% | 27.37% | 28.47% | 40.79% |

*New (union hitboxes, with the raycast pre-filter):*

| hitboxes | 0 | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|---|
| 0 | 0.01% | 0.03% | 0.21% | 1.85% | 18.81% |
| 1 | 0.03% | 0.05% | 0.19% | 2.31% | 20.73% |
| 10 | 0.28% | 0.33% | 0.85% | 5.76% | 43.04% |
| 100 | 2.98% | 3.16% | 3.51% | 8.90% | 60.12% |
| 1000 | 40.79% | 37.32% | 37.43% | 46.25% | 119.97% |

At low-to-moderate query counts `UpdateFrame`'s savings win outright (the 0-
and 1-query columns are New's `UpdateFrame` numbers, and they're lower than
Ref's throughout). At high query counts New is behind Ref even at 0 hitboxes
— the pre-filter itself (computing a ray/AABB test ahead of the exact test)
has a small fixed per-call cost that Ref never pays, and it shows up once
you're issuing hundreds of raycasts a frame.

**SimpleShapecast** (no pre-filter yet — this is the gap a future pass would close)

*Ref:*

| hitboxes | 0 | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|---|
| 0 | 0.00% | 0.00% | 0.03% | 0.59% | 5.85% |
| 1 | 0.02% | 0.03% | 0.15% | 1.22% | 13.07% |
| 10 | 0.19% | 0.21% | 0.45% | 2.23% | 21.13% |
| 100 | 2.28% | 2.31% | 2.54% | 4.50% | 22.52% |
| 1000 | 28.97% | 28.12% | 27.94% | 30.29% | 133.20% |

*New:*

| hitboxes | 0 | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|---|
| 0 | 0.01% | 0.03% | 0.23% | 2.06% | 22.40% |
| 1 | 0.03% | 0.08% | 0.50% | 5.12% | 53.27% |
| 10 | 0.27% | 0.44% | 2.20% | 18.30% | 183.62% |
| 100 | 2.92% | 3.37% | 5.04% | 21.22% | 202.76% |
| 1000 | 41.83% | 36.14% | 40.44% | 59.83% | 265.95% |

Without a pre-filter, `SimpleShapecast` cost grows with hitbox count even at
a fixed query count (the 1000-query column climbs from 22% to 266% going
from 0 to 1000 hitboxes) — fatter envelopes mean more candidates reach GJK,
and nothing narrows them first. This is the clearest evidence in these
sheets that the pre-filter is worth extending to the shapecast paths.

The tables below (query-shape routine costs, narrow-phase behavior on a
direct hit vs. a grazing contact) describe the exact-test code paths, which
this redesign didn't touch, so they're carried over unchanged from the
pre-union-hitboxes measurement:

**Closest-hit queries used to be flat in hitbox count** — 16× the hitboxes
cost the same, because the tree pruned to the closest hit during traversal.
That still roughly holds for `HistoricalHitboxesRef`; for the union-tree
implementation it's now closer to flat-with-a-slope (see the raycast table
above) — fatter envelopes mean the traversal prunes less aggressively as the
candidate count grows, even with the pre-filter in front of the exact test.

What actually moves the cost within a single query: **whether the cast
connects** (400 hitboxes, narrow-phase-only — this table predates the
union-tree change and the exact-test code paths it measures are unchanged by
it).
A clean hit bounds the search so everything farther is skipped; a grazing
shapecast never establishes that bound, so every candidate gets tested
(~10× a direct hit):

| | `Raycast` | `Shapecast` | `SimpleShapecast` |
|---|---|---|---|
| direct hit | 0.97 µs | 1.54 µs | 1.39 µs |
| grazing contact | 1.28 µs | 14.65 µs | 14.20 µs |
| empty space | 0.76 µs | 1.02 µs | 0.92 µs |

And for overlap queries, **which shape you query with**: a hitbox is
always a box, so the test is box × your shape; box/sphere/capsule get a
dedicated routine 1.5–5× faster than the GJK fallback everything else uses:

| query shape | routine | per-call (overlapping/separated) |
|---|---|---|
| box | `box_box` | 0.14 / 0.07 µs |
| sphere | `box_sphere` | 0.13 / 0.13 µs |
| capsule | `box_capsule` | 0.24 / 0.19 µs |
| cylinder, wedge, corner wedge, ellipsoid | GJK fallback | 0.5–0.8 µs |

`GetPartBoundsInBox`/`GetBoundsInRadius` always stay on a dedicated routine;
`GetPartsInPart` derives the shape from the part you hand it, so a
Cylinder/Wedge/mesh part drops to GJK, approximate with the other two on a
hot path if the exact silhouette doesn't matter. Overlap cost overall tracks
how many hitboxes fall *inside* the query volume, not how many exist.

If you need to cut cost, reduce how many parts carry `Settings.HITBOX_TAG` —
adding query volume is comparatively cheap, per the raycast crossover point
above. (One caveat: a historical tree occasionally rebuilds, now triggered by
its block sealing rather than a wall-clock timer — see
[Union Hitboxes](#union-hitboxes); rare and staggered across trees by
construction, so it shows up in the tail, not the median.)

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
| `StepFrequency` | `Hz60` | How often Central's `BindToSimulation` loop records a hitbox frame and recomputes rewound indices. |
| `HitboxStepPriority` | `1000` | Priority Central's internal binding runs at; your own query-calling bindings need a higher number. |
| `AUTO_ADD_CHARACTERS` | `true` | Auto-tags every part of a spawning player's character as an owned hitbox. |
| `DEFAULT_HITBOX_QUERY_GROUP` | `"HitboxQuery"` | Fallback query group for an unregistered `CollisionGroup`. |
| `INITIAL_QUERY_GROUPS` | `{DEFAULT_HITBOX_QUERY_GROUP}` | Query groups auto-registered by `Central.Start()`. |
| `DEFAULT_HITBOX_COLLISIONGROUP` | `"HitboxCollison"` | Fallback hitbox group for an unregistered `CollisionGroup`. |
| `INITIAL_COLLISION_GROUPS` | `{DEFAULT_HITBOX_COLLISIONGROUP}` | Hitbox groups auto-registered by `Central.Start()`. |
| `HITBOX_TAG` | `"CompensatedHitbox"` | `CollectionService` tag marking a part as lag-compensated. |
| `OWNER_ATTRIBUTE` | `"HitboxOwner"` | Attribute holding a hitbox's owning player's `Name`. |
| `LATENCY_ATTRIBUTE` | `"PartLatency"` | Attribute Central writes each player's averaged latency to. |
| `UNION_SIZE` | `16` | History frames per union block. |
| `UNIONS_PER_PART` | `5` | Number of block trees kept per part. |
| `FRAME_CAP` | *derived* = `UNIONS_PER_PART * UNION_SIZE` (`80`) | Size of the history ring buffer; not directly editable — tune `UNION_SIZE`/`UNIONS_PER_PART` instead. |
| `LATENCY_CEILING` | *derived* ≈ `1.067s` | What the ring can actually service; see [Union Hitboxes](#union-hitboxes). `MAX_LATENCY` is clamped to this. |
| `UNION_PADDING` | `1` | Padding (studs) baked into each union leaf's bounds, replacing the old `AABB_PADDING`. Per-part and runtime-tunable, unlike a tree's own padding. |
| `UNION_PREDICTION_FRAMES` | `16` | Caps how many frames of velocity-extrapolation inflation a block's envelope gets, so one teleport frame can't poison the next block. |
| `UNION_UPDATE_FRACTION` | `0.5` | A leaf is shrunk back to tight bounds once its volume exceeds this multiple of what the current block actually needs. |
| `RAYCAST_FRAME_RANGE` | `1` | Default `querySettings.frameRange` for `Raycast`. |
| `COLLISION_FRAME_RANGE` | `1` | Default `querySettings.frameRange` for `Shapecast`/`SimpleShapecast`/overlap. |
| `PREFER_NEAREST_FRAME` | `true` | Tie-break when several frames in range produce a hit: `true` = nearest frame wins regardless of distance; `false` = spatially closest wins, ties to nearer frame. |
| `LATENCY_OFFSET` | `0` | Seconds added to each raw latency sample before clamp/average; bias compensation earlier/later. |
| `LATENCY_SAMPLE_WINDOW` | `5` | How many recent client reports are averaged into `LATENCY_ATTRIBUTE`. |
| `MAX_LATENCY` | `1` | Upper clamp (s) on a reported latency sample, itself clamped to `LATENCY_CEILING`; bounds how far a modified client can push its own rewind. |
| `LATENCY_DUMMY_HIDE_OFFSET` | `Vector3.new(0, 13337, 0)` | Where the latency measurement rig is parked, off-map. |
| `LATENCY_ORBIT_RADIUS` | `25` | Radius (studs) of the circle the two latency dummies walk. |
| `LATENCY_ANGLE_EPSILON` | `math.rad(0.1)` | How close the delayed dummy must get to the predicted dummy's recorded angle to count as caught up. |
| `LATENCY_MEASURE_TIMEOUT` | `1` | Seconds before an unconverged measurement cycle is abandoned. |
| `LATENCY_MEASURE_PAUSE` | `0.5` | Seconds between measurement cycles. |
| `RAYCAST_MARGIN` | `1e-4` | Slack added to the live-hit distance before the historical query runs, so a flush hitbox still registers. |
| `GJK_TOLERANCE` | `1e-4` | Convergence tolerance for the GJK shapecast/intersection routines. |
| `TREE_REBUILD_CHECK_INTERVAL`, `TREE_REBUILD_CHECK_JITTER` | `10`, `0.2` | Legacy, test-only — only the frozen `HistoricalHitboxesRef` reference implementation still reads these. Production trees rebuild off block seals instead; see [Union Hitboxes](#union-hitboxes). |

## Third-party code

`lib/bolt` and `lib/visualizer.luau` from
[unityjaeger/Bolt](https://github.com/unityjaeger/Bolt)

[Observers](https://sleitnick.github.io/RbxObservers/api/Observers/)
(`sleitnick/observers`), pulled in as a regular Wally dependency
