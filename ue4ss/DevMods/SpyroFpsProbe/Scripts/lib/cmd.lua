-- The probe's command channel: drive it from outside the game without sending it key presses.
--
-- Write commands into cmd.txt in this mod folder, one per line; the probe takes the file every few
-- frames (renaming it first, so a writer never races the reader), runs each line and appends one or
-- more result lines to cmd_result.txt. tools/Invoke-Probe.ps1 does both halves and waits for the answer.
--
--   cmd.txt line        [@<id>] <verb> [args...]           e.g.  @a1 cap 320
--   cmd_result.txt line <id> TAB <status> TAB <text>       e.g.  a1	ok	t.MaxFPS 320
--
-- A line without an @id gets one ("n<counter>"). Text is one line: newlines in it are written as the
-- two characters \n. Statuses:
--   ok        the command is finished
--   started   it runs over several frames (a replay, a travel, a reload); "done" or "error" follows
--   done      the started command finished
--   error     it could not run, or failed part way
-- Commands that need Spyro (anything touching the pawn) wait for him for up to PAWN_WAIT seconds, so
-- a command written during a restart or a level load runs once he is back. Everything else (ping,
-- cap, key, trigger, swap, eval) runs at once, at the title screen too.
--
-- `help` lists the verbs. Other modules can add their own with cmd.register(verb, handler, options).
-- Every hotkey the probe binds is also a command: `key F5`, `key End` (`keys` lists them), so a tool
-- that only has a key binding is reachable from here without a change to it.
--
-- Costs nothing per frame beyond a counter while idle: the file is looked for every POLL_FRAMES frames.
local UEHelpers = require("UEHelpers")
local log = require("lib.log")
local paths = require("lib.paths")
local util = require("lib.util")
local state = require("lib.state")

local cmd = {}

local FILE = paths.modDir .. "\\cmd.txt"
local TAKEN = paths.modDir .. "\\cmd.taken"
local RESULT = paths.modDir .. "\\cmd_result.txt"
local POLL_FRAMES = 10   -- a third of a second at 30 FPS; a failed fopen is microseconds
local PAWN_WAIT = 120    -- seconds a command waits for Spyro (a restart takes 16-27 s, a travel ~10)
local DEFAULT_TIMEOUT = 600 -- seconds a started command may take before it is called failed

local verbs = {}        -- verb -> { handler, pawn = bool, help = "..." }
local order = {}        -- verbs in registration order, for help
local keyBinds = {}     -- key name ("F5", "END") -> { callbacks... }, captured from RegisterKeyBind
local keyOrder = {}
local queue = {}        -- commands waiting for a pawn: { id, verb, args, raw, since }
local jobs = {}         -- started commands: { id, verb, poll = fn(ctx) -> status, text | nil, deadline }
local frame = 0
local counter = 0

-- ---------------------------------------------------------------- results

local function oneLine(text)
    return (tostring(text or ""):gsub("\r?\n", "\\n"):gsub("\t", " "))
end

local function reply(id, status, text)
    local line = string.format("%s\t%s\t%s\n", id, status, oneLine(text))
    local file = io.open(RESULT, "a")
    if file then
        file:write(line)
        file:close()
    end
    log("cmd %s %s: %s", id, status, oneLine(text))
end

-- ---------------------------------------------------------------- key binds

-- Key.F5 is a number; the name is only in the Key table, so build the reverse map once.
local function reverse(tbl)
    local map = {}
    if type(tbl) == "table" then
        for name, v in pairs(tbl) do map[v] = name end
    end
    return map
end
local keyNames, modifierNames = nil, nil
local function keyName(value)
    keyNames = keyNames or reverse(Key)
    return keyNames[value] or tostring(value)
end
local function modifierName(value)
    modifierNames = modifierNames or reverse(ModifierKey)
    return modifierNames[value] or tostring(value)
