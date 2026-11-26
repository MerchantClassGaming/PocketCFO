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
-- Flavor: Both, except Waylaid Crate "Cost to fill" rows (Forever only,
-- gated on PocketCFO.flavor == "forever"; see ReadCrateBundles).

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

-- Coin icons for FormatCopper (see its comment for which coins show).
-- Own markup rather than GetCoinTextureString so the two-digit padding of
-- the coins after the first stays under our control.
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
    -- Brian, 2026-11-17 (replaces the 2026-11-03 always-three-coins rule):
    -- zero leading coins are dropped and the first coin shown has no
    -- leading zero ("1s 60c", not "0g 01s 60c"); coins after it keep two
    -- digits ("1g 05s 03c").
    if gold > 0 then
        local goldText = BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold)
        return string.format("%s%s %02d%s %02d%s", goldText, GOLD_ICON, silver, SILVER_ICON, copper, COPPER_ICON)
    elseif silver > 0 then
        return string.format("%d%s %02d%s", silver, SILVER_ICON, copper, COPPER_ICON)
    end
    return string.format("%d%s", copper, COPPER_ICON)
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

-- ---------------------------------------------------------------------------
-- Waylaid Crates (Forever only, Brian 2026-11-17). A crate is filled with
-- any ONE bundle from its list, so the tooltip shows each bundle's cost
-- (count x that mat's PCFO Value, the same number the mat's own tooltip
-- shows) and the cheapest in green. Unpriced bundle = "No price", never a
-- partial or zero total.
-- Confirmed in-game 2026-11-17 (/mcgd crate, Journeyman Textiles 248688):
--   - the whole list is ONE tooltip data line (the use line, has spellID,
--     type 44): "Use: Fill the crate with any bundle from the following
--     list:\n- 20 Wool Cloth\n- 40 Silk Cloth\n- 20 Medium Leather"
--   - C_Item.GetItemIDForItemInfo(name) returns the mat's itemID (2592,
--     4306, 2319); GetItemInfo(name) returns nil.
--   - GetItemIDForItemInfo returns 0 for a mat the player doesn't hold
--     (Bronze Tube), even after the item is loaded (verify, 75 of 96 mats),
--     so names resolve through ForeverCrateMats:GetItemIDByName. A name
--     that still doesn't resolve: the rows aren't remembered and the next
--     hover tries again.
-- Theoretical: every crate uses the same "- <count> <name>" format (both
-- captures and the method.gg list do).
local FILL_HEADER = "Cost to fill"

-- Merchant's Favor per sealed crate (Brian, 2026-11-17; player reports on
-- conquestcapped / wow.gg / u4gm): every tier has white and green crates,
-- green pays double. The crate's tier comes from ForeverCrateMats.CRATES
-- by itemID (any client language); the multiplier from the crate's own
-- quality. Base by tier: Apprentice 5, Journeyman 10, Expert 15, Artisan
-- 20. Artisan is unconfirmed (shown "Est." until a turn-in confirms it).
-- Only white (1) and green (2) are known; any other quality (game files
-- reportedly hold higher ones) or a crate not in the table shows no Favor.
local TIER_FAVOR = {
    Apprentice = { favor = 5 },
    Journeyman = { favor = 10 },
    Expert = { favor = 15 },
    Artisan = { favor = 20, estimated = true },
}
local FAVOR_MULTIPLIER = { [1] = 1, [2] = 2 }

local function CrateFavor(itemID, rarity)
    local multiplier = FAVOR_MULTIPLIER[rarity]
    local crateMats = PocketCFO_Valuation:GetModule("ForeverCrateMats", true)
    local crate = multiplier and crateMats and crateMats.CRATES and crateMats.CRATES[itemID]
    local tier = crate and TIER_FAVOR[crate.tier]
    if not tier then
        return nil
    end
    return tier.favor * multiplier, tier.estimated
end
local GetItemIDForItemInfo = C_Item and C_Item.GetItemIDForItemInfo

local function IsForever()
    local core = _G.PocketCFO
    return type(core) == "table" and core.flavor == "forever"
end

