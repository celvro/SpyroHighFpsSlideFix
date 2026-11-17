-- Scripted controller input: calls the character's own Blueprint input events, so the game processes a
-- test run exactly as it processes a player (the charge steering, the jump hold, the glide push and the
-- dialogue skips all live in that component, not in the movement component).
--
-- Every playable character has a FalconCharacterInputComponent subclass (CharacterInputComponent_Spyro,
-- _Sheila, ...), held by the player controller; the axes are events taking one float and the buttons events taking one bool.
-- The engine fires the axis events every frame while the stick is held, so held axes are re-sent every
-- frame here too; buttons are only sent when they change, as a real press does.
--
-- Use: input.hold({ leftY = 1 }), input.press("jump"), input.release("jump"), input.apply(pawn, pc) once
-- per frame, input.clear(pawn, pc) when the run ends (which also releases every held button).
local log = require("lib.log")

local input = {}

-- Event name per axis/button. Names are the DualShock/Xbox face-button positions the game uses:
-- As DefaultInput.ini binds them: FaceBottom = A/cross (Jump), FaceLeft = X/square (ChargeAttack),
-- FaceRight = B/circle (FireAttack), FaceTop = Y/triangle (FreeLook, and SkipCutscene). FaceTop is left
-- out: nothing here wants the camera, and a release sent for it would still reach FreeLook. Spyro's Blueprint
-- implements FaceBottom, FaceRight and FaceTop; FaceLeft is the native FalconCharacterInputComponent's.
-- (This had charge on FaceRight and flame on FaceTop until 2026-09-22, so every scripted "charge" before
-- then breathed fire and every "flame" went into first person.)
input.AXES = {
    leftX = "InputAxis_LeftStick_X", leftY = "InputAxis_LeftStick_Y",
    rightX = "InputAxis_RightStick_X", rightY = "InputAxis_RightStick_Y",
    triggerL = "InputAxis_TriggerLeft", triggerR = "InputAxis_TriggerRight",
}
-- The axis VALUE stored on the component each frame, which some Blueprint logic reads instead of the
-- movement input vector: the charge steering reads InputAxisLeftStickX (docs/findings/charge-turn-camera.md,
-- "Charge steering is Blueprint"), and the mouse charge steering fix reads InputAxisRightStickX. Calling
-- the axis event alone drives walking (AddMovementInput) but never sets these, so a replayed charge turn
-- steered straight (its yaw froze) until input.apply wrote them too. A property a character's component
-- does not have is skipped (pcall). Recording reads the same names (tools/replay.lua).
input.AXIS_PROPS = {
    leftX = "InputAxisLeftStickX", leftY = "InputAxisLeftStickY",
    rightX = "InputAxisRightStickX", rightY = "InputAxisRightStickY",
    triggerL = "InputAxisTriggerLeft", triggerR = "InputAxisTriggerRight",
}
local axisPropMissing = {} -- property name -> true once writing it failed, logged once

input.BUTTONS = {
    jump = "InputAction_FaceBottom", charge = "InputAction_FaceLeft", flame = "InputAction_FaceRight",
    shoulderL = "InputAction_ShoulderLeft", shoulderR = "InputAction_ShoulderRight",
    triggerL = "InputAction_TriggerLeft", triggerR = "InputAction_TriggerRight",
    stickL = "InputAction_LeftThumbstickButton", stickR = "InputAction_RightThumbstickButton",
}

local axes = {}        -- axis key -> value held this frame
local buttons = {}     -- button key -> true while held
local sent = {}        -- button key -> what the game was last told
local component = nil  -- { pcAddress, classAddress, object }
local missing = {}     -- event names this character does not have, logged once
local warned = false   -- the "no input component" line is logged once
local searchedAt = nil -- os.clock() of the last fruitless search, so one failure is not one per frame

local SEARCH_AGAIN = 1.0 -- seconds before a search that found nothing is tried again

