-- Cached engine handles, plus the frame counters the hooks need (they run outside the tick, so they
-- can't be passed the tick's values).
local UEHelpers = require("UEHelpers")

-- UEHelpers.GetPlayerController() runs FindAllOf("PlayerController") on every call, which is too
-- expensive to do every frame, so keep the controller until it becomes invalid (level change)
-- and only search again every CONTROLLER_RETRY_FRAMES frames while there is none.
local CONTROLLER_RETRY_FRAMES = 30

local engine = {
    frame = 0,   -- engine frames, counted by the tick; hooks use it to act once per frame
    dt = 1 / 60, -- the length of the frame that just finished
}

local cachedController = nil
local controllerRetryIn = 0
local cachedStatics = nil

function engine.getPlayerController()
    if cachedController and cachedController:IsValid() then return cachedController end
    cachedController = nil
    if controllerRetryIn > 0 then
        controllerRetryIn = controllerRetryIn - 1
        return nil
    end
    local pc = UEHelpers.GetPlayerController()
    if pc:IsValid() then
        cachedController = pc
    else
        controllerRetryIn = CONTROLLER_RETRY_FRAMES
    end
    return cachedController
end

function engine.getGameplayStatics()
    if not (cachedStatics and cachedStatics:IsValid()) then cachedStatics = UEHelpers.GetGameplayStatics() end
    return cachedStatics
end

function engine.worldDeltaSeconds(context)
    return engine.getGameplayStatics():GetWorldDeltaSeconds(context)
end

return engine
