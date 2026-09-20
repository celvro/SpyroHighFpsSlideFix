-- Queries on the player pawn that more than one fix needs.
local spyro = {}

-- Out-params and the cached camera below are reused between calls: these run every frame, and a
-- table (or a UE4SS object wrapper) per call is garbage the collector has to sweep up later.
local chargingOut = {}

-- IGetIsCharging (Blueprint) checks the Character.MoveState.Charging gameplay tag. Errors when the
-- pawn doesn't implement it (Spyro 3's other playable characters), so callers pcall this.
function spyro.isCharging(pawn)
    local out = chargingOut
    out.IsCharging = nil -- the reused table must not answer with the last call's value
    local ret = pawn:IGetIsCharging(out)
    if type(out.IsCharging) == "boolean" then return out.IsCharging end
    if type(ret) == "boolean" then return ret end
    error("IGetIsCharging returned no IsCharging value")
end

local function readFollowCamera(pawn)
    return pawn.FollowCamera
end

-- The FollowCamera of the pawn asked about last, kept while both stay valid: two fixes ask for it
-- every frame, and each property read allocates a fresh wrapper.
local cachedPawn, cachedCamera = nil, nil

-- The native FollowCameraComponent, or nil for a pawn that has none.
function spyro.followCamera(pawn)
    if cachedCamera and cachedPawn == pawn:GetAddress() and cachedCamera:IsValid() then return cachedCamera end
    cachedPawn, cachedCamera = nil, nil
    local ok, component = pcall(readFollowCamera, pawn)
    if ok and component and component:IsValid() then
        cachedPawn, cachedCamera = pawn:GetAddress(), component
        return component
    end
    return nil
end

return spyro
