-- PocketCFO_Crafting/UI/InventoryManager/CraftTooltipBuilder.lua
-- Tooltip content builder for Inventory Manager rows.
-- Consumes pre-calculated target/availability data from InventoryTargetEvaluator.
-- Does not directly aggregate inventory.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local CraftTooltipBuilder = PocketCFO_Crafting:NewModule("CraftTooltipBuilder")

local COLOR_GREEN = { r = 0.0, g = 0.8, b = 0.2 }
local COLOR_RED   = { r = 0.9, g = 0.2, b = 0.1 }

local function GetItemIcon(itemID)
    if not itemID then return nil end
    local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemID)
    return icon
end

local function IconString(icon, size)
    if not icon then return "" end
    size = size or 14
    return string.format("|T%s:%d:%d:0:0|t", tostring(icon), size, size)
end

-- Adds reagent mat lines to GameTooltip for the given result/config.
-- Slot display rules:
--   Single-tier slot:   [icon] totalNeeded         in green
--                    or [icon] totalNeeded (haveQty) in red if short
--   Two-tier slot:      [icon1] n1 (have1)  [icon2] n2 (have2) on one line
--   Optional/finishing: same quantity display plus item name for identification
local function AddMatLinesToTooltip(result, itemIDLookup)
    local config     = result.config
    local deficit    = result.deficit
    local multiplier = (deficit > 0) and deficit or 1

    if config.matSlots then
        local slotIndices = {}
        for slotIndex in pairs(config.matSlots) do
            table.insert(slotIndices, slotIndex)
        end
        table.sort(slotIndices)

        for _, slotIndex in ipairs(slotIndices) do
            local entries = config.matSlots[slotIndex]
            if type(entries) == "table" and #entries > 0 then

                if #entries == 1 then
                    local e           = entries[1]
                    local totalNeeded = (e.quantity or 1) * multiplier
                    local icon        = GetItemIcon(e.itemID)
                    local iconStr     = icon and IconString(icon, 28) or ""
                    local haveQty     = itemIDLookup[e.itemID] or 0
                    local isShort     = (haveQty < totalNeeded)
                    local r, g, b
                    if isShort then r, g, b = COLOR_RED.r,   COLOR_RED.g,   COLOR_RED.b
                    else            r, g, b = COLOR_GREEN.r, COLOR_GREEN.g, COLOR_GREEN.b end
                    local lineText
                    if isShort then
                        lineText = string.format("%s %d (%d)", iconStr, totalNeeded, haveQty)
                    else
                        lineText = string.format("%s %d", iconStr, totalNeeded)
                    end
                    GameTooltip:AddLine(lineText, r, g, b)

                elseif #entries == 2 then
                    local e1       = entries[1]
                    local e2       = entries[2]
                    local total1   = (e1.quantity or 1) * multiplier
                    local total2   = (e2.quantity or 1) * multiplier
                    local icon1    = GetItemIcon(e1.itemID)
                    local icon2    = GetItemIcon(e2.itemID)
                    local icon1Str = icon1 and IconString(icon1, 28) or ""
                    local icon2Str = icon2 and IconString(icon2, 28) or ""
                    local have1    = itemIDLookup[e1.itemID] or 0
                    local have2    = itemIDLookup[e2.itemID] or 0
                    local short1   = (have1 < total1)
                    local short2   = (have2 < total2)
                    local leftText
                    if short1 then leftText = string.format("%s %d (%d)", icon1Str, total1, have1)
                    else            leftText = string.format("%s %d",      icon1Str, total1) end
                    local lr, lg, lb
                    if short1 then lr, lg, lb = COLOR_RED.r,   COLOR_RED.g,   COLOR_RED.b
                    else            lr, lg, lb = COLOR_GREEN.r, COLOR_GREEN.g, COLOR_GREEN.b end
                    local rightText
                    if short2 then rightText = string.format("%s %d (%d)", icon2Str, total2, have2)
                    else            rightText = string.format("%s %d",      icon2Str, total2) end
                    local rr, rg, rb
                    if short2 then rr, rg, rb = COLOR_RED.r,   COLOR_RED.g,   COLOR_RED.b
                    else            rr, rg, rb = COLOR_GREEN.r, COLOR_GREEN.g, COLOR_GREEN.b end
                    GameTooltip:AddDoubleLine(leftText, rightText, lr, lg, lb, rr, rg, rb)

                else
                    -- 3+ tiers — one line each (rare edge case)
                    for _, e in ipairs(entries) do
                        local totalNeeded = (e.quantity or 1) * multiplier
                        local icon        = GetItemIcon(e.itemID)
                        local iconStr     = icon and IconString(icon, 28) or ""
                        local haveQty     = itemIDLookup[e.itemID] or 0
                        local isShort     = (haveQty < totalNeeded)
                        local r, g, b
                        if isShort then r, g, b = COLOR_RED.r,   COLOR_RED.g,   COLOR_RED.b
                        else            r, g, b = COLOR_GREEN.r, COLOR_GREEN.g, COLOR_GREEN.b end
                        local lineText
                        if isShort then lineText = string.format("%s %d (%d)", iconStr, totalNeeded, haveQty)
                        else            lineText = string.format("%s %d",      iconStr, totalNeeded) end
                        GameTooltip:AddLine(lineText, r, g, b)
                    end
                end
            end
        end
    end

    if config.optionalSlots then
        local optIndices = {}
        for slotIndex in pairs(config.optionalSlots) do
            table.insert(optIndices, slotIndex)
        end
        table.sort(optIndices)

        for _, slotIndex in ipairs(optIndices) do
            local slotEntry = config.optionalSlots[slotIndex]
            local itemID    = slotEntry and slotEntry.itemID
            if itemID then
                local totalNeeded = 1 * multiplier
                local icon        = GetItemIcon(itemID)
                local iconStr     = icon and IconString(icon, 28) or ""
                local itemName    = GetItemInfo(itemID) or ("ItemID " .. itemID)
                local haveQty     = itemIDLookup[itemID] or 0
                local isShort     = (haveQty < totalNeeded)
                local r, g, b
                if isShort then r, g, b = COLOR_RED.r,   COLOR_RED.g,   COLOR_RED.b
                else            r, g, b = COLOR_GREEN.r, COLOR_GREEN.g, COLOR_GREEN.b end
                local lineText
                if isShort then
                    lineText = string.format("%s %d (%d)  %s", iconStr, totalNeeded, haveQty, itemName)
                else
                    lineText = string.format("%s %d  %s", iconStr, totalNeeded, itemName)
                end
                GameTooltip:AddLine(lineText, r, g, b)
            end
        end
    end
