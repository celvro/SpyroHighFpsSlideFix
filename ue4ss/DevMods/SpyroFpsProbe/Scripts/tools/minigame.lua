-- Recording a minigame by hand.
--
-- The scripted tour cannot play a minigame. It teleports in front of a character and walks into them,
-- which starts the ones that hand a character over (Sheila, Sgt Byrd, Bentley, Agent 9) but does nothing
-- at all for the ones you board -- the Spyro 2 trolley, the shark and its boat -- and even where it does
-- get in, forward-and-jump is not playing a minigame in any sense that would show a bug up.
--
-- So this does the part a program is good at and leaves the rest alone: it travels to the level, puts
-- Spyro on the recorded spot, walks him into whoever starts it, and then LETS GO. From there it is your
-- controller. Press M and it records everything, the same way the tour samples a stop and into the same
-- CSV shape, so tools/Compare-Anims.ps1 reads a hand-played take at 30 and at 320 exactly as it reads
-- the tour's stops.
--
--   M   start or stop recording (a take)
--   F1  mark this moment: something went wrong just now
--   F2  retry -- put me back at the start of this minigame
--   C   drop into the next minigame on the list
--
-- Every drop-in and every retry tops the purse up, so Moneybags is never the reason a take cannot be
-- repeated, and nothing walks Spyro anywhere: he is put on the spot facing the right way and the rest
-- is yours.
--
-- minigame.txt in this mod folder does the same from outside: a level name (LS305), "next", or "list".
--
-- Takes are numbered within a run and every row carries the framerate cap, so playing one minigame at 30
-- and then the same one at 320 gives two takes that line up. A retry is just another take. Marks go to
-- minigame_notes_<stamp>.txt with the take, the time into it, the cap and the montage that was playing,
-- which is enough to say afterwards which moment a glitch was.
--
--   "minigame" lines  which one, who is holding the controller, and every mark
local UEHelpers = require("UEHelpers")
local anim = require("lib.anim")
local igc = require("lib.igc")
local input = require("lib.input")
local levels = require("lib.levels")
local log = require("lib.log")
local paths = require("lib.paths")
local routes = require("tools.routes")
local subworld = require("lib.subworld")
local quicksave = require("tools.quicksave")

local minigame = {}

local TRIGGER = paths.modDir .. "\\minigame.txt"
local CSV = string.format("%s\\minigame_%s.csv", paths.modDir, paths.stamp)
local ANIM_CSV = string.format("%s\\minigame_anims_%s.csv", paths.modDir, paths.stamp)
local NOTES = string.format("%s\\minigame_notes_%s.txt", paths.modDir, paths.stamp)
local HEADER = "cap,level,take,script,note,t,x,y,z,yaw,speed,mode\n"
local ANIM_HEADER = "cap,level,stop,script,note,t,who,class,montage,montagePos,section,rate,rootMotion,"
    .. "state,stateTime,x,y,z,yaw,speed,mode\n"

local SAMPLE = 0.1       -- seconds of game time between rows, as the tour uses
local SETTLE = 1.0   -- standing still after the teleport before you get the controller
local GEMS = 30000   -- topped up on every drop-in, so Moneybags is never what stops a take

-- The characters whose conversation hands the controller over, and the things you board. Everything on
-- this list gets an entry; whether it takes over by itself is worked out at the time.
local ENTRIES = { "Sheila", "SgtByrd", "Bentley", "Agent9", "SharkSub", "PlaneThief", "Trolley" }

local state = nil   -- { list, index, phase, take, ... } while the tool is running
local csv, animCsv = nil, nil
local pending = nil -- a request from a key or the trigger file, handled in the game thread
local ORIGIN = { x = 0, y = 0, z = 0 }
local NO_AXES = {}            -- sticks centred, reused so a driven frame allocates nothing

local function isEntry(note)
    for _, name in ipairs(ENTRIES) do
        if tostring(note):find(name, 1, true) then return true end
    end
    return false
end

