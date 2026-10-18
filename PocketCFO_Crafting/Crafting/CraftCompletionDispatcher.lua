-- PocketCFO_Crafting/Crafting/CraftCompletionDispatcher.lua
-- Coordinates all craft-completion side effects for one resolved
-- TRADE_SKILL_ITEM_CRAFTED_RESULT event.
--
-- CraftEventCapture owns event registration and event-time-only UI reads
-- (order-craft skip, pending config lookup). This module owns what happens
-- once those are known - it is the single place new craft-completion side
-- effects should be added.
--
-- Side effects, in order:
--   1. Best-known inventory snapshot adjustment (CraftInventoryAdapter).
--      Unchanged from prior CraftEventCapture behavior.
--   2. Legacy aggregate stat write (CraftStatLog). Unchanged - not yet
--      replaced. See "PocketCFO Docs/Craft Stat Migration.md".
--   3. OperationObservation build + OperationOutcomeService recording.
--      Crafting operations: one observation per event (unchanged).
--      Processing operations: output events for one physical operation are
--      buffered, then flushed as one composite observation after a short
--      window. This keeps runCount at 1 per operation regardless of how
--      many output items the operation yields.
--      Processing consumed inputs come from pre-operation primary-input capture.
--   4. Optional processing capture hook (ProcessingCaptureController).
--      Inert until capture mode is implemented.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local CraftCompletionDispatcher = PocketCFO_Crafting:NewModule("CraftCompletionDispatcher")

local function SessionLog(fmt, ...)
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    msg = "[MCG] " .. msg
    if PocketCFO and PocketCFO.AppendSessionLog then
        PocketCFO:AppendSessionLog(msg)
    end
    if PocketCFO and not PocketCFO.debugEnabled and not PocketCFO.traceEnabled then
        PocketCFO.sessionLog = PocketCFO.sessionLog or {}
        table.insert(PocketCFO.sessionLog, string.format("[%s] %s", date("%H:%M:%S"), msg))
    end
end

local function GetRecipeName(recipeID)
    local info = recipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo
        and C_TradeSkillUI.GetRecipeInfo(recipeID)
    return (info and info.name) or ("recipe:" .. tostring(recipeID))
end

local function GetProcessingRegistry()
    return PocketCFO and PocketCFO.ProcessingOperationRegistry
        or _G.PocketCFO_ProcessingOperationRegistry
end

local function IsProcessingOperation(recipeID)
    local registry = GetProcessingRegistry()
    return registry ~= nil and registry:IsProcessingOperation(recipeID)
end

local function GetProcessingEntry(recipeID)
    local registry = GetProcessingRegistry()
    return registry and registry.GetEntry and registry:GetEntry(recipeID) or nil
end

local function GetOutcomeService()
    return PocketCFO and PocketCFO.OperationOutcomeService or _G.PocketCFO_OperationOutcomeService
end

-- Records a structured, queryable failure for a processing completion that
-- never reached OperationOutcomeService:RecordObservation at all (builder
-- unavailable, or Build() itself returning nil) - previously these early
-- returns only wrote to SessionLog, so a registered Processing Operation
-- (e.g. Alchemy Recycling) could lose a completed craft with nothing visible
-- in /mcgd operation summary. No-op if OperationOutcomeService is
-- unavailable (SessionLog above already covers that case).
local function RecordProcessingCaptureFailure(reason, batch, stage)
    local outcomeService = GetOutcomeService()
    if not outcomeService or not outcomeService.RecordProcessingCaptureFailure then
        return
    end
    outcomeService:RecordProcessingCaptureFailure(reason, {
        recipeID = batch and batch.recipeID,
        stage = stage,
        primaryInputItemID = batch and batch.primaryInputItemID,
        primaryInputConfigKey = batch and batch.primaryInputConfigKey,
    })
end

