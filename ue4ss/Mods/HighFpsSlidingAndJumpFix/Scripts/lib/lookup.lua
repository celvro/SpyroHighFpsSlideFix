-- Finding the level Blueprints, montages and particle systems the fixes patch, and hooking them.
--
-- A StaticFindObject that finds nothing scans the whole object array (~10 ms, a visible hitch), so
-- lookups must never poll. Instead each user gets a few lookups at startup and a few more whenever
-- NotifyOnNewObject reports the object being created, i.e. when the level that has it loads.
local log = require("lib.log")

local lookup = {}

local RETRY_FRAMES = 60         -- frames between looks for a (not yet loaded) Blueprint or asset
local NEW_OBJECT_LOOKUPS = 10   -- lookups granted when the object we want is created
lookup.MAX_FAILURES = 200       -- failed RegisterHook calls before giving up on a level Blueprint

-- Spends one of `state`'s lookups every RETRY_FRAMES frames. Returns the object when a lookup
-- finds it (the caller decides whether to keep `state.lookups` for another try), else nil.
function lookup.find(state, path)
    if state.lookups <= 0 then return nil end
    if state.retryIn > 0 then
        state.retryIn = state.retryIn - 1
        return nil
    end
    state.retryIn = RETRY_FRAMES
    state.lookups = state.lookups - 1
    local object = StaticFindObject(path)
    if object and object:IsValid() then return object end
    return nil
end

-- Blueprints load after the mods, so the hooked function is looked up once its class is created
-- (see lookup.watch). `state` tracks the attempts; `name` is the fix named in the log.
function lookup.registerBlueprintHook(state, path, pre, post, name)
    if state.registered or state.failed then return end
    if not lookup.find(state, path) then return end
    local ok, err = pcall(RegisterHook, path, pre, post)
    if ok then
        state.registered = true
        log("%s hook registered", name)
    else
        state.failed = true
        log("%s fix disabled: RegisterHook failed: %s", name, tostring(err))
    end
end

local watched = {} -- class path -> { object name -> lookup state }

-- Grants `state` fresh lookups whenever an object called `name` of that class is created.
function lookup.watch(classPath, name, state)
    local names = watched[classPath]
    if not names then
        names = {}
        watched[classPath] = names
    end
    names[name] = state
end

local function startLookups(state)
    if not state then return end
    state.lookups = NEW_OBJECT_LOOKUPS
    state.retryIn = 0
end

-- Installs the notifications, once every fix has registered what it watches for. The callback only
-- flags the state; the lookup itself runs from the tick, on the game thread, after loading has had
-- a chance to finish.
function lookup.start()
    for classPath, names in pairs(watched) do
        NotifyOnNewObject(classPath, function(object)
            local ok, name = pcall(function() return object:GetFName():ToString() end)
            if ok then startLookups(names[name]) end
        end)
    end
end

return lookup