-- Color codes in the list text (2026-11-17: the last bundle on every
-- crate failed to resolve, e.g. "Tin Ore", while the others worked; the
-- list is wrapped in a color code, so the last name ends in "|r").
-- Removes |cAARRGGBB, |cn<name>: and |r.
local function StripColorCodes(text)
    text = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    text = string.gsub(text, "|cn[^:]*:", "")
    text = string.gsub(text, "|r", "")
    return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

-- { { count, name }, ... } from the crate's use line, or nil.
local function ReadCrateBundles(data)
    local lines = type(data) == "table" and data.lines or nil
    if type(lines) ~= "table" then
        return nil
    end
    for _, line in ipairs(lines) do
        local text = type(line) == "table" and line.leftText or nil
        if type(text) == "string" and line.spellID and string.find(text, "\n", 1, true) then
            local bundles
            for part in string.gmatch(text, "[^\n]+") do
                local count, name = string.match(part, "^%s*%-%s*(%d+)%s+(.-)%s*$")
                if count then
                    name = StripColorCodes(name)
                    bundles = bundles or {}
                    bundles[#bundles + 1] = { count = tonumber(count), name = name }
                end
            end
            if bundles then
                return bundles
            end
        end
    end
    return nil
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
-- AH sell slot (Brian, 2026-11-10: Plans: Copper Chain Vest showed a
-- disenchant estimate): GetItem() there doesn't give the recipe's link, and
-- falling back to data.hyperlink priced the crafted vest. On a mismatch the
-- crafted item's link is never used: the recipe's link comes from data.id
-- (recipes have no item level or variants, so the plain link is exact).
-- Theoretical: what GetItem() returns on the AH sell slot; this path is
-- correct either way.
local function ExtractItemLink(tooltip, data)
    if data and type(data) == "table" then
        if data.hyperlink then
            local dataID = tonumber(data.id)
            local linkID = LinkItemID(data.hyperlink)
            if dataID and linkID and linkID ~= dataID then
                if tooltip and tooltip.GetItem then
                    local ok, _, ownLink = pcall(tooltip.GetItem, tooltip)
                    if ok and LinkItemID(ownLink) == dataID then
                        return ownLink
                    end
                end
                local okInfo, _, recipeLink = pcall(GetItemInfo, dataID)
                if okInfo and LinkItemID(recipeLink) == dataID then
                    return recipeLink
                end
                -- Item data not loaded yet: a bare item string still prices
                -- the recipe, never the crafted item.
                return "item:" .. dataID
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

-- ---------------------------------------------------------------------------
-- Bound items (Brian, 2026-11-07): a soulbound or warbound copy can't go on
-- the AH, so it gets no PCFO Value (custom-rule values like containers still
-- show). Read from the bind line on the tooltip being built, with core's
-- shared check (SoulboundClassifier:TooltipTextIsBound: Soulbound, Binds
-- when picked up, Warbound / Warband), the same check the posting list uses.
-- Binds when equipped is not bound. data.lines (leftText) first, the same
-- shape core reads from C_TooltipInfo; else the tooltip's own left lines.
-- ---------------------------------------------------------------------------

-- Recipes (Brian, 2026-11-15: Pattern: Stormrider's Leather Helm on Forever
-- showed no PCFO Value): a recipe tooltip also shows the crafted item's
-- tooltip, bind line included, so a pattern for a Binds when picked up item
-- read as bound. For recipes the recipe's own bind type decides instead:
-- Binds when picked up (1) or account / warband bound (7, 8, 9) = bound.
-- Item data not loaded yet: the line check below, as before.
-- Theoretical: bindType values on Forever (same C_Item.GetItemInfo call).
local RECIPE_CLASS_ID = 9
local RECIPE_BOUND_BIND_TYPES = { [1] = true, [7] = true, [8] = true, [9] = true }

local function IsBoundTooltip(tooltip, data, itemLink)
    if itemLink then
        local ok, _, _, _, _, _, _, _, _, _, _, _, classID, _, bindType = pcall(GetItemInfo, itemLink)
        if ok and tonumber(classID) == RECIPE_CLASS_ID then
            return RECIPE_BOUND_BIND_TYPES[tonumber(bindType)] == true
        end
    end
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

    -- AH summary row / item header: it covers every version of the item at
    -- that item level. Its link carries the base item level, so when that
    -- misses it's priced by the real item level with the one "version
    -- unknown" rule the recipe book uses too
    -- (ValuationService:GetUnknownVersionValue, Item_Identity_Unification_Design.md
    -- 6.8): the same mace can't show a value here and none in the recipe book.
    if not value then
        local keyItemID, keyItemLevel = GetItemKeyArgs(tooltip)
        if keyItemID == itemID and valuationService.GetUnknownVersionValue then
            local okUnknown, unknown = pcall(valuationService.GetUnknownVersionValue, valuationService, itemID, keyItemLevel, itemLink)
            if okUnknown and type(unknown) == "table" and tonumber(unknown.value) then
                return unknown, tostring(itemID) .. "|itemKeyIlvl" .. tostring(keyItemLevel), "Value: version unknown, cheapest at item level"
            end
        end
        return nil, nil, "No value: " .. tostring(ok and type(result) == "table" and result.unresolvedReason or "lookupError")
    end
    return result, marketKey, "Value: " .. tostring(result.source)
end

-- Crate "Cost to fill" rows: { rows = { { label, text, value } }, lowest,
-- pending }. lowest only when two or more bundles are priced (same rule as
-- the value rows: with one value, no highlight).
local function BuildFillRows(data, itemID, rarity)
    local bundles = ReadCrateBundles(data)
    if not bundles then
        return nil
    end
    local fill = { rows = {} }
    fill.favor, fill.favorEstimated = CrateFavor(itemID, rarity)
    fill.header = FILL_HEADER
    if fill.favor then
        fill.header = FILL_HEADER .. " \194\183 " .. fill.favor .. " Favor" .. (fill.favorEstimated and " (Est.)" or "")
    end
    local priced = 0
    for _, bundle in ipairs(bundles) do
        -- ForeverCrateMats first (every crate mat, any client language);
        -- GetItemIDForItemInfo only as the fallback for a mat not on that
        -- list (works only for items the player holds; 0 otherwise).
        local itemID
        local crateMats = PocketCFO_Valuation:GetModule("ForeverCrateMats", true)
        if crateMats and crateMats.GetItemIDByName then
            itemID = crateMats:GetItemIDByName(bundle.name)
        end
        if not itemID and GetItemIDForItemInfo then
            local okID, id = pcall(GetItemIDForItemInfo, bundle.name)
            itemID = okID and tonumber(id) or nil
            if itemID == 0 then
                itemID = nil -- confirmed 2026-11-17: 0 for a mat the player doesn't hold (Bronze Tube)
            end
        end
        if not itemID then
            fill.pending = true -- name not resolved yet; build again next hover
        end
        local value
        if itemID then
            local result = LookUpPocketValue(nil, nil, itemID, false)
            local each = result and tonumber(result.value) or nil
            value = each and each * bundle.count or nil
        end
        if value then
            priced = priced + 1
        end
        fill.rows[#fill.rows + 1] = {
            label = "  " .. bundle.count .. " " .. bundle.name,
            text = value and (fill.favor
                and (FormatCopper(value) .. "  (" .. FormatCopper(value / fill.favor) .. " per Favor)")
                or FormatCopper(value)) or "No price",
            value = value,
            -- for Crate analysis (Tooltip:GetCrateFill): what to buy
            itemID = itemID,
            count = bundle.count,
            name = bundle.name,
            each = value and (value / bundle.count) or nil,
        }
    end
    if priced >= 2 then
        for _, row in ipairs(fill.rows) do
            if row.value and (not fill.lowest or row.value < fill.lowest) then
                fill.lowest = row.value
            end
        end
    end
    return fill
end

-- The Neutral AH row: { text, at } or nil. Tries the PCFO Value's market
-- key first, then the item link's own key (an item with no faction price
-- still gets its Neutral line). Flavor: Forever-only (caller gates).
local NEUTRAL_LABEL = "Neutral AH"

