-- Reading and driving a character's animation: the montage it is playing, how far into it, and which
-- montages its skeleton can play. Used by tools/animtest.lua (which plays every montage at two
-- framerates) and by tools/autotest.lua (which samples what the characters around a stop are playing).
--
-- Montages are matched to a character by SKELETON, not by name: every montage asset loaded in the level
-- whose `Skeleton` is the one the character's mesh uses can be played on it. Path matching is kept as a
-- label only (the folder under Plugins is the character's own token, e.g. CES1035_GreenDruid), because
-- several rhynocs share one skeleton and the folder is the only thing that says whose animation it is.
--
-- Two mesh settings have to be turned off while a montage is measured, or the timing is not the
-- animation's own: MeshComponentUpdateFlag (a character that is not rendered only ticks its montages, or
-- nothing at all) and bEnableUpdateRateOptimizations (URO skips anim ticks for distant characters and
-- interpolates between them, which would look like a framerate difference). anim.hold/anim.release set
-- and restore them.
local util = require("lib.util")

local anim = {}

local ALWAYS_TICK = 0 -- EMeshComponentUpdateFlag::AlwaysTickPoseAndRefreshBones

-- FindAllOf("AnimMontage") over every loaded montage is a full object-array walk, so the catalogue is
-- built once per level and thrown away by anim.forget().
local catalogue = nil -- skeleton address -> { { montage, path, name, length, rateScale } }

local function fullPath(object)
    local ok, full = pcall(function() return object:GetFullName() end)
    if not ok or type(full) ~= "string" then return nil end
    return full:match("^%S+%s+(.+)$") or full
end

function anim.mesh(actor)
    local ok, mesh = pcall(function() return actor.Mesh end)
    if not ok or not mesh or not mesh:IsValid() then return nil end
    return mesh
end

function anim.instance(actor)
    local mesh = anim.mesh(actor)
    if not mesh then return nil end
    local ok, instance = pcall(function() return mesh:GetAnimInstance() end)
    if not ok or not instance or not instance:IsValid() then return nil end
    return instance
end

-- The address of the skeleton this character's mesh animates, which is what decides whether a montage
-- can play on it.
function anim.skeletonAddress(actor)
    local mesh = anim.mesh(actor)
    if not mesh then return nil end
    local ok, address = pcall(function() return mesh.SkeletalMesh.Skeleton:GetAddress() end)
    return ok and address or nil
end

-- Every loaded montage, grouped by the skeleton it belongs to. Built on the first call after a level
-- change (anim.forget).
local function buildCatalogue()
    catalogue = {}
    for _, montage in ipairs(FindAllOf("AnimMontage") or {}) do
        local ok = pcall(function() return montage:IsValid() end) and montage:IsValid()
        local name = ok and montage:GetFName():ToString() or nil
        if name and not name:match("^Default__") then
            local okSkel, address = pcall(function() return montage.Skeleton:GetAddress() end)
            if okSkel and address and address ~= 0 then
                local list = catalogue[address]
                if not list then
                    list = {}
                    catalogue[address] = list
                end
                local okLength, length = pcall(function() return montage.SequenceLength end)
                local okRate, rateScale = pcall(function() return montage.RateScale end)
                -- A montage stops reporting itself as playing when it reaches its blend out, which is
                -- that much before the end of the sequence; without this every montage with a blend out
                -- would look like one that was interrupted.
                local okBlend, blendOut = pcall(function() return montage.BlendOut.BlendTime end)
                list[#list + 1] = {
                    montage = montage,
                    name = name,
                    path = fullPath(montage) or name,
                    -- 0 for a montage whose length this build can't read: tools/animtest.lua gives those
                    -- its own timeout rather than trusting the number.
                    length = (okLength and type(length) == "number") and length or 0,
                    rateScale = (okRate and type(rateScale) == "number") and rateScale or 0,
                    blendOut = (okBlend and type(blendOut) == "number") and blendOut or 0,
                }
            end
        end
    end
    return catalogue
end

-- Forget the catalogue, so the next lookup walks the object array again: montages load and unload with
-- their level.
function anim.forget()
    catalogue = nil
end

-- The montages this character's mesh can play, sorted by name so two passes visit them in one order.
function anim.montagesFor(actor)
    local address = anim.skeletonAddress(actor)
    if not address then return {} end
    if not catalogue then buildCatalogue() end
    local list = catalogue[address] or {}
    local copy = {}
    for index, entry in ipairs(list) do copy[index] = entry end
    table.sort(copy, function(a, b) return a.name < b.name end)
    return copy
end

-- The token in a montage's path that says which character it was made for ("CES1035_GreenDruid" in
-- /CES1035_GreenDruid/Animations/Montages/AM_...), so a shared skeleton's montages can be told apart.
function anim.pathToken(path)
    return path and path:match("^/([^/]+)/") or ""
end

-- Does this montage belong to this class, by its folder? BP_CES1035_GreenDruid_C -> CES1035_GreenDruid.
function anim.belongsTo(path, class)
    local token = anim.pathToken(path)
    if token == "" or not class then return false end
    local core = class:gsub("^BP_", ""):gsub("_C$", "")
    return core:find(token, 1, true) ~= nil or token:find(core, 1, true) ~= nil
end

