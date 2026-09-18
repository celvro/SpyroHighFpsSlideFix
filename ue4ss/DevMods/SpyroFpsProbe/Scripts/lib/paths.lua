-- Output paths, in the deployed mod folder (the traces stay there when the probe is redeployed).
local source = debug.getinfo(1, "S").source
local modDir = source:match("^@(.*)[/\\]Scripts[/\\]") or "."
local stamp = os.date("%Y%m%d_%H%M%S")

return {
    modDir = modDir,
    stamp = stamp,
    trace = string.format("%s\\trace_%s.csv", modDir, stamp),
    thieves = string.format("%s\\thieves_%s.csv", modDir, stamp), -- created with the first active thief
    flames = string.format("%s\\flames_%s.csv", modDir, stamp),   -- created with the first flame
    spots = modDir .. "\\spots.txt",
}
