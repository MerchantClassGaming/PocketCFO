-- PocketCFO_Crafting/Crafting/ProcessingAnalysisDisplayModelBuilder.lua
-- Converts an OperationEconomicsService Operation Summary (plus the
-- candidate item it was built for) into user-facing display rows: a
-- compact list row (BuildRow) and an expanded detail row (BuildDetailRow).
--
-- User-facing fields only. Never invents a value: a row with a missing
-- price gets valueUnavailableReason = "needsPrice", a row with no observed
-- craft yield yet gets "noData" - neither is ever displayed or sorted as
-- zero. Formatting numbers into strings/colors is the window's job; this
-- builder hands over raw numeric fields plus a status classification.
--
-- statusColor is a semantic color name ("green"/"yellow"/"red"/"grey"), the
-- same convention InventoryManagerWindow already uses for matStatus. This
-- builder does not pick RGBA pixel values - that mapping is the UI step's
-- job, kept here only as the agreed-upon name so rendering stays trivial.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local ProcessingAnalysisDisplayModelBuilder = PocketCFO_Crafting:NewModule("ProcessingAnalysisDisplayModelBuilder")

-- Temporary diagnostics for the "Prospecting rows show No data" investigation.
-- Remove once root cause is confirmed fixed in-game.
local function SessionLog(fmt, ...)
    local core = _G.PocketCFO
    if not core or not core.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    core:AppendSessionLog("[MCG] " .. msg)
end

-- summary.observationCount is hardwired to 0 whenever the summary is
-- unresolved (see OperationEconomicsService.NewUnresolvedSummary), which
-- would hide real recorded outcome data behind an earlier unresolved gate
-- (e.g. a missing OperationDefinitionService registration). Queried
-- independently here so the diagnostic reflects what OperationOutcomeService
-- actually has on file for this profileKey, not what the (possibly
-- short-circuited) summary reports.
local function GetIndependentOutcomeFacts(operationProfileKey)
    if not operationProfileKey then
        return false, 0
    end
    local outcomeService = _G.PocketCFO and _G.PocketCFO.OperationOutcomeService
        or _G.PocketCFO_OperationOutcomeService
    local aggregate = outcomeService and outcomeService.GetAggregate
        and outcomeService:GetAggregate(operationProfileKey)
    local runCount = aggregate and aggregate.runCount or 0
    return runCount > 0, runCount
end

ProcessingAnalysisDisplayModelBuilder.STATUS_GOOD = "good"
ProcessingAnalysisDisplayModelBuilder.STATUS_NEUTRAL = "neutral"
ProcessingAnalysisDisplayModelBuilder.STATUS_BAD = "bad"
ProcessingAnalysisDisplayModelBuilder.STATUS_LOW_CONFIDENCE = "lowConfidence"
ProcessingAnalysisDisplayModelBuilder.STATUS_UNAVAILABLE = "unavailable"

ProcessingAnalysisDisplayModelBuilder.VALUE_UNAVAILABLE_NEEDS_PRICE = "needsPrice"
ProcessingAnalysisDisplayModelBuilder.VALUE_UNAVAILABLE_NO_DATA = "noData"

local STATUS_COLOR_BY_KIND = {
    good = "green",
    neutral = "yellow",
    bad = "red",
    lowConfidence = "grey",
    unavailable = "grey",
}

-- Reasons ValuationService/OperationEconomicsService use specifically for
-- "we don't know what this item is worth" - as opposed to reasons like
-- "no crafts observed yet" that are a data problem, not a pricing problem.
-- Classification only (see VALUE_UNAVAILABLE_* above), never the note text
-- itself.
local PRICE_REASONS = {
    valuationAddonUnavailable = true,
    valuationModulesUnavailable = true,
    noPriceData = true,
    marketKeyUnresolved = true,
    configKeyRequiresItemID = true,
}

local function IsPriceReason(reason)
    return reason ~= nil and PRICE_REASONS[reason] == true
end

