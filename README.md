# Central

Server-authoritative hitbox, raycast, and shapecast querying for Roblox, with
built-in client latency compensation.

Central keeps a short rolling history of tagged hitbox parts on the server so
that raycasts/shapecasts issued against a player are resolved against where
that player actually saw the world, not just the current frame. It measures
each player's perceived replication delay automatically and rewinds hitbox
history to match.

See [DOCUMENTATION.md](DOCUMENTATION.md) for the full reference, including
alternate settings, backend internals, and how latency measurement works.

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

## Usage

Central is a single module required from both the server and the client; it
gates its own behavior based on `RunService`. Call `Central.Start()` once,
early, on both realms, before using any of the functions below.

```lua
local Central = require(ReplicatedStorage.Packages.Central)
Central.Start()
```

### Queries

Every query takes the `player` it's being cast on behalf of and an optional
`querySettings`. On the server, results are automatically lag-compensated
against that player's own measured latency; on the client they're a plain
pass-through to their Roblox counterpart.

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

### Collision group registration (server only)

Central keeps hitbox parts and queries in two separate, always mutually
non-collidable, families of `PhysicsService` collision group: a **hitbox**
group (for the parts) never collides with a **query** group (for the casts).

```lua
Central.AddCollisionGroup(name)    -- registers a hitbox group, non-collidable with every query group
Central.AddQueryGroup(name)        -- registers a query group, non-collidable with every hitbox group
```

### Creating a hitbox

Tag a `BasePart` with `Settings.HITBOX_TAG` (`"CompensatedHitbox"` by
default) to have the server start recording its `CFrame`, size, and
`CanCollide` every frame. Set the attribute and collision group *before*
adding the tag:

```lua
-- server
part:SetAttribute(Settings.OWNER_ATTRIBUTE, player.Name) -- optional, marks the part as this player's own
part.CollisionGroup = "EnemyHitbox" -- must already be registered
part:AddTag(Settings.HITBOX_TAG)
```

### Getting synced client/server results under `BindToSimulation`

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

Only apply real effects (damage, destroying a part) `if isServer` — the
client's call is just local feedback. Your binding's step priority must be
**higher** than `Settings.HitboxStepPriority`.

## Key settings

Every tunable lives on the table at `lib/Settings.luau`
(`Central.Settings`/`CentralServer.Settings` are the same table). The
defaults below are the most efficient configuration; see
[DOCUMENTATION.md](DOCUMENTATION.md) for every tunable and when you'd want to
change one.

| Setting | Default | What it controls |
|---|---|---|
| `StepFrequency` | `Hz60` | How often Central's `BindToSimulation` loop runs. |
| `HitboxStepPriority` | `1000` | Priority Central's internal binding runs at; your own query-calling bindings need a higher number. |
| `FRAME_CAP` | `20` | How many history samples are kept. |
| `HISTORY_CAPTURE_DIVISOR` | `3` | Capture one history sample every N simulation steps. |
| `HISTORY_BACKEND` | `"refit"` | Shares one AABB tree topology across history samples, refitting bounds per sample. Cheapest backend at every measured hitbox count. |
| `HITBOX_TAG` | `"CompensatedHitbox"` | `CollectionService` tag marking a part as lag-compensated. |
| `OWNER_ATTRIBUTE` | `"HitboxOwner"` | Attribute holding a hitbox's owning player's `Name`. |
| `DEBUG_MODE` | `false` | Draws rays/hitboxes for every query. Leave off outside debugging. |

## Performance

Average server CPU cost per frame, as a % of one 60Hz frame's 16667µs budget,
by hitbox count (rows) and casts issued that same frame (columns). Measured
at the shipped defaults (`FRAME_CAP = 20`, `HISTORY_CAPTURE_DIVISOR = 3`,
60Hz capture cadence, `HISTORY_BACKEND = "refit"`, `RAYCAST_FRAME_RANGE =
COLLISION_FRAME_RANGE = 1`, `GJK_TOLERANCE = 1e-3`, `PREFER_NEAREST_FRAME =
true`), server-side in Roblox Studio, driving `HistoricalRefit` and
`HistoryQueries` directly (bypassing `Central.Raycast`/`Central.Shapecast`'s
live-`workspace` pass) so the numbers isolate Central's own cost. Hitboxes
are static 2×2×2 parts scattered through a cube; casts originate from a
fixed point and aim at random points inside that cube, a mixed hit/graze/miss
workload. Each cell averages 60 simulated steps (~1s). 0 hitboxes/0 casts
isn't exactly 0% — that's the harness's own loop overhead. A cell over 100%
means that configuration alone exceeds a single 60Hz frame's budget.

### Raycast

| hitboxes \ casts/frame | 0 | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|---|
| 0 | 0.02% | 0.06% | 0.09% | 0.74% | 4.00% |
| 10 | 0.05% | 0.13% | 0.20% | 1.00% | 8.38% |
| 100 | 0.14% | 0.24% | 0.33% | 1.47% | 13.29% |
| 1,000 | 0.90% | 1.04% | 1.32% | 3.42% | 24.98% |
| 10,000 | 9.03% | 9.33% | 10.12% | 15.26% | 62.41% |

### Shapecast

| hitboxes \ casts/frame | 0 | 1 | 10 | 100 | 1000 |
|---|---|---|---|---|---|
| 0 | 0.02% | 0.08% | 0.11% | 0.44% | 4.85% |
| 10 | 0.05% | 0.14% | 0.23% | 1.48% | 10.62% |
| 100 | 0.14% | 0.26% | 0.40% | 1.64% | 14.77% |
| 1,000 | 1.14% | 1.04% | 1.43% | 4.00% | 26.67% |
| 10,000 | 8.53% | 8.49% | 12.59% | 15.13% | 57.89% |

## Third-party code

`lib/bolt` and `lib/visualizer.luau` from
[unityjaeger/Bolt](https://github.com/unityjaeger/Bolt)

[Observers](https://sleitnick.github.io/RbxObservers/api/Observers/)
(`sleitnick/observers`), pulled in as a regular Wally dependency
