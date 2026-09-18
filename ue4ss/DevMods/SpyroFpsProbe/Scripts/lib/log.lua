local PREFIX = "[SpyroFpsProbe] "

return function(fmt, ...)
    print(string.format(PREFIX .. fmt .. "\n", ...))
end
