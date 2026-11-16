--!strict
local DEFAULT_HITBOX_COLLISIONGROUP = "HitboxCollison"
local DEFAULT_HITBOX_QUERY_GROUP = "HitboxQuery"

local StepFrequency = Enum.StepFrequency.Hz60

-- Depth of the hitbox history ring, in simulation frames. One Bolt temporal tree bounds the whole
-- ring: each part has a single leaf covering everywhere it has been within it -- see
-- central/README.md's "Hitbox History" section for the full design.
local FRAME_CAP = 64

local RAYCAST_FRAME_RANGE = 1
local COLLISION_FRAME_RANGE = 1

-- Enum.StepFrequency members are all named "Hz<N>" (Hz1, Hz5, Hz10, Hz15, Hz30, Hz60), so this
-- stays correct if Roblox adds a member, unlike a hardcoded name -> Hz lookup table.
local stepHz = assert(tonumber(StepFrequency.Name:sub(3)), "Enum.StepFrequency member name didn't parse as Hz<N>")

-- The deepest rewind the ring can serve. A query resolves the player's rewound frame plus
-- frameRange frames either side of it, and the older side must still be inside the ring -- one
-- frame past its end wraps around onto the newest frame instead.
local LATENCY_CEILING = (FRAME_CAP - 1 - math.max(RAYCAST_FRAME_RANGE, COLLISION_FRAME_RANGE)) / stepHz

local Settings = {
    DEBUG_MODE = false,
    DEBUG_LIFETIME = 1.5,

    StepFrequency = StepFrequency,
    HitboxStepPriority = 1000,

    AUTO_ADD_CHARACTERS  = true,

    DEFAULT_HITBOX_QUERY_GROUP = DEFAULT_HITBOX_QUERY_GROUP,
    INITIAL_QUERY_GROUPS = {DEFAULT_HITBOX_QUERY_GROUP},

    DEFAULT_HITBOX_COLLISIONGROUP = DEFAULT_HITBOX_COLLISIONGROUP,
    INITIAL_COLLISION_GROUPS = {DEFAULT_HITBOX_COLLISIONGROUP},


    HITBOX_TAG = "CompensatedHitbox",
    OWNER_ATTRIBUTE = "HitboxOwner",
    LATENCY_ATTRIBUTE = "PartLatency",

    FRAME_CAP = FRAME_CAP,
    AABB_PADDING = 1, -- studs of slack around a leaf, so a part can move a little before its leaf is rewritten
    TEMPORAL_BUCKETS = 4, -- slots the temporal tree cuts the history into; more = tighter leaves, slightly more work per sample
    TREE_REBUILD_CHECK_FRAMES = 600, -- how often (frames) the tree is checked for, and given, a partial rebuild
    LATENCY_CEILING = LATENCY_CEILING, -- derived; see the comment above. MAX_LATENCY is clamped to this.

    RAYCAST_FRAME_RANGE = RAYCAST_FRAME_RANGE,
    COLLISION_FRAME_RANGE = COLLISION_FRAME_RANGE,

    -- how a closest-hit query picks a winner when several frames in range produce a hit
    -- true  = a hit in a frame nearer the player's estimated index wins outright, regardless of distance
    -- false = the spatially closest hit across all frames in range wins (ties go to the nearer frame)
    PREFER_NEAREST_FRAME = true,

    -- Legacy, test-only: the wall-clock rebuild schedule of the original one-tree-per-frame
    -- design. Only HistoricalHitboxesRef (the frozen reference implementation
    -- tests/DifferentialHarness and bench/Benchmark diff against) still reads these. Production
    -- HistoricalHitboxes has a single tree and checks it every TREE_REBUILD_CHECK_FRAMES.
    TREE_REBUILD_CHECK_INTERVAL = 10,
    TREE_REBUILD_CHECK_JITTER = 0.2,

    LATENCY_OFFSET = 0, -- seconds added to the clamped latency measurement before it's stored
    LATENCY_SAMPLE_WINDOW = 5, -- number of recent remote reports averaged into the latency attribute
    MAX_LATENCY = 1, -- seconds; clamps client-reported latency stamps, itself clamped to LATENCY_CEILING
    LATENCY_DUMMY_HIDE_OFFSET = Vector3.new(0, 13337, 0), -- moves the latency-measurement rig out of the playable map
    LATENCY_ORBIT_RADIUS = 25, -- radius (studs) of the circle the latency dummies spin around
    LATENCY_ANGLE_EPSILON = math.rad(0.1), -- how close (radians) the delayed dummy's angle needs to be to the predicted dummy's recorded angle to count as "reached"
    LATENCY_MEASURE_TIMEOUT = 1, -- seconds; give up on a measurement if the delayed dummy never catches up
    LATENCY_MEASURE_PAUSE = 0.5, -- seconds to wait between measurements

    RAYCAST_MARGIN = 1e-4,
    GJK_TOLERANCE = 1e-4,
}


return Settings