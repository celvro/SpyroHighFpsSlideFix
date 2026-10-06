-- Non-finite velocity and animation speed, on every NPC and enemy (PhasmidCharacter).
--
-- The Artisans gem thief runs in his idle pose because his anim Blueprint's Speed is NaN
-- (docs/findings/gem-thief-anim.md). The poison arrives in the movement component's Velocity, and it
-- sticks in the anim Blueprint for ever, because every one of these locomotion Blueprints sets
-- Speed = Lerp(Speed, VSize2D(GetVelocity()), DeltaTime * n) through the shared CalculateTurnRate
-- library: Lerp(NaN, v, a) is NaN. So any character driven that way can be left in its idle pose by one
-- bad frame. This watches all of them, not just the thief.
--
-- Each entry is read once every SCAN_INTERVAL (round robin, SCAN_PER_FRAME of them a frame, so a level
-- full of characters costs a few property reads per frame). **Off until Y turns it on**: the first
-- version crashed the game during startup (access violation, 2026-09-27 17:17), so it now waits to be
-- asked, leaves a newly constructed actor alone for GRACE seconds, and reads properties only — no
-- Blueprint calls on classes it knows nothing about.
--
--   "nanspeed" lines      first time a class shows a non-finite value, then at most one per class per
--                         LOG_INTERVAL: which of Velocity / Speed / DeltaTime is bad, the movement mode,
--                         the state name, and whether it recovered by itself.
--   "nanspeed summary"    every SUMMARY_INTERVAL and on a pawn change: per class, how many actors were
--                         caught, how many frames they spent non-finite, and which fields.
--   "nanspeed healed"     HEAL wrote a finite Speed back (only when the velocity itself is finite
--                         again). This is the candidate fix, verified on the thief 2026-09-27 16:57.
local anim = require("lib.anim")
local log = require("lib.log")
local util = require("lib.util")

local num = util.num

local nanspeed = {}

local SCAN_INTERVAL = 0.1     -- seconds between reads of one actor
local SCAN_PER_FRAME = 4      -- actors read per frame
local LOG_INTERVAL = 5        -- seconds between lines for one class
local SUMMARY_INTERVAL = 60
local GRACE = 1.0            -- seconds to leave a newly constructed actor alone before reading it
local HEAL = true

local entries = {}            -- address -> { actor, class, name, nextScan, bad, healed }
local order = {}              -- addresses, for the round robin
local cursor = 1
local pending = {}            -- objects from NotifyOnNewObject, resolved on the next frame
local classes = {}            -- class -> { actors, frames, fields = {}, lastLog }
local nextSummary = SUMMARY_INTERVAL
local running = false        -- Y turns the sweep on; it stays off through startup and level loads
local errorLogged = false