-- Unchanged from CraftEventCapture: logs the result of step 1.
local function LogAdjustmentResult(configID, recipeID, adjResult)
    local outputRow    = adjResult.outputRow
    local consumedRows = adjResult.consumedRows or {}
    local returnRows   = adjResult.returnRows or {}

    SessionLog("CraftCompletionDispatcher: craft debug recipe=%s recipeID=%s outputItemID=%s outputName=%s outputQty=%d returnedQty=%d matQty=%d matSource=%s",
        tostring(GetRecipeName(recipeID)),
        tostring(recipeID),
        tostring(outputRow and outputRow.itemID),
        tostring(outputRow and outputRow.itemName),
        tonumber(outputRow and outputRow.quantity) or 0,
        tonumber(adjResult.returned) or 0,
        tonumber(adjResult.decremented) or 0,
        tostring(adjResult.matSource))

    for _, reagent in ipairs(consumedRows) do
        local removed = reagent.removedByLocation or {}
        SessionLog("CraftCompletionDispatcher: reagent consumed itemID=%s itemName=%s quality=%s requested=%d bags=%d warbank=%d bank=%d remaining=%d",
            tostring(reagent.itemID),
            tostring(reagent.itemName),
            tostring(reagent.craftingQuality or 0),
            tonumber(reagent.requestedQuantity) or tonumber(reagent.quantity) or 0,
            tonumber(removed.bags) or 0,
            tonumber(removed.warbank) or 0,
            tonumber(removed.bank) or 0,
            tonumber(reagent.remainingQuantity) or 0)
    end

    for _, row in ipairs(returnRows) do
        SessionLog("CraftCompletionDispatcher: resourcefulness return itemID=%s itemName=%s quality=%s quantity=%d addedLocation=bags",
            tostring(row.itemID),
            tostring(row.itemName),
            tostring(row.craftingQuality or 0),
            tonumber(row.quantity) or 0)
    end

    SessionLog("CraftCompletionDispatcher: output added itemID=%s itemName=%s quality=%s quantity=%d addedLocation=bags",
        tostring(outputRow and outputRow.itemID),
        tostring(outputRow and outputRow.itemName),
        tostring(outputRow and outputRow.craftingQuality or 0),
        tonumber(adjResult.incremented) or 0)

    SessionLog("CraftCompletionDispatcher: snapshot adjustment applied configID=%s recipeID=%s outputItemID=%s outputQty=%d matQty=%d matSource=%s",
        tostring(configID),
        tostring(recipeID),
        tostring(outputRow and outputRow.itemID),
        tonumber(adjResult.incremented) or 0,
        tonumber(adjResult.decremented) or 0,
        tostring(adjResult.matSource))
end

-- ---------------------------------------------------------------------------
-- Processing operation batch state
-- ---------------------------------------------------------------------------
-- TRADE_SKILL_ITEM_CRAFTED_RESULT fires once per distinct output item for
-- processing operations (prospecting, milling, etc.). One physical prospect
-- can fire N events. We buffer and flush one composite observation so
-- OperationOutcomeService.runCount stays at 1 per operation.
--
-- _processingBatch is nil when no batch is pending.
local _processingBatch = nil

-- Extracts and identity-resolves the output row from one adjResult without
-- re-invoking the full OperationObservationBuilder.Build path. Avoids
-- calling GetCraftingOperationInfo for every additional output event.
local function ResolveOutputRow(adjResult)
    local outputRow = adjResult and adjResult.outputRow
    if not outputRow or not outputRow.itemID then return nil end
    local row = {
        itemID          = outputRow.itemID,
        itemName        = outputRow.itemName,
        quantity        = outputRow.quantity,
        craftingQuality = outputRow.craftingQuality,
    }
    local identityService = PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
    if identityService and identityService.FromItemID then
        local ok, identity = pcall(function() return identityService:FromItemID(row.itemID) end)
        if ok and type(identity) == "table" and not identity.unresolved then
            row.configKey = identity.configKey
        end
    end
    return row
end

