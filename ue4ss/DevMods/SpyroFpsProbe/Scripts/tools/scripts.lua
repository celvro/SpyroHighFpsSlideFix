-- The preset input scripts tools/autotest.lua plays at each stop. One script is a list of phases, each
-- held for `dur` seconds:
--
--   axes  = { leftY = 1, leftX = -1, ... }  sticks held for the phase (anything left out is centred)
--   hold  = { "jump", "charge" }            buttons held down for the whole phase
--   tap   = { button = "flame", period = 0.3, width = 0.1 }  press/release over and over (dialogue skips)
--
-- Times are in seconds of game time, so the same script covers the same amount of gameplay at 30 FPS
-- and at 320. Phase boundaries land on frames, so a phase is never shorter than one frame.
--
-- Adding a script: add it here and name it in a route stop (tools/routes.lua). Keep the first phase
-- still, so every framerate starts from the same standstill, and end with a still phase so the run
-- settles before the sample is taken.
local scripts = {}

local STILL = { dur = 0.5 }

-- Every playable character walks, jumps and can hold a direction; the ability buttons differ per
-- character (Spyro charges and flames, Sheila stomps, Byrd flies, Bentley swings, Agent 9 shoots),
-- but they are the same three face buttons, so the ability scripts are worth running for all of them.
scripts.list = {
    -- Movement: the walking acceleration and standstill bugs, and the jump height ones.
    walk = { STILL, { dur = 3.0, axes = { leftY = 1 } }, STILL },
    walkDiagonal = { STILL, { dur = 3.0, axes = { leftY = 1, leftX = 1 } }, STILL },
    walkTurn = { STILL, { dur = 1.5, axes = { leftY = 1 } }, { dur = 1.5, axes = { leftY = 1, leftX = 1 } },
                 { dur = 1.5, axes = { leftX = 1 } }, STILL },
    startStop = { STILL, { dur = 0.4, axes = { leftY = 1 } }, { dur = 0.4 }, { dur = 0.4, axes = { leftY = 1 } },
                  { dur = 0.4 }, { dur = 0.4, axes = { leftY = 1 } }, STILL },

    -- Jumps: a full-hold jump is the height test; the short hop is the hold-time cutoff.
    jump = { STILL, { dur = 0.6, hold = { "jump" } }, { dur = 2.0 }, STILL },
    hop = { STILL, { dur = 0.06, hold = { "jump" } }, { dur = 2.0 }, STILL },
    runJump = { STILL, { dur = 1.5, axes = { leftY = 1 } },
                { dur = 0.6, axes = { leftY = 1 }, hold = { "jump" } }, { dur = 2.0, axes = { leftY = 1 } }, STILL },
    doubleJump = { STILL, { dur = 0.6, hold = { "jump" } }, { dur = 0.3 }, { dur = 0.6, hold = { "jump" } },
                   { dur = 2.0 }, STILL },

    -- Glide: jump, then hold jump again to glide, and keep pushing forward.
    glide = { STILL, { dur = 0.6, axes = { leftY = 1 }, hold = { "jump" } }, { dur = 0.4, axes = { leftY = 1 } },
              { dur = 4.0, axes = { leftY = 1 }, hold = { "jump" } }, STILL },

    -- Spyro's charge and flame (the same buttons are the other characters' abilities).
    charge = { STILL, { dur = 3.0, axes = { leftY = 1 }, hold = { "charge" } }, STILL },
    chargeTurn = { STILL, { dur = 1.5, axes = { leftY = 1 }, hold = { "charge" } },
                   { dur = 1.5, axes = { leftY = 1, leftX = 1 }, hold = { "charge" } }, STILL },
    chargeJump = { STILL, { dur = 1.5, axes = { leftY = 1 }, hold = { "charge" } },
                   { dur = 0.6, axes = { leftY = 1 }, hold = { "charge", "jump" } },
                   { dur = 1.5, axes = { leftY = 1 }, hold = { "charge" } }, STILL },
    flame = { STILL, { dur = 0.2, hold = { "flame" } }, { dur = 2.0 }, STILL },

    -- Camera: the right stick spin, and what the camera does while Spyro turns under it.
    camSpin = { STILL, { dur = 2.0, axes = { rightX = 1 } }, { dur = 2.0, axes = { rightX = -1 } }, STILL },
    camCenter = { STILL, { dur = 1.5, axes = { leftY = 1 } }, { dur = 1.5, axes = { triggerR = 1 } }, STILL },

    -- Minigames and anything that starts with dialogue: walk into the trigger, then keep skipping.
    -- The stop is recorded in front of the character who starts it (Hunter for the skateboard, and so on).
    enterTalk = { STILL, { dur = 2.5, axes = { leftY = 1 } },
                  { dur = 12.0, tap = { button = "flame", period = 0.4, width = 0.1 } },
                  { dur = 3.0 }, STILL },
    talk = { STILL, { dur = 12.0, tap = { button = "flame", period = 0.4, width = 0.1 } }, { dur = 3.0 }, STILL },
    -- Once a minigame is running: hold forward and keep jumping, which is "play" in most of them.
    play = { STILL, { dur = 8.0, axes = { leftY = 1 }, tap = { button = "jump", period = 1.0, width = 0.2 } }, STILL },
    -- Both halves in one stop: walk into whoever starts it, tap through the dialogue, then play. The
    -- tour can't record a stop inside a minigame (it isn't running when the level is scanned), so this
    -- is the only way a minigame's own animations are reached, which is why tools/scan.lua gives it to
    -- every NPC it finds.
    enterPlay = { STILL, { dur = 2.5, axes = { leftY = 1 } },
                  { dur = 12.0, tap = { button = "flame", period = 0.4, width = 0.1 } },
                  { dur = 10.0, axes = { leftY = 1 }, tap = { button = "jump", period = 1.0, width = 0.2 } },
                  { dur = 2.0 }, STILL },

    -- Nothing at all: stand and let the level's own characters move (what tools/tour.lua does).
    idle = { { dur = 8.0 } },
}

-- Total seconds a script takes.
function scripts.duration(name)
    local total = 0
    for _, phase in ipairs(scripts.list[name] or {}) do total = total + phase.dur end
    return total
end

function scripts.exists(name)
    return scripts.list[name] ~= nil
end

-- The phase covering `elapsed`, and how far into it that is.
function scripts.phaseAt(name, elapsed)
    local start = 0
    for index, phase in ipairs(scripts.list[name] or {}) do
        if elapsed < start + phase.dur then return phase, elapsed - start, index end
        start = start + phase.dur
    end
    return nil, 0, nil
end

return scripts
