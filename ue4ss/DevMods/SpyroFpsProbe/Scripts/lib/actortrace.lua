-- Every character's position and velocity, every frame of a level replay and of the recording itself
-- (tools/replay.lua), so a run can be compared character by character with the recording or another run
-- (tools/Compare-ReplayActors.ps1) instead of by reading logs. Spyro is in the run's own trace and is
-- left out here.
--
--   replay_<take>_ref_actors.csv               while the take is recorded (t = the take's clock)
--   replay_<take>_run<cap>_<stamp>_actors.csv  during each replay (t = time since the take started playing)
--     "# actor,<name>,<class>,<dead|alive>"   one line per character, at the top: who was in the level and
--                                 whether it was dead (IsDead) when the file was opened (the state field
--                                 from 2026-11-19 on)
--     t,name,x,y,z,vx,vy,vz,mode,yaw  then one row per character per frame: game time since the take
--                                 started, the actor's name (the same in every run: placed actors keep
--                                 the name the level gave them through the replay's sublevel reload),
--                                 position relative to the level origin as the run's trace has it,
--                                 CharacterMovement.Velocity, MovementMode (1 walking, 2 navwalking,
--                                 3 falling, 4 swimming, 5 flying, 6 custom), and yaw (from 2026-11-19;
--                                 lib/actorstart.lua puts the characters back on the recording's first row)
--
-- Cost (Stone Hill, 27 characters, 2026-11-19): 0.11 ms a frame to read them all through properties
-- (RootComponent.RelativeLocation, which for a character's root is its world location, and
-- CharacterMovement.Velocity); K2_GetActorLocation would double it. The list is taken once, when the take
-- starts playing (one FindAllOf walk), so a character spawned later in the run is not in it.
--
-- Every character is IsValid-checked before every read: a sublevel streaming out frees its actors, and
-- touching a freed one takes the game down (CLAUDE.md).
local log = require("lib.log")

local actortrace = {}

local HEADER = "t,name,x,y,z,vx,vy,vz,mode,yaw\n"

-- Opens the file and lists the characters. `skip` is the player's pawn. Returns the trace state, or nil.
function actortrace.open(path, origin, skip)
    local file = io.open(path, "w")
    if not file then
        log("replay: could not open %s", path)
        return nil
    end
    local skipAddress = nil
    pcall(function() skipAddress = skip:GetAddress() end)
    local list = {}
    for _, actor in ipairs(FindAllOf("Character") or {}) do
        local ok, entry = pcall(function()
            if not actor:IsValid() or actor:GetAddress() == skipAddress then return nil end
            local name = actor:GetFName():ToString()
            if name:match("^Default__") then return nil end
            local cmc, root = actor.CharacterMovement, actor.RootComponent
            if not (cmc and cmc:IsValid() and root and root:IsValid()) then return nil end
            -- A killed enemy stays in the level as a dead actor (Zephyr's birds, 2026-11-19), so being listed
            -- is not being alive: PhasmidCharacter's IsDead says which.
            local deadOk, dead = pcall(function() return actor:IsDead() end)
            return { actor = actor, cmc = cmc, root = root, name = name, dead = deadOk and dead == true,
                     class = actor:GetClass():GetFName():ToString() }
        end)
        if ok and entry then list[#list + 1] = entry end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    for _, e in ipairs(list) do
        file:write(string.format("# actor,%s,%s,%s\n", e.name, e.class, e.dead and "dead" or "alive"))
    end
    file:write(HEADER)
    log("replay: tracing %d character(s) -> %s", #list, path)
    return { file = file, list = list, ox = origin.x, oy = origin.y, gone = 0 }
end

-- One row per character still alive.
function actortrace.sample(st, t)
    if not st then return end
    local file, ox, oy = st.file, st.ox, st.oy
    for _, e in ipairs(st.list) do
        if not e.dead then
            if e.actor:IsValid() and e.cmc:IsValid() and e.root:IsValid() then
                local l, v, rot = e.root.RelativeLocation, e.cmc.Velocity, e.root.RelativeRotation
                file:write(string.format("%.5f,%s,%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%d,%.2f\n", t, e.name,
                    l.X - ox, l.Y - oy, l.Z, v.X, v.Y, v.Z, e.cmc.MovementMode or 0, rot.Yaw))
            else
                e.dead = true -- freed (killed, or its sublevel streamed out): never touched again
                st.gone = st.gone + 1
            end
        end
    end
end

function actortrace.close(st)
    if not st then return end
    st.file:close()
    if st.gone > 0 then log("replay: %d traced character(s) were freed during the run", st.gone) end
end

return actortrace
