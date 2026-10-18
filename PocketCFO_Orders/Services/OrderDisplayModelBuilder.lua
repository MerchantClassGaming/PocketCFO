-- PocketCFO_Orders/Services/OrderDisplayModelBuilder.lua
-- Reshapes an OrderEconomicsService result into the player-facing
-- Order Analysis display model. Pure reshaping + row naming/icons - no
-- valuation, no economics math, no business decisions. The UI (Crafting's
-- companion window content) must not perform valuation/economics itself; this
-- is the only place that translates service output into what gets shown.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO_Orders = _G.PocketCFO_Orders

local OrderDisplayModelBuilder = PocketCFO_Orders:NewModule("OrderDisplayModelBuilder")

-- Reasons that mean "there is no order to evaluate yet" rather than "the
-- order exists but its economics could not be resolved." The UI shows a
-- different, non-alarming message for this class ("Select an order...").
local NO_ORDER_SELECTED_REASONS = {
    professionFrameUnavailable = true,
    ordersPageUnavailable = true,
    ordersPageNotShown = true,
    orderViewUnavailable = true,
    orderViewNotShown = true,
    selectedOrderUnavailable = true,
}

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

local function SafeGetItemInfo(itemID)
    if not itemID then
        return nil, nil
    end
    local ok, name, _, _, _, _, _, _, _, icon = pcall(GetItemInfo, itemID)
    if not ok then
        return nil, nil
    end
    return name, icon
end

local function SafeGetCurrencyInfo(currencyID)
    if not currencyID or not C_CurrencyInfo or type(C_CurrencyInfo.GetCurrencyInfo) ~= "function" then
        return nil, nil
    end
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    if not ok or type(info) ~= "table" then
        return nil, nil
    end
    return info.name, info.iconFileID
end

