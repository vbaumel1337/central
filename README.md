# Central

Server-authoritative hitbox, raycast, and shapecast querying for Roblox, with
built-in client latency compensation.

Central keeps a short rolling history of tagged hitbox parts on the server so
that raycasts/shapecasts issued against a player can be resolved against
where that player actually saw the world, not just the current frame. It
also ships a small client/server rig that measures each player's round-trip
latency automatically.

## Installation

Add to your `wally.toml`:

```toml
[dependencies]
Central = "vbaumel1337/central@^0.1.0"
```

Then `wally install`.

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

- `Central.Raycast(player, origin, direction, raycastParams?, querySettings?)`
- `Central.Shapecast(player, part, direction, raycastParams?, querySettings?)`
- `Central.SimpleShapecast(player, part, direction, raycastParams?, querySettings?)`
- `Central.GetBoundsInRadius(player, position, radius, overlapParams?, querySettings?)`
- `Central.GetPartBoundsInBox(player, cframe, size, overlapParams?, querySettings?)`
- `Central.GetPartsInPart(player, part, overlapParams?, querySettings?)`
- `Central.AddCollisionGroup(name)` / `Central.RemoveCollisionGroup(name)` (server only)
- `Central.AddQueryGroup(name)` / `Central.RemoveQueryGroup(name)` (server only)

`querySettings` is an optional table: `{ frameRange: number?, check: ((BasePart) -> boolean)? }`.

Tag any `BasePart` you want lag-compensated with `Settings.HITBOX_TAG`
(`"CompensatedHitbox"` by default) and, optionally, set the
`Settings.OWNER_ATTRIBUTE` attribute to a player's name to have it excluded
from that player's own historical queries.

See `lib/Settings.luau` for all tunable defaults (step frequency, frame
history depth, tag/attribute names, etc).

## Third-party code

`lib/bolt` and `lib/visualizer.luau` are vendored from
[unityjaeger/Bolt](https://github.com/unityjaeger/Bolt) (MIT). See
`lib/bolt/LICENSE`.
