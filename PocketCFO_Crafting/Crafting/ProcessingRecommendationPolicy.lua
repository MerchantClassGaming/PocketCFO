-- PocketCFO_Crafting/Crafting/ProcessingRecommendationPolicy.lua
-- Owns which evaluated processing rows are shown, per processing type.
--
-- ProcessingAnalysisController is the one reusable evaluator - it builds an
-- Operation Summary (via Core's OperationEconomicsService) for every
-- candidate primary input. This module only decides which of those
-- already-evaluated rows survive for display. It performs no valuation and
-- no economics of its own, and adding a new processing type means adding a
-- new policy here, never a new evaluator architecture.
--
-- Each policy receives a list of evaluated rows:
--   { itemID, configKey, itemName, summary, outputFamilyKey }
-- where `summary` is an OperationEconomicsService Operation Summary for
-- that specific candidate input, and returns the subset to display.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local ProcessingRecommendationPolicy = PocketCFO_Crafting:NewModule("ProcessingRecommendationPolicy")

ProcessingRecommendationPolicy.POLICY_EVALUATE_ALL_INPUTS = "EvaluateAllInputs"
ProcessingRecommendationPolicy.POLICY_RECOMMEND_CHEAPEST_INPUT = "RecommendCheapestInput"
ProcessingRecommendationPolicy.POLICY_RECOMMEND_BEST_INPUT_PER_OUTPUT_FAMILY = "RecommendBestInputPerOutputFamily"
ProcessingRecommendationPolicy.POLICY_RECOMMEND_TOP_N_PER_OUTPUT_FAMILY = "RecommendTopNPerOutputFamily"

local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

local function GetComparisonService()
    return PocketCFO and PocketCFO.OperationComparisonService or _G.PocketCFO_OperationComparisonService
end

--- Displays every evaluated row, unfiltered - "evaluate every valid input,
-- display every result" (Prospecting, Milling).
function ProcessingRecommendationPolicy.EvaluateAllInputs(rows)
    return rows or {}
end

--- Ranks candidates by currentCostPerUnitOutput ascending for unit-acquisition
-- workflows (Alchemy Recycling). Resolved rows come first; unresolved rows are
-- retained after them in stable input order so observed profiles do not vanish
-- just because yield or pricing is incomplete.
function ProcessingRecommendationPolicy.RecommendCheapestInput(rows)
    rows = rows or {}
    SessionLog("ProcessingRecommendationPolicy:RecommendCheapestInput: DIAG inputRows=%d", #rows)
    local ranked = {}
    for i = 1, #rows do
        ranked[i] = i
    end

    table.sort(ranked, function(a, b)
        local summaryA = rows[a] and rows[a].summary
        local summaryB = rows[b] and rows[b].summary
        local costA = type(summaryA) == "table" and summaryA.currentCostPerUnitOutput or nil
        local costB = type(summaryB) == "table" and summaryB.currentCostPerUnitOutput or nil
        if costA ~= nil and costB ~= nil and costA ~= costB then
            return costA < costB
        end
        if costA ~= nil and costB == nil then return true end
        if costA == nil and costB ~= nil then return false end
        return a < b
    end)

    local result = {}
    for _, index in ipairs(ranked) do
        result[#result + 1] = rows[index]
    end
    return result
end

--- Groups rows by row.outputFamilyKey and keeps the best (highest
-- expectedNet) row per family (Engineering Recycling: "recommend best
-- input for each output family"). Rows without an outputFamilyKey are
-- excluded entirely - this policy never guesses a row's output family.
function ProcessingRecommendationPolicy.RecommendBestInputPerOutputFamily(rows)
    rows = rows or {}

    local comparisonService = GetComparisonService()
    if not comparisonService or not comparisonService.CompareMany then
        return {}
    end

    local rowsByFamily = {}
    local familyOrder = {}
    for _, row in ipairs(rows) do
        local family = row.outputFamilyKey
        if family then
            if not rowsByFamily[family] then
                rowsByFamily[family] = {}
                familyOrder[#familyOrder + 1] = family
            end
            table.insert(rowsByFamily[family], row)
        end
    end

    local winners = {}
    for _, family in ipairs(familyOrder) do
        local familyRows = rowsByFamily[family]
        local summaries = {}
        for i, row in ipairs(familyRows) do
            summaries[i] = row.summary
        end
        local comparison = comparisonService:CompareMany(summaries, { metric = "expectedNet" })
        if comparison.best then
            winners[#winners + 1] = familyRows[comparison.best.index]
        end
    end

    return winners
end

-- Sentinel family for candidates whose output family could not be resolved
-- (e.g. CrushingAnalysisPolicy:ResolveOutputFamily returned nil,nil for an
-- unrecognized/unresolved quality tier). A candidate the game genuinely
-- produced/observed must never look identical to "this profile doesn't
-- exist" from the player's perspective - routing it into its own family
-- bucket reuses the exact same ranking/limiting/rendering path every other
-- family already gets (InventoryManagerWindow:RenderAnalysis groups
-- generically by row.outputFamilyKey, no window change required), so an
-- unresolved-family candidate renders as a visible section instead of
-- silently vanishing.
local UNRESOLVED_FAMILY_KEY = "unresolvedOutputFamily"
local UNRESOLVED_FAMILY_LABEL = "Unresolved Output Family (quality tier not determined)"

--- Groups rows by row.outputFamilyKey and ranks each group by expectedNet
-- (Crushing: "compare every known observed gem profile within a
-- quality-tier family and rank them"). Unlike RecommendBestInputPerOutputFamily
-- (single winner, unresolved-metric rows dropped), a candidate backed by a
-- real observation is never deleted just because pricing hasn't resolved
-- yet - resolved candidates rank first (highest expectedNet first),
-- unresolved candidates are kept and appended after them (stable, original
-- order) rather than discarded. Rows whose outputFamilyKey could not be
-- resolved are NOT excluded - they are stamped into the UNRESOLVED_FAMILY_KEY
-- sentinel bucket and ranked/returned alongside every other family, so a
-- genuinely-observed candidate is never invisible just because its quality
-- tier couldn't be classified.
--
-- Returns the FULL ranked set per family, not just a top slice - this is
-- the evaluation/recommendation layer, which must not truncate for
-- display. The Top Results / All Results display limit is applied
-- downstream by ProcessingAnalysisDisplayModelBuilder:LimitRowsPerFamily,
-- driven by CraftQueueController's toggle state, so switching between them
-- never re-runs this policy or re-evaluates economics.
function ProcessingRecommendationPolicy.RecommendTopNInputsPerOutputFamily(rows)
    rows = rows or {}

    local comparisonService = GetComparisonService()
    if not comparisonService or not comparisonService.CompareMany then
        SessionLog("ProcessingRecommendationPolicy:RecommendTopNInputsPerOutputFamily: DIAG dropped reason=comparisonServiceUnavailable")
        return {}
    end

    local rowsByFamily = {}
    local familyOrder = {}
    for _, row in ipairs(rows) do
        if not row.outputFamilyKey then
            SessionLog("ProcessingRecommendationPolicy:RecommendTopNInputsPerOutputFamily: DIAG unresolvedFamily itemID=%s itemName=%s configKey=%s -> routed to sentinel bucket instead of dropped",
                tostring(row.itemID), tostring(row.itemName or row.itemLabel), tostring(row.configKey))
            row.outputFamilyKey = UNRESOLVED_FAMILY_KEY
            row.outputFamilyLabel = UNRESOLVED_FAMILY_LABEL
        end
        local family = row.outputFamilyKey
        if not rowsByFamily[family] then
            rowsByFamily[family] = {}
            familyOrder[#familyOrder + 1] = family
        end
        table.insert(rowsByFamily[family], row)
    end

    local winners = {}
    for _, family in ipairs(familyOrder) do
        local familyRows = rowsByFamily[family]
        local summaries = {}
        for i, row in ipairs(familyRows) do
            summaries[i] = row.summary
            SessionLog("ProcessingRecommendationPolicy:RecommendTopNInputsPerOutputFamily: DIAG family=%s row[%d] itemID=%s unresolved=%s unresolvedReason=%s expectedNet=%s observationCount=%s",
                tostring(family), i, tostring(row.itemID),
                tostring(row.summary and row.summary.unresolved), tostring(row.summary and row.summary.unresolvedReason),
                tostring(row.summary and row.summary.expectedNet), tostring(row.summary and row.summary.observationCount))
        end

        local comparison = comparisonService:CompareMany(summaries, { metric = "expectedNet" })

        -- Stable ranking: resolved candidates first (highest expectedNet
        -- first), unresolved candidates after in their original order.
        -- comparison.results[i] corresponds to familyRows[i].
        local ranked = {}
        for i = 1, #familyRows do
            ranked[i] = i
        end
        table.sort(ranked, function(a, b)
            local resultA, resultB = comparison.results[a], comparison.results[b]
            local aResolved = resultA ~= nil and not resultA.unresolved
            local bResolved = resultB ~= nil and not resultB.unresolved
            if aResolved and bResolved then
                return resultA.value > resultB.value
            end
            if aResolved ~= bResolved then
                return aResolved
            end
            return a < b
        end)

        for i = 1, #ranked do
            winners[#winners + 1] = familyRows[ranked[i]]
        end

        SessionLog("ProcessingRecommendationPolicy:RecommendTopNInputsPerOutputFamily: DIAG family=%s candidates=%d ranked=%d",
            tostring(family), #familyRows, #ranked)
    end

    return winners
end

local POLICY_FUNCTIONS = {
    [ProcessingRecommendationPolicy.POLICY_EVALUATE_ALL_INPUTS] = ProcessingRecommendationPolicy.EvaluateAllInputs,
    [ProcessingRecommendationPolicy.POLICY_RECOMMEND_CHEAPEST_INPUT] = ProcessingRecommendationPolicy.RecommendCheapestInput,
    [ProcessingRecommendationPolicy.POLICY_RECOMMEND_BEST_INPUT_PER_OUTPUT_FAMILY] = ProcessingRecommendationPolicy.RecommendBestInputPerOutputFamily,
    [ProcessingRecommendationPolicy.POLICY_RECOMMEND_TOP_N_PER_OUTPUT_FAMILY] = ProcessingRecommendationPolicy.RecommendTopNInputsPerOutputFamily,
}

--- Applies the named policy to a list of evaluated rows.
-- @return table rows, string|nil errorReason ("unknownPolicy" when
--         policyName isn't registered)
function ProcessingRecommendationPolicy:Apply(policyName, rows)
    local policyFn = POLICY_FUNCTIONS[policyName]
    if not policyFn then
        SessionLog("ProcessingRecommendationPolicy:Apply: DIAG reason=unknownPolicy policyName=%s", tostring(policyName))
        return {}, "unknownPolicy"
    end
    local surviving = policyFn(rows)
    SessionLog("ProcessingRecommendationPolicy:Apply: DIAG policyName=%s inputRows=%d survivingRows=%d",
        tostring(policyName), type(rows) == "table" and #rows or 0, type(surviving) == "table" and #surviving or 0)
    return surviving, nil
end

function ProcessingRecommendationPolicy:OnEnable()
end

function ProcessingRecommendationPolicy:OnDisable()
end
