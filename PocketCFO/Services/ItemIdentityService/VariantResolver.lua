-- PocketCFO/Services/ItemIdentityService/VariantResolver.lua
-- Resolves meaningful item variant dimensions for identity matching.

local PocketCFO = _G.PocketCFO

local VariantResolver = {}

local function NonEmpty(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return tostring(value)
end

local function HasItemLevel(identity)
    return tonumber(identity and (identity.effectiveIlvl or identity.effectiveItemLevel or identity.itemLevel or identity.ilvl)) ~= nil
end

function VariantResolver:Resolve(identity)
    local classification = identity and identity.classification
    local stat = NonEmpty(identity and (identity.statFingerprint or identity.statTarget or identity.statKey))

    if classification == "commodity" then
        return "commodity"
    end
    if classification == "professionTool" then
        if stat then
            return "itemLevelStat"
        end
        return "itemLevel"
    end
    if classification == "craftedGear" then
        if stat then
            return "itemLevelStat"
        end
        return "itemLevel"
    end
    if classification == "professionAccessory" or classification == "professionItem" then
        return "itemLevel"
    end
    if HasItemLevel(identity) and stat then
        return "itemLevelStat"
    end
    if HasItemLevel(identity) and (classification == "craftedGear" or classification == "professionTool") then
        return "itemLevel"
    end
    return "none"
end

function VariantResolver:MatchingPath(identity)
    local variantType = identity and identity.variantType or self:Resolve(identity)

    if variantType == "itemLevelStat" then
        return "itemID_ilvl_stat"
    end
    if variantType == "itemLevel" then
        return "itemID_ilvl"
    end
    return "itemID"
end

function VariantResolver:NormalizeIdentity(identity)
    if type(identity) ~= "table" then
        return identity
    end

    local classification = identity.classification
    if classification == "professionAccessory" or classification == "professionItem" then
        if identity.statFingerprint ~= nil then
            identity.ignoredStatFingerprint = identity.statFingerprint
        end
        identity.statFingerprint = nil
        identity.variantStatTokens = {}
    end
    return identity
end

if PocketCFO then
    PocketCFO.ItemVariantResolver = VariantResolver
end

_G.PocketCFO_ItemVariantResolver = VariantResolver
