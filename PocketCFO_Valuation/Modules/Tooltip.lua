-- PocketCFO_Valuation/Modules/Tooltip.lua
-- Adds cached valuation lines to normal item tooltips.
--
-- Quality reagent slots (crafting form / order form): Blizzard builds the
-- slot tooltip from the slot's first listed reagent - always the lowest
-- quality - no matter what is slotted (Brian, 2026-10-16: lens slot showed
-- the low-quality value with only high-quality lenses loaded). For those
-- slots the single line is skipped and one "PocketCFO Value" line per
-- quality is added instead, the same way Auctionator does it.

-- Patch compat: Blizzard moved the coin-icon formatter to C_CurrencyInfo.
local GetCoinTextureString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString)
    or GetCoinTextureString
    or GetMoneyString

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local Tooltip = PocketCFO_Valuation:NewModule("Tooltip")

local TOOLTIP_DATA_HOOKED = false
local FALLBACK_ITEM_HOOKED = false
local QUALITY_REAGENT_HOOKED = false
local MAX_OWNER_DEPTH = 4
local REGISTERED_TOOLTIPS = setmetatable({}, { __mode = "k" })
local TOOLTIP_STATE = setmetatable({}, { __mode = "k" })

local function ClearTooltipState(tooltip)
    if not tooltip then
        return
    end

    local state = TOOLTIP_STATE[tooltip]
    if state then
        state.marketKey = nil
        state.itemLink = nil
        state.lineText = nil
        state.hasPocketCFOValue = nil
    end

    tooltip.PocketCFOValuationMarketKey = nil
    tooltip.PocketCFOValuationItemLink = nil
    tooltip.PocketCFOValuationLineText = nil
    tooltip.PocketCFOValuationHasPocketCFOValue = nil
end

local function SetTooltipState(tooltip, itemLink, marketKey, lineText)
    local state = TOOLTIP_STATE[tooltip]
    if not state then
        state = {}
        TOOLTIP_STATE[tooltip] = state
    end

    state.marketKey = marketKey
    state.itemLink = itemLink
    state.lineText = lineText
    state.hasPocketCFOValue = true

    tooltip.PocketCFOValuationMarketKey = marketKey
    tooltip.PocketCFOValuationItemLink = itemLink
    tooltip.PocketCFOValuationLineText = lineText
    tooltip.PocketCFOValuationHasPocketCFOValue = true
end

local function TooltipHasLine(tooltip, lineText)
    if not tooltip or not lineText or not tooltip.GetName then
        return false
    end

    local name = tooltip:GetName()
    if not name then
        return false
    end

    local lineCount = tooltip.NumLines and tooltip:NumLines() or 0
    for i = 1, lineCount do
        local line = _G[name .. "TextLeft" .. i]
        if line and line.GetText and line:GetText() == lineText then
            return true
        end
    end

    return false
end

local function TooltipAlreadyHasLine(tooltip, itemLink, marketKey, lineText)
    local state = TOOLTIP_STATE[tooltip]
    if state and state.hasPocketCFOValue and state.itemLink == itemLink and state.marketKey == marketKey and state.lineText == lineText and TooltipHasLine(tooltip, lineText) then
        return true
    end

    if tooltip.PocketCFOValuationHasPocketCFOValue and tooltip.PocketCFOValuationItemLink == itemLink and tooltip.PocketCFOValuationMarketKey == marketKey and tooltip.PocketCFOValuationLineText == lineText and TooltipHasLine(tooltip, lineText) then
        return true
    end

    return false
end

local function FormatCopper(value)
    value = tonumber(value)
    if not value then
        return nil
    end
    value = math.floor(value + 0.5)
    if GetCoinTextureString then
        return GetCoinTextureString(value)
    end
    return tostring(value) .. "c"
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

local function ExtractItemLink(tooltip, data)
    if data and type(data) == "table" then
        if data.hyperlink then
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

