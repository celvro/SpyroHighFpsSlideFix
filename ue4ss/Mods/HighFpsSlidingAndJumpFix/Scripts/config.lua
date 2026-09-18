-- Switches for testing, all in one place. Each fix is on by default; turning one off compares the
-- fixed behaviour against the game's own. The tuning constants of a fix live with it in fixes/,
-- next to the findings that explain them.
return {
    FIX_WALKING_ACCELERATION = true,      -- false: only fix braking (the original sliding fix)
    FIX_WALL_SLIDE = true,                -- false: blocked frames against walls reset the velocity (charge stalls)
    FIX_GLIDE_START = true,               -- false: early-pressed glides start ~5 units lower at high FPS
    FIX_GLIDE_DISTANCE = true,            -- false: glides drift up to 1% long or short at high FPS (position rounding)
    FIX_CHARGE_TURN_SLIP = true,          -- false: the unfixed charge turn
    FIX_MOUSE_CHARGE_STEERING = true,     -- false: the unfixed mouse charge steering
    FIX_CAMERA_CENTERING = true,          -- false: the unfixed camera centering
    FIX_CAMERA_CENTERING_SWITCH = true,   -- false: the per-frame centering switch threshold
    FIX_STUCK_CAMERA = true,              -- false: the camera getting stuck while centering
    FIX_CHARGE_DUST = true,               -- false: the missing charge dust
    FIX_DRUID_ENERGIZE = true,            -- false: druids that stop energizing
    FIX_DRAGON_SEGMENTS = true,           -- false: the bunched-up fire dragons
    FIX_FLAME_MUZZLE_LINES = true,        -- false: the stray lines in the flame breath
    FIX_BALLOON_CAMERA_SPIN = true,       -- false: the camera whirling around the balloonist's balloon
    FIX_BUZZ_CHARGE_RUN = true,           -- false: Buzz running in place, and sliding after his rolls

    PROFILE = false,                     -- log the fixes' per-frame cost to UE4SS.log
    PROFILE_INTERVAL = 10,                -- seconds between profile log lines
    -- GC spike investigation (see CLAUDE.md "Frame spikes"): only sampled while PROFILE is also on.
    -- GC_COLLECTION_KB is a per-frame collectgarbage("count") drop big enough to count as "a
    -- collection landed in this frame" rather than ordinary allocate/free noise.
    GC_PROFILE = false,
    GC_COLLECTION_KB = 5,
    -- Switches the shared Lua state's collector at load, to A/B against the default incremental one.
    -- "generational" is the only other mode Lua 5.4 offers; nil/false leaves whatever UE4SS started with.
    GC_MODE = nil,
}
