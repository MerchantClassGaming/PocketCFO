-- PocketCFO_Crafting/Crafting/RecipeAnalysisDisplayModelBuilder.lua
-- Reshapes a RecipeEconomicsService result into the player-facing Recipe
-- Analysis display model. Pure reshaping + names/labels - no valuation and
-- no economics math. Recipes-tab sibling of PocketCFO_Orders'
-- OrderDisplayModelBuilder.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local RecipeAnalysisDisplayModelBuilder = PocketCFO_Crafting:NewModule("RecipeAnalysisDisplayModelBuilder")

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

local function SafeGetCurrencyName(currencyID)
    if not currencyID or not C_CurrencyInfo or type(C_CurrencyInfo.GetCurrencyInfo) ~= "function" then
        return nil
    end
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    return ok and type(info) == "table" and info.name or nil
end

local function FormatPercent(fraction)
    local value = (tonumber(fraction) or 0) * 100
    if math.abs(value - math.floor(value + 0.5)) < 0.05 then
        return string.format("%d%%", math.floor(value + 0.5))
    end
    return string.format("%.1f%%", value)
end

local function FormatAmount(value)
    value = tonumber(value) or 0
    if math.abs(value - math.floor(value + 0.000001)) < 0.000001 then
        return tostring(math.floor(value + 0.000001))
    end
    return string.format("%.1f", value)
end

-- Rows whose name is a client-side cache miss get namePending so the
-- controller can schedule Item:ContinueOnItemLoad and re-render.
local function BuildItemRow(source, fallbackName)
    local row = {
        itemID = source.itemID,
        currencyID = source.currencyID,
        configKey = source.configKey,
        quantity = NumberOrNil(source.quantity) or 1,
        lineValue = source.lineValue,
        unvalued = source.unvalued == true,
        reason = source.reason,
    }
    if source.notChosen then
        row.name = source.slotName and string.format("%s (not chosen)", source.slotName) or "Reagent not chosen"
        row.valueText = "Not chosen"
        return row
    end
    if source.itemID then
        row.name = SafeGetItemInfo(source.itemID)
        row.namePending = row.name == nil
    elseif source.currencyID then
        row.name = SafeGetCurrencyName(source.currencyID)
    end
    row.name = row.name or fallbackName or "Unknown reagent"
    return row
end