local function BuildItemRow(source, fallbackName)
    local row = {
        itemID = source.itemID,
        currencyID = source.currencyID,
        configKey = source.configKey,
        quantity = NumberOrNil(source.quantity) or 1,
        valuePerUnit = source.valuePerUnit,
        lineValue = source.lineValue,
        suppliedBy = source.suppliedBy,
        classification = source.classification,
        identityBasis = source.identityBasis,
        unvalued = source.unvalued == true,
        reason = source.reason,
    }

    if source.itemID then
        row.name, row.icon = SafeGetItemInfo(source.itemID)
        -- itemID/configKey/value already resolved (see AttachConfigKey/
        -- ItemIdentityService - configKey generation for a plain reagent
        -- does not require the item name, only itemID); a nil name here
        -- means only the display string is a client-side cache miss, not an
        -- unknown item. Flagged instead of silently falling back so the
        -- controller can retrigger a full render once the name loads
        -- (Item:ContinueOnItemLoad in OrdersCompanionController) rather than
        -- leaving a resolved, valued row permanently mislabeled "Unknown".
        row.namePending = row.name == nil
    elseif source.currencyID then
        row.name, row.icon = SafeGetCurrencyInfo(source.currencyID)
    elseif source.notChosen then
        -- A slot you fill with nothing picked yet (e.g. a spark the customer
        -- didn't provide) - see ReagentSlotService.MarkNotChosenRows.
        row.name = source.slotName and string.format("%s (not chosen)", source.slotName) or "Reagent not chosen"
    end

    row.name = row.name or fallbackName or "Unknown reagent"
    return row
end

local function BuildRewardRow(reward)
    local row = {
        rewardType = reward.rewardType,
        itemID = reward.itemID,
        currencyID = reward.currencyID,
        configKey = reward.configKey,
        quantity = NumberOrNil(reward.quantity) or 1,
        valuePerUnit = reward.valuePerUnit,
        lineValue = reward.lineValue,
        valuationBasis = reward.valuationBasis,
        unvalued = reward.unvalued == true,
        reason = reward.reason,
    }

    if reward.rewardType == "item" then
        row.name, row.icon = SafeGetItemInfo(reward.itemID)
        row.namePending = row.name == nil
    elseif reward.rewardType == "currency" then
        row.name, row.icon = SafeGetCurrencyInfo(reward.currencyID)
    end

    row.name = row.name or "Unknown Reward"
    return row
end

local function BuildNamedRows(sourceRows, fallbackName)
    local rows = {}
    for _, row in ipairs(type(sourceRows) == "table" and sourceRows or {}) do
        rows[#rows + 1] = BuildItemRow(row, fallbackName)
    end
    return rows
end

local function BuildRewardRows(sourceRows)
    local rows = {}
    for _, row in ipairs(type(sourceRows) == "table" and sourceRows or {}) do
        rows[#rows + 1] = BuildRewardRow(row)
    end
    return rows
end

local function RemoveCustomerProvidedRows(rows)
    local filtered = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if row.suppliedBy ~= "customer" then
            filtered[#filtered + 1] = row
        end
    end
    return filtered
end

-- Only crafterMaterialRows feeds this list. Rewards, Estimated
-- Resourcefulness, and Finishing Reagents are all still-visible sections that
-- already render their own unvalued rows in place (label + right-column
-- "Unvalued") - duplicating them here would show the same unresolved item
-- twice. Crafter Materials is the one section that is no longer rendered
-- (see OrderAnalysisContent), so an unvalued crafter-provided material has no
-- other visible home; it is economically relevant (the crafter's input cost
-- is unresolved) and belongs here. Customer-provided rows never reach
-- crafterMaterialRows in the first place (OrderObservationBuilder only feeds
-- crafterProvidedReagents/finishingReagents from crafter-attributed slots),
-- but RemoveCustomerProvidedRows is kept as a defensive filter.
local function BuildItemsNotValued(crafterMaterialRows)
    local rows = {}
    for _, row in ipairs(RemoveCustomerProvidedRows(crafterMaterialRows)) do
        if row.unvalued then
            rows[#rows + 1] = {
                itemID = row.itemID,
                currencyID = row.currencyID,
                configKey = row.configKey,
                quantity = row.quantity,
                name = row.name,
                icon = row.icon,
                reason = row.reason,
            }
        end
    end
    return rows
end

--- Builds the Order Analysis display model from an OrderEconomicsService-
-- shaped result (either EvaluateCurrentOrder()'s or EvaluateObservation()'s
-- return value - same envelope).
-- @return table {
--     state = "resolved" | "unavailable" | "noOrderSelected",
--     resolved = boolean,
--     estimatedNetValue = number|nil,
--     commission = number,
--     rewards = { { rewardType, itemID, currencyID, configKey, quantity, name, icon, lineValue|nil, valuationBasis|nil, unvalued }, ... },
--     expectedResourcefulness = { { itemID, configKey, quantity, name, lineValue|nil, unvalued }, ... },
--     crafterMaterials = { ... },
--     finishingReagents = { ... },
--     itemsNotValued = { ... },
--     matQualityNote = string|nil,
-- }
function OrderDisplayModelBuilder:Build(economicsResult)
    if type(economicsResult) ~= "table" then
        return { state = "unavailable", resolved = false }
    end

    if economicsResult.resolved ~= true then
        local reason = economicsResult.unresolvedReason
        if NO_ORDER_SELECTED_REASONS[reason] then
            return { state = "noOrderSelected", resolved = false, unresolvedReason = reason }
        end
        return { state = "unavailable", resolved = false, unresolvedReason = reason }
    end

    local economics = economicsResult.economics
    if type(economics) ~= "table" then
        return { state = "unavailable", resolved = false, unresolvedReason = "missingEconomics" }
    end

    -- Resourcefulness eligibility is provider-agnostic (see
    -- ResourcefulnessPredictionService's exclusion registry and
    -- OrderEconomicsService's BuildResourcefulnessCandidates, which both
    -- consider customer- and crafter-provided reagents alike). Material
    -- provider only gates *cost* ownership (crafterMaterialRows/
    -- finishingReagentRows below), never resourcefulness display - do not
    -- apply RemoveCustomerProvidedRows to resourcefulnessRows.
    local rewardRows = BuildRewardRows(economics.rewardRows)
    local resourcefulnessRows = BuildNamedRows(economics.resourcefulnessRows, "Unknown reagent")
    local crafterMaterialRows = RemoveCustomerProvidedRows(BuildNamedRows(economics.crafterMaterialRows, "Unknown reagent"))
    local finishingReagentRows = RemoveCustomerProvidedRows(BuildNamedRows(economics.finishingReagentRows, "Unknown reagent"))

    return {
        state = "resolved",
        resolved = true,
        estimatedNetValue = economics.estimatedNetValue,
        commission = economics.crafterPayout,
        rewards = rewardRows,
        expectedResourcefulness = resourcefulnessRows,
        crafterMaterials = crafterMaterialRows,
        finishingReagents = finishingReagentRows,
        itemsNotValued = BuildItemsNotValued(crafterMaterialRows),
        matQualityNote = economics.usesHigherQualityMatsThanNeeded
            and "You're using at least one higher quality mat than this order needs. Make sure that's what you want."
            or nil,
    }
end

if PocketCFO_Orders then
    PocketCFO_Orders.OrderDisplayModelBuilder = OrderDisplayModelBuilder
end
