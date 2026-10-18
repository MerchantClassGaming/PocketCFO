-- PocketCFO_AH/Posting/Evaluation/PostingEvaluator.lua
-- Posting business decision engine. No AH lookup, matching, UI, or posting execution.

local PocketCFO_AH = _G.PocketCFO_AH

local PostingEvaluator = {}

local function NumberOrNil(value)
    value = tonumber(value)
    if value ~= nil then
        return value
    end
    return nil
end

local function PositiveQuantity(value)
    value = math.floor(tonumber(value) or 0)
    if value > 0 then
        return value
    end
    return 0
end

local function NormalizedProtectionPct(value)
    value = tonumber(value)
    if not value or value <= 0 then
        return nil
    end
    if value > 1 then
        return value / 100
    end
    return value
end

local function MarketProtectionThreshold(marketSettings)
    if type(marketSettings) ~= "table" then
        return nil
    end

    local marketValue = NumberOrNil(marketSettings.marketValue)
    local protectionPct = NormalizedProtectionPct(marketSettings.protectionPct)
    if not marketValue or marketValue <= 0 or not protectionPct then
        return nil
    end

    return marketValue * protectionPct
end

local function BuildResult(shouldPost, price, toPost, status, note, lowestAuction, ownedLowestQuantity, debug)
    return {
        shouldPost = shouldPost == true,
        price = price,
        toPost = PositiveQuantity(toPost),
        status = status,
        note = note,
        lowestAuction = lowestAuction,
        ownedLowestQuantity = PositiveQuantity(ownedLowestQuantity),
        ownedNextBuyCoverage = PositiveQuantity(debug and debug.ownedNextBuyCoverage),
        remainingToPost = PositiveQuantity(toPost),
        debug = debug,
    }
end

local function ReadyAtMaxPrice(maxPrice, toPost, note, debug)
    if toPost <= 0 then
        return BuildResult(false, nil, 0, "Skipped", "Skipped: no bag quantity available.", nil, 0, debug)
    end

    return BuildResult(true, maxPrice, toPost, "Ready", note, nil, 0, debug)
end

