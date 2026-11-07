-- PocketCFO_AH/Posting/Evaluation/PostingEvaluator.lua
-- Posting business decision engine. No AH lookup, matching, UI, or posting execution.

local PocketCFO_AH = _G.PocketCFO_AH

local PostingEvaluator = {}

-- Smart view: a cheapest listing up to this much above the max is matched,
-- not undercut (Brian, 2026-11-07).
local NEAR_MAX_MATCH = 1.10

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

-- ---------------------------------------------------------------------------
-- Smart AH view (design: claude/AH_Smart_Posting_Design.md). Price = match
-- the lowest real competitor, never below the floor (skip instead), never
-- above the ceiling. Everything offered is posted: owned auctions already at
-- the lowest price don't reduce it (FIFO puts ours behind them). The rules
-- view below is unchanged.
-- ---------------------------------------------------------------------------

local GEAR_GAP_PCT = 0.50

local function Gold(copper)
    copper = tonumber(copper)
    if not copper then
        return "?"
    end
    -- Two biggest coins (core PocketCFO:FormatMoney, 2026-11-05).
    return _G.PocketCFO:FormatMoney(copper)
end

local function BelowFloorNote(bounds)
    local source = bounds and bounds.floorSource
    if source == "disenchant" then
        return "Worth more disenchanted."
    elseif source == "vendor" then
        return "Lowest price is below vendor price."
    end
    return "Lowest price is below what it costs to make."
end