local function SetLastLookup(itemLink, identity, marketKey, exact, value, freshness, candidates, note)
    Tooltip.lastLookup = {
        itemLink = itemLink,
        identity = identity,
        marketKey = marketKey,
        cacheHit = exact ~= nil,
        value = value,
        freshness = freshness,
        sameItemCandidateCount = candidates and #candidates or 0,
        note = note,
    }
end

-- Containers: rare non-stackable drops (recipes/designs, tools...) left out
-- of the bag value (CustomValuationRegistrations) are listed under it, so
-- the jackpot is visible without driving the value (Brian, 2026-10-20).
local MAX_POSSIBLE_DROP_LINES = 3

local function AddPossibleDropLines(tooltip, result)
    local drops = type(result) == "table" and result.possibleDrops or nil
    if type(drops) ~= "table" or #drops == 0 then
        return
    end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    for index, drop in ipairs(drops) do
        if index > MAX_POSSIBLE_DROP_LINES then
            local moreText = string.format("  ...and %d more rare drops", #drops - MAX_POSSIBLE_DROP_LINES)
            if not TooltipHasLine(tooltip, moreText) then
                tooltip:AddLine(moreText, 0.6, 0.6, 0.6)
            end
            break
        end
        local ok, name = pcall(getInfo, drop.itemID)
        local text = string.format("Can also contain: %s (seen %d in %d opens)",
            (ok and name) or "a rare item", tonumber(drop.timesSeen) or 0, tonumber(drop.openCount) or 0)
        if not TooltipHasLine(tooltip, text) then
            tooltip:AddLine(text, 0.6, 0.6, 0.6)
        end
    end
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

local function AddValuationLine(tooltip, data)
    if not tooltip then
        return
    end

    local itemLink = ExtractItemLink(tooltip, data)
    if not itemLink then
        SetLastLookup(nil, nil, nil, nil, nil, nil, nil, "No item link on tooltip")
        return
    end

    -- The link on a quality slot tooltip is always the lowest quality;
    -- AddQualityReagentLines prices every quality instead.
    if IsQualityReagentSlotTooltip(tooltip) then
        SetLastLookup(itemLink, nil, nil, nil, nil, nil, nil, "Quality reagent slot - per-quality lines")
        return
    end

    -- Same answer as every other part of the addon: ValuationService applies
    -- custom/vendor/AH precedence, the stat-variant average and every
    -- valuation rule (2026-10-12). Previously this read PricingCache directly.
    local identityModule = PocketCFO_Valuation:GetModule("PricingIdentity", true)
    local cacheModule = PocketCFO_Valuation:GetModule("PricingCache", true)
    local valuationService = PocketCFO_Valuation:GetModule("ValuationService", true)
    if not identityModule or not cacheModule or not valuationService then
        SetLastLookup(itemLink, nil, nil, nil, nil, nil, nil, "Pricing modules unavailable")
        return
    end

    local identity = identityModule:BuildFromItemLink(itemLink)
    local marketKey = identity and identity.marketKey
    local itemID = (identity and identity.itemID) or tonumber(tostring(itemLink):match("item:(%d+)"))
    if not itemID then
        SetLastLookup(itemLink, identity, marketKey, nil, nil, nil, nil, "No itemID")
        return
    end

    local ok, result = pcall(valuationService.GetItemValue, valuationService, { itemID = itemID, itemLink = itemLink })
    local value = ok and type(result) == "table" and not result.unresolved and result.value or nil
    local exact = marketKey and cacheModule:GetEntry(marketKey) or nil

    -- AH summary row / item header: price by the real item level instead.
    if not value then
        local keyItemID, keyItemLevel = GetItemKeyArgs(tooltip)
        if keyItemID == itemID then
            local cheapest = CheapestValueAtItemLevel(valuationService, cacheModule, keyItemID, keyItemLevel)
            if cheapest then
                ok, result, value = true, cheapest, cheapest.value
                marketKey = tostring(itemID) .. "|itemKeyIlvl" .. tostring(keyItemLevel)
            end
        end
    end
    local formatted = FormatCopper(value)
    if not formatted then
        local candidates = cacheModule.GetCandidatesForItemID and cacheModule:GetCandidatesForItemID(itemID) or {}
        SetLastLookup(itemLink, identity, marketKey, exact, nil, nil, candidates,
            "No value: " .. tostring(ok and type(result) == "table" and result.unresolvedReason or "lookupError"))
        return
    end

    local freshness = result.isFresh and "fresh" or "stale"
    local lineText = "PocketCFO Value: " .. formatted
    if result.valuationBasis == "modeled" then
        lineText = lineText .. " (Estimated)"
    end
    local lastScanAge = result.source == "auctionHouse" and FormatLastScanAge(result.lastUpdated) or nil
    if lastScanAge then
        lineText = lineText .. " Last Scan: " .. lastScanAge
    end
    marketKey = marketKey or ("itemID:" .. tostring(itemID))
    if TooltipAlreadyHasLine(tooltip, itemLink, marketKey, lineText) then
        return
    end

    tooltip:AddLine(lineText, 0.2, 0.9, 0.8)
    AddPossibleDropLines(tooltip, result)
    SetTooltipState(tooltip, itemLink, marketKey, lineText)
    if tooltip.Show then
        pcall(tooltip.Show, tooltip)
    end
    SetLastLookup(itemLink, identity, marketKey, exact, value, freshness, nil, "Value: " .. tostring(result.source))
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

-- One "PocketCFO Value <quality icon>: <value>" line per quality of the
-- slot's mat, lowest first. Same value and suffixes as the single line.
-- A quality with no value gets no line, same as the single line.
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
            local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
            return select(2, getInfo(tier.itemID))
        end)
        itemLink = okLink and itemLink or nil
        local ok, result = pcall(valuationService.GetItemValue, valuationService, { itemID = tier.itemID, itemLink = itemLink })
        local value = ok and type(result) == "table" and not result.unresolved and result.value or nil
        local formatted = FormatCopper(value)
        if formatted then
            local lineText = "PocketCFO Value " .. QualityIconMarkup(tier.itemID, tierIndex) .. ": " .. formatted
            if result.valuationBasis == "modeled" then
                lineText = lineText .. " (Estimated)"
            end
            local lastScanAge = result.source == "auctionHouse" and FormatLastScanAge(result.lastUpdated) or nil
            if lastScanAge then
                lineText = lineText .. " Last Scan: " .. lastScanAge
            end
            if not TooltipHasLine(tooltip, lineText) then
                tooltip:AddLine(lineText, 0.2, 0.9, 0.8)
            end
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

local function RegisterTooltip(tooltip)
    if not tooltip or REGISTERED_TOOLTIPS[tooltip] then
        return
    end

    REGISTERED_TOOLTIPS[tooltip] = true
    if tooltip.HookScript then
        tooltip:HookScript("OnTooltipCleared", ClearTooltipState)
        tooltip:HookScript("OnHide", ClearTooltipState)
    end
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
    RegisterTooltip(GameTooltip)
    RegisterTooltip(ItemRefTooltip)

    local hasTooltipDataProcessor = TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
    if hasTooltipDataProcessor then
        if not TOOLTIP_DATA_HOOKED then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
                AddValuationLine(tooltip, data)
            end)
            TOOLTIP_DATA_HOOKED = true
        end
    elseif not FALLBACK_ITEM_HOOKED then
        if GameTooltip and GameTooltip.HookScript then
            GameTooltip:HookScript("OnTooltipSetItem", AddValuationLine)
        end
        if ItemRefTooltip and ItemRefTooltip.HookScript then
            ItemRefTooltip:HookScript("OnTooltipSetItem", AddValuationLine)
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