-- The character's input component. It is a subobject of the player controller in this game, not of the
-- pawn (lib/row.lua reads it as pc.CharacterInputComponent_Spyro), so both are accepted as its outer.
-- FindAllOf takes the native base class and returns the Blueprint subclasses too, so this works for every
-- playable character.
--
-- **The cache is keyed on the controller and the pawn's CLASS, not on the pawn's address.** The component
-- belongs to the player controller, which outlives every level load, so a new pawn does not need a new
-- lookup -- and a pawn address does get reused, so keying on it meant the hit test could pass for a
-- different pawn. What does need a new one is a different kind of character (Spyro -> Sheila), which has
-- its own CharacterInputComponent subclass; the class address catches exactly that.
--
-- Getting this wrong was not just a correctness risk: `input.clear` used to forget the component, and
-- `play.dead` and the other per-frame clears call it every frame, so a run spent a whole
-- FindAllOf("FalconCharacterInputComponent") walk of the object array -- and a "driving ..." log line --
-- on every frame of every death (measured at 30 a second in LS109 on 2026-11-04). Clearing the input
-- keeps the component now; input.forget() is the one that drops it.
local function find(pawn, pc)
    local okClass, class = pcall(function() return pawn:GetClass() end)
    local classAddress = (okClass and class and class:IsValid()) and class:GetAddress() or 0
    local controller = pc
    if not (controller and controller:IsValid()) then
        local ok, own = pcall(function() return pawn.Controller end)
        controller = (ok and own and own:IsValid()) and own or nil
    end
    local pcAddress = controller and controller:GetAddress() or 0
    if component and component.pcAddress == pcAddress and component.classAddress == classAddress
       and component.object:IsValid() then
        return component.object
    end
    if searchedAt and os.clock() - searchedAt < SEARCH_AGAIN then return nil end
    local wanted = { [pawn:GetAddress()] = true }
    if pcAddress ~= 0 then wanted[pcAddress] = true end
    if pc and pc:IsValid() then wanted[pc:GetAddress()] = true end
    local others = {}
    -- IsValid before GetOuter, not after: FindAllOf hands back everything in the object array, a
    -- component that is being destroyed included, and touching a freed one is an access violation inside
    -- UE4SS that pcall does not catch (see the IsValid rule in CLAUDE.md).
    for _, c in ipairs(FindAllOf("FalconCharacterInputComponent") or {}) do
        local okValid, valid = pcall(function() return c:IsValid() end)
        if okValid and valid then
            local ok, outer = pcall(function() return c:GetOuter() end)
            if ok and outer and outer:IsValid() then
                if wanted[outer:GetAddress()] then
                    component = { pcAddress = pcAddress, classAddress = classAddress, object = c }
                    searchedAt = nil
                    local named, name = pcall(function() return c:GetClass():GetFName():ToString() end)
                    log("input: driving %s", named and name or "an unnamed input component")
                    return c
                end
                local okName, outerName = pcall(function() return outer:GetFullName() end)
                if okName and #others < 3 then others[#others + 1] = outerName end
            end
        end
    end
    searchedAt = os.clock()
    if not warned then
        warned = true
        log("input: no FalconCharacterInputComponent on the pawn or its controller; found these instead: %s",
            #others > 0 and table.concat(others, ", ") or "none at all")
    end
    return nil
end

local function call(c, event, value)
    if missing[event] then return end
    local ok, err = pcall(function() c[event](c, value) end)
    if not ok then
        missing[event] = true
        log("input: %s unavailable on this character: %s", event, tostring(err))
    end
end

-- Sets the axes held from now on. Axes left out go back to 0.
function input.hold(values)
    axes = {}
    for key, value in pairs(values or {}) do
        if input.AXES[key] then axes[key] = value else log("input: no axis %q", tostring(key)) end
    end
end

function input.press(button)
    if input.BUTTONS[button] then buttons[button] = true else log("input: no button %q", tostring(button)) end
end

function input.release(button)
    buttons[button] = nil
end

function input.held(button)
    return buttons[button] == true
end

local function setProp(c, prop, value)
    if axisPropMissing[prop] then return end
    local ok = pcall(function() c[prop] = value end)
    if not ok then
        axisPropMissing[prop] = true
        log("input: %s not writable on this character; charge/mouse steering from a script may not work", prop)
    end
end

-- The left stick sent exactly as the engine's own input tick sends it, for a replay that must consume
-- the same movement input as its recording. On the ground, CharacterInputComponent_Spyro's stick events
-- each store their axis and call RequestGroundMovement, which adds ONE vector from BOTH stored axes:
-- AddMovementInput(Normal(fwd * sign(Y) + right * sign(X)), |(X, Y)|), skipped when both are <= 0.1
-- (bytecode offset 31522; in the air they add right * X and fwd * Y instead). The engine fires X before Y,
-- so a frame consumes |(x_k, y_(k-1))| + |(x_k, y_k)|: a W press 1.0, a W release 1.0, an A press 2.0
-- straight away. Firing the events from Lua (in pairs() order, Y first) with stored Y left set gave X 1.0
-- and Y 3.0 instead, the extra 1.0 being the engine's own zero-valued X event adding |(0, stored Y)|
-- (2026-11-16, docs/probe.md). So: stored Y = the previous frame's Y, fire X, fire Y, and then zero both
-- stored axes so the engine's own zero events add nothing. Not for a charge, which reads the stored stick
-- during its tick (tools/replay.lua forces it through a hook instead).
function input.sendLeftStick(pawn, pc, x, y, prevY)
    local c = find(pawn, pc)
    if not c then return false end
    setProp(c, input.AXIS_PROPS.leftY, prevY or 0)
    call(c, input.AXES.leftX, x or 0)
    call(c, input.AXES.leftY, y or 0)
    setProp(c, input.AXIS_PROPS.leftX, 0)
    setProp(c, input.AXIS_PROPS.leftY, 0)
    return true
end

-- Sends this frame's input. Call once per frame while a scripted run is going. `skip` (optional) is a set
-- of axis keys this call leaves alone -- neither event nor stored value -- for a caller that sends them
-- itself (tools/replay.lua sends the left stick through input.sendLeftStick).
function input.apply(pawn, pc, skip)
    local c = find(pawn, pc)
    if not c then return false end
    for key, event in pairs(input.AXES) do
        if not (skip and skip[key]) then call(c, event, axes[key] or 0) end
    end
    -- Also set the stored axis value, for the Blueprint logic that reads it rather than the movement
    -- input vector (the charge turn above all). Written after the event so it wins over a native zero.
    for key, prop in pairs(input.AXIS_PROPS) do
        if skip and skip[key] then
            -- the caller sends this one
        elseif not axisPropMissing[prop] then
            local ok = pcall(function() c[prop] = axes[key] or 0 end)
            if not ok then
                axisPropMissing[prop] = true
                log("input: %s not writable on this character; charge/mouse steering from a script may not work", prop)
            end
        end
    end
    for key, event in pairs(input.BUTTONS) do
        local want = buttons[key] == true
        if sent[key] ~= want then
            sent[key] = want
            call(c, event, want)
        end
    end
    return true
end

-- Releases everything: a button left pressed would stay pressed for the player. The component is kept
-- (input.forget drops it): this is called every frame by the tour's death and verify phases, and
-- dropping it there cost a full object-array walk per frame.
function input.clear(pawn, pc)
    axes, buttons = {}, {}
    if pawn and pawn:IsValid() then input.apply(pawn, pc) end
    sent = {}
end

-- The character's input component, for tools that read the raw axes off it (tools/replay.lua).
-- The same cached lookup input.apply uses; nil while there is no component to drive.
function input.component(pawn, pc)
    return find(pawn, pc)
end

-- Drop the cached component. Nothing needs this during a run -- the cache notices a new controller or a
-- new character class by itself -- but a tool that has finished with the character can say so.
function input.forget()
    component, searchedAt, warned = nil, nil, false
end

return input
