-- Every line the mod logs to UE4SS.log carries the mod's original folder name, which is what the
-- verification notes in CLAUDE.md quote and what players are asked to look for.
local PREFIX = "[HighFpsSlidingAndJumpFix] "

return function(fmt, ...)
    print(string.format(PREFIX .. fmt .. "\n", ...))
end
