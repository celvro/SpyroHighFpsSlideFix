-- Queries on the player pawn that more than one fix needs.
local spyro = {}

-- IGetIsCharging (Blueprint) checks the Character.MoveState.Charging gameplay tag. Errors when the
-- pawn doesn't implement it (Spyro 3's other playable characters), so callers pcall this.
function spyro.isCharging(pawn)
    local out = {}
    local ret = pawn:IGetIsCharging(out)
    if type(out.IsCharging) == "boolean" then return out.IsCharging end
    if type(ret) == "boolean" then return ret end
    error("IGetIsCharging returned no IsCharging value")
end

local function readFollowCamera(pawn)
    return pawn.FollowCamera
end

-- The native FollowCameraComponent, or nil for a pawn that has none.
function spyro.followCamera(pawn)
    local ok, component = pcall(readFollowCamera, pawn)
    if ok and component and component:IsValid() then return component end
    return nil
end

return spyro
