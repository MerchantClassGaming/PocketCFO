-- PocketCFO_Valuation/Modules/PricingIdentity.lua
-- Builds stable pricing identities and market keys. Rarity is intentionally excluded.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetDetailedItemLevelInfo = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local PricingIdentity = PocketCFO_Valuation:NewModule("PricingIdentity")

local ITEM_CLASS_STACKABLE = "stackable"
local ITEM_CLASS_FIXED_NONSTACKABLE = "fixed-nonstackable"
local ITEM_CLASS_VARIABLE_NONSTACKABLE = "variable-nonstackable"

local function NormalizePositiveNumber(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function GetItemIDFromLink(itemLink)
    if not itemLink then
        return nil
    end

    if GetItemInfoFromHyperlink then
        local ok, itemID = pcall(GetItemInfoFromHyperlink, itemLink)
        if ok and itemID then
            return tonumber(itemID)
        end
    end

    return tonumber(tostring(itemLink):match("item:(%d+)"))
end

local function SafeGetItemInfo(itemRef)
    if not itemRef or not GetItemInfo then
        return nil
    end

    local ok, itemName, itemLink, itemRarity, itemLevel, minLevel, itemType, itemSubType, maxStack, equipLoc, icon, sellPrice, classID, subclassID, bindType, expacID, setID, isCraftingReagent = pcall(GetItemInfo, itemRef)
    if not ok then
        return nil
    end

    return {
        itemName = itemName,
        itemLink = itemLink,
        itemRarity = itemRarity,
        itemLevel = tonumber(itemLevel) or nil,
        maxStack = tonumber(maxStack) or nil,
        equipLoc = equipLoc,
        classID = classID,
        subclassID = subclassID,
        isCraftingReagent = isCraftingReagent,
    }
end

local function SafeGetDetailedItemLevel(itemRef)
    if not itemRef then
        return nil
    end

    local api = GetDetailedItemLevelInfo
    if not api and C_Item then
        api = C_Item.GetDetailedItemLevelInfo
    end
    if type(api) ~= "function" then
        return nil
    end

    local ok, itemLevel = pcall(api, itemRef)
    if ok then
        return NormalizePositiveNumber(itemLevel)
    end
    return nil
end

local function SafeTradeSkillQuality(apiName, itemRef)
    if not itemRef or not C_TradeSkillUI then
        return nil
    end

    local api = C_TradeSkillUI[apiName]
    if type(api) ~= "function" then
        return nil
    end

    local ok, quality = pcall(api, itemRef)
    if ok then
        return NormalizePositiveNumber(quality)
    end
    return nil
end

local function GetQualityTier(itemLink, itemID, seed)
    return NormalizePositiveNumber(seed)
        or SafeTradeSkillQuality("GetItemReagentQualityByItemInfo", itemLink)
        or SafeTradeSkillQuality("GetItemCraftedQualityByItemInfo", itemLink)
        or SafeTradeSkillQuality("GetItemReagentQualityByItemInfo", itemID)
        or SafeTradeSkillQuality("GetItemCraftedQualityByItemInfo", itemID)
end

local function IsStackable(itemID, itemInfo)
    local maxStack = itemInfo and tonumber(itemInfo.maxStack)
    if maxStack ~= nil then
        return maxStack > 1
    end

    itemInfo = SafeGetItemInfo(itemID)
    if itemInfo and itemInfo.maxStack ~= nil then
        return itemInfo.maxStack > 1
    end

    return nil
end

local function GetItemStatsAndFingerprint(itemLink)
    -- Central valuation fingerprint helper. This intentionally matches the
    -- existing PocketCFO scanner/craft format: sorted C_Item.GetItemStats keys.
    if not itemLink or not C_Item or type(C_Item.GetItemStats) ~= "function" then
        return nil, nil
    end

    local ok, stats = pcall(C_Item.GetItemStats, itemLink)
    if not ok or type(stats) ~= "table" then
        return nil, nil
    end

    local keys = {}
    for statKey in pairs(stats) do
        keys[#keys + 1] = statKey
    end
    if #keys == 0 then
        return stats, nil
    end

    table.sort(keys)
    return stats, table.concat(keys, "|")
end

local function LinkHasBonusContext(itemLink)
    local itemString = itemLink and tostring(itemLink):match("item:([^|%]]+)")
    if not itemString then
        return false
    end

    local fields = {}
    for field in string.gmatch(itemString .. ":", "([^:]*):") do
        fields[#fields + 1] = field
    end

    -- Item links store the bonus-id count at field 13 in modern item strings.
    -- Crafted variable-stat gear usually needs those link-level modifiers to be
    -- distinguished. TODO: refine this when Blizzard exposes a direct API flag
    -- for variable-stat crafted equipment/accessories.
    return (tonumber(fields[13]) or 0) > 0
end

local function ClassifyItem(itemID, itemLink, itemInfo, statFingerprint, explicitClass)
    if explicitClass and explicitClass ~= "" then
        if explicitClass == ITEM_CLASS_STACKABLE then
            return explicitClass, true
        end
        return explicitClass, false
    end

    local isStackable = IsStackable(itemID, itemInfo)
    if isStackable == true then
        return ITEM_CLASS_STACKABLE, true
    end
    if isStackable == nil then
        -- TODO: Some item data is unavailable until the client cache resolves.
        -- Callers may retry after GET_ITEM_INFO_RECEIVED if a nil market key is
        -- not acceptable for their workflow.
        return nil, nil
    end

    if statFingerprint and tostring(statFingerprint) ~= "" and (not itemLink or LinkHasBonusContext(itemLink)) then
        return ITEM_CLASS_VARIABLE_NONSTACKABLE, false
    end

    return ITEM_CLASS_FIXED_NONSTACKABLE, false
end

local function NormalizeIdentityInput(input)
    if type(input) == "table" then
        return input
    end
    if type(input) ~= "string" then
        return nil
    end
    if input:find("item:", 1, true) then
        return { itemLink = input }
    end
    return { marketKey = input }
end

local function BuildIdentity(itemLink, itemID, overrides)
    overrides = overrides or {}
    itemID = tonumber(itemID) or GetItemIDFromLink(itemLink)
    if not itemID then
        return nil
    end

    local linkInfo = SafeGetItemInfo(itemLink)
    local idInfo = SafeGetItemInfo(itemID)
    local itemInfo = linkInfo or idInfo or {}
    local resolvedLink = itemLink or itemInfo.itemLink

    local itemLevel = NormalizePositiveNumber(overrides.itemLevel)
        or NormalizePositiveNumber(overrides.ilvl)
        or SafeGetDetailedItemLevel(resolvedLink)
        or SafeGetDetailedItemLevel(itemID)
        or NormalizePositiveNumber(itemInfo.itemLevel)

    local qualityTier = GetQualityTier(resolvedLink, itemID,
        overrides.qualityTier or overrides.craftingQuality)

    local itemStats, statFingerprint = GetItemStatsAndFingerprint(resolvedLink)
    statFingerprint = overrides.statFingerprint or statFingerprint

    local itemClass, isStackable = ClassifyItem(
        itemID,
        resolvedLink,
        itemInfo,
        statFingerprint,
        overrides.itemClass or overrides.classification
    )

    local identity = {
        itemID = itemID,
        itemName = overrides.itemName or itemInfo.itemName,
        qualityTier = qualityTier,
        itemLevel = itemLevel,
        statFingerprint = statFingerprint,
        isStackable = isStackable,
        marketKey = nil,

        itemLink = resolvedLink,
        itemClass = itemClass,
        itemStats = itemStats,
    }

    identity.marketKey = PricingIdentity:BuildMarketKey(identity)
    if not identity.marketKey then
        return nil
    end

    return identity
end

function PricingIdentity.GetStatFingerprint(selfOrItemLink, maybeItemLink)
    local itemLink = maybeItemLink
    if selfOrItemLink ~= PricingIdentity then
        itemLink = selfOrItemLink
    end

    local _, statFingerprint = GetItemStatsAndFingerprint(itemLink)
    return statFingerprint
end

function PricingIdentity.Classify(selfOrIdentity, maybeIdentity)
    local identityOrItemLink = maybeIdentity
    if selfOrIdentity ~= PricingIdentity then
        identityOrItemLink = selfOrIdentity
    end

    local identity = NormalizeIdentityInput(identityOrItemLink)
    if not identity then
        return nil
    end

    local itemLink = identity.itemLink or identity.link
    local itemID = tonumber(identity.itemID) or GetItemIDFromLink(itemLink)
    local itemInfo = SafeGetItemInfo(itemLink) or SafeGetItemInfo(itemID)
    local statFingerprint = identity.statFingerprint
    if statFingerprint == nil and itemLink then
        statFingerprint = PricingIdentity.GetStatFingerprint(itemLink)
    end

    return ClassifyItem(itemID, itemLink, itemInfo, statFingerprint, identity.itemClass or identity.classification)
end

function PricingIdentity.BuildFromItemLink(selfOrItemLink, maybeItemLink)
    local itemLink = maybeItemLink
    if selfOrItemLink ~= PricingIdentity then
        itemLink = selfOrItemLink
    end

    return BuildIdentity(itemLink, nil)
end

function PricingIdentity.BuildFromItemID(selfOrItemID, maybeItemID)
    local itemID = maybeItemID
    if selfOrItemID ~= PricingIdentity then
        itemID = selfOrItemID
    end

    return BuildIdentity(nil, itemID)
end

function PricingIdentity.BuildMarketKey(selfOrIdentity, maybeIdentity)
    local identity = maybeIdentity
    if selfOrIdentity ~= PricingIdentity then
        identity = selfOrIdentity
    end

    identity = NormalizeIdentityInput(identity)
    if not identity then
        return nil
    end
    if identity.marketKey and tostring(identity.marketKey) ~= "" then
        return tostring(identity.marketKey)
    end

    local itemLink = identity.itemLink or identity.link
    local itemID = tonumber(identity.itemID) or GetItemIDFromLink(itemLink)
    if not itemID then
        return nil
    end

    local itemInfo = SafeGetItemInfo(itemLink) or SafeGetItemInfo(itemID)
    local resolvedLink = itemLink or (itemInfo and itemInfo.itemLink)

    local isStackable = identity.isStackable
    local itemClass = identity.itemClass or identity.classification
    if itemClass == nil or isStackable == nil then
        itemClass, isStackable = PricingIdentity.Classify(identity)
    end
    if isStackable == nil then
        return nil
    end

    local keyParts = { tostring(itemID) }
    local qualityTier = NormalizePositiveNumber(identity.qualityTier or identity.craftingQuality)
        or GetQualityTier(resolvedLink, itemID)
    local itemLevel = NormalizePositiveNumber(identity.itemLevel or identity.ilvl)
        or SafeGetDetailedItemLevel(resolvedLink)
        or SafeGetDetailedItemLevel(itemID)
        or NormalizePositiveNumber(itemInfo and itemInfo.itemLevel)

    if qualityTier then
        keyParts[#keyParts + 1] = "q" .. tostring(qualityTier)
    elseif isStackable then
        keyParts[#keyParts + 1] = "q0"
    elseif itemLevel then
        keyParts[#keyParts + 1] = "ilvl" .. tostring(itemLevel)
    else
        return nil
    end

    if not isStackable and itemClass == ITEM_CLASS_VARIABLE_NONSTACKABLE then
        local statFingerprint = identity.statFingerprint
        if statFingerprint == nil and resolvedLink then
            statFingerprint = PricingIdentity.GetStatFingerprint(resolvedLink)
        end
        if not statFingerprint or tostring(statFingerprint) == "" then
            return nil
        end
        keyParts[#keyParts + 1] = "stats:" .. tostring(statFingerprint)
    end

    return table.concat(keyParts, "|")
end

PricingIdentity.ITEM_CLASS_STACKABLE = ITEM_CLASS_STACKABLE
PricingIdentity.ITEM_CLASS_FIXED_NONSTACKABLE = ITEM_CLASS_FIXED_NONSTACKABLE
PricingIdentity.ITEM_CLASS_VARIABLE_NONSTACKABLE = ITEM_CLASS_VARIABLE_NONSTACKABLE
