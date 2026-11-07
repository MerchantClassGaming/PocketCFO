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

-- ---------------------------------------------------------------------------
-- Milling (Brian, 2026-11-06)
-- ---------------------------------------------------------------------------
-- Milling is one-to-one: each herb mills to its own pigment, and that
-- pigment comes from nothing else. Once the herb is picked it is an ordinary
-- recipe, so it runs through the same RecipeEconomicsService math and Recipe
-- Analysis panel as everything else. The only milling-specific step is
-- filling in what the crafting form can't say for a salvage-style recipe:
--   input:  the herb slotted in the window (CraftEventCapture's live read,
--           the same one the processing headline uses), at its quantity
--   output: that herb's pigment and average count per mill, from your own
--           (or starter) milling history (ProcessingAnalysisController row)
--   Multicraft: doesn't apply to milling, so it is left off.
-- Resourcefulness, the AH cut and Cost to Make are the shared recipe math.

local MILLING_PROCESSING_TYPE = "milling"
local PICK_HERB_TEXT = "Pick an herb to see the details."
local NO_MILLING_HISTORY_TEXT = "No milling results for this herb yet."

local function GetProcessingOperationRegistry()
    return PocketCFO and PocketCFO.ProcessingOperationRegistry or _G.PocketCFO_ProcessingOperationRegistry
end

function RecipeAnalysisController:IsMillingRecipe(recipeID)
    local registry = GetProcessingOperationRegistry()
    recipeID = tonumber(recipeID)
    local entry = registry and registry.GetEntry and recipeID and registry:GetEntry(recipeID)
    return type(entry) == "table" and entry.processingType == MILLING_PROCESSING_TYPE
end

-- The herb slot: same pick as CraftQueueController's FindSlottedProcessingInput.
-- Second return: every live input, so Costs is exactly what is slotted.
local function FindSlottedHerb(recipeID)
    local capture = PocketCFO_Crafting:GetModule("CraftEventCapture", true)
    if not capture or not capture.GetLiveProcessingInputs then
        return nil, nil
    end
    local inputs = capture:GetLiveProcessingInputs(recipeID, "MillingRecipeAnalysis")
    inputs = type(inputs) == "table" and inputs or nil
    local driver
    for _, input in ipairs(inputs or {}) do
        if type(input) == "table" and input.itemID then
            if input.statisticalProfile == true or input.selectedCostInput == true then
                return input, inputs
            end
            if not driver and input.profileDriver == true then
                driver = input
            end
        end
    end
    return driver, inputs
end

-- The slotted herb's history row: exact quality (configKey) first, itemID
-- only for a row with no configKey.
local function FindHerbHistoryRow(rows, herb)
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if herb.configKey and row.configKey == herb.configKey then
            return row
        end
    end
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if not row.configKey and row.itemID == herb.itemID then
            return row
        end
    end
    return nil
end

-- The pigment and its average count per mill. One herb makes one pigment;
-- if history ever holds more than one output, the largest is the pigment.
local function FindPigment(row)
    local summary = type(row) == "table" and type(row.summary) == "table" and row.summary or nil
    if not summary or summary.unresolved then
        return nil
    end
    local best
    for _, output in ipairs(type(summary.outputValueRows) == "table" and summary.outputValueRows or {}) do
        local quantity = tonumber(output.quantityPerRun) or 0
        if output.itemID and quantity > 0 and (not best or quantity > best.quantity) then
            best = { itemID = output.itemID, configKey = output.configKey, quantity = quantity }
        end
    end
    return best
end

local function EvaluateMilling(recipeID, economicsService)
    local herb, inputs = FindSlottedHerb(recipeID)
    if not herb then
        return nil, "noHerbSlotted"
    end

    local observationBuilder = PocketCFO_Crafting:GetModule("RecipeObservationBuilder", true)
    local built = observationBuilder and observationBuilder:BuildCurrentRecipeObservation(recipeID)
    if type(built) ~= "table" or built.resolved ~= true then
        return {
            resolved = false,
            unresolvedReason = (type(built) == "table" and built.unresolvedReason) or "observationUnresolved",
        }
    end
    local observation = built.observation

    -- Input: exactly what is slotted.
    local reagents = {}
    for _, input in ipairs(inputs or {}) do
        if type(input) == "table" and input.itemID then
            reagents[#reagents + 1] = {
                itemID = input.itemID,
                configKey = input.configKey,
                quantity = tonumber(input.quantity) or 0,
            }
        end
    end
    observation.reagents = reagents
    observation.vellumRows = nil
    observation.displayedMulticraftPct = nil

    -- Output: the herb's pigment from history.
    local processingController = PocketCFO_Crafting:GetModule("ProcessingAnalysisController", true)
    local processingResult = processingController and processingController:EvaluateRecipe(recipeID)
    local pigment = FindPigment(FindHerbHistoryRow(processingResult and processingResult.rows, herb))
    observation.outputItemID = pigment and pigment.itemID or nil
    observation.outputConfigKey = pigment and pigment.configKey or nil
    observation.outputItemLink = nil
    observation.baseOutputQuantity = pigment and pigment.quantity or 1

    local result = economicsService:EvaluateObservation(observation)
    result.observation = observation
    result.noMillingHistory = pigment == nil

    -- Save the pigment's mat list for Smart Posting's Cost to Make, the same
    -- call RecipeEconomicsService:EvaluateCurrentRecipe makes for every other
    -- recipe. Only with history (no pigment = nothing to save). Never throws.
    local store = PocketCFO and PocketCFO.CostToMakeStore
    if pigment and result.resolved and store and type(store.Record) == "function" then
        store:Record(observation, result.economics)
    end
    SessionLog("RecipeAnalysisController: milling recipeID=%s herb=%s configKey=%s pigment=%s perMill=%s",
        tostring(recipeID), tostring(herb.itemID), tostring(herb.configKey),
        tostring(pigment and pigment.itemID), tostring(pigment and pigment.quantity))
    return result
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

    if self:IsMillingRecipe(recipeID) then
        local millingResult, millingReason = EvaluateMilling(recipeID, economicsService)
        local displayModel
        if millingReason == "noHerbSlotted" then
            displayModel = { state = "prompt", promptText = PICK_HERB_TEXT }
        else
            displayModel = displayBuilder:Build(millingResult)
            if millingResult and millingResult.noMillingHistory and displayModel.state == "resolved" then
                displayModel.noPriceNote = NO_MILLING_HISTORY_TEXT
                displayModel.outputPendingItemID = nil
            end
        end
        return {
            applicable = true,
            reason = displayModel.state == "unavailable" and (displayModel.unresolvedReason or "recipeAnalysisUnavailable") or nil,
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
