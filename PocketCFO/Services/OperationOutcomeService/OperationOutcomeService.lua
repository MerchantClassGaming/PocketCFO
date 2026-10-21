-- PocketCFO/Services/OperationOutcomeService/OperationOutcomeService.lua
-- Canonical owner of aggregated observed Operation outcomes.
--
-- Answers "what usually happens?" for one Operation Profile Key. Consumes
-- normalized OperationObservation payloads from PocketCFO_Crafting's
-- CraftCompletionDispatcher. Owns aggregates only, not raw per-craft history
-- - one hundred runs produce one aggregate row, not one hundred rows.
--
-- This service must never price anything, recommend anything, or guess
-- missing identity. Pricing belongs to the future OperationEconomicsService.
--
-- Persistence: PocketCFO.db.global.operationOutcomes[operationProfileKey]
--
-- Published starter (seed) aggregates for Processing Operations
-- (OperationOutcomeSeedData.lua) are immutable code. Read paths show a seed
-- row only until the user's own local runCount for that Statistical Profile
-- (or non-split Operation Profile) reaches SEED_HANDOFF_RUN_COUNT - then
-- local only. Seed is never summed with local data and never written into
-- SavedVariables. Recording paths never see seed data.

local PocketCFO = _G.PocketCFO

local OperationOutcomeService = {}

OperationOutcomeService.YIELD_STATUS_UNKNOWN = "unknown"
OperationOutcomeService.YIELD_STATUS_LOW_SAMPLE = "lowSample"
OperationOutcomeService.YIELD_STATUS_ESTABLISHED = "established"
OperationOutcomeService.ESTABLISHED_THRESHOLD = 100

-- Max local runs needed before the user's own results replace starter data.
-- Seed rows with fewer runs hand off once local runs match the seed's count.
OperationOutcomeService.SEED_HANDOFF_RUN_COUNT = 20

-- In-memory only, not persisted. Lets diagnostics inspect why observations
-- were dropped without polluting SavedVariables.
OperationOutcomeService.rejectionDiagnostics = OperationOutcomeService.rejectionDiagnostics or {}
OperationOutcomeService.rejectionRecords = OperationOutcomeService.rejectionRecords or {}

local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

local function FindPrimaryInputEvidence(observation)
    for _, row in ipairs(type(observation and observation.selectedInputEvidence) == "table" and observation.selectedInputEvidence or {}) do
        if type(row) == "table" and row.profileDriver == true then
            return row
        end
    end
    for _, row in ipairs(type(observation and observation.consumedInputs) == "table" and observation.consumedInputs or {}) do
        if type(row) == "table" then
            return row
        end
    end
    return nil
end

local function GetProcessingEntry(recipeID)
    local registry = PocketCFO and PocketCFO.ProcessingOperationRegistry
        or _G.PocketCFO_ProcessingOperationRegistry
    return registry and registry.GetEntry and registry:GetEntry(recipeID) or nil
end

local function SendOutcomeUpdatedMessage(observation, aggregateRow)
    if not PocketCFO or type(PocketCFO.SendMessage) ~= "function" then
        return
    end

    local primaryInput = FindPrimaryInputEvidence(observation)
    PocketCFO:SendMessage("PCFO_OPERATION_OUTCOME_UPDATED", {
        operationProfileKey = observation and observation.operationProfileKey,
        recipeID = observation and observation.recipeID,
        operationType = observation and observation.operationType,
        profileKeyMode = observation and observation.profileKeyMode,
        primaryInputConfigKey = (observation and observation.primaryInputConfigKey)
            or (primaryInput and primaryInput.configKey),
        primaryInputItemID = primaryInput and primaryInput.itemID,
        primaryInputItemName = primaryInput and primaryInput.itemName,
        runCount = aggregateRow and aggregateRow.runCount,
    })
end

local function GetGlobalDB()
    return PocketCFO and PocketCFO.db and PocketCFO.db.global
end