-- Short, user-facing explanations for the internal unresolved/missing-value
-- reason codes OperationEconomicsService/ValuationService/OperationDefinitionService
-- produce. No financial jargon - these are plain status notes.
local UNRESOLVED_REASON_NOTES = {
    valuationAddonUnavailable = "No economics value available: valuation addon not loaded",
    valuationModulesUnavailable = "No economics value available: valuation addon not loaded",
    definitionNotFound = "Recipe not flagged for processing analysis yet",
    definitionNotRegistered = "No outcome observations yet",
    processingOperationNotRegistered = "Recipe not flagged for processing analysis yet",
    primaryInputMissing = "Item identity not resolved yet",
    inputQuantityMissing = "Recipe input quantity not curated yet",
    definitionMissingInputs = "Recipe structure unavailable",
    missingDefinition = "Recipe structure unavailable",
    definitionServiceUnavailable = "Analysis services unavailable",
    unsupportedOperationRef = "Recipe not recognized",
    noPriceData = "No economics value available: no market price found",
    marketKeyUnresolved = "No economics value available: item not identifiable for pricing",
    configKeyRequiresItemID = "No economics value available: item not identifiable for pricing",
    noObservedYield = "No outcome observations yet",
    statisticalProfileRequired = "Select a specific input to see its economics",
    statisticalProfileNotObserved = "No outcome observations yet for this input",
}

-- Plain-language label for rows built from published starter data. Local
-- data takes over once it matches the starter row's run count, capped at
-- OperationOutcomeService's single handoff constant.
local function SeedDataNote()
    local outcomeService = _G.PocketCFO and _G.PocketCFO.OperationOutcomeService
        or _G.PocketCFO_OperationOutcomeService
    local handoff = outcomeService and outcomeService.SEED_HANDOFF_RUN_COUNT or 20
    return string.format("Starter data - your own crafts take over once you've done as many runs (%d at most).", handoff)
end

function ProcessingAnalysisDisplayModelBuilder:GetSeedDataNote()
    return SeedDataNote()
end

local function NoteForReason(reason)
    if not reason then
        return nil
    end
    return UNRESOLVED_REASON_NOTES[reason] or ("Unavailable: " .. tostring(reason))
end

