-- PocketCFO_Valuation/Modules/SearchRefresh.lua
-- Passive pricing refresh from Auction House search result events.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local SearchRefresh = PocketCFO_Valuation:NewModule("SearchRefresh", "AceEvent-3.0")

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function PackCall(fn, ...)
    if type(fn) ~= "function" then
        return false, { "unavailable" }
    end

    local returns = { pcall(fn, ...) }
    local ok = table.remove(returns, 1)
    if not ok then
        return false, returns
    end
    return true, returns
end

local function GetItemIDFromLink(itemLink)
    if not itemLink then
        return nil
    end
    if GetItemInfoFromHyperlink then
        local ok, itemID = pcall(GetItemInfoFromHyperlink, itemLink)
        if ok and itemID then
            return tonumber(itemID)
        end
    end
    return tonumber(tostring(itemLink):match("item:(%d+)"))
end

local function ExtractItemKey(row, fallbackItemKey)
    if type(row) ~= "table" then
        return fallbackItemKey
    end
    return row.itemKey or row.key or row.itemKeyInfo or fallbackItemKey
end

local function ExtractItemID(row, fallbackItemID, fallbackItemKey)
    if type(row) == "table" then
        return tonumber(row.itemID or row.itemId or row.id)
            or GetItemIDFromLink(row.itemLink or row.link)
            or tonumber(row.itemKey and row.itemKey.itemID)
            or tonumber(row.key and row.key.itemID)
    end
    return tonumber(fallbackItemID) or tonumber(fallbackItemKey and fallbackItemKey.itemID)
end

local function GetQuantity(row)
    local rawQuantity
    if type(row) == "table" then
        rawQuantity = row.quantity or row.stackSize or row.count or row.totalQuantity
    end
    local quantity = tonumber(rawQuantity) or 1
    if quantity < 1 then
        return 0
    end
    return math.floor(quantity)
end

local function GetUnitPrice(row)
    if type(row) ~= "table" then
        return nil
    end

    local unitPrice = tonumber(row.unitPrice or row.pricePerUnit or row.minPrice or row.price)
    if unitPrice then
        return unitPrice
    end

    local buyout = tonumber(row.buyoutAmount or row.buyout or row.buyoutPrice)
    local quantity = GetQuantity(row)
    if buyout and quantity > 1 then
        return buyout / quantity
    end
    return buyout
end

local function GetBuyout(row)
    if type(row) ~= "table" then
        return nil
    end
    return tonumber(row.buyoutAmount or row.buyout or row.buyoutPrice or row.minPrice or row.price or row.unitPrice)
end

local function BuildIdentity(row, fallbackItemID, fallbackItemKey)
    local identity = PocketCFO_Valuation:GetModule("PricingIdentity", true)
    if not identity then
        return nil
    end

    local itemLink = type(row) == "table" and (row.itemLink or row.link) or nil
    if itemLink then
        return identity:BuildFromItemLink(itemLink)
    end

    local itemID = ExtractItemID(row, fallbackItemID, fallbackItemKey)
    if itemID then
        return identity:BuildFromItemID(itemID)
    end
    return nil
end

local function AddObservation(buckets, identity, row)
    if not identity or not identity.marketKey then
        return false
    end

    local quantity = GetQuantity(row)
    if quantity <= 0 then
        return false
    end

    local marketKey = identity.marketKey
    local bucket = buckets[marketKey]
    if not bucket then
        bucket = {
            identity = identity,
            observations = {},
            isStackable = identity.isStackable == true,
        }
        buckets[marketKey] = bucket
    end

    if bucket.isStackable then
        local unitPrice = GetUnitPrice(row)
        if not unitPrice or unitPrice <= 0 then
            return false
        end
        bucket.observations[#bucket.observations + 1] = {
            quantity = quantity,
            unitPrice = unitPrice,
        }
    else
        local buyout = GetBuyout(row)
        if not buyout or buyout <= 0 then
            return false
        end
        bucket.observations[#bucket.observations + 1] = {
            quantity = 1,
            buyout = buyout,
            buyoutAmount = buyout,
        }
    end

    return true
