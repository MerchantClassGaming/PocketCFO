-- PocketCFO/Services/OperationComparisonService/OperationComparisonService.lua
-- Compares already-built Operation Summaries by a supplied numeric metric.
--
-- This service performs no valuation, no operation-path lookups, and no
-- structural/observation work of its own - it only reads the summaries it
-- is given (from OperationEconomicsService) and reports which is larger by
-- the requested metric. It does not own user-facing recommendations; the
-- "winner"/"best" fields below are the literal comparison result, not a
-- suggested action.

local PocketCFO = _G.PocketCFO

local OperationComparisonService = {}

OperationComparisonService.DEFAULT_METRIC = "expectedNet"

local function GetMetricValue(summary, metric)
    if type(summary) ~= "table" then
        return nil, "missingSummary"
    end
    if summary.unresolved then
        return nil, summary.unresolvedReason or "summaryUnresolved"
    end

    local value = summary[metric]
    if value == nil then
        return nil, "metricUnavailable"
    end
    if type(value) ~= "number" then
        return nil, "metricNotNumeric"
    end
    return value, nil
end

local function SummaryRef(summary)
    return type(summary) == "table" and summary.operationProfileKey or nil
end

--- Compares two Operation Summaries by one numeric metric (default
-- "expectedNet"). Returns unresolved if either summary is incomplete for
-- the requested metric - it never guesses a winner from partial data.
-- @param options table|nil { metric = "expectedNet" | "currentInputCost" | "expectedOperationIncome" }
function OperationComparisonService:CompareSummaries(summaryA, summaryB, options)
    options = type(options) == "table" and options or {}
    local metric = options.metric or self.DEFAULT_METRIC

    local valueA, reasonA = GetMetricValue(summaryA, metric)
    local valueB, reasonB = GetMetricValue(summaryB, metric)

    if valueA == nil or valueB == nil then
        return {
            metric = metric,
            unresolved = true,
            unresolvedReason = (valueA == nil and reasonA) or reasonB,
            a = { value = valueA, unresolvedReason = reasonA, operationProfileKey = SummaryRef(summaryA) },
            b = { value = valueB, unresolvedReason = reasonB, operationProfileKey = SummaryRef(summaryB) },
        }
    end

    local winner
    if valueA > valueB then
        winner = "a"
    elseif valueB > valueA then
        winner = "b"
    else
        winner = "tie"
    end

    return {
        metric = metric,
        unresolved = nil,
        a = { value = valueA, operationProfileKey = SummaryRef(summaryA) },
        b = { value = valueB, operationProfileKey = SummaryRef(summaryB) },
        difference = valueA - valueB,
        winner = winner,
    }
end

--- Compares any number of Operation Summaries by one numeric metric.
-- Returns one entry per input summary (preserving order) plus the entry
-- with the highest resolved value, if any.
function OperationComparisonService:CompareMany(summaries, options)
    options = type(options) == "table" and options or {}
    local metric = options.metric or self.DEFAULT_METRIC

    local results = {}
    if type(summaries) ~= "table" then
        return { metric = metric, results = results, best = nil }
    end

    local best = nil
    for i, summary in ipairs(summaries) do
        local value, reason = GetMetricValue(summary, metric)
        local entry = {
            index = i,
            operationProfileKey = SummaryRef(summary),
            value = value,
            unresolved = value == nil,
            unresolvedReason = reason,
        }
        results[#results + 1] = entry
        if value ~= nil and (not best or value > best.value) then
            best = entry
        end
    end

    return {
        metric = metric,
        results = results,
        best = best,
    }
end

if PocketCFO then
    PocketCFO.OperationComparisonService = OperationComparisonService
end

_G.PocketCFO_OperationComparisonService = OperationComparisonService
