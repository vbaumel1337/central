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

    FRAME_CAP = 60,
    RAYCAST_FRAME_RANGE = 2,
    COLLISION_FRAME_RANGE = 1,

    LATENCY_OFFSET = 0, -- seconds added to the clamped latency measurement before it's stored
    LATENCY_SAMPLE_WINDOW = 5, -- number of recent remote reports averaged into the latency attribute
    MAX_LATENCY = 1, -- seconds; clamps client-reported latency stamps (matches FRAME_CAP at Hz60)
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