end

-- Settings from matching ValuationRules "market" rules for this market,
-- or nil when none match (then pricing is unchanged from before rules).
local function GetMarketOptions(bucket)
    local rules = PocketCFO_Valuation:GetModule("ValuationRules", true)
    if not rules or not bucket then
        return nil
    end
    local ok, params, ruleIDs = pcall(rules.GetMarketParams, rules, bucket.identity)
    if not ok or not params then
        return nil
    end
    return { market = params, marketRuleIDs = ruleIDs }
end

local function BuildPricingRow(bucket, value, depthUsed, diagnostics)
    local identity = bucket and bucket.identity or {}
    return {
        itemID = identity.itemID,
        itemName = identity.itemName,
        qualityTier = identity.qualityTier,
        itemLevel = identity.itemLevel,
        statFingerprint = identity.statFingerprint,
        depthUsed = depthUsed,
        valuationDiagnostics = diagnostics,
        value = value,
        freshness = "fresh",
        timestamp = Now(),
        source = "search-refresh",
    }
end

function SearchRefresh:ApplyBuckets(buckets)
    local cache = PocketCFO_Valuation:GetModule("PricingCache", true)
    local valuation = PocketCFO_Valuation:GetModule("PricingValuation", true)
    if not cache or not valuation then
        return 0
    end

    local updated = 0
    local observed = 0
    for marketKey, bucket in pairs(buckets or {}) do
        observed = observed + 1
        local value, depthUsed, diagnostics
        if bucket.isStackable then
            value, depthUsed, diagnostics = valuation:CalculateStackableValue(bucket.observations, GetMarketOptions(bucket))
        else
            value, depthUsed = valuation:CalculateNonStackableValue(bucket.observations)
        end

        if value and cache:SetPricingRow(marketKey, BuildPricingRow(bucket, value, depthUsed, diagnostics)) then
            updated = updated + 1
        end
    end

    self.lastRefresh = {
        timestamp = Now(),
        marketsObserved = observed,
        marketsUpdated = updated,
    }
    return updated
end

function SearchRefresh:ProcessCommodityResults(itemID)
    itemID = tonumber(itemID)
    if not itemID or not C_AuctionHouse or type(C_AuctionHouse.GetNumCommoditySearchResults) ~= "function" then
        return 0
    end

    local ok, returns = PackCall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
    if not ok then
        return 0
    end

    local total = tonumber(returns[1]) or 0
    local buckets = {}
    for index = 1, total do
        local rowOk, rowReturns = PackCall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, index)
        local row = rowOk and rowReturns and rowReturns[1] or nil
        local identity = BuildIdentity(row, itemID, nil)
        AddObservation(buckets, identity, row)
    end

    return self:ApplyBuckets(buckets)
end

function SearchRefresh:ProcessItemResults(itemKey)
    if not itemKey or not C_AuctionHouse or type(C_AuctionHouse.GetNumItemSearchResults) ~= "function" then
        return 0
    end

    local ok, returns = PackCall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
    if not ok then
        return 0
    end

    local total = tonumber(returns[1]) or 0
    local buckets = {}
    for index = 1, total do
        local rowOk, rowReturns = PackCall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, index)
        local row = rowOk and rowReturns and rowReturns[1] or nil
        local observedItemKey = ExtractItemKey(row, itemKey)
        local identity = BuildIdentity(row, nil, observedItemKey)
        AddObservation(buckets, identity, row)
    end

    return self:ApplyBuckets(buckets)
end

function SearchRefresh:COMMODITY_SEARCH_RESULTS_UPDATED(_, itemID)
    self:ProcessCommodityResults(itemID)
end

function SearchRefresh:ITEM_SEARCH_RESULTS_UPDATED(_, itemKey)
    self:ProcessItemResults(itemKey)
end

function SearchRefresh:OnEnable()
    self:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
    self:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
end

function SearchRefresh:OnDisable()
    self:UnregisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
    self:UnregisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
end
