-- The run's two CSVs, a row every SAMPLE seconds of game time while a stop plays:
--
--   autotest_<stamp>.csv        one row per sample: cap, level, stop, script, t, position (from where the
--                               script started) and camera. Compared with tools/Compare-Autotest.ps1.
--   autotest_anims_<stamp>.csv  two rows per sample: what the played character and the character the stop
--                               was recorded in front of are animating (montage, how far into it, section,
--                               enemy state, where they have moved to). Compared with tools/Compare-Anims.ps1.
--
-- The scripted walk into an enemy is what starts its chase or attack, so this is where the animations the
-- player actually sees are compared between framerates. Each stop starts from the same teleport, facing
-- the same way, at a standstill, so the passes line up, and the tools join them on (level, stop, script, t).
local anim = require("lib.anim")
local log = require("lib.log")
local paths = require("lib.paths")

local samples = {}

local SAMPLE = 0.1 -- seconds of game time between rows
samples.CSV = string.format("%s\\autotest_%s.csv", paths.modDir, paths.stamp)
local HEADER = "cap,level,stop,script,note,t,tActual,x,y,z,yaw,speed,mode,camYaw,camPitch,camDist,camHeight\n"
local ANIM_CSV = string.format("%s\\autotest_anims_%s.csv", paths.modDir, paths.stamp)
local ANIM_HEADER = "cap,level,stop,script,note,t,who,class,montage,montagePos,section,rate,rootMotion,"
    .. "state,stateTime,x,y,z,yaw,speed,mode\n"

local csv, animCsv = nil, nil
local PLAYER_ORIGIN = { x = 0, y = 0, z = 0 } -- where the played character stood when the script started

local function open(path, header)
    local file = io.open(path, "a")
    if not file then
        log("autotest: could not write %s", path)
        return nil
    end
    if file:seek("end") == 0 then file:write(header) end
    return file
end

-- One animation row for a character: what it is playing, which state it is in and where it has moved to
-- since the script started. Positions are relative to where that character was then, so the two
-- framerates line up whatever offset the level streamed in at.
local function writeAnim(step, slot, who, actor, origin)
    if not (actor and pcall(function() return actor:IsValid() end) and actor:IsValid()) then return end
    local entry = step.entry
    local s = anim.state(actor)
    local okClass, class = pcall(function() return actor:GetClass():GetFName():ToString() end)
    local loc = actor:K2_GetActorLocation()
    local yaw, speed, mode = 0, 0, 0
    pcall(function() yaw = actor:K2_GetActorRotation().Yaw end)
    pcall(function()
        local cmc = actor.CharacterMovement
        local v = cmc.Velocity
        speed = math.sqrt(v.X * v.X + v.Y * v.Y)
        mode = cmc.MovementMode
    end)
    animCsv:write(string.format("%d,%s,%d,%s,%s,%.3f,%s,%s,%s,%.4f,%s,%.3f,%s,%s,%.3f,%.2f,%.2f,%.2f,%.2f,%.2f,%d\n",
        step.cap, entry.stop.level, entry.id, entry.stop.script, entry.stop.note:gsub(",", " "),
        slot, who, okClass and class or "?", s.montage, s.position, s.section, s.rate, tostring(s.rootMotion),
        s.enemyState, s.enemyStateTime, loc.X - origin.x, loc.Y - origin.y, loc.Z - origin.z,
        yaw, speed, mode))
end

-- A row of each file for the sample slot `slot` (0, 0.1, 0.2 ...), the same in every pass so the passes
-- join; tActual is the game time it was really taken at, a fraction of a frame later. The rows are for
-- the player and the character the stop was recorded in front of (run.target).
function samples.take(run, pawn, r, slot)
    local step = run.step
    local entry = step.entry
    csv = csv or open(samples.CSV, HEADER)
    if csv then
        csv:write(string.format("%d,%s,%d,%s,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%.3f,%.3f,%.1f,%.1f\n",
            step.cap, entry.stop.level, entry.id, entry.stop.script, entry.stop.note:gsub(",", " "),
            slot, run.elapsed, r.x - run.x0, r.y - run.y0, r.z - run.z0, r.yaw, r.speed or 0, r.mode,
            r.camYaw, r.camPitch, r.camDist, r.camHeight))
        run.samples = run.samples + 1
    end
    animCsv = animCsv or open(ANIM_CSV, ANIM_HEADER)
    if animCsv then
        PLAYER_ORIGIN.x, PLAYER_ORIGIN.y, PLAYER_ORIGIN.z = run.x0, run.y0, run.z0
        writeAnim(step, slot, "player", pawn, PLAYER_ORIGIN)
        if run.target and run.targetOrigin then
            writeAnim(step, slot, "target", run.target, run.targetOrigin)
        end
    end
end

-- The rows for the next slot, once the stop's elapsed time has reached it.
function samples.due(run, pawn, r)
    if run.elapsed < run.nextSample then return end
    samples.take(run, pawn, r, run.nextSample)
    run.nextSample = run.nextSample + SAMPLE
end

return samples