local function BuildItemRows(sourceRows, fallbackName)
    local rows = {}
    for _, row in ipairs(type(sourceRows) == "table" and sourceRows or {}) do
        rows[#rows + 1] = BuildItemRow(row, fallbackName)
    end
    return rows
end

local function BuildMulticraftTooltip(economics)
    local chanceText = FormatPercent(economics.multicraftChance)
    if economics.multicraftBonusSource == "history" then
        return string.format(
            "%s chance to make extra items. From your own crafts of this recipe, a Multicraft makes about %s extra (seen %d %s).",
            chanceText, FormatAmount(economics.multicraftBonus),
            economics.multicraftProcsObserved or 0,
            (economics.multicraftProcsObserved == 1) and "time" or "times")
    end
    return string.format(
        "%s chance to make extra items. The game doesn't say how many extra a Multicraft makes, so this uses +1 until you've crafted this recipe and seen a Multicraft.",
        chanceText)
end

local function FormatPoints(points)
    points = tonumber(points) or 0
    return tostring(math.floor(points + 0.5))
end

--- @return table {
--     state = "resolved" | "unavailable",
--     headline = { label, value, style = "profit" | "neutral" },
--     summaryRows = { { name, lineValue }, ... },      -- facts, shown neutral (no +/-, no color)
--     outputRows = { ... } | nil, outputSectionTitle,  -- only when the item has an AH price
--     noPriceNote = string | nil,
--     concentrationRow = { name, lineValue|nil, infoTitle, infoTooltip } | nil,
--     expectedResourcefulness = { ... },
--     costs = { ... },
-- }
-- Cost to Make is a fact, never judged good/bad (Brian): it is always shown,
-- uncolored and unsigned. Only Profit per Craft (needs an AH price for the
-- item) is green/red.
function RecipeAnalysisDisplayModelBuilder:Build(economicsResult)
    if type(economicsResult) ~= "table" or economicsResult.resolved ~= true or type(economicsResult.economics) ~= "table" then
        return {
            state = "unavailable",
            resolved = false,
            unresolvedReason = type(economicsResult) == "table" and economicsResult.unresolvedReason or nil,
        }
    end

    local economics = economicsResult.economics
    local priced = economics.outputValued == true and economics.profitPerCraft ~= nil

    local model = {
        state = "resolved",
        resolved = true,
        expectedResourcefulness = BuildItemRows(economics.resourcefulnessRows, "Unknown reagent"),
    }

    -- Summary facts
    local summaryRows = {}
    if priced then
        model.headline = { label = "Profit per Craft", value = economics.profitPerCraft, style = "profit" }
        summaryRows[#summaryRows + 1] = { name = "Cost to Make", lineValue = economics.costToMake }
    else
        model.headline = { label = "Cost to Make", value = economics.costToMake, style = "neutral" }
    end
    local itemsPerCraft = tonumber(economics.expectedItemsPerCraft) or 1
    if economics.costPerItem ~= nil and math.abs(itemsPerCraft - 1) > 0.000001 then
        summaryRows[#summaryRows + 1] = {
            name = "Cost per Item",
            lineValue = economics.costPerItem,
            infoTitle = "Cost per Item",
            infoTooltip = string.format(
                "Cost to Make divided by the %s items you can expect per craft%s.",
                FormatAmount(itemsPerCraft),
                economics.multicraftChance and ", including Multicraft" or ""),
        }
    end
    model.summaryRows = summaryRows

    -- Bound mats (can't be bought) and other unpriced mats
    local boundMats = type(economics.boundMats) == "table" and economics.boundMats or {}
    if #boundMats == 1 and economics.boundMatValuePerUnit ~= nil then
        local mat = boundMats[1]
        local boundName = SafeGetItemInfo(mat.itemID)
        local displayName = boundName or "bound mat"
        model.boundMatRow = {
            itemID = mat.itemID,
            namePending = boundName == nil,
            name = string.format("Value per %s (%s used)", displayName, FormatAmount(mat.quantity)),
            lineValue = economics.boundMatValuePerUnit,
            infoTitle = displayName,
            infoTooltip = string.format(
                "%s can't be bought, so it has no price and isn't in Cost to Make. This is your profit per craft divided by the %s used: what each one earns you when crafted into this item.",
                displayName, FormatAmount(mat.quantity)),
        }
    elseif #boundMats > 0 then
        local names = {}
        for _, mat in ipairs(boundMats) do
            local matName = SafeGetItemInfo(mat.itemID)
            names[#names + 1] = string.format("%s (%s)", matName or "bound mat", FormatAmount(mat.quantity))
        end
        local list = table.concat(names, ", ")
        if priced then
            model.boundMatsNote = string.format("Profit treats %s as free, since they can't be bought.", list)
        else
            model.boundMatsNote = string.format("Cost to Make doesn't include %s, since they can't be bought.", list)
        end
        model.boundMatsNoteItemIDs = {}
        for _, mat in ipairs(boundMats) do
            if SafeGetItemInfo(mat.itemID) == nil then
                model.boundMatsNoteItemIDs[#model.boundMatsNoteItemIDs + 1] = mat.itemID
            end
        end
    end
    if economics.hasUnchosenSlots then
        model.unchosenNote = "Choose a reagent for every slot to see the full cost."
    end
    if economics.hasOtherUnpricedMats then
        model.unpricedWarning = priced
            and "Some mats have no price, so real profit is lower."
            or "Some mats have no price, so real cost is higher."
    end

    -- What it sells for (only with an AH price). Item and Multicraft rows
    -- show the full AH price, then the AH cut, then what you keep (Brian:
    -- spell the cut out instead of folding it into the prices).
    if priced then
        local fullPerUnit = tonumber(economics.outputValuePerUnit) or 0
        local baseQuantity = tonumber(economics.baseQuantity) or 1
        local outputName = SafeGetItemInfo(economics.outputItemID)
        local grossValue = fullPerUnit * baseQuantity
        local outputRows = {
            {
                itemID = economics.outputItemID,
                name = outputName or "Crafted item",
                namePending = economics.outputItemID ~= nil and outputName == nil,
                quantity = baseQuantity,
                lineValue = grossValue,
            },
        }
        local variantCount = tonumber(economics.outputStatVariantCount)
        if variantCount then
            -- Shows "(Estimated)" (RecipeAnalysisContent) plus a hover note.
            outputRows[1].valuationBasis = "modeled"
            outputRows[1].infoTitle = "Estimated price"
            outputRows[1].infoTooltip = string.format(
                "No price yet for this exact version. This is the average of the %d stat %s with an auction price. Pick its stats with optional reagents to see the exact price.",
                variantCount, variantCount == 1 and "version" or "versions")
        end
        if economics.multicraftChance then
            local extraQuantity = tonumber(economics.expectedExtraQuantity) or 0
            grossValue = grossValue + fullPerUnit * extraQuantity
            outputRows[#outputRows + 1] = {
                name = "Multicraft bonus",
                quantity = extraQuantity,
                lineValue = fullPerUnit * extraQuantity,
                infoTitle = "Multicraft",
                infoTooltip = BuildMulticraftTooltip(economics),
            }
        end
        local keepValue = tonumber(economics.outputValue) or 0
        outputRows[#outputRows + 1] = {
            name = string.format("AH Cut (%d%%)", math.floor((economics.auctionHouseCut or 0) * 100 + 0.5)),
            lineValue = grossValue - keepValue,
            valueSign = "negative",
        }
        outputRows[#outputRows + 1] = {
            name = "You Keep",
            lineValue = keepValue,
        }
        model.outputRows = outputRows
        model.outputSectionTitle = "Sells For"
    else
        model.noPriceNote = "No auction price for this item."
    end

    -- Concentration (only while Concentrate is on)
    if economics.concentrating then
        local pointsText = economics.concentrationPoints and FormatPoints(economics.concentrationPoints) or "?"
        if economics.concentrationValuePerPoint ~= nil then
            model.concentrationRow = {
                name = string.format("Per Concentration point (%s used)", pointsText),
                lineValue = economics.concentrationValuePerPoint,
                infoTitle = "Concentration",
                infoTooltip = string.format(
                    "Using %s Concentration adds %s to what this craft sells for, compared with crafting it without Concentration.",
                    pointsText, (economics.concentrationGain and string.format("%.2fg", economics.concentrationGain / 10000)) or "?"),
            }
        else
            model.concentrationRow = {
                name = string.format("Concentration (%s used)", pointsText),
                infoTitle = "Concentration",
                infoTooltip = priced
                    and "Turn Concentrate off and back on to see what each point is worth for this craft."
                    or "Value per point needs an auction price for this item.",
            }
        end
    end

    local costs = BuildItemRows(economics.materialRows, "Unknown reagent")
    for _, row in ipairs(BuildItemRows(economics.finishingReagentRows, "Unknown reagent")) do
        costs[#costs + 1] = row
    end
    model.costs = costs

    return model
end

--- Deduped itemIDs whose names haven't loaded yet.
function RecipeAnalysisDisplayModelBuilder:CollectPendingItemIDs(displayModel)
    local itemIDs, seen = {}, {}
    if type(displayModel) ~= "table" then
        return itemIDs
    end
    for _, rows in ipairs({ displayModel.outputRows, displayModel.expectedResourcefulness, displayModel.costs, { displayModel.boundMatRow } }) do
        for _, row in ipairs(type(rows) == "table" and rows or {}) do
            if row.namePending and row.itemID and not seen[row.itemID] then
                seen[row.itemID] = true
                itemIDs[#itemIDs + 1] = row.itemID
            end
        end
    end
    for _, itemID in ipairs(displayModel.boundMatsNoteItemIDs or {}) do
        if not seen[itemID] then
            seen[itemID] = true
            itemIDs[#itemIDs + 1] = itemID
        end
    end
    return itemIDs
end

if PocketCFO_Crafting then
    PocketCFO_Crafting.RecipeAnalysisDisplayModelBuilder = RecipeAnalysisDisplayModelBuilder
end
