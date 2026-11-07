-- PocketCFO_Valuation/Modules/Tooltip.lua
-- Adds cached valuation lines to normal item tooltips.
--
-- Quality reagent slots (crafting form / order form): Blizzard builds the
-- slot tooltip from the slot's first listed reagent - always the lowest
-- quality - no matter what is slotted (Brian, 2026-10-16: lens slot showed
-- the low-quality value with only high-quality lenses loaded). For those
-- slots the single line is skipped and one "PocketCFO Value" line per
-- quality is added instead, the same way Auctionator does it.
--
-- Hover performance (Brian, 2026-11-07; a player had to turn the addon off,
-- frame rate fell to ~30 sweeping across bags). A hover only ever needs
-- three numbers, so it does the least work that gets them:
--   - One GetItemInfo call feeds the vendor row, the disenchant gate and
--     the item facts.
--   - Vendor: the sell price from that call.
--   - Disenchant: gear only (weapon / armor / profession gear, green to
--     purple); DisenchantValue prices the mats through the price sheet.
--   - PCFO Value, in order:
--       1. a custom value rule (containers, Moxie bags, gray items) -> value
--       2. bound (soulbound / warbound bind line) -> no PCFO Value (it
--          can't go on the AH; Brian: the PCFO Value is what it's worth on
--          the AH)
--       3. no vendor purchase price and nothing in the price cache for this
--          item ID -> no PCFO Value
--       4. otherwise ValuationService (price sheet: worked out once, reused
--          until a price or rule changes)
--   - The finished rows are remembered per item for ROW_SECONDS and until
--     the value version moves (Core.lua), so the game refreshing a bag
--     tooltip while you hover redraws stored rows instead of re-pricing.
-- Never calls tooltip:Show() (Midnight finding: never inside a tooltip hook).
-- Flavor: Both.

-- Patch compat: Blizzard moved the coin-icon formatter to C_CurrencyInfo.
local GetCoinTextureString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString)
    or GetCoinTextureString
    or GetMoneyString

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local Tooltip = PocketCFO_Valuation:NewModule("Tooltip")

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local TOOLTIP_DATA_HOOKED = false
local FALLBACK_ITEM_HOOKED = false
local QUALITY_REAGENT_HOOKED = false
local MAX_OWNER_DEPTH = 4

-- Value rows (Brian, 2026-11-03): PCFO Value / Disenchant / Vendor are
-- two-column rows, label on the left and gold on the right, so the gold
-- amounts line up down the right edge for comparison. Index of the row
-- whose left text is leftText (and right text is rightText when given).
local function FindLineIndex(tooltip, leftText, rightText)
    if not tooltip or not leftText or not tooltip.GetName then
        return nil
    end
    local name = tooltip:GetName()
    if not name then
        return nil
    end
    local lineCount = tooltip.NumLines and tooltip:NumLines() or 0
    for i = 1, lineCount do
        local left = _G[name .. "TextLeft" .. i]
        if left and left.GetText and left:GetText() == leftText then
            if rightText == nil then
                return i
            end
            local right = _G[name .. "TextRight" .. i]
            if right and right.GetText and right:GetText() == rightText then
                return i
            end
        end
    end
    return nil
end

local function TooltipHasRow(tooltip, label, valueText)
    return FindLineIndex(tooltip, label, valueText) ~= nil
end

-- Always gold, silver and copper, silver and copper two digits (Brian,
-- 2026-11-03), so the coin icons line up between right-aligned rows.
-- GetCoinTextureString leaves out zero coins, which breaks the alignment.
-- Theoretical: icon paths are Blizzard's own MoneyFrame textures (the ones
-- the GOLD/SILVER/COPPER_AMOUNT_TEXTURE strings use); not yet seen in-game
-- with this markup.
local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local function FormatCopper(value)
    value = tonumber(value)
    if not value then
        return nil
    end
    value = math.floor(value + 0.5)
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local copper = value % 100
    local goldText = BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold)
    return string.format("%s%s %02d%s %02d%s", goldText, GOLD_ICON, silver, SILVER_ICON, copper, COPPER_ICON)
end

