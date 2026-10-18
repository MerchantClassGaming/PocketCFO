-- PocketCFO_Crafting/Crafting/RecipeStateCapture.lua
-- Captures the current Blizzard crafting UI state into a recipe config draft.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local RecipeStateCapture = PocketCFO_Crafting:NewModule("RecipeStateCapture", "AceEvent-3.0")

local function GetProfessionContextService()
    return PocketCFO_Crafting:GetModule("ProfessionContextService", true)
end

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function GetRecipeRegistry()
    return PocketCFO and PocketCFO.RecipeRegistry or _G.PocketCFO_RecipeRegistry
end

local function SafeCall(method, object)
    if type(method) ~= "function" then
        return nil, "missing method"
    end
    local ok, result = pcall(method, object)
    if ok then
        return result, nil
    end
    return nil, result
end

local function GetCharacterNameRealm()
    local name, realm = UnitFullName("player")
    if name and realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function BuildInventoryRuleDiagnosticPayload(config, recipeInfo, currentRecipeInfo, schematicInfo, sf, operationInfo, resolutionDiag, source)
    local sfRecipeInfo, sfRecipeInfoError = nil, nil
    local opInfo, opInfoError = operationInfo, nil
    local schematicFromApi, schematicFromApiError = nil, nil

    if sf then
        sfRecipeInfo, sfRecipeInfoError = SafeCall(sf.GetRecipeInfo, sf)
        if not opInfo then
            opInfo, opInfoError = SafeCall(sf.GetRecipeOperationInfo, sf)
        end
    end

    if config and config.recipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
        local ok, result = pcall(C_TradeSkillUI.GetRecipeSchematic, config.recipeID, false)
        if ok then
            schematicFromApi = result
        else
            schematicFromApiError = result
        end
    end

    local recipeName = recipeInfo and recipeInfo.name
    if not recipeName and config and config.recipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
        local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, config.recipeID)
        if ok and info then
            recipeName = info.name
        end
    end

    return {
        source = source or "RecipeStateCapture:CaptureCurrentDraft",
        timestamp = date("%Y-%m-%d %H:%M:%S"),
        recipeID = config and config.recipeID,
        recipeName = recipeName,
        configID = config and config.configID,
        characterGUID = config and config.characterGUID,
        ownerKey = config and config.characterGUID,
        characterName = GetCharacterNameRealm(),
        rawRecipeInfo = recipeInfo,
        rawCurrentRecipeInfo = currentRecipeInfo,
        rawSchematicInfo = schematicInfo,
        rawSchematicFromApi = schematicFromApi,
        rawSchematicFromApiError = schematicFromApiError,
        rawSchematicFormRecipeInfo = sfRecipeInfo,
        rawSchematicFormRecipeInfoError = sfRecipeInfoError,
        rawOperationInfo = opInfo,
        rawOperationInfoError = opInfoError,
        opInfoCraftingQuality = opInfo and opInfo.craftingQuality,
        opInfoConcentrationCost = opInfo and opInfo.concentrationCost,
        opInfoBaseSkill = opInfo and opInfo.baseSkill,
        opInfoBonusSkill = opInfo and opInfo.bonusSkill,
        opInfoBonusStats = opInfo and opInfo.bonusStats,
        resolution = resolutionDiag,
    }
end

local function CaptureSlotState(recipeID, sf)
    local matSlots = {}
    local optionalSlots = {}
    local schematicInfo = nil

    if sf then
        schematicInfo = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
        local reagentSlots = sf.reagentSlots
        local transaction  = sf:GetTransaction()
        local typeCounters = {}

        if schematicInfo and schematicInfo.reagentSlotSchematics and reagentSlots then
            for arrayIndex, slotData in ipairs(schematicInfo.reagentSlotSchematics) do
                local reagentType = slotData.reagentType
                local slotIndex   = slotData.slotIndex

                -- Every slot is captured regardless of reagentType or
                -- required/optional-ness - a required reagentType==2 slot
                -- (e.g. a mandatory catalyst presented as an optional-type
                -- slot) is a real consumed allocation and must not be
                -- skipped. Previously this recipeType==2-and-required
                -- combination was excluded from both matSlots and
                -- optionalSlots entirely.
                do
                    typeCounters[reagentType] = (typeCounters[reagentType] or 0) + 1
                    local n = typeCounters[reagentType]
                    local slotFrame = reagentSlots[reagentType] and reagentSlots[reagentType][n]

                    if reagentType == 1 then
                        local qualityEntries = {}
                        if transaction then
                            local ok, allocs = pcall(function()
                                return transaction:GetAllocations(arrayIndex)
                            end)
                            if ok and allocs and slotData.reagents then
                                pcall(function()
                                    for _, reagent in ipairs(slotData.reagents) do
                                        if reagent.itemID then
                                            local alloc = allocs:FindAllocationByReagent(reagent)
                                            if alloc then
                                                local qty = alloc:GetQuantity()
                                                if qty and qty > 0 then
                                                    table.insert(qualityEntries, {
                                                        itemID = reagent.itemID,
                                                        quantity = qty,
                                                    })
                                                end
                                            end
                                        end
                                    end
                                end)
                            end
                        end

                        if #qualityEntries > 0 then
                            matSlots[slotIndex] = qualityEntries
                        elseif slotFrame and slotFrame.Button then
                            local ok, itemID = pcall(function()
                                return slotFrame.Button:GetItemID()
                            end)
                            if ok and itemID then
                                matSlots[slotIndex] = { { itemID = itemID, quantity = slotData.quantityRequired or 1 } }
                            end
                        end
                    else
                        local itemID = nil
                        local itemLink = nil
                        if slotFrame and slotFrame.Button then
                            local ok, result = pcall(function()
                                return slotFrame.Button:GetItemID()
                            end)
                            if ok then itemID = result end
                            if itemID then
                                itemLink = select(2, GetItemInfo(itemID))
                            end
                        end
                        if itemID then
                            optionalSlots[slotIndex] = {
                                itemID = itemID,
                                itemLink = itemLink,
                            }
                        end
                    end
                end
            end
        end
    else
        PocketCFO:Debug("RecipeStateCapture: SchematicForm unavailable, cannot read slot state")
    end

    if not schematicInfo and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
        local ok, result = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if ok then
            schematicInfo = result
        end
    end

    return matSlots, optionalSlots, schematicInfo