-- One entry per (level, character): the route has a walk, a flame and a charge stop at most of them and
-- they are all the same spot.
local function buildList()
    local list, seen = {}, {}
    for index, stop in ipairs(routes.all()) do
        local key = stop.level .. "|" .. stop.note
        if isEntry(stop.note) and not seen[key] then
            seen[key] = true
            list[#list + 1] = { stop = stop, id = index }
        end
    end
    table.sort(list, function(a, b)
        if a.stop.level ~= b.stop.level then return a.stop.level < b.stop.level end
        return a.id < b.id
    end)
    return list
end

local function openCsv(path, header)
    local file = io.open(path, "a")
    if not file then
        log("minigame: could not write %s", path)
        return nil
    end
    if file:seek("end") == 0 then file:write(header) end
    return file
end

local function current()
    return state and state.list and state.list[state.index]
end

-- "0" is what t.MaxFPS calls uncapped, which is not a framerate to compare anything against.
local function capName(cap)
    return (cap and cap > 0) and (cap .. " FPS") or "UNCAPPED (press F5 for 30 or F4 for 320 first)"
end

local function label()
    local entry = current()
    if not entry then return "?", "?" end
    return entry.stop.level, entry.stop.note
end

local function sample(r)
    csv = csv or openCsv(CSV, HEADER)
    if not csv then return end
    local level, note = label()
    csv:write(string.format("%d,%s,%d,minigame,%s,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%d\n",
        state.cap or 0, level, state.take, note:gsub(",", " "), state.recorded,
        r.x - ORIGIN.x, r.y - ORIGIN.y, r.z - ORIGIN.z, r.yaw, r.speed or 0, r.mode))
    state.rows = state.rows + 1
end

local function sampleAnim(pawn)
    if not (pawn and pawn:IsValid()) then return end
    animCsv = animCsv or openCsv(ANIM_CSV, ANIM_HEADER)
    if not animCsv then return end
    local level, note = label()
    local s = anim.state(pawn)
    local class = "?"
    pcall(function() class = pawn:GetClass():GetFName():ToString() end)
    local loc = pawn:K2_GetActorLocation()
    local yaw, speed, mode = 0, 0, 0
    pcall(function() yaw = pawn:K2_GetActorRotation().Yaw end)
    pcall(function()
        local cmc = pawn.CharacterMovement
        local v = cmc.Velocity
        speed = math.sqrt(v.X * v.X + v.Y * v.Y)
        mode = cmc.MovementMode
    end)
    animCsv:write(string.format(
        "%d,%s,%d,minigame,%s,%.3f,player,%s,%s,%.4f,%s,%.3f,%s,%s,%.3f,%.2f,%.2f,%.2f,%.2f,%.2f,%d\n",
        state.cap or 0, level, state.take, note:gsub(",", " "), state.recorded, class, s.montage,
        s.position, s.section, s.rate, tostring(s.rootMotion), s.enemyState, s.enemyStateTime,
        loc.X - ORIGIN.x, loc.Y - ORIGIN.y, loc.Z - ORIGIN.z, yaw, speed, mode))
end

local function flush()
    if csv then csv:flush() end
    if animCsv then animCsv:flush() end
end

-- Puts him on the stop, facing the way it was recorded, with the camera behind him.
local function place(pawn, pc, cmc, stop)
    local level, origin = levels.current(pawn)
    if level ~= stop.level or not origin then return false end
    local x, y, z = routes.place(stop, origin)
    pawn:K2_TeleportTo({ X = x, Y = y, Z = z }, { Pitch = 0, Yaw = stop.yaw, Roll = 0 })
    cmc.Velocity = { X = 0, Y = 0, Z = 0 }
    pc:SetControlRotation({ Pitch = stop.ctrlPitch, Yaw = stop.yaw, Roll = 0 })
    pcall(function() pawn.FollowCamera:ResetBehind(true) end)
    ORIGIN.x, ORIGIN.y, ORIGIN.z = x, y, z
    return true
end

local function startEntry(pawn, pc, cmc)
    local entry = current()
    if not entry then
        log("minigame: that was the last one on the list")
        state = nil
        return
    end
    local stop = entry.stop
    if levels.current(pawn) ~= stop.level then
        if not quicksave.travel(pawn, stop.level) then
            log("minigame: cannot travel to %s, skipping it", stop.level)
            state.index = state.index + 1
            return
        end
        state.phase = "travel"
        return
    end
    if not place(pawn, pc, cmc, stop) then
        log("minigame: cannot place %s %s, skipping it", stop.level, stop.note)
        state.index = state.index + 1
        return
    end
    state.phase, state.waited, state.walked, state.stillFor = "settle", 0, 0, 0
    state.character = subworld.character(pawn)
    log("minigame: %s, %s -- putting you on the spot", stop.level, stop.note)
end

-- Hand the controller back and say what to do with it.
-- Moneybags gates half the minigames and the most expensive thing he sells is 1000-odd gems, so top
-- up to well past that on every drop-in and every retry -- paying him should never be the reason a take
-- cannot be repeated. FalconGameState has the developers own switch for it: "debug - add treasure"
-- (count, clear count first); the false keeps what is already in the purse rather than resetting it.
local function giveGems(pc)
    local ok = pcall(function()
        local gs = UEHelpers.GetGameplayStatics():GetGameState(pc)
        gs["debug - add treasure"](gs, GEMS, false)
    end)
    log("minigame: %s", ok and ("added " .. GEMS .. " gems for Moneybags")
        or "could not add gems (debug - add treasure refused)")
end

local function handOver(pawn, pc, why)
    input.clear(pawn, pc)
    giveGems(pc)
    -- Nothing else: the level came in through the game's own load, so the controls, the HUD and any
    -- conversation are the game's. Reaching into them from here is what lost input and hid text boxes.
    igc.forget()
    state.phase = "ready"
    local level, note = label()
    local ignored
    pcall(function() ignored = pawn:IsMoveInputIgnored() end)
    log("minigame: %s, %s -- %s. You have the controller as %s%s.", level, note, why,
        subworld.character(pawn) or "?",
        ignored == true and " -- but the game says input is ignored (a cinematic?)" or "")
    log("minigame: M records a take, F1 marks a glitch, F2 retries this one, C moves on.")
end

function minigame.request(what) pending = what end
function minigame.toggleRecord() pending = "record" end
function minigame.mark() pending = "mark" end
function minigame.retry() pending = "retry" end

function minigame.running() return state ~= nil end
function minigame.recording() return state ~= nil and state.recording == true end

-- What the UI is doing right now. A text box that never appears is either not being created at all (the
-- trigger did not fire) or created and not drawn (its parent is hidden), and those want opposite fixes,
-- so the mark says which. UI_DialogueFrame_C is the text box; UI_Main_C is the HUD it hangs off, and a
-- hidden parent takes every child with it -- which is a real possibility in a subworld, because the
-- minigame's own HUD is exactly what takes UI_Main out of its normal visibility.
-- Rather than guess class names (UI_Main_C and UI_DialogueFrame_C are created by GameHud but neither
-- exists by those names at runtime), walk every UserWidget there is. FindAllOf on the native base
-- returns the Blueprint subclasses too, so this is the whole UI as the game actually built it.
local function uiReport(pc)
    -- Tallied per class, not listed per instance: the UI keeps over a thousand widgets alive and most
    -- are pooled spares that have never been shown. What matters is which classes have an instance that
    -- is actually drawn, and -- for a text box that is missing -- whether a dialogue class exists at all
    -- while none of its instances is visible.
    local widgets = FindAllOf("UserWidget") or {}
    local kinds, order = {}, {}
    for _, widget in ipairs(widgets) do
        local ok = pcall(function() return widget:IsValid() end)
        if ok and widget:IsValid() then
            local class = "?"
            pcall(function() class = widget:GetClass():GetFName():ToString() end)
            if not class:match("^Default__") then
                local k = kinds[class]
                if not k then
                    k = { total = 0, visible = 0, viewport = 0 }
                    kinds[class], order[#order + 1] = k, class
                end
                k.total = k.total + 1
                local visible, inViewport
                pcall(function() visible = widget:IsVisible() end)
                pcall(function() inViewport = widget:IsInViewport() end)
                if visible == true then k.visible = k.visible + 1 end
                if inViewport == true then k.viewport = k.viewport + 1 end
            end
        end
    end
    table.sort(order)
    local drawn, hidden = 0, {}
    for _, class in ipairs(order) do
        local k = kinds[class]
        local talks = class:lower():find("dialog") or class:lower():find("subtitle")
        if k.visible > 0 or k.viewport > 0 then
            drawn = drawn + 1
            log("minigame:   DRAWN %s x%d (visible %d, in viewport %d)", class, k.total, k.visible, k.viewport)
        elseif talks then
            hidden[#hidden + 1] = string.format("%s x%d", class, k.total)
        end
    end
    if #hidden > 0 then
        log("minigame:   dialogue classes present but nothing drawn: %s", table.concat(hidden, ", "))
    end
    log("minigame:   %d class(es) drawn out of %d, %d widgets in all", drawn, #order, #widgets)
    local hud
    pcall(function() hud = pc:GetHUD() end)
    if hud and hud:IsValid() then
        local hudName = "?"
        pcall(function() hudName = hud:GetClass():GetFName():ToString() end)
        log("minigame:   HUD %s", hudName)
    end
end

local function doMark(pawn)
    local level, note = label()
    local s = anim.state(pawn)
    state.marks = (state.marks or 0) + 1
    local line = string.format("mark %d | %s | %s %s | take %d | %s | t=%.2f | %d FPS | %s at %.3f%s\n",
        state.marks, os.date("%Y-%m-%d %H:%M:%S"), level, note, state.take,
        subworld.character(pawn) or "?", state.recorded or 0, state.cap or 0,
        s.montage ~= "" and s.montage or "(no montage)", s.position,
        s.section ~= "" and (" [" .. s.section .. "]") or "")
    local file = io.open(NOTES, "a")
    if file then file:write(line); file:close() end
    log("minigame: MARK %d at t=%.2f of take %d (%s, %s at %.3f)", state.marks, state.recorded or 0,
        state.take, subworld.character(pawn) or "?",
        s.montage ~= "" and s.montage or "no montage", s.position)
    pcall(uiReport, UEHelpers.GetPlayerController())
end

local function handle(pawn, pc, cmc)
    local what = pending
    pending = nil
    if not what then return end

    if what == "list" then
        local list = buildList()
        log("minigame: %d minigames on the list", #list)
        for i, entry in ipairs(list) do
            log("minigame:   %2d %s %s", i, entry.stop.level, entry.stop.note)
        end
        return
    end

    if what == "record" then
        if not state or (state.phase ~= "ready" and state.phase ~= "recording") then
            log("minigame: nothing to record yet -- drop into one first (C, or minigame.txt)")
            return
        end
        if state.recording then
            state.recording, state.phase = false, "ready"
            flush()
            log("minigame: take %d stopped: %.1f s, %d rows, %d mark(s). %s",
                state.take, state.recorded, state.rows, state.marks or 0, CSV)
        else
            state.take = (state.take or 0) + 1
            state.recording, state.recorded, state.rows, state.marks = true, 0, 0, 0
            state.nextSample, state.phase = 0, "recording"
            local level, note = label()
            log("minigame: take %d recording -- %s %s as %s at %s. M again to stop.",
                state.take, level, note, subworld.character(pawn) or "?", capName(state.cap))
        end
        return
    end

    if what == "mark" then
        -- Worth pressing whether or not a take is running: outside one there is no time to write down,
        -- but the picture of what the UI was doing is the half that matters when a text box is missing.
        if minigame.recording() then
            doMark(pawn)
        else
            log("minigame: MARK (no take running) -- what the UI is doing:")
            pcall(uiReport, pc)
        end
        return
    end

    if what == "retry" then
        if not state then
            log("minigame: not in one")
            return
        end
        if state.recording then
            state.recording = false
            flush()
            log("minigame: take %d abandoned", state.take)
        end
        local level, note = label()
        log("minigame: retrying %s %s", level, note)
        startEntry(pawn, pc, cmc)
        return
    end

    if what == "next" then
        if not state then
            state = { list = buildList(), index = 0, take = 0 }
            if #state.list == 0 then
                log("minigame: no minigame entries found in routes.txt")
                state = nil
                return
            end
        end
        if state.recording then state.recording = false; flush() end
        state.index = state.index + 1
        startEntry(pawn, pc, cmc)
        return
    end

    -- Anything else is taken as a level name: start the list there.
    local list = buildList()
    for i, entry in ipairs(list) do
        if entry.stop.level == what then
            state = { list = list, index = i, take = (state and state.take) or 0 }
            startEntry(pawn, pc, cmc)
            return
        end
    end
    log("minigame: nothing recorded in %s (minigame.txt takes a level, \"next\" or \"list\")",
        tostring(what))
end

local function readTrigger()
    local file = io.open(TRIGGER, "r")
    if not file then return nil end
    local line = file:read("l") or ""
    file:close()
    os.remove(TRIGGER)
    line = line:gsub("^\239\187\191", ""):match("^%s*(%S*)")
    return line ~= "" and line or nil
end

function minigame.update(pawn, pc, cmc, r, fpsCap)
    local trigger = readTrigger()
    if trigger then pending = trigger end
    handle(pawn, pc, cmc)
    if not state then return end
    state.cap = fpsCap

    if state.phase == "travel" then
        if quicksave.travelling() then return end
        startEntry(pawn, pc, cmc)
        return
    end

    if state.phase == "settle" then
        state.waited = state.waited + r.dt
        input.hold(NO_AXES)
        input.apply(pawn, pc)
        if state.waited >= SETTLE then
            -- No walking in. Being put on the spot, facing the right way, with the gems to pay for it is
            -- the whole job; walking him forward from there only ever guessed at what starts a minigame,
            -- and guessed wrong for every one you board.
            handOver(pawn, pc, "on the spot")
        end
        return
    end


    if state.phase == "recording" then
        state.recorded = state.recorded + r.dt
        if state.recorded >= state.nextSample then
            sample(r)
            sampleAnim(pawn)
            state.nextSample = state.nextSample + SAMPLE
            if state.rows % 100 == 0 then flush() end
        end
        return
    end
end

return minigame
