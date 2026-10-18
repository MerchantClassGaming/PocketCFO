-- PocketCFO_Crafting/Crafting/LureAnalysisDisplayModelBuilder.lua
-- Reshapes a LureAnalysisService result into a RecipeAnalysisContent display
-- model. Pure reshaping + player-facing labels - no valuation or math.
-- The lure's own reagent Costs and Resourcefulness rows come from the normal
-- Recipe Analysis display model for the same recipe, so they match exactly.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local LureAnalysisDisplayModelBuilder = PocketCFO_Crafting:NewModule("LureAnalysisDisplayModelBuilder")

-- Under this many skins the average is labeled "still settling".
local SETTLED_SKINS = 20

local ALL_LURES_TOOLTIP =
    "Average profit for each lure from your skins of its beast, minus what the lure costs to make today. A lure shows \"Open its recipe\" until you've selected it here once."
local AVERAGE_RETURN_TOOLTIP =
    "What one skin of this beast gives on average (kill loot and skin), at today's prices. Recent skins count a little more, so it keeps up as your skinning improves."

local function ItemName(itemID)
    if not itemID then
        return nil
    end
    local ok, name = pcall(GetItemInfo, itemID)
    return ok and name or nil
end

--- @param lure table LureAnalysisService:Evaluate result
--- @param recipeModel table RecipeAnalysisDisplayModelBuilder:Build result for the same recipe
--- @return table displayModel, table pendingItemIDs
function LureAnalysisDisplayModelBuilder:Build(lure, recipeModel)
    recipeModel = type(recipeModel) == "table" and recipeModel or {}
    local pending, seen = {}, {}
    local function MarkPending(itemID)
        if itemID and not seen[itemID] then
            seen[itemID] = true
            pending[#pending + 1] = itemID
        end
    end

    local beastName = lure.beastName or "this beast"
    local model = {
        state = "resolved",
        resolved = true,
        summaryRows = {},
        noteRows = {},
        sections = {},
        -- Same rows the normal Recipe Analysis shows for this recipe.
        expectedResourcefulness = recipeModel.expectedResourcefulness,
        costs = recipeModel.costs,
        unchosenNote = recipeModel.unchosenNote,
        unpricedWarning = recipeModel.unpricedWarning,
        boundMatsNote = recipeModel.boundMatsNote,
    }

    local averageReturn = lure.averageReturn or { skins = 0, rows = {}, total = 0 }

    if lure.state == "ok" then
        model.headline = { label = "Average Profit per Lure", value = lure.profit, style = "profit" }
        model.summaryRows[#model.summaryRows + 1] = { name = "Lure Cost", lineValue = lure.cost }
        model.summaryRows[#model.summaryRows + 1] = { name = "Average Return", lineValue = averageReturn.total }
        local skins = averageReturn.skins
        model.noteRows[#model.noteRows + 1] = string.format("Based on %d %s of %s%s.",
            skins, skins == 1 and "skin" or "skins", beastName,
            skins < SETTLED_SKINS and " (still settling)" or "")
    else
        model.headline = { label = "Lure Cost", value = lure.cost or 0, style = "neutral" }
        model.noteRows[#model.noteRows + 1] = string.format(
            "No skins of %s yet. Use this lure and skin the beast to see what it returns.", beastName)
    end
    if averageReturn.hasUnpriced then
        model.noteRows[#model.noteRows + 1] = "Some items have no price, so the real return is higher."
    end

    -- Average return per skin, item by item.
    if averageReturn.skins > 0 then
        local rows = {}
        for _, source in ipairs(averageReturn.rows) do
            local name = ItemName(source.itemID)
            if not name then
                MarkPending(source.itemID)
            end
            rows[#rows + 1] = {
                itemID = source.itemID,
                name = name or "Loading...",
                namePending = name == nil,
                quantity = source.quantity,
                lineValue = source.lineValue,
                unvalued = source.unvalued == true,
            }
        end
        model.sections[#model.sections + 1] = {
            title = "Average Return per Skin",
            rows = rows,
            valueSign = "positive",
            infoTooltip = AVERAGE_RETURN_TOOLTIP,
        }
    end

    -- All five lures, best first.
    local lureRows = {}
    for _, entry in ipairs(lure.allLures or {}) do
        local name = ItemName(entry.lureItemID)
        if not name then
            MarkPending(entry.lureItemID)
        end
        local row = {
            itemID = entry.lureItemID,
            name = (name or "Loading...") .. (entry.isSelected and " (this one)" or ""),
            namePending = name == nil,
            quantity = 1,
        }
        if entry.state == "ok" then
            row.lineValue = entry.profit
            row.valueSign = (entry.profit or 0) < 0 and "negative" or "positive"
        elseif entry.state == "noCost" then
            row.valueText = "Open its recipe"
            row.unvalued = true
        else
            row.valueText = "No skins yet"
            row.unvalued = true
        end
        lureRows[#lureRows + 1] = row
    end
    if #lureRows > 0 then
        model.sections[#model.sections + 1] = {
            title = "All Lures",
            rows = lureRows,
            infoTooltip = ALL_LURES_TOOLTIP,
        }
    end

    -- Item names from the recipe part of the model.
    local recipeBuilder = PocketCFO_Crafting:GetModule("RecipeAnalysisDisplayModelBuilder", true)
    if recipeBuilder and recipeBuilder.CollectPendingItemIDs then
        for _, itemID in ipairs(recipeBuilder:CollectPendingItemIDs(recipeModel)) do
            MarkPending(itemID)
        end
    end

    return model, pending
end

if PocketCFO_Crafting then
    PocketCFO_Crafting.LureAnalysisDisplayModelBuilder = LureAnalysisDisplayModelBuilder
end
