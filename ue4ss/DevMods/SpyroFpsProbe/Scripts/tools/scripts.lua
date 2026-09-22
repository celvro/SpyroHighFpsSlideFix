-- The preset input scripts tools/autotest.lua plays at each stop. One script is a list of phases, each
-- held for `dur` seconds:
--
--   axes  = { leftY = 1, leftX = -1, ... }  sticks held for the phase (anything left out is centred)
--   hold  = { "jump", "charge" }            buttons held down for the whole phase
--   tap   = { button = "jump", period = 1.0, width = 0.2 }   press/release over and over
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
    -- Flame from a standstill. (It used to walk first: the probe had flame on FaceTop, which is
    -- FreeLook, so a standing press went into first person. Flame is FaceRight, lib/input.lua.)
    flame = { STILL, { dur = 0.2, hold = { "flame" } }, { dur = 2.0 }, STILL },

    -- Camera: the right stick spin, and what the camera does while Spyro turns under it.
    camSpin = { STILL, { dur = 2.0, axes = { rightX = 1 } }, { dur = 2.0, axes = { rightX = -1 } }, STILL },
    camCenter = { STILL, { dur = 1.5, axes = { leftY = 1 } }, { dur = 1.5, axes = { triggerR = 1 } }, STILL },

    -- Minigames and anything that starts with dialogue.
    --
    -- These used to spend six seconds tapping FaceTop in the middle, meant to skip the NPC's dialogue.
    -- It never did: the probe's presses go to the character, not to the text box, and FaceTop is
    -- FreeLook, so what it did was put the camera in first person fifteen times a stop. Text boxes and
    -- cutscenes are now pressed through by lib/igc.lua instead, and enterTalk and talk are gone: without
    -- the tapping they were a walk and a wait, which walk and idle already are.
    --
    -- Once a minigame is running: hold forward and keep jumping, which is "play" in most of them. Three
    -- jumps is enough to see what a jump animates like; ten was most of the time each stop took.
    play = { STILL, { dur = 3.0, axes = { leftY = 1 }, tap = { button = "jump", period = 1.0, width = 0.2 } }, STILL },
    -- Both halves in one stop: walk into whoever starts it, then play. The tour can't record a stop
    -- inside a minigame (it isn't running when the level is scanned), so this is the only way a
    -- minigame's own animations are reached, which is why tools/scan.lua gives it to every NPC it finds.
    enterPlay = { STILL, { dur = 2.5, axes = { leftY = 1 } },
                  { dur = 3.0, axes = { leftY = 1 }, tap = { button = "jump", period = 1.0, width = 0.2 } },
                  { dur = 2.0 }, STILL },

    -- Nothing at all: stand and let the level's own characters move (what tools/tour.lua does).
    idle = { { dur = 8.0 } },
}

-- Whether a script ever pushes the left stick. A script that doesn't (a flame on the spot, a hop) can
-- never show that the game has taken input away: Spyro stands still either way, so the stop is called
-- played whether or not a conversation still has hold of him. Only a script that asks him to walk can
-- tell, so only those are allowed to clear the locked count (tools/autotest.lua).
function scripts.walks(name)
    for _, phase in ipairs(scripts.list[name] or {}) do
        local axes = phase.axes
        if axes and ((axes.leftY or 0) ~= 0 or (axes.leftX or 0) ~= 0) then return true end
    end
    return false
end

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
