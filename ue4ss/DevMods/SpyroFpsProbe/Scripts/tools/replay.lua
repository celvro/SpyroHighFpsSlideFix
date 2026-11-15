-- Full-level input capture and replay (Home / End). The missing piece between the world tour's preset
-- scripts and a real playthrough: record every input of a level played by hand, then play the same
-- inputs back from the same start at another framerate and write a trace to compare against the
-- recording. Free-run by design: nothing corrects the course, so after a real physics divergence the
-- rest of a run documents the drift, not the level. For a bug late in a level, record a second,
-- shorter take that goes straight to it (takes are per level and kept; see "files" below).
--
--   Home  start/stop recording a take (stand where the run should start, in the level, on the ground)
--   End   replay the newest take recorded for this level, at the current F5-F8 cap (no cap pressed
--         this session: the cap the take was recorded at); press again to abort
--
-- A replay reloads the level's gameplay sublevels first (quicksave.reloadLevel), so enemies and
-- mechanisms start where a fresh entry puts them, then teleports Spyro onto the take's start, settles,
-- and drives lib/input.lua from the take by game time. Text boxes and cutscenes that open are pressed
-- through (lib/igc.lua / lib/dialogue.lua), as the world tour does.
--
-- What is captured, and how:
--   axes     read each sampled frame from the character's input component (lib/input.lua's cache):
--            left/right stick, both trigger axes when the component has them
--   buttons  RegisterHook on the input events, the way lib/mouse.lua hooks the mouse axis. Spyro's
--            Blueprint implements FaceBottom/FaceRight (jump/flame); the rest are tried on the native
--            FalconCharacterInputComponent. A button whose event can't be hooked is logged once;
--            charge (FaceLeft, native) additionally falls back to the row's charging tag, which
--            follows the held button closely on the ground.
--   FaceTop  not captured and never replayed, for lib/input.lua's reason: a release sent for it
--            still reaches FreeLook.
--
-- Files, flat in this mod folder like every other output (positions are level-origin-relative, so a
-- take survives the level streaming in at a different LevelTransform):
--   replay_<level>_<stamp>_inputs.csv       one row per sampled frame of the recording
--   replay_<level>_<stamp>_ref.csv          the trace recorded alongside (same columns as a run)
--   replay_<level>_<stamp>_run<cap>_<t>.csv one replay run's trace
--   replay_takes.txt                        one line per take: "<level> <level>_<stamp>"; End picks
--                                           the last line for the current level
-- Compare a run against its ref with tools/compare_replays.py (python3; runs in the Cowork VM, not
-- on the game PC, which has no Python).
--
-- Log lines: "replay" (start/stop/abort/progress, and why a capture channel is degraded).
local UEHelpers = require("UEHelpers")
local anim = require("lib.anim")
local dialogue = require("lib.dialogue")
local igc = require("lib.igc")
local input = require("lib.input")
local invuln = require("lib.invuln")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local quicksave = require("tools.quicksave")
local overlay = require("tools.overlay")
local util = require("lib.util")

local num = util.num

local replay = {}

local SETTLE = 1.0       -- seconds standing on the start spot before the take plays
local SETTLE_MAX = 6.0   -- a start spot still falling/unplaced after this long aborts the run
local TAIL = 0.5         -- seconds of stillness written after the last input row
local PROGRESS_EVERY = 10 -- seconds of game time between "replay: ... s" progress lines
local INDEX = paths.modDir .. "\\replay_takes.txt"

-- The buttons captured and replayed, with the event that reports each one. BP: implemented by
-- Spyro's Blueprint (hook the Blueprint class function, found from the live component's class).
-- native: FalconCharacterInputComponent's own UFunction.
local NATIVE_CLASS = "/Script/Falcon.FalconCharacterInputComponent:"
local BUTTONS = {
    { key = "jump",     event = "InputAction_FaceBottom",    bp = true },
    { key = "flame",    event = "InputAction_FaceRight",     bp = true },
    { key = "charge",   event = "InputAction_FaceLeft",      bp = false },
    { key = "shoulderL", event = "InputAction_ShoulderLeft",  bp = false },
    { key = "shoulderR", event = "InputAction_ShoulderRight", bp = false },
    { key = "triggerL", event = "InputAction_TriggerLeft",   bp = false },
    { key = "triggerR", event = "InputAction_TriggerRight",  bp = false },
}
local BUTTON_ORDER = { "jump", "charge", "flame", "shoulderL", "shoulderR", "triggerL", "triggerR" }