-- Gear: a listing far below the next one up (or far below market value) is
-- a deal to buy, not a price to match. Ignores cheap listings from the
-- bottom while they're under 50% of the next listing or of market value.
-- Our own listings always count.
-- capPrice: the most this item can be worth next to its better versions
-- (bounds.ruleCap). A listing near it is real even if the next listing up
-- is overpriced (Brian, 2026-11-04: 350g green rod next to a 2,547g one,
-- blues at 738g).
-- goodPrice: a listing at or above it is real competition even when it looks
-- like a deal (Brian, 2026-11-04: 550g rod that costs 162g to make; others
-- at 2,900g). 2x cost to make, the lowest the max curve ever goes.
local function DropCheapGearListings(entries, marketValue, capPrice, goodPrice)
    local start = 1
    local ignoredPrice = nil
    local keptForCost = false
    while start <= #entries do
        local entry = entries[start]
        if entry.owned then
            break
        end
        local nextEntry = entries[start + 1]
        local reference = nextEntry and nextEntry.price
        if reference and capPrice and capPrice > 0 and capPrice < reference then
            reference = capPrice
        end
        local belowNext = reference and entry.price < reference * GEAR_GAP_PCT
        local belowMarket = marketValue and marketValue > 0 and entry.price < marketValue * GEAR_GAP_PCT
        if not (belowNext or belowMarket) then
            break
        end
        if goodPrice and entry.price >= goodPrice then
            keptForCost = true
            break
        end
        ignoredPrice = ignoredPrice or entry.price
        start = start + 1
    end
    local kept = {}
    for index = start, #entries do
        kept[#kept + 1] = entries[index]
    end
    return kept, ignoredPrice, start - 1, keptForCost
end

local function EvaluateSmart(row, rule, ladderResult, marketSettings, evaluationContext)
    local bounds = type(rule.bounds) == "table" and rule.bounds or {}
    local floor = NumberOrNil(rule.minPrice)
    if floor and floor <= 0 then
        floor = nil
    end
    local ceiling = NumberOrNil(rule.maxPrice)
    local inBags = PositiveQuantity(row.inBags or row.bagQuantity or row.quantity)
    -- Usually Post (Brian, 2026-11-04): how many the player wants up at once,
    -- saved per item; default one stack (1 for anything that doesn't stack).
    -- Post Now = Usually Post minus ours already selling next, never more
    -- than is offered. The Post Now cell changes it for this post only.
    local stackSize = PositiveQuantity(bounds.stackSize)
    local usuallyPost = PositiveQuantity(bounds.usuallyPost)
    if usuallyPost <= 0 then
        usuallyPost = stackSize > 0 and stackSize or 1
    end
    local defaultQuantity = math.min(inBags, usuallyPost)
    local postQuantity = defaultQuantity
    local isVariant = row.target and row.target.meaningfulVariant == true
    local marketValue = NumberOrNil(marketSettings and marketSettings.marketValue)
    local debug = {
        smart = true,
        floor = floor,
        floorSource = bounds.floorSource,
        ceiling = ceiling,
        ceilingBase = bounds.ceilingBase,
        marketValue = marketValue,
        lastSale = bounds.lastSale,
        ladderCount = #(ladderResult and ladderResult.ladder or {}),
        maxToPost = usuallyPost,
        remainingToPost = defaultQuantity,
        usuallyPost = usuallyPost,
        ownedNextBuyCoverage = 0,
        evaluationMode = isVariant and "smart-gear-gap" or "smart-bait-protected",
    }

    local function Result(shouldPost, price, note, lowestAuction)
        local result = BuildResult(shouldPost, price, shouldPost and postQuantity or 0,
            shouldPost and "Ready" or "Skipped", note, lowestAuction, 0, debug)
        -- Skipped rows show these in the Price / Qty cells as starting values.
        result.suggestedPrice = (not shouldPost) and floor or nil
        result.suggestedQuantity = (not shouldPost) and defaultQuantity or nil
        return result
    end

    if inBags <= 0 then
        return Result(false, nil, "Skipped: none left to post.")
    end

    -- Craftable but no Cost to Make yet (SmartPricing bounds.needsRecipe):
    -- no safe lowest price, so don't post (Brian, 2026-11-06). "Needs Price"
    -- keeps it bright and on top; typing a price still posts it.
    -- "ours": one of our characters can open the recipe. "seed": craftable,
    -- but a mat has no price yet (often loads by the next Refresh).
    if bounds.needsRecipe then
        -- pricesLoading: a mat's item data was just requested; the controller
        -- re-checks once by itself (2026-11-06).
        local note = bounds.needsRecipe == "ours" and "Open the recipe once, then Refresh."
            or "Can't price its materials yet. Refresh, or type a price."
        -- After its one automatic re-check (row.loadingRetried) a row that
        -- still can't load says what to do instead.
        if bounds.pricesLoading and not row.loadingRetried then
            note = "Loading prices..."
        elseif bounds.pricesLoading then
            note = "Prices didn't load. Refresh, or type a price."
        end
        local result = Result(false, nil, note)
        result.suggestedPrice = nil
        result.status = "Needs Price"
        return result
    end

    local entries = LadderEntries(ladderResult)
    debug.pricedAuctionCount = #entries
    debug.cheapestMatchedAuctions = BuildCheapestDebug(entries, 5)

    -- The AH search didn't finish (timed out, usually when many searches run
    -- back to back) and returned nothing: we don't know who's listing, so
    -- never price it as "No other listings" (Brian, 2026-11-06: a Hide
    -- Seeker's Pack listed at 3,957g was missed and the row posted at 2x
    -- our last sale). The controller re-checks the row once by itself.
    local context = type(evaluationContext) == "table" and evaluationContext or {}
    if context.lookupIncomplete and #entries == 0 then
        local note = row.searchRetried and "Couldn't check the AH. Refresh to try again."
            or "Couldn't check the AH yet. Checking again..."
        local result = Result(false, nil, note)
        result.suggestedPrice = nil
        result.status = "Needs Price"
        result.searchIncomplete = true
        return result
    end

    local validAuctions, ignoredPrice, keptForCost
    if isVariant then
        local costToMake = NumberOrNil(bounds.costToMake)
        local goodPrice = costToMake and costToMake > 0 and costToMake * 2 or nil
        validAuctions, ignoredPrice, debug.ignoredBaitAuctionCount, keptForCost = DropCheapGearListings(entries, marketValue,
            NumberOrNil(bounds.ruleCap), goodPrice)
        debug.keptForCost = keptForCost
    else
        local threshold = MarketProtectionThreshold(marketSettings)
        debug.protectionThreshold = threshold
        validAuctions = {}
        debug.ignoredBaitAuctionCount = 0
        for _, entry in ipairs(entries) do
            if entry.owned or not threshold or entry.price >= threshold then
                validAuctions[#validAuctions + 1] = entry
            else
                debug.ignoredBaitAuctionCount = debug.ignoredBaitAuctionCount + 1
            end
        end
    end
    debug.validAuctionCount = #validAuctions
    -- "Worth buying?" only below cost to make (Brian, 2026-11-04): above it,
    -- the seller can just craft another and relist, so buying never pays.
    local dealNote = ""
    if ignoredPrice then
        local costToMake = NumberOrNil(bounds.costToMake)
        if costToMake and costToMake > 0 and ignoredPrice >= costToMake then
            dealNote = " Ignored one far below the rest (" .. Gold(ignoredPrice) .. ")."
        else
            dealNote = " One listed far below market (" .. Gold(ignoredPrice) .. "). Worth buying?"
        end
    end

    if #validAuctions == 0 then
        -- Nobody else listing (Brian, 2026-11-04): price from evidence only.
        -- A value we're confident in -> Ready. Prices we picked ourselves
        -- (2x our last sale, a value from few listings) -> Ready with
        -- check = true: the "Check the price" group (Brian, 2026-11-06).
        -- Nothing to go on -> Needs Price.
        -- First: a listing with a similar stat (same stat group, same
        -- quality and item level; SmartPricing bounds.groupPrice) is what a
        -- buyer compares with, so match it (Brian, 2026-11-06). Below the
        -- floor it's ignored (never a reason to skip), above the max it's
        -- the max. Check the price.
        local groupPrice = NumberOrNil(bounds.groupPrice)
        if groupPrice and groupPrice > 0 and not (floor and groupPrice < floor) then
            local price, note = groupPrice, "No other listings for this stat. Matched a similar stat (" .. Gold(groupPrice) .. ")."
            if ceiling and ceiling > 0 and groupPrice > ceiling then
                price = ceiling
                note = "No other listings for this stat. A similar stat is listed higher (" .. Gold(groupPrice) .. "). Priced at the max."
            end
            local result = Result(true, price, note .. dealNote)
            result.check = true
            return result
        end
        if bounds.ceilingBase == "sale" and ceiling and ceiling > 0 then
            local result = Result(true, ceiling, "No other listings. 2x your last sale." .. dealNote)
            result.check = true
            return result
        end
        local valuePrice = NumberOrNil(bounds.valuePrice)
        if valuePrice and valuePrice > 0 then
            local why = bounds.ceilingBase == "rule" and "Priced below the better version." or "Priced at its value."
            if bounds.ceilingAtFloor then
                why = "Its value is under the lowest we'd post, so priced there."
            end
            return Result(true, valuePrice, "No other listings. " .. why .. dealNote)
        end
        local checkPrice = NumberOrNil(bounds.checkPrice)
        if checkPrice and checkPrice > 0 then
            local note = bounds.valueAtFloor and "No other listings. Few listings seen, and the value is under the lowest we'd post, so priced there."
                or "No other listings. Based on few listings, check the price."
            local result = Result(true, checkPrice, note .. dealNote)
            result.check = true
            return result
        end
        -- No starting price here: the floor (vendor / cost) isn't a price
        -- suggestion when we know nothing about the market (Brian, 2026-11-04).
        local result = Result(false, nil, "Not enough price data. Type a price to post." .. dealNote)
        result.suggestedPrice = nil
        -- Not "Skipped": the player should act on it, so it stays bright and
        -- sorts above posted and skipped rows (Brian, 2026-11-04).
        result.status = "Needs Price"
        return result
    end

    local lowestPrice = validAuctions[1].price
    local lowestAuction = validAuctions[1].auction
    debug.selectedCompetitionPrice = lowestPrice
    if keptForCost then
        local times = lowestPrice / NumberOrNil(bounds.costToMake)
        dealNote = " Below other listings, but " .. string.format("%.1f", times):gsub("%.0$", "")
            .. "x cost." .. dealNote
    end

    -- Ours already selling next at the lowest price count toward Usually
    -- Post (Brian, 2026-11-04). Only those at the lowest price: undercut
    -- ones won't sell next (cancel and repost them). Once Usually Post is
    -- up: "Listed" (Probably not); typing Post Now adds more.
    local coverage = CalculateOwnedNextBuyCoverage(validAuctions, lowestPrice)
    debug.ownedNextBuyCoverage = coverage
    postQuantity = math.min(inBags, math.max(0, usuallyPost - coverage))
    debug.remainingToPost = postQuantity
    if coverage > 0 and postQuantity <= 0 then
        local result = Result(false, nil, "Yours sells next (" .. Gold(lowestPrice) .. "). Type in Post Now to add more." .. dealNote, lowestAuction)
        result.status = "Listed"
        result.price = lowestPrice
        result.suggestedPrice = lowestPrice
        result.suggestedQuantity = nil
        return result
    end
    if coverage > 0 then
        dealNote = " " .. tostring(coverage) .. " of yours already up." .. dealNote
    end

    if floor and lowestPrice < floor then
        -- "Too Cheap" (Your call): some players post anyway to free bag space.
        local result = Result(false, nil, BelowFloorNote(bounds) .. dealNote, lowestAuction)
        result.status = "Too Cheap"
        -- No starting price (Brian, 2026-11-06): the floor is a price that
        -- won't sell when others list far below it, and what to do here is
        -- the player's call (dump at the lowest, buy the cheap ones and
        -- relist, or hold). Price stays blank; typing one still posts.
        result.suggestedPrice = nil
        return result
    end
    -- Never undercut over a small gap (Brian, 2026-11-07): the max is there
    -- to keep us off clown prices, not to shave a silver off a normal one.
    -- Cheapest listing within 10% above the max -> match it. Not for a
    -- better-version cap ("rule"): we never post above a better version.
    if ceiling and ceiling > 0 and lowestPrice > ceiling
        and bounds.ceilingBase ~= "rule"
        and lowestPrice <= ceiling * NEAR_MAX_MATCH then
        return Result(true, lowestPrice, "Matched lowest price." .. dealNote, lowestAuction)
    end
    if ceiling and ceiling > 0 and lowestPrice > ceiling then
        -- Nobody is listed at the max: we picked it (check, 2026-11-06).
        local note = "Others listed far higher. Priced at the max."
        if bounds.ceilingBase == "rule" then
            note = "Priced below the better version."
        elseif bounds.ceilingBase == "value" or bounds.ceilingBase == "market"
            or bounds.ceilingBase == "pastmarket" or bounds.ceilingBase == "lowvalue" then
            note = "Others listed above its value. Priced at its value."
        end
        if bounds.ceilingAtFloor then
            note = "Others listed higher. Priced at the lowest we'd post."
        end
        local result = Result(true, ceiling, note .. dealNote, lowestAuction)
        result.check = true
        return result
    end
    return Result(true, lowestPrice, "Matched lowest price." .. dealNote, lowestAuction)
end

function PostingEvaluator:Evaluate(row, matchedAuctions, marketSettings, evaluationContext)
    row = type(row) == "table" and row or {}
    evaluationContext = type(evaluationContext) == "table" and evaluationContext or {}
    local ladderResult = evaluationContext.marketLadder or evaluationContext.ladderResult

    local rule = type(row.resolvedRule) == "table" and row.resolvedRule or {}
    if rule.smart then
        return EvaluateSmart(row, rule, ladderResult, marketSettings, evaluationContext)
    end
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