local HIGHEST_COLOR = { 0.1, 1.0, 0.1 }
local OTHER_COLOR = { 1.0, 1.0, 1.0 }
local VALUE_COLOR = { 0.2, 0.9, 0.8 }
local NOTE_COLOR = { 0.6, 0.6, 0.6 }

local function AddValueRow(tooltip, label, valueText)
    if not TooltipHasRow(tooltip, label, valueText) then
        tooltip:AddDoubleLine(label, valueText,
            VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3],
            VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3])
    end
end

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function ColorAgeText(ageText, ageSeconds)
    local color = "ff00ff00"
    if ageSeconds > (7 * 24 * 60 * 60) then
        color = "ffff0000"
    elseif ageSeconds >= (24 * 60 * 60) then
        color = "ffffff00"
    end

    return "|c" .. color .. ageText .. "|r"
end

local function FormatLastScanAge(timestamp)
    timestamp = tonumber(timestamp)
    if not timestamp then
        return nil
    end

    local ageSeconds = math.max(0, Now() - timestamp)
    local ageText
    if ageSeconds < (60 * 60) then
        ageText = tostring(math.floor((ageSeconds / 60) + 0.5)) .. "m"
    elseif ageSeconds < (24 * 60 * 60) then
        ageText = tostring(math.floor((ageSeconds / (60 * 60)) + 0.5)) .. "h"
    else
        ageText = tostring(math.floor((ageSeconds / (24 * 60 * 60)) + 0.5)) .. "d"
    end

    return ColorAgeText(ageText, ageSeconds)
end

