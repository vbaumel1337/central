# Central

Server-authoritative hitbox, raycast, and shapecast querying for Roblox, with
built-in client latency compensation.

Central keeps a short rolling history of tagged hitbox parts on the server so
that raycasts/shapecasts issued against a player can be resolved against
where that player actually saw the world, not just the current frame. It
uses a small client/server rig that measures each player's round-trip
latency automatically.

Each recorded frame is stored in an AABB tree, and queries against that
history, raycasts, shapecasts, and overlap checks alike, are resolved with
 collision-detection math, all thanks to the Bolt library; see [Third-party code](#third-party-code).

**Warning**: the per-player latency that drives compensation is measured
with a fairly hacky trick (see
[How Character Latency Is Measured](#how-character-latency-is-measured))
rather than a principled formula, so its accuracy isn't guaranteed to hold
under every condition. It has held up well in testing so far, but it's
worth verifying against your own game before relying on it.

## Installation

Add to your `wally.toml`:

```toml
[dependencies]
Central = "vbaumel1337/central@^0.1.0"
```

Then `wally install`.

## Examples

A runnable example place is included at
[`examples/Server Authoritative Hitboxes Demo.rbxl`](<examples/Server Authoritative Hitboxes Demo.rbxl>) —
open it in Roblox Studio to see lag-compensated hitboxes, latency
measurement, and synced client/server queries in action.

It's also playable and copyable live on Roblox:
[Server-Authoritative Hitboxes Demo](https://www.roblox.com/games/92062322926252/Server-Authoritative-Hitboxes-Demo).

## Usage

Central is a single module required from both the server and the client;
it gates its own behavior based on `RunService`.

```lua
local Central = require(ReplicatedStorage.Packages.Central)
Central.Start()
```

Call `Central.Start()` once, early, on both the server and the client
(e.g. from your bootstrap scripts) before using any of the query functions
below. Calling it more than once, or from the wrong realm, warns and no-ops.

### API

#### Queries

Every query takes the `player` it's being cast on behalf of (used to
lag-compensate against, and to resolve that player's own hitboxes live,
see [Querying hitboxes](#querying-hitboxes)) and an optional `querySettings`.
On the client these are a plain pass-through to their Roblox counterpart;
on the server they additionally merge in a lag-compensated result.

**`Central.Raycast(player, origin, direction, raycastParams?, querySettings?)`**
counterpart to `workspace:Raycast(origin, direction, raycastParams)`.
Casts a ray from `origin` in `direction` and returns the closest hit as
`(distance, instance, position, normal)` instead of a `RaycastResult`.

```lua
local distance, instance, position, normal =
    Central.Raycast(player, origin, direction, raycastParams)
```

**`Central.Shapecast(player, part, direction, raycastParams?, querySettings?)`**
counterpart to `workspace:Shapecast(part, direction, raycastParams)`.
Sweeps `part`'s shape along `direction` and returns the closest hit as
`(distance, instance, position, normal)`.

```lua
local distance, instance, position, normal =
    Central.Shapecast(player, part, direction, raycastParams)
```

**`Central.SimpleShapecast(player, part, direction, raycastParams?, querySettings?)`**
also backed by `workspace:Shapecast` on the live side, but its
lag-compensated half skips computing an exact contact point/normal, only
checking whether and how far along `direction` a hit occurs. Cheaper than
`Shapecast` when you don't need the hit position.

```lua
local distance, instance =
    Central.SimpleShapecast(player, part, direction, raycastParams)
```

**`Central.GetBoundsInRadius(player, position, radius, overlapParams?, querySettings?)`**
counterpart to `workspace:GetPartBoundsInRadius(position, radius, overlapParams)`.
Returns `{BasePart}` overlapping a sphere of `radius` at `position`.

```lua
local parts = Central.GetBoundsInRadius(player, position, radius, overlapParams)
```

**`Central.GetPartBoundsInBox(player, cframe, size, overlapParams?, querySettings?)`**
counterpart to `workspace:GetPartBoundsInBox(cframe, size, overlapParams)`.
Returns `{BasePart}` overlapping an oriented box.

```lua
local parts = Central.GetPartBoundsInBox(player, cframe, size, overlapParams)
```

**`Central.GetPartsInPart(player, part, overlapParams?, querySettings?)`**
counterpart to `workspace:GetPartsInPart(part, overlapParams)`. Returns
`{BasePart}` overlapping `part`'s own shape and position.

```lua
local parts = Central.GetPartsInPart(player, part, overlapParams)
```

#### Collision Group Registration (server only)

Server-only calls for registering the two collision-group families
described in
[Creating and Querying a Lag-compensated Hitbox](#creating-and-querying-a-lag-compensated-hitbox).
Under the hood these wrap `PhysicsService:RegisterCollisionGroup` and
`PhysicsService:CollisionGroupSetCollidable`.

**`Central.AddCollisionGroup(name)`** registers `name` as a hitbox
collision group: creates the `PhysicsService` group if it doesn't exist
yet, and sets it non-collidable with every group already registered via
`AddQueryGroup`. A tagged hitbox part whose `CollisionGroup` isn't a
registered hitbox group gets forced onto
`Settings.DEFAULT_HITBOX_COLLISIONGROUP` instead.

```lua
Central.AddCollisionGroup("EnemyHitbox")
```

**`Central.RemoveCollisionGroup(name)`** reverses that: restores
collidability between `name` and every registered query group, and stops
treating `name` as a hitbox group.

```lua
Central.RemoveCollisionGroup("EnemyHitbox")
```

**`Central.AddQueryGroup(name)`** registers `name` as a query collision
group: creates the `PhysicsService` group if needed, and sets it
non-collidable with every registered hitbox group. Pass it as
`CollisionGroup` on the `RaycastParams`/`OverlapParams` you give to the
query functions above.

```lua
Central.AddQueryGroup("EnemyQuery")
```

**`Central.RemoveQueryGroup(name)`** reverses that: restores
collidability with every registered hitbox group, and stops treating
`name` as a query group. As with `RemoveCollisionGroup`, the underlying
`PhysicsService` group is left registered rather than unregistered.

```lua
Central.RemoveQueryGroup("EnemyQuery")
```

`Settings.INITIAL_COLLISION_GROUPS`/`Settings.INITIAL_QUERY_GROUPS` are
registered automatically by `Central.Start()`; by default each just
contains `Settings.DEFAULT_HITBOX_COLLISIONGROUP`/
`Settings.DEFAULT_HITBOX_QUERY_GROUP`.

## Creating and Querying a Lag-compensated Hitbox

Central keeps hitbox parts and queries in two separate families of
collision group, and always keeps those two families non-collidable with
each other: a **hitbox** group (for the parts) never collides with a
**query** group (for the casts). That's what lets a live query skip right
past a hitbox part instead of hitting its current position, the
historical (rewound) pass is what's responsible for checking hitboxes.

### Creating a hitbox

Tag a `BasePart` with `Settings.HITBOX_TAG` (`"CompensatedHitbox"` by
default) to have the server start recording its `CFrame`, size, and
`CanCollide` every frame:

```lua
-- server
part:SetAttribute(Settings.OWNER_ATTRIBUTE, player.Name) -- optional
part.CollisionGroup = "EnemyHitbox" -- must already be registered, see below
part:AddTag(Settings.HITBOX_TAG)
```

Set the attribute and collision group *before* adding the tag, Central
only reads them once, at the moment the tag is added.

- **Owner** (`Settings.OWNER_ATTRIBUTE`): the player who already sees this
  part in the right place on their own screen, e.g. a player's own
  hitboxes, so it doesn't need to be rewound for *their* queries. Set it
  to that player's `Name`. Everyone else still gets the normal
  lag-compensated treatment against it.
- **Collision group**: must already be registered with
  `Central.AddCollisionGroup(name)`, otherwise the part is silently reset
  to `Settings.DEFAULT_HITBOX_COLLISIONGROUP`. Registering it is also what
  makes it non-collidable with query groups, per the note above.

Each recorded frame is just a `CFrame`/size/`CanCollide` snapshot, not a
simulated body, the history has no physics of its own. It's never pushed,
never falls, and never collides with anything by itself; it only exists to
be checked against when a query runs. The live part still behaves normally
in `workspace` under Roblox's own physics, recording its history doesn't
change that.

### Querying hitboxes

```lua
-- server
Central.AddQueryGroup("EnemyQuery") -- once, e.g. at bootstrap

local raycastParams = RaycastParams.new()
raycastParams.CollisionGroup = "EnemyQuery"

local distance, instance, position, normal =
    Central.Raycast(player, origin, direction, raycastParams)
```

`Central.Raycast`, `Shapecast`, `SimpleShapecast`, `GetBoundsInRadius`,
`GetPartBoundsInBox`, and `GetPartsInPart` work like their `workspace`
equivalents and take the same `RaycastParams`/`OverlapParams`:

- **On the client**, they're a plain pass-through to `workspace:Raycast`/
  etc, no lag compensation happens there.
- **On the server**, each call runs two queries and merges the results: a
  normal **live** query against the world right now, and a **historical**
  query against that player's rewound hitbox history. Raycasts/shapecasts
  return whichever hit is closer; the overlap functions union both result
  sets.

Only these properties of `RaycastParams`/`OverlapParams` are honored:
`CollisionGroup`, `RespectCanCollide`, `ExcludeInstances`,
`IncludeInstances`, and, for the overlap functions only, `MaxParts`.

If you set `CollisionGroup`, it must be registered with
`Central.AddQueryGroup(name)`, or Central quietly falls back to
`Settings.DEFAULT_HITBOX_QUERY_GROUP` instead. Registering it is what makes
it non-collidable with hitbox groups, per the note above, that's the
whole reason a custom query group needs to be registered.

`querySettings` is an optional table (server only):
`{ frameRange: number?, check: ((BasePart) -> boolean)? }`

- `frameRange`: how many extra frames around the player's latency-resolved
  frame to search. Defaults to `Settings.RAYCAST_FRAME_RANGE` for
  `Raycast`, `Settings.COLLISION_FRAME_RANGE` for the rest.
- `check`: a `(part: BasePart) -> boolean` filter for candidate hits. On
  `Raycast`/`Shapecast`/`SimpleShapecast` it also makes the live cast
  pierce through failing parts instead of stopping on them.

See [Settings](#settings) for all tunable defaults (step frequency, frame
history depth, tag/attribute names, etc).

## Getting Synced Client/Server Results Under `BindToSimulation`

For gameplay code like shooting or projectiles, bind the *same* function
to `RunService:BindToSimulation` on both the client and the server, and
call Central's query functions from inside it:

```lua
RunService:BindToSimulation(function(delta)
    if not isFiring() then
        return
    end

    local origin, direction = getAimRay()
    local distance, instance, position = Central.Raycast(player, origin, direction)

    if instance and isServer then
        applyDamage(instance)
    end
end, Settings.StepFrequency, Settings.HitboxStepPriority + 100)
```

`BindToSimulation` runs both sides off the same input for a given step,
the client just sees it instantly, and the server sees it after a network
delay. On the client, `Central.Raycast` is a plain live raycast. On the
server, it's the live+historical merge: it rewinds to the frame matching
the firing player's own latency, so it's checking against roughly the
world the client was actually looking at. Same input, same rewound world
state, so both sides usually land on the same hit, though not always,
since jitter and latency variance keep it approximate.

- Only apply real effects (damage, destroying a part) `if isServer`. The
  client's call is just for local feedback, not proof of what the server
  will decide.
- `querySettings.frameRange` widens the tolerance if jitter is causing
  disagreements.
- A hitbox owned by the querying player (`Settings.OWNER_ATTRIBUTE`) is
  checked live instead of historically, on both realms.
- For something that moves every step, like a projectile you shapecast
  each frame, give it a registered query collision group instead of a
  hitbox one, so it doesn't physically collide with hitboxes and all its
  hit detection goes through Central.
- Your `BindToSimulation` binding must use a step priority **higher** than
  `Settings.HitboxStepPriority`. Central records that step's hitbox frame
  and recomputes each player's rewound index in its own `BindToSimulation`
  callback, at `Settings.HitboxStepPriority`; if your query-calling binding
  runs first, it queries against last step's data instead of the current
  one.

## How Character Latency Is Measured

Central doesn't rely on raw network ping for `Settings.LATENCY_ATTRIBUTE`.
Instead it measures the actual delay in what a client sees, using a fairly
hacky trick: a hidden NPC, tucked far out of the way, walks back and forth
between two fixed points forever, pausing briefly at each end. The walk is
completely deterministic and replicates to every client like any other part.

Both the server and every client independently watch that walk, every
simulation step, for the exact moment the NPC crosses the walk's midpoint,
a simple, unambiguous event to detect. The server timestamps the moment
*it* sees that crossing (ground truth). Each client, watching its own
replicated copy of the NPC, sees the same crossing sometime later, and
reports that delay back to the server over a `RemoteEvent`. The gap between
the two timestamps is how far behind that player's view of the world
actually is, capturing the real, perceived replication delay (including
Roblox's own part-interpolation buffering), not just round-trip ping.

That measured delay is then multiplied by `Settings.LATENCY_MULTIPLIER`
before being written to the player's `Settings.LATENCY_ATTRIBUTE`, which is
the number Central actually rewinds hitbox history by. The multiplier
(`1.42` by default) isn't derived from anything, it's a number found
by trial and error until the numbers lined up.
```lua
LATENCY_MULTIPLIER = 1.42, -- this number was releaved to me in a dream
```

If your own testing shows compensation consistently running ahead of or
behind what players actually see, try changing `Settings.LATENCY_MULTIPLIER` 

**Warning**: because this rests on a fixed multiplier tuned against one set
of conditions rather than a derived formula, it's entirely possible for it
to drift out of accuracy under different conditions (network profile,
server tick rate, physics load, etc.). In testing so far it has held up
well, but it isn't a guarantee, keep an eye on it rather than assuming
it'll stay correct forever.

## Settings

Every tunable lives as a plain field on the table at `lib/Settings.luau`
(`Central.Settings`/`CentralServer.Settings` are the same table). Several
fields get captured into local variables the moment the package is first
required, so mutating `Central.Settings` at runtime doesn't reliably take
effect for all of them — editing `lib/Settings.luau` directly is the safest
way to change a default.

| Setting | Default | What it controls |
|---|---|---|
| `DEBUG_MODE` | `false` | Draws rays/hit boxes for every query via the vendored Bolt visualizer. Costs performance — leave off outside debugging. |
| `DEBUG_LIFETIME` | `1.5` | Seconds a debug draw stays visible before clearing. Only matters if `DEBUG_MODE` is on. |
| `StepFrequency` | `Enum.StepFrequency.Hz60` | How often Central's own `BindToSimulation` loop records a hitbox frame and recomputes each player's rewound index — see [Getting Synced Client/Server Results](#getting-synced-clientserver-results-under-bindtosimulation). |
| `HitboxStepPriority` | `1000` | The priority Central's internal `BindToSimulation` binding runs at. Your own query-calling bindings need a higher priority number than this. |
| `AUTO_ADD_CHARACTERS` | `true` | Auto-tags every part of a spawning player's character as an owned hitbox. |
| `DEFAULT_HITBOX_QUERY_GROUP` | `"HitboxQuery"` | The query collision group Central falls back to when a query's `CollisionGroup` isn't a registered query group. |
| `INITIAL_QUERY_GROUPS` | `{DEFAULT_HITBOX_QUERY_GROUP}` | Query groups registered automatically by `Central.Start()`, equivalent to calling `Central.AddQueryGroup` for each. |
| `DEFAULT_HITBOX_COLLISIONGROUP` | `"HitboxCollison"` | The collision group a tagged hitbox part is forced onto if its `CollisionGroup` isn't a registered hitbox group. |
| `INITIAL_COLLISION_GROUPS` | `{DEFAULT_HITBOX_COLLISIONGROUP}` | Hitbox groups registered automatically by `Central.Start()`, equivalent to calling `Central.AddCollisionGroup` for each. |
| `HITBOX_TAG` | `"CompensatedHitbox"` | The `CollectionService` tag that marks a `BasePart` as lag-compensated — see [Creating a hitbox](#creating-a-hitbox). |
| `OWNER_ATTRIBUTE` | `"HitboxOwner"` | Attribute holding a hitbox's owning player's `Name` — see [Creating a hitbox](#creating-a-hitbox). |
| `LATENCY_ATTRIBUTE` | `"PartLatency"` | Attribute Central writes each player's measured, multiplied latency to — see [How Character Latency Is Measured](#how-character-latency-is-measured). |
| `FRAME_CAP` | `60` | Size of the hitbox/time history ring buffer. Combined with `StepFrequency`, this bounds how far back Central can rewind (60 frames at 60 Hz ≈ 1 second by default). |
| `RAYCAST_FRAME_RANGE` | `2` | Default `querySettings.frameRange` for `Central.Raycast`. |
| `COLLISION_FRAME_RANGE` | `1` | Default `querySettings.frameRange` for `Shapecast`/`SimpleShapecast`/the overlap functions. |
| `LATENCY_MULTIPLIER` | `1.42` | Empirically-tuned factor applied to measured latency before it's written to `LATENCY_ATTRIBUTE` — see [How Character Latency Is Measured](#how-character-latency-is-measured). |
| `AABB_PADDING` | `1` | Padding (in studs) added around each hitbox's bounding box in the per-frame AABB tree, giving queries slack before the tree needs a partial rebuild as parts move. |

## Third-party code

`lib/bolt` and `lib/visualizer.luau` are vendored from
[unityjaeger/Bolt](https://github.com/unityjaeger/Bolt) (MIT). See
`lib/bolt/LICENSE`.

Central also depends on [Observers](https://sleitnick.github.io/RbxObservers/api/Observers/)
(`sleitnick/observers`), pulled in as a regular Wally dependency (see
`wally.toml`) rather than vendored — it's used to watch for tagged hitbox
parts, player/character spawns, and attribute changes.