local function NormalizeQuantity(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Item reference helpers
-- ---------------------------------------------------------------------------

local function ItemRefKey(ref)
    if type(ref) ~= "table" then
        return nil
    end
    if ref.configKey and ref.configKey ~= "" then
        return tostring(ref.configKey)
    end
    local itemID = tonumber(ref.itemID)
    if itemID then
        return "item:" .. tostring(itemID)
    end
    return nil
end

local function AccumulateItemRefs(totalsByKey, refs)
    for _, ref in ipairs(refs or {}) do
        local key = ItemRefKey(ref)
        local quantity = NormalizeQuantity(ref and ref.quantity)
        if key and quantity > 0 then
            local entry = totalsByKey[key]
            if not entry then
                entry = {
                    itemID = tonumber(ref.itemID),
                    configKey = ref.configKey,
                    itemName = ref.itemName,
                    quantityTotal = 0,
                }
                totalsByKey[key] = entry
            end
            entry.quantityTotal = entry.quantityTotal + quantity
            entry.itemName = entry.itemName or ref.itemName
        end
    end
end

local function MarkObservedKeys(setTable, refs)
    for _, ref in ipairs(refs or {}) do
        local key = ItemRefKey(ref)
        if key then
            setTable[key] = true
        end
    end
end

local function SumQuantities(refs)
    local total = 0
    for _, ref in ipairs(refs or {}) do
        total = total + NormalizeQuantity(ref and ref.quantity)
    end
    return total
end

local function LogObservationRefs(label, refs)
    local count = type(refs) == "table" and #refs or 0
    SessionLog("OperationOutcomeService: %s count=%d", tostring(label), count)
    for index, ref in ipairs(type(refs) == "table" and refs or {}) do
        SessionLog("OperationOutcomeService: %s[%d] itemID=%s itemName=%s qty=%s quality=%s configKey=%s role=%s roleKey=%s selectedCostInput=%s statisticalProfile=%s fixedCatalyst=%s profileDriver=%s",
            tostring(label), index, tostring(ref.itemID), tostring(ref.itemName),
            tostring(ref.quantity), tostring(ref.craftingQuality), tostring(ref.configKey), tostring(ref.inputRole),
            tostring(ref.inputRoleKey), tostring(ref.selectedCostInput == true),
            tostring(ref.statisticalProfile == true), tostring(ref.fixedCatalyst == true),
            tostring(ref.profileDriver == true))
    end
end

local function LogStatisticalProfile(label, statisticalProfile)
    if type(statisticalProfile) ~= "table" then
        SessionLog("OperationOutcomeService: %s=(nil)", tostring(label))
        return
    end
    SessionLog("OperationOutcomeService: %s key=%s itemID=%s itemName=%s qty=%s configKey=%s role=%s roleKey=%s",
        tostring(label), tostring(statisticalProfile.key), tostring(statisticalProfile.itemID),
        tostring(statisticalProfile.itemName), tostring(statisticalProfile.quantity),
        tostring(statisticalProfile.configKey), tostring(statisticalProfile.inputRole),
        tostring(statisticalProfile.inputRoleKey))
end

-- ---------------------------------------------------------------------------
-- Aggregate row lifecycle
-- ---------------------------------------------------------------------------

local function NewCraftStatsTotals()
    return {
        skillAtCraftTotal = 0,
        skillAtCraftCount = 0,
        resourcefulnessPctTotal = 0,
        resourcefulnessPctCount = 0,
        multicraftPctTotal = 0,
        multicraftPctCount = 0,
        multicraftApplicableRunCount = 0,
        ingenuityPctTotal = 0,
        -- concentrationCraftCount: observations where concentration was
        -- actually used; the correct denominator for all ingenuity averages.
        concentrationCraftCount = 0,
        concentrationSpentTotal = 0,
        ingenuityProcCount = 0,
        -- concentrationReturnedTotal: sum of concentration points returned
        -- by Ingenuity procs (replaces ingenuityRefundTotal semantically).
        concentrationReturnedTotal = 0,
        -- Kept for backward-compatibility with aggregates written before
        -- concentrationCraftCount / concentrationReturnedTotal were added.
        ingenuityPctCount = 0,
        ingenuityRefundTotal = 0,
    }
end

local function NewAggregateRow(observation, now)
    return {
        operationProfileKey = observation.operationProfileKey,
        operationType = observation.operationType,
        profileKeyMode = observation.profileKeyMode,
        recipeID = observation.recipeID,
        professionID = observation.professionID,
        expansionID = observation.expansionID,
        childSkillLineID = observation.childSkillLineID,

        runCount = 0,

        consumedTotalsByKey = {},
        producedTotalsByKey = {},
        resourcefulnessTotalsByKey = {},
        observedOutputItemKeys = {},
        observedResourcefulnessItemKeys = {},
        -- statisticalProfiles: keyed by statisticalProfileKey. Populated only
        -- for operations whose registry entry flags an input as
        -- statisticalProfile = true (e.g. crushing's selected gem). Empty for
        -- operations like prospecting where the profile key itself already
        -- separates execution contexts - BuildAggregateView synthesizes a
        -- single "Default" Statistical Profile for those at read time.
        statisticalProfiles = {},
        latestSelectedInputEvidence = nil,

        consumedQuantityTotal = 0,
        resourcefulnessQuantityTotal = 0,
        resourcefulnessProcCount = 0,

        multicraftProcCount = 0,
        multicraftExtraTotal = 0,
        multicraftBaseQuantityTotal = 0,
        multicraftTotalQuantityTotal = 0,

        -- Historical monetary facts (observation-time valuation, attached by
        -- PocketCFO_Crafting's OperationHistoricalValuationEnricher before
        -- RecordObservation). Never repriced later - see AccumulateObservationTotals.
        totalHistoricalInputCost = 0,
        totalHistoricalResourcefulnessValue = 0,
        unresolvedInputValuationCount = 0,
        unresolvedResourcefulnessValuationCount = 0,

        craftStats = NewCraftStatsTotals(),

        firstObservedAt = now,
        lastObservedAt = now,
    }
end

local function NewStatisticalProfileAggregate(observation, statisticalProfile, now)
    statisticalProfile = type(statisticalProfile) == "table" and statisticalProfile or {}
    return {
        operationProfileKey = observation.operationProfileKey,
        operationType = observation.operationType,
        profileKeyMode = observation.profileKeyMode,
        recipeID = observation.recipeID,
        professionID = observation.professionID,
        expansionID = observation.expansionID,
        childSkillLineID = observation.childSkillLineID,

        statisticalProfileKey = statisticalProfile.key
            or statisticalProfile.configKey
            or (statisticalProfile.itemID and ("item:" .. tostring(statisticalProfile.itemID))),
        inputRoleKey = statisticalProfile.inputRoleKey,
        inputRole = statisticalProfile.inputRole,
        itemID = statisticalProfile.itemID,
        itemName = statisticalProfile.itemName,
        configKey = statisticalProfile.configKey,
        -- Craft Analysis pilot only: the produced output's crafting-quality
        -- tier (Q1/Q2/Q3), captured verbatim from the observation - never
        -- parsed out of configKey. nil for input-driven Statistical Profiles
        -- (e.g. Crushing's selected gem), which never set this field.
        craftingQuality = statisticalProfile.craftingQuality,

        runCount = 0,

        consumedTotalsByKey = {},
        producedTotalsByKey = {},
        resourcefulnessTotalsByKey = {},
        observedOutputItemKeys = {},
        observedResourcefulnessItemKeys = {},
        latestSelectedInputEvidence = nil,

        consumedQuantityTotal = 0,
        resourcefulnessQuantityTotal = 0,
        resourcefulnessProcCount = 0,

        multicraftProcCount = 0,
        multicraftExtraTotal = 0,
        multicraftBaseQuantityTotal = 0,
        multicraftTotalQuantityTotal = 0,

        totalHistoricalInputCost = 0,
        totalHistoricalResourcefulnessValue = 0,
        unresolvedInputValuationCount = 0,
        unresolvedResourcefulnessValuationCount = 0,

        craftStats = NewCraftStatsTotals(),

        firstObservedAt = now,
        lastObservedAt = now,
    }
end

local function CopySelectedInputEvidence(evidence)
    local copied = {}
    for _, row in ipairs(type(evidence) == "table" and evidence or {}) do
        if type(row) == "table" then
            copied[#copied + 1] = {
                inputRoleKey = row.inputRoleKey,
                inputRole = row.inputRole,
                itemID = row.itemID,
                itemName = row.itemName,
                itemLink = row.itemLink,
                quantity = row.quantity,
                configKey = row.configKey,
                craftingQuality = row.craftingQuality,
                profileDriver = row.profileDriver == true,
                deterministicOutputDriver = row.deterministicOutputDriver == true,
                selectedCostInput = row.selectedCostInput == true,
                fixedCatalyst = row.fixedCatalyst == true,
                statisticalProfile = row.statisticalProfile == true,
            }
        end
    end
    return copied
end

-- Derives the statisticalProfileKey for one observation's statisticalProfile
-- descriptor (built by OperationObservationBuilder from the input flagged
-- statisticalProfile = true in the ProcessingOperationRegistry entry).
local function DeriveStatisticalProfileKey(statisticalProfile)
    if type(statisticalProfile) ~= "table" then
        return nil
    end
    local key = statisticalProfile.key
        or statisticalProfile.configKey
        or (statisticalProfile.itemID and ("item:" .. tostring(statisticalProfile.itemID)))
    if not key or key == "" then
        return nil
    end
    return key
end

-- Compatibility pass for rows written before the Statistical Profile
-- rename. Idempotent and safe to call on every read/write.
--
-- Rows from that era store real per-context splits under
-- observedSubBucketAggregates (now statisticalProfiles), with each keyed
-- sub-row carrying its identity under subBucketKey instead of
-- statisticalProfileKey. Renaming both is a lossless read of data that's
-- already there - not an inference.
--
-- A small number of pre-architecture development observations never got a
-- proper Statistical Profile entry at all (traced to an early, now-replaced
-- iteration of the bucket-creation write path). Those are not production
-- data and are discarded rather than migrated: no key is fabricated or
-- inferred for them, and any surviving profile that still has no
-- statisticalProfileKey after the subBucketKey rename - i.e. one that never
-- had a captured identity - is dropped. Dropping a profile also removes its
-- contribution to the Operation Profile's runCount, which is recomputed
-- from the surviving Statistical Profiles so the invariant
-- (OperationProfile.runCount == SUM(StatisticalProfile.runCount)) always
-- holds. This is a no-op for current data: RecordObservation always
-- accumulates the row and, when a statisticalProfileKey resolves, the
-- matching profile in the same call from the same derived key, so the two
-- are already in lockstep for every observation recorded since the rename.
local function ReconcileRow(row)
    if type(row) ~= "table" then
        return
    end

    if row.statisticalProfiles == nil and row.observedSubBucketAggregates ~= nil then
        row.statisticalProfiles = row.observedSubBucketAggregates
    end
    row.observedSubBucketAggregates = nil
    -- Retired alongside the old bucket-creation write path; no longer read.
    row.observedSubBuckets = nil
    row.latestObservedSubBucket = nil

    local profiles = row.statisticalProfiles
    if type(profiles) ~= "table" then
        return
    end

    for tableKey, profile in pairs(profiles) do
        if type(profile) == "table" then
            if not profile.statisticalProfileKey or profile.statisticalProfileKey == "" then
                profile.statisticalProfileKey = profile.subBucketKey
            end
            profile.subBucketKey = nil
            if not profile.statisticalProfileKey or profile.statisticalProfileKey == "" then
                profiles[tableKey] = nil
            end
        else
            profiles[tableKey] = nil
        end
    end

    local runCountSum, profileCount = 0, 0
    for _, profile in pairs(profiles) do
        runCountSum = runCountSum + (tonumber(profile.runCount) or 0)
        profileCount = profileCount + 1
    end
    if profileCount > 0 then
        row.runCount = runCountSum
    end
end

local AccumulateCraftStats

local function AccumulateObservationTotals(target, observation, now)
    target.runCount = (target.runCount or 0) + 1
    target.firstObservedAt = target.firstObservedAt or now
    target.lastObservedAt = now

    target.consumedTotalsByKey = target.consumedTotalsByKey or {}
    target.producedTotalsByKey = target.producedTotalsByKey or {}
    target.resourcefulnessTotalsByKey = target.resourcefulnessTotalsByKey or {}
    AccumulateItemRefs(target.consumedTotalsByKey, observation.consumedInputs)
    AccumulateItemRefs(target.producedTotalsByKey, observation.producedOutputs)
    AccumulateItemRefs(target.resourcefulnessTotalsByKey, observation.resourcefulnessReturns)

    target.observedOutputItemKeys = target.observedOutputItemKeys or {}
    target.observedResourcefulnessItemKeys = target.observedResourcefulnessItemKeys or {}
    MarkObservedKeys(target.observedOutputItemKeys, observation.producedOutputs)
    MarkObservedKeys(target.observedResourcefulnessItemKeys, observation.resourcefulnessReturns)
    target.latestSelectedInputEvidence = CopySelectedInputEvidence(observation.selectedInputEvidence)

    target.consumedQuantityTotal = (target.consumedQuantityTotal or 0) + SumQuantities(observation.consumedInputs)
    target.resourcefulnessQuantityTotal = (target.resourcefulnessQuantityTotal or 0) + SumQuantities(observation.resourcefulnessReturns)
    if type(observation.resourcefulnessReturns) == "table" and #observation.resourcefulnessReturns > 0 then
        target.resourcefulnessProcCount = (target.resourcefulnessProcCount or 0) + 1
    end

    local multicraft = observation.multicraft or {}
    target.multicraftTotalQuantityTotal = (target.multicraftTotalQuantityTotal or 0) + (tonumber(multicraft.totalQuantity) or 0)
    target.multicraftBaseQuantityTotal = (target.multicraftBaseQuantityTotal or 0) + (tonumber(multicraft.baseQuantity) or 0)
    target.multicraftExtraTotal = (target.multicraftExtraTotal or 0) + (tonumber(multicraft.extraQuantity) or 0)
    if multicraft.occurred then
        target.multicraftProcCount = (target.multicraftProcCount or 0) + 1
    end

    -- Historical monetary facts: nil on observations the enricher never
    -- touched (e.g. Processing operations, or Crafting Operations recorded
    -- before this feature existed) contribute zero, exactly like any other
    -- untracked observation - never repriced, never backfilled.
    target.totalHistoricalInputCost = (target.totalHistoricalInputCost or 0) + (tonumber(observation.historicalInputCost) or 0)
    target.totalHistoricalResourcefulnessValue = (target.totalHistoricalResourcefulnessValue or 0) + (tonumber(observation.historicalResourcefulnessValue) or 0)
    target.unresolvedInputValuationCount = (target.unresolvedInputValuationCount or 0) + (tonumber(observation.unresolvedInputValuationCount) or 0)
    target.unresolvedResourcefulnessValuationCount = (target.unresolvedResourcefulnessValuationCount or 0) + (tonumber(observation.unresolvedResourcefulnessValuationCount) or 0)

    target.craftStats = target.craftStats or NewCraftStatsTotals()
    AccumulateCraftStats(target.craftStats, observation.craftStats)
end

function AccumulateCraftStats(totals, craftStats)
    craftStats = craftStats or {}

    if craftStats.skillAtCraft ~= nil then
        totals.skillAtCraftTotal = totals.skillAtCraftTotal + (tonumber(craftStats.skillAtCraft) or 0)
        totals.skillAtCraftCount = totals.skillAtCraftCount + 1
    end
    if craftStats.resourcefulnessPct ~= nil then
        totals.resourcefulnessPctTotal = totals.resourcefulnessPctTotal + (tonumber(craftStats.resourcefulnessPct) or 0)
        totals.resourcefulnessPctCount = totals.resourcefulnessPctCount + 1
    end

    -- multicraftApplicable distinguishes "operation supports multicraft" from
    -- "operation cannot multicraft" (prospecting, milling, etc.).
    if craftStats.multicraftApplicable then
        totals.multicraftApplicableRunCount = (totals.multicraftApplicableRunCount or 0) + 1
    end
    if craftStats.multicraftPct ~= nil then
        totals.multicraftPctTotal = totals.multicraftPctTotal + (tonumber(craftStats.multicraftPct) or 0)
        totals.multicraftPctCount = totals.multicraftPctCount + 1
    end

    local concentrationSpent = tonumber(craftStats.concentrationSpent) or 0
    totals.concentrationSpentTotal = (totals.concentrationSpentTotal or 0) + concentrationSpent

    -- Ingenuity only applies when concentration was actually used.
    -- concentrationCraftCount is the correct denominator for all ingenuity
    -- averages; do not use runCount or the old ingenuityPctCount.
    if concentrationSpent > 0 then
        totals.concentrationCraftCount = (totals.concentrationCraftCount or 0) + 1
        if craftStats.ingenuityPct ~= nil then
            totals.ingenuityPctTotal = (totals.ingenuityPctTotal or 0) + (tonumber(craftStats.ingenuityPct) or 0)
        end
        if craftStats.hadIngenuityProc then
            totals.ingenuityProcCount = (totals.ingenuityProcCount or 0) + 1
            totals.concentrationReturnedTotal = (totals.concentrationReturnedTotal or 0) + (tonumber(craftStats.ingenuityRefund) or 0)
        end
    end
end

local function NormalizeCraftingQuality(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function FindCrushingPrimaryGem(observation)
    for _, row in ipairs(type(observation and observation.selectedInputEvidence) == "table" and observation.selectedInputEvidence or {}) do
        if type(row) == "table" and row.statisticalProfile == true then
            return row
        end
    end
    for _, row in ipairs(type(observation and observation.consumedInputs) == "table" and observation.consumedInputs or {}) do
        if type(row) == "table" and (row.selectedCostInput == true or row.statisticalProfile == true) then
            return row
        end
    end
    return nil
end

local function CrushingOutputFamily(row)
    local name = row and row.itemName and tostring(row.itemName):lower() or nil
    if not name or name == "" then
        return nil, "missingOutputName"
    end
    if name:find("dust", 1, true) then
        return "dust"
    end
    if name:find("glass", 1, true) then
        return "glass"
    end
    return nil, nil
end

local function NotifyCrushingQualityRejected()
    local msg = "PocketCFO: Crushing result was not recorded because the output quality did not match the quality of the gems used."
    if PocketCFO and PocketCFO.Print then
        PocketCFO:Print(msg)
    elseif DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

local function ValidateCrushingOutputQuality(observation)
    local entry = GetProcessingEntry(observation and observation.recipeID)
    if not entry or entry.processingType ~= "crushing" then
        return nil
    end

    local primaryGem = FindCrushingPrimaryGem(observation)
    local primaryQuality = NormalizeCraftingQuality(primaryGem and primaryGem.craftingQuality)

    SessionLog("OperationOutcomeService: Crushing quality validation profileKey=%s recipeID=%s primaryItemID=%s primaryName=%s primaryQuality=%s",
        tostring(observation and observation.operationProfileKey),
        tostring(observation and observation.recipeID),
        tostring(primaryGem and primaryGem.itemID),
        tostring(primaryGem and primaryGem.itemName),
        tostring(primaryQuality))

    if not primaryGem then
        return "crushingPrimaryGemUnavailable"
    end
    if not primaryQuality then
        return "crushingPrimaryGemQualityUnavailable"
    end

    for _, row in ipairs(type(observation.producedOutputs) == "table" and observation.producedOutputs or {}) do
        local family, familyReason = CrushingOutputFamily(row)
        if familyReason == "missingOutputName" then
            SessionLog("OperationOutcomeService: Crushing quality validation output rejected itemID=%s reason=missingOutputName",
                tostring(row and row.itemID))
            return "crushingOutputFamilyUnavailable"
        end
        if family then
            local outputQuality = NormalizeCraftingQuality(row.craftingQuality)
            SessionLog("OperationOutcomeService: Crushing quality validation output family=%s itemID=%s itemName=%s outputQuality=%s primaryQuality=%s",
                tostring(family), tostring(row.itemID), tostring(row.itemName),
                tostring(outputQuality), tostring(primaryQuality))
            if not outputQuality then
                return "crushingOutputQualityUnavailable"
            end
            if outputQuality ~= primaryQuality then
                NotifyCrushingQualityRejected()
                return "crushingOutputQualityMismatch"
            end
        end
    end

    SessionLog("OperationOutcomeService: Crushing quality validation accepted profileKey=%s recipeID=%s primaryQuality=%s",
        tostring(observation and observation.operationProfileKey),
        tostring(observation and observation.recipeID),
        tostring(primaryQuality))

    return nil
end

local function FindRecyclingPrimaryInput(observation)
    for _, row in ipairs(type(observation and observation.selectedInputEvidence) == "table" and observation.selectedInputEvidence or {}) do
        if type(row) == "table" and row.profileDriver == true then
            return row
        end
    end
    for _, row in ipairs(type(observation and observation.consumedInputs) == "table" and observation.consumedInputs or {}) do
        if type(row) == "table" and (row.profileDriver == true or row.selectedCostInput == true) then
            return row
        end
    end
    return nil
end

local function RecyclingOutputFamily(row)
    local name = row and row.itemName and tostring(row.itemName):lower() or nil
    if not name or name == "" then
        return nil
    end
    if name:find("evercore", 1, true) then
        return "evercore"
    end
    if name:find("aetherlume", 1, true) then
        return "aetherlume"
    end
    return nil
end

local function NotifyRecyclingRejected()
    local msg = "Unexpected Midnight Recycling result: input quality did not match output quality. This operation was not included in recycling statistics."
    if PocketCFO and PocketCFO.Print then
        PocketCFO:Print(msg)
    elseif DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

local function ValidateEngineeringRecyclingQuality(observation)
    local entry = GetProcessingEntry(observation and observation.recipeID)
    if not entry or entry.processingType ~= "engineeringRecycling" then
        return nil
    end

    local primaryInput = FindRecyclingPrimaryInput(observation)
    local inputQuality = NormalizeCraftingQuality(primaryInput and primaryInput.craftingQuality)

    SessionLog("OperationOutcomeService: Recycling quality validation profileKey=%s recipeID=%s inputItemID=%s inputConfigKey=%s inputQuality=%s",
        tostring(observation and observation.operationProfileKey),
        tostring(observation and observation.recipeID),
        tostring(primaryInput and primaryInput.itemID),
        tostring(primaryInput and primaryInput.configKey),
        tostring(inputQuality))

    if not inputQuality then
        NotifyRecyclingRejected()
        return "recycling_input_quality_unresolved"
    end

    local relevantCount = 0
    local observedOutputQuality = nil
    for _, row in ipairs(type(observation.producedOutputs) == "table" and observation.producedOutputs or {}) do
        local family = RecyclingOutputFamily(row)
        if family then
            relevantCount = relevantCount + 1
            local outputQuality = NormalizeCraftingQuality(row.craftingQuality)
            SessionLog("OperationOutcomeService: Recycling quality validation output family=%s itemID=%s itemName=%s configKey=%s outputQuality=%s inputQuality=%s qty=%s",
                tostring(family), tostring(row.itemID), tostring(row.itemName), tostring(row.configKey),
                tostring(outputQuality), tostring(inputQuality), tostring(row.quantity))
            if not outputQuality then
                NotifyRecyclingRejected()
                return "recycling_output_quality_unresolved"
            end
            if observedOutputQuality and observedOutputQuality ~= outputQuality then
                NotifyRecyclingRejected()
                return "recycling_mixed_output_quality"
            end
            observedOutputQuality = outputQuality
            if outputQuality ~= inputQuality then
                NotifyRecyclingRejected()
                return "recycling_quality_mismatch"
            end
        end
    end

    if relevantCount == 0 then
        NotifyRecyclingRejected()
        return "recycling_output_quality_unresolved"
    end

    SessionLog("OperationOutcomeService: Recycling quality validation accepted profileKey=%s recipeID=%s inputQuality=%s outputQuality=%s relevantOutputs=%d",
        tostring(observation and observation.operationProfileKey),
        tostring(observation and observation.recipeID),
        tostring(inputQuality), tostring(observedOutputQuality), relevantCount)

    return nil
end

local ALCHEMY_RECYCLING_OUTPUT_ITEM_ID = 242651

local function FindRoleByPredicate(entry, predicate)
    for _, role in ipairs(type(entry and entry.inputRoles) == "table" and entry.inputRoles or {}) do
        if type(role) == "table" and predicate(role) then
            return role
        end
    end
    return nil
end

local function FindConsumedInputForRole(observation, role)
    if type(role) ~= "table" then
        return nil
    end
    for _, row in ipairs(type(observation and observation.consumedInputs) == "table" and observation.consumedInputs or {}) do
        if type(row) == "table" then
            if role.fixedItemID and tonumber(row.itemID) == tonumber(role.fixedItemID) then
                return row
            end
            if role.profileDriver == true and row.profileDriver == true then
                return row
            end
        end
    end
    return nil
end

local function BuildConsumedKeySet(observation)
    local set = {}
    for _, row in ipairs(type(observation and observation.consumedInputs) == "table" and observation.consumedInputs or {}) do
        local key = ItemRefKey(row)
        if key then
            set[key] = true
        end
    end
    return set
end

local function ValidateAndSanitizeAlchemyRecyclingObservation(observation)
    local entry = GetProcessingEntry(observation and observation.recipeID)
    if not entry or entry.processingType ~= "alchemyRecycling" then
        return nil
    end

    if not observation.primaryInputConfigKey or observation.primaryInputConfigKey == "" then
        return "alchemyRecyclingPrimaryInputUnresolved"
    end

    local primaryRole = FindRoleByPredicate(entry, function(role) return role.profileDriver == true end)
    local oilRole = FindRoleByPredicate(entry, function(role)
        return tonumber(role.fixedItemID) == 247811
    end)
    local primaryInput = FindConsumedInputForRole(observation, primaryRole)
    local oilInput = FindConsumedInputForRole(observation, oilRole)

    if not primaryInput or not primaryInput.configKey then
        return "alchemyRecyclingPrimaryInputUnresolved"
    end
    if tonumber(primaryInput.quantity) ~= tonumber(primaryRole and primaryRole.quantityRequired) then
        return "alchemyRecyclingPrimaryInputQuantityMismatch"
    end
    if not oilInput then
        return "alchemyRecyclingOilInputMissing"
    end
    if tonumber(oilInput.quantity) ~= tonumber(oilRole and oilRole.quantityRequired) then
        return "alchemyRecyclingOilInputQuantityMismatch"
    end

    -- Pricing is never a gate on whether a completed operation is recorded -
    -- OperationHistoricalValuationEnricher's own contract is that an unpriced
    -- item contributes zero to the sum and is never grounds to exclude the
    -- run (see its header comment). A brand-new/rare reagent (e.g. a flask
    -- with no resolved market price yet) must still produce a Statistical
    -- Profile; "needs price" is a display-layer state
    -- (ProcessingAnalysisDisplayModelBuilder.VALUE_UNAVAILABLE_NEEDS_PRICE),
    -- not a reason to drop the observation.

    local consumedKeys = BuildConsumedKeySet(observation)
    local derivateQuantity = 0
    local sanitizedOutputs = {}
    for _, row in ipairs(type(observation.producedOutputs) == "table" and observation.producedOutputs or {}) do
        if tonumber(row and row.itemID) == ALCHEMY_RECYCLING_OUTPUT_ITEM_ID then
            row.itemName = row.itemName or "Stabilized Derivate"
            row.craftingQuality = nil
            derivateQuantity = derivateQuantity + NormalizeQuantity(row.quantity)
            sanitizedOutputs[#sanitizedOutputs + 1] = row
        elseif consumedKeys[ItemRefKey(row)] then
            observation.resourcefulnessReturns = observation.resourcefulnessReturns or {}
            observation.resourcefulnessReturns[#observation.resourcefulnessReturns + 1] = row
            SessionLog("OperationOutcomeService: Alchemy Recycling routed produced consumed reagent to resourcefulness profileKey=%s itemID=%s itemName=%s qty=%s",
                tostring(observation.operationProfileKey), tostring(row and row.itemID),
                tostring(row and row.itemName), tostring(row and row.quantity))
        else
            SessionLog("OperationOutcomeService: Alchemy Recycling discarded unexpected non-Derivate output profileKey=%s itemID=%s itemName=%s qty=%s",
                tostring(observation.operationProfileKey), tostring(row and row.itemID),
                tostring(row and row.itemName), tostring(row and row.quantity))
        end
    end

    if derivateQuantity <= 0 then
        return "alchemyRecyclingDerivateOutputMissing"
    end

    observation.producedOutputs = sanitizedOutputs
    return nil
end

-- ---------------------------------------------------------------------------
-- Milling validation (exact quality match, single pigment identity,
-- herb->pigment self-discovery, resourcefulness identity sanitation)
-- ---------------------------------------------------------------------------
-- Unlike Crushing (dust+glass are both legitimate outputs, and only a
-- downgrade is rejected), Milling has no legitimate byproducts and requires
-- EXACT quality equality between the selected herb and the produced pigment
-- in both directions. It also has no curated herb->pigment table - the first
-- valid observation per Operation Profile establishes it, stored directly on
-- that profile's own aggregate row (row.millingKnownPigment) rather than a
-- second mapping database, mirroring how Crushing's quality validation
-- already lives next to this row's own accumulation instead of a separate
-- service.
--
-- This function both validates (returns a rejection reason or nil) AND
-- sanitizes observation.producedOutputs/resourcefulnessReturns in place when
-- accepting - the only way to honor "discard unrelated byproducts"/"ignore
-- unrelated return identities" without rejecting the whole observation, since
-- ValidateObservation is the last hook that runs before RecordObservation
-- accumulates those exact fields.

local function NotifyMillingRejected(message)
    if PocketCFO and PocketCFO.Print then
        PocketCFO:Print(message)
    elseif DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(message)
    end
end

local function GetMillingKnownPigment(profileKey)
    local globalDB = GetGlobalDB()
    local store = globalDB and globalDB.operationOutcomes
    local row = store and profileKey and store[profileKey]
    return row and row.millingKnownPigment
end

-- Groups producedOutputs by the same configKey-or-item:itemID identity
-- formula ItemRefKey/AccumulateItemRefs already use to build
-- producedTotalsByKey, so "one distinct produced item" here always means the
-- same thing it means once RecordObservation accumulates it.
local function GroupProducedOutputsByIdentity(producedOutputs)
    local grouped, order = {}, {}
    for _, row in ipairs(type(producedOutputs) == "table" and producedOutputs or {}) do
        local key = ItemRefKey(row)
        if key then
            if not grouped[key] then
                grouped[key] = { row = row, quantityTotal = 0 }
                order[#order + 1] = key
            end
            grouped[key].quantityTotal = grouped[key].quantityTotal + NormalizeQuantity(row.quantity)
        end
    end
    return grouped, order
end

local function ValidateAndSanitizeMillingObservation(observation)
    local entry = GetProcessingEntry(observation and observation.recipeID)
    if not entry or entry.processingType ~= "milling" then
        return nil
    end

    local primaryHerb = FindPrimaryInputEvidence(observation)
    local herbConfigKey = primaryHerb and (primaryHerb.configKey
        or (primaryHerb.itemID and ("item:" .. tostring(primaryHerb.itemID))))
    local herbQuality = NormalizeCraftingQuality(primaryHerb and primaryHerb.craftingQuality)

    SessionLog("OperationOutcomeService: Milling validation profileKey=%s recipeID=%s herbItemID=%s herbConfigKey=%s herbQuality=%s",
        tostring(observation.operationProfileKey), tostring(observation.recipeID),
        tostring(primaryHerb and primaryHerb.itemID), tostring(herbConfigKey), tostring(herbQuality))

    if not primaryHerb or not herbConfigKey then
        return "millingPrimaryHerbUnavailable"
    end
    if not herbQuality then
        return "millingPrimaryHerbQualityUnavailable"
    end

    -- Output cardinality: exactly one distinct pigment identity. When a
    -- known pigment is already established for this profile, any other
    -- identity present alongside it is an unexpected byproduct - discarded
    -- and diagnosed, never merged. Without a known pigment yet, more than
    -- one distinct identity is structurally invalid (no way to tell which
    -- one is "the" pigment), so the whole observation is rejected instead of
    -- guessed, and no herb->pigment relationship is learned from it.
    local grouped, order = GroupProducedOutputsByIdentity(observation.producedOutputs)
    local knownPigment = GetMillingKnownPigment(observation.operationProfileKey)

    if #order == 0 then
        return "millingNoProducedPigment"
    end

    if #order > 1 then
        if knownPigment and knownPigment.configKey and grouped[knownPigment.configKey] then
            for _, key in ipairs(order) do
                if key ~= knownPigment.configKey then
                    SessionLog("OperationOutcomeService: Milling discarded unexpected produced item profileKey=%s key=%s itemID=%s itemName=%s qty=%s",
                        tostring(observation.operationProfileKey), tostring(key),
                        tostring(grouped[key].row.itemID), tostring(grouped[key].row.itemName),
                        tostring(grouped[key].quantityTotal))
                end
            end
            observation.producedOutputs = { grouped[knownPigment.configKey].row }
            grouped, order = GroupProducedOutputsByIdentity(observation.producedOutputs)
        else
            SessionLog("OperationOutcomeService: Milling rejected multiple pigment identities profileKey=%s distinctOutputs=%d",
                tostring(observation.operationProfileKey), #order)
            return "millingMultiplePigmentIdentities"
        end
    end

    local pigmentKey = order[1]
    local pigmentEntry = pigmentKey and grouped[pigmentKey]
    if not pigmentEntry then
        return "millingPigmentUnavailable"
    end
    local pigmentQuality = NormalizeCraftingQuality(pigmentEntry.row.craftingQuality)
    if not pigmentQuality then
        return "millingPigmentQualityUnavailable"
    end

    SessionLog("OperationOutcomeService: Milling quality check profileKey=%s herbQuality=%s pigmentItemID=%s pigmentQuality=%s",
        tostring(observation.operationProfileKey), tostring(herbQuality),
        tostring(pigmentEntry.row.itemID), tostring(pigmentQuality))

    if pigmentQuality ~= herbQuality then
        if pigmentQuality > herbQuality then
            NotifyMillingRejected("This milling result was not recorded because the pigment quality was higher than the herb quality. Concentration or another quality-increasing effect appears to have been used.")
            SessionLog("OperationOutcomeService: Milling rejected output quality higher than input (concentration mismatch) profileKey=%s herbQuality=%s pigmentQuality=%s",
                tostring(observation.operationProfileKey), tostring(herbQuality), tostring(pigmentQuality))
            return "millingOutputQualityHigherThanInput"
        end
        NotifyMillingRejected("This milling result was not recorded because a high-quality herb produced lower-quality pigment. Increase milling skill before collecting high-quality herb data.")
        SessionLog("OperationOutcomeService: Milling rejected output quality lower than input (skill mismatch) profileKey=%s herbQuality=%s pigmentQuality=%s",
            tostring(observation.operationProfileKey), tostring(herbQuality), tostring(pigmentQuality))
        return "millingOutputQualityLowerThanInput"
    end

    if knownPigment and knownPigment.configKey and knownPigment.configKey ~= pigmentKey then
        NotifyMillingRejected("This milling result was not recorded because it produced a different pigment than previously observed for this herb.")
        SessionLog("OperationOutcomeService: Milling rejected conflicting pigment identity profileKey=%s knownPigment=%s observedPigment=%s",
            tostring(observation.operationProfileKey), tostring(knownPigment.configKey), tostring(pigmentKey))
        return "millingConflictingPigmentIdentity"
    end

    -- Resourcefulness identity: only returns matching the exact herb
    -- identity are valid. CraftCompletionDispatcher's BufferProcessingEvent
    -- already routes same-itemID returns into resourcefulnessReturns for
    -- every recipePlusPrimaryInput processing type (Prospecting, Milling),
    -- so this is a defensive sanitation pass, not the primary filter - any
    -- surviving mismatch is diagnosed and discarded rather than aggregated.
    local validReturns, discardedCount = {}, 0
    for _, row in ipairs(type(observation.resourcefulnessReturns) == "table" and observation.resourcefulnessReturns or {}) do
        local key = ItemRefKey(row)
        if key == herbConfigKey then
            validReturns[#validReturns + 1] = row
        else
            discardedCount = discardedCount + 1
            SessionLog("OperationOutcomeService: Milling discarded unexpected resourcefulness return profileKey=%s key=%s itemID=%s itemName=%s qty=%s",
                tostring(observation.operationProfileKey), tostring(key),
                tostring(row.itemID), tostring(row.itemName), tostring(row.quantity))
        end
    end
    observation.resourcefulnessReturns = validReturns

    SessionLog("OperationOutcomeService: Milling validation accepted profileKey=%s herbConfigKey=%s herbQuality=%s pigmentKey=%s pigmentQuality=%s pigmentQty=%s resourcefulnessValid=%d resourcefulnessDiscarded=%d",
        tostring(observation.operationProfileKey), tostring(herbConfigKey), tostring(herbQuality),
        tostring(pigmentKey), tostring(pigmentQuality), tostring(pigmentEntry.quantityTotal),
        #validReturns, discardedCount)

    return nil
end

-- ---------------------------------------------------------------------------
-- Validation
-- ---------------------------------------------------------------------------

-- Returns a rejection reason string, or nil if the observation is acceptable.
-- Never guesses missing identity - an incomplete observation is rejected,
-- not patched up.
function OperationOutcomeService:ValidateObservation(observation, options)
    options = type(options) == "table" and options or {}

    if type(observation) ~= "table" then
        return "observationNotTable"
    end
    if observation.unresolved then
        return observation.unresolvedReason or "observationUnresolved"
    end
    if not observation.operationProfileKey or observation.operationProfileKey == "" then
        return "missingOperationProfileKey"
    end
    if type(observation.producedOutputs) ~= "table" or #observation.producedOutputs == 0 then
        if not options.allowNoOutputs then
            return "noProducedOutputs"
        end
    end

    local processingRejection = ValidateCrushingOutputQuality(observation)
    if processingRejection then
        return processingRejection
    end

    local millingRejection = ValidateAndSanitizeMillingObservation(observation)
    if millingRejection then
        return millingRejection
    end

    local recyclingRejection = ValidateEngineeringRecyclingQuality(observation)
    if recyclingRejection then
        return recyclingRejection
    end

    local alchemyRecyclingRejection = ValidateAndSanitizeAlchemyRecyclingObservation(observation)
    if alchemyRecyclingRejection then
        return alchemyRecyclingRejection
    end

    return nil
end

local function CopyRejectionRows(rows)
    local copied = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if type(row) == "table" then
            copied[#copied + 1] = {
                itemID = row.itemID,
                configKey = row.configKey,
                itemName = row.itemName,
                craftingQuality = row.craftingQuality,
                quantity = row.quantity,
            }
        end
    end
    return copied
end

local function BuildRecyclingRejectionRecord(reason, observation)
    local primaryInput = FindRecyclingPrimaryInput(observation)
    return {
        timestamp = PocketCFO and PocketCFO.GetServerNow and PocketCFO:GetServerNow() or time(),
        reason = reason,
        recipeID = observation and observation.recipeID,
        operationProfileKey = observation and observation.operationProfileKey,
        inputItemID = primaryInput and primaryInput.itemID,
        inputConfigKey = primaryInput and primaryInput.configKey,
        inputCraftingQuality = primaryInput and primaryInput.craftingQuality,
        inputQuantity = primaryInput and primaryInput.quantity,
        outputs = CopyRejectionRows(observation and observation.producedOutputs),
        resourcefulnessReturns = CopyRejectionRows(observation and observation.resourcefulnessReturns),
    }
end

-- Structured rejection record for a rejected Alchemy Recycling observation
-- (see ValidateAndSanitizeAlchemyRecyclingObservation). Reports every field
-- CLAUDE.md's debug discipline requires to diagnose a dropped recycle
-- without re-guessing role assignment from scratch: which reagent rows were
-- actually consumed, which registry role each is supposed to occupy, which
-- one resolved as the primary/fixed input (if any), the Derivate quantity
-- produced, the generated profile key, and the rejection reason itself.
local function BuildAlchemyRecyclingRejectionRecord(reason, observation)
    local entry = GetProcessingEntry(observation and observation.recipeID)
    local primaryRole = FindRoleByPredicate(entry, function(role) return role.profileDriver == true end)
    local oilRole = FindRoleByPredicate(entry, function(role)
        return tonumber(role.fixedItemID) == 247811
    end)
    local primaryInput = FindConsumedInputForRole(observation, primaryRole)
    local oilInput = FindConsumedInputForRole(observation, oilRole)

    local derivateQuantity = 0
    for _, row in ipairs(type(observation and observation.producedOutputs) == "table" and observation.producedOutputs or {}) do
        if tonumber(row and row.itemID) == ALCHEMY_RECYCLING_OUTPUT_ITEM_ID then
            derivateQuantity = derivateQuantity + NormalizeQuantity(row.quantity)
        end
    end

    return {
        timestamp = PocketCFO and PocketCFO.GetServerNow and PocketCFO:GetServerNow() or time(),
        reason = reason,
        recipeID = observation and observation.recipeID,
        operationProfileKey = observation and observation.operationProfileKey,
        primaryInputRoleKey = primaryRole and primaryRole.key,
        primaryInputItemID = primaryInput and primaryInput.itemID,
        primaryInputConfigKey = primaryInput and primaryInput.configKey,
        primaryInputQuantity = primaryInput and primaryInput.quantity,
        oilRoleKey = oilRole and oilRole.key,
        oilItemID = (oilInput and oilInput.itemID) or (oilRole and oilRole.fixedItemID),
        oilConfigKey = oilInput and oilInput.configKey,
        oilQuantity = oilInput and oilInput.quantity,
        derivateQuantity = derivateQuantity,
        consumedInputs = CopyRejectionRows(observation and observation.consumedInputs),
        outputs = CopyRejectionRows(observation and observation.producedOutputs),
    }
end

-- Reasons that only mean "pricing hasn't resolved yet" - never worth a chat
-- message, since the gameplay observation itself is still valid and was
-- already recorded (or, for a hard capture failure, pricing was never the
-- cause). Matched by substring so any future valuation-only reason name is
-- covered without maintaining an exact enumeration.
local function IsPricingOnlyReason(reason)
    reason = type(reason) == "string" and reason:lower() or ""
    return reason:find("valuation", 1, true) ~= nil or reason:find("price", 1, true) ~= nil
end

local ALCHEMY_RECYCLING_FAILURE_MESSAGES = {
    alchemyRecyclingPrimaryInputUnresolved = "selected flask/potion input was not resolved.",
    alchemyRecyclingPrimaryInputQuantityMismatch = "consumed flask/potion quantity did not match the expected amount.",
    alchemyRecyclingOilInputMissing = "Oil of Heartwood was not detected as a consumed input.",
    alchemyRecyclingOilInputQuantityMismatch = "consumed Oil of Heartwood quantity did not match the expected amount.",
    alchemyRecyclingDerivateOutputMissing = "no Stabilized Derivate output was detected.",
    missingRecipeID = "the recipe could not be identified from the completion event.",
    missingOperationProfileKey = "no operation profile key could be generated.",
    operationProfileKeyUnresolved = "no operation profile key could be generated.",
    missingPrimaryInputIdentity = "selected flask/potion input was not resolved.",
    observationUnresolved = "the completed operation could not be resolved.",
    processingObservationBuilderUnavailable = "an internal service was unavailable.",
    processingObservationBuildReturnedNil = "the completed operation could not be resolved.",
}

-- User-facing notice for a completed Alchemy Recycling operation that could
-- not be recorded, for a reason other than pricing (see IsPricingOnlyReason)
-- - the task's example: "PocketCFO could not record this Alchemy recycle:
-- selected flask input was not resolved." Never fires for missing/incomplete
-- valuation; that is expected and handled entirely by the display layer.
local function NotifyAlchemyRecyclingCaptureFailure(reason)
    if IsPricingOnlyReason(reason) then
        return
    end
    local detail = ALCHEMY_RECYCLING_FAILURE_MESSAGES[reason] or ("reason: " .. tostring(reason))
    local msg = "PocketCFO could not record this Alchemy recycle: " .. detail
    if PocketCFO and PocketCFO.Print then
        PocketCFO:Print(msg)
    elseif DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(msg)
    end
end

-- Fallback structured record for a rejected/unresolved observation whose
-- recipeID resolves to a registered Processing Operation but whose rejection
-- reason doesn't match a more specific builder above (e.g. generic
-- "missingRecipeID"/"operationProfileKeyUnresolved" reasons, which never
-- matched the old ^alchemyRecycling/^recycling_ string-prefix gate and so
-- never produced a visible record even though the counter incremented).
local function BuildGenericProcessingRejectionRecord(reason, observation)
    return {
        timestamp = PocketCFO and PocketCFO.GetServerNow and PocketCFO:GetServerNow() or time(),
        reason = reason,
        recipeID = observation and observation.recipeID,
        operationProfileKey = observation and observation.operationProfileKey,
        consumedInputs = CopyRejectionRows(observation and observation.consumedInputs),
        outputs = CopyRejectionRows(observation and observation.producedOutputs),
        selectedInputEvidence = CopyRejectionRows(observation and observation.selectedInputEvidence),
    }
end

function OperationOutcomeService:RecordRejectionDiagnostic(reason, observation)
    self.rejectionDiagnostics[reason] = (self.rejectionDiagnostics[reason] or 0) + 1

    local processingEntry = GetProcessingEntry(observation and observation.recipeID)
    local record = nil
    if type(reason) == "string" and reason:match("^recycling_") then
        record = BuildRecyclingRejectionRecord(reason, observation)
    elseif type(reason) == "string" and reason:match("^alchemyRecycling") then
        record = BuildAlchemyRecyclingRejectionRecord(reason, observation)
        NotifyAlchemyRecyclingCaptureFailure(reason)
    elseif processingEntry then
        -- Any other rejection for a registered Processing Operation must
        -- still surface a structured record - do not rely on the reason
        -- string matching a specific processing type's prefix.
        record = BuildGenericProcessingRejectionRecord(reason, observation)
        if processingEntry.processingType == "alchemyRecycling" then
            NotifyAlchemyRecyclingCaptureFailure(reason)
        end
    end

    if record then
        self.rejectionRecords[#self.rejectionRecords + 1] = record
        while #self.rejectionRecords > 25 do
            table.remove(self.rejectionRecords, 1)
        end
    end

    SessionLog("OperationOutcomeService: observation rejected reason=%s profileKey=%s recipeID=%s",
        tostring(reason),
        tostring(observation and observation.operationProfileKey),
        tostring(observation and observation.recipeID))
end

-- Structured record for a completion that failed BEFORE ever reaching
-- RecordObservation/ValidateObservation above (e.g. OperationObservationBuilder
-- unavailable, or CraftCompletionDispatcher's processing batch flush
-- returning nil) - these previously left no trace anywhere but SessionLog,
-- so a registered Processing Operation could silently lose a completed
-- craft with nothing visible in /mcgd operation summary. Written into the
-- same rejectionRecords/rejectionDiagnostics store so it surfaces through
-- the existing diagnostic surface without adding a new one.
-- @param reason string
-- @param details table|nil { recipeID, stage, operationProfileKey,
--        consumedInputs, producedOutputs, primaryInputItemID,
--        primaryInputConfigKey }
function OperationOutcomeService:RecordProcessingCaptureFailure(reason, details)
    details = type(details) == "table" and details or {}
    self.rejectionDiagnostics[reason] = (self.rejectionDiagnostics[reason] or 0) + 1

    local record = {
        timestamp = PocketCFO and PocketCFO.GetServerNow and PocketCFO:GetServerNow() or time(),
        reason = reason,
        stage = details.stage,
        recipeID = details.recipeID,
        operationProfileKey = details.operationProfileKey,
        consumedInputs = CopyRejectionRows(details.consumedInputs),
        outputs = CopyRejectionRows(details.producedOutputs),
        primaryInputItemID = details.primaryInputItemID,
        primaryInputConfigKey = details.primaryInputConfigKey,
    }
    self.rejectionRecords[#self.rejectionRecords + 1] = record
    while #self.rejectionRecords > 25 do
        table.remove(self.rejectionRecords, 1)
    end

    local processingEntry = GetProcessingEntry(details.recipeID)
    if processingEntry and processingEntry.processingType == "alchemyRecycling" then
        NotifyAlchemyRecyclingCaptureFailure(reason)
    end

    SessionLog("OperationOutcomeService: processing capture failure stage=%s reason=%s recipeID=%s",
        tostring(details.stage), tostring(reason), tostring(details.recipeID))
end

function OperationOutcomeService:GetRejectionDiagnostics()
    return self.rejectionDiagnostics
end

function OperationOutcomeService:GetRejectionRecords()
    return self.rejectionRecords
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

function OperationOutcomeService:GetStore()
    local globalDB = GetGlobalDB()
    if not globalDB then
        return nil
    end
    globalDB.operationOutcomes = globalDB.operationOutcomes or {}
    return globalDB.operationOutcomes
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Records one normalized OperationObservation into its aggregate row.
-- @param observation table built by PocketCFO_Crafting's OperationObservationBuilder
-- @param options table|nil { allowNoOutputs = true } to permit recording
--        processing observations with no resolvable output (still rejected
--        by default; this is the explicit-allow escape hatch the
--        architecture calls for, not a default behavior).
-- @return boolean success, string|nil rejectionReason
function OperationOutcomeService:RecordObservation(observation, options)
    local rejectionReason = self:ValidateObservation(observation, options)
    if rejectionReason then
        self:RecordRejectionDiagnostic(rejectionReason, observation)
        return false, rejectionReason
    end

    local store = self:GetStore()
    if not store then
        self:RecordRejectionDiagnostic("coreDatabaseUnavailable", observation)
        return false, "coreDatabaseUnavailable"
    end

    local profileKey = observation.operationProfileKey
    local now = PocketCFO and PocketCFO.GetServerNow and PocketCFO:GetServerNow() or time()

    SessionLog("OperationOutcomeService: ingest profileKey=%s recipeID=%s profileKeyMode=%s",
        tostring(profileKey), tostring(observation.recipeID), tostring(observation.profileKeyMode))
    LogObservationRefs("ingestConsumedInputs", observation.consumedInputs)
    LogObservationRefs("ingestSelectedInputEvidence", observation.selectedInputEvidence)
    LogStatisticalProfile("ingestStatisticalProfile", observation.statisticalProfile)

    local row = store[profileKey]
    if not row then
        row = NewAggregateRow(observation, now)
        store[profileKey] = row
    end
    ReconcileRow(row)

    row.operationType = observation.operationType or row.operationType
    row.profileKeyMode = observation.profileKeyMode or row.profileKeyMode
    row.recipeID = row.recipeID or observation.recipeID
    row.professionID = row.professionID or observation.professionID
    row.expansionID = row.expansionID or observation.expansionID
    row.childSkillLineID = row.childSkillLineID or observation.childSkillLineID

    local runCountBefore = row.runCount or 0

    AccumulateObservationTotals(row, observation, now)

    -- Milling: learn the herb->pigment identity from the first validated
    -- observation for this profile. ValidateAndSanitizeMillingObservation
    -- already guarantees exactly one distinct produced identity survives in
    -- observation.producedOutputs, and already rejected (before reaching
    -- here) any observation whose pigment conflicts with an already-known
    -- one - so this only ever sets row.millingKnownPigment once, never
    -- overwrites it.
    if not row.millingKnownPigment then
        local millingEntry = GetProcessingEntry(observation.recipeID)
        if millingEntry and millingEntry.processingType == "milling" then
            local pigmentRow = type(observation.producedOutputs) == "table" and observation.producedOutputs[1]
            if pigmentRow then
                row.millingKnownPigment = {
                    configKey = pigmentRow.configKey,
                    itemID = pigmentRow.itemID,
                    itemName = pigmentRow.itemName,
                }
                SessionLog("OperationOutcomeService: Milling learned pigment identity profileKey=%s pigmentConfigKey=%s itemID=%s itemName=%s",
                    tostring(profileKey), tostring(row.millingKnownPigment.configKey),
                    tostring(row.millingKnownPigment.itemID), tostring(row.millingKnownPigment.itemName))
            end
        end
    end

    local statisticalProfileKey = DeriveStatisticalProfileKey(observation.statisticalProfile)
    if statisticalProfileKey then
        row.statisticalProfiles = row.statisticalProfiles or {}
        local profileAggregate = row.statisticalProfiles[statisticalProfileKey]
        if not profileAggregate then
            profileAggregate = NewStatisticalProfileAggregate(observation, observation.statisticalProfile, now)
            row.statisticalProfiles[statisticalProfileKey] = profileAggregate
        end
        profileAggregate.operationType = observation.operationType or profileAggregate.operationType
        profileAggregate.profileKeyMode = observation.profileKeyMode or profileAggregate.profileKeyMode
        profileAggregate.recipeID = profileAggregate.recipeID or observation.recipeID
        profileAggregate.professionID = profileAggregate.professionID or observation.professionID
        profileAggregate.expansionID = profileAggregate.expansionID or observation.expansionID
        profileAggregate.childSkillLineID = profileAggregate.childSkillLineID or observation.childSkillLineID
        profileAggregate.itemName = profileAggregate.itemName or observation.statisticalProfile.itemName
        AccumulateObservationTotals(profileAggregate, observation, now)
    end

    SessionLog("OperationOutcomeService: recorded profileKey=%s recipeID=%s runCountBefore=%d runCountAfter=%d",
        tostring(profileKey), tostring(row.recipeID), runCountBefore, row.runCount)

    SendOutcomeUpdatedMessage(observation, row)

    return true
end

local function SafeDiv(numerator, denominator)
    denominator = tonumber(denominator)
    if not denominator or denominator == 0 then
        return nil
    end
    return (tonumber(numerator) or 0) / denominator
end

local function BuildExpectedList(totalsByKey, runCount)
    local list = {}
    for _, entry in pairs(totalsByKey or {}) do
        list[#list + 1] = {
            itemID = entry.itemID,
            configKey = entry.configKey,
            itemName = entry.itemName,
            quantityTotal = entry.quantityTotal,
            expectedPerRun = SafeDiv(entry.quantityTotal, runCount),
        }
    end
    table.sort(list, function(a, b)
        return tostring(a.configKey or a.itemID) < tostring(b.configKey or b.itemID)
    end)
    return list
end

local function CountTableEntries(t)
    local count = 0
    for _ in pairs(t or {}) do
        count = count + 1
    end
    return count
end

local function BuildEffectiveStats(row)
    local runCount = row.runCount or 0
    local craftStats = row.craftStats or {}

    local avgResourcefulnessPct = SafeDiv(craftStats.resourcefulnessPctTotal, craftStats.resourcefulnessPctCount)
    local rfMatReturnPct = SafeDiv(row.resourcefulnessQuantityTotal, row.consumedQuantityTotal)

    -- multicraftApplicableRunCount: prefer the new field; fall back to
    -- multicraftPctCount for aggregates written before this field existed.
    local multicraftApplicableRunCount = craftStats.multicraftApplicableRunCount
        or (craftStats.multicraftPctCount and craftStats.multicraftPctCount > 0
            and craftStats.multicraftPctCount)
        or 0

    -- Ingenuity denominators: prefer concentrationCraftCount (only counts
    -- runs where concentration was spent); fall back to the old
    -- ingenuityPctCount for aggregates written before that field existed.
    local concentrationCraftCount = craftStats.concentrationCraftCount
        or craftStats.ingenuityPctCount
        or 0
    local concentrationReturnedTotal = craftStats.concentrationReturnedTotal
        or craftStats.ingenuityRefundTotal
        or 0

    -- Historical monetary averages: pure arithmetic over already-stored
    -- totals (no ValuationService call here - that would be "current
    -- economic meaning", which belongs to OperationEconomicsService). A row
    -- with no enriched observations yet simply has totalHistoricalInputCost
    -- == 0, so these average out to 0 rather than nil - honest for a
    -- brand-new Statistical Profile (every observation it has ever seen was
    -- enriched), but understates the parent Operation Profile's row if that
    -- row also carries older, un-enriched runs. Craft Analysis only ever
    -- reads Statistical Profile views, never this parent rollup, so that
    -- dilution never reaches the pilot's displayed numbers.
    local historicalNetCostTotal = (row.totalHistoricalInputCost or 0) - (row.totalHistoricalResourcefulnessValue or 0)

    -- Seed rows carry no historical monetary totals (those were the source
    -- crafter's costs, not this user's) - report nil, never a fake 0.
    local hasHistoricalCost = not row.isSeedData

    return {
        avgSkillAtCraft = SafeDiv(craftStats.skillAtCraftTotal, craftStats.skillAtCraftCount),

        avgResourcefulnessPct = avgResourcefulnessPct,
        resourcefulnessProcRate = SafeDiv(row.resourcefulnessProcCount, runCount),
        resourcefulnessProcCount = row.resourcefulnessProcCount,
        resourcefulnessQuantityTotal = row.resourcefulnessQuantityTotal,
        resourcefulnessMatReturnPct = rfMatReturnPct,
        resourcefulnessEffectiveReturnPerDisplayedPct =
            (rfMatReturnPct and avgResourcefulnessPct and avgResourcefulnessPct ~= 0)
            and (rfMatReturnPct / avgResourcefulnessPct) or nil,

        multicraftApplicableRunCount = multicraftApplicableRunCount,
        avgMulticraftPct = SafeDiv(craftStats.multicraftPctTotal, craftStats.multicraftPctCount),
        multicraftProcRate = SafeDiv(row.multicraftProcCount, runCount),
        multicraftExtraPerCraft = SafeDiv(row.multicraftExtraTotal, runCount),
        multicraftExtraPerProc = SafeDiv(row.multicraftExtraTotal, row.multicraftProcCount),

        concentrationCraftCount = concentrationCraftCount,
        avgIngenuityPct = SafeDiv(craftStats.ingenuityPctTotal, concentrationCraftCount),
        ingenuityProcRate = SafeDiv(craftStats.ingenuityProcCount, concentrationCraftCount),
        concentrationReturnedTotal = concentrationReturnedTotal,
        averageConcentrationReturned = SafeDiv(concentrationReturnedTotal, concentrationCraftCount),

        avgHistoricalInputCost = hasHistoricalCost and SafeDiv(row.totalHistoricalInputCost, runCount) or nil,
        avgHistoricalResourcefulnessValue = hasHistoricalCost and SafeDiv(row.totalHistoricalResourcefulnessValue, runCount) or nil,
        avgHistoricalEffectiveCostPerCraft = hasHistoricalCost and SafeDiv(historicalNetCostTotal, runCount) or nil,
        avgHistoricalEffectiveCostPerProducedItem = hasHistoricalCost and SafeDiv(historicalNetCostTotal, row.multicraftTotalQuantityTotal) or nil,
    }
end

--- Returns yield confidence/status for a profile key or an already-fetched
-- aggregate row/view.
function OperationOutcomeService:GetYieldStatus(profileKeyOrAggregate)
    local aggregate = profileKeyOrAggregate
    if type(aggregate) ~= "table" then
        aggregate = self:GetAggregate(profileKeyOrAggregate)
    end

    local runCount = aggregate and aggregate.runCount or 0
    if runCount <= 0 then
        return self.YIELD_STATUS_UNKNOWN
    end
    if runCount < self.ESTABLISHED_THRESHOLD then
        return self.YIELD_STATUS_LOW_SAMPLE
    end
    return self.YIELD_STATUS_ESTABLISHED
end

-- Builds the read-only view returned to consumers: stored totals plus
-- derived expected-per-run and effective-stat fields. Derived fields are
-- computed fresh on every call, never written back into the persisted row.
--
-- Operation Profile (parent) views expose metadata and rollups only.
-- Statistical Profile views (options.isStatisticalProfile = true) expose the
-- complete authoritative per-execution-context statistics - consumed/
-- produced/resourcefulness averages are authoritative only within a
-- Statistical Profile, never blended at the parent level.
local BuildAggregateView

-- Synthesizes the single "Default" Statistical Profile for operations that
-- never split into named execution contexts (e.g. prospecting, where the
-- operation profile key itself already separates the ore) - mirrors the
-- row's own totals so every Operation Profile always has at least one
-- Statistical Profile to report against.
local function BuildDefaultStatisticalProfileView(row)
    local synthetic = {
        operationProfileKey = row.operationProfileKey,
        operationType = row.operationType,
        profileKeyMode = row.profileKeyMode,
        recipeID = row.recipeID,
        professionID = row.professionID,
        expansionID = row.expansionID,
        childSkillLineID = row.childSkillLineID,
        isSeedData = row.isSeedData,

        statisticalProfileKey = "default",
        itemName = "Default",

        runCount = row.runCount,
        consumedTotalsByKey = row.consumedTotalsByKey,
        producedTotalsByKey = row.producedTotalsByKey,
        resourcefulnessTotalsByKey = row.resourcefulnessTotalsByKey,
        observedOutputItemKeys = row.observedOutputItemKeys,
        observedResourcefulnessItemKeys = row.observedResourcefulnessItemKeys,
        latestSelectedInputEvidence = row.latestSelectedInputEvidence,

        consumedQuantityTotal = row.consumedQuantityTotal,
        resourcefulnessQuantityTotal = row.resourcefulnessQuantityTotal,
        resourcefulnessProcCount = row.resourcefulnessProcCount,

        multicraftProcCount = row.multicraftProcCount,
        multicraftExtraTotal = row.multicraftExtraTotal,
        multicraftBaseQuantityTotal = row.multicraftBaseQuantityTotal,
        multicraftTotalQuantityTotal = row.multicraftTotalQuantityTotal,

        totalHistoricalInputCost = row.totalHistoricalInputCost,
        totalHistoricalResourcefulnessValue = row.totalHistoricalResourcefulnessValue,
        unresolvedInputValuationCount = row.unresolvedInputValuationCount,
        unresolvedResourcefulnessValuationCount = row.unresolvedResourcefulnessValuationCount,

        craftStats = row.craftStats,

        firstObservedAt = row.firstObservedAt,
        lastObservedAt = row.lastObservedAt,
    }
    return BuildAggregateView(synthetic, { isStatisticalProfile = true })
end

BuildAggregateView = function(row, options)
    if type(row) ~= "table" then
        return nil
    end

    -- Must run before runCount is read below: it may rewrite row.runCount
    -- (e.g. discarding an unkeyable legacy Statistical Profile also
    -- discards its contribution to the parent's total). Harmless no-op for
    -- Statistical Profile sub-rows, which never carry a statisticalProfiles
    -- table of their own. Skipped for seed rows (immutable published data,
    -- already in current shape).
    if not row.isSeedData then
        ReconcileRow(row)
    end

    options = type(options) == "table" and options or {}
    local runCount = row.runCount or 0

    local view = {
        operationProfileKey = row.operationProfileKey,
        operationType = row.operationType,
        profileKeyMode = row.profileKeyMode,
        recipeID = row.recipeID,
        professionID = row.professionID,
        expansionID = row.expansionID,
        childSkillLineID = row.childSkillLineID,

        -- true when this view is built (wholly or, for a split parent,
        -- partly) from published starter data rather than the user's own.
        isSeedData = row.isSeedData == true,

        runCount = runCount,

        craftStats = row.craftStats,
        effective = BuildEffectiveStats(row),

        totalHistoricalInputCost = row.totalHistoricalInputCost,
        totalHistoricalResourcefulnessValue = row.totalHistoricalResourcefulnessValue,
        unresolvedInputValuationCount = row.unresolvedInputValuationCount,
        unresolvedResourcefulnessValuationCount = row.unresolvedResourcefulnessValuationCount,

        firstObservedAt = row.firstObservedAt,
        lastObservedAt = row.lastObservedAt,
    }

    view.yieldStatus = OperationOutcomeService:GetYieldStatus(view)

    if options.isStatisticalProfile then
        -- Statistical Profile view: complete authoritative detail (Goal 3).
        view.isStatisticalProfile = true
        view.statisticalProfileKey = row.statisticalProfileKey
        view.inputRoleKey = row.inputRoleKey
        view.inputRole = row.inputRole
        view.itemID = row.itemID
        view.itemName = row.itemName
        view.configKey = row.configKey
        view.craftingQuality = row.craftingQuality

        view.expectedConsumedInputsPerRun = BuildExpectedList(row.consumedTotalsByKey, runCount)
        view.expectedProducedOutputsPerRun = BuildExpectedList(row.producedTotalsByKey, runCount)
        view.expectedResourcefulnessReturnsPerRun = BuildExpectedList(row.resourcefulnessTotalsByKey, runCount)

        view.observedOutputItemKeys = row.observedOutputItemKeys
        view.observedResourcefulnessItemKeys = row.observedResourcefulnessItemKeys
        view.latestSelectedInputEvidence = row.latestSelectedInputEvidence

        view.multicraft = {
            procCount = row.multicraftProcCount,
            extraTotal = row.multicraftExtraTotal,
            extraPerRun = SafeDiv(row.multicraftExtraTotal, runCount),
            totalQuantityTotal = row.multicraftTotalQuantityTotal,
            baseQuantityTotal = row.multicraftBaseQuantityTotal,
        }

        return view
    end

    -- Operation Profile (parent) view: metadata and rollups only (Goal 2).
    -- Consumed/produced/resourcefulness averages are authoritative only
    -- within each Statistical Profile and are never blended here, except the
    -- produced-output rollup: the crafted output item is the same across
    -- Statistical Profiles even when consumed/returned items differ (e.g.
    -- crushing always produces Gemdust regardless of which gem was selected).
    local hasStatisticalProfileSplit = CountTableEntries(row.statisticalProfiles) > 0

    local statisticalProfiles = {}
    if hasStatisticalProfileSplit then
        for _, profileRow in pairs(row.statisticalProfiles) do
            statisticalProfiles[#statisticalProfiles + 1] =
                BuildAggregateView(profileRow, { isStatisticalProfile = true })
        end
        table.sort(statisticalProfiles, function(a, b)
            return tostring(a.itemName or a.statisticalProfileKey) < tostring(b.itemName or b.statisticalProfileKey)
        end)
    else
        statisticalProfiles[1] = BuildDefaultStatisticalProfileView(row)
    end

    local latestStatisticalProfile = nil
    for _, profile in ipairs(statisticalProfiles) do
        if not latestStatisticalProfile
        or (profile.lastObservedAt or 0) > (latestStatisticalProfile.lastObservedAt or 0) then
            latestStatisticalProfile = profile
        end
    end

    view.hasStatisticalProfileSplit = hasStatisticalProfileSplit
    view.statisticalProfiles = statisticalProfiles
    view.latestStatisticalProfile = latestStatisticalProfile
    view.latestSelectedInputEvidence = row.latestSelectedInputEvidence

    view.rollupExpectedProducedOutputsPerRun = BuildExpectedList(row.producedTotalsByKey, runCount)

    view.multicraft = {
        procCount = row.multicraftProcCount,
        extraTotal = row.multicraftExtraTotal,
        extraPerRun = SafeDiv(row.multicraftExtraTotal, runCount),
        totalQuantityTotal = row.multicraftTotalQuantityTotal,
        baseQuantityTotal = row.multicraftBaseQuantityTotal,
    }

    return view
end

-- ---------------------------------------------------------------------------
-- Starter (seed) data handoff - read time only
-- ---------------------------------------------------------------------------

local function GetSeedOperations()
    local seed = (PocketCFO and PocketCFO.OperationOutcomeSeedData) or _G.PocketCFO_OperationOutcomeSeedData
    return seed and type(seed.operations) == "table" and seed.operations or nil
end

-- One rule for every handoff: the seed row wins until the user's own local
-- row matches the seed row's sample size (capped at SEED_HANDOFF_RUN_COUNT,
-- and never on zero local runs), then local only. A thin seed row (e.g. 4
-- runs) hands off after 4 local runs rather than masking 19 of the user's.
local function ChooseSeedOrLocal(localRow, seedRow)
    if not seedRow then
        return localRow
    end
    if localRow then
        local localRuns = tonumber(localRow.runCount) or 0
        local seedRuns = tonumber(seedRow.runCount) or 0
        local handoff = math.max(1, math.min(OperationOutcomeService.SEED_HANDOFF_RUN_COUNT, seedRuns))
        if localRuns >= handoff then
            return localRow
        end
    end
    return seedRow
end

local COMPOSITE_SUM_FIELDS = {
    "runCount",
    "consumedQuantityTotal", "resourcefulnessQuantityTotal", "resourcefulnessProcCount",
    "multicraftProcCount", "multicraftExtraTotal", "multicraftBaseQuantityTotal", "multicraftTotalQuantityTotal",
}

local function AddKeyedTotals(target, totalsByKey)
    for key, entry in pairs(totalsByKey or {}) do
        local existing = target[key]
        if not existing then
            existing = { itemID = entry.itemID, configKey = entry.configKey, itemName = entry.itemName, quantityTotal = 0 }
            target[key] = existing
        end
        existing.quantityTotal = existing.quantityTotal + (tonumber(entry.quantityTotal) or 0)
    end
end

-- Parent row for a split Operation Profile (e.g. Crushing) whose chosen
-- Statistical Profiles mix seed and local rows. Never persisted. Parent
-- totals are rebuilt as the sum of the chosen profiles, so the existing
-- invariant (Operation Profile totals == SUM(Statistical Profile totals))
-- still holds. Flagged isSeedData, so historical monetary averages read nil -
-- a seed/local blend has no honest historical cost.
local function BuildCompositeRow(baseRow, chosenProfiles)
    local composite = {
        operationProfileKey = baseRow.operationProfileKey,
        operationType = baseRow.operationType,
        profileKeyMode = baseRow.profileKeyMode,
        recipeID = baseRow.recipeID,
        professionID = baseRow.professionID,
        expansionID = baseRow.expansionID,
        childSkillLineID = baseRow.childSkillLineID,
        isSeedData = true,

        statisticalProfiles = chosenProfiles,
        consumedTotalsByKey = {},
        producedTotalsByKey = {},
        resourcefulnessTotalsByKey = {},
        observedOutputItemKeys = {},
        observedResourcefulnessItemKeys = {},
        craftStats = NewCraftStatsTotals(),
    }
    for _, field in ipairs(COMPOSITE_SUM_FIELDS) do
        composite[field] = 0
    end

    local latest = nil
    for _, profile in pairs(chosenProfiles) do
        for _, field in ipairs(COMPOSITE_SUM_FIELDS) do
            composite[field] = composite[field] + (tonumber(profile[field]) or 0)
        end
        AddKeyedTotals(composite.consumedTotalsByKey, profile.consumedTotalsByKey)
        AddKeyedTotals(composite.producedTotalsByKey, profile.producedTotalsByKey)
        AddKeyedTotals(composite.resourcefulnessTotalsByKey, profile.resourcefulnessTotalsByKey)
        for key in pairs(profile.observedOutputItemKeys or {}) do
            composite.observedOutputItemKeys[key] = true
        end
        for key in pairs(profile.observedResourcefulnessItemKeys or {}) do
            composite.observedResourcefulnessItemKeys[key] = true
        end
        for field, value in pairs(profile.craftStats or {}) do
            if type(value) == "number" then
                composite.craftStats[field] = (composite.craftStats[field] or 0) + value
            end
        end
        if profile.firstObservedAt and (not composite.firstObservedAt or profile.firstObservedAt < composite.firstObservedAt) then
            composite.firstObservedAt = profile.firstObservedAt
        end
        if not latest or (profile.lastObservedAt or 0) > (latest.lastObservedAt or 0) then
            latest = profile
        end
    end
    composite.lastObservedAt = latest and latest.lastObservedAt
    composite.latestSelectedInputEvidence = latest and latest.latestSelectedInputEvidence

    return composite
end

-- Returns the row BuildAggregateView should read for one Operation Profile:
-- the local row, the seed row, or (split operations with any seed profile
-- still in use) a composite of per-Statistical-Profile choices.
local function ResolveOperationRow(localRow, seedRow)
    if not seedRow then
        return localRow
    end
    if not localRow then
        return seedRow
    end
    ReconcileRow(localRow)

    local seedProfiles = type(seedRow.statisticalProfiles) == "table" and seedRow.statisticalProfiles or {}
    local localProfiles = type(localRow.statisticalProfiles) == "table" and localRow.statisticalProfiles or {}
    if CountTableEntries(seedProfiles) == 0 and CountTableEntries(localProfiles) == 0 then
        -- Non-split Operation Profile (Prospecting, Milling, Recycling).
        return ChooseSeedOrLocal(localRow, seedRow)
    end

    local chosen, usesSeed = {}, false
    for key, seedProfile in pairs(seedProfiles) do
        chosen[key] = ChooseSeedOrLocal(localProfiles[key], seedProfile)
        if chosen[key] == seedProfile then
            usesSeed = true
        end
    end
    for key, localProfile in pairs(localProfiles) do
        if not chosen[key] then
            chosen[key] = localProfile
        end
    end

    if not usesSeed then
        return localRow
    end
    return BuildCompositeRow(localRow, chosen)
end

--- Returns the aggregate view for one operation profile key, or nil.
function OperationOutcomeService:GetAggregate(operationProfileKey)
    local store = self:GetStore()
    local seedOperations = GetSeedOperations()
    local row = ResolveOperationRow(
        store and store[operationProfileKey],
        seedOperations and seedOperations[operationProfileKey])
    return BuildAggregateView(row)
end

--- Canonical Statistical Profile identity: the same configKey-or-item:itemID
-- formula DeriveStatisticalProfileKey applies to a captured observation's
-- statisticalProfile descriptor, exposed so callers resolving "which
-- Statistical Profile is this candidate?" (e.g. ProcessingAnalysisController
-- selecting a gem) never need to hand-build or duplicate the "item:" prefix
-- convention themselves.
-- @param identity table { configKey = string|nil, itemID = number|nil }
-- @return string|nil statisticalProfileKey
function OperationOutcomeService:ResolveStatisticalProfileKey(identity)
    return DeriveStatisticalProfileKey({
        configKey = type(identity) == "table" and identity.configKey or nil,
        itemID = type(identity) == "table" and identity.itemID or nil,
    })
end

--- Returns the aggregate view for exactly one Statistical Profile within an
-- Operation Profile, or nil if the Operation Profile or that specific
-- Statistical Profile has no observations. Never falls back to the parent
-- Operation Profile or to any other Statistical Profile - a caller asking
-- for a specific selected gem's economics must get that gem's data or an
-- explicit "not found", never another gem's blended-in totals.
function OperationOutcomeService:GetStatisticalProfileAggregate(operationProfileKey, statisticalProfileKey)
    if not operationProfileKey or not statisticalProfileKey or statisticalProfileKey == "" then
        return nil
    end

    local store = self:GetStore()
    local row = store and store[operationProfileKey]
    if row then
        ReconcileRow(row)
    end
    local localProfile = row and row.statisticalProfiles and row.statisticalProfiles[statisticalProfileKey]

    local seedOperations = GetSeedOperations()
    local seedRow = seedOperations and seedOperations[operationProfileKey]
    local seedProfile = seedRow and seedRow.statisticalProfiles and seedRow.statisticalProfiles[statisticalProfileKey]

    local profileRow = ChooseSeedOrLocal(localProfile, seedProfile)
    if not profileRow then
        return nil
    end

    return BuildAggregateView(profileRow, { isStatisticalProfile = true })
end

local function CountStoreRows(store)
    local count = 0
    for _ in pairs(store or {}) do
        count = count + 1
    end
    return count
end

local function RemoveEmptyOutcomeStore(globalDB)
    if globalDB
    and type(globalDB.operationOutcomes) == "table"
    and CountStoreRows(globalDB.operationOutcomes) == 0 then
        globalDB.operationOutcomes = nil
    end
end

--- Clears every stored operation aggregate.
-- @return table { success = boolean, removedCount = number, reason = string|nil }
function OperationOutcomeService:ClearAll()
    local globalDB = GetGlobalDB()
    if not globalDB then
        return { success = false, removedCount = 0, reason = "coreDatabaseUnavailable" }
    end

    local removedCount = CountStoreRows(globalDB.operationOutcomes)
    globalDB.operationOutcomes = nil
    SessionLog("OperationOutcomeService: cleared all aggregates removed=%d", removedCount)
    return { success = true, removedCount = removedCount }
end

--- Clears every aggregate stored for one recipeID.
-- @return table { success = boolean, removedCount = number, recipeID = number|nil, reason = string|nil }
function OperationOutcomeService:ClearRecipe(recipeID)
    recipeID = tonumber(recipeID)
    if not recipeID or recipeID <= 0 then
        return { success = false, removedCount = 0, reason = "invalidRecipeID" }
    end

    local globalDB = GetGlobalDB()
    if not globalDB then
        return { success = false, removedCount = 0, recipeID = recipeID, reason = "coreDatabaseUnavailable" }
    end

    local store = globalDB.operationOutcomes
    local removedCount = 0
    if type(store) == "table" then
        for profileKey, row in pairs(store) do
            if type(row) == "table" and tonumber(row.recipeID) == recipeID then
                store[profileKey] = nil
                removedCount = removedCount + 1
            end
        end
    end

    RemoveEmptyOutcomeStore(globalDB)
    SessionLog("OperationOutcomeService: cleared recipe aggregates recipeID=%s removed=%d",
        tostring(recipeID), removedCount)
    return { success = true, removedCount = removedCount, recipeID = recipeID }
end

--- Clears exactly one operation aggregate by profile key.
-- @return table { success = boolean, removedCount = number, profileKey = string|nil, reason = string|nil }
function OperationOutcomeService:ClearProfile(profileKey)
    if profileKey == nil or tostring(profileKey) == "" then
        return { success = false, removedCount = 0, reason = "missingProfileKey" }
    end
    profileKey = tostring(profileKey)

    local globalDB = GetGlobalDB()
    if not globalDB then
        return { success = false, removedCount = 0, profileKey = profileKey, reason = "coreDatabaseUnavailable" }
    end

    local store = globalDB.operationOutcomes
    local removedCount = 0
    if type(store) == "table" and store[profileKey] ~= nil then
        store[profileKey] = nil
        removedCount = 1
    end

    RemoveEmptyOutcomeStore(globalDB)
    SessionLog("OperationOutcomeService: cleared profile aggregate profileKey=%s removed=%d",
        tostring(profileKey), removedCount)
    return { success = true, removedCount = removedCount, profileKey = profileKey }
end

--- Clears the aggregate for one operation profile key. Used to invalidate
-- yields after a major Blizzard change to the underlying operation.
function OperationOutcomeService:ResetAggregate(operationProfileKey)
    local result = self:ClearProfile(operationProfileKey)
    return result.success == true and result.removedCount > 0
end

--- Returns aggregate views for all known operation profiles (local plus
-- seeded), optionally filtered by operationType, professionID, and/or recipeID.
function OperationOutcomeService:ListAggregates(filter)
    filter = type(filter) == "table" and filter or nil
    local store = self:GetStore() or {}
    local seedOperations = GetSeedOperations() or {}
    local results = {}

    local profileKeys = {}
    for profileKey in pairs(store) do
        profileKeys[profileKey] = true
    end
    for profileKey in pairs(seedOperations) do
        profileKeys[profileKey] = true
    end

    for profileKey in pairs(profileKeys) do
        local row = ResolveOperationRow(store[profileKey], seedOperations[profileKey])
        local matchesType = not filter or not filter.operationType or row.operationType == filter.operationType
        local matchesProfession = not filter or not filter.professionID or row.professionID == filter.professionID
        local matchesRecipe = not filter or not filter.recipeID or row.recipeID == filter.recipeID
        if matchesType and matchesProfession and matchesRecipe then
            results[#results + 1] = BuildAggregateView(row)
        end
    end

    table.sort(results, function(a, b)
        return (a.lastObservedAt or 0) > (b.lastObservedAt or 0)
    end)

    return results
end

if PocketCFO then
    PocketCFO.OperationOutcomeService = OperationOutcomeService
end

_G.PocketCFO_OperationOutcomeService = OperationOutcomeService
