-- PocketCFO_Orders/Services/OrderEconomicsService.lua
-- Answers exactly one question: "What is this order worth to the crafter?"
--
--   OrderObservationBuilder
--       read-only normalized order observation
--           |
--   OrderEconomicsService
--       attributes cost/reward/Resourcefulness value to the observation
--           |
--   estimated net value (plus clear row-level unvalued diagnostics)
--
-- Composes three existing services and adds no valuation math of its own:
--   ResourcefulnessPredictionService  - eligibility + expected return quantities
--   ValuationService (PocketCFO_Valuation) - "what is this ConfigKey worth now?"
--   OrderObservationBuilder           - read-only observation capture
--
-- Read-only, stateless, non-persistent, deterministic for a given
-- observation and current valuation state. Does not claim/fulfill orders,
-- change allocations, add UI, or store historical order economics. See
-- PocketCFO_Orders/CLAUDE.md and PocketCFO/CLAUDE.md for the architecture
-- principles this service must respect.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Orders = _G.PocketCFO_Orders

local OrderEconomicsService = PocketCFO_Orders:NewModule("OrderEconomicsService")

local function GetObservationBuilder()
    return PocketCFO_Orders:GetModule("OrderObservationBuilder", true)
end

local function GetResourcefulnessPredictionService()
    return (PocketCFO and PocketCFO.ResourcefulnessPredictionService) or _G.PocketCFO_ResourcefulnessPredictionService
end

-- Safe cross-addon access to PocketCFO_Valuation's ValuationService. Never
-- force-loads PocketCFO_Valuation as a side effect of an economics query -
-- same pattern OperationHistoricalValuationEnricher uses in PocketCFO_Crafting.
local function GetValuationService()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_Valuation"))
        or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_Valuation"))
    if not loaded then
        return nil
    end
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule("ValuationService", true)
end

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

local function NewDiagnostics()
    return {
        unvaluedCostInputs = {},
        unvaluedResourcefulnessInputs = {},
        valuationFailures = {},
    }
end

local function Unresolved(reason, diagnostics)
    return {
        resolved = false,
        unresolvedReason = reason,
        diagnostics = diagnostics or NewDiagnostics(),
    }
end

-- Every GetItemValue call is routed through here so an unexpected error
-- inside PocketCFO_Valuation (a different addon we do not control) becomes a
-- diagnostic row instead of an uncaught error breaking order evaluation.
local function SafeGetItemValue(valuationService, itemRef, diagnostics)
    local ok, result = pcall(function()
        return valuationService:GetItemValue(itemRef)
    end)
    if not ok then
        diagnostics.valuationFailures[#diagnostics.valuationFailures + 1] = {
            configKey = itemRef.configKey,
            itemID = itemRef.itemID,
            reason = "valuationUnavailable",
        }
        return nil
    end
    return result
end

-- Same pcall-guard as SafeGetItemValue, for GetCurrencyValue. GetCurrencyValue
-- is a newer, smaller ValuationService API - guarded separately so an older
-- cached ValuationService module without it degrades to "unvalued" instead
-- of erroring.
local function SafeGetCurrencyValue(valuationService, currencyID, diagnostics)
    if type(valuationService.GetCurrencyValue) ~= "function" then
        return nil
    end
    local ok, result = pcall(function()
        return valuationService:GetCurrencyValue({ currencyID = currencyID })
    end)
    if not ok then
        diagnostics.valuationFailures[#diagnostics.valuationFailures + 1] = {
            currencyID = currencyID,
            reason = "valuationUnavailable",
        }
        return nil
    end
    return result
end

local function NewInputRow(row, reason)
    return {
        configKey = row and row.configKey or nil,
        itemID = row and row.itemID or nil,
        currencyID = row and row.currencyID or nil,
        quantity = row and row.quantity or nil,
        suppliedBy = row and row.suppliedBy or nil,
        classification = row and row.classification or nil,
        identityBasis = row and row.identityBasis or nil,
        notChosen = row and row.notChosen == true or nil,
        slotName = row and row.slotName or nil,
        reason = reason,
        unvalued = reason ~= nil,
    }
