-- PocketCFO_Crafting/Crafting/RecipeObservationBuilder.lua
-- Read-only normalization of the recipe currently loaded in the Recipes-tab
-- crafting form (ProfessionsFrame.CraftingPage.SchematicForm): the mats it
-- will consume, the crafter's live Resourcefulness/Multicraft %, and the
-- output item at the quality the form currently predicts.
--
-- Recipes-tab sibling of PocketCFO_Orders' OrderObservationBuilder. There is
-- no customer on a Recipes-tab craft, so every schematic slot is the
-- crafter's cost. Slot reading (allocations, required-quantity correction,
-- estimated quality, "not chosen" slots) is shared with Orders through Core's
-- ReagentSlotService.
--
-- API sources (all already used elsewhere in PocketCFO_Crafting):
--   C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
--     -> slot structure and output quantityMin/quantityMax (base output per
--        craft). quantityMin/quantityMax: Confirmed (third-party) - CraftSim
--        RecipeData uses (quantityMin + quantityMax) / 2 as base output.
--   SchematicForm:GetTransaction() (GetAllocations/CreateCraftingReagentInfoTbl)
--     -> live allocation state for every slot.
--   SchematicForm:GetRecipeOperationInfo()
--     -> bonusStats (Resourcefulness/Multicraft ratingPct - confirmed in-game
--        by CraftEventCapture/OperationObservationBuilder's StatsFromOpInfo).
--   ItemIdentityService:BuildRecipeOutputIdentity
--     -> quality-aware output ConfigKey (same call CraftAnalysisController uses).

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting
local ReagentSlots = PocketCFO and PocketCFO.ReagentSlotService

local RecipeObservationBuilder = PocketCFO_Crafting:NewModule("RecipeObservationBuilder")

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

local function NonEmpty(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return tostring(value)
end

local function NewDiagnostics()
    return ReagentSlots.NewDiagnostics()
end

local function Unresolved(reason, diagnostics)
    return {
        resolved = false,
        unresolvedReason = reason,
        diagnostics = diagnostics or NewDiagnostics(),
    }
end

local function SafeRead(parent, key)
    if parent == nil then
        return false, nil
    end
    return pcall(function()
        return parent[key]
    end)
end

local function SafeMethod(object, methodName, ...)
    if object == nil then
        return false, nil
    end
    local args = { ... }
    local okMethod, method = SafeRead(object, methodName)
    if not okMethod or type(method) ~= "function" then
        return false, nil
    end
    return pcall(function()
        return method(object, unpack(args))
    end)
end

local function ApiCall(apiTable, functionName, ...)
    if type(apiTable) ~= "table" or type(apiTable[functionName]) ~= "function" then
        return false, nil, "missingAPI"
    end
    local args = { pcall(apiTable[functionName], ...) }
    local ok = table.remove(args, 1)
    if not ok then
        return false, nil, args[1]
    end
    return true, args[1], nil
end

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

-- Recipes-tab version of OrderObservationBuilder's NormalizeCrafterReagents:
-- no customer, so every slot is processed. Required/optional costs go to
-- reagents; finishing-slot costs go to finishingReagents so Resourcefulness
-- (which excludes finishing reagents) never sees them.
local function NormalizeRecipeReagents(transaction, reagentTbl, slotRows, diagnostics)
    local reagents = {}
    local finishing = {}
    local seen = {}
    local consumedReagentRows = {}

    for _, slotRow in ipairs(slotRows or {}) do
        local target = slotRow.classification == "finishing" and finishing or reagents
        ReagentSlots.AddCrafterSlotRows(target, seen, consumedReagentRows, transaction, reagentTbl, slotRow, diagnostics)
    end

    ReagentSlots.MarkNotChosenRows({ reagents, finishing }, slotRows)
    return reagents, finishing
end

-- Same bonusStats read as OperationObservationBuilder's StatsFromOpInfo
-- (confirmed in-game). Returns percentages (e.g. 23.5), nil when the stat
-- is absent - absent Multicraft means the recipe cannot multicraft.
local function ExtractBonusStatPcts(operationInfo)
    local bonusStats = type(operationInfo) == "table" and operationInfo.bonusStats or nil
    if type(bonusStats) ~= "table" then
        return nil, nil
    end
    local resourcefulnessPct, multicraftPct
    for _, stat in ipairs(bonusStats) do
        if type(stat) == "table" then
            if stat.bonusStatName == "Resourcefulness" then
                resourcefulnessPct = NumberOrNil(stat.ratingPct)
            elseif stat.bonusStatName == "Multicraft" then
                multicraftPct = NumberOrNil(stat.ratingPct)
            end
        end
    end
    return resourcefulnessPct, multicraftPct
end

-- The exact predicted output item link - the same call Blizzard's crafting
-- form makes when you shift-click the output icon (Blizzard 12.1.0 source,
-- Blizzard_ProfessionsRecipeSchematicForm.lua OutputIcon OnClick):
--   GetRecipeOutputItemData(recipeID, transaction:CreateCraftingReagentInfoTbl(),
--     transaction:GetAllocationItemGUID(), form:GetOutputOverrideQualityID()).hyperlink
-- GetOutputOverrideQualityID reads the form's current predicted quality
-- (Concentration included). For gear this link carries the real item level
-- (e.g. ilvl 206) that the AH scan priced, where a bare itemID only resolves
-- to the base item level - the cause of "No auction price" on crafted gear.
local function ResolveOutputItemLink(recipeID, sf, transaction, reagentTbl)
    if not C_TradeSkillUI or type(C_TradeSkillUI.GetRecipeOutputItemData) ~= "function" then
        return nil
    end
    local okGUID, allocationGUID = SafeMethod(transaction, "GetAllocationItemGUID")
    local okQuality, qualityID = SafeMethod(sf, "GetOutputOverrideQualityID")
    local ok, outputInfo = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, reagentTbl or {},
        okGUID and allocationGUID or nil, okQuality and qualityID or nil)
    return ok and type(outputInfo) == "table" and NonEmpty(outputInfo.hyperlink) or nil
end

local function ResolveSchematicForm()
    local professionsFrame = _G.ProfessionsFrame
    local craftingPage = professionsFrame and professionsFrame.CraftingPage
    return craftingPage and craftingPage.SchematicForm or nil
end

local function ResolveOutput(recipeID, recipeInfo, schematicInfo, sf, operationInfo, diagnostics)
    local identityService = GetItemIdentityService()
    local fallbackItemID = NumberOrNil(schematicInfo and schematicInfo.outputItemID)
        or NumberOrNil(recipeInfo and recipeInfo.outputItemID)

    if not identityService or type(identityService.BuildRecipeOutputIdentity) ~= "function" then
        diagnostics.unresolvedIdentities[#diagnostics.unresolvedIdentities + 1] = {
            source = "recipe.outputItem",
            itemID = fallbackItemID,
            reason = "itemIdentityServiceUnavailable",
        }
        return fallbackItemID, nil, nil
    end

    local _, currentRecipeInfo = SafeMethod(sf, "GetRecipeInfo")
    local ok, identity, resolution = pcall(function()
        return identityService:BuildRecipeOutputIdentity(recipeID, {
            recipeInfo = recipeInfo,
            currentRecipeInfo = type(currentRecipeInfo) == "table" and currentRecipeInfo or nil,
            schematicInfo = schematicInfo,
            operationInfo = operationInfo,
        })
    end)

    local resolvedItemID = (ok and type(identity) == "table" and NumberOrNil(identity.itemID))
        or (ok and type(resolution) == "table" and NumberOrNil(resolution.targetItemID))
        or fallbackItemID

    if ok and type(identity) == "table" and not identity.unresolved and identity.configKey then
        return resolvedItemID, identity.configKey, NumberOrNil(identity.craftingQuality or identity.qualityTier)
    end

    diagnostics.unresolvedIdentities[#diagnostics.unresolvedIdentities + 1] = {
        source = "recipe.outputItem",
        itemID = resolvedItemID,
        reason = ok and type(identity) == "table" and identity.unresolvedReason or "identityResolutionFailed",
    }
    return resolvedItemID, nil, nil
end

--- Builds a normalized observation of the recipe loaded in the Recipes-tab
-- crafting form.
-- @return { resolved = true, observation = {...}, diagnostics = {...} }
--      or { resolved = false, unresolvedReason = string, diagnostics = {...} }
function RecipeObservationBuilder:BuildCurrentRecipeObservation(recipeID)
    local diagnostics = NewDiagnostics()

    recipeID = NumberOrNil(recipeID)
    if not recipeID then
        return Unresolved("recipeIDUnavailable", diagnostics)
    end

    local sf = ResolveSchematicForm()
    if not sf then
        return Unresolved("schematicFormUnavailable", diagnostics)
    end

    local okRecipeInfo, recipeInfo = ApiCall(C_TradeSkillUI, "GetRecipeInfo", recipeID)
    if not okRecipeInfo or type(recipeInfo) ~= "table" then
        return Unresolved("recipeInfoUnavailable", diagnostics)
    end

    local okSchematic, schematicInfo = ApiCall(C_TradeSkillUI, "GetRecipeSchematic", recipeID, false)
    if not okSchematic or type(schematicInfo) ~= "table" then
        return Unresolved("recipeSchematicUnavailable", diagnostics)
    end

    local okTransaction, transaction = SafeMethod(sf, "GetTransaction")
    if not okTransaction or not transaction then
        return Unresolved("transactionUnavailable", diagnostics)
    end

    -- The form is a singleton Blizzard reuses across recipes; make sure it is
    -- showing the recipe we were asked about before reading it.
    local okTxRecipe, txRecipeID = SafeMethod(transaction, "GetRecipeID")
    if okTxRecipe and NumberOrNil(txRecipeID) and NumberOrNil(txRecipeID) ~= recipeID then
        return Unresolved("formShowsDifferentRecipe", diagnostics)
    end

    local okReagentTbl, reagentTbl = SafeMethod(transaction, "CreateCraftingReagentInfoTbl")
    if not okReagentTbl or type(reagentTbl) ~= "table" then
        reagentTbl = {}
    end

    local okConcentrating, concentrating = SafeMethod(transaction, "IsApplyingConcentration")
    concentrating = okConcentrating and concentrating == true or false

    local okOperationInfo, operationInfo = SafeMethod(sf, "GetRecipeOperationInfo")
    if not okOperationInfo or type(operationInfo) ~= "table" then
        operationInfo = nil
    end
    local resourcefulnessPct, multicraftPct = ExtractBonusStatPcts(operationInfo)

    local slotRows = ReagentSlots.BuildSlotRows(schematicInfo, diagnostics)
    local reagents, finishingReagents = NormalizeRecipeReagents(transaction, reagentTbl, slotRows, diagnostics)

    local quantityMin = NumberOrNil(schematicInfo.quantityMin)
    local quantityMax = NumberOrNil(schematicInfo.quantityMax)
    local baseOutputQuantity
    if quantityMin and quantityMax then
        baseOutputQuantity = (quantityMin + quantityMax) / 2
    else
        baseOutputQuantity = quantityMin or quantityMax
    end

    local outputItemID, outputConfigKey, outputQuality =
        ResolveOutput(recipeID, recipeInfo, schematicInfo, sf, operationInfo, diagnostics)
    local outputItemLink = ResolveOutputItemLink(recipeID, sf, transaction, reagentTbl)
    if outputItemLink and GetItemInfoInstant then
        -- Keep itemID and link describing the same item (per-quality itemIDs).
        local okInstant, linkItemID = pcall(GetItemInfoInstant, outputItemLink)
        outputItemID = (okInstant and NumberOrNil(linkItemID)) or outputItemID
    end

    return {
        resolved = true,
        observation = {
            recipeID = recipeID,
            recipeName = NonEmpty(recipeInfo.name),
            outputItemID = outputItemID,
            outputConfigKey = outputConfigKey,
            outputItemLink = outputItemLink,
            outputQuality = outputQuality,
            baseOutputQuantity = baseOutputQuantity,
            reagents = reagents,
            finishingReagents = finishingReagents,
            displayedResourcefulnessPct = resourcefulnessPct,
            displayedMulticraftPct = multicraftPct,
            concentrating = concentrating,
            -- operationInfo.concentrationCost: Confirmed (third-party) -
            -- CraftSim reads this field from the same CraftingOperationInfo
            -- struct. Not yet confirmed from SchematicForm:GetRecipeOperationInfo
            -- in-game.
            concentrationCost = NumberOrNil(operationInfo and operationInfo.concentrationCost),
        },
        diagnostics = diagnostics,
    }
end

if PocketCFO_Crafting then
    PocketCFO_Crafting.RecipeObservationBuilder = RecipeObservationBuilder
end