local function BuildNeutralRow(itemLink, marketKey)
    local cacheModule = PocketCFO_Valuation:GetModule("PricingCache", true)
    if not cacheModule or not cacheModule.GetNeutralEntry then
        return nil
    end
    local value, at
    if marketKey then
        value, at = cacheModule:GetNeutralEntry(marketKey)
    end
    if not value and itemLink then
        local identity = PocketCFO_Valuation:GetModule("PricingIdentity", true)
        local okKey, ownKey = false, nil
        if identity and identity.BuildMarketKey then
            okKey, ownKey = pcall(identity.BuildMarketKey, identity, itemLink)
        end
        if okKey and ownKey and ownKey ~= marketKey then
            value, at = cacheModule:GetNeutralEntry(ownKey)
        end
    end
    local text = FormatCopper(value)
    if not text then
        return nil
    end
    return { text = text, at = at }
end

-- Everything the tooltip shows for one item, ready to draw:
--   values = { { label, text, value }, ... } (PCFO Value, Disenchant, Vendor)
--   highest = the largest value when two or more rows show
--   scanAt = AH scan time for the "Scanned ... ago" line, uncertain = few
--   listings, dropLines = container rare drops
local function BuildRows(tooltip, itemLink, bound, data)
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

    -- Neutral AH (Brian, 2026-11-24, claude/Forever_Markets_Design.md): the
    -- Neutral AH's scanned price for this item, beside the PCFO Value (your
    -- faction's AH). We can't tell if the player is buying or selling, so
    -- both show. Only when a Neutral scan priced it; not on bound copies.
    -- The scanned price itself, without the PCFO Value rules (caps). Not part
    -- of the highest-value color. Flavor: Forever-only (gated).
    if IsForever() and not bound then
        rows.neutral = BuildNeutralRow(itemLink, marketKey)
    end

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

    -- Waylaid Crate (Forever only): Cost to fill per bundle.
    if classID == 0 and IsForever() then
        local fill = BuildFillRows(data, itemID, rarity)
        if fill then
            rows.fill = fill
            if fill.pending then
                rows.pending = true
            end
        else
            -- A known crate with no bundle list yet: the game hasn't loaded
            -- the crate's text, so the first tooltip comes without it (seen
            -- 2026-11-17: AH crates not yet loaded showed no crate rows for
            -- up to ROW_SECONDS). Don't remember these rows; the redraw with
            -- the full text builds them again.
            local crateMats = PocketCFO_Valuation:GetModule("ForeverCrateMats", true)
            if crateMats and crateMats.CRATES and crateMats.CRATES[itemID] then
                rows.pending = true
            end
        end
    end
    return rows
