-- Checks lib/input.lua's input.sendLeftStick against a model of how Spyro's walking consumes the left
-- stick, so the replay's input ordering can be changed without a game restart to find out it broke.
--
-- The model is CharacterInputComponent_Spyro's bytecode (docs/probe.md, level replay, 2026-11-16): on the
-- ground each stick event stores its axis and calls RequestGroundMovement, which adds ONE vector from both
-- stored axes -- Normal(fwd * sign(Y) + right * sign(X)) at length |(X, Y)|, skipped when both are <= 0.1.
-- The engine fires X then Y once per input tick with the hardware value.
--
-- A recorded frame k is: engine X(x_k), engine Y(y_k). A replayed frame k is: Lua input.sendLeftStick at
-- the end of frame k-1, then engine X(0), engine Y(0) (no hardware stick during a replay). The test feeds
-- both the same stick sequence -- keys, simultaneous changes, analog ramps -- and requires every frame's
-- consumed input vector to match.
--
--   lua tools\tests\leftstick_test.lua
--
-- Exits non-zero on a failure.
local here = debug.getinfo(1, "S").source:match("^@(.*)[/\\]tools[/\\]tests[/\\]") or "."
package.path = here .. "\\ue4ss\\DevMods\\SpyroFpsProbe\\Scripts\\?.lua;" .. package.path

package.preload["lib.log"] = function() return function() end end
FindAllOf = function() error("the test hands input.lua its component through the cache; no search expected") end

local function sign(v) return v > 0 and 1 or (v < 0 and -1 or 0) end

-- A fake input component that adds to a pending vector the way RequestGroundMovement does.
-- Camera yaw 0: forward is +X, right is +Y.
local function makeComponent()
    local c = { InputAxisLeftStickX = 0, InputAxisLeftStickY = 0, pending = { 0, 0 } }
    local function requestGroundMovement(self)
        local x, y = self.InputAxisLeftStickX, self.InputAxisLeftStickY
        if math.abs(x) <= 0.1 and math.abs(y) <= 0.1 then return end
        local dx, dy = sign(y), sign(x)                -- fwd * sign(Y) + right * sign(X)
        local n = math.sqrt(dx * dx + dy * dy)
        local len = math.sqrt(x * x + y * y)
        self.pending[1] = self.pending[1] + dx / n * len
        self.pending[2] = self.pending[2] + dy / n * len
    end
    c.InputAxis_LeftStick_X = function(self, v) self.InputAxisLeftStickX = v; requestGroundMovement(self) end
    c.InputAxis_LeftStick_Y = function(self, v)
        self.InputAxisLeftStickY = v
        requestGroundMovement(self)
        -- tools/replay.lua's stick hook: after the Y body, restore both stored axes to the take's
        local inject = rawget(self, "inject")
        if inject then
            self.InputAxisLeftStickX, self.InputAxisLeftStickY = inject[1], inject[2]
        end
    end
    -- Every other axis/button event input.apply might fire: accepted, no movement.
    setmetatable(c, { __index = function() return function() end end })
    c.consume = function(self)
        local v = self.pending
        self.pending = { 0, 0 }
        return v
    end
    return c
end

-- The cache input.lua keeps is keyed on the controller and the pawn class; fake both so find() returns
-- our component without a FindAllOf walk. The first call has to search, so prime it through FindAllOf.
local function fakeObject(address)
    return {
        IsValid = function() return true end,
        GetAddress = function() return address end,
        GetClass = function(self) return fakeObject(0x500) end,
        GetOuter = function() return fakeObject(0x200) end,
        GetFName = function() return { ToString = function() return "Fake" end } end,
    }
end

local failures = 0
local function check(name, sequence, withHook)
    local input = (function()
        package.loaded["lib.input"] = nil
        return require("lib.input")
    end)()
    local pawn, pc = fakeObject(0x100), fakeObject(0x200)
    local recorded, replayed = makeComponent(), makeComponent()
    replayed.IsValid = function() return true end
    replayed.GetOuter = function() return pc end
    replayed.GetClass = function() return fakeObject(0x600) end
    FindAllOf = function() return { replayed } end

    -- Recording: the engine's events with the hardware value each frame.
    local want = {}
    for k, s in ipairs(sequence) do
        recorded:InputAxis_LeftStick_X(s[1])
        recorded:InputAxis_LeftStick_Y(s[2])
        want[k] = recorded:consume()
    end
    -- Replay: Lua at the end of frame k-1 sends frame k's row, then frame k's engine events fire with 0.
    local prevY = 0
    for k, s in ipairs(sequence) do
        if withHook then replayed.inject = { s[1], s[2] } end
        input.sendLeftStick(pawn, pc, s[1], s[2], prevY)
        prevY = s[2]
        replayed:InputAxis_LeftStick_X(0)
        replayed:InputAxis_LeftStick_Y(0)
        if withHook and (replayed.InputAxisLeftStickX ~= s[1] or replayed.InputAxisLeftStickY ~= s[2]) then
            failures = failures + 1
            print(string.format("FAIL %s frame %d: stored stick (%.2f, %.2f) after the input tick, take (%.2f, %.2f)",
                name, k, replayed.InputAxisLeftStickX, replayed.InputAxisLeftStickY, s[1], s[2]))
            return
        end
        local got = replayed:consume()
        local w = want[k]
        if math.abs(got[1] - w[1]) > 1e-6 or math.abs(got[2] - w[2]) > 1e-6 then
            failures = failures + 1
            print(string.format("FAIL %s frame %d stick (%.2f, %.2f): replay (%.3f, %.3f), recording (%.3f, %.3f)",
                name, k, s[1], s[2], got[1], got[2], w[1], w[2]))
            return
        end
    end
    print("ok   " .. name)
end

check("W press, hold, release", { {0, 0}, {0, 1}, {0, 1}, {0, 1}, {0, 0}, {0, 0} })
check("A press, hold, release", { {0, 0}, {-1, 0}, {-1, 0}, {0, 0}, {0, 0} })
check("A release and W press on one frame", { {-1, 0}, {-1, 0}, {0, 1}, {0, 1}, {0, 0} })
check("diagonal on and off", { {0, 0}, {1, 1}, {1, 1}, {0, 1}, {0, 0} })
check("analog ramp (LS102_20261115_160013)", {
    {0, 0}, {-0.1425, 0}, {-0.4562, 0}, {-0.7804, 0}, {-1, 0.0588}, {-1, 0.1425}, {-0.9059, 0.4144},
    {-0.7909, 0.6131}, {-0.4667, 0.9686}, {-0.2157, 1}, {0, 0.3412}, {0, 0}, {0.4771, 0.0065}, {0, 0} })
check("analog under the 0.1 dead zone", { {0, 0}, {0.05, 0.08}, {0.2, 0.05}, {0.05, 0.3}, {0, 0} })

-- The same sequences with tools/replay.lua's stored-stick hook on, as every replayed frame has it: the
-- consumed input must not change, and the stored stick must read the take's after the input tick.
check("hook: A release and W press on one frame", { {-1, 0}, {-1, 0}, {0, 1}, {0, 1}, {0, 0} }, true)
check("hook: diagonal on and off", { {0, 0}, {1, 1}, {1, 1}, {0, 1}, {0, 0} }, true)
check("hook: analog ramp", { {0, 0}, {-0.1425, 0}, {-0.4562, 0}, {-1, 0.0588}, {-0.4667, 0.9686}, {0, 0.3412}, {0, 0} }, true)

if failures > 0 then
    print(string.format("%d failure(s)", failures))
    os.exit(1)
end
print("all passed")
