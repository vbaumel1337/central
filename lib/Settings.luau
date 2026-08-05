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

    LATENCY_MULTIPLIER = 1.42, -- this number was releaved to me in a dream
    MAX_LATENCY = 1, -- seconds; clamps client-reported latency stamps (matches FRAME_CAP at Hz60)
    LATENCY_STAMP_HISTORY = 3, -- how many recent dummy crossings to keep timestamps for
    LATENCY_DUMMY_STEP_INTERVAL = 0.5, -- seconds the latency dummy pauses at each end of its platform
    LATENCY_DUMMY_HIDE_OFFSET = Vector3.new(0, 13337, 0), -- moves the latency-measurement rig out of the playable map

    RAYCAST_MARGIN = 1e-4,
    GJK_TOLERANCE = 1e-4,

    AABB_PADDING = 1,
}


return Settings