end

-- Remembered rows: item link (+ bound, + AH summary row item level) ->
-- { rows, at, version }.
local ROW_SECONDS = 60
local ROW_MAX_ENTRIES = 500
local rowMemo, rowMemoCount = {}, 0

local function GetRows(tooltip, itemLink, bound, data)
    local _, keyItemLevel = GetItemKeyArgs(tooltip)
    local key = itemLink .. (bound and "#bound" or "") .. (keyItemLevel and ("#ilvl" .. keyItemLevel) or "")
    local version = PocketCFO_Valuation.valueVersion or 0
    local now = GetTime and GetTime() or 0
    local entry = rowMemo[key]
    if entry and entry.version == version and now - entry.at < ROW_SECONDS then
        return entry.rows
    end
    local rows = BuildRows(tooltip, itemLink, bound, data)
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

local function DrawFillRows(tooltip, fill)
    if not fill then
        return
    end
    tooltip:AddLine(fill.header, VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3])
    for _, row in ipairs(fill.rows) do
        local color = OTHER_COLOR
        if not row.value then
            color = NOTE_COLOR
        elseif fill.lowest and row.value == fill.lowest then
            color = HIGHEST_COLOR
        end
        tooltip:AddDoubleLine(row.label, row.text,
            OTHER_COLOR[1], OTHER_COLOR[2], OTHER_COLOR[3],
            color[1], color[2], color[3])
    end
end

