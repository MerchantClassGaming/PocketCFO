-- PocketCFO/Services/OperationEconomicsService/OperationEconomicsService.lua
-- Converts an Operation Definition's structure, OperationOutcomeService's
-- observed expected quantities, and PocketCFO_Valuation's current prices
-- into a reusable Operation Summary.
--
-- Answers "what does this operation mean financially?" only. Makes no
-- recommendation, applies no Processing-specific display policy, and never
-- touches inventory ownership/availability. Consumers (Processing UI,
-- Orders, future VCM/Shopping) decide what to show and what to do with the
-- summary.
--
-- currentInputCost is always the full value of required consumed inputs
-- (from the static OperationDefinition - reagent requirements are structural
-- and known immediately, no observation needed) priced at CURRENT
-- ValuationService prices. Expected output/resourcefulness income always
-- comes from OperationOutcomeService's observed aggregate - never from the
-- static definition - per architecture: "Expected quantities come from
-- OperationOutcomeService, not from the static definition."
--
-- historicalOperationCost is the opposite: the preserved historical average
-- cost of completed operations, read verbatim from OperationOutcomeService's
-- already-stored monetary totals (observation-time valuation, never
-- repriced). It is informational only - it must never drive
-- expectedNet/expectedROIPercent. Those are always computed from
-- currentInputCost, so opening/refreshing analysis after prices change
-- updates currentInputCost/expectedNet/expectedROIPercent without touching
-- historicalOperationCost or any stored observation.
--
-- Unpriced outputs are never guessed: a missing output price or missing
-- observation yield produces an explicit missingValues entry and a nil
-- expectedOperationIncome/expectedNet rather than a partial sum.
--
-- Exception (Brian, 2026-10-13): an unpriced INPUT or RESOURCEFULNESS
-- return is counted as free (0) instead of blanking the whole row. Typical
-- case: a bound optional finishing reagent (e.g. a Multicraft Manifold from
-- patron orders) that can never have an AH price. Such rows carry
-- countedAsFree = true and are listed in summary.countedAsFreeItems (not
-- missingValues) so the display names them - never silently hidden.

local PocketCFO = _G.PocketCFO

local OperationEconomicsService = {}

local CURRENCY_COPPER = "copper"
local YIELD_STATUS_UNKNOWN = "unknown"

local function GetDefinitionService()
    return PocketCFO and PocketCFO.OperationDefinitionService or _G.PocketCFO_OperationDefinitionService
end

local function GetOutcomeService()
    return PocketCFO and PocketCFO.OperationOutcomeService or _G.PocketCFO_OperationOutcomeService
end

local function GetProfileKeyService()
    return PocketCFO and PocketCFO.OperationProfileKeyService or _G.PocketCFO_OperationProfileKeyService
end

-- Temporary diagnostics for the "Prospecting Analysis needs-price delay"
-- investigation. Remove once the rerender-on-price-update fix is confirmed
-- working in-game.
local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

-- Documented safe access pattern from
-- PocketCFO_Valuation/Modules/ValuationService.lua: never force-load the
-- addon as a side effect of pricing a query.
local function GetValuationService()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_Valuation"))
        or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_Valuation"))
    if not loaded then
        return nil
    end
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule("ValuationService", true)
end

local function NewUnresolvedSummary(recipeID, profileKey, reason, operationType, historicalOperationCost)
    return {
        operationProfileKey = profileKey,
        operationType = operationType,
        recipeID = recipeID,
        currentInputCost = nil,
        -- Historical operation cost is informational only and survives even
        -- when current pricing is unresolved (e.g. valuation addon not
        -- loaded) - never fall back to it for expectedNet/expectedROIPercent,
        -- which stay nil here alongside currentInputCost.
        historicalOperationCost = historicalOperationCost,
        expectedOperationIncome = nil,
        expectedOutputValue = nil,
        expectedResourcefulnessValue = nil,
        expectedTotalValue = nil,
        expectedNet = nil,
        expectedROIPercent = nil,
        inputValueRows = {},
        outputValueRows = {},
        resourcefulnessValueRows = {},
        observationCount = 0,
        yieldStatus = YIELD_STATUS_UNKNOWN,
        confidence = YIELD_STATUS_UNKNOWN,
        missingValues = { { category = "operation", reason = reason } },
        currency = CURRENCY_COPPER,
        unresolved = true,
        unresolvedReason = reason,
    }