-- What the character is playing right now. Everything is optional: characters without a Falcon enemy
-- state component (the playable ones, Moneybags, the dragons) just have no state name.
function anim.state(actor, instance)
    instance = instance or anim.instance(actor)
    local s = { montage = "", position = 0, section = "", rate = 0, playing = false }
    if instance then
        local ok, montage = pcall(function() return instance:GetCurrentActiveMontage() end)
        if ok and montage and montage:IsValid() then
            local okName, name = pcall(function() return montage:GetFName():ToString() end)
            s.montage = okName and name or ""
            local okPos, position = pcall(function() return instance:Montage_GetPosition(montage) end)
            s.position = okPos and util.num(position) or 0
            local okSection, section = pcall(function() return instance:Montage_GetCurrentSection(montage):ToString() end)
            s.section = okSection and section or ""
            local okRate, rate = pcall(function() return instance:Montage_GetPlayRate(montage) end)
            s.rate = okRate and util.num(rate) or 0
            local okPlaying, playing = pcall(function() return instance:Montage_IsPlaying(montage) end)
            s.playing = okPlaying and playing or false
        end
    end
    local okRoot, rootMotion = pcall(function() return actor:IsPlayingRootMotion() end)
    s.rootMotion = okRoot and rootMotion or false
    local okState, name = pcall(function() return actor.FalconEnemy:BP_GetCurrentStateName():ToString() end)
    s.enemyState = okState and name or ""
    local okTime, stateTime = pcall(function() return actor.FalconEnemy:GetCurrentStateTime() end)
    s.enemyStateTime = okTime and util.num(stateTime) or 0
    return s
end

-- Make this mesh tick its animation every frame however far away, hidden or dormant the character is,
-- and remember what each setting was. anim.release puts them all back.
--
-- A character the game has no use for yet (the Town Square thief before it is chased) has its mesh tick
-- switched off or its time dilation at 0, and a montage played on it sits at position 0 for ever, which
-- is not a framerate difference but looks like one.
function anim.hold(actor)
    local mesh = anim.mesh(actor)
    if not mesh then return nil end
    local held = { mesh = mesh, actor = actor }
    pcall(function()
        held.updateFlag = mesh.MeshComponentUpdateFlag
        mesh.MeshComponentUpdateFlag = ALWAYS_TICK
    end)
    pcall(function()
        held.uro = mesh.bEnableUpdateRateOptimizations
        mesh.bEnableUpdateRateOptimizations = false
    end)
    pcall(function()
        held.pauseAnims = mesh.bPauseAnims
        mesh.bPauseAnims = false
    end)
    pcall(function()
        held.noSkeletonUpdate = mesh.bNoSkeletonUpdate
        mesh.bNoSkeletonUpdate = false
    end)
    pcall(function()
        held.animRate = mesh.GlobalAnimRateScale
        if held.animRate == 0 then mesh.GlobalAnimRateScale = 1 end
    end)
    pcall(function()
        held.ticking = mesh:IsComponentTickEnabled()
        if not held.ticking then mesh:SetComponentTickEnabled(true) end
    end)
    pcall(function()
        held.dilation = actor.CustomTimeDilation
        if held.dilation == 0 then actor.CustomTimeDilation = 1 end
    end)
    return held
end

function anim.release(held)
    if not held or not held.mesh or not held.mesh:IsValid() then return end
    local mesh = held.mesh
    pcall(function()
        if held.updateFlag ~= nil then mesh.MeshComponentUpdateFlag = held.updateFlag end
        if held.uro ~= nil then mesh.bEnableUpdateRateOptimizations = held.uro end
        if held.pauseAnims ~= nil then mesh.bPauseAnims = held.pauseAnims end
        if held.noSkeletonUpdate ~= nil then mesh.bNoSkeletonUpdate = held.noSkeletonUpdate end
        if held.animRate ~= nil then mesh.GlobalAnimRateScale = held.animRate end
    end)
    pcall(function()
        if held.ticking == false then mesh:SetComponentTickEnabled(false) end
    end)
    pcall(function()
        if held.dilation ~= nil and held.actor:IsValid() then held.actor.CustomTimeDilation = held.dilation end
    end)
end

-- Why a montage might not be advancing, for the log line when one sits still: every setting that stops
-- an animation ticking, plus what the montage itself reports.
function anim.diagnose(actor, instance, montage)
    local parts = {}
    local function add(name, fn)
        local ok, value = pcall(fn)
        parts[#parts + 1] = string.format("%s=%s", name, ok and tostring(value) or "?")
    end
    local mesh = anim.mesh(actor)
    if mesh then
        add("tick", function() return mesh:IsComponentTickEnabled() end)
        add("updateFlag", function() return mesh.MeshComponentUpdateFlag end)
        add("pauseAnims", function() return mesh.bPauseAnims end)
        add("noSkeleton", function() return mesh.bNoSkeletonUpdate end)
        add("animRate", function() return mesh.GlobalAnimRateScale end)
        add("uro", function() return mesh.bEnableUpdateRateOptimizations end)
        add("visible", function() return mesh:IsVisible() end)
    else
        parts[#parts + 1] = "mesh=none"
    end
    add("dilation", function() return actor.CustomTimeDilation end)
    add("hidden", function() return actor:IsHidden() end)
    if instance then
        add("anyMontage", function() return instance:IsAnyMontagePlaying() end)
        add("rate", function() return instance:Montage_GetPlayRate(montage) end)
        add("section", function() return instance:Montage_GetCurrentSection(montage):ToString() end)
        add("rootMode", function() return instance.RootMotionMode end)
    end
    return table.concat(parts, " ")
end

-- Starts a montage from the beginning at rate 1, stopping anything else that is playing. Returns the
-- length the engine reports, or nil when it refused (the wrong skeleton, no anim instance).
function anim.play(instance, montage)
    local ok, length = pcall(function()
        return instance:Montage_Play(montage, 1.0, 0, 0.0, true)
    end)
    if not ok or type(length) ~= "number" or length <= 0 then return nil end
    return length
end

function anim.stop(instance, montage)
    pcall(function() instance:Montage_Stop(0.0, montage) end)
end

return anim
