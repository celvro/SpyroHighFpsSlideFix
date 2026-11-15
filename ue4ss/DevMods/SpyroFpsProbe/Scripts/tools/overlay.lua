-- A UMG text overlay for the replay tool (tools/replay.lua). The game is a Shipping build, where
-- KismetSystemLibrary:PrintString and the on-screen debug text are compiled out, so the only way to
-- draw in the viewport is a real widget. This builds one UserWidget by hand -- a CanvasPanel root with
-- one TextBlock -- and adds it to the viewport, then overlay.set() changes its text and overlay.hide()
-- collapses it.
--
-- Every construction step is logged (overlay: ...) and guarded, because a hand-built widget has several
-- ways to render nothing (no font, no WidgetTree root, a UserWidget that AddToViewport ignores), and
-- the screenshots are the only way to tell which. If the build fails it is not retried.
local log = require("lib.log")

local overlay = {}

local widget, textBlock = nil, nil
local built, failed = false, false
local lastText = nil

-- ESlateVisibility
local VIS_VISIBLE, VIS_COLLAPSED, VIS_HITTEST_INVISIBLE = 0, 1, 3

local function findClass(path)
    local c = StaticFindObject(path)
    if not (c and c:IsValid()) then error("class not found: " .. path) end
    return c
end

-- An FText from a Lua string: FText() global if this build has it, else KismetTextLibrary.
local function ftext(s)
    local ok, t = pcall(function() return FText(s) end)
    if ok and t then return t end
    local lib = StaticFindObject("/Script/Engine.Default__KismetTextLibrary")
    return lib:Conv_StringToText(s)
end

local function build(pc)
    if built then return true end
    if failed then return false end
    local ok, err = pcall(function()
        local world = pc:GetWorld()
        if not (world and world:IsValid()) then error("no world") end
        local UserWidget = findClass("/Script/UMG.UserWidget")
        local WidgetTree = findClass("/Script/UMG.WidgetTree")
        local CanvasPanel = findClass("/Script/UMG.CanvasPanel")
        local TextBlock = findClass("/Script/UMG.TextBlock")

        widget = StaticConstructObject(UserWidget, world)
        if not (widget and widget:IsValid()) then error("UserWidget construct failed") end
        local tree = StaticConstructObject(WidgetTree, widget)
        widget.WidgetTree = tree
        local canvas = StaticConstructObject(CanvasPanel, tree)
        tree.RootWidget = canvas
        textBlock = StaticConstructObject(TextBlock, tree)

        -- A dark, auto-sizing Border behind the text (it is unreadable over the bright sky otherwise).
        -- Border is a UPanelWidget, so AddChild gives it the text as its content. If any of this is not
        -- available in this build, fall back to the text straight on the canvas, which is known to draw.
        local placed = false
        pcall(function()
            local border = StaticConstructObject(findClass("/Script/UMG.Border"), tree)
            border:SetBrushColor({ R = 0.0, G = 0.0, B = 0.0, A = 0.55 })
            local bslot = canvas:AddChildToCanvas(border)
            bslot:SetAutoSize(true)
            bslot:SetPosition({ X = 40.0, Y = 130.0 })
            border:SetPadding({ Left = 12.0, Top = 6.0, Right = 12.0, Bottom = 6.0 })
            border:AddChild(textBlock)
            placed = true
        end)
        if not placed then
            log("overlay: Border unavailable, text on canvas with no background")
            local slot = canvas:AddChildToCanvas(textBlock)
            pcall(function() slot:SetAutoSize(true) end)
            pcall(function() slot:SetPosition({ X = 48.0, Y = 140.0 }) end)
        end

        -- A hand-built TextBlock has no font set, so give it the engine's Roboto or it draws nothing.
        pcall(function()
            local font = StaticFindObject("/Engine/EngineFonts/Roboto.Roboto")
            if font and font:IsValid() then
                textBlock:SetFont({ FontObject = font, TypefaceFontName = FName("Regular"), Size = 18 })
            end
        end)
        pcall(function()
            textBlock:SetColorAndOpacity({ SpecifiedColor = { R = 0.75, G = 0.95, B = 1.0, A = 1.0 }, ColorUseRule = 0 })
        end)
        textBlock:SetText(ftext("[replay] overlay ready"))

        widget:AddToViewport(10000)
        widget:SetVisibility(VIS_HITTEST_INVISIBLE)
    end)
    if not ok then
        failed = true
        log("overlay: UMG build failed (%s); the menu stays in the console log", tostring(err))
        return false
    end
    built = true
    log("overlay: UMG overlay created and added to the viewport")
    return true
end

-- Show `text` (multi-line, \\n). Builds the widget on first use.
function overlay.set(pc, text)
    if failed then return end
    if not built and not build(pc) then return end
    if not (textBlock and textBlock:IsValid() and widget and widget:IsValid()) then return end
    pcall(function() widget:SetVisibility(VIS_HITTEST_INVISIBLE) end)
    if text ~= lastText then
        lastText = text
        pcall(function() textBlock:SetText(ftext(text)) end)
    end
end

function overlay.hide()
    lastText = nil
    if widget and widget:IsValid() then pcall(function() widget:SetVisibility(VIS_COLLAPSED) end) end
end

return overlay
