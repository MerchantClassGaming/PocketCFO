-- PocketCFO_Crafting/Crafting/OperationObservationBuilder.lua
-- Normalizes one completed TRADE_SKILL_ITEM_CRAFTED_RESULT event (plus the
-- inventory adjustment CraftInventoryAdapter already computed for it) into
-- the canonical OperationObservation payload. This is the only shape Core's
-- future OperationOutcomeService should consume craft-completion data
-- through; no other service should read Blizzard craft events directly.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local OperationObservationBuilder = PocketCFO_Crafting:NewModule("OperationObservationBuilder")

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

local function GetProfileKeyService()
    return PocketCFO and PocketCFO.OperationProfileKeyService or _G.PocketCFO_OperationProfileKeyService
end

local function GetCraftStatLog()
    return PocketCFO_Crafting:GetModule("CraftStatLog", true)
end

local function GetProcessingRegistry()
    return PocketCFO and PocketCFO.ProcessingOperationRegistry
        or _G.PocketCFO_ProcessingOperationRegistry
end

local function GetCraftAnalysisEligibilityPolicy()
    return PocketCFO and PocketCFO.CraftAnalysisEligibilityPolicy
        or _G.PocketCFO_CraftAnalysisEligibilityPolicy
end

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function NormalizeID(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

-- Best-effort configKey attachment. Reagent/output rows from
-- CraftInventoryAdapter already carry itemID/itemName/quantity/quality;
-- this does not block the observation if identity resolution fails.
local function AttachConfigKey(row)
    if type(row) ~= "table" or not row.itemID then
        return row
    end
    local identityService = GetItemIdentityService()
    if identityService and identityService.FromItemID then
        local ok, identity = pcall(function() return identityService:FromItemID(row.itemID) end)
        if ok and type(identity) == "table" and not identity.unresolved then
            row.configKey = row.configKey or identity.configKey
        end
    end
    return row
end

local function BuildConsumedInputs(adjResult)
    local list = {}
    for _, reagent in ipairs((adjResult and adjResult.consumedRows) or {}) do
        list[#list + 1] = AttachConfigKey({
            itemID          = reagent.itemID,
            itemName        = reagent.itemName,
            quantity        = reagent.requestedQuantity or reagent.quantity,
            craftingQuality = reagent.craftingQuality,
        })
    end
    return list
end

local function BuildProducedOutputs(adjResult)
    local list = {}
    local outputRow = adjResult and adjResult.outputRow
    if outputRow and outputRow.itemID then
        list[#list + 1] = AttachConfigKey({
            itemID          = outputRow.itemID,
            itemName        = outputRow.itemName,
            quantity        = outputRow.quantity,
            craftingQuality = outputRow.craftingQuality,
        })
    end
    return list
end

local function BuildResourcefulnessReturns(adjResult)
    local list = {}
    for _, row in ipairs((adjResult and adjResult.returnRows) or {}) do
        list[#list + 1] = AttachConfigKey({
            itemID          = row.itemID,
            itemName        = row.itemName,
            quantity        = row.quantity,
            craftingQuality = row.craftingQuality,
        })
    end
    return list
end

-- No positional fallback: a fixed-catalyst input (e.g. Alchemy Recycling's
-- Oil of Heartwood) must never become the primary/profile-driving input just
-- because it happens to be first in preOperationInputs. Callers must treat a
-- nil return as "primary input not yet resolved", not "guess the first one".
local function FindProfileDriverInput(inputs)
    for _, input in ipairs(type(inputs) == "table" and inputs or {}) do
        if type(input) == "table" and input.profileDriver == true then
            return input
        end
    end
    return nil
end

local function BuildSelectedInputEvidence(inputs)
    local evidence = {}
    for _, input in ipairs(type(inputs) == "table" and inputs or {}) do
        if type(input) == "table" and (input.selected == true or input.selectedCostInput == true or input.statisticalProfile == true) then
            evidence[#evidence + 1] = {
                inputRoleKey = input.inputRoleKey,
                inputRole = input.inputRole,
                itemID = input.itemID,
                itemName = input.itemName,
                itemLink = input.itemLink,
                quantity = input.quantity,
                configKey = input.configKey,
                craftingQuality = input.craftingQuality,
                profileDriver = input.profileDriver == true,
                deterministicOutputDriver = input.deterministicOutputDriver == true,
                selectedCostInput = input.selectedCostInput == true,
                fixedCatalyst = input.fixedCatalyst == true,
                statisticalProfile = input.statisticalProfile == true,
            }
        end
    end
    return evidence
end

