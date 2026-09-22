-- Is there ground at a spot? A downward line trace, shared by tools/scan.lua (placing a tour stop where
-- the character won't be dropped into the void) and the world tour (tools/worldtour/drive.lua,
-- stopping a walk before it goes over an edge into the water).
local UEHelpers = require("UEHelpers")
local log = require("lib.log")

local ground = {}

local failed = false

-- The Z of the ground at (x, y), looking from `up` above z down to `down` below it. Returns nil for thin
-- air. When the trace itself isn't available, it returns `z` (so callers carry on unchecked) and says so
-- once.
function ground.zAt(worldContext, x, y, z, up, down)
    local hit = {}
    local ok, blocked = pcall(function()
        return UEHelpers.GetKismetSystemLibrary():LineTraceSingle(worldContext,
            { X = x, Y = y, Z = z + up }, { X = x, Y = y, Z = z - down },
            0 --[[ETraceTypeQuery Visibility]], false, {}, 0 --[[EDrawDebugTrace None]], hit, true,
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0)
    end)
    if not ok then
        if not failed then
            failed = true
            log("ground: LineTraceSingle is unavailable (%s); ground checks are skipped", tostring(blocked))
        end
        return z
    end
    if blocked ~= true then return nil end
    local point = hit.OutHit or hit
    local location = point.Location or point.ImpactPoint
    return location and location.Z or nil
end

return ground