local function DrawRows(tooltip, rows)
    local first = rows.values[1]
    if not first and not rows.fill and not rows.neutral then
        return
    end
    -- The hook ran already for this tooltip build: don't add the rows twice.
    if first and TooltipHasRow(tooltip, first.label, first.text) then
        return
    end
    if not first and rows.fill and TooltipHasRow(tooltip, rows.fill.header) then
        return
    end
    if not first and not rows.fill and TooltipHasRow(tooltip, NEUTRAL_LABEL, rows.neutral.text) then
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
    -- Neutral AH line (Forever only), with its own scan age.
    if rows.neutral then
        tooltip:AddDoubleLine(NEUTRAL_LABEL, rows.neutral.text,
            VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3],
            OTHER_COLOR[1], OTHER_COLOR[2], OTHER_COLOR[3])
        local neutralAge = rows.neutral.at and FormatLastScanAge(rows.neutral.at) or nil
        if neutralAge then
            tooltip:AddLine("Neutral scanned " .. neutralAge .. " ago", NOTE_COLOR[1], NOTE_COLOR[2], NOTE_COLOR[3])
        end
    end
    for _, text in ipairs(rows.dropLines or {}) do
        tooltip:AddLine(text, NOTE_COLOR[1], NOTE_COLOR[2], NOTE_COLOR[3])
    end
    DrawFillRows(tooltip, rows.fill)
end

-- "You have" line (Brian, 2026-11-21; claude/Shopping_List_Design.md
-- section 8): where this character has the item, so players know where to
-- go get it (bank, mail, an auction to cancel). Only places with some show;
-- no line when there are none. Counts come from core
-- InventoryStateService:GetItemPlaces: bags live, every other place from its
-- last scan, looked up per item ID (built once per scan, not per hover).
-- Not remembered with the value rows: counts change without the value
-- version moving. Flavor: Both (no warband bank on Forever, so never shown).
local PLACE_ORDER = {
    { key = "bags", label = "Bags" },
    { key = "bank", label = "Bank" },
    { key = "warbank", label = "Warband bank" },
    { key = "mail", label = "Mail" },
    { key = "ah", label = "AH" },
}
local PLACES_LABEL = "You have"

local function DrawPlacesLine(tooltip, itemLink)
    local core = _G.PocketCFO
    local service = core and core.InventoryStateService
    local itemID = LinkItemID(itemLink)
    if not itemID or not service or not service.GetItemPlaces then
        return
    end
    local places = service:GetItemPlaces(itemID)
    local parts = {}
    for _, place in ipairs(PLACE_ORDER) do
        local count = tonumber(places[place.key]) or 0
        if count > 0 then
            parts[#parts + 1] = place.label .. " " .. (BreakUpLargeNumbers and BreakUpLargeNumbers(count) or tostring(count))
        end
    end
    if #parts == 0 then
        return
    end
    local text = table.concat(parts, " \194\183 ")
    -- The hook ran already for this tooltip build: don't add it twice.
    if TooltipHasRow(tooltip, PLACES_LABEL) then
        return
    end
    tooltip:AddDoubleLine(PLACES_LABEL, text,
        VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3],
        OTHER_COLOR[1], OTHER_COLOR[2], OTHER_COLOR[3])
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
    local rows = GetRows(tooltip, itemLink, IsBoundTooltip(tooltip, data, itemLink), data)
    DrawRows(tooltip, rows)
    DrawPlacesLine(tooltip, itemLink)
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

-- Crate analysis (Forever only, PocketCFO_AH CrateAnalysis): the same crate
-- numbers the crate tooltip shows, without a tooltip. Returns nil when not
-- Forever, not a crate, or the game hasn't loaded the crate's text yet.
-- Theoretical: C_TooltipInfo.GetHyperlink with a crate link built from
-- GetItemInfo / "item:<id>" returns the same use line as a hovered crate
-- (captures used hovered links).
function Tooltip:GetCrateFill(crateID)
    if not IsForever() or not crateID or not C_TooltipInfo or not C_TooltipInfo.GetHyperlink then
        return nil
    end
    local okInfo, itemName, itemLink, rarity = pcall(GetItemInfo, crateID)
    if not okInfo or not itemName then
        return nil
    end
    local okData, data = pcall(C_TooltipInfo.GetHyperlink, itemLink or ("item:" .. crateID))
    if not okData or type(data) ~= "table" then
        return nil
    end
    local fill = BuildFillRows(data, crateID, tonumber(rarity))
    if not fill then
        return nil
    end
    local result = LookUpPocketValue(nil, nil, crateID, false)
    fill.crateValue = result and tonumber(result.value) or nil
    fill.itemName = itemName
    fill.rarity = tonumber(rarity)
    return fill
end

-- Same money text as the tooltip (Crate analysis uses it so numbers read
-- the same in both places).
function Tooltip:FormatMoney(value)
    return FormatCopper(value)
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
