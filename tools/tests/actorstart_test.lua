-- Drives the probe's lib/actorstart.lua (characters put back the way a take's recording found them)
-- against a written _ref_actors.csv and fake actors: the first row of each character is read (with and
-- without the yaw column), characters missing from the recording are destroyed, the others are teleported
-- to their first row with the level origin added back and their velocity set, Spyro is never touched,
-- freed actors are not touched, and a take without a character trace gives nil.
--
--   lua tools\tests\actorstart_test.lua
--
-- Exits non-zero on a failure.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]tools[/\\]tests[/\\]") or "."
package.path = here .. "\\ue4ss\\DevMods\\SpyroFpsProbe\\Scripts\\?.lua;" .. package.path

local dir = os.getenv("TEMP") or "."
package.preload["lib.paths"] = function() return { modDir = dir } end
local logLines = {}
package.preload["lib.log"] = function()
    return function(fmt, ...) logLines[#logLines + 1] = string.format(fmt, ...) end
end

local failures = 0
local function check(cond, message)
    if not cond then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local function write(take, text)
    local f = assert(io.open(string.format("%s\\replay_%s_ref_actors.csv", dir, take), "w"))
    f:write(text)
    f:close()
end

write("TEST_A", table.concat({
    "# actor,Cowlek_01,BP_Cowlek_C,alive",
    "# actor,Cowlek_02,BP_Cowlek_C,dead",
    "# actor,Tub,CNS2140_SergeantTub_C",
    "t,name,x,y,z,vx,vy,vz,mode,yaw",
    "0.00000,Cowlek_01,100.00,200.00,30.00,55.0,0.0,0.0,2,90.00",
    "0.00000,Cowlek_02,-10.00,-20.00,40.00,0.0,0.0,0.0,2,-45.50",
    "0.00000,Tub,-3664.06,1480.81,738.00,0.0,0.0,0.0,1,10.00",
    "0.03333,Cowlek_01,999.00,999.00,30.00,55.0,0.0,0.0,2,90.00",
    "",
}, "\n"))
-- An older take: no yaw column.
write("TEST_OLD", table.concat({
    "# actor,Ram,BP_CES1015_Ram_C",
    "t,name,x,y,z,vx,vy,vz,mode",
    "0.00000,Ram,1.00,2.00,3.00,4.0,5.0,6.0,2",
    "",
}, "\n"))

local actorstart = require("lib.actorstart")

local a = actorstart.read("TEST_A")
check(a and a.count == 3, "three characters listed")
check(a and a.first.Cowlek_01.x == 100 and a.first.Cowlek_01.yaw == 90, "first row of Cowlek_01, not the later one")
check(a and a.first.Cowlek_02.yaw == -45.5 and a.first.Tub.mode == 1, "yaw and mode read")
local old = actorstart.read("TEST_OLD")
check(old and old.first.Ram.vz == 6 and old.first.Ram.yaw == nil, "a take without yaw reads, yaw nil")
check(actorstart.read("NO_SUCH_TAKE") == nil, "no character trace: nil")

-- Fake actors.
local touched = {}
local function fname(text) return { ToString = function() return text end } end
local nextAddress = 0x100
local function actor(name, opts)
    opts = opts or {}
    nextAddress = nextAddress + 0x10
    local self = { name = name, address = nextAddress, freed = opts.freed, rot = { Pitch = 1, Yaw = 2, Roll = 3 } }
    local function guard(what)
        if self.freed then touched[#touched + 1] = name .. ":" .. what; error("freed") end
    end
    self.CharacterMovement = { IsValid = function() return true end }
    function self:IsValid() return not self.freed end
    function self:GetAddress() return self.address end
    function self:GetFName() guard("GetFName"); return fname(name) end
    function self:K2_GetActorRotation() guard("rot"); return self.rot end
    function self:K2_SetActorLocationAndRotation(loc, rot, sweep, hit, teleport)
        guard("set"); self.loc, self.newRot, self.teleport, self.hit = loc, rot, teleport, hit
    end
    function self:K2_DestroyActor() guard("destroy"); self.destroyed = true end
    return self
end

local spyro = actor("BP_CPS1999_Playable_C_0")
local c1, c2 = actor("Cowlek_01"), actor("Cowlek_02")
local revived = actor("Cowlek_03")            -- dead when the take started, revived by the reload
local freed = actor("Cowlek_04", { freed = true })
local default = actor("Default__BP_Cowlek_C")
FindAllOf = function(class) assert(class == "Character"); return { spyro, c1, c2, revived, freed, default } end

local removed = actorstart.removeAbsent(a, spyro)
table.sort(removed)
check(#removed == 2 and removed[1] == "Cowlek_02" and removed[2] == "Cowlek_03" and revived.destroyed and c2.destroyed,
    "the cowlek recorded dead and the one not recorded are destroyed")
check(a.dead.Cowlek_02 and not a.dead.Cowlek_01 and not a.dead.Tub, "dead/alive read, missing state = alive")
check(not spyro.destroyed and not c1.destroyed and not default.destroyed, "Spyro, recorded ones and defaults stay")

local placed, missing = actorstart.place(a, { x = 300000, y = -300000 }, spyro)
check(placed == 1 and c2.loc == nil, "only the living one placed (got " .. tostring(placed) .. ")")
check(#missing == 1 and missing[1] == "Tub", "Tub is reported missing")
check(math.abs(c1.loc.X - (300100 - 55 * 0.03333)) < 1e-6 and c1.loc.Y == -299800 and c1.loc.Z == 30,
    "origin added back, one recorded frame back along the velocity")
check(math.abs(a.dt - 0.03333) < 1e-9, "the frame length is read from the second frame")
check(c1.newRot.Yaw == 90 and c1.newRot.Pitch == 1 and c1.newRot.Roll == 3, "recorded yaw, own pitch and roll")
check(c1.teleport == true and type(c1.hit) == "table" and next(c1.hit) == nil, "teleport, with an empty hit table")
check(c1.CharacterMovement.Velocity.X == 55, "velocity set")
check(spyro.loc == nil, "Spyro is not placed")
check(#touched == 0, "freed actors were touched: " .. table.concat(touched, ", "))

-- An older take keeps the character's own yaw.
local ram = actor("Ram")
FindAllOf = function() return { ram } end
actorstart.place(old, { x = 0, y = 0 }, spyro)
check(ram.newRot.Yaw == 2, "no recorded yaw: the character's own")

actorstart.placeAndLog(a, { x = 0, y = 0 }, spyro)
check(logLines[#logLines]:find("not in the level") ~= nil, "the log line names what is missing")
FindAllOf = function() error("boom") end
actorstart.removeAndLog(a, spyro, "LS213")
check(logLines[#logLines]:find("failed") ~= nil, "an error is logged, not raised")

os.remove(string.format("%s\\replay_TEST_A_ref_actors.csv", dir))
os.remove(string.format("%s\\replay_TEST_OLD_ref_actors.csv", dir))
if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print("actorstart_test: all passed")
