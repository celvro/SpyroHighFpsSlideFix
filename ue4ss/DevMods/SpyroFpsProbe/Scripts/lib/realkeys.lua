-- Real key presses, posted to the game window by KeyPipe.ps1 in this mod's folder: the same
-- WM_KEYDOWN / WM_KEYUP a keyboard produces, so they go through Slate to whatever has the focus -- the
-- game, or a conversation's text box -- exactly like the player's own keys.
--
-- The helper is started once (io.popen, write mode) and kept running, so a key reaches the game as soon
-- as its line is written; a PowerShell start per press would land about a second late. It writes
-- keypipe.ready once it has found the window, and realkeys.ready() reads that, so a caller can wait for it
-- before relying on the timing (tools/replay.lua does, in its settle phase).
--
-- Why not call the widget: calling a text box's Blueprint press function from Lua froze the game for good
-- (LS213, 2026-11-18, docs/probe.md), while a posted key closed the same box.
--
--   "realkeys" lines  the helper starting, being ready, and failing
local log = require("lib.log")
local paths = require("lib.paths")

local realkeys = {}

realkeys.SPACE = 32 -- Jump, UI_Confirm and SkipCutscene (DefaultInput.ini)
realkeys.ENTER = 13 -- UI_Confirm only

local SCRIPT = paths.modDir .. "\\KeyPipe.ps1"
local READY = paths.modDir .. "\\keypipe.ready"
local COMMAND = 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' .. SCRIPT .. '"'

local pipe = nil
local isReady = false

-- Starts the helper if it is not running. Returns true when it is (or was just) started.
function realkeys.start()
    if pipe then return true end
    os.remove(READY)
    isReady = false
    local ok, handle = pcall(io.popen, COMMAND, "w")
    if not ok or not handle then
        log("realkeys: could not start %s: %s", SCRIPT, tostring(handle))
        return false
    end
    pipe = handle
    log("realkeys: key helper started")
    return true
end

-- Whether the helper has found the game window and is reading. Cheap after the first true.
function realkeys.ready()
    if not pipe then return false end
    if isReady then return true end
    local f = io.open(READY, "r")
    if not f then return false end
    f:close()
    isReady = true
    log("realkeys: key helper ready")
    return true
end

local function send(line)
    if not pipe then return false end
    local ok = pcall(function()
        assert(pipe:write(line, "\n"))
        assert(pipe:flush())
    end)
    if not ok then
        log("realkeys: key helper is gone; it starts again on the next start()")
        pcall(function() pipe:close() end)
        pipe, isReady = nil, false
    end
    return ok
end

function realkeys.down(vk) return send("d " .. vk) end
function realkeys.up(vk) return send("u " .. vk) end
function realkeys.tap(vk) return send("t " .. vk) end

return realkeys