local function BuildCheapestDebug(entries, limit)
    local cheapest = {}
    limit = tonumber(limit) or 5
    for index = 1, math.min(#entries, limit) do
        local entry = entries[index]
        local auction = entry.auction
        cheapest[#cheapest + 1] = {
            price = entry.price,
            quantity = entry.quantity,
            owned = entry.owned,
            auctionID = entry.auctionID,
            itemID = entry.itemID or auction and auction.itemID,
            itemLevel = auction and (auction.ilvl or auction.itemLevel),
            craftingQuality = auction and (auction.craftingQuality or auction.qualityTier or auction.itemQuality),
            statFingerprint = auction and auction.statFingerprint,
        }
    end
    return cheapest
end

local function LadderEntries(ladderResult)
    local entries = {}
    for index, ladderRow in ipairs(ladderResult and ladderResult.ladder or {}) do
        local price = NumberOrNil(ladderRow.price)
        if price and price > 0 then
            entries[#entries + 1] = {
                auction = ladderRow.auction,
                auctionID = ladderRow.auctionID,
                price = price,
                quantity = PositiveQuantity(ladderRow.quantity),
                owned = ladderRow.owned == true,
                originalIndex = ladderRow.position or index,
                itemID = ladderRow.itemID,
            }
        end
    end
    return entries
end

local function CalculateOwnedNextBuyCoverage(entries, competitionPrice)
    local coverage = 0
    local coverageRows = {}
    local started = false

    for _, entry in ipairs(entries or {}) do
        if entry.price == competitionPrice then
            started = true
            coverageRows[#coverageRows + 1] = {
                index = #coverageRows + 1,
                owned = entry.owned == true,
                auctionID = entry.auctionID,
                price = entry.price,
                quantity = entry.quantity,
            }

            if entry.owned then
                coverage = coverage + entry.quantity
            else
                break
            end
        elseif started then
            break
        end
    end

    return coverage, coverageRows
end

function PostingEvaluator:Evaluate(row, matchedAuctions, marketSettings, evaluationContext)
    row = type(row) == "table" and row or {}
    evaluationContext = type(evaluationContext) == "table" and evaluationContext or {}
    local ladderResult = evaluationContext.marketLadder or evaluationContext.ladderResult

    local rule = type(row.resolvedRule) == "table" and row.resolvedRule or {}
    local maxToPost = PositiveQuantity(rule.maxToPost or rule.targetPosted)
    local inBags = PositiveQuantity(row.inBags or row.bagQuantity or row.quantity)
    local minPrice = NumberOrNil(rule.minPrice) or 0
    local maxPrice = NumberOrNil(rule.maxPrice)
    local desiredPostQuantity = math.min(maxToPost, inBags)
    local isVariant = row.target and row.target.meaningfulVariant == true
    local debug = {
        rawMatchCount = #(type(matchedAuctions) == "table" and matchedAuctions or {}),
        ladderCount = #(ladderResult and ladderResult.ladder or {}),
        validAuctionCount = 0,
        protectionThreshold = nil,
        selectedCompetitionPrice = nil,
        evaluationMode = isVariant and "variant-lowest-identical" or "nonvariant-bait-protected",
        baitFilteringApplied = not isVariant,
        cheapestMatchedAuctions = {},
        ignoredBaitAuctionCount = 0,
    }

    if maxToPost <= 0 then
        return BuildResult(false, nil, 0, "Skipped", "Skipped: Max To Post is zero.", nil, 0, debug)
    end

    local protectionThreshold = MarketProtectionThreshold(marketSettings)
    debug.protectionThreshold = protectionThreshold
    if isVariant then
        debug.protectionThreshold = nil
    end
    debug.marketProtectionThreshold = protectionThreshold
    local validAuctions = {}
    local pricedAuctions = LadderEntries(ladderResult)

    for _, entry in ipairs(pricedAuctions) do
        if isVariant or not protectionThreshold or entry.price >= protectionThreshold then
            validAuctions[#validAuctions + 1] = entry
        else
            debug.ignoredBaitAuctionCount = debug.ignoredBaitAuctionCount + 1
        end
    end
    debug.pricedAuctionCount = #pricedAuctions
    debug.cheapestMatchedAuctions = BuildCheapestDebug(pricedAuctions, isVariant and 1 or 5)
    debug.validAuctionCount = #validAuctions

    if #validAuctions == 0 then
        debug.maxToPost = maxToPost
        debug.ownedLowestQuantity = 0
        debug.ownedNextBuyCoverage = 0
        debug.remainingToPost = desiredPostQuantity
        debug.coverageRows = {}
        return ReadyAtMaxPrice(
            maxPrice,
            desiredPostQuantity,
            "Posting at Max Price because no valid auctions exist.",
            debug
        )
    end

    local lowestPrice = validAuctions[1].price
    debug.selectedCompetitionPrice = lowestPrice

    local lowestAuction = nil

    for _, entry in ipairs(validAuctions) do
        if entry.price == lowestPrice then
            lowestAuction = lowestAuction or entry.auction
        end
    end

    local ownedNextBuyCoverage = 0
    local coverageRows = {}
    ownedNextBuyCoverage, coverageRows = CalculateOwnedNextBuyCoverage(validAuctions, lowestPrice)
    local remainingToPost = math.min(math.max(0, maxToPost - ownedNextBuyCoverage), inBags)
    debug.ownedLowestQuantity = ownedNextBuyCoverage
    debug.ownedNextBuyCoverage = ownedNextBuyCoverage
    debug.remainingToPost = remainingToPost
    debug.coverageRows = coverageRows
    debug.maxToPost = maxToPost

    if ownedNextBuyCoverage >= maxToPost then
        return BuildResult(
            false,
            nil,
            0,
            "Skipped",
            "Skipped: already covered at current lowest price.",
            lowestAuction,
            ownedNextBuyCoverage,
            debug
        )
    end

    if lowestPrice < minPrice then
        return BuildResult(
            false,
            nil,
            0,
            "Skipped",
            "Skipped: lowest valid auction below Min Price.",
            lowestAuction,
            ownedNextBuyCoverage,
            debug
        )
    end

    if maxPrice and lowestPrice > maxPrice then
        if remainingToPost <= 0 then
            return BuildResult(false, nil, 0, "Skipped", "Skipped: no bag quantity available.", lowestAuction, ownedNextBuyCoverage, debug)
        end

        return BuildResult(
            true,
            maxPrice,
            remainingToPost,
            "Ready",
            "Post at Max Price as lowest valid auction is above max",
            lowestAuction,
            ownedNextBuyCoverage,
            debug
        )
    end

    if remainingToPost <= 0 then
        return BuildResult(false, nil, 0, "Skipped", "Skipped: no bag quantity available.", lowestAuction, ownedNextBuyCoverage, debug)
    end

    return BuildResult(
        true,
        lowestPrice,
        remainingToPost,
        "Ready",
        "Posting at current lowest price.",
        lowestAuction,
        ownedNextBuyCoverage,
        debug
    )
end

if PocketCFO_AH then
    PocketCFO_AH.PostingEvaluator = PostingEvaluator
end

_G.PostingEvaluator = PostingEvaluator
