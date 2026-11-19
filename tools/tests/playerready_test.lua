-- Drives the probe's lib/playerready.lua (the level-start events the level replay's sublevel reload
-- skips) against fake actors: PlayerReady only on IGC_Selector_C and its subclasses, GameStateChange
-- (with the game state's current and previous state) only on Spyro_IGC_Base_C and its subclasses, both
-- only in the level's reloaded sublevels. Other classes (Zoe, which has PlayerReady too), other levels,
-- art sublevels and freed actors are not called, a call that raises is reported, and with no game state
-- to read no GameStateChange is sent.
--
--   lua tools\tests\playerready_test.lua
--
-- Exits non-zero on a failure.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]tools[/\\]tests[/\\]") or "."
package.path = here .. "\\ue4ss\\DevMods\\SpyroFpsProbe\\Scripts\\?.lua;" .. package.path

local logLines = {}
package.preload["lib.log"] = function()
    return function(fmt, ...)
        local line = string.format(fmt, ...)
        logLines[#logLines + 1] = line
        return line
    end
end

local violations = {}
local function fname(text) return { ToString = function() return text end } end

local nextAddress = 0x1000
local function class(name, super)
    nextAddress = nextAddress + 0x80
    local c = { name = name, super = super, address = nextAddress }
    function c:IsValid() return true end
    function c:GetAddress() return self.address end
    function c:GetFName() return fname(self.name) end
    function c:GetSuperStruct() return self.super end
    return c
end

local Actor = class("Actor")
local Selector = class("IGC_Selector_C", Actor)
local OrbSelector = class("IGC_Selector_Orb_C", Selector)
local Zoe = class("CNS2161_Zoe_C", class("BP_Base_NPC_C", Actor))
local IgcBase = class("Spyro_IGC_Base_C", Actor)
local DoEvent = class("Spyro_IGC_DoEvent_C", IgcBase)
local Sequence = class("Spyro_IGC_Sequence_C", IgcBase)

local readied, states = {}, {}
local function actor(name, sub, cls, opts)
    opts = opts or {}
    local a = { name = name, sub = sub, cls = cls, freed = opts.freed, raises = opts.raises }
    local function guard(what)
        if a.freed then violations[#violations + 1] = name .. ":" .. what; error("freed") end
    end
    function a:IsValid() return not self.freed end
    function a:GetFName() guard("GetFName"); return fname(name) end
    function a:GetClass() guard("GetClass"); return cls end
    function a:GetOuter()
        guard("GetOuter")
        return { GetOuter = function() return { GetFName = function() return fname(sub) end } end }
    end
    function a:PlayerReady()
        guard("PlayerReady")
        if self.raises then error("no PlayerReady") end
        readied[name] = (readied[name] or 0) + 1
    end
    function a:GameStateChange(prev, nextState)
        guard("GameStateChange")
        if self.raises then error("no GameStateChange") end
        states[name] = states[name] or {}
        table.insert(states[name], { prev, nextState })
    end
    return a
end

local world = {
    actor("IGC_Selector2_3253", "LS213_design", Selector),        -- Tub's
    actor("IGC_Selector_514", "LS213_design", Selector),          -- Colonel Blub's
    actor("IGC_SelectorOrb_1", "LS213_Cinematics", OrbSelector),  -- a subclass
    actor("CNS2161_Zoe_1122", "LS213_design", Zoe),               -- has PlayerReady, not a selector
    actor("1_SergeantTub0_Intro_DoEvent", "LS213_design", DoEvent), -- Tub's intro
    actor("6_Juliet2_Sequence", "LS213_Cinematics", Sequence),
    actor("IGC_Selector_Art", "LS213_Art01", Selector),           -- not reloaded
    actor("Art_Sequence", "LS213_Art01", Sequence),               -- not reloaded
    actor("IGC_Selector_Other", "LS214_design", Selector),        -- another level
    actor("IGC_Selector_Freed", "LS213_design", Selector, { freed = true }),
    actor("Freed_Sequence", "LS213_design", Sequence, { freed = true }),
    actor("IGC_Selector_Raises", "LS213_Loot", Selector, { raises = true }),
    actor("Raises_DoEvent", "LS213_Loot", DoEvent, { raises = true }),
}
FindAllOf = function(name) assert(name == "Actor"); return world end
local gameState = { theCurrentGameState = 3, thePreviousGameState = 5 }
function gameState:IsValid() return true end
FindFirstOf = function(name) assert(name == "FalconGameStateBase"); return gameState end

local playerready = require("lib.playerready")

local failures = 0
local function check(cond, message)
    if not cond then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

check(playerready.wanted("LS213_design", "LS213"), "design is reloaded")
check(playerready.wanted("LS213_Loot", "LS213"), "Loot is reloaded")
check(playerready.wanted("LS213_Enemy", "LS213"), "Enemy is reloaded")
check(not playerready.wanted("LS213_Art01", "LS213"), "art is not")
check(not playerready.wanted("LS214_design", "LS213"), "another level is not")

local r = playerready.notify("LS213")
check(readied["IGC_Selector2_3253"] == 1, "Tub's selector gets PlayerReady once")
check(readied["IGC_Selector_514"] == 1, "Blub's selector gets PlayerReady")
check(readied["IGC_SelectorOrb_1"] == 1, "a selector subclass gets PlayerReady")
check(readied["CNS2161_Zoe_1122"] == nil, "Zoe is not called")
check(readied["6_Juliet2_Sequence"] == nil, "a cinematic does not get PlayerReady")
check(readied["IGC_Selector_Art"] == nil, "an art-sublevel selector is not called")
check(readied["IGC_Selector_Other"] == nil, "another level's selector is not called")
check(#r.ready == 3, "three selectors called (got " .. #r.ready .. ")")
check(#r.readyFailed == 1 and r.readyFailed[1] == "IGC_Selector_Raises", "a PlayerReady that raises is reported")

local tub = states["1_SergeantTub0_Intro_DoEvent"]
check(tub and #tub == 1 and tub[1][1] == 5 and tub[1][2] == 3, "Tub's intro gets GameStateChange(5, 3) once")
check(states["6_Juliet2_Sequence"] and #states["6_Juliet2_Sequence"] == 1, "a sequence gets GameStateChange")
check(states["Art_Sequence"] == nil, "an art-sublevel IGC is not called")
check(states["IGC_Selector2_3253"] == nil, "selectors do not get GameStateChange")
check(states["CNS2161_Zoe_1122"] == nil, "Zoe does not get GameStateChange")
check(#r.state == 2, "two IGCs called (got " .. #r.state .. ")")
check(#r.stateFailed == 1 and r.stateFailed[1] == "Raises_DoEvent", "a GameStateChange that raises is reported")
check(r.current == 3 and r.previous == 5, "the game state sent is reported")
check(#violations == 0, "freed actors were touched: " .. table.concat(violations, ", "))

playerready.notifyAndLog("LS213")
local line = logLines[#logLines]
check(line:find("PlayerReady sent to 3") ~= nil, "the log line counts the selectors")
check(line:find("game state 3 sent to 2") ~= nil, "the log line counts the IGCs")
check(line:find("Raises_DoEvent") ~= nil and line:find("IGC_Selector_Raises") ~= nil, "the log line names failures")

-- No game state to read: PlayerReady still goes out, GameStateChange does not.
states = {}
FindFirstOf = function() return nil end
r = playerready.notify("LS213")
check(#r.ready == 3 and #r.state == 0 and r.current == nil, "no game state: selectors only")
check(next(states) == nil, "no game state: no GameStateChange sent")
playerready.notifyAndLog("LS213")
check(logLines[#logLines]:find("no game state") ~= nil, "no game state: said in the log line")

FindAllOf = function() error("boom") end
playerready.notifyAndLog("LS213")
check(logLines[#logLines]:find("failed") ~= nil, "an error is logged, not raised")

if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print("playerready_test: all passed")