local held = {}          -- button key -> true while the player holds it (written by the hooks)
local hooked = {}        -- button key -> true once its event hook is registered
local hookFailed = {}    -- button key -> true once registering was tried and failed (logged then)
local hooksTriedAt = nil -- os.clock() of the last registration sweep that left something unhooked
local chargeFallback = false -- charge comes from the charging tag (its event could not be hooked)
local axisProbe = nil    -- which optional axis properties this component has (probed once)

local pending = nil      -- "record" or "replay", set by a key, handled in the game thread
local pendingMenu = nil  -- "toggle" or "cycle" for the take picker (Ins / Del)
local rec = nil          -- recording in progress
local run = nil          -- replay in progress

-- ---------------------------------------------------------------- on-screen debug menu (Ins / Del)
--
-- Drawn with KismetSystemLibrary:PrintString (on-screen debug text) each frame while recording, while
-- a replay runs, or while the take picker is open -- so the recording state is visible and a take can
-- be chosen for the current level before End. Ins toggles the picker; Del steps the selection; End
-- plays the selected take (the newest if none is selected). ASCII only, for the game's debug font.
local menuOpen = false
local menuTakes = {}     -- { { id, when }, ... } newest first, for menuLevel
local menuLevel = nil
local menuIndex = 1
local selected = nil     -- { level, id } the user picked; End prefers it over the newest

-- "LS102_20261115_142209" -> "14:22:09", for a readable line in the picker.
local function takeWhen(id)
    local h, m, s = id:match("_%d%d%d%d%d%d%d%d_(%d%d)(%d%d)(%d%d)$")
    return h and string.format("%s:%s:%s", h, m, s) or id
end

-- Every take recorded for a level, newest first (replay_takes.txt is appended, so newest is last).
local function takesFor(level)
    local list = {}
    local file = io.open(INDEX, "r")
    if file then
        for line in file:lines() do
            local lineLevel, id = util.stripBom(line):match("^(%S+)%s+(%S+)$")
            if lineLevel == level then table.insert(list, 1, { id = id, when = takeWhen(id) }) end
        end
        file:close()
    end
    return list
end

-- The overlay (tools/overlay.lua) is a UMG widget, the only thing that draws in this Shipping build.

