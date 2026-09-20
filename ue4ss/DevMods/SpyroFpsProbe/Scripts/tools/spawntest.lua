-- Spawn test (U, or create spawntest.txt in this mod folder, containing "restart" to start over from the first
-- type; it waits until Spyro is in a level): spawns
-- every chase/flee character type (tools/spawnlist.lua) SPAWN_DISTANCE in front of Spyro on his floor, one at a time,
-- uncapped, and watches whether it moves when its state machine asks it to. Patrols are left to the tour.
-- Stand Spyro somewhere open and flat with navmesh (a normal level with walking enemies), facing open ground.
--
-- Each type: load its class, spawn it (deferred spawn, AdjustIfPossibleButAlwaysSpawn), give it an AI
-- controller, watch it for WATCH seconds, destroy it. Before each spawn Spyro is put back where the run
-- started, facing the same way (knockback and respawns move him). Per state it sums the time, the time it wanted to move
-- (input acceleration, or a RequestedVelocity that changed since the last frame, as trackers/stalls.lua)
-- and the part of that with zero horizontal velocity.
--
--   "spawntest" lines    one per type: verdict, then per state: seconds, wanted-to-move seconds, still while
--                        wanting, distance, max speed, first move after the state was entered.
--                        Verdicts: stalled (wanted to move 0.3 s or more and was still for over half of it),
--                        moved, idle (never asked to move: its triggers didn't fire), failed (load or spawn).
--   spawntest_<stamp>.csv  one row per type and state.
--   spawntest_progress.txt  the next type to test. A type is marked "running" while it's out, so after a crash
--                        the next run skips it (logged "crashed last run"). Delete the file to start over.
-- The trigger file can hold options: "restart" to start from the first type, "fps=30" to cap the framerate for a
-- control run, "only=Cowlek,GiantCrab" to test just the types whose class name contains one of those (in list
-- order, ignoring the skip rules and the progress file).
local UEHelpers = require("UEHelpers")
local invuln = require("lib.invuln")
local log = require("lib.log")
local paths = require("lib.paths")
local list = require("tools.spawnlist")
local stalls = require("trackers.stalls")
local idle = require("tools.spawnidle")

local spawntest = {}

local SPAWN_DISTANCE = 250 -- 450 was too far for many chase triggers (2026-09-19 run)
local NUDGE_DISTANCE = 150 -- where a type that hasn't asked to move by NUDGE_AT is moved to
local NUDGE_AT = 4        -- seconds into WATCH
local GROUND_CLEARANCE = 2 -- spawned standing on Spyro's floor: dropped from above, about half hung in the air
local WATCH = 8          -- seconds per type
local GAP = 0.5          -- seconds between types
local STALL_WANT = 0.3   -- seconds of wanting to move before a still state counts as stalled
-- Parked types still cost a little each (the framerate fell from ~330 to 246 over 56 types, 2026-09-19 15:20), and
-- the default-acceleration stall needs ~300 FPS. Below this the run stops between types, keeping its place: a
-- restart clears the parked types and the next run continues.
local MIN_FPS = 260
local TRIGGER = paths.modDir .. "\\spawntest.txt"
local PROGRESS = paths.modDir .. "\\spawntest_progress.txt"
local STOP = paths.modDir .. "\\spawntest.stop" -- an empty file that stops a run that is already going
local CSV = string.format("%s\\spawntest_%s.csv", paths.modDir, paths.stamp)
-- Types that crash the game when spawned out of their setup (the next run skips a crashed type anyway;
-- these save a restart). The skate-race crab aborted the engine on spawn (2026-09-19 13:56).
local SKIP = { BP_CES3056_GiantCrab_SkateRace_Blue_C = "crashed the game (skate race setup)",
               BP_CES3056_GiantCrab_SkateRace_C = "same skate race crab as _Blue, which crashed the game",
               BP_CES3361_HoverCannonRhynoc_C = "crashed the game on spawn twice (access violation, 14:34 and again)" }
-- Egg thieves and bosses only start moving from their own level's setup (chases, arenas, phases): every one
-- was idle in the 2026-09-19 run.
local function skipReason(entry)
    if SKIP[entry.class] then return SKIP[entry.class] end
    if entry.group == "Boss" then return "boss (only moves in its arena)" end
    if entry.class:find("Thief") or entry.class == "BP_LS328_MoneybagsRevenge_C" then return "egg thief (only moves in its chase)" end
    if idle[entry.class] then return "never moved in earlier runs (waits for its own level's triggers)" end
    return nil
end

local requested = false
local options = nil -- from the trigger file: { fps = <cap>, only = { pattern, ... } }
local run = nil -- { index, phase = "spawn" | "watch" | "gap", until, cur }
local nextPoll = 0
local nextStopPoll = 0
local file = nil

local function readProgress()
    local f = io.open(PROGRESS, "r")
    if not f then return 1, false end
    local line = f:read("l") or ""
    f:close()
    local n, running = line:match("^(%d+)%s*(%a*)")
    return tonumber(n) or 1, running == "running"
end

local function writeProgress(index, running)
    local f = io.open(PROGRESS, "w")
    if not f then return end
    f:write(string.format("%d%s\n", index, running and " running" or ""))
    f:close()
end

local function loadClass(path)
    local cls = StaticFindObject(path)
    if cls and cls:IsValid() then return cls end
    -- The package's asset name (no _C) first: LoadAsset on the class path only logs "Asset was found but not
    -- loaded, could be a package" and loads nothing.
    pcall(LoadAsset, (path:gsub("_C$", "")))
    cls = StaticFindObject(path)
    if cls and cls:IsValid() then return cls end
    local ok = pcall(LoadAsset, path)
    cls = StaticFindObject(path)
    if cls and cls:IsValid() then return cls end
    error("class not found after LoadAsset (" .. tostring(ok) .. ")")
end

-- Where a character stands dist in front of Spyro on his floor: its capsule centre is its half height up.
local function groundSpot(pawn, pc, dist, halfHeight)
    local loc = pawn:K2_GetActorLocation()
    local rad = math.rad(pc:GetControlRotation().Yaw)
    local floor = loc.Z - pawn.CapsuleComponent:GetScaledCapsuleHalfHeight()
    return { X = loc.X + math.cos(rad) * dist, Y = loc.Y + math.sin(rad) * dist, Z = floor + halfHeight + GROUND_CLEARANCE }
end

local function spawn(pawn, pc, entry, cls)
    local yaw = pc:GetControlRotation().Yaw
    local face = math.rad(yaw + 180) / 2 -- facing Spyro
    local transform = {
        Rotation = { X = 0, Y = 0, Z = math.sin(face), W = math.cos(face) },
        Translation = groundSpot(pawn, pc, SPAWN_DISTANCE, 100),
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
    local statics = UEHelpers.GetGameplayStatics()
    local actor = statics:BeginDeferredActorSpawnFromClass(pawn, cls, transform, 2, nil)
    if not actor or not actor:IsValid() then error("BeginDeferredActorSpawnFromClass returned nothing") end
    -- Now its capsule size is known: stand it on the floor.
    local ok, half = pcall(function() return actor.CapsuleComponent:GetScaledCapsuleHalfHeight() end)
    if ok and type(half) == "number" then transform.Translation = groundSpot(pawn, pc, SPAWN_DISTANCE, half) end
    statics:FinishSpawningActor(actor, transform)
    if not actor.Controller:IsValid() then pcall(function() actor:SpawnDefaultController() end) end
    return actor
end

local function stateName(actor)
    local ok, name = pcall(function() return actor.FalconEnemy:BP_GetCurrentStateName():ToString() end)
    return ok and name or "?"
end

local function newCur(entry, actor)
    return { entry = entry, actor = actor, start = os.clock(), states = {}, order = {}, state = nil, rx = nil, ry = nil,
             frames = 0, dtSum = 0, controller = actor.Controller:IsValid() }
end

local function sample(cur, dt)
    local actor = cur.actor
    if not actor:IsValid() then return end
    local cmc = actor.CharacterMovement
    if not cmc:IsValid() then return end
    local name = stateName(actor)
    local s = cur.states[name]
    if not s then
        s = { time = 0, want = 0, stillWant = 0, dist = 0, vmax = 0, entered = os.clock(), firstMove = nil, modes = {} }
        cur.states[name] = s
        cur.order[#cur.order + 1] = name
    end
    if name ~= cur.state then s.entered, cur.state = os.clock(), name end
    local vel, req, acc = cmc.Velocity, cmc.RequestedVelocity, cmc.Acceleration
    local speed = math.sqrt(vel.X * vel.X + vel.Y * vel.Y)
    local rx, ry = req.X, req.Y
    local want = acc.X ~= 0 or acc.Y ~= 0 or ((rx ~= 0 or ry ~= 0) and (rx ~= cur.rx or ry ~= cur.ry))
    cur.rx, cur.ry = rx, ry
    s.modes[cmc.MovementMode] = true
    s.time = s.time + dt
    s.dist = s.dist + speed * dt
    s.vmax = math.max(s.vmax, speed)
    if want then
        s.want = s.want + dt
        if speed == 0 then s.stillWant = s.stillWant + dt end
    end
    if speed > 0 and not s.firstMove then s.firstMove = os.clock() - s.entered end
    cur.frames, cur.dtSum = cur.frames + 1, cur.dtSum + dt
end

local function report(index, cur, failure)
    local e = cur and cur.entry or list[index]
    if failure then
        log("spawntest %d/%d %s failed: %s", index, #list, e.class, failure)
        if file then file:write(string.format("%s,%s,,,,,,,,,,failed\n", e.class, e.group)) file:flush() end
        return
    end
    local verdict, anyWant, dist = "idle", false, 0
    local parts = {}
    for _, name in ipairs(cur.order) do
        local s = cur.states[name]
        dist = dist + s.dist
        if s.want > 0 then anyWant = true end
        local stalled = s.want >= STALL_WANT and s.stillWant > 0.5 * s.want
        if stalled then verdict = "stalled" end
        local modes = {}
        for m in pairs(s.modes) do modes[#modes + 1] = tostring(m) end
        table.sort(modes)
        parts[#parts + 1] = string.format("%s[mode %s] %.2fs want %.2fs still %.2fs dist %.0f vmax %.0f first %s",
            name, table.concat(modes, "/"), s.time, s.want, s.stillWant, s.dist, s.vmax,
            s.firstMove and string.format("%.3fs", s.firstMove) or "never")
        if file then
            file:write(string.format("%s,%s,%.0f,%s,%s,%s,%.3f,%.3f,%.3f,%.1f,%.1f,%s,%.1f\n", e.class, e.group, e.accel,
                e.moves, name, table.concat(modes, "/"), s.time, s.want, s.stillWant, s.dist, s.vmax,
                s.firstMove and string.format("%.4f", s.firstMove) or "", cur.frames / math.max(cur.dtSum, 1e-6)))
        end
    end
    if verdict == "idle" and anyWant then verdict = "moved" end
    if verdict == "idle" and dist > 50 then verdict = "moved (no request seen)" end
    log("spawntest %d/%d %s: %s accel=%.0f moves=%s avgFps=%.0f controller=%s | %s", index, #list, e.class, verdict,
        e.accel, e.moves, cur.frames / math.max(cur.dtSum, 1e-6), tostring(cur.controller) .. (cur.nudgedAt and (" nudged in " .. cur.nudgedAt) or ""), table.concat(parts, " | "))
    if file then file:flush() end
end

local function destroy(cur)
    if cur and cur.actor:IsValid() then pcall(function() cur.actor:K2_DestroyActor() end) end
end

-- Every finished type stays alive (hidden, frozen, no collision) until the run ends. Four times a child class
-- failed to load ("Could not find SuperStruct ReceiveBeginPlay/UserConstructionScript": types 101, 107, 111,
-- 160), each a subclass of an enemy Blueprint that had been spawned and destroyed earlier in the session (not
-- always the type just before): the parent was being unloaded while the child loaded. A forced garbage
-- collection didn't help, and keeping only the previous type alive stopped all but the last one. Live
-- instances keep every class the run has loaded.
-- Hiding it and CustomTimeDilation 0 weren't enough: its components kept ticking (animation, movement, AI)
-- and the stall tracker kept reading it, so the framerate fell from ~330 to 187 by the 11th type and 56 by the
-- 111th (2026-09-19 15:00 run). Every component's tick goes off and it's deactivated, and the tracker drops it.
local function freeze(cur)
    local actor = cur.actor
    pcall(stalls.ignore, actor)
    pcall(function()
        actor:SetActorHiddenInGame(true)
        actor:SetActorEnableCollision(false)
        actor:SetActorTickEnabled(false)
        actor.CustomTimeDilation = 0
    end)
    -- Only the known heavy components, by name. Walking K2_GetComponentsByClass's result and deactivating each
    -- one crashed inside UE4SS (access violation, type 76 VulturePlucked, 2026-09-19 15:50).
    for _, name in ipairs({ "CharacterMovement", "Mesh", "FalconEnemy" }) do
        pcall(function()
            local comp = actor[name]
            if comp:IsValid() then comp:SetComponentTickEnabled(false) end
        end)
    end
    pcall(function()
        local controller = actor.Controller
        if controller:IsValid() then controller:SetActorTickEnabled(false) end
    end)
end

-- Before each spawn, Spyro goes back to where the run started (knockback and respawns move him), facing the
-- same way, so every type spawns in the same spot relative to him.
local function goHome(pawn, pc)
    pawn:K2_TeleportTo(run.home, { Pitch = 0, Yaw = run.homeYaw, Roll = 0 })
    pawn.CharacterMovement.Velocity = { X = 0, Y = 0, Z = 0 }
    pc:SetControlRotation({ Pitch = run.homePitch, Yaw = run.homeYaw, Roll = 0 })
end

local function destroyKept()
    for _, cur in ipairs(run.kept) do destroy(cur) end
    run.kept = {}
end

local function matchesOnly(entry)
    for _, pattern in ipairs(options and options.only or {}) do
        if entry.class:find(pattern, 1, true) then return true end
    end
    return false
end

local function start(pawn, pc, setFpsCap)
    local index, crashed = readProgress()
    if options and options.only then
        index, crashed = nil, false
        for i, entry in ipairs(list) do
            if matchesOnly(entry) then index = index or i end
        end
        if not index then
            log("spawntest: nothing matches only=%s", table.concat(options.only, ","))
            return
        end
    end
    if crashed then
        log("spawntest: %s crashed last run, skipping it", list[index] and list[index].class or tostring(index))
        index = index + 1
    end
    if index > #list then
        log("spawntest: all %d types done (delete spawntest_progress.txt to start over)", #list)
        return
    end
    if not file then
        file = io.open(CSV, "w")
        if file then file:write("class,group,accel,moves,state,modes,time,want,still_want,dist,vmax,first_move,avg_fps\n") end
    end
    setFpsCap(options and options.fps or 0)
    local loc, ctrl = pawn:K2_GetActorLocation(), pc:GetControlRotation()
    run = { index = index, phase = "spawn", kept = {}, home = { X = loc.X, Y = loc.Y, Z = loc.Z }, homeYaw = ctrl.Yaw, homePitch = ctrl.Pitch }
    -- Where he stands decides the position grid: an axis near 0 has fine steps and can't show the stall.
    log("spawntest: starting at %d/%d (%s), %d s each, cap %s%s, Spyro at (%.0f, %.0f, %.0f)", index, #list,
        list[index].class, WATCH, tostring(options and options.fps or 0),
        (options and options.only) and (", only " .. table.concat(options.only, ",")) or "", loc.X, loc.Y, loc.Z)
end

-- setFpsCap(cap) is main.lua's F-key handler.
function spawntest.update(pawn, pc, setFpsCap, dt)
    -- spawntest.stop stops a run that is already going (the start trigger is only read between runs),
    -- so a test can be turned off without reaching for U in the game window.
    if run and os.clock() >= nextStopPoll then
        nextStopPoll = os.clock() + 1
        local f = io.open(STOP, "r")
        if f then
            f:close()
            os.remove(STOP)
            requested = true
        end
    end
    if not run and os.clock() >= nextPoll then
        nextPoll = os.clock() + 1
        local f = io.open(TRIGGER, "r")
        if f then
            local text = f:read("a") or ""
            f:close()
            os.remove(TRIGGER)
            -- "restart" starts over; "fps=30" caps the framerate (a control run); "only=Cowlek,GiantCrab" runs
            -- just the types whose class name contains one of those, in list order, ignoring the progress file.
            if text:match("restart") then writeProgress(1, false) end
            options = { fps = tonumber(text:match("fps=(%d+)")) }
            local only = text:match("only=([%w_,%-]+)")
            if only then
                options.only = {}
                for pattern in only:gmatch("[^,]+") do options.only[#options.only + 1] = pattern end
            end
            requested = true
        end
    end
    if requested then
        requested = false
        if run then
            destroy(run.cur)
            destroyKept()
            writeProgress(run.index, false)
            log("spawntest: stopped at %d/%d", run.index, #list)
            run = nil
            invuln.clear(pawn)
        else
            start(pawn, pc, setFpsCap)
        end
        return
    end
    if not run then return end
    invuln.update(pawn) -- enemies attack him: keep Sparx topped up so he doesn't lose lives

    if run.phase == "spawn" then
        local entry = list[run.index]
        if not entry then
            destroyKept()
            log("spawntest: done, %d types", #list)
            run = nil
            invuln.clear(pawn)
            return
        end
        -- A control run (only=...) tests just those types, whatever the skip rules say.
        local skip = (options and options.only) and (not matchesOnly(entry) and "not in only=" or nil) or skipReason(entry)
        if skip == "not in only=" then
            run.index = run.index + 1
            return
        end
        if skip then
            log("spawntest %d/%d %s: skipped, %s", run.index, #list, entry.class, skip)
            run.index = run.index + 1
            writeProgress(run.index, false)
            return
        end
        writeProgress(run.index, true)
        log("spawntest %d/%d %s: spawning", run.index, #list, entry.class)
        pcall(goHome, pawn, pc)
        local okLoad, cls = pcall(loadClass, entry.path)
        local ok, actor = false, cls
        if okLoad then ok, actor = pcall(spawn, pawn, pc, entry, cls) end
        if not ok then
            report(run.index, { entry = entry }, tostring(actor))
            run.index = run.index + 1
            writeProgress(run.index, false)
            return
        end
        run.cur = newCur(entry, actor)
        run.phase, run["until"] = "watch", os.clock() + WATCH
    elseif run.phase == "watch" then
        local cur = run.cur
        -- Its trigger may need Spyro closer: once, halfway through, move a type that hasn't asked to move yet.
        if not cur.nudged and os.clock() - cur.start >= NUDGE_AT and cur.actor:IsValid() then
            cur.nudged = true
            local wanted = false
            for _, s in pairs(cur.states) do if s.want > 0 then wanted = true end end
            if not wanted then
                pcall(function()
                    local spot = groundSpot(pawn, pc, NUDGE_DISTANCE, cur.actor.CapsuleComponent:GetScaledCapsuleHalfHeight())
                    cur.actor:K2_SetActorLocation(spot, false, {}, true)
                    cur.nudgedAt = cur.state
                end)
            end
        end
        local ok, err = pcall(sample, run.cur, dt)
        if not ok and not run.cur.errorLogged then
            run.cur.errorLogged = true
            log("spawntest %s sample error: %s", run.cur.entry.class, tostring(err))
        end
        if os.clock() >= run["until"] or not run.cur.actor:IsValid() then
            report(run.index, run.cur)
            freeze(run.cur)
            run.kept[#run.kept + 1] = run.cur
            run.cur = nil
            run.index = run.index + 1
            writeProgress(run.index, false)
            run.phase, run["until"] = "gap", os.clock() + GAP
            local last = run.kept[#run.kept]
            local fps = last.frames / math.max(last.dtSum, 1e-6)
            if last.frames > 0 and not (options and options.fps and options.fps > 0) and fps < MIN_FPS then
                log("spawntest: framerate down to %.0f (below %d), stopping at %d/%d; restart the game to continue (it resumes by itself)",
                    fps, MIN_FPS, run.index, #list)
                destroyKept()
                writeProgress(run.index, false)
                local trigger = io.open(TRIGGER, "w") -- the next session picks up from here
                if trigger then trigger:write("go\n") trigger:close() end
                nextPoll = math.huge -- not this session: the parked classes are what slowed it down
                run = nil
                invuln.clear(pawn)
                return
            end
        end
    elseif run.phase == "gap" and os.clock() >= run["until"] then
        run.phase = "spawn"
    end
end

function spawntest.toggle()
    requested, options = true, nil -- U is always a plain uncapped run
end

return spawntest
