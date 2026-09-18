-- Fireworks Factory's segmented fire dragons.
--
--   "dragon" lines  once a second per dragon: fps, head speed, live and "managed" segments (bAlive off, i.e.
--                   taken over by the fire dragon segment fix), mean link distance (3D, horizontal,
--                   head->first), body length, and lag (link/speed, frames >= DRAGON_MIN_SPEED) next to the
--                   30 FPS and unfixed-at-this-framerate predictions. Links include the segments' vertical
--                   sine offsets, so lag reads a bit high on slow or turning stretches.
local log = require("lib.log")
local util = require("lib.util")

local vecDist, lookupDue = util.vecDist, util.lookupDue

local DRAGON_REPORT_INTERVAL = 1.0 -- seconds of game time per dragon line
local DRAGON_MIN_SPEED = 100       -- slower head frames are left out of the lag average

local dragons = { CLASS = "BP_CBS3012_FireDragon_C" }

local heads = {}
local lookup = { lookups = 1, nextLookup = 0 }
local classSeen = false
local stats = {} -- head address -> accumulated dragon line values
local errorLogged = false

-- Seconds a DragonSineMovement segment trails a steadily moving leader when MoveUpdate gets `delta`
-- once per frame of dt: it keeps K = (1 - 4 * delta)^2 of its distance per call.
local function dragonTrail(dt, delta)
    local keep = (1 - 4 * delta) ^ 2
    return dt * keep / (1 - keep)
end

local function newStats(loc, time)
    return { prevLoc = loc, start = time, frames = 0, dtSum = 0, speedSum = 0, links = 0, linkSum = 0,
             linkHSum = 0, firstSum = 0, bodySum = 0, lagSum = 0, lagFrames = 0, segments = 0, managed = 0 }
end

local function logDragon(s, name)
    local lag = s.lagFrames > 0 and s.lagSum / s.lagFrames or 0 / 0
    local avgDt = s.dtSum / s.frames
    log("dragon %s: fps %.1f, speed %.1f, segments %d (managed %d), link %.1f (horiz %.1f, first %.1f), body %.1f, lag %.4f s/link (30 FPS 0.1006, unfixed here %.4f)",
        name, s.frames / s.dtSum, s.speedSum / s.frames, s.segments, s.managed, s.linkSum / math.max(s.links, 1),
        s.linkHSum / math.max(s.links, 1), s.firstSum / s.frames, s.bodySum / s.frames, lag,
        dragonTrail(avgDt, math.max(avgDt, 0.033)))
end

-- Per dragon: head speed and the distance from each live segment to the one it follows (the head for
-- the first). Sampled before the world tick, so all positions are from the same frame.
local function update(time, dt)
    if lookupDue(lookup, time) then heads = FindAllOf(dragons.CLASS) or {} end
    if dt <= 0 then return end
    for _, head in ipairs(heads) do
        if head:IsValid() and not head.bIsDead then
            local address = head:GetAddress()
            local loc = head:K2_GetActorLocation()
            local s = stats[address]
            if not s or not s.prevLoc then
                stats[address] = newStats(loc, time)
            else
                local speed = vecDist(loc, s.prevLoc) / dt
                s.prevLoc = loc
                local leaderLoc, segments, managed, links, linkSum, body = loc, 0, 0, 0, 0, 0
                local first = 0
                local bodySegments = head.BodySegments
                for i = 1, bodySegments:GetArrayNum() do
                    local segment = bodySegments[i]
                    if segment:IsValid() and segment.IsAlive_0 then
                        local segLoc = segment:K2_GetActorLocation()
                        local link, linkH = vecDist(segLoc, leaderLoc)
                        if segments == 0 then first = link end
                        segments = segments + 1
                        if not segment.DragonSineMovement.bAlive then managed = managed + 1 end
                        links = links + 1
                        linkSum = linkSum + link
                        s.linkHSum = s.linkHSum + linkH
                        body = body + link
                        leaderLoc = segLoc
                    end
                end
                if segments > 0 then
                    s.frames = s.frames + 1
                    s.dtSum = s.dtSum + dt
                    s.speedSum = s.speedSum + speed
                    s.links = s.links + links
                    s.linkSum = s.linkSum + linkSum
                    s.firstSum = s.firstSum + first
                    s.bodySum = s.bodySum + body
                    s.segments, s.managed = segments, managed
                    if speed >= DRAGON_MIN_SPEED then
                        s.lagSum = s.lagSum + linkSum / links / speed
                        s.lagFrames = s.lagFrames + 1
                    end
                end
                if time - s.start >= DRAGON_REPORT_INTERVAL then
                    if s.frames > 0 then
                        local name = head:GetFName():ToString()
                        logDragon(s, name:find("Purple") and "purple" or name:find("Red") and "red" or name)
                    end
                    stats[address] = newStats(loc, time)
                end
            end
        end
    end
end

-- The first call succeeds on every level without dragons, so errors are logged here rather than via tryCall.
function dragons.update(time, dt)
    local ok, err = pcall(update, time, dt)
    if not ok and not errorLogged then
        errorLogged = true
        log("fire dragon stats error: %s", tostring(err))
    end
end

-- The dragon Blueprint class was created: its level is loading, so look for the heads for a while.
function dragons.classLoaded()
    lookup.lookups, lookup.nextLookup, classSeen = util.NEW_OBJECT_LOOKUPS, 0, true
end

-- A new pawn (level load, respawn) may come with new dragons; look again if their class has loaded.
function dragons.pawnChanged()
    if classSeen then lookup.lookups, lookup.nextLookup = util.NEW_OBJECT_LOOKUPS, 0 end
end

return dragons
