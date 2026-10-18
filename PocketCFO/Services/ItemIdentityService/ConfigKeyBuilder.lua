-- PocketCFO/Services/ItemIdentityService/ConfigKeyBuilder.lua
-- Builds canonical, opaque PocketCFO item identity keys.

local PocketCFO = _G.PocketCFO

local ConfigKeyBuilder = {}

local function NonEmpty(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return tostring(value)
end

local function NumberPart(value)
    local number = tonumber(value)
    if number then
        return tostring(number)
    end
    return nil
end

local function EscapePart(value)
    value = NonEmpty(value)
    if not value then
        return nil
    end
    value = value:gsub("%%", "%%25")
    value = value:gsub("|", "%%7C")
    value = value:gsub(":", "%%3A")
    return value
end

local function AddPart(parts, key, value)
    value = EscapePart(value)
    if value then
        parts[#parts + 1] = key .. ":" .. value
    end
end

function ConfigKeyBuilder:Build(identity)
    if type(identity) ~= "table" then
        return nil, "missingIdentity"
    end

    local itemID = NumberPart(identity.itemID)
    if not itemID then
        return nil, "missingItemID"
    end

    local parts = { "pcfo", "item", "v1" }
    AddPart(parts, "id", itemID)

    local matchingPath = NonEmpty(identity.matchingPath) or "itemID"
    AddPart(parts, "path", matchingPath)

    if matchingPath == "itemID_ilvl" or matchingPath == "itemID_ilvl_stat" then
        AddPart(parts, "ilvl", NumberPart(identity.effectiveIlvl or identity.effectiveItemLevel or identity.itemLevel or identity.ilvl) or "0")
    end

    if matchingPath == "itemID_ilvl_stat" then
        AddPart(parts, "stat", NonEmpty(identity.statFingerprint) or "none")
    end

    return table.concat(parts, "|")
end

if PocketCFO then
    PocketCFO.ItemIdentityConfigKeyBuilder = ConfigKeyBuilder
end

_G.PocketCFO_ItemIdentityConfigKeyBuilder = ConfigKeyBuilder