local function LinkItemID(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- Recipes (confirmed in-game 2026-10-26, /mcgd tipcalls on Plans: Amani
-- Forgemaster's Decorative Spear): data.id is the recipe, but data.hyperlink
-- is the CRAFTED item's link, so the value line priced the crafted item.
-- tooltip:GetItem() returns the recipe's own link. When data.hyperlink's item
-- doesn't match data.id, the tooltip's own link is used instead.
local function ExtractItemLink(tooltip, data)
    if data and type(data) == "table" then
        if data.hyperlink then
            local dataID = tonumber(data.id)
            local linkID = LinkItemID(data.hyperlink)
            if dataID and linkID and linkID ~= dataID and tooltip and tooltip.GetItem then
                local ok, _, ownLink = pcall(tooltip.GetItem, tooltip)
                if ok and LinkItemID(ownLink) == dataID then
                    return ownLink
                end
            end
            return data.hyperlink
        end
        if data.itemLink then
            return data.itemLink
        end
        if data.link then
            return data.link
        end
    end

    if tooltip and tooltip.GetItem then
        local ok, _, itemLink = pcall(tooltip.GetItem, tooltip)
        if ok and itemLink then
            return itemLink
        end
    end

    local tooltipData
    if tooltip and tooltip.GetPrimaryTooltipData then
        local ok, result = pcall(tooltip.GetPrimaryTooltipData, tooltip)
        if ok then
            tooltipData = result
        end
    elseif tooltip and tooltip.GetTooltipData then
        local ok, result = pcall(tooltip.GetTooltipData, tooltip)
        if ok then
            tooltipData = result
        end
    end

    if type(tooltipData) == "table" then
        return tooltipData.hyperlink or tooltipData.itemLink or tooltipData.link
    end

    return nil
end

-- A slot whose options are quality tiers of one mat. Blizzard's own rule
-- (Confirmed in Blizzard 12.1.0 source, Professions.GetReagentInputMode -
-- same check ReagentSlotService.IsQualityTierSlot uses): reagentType Basic
-- with more than one reagent.
local function IsQualityTierSchematic(schematic)
    if type(schematic) ~= "table" or type(schematic.reagents) ~= "table" or #schematic.reagents < 2 then
        return false
    end
    local basicType = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
    return basicType ~= nil and tonumber(schematic.reagentType) == basicType
end

-- Is this tooltip owned by a quality reagent slot? Walks the owner and a
-- few parents for a frame with :GetReagentSlotSchematic() (the slot method
-- Auctionator calls). Theoretical: which frame owns the slot tooltip (the
-- slot or its Button) is not confirmed in-game yet - see /mcgd reagenttip.
local function IsQualityReagentSlotTooltip(tooltip)
    if not tooltip or not tooltip.GetOwner then
        return false
    end
    local okOwner, node = pcall(tooltip.GetOwner, tooltip)
    node = okOwner and node or nil
    local depth = 0
    while node and depth <= MAX_OWNER_DEPTH do
        local okMethod, method = pcall(function() return node.GetReagentSlotSchematic end)
        if okMethod and type(method) == "function" then
            local ok, schematic = pcall(method, node)
            return ok and IsQualityTierSchematic(schematic)
        end
        local okParent, parent = pcall(function() return node:GetParent() end)
        node = okParent and parent or nil
        depth = depth + 1
    end
    return false
end

-- Last hover, for diagnostics.
local function SetLastLookup(itemLink, marketKey, value, freshness, note)
    Tooltip.lastLookup = {
        itemLink = itemLink,
        marketKey = marketKey,
        cacheHit = marketKey ~= nil,
        value = value,
        freshness = freshness,
        note = note,
    }
end

-- Containers: rare non-stackable drops (recipes/designs, tools...) left out
-- of the bag value (CustomValuationRegistrations) are listed under it, so
-- the jackpot is visible without driving the value (Brian, 2026-10-20).
-- Built once with the rest of the rows; returns a list of line texts.
local MAX_POSSIBLE_DROP_LINES = 3

local function BuildPossibleDropLines(result)
    local drops = type(result) == "table" and result.possibleDrops or nil
    if type(drops) ~= "table" or #drops == 0 then
        return nil
    end
    local lines = {}
    for index, drop in ipairs(drops) do
        if index > MAX_POSSIBLE_DROP_LINES then
            lines[#lines + 1] = string.format("  ...and %d more rare drops", #drops - MAX_POSSIBLE_DROP_LINES)
            break
        end
        local ok, name = pcall(GetItemInfo, drop.itemID)
        lines[#lines + 1] = string.format("Can also contain: %s (seen %d in %d opens)",
            (ok and name) or "a rare item", tonumber(drop.timesSeen) or 0, tonumber(drop.openCount) or 0)
    end
    return lines
end

-- AH summary rows and the item header above a listing: Blizzard fills these
-- with GetItemKey(itemID, itemLevel, itemSuffix, requiredLevel), and the link
-- they carry has the base item level, not the real one. Confirmed in-game
-- 2026-10-24 (Sin'dorei Jeweler's Loupes summary row: getterName
-- "GetItemKey", args 240959, 232, 0, 78; link built key ilvl206). Returns
-- itemID, itemLevel for such a tooltip, else nil.
local function GetItemKeyArgs(tooltip)
    local info = tooltip and (tooltip.processingInfo or tooltip.info)
    if type(info) ~= "table" or info.getterName ~= "GetItemKey" or type(info.getterArgs) ~= "table" then
        return nil
    end
    local itemID, itemLevel = tonumber(info.getterArgs[1]), tonumber(info.getterArgs[2])
    if not itemID or not itemLevel then
        return nil
    end
    return itemID, itemLevel
end

-- A summary row covers every version of the item at that item level (e.g.
-- tools with different stats). Shows the cheapest PocketCFO value among
-- them (Brian, 2026-10-24: matches the row's lowest price, as Auctionator
-- does). Each version goes through ValuationService so rules still apply.
local function CheapestValueAtItemLevel(valuationService, cacheModule, itemID, itemLevel)
    if not cacheModule.GetCandidatesForItemID then
        return nil
    end
    local best
    for _, row in ipairs(cacheModule:GetCandidatesForItemID(itemID) or {}) do
        if type(row) == "table" and tonumber(row.itemLevel) == itemLevel then
            local ok, result = pcall(valuationService.GetItemValue, valuationService, {
                itemID = itemID,
                itemLevel = row.itemLevel,
                qualityTier = row.qualityTier,
                statFingerprint = row.statFingerprint,
            })
            local value = ok and type(result) == "table" and not result.unresolved and tonumber(result.value) or nil
            if value and (not best or value < best.value) then
                best = result
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- Bound items (Brian, 2026-11-07): a soulbound or warbound copy can't go on
-- the AH, so it gets no PCFO Value (custom-rule values like containers still
-- show). Read from the bind line on the tooltip being built, with core's
-- shared check (SoulboundClassifier:TooltipTextIsBound: Soulbound, Binds
-- when picked up, Warbound / Warband), the same check the posting list uses.
-- Binds when equipped is not bound. data.lines (leftText) first, the same
-- shape core reads from C_TooltipInfo; else the tooltip's own left lines.
-- ---------------------------------------------------------------------------

local function IsBoundTooltip(tooltip, data)
    local core = _G.PocketCFO
    local classifier = (core and core.SoulboundClassifier) or _G.PocketCFO_SoulboundClassifier
    if not classifier or type(classifier.TooltipTextIsBound) ~= "function" then
        return false
    end
    local lines = type(data) == "table" and data.lines or nil
    if type(lines) == "table" then
        for _, line in ipairs(lines) do
            local text = type(line) == "table" and line.leftText or nil
            if text and text ~= "" and classifier:TooltipTextIsBound(text) then
                return true
            end
        end
        return false
    end
    local name = tooltip and tooltip.GetName and tooltip:GetName()
    if not name then
        return false
    end
    for i = 1, (tooltip.NumLines and tooltip:NumLines() or 0) do
        local left = _G[name .. "TextLeft" .. i]
        local text = left and left.GetText and left:GetText()
        if text and text ~= "" and classifier:TooltipTextIsBound(text) then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Building the rows (once per item per change; see the header).
-- ---------------------------------------------------------------------------

local DISENCHANT_RARITY = { [2] = true, [3] = true, [4] = true }
local DISENCHANT_CLASS = { [2] = true, [4] = true, [19] = true }

-- PCFO Value: the filters from the header, then ValuationService.
-- Returns result, marketKey, note.
local function LookUpPocketValue(tooltip, itemLink, itemID, bound)
    local valuationService = PocketCFO_Valuation:GetModule("ValuationService", true)
    local cacheModule = PocketCFO_Valuation:GetModule("PricingCache", true)
    local vendorService = PocketCFO_Valuation:GetModule("VendorPriceService", true)
    if not valuationService or not cacheModule then
        return nil, nil, "Pricing modules unavailable"
    end

    local hasRule = valuationService.HasValueRule and valuationService:HasValueRule(itemID, itemLink)
    if not hasRule then
        if bound then
            return nil, nil, "Bound - no PCFO Value"
        end
        local keyItemID = GetItemKeyArgs(tooltip)
        local hasVendor = vendorService and vendorService.HasPrice and vendorService:HasPrice(itemID)
        local hasCache = cacheModule.HasItemID and cacheModule:HasItemID(keyItemID or itemID)
        if not hasVendor and not hasCache then
            return nil, nil, "No price data for this item"
        end
    end

    local ok, result = pcall(valuationService.GetItemValue, valuationService, { itemID = itemID, itemLink = itemLink })
    local value = ok and type(result) == "table" and not result.unresolved and tonumber(result.value) or nil
    local marketKey = value and result.provenance and result.provenance.marketKey or nil

    -- AH summary row / item header: price by the real item level instead.
    if not value then
        local keyItemID, keyItemLevel = GetItemKeyArgs(tooltip)
        if keyItemID == itemID then
            local cheapest = CheapestValueAtItemLevel(valuationService, cacheModule, keyItemID, keyItemLevel)
            if cheapest then
                return cheapest, tostring(itemID) .. "|itemKeyIlvl" .. tostring(keyItemLevel), "Value: cheapest at item level"
            end
        end
        return nil, nil, "No value: " .. tostring(ok and type(result) == "table" and result.unresolvedReason or "lookupError")
    end
    return result, marketKey, "Value: " .. tostring(result.source)
end

-- Everything the tooltip shows for one item, ready to draw:
--   values = { { label, text, value }, ... } (PCFO Value, Disenchant, Vendor)
--   highest = the largest value when two or more rows show
--   scanAt = AH scan time for the "Scanned ... ago" line, uncertain = few
--   listings, dropLines = container rare drops
local function BuildRows(tooltip, itemLink, bound)
    local itemID = LinkItemID(itemLink)
    local rows = { values = {} }
    if not itemID then
        rows.note = "No itemID"
        return rows
    end

    -- The one GetItemInfo call: sell price, rarity and item class.
    local okInfo, itemName, _, rarity, _, _, _, _, _, _, _, sellPrice, classID = pcall(GetItemInfo, itemLink)
    if not okInfo or not itemName then
        rows.pending = true -- item data not loaded yet; build again next time
    end
    rarity = okInfo and tonumber(rarity) or nil
    classID = okInfo and tonumber(classID) or nil
    sellPrice = okInfo and tonumber(sellPrice) or nil

    -- PCFO Value
    local result, marketKey, note = LookUpPocketValue(tooltip, itemLink, itemID, bound)
    local pocketValue = result and tonumber(result.value) or nil
    local pocketText = FormatCopper(pocketValue)
    if pocketText then
        local label = "PCFO Value"
        if result.valuationBasis == "modeled" then
            label = label .. " (Est.)"
        end
        rows.values[#rows.values + 1] = { label = label, text = pocketText, value = pocketValue }
        if result.source == "auctionHouse" then
            rows.scanAt = tonumber(result.lastUpdated)
            -- Thin evidence (ValuationService:GetConfidence, 2026-11-04):
            -- said on the scan line, no new tooltip line.
            local valuationService = PocketCFO_Valuation:GetModule("ValuationService", true)
            if valuationService and valuationService.GetConfidence then
                local okLevel, level = pcall(valuationService.GetConfidence, valuationService, result)
                rows.uncertain = okLevel and level == "uncertain" or nil
            end
        end
        rows.dropLines = BuildPossibleDropLines(result)
    end
    rows.note = note
    rows.marketKey = marketKey
    rows.value = pocketValue
    rows.freshness = result and (result.isFresh and "fresh" or "stale") or nil

    -- Disenchant (Est.): gear only. DisenchantValue checks the same gate
    -- again with its own data; this one just avoids calling it at all for
    -- mats, consumables, quest items and the like.
    if DISENCHANT_RARITY[rarity] and DISENCHANT_CLASS[classID] then
        local disenchantValue = PocketCFO_Valuation:GetModule("DisenchantValue", true)
        if disenchantValue then
            local ok, estimate = pcall(disenchantValue.GetEstimate, disenchantValue, itemLink)
            local text = ok and FormatCopper(estimate) or nil
            if text then
                rows.values[#rows.values + 1] = { label = "Disenchant (Est.)", text = text, value = tonumber(estimate) }
            end
        end
    end

    -- Vendor: what a merchant pays per item; no row when it pays nothing.
    -- Theoretical: GetItemInfo sellPrice is 0 for items a merchant won't
    -- buy; the row is skipped for 0 or nil either way.
    if sellPrice and sellPrice > 0 then
        rows.values[#rows.values + 1] = { label = "Vendor", text = FormatCopper(sellPrice), value = sellPrice }
    end

    -- When two or more of PCFO Value / Disenchant / Vendor show, the highest
    -- gold amount is green and the others white; labels stay teal. With one
    -- value, colors are unchanged. Values only, no advice.
    if #rows.values >= 2 then
        local highest = rows.values[1].value
        for _, row in ipairs(rows.values) do
            if row.value > highest then
                highest = row.value
            end
        end
        rows.highest = highest
    end
    return rows
end

-- Remembered rows: item link (+ bound, + AH summary row item level) ->
-- { rows, at, version }.
local ROW_SECONDS = 60
local ROW_MAX_ENTRIES = 500
local rowMemo, rowMemoCount = {}, 0

local function GetRows(tooltip, itemLink, bound)
    local _, keyItemLevel = GetItemKeyArgs(tooltip)
    local key = itemLink .. (bound and "#bound" or "") .. (keyItemLevel and ("#ilvl" .. keyItemLevel) or "")
    local version = PocketCFO_Valuation.valueVersion or 0
    local now = GetTime and GetTime() or 0
    local entry = rowMemo[key]
    if entry and entry.version == version and now - entry.at < ROW_SECONDS then
        return entry.rows
    end
    local rows = BuildRows(tooltip, itemLink, bound)
    if not rows.pending then
        if rowMemoCount >= ROW_MAX_ENTRIES then
            rowMemo, rowMemoCount = {}, 0
        end
        if not rowMemo[key] then
            rowMemoCount = rowMemoCount + 1
        end
        rowMemo[key] = { rows = rows, at = now, version = version }
    end
    return rows
end

local function DrawRows(tooltip, rows)
    local first = rows.values[1]
    if not first then
        return
    end
    -- The hook ran already for this tooltip build: don't add the rows twice.
    if TooltipHasRow(tooltip, first.label, first.text) then
        return
    end
    for _, row in ipairs(rows.values) do
        local color = VALUE_COLOR
        if rows.highest then
            color = (row.value == rows.highest) and HIGHEST_COLOR or OTHER_COLOR
        end
        tooltip:AddDoubleLine(row.label, row.text,
            VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3],
            color[1], color[2], color[3])
    end
    -- "Scanned <age> ago" for AH values, worked out now so it's never stale.
    local lastScanAge = rows.scanAt and FormatLastScanAge(rows.scanAt) or nil
    if lastScanAge then
        local scanText = rows.uncertain
            and ("Few listings \194\183 scanned " .. lastScanAge .. " ago")
            or ("Scanned " .. lastScanAge .. " ago")
        tooltip:AddLine(scanText, NOTE_COLOR[1], NOTE_COLOR[2], NOTE_COLOR[3])
    end
    for _, text in ipairs(rows.dropLines or {}) do
        tooltip:AddLine(text, NOTE_COLOR[1], NOTE_COLOR[2], NOTE_COLOR[3])
    end
end

local function OnItemTooltip(tooltip, data)
    if not tooltip then
        return
    end
    local itemLink = ExtractItemLink(tooltip, data)
    if not itemLink then
        SetLastLookup(nil, nil, nil, nil, "No item link on tooltip")
        return
    end
    -- The link on a quality slot tooltip is always the lowest quality;
    -- AddQualityReagentLines prices every quality instead.
    if IsQualityReagentSlotTooltip(tooltip) then
        SetLastLookup(itemLink, nil, nil, nil, "Quality reagent slot - per-quality lines")
        return
    end
    local rows = GetRows(tooltip, itemLink, IsBoundTooltip(tooltip, data))
    DrawRows(tooltip, rows)
    SetLastLookup(itemLink, rows.marketKey, rows.value, rows.freshness, rows.note)
end

local function QualityIconMarkup(itemID, fallbackTier)
    local ok, markup = pcall(function()
        local info = C_TradeSkillUI.GetItemReagentQualityInfo(itemID)
        return info and info.iconChat and CreateAtlasMarkup(info.iconChat, 17, 17)
    end)
    if ok and markup then
        return markup
    end
    return "Q" .. tostring(fallbackTier)
end

-- One "PCFO Value <quality icon>" row per quality of the slot's mat, lowest
-- first, gold on the right like the single row. Each quality has its own
-- scan age, so it stays on that row's label as "(3h)" instead of a
-- footer line. A quality with no value gets no row, same as the single row.
local function AddQualityReagentLines(slot)
    local tooltip = GameTooltip
    local valuationService = PocketCFO_Valuation:GetModule("ValuationService", true)
    if not tooltip or not valuationService or not slot or type(slot.GetReagentSlotSchematic) ~= "function" then
        return
    end
    local okSchematic, schematic = pcall(slot.GetReagentSlotSchematic, slot)
    if not okSchematic or not IsQualityTierSchematic(schematic) then
        return
    end

    local tiers = {}
    for index, reagent in ipairs(schematic.reagents) do
        local itemID = tonumber(type(reagent) == "table" and reagent.itemID or nil)
        if itemID then
            local okQuality, quality = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, itemID)
            tiers[#tiers + 1] = {
                itemID = itemID,
                order = (okQuality and tonumber(quality)) or index,
            }
        end
    end
    table.sort(tiers, function(a, b) return a.order < b.order end)

    for tierIndex, tier in ipairs(tiers) do
        local okLink, itemLink = pcall(function()
            return select(2, GetItemInfo(tier.itemID))
        end)
        itemLink = okLink and itemLink or nil
        local ok, result = pcall(valuationService.GetItemValue, valuationService, { itemID = tier.itemID, itemLink = itemLink })
        local value = ok and type(result) == "table" and not result.unresolved and result.value or nil
        local formatted = FormatCopper(value)
        if formatted then
            local label = "PCFO Value " .. QualityIconMarkup(tier.itemID, tierIndex)
            if result.valuationBasis == "modeled" then
                label = label .. " (Est.)"
            end
            local lastScanAge = result.source == "auctionHouse" and FormatLastScanAge(result.lastUpdated) or nil
            if lastScanAge then
                label = label .. " (" .. lastScanAge .. ")"
            end
            AddValueRow(tooltip, label, formatted)
        end
    end
end

-- Hooks the Blizzard function that builds quality reagent slot tooltips.
-- Function names and the (slot, transaction) signature: Confirmed
-- (third-party) - Auctionator Source/Tooltips/Hooks.lua hooks the same
-- functions the same way, newer name first.
local function HookQualityReagentTooltips()
    if QUALITY_REAGENT_HOOKED or not Professions or not hooksecurefunc then
        return
    end
    local functionName = (type(Professions.SetupQualityReagentTooltip) == "function" and "SetupQualityReagentTooltip")
        or (type(Professions.SetupReagentQualityPickerTooltip) == "function" and "SetupReagentQualityPickerTooltip")
        or nil
    if not functionName then
        return
    end
    hooksecurefunc(Professions, functionName, function(slot)
        pcall(AddQualityReagentLines, slot)
    end)
    QUALITY_REAGENT_HOOKED = true
end

function Tooltip:InspectItem(itemLinkOrID)
    local identityModule = PocketCFO_Valuation:GetModule("PricingIdentity", true)
    local cacheModule = PocketCFO_Valuation:GetModule("PricingCache", true)
    if not identityModule or not cacheModule then
        return nil
    end

    local identity
    if type(itemLinkOrID) == "string" and itemLinkOrID:find("item:", 1, true) then
        identity = identityModule:BuildFromItemLink(itemLinkOrID)
    else
        identity = identityModule:BuildFromItemID(tonumber(itemLinkOrID))
    end

    local marketKey = identity and identity.marketKey
    local exact = marketKey and cacheModule:GetEntry(marketKey) or nil
    local value, freshness
    if marketKey then
        value, freshness = cacheModule:GetValueByMarketKey(marketKey)
    end
    local candidates = identity and cacheModule:GetCandidatesForItemID(identity.itemID) or {}

    return {
        input = itemLinkOrID,
        identity = identity,
        marketKey = marketKey,
        exact = exact,
        hasExact = exact ~= nil,
        value = value,
        freshness = freshness,
        candidates = candidates,
    }
end

function Tooltip:GetLastLookup()
    return self.lastLookup
end

function Tooltip:OnEnable()
    local hasTooltipDataProcessor = TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
    if hasTooltipDataProcessor then
        if not TOOLTIP_DATA_HOOKED then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
                pcall(OnItemTooltip, tooltip, data)
            end)
            TOOLTIP_DATA_HOOKED = true
        end
    elseif not FALLBACK_ITEM_HOOKED then
        local function OnTooltipSetItem(tooltip)
            pcall(OnItemTooltip, tooltip, nil)
        end
        if GameTooltip and GameTooltip.HookScript then
            GameTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        end
        if ItemRefTooltip and ItemRefTooltip.HookScript then
            ItemRefTooltip:HookScript("OnTooltipSetItem", OnTooltipSetItem)
        end
        FALLBACK_ITEM_HOOKED = true
    end

    -- Blizzard_ProfessionsTemplates may load before or after this addon;
    -- ContinueOnAddOnLoaded runs now if it is already loaded.
    if EventUtil and EventUtil.ContinueOnAddOnLoaded then
        EventUtil.ContinueOnAddOnLoaded("Blizzard_ProfessionsTemplates", HookQualityReagentTooltips)
    else
        HookQualityReagentTooltips()
    end
end

function Tooltip:OnDisable()
end
