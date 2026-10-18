-- PocketCFO_Crafting/Crafting/CraftAnalysisController.lua
-- Ordinary Craft Analysis pilot evaluator, sibling to
-- ProcessingAnalysisController. Handles exactly the recipes enabled by
-- Core's CraftAnalysisEligibilityPolicy.
--
-- For an eligible recipe, enumerates the produced-output-ConfigKey
-- Statistical Profiles already stored by Core's OperationOutcomeService
-- (see OperationObservationBuilder's craft-analysis-eligible branch, which
-- writes one Statistical Profile per distinct produced output ConfigKey
-- under the recipe's Operation Profile row), asks OperationEconomicsService
-- for a complete summary of each, and converts the results into the same
-- display-row shape ProcessingAnalysisController produces so the existing
-- InventoryManagerWindow analysis renderers can be reused unchanged.
--
-- This controller does not implement any pricing/valuation math itself -
-- see OperationEconomicsService:SummarizeStatisticalProfile.
--
-- ProcessingAnalysisController remains processing-only; this controller
-- never touches ProcessingOperationRegistry/ProcessingAnalysisRegistry, and
-- ProcessingAnalysisController never touches CraftAnalysisEligibilityPolicy.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local CraftAnalysisController = PocketCFO_Crafting:NewModule("CraftAnalysisController")

local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

local function GetProfessionContextService()
    return PocketCFO_Crafting:GetModule("ProfessionContextService", true)
end

-- Craft-specific builder: reuses ProcessingAnalysisDisplayModelBuilder for
-- everything neutral (label formatting, economics, status) and extends the
-- detail row with the craft-only multicraft production block Processing
-- Analysis must never carry. See CraftAnalysisDisplayModelBuilder.lua.
local function GetDisplayModelBuilder()
    return PocketCFO_Crafting:GetModule("CraftAnalysisDisplayModelBuilder", true)
end

local function GetEligibilityPolicy()
    return PocketCFO and PocketCFO.CraftAnalysisEligibilityPolicy or _G.PocketCFO_CraftAnalysisEligibilityPolicy
end

local function GetProfileKeyService()
    return PocketCFO and PocketCFO.OperationProfileKeyService or _G.PocketCFO_OperationProfileKeyService
end

local function GetEconomicsService()
    return PocketCFO and PocketCFO.OperationEconomicsService or _G.PocketCFO_OperationEconomicsService
end

local function GetOutcomeService()
    return PocketCFO and PocketCFO.OperationOutcomeService or _G.PocketCFO_OperationOutcomeService
end

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function NewResult(applicable, reason, extra)
    local result = {
        applicable = applicable == true,
        reason = reason,
        rows = {},
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            result[k] = v
        end
    end
    return result
end

-- Best-effort resolution of the ConfigKey the crafting UI would currently
-- produce for this recipe (used only to prefer highlighting that row - see
-- BuildDetailViewModel/EvaluateRecipe callers). Never blocks evaluation when
-- unresolved; the window's existing stable-row/first-row fallback applies.
local function ResolveCurrentOutputConfigKey(recipeID)
    local identityService = GetItemIdentityService()
    if not identityService or not identityService.BuildRecipeOutputIdentity then
        return nil
    end

    local sf = ProfessionsFrame and ProfessionsFrame.CraftingPage
        and ProfessionsFrame.CraftingPage.SchematicForm
    local recipeInfo = C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
    local currentRecipeInfo, operationInfo
    if sf then
        if sf.GetRecipeInfo then
            local ok, info = pcall(function() return sf:GetRecipeInfo() end)
            if ok then currentRecipeInfo = info end
        end
        if sf.GetRecipeOperationInfo then
            local ok, info = pcall(function() return sf:GetRecipeOperationInfo() end)
            if ok then operationInfo = info end
        end
    end

    local ok, identity = pcall(function()
        return identityService:BuildRecipeOutputIdentity(recipeID, {
            recipeInfo = recipeInfo,
            currentRecipeInfo = currentRecipeInfo,
            operationInfo = operationInfo,
        })
    end)
    if ok and type(identity) == "table" and not identity.unresolved then
        return identity.configKey
    end
    return nil
end

--- Evaluates one recipeID for ordinary Craft Analysis applicability and, if
-- applicable, builds ready-to-render display rows - one per historically
-- observed produced-output ConfigKey Statistical Profile.
-- @return table { applicable, reason, rows, recipeID, professionID, label,
--                 hasOutputFamilies, supportsResultsLimit }
function CraftAnalysisController:EvaluateRecipe(recipeID, professionID)
    recipeID = tonumber(recipeID)
    if not recipeID then
        SessionLog("CraftAnalysisController:EvaluateRecipe: reason=missingRecipeID")
        return NewResult(false, "missingRecipeID")
    end

    local eligibilityPolicy = GetEligibilityPolicy()
    if not eligibilityPolicy or not eligibilityPolicy.IsEnabled or not eligibilityPolicy:IsEnabled(recipeID) then
        SessionLog("CraftAnalysisController:EvaluateRecipe: recipeID=%s reason=notEnabledForCraftAnalysis", tostring(recipeID))
        return NewResult(false, "notEnabledForCraftAnalysis", { recipeID = recipeID, professionID = professionID })
    end

    local profileKeyService = GetProfileKeyService()
    if not profileKeyService then
        return NewResult(false, "profileKeyServiceUnavailable", { recipeID = recipeID, professionID = professionID })
    end

    local keyResult = profileKeyService:BuildKey(recipeID)
    if not keyResult or keyResult.unresolved then
        SessionLog("CraftAnalysisController:EvaluateRecipe: recipeID=%s reason=operationProfileKeyUnresolved",
            tostring(recipeID))
        return NewResult(false, "operationProfileKeyUnresolved", { recipeID = recipeID, professionID = professionID })
    end

    local outcomeService = GetOutcomeService()
    local economicsService = GetEconomicsService()
    if not outcomeService or not economicsService then
        return NewResult(false, "servicesUnavailable", { recipeID = recipeID, professionID = professionID })
    end

    local aggregate = outcomeService.GetAggregate and outcomeService:GetAggregate(keyResult.profileKey)
    local profiles = (aggregate and aggregate.hasStatisticalProfileSplit) and aggregate.statisticalProfiles or {}

    local label = "Craft Analysis"
    local currentOutputConfigKey = ResolveCurrentOutputConfigKey(recipeID)

    if #profiles == 0 then
        SessionLog("CraftAnalysisController:EvaluateRecipe: recipeID=%s reason=noCraftsObservedYet", tostring(recipeID))
        return {
            applicable = true,
            reason = "noCraftsObservedYet",
            label = label,
            recipeID = recipeID,
            professionID = professionID,
            rows = {},
            emptyMessage = "No crafts observed yet for this recipe.",
            currentOutputConfigKey = currentOutputConfigKey,
        }
    end

    local displayBuilder = GetDisplayModelBuilder()
    local displayRows = {}
    for _, profileView in ipairs(profiles) do
        local summary = economicsService:SummarizeStatisticalProfile(profileView, {})
        local itemLabel = profileView.itemName or (profileView.itemID and ("item:" .. tostring(profileView.itemID))) or "Unknown"
        local row = displayBuilder and displayBuilder:BuildRow(itemLabel, summary, {
            itemID = profileView.itemID,
            configKey = profileView.configKey,
            quality = profileView.craftingQuality,
        })
        if row then
            displayRows[#displayRows + 1] = row
        end
        SessionLog("CraftAnalysisController:EvaluateRecipe: DIAG row itemID=%s configKey=%s craftingQuality=%s observationCount=%s expectedPerCraft=%s",
            tostring(profileView.itemID), tostring(profileView.configKey), tostring(profileView.craftingQuality),
            tostring(summary.observationCount), tostring(summary.expectedNet))
    end

    table.sort(displayRows, function(a, b)
        local qa, qb = tonumber(a.quality) or 0, tonumber(b.quality) or 0
        if qa ~= qb then return qa < qb end
        return tostring(a.itemLabel) < tostring(b.itemLabel)
    end)

    SessionLog("CraftAnalysisController:EvaluateRecipe: recipeID=%s profileKey=%s profiles=%d rows=%d currentOutputConfigKey=%s",
        tostring(recipeID), tostring(keyResult.profileKey), #profiles, #displayRows, tostring(currentOutputConfigKey))

    return {
        applicable = true,
        reason = nil,
        label = label,
        recipeID = recipeID,
        professionID = professionID,
        rows = displayRows,
        hasOutputFamilies = false,
        supportsResultsLimit = false,
        currentOutputConfigKey = currentOutputConfigKey,
    }
end

--- Builds the expanded detail-view model for a display row previously
-- returned by EvaluateRecipe/EvaluateCurrentRecipe's .rows. Delegates
-- entirely to the display builder - this controller does not touch
-- economics math itself.
function CraftAnalysisController:BuildDetailViewModel(displayRow)
    if type(displayRow) ~= "table" then
        return nil
    end
    local displayBuilder = GetDisplayModelBuilder()
    if not displayBuilder or not displayBuilder.BuildDetailRow then
        return nil
    end
    return displayBuilder:BuildDetailRow(displayRow.itemLabel, displayRow.summary, {
        itemID = displayRow.itemID,
        configKey = displayRow.configKey,
        quality = displayRow.quality,
    })
end

--- Convenience wrapper that reads the currently selected recipe/profession
-- from ProfessionContextService.
function CraftAnalysisController:EvaluateCurrentRecipe()
    local contextService = GetProfessionContextService()
    local recipeID = contextService and contextService:GetCurrentRecipeID()
    local context = contextService and contextService:GetCurrentProfessionContext() or {}
    if not recipeID then
        return NewResult(false, "noRecipeSelected", { professionID = context.professionID })
    end
    return self:EvaluateRecipe(recipeID, context.professionID)
end

function CraftAnalysisController:OnEnable()
end

function CraftAnalysisController:OnDisable()
end
