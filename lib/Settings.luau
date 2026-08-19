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

    -- how many history samples are kept. The rewind window they cover is
    -- (FRAME_CAP - 1) * HISTORY_CAPTURE_DIVISOR / StepFrequency seconds, and MAX_LATENCY is
    -- derived from it below. Raise this to rewind further back.
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
    --
    -- Set to 1 rather than 0, for two reasons that are easy to conflate.
    --
    -- The first and the reason it cannot be 0: the rewind index is only as good as the latency
    -- estimate behind it, and that estimate is never exact. Blending resolves a stamp to the two
    -- samples it falls between and interpolates, which is exact only if the stamp is. When the
    -- estimate is off, the true bracket is an adjacent pair, and at range 0 those slots are never
    -- traversed at all - no amount of blending recovers a sample the query never looked at.
    --
    -- The second: the broad phase bounds each sample's own pose, not the swept interval between
    -- samples, so a fast mover can be a candidate in neither bracket slot and be missed at a
    -- blended pose it genuinely occupies. Per-sample swept bounds are the real fix for that one.
    --
    -- Blending made this unnecessary for accuracy *between* two correctly chosen samples. It did
    -- not make the estimate that chooses them exact, and it did not make the broad phase see
    -- motion between captures.
    --
    -- It is not free. A query that finds nothing walks every slot in range, so this doubles the
    -- broad phase work in exactly the grazing and empty-space cases that are the expensive ones.
    -- PREFER_NEAREST_FRAME keeps the hit path cheap by stopping as soon as a hit exists.
    RAYCAST_FRAME_RANGE = 1,
    COLLISION_FRAME_RANGE = 1,

    -- how a closest-hit query picks a winner when several frames in range produce a hit
    -- true  = a hit in a frame nearer the player's estimated index wins outright, regardless of distance
    -- false = the spatially closest hit across all frames in range wins (ties go to the nearer frame)
    PREFER_NEAREST_FRAME = true,

    -- where the querying player's OWN hitboxes are resolved. They are never lag compensated
    -- (a player sees their own character where the server has it), so either way they resolve at
    -- "now"; this only picks which structure answers.
    --   "history" - the history structure at its newest sample. One traversal, filters handled
    --               internally, and `check` costs nothing extra. Owned parts resolve against the
    --               same box approximation as everyone else's, and are up to one capture interval
    --               stale rather than live.
    --   "live"    - a second workspace query with IncludeInstances set to the owned parts. True
    --               engine geometry and genuinely current, at the cost of marshalling the include
    --               list per query and, when `check` is set, an iterative exclude-and-retry loop.
    -- Prefer "live" if you tag fast movers (projectiles, vehicles) or non-box shapes as hitboxes.
    OWNED_HITBOX_SOURCE = "history" :: "history" | "live",

    -- which history backend CentralServer builds. Both expose the same interface and the same
    -- query semantics; they differ only in what they keep per sample.
    --   "refit" - one tree owning topology, mutated only when a part is added or removed, plus a
    --             pair of bounds arrays per sample refit bottom-up on capture. Capture cost is
    --             flat per hitbox where "trees" climbs with count, and queries are no slower.
    --   "trees" - one dynamic tree per sample, rewritten in full every capture. The original
    --             implementation, kept as an escape hatch and as the reference that "refit" is
    --             differentially tested against.
    HISTORY_BACKEND = "refit" :: "trees" | "refit",
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
    LATENCY_DUMMY_HIDE_OFFSET = Vector3.new(0, 13337, 0), -- moves the latency-measurement rig out of the playable map
    LATENCY_ORBIT_RADIUS = 25, -- radius (studs) of the circle the latency dummies spin around
    LATENCY_ANGLE_EPSILON = math.rad(0.1), -- how close (radians) the delayed dummy's angle needs to be to the predicted dummy's recorded angle to count as "reached"
    LATENCY_MEASURE_TIMEOUT = 1, -- seconds; give up on a measurement if the delayed dummy never catches up
    LATENCY_MEASURE_PAUSE = 0.5, -- seconds to wait between measurements

    RAYCAST_MARGIN = 1e-4,
    --how close gjk has to get before it accepts a contact. it is a convergence threshold, not an
    --accuracy guarantee: a looser value ends the advancement loop in fewer iterations, so it
    --trades hit precision for narrow phase cost. Not yet measured at this value.
    GJK_TOLERANCE = 1e-3,

    AABB_PADDING = 1,
}


--The clamp on a client-reported latency stamp, in seconds.
--
--This used to be a hand-set number, which meant it could quietly disagree with the history it has
--to be resolved against. A stamp older than the oldest surviving sample has no pair of samples to
--bracket between, so the rewind lands on the end of the window instead of where the client was,
--and nothing reports that it happened.
--
--So it is derived rather than configured. A sample is captured every HISTORY_CAPTURE_DIVISOR
--steps and the ring holds FRAME_CAP of them, so the reachable span is FRAME_CAP - 1 intervals:
--the worst case is the instant after a capture, when the oldest slot has just been overwritten.
--At the defaults that is 19 * 3 / 60 = 0.95s, where a hand-set 1s was 0.05s too generous.
--
--It is read through __index rather than stored, so it stays correct when FRAME_CAP, the divisor,
--or StepFrequency are changed before Central.Start().
local function maxLatency(): number
    --the rate is encoded in the enum item's name (Hz60, Hz30, ...)
    local hz = tonumber(Settings.StepFrequency.Name:match("%d+")) or 60
    return (Settings.FRAME_CAP - 1) * Settings.HISTORY_CAPTURE_DIVISOR / hz
end

export type Settings = typeof(Settings) & {MAX_LATENCY: number}

return (setmetatable(Settings, {
    __index = function(_, key: string): any
        if key == "MAX_LATENCY" then
            return maxLatency()
        end
        return nil
    end,

    --without this a `Settings.MAX_LATENCY = n` would rawset straight past the getter and put the
    --old disagreement back, silently and permanently
    __newindex = function(self, key: string, value: any)
        if key == "MAX_LATENCY" then
            warn("[Central] MAX_LATENCY is derived from FRAME_CAP, HISTORY_CAPTURE_DIVISOR and StepFrequency; change those instead. Ignoring.")
            return
        end
        rawset(self :: any, key, value)
    end,
}) :: any) :: Settings