end

function RecipeStateCapture:CaptureCurrentDraft()
    local contextService = GetProfessionContextService()
    local recipeID = contextService and contextService:GetCurrentRecipeID()
    if not recipeID then
        PocketCFO:Debug("RecipeStateCapture: no recipe selected")
        return nil
    end

    local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
    if not recipeInfo then
        PocketCFO:Debug("RecipeStateCapture: GetRecipeInfo returned nil for %d", recipeID)
        return nil
    end

    local context = contextService and contextService:GetCurrentProfessionContext() or {}
    local professionID = context.professionID
    local expansionID = context.expansionID
    if not professionID then
        PocketCFO:Debug("RecipeStateCapture: could not resolve professionID")
    end

    local sf = ProfessionsFrame and ProfessionsFrame.CraftingPage
        and ProfessionsFrame.CraftingPage.SchematicForm
    local currentRecipeInfo = nil
    local operationInfo = nil
    if sf then
        currentRecipeInfo = SafeCall(sf.GetRecipeInfo, sf)
        operationInfo = SafeCall(sf.GetRecipeOperationInfo, sf)
    end

    local matSlots, optionalSlots, schematicInfo = CaptureSlotState(recipeID, sf)
    local concentrationFlag = false
    local craftingPage = ProfessionsFrame and ProfessionsFrame.CraftingPage
    if craftingPage then
        local cc = craftingPage.ConcentrationContainer
        if cc and cc.Button then
            concentrationFlag = cc.Button:GetChecked() == true
        end
    end

    local identityService = GetItemIdentityService()
    local outputIdentity, identityMeta = nil, {}
    if identityService and identityService.BuildRecipeOutputIdentity then
        outputIdentity, identityMeta = identityService:BuildRecipeOutputIdentity(recipeID, {
            recipeInfo = recipeInfo,
            currentRecipeInfo = currentRecipeInfo,
            schematicInfo = schematicInfo,
            operationInfo = operationInfo,
            expansionID = expansionID,
            optionalSlots = optionalSlots,
        })
    end

    local targetIlvl = identityMeta and identityMeta.targetIlvl
    local targetItemID = identityMeta and identityMeta.targetItemID
    local statTarget = identityMeta and identityMeta.statFingerprint

    local registry = GetRecipeRegistry()
    local outputItemID = targetItemID
        or schematicInfo and schematicInfo.outputItemID
        or recipeInfo.outputItemID
        or registry and registry.GetOutputItemID and registry:GetOutputItemID(recipeID)

    PocketCFO:Debug("RecipeStateCapture: targetIlvl=%s statTarget=%s configKey=%s",
        tostring(targetIlvl), tostring(statTarget), tostring(outputIdentity and outputIdentity.configKey))

    local now = PocketCFO:Now()
    local config = {
        configID = PocketCFO:NewUUID(),
        characterGUID = PocketCFO.db.char.characterGUID,
        recipeID = recipeID,
        professionID = professionID,
        expansionID = expansionID,
        targetQuantity = 1,
        matSlots = matSlots,
        optionalSlots = optionalSlots,
        concentrationFlag = concentrationFlag,
        targetIlvl = targetIlvl,
        targetItemID = targetItemID,
        outputItemID = outputItemID,
        statTarget = statTarget,
        statFingerprint = statTarget,
        outputIdentity = outputIdentity,
        configKey = outputIdentity and outputIdentity.configKey,
        itemID = outputIdentity and outputIdentity.itemID,
        itemName = outputIdentity and outputIdentity.itemName,
        itemLink = outputIdentity and outputIdentity.itemLink,
        quality = outputIdentity and outputIdentity.quality,
        craftingQuality = outputIdentity and outputIdentity.craftingQuality,
        matchingPath = outputIdentity and outputIdentity.matchingPath,
        createdAt = now,
        updatedAt = now,
    }

    return config, BuildInventoryRuleDiagnosticPayload(
        config,
        recipeInfo,
        currentRecipeInfo,
        schematicInfo,
        sf,
        operationInfo,
        identityMeta and identityMeta.targetIlvlResolution,
        "RecipeStateCapture:CaptureCurrentDraft"
    )
end
