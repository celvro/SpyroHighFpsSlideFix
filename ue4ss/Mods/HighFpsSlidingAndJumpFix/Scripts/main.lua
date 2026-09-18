-- High FPS Gameplay Fixes: runtime fixes for framerate-dependent gameplay bugs in Spyro Reignited
-- Trilogy (UE 4.19). The game was tuned at 30 FPS, so every fix reproduces what 30 FPS does and
-- leaves 30 FPS and lower alone (the stuck camera fix is the one exception, see fixes/camera.lua).
-- The folder and log prefix keep the original name (HighFpsSlidingAndJumpFix) so updates replace
-- older installs instead of loading alongside them.
--
-- Scripts/
--   config.lua    on/off switches for every fix and for profiling
--   lib/          shared helpers: logging, engine handles, object lookups, the UE movement math
--   fixes/        one module per fix, each headed by the findings that explain it
--   profiler.lua  per-frame cost logging (config.PROFILE)
--
-- A fix module returns { name, enabled, update(ctx) [, reset()] [, disable(ctx, err)] }. This file
-- reads what every fix needs once per frame into `ctx`, runs them in order, and takes a fix that
-- errors out of the rotation (calling its disable to put back whatever it changed in the engine)
-- instead of repeating the error every frame.

local config = require("config")
local engine = require("lib.engine")
local log = require("lib.log")
local lookup = require("lib.lookup")
local profiler = require("profiler")

local VERSION = "1.5.0" -- tools/Package-Release.ps1 names the release zip from this

local camera = require("fixes.camera")

-- Fixes that patch level assets or register hooks as levels load: they only need the controller,
-- so they also run while there is no pawn.
local levelFixes = {
    require("fixes.druid"),
    require("fixes.dragon"),
    require("fixes.balloon"),
}
-- Fixes that act on Spyro, in the order the tick runs them.
local pawnFixes = {
    require("fixes.flame"),
    require("fixes.walking"),
    require("fixes.jump"),
    require("fixes.glide"),
    require("fixes.dust"),
    require("fixes.charge"),
    camera.centering,
    camera.switch,
}

-- Filled in once per frame and passed to every fix; reused so a tick allocates nothing.
local ctx = { pc = nil, pawn = nil, cmc = nil, dt = 0, mode = 0, vel = nil }

local function run(fix)
    if not fix.enabled or fix.failed then return end
    local ok, err = pcall(fix.update, ctx)
    if ok then return end
    fix.failed = true
    if fix.disable then pcall(fix.disable, ctx, err) end
    log("%s disabled after error: %s", fix.name, tostring(err))
end

-- No pawn to fix (level change, cutscene): drop the per-pawn state so nothing carries over.
local function resetPawnFixes()
    for _, fix in ipairs(pawnFixes) do
        if fix.reset then fix.reset() end
    end
end

local function tick()
    local pc = engine.getPlayerController()
    if not pc then return end
    ctx.pc = pc
    for _, fix in ipairs(levelFixes) do run(fix) end

    local pawn = pc.Pawn
    if not pawn:IsValid() then resetPawnFixes() return end
    local cmc = pawn.CharacterMovement
    if not cmc:IsValid() then resetPawnFixes() return end

    ctx.pawn, ctx.cmc = pawn, cmc
    ctx.dt = engine.worldDeltaSeconds(pawn)
    engine.dt = ctx.dt
    -- Read once and shared: the mode and velocity of the frame that just finished. Everything a fix
    -- writes here (velocity, gravity scale, friction, camera speeds) applies to the next frame.
    ctx.mode = cmc.MovementMode
    ctx.vel = cmc.Velocity
    for _, fix in ipairs(pawnFixes) do run(fix) end
end

local errorLogged = false

local function runTick()
    engine.frame = engine.frame + 1
    local ok, err = pcall(tick)
    if not ok and not errorLogged then
        errorLogged = true
        log("error: %s", tostring(err))
    end
end

if not EngineTickAvailable then
    log("EngineTick hook unavailable; fixes disabled")
    return
end

if config.GC_MODE then
    local ok, err = pcall(collectgarbage, config.GC_MODE)
    if ok then log("collectgarbage(%q) applied to the shared Lua state", config.GC_MODE)
    else log("collectgarbage(%q) failed: %s", config.GC_MODE, tostring(err)) end
end

-- After the fix modules have registered what they watch for (they do that when required above).
lookup.start()

LoopInGameThreadAfterFrames(1, config.PROFILE and profiler.wrap(runTick) or runTick)

log("v%s loaded%s%s", VERSION, config.PROFILE and " (profiling on)" or "", config.GC_PROFILE and " (GC profiling on)" or "")
