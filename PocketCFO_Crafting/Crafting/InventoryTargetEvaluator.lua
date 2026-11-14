-- PocketCFO_Crafting/Crafting/InventoryTargetEvaluator.lua
-- Inventory Manager target evaluation engine.
-- Evaluates saved inventory targets against InventoryStateService availability.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local InventoryTargetEvaluator = PocketCFO_Crafting:NewModule("InventoryTargetEvaluator")

local CRAFTING_LOCATIONS = {
    bags = true,
    bank = true,
    warbank = true,
    mail = true,
}

local function DebugTime()
    return debugprofilestop and debugprofilestop() or (GetTime and GetTime() * 1000) or 0
end

local function LogTiming(label, startedAt, extra)
    if not PocketCFO or not PocketCFO.Debug then return end
    local elapsed = DebugTime() - (startedAt or DebugTime())
    if extra and extra ~= "" then
        PocketCFO:Debug("%s elapsed=%.1fms %s", label, elapsed, extra)
    else
        PocketCFO:Debug("%s elapsed=%.1fms", label, elapsed)
    end
end

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function GetInventoryStateService()
    return PocketCFO and (PocketCFO.InventoryStateService or _G.InventoryStateService) or _G.InventoryStateService
end

local function GetItemIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function GetRecipeConfigStore()
    return PocketCFO_Crafting:GetModule("RecipeConfigStore", true)
end

local function NormalizePositiveQuantity(value, fallback)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return fallback or 0
end

local function BuildTargetFieldEvidence(config)
    return {
        evidenceType        = "recipeOutput",
        recipeID            = config.recipeID,
        itemID              = config.targetItemID or config.itemID,
        outputItemID        = config.targetItemID or config.outputItemID or config.itemID,
        itemLink            = config.itemLink or config.outputItemLink,
        itemName            = config.itemName or config.outputItemName or config.targetItemName,
        craftingQuality     = config.craftingQuality or config.itemQuality or config.targetQuality,
        itemQuality         = config.itemQuality or config.craftingQuality or config.targetQuality,
        effectiveIlvl       = config.effectiveIlvl or config.effectiveItemLevel or config.targetIlvl,
        effectiveItemLevel  = config.effectiveItemLevel or config.effectiveIlvl or config.targetIlvl,
        ilvl                = config.targetIlvl,
        targetIlvl          = config.targetIlvl,
        statFingerprint     = config.statFingerprint or config.statTarget,
        statTarget          = config.statTarget,
    }
end

local function BuildTargetEvidence(config)
    if type(config) ~= "table" then
        return nil
    end

    if config.configKey and config.configKey ~= "" then
        return config.configKey
    end

    return BuildTargetFieldEvidence(config)
end

-- Targets saved before the 2026-11-10 identity rule hold the item's old
-- config key (Item_Identity_Unification_Design.md 6.3). Once per target, when
-- the item's data is loaded, the target's identity is worked out again from
-- its own fields; if the old rule gives the saved key, the target moves to the
-- new key and remembers the old one (legacyConfigKey) so copies still saved
-- under it (an unvisited bank or mailbox) keep counting. Not done while item
-- data is still loading: a cold item would build a key without its stats.
local IDENTITY_RULE_VERSION = 2

local function RekeyTarget(config)
    if type(config) ~= "table" or config.identityRuleVersion == IDENTITY_RULE_VERSION then
        return
    end
    local savedKey = config.configKey
    if not savedKey or savedKey == "" then
        return
    end
    local identityService = GetItemIdentityService()
    if not identityService or not identityService.Identify then
        return
    end
    local ok, identity = pcall(identityService.Identify, identityService, BuildTargetFieldEvidence(config))
    if not ok or type(identity) ~= "table" or identity.unresolved or identity.pendingItemData or not identity.configKey then
        return
    end
    if identity.configKey ~= savedKey and identity.legacyConfigKey == savedKey then
        config.legacyConfigKey = savedKey
        config.configKey = identity.configKey
        if type(config.identity) == "table" then
            config.identity.configKey = identity.configKey
        end
        if identityService.RecordLegacyMatch then
            identityService:RecordLegacyMatch()
        end
        SessionLog("InventoryTargetEvaluator: target re-keyed configID=%s old=%s new=%s",
            tostring(config.configID), tostring(savedKey), tostring(identity.configKey))
    end
    config.identityRuleVersion = IDENTITY_RULE_VERSION
end

