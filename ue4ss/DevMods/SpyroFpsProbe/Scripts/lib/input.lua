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
-- FaceBottom = A/cross (jump), FaceRight = B/circle (charge), FaceTop = Y/triangle (flame).
input.AXES = {
    leftX = "InputAxis_LeftStick_X", leftY = "InputAxis_LeftStick_Y",
    rightX = "InputAxis_RightStick_X", rightY = "InputAxis_RightStick_Y",
    triggerL = "InputAxis_TriggerLeft", triggerR = "InputAxis_TriggerRight",
}
input.BUTTONS = {
    jump = "InputAction_FaceBottom", charge = "InputAction_FaceRight", flame = "InputAction_FaceTop",
    shoulderL = "InputAction_ShoulderLeft", shoulderR = "InputAction_ShoulderRight",
    triggerL = "InputAction_TriggerLeft", triggerR = "InputAction_TriggerRight",
    stickL = "InputAction_LeftThumbstickButton", stickR = "InputAction_RightThumbstickButton",
}

local axes = {}        -- axis key -> value held this frame
local buttons = {}     -- button key -> true while held
local sent = {}        -- button key -> what the game was last told
local component = nil  -- { pawnAddress, object }
local missing = {}     -- event names this character does not have, logged once
local warned = false   -- the "no input component" line is logged once

-- The character's input component. It is a subobject of the player controller in this game, not of the
-- pawn (lib/row.lua reads it as pc.CharacterInputComponent_Spyro), so both are accepted as its outer.
-- FindAllOf takes the native base class and returns the Blueprint subclasses too, so this works for every
-- playable character; looked up once per pawn.
local function find(pawn, pc)
    local address = pawn:GetAddress()
    if component and component.pawnAddress == address and component.object:IsValid() then
        return component.object
    end
    local wanted = { [address] = true }
    if pc and pc:IsValid() then
        wanted[pc:GetAddress()] = true
        local ok, controller = pcall(function() return pawn.Controller end)
        if ok and controller and controller:IsValid() then wanted[controller:GetAddress()] = true end
    end
    local others = {}
    for _, c in ipairs(FindAllOf("FalconCharacterInputComponent") or {}) do
        local ok, outer = pcall(function() return c:GetOuter() end)
        if ok and outer and outer:IsValid() and c:IsValid() then
            if wanted[outer:GetAddress()] then
                component = { pawnAddress = address, object = c }
                local named, name = pcall(function() return c:GetClass():GetFName():ToString() end)
                log("input: driving %s", named and name or "an unnamed input component")
                return c
            end
            local okName, outerName = pcall(function() return outer:GetFullName() end)
            if okName and #others < 3 then others[#others + 1] = outerName end
        end
    end
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

-- Sends this frame's input. Call once per frame while a scripted run is going.
function input.apply(pawn, pc)
    local c = find(pawn, pc)
    if not c then return false end
    for key, event in pairs(input.AXES) do
        call(c, event, axes[key] or 0)
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

-- Releases everything (a button left pressed would stay pressed for the player) and forgets the pawn.
function input.clear(pawn, pc)
    axes, buttons = {}, {}
    if pawn and pawn:IsValid() then input.apply(pawn, pc) end
    sent, component = {}, nil
end

return input
