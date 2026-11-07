-- PocketCFO_AH/Posting/Smart/SmartPricing.lua
-- Smart AH view: works out each item's floor (lowest price we post at) and
-- ceiling (most we post at), the setting that turns the smart view on, and
-- the per-character Keep list. Design: claude/AH_Smart_Posting_Design.md.
--
-- Floor   = highest of today's Cost to Make, vendor sell price, disenchant
--           value, x 1.10 (covers the 5% AH cut plus a small profit).
-- Ceiling = the most we post at (stage 2, Brian 2026-11-06), first that
--           applies: 1. confident market value = the max; 2. not confident:
--           current-expansion crafted -> Cost to Make x curve, everything
--           else -> market value (few listings or not); 3. (later) scan
--           history, via Valuation; 4. 2x our last sale; 5. none (Your
--           call). Lowered by Valuation's ladder cap; never below the floor.
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

-- "confident" | "uncertain" for a GetItemValue result (ValuationService),
-- plus the reason (e.g. "farBelowUsual").
local function Confidence(result)
    local valuation = _G.PocketCFO_Valuation
    local service = valuation and valuation.GetModule and valuation:GetModule("ValuationService", true)
    if not service or type(service.GetConfidence) ~= "function" then
        return "uncertain"
    end
    local ok, level, reason = pcall(service.GetConfidence, service, result)
    if not ok then
        return "uncertain"
    end
    return level or "uncertain", reason
end

-- True when the item comes from an expansion before the current one
-- (GetItemInfo's expansion ID vs the client's current expansion). Unknown =
-- false (current-expansion rules, the lower max). Theoretical: whether
-- crafted items report their expansion correctly (2026-11-06).
local function CurrentExpansion()
    if type(LE_EXPANSION_LEVEL_CURRENT) == "number" then
        return LE_EXPANSION_LEVEL_CURRENT
    end
    if type(GetServerExpansionLevel) == "function" then
        local ok, level = pcall(GetServerExpansionLevel)
        if ok and type(level) == "number" then
            return level
        end
    end
    return nil
end

local function IsPastExpansion(itemLink, itemID)
    if type(GetItemInfo) ~= "function" then
        return false
    end
    local current = CurrentExpansion()
    if not current then
        return false
    end
    local ok, expansionID = pcall(function()
        return select(15, GetItemInfo(itemLink or itemID))
    end)
    expansionID = ok and tonumber(expansionID) or nil
    return expansionID ~= nil and expansionID < current
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