-- Called each frame; drives the UMG overlay (tools/overlay.lua).
local function drawOverlay(pc, pawn, r)
    local lines = {}
    if rec then
        lines[#lines + 1] = string.format("[REC] %s   %d frames   %.1fs    (Home stops)",
            rec.level, rec.frames, rec.lastT or 0)
    elseif run then
        local total = run.take.rows[#run.take.rows].t
        lines[#lines + 1] = string.format("[PLAY] %s  @%d fps   %s   %.1f/%.1fs    (End aborts)",
            run.take.id, run.cap, run.phase, run.elapsed or 0, total)
    end
    if menuOpen then
        lines[#lines + 1] = string.format("-- replay takes for %s  (Up/Down choose, End plays) --",
            tostring(menuLevel))
        if #menuTakes == 0 then
            lines[#lines + 1] = "   (none for this level -- Home records one)"
        else
            for i, take in ipairs(menuTakes) do
                lines[#lines + 1] = string.format("  %s %s  (%s)%s",
                    i == menuIndex and ">" or "  ", take.id, take.when, i == 1 and "   [newest]" or "")
            end
        end
        local cancelIdx = #menuTakes + 1
        lines[#lines + 1] = string.format("  %s [ cancel ]", menuIndex == cancelIdx and ">" or "  ")
    end
    if #lines == 0 then
        -- Idle, in a level: a one-line hint. Doubles as the render check while the widget is new.
        lines[#lines + 1] = "[replay]  End: pick a take   Home: record"
    end
    overlay.set(pc, table.concat(lines, "\n"))
end


-- ---------------------------------------------------------------- capture: button hooks

local function hookButton(b, path)
    local fn = StaticFindObject(path)
    if not (fn and fn:IsValid()) then return false, "not found" end
    local ok, err = pcall(RegisterHook, path, function(context, pressed)
        local okGet, value = pcall(function() return pressed:get() end)
        if okGet and type(value) == "boolean" then held[b.key] = value or nil end
    end)
    if not ok then return false, tostring(err) end
    return true
end

-- Register what can be registered, once the component exists; retried while something is missing,
-- at most once a second (a StaticFindObject miss scans the object array: CLAUDE.md).
local function registerHooks(pawn, pc)
    local missing = false
    for _, b in ipairs(BUTTONS) do
        if not hooked[b.key] and not hookFailed[b.key] then missing = true end
    end
    if not missing then return end
    if hooksTriedAt and os.clock() - hooksTriedAt < 1.0 then return end
    hooksTriedAt = os.clock()
    local component = input.component(pawn, pc)
    local bpPrefix = nil
    if component then
        local ok, full = pcall(function() return component:GetClass():GetFullName() end)
        local path = ok and type(full) == "string" and full:match("^%S+%s+(.+)$") or nil
        if path then bpPrefix = path .. ":" end
    end
    for _, b in ipairs(BUTTONS) do
        if not hooked[b.key] and not hookFailed[b.key] then
            local tried = {}
            -- The Blueprint subclass first for the events Spyro implements, the native class for the
            -- rest -- and each falls back to the other, so a character that overrides differently
            -- still gets its buttons.
            local order = b.bp and { bpPrefix, NATIVE_CLASS } or { NATIVE_CLASS, bpPrefix }
            for _, prefix in ipairs(order) do
                if prefix then
                    local ok, why = hookButton(b, prefix .. b.event)
                    if ok then
                        hooked[b.key] = true
                        break
                    end
                    tried[#tried + 1] = string.format("%s (%s)", prefix .. b.event, tostring(why))
                end
            end
            if not hooked[b.key] and (bpPrefix or not b.bp) then
                hookFailed[b.key] = true
                if b.key == "charge" then
                    chargeFallback = true
                    log("replay: charge events not hookable; recording charge from the charging tag instead (%s)",
                        table.concat(tried, "; "))
                else
                    log("replay: %s not captured: %s", b.key, table.concat(tried, "; "))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- replay: forcing the stored stick
--
-- The charge turn reads the component's stored InputAxisLeftStickX, which the engine resets from
-- hardware (0, with no controller touching it) every input tick -- before the charge movement runs.
-- Writing the property from the end-of-frame sample loses that race (the stored value read back 0 in
-- all 282 charging frames of the first replay, and the charge steered straight). So, exactly as the
-- fix mod does for mouse steering on InputAxis_RightStick_X, hook the left-stick axis functions: the
-- Blueprint stores the frame's value in its body, and this pre-hook (which runs AFTER the body in this
-- UE4SS build, see CLAUDE.md) overwrites it with the replay's value, in time for the charge to read it.
local INJECT_FUNCS = {
    InputAxisLeftStickX = "/CharacterCommon/Components/CharacterInputComponent/CharacterInputComponent_Spyro.CharacterInputComponent_Spyro_C:InputAxis_LeftStick_X",
    InputAxisLeftStickY = "/CharacterCommon/Components/CharacterInputComponent/CharacterInputComponent_Spyro.CharacterInputComponent_Spyro_C:InputAxis_LeftStick_Y",
}
local injectAxes = nil       -- { InputAxisLeftStickX = n, InputAxisLeftStickY = n } while a replay drives; nil otherwise
local injectHooked = {}      -- property name -> true once its hook is registered
local injectTriedAt = nil    -- os.clock() of the last registration sweep that left one unhooked

local function registerInjectHooks()
    local missing = false
    for prop in pairs(INJECT_FUNCS) do if not injectHooked[prop] then missing = true end end
    if not missing then return end
    if injectTriedAt and os.clock() - injectTriedAt < 1.0 then return end
    injectTriedAt = os.clock()
    for prop, path in pairs(INJECT_FUNCS) do
        if not injectHooked[prop] then
            local fn = StaticFindObject(path)
            if fn and fn:IsValid() then
                local ok, err = pcall(RegisterHook, path, function(context)
                    if not injectAxes then return end
                    local okc, comp = pcall(function() return context:get() end)
                    if okc and comp and comp:IsValid() then
                        pcall(function() comp[prop] = injectAxes[prop] or 0 end)
                    end
                end)
                if ok then
                    injectHooked[prop] = true
                    log("replay: stick injection hook on %s registered", prop)
                else
                    log("replay: could not hook %s (%s); the charge turn may not replay", prop, tostring(err))
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- capture: axes

local function probeAxes(component)
    if axisProbe then return axisProbe end
    local probe = {}
    local function has(name)
        local ok, value = pcall(function() return component[name] end)
        return ok and type(value) == "number"
    end
    probe.ry = has("InputAxisRightStickY")
    probe.tl = has("InputAxisTriggerLeft")
    probe.tr = has("InputAxisTriggerRight")
    axisProbe = probe
    local missing = {}
    if not probe.ry then missing[#missing + 1] = "right stick Y" end
    if not probe.tl then missing[#missing + 1] = "trigger L" end
    if not probe.tr then missing[#missing + 1] = "trigger R" end
    if #missing > 0 then
        log("replay: this input component has no %s axis; recorded as 0", table.concat(missing, ", "))
    end
    return probe
end

local function readAxes(pawn, pc)
    local component = input.component(pawn, pc)
    if not component then return nil end
    local ok, axes = pcall(function()
        local probe = probeAxes(component)
        return {
            lx = component.InputAxisLeftStickX, ly = component.InputAxisLeftStickY,
            rx = component.InputAxisRightStickX,
            ry = probe.ry and component.InputAxisRightStickY or 0,
            tl = probe.tl and component.InputAxisTriggerLeft or 0,
            tr = probe.tr and component.InputAxisTriggerRight or 0,
        }
    end)
    return ok and axes or nil
end

-- ---------------------------------------------------------------- the trace both modes write

local TRACE_HEADER = "t,dt,x,y,z,yaw,vx,vy,vz,speed,mode,custom_mode,charging,pressed_jump,montage,montage_pos,cam_yaw\n"

local function writeTraceRow(file, t, r, pawn, origin)
    local s = anim.state(pawn)
    file:write(string.format("%.5f,%.5f,%.3f,%.3f,%.3f,%.2f,%.3f,%.3f,%.3f,%.2f,%d,%d,%s,%s,%s,%.4f,%.3f\n",
        t, num(r.dt), num(r.x) - origin.x, num(r.y) - origin.y, num(r.z), num(r.yaw),
        num(r.vx), num(r.vy), num(r.vz), num(r.speed), num(r.mode), num(r.customMode),
        tostring(r.charging), tostring(r.pressedJump), s.montage, s.position, num(r.camYaw)))
end

-- ---------------------------------------------------------------- recording

local function startRecord(pawn, pc, r)
    if run then
        log("replay: can't record while a replay is running (End aborts it)")
        return
    end
    local level, origin = levels.current(pawn)
    if not level then
        log("replay: the level name is unavailable; not recording")
        return
    end
    if not origin then
        origin = { X = 0, Y = 0 }
        log("replay: no LevelTransform for %s; recording absolute positions (comparable within this load only)", level)
    end
    if r.mode == 3 then
        log("replay: start on the ground, not falling; not recording")
        return
    end
    local id = string.format("%s_%s", level, os.date("%Y%m%d_%H%M%S"))
    local inputsPath = string.format("%s\\replay_%s_inputs.csv", paths.modDir, id)
    local refPath = string.format("%s\\replay_%s_ref.csv", paths.modDir, id)
    local inputs = io.open(inputsPath, "w")
    local ref = io.open(refPath, "w")
    if not inputs or not ref then
        if inputs then inputs:close() end
        if ref then ref:close() end
        log("replay: could not open %s", inputs and refPath or inputsPath)
        return
    end
    local rot = pawn:K2_GetActorRotation()
    local ctrl = pc:GetControlRotation()
    inputs:write(string.format("# v1|level=%s|cap=%s|origin=%.1f,%.1f|start=%.3f,%.3f,%.3f|rot=%.3f,%.3f,%.3f|ctrl=%.3f,%.3f\n",
        level, tostring(require("lib.state").fpsCap or ""), origin.X, origin.Y,
        r.x - origin.X, r.y - origin.Y, r.z, rot.Pitch, rot.Yaw, rot.Roll, ctrl.Pitch, ctrl.Yaw))
    inputs:write("t,lx,ly,rx,ry,tl,tr," .. table.concat(BUTTON_ORDER, ",") .. "\n")
    ref:write(TRACE_HEADER)
    rec = {
        id = id, level = level, origin = { x = origin.X, y = origin.Y },
        inputs = inputs, ref = ref, start = r.time, frames = 0,
    }
    log("replay: RECORDING %s (stop with Home). Play the level; avoid dying.", id)
end

local function stopRecord(reason)
    local r = rec
    rec = nil
    if not r then return end
    r.inputs:close()
    r.ref:close()
    local index = io.open(INDEX, "a")
    if index then
        index:write(string.format("%s %s\n", r.level, r.id))
        index:close()
    end
    log("replay: take %s saved, %d frames, %.1f s (%s)", r.id, r.frames, r.lastT or 0, reason)
end

local function updateRecord(pawn, pc, r)
    registerHooks(pawn, pc)
    local axes = readAxes(pawn, pc)
    if not axes then return end -- no component this frame; the gap stays out of the file
    if chargeFallback then held.charge = r.charging or nil end
    local t = r.time - rec.start
    local flags = {}
    for i, key in ipairs(BUTTON_ORDER) do flags[i] = held[key] and "1" or "0" end
    rec.inputs:write(string.format("%.5f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%s\n",
        t, num(axes.lx), num(axes.ly), num(axes.rx), num(axes.ry), num(axes.tl), num(axes.tr),
        table.concat(flags, ",")))
    writeTraceRow(rec.ref, t, r, pawn, rec.origin)
    rec.frames = rec.frames + 1
    rec.lastT = t
end

-- ---------------------------------------------------------------- loading a take

local function newestTake(level)
    local file = io.open(INDEX, "r")
    if not file then return nil end
    local newest = nil
    for line in file:lines() do
        local lineLevel, id = util.stripBom(line):match("^(%S+)%s+(%S+)$")
        if lineLevel == level then newest = id end
    end
    file:close()
    return newest
end

local function loadTake(id)
    local path = string.format("%s\\replay_%s_inputs.csv", paths.modDir, id)
    local file = io.open(path, "r")
    if not file then
        log("replay: %s is missing", path)
        return nil
    end
    local header = file:read("l")
    local take = { id = id, rows = {} }
    for field in (header or ""):gmatch("([^|]+)") do
        local name, value = field:match("^%s*#?%s*(%w+)=(.*)$")
        if name == "level" then take.level = value end
        if name == "cap" then take.cap = tonumber(value) end
        if name == "origin" then take.originX, take.originY = value:match("^([%-%d%.]+),([%-%d%.]+)$") end
        if name == "start" then take.sx, take.sy, take.sz = value:match("^([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)$") end
        if name == "rot" then take.pitch, take.yaw, take.roll = value:match("^([%-%d%.]+),([%-%d%.]+),([%-%d%.]+)$") end
        if name == "ctrl" then take.ctrlPitch, take.ctrlYaw = value:match("^([%-%d%.]+),([%-%d%.]+)$") end
    end
    file:read("l") -- the column line
    for line in file:lines() do
        local fields = {}
        for field in line:gmatch("[^,]+") do fields[#fields + 1] = field end
        if #fields >= 7 + #BUTTON_ORDER then
            local row = {
                t = tonumber(fields[1]),
                lx = tonumber(fields[2]), ly = tonumber(fields[3]),
                rx = tonumber(fields[4]), ry = tonumber(fields[5]),
                tl = tonumber(fields[6]), tr = tonumber(fields[7]),
            }
            for i, key in ipairs(BUTTON_ORDER) do row[key] = fields[7 + i] == "1" end
            if row.t then take.rows[#take.rows + 1] = row end
        end
    end
    file:close()
    for _, name in ipairs({ "sx", "sy", "sz", "pitch", "yaw", "roll", "ctrlPitch", "ctrlYaw" }) do
        take[name] = tonumber(take[name])
        if not take[name] then
            log("replay: %s has a broken header (%s); not replaying it", id, name)
            return nil
        end
    end
    if #take.rows == 0 then
        log("replay: %s has no input rows; not replaying it", id)
        return nil
    end
    return take
end

-- ---------------------------------------------------------------- replaying

local function finishRun(pawn, pc, reason)
    local s = run
    run = nil
    injectAxes = nil
    if not s then return end
    input.clear(pawn, pc)
    if s.file then s.file:close() end
    log("replay: run of %s at %d FPS %s after %.1f s of %.1f (%s)",
        s.take.id, s.cap, reason, s.elapsed or 0, s.take.rows[#s.take.rows].t,
        s.path or "no trace written")
end

local function startReplay(pawn, pc, r, setFpsCap)
    if rec then
        log("replay: can't replay while recording (Home stops the recording)")
        return
    end
    local level, origin = levels.current(pawn)
    if not level then
        log("replay: the level name is unavailable")
        return
    end
    local id = nil
    if selected and selected.level == level and newestTake(level) then
        -- Use the picked take only if it still exists in the index.
        for _, take in ipairs(takesFor(level)) do
            if take.id == selected.id then id = selected.id break end
        end
    end
    id = id or newestTake(level)
    if not id then
        log("replay: no take recorded for %s yet (Home records one)", level)
        return
    end
    log("replay: End will play %s (%s)", id, (selected and selected.id == id) and "picked in the menu" or "the newest take")
    local take = loadTake(id)
    if not take then return end
    local state = require("lib.state")
    local cap = state.fpsCap or take.cap
    if not cap then
        cap = 30
        log("replay: no cap set this session and none in the take; using 30")
    end
    origin = origin or { X = 0, Y = 0 }
    local stamp = os.date("%Y%m%d_%H%M%S")
    local path = string.format("%s\\replay_%s_run%d_%s.csv", paths.modDir, id, cap, stamp)
    local file = io.open(path, "w")
    if not file then
        log("replay: could not open %s", path)
        return
    end
    file:write(TRACE_HEADER)
    run = {
        take = take, cap = cap, file = file, path = path,
        origin = { x = origin.X, y = origin.Y },
        phase = "reload", next = 1, elapsed = 0, settled = 0, progressAt = PROGRESS_EVERY,
    }
    setFpsCap(cap)
    log("replay: replaying %s at %d FPS (%d input rows, %.1f s); End aborts", id, cap,
        #take.rows, take.rows[#take.rows].t)
    if not quicksave.reloadLevel(pawn, function()
        if run and run.phase == "reload" then run.phase = "place" end
    end) then
        log("replay: no sublevels to reload; replaying against the level as it stands")
        run.phase = "place"
    end
end

local function place(pawn, pc, cmc)
    local s = run
    local x = s.take.sx + s.origin.x
    local y = s.take.sy + s.origin.y
    pawn:K2_TeleportTo({ X = x, Y = y, Z = s.take.sz },
        { Pitch = s.take.pitch, Yaw = s.take.yaw, Roll = s.take.roll })
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }
    pc:SetControlRotation({ Pitch = s.take.ctrlPitch, Yaw = s.take.ctrlYaw, Roll = 0 })
    if not pcall(function() pawn.FollowCamera:ResetBehind(true) end) then
        pcall(function() pawn.FollowCamera:SetCameraYaw(s.take.yaw) end)
    end
end

local function updateReplay(pawn, pc, cmc, r)
    local s = run
    if s.phase == "reload" then return end -- quicksave is doing the work; its callback moves us on
    if s.phase == "place" then
        place(pawn, pc, cmc)
        s.phase, s.settled = "settle", 0
        return
    end
    if s.phase == "settle" then
        s.settled = s.settled + r.dt
        input.hold({})
        input.apply(pawn, pc)
        local dx, dy = r.x - (s.take.sx + s.origin.x), r.y - (s.take.sy + s.origin.y)
        local off = math.sqrt(dx * dx + dy * dy)
        if off > 300 and s.settled < SETTLE_MAX then
            -- The teleport does not always take on the first try (seen on 9% of tour stops).
            place(pawn, pc, cmc)
            return
        end
        if r.mode == 3 and s.settled < SETTLE_MAX then return end -- let him land first
        if s.settled >= SETTLE_MAX and (off > 300 or r.mode == 3) then
            finishRun(pawn, pc, "aborted: never settled on the start spot")
            return
        end
        if s.settled < SETTLE then return end
        s.phase, s.elapsed = "play", 0
        log("replay: playing")
        return
    end
    -- "play"
    if igc.active(s.take.level) then igc.close(pc, pawn, s.take.level) end
    local health = invuln.health(pawn)
    if health and health <= 0 then
        finishRun(pawn, pc, "DIED -- a death that the recording did not have is a finding")
        return
    end
    local rows = s.take.rows
    while s.next <= #rows and rows[s.next].t <= s.elapsed do
        local row = rows[s.next]
        input.hold({ leftX = row.lx, leftY = row.ly, rightX = row.rx, rightY = row.ry,
                     triggerL = row.tl, triggerR = row.tr })
        s.curLx, s.curLy = row.lx, row.ly
        for _, key in ipairs(BUTTON_ORDER) do
            if row[key] ~= input.held(key) then
                if row[key] then input.press(key) else input.release(key) end
            end
        end
        s.next = s.next + 1
    end
    -- Force the stored stick value the charge turn reads (the event path alone does not reach it).
    injectAxes = { InputAxisLeftStickX = s.curLx or 0, InputAxisLeftStickY = s.curLy or 0 }
    input.apply(pawn, pc)
    writeTraceRow(s.file, s.elapsed, r, pawn, s.origin)
    if s.elapsed >= s.progressAt then
        s.progressAt = s.progressAt + PROGRESS_EVERY
        log("replay: %.0f / %.0f s", s.elapsed, rows[#rows].t)
    end
    s.elapsed = s.elapsed + r.dt
    if s.elapsed > rows[#rows].t + TAIL then finishRun(pawn, pc, "completed") end
end

-- ---------------------------------------------------------------- wiring

function replay.requestRecord() pending = "record" end
function replay.requestReplay() pending = "end" end

-- True while a replay is driving (or waiting out a reload): main.lua answers paused prompts for it.
function replay.running()
    return run ~= nil
end

-- Up / Down arrows: move the take-picker selection (only while it is open).
function replay.menuUp()   pendingMenu = "up" end
function replay.menuDown() pendingMenu = "down" end

-- The picker has #menuTakes entries plus a trailing cancel slot, so the count is one more.
local function menuCount() return #menuTakes + 1 end

local function selectIndex(i)
    menuIndex = i
    if menuTakes[menuIndex] then
        selected = { level = menuLevel, id = menuTakes[menuIndex].id }
        log("replay: selected %d/%d  %s (%s)%s", menuIndex, #menuTakes,
            menuTakes[menuIndex].id, menuTakes[menuIndex].when, menuIndex == 1 and "  [newest]" or "")
    else
        selected = nil -- the cancel slot
        log("replay: selected [ cancel ] (End closes the picker)")
    end
end

-- Open the picker for the level Spyro is in (End, when nothing is running and it is closed).
local function openMenu(pawn)
    local level = levels.current(pawn)
    menuOpen, menuLevel = true, level
    menuTakes = level and takesFor(level) or {}
    selectIndex(1)
    if #menuTakes == 0 then
        log("replay: no takes for %s yet (Home records one). End again closes this.", tostring(level))
    else
        log("replay: take picker open for %s (%d take%s); Up/Down choose, End plays, Home records",
            tostring(level), #menuTakes, #menuTakes == 1 and "" or "s")
    end
end

local function handleMenu(pawn)
    local kind = pendingMenu
    pendingMenu = nil
    if not kind or not menuOpen then return end
    local n = menuCount()
    if kind == "up" then
        selectIndex((menuIndex - 2) % n + 1)
    elseif kind == "down" then
        selectIndex(menuIndex % n + 1)
    end
end

function replay.update(pawn, pc, cmc, r, setFpsCap)
    local kind = pending
    pending = nil
    local ok, err = pcall(function()
        if kind == "record" then
            if rec then stopRecord("stopped with Home") else startRecord(pawn, pc, r) end
        elseif kind == "end" then
            if run then
                finishRun(pawn, pc, "aborted with End")
            elseif menuOpen then
                menuOpen = false
                if selected then
                    startReplay(pawn, pc, r, setFpsCap) -- plays `selected`
                else
                    log("replay: picker cancelled")
                end
            else
                openMenu(pawn)
            end
        end
        registerInjectHooks()
        handleMenu(pawn)
        if rec then updateRecord(pawn, pc, r) end
        if run then updateReplay(pawn, pc, cmc, r) end
        drawOverlay(pc, pawn, r)
    end)
    if not ok then
        log("replay error: %s", tostring(err))
        if rec then stopRecord("stopped by an error") end
        if run then
            local s = run
            run = nil
            if s.file then pcall(function() s.file:close() end) end
            pcall(function() input.clear(pawn, pc) end)
        end
    end
end

return replay