local function ResolveInputRow(input)
    if type(input) ~= "table" or not input.itemID then
        return nil
    end
    local row = {
        itemID    = input.itemID,
        itemLink  = input.itemLink,
        itemName  = input.itemName,
        quantity  = input.quantity,
        configKey = input.configKey,
        craftingQuality = input.craftingQuality,
        inputRoleKey = input.inputRoleKey,
        inputRole = input.inputRole,
        profileDriver = input.profileDriver == true,
        deterministicOutputDriver = input.deterministicOutputDriver == true,
        selectedCostInput = input.selectedCostInput == true,
        fixedCatalyst = input.fixedCatalyst == true,
        selected = input.selected == true,
        statisticalProfile = input.statisticalProfile == true,
        slotRule = input.slotRule,
    }
    if not row.configKey then
        local identityService = PocketCFO and PocketCFO.ItemIdentityService
            or _G.ItemIdentityService
        if identityService and identityService.FromItemID then
            local ok, identity = pcall(function()
                return identityService:FromItemID(row.itemID)
            end)
            if ok and type(identity) == "table" and not identity.unresolved then
                row.configKey = identity.configKey
                row.itemName = row.itemName or identity.itemName
                row.itemLink = row.itemLink or identity.itemLink
            end
        end
    end
    return row
end

local function FindProfileDriverInput(inputs)
    for _, input in ipairs(type(inputs) == "table" and inputs or {}) do
        if type(input) == "table" and input.profileDriver == true then
            return input
        end
    end
    return nil
end

local function FindStatisticalProfileInput(inputs)
    for _, input in ipairs(type(inputs) == "table" and inputs or {}) do
        if type(input) == "table" and input.statisticalProfile == true then
            return input
        end
    end
    return nil
end

local function LogObservationList(label, rows)
    local count = type(rows) == "table" and #rows or 0
    SessionLog("CraftCompletionDispatcher: %s count=%d", tostring(label), count)
    for index, row in ipairs(type(rows) == "table" and rows or {}) do
        SessionLog("CraftCompletionDispatcher: %s[%d] itemID=%s itemName=%s qty=%s configKey=%s role=%s roleKey=%s selectedCostInput=%s statisticalProfile=%s fixedCatalyst=%s profileDriver=%s",
            tostring(label), index, tostring(row.itemID), tostring(row.itemName),
            tostring(row.quantity), tostring(row.configKey), tostring(row.inputRole),
            tostring(row.inputRoleKey), tostring(row.selectedCostInput == true),
            tostring(row.statisticalProfile == true), tostring(row.fixedCatalyst == true),
            tostring(row.profileDriver == true))
    end
end

local function LogStatisticalProfile(label, statisticalProfile)
    if type(statisticalProfile) ~= "table" then
        SessionLog("CraftCompletionDispatcher: %s=(nil)", tostring(label))
        return
    end
    SessionLog("CraftCompletionDispatcher: %s key=%s itemID=%s itemName=%s qty=%s configKey=%s role=%s roleKey=%s",
        tostring(label), tostring(statisticalProfile.key), tostring(statisticalProfile.itemID),
        tostring(statisticalProfile.itemName), tostring(statisticalProfile.quantity),
        tostring(statisticalProfile.configKey), tostring(statisticalProfile.inputRole),
        tostring(statisticalProfile.inputRoleKey))
end

