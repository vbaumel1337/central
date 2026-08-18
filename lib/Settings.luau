--!strict
local DEFAULT_HITBOX_COLLISIONGROUP = "HitboxCollison"
local DEFAULT_HITBOX_QUERY_GROUP = "HitboxQuery"

local Settings = {
    DEBUG_MODE = false,
    DEBUG_LIFETIME = 1.5,

    StepFrequency = Enum.StepFrequency.Hz60,
    HitboxStepPriority = 1000,

    AUTO_ADD_CHARACTERS  = true,

    DEFAULT_HITBOX_QUERY_GROUP = DEFAULT_HITBOX_QUERY_GROUP,
    INITIAL_QUERY_GROUPS = {DEFAULT_HITBOX_QUERY_GROUP},

    DEFAULT_HITBOX_COLLISIONGROUP = DEFAULT_HITBOX_COLLISIONGROUP,
    INITIAL_COLLISION_GROUPS = {DEFAULT_HITBOX_COLLISIONGROUP},


    HITBOX_TAG = "CompensatedHitbox",
    OWNER_ATTRIBUTE = "HitboxOwner",
    LATENCY_ATTRIBUTE = "PartLatency",

    -- how many history samples are kept. The window they cover is
    -- FRAME_CAP * HISTORY_CAPTURE_DIVISOR / StepFrequency, which has to reach MAX_LATENCY.
    FRAME_CAP = 20,
    -- capture one sample every N simulation steps. Roblox replicates player characters at about
    -- 20Hz, so capturing at 60 stored two duplicates for every real sample. A rewind resolves by
    -- blending the two samples it falls between, so a longer interval costs accuracy only for
    -- parts that move far within it, not for characters.
    -- Set to 1 to capture every step, which restores the old sampling.
    HISTORY_CAPTURE_DIVISOR = 3,
    -- extra samples either side of the resolved bracket to search. The bracket is already the
    -- exact rewind time, so this exists for hitboxes that move far enough between captures that
    -- the bracket's own bounds might not contain them.
    RAYCAST_FRAME_RANGE = 0,
    COLLISION_FRAME_RANGE = 0,

    -- how a closest-hit query picks a winner when several frames in range produce a hit
    -- true  = a hit in a frame nearer the player's estimated index wins outright, regardless of distance
    -- false = the spatially closest hit across all frames in range wins (ties go to the nearer frame)
    PREFER_NEAREST_FRAME = true,

    -- which history backend CentralServer builds: "trees" is the shipping one (one dynamic tree
    -- per historical frame), "refit" is the prototype (one shared topology, per-frame bounds
    -- refit bottom-up). Both expose the same interface and the same query semantics.
    HISTORY_BACKEND = "trees" :: "trees" | "refit",
    -- refit backend only: how many stale history slots UpdateFrame re-refits per frame. A part
    -- being added or removed restructures the shared topology and invalidates every slot's
    -- internal nodes at once, and this spreads that cost instead of landing it on one query.
    HISTORY_REFIT_BUDGET = 4,

    -- seconds between should_rebuild checks on each historical tree. the check is a full scan over
    -- the tree's nodes, so running it on every frame update is wasteful when the trees stay balanced
    TREE_REBUILD_CHECK_INTERVAL = 10,
    -- fraction of the interval used to randomise each tree's next check, on top of the even initial
    -- stagger, so the trees never drift into checking (and rebuilding) on the same frame
    TREE_REBUILD_CHECK_JITTER = 0.2,

    LATENCY_OFFSET = 0, -- seconds added to the clamped latency measurement before it's stored
    LATENCY_SAMPLE_WINDOW = 5, -- number of recent remote reports averaged into the latency attribute
    MAX_LATENCY = 1, -- seconds; clamps client-reported latency stamps (must not exceed the history window, see FRAME_CAP)
    LATENCY_DUMMY_HIDE_OFFSET = Vector3.new(0, 13337, 0), -- moves the latency-measurement rig out of the playable map
    LATENCY_ORBIT_RADIUS = 25, -- radius (studs) of the circle the latency dummies spin around
    LATENCY_ANGLE_EPSILON = math.rad(0.1), -- how close (radians) the delayed dummy's angle needs to be to the predicted dummy's recorded angle to count as "reached"
    LATENCY_MEASURE_TIMEOUT = 1, -- seconds; give up on a measurement if the delayed dummy never catches up
    LATENCY_MEASURE_PAUSE = 0.5, -- seconds to wait between measurements

    RAYCAST_MARGIN = 1e-4,
    GJK_TOLERANCE = 1e-4,

    AABB_PADDING = 1,
}


return Settings