end
-- What people type for a modifier, against ModifierKey's names.
local MODIFIER_ALIASES = { CTRL = "CONTROL", CONTROL = "CONTROL", SHIFT = "SHIFT", ALT = "ALT" }
local function normalizeKey(raw)
    local parts = {}
    for part in raw:upper():gmatch("[^+]+") do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do parts[i] = MODIFIER_ALIASES[parts[i]] or parts[i] end
    return table.concat(parts, "+")
end

-- Every RegisterKeyBind the probe makes after this module loads is recorded on the way through, so
-- `key <name>` can call the same function the key would. The modifier form (key, { mods }, fn) is
-- recorded under "<mod>+<key>". The real RegisterKeyBind still runs, so the keys work as before.
local function wrapKeyBinds()
    if type(RegisterKeyBind) ~= "function" or cmd.wrapped then return end
    cmd.wrapped = true
    local original = RegisterKeyBind
    RegisterKeyBind = function(key, a, b)
        local fn, mods = a, nil
        if type(a) == "table" then fn, mods = b, a end
        local ok = pcall(function()
            local name = keyName(key)
            if mods then
                local parts = {}
                for _, m in ipairs(mods) do parts[#parts + 1] = modifierName(m) end
                name = table.concat(parts, "+") .. "+" .. name
            end
            name = name:upper()
            if not keyBinds[name] then
                keyBinds[name] = {}
                keyOrder[#keyOrder + 1] = name
            end
            table.insert(keyBinds[name], fn)
        end)
        if not ok then log("cmd: could not record a key bind") end
        return original(key, a, b)
    end
end

-- ---------------------------------------------------------------- parsing

-- "@a1 replay take=LS102_x cap=320 fast" -> "a1", "replay", { take = "LS102_x", cap = "320", "fast" }, rest
local function parse(line)
    line = util.stripBom(line):gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" or line:match("^#") then return nil end
    local id = line:match("^@(%S+)")
    if id then line = line:gsub("^@%S+%s*", "") end
    if not id then
        counter = counter + 1
        id = "n" .. counter
    end
    local verb, rest = line:match("^(%S+)%s*(.*)$")
    if not verb then return nil end
    local args = {}
    for token in rest:gmatch("%S+") do
        local k, v = token:match("^([%w_]+)=(.*)$")
        if k then args[k] = v else args[#args + 1] = token end
    end
    return { id = id, verb = verb:lower(), args = args, rest = rest }
end

-- ---------------------------------------------------------------- running

local function context(setFpsCap)
    local ctx = { setFpsCap = setFpsCap, r = state.prevRow }
    local pc = UEHelpers.GetPlayerController()
    if pc and pc:IsValid() then
        ctx.pc = pc
        local pawn = pc.Pawn
        if pawn and pawn:IsValid() then
            ctx.pawn = pawn
            local cmc = pawn.CharacterMovement
            if cmc and cmc:IsValid() then ctx.cmc = cmc end
        end
    end
    return ctx
end

-- A handler returns status, text: "ok"/"error" to finish, or "started", text, poll[, timeout] to keep
-- going, where poll(ctx) returns nil while it runs and "done"/"error", text when it ends.
local function run(c, ctx)
    local entry = verbs[c.verb]
    local ok, status, text, poll, timeout = pcall(entry.handler, ctx, c.args, c)
    if not ok then
        reply(c.id, "error", status)
        return
    end
    reply(c.id, status or "ok", text or "")
    if status == "started" and poll then
        jobs[#jobs + 1] = { id = c.id, verb = c.verb, poll = poll, deadline = os.clock() + (timeout or DEFAULT_TIMEOUT) }
    end
end

local function dispatch(c, ctx)
    local entry = verbs[c.verb]
    if not entry then
        reply(c.id, "error", string.format("unknown command '%s' (help lists them)", c.verb))
    elseif entry.pawn and not ctx.pawn then
        c.since = os.clock()
        queue[#queue + 1] = c
        log("cmd %s: %s waits for Spyro", c.id, c.verb)
    else
        run(c, ctx)
    end
end

local function readFile()
    local probe = io.open(FILE, "r")
    if not probe then return nil end
    probe:close()
    os.remove(TAKEN)
    -- Renaming fails while the writer still has the file open; it is tried again next poll.
    if not os.rename(FILE, TAKEN) then return nil end
    local file = io.open(TAKEN, "r")
    if not file then return nil end
    local text = file:read("a") or ""
    file:close()
    os.remove(TAKEN)
    return text
end

-- Called every frame from main.lua, before the pawn checks (commands also run at the title screen).
function cmd.update(setFpsCap)
    frame = frame + 1
    local polling = frame % POLL_FRAMES == 0
    if not polling and #queue == 0 and #jobs == 0 then return end
    local ctx = context(setFpsCap)

    if #queue > 0 then
        local waiting = queue
        queue = {}
        for _, c in ipairs(waiting) do
            if ctx.pawn then
                run(c, ctx)
            elseif os.clock() - c.since > PAWN_WAIT then
                reply(c.id, "error", string.format("%s: no Spyro after %d s", c.verb, PAWN_WAIT))
            else
                queue[#queue + 1] = c
            end
        end
    end

    if #jobs > 0 then
        local active = jobs
        jobs = {}
        for _, job in ipairs(active) do
            local ok, status, text = pcall(job.poll, ctx)
            if not ok then
                reply(job.id, "error", status)
            elseif status then
                reply(job.id, status, text)
            elseif os.clock() > job.deadline then
                reply(job.id, "error", job.verb .. ": timed out")
            else
                jobs[#jobs + 1] = job
            end
        end
    end

    if polling then
        local text = readFile()
        if text then
            for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                local c = parse(line)
                if c then dispatch(c, ctx) end
            end
        end
    end
end

-- handler(ctx, args, command) -> see run(). options: pawn = true to wait for Spyro, help = "usage - what".
function cmd.register(verb, handler, options)
    options = options or {}
    verb = verb:lower()
    if not verbs[verb] then order[#order + 1] = verb end
    verbs[verb] = { handler = handler, pawn = options.pawn, help = options.help or verb }
end

-- ---------------------------------------------------------------- built-in commands

local function fmt(v)
    if type(v) == "number" then
        if v ~= v then return "nan" end
        if math.type(v) == "integer" then return tostring(v) end
        return string.format("%.3f", v)
    end
    return tostring(v)
end

-- A table as "k=v k=v", one level deep, keys sorted; anything else through tostring.
local function describe(v)
    if type(v) ~= "table" then
        local s = util.asString(v)
        return s or fmt(v)
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        local value = v[k]
        parts[#parts + 1] = tostring(k) .. "=" .. (type(value) == "table" and "{...}" or (util.asString(value) or fmt(value)))
    end
    return table.concat(parts, " ")
end

-- main.lua's setFpsCap runs the console command through ExecuteInGameThread, so state.fpsCap only
-- changes a frame later. A replay started in between reads the old cap and sets it back (seen
-- 2026-11-17: `replay cap=30` ran at 60). Record the new cap at once as well.
local function setCap(ctx, cap)
    cap = math.floor(cap)
    state.fpsCap = cap
    ctx.setFpsCap(cap)
end

cmd.register("help", function()
    local lines = {}
    for _, verb in ipairs(order) do lines[#lines + 1] = verbs[verb].help end
    return "ok", table.concat(lines, "\n")
end, { help = "help - this list" })

cmd.register("ping", function(ctx)
    return "ok", string.format("pong frame=%d pawn=%s cap=%s", frame, ctx.pawn and "yes" or "no", tostring(state.fpsCap))
end, { help = "ping - is the probe listening (works at the title screen)" })

cmd.register("cap", function(ctx, args)
    local cap = tonumber(args[1])
    if not cap then return "error", "cap <fps>, 0 for uncapped" end
    if not ctx.pc then return "error", "no player controller yet" end
    setCap(ctx, cap)
    return "ok", "t.MaxFPS " .. math.floor(cap)
end, { help = "cap <fps> - set t.MaxFPS (0 uncapped), as F5-F8/F4 do" })

cmd.register("keys", function()
    local list = {}
    for _, name in ipairs(keyOrder) do list[#list + 1] = name end
    return "ok", table.concat(list, " ")
end, { help = "keys - every key the probe binds (key <name> presses it)" })

cmd.register("key", function(_, args)
    if #args == 0 then return "error", "key <name> [<name> ...], e.g. key F5 or key END" end
    local pressed = {}
    for _, raw in ipairs(args) do
        local name = normalizeKey(raw)
        local callbacks = keyBinds[name]
        if not callbacks then return "error", string.format("no probe key bind for %s (keys lists them)", raw) end
        for _, fn in ipairs(callbacks) do fn() end
        pressed[#pressed + 1] = name
    end
    return "ok", "pressed " .. table.concat(pressed, " ")
end, { help = "key <name> ... - call what a probe hotkey does (the game itself sees no key)" })

cmd.register("state", function(ctx)
    local levels = require("lib.levels")
    local replay = require("tools.replay")
    local r = ctx.r
    local level, origin = levels.current(ctx.pawn)
    local parts = {
        "level=" .. tostring(level),
        "cap=" .. tostring(state.fpsCap),
        "replay=" .. (replay.running() and "running" or (replay.recording() and "recording" or "idle")),
        "travelling=" .. tostring(require("tools.quicksave").travelling()),
        "swapping=" .. tostring(require("lib.gameswap").running()),
    }
    if r then
        local fps = (r.dt and r.dt > 0) and 1 / r.dt or 0
        parts[#parts + 1] = string.format("fps=%.0f t=%.2f", fps, r.time)
        parts[#parts + 1] = string.format("pos=%.1f,%.1f,%.1f", r.x, r.y, r.z)
        if origin then parts[#parts + 1] = string.format("rel=%.1f,%.1f,%.1f", r.x - origin.X, r.y - origin.Y, r.z) end
        parts[#parts + 1] = string.format("yaw=%.1f speed=%.1f vz=%.1f mode=%s", r.yaw, r.speed, r.vz or 0,
            util.MOVE_MODE_NAMES[r.mode] or tostring(r.mode))
        if r.camYaw == r.camYaw then parts[#parts + 1] = string.format("camYaw=%.1f", r.camYaw) end
    end
    return "ok", table.concat(parts, " ")
end, { pawn = true, help = "state - level, cap, fps, position (absolute and level-relative), yaw, speed, mode, replay/travel state" })

cmd.register("teleport", function(ctx, args)
    local x, y, z = tonumber(args[1]), tonumber(args[2]), tonumber(args[3])
    if not (x and y and z) then return "error", "teleport <x> <y> <z> [yaw=<deg>] [rel]" end
    local relative = false
    for _, a in ipairs(args) do if a == "rel" then relative = true end end
    if relative then
        local _, origin = require("lib.levels").current(ctx.pawn)
        if not origin then return "error", "the level origin is unavailable" end
        x, y = x + origin.X, y + origin.Y
    end
    local rot = ctx.pawn:K2_GetActorRotation()
    local yaw = tonumber(args.yaw) or rot.Yaw
    local placed = ctx.pawn:K2_TeleportTo({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = yaw, Roll = 0 })
    if ctx.cmc then ctx.cmc.Velocity = { X = 0, Y = 0, Z = 0 } end
    return "ok", string.format("at %.1f,%.1f,%.1f yaw=%.1f%s", x, y, z, yaw,
        placed == false and " (no room there; the engine moved him)" or "")
end, { pawn = true, help = "teleport <x> <y> <z> [yaw=<deg>] [rel] - move Spyro (rel: x,y from the level origin, as state's rel=)" })

cmd.register("quicksave", function(_, args)
    local kind = args[1]
    local known = { save = true, load = true, reload = true, transporter = true }
    if not known[kind] then return "error", "quicksave save|load|reload|transporter (V/B/L/N)" end
    require("tools.quicksave").request(kind)
    return "ok", "requested " .. kind
end, { pawn = true, help = "quicksave save|load|reload|transporter - V/B/L/N" })

cmd.register("reload", function(ctx)
    local finished = false
    local ok = require("tools.quicksave").reloadLevel(ctx.pawn, function() finished = true end)
    if not ok then return "error", "no gameplay sublevels to reload" end
    return "started", "reloading the level's gameplay sublevels", function()
        if finished then return "done", "level reloaded" end
    end, 120
end, { pawn = true, help = "reload - stream the level's gameplay sublevels out and back (no teleport)" })

cmd.register("travel", function(ctx, args)
    local level = (args[1] or ""):upper()
    if not level:match("^LS[123]%d%d$") then return "error", "travel <LS###> (LS1xx-LS3xx)" end
    local levels = require("lib.levels")
    local quicksave = require("tools.quicksave")
    local here = levels.current(ctx.pawn)
    if here == level then return "ok", "already in " .. level end
    if here and here:sub(3, 3) ~= level:sub(3, 3) then
        return "error", string.format("%s is in another game than %s: swap %s first", level, here, level:sub(3, 3))
    end
    if not quicksave.travel(ctx.pawn, level) then return "error", "travel did not start (see the log)" end
    return "started", "travelling to " .. level, function(now)
        if quicksave.travelling() then return nil end
        local arrived = now.pawn and levels.current(now.pawn)
        if arrived == level then return "done", "in " .. level end
        return "error", string.format("travel ended in %s, not %s", tostring(arrived), level)
    end, 90
end, { pawn = true, help = "travel <LS###> - load a level of the current game (done once Spyro stands there)" })

cmd.register("swap", function(_, args)
    local game = tonumber(args[1])
    if not (game and game >= 1 and game <= 3) then return "error", "swap <1|2|3>" end
    local gameswap = require("lib.gameswap")
    if gameswap.running() then return "error", "a game swap is already running" end
    gameswap.begin(game)
    return "started", "swapping to Spyro " .. game, function()
        local result = gameswap.finished()
        if result == nil then return nil end
        if result == "done" then return "done", "in Spyro " .. game end
        return "error", tostring(result)
    end, 120
end, { help = "swap <1|2|3> - change game through the title screen (as the world tour does)" })

-- replay.onFinish only ever adds listeners, so there is one, registered on first use, handing each run's
-- summary to the replay command waiting for it (one replay runs at a time).
local waitingReplay = nil
local function watchReplay()
    if cmd.replayWatched then return end
    cmd.replayWatched = true
    require("tools.replay").onFinish(function(summary)
        if waitingReplay then waitingReplay(summary) end
    end)
end

cmd.register("replay", function(ctx, args)
    local replay = require("tools.replay")
    if replay.recording() then return "error", "a take is being recorded (replay-record stop ends it)" end
    local take = args.take or args[1]
    if take == "newest" then take = nil end
    if args.cap then
        local cap = tonumber(args.cap)
        if not cap then return "error", "replay cap=<fps>: not a number" end
        setCap(ctx, cap)
    end
    watchReplay()
    local summary, startedAt, sawRun = nil, os.clock(), false
    waitingReplay = function(s) if not summary then summary = s end end
    replay.requestPlay(take)
    return "started", string.format("replaying %s%s", take or "the newest take", args.cap and (" at " .. args.cap .. " FPS") or ""), function()
        if summary then
            waitingReplay = nil
            if summary.failed then return "error", summary.reason end
            local status = summary.reason == "completed" and "done" or "error"
            return status, string.format("take=%s cap=%s %s after %.1f of %.1f s trace=%s", tostring(summary.id),
                tostring(summary.cap), summary.reason, summary.elapsed or 0, summary.length or 0, tostring(summary.path))
        end
        if replay.running() then sawRun = true end
        if not sawRun and os.clock() - startedAt > 5 then
            waitingReplay = nil
            return "error", "the replay did not start (no take for this level, or see the replay: lines in the log)"
        end
    end, 3600
end, { pawn = true, help = "replay [take=<id>|newest] [cap=<fps>] - play a take from its start, as End does; done when it ends" })

cmd.register("replay-reset", function(_, args)
    local replay = require("tools.replay")
    watchReplay()
    local summary, startedAt, sawRun = nil, os.clock(), false
    waitingReplay = function(s) if not summary then summary = s end end
    replay.requestReset()
    return "started", "resetting the level to the selected or newest take's start", function()
        if summary then
            waitingReplay = nil
            return "done", string.format("Spyro on the start of %s (%s)", tostring(summary.id), summary.reason)
        end
        if replay.running() then sawRun = true end
        if not sawRun and os.clock() - startedAt > 5 then
            waitingReplay = nil
            return "error", "the reset did not start (see the replay: lines in the log)"
        end
    end, 120
end, { pawn = true, help = "replay-reset - PageUp: reload the sublevels, Spyro on the take's start" })

cmd.register("replay-abort", function()
    local replay = require("tools.replay")
    if not replay.running() then return "ok", "no replay running" end
    replay.requestReplay() -- End while a run is going aborts it
    return "ok", "aborting"
end, { help = "replay-abort - stop a running replay (End)" })

cmd.register("replay-record", function(_, args)
    local replay = require("tools.replay")
    local want = args[1]
    if want ~= "start" and want ~= "stop" then return "error", "replay-record start|stop" end
    if (want == "start") == replay.recording() then
        return "ok", want == "start" and "already recording" or "not recording"
    end
    local before = replay.lastSaved()
    replay.requestRecord()
    return "started", want == "start" and "starting a take" or "stopping the take", function()
        if want == "start" then
            if replay.recording() then return "done", "recording" end
        else
            local saved = replay.lastSaved()
            if saved and saved ~= before then
                return "done", string.format("take=%s frames=%d seconds=%.1f", saved.id, saved.frames, saved.seconds)
            end
        end
    end, 10
end, { pawn = true, help = "replay-record start|stop - Home; stop answers with the saved take id" })

cmd.register("takes", function(ctx, args)
    local level = args[1] or require("lib.levels").current(ctx.pawn)
    if not level then return "error", "takes [LS###]: no level" end
    local list = {}
    for _, take in ipairs(require("tools.replay").takes(level)) do list[#list + 1] = take.id end
    return "ok", #list > 0 and table.concat(list, "\n") or ("no takes for " .. level)
end, { pawn = true, help = "takes [LS###] - replay takes for a level, newest first" })

-- Every character in the level by class, with what decides how it gets going from a standstill
-- (.claude/skills/npc-accel-check): MaxAcceleration, MaxWalkSpeed, movement mode, and whether its AI's
-- requested moves accelerate (fixes/npcwalk.lua covers those). With a class filter, each matching
-- character's name, level-relative position and distance from Spyro instead. One FindAllOf walk.
cmd.register("characters", function(ctx, args)
    local filter = args[1] and args[1]:lower()
    local _, origin = require("lib.levels").current(ctx.pawn)
    local ox, oy = origin and origin.X or 0, origin and origin.Y or 0
    local me = ctx.pawn:K2_GetActorLocation()
    local classes, order, lines = {}, {}, {}
    for _, actor in ipairs(FindAllOf("Character") or {}) do
        pcall(function()
            if not actor:IsValid() or actor:GetAddress() == ctx.pawn:GetAddress() then return end
            local class = actor:GetClass():GetFName():ToString()
            if filter then
                if not class:lower():find(filter, 1, true) then return end
                local l = actor:K2_GetActorLocation()
                lines[#lines + 1] = string.format("%s %s rel=%.0f,%.0f,%.0f dist=%.0f", actor:GetFName():ToString(),
                    class, l.X - ox, l.Y - oy, l.Z, math.sqrt((l.X - me.X) ^ 2 + (l.Y - me.Y) ^ 2))
                return
            end
            local c = classes[class]
            if not c then
                local m = actor.CharacterMovement
                c = { n = 0, text = string.format("acc=%.0f walk=%.0f mode=%s requestedAccel=%s", m.MaxAcceleration,
                    m.MaxWalkSpeed, util.MOVE_MODE_NAMES[m.MovementMode] or tostring(m.MovementMode),
                    tostring(m.bRequestedMoveUseAcceleration)) }
                classes[class] = c
                order[#order + 1] = class
            end
            c.n = c.n + 1
        end)
    end
    if filter then
        table.sort(lines)
        return "ok", #lines > 0 and table.concat(lines, "\n") or ("no character class matches " .. args[1])
    end
    table.sort(order)
    for _, class in ipairs(order) do lines[#lines + 1] = string.format("%s x%d %s", class, classes[class].n, classes[class].text) end
    return "ok", table.concat(lines, "\n")
end, { pawn = true, help = "characters [class text] - every character class (count, acceleration, walk speed, mode); with a filter, each one's position and distance" })

-- tools/debugunlock.lua (guidebook levels, Spyro 2/3 abilities and characters) applies everything once
-- and is idempotent. Required here only when asked, so a probe without that module still loads.
cmd.register("unlock", function(ctx)
    local ok, debugunlock = pcall(require, "tools.debugunlock")
    if not ok then return "error", "tools/debugunlock.lua is not in this probe: " .. tostring(debugunlock) end
    local result = debugunlock.apply(ctx.pawn)
    return "ok", result ~= nil and describe(result) or "applied"
end, { pawn = true, help = "unlock - debugunlock.apply: guidebook levels, abilities, characters (tools/debugunlock.lua)" })

-- The trigger files the tools already read, written by the probe itself (so never with a BOM).
local TRIGGERS = { autotest = true, review = true, animtest = true, scansweep = true, spawntest = true,
                   dumpstate = true, minigame = true, scan = true }
cmd.register("trigger", function(_, args, c)
    local name = args[1]
    if not (name and TRIGGERS[name]) then
        local list = {}
        for k in pairs(TRIGGERS) do list[#list + 1] = k end
        table.sort(list)
        return "error", "trigger <" .. table.concat(list, "|") .. "> [options...]"
    end
    local options = c.rest:gsub("^%S+%s*", "")
    local file = io.open(paths.modDir .. "\\" .. name .. ".txt", "w")
    if not file then return "error", "could not write " .. name .. ".txt" end
    file:write(options)
    file:close()
    return "ok", string.format("%s.txt written (%s)", name, options == "" and "no options" or options)
end, { help = "trigger <tool> [options] - write that tool's trigger file (autotest, animtest, scansweep, ...)" })

-- Lua in the probe's own state, with the frame's objects at hand. A dev tool for a local mod: anything
-- that can write cmd.txt can already rewrite the probe's scripts.
cmd.register("eval", function(ctx, _, c)
    local env = setmetatable({ pc = ctx.pc, pawn = ctx.pawn, cmc = ctx.cmc, r = ctx.r, ctx = ctx,
                               UEHelpers = UEHelpers, log = log, state = state }, { __index = _G })
    local chunk = load("return " .. c.rest, "=eval", "t", env)
    if not chunk then
        local err
        chunk, err = load(c.rest, "=eval", "t", env)
        if not chunk then return "error", err end
    end
    local results = table.pack(chunk())
    local parts = {}
    for i = 1, results.n do parts[#parts + 1] = describe(results[i]) end
    return "ok", results.n > 0 and table.concat(parts, ", ") or "(no value)"
end, { help = "eval <lua> - run Lua in the probe (pc, pawn, cmc, r = last row, state, UEHelpers); returns the values" })

-- Results from an earlier session are of no use to anyone waiting now.
do
    local file = io.open(RESULT, "w")
    if file then file:close() end
end
wrapKeyBinds()

return cmd
