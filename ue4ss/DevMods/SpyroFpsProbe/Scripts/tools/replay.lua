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
--   PgUp  reset the level: reload its gameplay sublevels and stand Spyro on the start of the selected
--         (else newest) take, then stop -- nothing plays. Aborts a replay or a recording first.
--
-- A replay reloads the level's gameplay sublevels first (quicksave.reloadLevel), so enemies and
-- mechanisms start where a fresh entry puts them, then teleports Spyro onto the take's start, settles,
-- and drives lib/input.lua from the take by game time, Jump as a real Space key (lib/realkeys.lua).
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
local actorstart = require("lib.actorstart")
local actortrace = require("lib.actortrace")
local anim = require("lib.anim")
local config = require("config")
local realkeys = require("lib.realkeys")
local input = require("lib.input")
local invuln = require("lib.invuln")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local playerready = require("lib.playerready")
local quicksave = require("tools.quicksave")
local overlay = require("tools.overlay")
local util = require("lib.util")

local num = util.num

local replay = {}

local SETTLE = 1.0       -- seconds standing on the start spot before the take plays
local SETTLE_MAX = 6.0   -- a start spot still falling/unplaced after this long aborts the run
local PLACE_TOLERANCE = 5 -- units from the take's start the settle accepts (horizontal)
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
local pendingId = nil    -- the take a "play" request names (lib/cmd.lua), instead of the picker's
local finishListeners = {} -- called with { id, cap, reason, path, elapsed, resetOnly } when a run ends
local lastSaved = nil    -- { id, frames, seconds } of the take the last recording saved

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

