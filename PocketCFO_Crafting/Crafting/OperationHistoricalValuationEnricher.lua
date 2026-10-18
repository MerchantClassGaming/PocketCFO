-- PocketCFO_Crafting/Crafting/OperationHistoricalValuationEnricher.lua
-- Attaches observation-time monetary facts to a physical OperationObservation
-- before it is recorded by Core's OperationOutcomeService:
--
--   OperationObservationBuilder
--       physical observation
--           |
--   OperationHistoricalValuationEnricher
--       attaches observation-time monetary facts
--           |
--   OperationOutcomeService:RecordObservation
--
-- Reads current ValuationService prices to compute what this specific craft
-- was worth AT THE TIME it happened. OperationOutcomeService stores these
-- facts verbatim and never calls ValuationService itself; the facts are
-- never recalculated or repriced later.
--
-- Valuation policy: a resolved current or stale-cached price is used as-is;
-- an unresolved price contributes zero to the sum and increments the
-- matching diagnostic counter. The run is never excluded and the sum is
-- never rejected because of one unpriced item.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local OperationHistoricalValuationEnricher = PocketCFO_Crafting:NewModule("OperationHistoricalValuationEnricher")

local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

-- Same safe-access pattern OperationEconomicsService uses: never force-load
-- PocketCFO_Valuation as a side effect of enriching an observation.
local function GetValuationService()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_Valuation"))
        or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_Valuation"))
    if not loaded then
        return nil
    end
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule("ValuationService", true)
end

local function NormalizeQuantity(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return 0
end

-- Sums quantity x observation-time unit value across a list of
-- { itemID, configKey, quantity } rows (OperationObservation's
-- consumedInputs/resourcefulnessReturns shape). An unresolved/unpriced item
-- contributes zero to the sum and increments unresolvedCount - never
-- rejects the sum, never excludes the run.
local function SumHistoricalValue(valuationService, rows)
    local total, unresolvedCount = 0, 0
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        local quantity = NormalizeQuantity(row and row.quantity)
        if quantity > 0 then
            local priced = valuationService:GetItemValue({ itemID = row.itemID, configKey = row.configKey })
            if priced.unresolved then
                unresolvedCount = unresolvedCount + 1
            else
                total = total + (tonumber(priced.valuePerUnit) or 0) * quantity
            end
        end
    end
    return total, unresolvedCount
end

--- Attaches historicalInputCost/historicalResourcefulnessValue and their
-- unresolved-valuation counters to a physical OperationObservation. Mutates
-- and returns the same observation table - purely additive fields; no
-- existing field is read or changed. Safe to call on any observation
-- (including one with unresolved=true - it still gets zeroed historical
-- facts rather than being special-cased).
function OperationHistoricalValuationEnricher:Enrich(observation)
    if type(observation) ~= "table" then
        return observation
    end

    local valuationService = GetValuationService()
    if not valuationService then
        observation.historicalInputCost = 0
        observation.historicalResourcefulnessValue = 0
        observation.unresolvedInputValuationCount =
            (type(observation.consumedInputs) == "table" and #observation.consumedInputs) or 0
        observation.unresolvedResourcefulnessValuationCount =
            (type(observation.resourcefulnessReturns) == "table" and #observation.resourcefulnessReturns) or 0
        SessionLog("OperationHistoricalValuationEnricher: valuation service unavailable, historical facts zeroed profileKey=%s",
            tostring(observation.operationProfileKey))
        return observation
    end

    local inputCost, unresolvedInputCount = SumHistoricalValue(valuationService, observation.consumedInputs)
    local resourcefulnessValue, unresolvedResourcefulnessCount = SumHistoricalValue(valuationService, observation.resourcefulnessReturns)

    observation.historicalInputCost = inputCost
    observation.historicalResourcefulnessValue = resourcefulnessValue
    observation.unresolvedInputValuationCount = unresolvedInputCount
    observation.unresolvedResourcefulnessValuationCount = unresolvedResourcefulnessCount

    SessionLog("OperationHistoricalValuationEnricher: profileKey=%s historicalInputCost=%s historicalResourcefulnessValue=%s unresolvedInput=%d unresolvedResourcefulness=%d",
        tostring(observation.operationProfileKey), tostring(inputCost), tostring(resourcefulnessValue),
        unresolvedInputCount, unresolvedResourcefulnessCount)

    return observation
end

if PocketCFO_Crafting then
    PocketCFO_Crafting.OperationHistoricalValuationEnricher = OperationHistoricalValuationEnricher
end