local function finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function get(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

function nanspeed.onNewObject(object)
    pending[#pending + 1] = object
end

local function resolve(time)
    for i = #pending, 1, -1 do
        local actor = pending[i]
        pending[i] = nil
        if actor:IsValid() then
            local address = actor:GetAddress()
            local name = get(function() return actor:GetFName():ToString() end)
            if not entries[address] and name and not name:match("^Default__") then
                entries[address] = {
                    actor = actor,
                    class = get(function() return actor:GetClass():GetFName():ToString() end) or "?",
                    name = name,
                    -- Reading an actor the engine has only just constructed is what the startup crash
                    -- looked like, so nothing is touched until it has been alive for GRACE.
                    nextScan = time + GRACE,
                }
                order[#order + 1] = address
            end
        end
    end
end

-- Reads one actor: its horizontal speed, and its anim Blueprint's Speed and last DeltaTime. Characters
-- whose Blueprint has no Speed (a state machine instead of a blendspace) read nil and are skipped.
local function scan(e, time)
    local actor = e.actor
    local cmc = get(function() return actor.CharacterMovement end)
    local velocity = cmc and cmc:IsValid() and get(function() return cmc.Velocity end)
    local speed = velocity and math.sqrt(velocity.X * velocity.X + velocity.Y * velocity.Y)
    local instance = anim.instance(actor)
    local animSpeed = instance and get(function() return instance.Speed end)
    local animDt = instance and get(function() return instance.Time end)

    local fields = {}
    if speed ~= nil and not finite(speed) then fields[#fields + 1] = "velocity" end
    if animSpeed ~= nil and not finite(animSpeed) then fields[#fields + 1] = "animSpeed" end
    if animDt ~= nil and not finite(animDt) then fields[#fields + 1] = "animDt" end

    if #fields == 0 then
        if e.bad then
            e.bad = false
            log("nanspeed %s %s recovered vel=%s animSpeed=%s time=%s",
                e.class, e.name, num(speed), num(animSpeed), num(time))
        end
        return
    end

    local c = classes[e.class]
    if not c then
        c = { actors = {}, count = 0, frames = 0, fields = {}, lastLog = -LOG_INTERVAL }
        classes[e.class] = c
    end
    if not c.actors[e.name] then c.actors[e.name] = true; c.count = c.count + 1 end
    c.frames = c.frames + 1
    for _, field in ipairs(fields) do c.fields[field] = (c.fields[field] or 0) + 1 end

    local first = not e.bad
    e.bad = true
    if first or time - c.lastLog >= LOG_INTERVAL then
        c.lastLog = time
        local mode = cmc and cmc:IsValid() and get(function() return cmc.MovementMode end) or -1
        -- Only properties are read here. The state name would need BP_GetCurrentStateName on a component
        -- of a class this sweep knows nothing about, and calling a Blueprint function on 735 unrelated
        -- classes is not worth another access violation; trackers/gemthief.lua reads it for the thief.
        log("nanspeed %s %s %s%s mode=%s vel=%s animSpeed=%s animDt=%s time=%s",
            e.class, e.name, table.concat(fields, "+"), first and " (first)" or "",
            util.MOVE_MODE_NAMES[mode] or tostring(mode), num(speed), num(animSpeed), num(animDt),
            num(time))
    end

    -- Only a finite velocity can heal the anim Blueprint: writing a NaN over a NaN changes nothing, and
    -- the Lerp converges on its own once its own input is a number again.
    if HEAL and instance and finite(speed) and not finite(animSpeed) then
        get(function() instance.Speed = speed end)
        if not e.healed then
            e.healed = true
            log("nanspeed healed %s %s wrote Speed=%s", e.class, e.name, num(speed))
        end
    end
end

local function logSummary(reason)
    local lines = 0
    for class, c in pairs(classes) do
        local fields = {}
        for field, count in pairs(c.fields) do fields[#fields + 1] = string.format("%s=%d", field, count) end
        table.sort(fields)
        log("nanspeed summary %s actors=%d frames=%d %s", class, c.count, c.frames, table.concat(fields, " "))
        lines = lines + 1
    end
    if lines > 0 then log("nanspeed summary (%s): %d class(es)", reason, lines) end
end

function nanspeed.pawnChanged()
    logSummary("pawn changed")
    classes = {}
end

-- Y. Off at startup on purpose (see the header), so a level is always fully loaded before anything here
-- reads an actor.
function nanspeed.toggle()
    running = not running
    log("nanspeed %s (%d character(s) known)", running and "on" or "off", #order)
end

function nanspeed.update(r)
    if errorLogged then return end
    local ok, err = pcall(function()
        resolve(r.time)
        if not running then return end
        local checked = 0
        local steps = 0
        while checked < SCAN_PER_FRAME and steps < #order do
            steps = steps + 1
            if cursor > #order then cursor = 1 end
            local address = order[cursor]
            local e = entries[address]
            if not e or not e.actor:IsValid() then
                entries[address] = nil
                table.remove(order, cursor)
            else
                cursor = cursor + 1
                if r.time >= e.nextScan then
                    e.nextScan = r.time + SCAN_INTERVAL
                    checked = checked + 1
                    scan(e, r.time)
                end
            end
        end
        if r.time >= nextSummary then
            nextSummary = r.time + SUMMARY_INTERVAL
            logSummary("periodic")
        end
    end)
    if not ok then
        errorLogged = true
        log("nanspeed error: %s", tostring(err))
    end
end

return nanspeed
