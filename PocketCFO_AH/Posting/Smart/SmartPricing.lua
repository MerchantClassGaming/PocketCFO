-- PocketCFO_AH/Posting/Smart/SmartPricing.lua
-- Smart AH view: works out each item's floor (lowest price we post at) and
-- ceiling (most we post at), the setting that turns the smart view on, and
-- the per-character Keep list. Design: claude/AH_Smart_Posting_Design.md.
--
-- Floor   = highest of today's Cost to Make, vendor sell price, disenchant
--           value, x 1.10 (covers the 5% AH cut plus a small profit).
-- Ceiling = the most we post at, first that exists: 2x our last sale (real
--           evidence of what a buyer paid), Cost to Make x curve (market value
--           can't rein crafted items in: for gear it's the lowest buyout,
--           which can be the silly listing itself), market value x curve.
--           Never below the floor.
-- Matching the lowest real competitor, and every Note the player sees,
-- happen in PostingEvaluator (smart branch).
--
-- Flavor: Both. The curve's gold amounts are scaled for Forever's smaller
-- economy (retail / 10, Brian 2026-11-04); tune live.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local SmartPricing = PocketCFO_AH:NewModule("SmartPricing")

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local COPPER_PER_GOLD = 10000
-- Prices must be whole silver: PostItem with copper left over returns ok but
-- no auction is created (stuck post captures 2026-11-04: 41316274 and
-- 56122796 never posted, 41310000 and 10002800 did).
local COPPER_PER_SILVER = 100

local function SilverUp(copper)
    return math.ceil(copper / COPPER_PER_SILVER) * COPPER_PER_SILVER
end

local function SilverDown(copper)
    return math.floor(copper / COPPER_PER_SILVER) * COPPER_PER_SILVER
end
local FLOOR_MARKUP = 1.10
local DEFAULT_DURATION = 12

-- Ceiling multiplier by base price (gold), retail. Smooth: straight lines
-- between points on a log scale, flat past the ends (never below 2x).
-- Anchor: a 100g-to-make item caps at 10x = 1,000g (Brian, 2026-11-04).
local CURVE = {
    { gold = 1, mult = 25 },
    { gold = 10, mult = 15 },
    { gold = 100, mult = 10 },
    { gold = 1000, mult = 5 },
    { gold = 10000, mult = 3 },
}
local MIN_MULT = 2
-- Max price from our own last sale: 2x it (knife sold at 2,000g against
-- competition -> 4,000g when nobody else lists; Brian 2026-11-04).
local SALE_MULTIPLIER = 2
local FOREVER_GOLD_SCALE = 0.1

local function IsForever()
    return PocketCFO and PocketCFO.flavor == "forever"
end

local function Log10(x)
    return math.log(x) / math.log(10)
end

