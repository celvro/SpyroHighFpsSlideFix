-- Switches for what the probe measures, all in one place. The probe samples on the game thread, so
-- every tracker left on is frame time the game doesn't get: at 320 FPS a frame is 3.1 ms, and the
-- trackers that walk a list of actors or write a CSV row per actor per frame each take a slice of
-- it. Turn on what the run is measuring and leave the rest off. PROFILE below prints what each one
-- actually costs, so these switches can be set from measurements rather than guesses.
--
-- Most trackers are off because their bug is fixed and verified (the findings table in CLAUDE.md
-- says which): turn one back on to re-measure its fix, to check a regression, or to pick the
-- investigation back up. The load line in UE4SS.log lists what was on for the run.
return {
    TRACKERS = {
        -- On: cheap, and the general movement log every other measurement is read against.
        movement = true,     -- seg / drift / rise      jump height, glide distance, braking slide
        -- On: the charge camera went slow again on 2026-10-10 (the mod logged 28-29 `stuck camera
        -- release` lines a run, where the verified state logged none). `charge` drives the camera
        -- tracker's lock measurements, and `camera` adds camtransition plus the camdump diffs.
        -- Turn both back off once that is settled.
        charge = true,       -- charge / turn               docs/findings/charge-turn-camera.md
        camera = true,       -- camlock / camstuck / camtransition / camdump

        -- Off: the open investigation (docs/findings/turtle-soup.md), parked for the run above.
        -- Writes a row per turtle per frame, so it is also the most expensive tracker here.
        turtle = false,      -- turtleslide / turtlerun / turtlestall / turtlestart

        -- Off: fixed and verified.
        glide = false,       -- glide / hover / glideair    docs/findings/jump-glide.md
        dragons = false,     -- dragon                      docs/findings/fire-dragon.md
        flames = false,      -- flame                       docs/findings/flame-breath.md
        walkin = false,      -- walkin                      docs/findings/freed-dragon-walkin.md
        hits = false,        -- chargestall                 docs/findings/charge-wall-stall.md
        buzz = false,        -- buzzrun                     docs/findings/buzz-charge-run.md
        lizard = false,      -- lizardstall / lizardstep     docs/findings/skelos-badlands.md
        gemthief = false,    -- gemthief                    docs/findings/gem-thief-anim.md
        nanspeed = false,    -- nanspeed                    the same fix, swept over every character

        -- Off: measured, and the answer was that the game already matches 30 FPS (or isn't worth
        -- fixing), so there is nothing to watch for.
        supercharge = false, -- supercharge                 docs/findings/super-charge.md
        thieves = false,     -- thief                       docs/findings/thief-chase.md
        flight = false,      -- flight / flightramp         docs/findings/flight.md

        -- Off: the survey is done (docs/findings/npc-stalls.md). It looks at every NPC and enemy in
        -- the level every frame, so turn it on for a survey run and off again afterwards.
        stalls = false,      -- stall / stallsummary
    },

    -- trace_<stamp>.csv, one row per frame (columns in lib/trace.lua). A string.format of 60 fields
    -- and a write every frame: the biggest single cost after the per-actor trackers.
    TRACE = true,

    -- Level replay and PgUp reset: after the sublevel reload, re-send the two level-start events the reload
    -- skips (lib/playerready.lua): PlayerReady to the NPC dialogue selectors, which pick their conversation
    -- on it, and the current game state to the dialogues and cutscenes, which only play once they have
    -- seen it. Without them no NPC in the level can be talked to after a reset (Zephyr's Sergeant Tub
    -- stayed on his cannon while Spyro walked up to him).
    REPLAY_PLAYER_READY = true,

    -- Level replay: every other character's position and velocity, every frame, into
    -- replay_<take>_run<cap>_<stamp>_actors.csv (lib/actortrace.lua), for tools/Compare-ReplayActors.ps1.
    -- 0.11 ms a frame for Stone Hill's 27 characters.
    REPLAY_ACTORS = true,

    -- Level replay and PgUp reset: put the characters back the way the recording found them
    -- (lib/actorstart.lua, from the take's replay_<take>_ref_actors.csv): the ones dead when the take started
    -- are destroyed after the reload, and the rest are teleported to where they stood when it started.
    REPLAY_ACTOR_START = true,

    -- Optional reads in lib/row.lua. Each is a reflection call (several wrapped in pcall) on every
    -- frame, so they follow the trackers that want them. A group that is off leaves its row fields
    -- nil and its trace columns blank.
    ROW_CAMERA = true,     -- camera rotation/location, FOV, FollowCamera yaw, m_radDefault,
                            -- m_ctrInterp, IsTransitioning. Wanted by camera, charge and
                            -- supercharge, and by the world tour's camera columns
                            -- (tools/worldtour/samples.lua) — turn it on for a tour.
    ROW_STICKS = true,     -- CharacterInputComponent_Spyro raw axes. Wanted by camera, charge, flight.
    ROW_CHARGE_TAG = true, -- IGetIsCharging. With it off, r.charging falls back to
                            -- MaxWalkSpeed >= 450, which is what the call fails over to anyway.
    ROW_DUST = false,       -- Charge_GroundEffects, for the charge line's dust counts. Wanted by charge.

    -- Debug unlocks (tools/debugunlock.lua), applied on every level load. They write save data (the
    -- guidebook flag, inventory items), so back the save up first (tools/Save-GameSnapshot.ps1).
    -- Remove the whole table to have the probe write nothing; guidebook = false clears the flag again.
    DEBUG_UNLOCKS = {
        guidebook = true,   -- the guidebook lists and travels to every level, visited or not
        moves = true,       -- Spyro 2: climbing, head bash, swimming underwater; Spyro 3: Sparx's four powers
        superflame = false, -- Spyro 2/3: permanent super flame (replaces the normal flame, so off)
    },

    -- Times each tracker's share of the frame and logs a ranked summary every PROFILE_INTERVAL
    -- seconds (lib/profile.lua). Two clock reads per tracker per frame, so it costs something
    -- itself: it is a measurement run, not something to leave on. Must be false in commits.
    PROFILE = false,
    PROFILE_INTERVAL = 10,
}
