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
-- A conversation that asks the player to pick from a list -- the balloonist asking where to fly, and
-- anything else that puts choices on screen -- is a second widget, UI_DialogueQuestions_C, and Continue
-- on the text box does nothing to it. Marco the Balloonist held the tour in LS101 that way (2026-09-27).
-- Its own Confirm (handle key down, AssetDump --code) takes the answer widget it was given and does:
--
--     this.selected index = questionlist.GetChildIndex(the widget)
--     return reply()      -- HudDialogOptionSelected(selected index) on whoever asked, which closes it
--
-- so the first answer is taken by confirming on questionlist child 0. That is the harmless one -- "Stay
-- here" on a balloonist, rather than being flown to another level in the middle of a stop -- and it is
-- the one the game itself focuses when the question pops (pop the question, default answer).
--
--   "dialogue" lines  each text box pressed through, how many presses it took, and each question answered
local log = require("lib.log")

local dialogue = {}

local PRESS_INTERVAL = 0.4 -- seconds between presses: long enough for the next line to come up
local CONFIRM = "Gamepad_FaceButton_Bottom"
local QUESTIONS = "UI_DialogueQuestions_C"
local FIRST_ANSWER = 0 -- "Stay here" on the balloonist; the first choice on anything else
local KEY_TRIES = 2    -- presses through the widget's key handler before its two steps are called direct

local nextPress = 0
local current = nil -- { address, presses }
local key = nil
local nextAnswer = 0
local answering = nil -- { address, tries } while a question is on screen

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

-- The list of answers, if one is up and waiting to be answered. The test is the widget's own: it only
-- takes Confirm while the question is shown, it has not been answered and it has not closed.
function dialogue.question()
    for _, box in ipairs(FindAllOf(QUESTIONS) or {}) do
        local ok, waiting = pcall(function()
            if not box:IsValid() or box:GetFName():ToString():match("^Default__") then return false end
            if box.closed == true or box["returned reply"] == true then return false end
            return box["question shown"] == true
        end)
        if ok and waiting then return box end
    end
    return nil
end

-- Takes the first answer, by Confirm on the widget for it, as pressing the button does. A key event has
-- to come from the game (Default__FalconHud.CreateKeyEvent), and if it cannot be made -- or the presses
-- are not getting through, which a failed call would not show -- the two steps that Confirm takes are
-- called on the widget instead.
local function takeFirstAnswer(box, tries)
    local ok, first = pcall(function() return box.questionlist:GetChildAt(FIRST_ANSWER) end)
    if not (ok and first and first:IsValid()) then return false, "no answers in the list" end
    if tries <= KEY_TRIES then
        local pressed, err = pcall(function()
            local hud = StaticFindObject("/Script/Falcon.Default__FalconHud")
            local event = hud:CreateKeyEvent({ KeyName = FName(CONFIRM) })
            box["handle key down"](box, event, first)
        end)
        if pressed then return true, "Confirm" end
        if tries == 1 then log("dialogue: Confirm on the answer failed: %s", tostring(err)) end
    end
    local set, err = pcall(function()
        box["selected index"] = FIRST_ANSWER
        box["return reply"](box)
    end)
    if set then return true, "its own reply call" end
    return false, tostring(err)
end

-- Answers the question on screen, at most every PRESS_INTERVAL. Returns true while one is up.
local function answerQuestion()
    local box = dialogue.question()
    if not box then
        if answering then
            log("dialogue: question answered after %d press(es)", answering.tries)
            answering = nil
        end
        return false
    end
    local now = os.clock()
    if now < nextAnswer then return true end
    nextAnswer = now + PRESS_INTERVAL
    local address = box:GetAddress()
    if not answering or answering.address ~= address then
        answering = { address = address, tries = 0 }
        log("dialogue: a question is up; taking the first answer")
    end
    answering.tries = answering.tries + 1
    local ok, how = takeFirstAnswer(box, answering.tries)
    if ok then
        if answering.tries == 1 or how ~= answering.how then
            answering.how = how
            log("dialogue: answering with the first option (%s)", how)
        end
    elseif not answering.failed then
        answering.failed = true
        log("dialogue: taking the first answer failed: %s", tostring(how))
    end
    return true
end

-- Presses Continue on the open box, at most every PRESS_INTERVAL. Returns true while a box is open.
-- A question with answers on screen is dealt with first: Continue does nothing to one.
function dialogue.advance()
    if answerQuestion() then return true end
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
