-- PocketCFO_Crafting/Crafting/RecipeAnalysisController.lua
-- Live Recipe Analysis: the default analysis for every ordinary (non-
-- processing) recipe that CraftAnalysisEligibilityPolicy does not route to
-- the history-based CraftAnalysisController. Works like Order Analysis -
-- reads what is loaded in the crafting form right now - so it has numbers
-- before the recipe has ever been crafted.
--
-- Composes RecipeEconomicsService + RecipeAnalysisDisplayModelBuilder and
-- returns a CraftQueueController-shaped analysis result carrying the
-- display model. No economics math here.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local RecipeAnalysisController = PocketCFO_Crafting:NewModule("RecipeAnalysisController")

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

local function GetEconomicsService()
    return PocketCFO_Crafting:GetModule("RecipeEconomicsService", true)
end

local function GetDisplayModelBuilder()
    return PocketCFO_Crafting:GetModule("RecipeAnalysisDisplayModelBuilder", true)
end

local function GetLureAnalysisService()
    return PocketCFO_Crafting:GetModule("LureAnalysisService", true)
end

local function GetLureDisplayModelBuilder()
    return PocketCFO_Crafting:GetModule("LureAnalysisDisplayModelBuilder", true)
end

-- ---------------------------------------------------------------------------
-- Concentration value per point (Brian's snapshot approach)
-- ---------------------------------------------------------------------------
-- Only the output value changes when Concentrate is toggled (same mats, same
-- Resourcefulness, same Multicraft), so value per point is
--   (output value with Concentrate - output value without) / points used.
-- The "without" number is the last non-concentrating evaluation, kept only
-- while the recipe AND the exact mats loaded are unchanged (the signature
-- below) - a different recipe or a mat change overwrites/invalidates it.
-- In-memory only; never persisted.

local concentrationBaseline = nil -- { signature, outputValue }

local function ReagentSignature(recipeID, observation)
    local parts = {}
    for _, list in ipairs({ observation and observation.reagents, observation and observation.finishingReagents }) do
        for _, row in ipairs(type(list) == "table" and list or {}) do
            parts[#parts + 1] = tostring(row.configKey or row.itemID or row.currencyID) .. "x" .. tostring(row.quantity)
        end
    end
    table.sort(parts)
    return tostring(recipeID) .. "|" .. table.concat(parts, ",")
end

local function ApplyConcentrationBaseline(recipeID, economicsResult)
    if type(economicsResult) ~= "table" or economicsResult.resolved ~= true then
        return
    end
    local economics = economicsResult.economics
    local signature = ReagentSignature(recipeID, economicsResult.observation)

    if not economics.concentrating then
        concentrationBaseline = economics.outputValue and {
            signature = signature,
            outputValue = economics.outputValue,
        } or nil
        return
    end

    local points = tonumber(economics.concentrationCost)
    economics.concentrationPoints = points
    if concentrationBaseline
        and concentrationBaseline.signature == signature
        and economics.outputValue
        and points and points > 0 then
        economics.concentrationGain = economics.outputValue - concentrationBaseline.outputValue
        economics.concentrationValuePerPoint = economics.concentrationGain / points
    end
end

function RecipeAnalysisController:EvaluateRecipe(recipeID, professionID)
    local economicsService = GetEconomicsService()
    local displayBuilder = GetDisplayModelBuilder()
    if not economicsService or not displayBuilder then
        return {
            applicable = false,
            reason = "recipeAnalysisServicesUnavailable",
            rows = {},
            recipeID = recipeID,
            professionID = professionID,
        }
    end

    local economicsResult = economicsService:EvaluateCurrentRecipe(recipeID)

    -- Great beast lure recipes get Lure Analysis: the same Cost to Make,
    -- compared with what the beast returns (LureAnalysisService).
    local lureService = GetLureAnalysisService()
    local lureBuilder = GetLureDisplayModelBuilder()
    if lureService and lureBuilder and lureService:IsLureResult(economicsResult) then
        local recipeModel = displayBuilder:Build(economicsResult)
        local lureModel, pendingItemIDs = lureBuilder:Build(lureService:Evaluate(economicsResult), recipeModel)
        SessionLog("RecipeAnalysisController: lure recipeID=%s lureItemID=%s",
            tostring(recipeID), tostring(economicsResult.economics.outputItemID))
        return {
            applicable = true,
            label = "Lure Analysis",
            recipeID = recipeID,
            professionID = professionID,
            rows = {},
            hasOutputFamilies = false,
            supportsResultsLimit = false,
            isLiveRecipeAnalysis = true,
            displayModel = lureModel,
            pendingItemIDs = pendingItemIDs,
        }
    end

    ApplyConcentrationBaseline(recipeID, economicsResult)
    local displayModel = displayBuilder:Build(economicsResult)

    local economics = type(economicsResult) == "table" and economicsResult.economics or nil
    SessionLog("RecipeAnalysisController: recipeID=%s resolved=%s reason=%s profit=%s cost=%s outputValued=%s multicraftChance=%s bonus=%s bonusSource=%s",
        tostring(recipeID),
        tostring(type(economicsResult) == "table" and economicsResult.resolved),
        tostring(type(economicsResult) == "table" and economicsResult.unresolvedReason),
        tostring(economics and economics.profitPerCraft),
        tostring(economics and economics.totalCost),
        tostring(economics and economics.outputValued),
        tostring(economics and economics.multicraftChance),
        tostring(economics and economics.multicraftBonus),
        tostring(economics and economics.multicraftBonusSource))

    return {
        applicable = true,
        reason = displayModel.state ~= "resolved" and (displayModel.unresolvedReason or "recipeAnalysisUnavailable") or nil,
        label = "Recipe Analysis",
        recipeID = recipeID,
        professionID = professionID,
        rows = {},
        hasOutputFamilies = false,
        supportsResultsLimit = false,
        isLiveRecipeAnalysis = true,
        displayModel = displayModel,
        pendingItemIDs = displayBuilder:CollectPendingItemIDs(displayModel),
    }
end

function RecipeAnalysisController:EvaluateCurrentRecipe()
    local contextService = GetProfessionContextService()
    local recipeID = contextService and contextService:GetCurrentRecipeID()
    local context = contextService and contextService:GetCurrentProfessionContext() or {}
    if not recipeID then
        return {
            applicable = false,
            reason = "noRecipeSelected",
            rows = {},
            professionID = context.professionID,
        }
    end
    return self:EvaluateRecipe(recipeID, context.professionID)
end

function RecipeAnalysisController:OnEnable()
end

function RecipeAnalysisController:OnDisable()
end
