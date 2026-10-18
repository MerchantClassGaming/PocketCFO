-- PocketCFO_Valuation/Modules/PricingValuation.lua
-- Pure pricing valuation calculations. No auction house scanning happens here.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local PricingValuation = PocketCFO_Valuation:NewModule("PricingValuation")

local DEFAULT_STACKABLE_DEPTH = 200

-- Market-representativeness tuning. See PocketCFO_Valuation CLAUDE.md /
-- ValuationService design notes: these strip non-representative low-price
-- outliers (bait/fire-sale/mistake postings) and high-price "clown" walls
-- before the quantity-weighted median is computed, without changing the
-- existing per-rarity quantity targets (GetStackableDepthThreshold).
local LOW_PRICE_OUTLIER_MULTIPLIER = 3.0
local LOW_PRICE_OUTLIER_QUANTITY_THRESHOLD = 2
local UPPER_MARKET_MULTIPLIER = 3.0

local function NormalizeObservations(observations)
    if type(observations) ~= "table" then
        return {}
    end

    local rows = {}
    for _, row in pairs(observations) do
        if type(row) == "table" then
            rows[#rows + 1] = row
        end
    end
    return rows
end

local function NormalizeQuantity(row)
    local quantity = tonumber(row.quantity)
        or tonumber(row.stackSize)
        or tonumber(row.count)
        or tonumber(row.totalQuantity)
        or 1

    if quantity < 1 then
        return 0
    end
    return math.floor(quantity)
end

local function NormalizeUnitPrice(row)
    local unitPrice = tonumber(row.unitPrice)
        or tonumber(row.pricePerUnit)
        or tonumber(row.copperValue)
        or tonumber(row.value)

    if unitPrice then
        return unitPrice
    end

    local buyout = tonumber(row.buyout)
        or tonumber(row.buyoutAmount)
        or tonumber(row.minPrice)
        or tonumber(row.price)

    if not buyout then
        return nil
    end

    local quantity = NormalizeQuantity(row)
    if quantity > 1 then
        return buyout / quantity
    end
    return buyout
end

local function NormalizeBuyout(row)
    return tonumber(row.buyout)
        or tonumber(row.buyoutAmount)
        or tonumber(row.minPrice)
        or tonumber(row.price)
        or tonumber(row.unitPrice)
        or tonumber(row.pricePerUnit)
        or tonumber(row.copperValue)
        or tonumber(row.value)
end

local function GetRarity(options, observations)
    if type(options) == "table" then
        local rarity = tonumber(options.rarity or options.itemRarity)
        if rarity then
            return rarity
        end
    else
        local rarity = tonumber(options)
        if rarity then
            return rarity
        end
    end

    if type(observations) == "table" then
        for _, row in pairs(observations) do
            if type(row) == "table" then
                local rarity = tonumber(row.rarity or row.itemRarity)
                if rarity then
                    return rarity
                end
            end
        end
    end

    return nil
end

local function GetStackableDepthThreshold(options, observations)
    local rarity = GetRarity(options, observations)
    if rarity == 3 then
        return 50
    end
    if rarity == 4 then
        return 10
    end
    return DEFAULT_STACKABLE_DEPTH
end

-- Groups price-sorted individual auction observations into price buckets
-- (one bucket per distinct copper price). Rounds to the nearest copper so
-- floating-point division noise from buyout/quantity splits doesn't split
-- what is really one listed price into multiple buckets.
local function BuildPriceBuckets(pricedRows)
    local buckets = {}
    for _, row in ipairs(pricedRows) do
        local price = math.floor(row.unitPrice + 0.5)
        local last = buckets[#buckets]
        if last and last.price == price then
            last.quantity = last.quantity + row.quantity
        else
            buckets[#buckets + 1] = { price = price, quantity = row.quantity }
        end
    end
    return buckets
end

-- Phase 2: strips leading low-price buckets that are not representative of
-- the market (bait, fire-sale, accidental, or mistake postings) rather than
-- attempting to detect intent. A bucket is discarded only when the very next
-- bucket's price is more than lowPriceOutlierMultiplier times its price AND
-- its own quantity is at or under lowPriceOutlierQuantityThreshold. Repeats
-- against the next pair until a bucket survives. Returns the index of the
-- first surviving bucket and the list of rejected buckets (with reason).
local function RejectLowPriceOutliers(buckets, market)
    local multiplier = tonumber(market and market.lowOutlierMultiplier) or LOW_PRICE_OUTLIER_MULTIPLIER
    local maxQuantity = tonumber(market and market.lowOutlierMaxQuantity) or LOW_PRICE_OUTLIER_QUANTITY_THRESHOLD
    local rejected = {}
    local startIndex = 1
    while startIndex < #buckets do
        local first = buckets[startIndex]
        local second = buckets[startIndex + 1]
        if second.price > (first.price * multiplier)
            and first.quantity <= maxQuantity then
            rejected[#rejected + 1] = { price = first.price, quantity = first.quantity, reason = "lowPriceOutlier" }
            startIndex = startIndex + 1
        else
            break
        end
    end
    return startIndex, rejected
end

-- Phase 3/4: the first surviving bucket becomes the market anchor. Buckets
-- are accepted while walking upward through the ladder as long as their
-- price stays within upperMarketMultiplier of the anchor. The first bucket
-- that exceeds the boundary ends the sample - everything from that bucket
-- onward (including further, even-higher buckets) is rejected, not skipped.
local function AcceptUpperMarketBuckets(buckets, startIndex, anchorPrice, market)
    local accepted = {}
    local rejected = {}
    local boundary = anchorPrice * (tonumber(market and market.upperMarketMultiplier) or UPPER_MARKET_MULTIPLIER)
    local boundaryExceeded = false
    for index = startIndex, #buckets do
        local bucket = buckets[index]
        if not boundaryExceeded and bucket.price <= boundary then
            accepted[#accepted + 1] = bucket
        else
            boundaryExceeded = true
            rejected[#rejected + 1] = { price = bucket.price, quantity = bucket.quantity, reason = "upperMarketBoundary" }
        end
    end
    return accepted, rejected
end

-- Phase 5: the existing per-rarity quantity target still caps the sample.
-- Whichever limit is hit first - the market boundary (already applied above)
-- or the quantity target - ends the sample, preserving today's behavior for
-- deep, healthy markets.
local function ApplyQuantityTarget(buckets, targetDepth)
    local trimmed = {}
    local remaining = targetDepth
    for _, bucket in ipairs(buckets) do
        if remaining <= 0 then
            break
        end
        local used = math.min(bucket.quantity, remaining)
        trimmed[#trimmed + 1] = { price = bucket.price, quantity = used }
        remaining = remaining - used
    end
    return trimmed
end

-- Phase 6: quantity-weighted median computed only from accepted buckets.
local function WeightedMedianPrice(buckets)
    local totalQuantity = 0
    for _, bucket in ipairs(buckets) do
        totalQuantity = totalQuantity + bucket.quantity
    end
    if totalQuantity <= 0 then
        return nil, 0
    end

    local target = math.ceil(totalQuantity / 2)
    local cumulative = 0
    for _, bucket in ipairs(buckets) do
        cumulative = cumulative + bucket.quantity
        if cumulative >= target then
            return bucket.price, totalQuantity
        end
    end
    return buckets[#buckets].price, totalQuantity
end

function PricingValuation:OnEnable()
end

function PricingValuation:OnDisable()
end

function PricingValuation.GetStackableDepthThreshold(selfOrOptions, maybeOptions, maybeObservations)
    local options = maybeOptions
    local observations = maybeObservations
    if selfOrOptions ~= PricingValuation then
        options = selfOrOptions
        observations = maybeOptions
    end
    return GetStackableDepthThreshold(options, observations)
end

function PricingValuation.CalculateStackableValue(selfOrObservations, maybeObservations, maybeOptions)
    local observations = maybeObservations
    local options = maybeOptions
    if selfOrObservations ~= PricingValuation then
        observations = selfOrObservations
        options = maybeObservations
    end

    local rows = NormalizeObservations(observations)
    local pricedRows = {}

    for _, row in ipairs(rows) do
        local quantity = NormalizeQuantity(row)
        local unitPrice = NormalizeUnitPrice(row)
        if quantity > 0 and unitPrice and unitPrice > 0 then
            pricedRows[#pricedRows + 1] = {
                unitPrice = unitPrice,
                quantity = quantity,
            }
        end
    end

    table.sort(pricedRows, function(a, b)
        return a.unitPrice < b.unitPrice
    end)

    local buckets = BuildPriceBuckets(pricedRows)
    if #buckets == 0 then
        return nil, 0, {
            anchorPrice = nil,
            acceptedBucketCount = 0,
            acceptedQuantity = 0,
            rejectedBucketCount = 0,
            rejectedQuantity = 0,
            rejectedBuckets = {},
        }
    end

    -- options.market: settings from matching ValuationRules "market" rules
    -- (see ValuationRules.lua / ValuationRuleSet.lua). Any setting a rule
    -- doesn't name falls back to the constants above, so with no market
    -- rules this prices exactly as before.
    local market = type(options) == "table" and type(options.market) == "table" and options.market or nil

    local anchorIndex, lowRejected = RejectLowPriceOutliers(buckets, market)
    local anchorPrice = buckets[anchorIndex].price

    local upperAccepted, upperRejected = AcceptUpperMarketBuckets(buckets, anchorIndex, anchorPrice, market)

    local targetDepth = tonumber(market and market.depth) or GetStackableDepthThreshold(options, observations)
    local acceptedBuckets = ApplyQuantityTarget(upperAccepted, targetDepth)

    local value, depthUsed = WeightedMedianPrice(acceptedBuckets)

    local rejectedBuckets = {}
    local rejectedQuantity = 0
    for _, bucket in ipairs(lowRejected) do
        rejectedBuckets[#rejectedBuckets + 1] = bucket
        rejectedQuantity = rejectedQuantity + bucket.quantity
    end
    for _, bucket in ipairs(upperRejected) do
        rejectedBuckets[#rejectedBuckets + 1] = bucket
        rejectedQuantity = rejectedQuantity + bucket.quantity
    end

    local diagnostics = {
        anchorPrice = anchorPrice,
        acceptedBucketCount = #acceptedBuckets,
        acceptedQuantity = depthUsed or 0,
        rejectedBucketCount = #rejectedBuckets,
        rejectedQuantity = rejectedQuantity,
        rejectedBuckets = rejectedBuckets,
        targetDepth = targetDepth,
        marketRuleIDs = type(options) == "table" and options.marketRuleIDs or nil,
    }

    if not value or (depthUsed or 0) <= 0 then
        return nil, 0, diagnostics
    end

    return value, depthUsed, diagnostics
end

function PricingValuation.CalculateNonStackableValue(selfOrObservations, maybeObservations)
    local observations = maybeObservations
    if selfOrObservations ~= PricingValuation then
        observations = selfOrObservations
    end

    local rows = NormalizeObservations(observations)
    local lowestBuyout

    for _, row in ipairs(rows) do
        local buyout = NormalizeBuyout(row)
        if buyout and buyout > 0 and (not lowestBuyout or buyout < lowestBuyout) then
            lowestBuyout = buyout
        end
    end

    if not lowestBuyout then
        return nil, 0
    end

    return lowestBuyout, 1
end
