-- NaN animation speed fix
--
-- An NPC or enemy can end up running in its idle pose for the rest of the level. The Artisans gem thief
-- (BP_CES1012_GemThief) is the reported case: his Flee state is the only one with no montage, so while
-- fleeing his pose comes only from his anim Blueprint's blendspace, and that blendspace's X is the
-- Blueprint's Speed, set every update through the shared CalculateTurnRate library as
--     Speed = Lerp(Speed, VSize2D(GetVelocity()), DeltaTime * n)
-- The accumulator is its own input, so one non-finite frame sticks for ever: Lerp(NaN, v, a) is NaN, and
-- an inf becomes NaN on the next frame (inf + a*(v - inf) = inf - inf). A NaN X reads as the blendspace's
-- idle sample at any speed, so the character glides along in its idle animation. The NaN arrives in the
-- character's Velocity when a flee starts from a standstill at high FPS (see the findings doc); at 30 FPS
-- it has never been seen.
--
-- This writes the character's own horizontal speed over a non-finite Speed, which is all the Lerp needs
-- to converge again — the fix doesn't own the value afterwards. It only writes when the velocity itself
-- is finite, since writing a NaN over a NaN achieves nothing, and the character is left alone entirely
-- while its Speed is a number, so nothing that works is touched. Verified with the probe's T test at
-- 30 and 320 FPS (docs/findings/gem-thief-anim.md).
--
-- It heals at every framerate rather than only above 30: a NaN pose is not what 30 FPS does either, and
-- the state cannot arise there, so there is nothing of the reference behaviour to preserve.

local config = require("config")
local log = require("lib.log")

local PHASMID_CHARACTER = "/Script/Phasmid.PhasmidCharacter" -- every NPC and enemy derives from this
local CHECK_INTERVAL = 0.25  -- seconds between checks of one character
local CHECKS_PER_FRAME = 2   -- characters read per frame, round robin
local GRACE = 1              -- seconds before a newly constructed character is read
local MAX_LOGS = 3           -- heals logged per session; the rest are silent

local fix = {
    name = "NaN animation speed fix",
    enabled = config.FIX_NAN_ANIM_SPEED,
}

-- One entry per character: the actor, its cached anim instance, when to read it next, and skip for the
-- ones whose anim Blueprint has no Speed at all (a state machine instead of a blendspace), which is most
-- of them and never needs reading again.
local entries = {}
local order = {}
local cursor = 1
local pending = {}
local time = 0        -- seconds, accumulated from the tick's dt. Level fixes run before main reads dt,
                      -- so this is one frame behind and stands still until there is a pawn, which is
                      -- exactly when there is nothing to heal anyway.
local healed = 0

-- A NaN compares false against everything, so every test goes through this.
local function isFinite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function animInstance(actor)
    local mesh = actor.Mesh
    if not mesh or not mesh:IsValid() then return nil end
    local instance = mesh:GetAnimInstance()
    if not instance or not instance:IsValid() then return nil end
    return instance
end

-- Characters are collected as the engine creates them (CLAUDE.md: never poll for something that may not
-- exist). The callback only appends; everything else happens on the tick, so nothing reads an actor the
-- engine is still building.
local function onNewCharacter(object)
    pending[#pending + 1] = object
end

local function resolve()
    for i = #pending, 1, -1 do
        local actor = pending[i]
        pending[i] = nil
        if actor:IsValid() then
            local address = actor:GetAddress()
            if not entries[address] then
                entries[address] = { actor = actor, nextCheck = time + GRACE }
                order[#order + 1] = address
            end
        end
    end
end

-- Reads one character's anim Blueprint Speed and, if it has gone non-finite, writes its real speed back.
local function check(e)
    local actor = e.actor
    if not e.instance or not e.instance:IsValid() then
        e.instance = animInstance(actor)
        if not e.instance then return end
    end
    local speed = e.instance.Speed
    if speed == nil then
        e.skip = true -- this Blueprint has no Speed; never worth reading again
        return
    end
    if isFinite(speed) then return end

    local cmc = actor.CharacterMovement
    if not cmc or not cmc:IsValid() then return end
    local v = cmc.Velocity
    local real = math.sqrt(v.X * v.X + v.Y * v.Y)
    if not isFinite(real) then return end -- the velocity is NaN too on the frame it lands; next time
    e.instance.Speed = real
    healed = healed + 1
    -- Rate limited in case a write ever fails to stick: this would otherwise log every CHECK_INTERVAL.
    if healed <= MAX_LOGS then
        log("%s: healed %s (animation speed was not a number)", fix.name,
            actor:GetClass():GetFName():ToString())
    end
end

function fix.update(ctx)
    time = time + (ctx.dt or 0)
    resolve()
    local checked, steps = 0, 0
    while checked < CHECKS_PER_FRAME and steps < #order do
        steps = steps + 1
        if cursor > #order then cursor = 1 end
        local address = order[cursor]
        local e = entries[address]
        if not e or not e.actor:IsValid() then
            entries[address] = nil
            table.remove(order, cursor)
        elseif e.skip then
            cursor = cursor + 1
        else
            cursor = cursor + 1
            if time >= e.nextCheck then
                e.nextCheck = time + CHECK_INTERVAL
                checked = checked + 1
                check(e)
            end
        end
    end
end

-- Nothing of the engine's is held: the only write is a finite number over a NaN, so an error needs no
-- undoing. The characters are dropped so a disabled fix stops holding them.
function fix.disable()
    entries, order, pending, cursor = {}, {}, {}, 1
end

if fix.enabled then
    NotifyOnNewObject(PHASMID_CHARACTER, onNewCharacter)
end

return fix