local function BuildStatisticalProfile(inputs)
    for _, input in ipairs(type(inputs) == "table" and inputs or {}) do
        if type(input) == "table" and input.statisticalProfile == true then
            return {
                key = input.configKey or (input.itemID and ("item:" .. tostring(input.itemID)) or nil),
                inputRoleKey = input.inputRoleKey,
                inputRole = input.inputRole,
                itemID = input.itemID,
                itemName = input.itemName,
                configKey = input.configKey,
                quantity = input.quantity,
                craftingQuality = input.craftingQuality,
            }
        end
    end
    return nil
end

-- Craft Analysis pilot only: derives the Statistical Profile identity from
-- the produced output's own ConfigKey rather than from a selected input.
-- Must run after producedOutputs has been normalized (AttachConfigKey
-- already ran as part of BuildProducedOutputs) - never parses or rebuilds a
-- configKey locally. Returns nil, reason when the output identity did not
-- resolve, so the caller can fail the profile write explicitly instead of
-- guessing a fallback identity.
local function BuildOutputStatisticalProfile(producedOutputs)
    local outputRow = type(producedOutputs) == "table" and producedOutputs[1] or nil
    if not outputRow or not outputRow.itemID then
        return nil, "missingProducedOutput"
    end
    if not outputRow.configKey or outputRow.configKey == "" then
        return nil, "outputConfigKeyUnresolved"
    end
    return {
        key = outputRow.configKey,
        itemID = outputRow.itemID,
        itemName = outputRow.itemName,
        configKey = outputRow.configKey,
        quantity = outputRow.quantity,
        craftingQuality = outputRow.craftingQuality,
    }, nil
end

local function LogInputList(label, rows)
    local count = type(rows) == "table" and #rows or 0
    SessionLog("OperationObservationBuilder: %s count=%d", tostring(label), count)
    for index, row in ipairs(type(rows) == "table" and rows or {}) do
        SessionLog("OperationObservationBuilder: %s[%d] itemID=%s itemName=%s qty=%s quality=%s configKey=%s role=%s roleKey=%s selectedCostInput=%s statisticalProfile=%s fixedCatalyst=%s profileDriver=%s",
            tostring(label), index, tostring(row.itemID), tostring(row.itemName),
            tostring(row.quantity), tostring(row.craftingQuality), tostring(row.configKey), tostring(row.inputRole),
            tostring(row.inputRoleKey), tostring(row.selectedCostInput == true),
            tostring(row.statisticalProfile == true), tostring(row.fixedCatalyst == true),
            tostring(row.profileDriver == true))
    end
end

local function LogStatisticalProfile(label, statisticalProfile)
    if type(statisticalProfile) ~= "table" then
        SessionLog("OperationObservationBuilder: %s=(nil)", tostring(label))
        return
    end
    SessionLog("OperationObservationBuilder: %s key=%s itemID=%s itemName=%s qty=%s quality=%s configKey=%s role=%s roleKey=%s",
        tostring(label), tostring(statisticalProfile.key), tostring(statisticalProfile.itemID),
        tostring(statisticalProfile.itemName), tostring(statisticalProfile.quantity),
        tostring(statisticalProfile.craftingQuality), tostring(statisticalProfile.configKey), tostring(statisticalProfile.inputRole),
        tostring(statisticalProfile.inputRoleKey))
end

local function BuildMulticraftEvidence(result)
    local totalQuantity   = tonumber(result and result.quantity) or 1
    local multicraftExtra = tonumber(result and result.multicraft) or 0
    local baseQuantity    = math.max(0, totalQuantity - multicraftExtra)
    return {
        occurred      = multicraftExtra > 0,
        totalQuantity = totalQuantity,
        baseQuantity  = baseQuantity,
        extraQuantity = multicraftExtra,
    }
end

-- Extracts stat percentages from an opInfo table (SchematicForm or API).
-- Returns skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct.
local function StatsFromOpInfo(opInfo)
    if type(opInfo) ~= "table" then
        return nil, nil, nil, nil
    end
    local skill = (opInfo.baseSkill or 0) + (opInfo.bonusSkill or 0)
    local rfPct, mcPct, ingPct
    if type(opInfo.bonusStats) == "table" then
        for _, stat in ipairs(opInfo.bonusStats) do
            if stat.bonusStatName == "Resourcefulness" then
                rfPct = stat.ratingPct
            elseif stat.bonusStatName == "Multicraft" then
                mcPct = stat.ratingPct
            elseif stat.bonusStatName == "Ingenuity" then
                ingPct = stat.ratingPct
            end
        end
    end
    return skill, rfPct, mcPct, ingPct
end

