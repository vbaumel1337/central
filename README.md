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
- Widen `querySettings.frameRange` if jitter is causing disagreements.
- A hitbox owned by the querying player is never rewound: it resolves at the
  newest history sample rather than at that player's latency. Set
  `Settings.OWNED_HITBOX_SOURCE = "live"` to resolve it with a second
  `workspace` query against true engine geometry instead.
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

## Performance

> **Stale.** These numbers were measured before history capture was decoupled
> from the simulation step, before the per-candidate query filter was hoisted,
> and before owned hitboxes moved onto the history path. They describe the
> shipping backend at the old defaults (`FRAME_CAP = 60`, capture every step,
> frame ranges of `1`). The scaling behaviour still holds; the absolute figures
> do not. Re-measure before quoting them.

Measured server-side in Studio: a 3×3×3 grid of anchored hitbox parts
(7 studs apart), all moved and all 60 history frames populated every frame,
at default settings (`FRAME_CAP = 60`, frame ranges of `1`,
`PREFER_NEAREST_FRAME = true`). Timed against `HistoricalHitboxes` directly,
lag-compensation cost alone; `Central.Raycast`/friends add a live
`workspace` cast on top. Absolute numbers will move with hardware; the
scaling behavior is the part worth trusting.

**Closest-hit queries are flat in hitbox count**: 16× the hitboxes costs
the same, because the tree prunes to the closest hit during traversal:

| hitboxes | `Raycast` | `Shapecast` | `SimpleShapecast` | Overlap (per part) |
|---|---|---|---|---|
| 50 | 0.94 µs | 1.35 µs | 1.23 µs | 50.3 µs (1.05 µs) |
| 400 | 1.01 µs | 1.51 µs | 1.40 µs | 70.8 µs (1.11 µs) |
| 800 | 1.03 µs | 1.42 µs | 1.37 µs | 70.1 µs (1.10 µs) |

What actually moves the cost: **whether the cast connects** (400 hitboxes).
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

**Per frame**: median of 600 timed frames, each covering `UpdateFrame` plus
the stated number of queries, measured in place (so it includes the cache
pressure a query pays right after `UpdateFrame` just walked the whole tree;
a query timed alone in a tight loop looks 1.5–2× cheaper than this).

`UpdateFrame` runs once per simulation step regardless of querying, and is
roughly linear in hitbox count:

| hitboxes | per frame | per hitbox |
|---|---|---|
| 50 | 69 µs | 1.38 µs |
| 100 | 156 µs | 1.56 µs |
| 200 | 364 µs | 1.82 µs |
| 400 | 778 µs | 1.95 µs |
| 800 | 1730 µs | 2.16 µs |

Whole frame with raycasts, as a share of one 60 Hz frame (16667 µs):

| hitboxes | 0 casts | 1 | 5 | 10 | 25 | 50 | 100 |
|---|---|---|---|---|---|---|---|
| 50 | 0.4% | 0.4% | 0.5% | 0.5% | 0.6% | 0.8% | 1.3% |
| 100 | 0.9% | 1.0% | 1.1% | 1.2% | 1.3% | 1.6% | 1.9% |
| 200 | 2.2% | 2.3% | 2.3% | 2.3% | 2.5% | 2.8% | 3.3% |
| 400 | 4.7% | 5.0% | 5.1% | 5.0% | 5.2% | 5.5% | 6.1% |
| 800 | 10.4% | 10.8% | 11.6% | 11.0% | 11.7% | 11.7% | 13.2% |

Shapecasts land within noise of those raycast figures at every count; the
per-cast difference is small enough that `UpdateFrame` dominates either way:

| hitboxes | 0 casts | 1 | 5 | 10 | 25 | 50 | 100 |
|---|---|---|---|---|---|---|---|
| 50 | 0.4% | 0.4% | 0.5% | 0.5% | 0.7% | 0.9% | 1.5% |
| 100 | 1.0% | 1.0% | 1.1% | 1.1% | 1.3% | 1.6% | 2.1% |
| 200 | 2.1% | 2.3% | 2.3% | 2.3% | 2.5% | 2.8% | 3.4% |
| 400 | 4.7% | 4.9% | 4.9% | 5.1% | 5.1% | 5.4% | 6.0% |
| 800 | 11.1% | 11.1% | 11.2% | 11.7% | 11.1% | 11.9% | 12.8% |

