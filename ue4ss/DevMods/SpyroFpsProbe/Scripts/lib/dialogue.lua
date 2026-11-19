-- Pressing Continue on an NPC's text box, the way a player does, so a conversation plays out exactly as
-- it would by hand: the text finishes, the next line comes up, a question takes the answer the game
-- puts the focus on, and whatever the conversation starts (a minigame, a flight) starts by itself.
--
-- The press is a real key: Enter, posted to the game window by the key helper (lib/realkeys.lua,
-- KeyPipe.ps1 in this mod's folder). Enter is UI_Confirm and nothing else
-- (DefaultInput.ini); Space is UI_Confirm too but also Jump, so a Space landing just after a box closed
-- would make Spyro jump. The key goes through Slate to whichever widget has the focus, exactly like a
-- keyboard: the text box (UI_Dialogue_C) and the answer list (UI_DialogueQuestions_C) both take
-- UI_Confirm in their own key handlers, and the game focuses a question's default answer when it pops
-- ("Stay here" on a balloonist, rather than being flown to another level in the middle of a stop).
--
-- Nothing on the widgets is called from Lua. Until 2026-11-18 this pressed by calling the box's
-- OnMouseButtonDownFromGameInstance (and, for a question, its "handle key down" / "return reply"). That
-- froze the game for good once the call worked (it had been failing on a missing out-param): the game
-- thread spun in engine code under UE4SS's new-object dispatch, which runs the mods' NotifyOnNewObject
-- Lua callbacks in the middle of the Lua call that made the box create something. The posted Enter
-- closed the same box and sent Sergeant Tub off his cannon (docs/probe.md).
--
-- The key needs no focus. Presses are PRESS_EVERY apart, the pace of a player reading along.
--
--   "dialogue" lines  each text box or question pressed through, and how many presses it took
local log = require("lib.log")
local realkeys = require("lib.realkeys")

local dialogue = {}

local PRESS_EVERY = 2 -- seconds (os.time, whole seconds) between presses
local QUESTIONS = "UI_DialogueQuestions_C"

local lastPress = nil -- os.time() of the last press
local current = nil   -- { address, kind, presses } of the box or question being pressed through

local function drawn(box, extra)
    local ok, yes = pcall(function()
        if not box:IsValid() or box:GetFName():ToString():match("^Default__") then return false end
        if box.closed == true then return false end
        if extra and not extra(box) then return false end
        return box:IsVisible() == true
    end)
    return ok and yes
end

-- The text box on screen, if there is one.
function dialogue.open()
    for _, box in ipairs(FindAllOf("UI_Dialogue_C") or {}) do
        if drawn(box) then return box end
    end
    return nil
end

-- The list of answers, if one is up and waiting to be answered.
function dialogue.question()
    for _, box in ipairs(FindAllOf(QUESTIONS) or {}) do
        if drawn(box, function(b) return b["returned reply"] ~= true and b["question shown"] == true end) then
            return box
        end
    end
    return nil
end

-- Presses Enter once (see the top of the file). False while the key helper is still starting.
function dialogue.press()
    if not realkeys.start() or not realkeys.ready() then return false end
    return realkeys.tap(realkeys.ENTER)
end

-- Presses Continue on whatever is up, at most every PRESS_EVERY seconds. Returns true while a text box or
-- a question is on screen.
function dialogue.advance()
    local box, kind = dialogue.question(), "question"
    if not box then box, kind = dialogue.open(), "text box" end
    if not box then
        if current then
            log("dialogue: %s closed after %d press(es)", current.kind, current.presses)
            current = nil
        end
        return false
    end
    local address = box:GetAddress()
    if not current or current.address ~= address then
        if current then log("dialogue: %s closed after %d press(es)", current.kind, current.presses) end
        current = { address = address, kind = kind, presses = 0 }
        log("dialogue: %s open; pressing Enter", kind)
    end
    local now = os.time()
    if lastPress and now - lastPress < PRESS_EVERY then return true end
    if dialogue.press() then
        lastPress = now
        current.presses = current.presses + 1
    end
    return true
end

return dialogue
