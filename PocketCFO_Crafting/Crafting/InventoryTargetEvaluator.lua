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

local function BuildTargetEvidence(config)
    if type(config) ~= "table" then
        return nil
    end

    if config.configKey and config.configKey ~= "" then
        return config.configKey
    end

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
    local evidence = BuildTargetEvidence(config)
    local configKey, resolved = ResolveIdentity(evidence)
    if not configKey then
        SessionLog("InventoryTargetEvaluator: target unresolved configID=%s recipeID=%s reason=%s",
            tostring(config and config.configID), tostring(config and config.recipeID), tostring(resolved))
        return 0, nil, resolved
    end

    local availability = GetAvailability(configKey, characterGUID, batchCache)
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