-- "No price, counted as free: Multicraft Manifold, ..." for the inputs /
-- resourcefulness returns OperationEconomicsService counted as free (see
-- summary.countedAsFreeItems). One name per itemID. nil when none.
local function CountedAsFreeNote(summary)
    local items = type(summary.countedAsFreeItems) == "table" and summary.countedAsFreeItems or {}
    local names, seen = {}, {}
    for _, item in ipairs(items) do
        local key = item.itemID or item.configKey
        if key and not seen[key] then
            seen[key] = true
            local name = item.itemName
            if not name and item.itemID and C_Item and C_Item.GetItemInfo then
                local ok, infoName = pcall(C_Item.GetItemInfo, item.itemID)
                name = ok and infoName or nil
            end
            names[#names + 1] = name or ("Item " .. tostring(item.itemID))
        end
    end
    if #names == 0 then
        return nil
    end
    return "No price, counted as free: " .. table.concat(names, ", ")
end

-- Appends the crafting-quality tier to the display label (e.g. "Refulgent
-- Copper Ore Q1") so same-named quality variants are distinguishable by name
-- alone, not just by the icon's quality-tier overlay. quality is only ever
-- appended when it is a known, meaningful positive tier - never guessed or
-- defaulted to 0/1 for items with no quality data.
--
-- Idempotent by construction: if itemLabel already ends with the exact
-- " Q<n>" suffix this call would produce, it is returned unchanged rather
-- than suffixed a second time. This is what makes it safe for a caller to
-- pass an itemLabel that was already formatted by an earlier BuildRow call
-- (e.g. BuildDetailRow re-deriving a row from a previously-built list row's
-- itemLabel) back through this same formatter without producing "Name Q2
-- Q2" - the single authoritative label from the first formatting pass wins.
local function FormatItemLabel(itemLabel, quality)
    itemLabel = itemLabel or "Unknown"
    quality = tonumber(quality)
    if not quality or quality <= 0 then
        return itemLabel
    end
    local suffix = string.format(" Q%d", quality)
    if itemLabel:sub(-#suffix) == suffix then
        return itemLabel
    end
    return itemLabel .. suffix
end

--- Builds one display row for one candidate item's Operation Summary.
-- @param itemLabel string user-facing item name (already resolved by the
--        caller - this builder does not look up item names itself)
-- @param summary table OperationEconomicsService Operation Summary
-- @param extra table|nil { itemID, configKey, quality, itemLink,
--        outputFamilyKey, outputFamilyLabel } carried through for the
--        window's row-click -> detail-view lookup, icon/quality-overlay
--        rendering, and (outputFamilyKey/Label) grouped-section rendering
--        for policies that group by output family (e.g. Crushing's
--        quality-tier groups) - nil for ungrouped processing types.
--        quality is also folded into itemLabel (see FormatItemLabel).
function ProcessingAnalysisDisplayModelBuilder:BuildRow(itemLabel, summary, extra)
    summary = type(summary) == "table" and summary or {}
    extra = type(extra) == "table" and extra or {}
    local unitAcquisitionMode = extra.analysisMode == "unitAcquisitionCost"

    local base = {
        itemLabel = FormatItemLabel(itemLabel, extra.quality),
        itemID = extra.itemID,
        configKey = extra.configKey,
        quality = extra.quality,
        itemLink = extra.itemLink,
        currency = summary.currency or "copper",
        summary = summary,
        outputFamilyKey = extra.outputFamilyKey,
        outputFamilyLabel = extra.outputFamilyLabel,

        currentInputCost = summary.currentInputCost,
        historicalOperationCost = summary.historicalOperationCost,
        expectedOutputValue = summary.expectedOutputValue,
        expectedResourcefulnessValue = summary.expectedResourcefulnessValue,
        expectedTotalValue = summary.expectedTotalValue,
        expectedROIPercent = summary.expectedROIPercent,
        observationCount = summary.observationCount or 0,
        analysisMode = extra.analysisMode,
        outputItemName = extra.outputItemName,
        expectedUnitOutputQuantity = summary.expectedUnitOutputQuantity,
        currentEffectiveAcquisitionCost = summary.currentEffectiveAcquisitionCost,
        currentCostPerUnitOutput = summary.currentCostPerUnitOutput,
        historicalEffectiveAcquisitionCost = summary.historicalEffectiveAcquisitionCost,
        historicalCostPerUnitOutput = summary.historicalCostPerUnitOutput,

        isSeedData = summary.isSeedData == true,
        seedDataNote = summary.isSeedData and SeedDataNote() or nil,
    }

    if summary.unresolved then
        base.expectedPerCraft = nil
        base.valueUnavailableReason = IsPriceReason(summary.unresolvedReason)
            and self.VALUE_UNAVAILABLE_NEEDS_PRICE or self.VALUE_UNAVAILABLE_NO_DATA
        base.statusKind = self.STATUS_UNAVAILABLE
        base.statusColor = STATUS_COLOR_BY_KIND[self.STATUS_UNAVAILABLE]
        base.note = NoteForReason(summary.unresolvedReason)
        base.unresolvedReason = summary.unresolvedReason
        do
            local outcomeFound, runCount = GetIndependentOutcomeFacts(summary.operationProfileKey)
            SessionLog("ProspectingAnalysis row: recipeID=%s input itemID=%s input configKey=%s operationProfileKey=%s outcomeFound=%s runCount=%s economicsResolved=false unresolvedReason=%s renderExpectedCraftValue=%s",
                tostring(summary.recipeID), tostring(extra.itemID), tostring(extra.configKey),
                tostring(summary.operationProfileKey), tostring(outcomeFound),
                tostring(runCount), tostring(summary.unresolvedReason), tostring(base.expectedPerCraft))
        end
        return base
    end

    local hasFullPicture = unitAcquisitionMode
        and summary.currentCostPerUnitOutput ~= nil
        or (summary.currentInputCost ~= nil and summary.expectedOperationIncome ~= nil)

    if not hasFullPicture then
        local firstMissing = type(summary.missingValues) == "table" and summary.missingValues[1] or nil
        local reason = firstMissing and firstMissing.reason
        base.expectedPerCraft = nil
        base.valueUnavailableReason = IsPriceReason(reason)
            and self.VALUE_UNAVAILABLE_NEEDS_PRICE or self.VALUE_UNAVAILABLE_NO_DATA
        base.statusKind = self.STATUS_LOW_CONFIDENCE
        base.statusColor = STATUS_COLOR_BY_KIND[self.STATUS_LOW_CONFIDENCE]
        base.note = NoteForReason(reason) or "Not enough data yet"
        base.unresolvedReason = nil
        do
            local outcomeFound, runCount = GetIndependentOutcomeFacts(summary.operationProfileKey)
            SessionLog("ProspectingAnalysis row: recipeID=%s input itemID=%s input configKey=%s operationProfileKey=%s outcomeFound=%s runCount=%s economicsResolved=false unresolvedReason=%s renderExpectedCraftValue=%s",
                tostring(summary.recipeID), tostring(extra.itemID), tostring(extra.configKey),
                tostring(summary.operationProfileKey), tostring(outcomeFound),
                tostring(runCount), tostring(reason), tostring(base.expectedPerCraft))
        end
        return base
    end

    if unitAcquisitionMode then
        base.expectedPerCraft = summary.currentCostPerUnitOutput
    else
        base.expectedPerCraft = summary.expectedNet
    end
    base.valueUnavailableReason = nil
    base.unresolvedReason = nil
    base.note = CountedAsFreeNote(summary)

    if unitAcquisitionMode then
        base.statusKind = self.STATUS_NEUTRAL
    elseif summary.expectedNet > 0 then
        base.statusKind = self.STATUS_GOOD
    elseif summary.expectedNet < 0 then
        base.statusKind = self.STATUS_BAD
    else
        base.statusKind = self.STATUS_NEUTRAL
    end

    SessionLog("ProspectingAnalysis row: recipeID=%s input itemID=%s input configKey=%s operationProfileKey=%s outcomeFound=%s runCount=%s economicsResolved=true unresolvedReason=nil renderExpectedCraftValue=%s",
        tostring(summary.recipeID), tostring(extra.itemID), tostring(extra.configKey),
        tostring(summary.operationProfileKey), tostring((summary.observationCount or 0) > 0),
        tostring(summary.observationCount or 0), tostring(base.expectedPerCraft))
    base.statusColor = STATUS_COLOR_BY_KIND[base.statusKind]

    return base
end

-- Default rows kept per output family for the "Top Results" display mode
-- (Crushing's Low-Quality/High-Quality groups). This is a presentation
-- concern only - ProcessingRecommendationPolicy hands back the FULL ranked
-- set per family; this builder is what narrows it for display, on request
-- from CraftQueueController's toggle state.
ProcessingAnalysisDisplayModelBuilder.TOP_N_PER_FAMILY = 3

--- Truncates an already-ranked list of display rows down to at most
-- limitPerFamily rows per row.outputFamilyKey, preserving existing order -
-- families are ranked/sorted upstream (resolved-first, highest expectedNet
-- first, within each family) by ProcessingRecommendationPolicy; this only
-- truncates, it never re-sorts or re-groups. Rows with no outputFamilyKey
-- (every non-grouped processing type) are always kept unchanged.
-- @param rows table display rows (as returned by BuildRows)
-- @param limitPerFamily number|nil rows to keep per family; nil means no
--        limit ("All Results" mode)
function ProcessingAnalysisDisplayModelBuilder:LimitRowsPerFamily(rows, limitPerFamily)
    rows = rows or {}
    if not limitPerFamily then
        return rows
    end

    local countByFamily = {}
    local limited = {}
    for _, row in ipairs(rows) do
        local family = row.outputFamilyKey
        if not family then
            limited[#limited + 1] = row
        else
            local count = countByFamily[family] or 0
            if count < limitPerFamily then
                countByFamily[family] = count + 1
                limited[#limited + 1] = row
            end
        end
    end
    return limited
end

--- Builds display rows for a list of evaluated rows carrying
-- .itemLabel/.itemName, .itemID/.configKey, .quality, .itemLink,
-- .outputFamilyKey/.outputFamilyLabel, and .summary fields, as produced by
-- ProcessingAnalysisController.
function ProcessingAnalysisDisplayModelBuilder:BuildRows(evaluatedRows, options)
    options = type(options) == "table" and options or {}
    local displayRows = {}
    for _, row in ipairs(evaluatedRows or {}) do
        local label = row.itemLabel or row.itemName or row.label
        displayRows[#displayRows + 1] = self:BuildRow(label, row.summary, {
            itemID = row.itemID,
            configKey = row.configKey,
            quality = row.quality,
            itemLink = row.itemLink,
            outputFamilyKey = row.outputFamilyKey,
            outputFamilyLabel = row.outputFamilyLabel,
            analysisMode = options.analysisMode,
            outputItemName = options.outputItemName,
        })
    end
    return displayRows
end

--- Builds the expanded detail-view model for one already-built list row
-- (or any itemLabel/summary pair). Reuses BuildRow's classification so list
-- and detail views never disagree about status/needsPrice, and adds the
-- per-item output/resourcefulness/input line lists the detail view shows.
function ProcessingAnalysisDisplayModelBuilder:BuildDetailRow(itemLabel, summary, extra)
    local row = self:BuildRow(itemLabel, summary, extra)
    summary = type(summary) == "table" and summary or {}
    row.inputs = summary.inputValueRows or {}
    row.outputs = summary.outputValueRows or {}
    row.resourcefulnessReturns = summary.resourcefulnessValueRows or {}
    return row
end

function ProcessingAnalysisDisplayModelBuilder:OnEnable()
end

function ProcessingAnalysisDisplayModelBuilder:OnDisable()
end