end

-- True when the game has already sent this item's details (same check
-- CraftQueueController:ScheduleAnalysisItemDataRefresh uses to decide what
-- to watch). Before that, pricing can't build the item's market key, so "no
-- price" means "not loaded yet", not "has no price".
local function IsItemDataLoaded(itemID)
    itemID = tonumber(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not itemID or not getInfo then
        return false
    end
    local ok, name = pcall(getInfo, itemID)
    return ok and name ~= nil
end

-- The 2026-10-13 "unpriced counts as free" exception is for items that
-- genuinely have no price (bound reagents like Multicraft Manifolds). Two
-- cases are never free (fix 2026-10-16, Crushing/Prospecting showing gems
-- and ore at zero cost on first open):
--   1. The operation's primary input (the gem/ore/herb being processed) -
--      a zero-cost primary input always produces a fake profit.
--   2. Any item whose details haven't loaded yet - it goes to missingValues
--      so the row reads "needs price" and CraftQueueController's existing
--      item-data watcher re-runs the analysis once the details arrive.
local function CanCountAsFree(itemRef, primaryInputItemID)
    local itemID = tonumber(itemRef and itemRef.itemID)
    if primaryInputItemID and itemID == tonumber(primaryInputItemID) then
        return false
    end
    return IsItemDataLoaded(itemID)
end

-- Prices one input/output/resourcefulness item reference and records a
-- missingValues entry instead of guessing when the price is unknown.
-- When freeList is given (inputs and resourcefulness returns only), an
-- unpriced item is instead counted as free: lineValue 0, countedAsFree =
-- true, and recorded in freeList rather than missingValues - unless
-- CanCountAsFree rules it out (primary input, or details not loaded yet).
local function BuildValueRow(valuationService, itemRef, quantityPerRun, category, missingValues, freeList, primaryInputItemID)
    quantityPerRun = tonumber(quantityPerRun) or 0

    if freeList and not CanCountAsFree(itemRef, primaryInputItemID) then
        freeList = nil
    end

    local priced = valuationService:GetItemValue({ itemID = itemRef.itemID, configKey = itemRef.configKey })

    SessionLog("OperationEconomicsService price lookup: category=%s itemID=%s configKey=%s cacheHit=%s reason=%s isFresh=%s lastUpdated=%s",
        tostring(category), tostring(itemRef.itemID), tostring(itemRef.configKey),
        tostring(not priced.unresolved), tostring(priced.unresolvedReason),
        tostring(priced.isFresh), tostring(priced.lastUpdated))

    local row = {
        itemID = itemRef.itemID,
        configKey = itemRef.configKey,
        itemName = itemRef.itemName,
        quantityPerRun = quantityPerRun,
        valuePerUnit = nil,
        lineValue = nil,
        unresolved = priced.unresolved,
        unresolvedReason = priced.unresolvedReason,
    }

    if priced.unresolved and freeList then
        row.unresolved = nil
        row.countedAsFree = true
        row.valuePerUnit = 0
        row.lineValue = 0
        freeList[#freeList + 1] = {
            category = category,
            itemID = itemRef.itemID,
            configKey = itemRef.configKey,
            itemName = itemRef.itemName,
            reason = priced.unresolvedReason,
        }
    elseif priced.unresolved then
        missingValues[#missingValues + 1] = {
            category = category,
            itemID = itemRef.itemID,
            configKey = itemRef.configKey,
            reason = priced.unresolvedReason,
        }
    else
        row.valuePerUnit = priced.valuePerUnit
        row.lineValue = priced.valuePerUnit * quantityPerRun
    end

    return row
end

-- Sums resolved line values. Returns nil (not a partial sum) if any row in
-- the list is unresolved, so an unknown price never silently becomes zero.
local function SumResolvedRows(rows)
    local total = 0
    for _, row in ipairs(rows) do
        if row.unresolved then
            return nil
        end
        total = total + (row.lineValue or 0)
    end
    return total
end

-- Prices every ref in `refs` (shaped like OperationOutcomeService's
-- BuildExpectedList entries: { itemID, configKey, itemName, expectedPerRun })
-- under `category`, appending unresolved prices to missingValues.
local function BuildValueRows(valuationService, refs, category, missingValues, freeList, primaryInputItemID)
    local rows = {}
    for _, ref in ipairs(refs or {}) do
        rows[#rows + 1] = BuildValueRow(valuationService, ref, ref.expectedPerRun, category, missingValues, freeList, primaryInputItemID)
    end
    return rows
end

local function BuildQuantityOnlyRows(refs)
    local rows = {}
    for _, ref in ipairs(refs or {}) do
        rows[#rows + 1] = {
            itemID = ref.itemID,
            configKey = ref.configKey,
            itemName = ref.itemName,
            quantityPerRun = tonumber(ref.expectedPerRun) or tonumber(ref.quantityPerRun) or 0,
            valuePerUnit = nil,
            lineValue = nil,
            quantityOnly = true,
            unresolved = nil,
            unresolvedReason = nil,
        }
    end
    return rows
end

local function SafeDiv(numerator, denominator)
    denominator = tonumber(denominator)
    if not denominator or denominator == 0 then
        return nil
    end
    return (tonumber(numerator) or 0) / denominator
end

-- Weighted average per-unit current value across a list of already-priced
-- value rows (BuildValueRow's shape). nil (not a partial average) if any
-- row is unresolved or there is no quantity to weight by - the same
-- "never guess a missing price" discipline SumResolvedRows already applies
-- to totals.
local function AveragePerUnitValue(rows)
    local totalValue, totalQuantity = 0, 0
    for _, row in ipairs(rows or {}) do
        if row.unresolved then
            return nil
        end
        totalValue = totalValue + (row.lineValue or 0)
        totalQuantity = totalQuantity + (row.quantityPerRun or 0)
    end
    if totalQuantity <= 0 then
        return nil
    end
    return totalValue / totalQuantity
end

local function SumExpectedQuantity(refs, targetItemID)
    targetItemID = tonumber(targetItemID)
    local total = 0
    for _, ref in ipairs(refs or {}) do
        if not targetItemID or tonumber(ref.itemID) == targetItemID then
            total = total + (tonumber(ref.expectedPerRun) or tonumber(ref.quantityPerRun) or 0)
        end
    end
    return total > 0 and total or nil
end

local function AddUnitAcquisitionEconomics(summary, expectedOutputQuantity)
    if type(summary) ~= "table" then
        return summary
    end

    expectedOutputQuantity = tonumber(expectedOutputQuantity)
    if expectedOutputQuantity and expectedOutputQuantity <= 0 then
        expectedOutputQuantity = nil
    end

    summary.expectedUnitOutputQuantity = expectedOutputQuantity

    if summary.currentInputCost ~= nil and summary.expectedResourcefulnessValue ~= nil then
        summary.currentGrossOperationCost = summary.currentInputCost
        summary.currentEffectiveAcquisitionCost =
            summary.currentInputCost - summary.expectedResourcefulnessValue
    end

    if summary.currentEffectiveAcquisitionCost ~= nil and expectedOutputQuantity then
        summary.currentCostPerUnitOutput =
            summary.currentEffectiveAcquisitionCost / expectedOutputQuantity
    end

    if summary.historicalGrossInputCostPerCraft ~= nil
    and summary.historicalResourcefulnessValuePerCraft ~= nil then
        summary.historicalEffectiveAcquisitionCost =
            summary.historicalGrossInputCostPerCraft - summary.historicalResourcefulnessValuePerCraft
    elseif summary.historicalEffectiveCostPerCraft ~= nil then
        summary.historicalEffectiveAcquisitionCost = summary.historicalEffectiveCostPerCraft
    end

    if summary.historicalEffectiveAcquisitionCost ~= nil and expectedOutputQuantity then
        summary.historicalCostPerUnitOutput =
            summary.historicalEffectiveAcquisitionCost / expectedOutputQuantity
    end

    return summary
end

--- Builds an Operation Summary for exactly one Statistical Profile,
-- pricing consumed inputs, produced outputs, and resourcefulness returns
-- entirely from that profile's own observed per-run expected quantities
-- (OperationOutcomeService's expectedConsumedInputsPerRun/
-- expectedProducedOutputsPerRun/expectedResourcefulnessReturnsPerRun).
--
-- Processing Operations that split by selected input (e.g. Crushing's
-- selected gem, profileKeyMode recipeOnly) cannot derive a static
-- OperationDefinition the ordinary way - see
-- OperationDefinitionService:DeriveProcessingDefinition, which only derives
-- a single profileDriver-based input and intentionally falls through to
-- unresolved for recipeOnly operations. Their Statistical Profile's own
-- consumed totals already include every real consumed input for that
-- context (the selected gem *and* any fixed catalyst, since
-- CraftInventoryAdapter records whatever the craft actually consumed) - so
-- once at least one craft has been observed for the requested profile, its
-- own totals are a complete, honest cost/income basis without needing the
-- static definition at all.
function OperationEconomicsService:SummarizeStatisticalProfile(profileView, options)
    options = type(options) == "table" and options or {}

    local valuationService = GetValuationService()
    if not valuationService then
        return NewUnresolvedSummary(profileView.recipeID, profileView.operationProfileKey,
            "valuationAddonUnavailable", profileView.operationType,
            profileView.effective and profileView.effective.avgHistoricalInputCost)
    end

    local missingValues = {}
    local countedAsFreeItems = {}
    local primaryInputItemID = options.primaryInputItemID
    local inputValueRows = BuildValueRows(valuationService, profileView.expectedConsumedInputsPerRun, "input", missingValues, countedAsFreeItems, primaryInputItemID)
    local outputValueRows = options.outputValuationMode == "quantityOnly"
        and BuildQuantityOnlyRows(profileView.expectedProducedOutputsPerRun)
        or BuildValueRows(valuationService, profileView.expectedProducedOutputsPerRun, "output", missingValues)
    local resourcefulnessValueRows = BuildValueRows(valuationService, profileView.expectedResourcefulnessReturnsPerRun, "resourcefulness", missingValues, countedAsFreeItems, primaryInputItemID)

    -- currentInputCost: full current-priced value of every required consumed
    -- input for one operation. Never historical - see file header.
    local currentInputCost = SumResolvedRows(inputValueRows)
    local outputIncome = options.outputValuationMode == "quantityOnly" and nil or SumResolvedRows(outputValueRows)
    local resourcefulnessIncome = SumResolvedRows(resourcefulnessValueRows)

    local expectedOperationIncome = nil
    if outputIncome ~= nil and resourcefulnessIncome ~= nil then
        expectedOperationIncome = outputIncome + resourcefulnessIncome
    end

    -- Expected profit/ROI are always driven by currentInputCost, never by
    -- historicalOperationCost - historical cost is informational only.
    local expectedNet = nil
    if currentInputCost ~= nil and expectedOperationIncome ~= nil then
        expectedNet = expectedOperationIncome - currentInputCost
    end

    local expectedROIPercent = nil
    if expectedNet ~= nil and currentInputCost ~= nil and currentInputCost ~= 0 then
        expectedROIPercent = (expectedNet / currentInputCost) * 100
    end

    local outcomeService = GetOutcomeService()
    local yieldStatus = YIELD_STATUS_UNKNOWN
    if outcomeService and outcomeService.GetYieldStatus then
        yieldStatus = outcomeService:GetYieldStatus(profileView)
    end

    -- Additional derived economics reused by CraftAnalysisController (and
    -- available, harmlessly unused, to every other SummarizeStatisticalProfile
    -- caller e.g. Crushing). Historical figures read only already-stored
    -- monetary totals (profileView.effective, computed by
    -- OperationOutcomeService purely from stored data) - never repriced
    -- here. Current figures reuse the value rows already built above -
    -- never a second ValuationService lookup pass.
    local effective = profileView.effective or {}
    local runCount = profileView.runCount

    local multicraft = profileView.multicraft or {}
    local avgBaseOutputPerCraft = SafeDiv(multicraft.baseQuantityTotal, runCount)
    local avgTotalOutputPerCraft = SafeDiv(multicraft.totalQuantityTotal, runCount)
    local avgMulticraftBonusWhenProcs = SafeDiv(multicraft.extraTotal, multicraft.procCount)
    local avgTotalOutputWhenMulticraftProcs = nil
    if avgBaseOutputPerCraft ~= nil and avgMulticraftBonusWhenProcs ~= nil then
        avgTotalOutputWhenMulticraftProcs = avgBaseOutputPerCraft + avgMulticraftBonusWhenProcs
    end

    local currentReplacementInputCostPerCraft = currentInputCost
    local currentResourcefulnessValuePerCraft = resourcefulnessIncome
    local currentEffectiveInputCostPerCraft = nil
    if currentReplacementInputCostPerCraft ~= nil and currentResourcefulnessValuePerCraft ~= nil then
        currentEffectiveInputCostPerCraft = currentReplacementInputCostPerCraft - currentResourcefulnessValuePerCraft
    end

    local currentEffectiveCostPerProducedItem = nil
    if currentEffectiveInputCostPerCraft ~= nil and avgTotalOutputPerCraft ~= nil and avgTotalOutputPerCraft > 0 then
        currentEffectiveCostPerProducedItem = currentEffectiveInputCostPerCraft / avgTotalOutputPerCraft
    end

    local currentOutputMarketValuePerItem = AveragePerUnitValue(outputValueRows)

    local makeVsBuyDifferencePerItem = nil
    if currentOutputMarketValuePerItem ~= nil and currentEffectiveCostPerProducedItem ~= nil then
        makeVsBuyDifferencePerItem = currentOutputMarketValuePerItem - currentEffectiveCostPerProducedItem
    end

    local summary = {
        operationProfileKey = profileView.operationProfileKey,
        statisticalProfileKey = profileView.statisticalProfileKey,
        operationType = profileView.operationType,
        recipeID = profileView.recipeID,
        currentInputCost = currentInputCost,
        -- Historical operation cost: preserved historical average, informational
        -- only. Never used for expectedNet/expectedROIPercent above.
        historicalOperationCost = effective.avgHistoricalInputCost,
        expectedOperationIncome = expectedOperationIncome,
        expectedOutputValue = outputIncome,
        expectedResourcefulnessValue = resourcefulnessIncome,
        expectedTotalValue = expectedOperationIncome,
        expectedNet = expectedNet,
        expectedROIPercent = expectedROIPercent,
        inputValueRows = inputValueRows,
        outputValueRows = outputValueRows,
        resourcefulnessValueRows = resourcefulnessValueRows,
        observationCount = profileView.runCount or 0,
        -- Built from published starter data, not this user's own crafts.
        isSeedData = profileView.isSeedData == true,
        yieldStatus = yieldStatus,
        confidence = yieldStatus,
        missingValues = missingValues,
        countedAsFreeItems = countedAsFreeItems,
        currency = CURRENCY_COPPER,
        unresolved = nil,
        unresolvedReason = nil,

        -- Observed production (stored quantities only - no pricing).
        avgBaseOutputPerCraft = avgBaseOutputPerCraft,
        avgTotalOutputPerCraft = avgTotalOutputPerCraft,
        multicraftProcRate = effective.multicraftProcRate,
        avgMulticraftBonusWhenProcs = avgMulticraftBonusWhenProcs,
        avgTotalOutputWhenMulticraftProcs = avgTotalOutputWhenMulticraftProcs,
        avgResourcefulnessReturns = SafeDiv(effective.resourcefulnessQuantityTotal, runCount),

        -- Historical economics (stored monetary totals only - never repriced).
        historicalGrossInputCostPerCraft = effective.avgHistoricalInputCost,
        historicalResourcefulnessValuePerCraft = effective.avgHistoricalResourcefulnessValue,
        historicalEffectiveCostPerCraft = effective.avgHistoricalEffectiveCostPerCraft,
        historicalEffectiveCostPerProducedItem = effective.avgHistoricalEffectiveCostPerProducedItem,

        -- Current economics (current ValuationService prices only).
        currentReplacementInputCostPerCraft = currentReplacementInputCostPerCraft,
        currentResourcefulnessValuePerCraft = currentResourcefulnessValuePerCraft,
        currentEffectiveInputCostPerCraft = currentEffectiveInputCostPerCraft,
        currentEffectiveCostPerProducedItem = currentEffectiveCostPerProducedItem,
        currentOutputMarketValuePerItem = currentOutputMarketValuePerItem,
        makeVsBuyDifferencePerItem = makeVsBuyDifferencePerItem,
    }

    if options.unitAcquisitionOutputItemID then
        AddUnitAcquisitionEconomics(
            summary,
            SumExpectedQuantity(profileView.expectedProducedOutputsPerRun, options.unitAcquisitionOutputItemID))
    end

    return summary
end

--- Builds the Operation Summary for an already-resolved OperationDefinition.
-- @param definition table from OperationDefinitionService, or an unresolved
--        definition result (propagated through, not guessed past).
function OperationEconomicsService:SummarizeDefinition(definition, options)
    options = type(options) == "table" and options or {}

    if type(definition) ~= "table" then
        return NewUnresolvedSummary(nil, nil, "missingDefinition")
    end

    local outcomeService = GetOutcomeService()
    local aggregate = (outcomeService and definition.profileKey)
        and outcomeService:GetAggregate(definition.profileKey) or nil

    -- Statistical Profile path: takes precedence over (and does not require)
    -- a resolved static definition - see SummarizeStatisticalProfile. This
    -- must run before the definition.unresolved check below, since recipeOnly
    -- split operations (Crushing) never produce a resolved definition at all.
    if aggregate and aggregate.hasStatisticalProfileSplit then
        local requestedKey = options.statisticalProfileKey
        if not requestedKey then
            return NewUnresolvedSummary(definition.recipeID, definition.profileKey,
                "statisticalProfileRequired", definition.operationType)
        end

        local profileView = outcomeService.GetStatisticalProfileAggregate
            and outcomeService:GetStatisticalProfileAggregate(definition.profileKey, requestedKey)
        if not profileView then
            -- Explicit, structured "not this one" - never falls back to the
            -- parent aggregate or another Statistical Profile's data.
            return NewUnresolvedSummary(definition.recipeID, definition.profileKey,
                "statisticalProfileNotObserved", definition.operationType)
        end

        options.outputValuationMode = options.outputValuationMode or definition.outputValuationMode
        options.unitAcquisitionOutputItemID = options.unitAcquisitionOutputItemID or definition.unitAcquisitionOutputItemID
        return self:SummarizeStatisticalProfile(profileView, options)
    end

    -- Non-split path: unchanged from before Statistical Profile selection
    -- existed (Prospecting, Milling, and any Crafting Operation).
    if definition.unresolved then
        return NewUnresolvedSummary(definition.recipeID, definition.profileKey,
            definition.unresolvedReason or "definitionUnresolved", definition.operationType)
    end
    if type(definition.inputs) ~= "table" or #definition.inputs == 0 then
        return NewUnresolvedSummary(definition.recipeID, definition.profileKey,
            "definitionMissingInputs", definition.operationType)
    end

    local valuationService = GetValuationService()
    if not valuationService then
        return NewUnresolvedSummary(definition.recipeID, definition.profileKey,
            "valuationAddonUnavailable", definition.operationType,
            aggregate and aggregate.effective and aggregate.effective.avgHistoricalInputCost)
    end

    local missingValues = {}
    local countedAsFreeItems = {}

    local inputValueRows = {}
    for _, ref in ipairs(definition.inputs) do
        inputValueRows[#inputValueRows + 1] = BuildValueRow(valuationService, ref, ref.quantity, "input", missingValues, countedAsFreeItems, options.primaryInputItemID)
    end

    local outputValueRows = {}
    local resourcefulnessValueRows = {}

    -- No observations yet: cost can still be computed structurally, but
    -- income cannot be invented from the static definition.
    local yieldSource = nil
    if aggregate and (aggregate.runCount or 0) > 0 then
        yieldSource = aggregate.statisticalProfiles and aggregate.statisticalProfiles[1]
    end

    if not yieldSource then
        missingValues[#missingValues + 1] = { category = "yield", reason = "noObservedYield" }
    else
        for _, ref in ipairs(yieldSource.expectedProducedOutputsPerRun or {}) do
            outputValueRows[#outputValueRows + 1] =
                (definition.outputValuationMode == "quantityOnly")
                    and {
                        itemID = ref.itemID,
                        configKey = ref.configKey,
                        itemName = ref.itemName,
                        quantityPerRun = ref.expectedPerRun,
                        valuePerUnit = nil,
                        lineValue = nil,
                        quantityOnly = true,
                        unresolved = nil,
                        unresolvedReason = nil,
                    }
                    or BuildValueRow(valuationService, ref, ref.expectedPerRun, "output", missingValues)
        end
        for _, ref in ipairs(yieldSource.expectedResourcefulnessReturnsPerRun or {}) do
            resourcefulnessValueRows[#resourcefulnessValueRows + 1] =
                BuildValueRow(valuationService, ref, ref.expectedPerRun, "resourcefulness", missingValues, countedAsFreeItems, options.primaryInputItemID)
        end
    end

    -- Guarded the same way expectedOperationIncome already is below: with no
    -- observed yield yet, outputValueRows/resourcefulnessValueRows are
    -- trivially empty and SumResolvedRows({}) would return 0 - a fake "no
    -- output" answer, not an honest "we don't know yet". Keep them nil in
    -- that case so a row with zero crafts observed never renders as if it
    -- had a real zero-value output.
    local hasYieldData = yieldSource ~= nil
    -- currentInputCost: full current-priced value of every required consumed
    -- input for one operation (definition.inputs' structural quantities x
    -- current ValuationService prices). Never historical - see file header.
    local currentInputCost = SumResolvedRows(inputValueRows)
    local outputIncome = (hasYieldData and definition.outputValuationMode ~= "quantityOnly")
        and SumResolvedRows(outputValueRows) or nil
    local resourcefulnessIncome = hasYieldData and SumResolvedRows(resourcefulnessValueRows) or nil

    local expectedOperationIncome = nil
    if hasYieldData and outputIncome ~= nil and resourcefulnessIncome ~= nil then
        expectedOperationIncome = outputIncome + resourcefulnessIncome
    end

    -- Expected profit/ROI are always driven by currentInputCost, never by
    -- historicalOperationCost - historical cost is informational only.
    local expectedNet = nil
    if currentInputCost ~= nil and expectedOperationIncome ~= nil then
        expectedNet = expectedOperationIncome - currentInputCost
    end

    -- Percent return on the required inputs. nil (not zero) whenever cost or
    -- net is unresolved, or cost is zero (division is undefined) - never
    -- guessed past a missing price the same way the sums above never are.
    local expectedROIPercent = nil
    if expectedNet ~= nil and currentInputCost ~= nil and currentInputCost ~= 0 then
        expectedROIPercent = (expectedNet / currentInputCost) * 100
    end

    local yieldStatus = YIELD_STATUS_UNKNOWN
    if outcomeService and outcomeService.GetYieldStatus then
        yieldStatus = outcomeService:GetYieldStatus(aggregate or definition.profileKey)
    end

    local effective = aggregate and aggregate.effective or {}
    local currentEffectiveInputCostPerCraft = nil
    if currentInputCost ~= nil and resourcefulnessIncome ~= nil then
        currentEffectiveInputCostPerCraft = currentInputCost - resourcefulnessIncome
    end

    local summary = {
        operationProfileKey = definition.profileKey,
        operationType = definition.operationType,
        recipeID = definition.recipeID,
        currentInputCost = currentInputCost,
        -- Historical operation cost: preserved historical average, informational
        -- only. Never used for expectedNet/expectedROIPercent above.
        historicalOperationCost = aggregate and aggregate.effective and aggregate.effective.avgHistoricalInputCost,
        expectedOperationIncome = expectedOperationIncome,
        expectedOutputValue = outputIncome,
        expectedResourcefulnessValue = resourcefulnessIncome,
        expectedTotalValue = expectedOperationIncome,
        expectedNet = expectedNet,
        expectedROIPercent = expectedROIPercent,
        inputValueRows = inputValueRows,
        outputValueRows = outputValueRows,
        resourcefulnessValueRows = resourcefulnessValueRows,
        observationCount = aggregate and aggregate.runCount or 0,
        -- Built from published starter data, not this user's own crafts.
        isSeedData = aggregate ~= nil and aggregate.isSeedData == true,
        yieldStatus = yieldStatus,
        confidence = yieldStatus,
        missingValues = missingValues,
        countedAsFreeItems = countedAsFreeItems,
        currency = CURRENCY_COPPER,
        unresolved = nil,
        unresolvedReason = nil,

        historicalGrossInputCostPerCraft = effective.avgHistoricalInputCost,
        historicalResourcefulnessValuePerCraft = effective.avgHistoricalResourcefulnessValue,
        historicalEffectiveCostPerCraft = effective.avgHistoricalEffectiveCostPerCraft,
        currentReplacementInputCostPerCraft = currentInputCost,
        currentResourcefulnessValuePerCraft = resourcefulnessIncome,
        currentEffectiveInputCostPerCraft = currentEffectiveInputCostPerCraft,
    }

    if definition.unitAcquisitionOutputItemID then
        local expectedQuantity = yieldSource
            and SumExpectedQuantity(yieldSource.expectedProducedOutputsPerRun, definition.unitAcquisitionOutputItemID)
            or nil
        AddUnitAcquisitionEconomics(summary, expectedQuantity)
    end

    return summary
end

--- Builds the Operation Summary for an operationProfileKey. Tries a direct
-- definition lookup first; falls back to re-deriving a Crafting Operation
-- definition from its recipeID (parsed via OperationProfileKeyService) when
-- nothing has been cached yet this session.
function OperationEconomicsService:SummarizeProfileKey(operationProfileKey, options)
    options = type(options) == "table" and options or {}

    local definitionService = GetDefinitionService()
    if not definitionService then
        return NewUnresolvedSummary(nil, operationProfileKey, "definitionServiceUnavailable")
    end

    local definition = definitionService:GetDefinitionByProfileKey(operationProfileKey)
    if not definition then
        local profileKeyService = GetProfileKeyService()
        local recipeID = profileKeyService and profileKeyService:ParseProfileKey(operationProfileKey)
        if recipeID then
            definition = definitionService:GetDefinition(recipeID, options)
        end
    end

    if not definition then
        return NewUnresolvedSummary(nil, operationProfileKey, "definitionNotFound")
    end

    return self:SummarizeDefinition(definition, options)
end

--- Builds the Operation Summary for a recipeID, operationProfileKey, or an
-- already-resolved OperationDefinition table.
-- @param operationRef number recipeID | string operationProfileKey | table definition
function OperationEconomicsService:SummarizeOperation(operationRef, options)
    options = type(options) == "table" and options or {}

    if type(operationRef) == "number" then
        local definitionService = GetDefinitionService()
        if not definitionService then
            return NewUnresolvedSummary(operationRef, nil, "definitionServiceUnavailable")
        end
        local definition = definitionService:GetDefinition(operationRef, options)
        return self:SummarizeDefinition(definition, options)
    end

    if type(operationRef) == "string" then
        return self:SummarizeProfileKey(operationRef, options)
    end

    if type(operationRef) == "table" then
        return self:SummarizeDefinition(operationRef, options)
    end

    return NewUnresolvedSummary(nil, nil, "unsupportedOperationRef")
end

if PocketCFO then
    PocketCFO.OperationEconomicsService = OperationEconomicsService
end

_G.PocketCFO_OperationEconomicsService = OperationEconomicsService