-- Learns Processing Analysis input candidates from real completed
-- operations, for "evaluate all inputs" policies (Prospecting, Milling)
-- whose curated ProcessingOperationRegistry.knownPrimaryInputs list starts
-- empty. Gated on the recipe's Processing Analysis policy being
-- EvaluateAllInputs - this is the only place that check happens, so
-- Crushing/Recycling/Disenchanting (selected-input policies) are never
-- affected. Writes only to PocketCFO.db.global.processingObservedPrimaryInputs
-- via ProcessingOperationRegistry:RecordObservedPrimaryInput - never to a
-- Lua registry file.
local function RecordObservedPrimaryInputIfApplicable(batch)
    local recipeID = batch and batch.recipeID
    local itemID = batch and batch.primaryInputItemID
    local itemLink = batch and batch.primaryInputItemLink
    if not recipeID or not itemID then
        return
    end

    local registry = GetProcessingRegistry()
    local entry = registry and registry.GetEntry and registry:GetEntry(recipeID)
    local processingType = entry and entry.processingType
    if not registry or not registry.RecordObservedPrimaryInput or not processingType then
        return
    end

    local analysisRegistry = PocketCFO_Crafting:GetModule("ProcessingAnalysisRegistry", true)
    local policyName = analysisRegistry and analysisRegistry.GetPolicyForProcessingType
        and analysisRegistry:GetPolicyForProcessingType(processingType)

    local recommendationPolicy = PocketCFO_Crafting:GetModule("ProcessingRecommendationPolicy", true)
    local evaluateAllInputsPolicy = recommendationPolicy and recommendationPolicy.POLICY_EVALUATE_ALL_INPUTS
    if not evaluateAllInputsPolicy or policyName ~= evaluateAllInputsPolicy then
        return
    end

    local identityService = PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
    local identity = nil
    if identityService and identityService.FromItemID then
        local ok, result = pcall(function() return identityService:FromItemID(itemID) end)
        if ok and type(result) == "table" and not result.unresolved then
            identity = result
        end
    end

    local itemName = (identity and identity.itemName) or (GetItemInfo and GetItemInfo(itemID)) or nil
    local recorded, reason = registry:RecordObservedPrimaryInput({
        recipeID = recipeID,
        processingType = processingType,
        policy = policyName,
        itemID = itemID,
        itemName = itemName,
        configKey = identity and identity.configKey,
        itemLink = itemLink,
    })

    if recorded then
        SessionLog("CraftCompletionDispatcher: observed primary input recorded recipeID=%s processingType=%s itemID=%s itemName=%s configKey=%s itemLink=%s",
            tostring(recipeID), tostring(processingType), tostring(itemID), tostring(itemName), tostring(identity and identity.configKey), tostring(itemLink))
    else
        SessionLog("CraftCompletionDispatcher: observed primary input skipped recipeID=%s processingType=%s reason=%s",
            tostring(recipeID), tostring(processingType), tostring(reason))
    end
end

