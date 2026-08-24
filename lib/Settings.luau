--!strict
local DEFAULT_HITBOX_COLLISIONGROUP = "HitboxCollison"
local DEFAULT_HITBOX_QUERY_GROUP = "HitboxQuery"

local StepFrequency = Enum.StepFrequency.Hz60

-- Union hitboxes: history frames are grouped into blocks, one Bolt tree per block, whose leaves
-- are the union of a part's boxes over the block. UNION_SIZE frames per block, UNIONS_PER_PART
-- block trees -- see central/README.md's "Union Hitboxes" section for the full design.
local UNION_SIZE = 16
local UNIONS_PER_PART = 5
local FRAME_CAP = UNIONS_PER_PART * UNION_SIZE -- derived: size of the history ring buffer

-- Enum.StepFrequency members are all named "Hz<N>" (Hz1, Hz5, Hz10, Hz15, Hz30, Hz60), so this
-- stays correct if Roblox adds a member, unlike a hardcoded name -> Hz lookup table.
local stepHz = assert(tonumber(StepFrequency.Name:sub(3)), "Enum.StepFrequency member name didn't parse as Hz<N>")

-- The block currently being refilled holds a mix of new frames and ~FRAME_CAP-frame-stale ones,
-- so it's treated as out of service; the ceiling only covers the other (UNIONS_PER_PART - 1) blocks.
local LATENCY_CEILING = (UNIONS_PER_PART - 1) * UNION_SIZE / stepHz

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
    UNION_SIZE = UNION_SIZE,
    UNIONS_PER_PART = UNIONS_PER_PART,
    UNION_PADDING = 1, -- replaces AABB_PADDING; baked into each leaf's half_extents (see writeLeaf)
    UNION_PREDICTION_FRAMES = 16, -- cap on velocity-extrapolation inflation (teleport guard)
    UNION_UPDATE_FRACTION = 0.5, -- shrink a leaf's envelope once it exceeds this multiple of the volume it needs
    LATENCY_CEILING = LATENCY_CEILING, -- derived; see the comment above. MAX_LATENCY is clamped to this.

    RAYCAST_FRAME_RANGE = 1,
    COLLISION_FRAME_RANGE = 1,

    -- how a closest-hit query picks a winner when several frames in range produce a hit
    -- true  = a hit in a frame nearer the player's estimated index wins outright, regardless of distance
    -- false = the spatially closest hit across all frames in range wins (ties go to the nearer frame)
    PREFER_NEAREST_FRAME = true,

    -- Legacy, test-only: the pre-union-hitboxes wall-clock rebuild schedule. Only
    -- HistoricalHitboxesRef (the frozen reference implementation tests/DifferentialHarness and
    -- bench/Benchmark diff against) still reads these. Production HistoricalHitboxes drives
    -- should_rebuild/partial_rebuild off block seals instead (see UnionRegister:Seal), which are
    -- already staggered by construction, so these no longer need a runtime equivalent.
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