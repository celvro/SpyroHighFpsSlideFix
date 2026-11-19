-- The player controller, kept between frames.
--
-- UEHelpers.GetPlayerController() is FindAllOf("PlayerController"): a walk of the whole object array on
-- every call, 0.075 ms each in Zephyr (LS213, 2026-11-19). main.lua's sample and lib/resume.lua each asked
-- for it every frame, which was 0.15-0.25 ms of a 4 ms frame (docs/findings/frame-rate-ceiling.md). The fix
-- mod has kept its controller the same way since 2026-09 (its lib/engine.lua).
--
-- The one found is kept while IsValid() holds (a level load frees it; IsValid never dereferences a freed
-- object, see CLAUDE.md), and while there is none the search runs at most every RETRY seconds instead of
-- every frame. Callers get what UEHelpers returns: a controller, or an object whose IsValid() is false.
local UEHelpers = require("UEHelpers")

local controller = {}

local RETRY = 0.25 -- seconds between searches while no valid controller is known

local cached = nil
local nextSearch = 0

function controller.get()
    if cached and cached:IsValid() then return cached end
    local now = os.clock()
    if cached and now < nextSearch then return cached end
    nextSearch = now + RETRY
    cached = UEHelpers.GetPlayerController()
    return cached
end

-- Forget the cached one, so the next get() searches again (a caller that knows the old one is stale).
function controller.forget()
    cached, nextSearch = nil, 0
end

return controller