local function BuildCraftStatSnapshot(recipeID, result, context)
    local skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct

    -- Prefer the SchematicForm opInfo captured at event time: it reflects
    -- the actual character stats with the real reagents loaded in the UI.
    -- Fall back to the CraftStatLog helper (calls GetCraftingOperationInfo
    -- with empty reagents) when no captured data is available.
    local capturedOpInfo = context and context.capturedOpInfo
    if capturedOpInfo then
        skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct =
            StatsFromOpInfo(capturedOpInfo)
    else
        local statLog = GetCraftStatLog()
        if statLog and statLog.GetOperationStats then
            skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct =
                statLog:GetOperationStats(recipeID)
        end
    end

    -- multicraftApplicable is true when Multicraft appears in bonusStats,
    -- false when the operation type cannot multicraft (prospecting, etc.).
    -- nil multicraftPct means the stat was absent from bonusStats → not applicable.
    local multicraftApplicable = multicraftPct ~= nil

    -- Concentration/Ingenuity: for processing operations, result.concentrationSpent
    -- may carry stale values from a previous craft. Guard against false ingenuity
    -- counts by requiring capturedOpInfo.concentrationCost > 0 before trusting it.
    -- If capturedOpInfo is absent for a processing op, default to 0 (not applicable)
    -- rather than risk a false positive. Crafting operations keep existing behavior.
    -- Theoretical: capturedOpInfo.concentrationCost field name unverified in-game.
    local rawConcentrationSpent = tonumber(result and result.concentrationSpent) or 0
    local concentrationSpent
    if rawConcentrationSpent == 0 then
        concentrationSpent = 0
    else
        local registry = GetProcessingRegistry()
        local isProcessing = registry and registry:IsProcessingOperation(recipeID)
        if isProcessing then
            local opCost = capturedOpInfo
                and tonumber(capturedOpInfo.concentrationCost) or 0
            concentrationSpent = opCost > 0 and rawConcentrationSpent or 0
        else
            concentrationSpent = rawConcentrationSpent
        end
    end

    return {
        skillAtCraft         = skillAtCraft,
        resourcefulnessPct   = resourcefulnessPct,
        multicraftPct        = multicraftPct,
        multicraftApplicable = multicraftApplicable,
        ingenuityPct         = ingenuityPct,
        concentrationSpent   = concentrationSpent,
        hadIngenuityProc     = concentrationSpent > 0 and (result and result.hasIngenuityProc == true) or false,
        ingenuityRefund      = concentrationSpent > 0 and (tonumber(result and result.ingenuityRefund) or 0) or 0,
    }
end