-- Two availability results for the same item (current key + old key) as one.
local function MergeAvailability(primary, secondary)
    if type(secondary) ~= "table" or (tonumber(secondary.totalQuantity) or 0) <= 0
        and (tonumber(secondary.availableQuantity) or 0) <= 0 then
        return primary
    end
    local merged = {}
    for key, value in pairs(primary or {}) do
        merged[key] = value
    end
    merged.availableQuantity = (tonumber(primary and primary.availableQuantity) or 0) + (tonumber(secondary.availableQuantity) or 0)
    merged.totalQuantity = (tonumber(primary and primary.totalQuantity) or 0) + (tonumber(secondary.totalQuantity) or 0)
    local function Sum(field)
        local out = {}
        for key, value in pairs(primary and primary[field] or {}) do
            out[key] = (tonumber(value) or 0)
        end
        for key, value in pairs(secondary[field] or {}) do
            out[key] = (out[key] or 0) + (tonumber(value) or 0)
        end
        return out
    end
    merged.byLocation = Sum("byLocation")
    merged.byOwner = Sum("byOwner")
    return merged
end

local function ResolveIdentity(evidence)
    if type(evidence) == "string" then
        return evidence, nil
    end

    local identityService = GetItemIdentityService()
    if not identityService or not identityService.Identify then
        return nil, "identityServiceUnavailable"
    end

    local identity = identityService:Identify(evidence)
    if identity and identity.configKey then
        return identity.configKey, identity
    end

    return nil, identity and identity.unresolvedReason or "configKeyUnavailable"
end

local function CacheKeyForEvidence(evidence)
    if type(evidence) == "string" then
        return "key:" .. evidence
    end
    if type(evidence) == "table" then
        if evidence.evidenceType == "itemID" and evidence.itemID then
            return "itemID:" .. tostring(evidence.itemID)
        end
        if evidence.configKey then
            return "key:" .. tostring(evidence.configKey)
        end
    end
    return nil
end

local function GetAvailability(evidence, characterGUID, batchCache)
    local inventoryStateService = GetInventoryStateService()
    if not inventoryStateService or not inventoryStateService.GetAvailability then
        return {
            availableQuantity = 0,
            unresolved = true,
            unresolvedReason = "inventoryStateServiceUnavailable",
        }
    end

    local cacheKey = CacheKeyForEvidence(evidence)
    if batchCache and cacheKey and batchCache.availabilityByEvidence[cacheKey] ~= nil then
        batchCache.availabilityHits = (batchCache.availabilityHits or 0) + 1
        return batchCache.availabilityByEvidence[cacheKey]
    end

    local availability
    if batchCache and batchCache.batchState and inventoryStateService.GetAvailabilityFromState then
        -- Query pre-built state; avoids rebuilding the full aggregated inventory per unique key.
        availability = inventoryStateService:GetAvailabilityFromState(
            batchCache.batchState, evidence, { characterOwnerKey = characterGUID }
        ) or { availableQuantity = 0 }
    else
        availability = inventoryStateService:GetAvailability(evidence, {
            characterOwnerKey = characterGUID,
        }) or { availableQuantity = 0 }
    end

    if batchCache and cacheKey then
        batchCache.availabilityByEvidence[cacheKey] = availability
        batchCache.availabilityMisses = (batchCache.availabilityMisses or 0) + 1
    end
    return availability
end

local function GetTotalOwnedQuantity(config, characterGUID, batchCache)
    RekeyTarget(config)
    local evidence = BuildTargetEvidence(config)
    local configKey, resolved = ResolveIdentity(evidence)
    if not configKey then
        SessionLog("InventoryTargetEvaluator: target unresolved configID=%s recipeID=%s reason=%s",
            tostring(config and config.configID), tostring(config and config.recipeID), tostring(resolved))
        return 0, nil, resolved
    end

    local availability = GetAvailability(configKey, characterGUID, batchCache)
    local oldKey = config and config.legacyConfigKey
    if oldKey and oldKey ~= "" and oldKey ~= configKey then
        availability = MergeAvailability(availability, GetAvailability(oldKey, characterGUID, batchCache))
    end
    return NormalizePositiveQuantity(availability.availableQuantity, 0), configKey, availability
end

local function SumCraftingLocationQuantity(availability)
    local total = 0
    for location, quantity in pairs(availability and availability.byLocation or {}) do
        if CRAFTING_LOCATIONS[location] then
            total = total + NormalizePositiveQuantity(quantity, 0)
        end
    end
    return total
end

local function BuildItemIDEvidence(itemID)
    return {
        evidenceType = "itemID",
        itemID = itemID,
    }
end

local function GetCraftingQuantityForItemID(itemID, characterGUID, batchCache)
    itemID = tonumber(itemID)
    if not itemID then
        return 0
    end

    local availability = GetAvailability(BuildItemIDEvidence(itemID), characterGUID, batchCache)
    return SumCraftingLocationQuantity(availability), availability
end

local function SetItemAvailability(cache, itemID, characterGUID, batchCache)
    itemID = tonumber(itemID)
    if not itemID then
        return 0
    end

    if cache[itemID] == nil then
        cache[itemID] = GetCraftingQuantityForItemID(itemID, characterGUID, batchCache)
    end
    return cache[itemID] or 0