-- Ceiling multiplier for a base price in copper.
function SmartPricing:CurveMultiplier(baseCopper)
    baseCopper = tonumber(baseCopper)
    if not baseCopper or baseCopper <= 0 then
        return nil
    end
    local gold = baseCopper / COPPER_PER_GOLD
    if IsForever() then
        gold = gold / FOREVER_GOLD_SCALE
    end
    local first, last = CURVE[1], CURVE[#CURVE]
    if gold <= first.gold then
        return first.mult
    end
    if gold >= last.gold then
        return math.max(MIN_MULT, last.mult)
    end
    local x = Log10(gold)
    for index = 1, #CURVE - 1 do
        local a, b = CURVE[index], CURVE[index + 1]
        if gold <= b.gold then
            local xa, xb = Log10(a.gold), Log10(b.gold)
            local t = (x - xa) / (xb - xa)
            return math.max(MIN_MULT, a.mult + (b.mult - a.mult) * t)
        end
    end
    return MIN_MULT
end

-- ---------------------------------------------------------------------------
-- Setting: smart view on / off. Owned by core BetaFeatures (2026-11-06):
-- on only when the Auction House Posting beta AND its Smart Posting option
-- are both checked. Both default off.
-- ---------------------------------------------------------------------------

-- Smart posting needs the posting modules, which Forever doesn't load yet
-- (PocketCFO_AH_Camelot.toc); there it reads off until they are added.
function SmartPricing:IsSmartView()
    if not PocketCFO_AH:GetModule("PostingController", true) then
        return false
    end
    local beta = PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("BetaFeatures", true)
    return beta ~= nil and beta:IsSmartAuctionHouseOn() == true
end

-- ---------------------------------------------------------------------------
-- Keep list: per character. [itemKey] = { keep = number or nil (nil = all),
-- itemID, itemName, configKey }. Never touches the old itemRuleIgnoreList.
-- ---------------------------------------------------------------------------

local function CharKey()
    return PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID
        or (UnitGUID and UnitGUID("player")) or "unknown"
end

local function KeepRoot()
    local db = PocketCFO_AH.db and PocketCFO_AH.db.global
    if not db then
        return {}
    end
    db.smartKeepList = db.smartKeepList or {}
    local key = CharKey()
    db.smartKeepList[key] = db.smartKeepList[key] or {}
    return db.smartKeepList[key]
end

function SmartPricing:GetKeepList()
    return KeepRoot()
end

function SmartPricing:GetKeep(itemKey)
    if not itemKey then
        return nil
    end
    return KeepRoot()[tostring(itemKey)]
end

function SmartPricing:AddKeep(itemKey, info)
    if not itemKey then
        return
    end
    info = info or {}
    local root = KeepRoot()
    local entry = root[tostring(itemKey)] or {}
    entry.itemID = tonumber(info.itemID) or entry.itemID
    entry.itemName = info.itemName or entry.itemName
    entry.itemLink = info.itemLink or entry.itemLink
    entry.configKey = info.configKey or entry.configKey
    root[tostring(itemKey)] = entry
end

-- amount nil or blank = keep all.
function SmartPricing:SetKeepAmount(itemKey, amount)
    local entry = itemKey and KeepRoot()[tostring(itemKey)]
    if not entry then
        return
    end
    amount = tonumber(amount)
    entry.keep = (amount and amount >= 0) and math.floor(amount) or nil
end

function SmartPricing:RemoveKeep(itemKey)
    if itemKey then
        KeepRoot()[tostring(itemKey)] = nil
    end
end

-- How many of a bag stack are offered for posting after the Keep list.
-- Returns quantity (0 = keep all) and the keep entry.
function SmartPricing:QuantityAfterKeep(itemKey, inBags)
    inBags = math.max(0, math.floor(tonumber(inBags) or 0))
    local entry = self:GetKeep(itemKey)
    if not entry then
        return inBags, nil
    end
    if entry.keep == nil then
        return 0, entry
    end
    return math.max(0, inBags - entry.keep), entry
end

-- ---------------------------------------------------------------------------
-- Usually Post: how many the player wants up at once, per item, for the whole
-- account (Brian, 2026-11-04). Separate from Keep on purpose. Saved until the
-- player changes it. Stackables: units; everything else: auctions.
-- [itemKey] = number. No entry = the default (one stack, 1 if it doesn't stack).
-- ---------------------------------------------------------------------------

local function UsuallyPostRoot()
    local db = PocketCFO_AH.db and PocketCFO_AH.db.global
    if not db then
        return {}
    end
    db.smartUsuallyPost = db.smartUsuallyPost or {}
    return db.smartUsuallyPost
end

function SmartPricing:GetUsuallyPost(itemKey)
    if not itemKey then
        return nil
    end
    return tonumber(UsuallyPostRoot()[tostring(itemKey)])
end

-- amount nil, blank or 0 = back to the default.
function SmartPricing:SetUsuallyPost(itemKey, amount)
    if not itemKey then
        return
    end
    amount = math.floor(tonumber(amount) or 0)
    UsuallyPostRoot()[tostring(itemKey)] = amount > 0 and amount or nil
end

function SmartPricing:DefaultUsuallyPost(stackSize)
    stackSize = math.floor(tonumber(stackSize) or 0)
    return stackSize > 0 and stackSize or 1
end

-- ---------------------------------------------------------------------------
-- Floor and ceiling.
-- ---------------------------------------------------------------------------

local function ValuationAddon()
    local addon = _G.PocketCFO_Valuation
    if addon and type(addon.GetItemValue) == "function" then
        return addon
    end
    return nil
end

-- Returns value per unit, source, and the value before Valuation's adjust
-- rules (nil when no rule changed it).
local function UnitValue(itemRef)
    local valuation = ValuationAddon()
    if not valuation then
        return nil, nil
    end
    local ok, result = pcall(valuation.GetItemValue, valuation, itemRef)
    if not ok or type(result) ~= "table" or result.unresolved then
        return nil, nil
    end
    local value = tonumber(result.valuePerUnit or result.value)
    if not value or value <= 0 then
        return nil, nil
    end
    return value, result.source, tonumber(result.unadjustedValue), result
end

-- "confident" | "uncertain" for a GetItemValue result (ValuationService).
local function Confidence(result)
    local valuation = _G.PocketCFO_Valuation
    local service = valuation and valuation.GetModule and valuation:GetModule("ValuationService", true)
    if not service or type(service.GetConfidence) ~= "function" then
        return "uncertain"
    end
    local ok, level = pcall(service.GetConfidence, service, result)
    return ok and level or "uncertain"
end

local function VendorSellPrice(itemLink, itemID)
    if type(GetItemInfo) ~= "function" then
        return nil
    end
    local ok, _, _, _, _, _, _, _, _, _, _, sellPrice = pcall(GetItemInfo, itemLink or itemID)
    sellPrice = ok and tonumber(sellPrice) or nil
    if sellPrice and sellPrice > 0 then
        return sellPrice
    end
    return nil
end

-- One stack: the default quantity to post (Brian, 2026-11-04). 1 for
-- anything that doesn't stack.
local function StackSize(itemLink, itemID)
    if type(GetItemInfo) ~= "function" then
        return 1
    end
    local ok, _, _, _, _, _, _, _, stackCount = pcall(GetItemInfo, itemLink or itemID)
    stackCount = ok and tonumber(stackCount) or nil
    if stackCount and stackCount > 1 then
        return math.floor(stackCount)
    end
    return 1
end

local function DisenchantValue(itemLink)
    local valuation = _G.PocketCFO_Valuation
    local module = valuation and valuation.GetModule and valuation:GetModule("DisenchantValue", true)
    if not module or type(module.GetEstimate) ~= "function" or type(itemLink) ~= "string" then
        return nil
    end
    local ok, copper = pcall(module.GetEstimate, module, itemLink)
    copper = ok and tonumber(copper) or nil
    if copper and copper > 0 then
        return copper
    end
    return nil
end

local function CostToMake(configKey, itemID)
    local store = PocketCFO and PocketCFO.CostToMakeStore
    if not store or type(store.GetCostToday) ~= "function" then
        return nil
    end
    local ok, cost = pcall(store.GetCostToday, store, configKey, itemID, function(matID, matConfigKey)
        return (UnitValue({ itemID = matID, configKey = matConfigKey }))
    end)
    cost = ok and tonumber(cost) or nil
    if cost and cost > 0 then
        return cost
    end
    return nil
end

-- Our own most recent sale (PocketCFO_Valuation SaleIndex: one quick lookup
-- built once per few minutes from our listings and gold income). A sale is
-- real evidence of what a buyer paid, so it sets the max price.
-- Returns copper per unit, source ("listing" | "income").
local function LastSalePrice(configKey, itemID)
    local valuation = _G.PocketCFO_Valuation
    local index = valuation and valuation.GetModule and valuation:GetModule("SaleIndex", true)
    if not index or type(index.GetLastSale) ~= "function" then
        return nil
    end
    local ok, price, _, source = pcall(index.GetLastSale, index, configKey, itemID)
    if ok and price then
        return price, source
    end
    return nil
end

-- bounds = {
--   floor, floorSource ("cost" | "vendor" | "disenchant"), floorBase,
--   costToMake, vendorSell, disenchant, marketValue, marketSource,
--   ceiling, ceilingBase ("sale" | "cost" | "market"), multiplier,
--   lastSale, lastSaleSource, confidence ("confident" | "uncertain"),
--   valuePrice (confident value, between floor and max), ruleCap, stackSize,
--   usuallyPost (saved Usually Post, nil = default) }
-- Any field can be nil. Never throws.
function SmartPricing:GetBounds(candidate)
    local bounds = {}
    local ok, err = pcall(function()
        candidate = type(candidate) == "table" and candidate or {}
        local itemID = tonumber(candidate.itemID)
        local itemLink = candidate.itemLink
        local configKey = candidate.configKey or (candidate.identity and candidate.identity.configKey)

        bounds.usuallyPost = SmartPricing:GetUsuallyPost(configKey or (itemID and tostring(itemID)))
        bounds.costToMake = CostToMake(configKey, itemID)
        bounds.vendorSell = VendorSellPrice(itemLink, itemID)
        bounds.disenchant = DisenchantValue(itemLink)
        local unadjusted, marketResult
        bounds.marketValue, bounds.marketSource, unadjusted, marketResult = UnitValue({ itemID = itemID, itemLink = itemLink, configKey = configKey })
        if marketResult then
            marketResult.configKey = marketResult.configKey or configKey
            bounds.confidence = Confidence(marketResult)
        end
        -- Valuation's sanity caps (quality-sibling-cap, tool-tier-cap: a lower
        -- quality is never worth more than a higher one) lowered this item's
        -- value: that value is also the most we post at (Brian, 2026-11-04:
        -- green 206 quill posted at 5,252g while a blue 212 sat at 800g).
        if bounds.marketValue and unadjusted and bounds.marketValue < unadjusted then
            bounds.ruleCap = bounds.marketValue
        end
        -- The cap a rule worked out even when it didn't lower the value
        -- (ValuationRuleSet NoteCap): never post above a better version.
        local ladderCap = marketResult and tonumber(marketResult.ladderCap)
        if ladderCap and ladderCap > 0 and (not bounds.ruleCap or ladderCap < bounds.ruleCap) then
            bounds.ruleCap = ladderCap
        end
        bounds.lastSale, bounds.lastSaleSource = LastSalePrice(configKey, itemID)
        bounds.stackSize = StackSize(itemLink, itemID)

        local base, source = nil, nil
        for _, pair in ipairs({
            { bounds.costToMake, "cost" },
            { bounds.disenchant, "disenchant" },
            { bounds.vendorSell, "vendor" },
        }) do
            if pair[1] and (not base or pair[1] > base) then
                base, source = pair[1], pair[2]
            end
        end
        if base then
            bounds.floorBase = base
            bounds.floorSource = source
            bounds.floor = SilverUp(base * FLOOR_MARKUP)
        end

        -- Max price, first that exists (Brian, 2026-11-04):
        --   2x our last sale  ->  Cost to Make x curve  ->  market value x curve.
        -- No max = not posted ("No price data yet").
        local ceiling, ceilingKind = nil, nil
        if bounds.lastSale then
            bounds.multiplier = SALE_MULTIPLIER
            ceiling, ceilingKind = bounds.lastSale * SALE_MULTIPLIER, "sale"
        elseif bounds.costToMake then
            bounds.multiplier = self:CurveMultiplier(bounds.costToMake)
            ceiling, ceilingKind = bounds.costToMake * (bounds.multiplier or MIN_MULT), "cost"
        elseif bounds.marketValue then
            bounds.multiplier = self:CurveMultiplier(bounds.marketValue)
            ceiling, ceilingKind = bounds.marketValue * (bounds.multiplier or MIN_MULT), "market"
        end
        if ceiling then
            bounds.ceilingBase = ceilingKind
            bounds.ceiling = SilverDown(ceiling)
            if bounds.floor and bounds.ceiling < bounds.floor then
                bounds.ceiling = bounds.floor
            end
        end
        if bounds.ruleCap then
            local capped = math.max(SilverDown(bounds.ruleCap), bounds.floor or 0)
            if not bounds.ceiling or capped < bounds.ceiling then
                bounds.ceiling = capped
                bounds.ceilingBase = "rule"
                ceilingKind = "rule"
            end
        end
        -- Nobody else listing: post at the value only when there's enough
        -- evidence behind it (Brian, 2026-11-04). Kept between floor and max.
        if bounds.marketValue and bounds.confidence == "confident" then
            local price = math.max(SilverDown(bounds.marketValue), bounds.floor or 0)
            if bounds.ceiling then
                price = math.min(price, bounds.ceiling)
            end
            bounds.valuePrice = price
        end
    end)
    if not ok and PocketCFO and PocketCFO.AppendSessionLog then
        PocketCFO:AppendSessionLog("[MCG] SmartPricing: GetBounds failed err=" .. tostring(err))
    end
    return bounds
end

SmartPricing.DEFAULT_DURATION = DEFAULT_DURATION
SmartPricing.SilverUp = SilverUp
SmartPricing.FLOOR_MARKUP = FLOOR_MARKUP