end

-- Shows the tooltip for an Inventory Manager row.
-- result must include result.outputItemID (pre-resolved by QueueGeneration).
-- Returns true if tooltip was shown successfully.
function CraftTooltipBuilder:ShowRowTooltip(row, result, itemName, charGUID)
    if not row or not result then return false end

    local targetEvaluator = PocketCFO_Crafting:GetModule("InventoryTargetEvaluator", true)
    if not targetEvaluator then
        return false
    end

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(itemName or "Unknown", 1, 1, 1)
    GameTooltip:AddLine(
        string.format("In stock: %d   Target: %d   Need: %d",
            result.currentStock or 0,
            result.config and result.config.targetQuantity or 0,
            result.deficit or 0),
        0.8, 0.8, 0.8)

    local outputItemID = result.outputItemID
    if outputItemID then
        GameTooltip:AddLine("Item ID: " .. tostring(outputItemID), 0.7, 0.7, 0.7)
    end

    GameTooltip:AddLine(" ")

    -- Ask the evaluator for fresh material availability on hover.
    local itemIDLookup = targetEvaluator:GetMaterialAvailabilityByItemID(
        result.config,
        charGUID,
        result.deficit
    )
    AddMatLinesToTooltip(result, itemIDLookup or {})

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to load recipe",  0.5, 0.5, 0.5)
    GameTooltip:AddLine("Right-click to delete", 0.5, 0.5, 0.5)
    GameTooltip:Show()
    return true
end