-- Cost to Make: saved recipe at today's prices, else the recipe estimate.
-- Both live in core CostToMakeStore (estimate moved there 2026-11-06 so
-- Valuation can use it too; behaviour unchanged).
-- Set when an estimate asked for item data (mat not loaded yet). GetBounds
-- reads it into bounds.pricesLoading; the controller then re-checks once by
-- itself (Brian, 2026-11-06: first pass after /reload said "Open the
-- recipe" until a manual Refresh).
local loadingRequested = false

-- A mat with no price is only "loading" when the client hasn't loaded its
-- item data yet. A loaded mat with no price just has no price: not loading
-- (2026-11-06: treating those as loading caused an endless refresh loop).
local function RequestItemData(itemID)
    local cached = nil
    if C_Item and type(C_Item.IsItemDataCachedByID) == "function" then
        local ok, result = pcall(C_Item.IsItemDataCachedByID, itemID)
        cached = ok and result == true or nil
    end
    if cached then
        return
    end
    loadingRequested = true
    if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

local function MatValue(matID, matConfigKey)
    return (UnitValue({ itemID = matID, configKey = matConfigKey }))
end

-- Returns copper, source ("saved" = recipe analysis, "estimate" = recipe
-- schematic at today's prices) or nil.
local function CostToMake(configKey, itemID, itemName)
    local store = PocketCFO and PocketCFO.CostToMakeStore
    if not store or type(store.GetCost) ~= "function" then
        return nil
    end
    local ok, cost, source = pcall(store.GetCost, store, configKey, itemID, itemName, MatValue, RequestItemData)
    cost = ok and tonumber(cost) or nil
    if cost and cost > 0 then
        return cost, source
    end
    return nil
end

-- Cheapest current listing of the same item, quality and item level with a
-- different stat in the same stat group (Brian, 2026-11-06: Resourcefulness
-- = Multicraft, Perception = Finesse; Ingenuity, Crafting Speed and Deftness
-- only match themselves). Used when no one lists our exact stat: a buyer
-- who wants the tool takes the cheapest equivalent. From PricingCache (what
-- the last search saw), current = within 3 days of the item's newest price.
-- Returns copper, the stat string, or nil.
local SAME_GROUP_WINDOW = 3 * 24 * 60 * 60

local function ValuationModule(name)
    local valuation = _G.PocketCFO_Valuation
    if not valuation or type(valuation.GetModule) ~= "function" then
        return nil
    end
    local ok, module = pcall(valuation.GetModule, valuation, name, true)
    return ok and module or nil
end

local function SameGroupListing(itemLink, itemID)
    local groupKey = _G.PocketCFO_Valuation and _G.PocketCFO_Valuation.StatGroupKey
    local identity = ValuationModule("PricingIdentity")
    local cache = ValuationModule("PricingCache")
    if type(groupKey) ~= "function" or not identity or not cache or type(itemLink) ~= "string" or not itemID then
        return nil
    end
    local okKey, ownKey = pcall(identity.BuildMarketKey, identity, itemLink)
    ownKey = okKey and type(ownKey) == "string" and ownKey or nil
    local ownStats = ownKey and ownKey:match("|stats:(.+)$")
    if not ownStats then
        return nil
    end
    local ownQuality, ownIlvl = ownKey:match("|q(%d+)"), ownKey:match("|ilvl(%d+)")
    local ownGroup = groupKey(ownStats)
    local rows = cache:GetCandidatesForItemID(itemID) or {}
    local newest
    for _, row in ipairs(rows) do
        local timestamp = type(row) == "table" and tonumber(row.timestamp)
        if timestamp and (not newest or timestamp > newest) then
            newest = timestamp
        end
    end
    if not newest then
        return nil
    end
    local cutoff = newest - SAME_GROUP_WINDOW
    local cheapest, cheapestStats
    for _, row in ipairs(rows) do
        local key = type(row) == "table" and tostring(row.marketKey or "") or ""
        local stats = key:match("|stats:(.+)$")
        local value = tonumber(row.value)
        if stats and stats ~= ownStats and value and value > 0
            and (tonumber(row.timestamp) or 0) >= cutoff
            and key:match("|q(%d+)") == ownQuality and key:match("|ilvl(%d+)") == ownIlvl
            and groupKey(stats) == ownGroup then
            if not cheapest or value < cheapest then
                cheapest, cheapestStats = value, stats
            end
        end
    end
    return cheapest, cheapestStats
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
--   costToMake, costSource ("saved" | "estimate"), vendorSell, disenchant,
--   marketValue, marketSource,
--   ceiling, ceilingBase ("value" | "cost" | "lowvalue" | "market" | "pastmarket" | "sale" | "rule"), multiplier,
--   pastExpansion, pricesLoading (estimate asked for mat data), checkPrice,
--   valueAtFloor, needsRecipe ("ours" | "seed"),
--   lastSale, lastSaleSource, confidence ("confident" | "uncertain"),
--   valuePrice (confident value, between floor and max), ruleCap,
--   ruleCapFrom ({ itemID, quality, price } of the better item behind ruleCap), stackSize,
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
        loadingRequested = false
        bounds.costToMake, bounds.costSource = CostToMake(configKey, itemID, candidate.itemName)
        bounds.pricesLoading = (not bounds.costToMake and loadingRequested) or nil
        bounds.pastExpansion = IsPastExpansion(itemLink, itemID) or nil
        bounds.vendorSell = VendorSellPrice(itemLink, itemID)
        bounds.disenchant = DisenchantValue(itemLink)
        local unadjusted, marketResult
        bounds.marketValue, bounds.marketSource, unadjusted, marketResult = UnitValue({ itemID = itemID, itemLink = itemLink, configKey = configKey })
        if marketResult then
            marketResult.configKey = marketResult.configKey or configKey
            bounds.confidence, bounds.confidenceReason = Confidence(marketResult)
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
        -- ruleCapFrom (2026-11-07): the better item that set that cap, for the
        -- post window's single "Capped by" line. Equal caps count, so a value
        -- lowered by the cap (ruleCap above) still names the item.
        local ladderCap = marketResult and tonumber(marketResult.ladderCap)
        if ladderCap and ladderCap > 0 and (not bounds.ruleCap or ladderCap <= bounds.ruleCap) then
            bounds.ruleCap = ladderCap
            bounds.ruleCapFrom = marketResult.ladderCapFrom
        end
        bounds.lastSale, bounds.lastSaleSource = LastSalePrice(configKey, itemID)
        bounds.groupPrice, bounds.groupStats = SameGroupListing(itemLink, itemID)
        bounds.stackSize = StackSize(itemLink, itemID)

        -- Craftable (anyone can make it: shipped recipe seed or this
        -- account's professions) but no Cost to Make, saved or estimated: no
        -- floor at all, never fall back to vendor / disenchant (Brian,
        -- 2026-11-06: 50g pickaxe floored at 3.55g vendor +10%; a bought
        -- crafted item still has a replacement cost). needsRecipe = "ours"
        -- (open the recipe) | "seed" (mats not priced yet). The evaluator
        -- skips the row.
        if not bounds.costToMake then
            local seed = PocketCFO and PocketCFO.RecipeSeed
            local okCraftable, craftable = pcall(function()
                return seed and seed:IsCraftable(itemID, candidate.itemName)
            end)
            if okCraftable and craftable then
                local okOurs, ours = pcall(seed.IsOurs, seed, itemID, candidate.itemName)
                bounds.needsRecipe = (okOurs and ours) and "ours" or "seed"
            end
        end

        local base, source = nil, nil
        for _, pair in ipairs(bounds.needsRecipe and {} or {
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

        -- Max price (stage 2, Brian 2026-11-06). Fix the value, don't
        -- multiply it: a value we trust IS the max.
        --   1. Confident market value -> the value.            ("value")
        --   2. Not confident:
        --      a. current-expansion crafted -> Cost to Make x curve: anyone
        --         can level a crafter, so cost holds the price down. ("cost")
        --      b. everything else (past-expansion crafted, drops, mats,
        --         transmog) -> market value, few listings or not; few people
        --         go back to craft old items (50g pickaxe sells at ~4,000g).
        --         ("pastmarket" for past-expansion crafted, else "market")
        --   3. (later) scan history, through Valuation's market value.
        --   4. 2x our last sale, only when there's no value at all. ("sale")
        --   5. No max = not posted (Your call).
        -- Replaced 2026-11-04's order (2x last sale first, market value x
        -- curve for drops): a single 400g sale capped a tool valued 1,285g.
        local ceiling, ceilingKind = nil, nil
        local currentCraft = bounds.costToMake and not bounds.pastExpansion
        if bounds.marketValue and bounds.confidence == "confident" then
            bounds.multiplier = 1
            ceiling, ceilingKind = bounds.marketValue, "value"
        elseif currentCraft then
            bounds.multiplier = self:CurveMultiplier(bounds.costToMake)
            ceiling, ceilingKind = bounds.costToMake * (bounds.multiplier or MIN_MULT), "cost"
            -- Never below a value we only threw out for being too LOW
            -- (Brian, 2026-11-06: Chef's Bright Linen Cooking Chapeau, value
            -- 357g rejected as far below a clown-polluted history, then
            -- cost x curve gave 112g, lower than the price we called too
            -- low). Values far ABOVE usual may be clowns and don't count.
            if bounds.confidenceReason == "farBelowUsual" and bounds.marketValue
                and bounds.marketValue > ceiling then
                bounds.multiplier = 1
                ceiling, ceilingKind = bounds.marketValue, "lowvalue"
            end
        elseif bounds.marketValue then
            bounds.multiplier = 1
            ceiling, ceilingKind = bounds.marketValue, (bounds.costToMake and bounds.pastExpansion) and "pastmarket" or "market"
        elseif bounds.lastSale then
            bounds.multiplier = SALE_MULTIPLIER
            ceiling, ceilingKind = bounds.lastSale * SALE_MULTIPLIER, "sale"
        end
        if ceiling then
            bounds.ceilingBase = ceilingKind
            bounds.ceiling = SilverDown(ceiling)
            if bounds.floor and bounds.ceiling < bounds.floor then
                bounds.ceiling = bounds.floor
                -- The max was under the lowest we'd post and got raised to
                -- it: label it that way, not by what it started from
                -- (Brian, 2026-11-07).
                bounds.ceilingAtFloor = true
            end
        end
        if bounds.ruleCap then
            local capped = math.max(SilverDown(bounds.ruleCap), bounds.floor or 0)
            if not bounds.ceiling or capped < bounds.ceiling then
                bounds.ceiling = capped
                bounds.ceilingBase = "rule"
                ceilingKind = "rule"
                bounds.ceilingAtFloor = (bounds.floor and SilverDown(bounds.ruleCap) < bounds.floor) or nil
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
        -- Value from few listings: still a price, but the player checks it
        -- ("Check the price" group, Brian 2026-11-06). Same floor / max.
        -- valueAtFloor = the value was below the floor, so this is the floor.
        elseif bounds.marketValue then
            local value = SilverDown(bounds.marketValue)
            local price = math.max(value, bounds.floor or 0)
            if bounds.ceiling then
                price = math.min(price, bounds.ceiling)
            end
            if price > 0 then
                bounds.checkPrice = price
                bounds.valueAtFloor = (bounds.floor and value < bounds.floor) and true or nil
            end
        end
    end)
    if not ok and PocketCFO and PocketCFO.AppendSessionLog then
        PocketCFO:AppendSessionLog("[MCG] SmartPricing: GetBounds failed err=" .. tostring(err))
    end
    return bounds
end

-- ---------------------------------------------------------------------------
-- Load mat data before the list is built (Brian, 2026-11-06: after /reload
-- almost every craftable row came back "Loading prices..."). Asks the
-- client for every not-yet-loaded mat of every craftable item in the bags.
-- Called when the AH opens and before Post Auctions builds its list; the
-- controller waits until IsPrewarming() is false or 5 seconds pass.
-- ---------------------------------------------------------------------------

local prewarmPending = {}

local function IsCached(itemID)
    if not (C_Item and type(C_Item.IsItemDataCachedByID) == "function") then
        return true
    end
    local ok, cached = pcall(C_Item.IsItemDataCachedByID, itemID)
    return not ok or cached == true
end

-- Returns true when something is still loading.
function SmartPricing:PrewarmMats()
    local seed = PocketCFO and PocketCFO.RecipeSeed
    if not seed or not C_Container or type(C_Container.GetContainerItemID) ~= "function"
        or not C_TradeSkillUI or type(C_TradeSkillUI.GetRecipeSchematic) ~= "function" then
        return false
    end
    local basicType = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
    local lastBag = tonumber(NUM_TOTAL_EQUIPPED_BAG_SLOTS) or 5
    local seen = {}
    pcall(function()
        for bag = 0, lastBag do
            local slots = tonumber(C_Container.GetContainerNumSlots(bag)) or 0
            for slot = 1, slots do
                local itemID = C_Container.GetContainerItemID(bag, slot)
                if itemID and not seen[itemID] then
                    seen[itemID] = true
                    for _, recipeID in ipairs(seed:GetRecipeIDsForOutput(itemID) or {}) do
                        local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
                        local slotsList = ok and type(schematic) == "table" and schematic.reagentSlotSchematics or {}
                        for _, reagentSlot in ipairs(slotsList) do
                            if reagentSlot.reagentType == basicType and reagentSlot.required ~= false then
                                for _, reagent in ipairs(type(reagentSlot.reagents) == "table" and reagentSlot.reagents or {}) do
                                    local matID = tonumber(reagent.itemID)
                                    if matID and not IsCached(matID) then
                                        prewarmPending[matID] = true
                                        if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
                                            pcall(C_Item.RequestLoadItemDataByID, matID)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end)
    return self:IsPrewarming()
end

function SmartPricing:IsPrewarming()
    for matID in pairs(prewarmPending) do
        if IsCached(matID) then
            prewarmPending[matID] = nil
        end
    end
    return next(prewarmPending) ~= nil
end

-- Start loading as soon as the AH opens (PocketCFO_AH loads on AH open, so
-- also once now), well before the player clicks Post Auctions.
do
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("AUCTION_HOUSE_SHOW")
    frame:SetScript("OnEvent", function()
        if SmartPricing:IsSmartView() then
            pcall(SmartPricing.PrewarmMats, SmartPricing)
        end
    end)
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if SmartPricing:IsSmartView() then
                pcall(SmartPricing.PrewarmMats, SmartPricing)
            end
        end)
    end
end

SmartPricing.DEFAULT_DURATION = DEFAULT_DURATION
SmartPricing.SilverUp = SilverUp
SmartPricing.FLOOR_MARKUP = FLOOR_MARKUP