If you need to cut cost, reduce how many parts carry `Settings.HITBOX_TAG`,
adding query volume is comparatively cheap. (One caveat on the medians: a
historical tree occasionally rebuilds (`TREE_REBUILD_CHECK_INTERVAL`) and
that frame spikes; rare and staggered across trees, so it shows up in the
tail, not the median.)

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
| `FRAME_CAP` | `20` | How many history samples are kept. The window they span is `FRAME_CAP * HISTORY_CAPTURE_DIVISOR / StepFrequency`, and has to reach `MAX_LATENCY` (20 × 3 @ 60 Hz = 1s). |
| `HISTORY_CAPTURE_DIVISOR` | `3` | Capture one history sample every N simulation steps. Roblox replicates characters at ~20 Hz, so capturing every step at 60 stored duplicates. A rewind blends the two samples it falls between, so a longer interval only costs accuracy for parts that move far within it. `1` captures every step. |
| `OWNED_HITBOX_SOURCE` | `"history"` | Where the querying player's own hitboxes resolve. `"history"` uses the history structure's newest sample; `"live"` uses a second `workspace` query against true engine geometry. Prefer `"live"` if you tag fast movers or non-box shapes. |
| `HISTORY_BACKEND` | `"trees"` | `"trees"` keeps one AABB tree per history sample. `"refit"` is the prototype: one shared topology with per-sample bounds refit bottom-up. |
| `HISTORY_REFIT_BUDGET` | `4` | `refit` backend only. How many stale samples each capture re-refits, spreading the cost of a topology change. |
| `RAYCAST_FRAME_RANGE` | `0` | Default `querySettings.frameRange` for `Raycast`. |
| `COLLISION_FRAME_RANGE` | `0` | Default `querySettings.frameRange` for `Shapecast`/`SimpleShapecast`/overlap. |
| `PREFER_NEAREST_FRAME` | `true` | Tie-break when several frames in range produce a hit: `true` = nearest frame wins regardless of distance; `false` = spatially closest wins, ties to nearer frame. |
| `TREE_REBUILD_CHECK_INTERVAL` | `10` | Seconds between balance checks on each historical AABB tree. |
| `TREE_REBUILD_CHECK_JITTER` | `0.2` | Fraction of the interval used to randomize each tree's next check, so they don't all come due together. |
| `LATENCY_OFFSET` | `0` | Seconds added to each raw latency sample before clamp/average; bias compensation earlier/later. |
| `LATENCY_SAMPLE_WINDOW` | `5` | How many recent client reports are averaged into `LATENCY_ATTRIBUTE`. |
| `MAX_LATENCY` | `1` | Upper clamp (s) on a reported latency sample; also bounds how far a modified client can push its own rewind. |
| `LATENCY_DUMMY_HIDE_OFFSET` | `Vector3.new(0, 13337, 0)` | Where the latency measurement rig is parked, off-map. |
| `LATENCY_ORBIT_RADIUS` | `25` | Radius (studs) of the circle the two latency dummies walk. |
| `LATENCY_ANGLE_EPSILON` | `math.rad(0.1)` | How close the delayed dummy must get to the predicted dummy's recorded angle to count as caught up. |
| `LATENCY_MEASURE_TIMEOUT` | `1` | Seconds before an unconverged measurement cycle is abandoned. |
| `LATENCY_MEASURE_PAUSE` | `0.5` | Seconds between measurement cycles. |
| `RAYCAST_MARGIN` | `1e-4` | Slack added to the live-hit distance before the historical query runs, so a flush hitbox still registers. |
| `GJK_TOLERANCE` | `1e-4` | Convergence tolerance for the GJK shapecast/intersection routines. |
| `AABB_PADDING` | `1` | Padding (studs) around each hitbox's bounding box in the AABB tree, giving queries slack before a partial rebuild is needed. Ignored by the `refit` backend, which stores exact bounds. |

## Third-party code

`lib/bolt` and `lib/visualizer.luau` from
[unityjaeger/Bolt](https://github.com/unityjaeger/Bolt)

[Observers](https://sleitnick.github.io/RbxObservers/api/Observers/)
(`sleitnick/observers`), pulled in as a regular Wally dependency
