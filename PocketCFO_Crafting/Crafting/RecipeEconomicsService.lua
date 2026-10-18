-- PocketCFO_Crafting/Crafting/RecipeEconomicsService.lua
-- Answers one question: "What do I make (or lose) per craft of this recipe,
-- right now, with what is loaded in the crafting form?"
--
--   RecipeObservationBuilder   read-only snapshot of the crafting form
--           |
--   RecipeEconomicsService     prices mats, output, Resourcefulness, Multicraft
--           |
--   profit per craft (plus row-level unvalued diagnostics)
--
-- Recipes-tab sibling of PocketCFO_Orders' OrderEconomicsService. Differences
-- from an order (per Brian):
--   - No gold payout and no reward items/currencies - the only thing a
--     craft produces is the item itself.
--   - Multicraft counts. On an order the extra items are lost; on a normal
--     craft they are yours, so expected output = base + chance x bonus.
--
-- Multicraft bonus size: the game does not expose how many extra items a
-- proc gives. Uses this recipe's own observed average from craft history
-- (OperationOutcomeService row-level multicraftExtraTotal / procCount) when
-- at least one proc has been seen, otherwise +1 (Brian's chosen default).
--
-- Output value is the sale value after the 5% auction house cut.
--
-- Composes existing services and adds no valuation math of its own:
--   ValuationService (PocketCFO_Valuation)  - item values
--   ResourcefulnessPredictionService (Core) - expected returned reagents
--   OperationOutcomeService (Core)          - observed multicraft average
-- Read-only, stateless, non-persistent.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local RecipeEconomicsService = PocketCFO_Crafting:NewModule("RecipeEconomicsService")

RecipeEconomicsService.AUCTION_HOUSE_CUT = 0.05
RecipeEconomicsService.DEFAULT_MULTICRAFT_BONUS = 1

local function GetObservationBuilder()
    return PocketCFO_Crafting:GetModule("RecipeObservationBuilder", true)
end

local function GetResourcefulnessPredictionService()
    return (PocketCFO and PocketCFO.ResourcefulnessPredictionService) or _G.PocketCFO_ResourcefulnessPredictionService
end

local function GetProfileKeyService()
    return PocketCFO and PocketCFO.OperationProfileKeyService or _G.PocketCFO_OperationProfileKeyService
end

local function GetOutcomeService()
    return PocketCFO and PocketCFO.OperationOutcomeService or _G.PocketCFO_OperationOutcomeService
end

-- Never force-loads PocketCFO_Valuation as a side effect of an economics
-- query - same pattern as OrderEconomicsService/OperationHistoricalValuationEnricher.
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

local function SafeGetItemValue(valuationService, itemRef, diagnostics)
    if not valuationService then
        return nil
    end
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

-- Value per unit, or nil when the item cannot be priced. itemLink (optional)
-- lets PricingIdentity build the same market key the AH scan and tooltip
-- use for gear (real item level / quality from the link, not the base ilvl).
local function PriceUnit(valuationService, itemID, configKey, diagnostics, itemLink)
    if not itemID then
        return nil
    end
    local priced = SafeGetItemValue(valuationService, { itemID = itemID, configKey = configKey, itemLink = itemLink }, diagnostics)
    if not priced or priced.unresolved or priced.valuePerUnit == nil then
        return nil
    end
    -- Second return: the full valuation result (e.g. statVariantCount when
    -- the price is an average of stat versions). Existing callers ignore it.
    return NumberOrNil(priced.valuePerUnit), priced
end

-- Bound ("gather it yourself") detection: GetItemInfo's 14th return, bindType.
-- Confirmed in-game: Thalassian Lumber (256963) returns 1 (binds when picked
-- up), even though the item is warband-bound. Counted as bound: 1 (on
-- acquire), 4 (quest), 7/8/9 (account/warband). Bind-on-equip (2) and
-- bind-on-use (3) stay tradeable. nil (item data not cached yet) = unknown,
-- treated as not bound so it never produces a wrong value line.
local BOUND_BIND_TYPES = { [1] = true, [4] = true, [7] = true, [8] = true, [9] = true }

local function IsBoundItem(itemID)
    if not itemID or not GetItemInfo then
        return false
    end
    local ok, bindType = pcall(function()
        return select(14, GetItemInfo(itemID))
    end)
    return ok and BOUND_BIND_TYPES[tonumber(bindType)] == true
end

local function PriceCostRows(valuationService, rows, diagnostics)
    local total = 0
    local pricedRows = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        local quantity = NumberOrNil(row.quantity) or 0
        local valuePerUnit = quantity > 0 and PriceUnit(valuationService, row.itemID, row.configKey, diagnostics) or nil
        local priced = {
            itemID = row.itemID,
            currencyID = row.currencyID,
            configKey = row.configKey,
            quantity = quantity,
            classification = row.classification,
            identityBasis = row.identityBasis,
            notChosen = row.notChosen == true,
            slotName = row.slotName,
        }
        if valuePerUnit then
            priced.valuePerUnit = valuePerUnit
            priced.lineValue = valuePerUnit * quantity
            priced.unvalued = false
            total = total + priced.lineValue
        else
            priced.unvalued = true
            priced.reason = (not row.itemID) and "missingConfigKey" or "valuationUnavailable"
            priced.bound = IsBoundItem(row.itemID)
            diagnostics.unvaluedCostInputs[#diagnostics.unvaluedCostInputs + 1] = priced
        end
        pricedRows[#pricedRows + 1] = priced
    end
    return total, pricedRows
end

-- Same contract bridge as OrderEconomicsService: prediction rows carry only
-- configKey, so map back to the reagent row that produced them for itemID.
local function ValueResourcefulness(valuationService, observation, diagnostics)
    local service = GetResourcefulnessPredictionService()
    if not service or type(service.PredictExpectedReturns) ~= "function" then
        diagnostics.unvaluedResourcefulnessInputs[#diagnostics.unvaluedResourcefulnessInputs + 1] = {
            reason = "predictionUnavailable",
        }
        return 0, {}
    end

    local input = {}
    local byConfigKey = {}
    for _, row in ipairs(type(observation.reagents) == "table" and observation.reagents or {}) do
        -- A slot we can't identify (e.g. a heraldry/spark slot with nothing
        -- chosen yet) is left out of Resourcefulness entirely rather than
        -- shown as an "Unknown reagent" return (Brian).
        if row.configKey and row.itemID then
            input[#input + 1] = { configKey = row.configKey, quantity = row.quantity }
            if not byConfigKey[row.configKey] then
                byConfigKey[row.configKey] = row
            end
        end
    end

    local ok, prediction = pcall(function()
        return service:PredictExpectedReturns({
            displayedResourcefulnessPct = observation.displayedResourcefulnessPct,
            reagents = input,
        })
    end)
    if not ok or type(prediction) ~= "table" then
        diagnostics.unvaluedResourcefulnessInputs[#diagnostics.unvaluedResourcefulnessInputs + 1] = {
            reason = "predictionUnavailable",
        }
        return 0, {}
    end

    local total = 0
    local rows = {}
    for _, returnRow in ipairs(type(prediction.expectedReturnedReagents) == "table" and prediction.expectedReturnedReagents or {}) do
        local quantity = NumberOrNil(returnRow.expectedQuantity) or 0
        if quantity > 0 then
            local source = returnRow.configKey and byConfigKey[returnRow.configKey]
            local itemID = source and source.itemID
            if not itemID then
                quantity = 0
            end
        end
        if quantity > 0 then
            local source = byConfigKey[returnRow.configKey]
            local itemID = source.itemID
            local valuePerUnit = PriceUnit(valuationService, itemID, returnRow.configKey, diagnostics)
            local row = {
                itemID = itemID,
                configKey = returnRow.configKey,
                quantity = quantity,
            }
            if valuePerUnit then
                row.valuePerUnit = valuePerUnit
                row.lineValue = valuePerUnit * quantity
                row.unvalued = false
                total = total + row.lineValue
            else
                row.unvalued = true
                row.reason = itemID and "valuationUnavailable" or "missingConfigKey"
                diagnostics.unvaluedResourcefulnessInputs[#diagnostics.unvaluedResourcefulnessInputs + 1] = row
            end
            rows[#rows + 1] = row
        end
    end
    return total, rows
end

-- This recipe's observed average extra items per Multicraft proc, from the
-- row-level totals OperationOutcomeService already keeps for every recipe
-- crafted (OperationObservationBuilder records multicraft evidence for all
-- ordinary crafts). nil when no proc has been observed yet.
local function GetObservedMulticraftBonus(recipeID)
    local profileKeyService = GetProfileKeyService()
    local outcomeService = GetOutcomeService()
    if not profileKeyService or not outcomeService or not outcomeService.GetAggregate then
        return nil, 0
    end
    local okKey, keyResult = pcall(function() return profileKeyService:BuildKey(recipeID) end)
    if not okKey or type(keyResult) ~= "table" or keyResult.unresolved or not keyResult.profileKey then
        return nil, 0
    end
    local okAgg, aggregate = pcall(function() return outcomeService:GetAggregate(keyResult.profileKey) end)
    local multicraft = okAgg and type(aggregate) == "table" and aggregate.multicraft or nil
    local procCount = NumberOrNil(multicraft and multicraft.procCount) or 0
    local extraTotal = NumberOrNil(multicraft and multicraft.extraTotal) or 0
    if procCount <= 0 or extraTotal <= 0 then
        return nil, procCount
    end
    return extraTotal / procCount, procCount
end

--- Evaluates an already-normalized recipe observation. Never reads frames.
-- @return { resolved = true, economics = {...}, diagnostics = {...} }
--      or { resolved = false, unresolvedReason = string, diagnostics = {...} }
function RecipeEconomicsService:EvaluateObservation(observation)
    local diagnostics = NewDiagnostics()
    if type(observation) ~= "table" then
        return Unresolved("invalidObservation", diagnostics)
    end

    local valuationService = GetValuationService()
    if valuationService and type(valuationService.GetItemValue) ~= "function" then
        valuationService = nil
    end

    local materialCost, materialRows = PriceCostRows(valuationService, observation.reagents, diagnostics)
    local finishingCost, finishingRows = PriceCostRows(valuationService, observation.finishingReagents, diagnostics)
    local totalCost = materialCost + finishingCost

    local resourcefulnessValue, resourcefulnessRows = ValueResourcefulness(valuationService, observation, diagnostics)

    -- Output
    local baseQuantity = NumberOrNil(observation.baseOutputQuantity) or 1
    local multicraftChance = nil
    local multicraftBonus = nil
    local multicraftBonusSource = nil
    local multicraftProcsObserved = 0
    local multicraftPct = NumberOrNil(observation.displayedMulticraftPct)
    if multicraftPct and multicraftPct > 0 then
        multicraftChance = multicraftPct / 100
        local observedBonus
        observedBonus, multicraftProcsObserved = GetObservedMulticraftBonus(observation.recipeID)
        if observedBonus then
            multicraftBonus = observedBonus
            multicraftBonusSource = "history"
        else
            multicraftBonus = self.DEFAULT_MULTICRAFT_BONUS
            multicraftBonusSource = "default"
        end
    end
    local expectedExtraQuantity = (multicraftChance and multicraftBonus) and (multicraftChance * multicraftBonus) or 0

    local outputValuePerUnit, outputPriced = PriceUnit(valuationService, observation.outputItemID, observation.outputConfigKey,
        diagnostics, observation.outputItemLink)
    local outputNetPerUnit = outputValuePerUnit and (outputValuePerUnit * (1 - self.AUCTION_HOUSE_CUT)) or nil

    local baseOutputValue = outputNetPerUnit and (outputNetPerUnit * baseQuantity) or nil
    local multicraftValue = (outputNetPerUnit and expectedExtraQuantity > 0) and (outputNetPerUnit * expectedExtraQuantity) or nil
    local outputValue = baseOutputValue and (baseOutputValue + (multicraftValue or 0)) or nil

    local profitPerCraft = outputValue and (outputValue + resourcefulnessValue - totalCost) or nil

    -- Unpriced mats are left out of cost, so profit is really "profit if the
    -- unpriced mats were free". Two kinds:
    --   bound mats (can't be bought, e.g. housing decor lumber) - expected,
    --     named in a note; with exactly one bound type and nothing else
    --     unpriced, profit / its quantity is the exact value per unit.
    --   other unpriced mats (price data missing) - flagged as a warning.
    -- Two or more bound types get no per-unit number: there is no honest way
    -- to split profit between them (Brian).
    local boundMats = {}
    local boundByItemID = {}
    local hasOtherUnpricedMats = false
    local hasUnchosenSlots = false
    for _, list in ipairs({ materialRows, finishingRows }) do
        local isFinishing = (list == finishingRows)
        for _, row in ipairs(list) do
            if row.unvalued then
                if row.notChosen then
                    -- Nothing picked yet - not missing price data (Brian).
                    hasUnchosenSlots = true
                elseif row.bound and row.itemID then
                    local entry = boundByItemID[row.itemID]
                    if not entry then
                        entry = { itemID = row.itemID, configKey = row.configKey, quantity = 0 }
                        boundByItemID[row.itemID] = entry
                        boundMats[#boundMats + 1] = entry
                    end
                    entry.quantity = entry.quantity + (NumberOrNil(row.quantity) or 0)
                    if isFinishing then
                        entry.fromFinishing = true
                    end
                else
                    hasOtherUnpricedMats = true
                end
            end
        end
    end
    -- Per-unit value only for a bound REQUIRED material (e.g. housing
    -- lumber). A bound finishing reagent (e.g. Multicraft Manifold) only adds
    -- a stat boost, so profit / its quantity would wrongly credit it with the
    -- whole craft's profit - it just gets the "treated as free" note
    -- (Brian, 2026-10-13).
    local boundMatValuePerUnit = nil
    if #boundMats == 1 and not boundMats[1].fromFinishing
        and not hasOtherUnpricedMats and not hasUnchosenSlots
        and profitPerCraft ~= nil and boundMats[1].quantity > 0 then
        boundMatValuePerUnit = profitPerCraft / boundMats[1].quantity
    end

    local costToMake = totalCost - resourcefulnessValue
    local expectedItemsPerCraft = baseQuantity + expectedExtraQuantity
    local costPerItem = expectedItemsPerCraft > 0 and (costToMake / expectedItemsPerCraft) or nil

    return {
        resolved = true,
        economics = {
            profitPerCraft = profitPerCraft,
            costToMake = costToMake,
            boundMats = boundMats,
            boundMatValuePerUnit = boundMatValuePerUnit,
            hasOtherUnpricedMats = hasOtherUnpricedMats,
            hasUnchosenSlots = hasUnchosenSlots,
            expectedItemsPerCraft = expectedItemsPerCraft,
            costPerItem = costPerItem,
            concentrating = observation.concentrating == true,
            concentrationCost = NumberOrNil(observation.concentrationCost),
            totalCost = totalCost,

            outputItemID = observation.outputItemID,
            outputConfigKey = observation.outputConfigKey,
            outputValued = outputValuePerUnit ~= nil,
            outputValuePerUnit = outputValuePerUnit,
            -- Set when the price is the average of the item's stat versions
            -- (no stats picked yet - see ValuationService ResolveStatVariantAverage).
            outputStatVariantCount = outputPriced and tonumber(outputPriced.statVariantCount) or nil,
            outputNetPerUnit = outputNetPerUnit,
            auctionHouseCut = self.AUCTION_HOUSE_CUT,
            baseQuantity = baseQuantity,
            baseOutputValue = baseOutputValue,

            multicraftChance = multicraftChance,
            multicraftBonus = multicraftBonus,
            multicraftBonusSource = multicraftBonusSource,
            multicraftProcsObserved = multicraftProcsObserved,
            expectedExtraQuantity = expectedExtraQuantity,
            multicraftValue = multicraftValue,
            outputValue = outputValue,

            expectedResourcefulnessValue = resourcefulnessValue,
            resourcefulnessRows = resourcefulnessRows,
            materialRows = materialRows,
            finishingReagentRows = finishingRows,
        },
        diagnostics = diagnostics,
    }
end

--- Builds and evaluates the recipe loaded in the Recipes-tab crafting form.
function RecipeEconomicsService:EvaluateCurrentRecipe(recipeID)
    local builder = GetObservationBuilder()
    if not builder or type(builder.BuildCurrentRecipeObservation) ~= "function" then
        return Unresolved("observationBuilderUnavailable", NewDiagnostics())
    end
    local built = builder:BuildCurrentRecipeObservation(recipeID)
    if type(built) ~= "table" or built.resolved ~= true then
        return {
            resolved = false,
            unresolvedReason = (type(built) == "table" and built.unresolvedReason) or "observationUnresolved",
            diagnostics = (type(built) == "table" and built.diagnostics) or NewDiagnostics(),
        }
    end
    local result = self:EvaluateObservation(built.observation)
    result.observation = built.observation
    result.observationDiagnostics = built.diagnostics
    return result
end

if PocketCFO_Crafting then
    PocketCFO_Crafting.RecipeEconomicsService = RecipeEconomicsService
end