end

local function MarkUnvaluedInput(diagnostics, row, quantity, reason)
    local unvalued = {
        configKey = row and row.configKey or nil,
        itemID = row and row.itemID or nil,
        currencyID = row and row.currencyID or nil,
        quantity = quantity or (row and row.quantity) or nil,
        suppliedBy = row and row.suppliedBy or nil,
        classification = row and row.classification or nil,
        identityBasis = row and row.identityBasis or nil,
        reason = reason,
    }
    diagnostics.unvaluedCostInputs[#diagnostics.unvaluedCostInputs + 1] = unvalued
    return unvalued
end

-- Prices one { itemID, configKey, quantity } row (a crafterProvidedReagents
-- or finishingReagents row). ValuationService's contract requires itemID
-- alongside configKey - see ValuationService.lua NormalizeItemRef, which
-- treats a bare configKey as unresolved ("configKeyRequiresItemID"). Returns
-- the priced line row; unpriced rows are marked Unvalued and excluded from
-- totals without aborting order economics.
local function PriceCostRow(valuationService, row, diagnostics)
    local quantity = NumberOrNil(row.quantity)
    if not quantity or quantity <= 0 then
        MarkUnvaluedInput(diagnostics, row, row.quantity, "invalidQuantity")
        return NewInputRow(row, "invalidQuantity")
    end

    if not row.itemID then
        MarkUnvaluedInput(diagnostics, row, quantity, "missingConfigKey")
        local unvalued = NewInputRow(row, "missingConfigKey")
        unvalued.quantity = quantity
        return unvalued
    end

    local priced = valuationService and SafeGetItemValue(valuationService, { itemID = row.itemID, configKey = row.configKey }, diagnostics)
    if not priced or priced.unresolved or priced.valuePerUnit == nil then
        MarkUnvaluedInput(diagnostics, row, quantity, "valuationUnavailable")
        local unvalued = NewInputRow(row, "valuationUnavailable")
        unvalued.quantity = quantity
        return unvalued
    end

    local valuePerUnit = NumberOrNil(priced.valuePerUnit) or 0
    return {
        configKey = row.configKey,
        itemID = row.itemID,
        currencyID = row.currencyID,
        quantity = quantity,
        suppliedBy = row.suppliedBy,
        classification = row.classification,
        identityBasis = row.identityBasis,
        valuePerUnit = valuePerUnit,
        lineValue = valuePerUnit * quantity,
        unvalued = false,
    }
end

-- Sums cost rows (crafterProvidedReagents or finishingReagents). Continues
-- past failed rows so every unvaluable input is captured and shown.
local function PriceCostRows(valuationService, rows, diagnostics)
    local total = 0
    local pricedRows = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        local pricedRow = PriceCostRow(valuationService, row, diagnostics)
        pricedRows[#pricedRows + 1] = pricedRow
        if pricedRow and pricedRow.lineValue ~= nil then
            total = total + pricedRow.lineValue
        end
    end
    return total, pricedRows
end

-- Item rewards behave differently from costs: an unpriced reward is listed
-- as Unvalued and excluded from the net value, never blocking the result.
-- Only requires itemID (configKey is optional metadata to
-- ValuationService, same as OperationHistoricalValuationEnricher's usage).
local function ValueItemRewards(valuationService, itemRewards, diagnostics)
    local valuedTotal = 0
    local rewardRows = {}
    for _, row in ipairs(type(itemRewards) == "table" and itemRewards or {}) do
        local quantity = NumberOrNil(row.quantity) or 1
        local priced = valuationService and row.itemID and SafeGetItemValue(valuationService, { itemID = row.itemID, configKey = row.configKey }, diagnostics)
        if priced and not priced.unresolved and priced.valuePerUnit ~= nil then
            local valuePerUnit = NumberOrNil(priced.valuePerUnit) or 0
            local lineValue = valuePerUnit * quantity
            valuedTotal = valuedTotal + lineValue
            rewardRows[#rewardRows + 1] = {
                rewardType = "item",
                configKey = row.configKey,
                itemID = row.itemID,
                quantity = quantity,
                valuePerUnit = valuePerUnit,
                lineValue = lineValue,
                valuationBasis = priced.valuationBasis,
                unvalued = false,
            }
        else
            local unvalued = {
                rewardType = "item",
                configKey = row.configKey,
                itemID = row.itemID,
                quantity = quantity,
                reason = "valuationUnavailable",
                unvalued = true,
            }
            rewardRows[#rewardRows + 1] = unvalued
        end
    end
    return valuedTotal, rewardRows
end

-- Currency rewards: asks ValuationService:GetCurrencyValue per currencyID
-- (Moxie's 600:1 bag-ratio strategy and any other registered currency
-- strategy lives entirely in PocketCFO_Valuation - this only asks the
-- question and consumes the answer, same policy as item rewards: an
-- unpriced currency reward is marked Unvalued in-place and excluded from
-- valuedRewardValue, never blocks resolution).
local function ValueCurrencyRewards(valuationService, currencyRewards, diagnostics)
    local valuedTotal = 0
    local rewardRows = {}
    for _, row in ipairs(type(currencyRewards) == "table" and currencyRewards or {}) do
        local quantity = NumberOrNil(row.quantity) or 1
        local priced = valuationService and row.currencyID and SafeGetCurrencyValue(valuationService, row.currencyID, diagnostics)
        if priced and not priced.unresolved and priced.valuePerUnit ~= nil then
            local valuePerUnit = NumberOrNil(priced.valuePerUnit) or 0
            local lineValue = valuePerUnit * quantity
            valuedTotal = valuedTotal + lineValue
            rewardRows[#rewardRows + 1] = {
                rewardType = "currency",
                currencyID = row.currencyID,
                quantity = quantity,
                valuePerUnit = valuePerUnit,
                lineValue = lineValue,
                valuationBasis = priced.valuationBasis,
                unvalued = false,
            }
        else
            local unvalued = {
                rewardType = "currency",
                currencyID = row.currencyID,
                quantity = quantity,
                reason = "valuationUnavailable",
                unvalued = true,
            }
            rewardRows[#rewardRows + 1] = unvalued
        end
    end
    return valuedTotal, rewardRows
end

-- Resourcefulness applies to consumed reagents regardless of who supplied
-- them, but excludes finishing reagents. ResourcefulnessPredictionService
-- owns eligibility (Spark, Heraldry, lumber, etc.) - this only assembles the
-- candidate list, it does not filter it.
local function BuildResourcefulnessCandidates(observation)
    local rows = {}
    for _, row in ipairs(type(observation.customerProvidedReagents) == "table" and observation.customerProvidedReagents or {}) do
        rows[#rows + 1] = row
    end
    for _, row in ipairs(type(observation.crafterProvidedReagents) == "table" and observation.crafterProvidedReagents or {}) do
        rows[#rows + 1] = row
    end
    return rows
end

-- ResourcefulnessPredictionService's expectedReturnedReagents rows carry
-- only { configKey, expectedQuantity } - it is deliberately identity-free
-- (see its header comment: no valuation, no economics knowledge). Pricing a
-- return needs itemID too, so this maps configKey back to the itemID of the
-- candidate reagent that produced it - a Resourcefulness return is always
-- more of the same reagent that went in, so the mapping is exact, not
-- guessed. This is the only place OrderEconomicsService bridges the two
-- services' contracts.
local function BuildConfigKeyToCandidate(candidateRows)
    local map = {}
    for _, row in ipairs(candidateRows) do
        if row.configKey and not map[row.configKey] then
            map[row.configKey] = {
                itemID = row.itemID,
                suppliedBy = row.suppliedBy,
                classification = row.classification,
            }
        end
    end
    return map
end

-- Values the predicted Resourcefulness returns. Any return whose itemID
-- cannot be recovered or whose value cannot be resolved is appended to
-- diagnostics.unvaluedResourcefulnessInputs, shown as Unvalued, and excluded
-- from totals without aborting order economics.
local function ValueResourcefulnessReturns(valuationService, expectedReturnedReagents, configKeyToCandidate, diagnostics)
    local total = 0
    local rows = {}
    for _, returnRow in ipairs(type(expectedReturnedReagents) == "table" and expectedReturnedReagents or {}) do
        local expectedQuantity = NumberOrNil(returnRow.expectedQuantity) or 0
        if expectedQuantity > 0 then
            local candidate = returnRow.configKey and configKeyToCandidate[returnRow.configKey]
            local itemID = candidate and candidate.itemID
            if not returnRow.configKey or not itemID then
                local unvalued = {
                    configKey = returnRow.configKey,
                    quantity = expectedQuantity,
                    suppliedBy = candidate and candidate.suppliedBy,
                    classification = candidate and candidate.classification,
                    reason = "missingConfigKey",
                    unvalued = true,
                }
                rows[#rows + 1] = unvalued
                diagnostics.unvaluedResourcefulnessInputs[#diagnostics.unvaluedResourcefulnessInputs + 1] = unvalued
            else
                local priced = valuationService and SafeGetItemValue(valuationService, { itemID = itemID, configKey = returnRow.configKey }, diagnostics)
                if priced and not priced.unresolved and priced.valuePerUnit ~= nil then
                    local valuePerUnit = NumberOrNil(priced.valuePerUnit) or 0
                    local lineValue = valuePerUnit * expectedQuantity
                    total = total + lineValue
                    rows[#rows + 1] = {
                        configKey = returnRow.configKey,
                        itemID = itemID,
                        quantity = expectedQuantity,
                        suppliedBy = candidate and candidate.suppliedBy,
                        classification = candidate and candidate.classification,
                        valuePerUnit = valuePerUnit,
                        lineValue = lineValue,
                        unvalued = false,
                    }
                else
                    local unvalued = {
                        configKey = returnRow.configKey,
                        itemID = itemID,
                        quantity = expectedQuantity,
                        suppliedBy = candidate and candidate.suppliedBy,
                        classification = candidate and candidate.classification,
                        reason = "valuationUnavailable",
                        unvalued = true,
                    }
                    rows[#rows + 1] = unvalued
                    diagnostics.unvaluedResourcefulnessInputs[#diagnostics.unvaluedResourcefulnessInputs + 1] = unvalued
                end
            end
        end
    end
    return total, rows
end

--- Evaluates a captured, already-normalized order observation. Deterministic
-- for a given observation and the current valuation cache - never reads
-- Blizzard frames or UI state. Safe to call from diagnostics with a
-- hand-built observation table.
-- @param observation table - see OrderObservationBuilder:BuildCurrentOrderObservation
-- @return table - success shape { resolved = true, economics = {...}, diagnostics = {...} }
--                  or failure shape { resolved = false, unresolvedReason = string, diagnostics = {...} }
function OrderEconomicsService:EvaluateObservation(observation)
    local diagnostics = NewDiagnostics()

    if type(observation) ~= "table" then
        return Unresolved("invalidObservation", diagnostics)
    end

    local valuationService = GetValuationService()
    if valuationService and type(valuationService.GetItemValue) ~= "function" then
        valuationService = nil
    end

    local resourcefulnessService = GetResourcefulnessPredictionService()
    if resourcefulnessService and type(resourcefulnessService.PredictExpectedReturns) ~= "function" then
        resourcefulnessService = nil
    end

    local crafterMaterialCost, crafterMaterialRows = PriceCostRows(valuationService, observation.crafterProvidedReagents, diagnostics)
    local finishingReagentCost, finishingReagentRows = PriceCostRows(valuationService, observation.finishingReagents, diagnostics)

    local valuedItemRewardValue, itemRewardRows = ValueItemRewards(valuationService, observation.itemRewards, diagnostics)
    local valuedCurrencyRewardValue, currencyRewardRows = ValueCurrencyRewards(valuationService, observation.currencyRewards, diagnostics)
    local valuedRewardValue = valuedItemRewardValue + valuedCurrencyRewardValue

    local rewardRows = {}
    for _, reward in ipairs(itemRewardRows) do
        rewardRows[#rewardRows + 1] = reward
    end
    for _, reward in ipairs(currencyRewardRows) do
        rewardRows[#rewardRows + 1] = reward
    end

    local candidateRows = BuildResourcefulnessCandidates(observation)
    local predictionInput = {}
    for _, row in ipairs(candidateRows) do
        predictionInput[#predictionInput + 1] = {
            configKey = row.configKey,
            quantity = row.quantity,
            suppliedBy = row.suppliedBy,
        }
    end

    local prediction
    if resourcefulnessService then
        local okPrediction, predicted = pcall(function()
            return resourcefulnessService:PredictExpectedReturns({
                displayedResourcefulnessPct = observation.displayedResourcefulnessPct,
                reagents = predictionInput,
            })
        end)
        if okPrediction and type(predicted) == "table" then
            prediction = predicted
        end
    end

    if not prediction then
        diagnostics.unvaluedResourcefulnessInputs[#diagnostics.unvaluedResourcefulnessInputs + 1] = {
            reason = "predictionUnavailable",
        }
        prediction = { expectedReturnedReagents = {} }
    end

    local configKeyToCandidate = BuildConfigKeyToCandidate(candidateRows)
    local expectedResourcefulnessValue, resourcefulnessRows =
        ValueResourcefulnessReturns(valuationService, prediction.expectedReturnedReagents, configKeyToCandidate, diagnostics)

    local crafterPayout = NumberOrNil(observation.crafterPayout) or 0

    local estimatedNetValue = crafterPayout
        + valuedRewardValue
        + expectedResourcefulnessValue
        - crafterMaterialCost
        - finishingReagentCost

    return {
        resolved = true,
        economics = {
            estimatedNetValue = estimatedNetValue,

            crafterPayout = crafterPayout,
            crafterMaterialCost = crafterMaterialCost,
            finishingReagentCost = finishingReagentCost,
            valuedRewardValue = valuedRewardValue,
            expectedResourcefulnessValue = expectedResourcefulnessValue,

            commissionRows = {
                {
                    label = "Gold Payout",
                    quantity = 1,
                    lineValue = crafterPayout,
                    unvalued = false,
                },
            },
            rewardRows = rewardRows,
            resourcefulnessRows = resourcefulnessRows,
            crafterMaterialRows = crafterMaterialRows,
            finishingReagentRows = finishingReagentRows,

            -- Passthrough for the "check your mats" note - not used in any
            -- value above (see OrderObservationBuilder).
            usesHigherQualityMatsThanNeeded = observation.usesHigherQualityMatsThanNeeded == true,
        },
        diagnostics = diagnostics,
    }
end

--- Builds and evaluates the currently selected Blizzard crafting order.
-- Thin composition of OrderObservationBuilder + EvaluateObservation - all
-- frame reads happen inside OrderObservationBuilder.
-- @return table - same success/failure shape as EvaluateObservation.
function OrderEconomicsService:EvaluateCurrentOrder()
    local observationBuilder = GetObservationBuilder()
    if not observationBuilder or type(observationBuilder.BuildCurrentOrderObservation) ~= "function" then
        return Unresolved("observationBuilderUnavailable", NewDiagnostics())
    end

    local built = observationBuilder:BuildCurrentOrderObservation()
    if type(built) ~= "table" or built.resolved ~= true then
        return {
            resolved = false,
            unresolvedReason = (type(built) == "table" and built.unresolvedReason) or "observationUnresolved",
            diagnostics = (type(built) == "table" and built.diagnostics) or NewDiagnostics(),
        }
    end

    return self:EvaluateObservation(built.observation)
end

if PocketCFO_Orders then
    PocketCFO_Orders.OrderEconomicsService = OrderEconomicsService
end
