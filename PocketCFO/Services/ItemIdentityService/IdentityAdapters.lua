-- PocketCFO/Services/ItemIdentityService/IdentityAdapters.lua
-- Converts supported evidence sources into normalized identity facts.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetDetailedItemLevelInfo = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo

local PocketCFO = _G.PocketCFO

local IdentityAdapters = {}

local METADATA_RETRY_DELAYS = { 0.05, 0.15, 0.35 }

local ITEM_CLASS_CONSUMABLE = 0
local ITEM_CLASS_WEAPON = 2
local ITEM_CLASS_ARMOR = 4
local ITEM_CLASS_REAGENT = 5
local ITEM_CLASS_TRADESKILL = 7
local ITEM_CLASS_PROFESSION = 19

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

local function PositiveNumber(value)
    local number = tonumber(value)
    if number and number > 0 then
        return number
    end
    return nil
end

local function NonEmpty(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return value
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return false, nil
    end
    return pcall(fn, ...)
end

local function GetIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function GetResolutionCaches()
    local service = GetIdentityService()
    if service and service.GetResolutionCaches then
        return service:GetResolutionCaches()
    end
    IdentityAdapters.baseFactsByItemID = IdentityAdapters.baseFactsByItemID or {}
    IdentityAdapters.variantFactsByItemLink = IdentityAdapters.variantFactsByItemLink or {}
    IdentityAdapters.requestedItemData = IdentityAdapters.requestedItemData or {}
    IdentityAdapters.metadataRetryByItemKey = IdentityAdapters.metadataRetryByItemKey or {}
    IdentityAdapters.identityDiagnostics = IdentityAdapters.identityDiagnostics or {}
    return {
        baseFactsByItemID = IdentityAdapters.baseFactsByItemID,
        variantFactsByItemLink = IdentityAdapters.variantFactsByItemLink,
        requestedItemData = IdentityAdapters.requestedItemData,
        metadataRetryByItemKey = IdentityAdapters.metadataRetryByItemKey,
        diagnostics = IdentityAdapters.identityDiagnostics,
    }
end

local function Diag(counter, detail)
    local service = GetIdentityService()
    if service and service.RecordResolutionDiagnostic then
        service:RecordResolutionDiagnostic(counter, detail)
        return
    end
    if PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug("[ItemIdentityService] %s%s", tostring(counter), detail and (" " .. tostring(detail)) or "")
    end
end

local function NormalizeBoolean(value)
    if value == true or value == "true" then
        return true
    end
    if value == false or value == "false" then
        return false
    end
    return nil
end

local function ApplyBaseFacts(identity, facts)
    if type(identity) ~= "table" or type(facts) ~= "table" then
        return identity
    end
    identity.itemID = NumberOrNil(identity.itemID) or NumberOrNil(facts.itemID)
    identity.itemName = NonEmpty(identity.itemName) or NonEmpty(facts.itemName)
    identity.itemLink = NonEmpty(identity.itemLink) or NonEmpty(facts.itemLink)
    identity.quality = NumberOrNil(identity.quality) or NumberOrNil(facts.quality or facts.rarityQuality)
    identity.rarityQuality = NumberOrNil(identity.rarityQuality) or NumberOrNil(facts.rarityQuality or facts.quality)
    identity.itemClassID = NumberOrNil(identity.itemClassID) or NumberOrNil(facts.itemClassID or facts.classID)
    identity.itemSubClassID = NumberOrNil(identity.itemSubClassID) or NumberOrNil(facts.itemSubClassID or facts.subClassID)
    identity.equipLoc = NonEmpty(identity.equipLoc) or NonEmpty(facts.equipLoc)
    identity.inventoryType = NonEmpty(identity.inventoryType) or NonEmpty(facts.inventoryType or facts.equipLoc)
    identity.maxStack = NumberOrNil(identity.maxStack) or NumberOrNil(facts.maxStack)
    if identity.isStackable == nil then
        identity.isStackable = NormalizeBoolean(facts.isStackable)
    end
    identity.icon = NumberOrNil(identity.icon) or NumberOrNil(facts.icon)
    identity.iconID = NumberOrNil(identity.iconID) or NumberOrNil(facts.iconID or facts.icon)
    return identity
end

local function ApplyVariantFacts(identity, facts)
    if type(identity) ~= "table" or type(facts) ~= "table" then
        return identity
    end
    identity.effectiveIlvl = NumberOrNil(identity.effectiveIlvl) or NumberOrNil(facts.effectiveIlvl or facts.effectiveItemLevel)
    identity.effectiveItemLevel = NumberOrNil(identity.effectiveItemLevel) or NumberOrNil(facts.effectiveItemLevel or facts.effectiveIlvl)
    identity.statFingerprint = NonEmpty(identity.statFingerprint) or NonEmpty(facts.statFingerprint)
    identity.itemStats = identity.itemStats or facts.itemStats
    identity.rawStatTokens = identity.rawStatTokens or facts.rawStatTokens
    identity.variantStatTokens = identity.variantStatTokens or facts.variantStatTokens
    identity.craftingQuality = NumberOrNil(identity.craftingQuality) or NumberOrNil(facts.craftingQuality)
    identity.itemQuality = NumberOrNil(identity.itemQuality) or NumberOrNil(facts.itemQuality or facts.craftingQuality)
    return identity
end

local function ItemIDFromLink(itemLink)
    if not itemLink then
        return nil
    end
    if GetItemInfoFromHyperlink then
        local ok, itemID = SafeCall(GetItemInfoFromHyperlink, itemLink)
        if ok and itemID then
            return NumberOrNil(itemID)
        end
    end
    return NumberOrNil(tostring(itemLink):match("item:(%d+)"))
end

local VARIANT_STAT_ALLOWLIST = {
    ITEM_MOD_CRIT_RATING_SHORT = true,
    ITEM_MOD_HASTE_RATING_SHORT = true,
    ITEM_MOD_MASTERY_RATING_SHORT = true,
    ITEM_MOD_VERSATILITY = true,
    ITEM_MOD_VERSATILITY_RATING_SHORT = true,
    ITEM_MOD_FINESSE_SHORT = true,
    ITEM_MOD_INGENUITY_SHORT = true,
    ITEM_MOD_MULTICRAFT_SHORT = true,
    ITEM_MOD_RESOURCEFULNESS_SHORT = true,
    ITEM_MOD_CRAFTING_SPEED_SHORT = true,
    ITEM_MOD_DEFTNESS_SHORT = true,
    ITEM_MOD_PERCEPTION_SHORT = true,
}

local VARIANT_STAT_ALIASES = {
    ITEM_MOD_VERSATILITY_RATING_SHORT = "ITEM_MOD_VERSATILITY",
}

local function NormalizeVariantStatToken(value)
    value = tostring(value or ""):match("^%s*(.-)%s*$")
    if value == "" then
        return nil
    end
    value = value:gsub("[^A-Z0-9_]", "")
    value = VARIANT_STAT_ALIASES[value] or value
    if VARIANT_STAT_ALLOWLIST[value] then
        return value
    end
    return nil
end

local function BuildFilteredVariantFingerprint(rawTokens)
    local seen = {}
    local filtered = {}
    for _, rawToken in ipairs(rawTokens or {}) do
        local token = NormalizeVariantStatToken(rawToken)
        if token and not seen[token] then
            seen[token] = true
            filtered[#filtered + 1] = token
        end
    end
    table.sort(filtered)
    if #filtered == 0 then
        return nil, filtered
    end
    return table.concat(filtered, "|"), filtered
end

local function SplitStatFingerprint(value)
    local tokens = {}
    if value == nil or tostring(value) == "" then
        return tokens
    end
    for token in string.gmatch(tostring(value), "([^|]+)") do
        tokens[#tokens + 1] = token
    end
    return tokens
end

local function GetItemStatsAndFingerprint(itemLink)
    if not itemLink or not C_Item or type(C_Item.GetItemStats) ~= "function" then
        return nil, nil, {}, {}
    end

    Diag("api.C_Item.GetItemStats", "itemLink=" .. tostring(itemLink))
    local ok, stats = SafeCall(C_Item.GetItemStats, itemLink)
    if not ok or type(stats) ~= "table" then
        return nil, nil, {}, {}
    end

    local keys = {}
    for statKey in pairs(stats) do
        keys[#keys + 1] = tostring(statKey)
    end
    table.sort(keys)
    local fingerprint, filtered = BuildFilteredVariantFingerprint(keys)
    return stats, fingerprint, keys, filtered
end

local function GetDetailedItemLevel(itemRef)
    if not itemRef then
        return nil
    end
    if C_Item and type(C_Item.GetDetailedItemLevelInfo) == "function" then
        Diag("api.C_Item.GetDetailedItemLevelInfo", "itemRef=" .. tostring(itemRef))
        local ok, ilvl = SafeCall(C_Item.GetDetailedItemLevelInfo, itemRef)
        if ok and PositiveNumber(ilvl) then
            return PositiveNumber(ilvl)
        end
    end
    if GetDetailedItemLevelInfo then
        Diag("api.GetDetailedItemLevelInfo", "itemRef=" .. tostring(itemRef))
        local ok, ilvl = SafeCall(GetDetailedItemLevelInfo, itemRef)
        if ok and PositiveNumber(ilvl) then
            return PositiveNumber(ilvl)
        end
    end
    return nil
end

local function GetCraftingQuality(itemRef)
    if not itemRef or not C_TradeSkillUI then
        return nil
    end

    local apis = {
        "GetItemCraftedQualityByItemInfo",
        "GetItemReagentQualityByItemInfo",
    }
    for _, apiName in ipairs(apis) do
        local api = C_TradeSkillUI[apiName]
        if type(api) == "function" then
            Diag("api.C_TradeSkillUI." .. apiName, "itemRef=" .. tostring(itemRef))
            local ok, quality = SafeCall(api, itemRef)
            quality = ok and PositiveNumber(quality) or nil
            if quality then
                return quality
            end
        end
    end
    return nil
end

local function RequestItemDataOnce(itemRef, itemID)
    local caches = GetResolutionCaches()
    local requested = caches.requestedItemData or {}
    local key = itemID and ("itemID:" .. tostring(itemID)) or itemRef and ("itemRef:" .. tostring(itemRef)) or nil
    if not key or requested[key] then
        return requested[key] == true
    end

    requested[key] = true
    Diag("api.itemDataRequest", key)

    if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" and itemID then
        SafeCall(C_Item.RequestLoadItemDataByID, itemID)
        return true
    end
    if C_Item and type(C_Item.RequestLoadItemData) == "function" and itemRef then
        SafeCall(C_Item.RequestLoadItemData, itemRef)
        return true
    end
    return true
end

local BuildBaseFacts

local function MetadataRetryKey(itemRef, itemID)
    itemID = NumberOrNil(itemID)
    if itemID then
        return "itemID:" .. tostring(itemID)
    end
    if itemRef then
        return "itemRef:" .. tostring(itemRef)
    end
    return nil
end

local function MergeBaseFacts(currentFacts, refreshedFacts)
    if type(refreshedFacts) ~= "table" then
        return currentFacts
    end
    local merged = type(currentFacts) == "table" and currentFacts or {}
    for key, value in pairs(refreshedFacts) do
        if value ~= nil then
            merged[key] = value
        end
    end
    if refreshedFacts.pendingItemData ~= true then
        merged.pendingItemData = nil
    end
    return merged
end

local function SchedulePendingItemDataRetry(itemRef, itemID)
    local key = MetadataRetryKey(itemRef, itemID)
    if not key or not C_Timer or type(C_Timer.After) ~= "function" then
        return
    end

    local caches = GetResolutionCaches()
    caches.metadataRetryByItemKey = caches.metadataRetryByItemKey or {}
    local retryState = caches.metadataRetryByItemKey
    if retryState[key] then
        return
    end
    retryState[key] = {
        attempts = 0,
        pending = true,
    }

    for _, delay in ipairs(METADATA_RETRY_DELAYS) do
        C_Timer.After(delay, function()
            local state = retryState[key]
            if not state or state.pending ~= true then
                return
            end
            state.attempts = (state.attempts or 0) + 1

            local refreshedFacts = BuildBaseFacts(itemRef, itemID)
            local refreshedItemID = NumberOrNil(refreshedFacts and refreshedFacts.itemID) or NumberOrNil(itemID)
            local cacheKey = refreshedItemID or NumberOrNil(itemID)
            if cacheKey then
                caches.baseFactsByItemID[cacheKey] = MergeBaseFacts(caches.baseFactsByItemID[cacheKey], refreshedFacts)
            end

            if refreshedItemID and refreshedItemID ~= NumberOrNil(itemID) then
                caches.baseFactsByItemID[refreshedItemID] = MergeBaseFacts(caches.baseFactsByItemID[refreshedItemID], refreshedFacts)
            end

            Diag("identity.pendingItemData.retry", string.format(
                "attempt=%s itemID=%s pending=%s",
                tostring(state.attempts),
                tostring(refreshedItemID or itemID),
                tostring(refreshedFacts and refreshedFacts.pendingItemData == true)
            ))

            if refreshedFacts and refreshedFacts.pendingItemData ~= true then
                state.pending = false
                state.resolved = true
            elseif state.attempts >= #METADATA_RETRY_DELAYS then
                state.pending = false
                state.exhausted = true
            end
        end)
    end
end

function BuildBaseFacts(itemRef, itemID)
    local facts = {
        itemID = NumberOrNil(itemID),
    }

    if GetItemInfoInstant and itemRef then
        local ok, instantID, _, _, equipLoc, icon, itemClassID, itemSubClassID = SafeCall(GetItemInfoInstant, itemRef)
        if ok then
            facts.itemID = facts.itemID or NumberOrNil(instantID)
            facts.equipLoc = NonEmpty(equipLoc)
            facts.inventoryType = NonEmpty(equipLoc)
            facts.itemClassID = NumberOrNil(itemClassID)
            facts.classID = NumberOrNil(itemClassID)
            facts.itemSubClassID = NumberOrNil(itemSubClassID)
            facts.subClassID = NumberOrNil(itemSubClassID)
            facts.icon = NumberOrNil(icon)
            facts.iconID = NumberOrNil(icon)
        end
    end

    local fullInfoRef = facts.itemID or itemRef
    local fullInfoAvailable = false
    if GetItemInfo and fullInfoRef then
        Diag("api.GetItemInfo", "itemRef=" .. tostring(fullInfoRef))
        local ok, itemName, itemLink, rarityQuality, _, _, _, _, maxStack, equipLoc, icon, _, itemClassID, itemSubClassID = SafeCall(GetItemInfo, fullInfoRef)
        if ok and itemName then
            facts.itemName = NonEmpty(itemName)
            facts.itemLink = NonEmpty(itemLink)
            facts.quality = NumberOrNil(rarityQuality)
            facts.rarityQuality = NumberOrNil(rarityQuality)
            facts.equipLoc = facts.equipLoc or NonEmpty(equipLoc)
            facts.inventoryType = facts.inventoryType or NonEmpty(equipLoc)
            facts.itemClassID = facts.itemClassID or NumberOrNil(itemClassID)
            facts.classID = facts.classID or NumberOrNil(itemClassID)
            facts.itemSubClassID = facts.itemSubClassID or NumberOrNil(itemSubClassID)
            facts.subClassID = facts.subClassID or NumberOrNil(itemSubClassID)
            facts.maxStack = NumberOrNil(maxStack)
            facts.isStackable = facts.maxStack and facts.maxStack > 1 or nil
            facts.icon = facts.icon or NumberOrNil(icon)
            facts.iconID = facts.iconID or NumberOrNil(icon)
            facts.fullInfoAvailable = true
            fullInfoAvailable = true
        end
    end
    if not fullInfoAvailable and C_Item and type(C_Item.GetItemInfo) == "function" and fullInfoRef then
        Diag("api.C_Item.GetItemInfo", "itemRef=" .. tostring(fullInfoRef))
        local ok, itemName, itemLink, rarityQuality, _, _, _, _, maxStack, equipLoc, icon, _, itemClassID, itemSubClassID = SafeCall(C_Item.GetItemInfo, fullInfoRef)
        if ok and itemName then
            facts.itemName = NonEmpty(itemName)
            facts.itemLink = NonEmpty(itemLink)
            facts.quality = NumberOrNil(rarityQuality)
            facts.rarityQuality = NumberOrNil(rarityQuality)
            facts.equipLoc = facts.equipLoc or NonEmpty(equipLoc)
            facts.inventoryType = facts.inventoryType or NonEmpty(equipLoc)
            facts.itemClassID = facts.itemClassID or NumberOrNil(itemClassID)
            facts.classID = facts.classID or NumberOrNil(itemClassID)
            facts.itemSubClassID = facts.itemSubClassID or NumberOrNil(itemSubClassID)
            facts.subClassID = facts.subClassID or NumberOrNil(itemSubClassID)
            facts.maxStack = NumberOrNil(maxStack)
            facts.isStackable = facts.maxStack and facts.maxStack > 1 or nil
            facts.icon = facts.icon or NumberOrNil(icon)
            facts.iconID = facts.iconID or NumberOrNil(icon)
            facts.fullInfoAvailable = true
            fullInfoAvailable = true
        end
    end
    if not fullInfoAvailable and fullInfoRef then
        facts.pendingItemData = true
        RequestItemDataOnce(fullInfoRef, facts.itemID)
    end

    return facts
end

local function ApplyCachedBaseFacts(identity)
    local itemID = NumberOrNil(identity.itemID) or (identity.itemLink and ItemIDFromLink(identity.itemLink))
    if not itemID and not identity.itemLink then
        return identity
    end

    local caches = GetResolutionCaches()
    local cache = caches.baseFactsByItemID
    local facts = itemID and cache[itemID] or nil
    if facts then
        Diag("cache.base.hit", "itemID=" .. tostring(itemID))
    else
        Diag("cache.base.miss", "itemID=" .. tostring(itemID or identity.itemLink))
        facts = BuildBaseFacts(identity.itemLink or itemID, itemID)
        itemID = NumberOrNil(facts.itemID) or itemID
        if itemID then
            cache[itemID] = facts
        end
    end

    ApplyBaseFacts(identity, facts)
    if facts and facts.pendingItemData then
        identity.pendingItemData = true
        Diag("identity.pendingItemData", "itemID=" .. tostring(identity.itemID))
        SchedulePendingItemDataRetry(identity.itemLink or itemID, identity.itemID or itemID)
    end
    return identity
end

local function Classification(identity)
    local classID = NumberOrNil(identity and (identity.itemClassID or identity.classID))
    local equipLoc = identity and (identity.equipLoc or identity.inventoryType or identity.itemEquipLoc)
    if equipLoc == "INVTYPE_PROFESSION_TOOL" then
        return "professionTool"
    end
    if equipLoc == "INVTYPE_PROFESSION_GEAR" then
        return "professionAccessory"
    end
    if classID == ITEM_CLASS_WEAPON or classID == ITEM_CLASS_ARMOR then
        return "craftedGear"
    end
    if classID == ITEM_CLASS_REAGENT or classID == ITEM_CLASS_TRADESKILL then
        return "reagent"
    end
    if classID == ITEM_CLASS_CONSUMABLE then
        return "consumable"
    end
    if classID == ITEM_CLASS_PROFESSION then
        return "professionItem"
    end
    return "item"
end

local function ItemLevelRelevant(identity)
    if NumberOrNil(identity.effectiveIlvl or identity.effectiveItemLevel or identity.itemLevel or identity.ilvl) then
        return false
    end
    local classification = Classification(identity)
    return classification == "craftedGear"
        or classification == "professionTool"
        or classification == "professionAccessory"
        or classification == "professionItem"
end

local function StatsRelevant(identity)
    if NonEmpty(identity.statFingerprint or identity.statTarget or identity.statKey) then
        return false
    end
    local classification = Classification(identity)
    return identity.itemLink ~= nil
        and (classification == "craftedGear" or classification == "professionTool")
end

local function CraftingQualityRelevant(identity)
    if NumberOrNil(identity.craftingQuality or identity.itemQuality) then
        return false
    end
    if identity.itemLink == nil then
        return false
    end
    local source = identity.source or identity.evidenceType
    if source == "recipeOutput" or source == "craftResult" then
        return true
    end
    return Classification(identity) == "reagent"
end

local function BuildVariantFacts(identity)
    local facts = {}
    local itemRef = identity.itemLink
    if not itemRef then
        return facts
    end

    if ItemLevelRelevant(identity) then
        local detailedIlvl = GetDetailedItemLevel(itemRef)
        if detailedIlvl then
            facts.effectiveIlvl = detailedIlvl
            facts.effectiveItemLevel = detailedIlvl
        end
    else
        Diag("api.GetDetailedItemLevelInfo.skipped", "itemID=" .. tostring(identity.itemID))
    end

    if StatsRelevant(identity) then
        local itemStats, statFingerprint, rawStatTokens, filteredStatTokens = GetItemStatsAndFingerprint(itemRef)
        facts.itemStats = itemStats
        facts.rawStatTokens = rawStatTokens
        facts.variantStatTokens = filteredStatTokens
        facts.statFingerprint = statFingerprint
    else
        Diag("api.C_Item.GetItemStats.skipped", "itemID=" .. tostring(identity.itemID))
    end

    if CraftingQualityRelevant(identity) then
        local craftingQuality = GetCraftingQuality(itemRef)
        facts.craftingQuality = craftingQuality
        facts.itemQuality = craftingQuality
    else
        Diag("api.craftingQuality.skipped", "itemID=" .. tostring(identity.itemID))
    end

    return facts
end

local function ApplyCachedVariantFacts(identity)
    local itemLink = NonEmpty(identity.itemLink)
    if not itemLink then
        return identity
    end
    local needsVariantFacts = ItemLevelRelevant(identity) or StatsRelevant(identity) or CraftingQualityRelevant(identity)
    local explicitFingerprint = NonEmpty(identity.statFingerprint)

    local caches = GetResolutionCaches()
    local cache = caches.variantFactsByItemLink
    local facts = cache[itemLink]
    if facts then
        Diag("cache.variant.hit", "itemLink=" .. tostring(itemLink))
    elseif needsVariantFacts then
        Diag("cache.variant.miss", "itemLink=" .. tostring(itemLink))
        facts = BuildVariantFacts(identity)
        cache[itemLink] = facts
    else
        Diag("cache.variant.skipped", "itemID=" .. tostring(identity.itemID))
    end

    ApplyVariantFacts(identity, facts)

    explicitFingerprint = explicitFingerprint or NonEmpty(identity.statFingerprint)
    if explicitFingerprint then
        local explicitRaw = SplitStatFingerprint(explicitFingerprint)
        local filteredExplicit, filteredExplicitTokens = BuildFilteredVariantFingerprint(explicitRaw)
        identity.rawStatTokens = #explicitRaw > 0 and explicitRaw or identity.rawStatTokens
        identity.variantStatTokens = filteredExplicitTokens
        identity.statFingerprint = filteredExplicit
        identity.droppedStatFingerprint = explicitFingerprint ~= filteredExplicit and explicitFingerprint or nil
    end
    return identity
end

-- Diagnostic-only: reports the same variant-relevance decisions and raw API
-- results that BuildVariantFacts uses, without gating the API calls behind
-- those decisions, so a diagnostic caller can see whether a missing stat
-- variant is because stats were never considered relevant or because
-- C_Item.GetItemStats returned nothing useful. Does not alter production
-- resolution state (only touches the base-facts cache, same as any other
-- identity resolution would).
function IdentityAdapters:DiagnoseItemLink(itemLink)
    itemLink = NonEmpty(itemLink)
    if not itemLink then
        return nil, "missingItemLink"
    end

    local identity = {
        source = "itemLink",
        evidenceType = "itemLink",
        itemID = ItemIDFromLink(itemLink),
        itemLink = itemLink,
    }
    ApplyCachedBaseFacts(identity)

    local itemLevelRelevant = ItemLevelRelevant(identity)
    local statsRelevant = StatsRelevant(identity)
    local craftingQualityRelevant = CraftingQualityRelevant(identity)

    local itemStats, statFingerprint, itemStatsKeys, filteredStatTokens = GetItemStatsAndFingerprint(itemLink)
    local detailedItemLevel = GetDetailedItemLevel(itemLink)

    return {
        itemID = identity.itemID,
        baseFacts = identity,
        relevance = {
            classification = Classification(identity),
            itemLevelRelevant = itemLevelRelevant,
            statsRelevant = statsRelevant,
            craftingQualityRelevant = craftingQualityRelevant,
            needsVariantFacts = itemLevelRelevant or statsRelevant or craftingQualityRelevant,
        },
        rawAPI = {
            detailedItemLevel = detailedItemLevel,
            itemStats = itemStats,
            itemStatsKeys = itemStatsKeys,
            filteredStatTokens = filteredStatTokens,
            statFingerprint = statFingerprint,
        },
    }
end

local function FillItemInfo(identity)
    if type(identity) ~= "table" then
        return identity
    end
    if identity.itemLink and not identity.itemID then
        identity.itemID = ItemIDFromLink(identity.itemLink)
    end
    ApplyCachedBaseFacts(identity)
    ApplyCachedVariantFacts(identity)
    return identity
end

local function FromRow(row, source)
    if type(row) ~= "table" then
        return nil, "missingEvidence"
    end

    local itemKey = row.itemKey
    local identity = {
        source = source,
        evidenceType = source,
        raw = row,

        configKey = NonEmpty(row.configKey),
        itemID = NumberOrNil(row.itemID or row.itemId or row.id or row.targetItemID or row.outputItemID or row.debugItemID or (type(itemKey) == "table" and itemKey.itemID)),
        itemLink = NonEmpty(row.itemLink or row.link or row.hyperlink or row.itemString or row.outputItemLink),
        itemName = NonEmpty(row.itemName or row.name or row.itemDisplayName or row.outputItemName or row.targetItemName),
        quality = NumberOrNil(row.quality or row.rarityQuality or row.itemRarity),
        craftingQuality = NumberOrNil(row.craftingQuality or row.itemQuality or row.qualityTier),
        itemQuality = NumberOrNil(row.itemQuality or row.craftingQuality or row.qualityTier),
        effectiveIlvl = NumberOrNil(row.effectiveIlvl or row.effectiveItemLevel or row.itemLevel or row.ilvl or row.targetIlvl or (type(itemKey) == "table" and itemKey.itemLevel)),
        effectiveItemLevel = NumberOrNil(row.effectiveItemLevel or row.effectiveIlvl or row.itemLevel or row.ilvl or row.targetIlvl or (type(itemKey) == "table" and itemKey.itemLevel)),
        statFingerprint = NonEmpty(row.statFingerprint or row.statKey or row.statTarget),
        itemClassID = NumberOrNil(row.itemClassID or row.classID),
        itemSubClassID = NumberOrNil(row.itemSubClassID or row.subClassID or row.subclassID),
        equipLoc = NonEmpty(row.equipLoc or row.inventoryType or row.itemEquipLoc),
        inventoryType = NonEmpty(row.inventoryType or row.equipLoc or row.itemEquipLoc),
        isCommodity = NormalizeBoolean(row.isCommodity),
        isStackable = NormalizeBoolean(row.isStackable),
        maxStack = NumberOrNil(row.maxStack),
        itemKey = type(itemKey) == "table" and itemKey or row.auctionItemKey,
        itemLocation = row.itemLocation,
        recipeID = NumberOrNil(row.recipeID),
        auctionID = NumberOrNil(row.auctionID),
        ownerKey = row.ownerKey,
        location = row.location,
        bag = NumberOrNil(row.bag or row.containerID),
        slot = NumberOrNil(row.slot),
    }

    if not identity.itemID and identity.itemLink then
        identity.itemID = ItemIDFromLink(identity.itemLink)
    end

    return FillItemInfo(identity)
end

function IdentityAdapters:FromItemID(itemID)
    itemID = NumberOrNil(itemID)
    if not itemID then
        return nil, "missingItemID"
    end
    return FromRow({ itemID = itemID }, "itemID")
end

function IdentityAdapters:FromItemLink(itemLink)
    itemLink = NonEmpty(itemLink)
    if not itemLink then
        return nil, "missingItemLink"
    end
    return FromRow({ itemLink = itemLink }, "itemLink")
end

function IdentityAdapters:FromBagSlot(bag, slot)
    bag = NumberOrNil(bag)
    slot = NumberOrNil(slot)
    if bag == nil or slot == nil then
        return nil, "missingBagSlot"
    end

    local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot) or nil
    local itemLocation = ItemLocation and ItemLocation.CreateFromBagAndSlot and ItemLocation:CreateFromBagAndSlot(bag, slot) or nil
    local itemLink = info and (info.hyperlink or info.itemLink)

    if not itemLink and itemLocation and C_Item and type(C_Item.GetItemLink) == "function" then
        local ok, link = SafeCall(C_Item.GetItemLink, itemLocation)
        if ok then
            itemLink = link
        end
    end

    return FromRow({
        itemID = info and info.itemID,
        itemLink = itemLink,
        itemName = info and info.itemName,
        itemLocation = itemLocation,
        bag = bag,
        slot = slot,
    }, "bagSlot")
end

function IdentityAdapters:FromRecipeOutput(recipeID, options)
    options = type(options) == "table" and options or {}
    recipeID = NumberOrNil(recipeID or options.recipeID)
    if not recipeID then
        return nil, "missingRecipeID"
    end

    local outputData
    if C_TradeSkillUI and type(C_TradeSkillUI.GetRecipeOutputItemData) == "function" then
        local ok, data = SafeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        if ok and type(data) == "table" then
            outputData = data
        end
    end

    local recipeInfo
    if C_TradeSkillUI and type(C_TradeSkillUI.GetRecipeInfo) == "function" then
        local ok, data = SafeCall(C_TradeSkillUI.GetRecipeInfo, recipeID)
        if ok and type(data) == "table" then
            recipeInfo = data
        end
    end

    local schematic
    if C_TradeSkillUI and type(C_TradeSkillUI.GetRecipeSchematic) == "function" then
        local ok, data = SafeCall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if ok and type(data) == "table" then
            schematic = data
        end
    end

    local row = {
        recipeID = recipeID,
        itemID = options.itemID or options.outputItemID or outputData and outputData.itemID or schematic and schematic.outputItemID or recipeInfo and recipeInfo.outputItemID,
        itemLink = options.itemLink or options.outputItemLink or outputData and outputData.itemLink,
        itemName = options.itemName or options.outputItemName or outputData and (outputData.itemName or outputData.name) or recipeInfo and recipeInfo.name,
        quality = options.quality,
        craftingQuality = options.craftingQuality,
        itemLevel = options.itemLevel or options.ilvl or schematic and schematic.outputItemInfo and schematic.outputItemInfo.itemLevel or outputData and outputData.itemLevel or recipeInfo and recipeInfo.itemLevel,
        statFingerprint = options.statFingerprint or options.statTarget,
    }

    local identity, reason = FromRow(row, "recipeOutput")
    if identity then
        identity.recipeInfo = recipeInfo
        identity.outputData = outputData
        identity.schematic = schematic
    end
    return identity, reason
end

function IdentityAdapters:FromAuctionRow(row)
    return FromRow(row, "auctionRow")
end

function IdentityAdapters:FromOwnedAuctionRow(row)
    return FromRow(row, "ownedAuctionRow")
end

function IdentityAdapters:FromSnapshotRow(row)
    return FromRow(row, "snapshotRow")
end

local function ItemLinkOrIDFromEvidence(evidence)
    local itemLink = NonEmpty(evidence.itemLink or evidence.value)
    local itemID = NumberOrNil(evidence.itemID or evidence.value)
    return itemLink, itemID
end

function IdentityAdapters:FromItemLocationEvidence(evidence)
    local bag = NumberOrNil(evidence.bag or evidence.containerID)
    local slot = NumberOrNil(evidence.slot)

    if (bag == nil or slot == nil) and evidence.itemLocation and ItemLocation and ItemLocation.IsValid then
        local ok, isValid = SafeCall(ItemLocation.IsValid, evidence.itemLocation)
        if ok and isValid and evidence.itemLocation.GetBagAndSlot then
            local okBagSlot, locBag, locSlot = SafeCall(evidence.itemLocation.GetBagAndSlot, evidence.itemLocation)
            if okBagSlot then
                bag = bag or NumberOrNil(locBag)
                slot = slot or NumberOrNil(locSlot)
            end
        end
    end

    if bag ~= nil and slot ~= nil then
        return self:FromBagSlot(bag, slot)
    end

    local itemLink, itemID = ItemLinkOrIDFromEvidence(evidence)
    if not itemLink and evidence.itemLocation and C_Item and type(C_Item.GetItemLink) == "function" then
        local ok, link = SafeCall(C_Item.GetItemLink, evidence.itemLocation)
        if ok then
            itemLink = NonEmpty(link)
        end
    end

    if itemLink then
        return self:FromItemLink(itemLink)
    end
    if itemID then
        return self:FromItemID(itemID)
    end
    return nil, "missingItemLocationTarget"
end

function IdentityAdapters:FromEvidence(evidence)
    if type(evidence) ~= "table" then
        return nil, "missingEvidence"
    end

    local evidenceType = evidence.evidenceType or evidence.source or evidence.type

    if evidenceType == "itemID" or evidenceType == "itemIDFallback" then
        return self:FromItemID(evidence.itemID or evidence.value)
    end
    if evidenceType == "itemLink" or evidenceType == "tooltipItemLink" then
        local itemLink, itemID = ItemLinkOrIDFromEvidence(evidence)
        if itemLink then
            return self:FromItemLink(itemLink)
        end
        if itemID then
            return self:FromItemID(itemID)
        end
        return nil, "missingItemLink"
    end
    if evidenceType == "bagSlot" then
        return self:FromBagSlot(evidence.bag or evidence.containerID, evidence.slot)
    end
    if evidenceType == "itemLocation" then
        return self:FromItemLocationEvidence(evidence)
    end
    if evidenceType == "recipeOutput" then
        return self:FromRecipeOutput(evidence.recipeID, evidence)
    end
    if evidenceType == "ownedAuctionRow" then
        return self:FromOwnedAuctionRow(evidence.row or evidence)
    end
    if evidenceType == "snapshotRow" then
        return self:FromSnapshotRow(evidence.row or evidence)
    end
    if evidenceType == "auctionRow" or evidenceType == "auctionBrowseRow" then
        return self:FromAuctionRow(evidence.row or evidence)
    end
    if evidenceType == "craftResult" then
        return self:FromCraftResult(evidence.row or evidence)
    end
    if evidenceType == "item" or evidenceType == "tooltipData" then
        local itemLink, itemID = ItemLinkOrIDFromEvidence(evidence)
        if itemLink then
            return self:FromItemLink(itemLink)
        end
        if itemID then
            return self:FromItemID(itemID)
        end
        return self:FromItemLocationEvidence(evidence)
    end

    return nil, "unsupportedEvidenceType"
end

function IdentityAdapters:NormalizeVariantStatFingerprint(value)
    local fingerprint = BuildFilteredVariantFingerprint(SplitStatFingerprint(value))
    return fingerprint
end

-- Builds a full identity from a TRADE_SKILL_ITEM_CRAFTED_RESULT event payload.
-- Sets quantity, isStackable, and itemGUID (nil for stackable items) on the identity.
function IdentityAdapters:FromCraftResult(result)
    if type(result) ~= "table" then
        return nil, "missingResult"
    end
    local itemLink = NonEmpty(result.hyperlink or result.itemLink)
    local itemID   = PositiveNumber(result.itemID) or (itemLink and ItemIDFromLink(itemLink))
    if not itemID then
        return nil, "missingItemID"
    end

    local rawQty  = tonumber(result.quantity or result.quantityCrafted or result.numCrafted or result.numItems or result.amount)
    local quantity = (rawQty and rawQty > 0) and rawQty or 1
    local itemGUID = result.itemGUID

    local identity, reason = FromRow({
        itemID          = itemID,
        itemLink        = itemLink,
        itemName        = result.itemName,
        craftingQuality = result.craftingQuality or result.itemQuality,
        statFingerprint = result.statFingerprint,
    }, "craftResult")

    if not identity then
        return nil, reason
    end

    identity.quantity = quantity

    -- Determine stackability: quantity > 1 → stackable; GUID present → not stackable;
    -- otherwise fall back to identity.maxStack if FillItemInfo populated it, then
    -- assume stackable (crafted non-GUID items are always consumables or reagents).
    if quantity > 1 then
        identity.isStackable = true
    elseif identity.maxStack ~= nil then
        identity.isStackable = identity.maxStack > 1
    elseif itemGUID and tostring(itemGUID) ~= "" then
        identity.isStackable = false
    else
        identity.isStackable = true
    end
    identity.itemGUID = identity.isStackable and nil or itemGUID

    return identity
end

-- Returns the crafting quality tier for a reagent.
-- Checks data on the reagent table first, then falls back to the TradeSkillUI API.
function IdentityAdapters:GetReagentCraftingQuality(reagent, itemRef)
    local quality = tonumber(reagent and (reagent.craftingQuality or reagent.quality or reagent.itemQuality))
    if quality and quality > 0 then return quality end
    return GetCraftingQuality(itemRef)
end

local TOOL_MISSIVE_STATS = {
    ["Deftness"]        = "ITEM_MOD_DEFTNESS_SHORT",
    ["Finesse"]         = "ITEM_MOD_FINESSE_SHORT",
    ["Perception"]      = "ITEM_MOD_PERCEPTION_SHORT",
    ["Crafting Speed"]  = "ITEM_MOD_CRAFTING_SPEED_SHORT",
    ["Resourcefulness"] = "ITEM_MOD_RESOURCEFULNESS_SHORT",
    ["Multicraft"]      = "ITEM_MOD_MULTICRAFT_SHORT",
    ["Ingenuity"]       = "ITEM_MOD_INGENUITY_SHORT",
}

local GEAR_MISSIVE_STATS = {
    ["Aurora"]     = "ITEM_MOD_HASTE_RATING_SHORT|ITEM_MOD_VERSATILITY",
    ["Feverflare"] = "ITEM_MOD_HASTE_RATING_SHORT|ITEM_MOD_MASTERY_RATING_SHORT",
    ["Fireflash"]  = "ITEM_MOD_CRIT_RATING_SHORT|ITEM_MOD_HASTE_RATING_SHORT",
    ["Harmonious"] = "ITEM_MOD_MASTERY_RATING_SHORT|ITEM_MOD_VERSATILITY",
    ["Peerless"]   = "ITEM_MOD_CRIT_RATING_SHORT|ITEM_MOD_MASTERY_RATING_SHORT",
    ["Quickblade"] = "ITEM_MOD_CRIT_RATING_SHORT|ITEM_MOD_VERSATILITY",
}

-- Returns the raw stat fingerprint string and missive suffix label for a given item name string.
-- Used by RecipeOptionResolver for UI option building; avoids duplicating the stat tables.
function IdentityAdapters:GetMissiveStatForItemName(itemName)
    itemName = tostring(itemName or "")
    if not itemName:find("Missive", 1, true) then
        return nil, nil
    end

    local gearSuffix = itemName:match("Missive of the (%a+)$")
    if gearSuffix and GEAR_MISSIVE_STATS[gearSuffix] then
        return GEAR_MISSIVE_STATS[gearSuffix], gearSuffix
    end

    local toolSuffix = itemName:match("Missive of (.+)$")
    if toolSuffix and TOOL_MISSIVE_STATS[toolSuffix] then
        return TOOL_MISSIVE_STATS[toolSuffix], toolSuffix
    end

    return nil, nil
end

function IdentityAdapters:GetMissiveStatFingerprint(optionalSlots)
    for _, slotEntry in pairs(optionalSlots or {}) do
        if slotEntry and slotEntry.itemID then
            local itemName = GetItemInfo and GetItemInfo(slotEntry.itemID) or nil
            if itemName and itemName:find("Missive", 1, true) then
                local gearSuffix = itemName:match("Missive of the (%a+)$")
                if gearSuffix then
                    return self:NormalizeVariantStatFingerprint(GEAR_MISSIVE_STATS[gearSuffix])
                end

                local toolSuffix = itemName:match("Missive of (.+)$")
                if toolSuffix then
                    return self:NormalizeVariantStatFingerprint(TOOL_MISSIVE_STATS[toolSuffix])
                end
            end
        end
    end
    return nil
end

local TARGET_ILVL_SOURCE_HYPERLINK_DETAILED_ILVL = "HYPERLINK_DETAILED_ILVL"
local TARGET_ILVL_SOURCE_RECIPE_INFO_FALLBACK = "RECIPE_INFO_FALLBACK"
local TARGET_ILVL_SOURCE_OTHER_FALLBACK = "OTHER_FALLBACK"
local MIDNIGHT_EXPANSION_ID = 12
local MIDNIGHT_MAX_TARGET_ILVL = 400

function IdentityAdapters:NormalizeCraftingQualityTier(recipeInfo, rawCraftingQuality)
    local quality = tonumber(rawCraftingQuality)
    local maxQuality = tonumber(recipeInfo and recipeInfo.maxQuality) or 0

    if not quality or maxQuality <= 0 then
        return nil
    end
    if quality >= 1 and quality <= maxQuality and math.floor(quality) == quality then
        return quality
    end
    if recipeInfo and recipeInfo.qualityIDs then
        for tier = 1, maxQuality do
            if tonumber(recipeInfo.qualityIDs[tier]) == quality then
                return tier
            end
        end
    end
    return nil
end

local function IsSaneRecipeItemLevel(itemLevel, expansionID)
    local ilvl = tonumber(itemLevel)
    if not ilvl or ilvl <= 0 then
        return false
    end
    if tonumber(expansionID) == MIDNIGHT_EXPANSION_ID and ilvl > MIDNIGHT_MAX_TARGET_ILVL then
        return false
    end
    return true
end

function IdentityAdapters:ResolveRecipeTargetIlvl(recipeInfo, currentRecipeInfo, schematicInfo, operationInfo, expansionID)
    local outputItemID = schematicInfo and schematicInfo.outputItemID
        or recipeInfo and recipeInfo.outputItemID
    local hyperlink = currentRecipeInfo and currentRecipeInfo.hyperlink
        or recipeInfo and recipeInfo.hyperlink
    local recipeItemLevel = recipeInfo and recipeInfo.itemLevel
    local baseItemLevel = GetDetailedItemLevel(hyperlink)
    local targetIlvlSource = baseItemLevel and TARGET_ILVL_SOURCE_HYPERLINK_DETAILED_ILVL or nil

    if not baseItemLevel and IsSaneRecipeItemLevel(recipeItemLevel, expansionID) then
        baseItemLevel = tonumber(recipeItemLevel)
        targetIlvlSource = TARGET_ILVL_SOURCE_RECIPE_INFO_FALLBACK
    end
    targetIlvlSource = targetIlvlSource or TARGET_ILVL_SOURCE_OTHER_FALLBACK

    local baseDiag = {
        outputItemID = outputItemID,
        hyperlinkUsed = hyperlink,
        hyperlinkResolvedBaseIlvl = targetIlvlSource == TARGET_ILVL_SOURCE_HYPERLINK_DETAILED_ILVL and baseItemLevel or nil,
        recipeItemLevel = recipeItemLevel,
        baseItemLevelUsed = baseItemLevel,
        expansionID = expansionID,
        targetIlvlSource = targetIlvlSource,
    }

    local function BuildDiag(rawCraftingQuality, normalizedCraftingQuality, lookupCraftingQuality, targetIlvl, targetItemID, fallbackReason)
        local warnings = {}
        if tonumber(targetIlvl) and tonumber(targetIlvl) > 700 then
            table.insert(warnings, "targetIlvl > 700")
        end
        if tonumber(expansionID) == MIDNIGHT_EXPANSION_ID
        and tonumber(targetIlvl) and tonumber(targetIlvl) > MIDNIGHT_MAX_TARGET_ILVL then
            table.insert(warnings, "Midnight targetIlvl > 400")
        end
        if rawCraftingQuality and not normalizedCraftingQuality then
            table.insert(warnings, "rawCraftingQuality did not resolve to a quality tier")
        end

        return {
            rawCraftingQuality = rawCraftingQuality,
            normalizedCraftingQuality = normalizedCraftingQuality,
            lookupCraftingQualityUsed = lookupCraftingQuality,
            selectedQualityItemID = lookupCraftingQuality and recipeInfo and recipeInfo.qualityItemIDs and recipeInfo.qualityItemIDs[lookupCraftingQuality] or nil,
            selectedQualityIlvlBonus = lookupCraftingQuality and recipeInfo and recipeInfo.qualityIlvlBonuses and recipeInfo.qualityIlvlBonuses[lookupCraftingQuality] or nil,
            baseItemLevelUsed = baseDiag.baseItemLevelUsed,
            targetIlvlSource = baseDiag.targetIlvlSource,
            outputItemID = baseDiag.outputItemID,
            hyperlinkUsed = baseDiag.hyperlinkUsed,
            hyperlinkResolvedBaseIlvl = baseDiag.hyperlinkResolvedBaseIlvl,
            recipeItemLevel = baseDiag.recipeItemLevel,
            expansionID = baseDiag.expansionID,
            resolvedTargetIlvl = targetIlvl,
            resolvedTargetItemID = targetItemID,
            fallbackReason = fallbackReason,
            warnings = warnings,
        }
    end

    if not recipeInfo or not recipeInfo.supportsQualities or (recipeInfo.maxQuality or 0) == 0 then
        return baseItemLevel, nil, BuildDiag(nil, nil, nil, baseItemLevel, nil, "no quality support")
    end

    local rawCraftingQuality = operationInfo and operationInfo.craftingQuality
    local craftingQuality = self:NormalizeCraftingQualityTier(recipeInfo, rawCraftingQuality)
    if not craftingQuality then
        return baseItemLevel, nil, BuildDiag(rawCraftingQuality, nil, nil, baseItemLevel, nil, "unresolved craftingQuality")
    end

    if recipeInfo.qualityItemIDs and recipeInfo.qualityItemIDs[craftingQuality] then
        local tierItemID = recipeInfo.qualityItemIDs[craftingQuality]
        local getItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local _, _, _, ilvl = getItemInfo(tierItemID)
        if ilvl then
            if tonumber(expansionID) == MIDNIGHT_EXPANSION_ID and ilvl > MIDNIGHT_MAX_TARGET_ILVL then
                return nil, tierItemID, BuildDiag(rawCraftingQuality, craftingQuality, craftingQuality, nil, tierItemID, "Midnight qualityItemID ilvl > 400")
            end
            return ilvl, tierItemID, BuildDiag(rawCraftingQuality, craftingQuality, craftingQuality, ilvl, tierItemID, nil)
        end
    end

    if recipeInfo.qualityIlvlBonuses and recipeInfo.qualityIlvlBonuses[craftingQuality] and baseItemLevel then
        local bonus = recipeInfo.qualityIlvlBonuses[craftingQuality]
        local ilvl = baseItemLevel + bonus
        if tonumber(expansionID) == MIDNIGHT_EXPANSION_ID and ilvl > MIDNIGHT_MAX_TARGET_ILVL then
            return nil, nil, BuildDiag(rawCraftingQuality, craftingQuality, craftingQuality, nil, nil, "Midnight targetIlvl > 400")
        end
        return ilvl, nil, BuildDiag(rawCraftingQuality, craftingQuality, craftingQuality, ilvl, nil, nil)
    end

    return baseItemLevel, nil, BuildDiag(rawCraftingQuality, craftingQuality, craftingQuality, baseItemLevel, nil, "no quality itemID or ilvl bonus for resolved tier")
end

if PocketCFO then
    PocketCFO.ItemIdentityAdapters = IdentityAdapters
end

_G.PocketCFO_ItemIdentityAdapters = IdentityAdapters
