-- Pressing Continue on an NPC's text box, the way a player does, so a conversation plays out exactly as
-- it would by hand: the text finishes, the next line comes up, a yes/no question takes its default
-- answer, and whatever the conversation starts (a minigame, a flight) starts by itself.
--
-- The box (UI_Dialogue_C, AssetDump --code, 2026-09-22) advances in HandleKeyDown, on a key bound to
-- UI_Confirm (Gamepad_FaceButton_Bottom, SpaceBar, Enter in DefaultInput.ini): the first press shows the
-- rest of the line, the next one moves on, and with a question up it returns the selected reply. The
-- probe's own input goes to the character's input component and never reaches a widget, so this uses
-- the entry the box itself has for a press that does not come from Slate:
--
--     OnMouseButtonDownFromGameInstance(MouseKey):
--         HandleKeyDown(FalconHud.CreateKeyEvent(MouseKey))
--
-- called with the pad's confirm button. Nothing else is touched: no skip flags, no ending the cinematic,
-- no input mode, no HUD. The conversation closes itself and hands the controls back itself.
--
--   "dialogue" lines  each text box pressed through, and how many presses it took
local log = require("lib.log")

local dialogue = {}

local PRESS_INTERVAL = 0.4 -- seconds between presses: long enough for the next line to come up
local CONFIRM = "Gamepad_FaceButton_Bottom"

local nextPress = 0
local current = nil -- { address, presses }
local key = nil

-- The text box on screen, if there is one.
function dialogue.open()
    for _, box in ipairs(FindAllOf("UI_Dialogue_C") or {}) do
        local ok, drawn = pcall(function()
            if not box:IsValid() or box:GetFName():ToString():match("^Default__") then return false end
            if box.closed == true then return false end
            return box:IsVisible() == true
        end)
        if ok and drawn then return box end
    end
    return nil
end

-- Presses Continue on the open box, at most every PRESS_INTERVAL. Returns true while a box is open.
function dialogue.advance()
    local box = dialogue.open()
    if not box then
        if current then
            log("dialogue: text box closed after %d press(es)", current.presses)
            current = nil
        end
        return false
    end
    local now = os.clock()
    if now < nextPress then return true end
    nextPress = now + PRESS_INTERVAL
    local address = box:GetAddress()
    if not current or current.address ~= address then
        if current then log("dialogue: text box closed after %d press(es)", current.presses) end
        current = { address = address, presses = 0 }
        log("dialogue: text box open; pressing Continue")
    end
    key = key or { KeyName = FName(CONFIRM) }
    local ok, err = pcall(function() box:OnMouseButtonDownFromGameInstance(key) end)
    current.presses = current.presses + 1
    if not ok and not current.failed then
        current.failed = true
        log("dialogue: pressing Continue failed: %s", tostring(err))
    end
    return true
end

return dialogue
