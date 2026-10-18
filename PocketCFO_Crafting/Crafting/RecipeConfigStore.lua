-- PocketCFO_Crafting/Crafting/RecipeConfigStore.lua
-- Owns saved Inventory Manager recipe configuration persistence.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local RecipeConfigStore = PocketCFO_Crafting:NewModule("RecipeConfigStore", "AceEvent-3.0")

local function GetConfigs()
    PocketCFO_Crafting.db.global.recipeConfigurations =
        PocketCFO_Crafting.db.global.recipeConfigurations or {}
    return PocketCFO_Crafting.db.global.recipeConfigurations
end

local function GetRecipeName(recipeID)
    local info = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
    return info and info.name or "Unknown"
end

local function GetConfigFingerprint(config)
    local optItems = {}
    if config and config.optionalSlots then
        for _, slotEntry in pairs(config.optionalSlots) do
            if slotEntry and slotEntry.itemID then
                table.insert(optItems, slotEntry.itemID)
            end
        end
    end
    table.sort(optItems)

    local qualityKey = config and config.targetItemID
        and tostring(config.targetItemID)
        or tostring(config and config.targetIlvl or 0)

    return string.format("%d|%s|%s|%s",
        config and config.recipeID or 0,
        tostring(config and config.statTarget or "none"),
        qualityKey,
        table.concat(optItems, ",")
    )
end

local function RecordInventoryRuleDiagnostic(payload, config)
    local diag = _G.MCG_Diagnostic
    if not diag or type(diag.RecordInventoryRuleSave) ~= "function" then
        return
    end

    payload = payload or {}
    payload.finalConfigWritten = config
    payload.finalConfigLookupKey = config and config.configID

    local ok, err = pcall(diag.RecordInventoryRuleSave, payload)
    if not ok then
        PocketCFO:Debug("RecipeConfigStore: inventory rule diagnostic failed: %s", tostring(err))
    end
end

local function CopyIdentityMetadata(config, identity)
    if type(config) ~= "table" or type(identity) ~= "table" or identity.unresolved then
        return
    end

    config.configKey = config.configKey or identity.configKey
    config.itemID = config.itemID or identity.itemID
    config.itemName = config.itemName or identity.itemName
    config.itemLink = config.itemLink or identity.itemLink
    config.quality = config.quality or identity.quality
    config.craftingQuality = config.craftingQuality or identity.craftingQuality
    config.itemQuality = config.itemQuality or identity.itemQuality
    config.effectiveIlvl = config.effectiveIlvl or identity.effectiveIlvl
    config.effectiveItemLevel = config.effectiveItemLevel or identity.effectiveItemLevel
    config.statFingerprint = config.statFingerprint or identity.statFingerprint
    config.matchingPath = config.matchingPath or identity.matchingPath
    config.variantType = config.variantType or identity.variantType
    config.auctionPath = config.auctionPath or identity.auctionPath
    config.identity = config.identity or {
        configKey = identity.configKey,
        itemID = identity.itemID,
        itemName = identity.itemName,
        itemLink = identity.itemLink,
        quality = identity.quality,
        craftingQuality = identity.craftingQuality,
        effectiveIlvl = identity.effectiveIlvl,
        statFingerprint = identity.statFingerprint,
        matchingPath = identity.matchingPath,
        variantType = identity.variantType,
        auctionPath = identity.auctionPath,
    }
end

function RecipeConfigStore:GetConfigFingerprint(config)
    return GetConfigFingerprint(config)
end

function RecipeConfigStore:FindMatchingSavedConfig(config, charGUID)
    if not config then return nil end

    local newFingerprint = GetConfigFingerprint(config)
    for savedConfigID, existing in pairs(GetConfigs()) do
        if existing
        and existing.characterGUID == charGUID
        and GetConfigFingerprint(existing) == newFingerprint then
            return existing.configID or savedConfigID, existing, newFingerprint
        end
    end

    return nil, nil, newFingerprint
end

function RecipeConfigStore:GetConfigurations(filterCharGUID, filterProfID)
    local results = {}
    for _, config in pairs(GetConfigs()) do
        local charMatch = (not filterCharGUID) or (config.characterGUID == filterCharGUID)
        local profMatch = (not filterProfID)   or (config.professionID  == filterProfID)
        if charMatch and profMatch then
            table.insert(results, config)
        end
    end
    return results
end

function RecipeConfigStore:GetConfiguration(configID)
    return GetConfigs()[configID]
end

function RecipeConfigStore:SaveConfiguration(config, diagnosticPayload)
    if not config then
        return nil, "missingConfig"
    end

    config.configID = config.configID or PocketCFO:NewUUID()
    config.targetQuantity = math.max(1, math.floor(tonumber(config.targetQuantity) or 1))
    config.createdAt = config.createdAt or PocketCFO:Now()
    config.updatedAt = PocketCFO:Now()

    CopyIdentityMetadata(config, config.outputIdentity or config.identity)
    GetConfigs()[config.configID] = config
    RecordInventoryRuleDiagnostic(diagnosticPayload, GetConfigs()[config.configID])

    local recipeName = GetRecipeName(config.recipeID)
    PocketCFO:Print("Saved: %s (target: %d)", recipeName, config.targetQuantity)
    PocketCFO:Debug("RecipeConfigStore saved: configID=%s recipeID=%d profID=%s expID=%s fingerprint=%s configKey=%s",
        config.configID,
        config.recipeID,
        tostring(config.professionID),
        tostring(config.expansionID),
        tostring(GetConfigFingerprint(config)),
        tostring(config.configKey)
    )

    PocketCFO:SendMessage("MCGCFO_CONFIG_SAVED", config)
    return config
end

function RecipeConfigStore:SetTargetQuantity(configID, quantity)
    local config = GetConfigs()[configID]
    if not config then
        PocketCFO:Debug("RecipeConfigStore:SetTargetQuantity - configID not found: %s", configID)
        return
    end
    if type(quantity) ~= "number" or quantity < 1 then
        PocketCFO:Print("Target quantity must be a positive number.")
        return
    end
    config.targetQuantity = math.floor(quantity)
    config.updatedAt = PocketCFO:Now()
    PocketCFO:SendMessage("MCGCFO_CONFIG_UPDATED", config)
end

function RecipeConfigStore:DeleteConfiguration(configID)
    if not GetConfigs()[configID] then
        PocketCFO:Debug("RecipeConfigStore:Delete - configID not found: %s", configID)
        return
    end
    GetConfigs()[configID] = nil
    PocketCFO:SendMessage("MCGCFO_CONFIG_DELETED", configID)
    PocketCFO:Debug("RecipeConfigStore: deleted configID=%s", configID)
end