--- Builds the canonical OperationObservation for one completed craft event.
-- Never errors on missing structural data - returns an explicit
-- unresolved/unresolvedReason instead, so the dispatcher can skip outcome
-- recording without failing the rest of craft-completion handling.
-- @param context table { result, recipeID, configID, config, event }
-- @param adjResult table|nil the CraftInventoryAdapter result already
--        computed for this event (reused to avoid recomputing consumption).
function OperationObservationBuilder:Build(context, adjResult)
    context = type(context) == "table" and context or {}
    local recipeID = NormalizeID(context.recipeID)
    local result = context.result

    local now = PocketCFO and PocketCFO.GetServerNow and PocketCFO:GetServerNow() or time()

    if not recipeID then
        return {
            unresolved = true,
            unresolvedReason = "missingRecipeID",
            source = "TRADE_SKILL_ITEM_CRAFTED_RESULT",
            recordedAt = now,
            configID = context.configID,
        }
    end

    local professionContextService = GetProfessionContextService()
    local professionContext = professionContextService
        and professionContextService:GetCurrentProfessionContext() or {}

    -- Resolve primaryInputConfigKey from the pre-captured processing inputs.
    -- Required by recipePlusPrimaryInput operations (prospecting, milling) so that
    -- OperationProfileKeyService can produce a per-ore profileKey rather than a
    -- shared per-recipeID key. Skipped for crafting operations (no preOperationInputs).
    local primaryInputConfigKey = context.primaryInputConfigKey
    if type(context.preOperationInputs) == "table" and #context.preOperationInputs > 0 then
        local firstInput = FindProfileDriverInput(context.preOperationInputs)
        if firstInput and firstInput.configKey then
            primaryInputConfigKey = primaryInputConfigKey or firstInput.configKey
        elseif firstInput and firstInput.itemID then
            local identityService = GetItemIdentityService()
            if identityService and identityService.FromItemID then
                local ok, identity = pcall(function()
                    return identityService:FromItemID(firstInput.itemID)
                end)
                if ok and type(identity) == "table" and not identity.unresolved then
                    primaryInputConfigKey = identity.configKey
                end
            end
        end
    end

    SessionLog("OperationObservationBuilder: primary input resolution recipeID=%s itemID=%s configKey=%s captured=%s",
        tostring(recipeID),
        tostring(context.preOperationInputs and context.preOperationInputs[1] and context.preOperationInputs[1].itemID),
        tostring(primaryInputConfigKey),
        tostring(type(context.preOperationInputs) == "table" and #context.preOperationInputs or 0))

    local profileKeyService = GetProfileKeyService()
    local keyResult = profileKeyService and profileKeyService:BuildKey(recipeID, {
        primaryInputConfigKey = primaryInputConfigKey,
    }) or nil

    local consumedInputs = BuildConsumedInputs(adjResult)
    local producedOutputs = BuildProducedOutputs(adjResult)
    local selectedInputEvidence = BuildSelectedInputEvidence(context.preOperationInputs)

    -- Statistical Profile identity source depends on operation type:
    --   Processing operations keep the existing input-driven identity
    --   (e.g. Crushing's selected gem) - unchanged.
    --   Ordinary Crafting Operations enabled by CraftAnalysisEligibilityPolicy
    --   use the produced output's own ConfigKey instead, resolved only after
    --   producedOutputs is normalized above. Never falls back to the
    --   input-driven identity for an eligible recipe - an unresolved output
    --   identity means no Statistical Profile is written for that craft, not
    --   a guessed one.
    local processingRegistry = GetProcessingRegistry()
    local isProcessingRecipe = processingRegistry ~= nil and processingRegistry:IsProcessingOperation(recipeID)
    local eligibilityPolicy = GetCraftAnalysisEligibilityPolicy()
    local craftAnalysisEligible = not isProcessingRecipe
        and eligibilityPolicy ~= nil
        and eligibilityPolicy.IsEnabled ~= nil
        and eligibilityPolicy:IsEnabled(recipeID) == true

    local statisticalProfile, statisticalProfileUnresolvedReason
    if craftAnalysisEligible then
        statisticalProfile, statisticalProfileUnresolvedReason = BuildOutputStatisticalProfile(producedOutputs)
        if not statisticalProfile then
            SessionLog("OperationObservationBuilder: craft analysis statistical profile unresolved recipeID=%s reason=%s",
                tostring(recipeID), tostring(statisticalProfileUnresolvedReason))
        end
    else
        statisticalProfile = BuildStatisticalProfile(context.preOperationInputs)
    end

    LogInputList("preOperationInputs", context.preOperationInputs)
    LogInputList("consumedInputsBeforeProcessingOverride", consumedInputs)
    LogInputList("selectedInputEvidenceBeforeDispatch", selectedInputEvidence)
    LogStatisticalProfile("statisticalProfileBeforeDispatch", statisticalProfile)

    local observation = {
        recipeID               = recipeID,
        professionID           = professionContext.professionID,
        expansionID            = professionContext.expansionID,
        childSkillLineID       = professionContext.childSkillLineID,
        consumedInputs         = consumedInputs,
        producedOutputs        = producedOutputs,
        resourcefulnessReturns = BuildResourcefulnessReturns(adjResult),
        selectedInputEvidence  = selectedInputEvidence,
        statisticalProfile     = statisticalProfile,
        multicraft             = BuildMulticraftEvidence(result),
        craftStats             = BuildCraftStatSnapshot(recipeID, result, context),
        source                 = "TRADE_SKILL_ITEM_CRAFTED_RESULT",
        recordedAt             = now,
        configID               = context.configID,
    }

    if not keyResult then
        observation.unresolved = true
        observation.unresolvedReason = "profileKeyServiceUnavailable"
    elseif keyResult.unresolved then
        observation.operationType = keyResult.operationType
        observation.unresolved = true
        observation.unresolvedReason = keyResult.unresolvedReason
        SessionLog("OperationObservationBuilder: observation profileKey unresolved recipeID=%s reason=%s primaryInputConfigKey=%s",
            tostring(recipeID), tostring(keyResult.unresolvedReason), tostring(primaryInputConfigKey))
    else
        observation.operationProfileKey = keyResult.profileKey
        observation.operationType = keyResult.operationType
        observation.profileKeyMode = keyResult.profileKeyMode
        observation.primaryInputConfigKey = keyResult.primaryInputConfigKey
        SessionLog("OperationObservationBuilder: observation profileKey=%s recipeID=%s",
            tostring(observation.operationProfileKey), tostring(recipeID))
    end

    return observation
end

if PocketCFO_Crafting then
    PocketCFO_Crafting.OperationObservationBuilder = OperationObservationBuilder
end
