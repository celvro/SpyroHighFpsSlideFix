-- Dumps every reflected property of an object (recursing into structs and arrays) to a text file,
-- and diffs two dumps. Used for the FollowCameraComponent (camdump_*.txt) and the GlobalTransporter.
local log = require("lib.log")
local paths = require("lib.paths")

local MAX_DEPTH = 4       -- struct/array nesting levels to expand
local MAX_ELEMENTS = 16   -- array elements to expand
local MAX_DIFF_LINES = 80
local STOP_CLASSES = { SceneComponent = true, ActorComponent = true, Object = true }
local SKIP_TYPES = {
    DelegateProperty = true, MulticastDelegateProperty = true, MulticastInlineDelegateProperty = true,
    MulticastSparseDelegateProperty = true, MapProperty = true, SetProperty = true, InterfaceProperty = true,
    WeakObjectProperty = true, LazyObjectProperty = true, SoftObjectProperty = true, SoftClassProperty = true,
}

local dump = {}

local function describeValue(v)
    local kind = type(v)
    if kind == "number" then return string.format("%.6g", v) end
    if kind ~= "userdata" then return tostring(v) end
    local ok, valid = pcall(function() return v:IsValid() end)
    if ok and valid == false then return "<null>" end
    for _, method in ipairs({ "GetFullName", "ToString" }) do
        local ok, text = pcall(function() return v[method](v) end)
        if ok and text ~= nil then return tostring(text) end
    end
    return tostring(v)
end

local dumpValue

-- Appends { path, value } for every reflected property of `struct` read from `container`.
local function dumpStruct(struct, container, prefix, depth, out, seen)
    struct:ForEachProperty(function(prop)
        local name = prop:GetFName():ToString()
        if seen then
            if seen[name] then return end
            seen[name] = true
        end
        local ok, err = pcall(function() dumpValue(prop, container[name], prefix .. name, depth, out) end)
        if not ok then out[#out + 1] = { prefix .. name, "<error: " .. tostring(err) .. ">" } end
    end)
end

function dumpValue(prop, value, path, depth, out)
    local kind = prop:GetClass():GetFName():ToString()
    if SKIP_TYPES[kind] then
        out[#out + 1] = { path, "<" .. kind .. ">" }
    elseif kind == "StructProperty" and depth < MAX_DEPTH then
        dumpStruct(prop:GetStruct(), value, path .. ".", depth + 1, out)
    elseif kind == "ArrayProperty" and depth < MAX_DEPTH then
        out[#out + 1] = { path .. ".Num", tostring(value:GetArrayNum()) }
        local inner = prop:GetInner()
        value:ForEach(function(index, element)
            if index > MAX_ELEMENTS then return true end
            dumpValue(inner, element:get(), string.format("%s[%d]", path, index), depth + 1, out)
        end)
    else
        out[#out + 1] = { path, describeValue(value) }
    end
end

-- Every reflected property of the object, from its own class up to (not including) SceneComponent.
-- Returns a list of { path, value }.
function dump.object(obj)
    local out, seen = {}, {}
    local class = obj:GetClass()
    while class and class:IsValid() do
        local className = class:GetFName():ToString()
        if STOP_CLASSES[className] then break end
        out[#out + 1] = { "# class", className }
        dumpStruct(class, obj, "", 0, out, seen)
        class = class:GetSuperStruct()
    end
    return out
end

function dump.write(label, entries)
    local path = string.format("%s\\camdump_%s_%s.txt", paths.modDir, os.date("%Y%m%d_%H%M%S"), label)
    local file = io.open(path, "w")
    if file then
        for _, e in ipairs(entries) do file:write(e[1], " = ", e[2], "\n") end
        file:close()
    end
    log("camdump %s: %d values -> %s", label, #entries, path)
end

function dump.logDiff(before, after, label)
    local old = {}
    for _, e in ipairs(before) do old[e[1]] = e[2] end
    local changed = {}
    for _, e in ipairs(after) do
        if e[1] ~= "# class" and old[e[1]] ~= e[2] then
            changed[#changed + 1] = string.format("%s: %s -> %s", e[1], tostring(old[e[1]]), e[2])
        end
    end
    log("camdump diff %s: %d values changed%s", label, #changed,
        #changed > MAX_DIFF_LINES and string.format(" (first %d shown)", MAX_DIFF_LINES) or "")
    for i = 1, math.min(#changed, MAX_DIFF_LINES) do log("camdump diff %s", changed[i]) end
end

return dump