-- Every key the replay tool uses, shown in the overlay while idle or with the picker open. Keep it in step
-- with the key binds in main.lua. ASCII only (the widget's font).
local LEGEND = {
    "-- replay keys --",
    "Home    record a take (again to stop)",
    "End     take picker / play selected / abort",
    "PgUp    reset level to the take's start",
    "Up/Down choose a take (picker open)",
    "F5      30 FPS      F6   60 FPS",
    "F7      120 FPS     F8   uncapped",
}

-- Called each frame; drives the UMG overlay (tools/overlay.lua).
local function drawOverlay(pc, pawn, r)
    local lines = {}
    if rec then
        lines[#lines + 1] = string.format("[REC] %s   %d frames   %.1fs    (Home stops)",
            rec.level, rec.frames, rec.lastT or 0)
    elseif run then
        local total = run.take.rows[#run.take.rows].t
        lines[#lines + 1] = string.format("[%s] %s  @%d fps   %s   %.1f/%.1fs    (End aborts)",
            run.resetOnly and "RESET" or "PLAY", run.take.id, run.cap, run.phase, run.elapsed or 0, total)
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
    if #lines == 0 or menuOpen then
        -- Idle, or the picker is open: every key this tool uses, one per line.
        for _, text in ipairs(LEGEND) do lines[#lines + 1] = text end
    end
    overlay.set(pc, table.concat(lines, "\n"))
end


-- ---------------------------------------------------------------- capture: button hooks

-- The left stick of a frame whose Jump arrives as a real Space key, held back until that Jump has run
-- (the "play" phase): { pawn, pc, x, y, prevY }.
local deferredStick = nil
local jumpPending = false -- a real Space change is on its way and its Jump has not run yet
local JUMP_WAIT_TICKS = 3 -- ticks a stick is held back for that Jump before it is sent as usual

local function sendDeferredStick()
    local d = deferredStick
    deferredStick, jumpPending = nil, false
    if d and d.pawn:IsValid() and d.pc:IsValid() then input.sendLeftStick(d.pawn, d.pc, d.x, d.y, d.prevY) end
end

local function hookButton(b, path)
    local fn = StaticFindObject(path)
    if not (fn and fn:IsValid()) then return false, "not found" end
    local ok, err = pcall(RegisterHook, path, function(context, pressed)
        local okGet, value = pcall(function() return pressed:get() end)
        if okGet and type(value) == "boolean" then held[b.key] = value or nil end
        -- A replayed real Space has just run Jump: now the frame's stick, as the engine orders them.
        if b.key == "jump" then
            if deferredStick then pcall(sendDeferredStick) else jumpPending = false end
        end
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
    -- Mouse charge steering reads the stored InputAxisRightStickX in the charge's tick (the mouse's X for
    -- the frame; docs/findings/charge-turn-camera.md). The engine's own right-stick event (0: nobody is
    -- moving the mouse) overwrote what input.apply stored, so a mouse-steered charge went straight in the
    -- replay (LS213_20261119_145931: recorded yaw 24.5 -> 55.9 deg in 0.2 s, replay stayed at 24.45;
    -- 2026-11-19). Restored after that event like the left stick.
    InputAxisRightStickX = "/CharacterCommon/Components/CharacterInputComponent/CharacterInputComponent_Spyro.CharacterInputComponent_Spyro_C:InputAxis_RightStick_X",
}
local injectAxes = nil       -- { InputAxisLeftStickX/Y = n, InputAxisRightStickX = n } while a replay drives; nil otherwise
local LEFT_STICK = { leftX = true, leftY = true } -- input.apply leaves these to input.sendLeftStick
-- The RAW value the engine passed to each stick event this frame, which is what the walking (AddMovementInput)
-- uses. It is NOT the stored InputAxisLeftStickX/Y: for keyboard input the Blueprint stores a smoothed ramp
-- (-0.14, -0.46, -0.78, -1.0) while the movement already runs on the full key value. A take recorded from the
-- stored values replays the opening of every walk with the wrong heading (LS102_20261115_160013: 7 deg at 1 s).
local rawAxes = {}
-- Every call of each stick event since the last trace row, values in call order. The engine fires the
-- events once per input tick with the hardware value, and input.apply fires them again with the
-- replay's value, so a replayed frame sees more calls than a recorded one -- and the replayed pawn's
-- consumed input ran 3.0 against the recording's 2.0 at full stick (2026-11-16). This column is the
-- measurement of what the Blueprint body was fed; written to the trace as `evt`.
local eventCalls = { InputAxisLeftStickX = {}, InputAxisLeftStickY = {} }
-- Every Pawn:AddMovementInput call since the last trace row, as "dirX|dirY|scale" strings. This is the
-- movement's real input (the recording and the replay can differ here even when the stick values match:
-- 2026-11-15 the replay's pawn input vector was longer by a constant 0.798 and the recording turned to a
-- diagonal on a stick of (-0.07, 1.0)). Written to the trace's `ami` column.
local amiCalls = {}
local amiHooked = false
local amiTriedAt = nil
local amiTries = 0
-- Candidate paths: the function this build's StaticFindObject answers to is unknown (the bare path
-- found nothing, silently, for a whole session), so try each spelling and say what happened.
local AMI_PATHS = {
    "/Script/Engine.Pawn:AddMovementInput",
    "Function /Script/Engine.Pawn:AddMovementInput",
    "/Script/Engine.Default__Pawn:AddMovementInput",
}
local function registerAmiHook()
    if amiHooked then return end
    if amiTriedAt and os.clock() - amiTriedAt < 2.0 then return end
    amiTriedAt = os.clock()
    amiTries = amiTries + 1
    for _, path in ipairs(AMI_PATHS) do
        local fn = StaticFindObject(path)
        if fn and fn:IsValid() then
            local ok, err = pcall(RegisterHook, path, function(context, dir, scale)
                local okd, d = pcall(function() return dir:get() end)
                local oks, sc = pcall(function() return scale:get() end)
                if okd and type(d) == "table" and #amiCalls < 12 then
                    amiCalls[#amiCalls + 1] = string.format("%.2f|%.2f|%.3f", d.X or 0, d.Y or 0, oks and sc or 0)
                end
            end)
            if ok then
                amiHooked = true
                log("replay: AddMovementInput hook registered via %s", path)
            else
                log("replay: AddMovementInput hook failed on %s: %s", path, tostring(err))
                amiHooked = true -- do not retry a failing RegisterHook forever
            end
            return
        end
    end
    if amiTries == 5 then
        log("replay: AddMovementInput not found under any path (%d tries); the ami column stays empty", amiTries)
    end
end

local injectHooked = {}      -- property name -> true once its hook is registered
local injectTriedAt = nil    -- os.clock() of the last registration sweep that left one unhooked

local function registerInjectHooks()
    registerAmiHook()
    local missing = false
    for prop in pairs(INJECT_FUNCS) do if not injectHooked[prop] then missing = true end end
    if not missing then return end
    if injectTriedAt and os.clock() - injectTriedAt < 1.0 then return end
    injectTriedAt = os.clock()
    for prop, path in pairs(INJECT_FUNCS) do
        if not injectHooked[prop] then
            local fn = StaticFindObject(path)
            if fn and fn:IsValid() then
                local ok, err = pcall(RegisterHook, path, function(context, value)
                    local okv, raw = pcall(function() return value:get() end)
                    if okv and type(raw) == "number" then
                        rawAxes[prop] = raw
                        local calls = eventCalls[prop]
                        if calls and #calls < 12 then calls[#calls + 1] = string.format("%.3f", raw) end
                    end
                    -- Restore BOTH stored axes, and only after the Y event: the engine fires X then Y, so
                    -- its zero-valued X and Y bodies (and sendLeftStick's calls) run on stored (0, 0) and
                    -- RequestGroundMovement adds nothing, while everything after the input tick -- the
                    -- charge above all -- reads the take's stick. Restoring each axis after its own event
                    -- left X set when the Y body ran, which added |(x, 0)| more input every frame.
                    if not injectAxes then return end
                    if prop == "InputAxisRightStickX" then
                        local okc, comp = pcall(function() return context:get() end)
                        if okc and comp and comp:IsValid() then
                            pcall(function() comp.InputAxisRightStickX = injectAxes.InputAxisRightStickX or 0 end)
                        end
                        return
                    end
                    if prop ~= "InputAxisLeftStickY" then return end
                    local okc, comp = pcall(function() return context:get() end)
                    if okc and comp and comp:IsValid() then
                        pcall(function()
                            comp.InputAxisLeftStickX = injectAxes.InputAxisLeftStickX or 0
                            comp.InputAxisLeftStickY = injectAxes.InputAxisLeftStickY or 0
                        end)
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

-- acc / last / pend: the lengths of what the movement actually consumed -- the character movement
-- component's current acceleration (units/s^2, 1000 at full input from rest), the pawn's last movement input
-- vector and the one pending at sample time (0..1). Recording and replay write them the same way, so a frame
-- where the same stick gives a different speed shows which of them differs (2026-11-15: an analog stick gave
-- +27 speed on the first frame of a replay against the recording's +18).
local TRACE_HEADER = "t,dt,x,y,z,yaw,vx,vy,vz,speed,mode,custom_mode,charging,pressed_jump,montage,montage_pos,cam_yaw,acc,last,pend,ami,evt\n"

local function vectorLength(call)
    local ok, v = pcall(call)
    if not (ok and type(v) == "table" or ok and v ~= nil) then return -1 end
    local okLen, len = pcall(function() return math.sqrt((v.X or 0) ^ 2 + (v.Y or 0) ^ 2 + (v.Z or 0) ^ 2) end)
    return okLen and len or -1
end

local function inputDiagnostics(pawn)
    local cmc = nil
    pcall(function() cmc = pawn.CharacterMovement end)
    local acc = cmc and vectorLength(function() return cmc:GetCurrentAcceleration() end) or -1
    local last = vectorLength(function() return pawn:GetLastMovementInputVector() end)
    local pend = vectorLength(function() return pawn:GetPendingMovementInputVector() end)
    return acc, last, pend
end

local function writeTraceRow(file, t, r, pawn, origin)
    local s = anim.state(pawn)
    local acc, last, pend = inputDiagnostics(pawn)
    local ami = table.concat(amiCalls, ";")
    amiCalls = {}
    local evt = string.format("x:%s;y:%s",
        table.concat(eventCalls.InputAxisLeftStickX, "/"), table.concat(eventCalls.InputAxisLeftStickY, "/"))
    eventCalls.InputAxisLeftStickX, eventCalls.InputAxisLeftStickY = {}, {}
    file:write(string.format("%.5f,%.5f,%.3f,%.3f,%.3f,%.2f,%.3f,%.3f,%.3f,%.2f,%d,%d,%s,%s,%s,%.4f,%.3f,%.2f,%.4f,%.4f,%s,%s\n",
        t, num(r.dt), num(r.x) - origin.x, num(r.y) - origin.y, num(r.z), num(r.yaw),
        num(r.vx), num(r.vy), num(r.vz), num(r.speed), num(r.mode), num(r.customMode),
        tostring(r.charging), tostring(r.pressedJump), s.montage, s.position, num(r.camYaw),
        acc, last, pend, ami, evt))
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
    inputs:write("t,lx,ly,rx,ry,tl,tr," .. table.concat(BUTTON_ORDER, ",") .. ",rlx,rly,cpitch,cyaw\n")
    ref:write(TRACE_HEADER)
    rec = {
        id = id, level = level, origin = { x = origin.X, y = origin.Y },
        inputs = inputs, ref = ref, start = r.time, frames = 0,
    }
    -- Every other character while the take is played, so each replay can be compared against what they
    -- really did (tools/Compare-ReplayActors.ps1 takes this as its reference).
    if config.REPLAY_ACTORS then
        rec.actors = actortrace.open(string.format("%s\\replay_%s_ref_actors.csv", paths.modDir, id), rec.origin, pawn)
    end
    log("replay: RECORDING %s (stop with Home). Play the level; avoid dying.", id)
end

local function stopRecord(reason)
    local r = rec
    rec = nil
    if not r then return end
    r.inputs:close()
    r.ref:close()
    actortrace.close(r.actors)
    local index = io.open(INDEX, "a")
    if index then
        index:write(string.format("%s %s\n", r.level, r.id))
        index:close()
    end
    log("replay: take %s saved, %d frames, %.1f s (%s)", r.id, r.frames, r.lastT or 0, reason)
    lastSaved = { id = r.id, frames = r.frames, seconds = r.lastT or 0 }
end

local function updateRecord(pawn, pc, r)
    registerHooks(pawn, pc)
    local axes = readAxes(pawn, pc)
    if not axes then return end -- no component this frame; the gap stays out of the file
    if chargeFallback then held.charge = r.charging or nil end
    -- NOT r.time - rec.start: r.time is a float32 world clock, and hours into a session its ULP is
    -- 1/1024 s, so every 1/30 step records as 34/1024 = 33.20 ms. That ran 0.4%% slow, half a frame
    -- every ~4 s, and the mid-frame row selection then fired late rows one frame early (take
    -- LS102_20261116_094803: presses at #33/#93 exact, #139/#170 one frame early). Accumulate the
    -- engine's own dt instead, in a Lua double, exactly as the replay accumulates its elapsed.
    rec.t = rec.frames == 0 and 0 or rec.t + r.dt
    local t = rec.t
    local flags = {}
    for i, key in ipairs(BUTTON_ORDER) do flags[i] = held[key] and "1" or "0" end
    -- Axes at full float32 precision (%.9g round-trips a float exactly): an analog value written to 4
    -- places (0.12156862 -> 0.1216) replayed a different stick, 0.2432 of movement input against the
    -- recording's 0.2431, and the charge steers by the stored stick, so a gamepad take drifted a float
    -- step at a time (LS102_20261116_230304: one float32 step at f64, 3.3 units by 21 s; 2026-11-16).
    rec.inputs:write(string.format("%.5f,%.9g,%.9g,%.9g,%.9g,%.9g,%.9g,%s,%.9g,%.9g,%.5f,%.5f\n",
        t, num(axes.lx), num(axes.ly), num(axes.rx), num(axes.ry), num(axes.tl), num(axes.tr),
        table.concat(flags, ","),
        num(rawAxes.InputAxisLeftStickX or axes.lx), num(rawAxes.InputAxisLeftStickY or axes.ly),
        num(r.camPitch), num(r.camYaw)))
    writeTraceRow(rec.ref, t, r, pawn, rec.origin)
    actortrace.sample(rec.actors, t)
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
            -- Takes recorded before 2026-11-15 have no raw columns; they replay from the stored values.
            row.rlx, row.rly = tonumber(fields[8 + #BUTTON_ORDER]), tonumber(fields[9 + #BUTTON_ORDER])
            -- Camera rotation that frame (2026-11-16 format). Older takes have none: the game's own
            -- camera runs free, and mouse look in the recording is lost (confirmed by a camera-only take).
            row.cpitch, row.cyaw = tonumber(fields[10 + #BUTTON_ORDER]), tonumber(fields[11 + #BUTTON_ORDER])
            if row.t then take.rows[#take.rows + 1] = row end
        end
    end
    file:close()
    -- Takes recorded before 2026-11-16 carry the float32-clock timestamps described in updateRecord
    -- (0.4%% slow after hours of uptime). Rows are one per frame at the take's cap, so rebuild the
    -- times from the frame count: each recorded gap, rounded to whole frames, says how many frames
    -- passed (1 normally; more when a frame was dropped). Harmless for clean takes, and it undoes
    -- the drift exactly.
    if take.cap and take.cap > 0 and #take.rows > 1 then
        local frame = 0
        local prevRecorded = take.rows[1].t
        take.rows[1].t = 0
        for i = 2, #take.rows do
            local gap = take.rows[i].t - prevRecorded
            prevRecorded = take.rows[i].t
            frame = frame + math.max(1, math.floor(gap * take.cap + 0.5))
            take.rows[i].t = frame / take.cap
        end
    end
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
    if s.spaceDown then realkeys.up(realkeys.SPACE) end -- never leave the player's Space held
    deferredStick, jumpPending = nil, false
    if s.file then s.file:close() end
    actortrace.close(s.actors)
    local summary = { id = s.take.id, cap = s.cap, reason = reason, path = s.path,
                      elapsed = s.elapsed or 0, length = s.take.rows[#s.take.rows].t, resetOnly = s.resetOnly }
    for _, listener in ipairs(finishListeners) do
        local okListener, listenerErr = pcall(listener, summary)
        if not okListener then log("replay: finish listener failed: %s", tostring(listenerErr)) end
    end
    if s.resetOnly then
        log("replay: level reset, Spyro is on the start of %s (%s)", s.take.id, reason)
        return
    end
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
    -- Jump goes out as a real Space (the "play" phase); the settle waits for the key helper. Started
    -- before the trace is opened: the helper inherits every file the game has open when it starts and
    -- keeps it until the game exits, which left the run's CSV locked against readers (2026-11-19).
    realkeys.start()
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
        -- Who was alive at the take's start, and where (lib/actorstart.lua); nil for older takes.
        start = config.REPLAY_ACTOR_START and actorstart.read(take.id) or nil,
    }
    setFpsCap(cap)
    log("replay: camera: %s", take.rows[1] and take.rows[1].cyaw
        and "driving the recorded camera" or "old take, no camera data; the game's camera runs free")
    log("replay: replaying %s at %d FPS (%d input rows, %.1f s); End aborts", id, cap,
        #take.rows, take.rows[#take.rows].t)
    if not quicksave.reloadLevel(pawn, function()
        -- The reloaded NPC dialogue selectors missed the level's player-ready event (lib/playerready.lua).
        if config.REPLAY_PLAYER_READY then playerready.notifyAndLog(level) end
        -- Enemies dead when the take started stay dead (lib/actorstart.lua).
        if run and run.start then actorstart.removeAndLog(run.start, pawn, level) end
        if run and run.phase == "reload" then run.phase = "place" end
    end) then
        log("replay: no sublevels to reload; replaying against the level as it stands")
        run.phase = "place"
    end
end

-- PgUp: put the level back as a fresh entry has it and Spyro on the selected take's start, ready to
-- record or replay. It is a replay run that never reaches "play" (resetOnly): the same reload, place and
-- settle, with no trace file and no cap change.
local function startReset(pawn, pc, r)
    if rec then
        log("replay: can't reset while recording (Home stops the recording)")
        return
    end
    local level = levels.current(pawn)
    if not level then
        log("replay: the level name is unavailable")
        return
    end
    local id = nil
    if selected and selected.level == level then
        for _, take in ipairs(takesFor(level)) do
            if take.id == selected.id then id = selected.id break end
        end
    end
    id = id or newestTake(level)
    if not id then
        log("replay: no take recorded for %s, so there is no start to reset to (Home records one)", level)
        return
    end
    local take = loadTake(id)
    if not take then return end
    local _, origin = levels.current(pawn)
    origin = origin or { X = 0, Y = 0 }
    run = {
        take = take, cap = require("lib.state").fpsCap or take.cap or 30, resetOnly = true,
        origin = { x = origin.X, y = origin.Y },
        phase = "reload", next = 1, elapsed = 0, settled = 0, progressAt = PROGRESS_EVERY,
        start = config.REPLAY_ACTOR_START and actorstart.read(take.id) or nil,
    }
    log("replay: resetting %s to the start of %s", level, id)
    if not quicksave.reloadLevel(pawn, function()
        if config.REPLAY_PLAYER_READY then playerready.notifyAndLog(level) end
        if run and run.start then actorstart.removeAndLog(run.start, pawn, level) end
        if run and run.phase == "reload" then run.phase = "place" end
    end) then
        log("replay: no sublevels to reload; only moving Spyro to the start")
        run.phase = "place"
    end
end

local function setControlRotation(pc, take)
    pcall(function() pc:SetControlRotation({ Pitch = take.ctrlPitch, Yaw = take.ctrlYaw, Roll = 0 }) end)
end

-- SetControlRotation alone does not move the follow camera's own yaw (the camera drives the heading the
-- stick is relative to, and PlayerCameraManager's rotation, the recorded cam_yaw, follows it), so set that
-- directly. Which setter takes what is not documented: try each, log what it did and where the camera ended
-- up, and stop at the first that lands within half a degree of the recorded heading.
local function cameraYawNow(pawn)
    local ok, yaw = pcall(function() return pawn.FollowCamera:GetCameraYaw() end)
    return ok and type(yaw) == "number" and yaw or nil
end

local function setCameraHeading(pawn, take)
    local cam, camErr = nil, nil
    local okCam, got = pcall(function() return pawn.FollowCamera end)
    if okCam then cam = got else camErr = got end
    if not (cam and cam:IsValid()) then
        log("replay: no FollowCamera on the pawn (%s); the recorded camera heading was not restored", tostring(camErr or got))
        return
    end
    local tries = {
        { "SetCameraPitchYaw", function() cam:SetCameraPitchYaw(take.ctrlPitch, take.ctrlYaw) end },
        { "SetCameraYaw",      function() cam:SetCameraYaw(take.ctrlYaw) end },
    }
    local before = cameraYawNow(pawn)
    for _, try in ipairs(tries) do
        local ok, err = pcall(try[2])
        local now = cameraYawNow(pawn)
        log("replay: camera %s(%.2f) -> %s; GetCameraYaw %s -> %s (want %.2f)", try[1], take.ctrlYaw,
            ok and "ok" or tostring(err), tostring(before), tostring(now), take.ctrlYaw)
        if ok and now and math.abs((now - take.ctrlYaw + 180) % 360 - 180) < 0.5 then return end
    end
end

-- Replaying the camera. Mouse look never reaches the axes a take records (the charge-steering stored
-- value is a separate path), so a recorded camera move was simply absent from the replay -- a camera-only
-- take replayed with the camera frozen (2026-11-16). Takes now carry the PlayerCameraManager rotation per
-- frame, and the replay sets the follow camera AND the control rotation (the heading the left stick is
-- relative to) to it on the same frame the row's sticks go out. The cost: a camera-driven replay no longer
-- exercises the game's own camera behaviour, so camera-centering fixes still need takes judged by eye.
local driveCameraFailed = false
local lastCamYaw = nil -- the yaw driveCamera last set, to tell whether the game moved the camera since
local function driveCamera(pawn, pc, row)
    if not (row and row.cyaw) then return end
    local ok = pcall(function()
        pawn.FollowCamera:SetCameraPitchYaw(row.cpitch or 0, row.cyaw)
        pc:SetControlRotation({ Pitch = row.cpitch or 0, Yaw = row.cyaw, Roll = 0 })
    end)
    if ok then lastCamYaw = row.cyaw end
    if not ok and not driveCameraFailed then
        driveCameraFailed = true
        log("replay: driving the recorded camera failed; the game's own camera runs this replay")
    end
end

-- Did the game turn the camera itself during the frame that just ended? After an outside
-- SetCameraPitchYaw the walking camera stays put (its auto-rotation does not run), but a charge's native
-- centering (FollowCameraComponent, docs/findings/charge-turn-camera.md) still steps it every frame.
local function gameTurnedCamera(pawn)
    if not lastCamYaw then return false end
    local ok, yaw = pcall(function() return pawn.FollowCamera:GetCameraYaw() end)
    if not (ok and type(yaw) == "number") then return false end
    return math.abs((yaw - lastCamYaw + 180) % 360 - 180) > 0.01
end

local function place(pawn, pc, cmc)
    local s = run
    local x = s.take.sx + s.origin.x
    local y = s.take.sy + s.origin.y
    pawn:K2_TeleportTo({ X = x, Y = y, Z = s.take.sz },
        { Pitch = s.take.pitch, Yaw = s.take.yaw, Roll = s.take.roll })
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }
    lastCamYaw = nil -- a new run: nothing set yet, so the first frame does not count as the game turning it
    -- The camera first, THEN the control rotation. ResetBehind(true) snaps the camera (and with it the
    -- control rotation the left stick is relative to) to straight behind Spyro, so calling it after
    -- SetControlRotation threw the recorded camera heading away: a take recorded with the camera 2.7 deg
    -- off his facing replayed with it at 0, and every walk went 2.7 deg the wrong way (38 units after 4 s
    -- of walking forward; 2026-11-15, LS102_20261115_161245). The take header's ctrl yaw is the camera
    -- heading at the moment Home was pressed.
    if not pcall(function() pawn.FollowCamera:ResetBehind(true) end) then
        pcall(function() pawn.FollowCamera:SetCameraYaw(s.take.ctrlYaw) end)
    end
    setControlRotation(pc, s.take)
    setCameraHeading(pawn, s.take)
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
        setControlRotation(pc, s.take) -- hold the recorded camera heading until play starts
        local dx, dy = r.x - (s.take.sx + s.origin.x), r.y - (s.take.sy + s.origin.y)
        local off = math.sqrt(dx * dx + dy * dy)
        if off > PLACE_TOLERANCE and s.settled < SETTLE_MAX then
            -- The teleport does not always take on the first try (seen on 9% of tour stops), and a replay
            -- that starts off the spot is shifted for its whole length (LS102_20261116_122108 started
            -- 156 units away after a run that ended across the level, and was accepted while this
            -- allowed 300; 2026-11-16).
            place(pawn, pc, cmc)
            return
        end
        if r.mode == 3 and s.settled < SETTLE_MAX then return end -- let him land first
        if s.settled >= SETTLE_MAX and (off > PLACE_TOLERANCE or r.mode == 3) then
            finishRun(pawn, pc, "aborted: never settled on the start spot")
            return
        end
        if s.settled < SETTLE then return end
        if s.resetOnly then
            actorstart.placeAndLog(s.start, s.origin, pawn) -- every character where the take started it
            finishRun(pawn, pc, "done")
            return
        end
        -- A real Space needs the key helper, and the Jump hook that sends the stick held back for it.
        local realReady = realkeys.ready() and hooked.jump == true
        if not realReady and s.settled < SETTLE_MAX then return end
        s.realJump = realReady
        s.phase, s.elapsed = "play", 0
        -- Every character where the take started it, now that the take starts: during the settle they
        -- would have wandered off again (lib/actorstart.lua).
        actorstart.placeAndLog(s.start, s.origin, pawn)
        if config.REPLAY_ACTORS and s.path then
            local actorsPath = s.path:gsub("%.csv$", "_actors.csv") -- one value: gsub also returns a count
            s.actors = actortrace.open(actorsPath, s.origin, pawn)
        end
        log("replay: playing (Jump as %s)", s.realJump and "a real Space key"
            or "an injected input event: the key helper or the Jump hook never got ready, so a conversation will not close")
        return
    end
    -- "play"
    -- Only the take's own inputs go in: nothing here looks for text boxes or cutscenes. The take's Jump
    -- goes out as a real Space key (lib/realkeys.lua), the way the player pressed it, so a press the
    -- recording made into a conversation's text box (Space is Jump and UI_Confirm) reaches the box the
    -- same way. Injected through the input component, as the other buttons are, it never reached a box,
    -- and calling the box's own press function from Lua froze the game (docs/probe.md, 2026-11-18).
    local health = invuln.health(pawn)
    if health and health <= 0 then
        finishRun(pawn, pc, "DIED -- a death that the recording did not have is a finding")
        return
    end
    local rows = s.take.rows
    -- The row of the frame that just ended (sent at the end of the frame before it): its camera is the
    -- one the recording had when the NEXT frame began.
    local endedRow = s.sent and rows[s.sent] or nil
    -- Which recorded row to send now. A recorded row (t, axes) was read at the END of the frame that
    -- ended at t, so it is the input that frame's movement already used. What is sent here, at the end
    -- of a frame, is used by the NEXT frame -- so sending "the row at or before elapsed" (as this did
    -- until 2026-11-15) put every input one frame late, and its `<=` against a t rounded to 5 places
    -- made about half the rows a second frame late (0.06667 <= 0.066666 is false). The row to send is
    -- the one whose recorded frame covers the middle of the frame about to run: the first row with
    -- t >= elapsed + dt/2. At the take's own cap that is exactly the next row, with half a frame of
    -- margin against rounding; at another cap it is the recorded input in effect at that frame's middle.
    local mid = s.elapsed + r.dt * 0.5
    while s.next < #rows and rows[s.next].t < mid do
        -- (Rows passed over are not applied: at a cap above the take's, a press shorter than one
        -- replayed frame is lost. At the take's own cap nothing is passed over.)
        s.next = s.next + 1
    end
    if s.next <= #rows and s.next ~= s.sent then
        local row = rows[s.next]
        -- The left stick goes out the way the engine's input tick sends it (input.sendLeftStick): the
        -- frame then consumes |(x_k, y_(k-1))| + |(x_k, y_k)| like the recording, at any stick tilt. This
        -- replaces the "half-frame filter" (2026-11-16), which averaged Y with the last row: right for
        -- keys on Y alone, but it left the consumed input at X 1.0 / Y 3.0 against the recording's 2.0,
        -- which a partly tilted analog stick would feel. Charging or not: a stick event adds nothing
        -- during a charge, and the charge reads the stored stick, which the hook restores (below).
        s.stickX, s.stickY = row.rlx or row.lx, row.rly or row.ly
        input.hold({ rightX = row.rx, rightY = row.ry, triggerL = row.tl, triggerR = row.tr })
        s.curLx, s.curLy, s.curRx = row.lx, row.ly, row.rx
        for _, key in ipairs(BUTTON_ORDER) do
            if not (key == "jump" and s.realJump) and row[key] ~= input.held(key) then
                if row[key] then input.press(key) else input.release(key) end
            end
        end
        s.sent = s.next
    end
    -- Jump as a real Space key goes out one replayed frame ahead: from the row the NEXT frame will send.
    -- A posted key goes through the message pump and the player input and acts a frame after the
    -- injected event (which runs between frames): sent from the current row, all three take-offs of
    -- LS102_20261116_233040 at 30->30 came 0.033 s late, with every frame before the first jump exact
    -- (2026-11-19).
    local spaceChanges = false
    if s.realJump then
        local ahead, midNext = s.next, s.elapsed + r.dt * 1.5
        while ahead < #rows and rows[ahead].t < midNext do ahead = ahead + 1 end
        local want = rows[ahead] and rows[ahead].jump == true
        if want ~= (s.spaceDown == true) then
            s.spaceDown = want
            if want then realkeys.down(realkeys.SPACE) else realkeys.up(realkeys.SPACE) end
        end
        if want ~= (s.spaceWas == true) then
            s.spaceWas = want
            jumpPending, s.holdFrom, s.holdTicks = true, s.elapsed + r.dt * 0.5, JUMP_WAIT_TICKS
        end
    end
    -- A stick held back for a Jump that did not run in its frame (the key went to a text box, which takes
    -- Space as Continue): that frame is over, so the stick is dropped rather than added to the next one.
    if deferredStick then
        deferredStick = nil
        if not s.lateStickNoted then
            s.lateStickNoted = true
            log("replay: a Space press did not run Jump in time (a text box took it?); a frame's stick was dropped")
        end
    end
    -- Hold this tick's stick back for the Jump if the Space change is still on its way: from the tick
    -- after the one that sent it (a key sent at the end of frame N ran Jump in frame N+2 at 30 FPS), for
    -- at most JUMP_WAIT_TICKS ticks.
    if jumpPending and s.holdTicks and s.elapsed > s.holdFrom then
        spaceChanges = true
        s.holdTicks = s.holdTicks - 1
        if s.holdTicks <= 0 then jumpPending = false end
    end
    -- The stored stick (InputAxisLeftStickX/Y) as the recording had it after this frame's input tick,
    -- restored by the stick hook after the engine's Y event (registerInjectHooks). The charge steers by
    -- it, and anything else that reads it in the tick sees the take's value. It used to be forced only
    -- while charging, so on the FIRST frame of a charge the stick read 0 and the turn started a frame
    -- late (LS102_20261116_230304, a gamepad take: f34 yaw -11.21 against the recording's -8.46, the
    -- replay a frame behind from there and the camera fighting it, 2026-11-16).
    injectAxes = { InputAxisLeftStickX = s.curLx or 0, InputAxisLeftStickY = s.curLy or 0,
                   InputAxisRightStickX = s.curRx or 0 }
    -- The camera, in two steps around the sticks.
    -- 1. The camera of the frame that just ended: the one the recording had when the next frame began,
    --    which the sticks are turned by (input runs before the camera updates). Setting the NEXT frame's
    --    camera before the sticks turned every stick by it (LS102_20261116_122108: vy 0.017 vs 0.000 on
    --    the first walking frame).
    -- 2. Then, unless the game is turning the camera itself, the next frame's camera. After an outside
    --    set the walking camera stays put, so without this it lags the recording a frame (2.7 deg a
    --    frame while it auto-rotates). A charge's native centering does step it, from wherever it is,
    --    so there step 2 would count that step twice (+4.7 deg on the first charge frame of
    --    LS102_20261116_230304, and the charge steers by the control rotation, so Spyro's yaw drifted);
    --    left at the ended frame's camera, the centering steps from the recording's own state and
    --    lands on its next value. Whether the game turned it is measured on the frame that just ended;
    --    a charge press counts from its first frame, which nothing has measured yet.
    local gameTurns = gameTurnedCamera(pawn)
    driveCamera(pawn, pc, endedRow)
    input.apply(pawn, pc, LEFT_STICK)
    if spaceChanges then
        -- The engine runs a frame's action events (Jump) before its axis events. Sent from here, the stick
        -- would come before the real Space's Jump: the take-off frame of LS102_20261116_233040 then
        -- consumed 2.0265 of movement input (the ground's two vectors) against the recording's 1.0133 (the
        -- air's one), turning Spyro 5.8 deg and drifting the run 5 units (2026-11-19). The Jump hook sends
        -- it instead, straight after Jump, as the engine orders them (sendDeferredStick).
        deferredStick = { pawn = pawn, pc = pc, x = s.stickX or 0, y = s.stickY or 0, prevY = s.prevStickY or 0 }
    else
        input.sendLeftStick(pawn, pc, s.stickX or 0, s.stickY or 0, s.prevStickY or 0)
    end
    -- The Y the engine's stored axis held when the next frame's X event runs (sendLeftStick's prevY).
    s.prevStickY = s.stickY or 0
    local nextRow = s.sent and rows[s.sent] or nil
    local chargePress = nextRow and nextRow.charge and not (endedRow and endedRow.charge)
    if not gameTurns and not chargePress then driveCamera(pawn, pc, nextRow) end
    writeTraceRow(s.file, s.elapsed, r, pawn, s.origin)
    actortrace.sample(s.actors, s.elapsed) -- every other character (config REPLAY_ACTORS)
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
function replay.requestReset() pending = "reset" end

-- Play one take by id (or the newest for this level when id is nil), without the picker: what End does
-- with the picker open, for lib/cmd.lua. Handled on the next sampled frame, in the game thread.
function replay.requestPlay(id)
    pending, pendingId = "play", id
end

-- True while a replay is driving (or waiting out a reload): main.lua answers paused prompts for it.
function replay.running()
    return run ~= nil
end

-- True while a take is being recorded.
function replay.recording()
    return rec ~= nil
end

-- The take the last recording saved ({ id, frames, seconds }), or nil.
function replay.lastSaved()
    return lastSaved
end

-- Every take recorded for a level, newest first: { { id, when }, ... }.
function replay.takes(level)
    return takesFor(level)
end

-- fn(summary) when a run or a level reset ends; summary = { id, cap, reason, path, elapsed, length,
-- resetOnly }. reason is "completed", "aborted with End", "aborted by a reset", ...
function replay.onFinish(fn)
    finishListeners[#finishListeners + 1] = fn
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
        elseif kind == "reset" then
            if run then finishRun(pawn, pc, "aborted by a reset") end
            menuOpen = false
            startReset(pawn, pc, r)
        elseif kind == "play" then
            local id = pendingId
            pendingId = nil
            if run then finishRun(pawn, pc, "aborted by a new replay") end
            menuOpen = false
            local level = levels.current(pawn)
            -- startReplay falls back to the newest take when the selection is not in the index, which
            -- is right for the picker and wrong for a take asked for by name, so check it here.
            local known = id == nil
            for _, take in ipairs(level and takesFor(level) or {}) do
                if take.id == id then known = true end
            end
            if known then
                selected = id and { level = level, id = id } or nil
                startReplay(pawn, pc, r, setFpsCap)
            else
                log("replay: %s is not a take for %s in replay_takes.txt; not replaying it", id, tostring(level))
                for _, listener in ipairs(finishListeners) do
                    pcall(listener, { id = id, reason = "unknown take", failed = true })
                end
            end
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
        if run then
            registerHooks(pawn, pc) -- the Jump hook sends a stick held back for a real Space (updateReplay)
            updateReplay(pawn, pc, cmc, r)
        end
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