local function FlushProcessingBatch()
    if not _processingBatch then return end
    local batch = _processingBatch
    _processingBatch = nil

    -- A buffered batch only exists because at least one output event fired,
    -- i.e. the processing operation already completed successfully. Learn
    -- from it regardless of whether the observation build below succeeds.
    RecordObservedPrimaryInputIfApplicable(batch)

    local builder = PocketCFO_Crafting:GetModule("OperationObservationBuilder", true)
    if not builder or not builder.Build then
        SessionLog("CraftCompletionDispatcher: processing batch dropped reason=builder-unavailable recipeID=%s primaryInputConfigKey=%s",
            tostring(batch.recipeID), tostring(batch.primaryInputConfigKey))
        RecordProcessingCaptureFailure("processingObservationBuilderUnavailable", batch, "observationBuilderLookup")
        return
    end

    if batch.primaryInputConfigKey then
        batch.firstContext.primaryInputConfigKey = batch.primaryInputConfigKey
    end

    -- Build the base observation from the first buffered event.
    -- craftStats, professionContext, and profileKey are captured once here.
    -- GetCraftingOperationInfo is not called again for additional output events.
    local observation = builder:Build(batch.firstContext, batch.firstAdjResult)
    if not observation then
        SessionLog("CraftCompletionDispatcher: processing batch dropped reason=builder-returned-nil recipeID=%s primaryInputConfigKey=%s",
            tostring(batch.recipeID), tostring(batch.primaryInputConfigKey))
        RecordProcessingCaptureFailure("processingObservationBuildReturnedNil", batch, "observationBuild")
        return
    end

    if observation.unresolved then
        SessionLog("CraftCompletionDispatcher: processing batch observation unresolved reason=%s recipeID=%s primaryInputConfigKey=%s",
            tostring(observation.unresolvedReason), tostring(batch.recipeID), tostring(batch.primaryInputConfigKey))
    end

    -- Append produced outputs from each additional buffered output event.
    for _, extraRow in ipairs(batch.extraOutputRows) do
        observation.producedOutputs[#observation.producedOutputs + 1] = extraRow
    end

    -- For processing operations, any output whose itemID matches the primary input
    -- is a resourcefulness return (e.g. ore returned to the player), not a crafted
    -- output. Move such items from producedOutputs into resourcefulnessReturns so
    -- that OperationOutcomeService aggregates them correctly.
    if batch.primaryInputItemID then
        local filteredOutputs = {}
        local returnedQty = 0
        for _, row in ipairs(observation.producedOutputs) do
            if row.itemID == batch.primaryInputItemID then
                observation.resourcefulnessReturns[#observation.resourcefulnessReturns + 1] = row
                returnedQty = returnedQty + (tonumber(row.quantity) or 1)
            else
                filteredOutputs[#filteredOutputs + 1] = row
            end
        end
        if returnedQty > 0 then
            observation.producedOutputs = filteredOutputs
            SessionLog("CraftCompletionDispatcher: processing resourcefulness returns detected recipeID=%s primaryInputItemID=%s returnedQty=%d",
                tostring(batch.recipeID), tostring(batch.primaryInputItemID), returnedQty)
        end
    end

    -- Processing consumption is the pre-operation primary input. Prefer this
    -- over any result-time adapter row because the SchematicForm transaction can
    -- be stale after Blizzard dispatches the operation.
    if type(batch.preOperationInputs) == "table"
    and #batch.preOperationInputs > 0 then
        observation.consumedInputs = {}
        for _, input in ipairs(batch.preOperationInputs) do
            local row = ResolveInputRow(input)
            if row then
                observation.consumedInputs[#observation.consumedInputs + 1] = row
            end
        end
        SessionLog("CraftCompletionDispatcher: processing batch consumedInputs from pre-capture recipeID=%s count=%d primaryInputConfigKey=%s",
            tostring(batch.recipeID), #observation.consumedInputs, tostring(batch.primaryInputConfigKey))
    elseif #observation.consumedInputs == 0 then
        SessionLog("CraftCompletionDispatcher: processing batch consumedInputs empty recipeID=%s reason=no-pre-capture-available",
            tostring(batch.recipeID))
    end

    SessionLog("CraftCompletionDispatcher: processing batch flushed recipeID=%s primaryInputConfigKey=%s eventCount=%d outputCount=%d observationProfileKey=%s",
        tostring(batch.recipeID), tostring(batch.primaryInputConfigKey), batch.eventCount,
        #observation.producedOutputs, tostring(observation.operationProfileKey))
    LogObservationList("finalObservationConsumedInputs", observation.consumedInputs)
    LogObservationList("finalObservationSelectedInputEvidence", observation.selectedInputEvidence)
    LogStatisticalProfile("finalObservationStatisticalProfile", observation.statisticalProfile)

    local enricher = PocketCFO_Crafting:GetModule("OperationHistoricalValuationEnricher", true)
    if enricher and enricher.Enrich then
        observation = enricher:Enrich(observation)
    end

    local outcomeService = PocketCFO and PocketCFO.OperationOutcomeService
        or _G.PocketCFO_OperationOutcomeService
    if outcomeService and outcomeService.RecordObservation then
        local recorded, rejectionReason = outcomeService:RecordObservation(observation)
        if not recorded then
            SessionLog("CraftCompletionDispatcher: OperationOutcomeService record rejected reason=%s profileKey=%s recipeID=%s",
                tostring(rejectionReason), tostring(observation.operationProfileKey), tostring(batch.recipeID))
        else
            SessionLog("CraftCompletionDispatcher: OperationOutcomeService record accepted profileKey=%s recipeID=%s",
                tostring(observation.operationProfileKey), tostring(batch.recipeID))
        end
    else
        SessionLog("CraftCompletionDispatcher: OperationOutcomeService record rejected reason=operationOutcomeServiceUnavailable profileKey=%s",
            tostring(observation.operationProfileKey))
    end

    local captureController = PocketCFO_Crafting:GetModule("ProcessingCaptureController", true)
    if captureController and captureController.IsCaptureModeActive and captureController:IsCaptureModeActive() then
        if captureController.RecordObservation then
            captureController:RecordObservation(observation, batch.firstContext)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Steps 1 and 2 (unchanged)
-- ---------------------------------------------------------------------------

-- Step 1: unchanged inventory adjustment behavior, moved from CraftEventCapture.
function CraftCompletionDispatcher:ApplyInventoryAdjustment(context)
    local craftInventory = PocketCFO and PocketCFO.CraftInventoryAdapter
    if not craftInventory or not craftInventory.ApplyCraftSnapshotAdjustments then
        SessionLog("CraftCompletionDispatcher: snapshot adjustment skipped reason=adapter-unavailable configID=%s recipeID=%s",
            tostring(context.configID), tostring(context.recipeID))
        return { skipped = true, skipReason = "adapter-unavailable" }
    end

    local ownerKey = PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID
    local adjResult = craftInventory:ApplyCraftSnapshotAdjustments(
        ownerKey, context.configID, context.config, context.recipeID, context.result)
    if not adjResult.skipped then
        LogAdjustmentResult(context.configID, context.recipeID, adjResult)
    end
    return adjResult
end

-- Step 2: unchanged stat write behavior, moved from CraftEventCapture.
function CraftCompletionDispatcher:WriteCraftStat(context)
    local statLog = PocketCFO_Crafting:GetModule("CraftStatLog", true)
    if statLog and statLog.LogCraft then
        statLog:LogCraft(context.result, context.recipeID)
        return true
    end
    SessionLog("CraftCompletionDispatcher: CraftStatLog unavailable; craft stat write skipped")
    return false
end

-- ---------------------------------------------------------------------------
-- Step 3 — crafting path (unchanged)
-- ---------------------------------------------------------------------------

-- Builds one OperationObservation and records it. Used for normal crafting
-- operations only. Processing operations go through BufferProcessingEvent.
function CraftCompletionDispatcher:BuildAndRecordObservation(context, adjResult)
    local builder = PocketCFO_Crafting:GetModule("OperationObservationBuilder", true)
    if not builder or not builder.Build then
        SessionLog("CraftCompletionDispatcher: observation build skipped reason=builder-unavailable recipeID=%s",
            tostring(context.recipeID))
        return nil
    end

    local observation = builder:Build(context, adjResult)
    if not observation then
        SessionLog("CraftCompletionDispatcher: observation build returned nil recipeID=%s", tostring(context.recipeID))
        return nil
    end

    if observation.unresolved then
        SessionLog("CraftCompletionDispatcher: observation unresolved reason=%s recipeID=%s",
            tostring(observation.unresolvedReason), tostring(context.recipeID))
    end

    -- Attaches observation-time monetary facts (historicalInputCost etc.)
    -- before recording - only for observations that actually carry a
    -- resolved output-ConfigKey Statistical Profile (i.e. an eligible Craft
    -- Analysis pilot recipe; see OperationObservationBuilder). Every other
    -- ordinary craft has no Statistical Profile for these facts to matter
    -- to - Craft Analysis only ever reads a Statistical Profile's own
    -- totals, never the blended parent recipe row - so skipping the
    -- ValuationService lookups for them is a pure cost saving, not a
    -- behavior change. Processing operations are enriched in
    -- FlushProcessingBatch after their composite observation is built.
    if observation.statisticalProfile then
        local enricher = PocketCFO_Crafting:GetModule("OperationHistoricalValuationEnricher", true)
        if enricher and enricher.Enrich then
            observation = enricher:Enrich(observation)
        end
    end

    local outcomeService = PocketCFO and PocketCFO.OperationOutcomeService or _G.PocketCFO_OperationOutcomeService
    if outcomeService and outcomeService.RecordObservation then
        local recorded, rejectionReason = outcomeService:RecordObservation(observation)
        if not recorded then
            SessionLog("CraftCompletionDispatcher: outcome recording rejected reason=%s profileKey=%s recipeID=%s",
                tostring(rejectionReason), tostring(observation.operationProfileKey), tostring(context.recipeID))
        end
    else
        SessionLog("CraftCompletionDispatcher: outcome recording skipped reason=operationOutcomeServiceUnavailable profileKey=%s",
            tostring(observation.operationProfileKey))
    end

    local captureController = PocketCFO_Crafting:GetModule("ProcessingCaptureController", true)
    if captureController and captureController.IsCaptureModeActive and captureController:IsCaptureModeActive() then
        if captureController.RecordObservation then
            captureController:RecordObservation(observation, context)
        end
    end

    return observation
end

-- ---------------------------------------------------------------------------
-- Step 3 — processing path
-- ---------------------------------------------------------------------------

-- Buffers one processing output event. On the first event for a recipeID +
-- primaryInputConfigKey pair, starts a 0.5s timer; on flush, one composite
-- observation is built and recorded. Steps 1 and 2 run per-event.
--
-- The batch is keyed by both recipeID and primaryInputConfigKey so that outputs
-- from different ore inputs (same recipeID, different ore) are never merged.
function CraftCompletionDispatcher:BufferProcessingEvent(context, adjResult)
    local recipeID = context.recipeID
    local profileDriverInput = FindProfileDriverInput(context.preOperationInputs)
    local statisticalProfileInput = FindStatisticalProfileInput(context.preOperationInputs)
    local primaryInputItemID = profileDriverInput and profileDriverInput.itemID or nil
    -- Real hyperlink captured from the actual reagent instance selected, when
    -- available - preferred by Processing Analysis's icon quality-tier
    -- overlay over a freshly rebuilt itemID-only link (see
    -- ProcessingOperationRegistry:RecordObservedPrimaryInput).
    local primaryInputItemLink = profileDriverInput and profileDriverInput.itemLink or nil
    local primaryInputConfigKey = context.primaryInputConfigKey
        or (profileDriverInput and profileDriverInput.configKey)
        or nil
    local batchDiscriminator = primaryInputConfigKey
        or (statisticalProfileInput and (statisticalProfileInput.configKey
            or (statisticalProfileInput.itemID and ("item:" .. tostring(statisticalProfileInput.itemID)))))
        or nil
    local entry = GetProcessingEntry(recipeID)

    SessionLog("CraftCompletionDispatcher: processing event received recipeID=%s primaryInputItemID=%s primaryInputConfigKey=%s batchDiscriminator=%s",
        tostring(recipeID), tostring(primaryInputItemID), tostring(primaryInputConfigKey), tostring(batchDiscriminator))

    if not primaryInputConfigKey
    and entry
    and entry.profileKeyMode == "recipePlusPrimaryInput" then
        SessionLog("CraftCompletionDispatcher: processing event primary input capture failure recipeID=%s reason=missingPrimaryInputConfigKey",
            tostring(recipeID))
    end

    if _processingBatch
    and _processingBatch.recipeID == recipeID
    and _processingBatch.batchDiscriminator == batchDiscriminator then
        -- Add this event's output to the running batch.
        local row = ResolveOutputRow(adjResult)
        if row then
            _processingBatch.extraOutputRows[#_processingBatch.extraOutputRows + 1] = row
        end
        _processingBatch.eventCount = _processingBatch.eventCount + 1
        SessionLog("CraftCompletionDispatcher: processing batch appended recipeID=%s primaryInputConfigKey=%s batchDiscriminator=%s eventCount=%d",
            tostring(recipeID), tostring(primaryInputConfigKey), tostring(batchDiscriminator), _processingBatch.eventCount)
    else
        if _processingBatch then
            -- A different recipe/ore fired before the previous batch flushed.
            -- Flush immediately to avoid dropping that observation.
            SessionLog("CraftCompletionDispatcher: processing batch pre-empted oldRecipeID=%s oldPrimaryInputConfigKey=%s oldBatchDiscriminator=%s newRecipeID=%s newPrimaryInputConfigKey=%s newBatchDiscriminator=%s",
                tostring(_processingBatch.recipeID), tostring(_processingBatch.primaryInputConfigKey),
                tostring(_processingBatch.batchDiscriminator), tostring(recipeID),
                tostring(primaryInputConfigKey), tostring(batchDiscriminator))
            FlushProcessingBatch()
        end

        _processingBatch = {
            recipeID             = recipeID,
            primaryInputItemID   = primaryInputItemID,
            primaryInputItemLink = primaryInputItemLink,
            primaryInputConfigKey = primaryInputConfigKey,
            batchDiscriminator   = batchDiscriminator,
            firstContext         = context,
            firstAdjResult       = adjResult,
            extraOutputRows      = {},
            eventCount           = 1,
            preOperationInputs   = context.preOperationInputs,
        }

        SessionLog("CraftCompletionDispatcher: processing batch started recipeID=%s primaryInputConfigKey=%s batchDiscriminator=%s primaryInputItemID=%s",
            tostring(recipeID), tostring(primaryInputConfigKey), tostring(batchDiscriminator), tostring(primaryInputItemID))

        C_Timer.After(0.5, FlushProcessingBatch)
    end
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

--- Coordinates all craft-completion side effects for one resolved event.
-- @param context table { event, result, recipeID, configID, config }
function CraftCompletionDispatcher:Dispatch(context)
    SessionLog("CraftCompletionDispatcher: dispatch entered contextType=%s resultType=%s recipeID=%s configID=%s",
        tostring(type(context)), tostring(type(context and context.result)),
        tostring(context and context.recipeID), tostring(context and context.configID))

    if type(context) ~= "table" or type(context.result) ~= "table" then
        SessionLog("CraftCompletionDispatcher: dispatch skipped reason=invalid-context")
        return
    end

    -- Steps 1 and 2 run for every event regardless of operation type.
    local adjResult = self:ApplyInventoryAdjustment(context)
    self:WriteCraftStat(context)

    -- Step 3: processing operations buffer output events and flush one
    -- composite observation; crafting operations record immediately.
    if IsProcessingOperation(context.recipeID) then
        SessionLog("CraftCompletionDispatcher: dispatch route=processing recipeID=%s",
            tostring(context.recipeID))
        self:BufferProcessingEvent(context, adjResult)
    else
        SessionLog("CraftCompletionDispatcher: dispatch route=crafting recipeID=%s",
            tostring(context.recipeID))
        self:BuildAndRecordObservation(context, adjResult)
    end

    SessionLog("CraftCompletionDispatcher: dispatched recipeID=%s configID=%s",
        tostring(context.recipeID), tostring(context.configID))
end

function CraftCompletionDispatcher:OnEnable()
end

function CraftCompletionDispatcher:OnDisable()
    -- Flush any in-progress batch so data is not silently dropped.
    if _processingBatch then
        SessionLog("CraftCompletionDispatcher: processing batch flushed reason=disable recipeID=%s primaryInputConfigKey=%s",
            tostring(_processingBatch.recipeID), tostring(_processingBatch.primaryInputConfigKey))
        FlushProcessingBatch()
    end
end