end

local function EvaluateMaterialAvailability(config, characterGUID, deficit, batchCache)
    local availabilityByItemID = {}
    local missingOpts = {}
    local qualMiss = {}

    if not config or not config.matSlots or not next(config.matSlots) then
        return "green", missingOpts, qualMiss, availabilityByItemID
    end

    local craftsNeeded = (deficit and deficit > 0) and deficit or 1
    local allPresent = true
    local anyPresent = true

    for _, qualityEntries in pairs(config.matSlots or {}) do
        if type(qualityEntries) == "table" then
            local totalHave = 0
            local perCraftNeed = 0

            for _, qe in ipairs(qualityEntries) do
                local itemID = tonumber(qe and qe.itemID)
                if itemID then
                    totalHave = totalHave + SetItemAvailability(availabilityByItemID, itemID, characterGUID, batchCache)
                    perCraftNeed = perCraftNeed + (tonumber(qe.quantity) or 1)
                end
            end

            if perCraftNeed > 0 and totalHave < perCraftNeed then
                anyPresent = false
                allPresent = false
            elseif perCraftNeed > 0 and totalHave < perCraftNeed * craftsNeeded then
                allPresent = false
            end
        end
    end

    for _, slotEntry in pairs(config.optionalSlots or {}) do
        local itemID = type(slotEntry) == "table" and tonumber(slotEntry.itemID) or nil
        if itemID and SetItemAvailability(availabilityByItemID, itemID, characterGUID, batchCache) <= 0 then
            table.insert(missingOpts, itemID)
        end
    end

    local matStatus
    if allPresent then
        matStatus = "green"
    elseif anyPresent then
        matStatus = "yellow"
    else
        matStatus = "red"
    end

    return matStatus, missingOpts, qualMiss, availabilityByItemID
end

local function BuildEvaluationResult(config, characterGUID, batchCache)
    local currentStock, configKey, targetAvailability = GetTotalOwnedQuantity(config, characterGUID, batchCache)
    local targetQuantity = NormalizePositiveQuantity(config and config.targetQuantity, 1)
    local deficit = math.max(0, targetQuantity - currentStock)
    local matStatus, missingOpts, qualMiss, materialAvailabilityByItemID =
        EvaluateMaterialAvailability(config, characterGUID, deficit, batchCache)

    return {
        config                       = config,
        configKey                    = configKey,
        currentStock                 = currentStock,
        deficit                      = deficit,
        matStatus                    = matStatus,
        missingOptionals             = missingOpts,
        qualityMismatches            = qualMiss,
        canCraft                     = (matStatus ~= "red"),
        materialAvailabilityByItemID = materialAvailabilityByItemID,
        targetAvailability           = targetAvailability,
    }
end

function InventoryTargetEvaluator:GetMaterialAvailabilityByItemID(config, characterGUID, deficit)
    local batchCache = {
        availabilityByEvidence = {},
        availabilityHits = 0,
        availabilityMisses = 0,
    }
    local _, _, _, availabilityByItemID = EvaluateMaterialAvailability(config, characterGUID, deficit or 1, batchCache)
    return availabilityByItemID
end

function InventoryTargetEvaluator:Calculate(characterGUID, filterProfID)
    local startedAt = DebugTime()
    local results = {}
    local store = GetRecipeConfigStore()
    local configurations = store and store.GetConfigurations
        and store:GetConfigurations(characterGUID, filterProfID)
        or {}

    local inventoryStateService = GetInventoryStateService()
    local batchState = inventoryStateService
        and inventoryStateService.BuildCurrentState
        and inventoryStateService:BuildCurrentState({ characterOwnerKey = characterGUID })
        or nil

    local batchCache = {
        availabilityByEvidence = {},
        batchState = batchState,
        availabilityHits = 0,
        availabilityMisses = 0,
    }

    for _, config in pairs(configurations) do
        if config.characterGUID == characterGUID then
            local profMatch = (not filterProfID) or (config.professionID == filterProfID)
            if profMatch then
                table.insert(results, BuildEvaluationResult(config, characterGUID, batchCache))
            end
        end
    end

    LogTiming("InventoryTargetEvaluator:Calculate", startedAt, string.format(
        "results=%d availabilityHits=%d availabilityMisses=%d batchState=%s",
        #results,
        batchCache.availabilityHits or 0,
        batchCache.availabilityMisses or 0,
        tostring(batchState ~= nil)
    ))
    return results
end

function InventoryTargetEvaluator:CalculateOne(configID)
    local store = GetRecipeConfigStore()
    local config = store and store.GetConfiguration and store:GetConfiguration(configID) or nil
    if not config then
        return nil
    end

    return BuildEvaluationResult(config, config.characterGUID, {
        availabilityByEvidence = {},
        availabilityHits = 0,
        availabilityMisses = 0,
    })
end
