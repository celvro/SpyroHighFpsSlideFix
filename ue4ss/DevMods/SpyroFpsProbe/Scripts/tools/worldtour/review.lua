-- Review runs (review.txt, or "review" in autotest.txt): somebody watches the tour and says what each
-- stop looks like. F3 (fine) or F4 (wrong) on the stop being played goes to review_<stamp>.txt, numbered
-- so a wrong one can be talked about, with what can be measured about it -- how far the target is and how
-- far off his facing it stands, whether a conversation is open -- so "wrong" can be matched with the
-- description of why. F4 also holds the tour on that stop once its script is done (play.lua), and F3
-- carries on from there.
--
--   "review" lines  each verdict, the hold, and the totals at the end of the run
local igc = require("lib.igc")
local log = require("lib.log")
local paths = require("lib.paths")
local drive = require("tools.worldtour.drive")

local review = {}

local FILE = string.format("%s\\review_%s.txt", paths.modDir, paths.stamp)

function review.rate(run, r, verdict)
    if not (run.step and run.review) then return end
    if run.phase == "held" then
        if verdict == "fine" then
            log("review: carrying on")
            run.phase = "next"
        end
        return
    end
    local entry = run.step.entry
    run.review.count = run.review.count + 1
    run.review[verdict] = (run.review[verdict] or 0) + 1
    local stop = entry.stop
    local distance = drive.targetDistance(run, r)
    local off = "?"
    local ok, loc = pcall(function() return run.target:K2_GetActorLocation() end)
    if ok and loc then
        local bearing = math.deg(math.atan(loc.Y - r.y, loc.X - r.x))
        off = string.format("%.0f", (bearing - r.yaw + 540) % 360 - 180)
    end
    local line = string.format("#%d %s | %s | %s stop %d | %s | %s | %.1f s in (%s) | target %s away, %s deg off his facing%s",
        run.review.count, verdict:upper(), os.date("%H:%M:%S"), stop.level, entry.id, stop.script, stop.note,
        run.elapsed or 0, run.phase, distance and string.format("%.0f", distance) or "?", off,
        igc.active(stop.level) and " | in a conversation" or "")
    local file = io.open(FILE, "a")
    if file then file:write(line, "\n"); file:close() end
    log("review: %s", line)
    if verdict == "wrong" then
        run.hold = true
        log("review: #%d -- the tour holds here once this stop's script is done; F3 carries on", run.review.count)
    end
end

function review.summary(run)
    log("review: %d rated, %d fine, %d wrong; %s", run.review.count, run.review.fine or 0,
        run.review.wrong or 0, FILE)
end

return review
