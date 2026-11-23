-- PocketCFO_AH/Posting/Evaluation/PostingEvaluationPipeline.lua
-- Evaluation pipeline: finds next pending row, gathers market inputs from services,
-- calls PostingEvaluator for the posting decision, passes result back to the controller.
-- Ownership is sourced from AHListingService. AuctionLookupService owns the AH query.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingEvaluationPipeline = PocketCFO_AH:NewModule("PostingEvaluationPipeline")

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function PositiveQuantity(value)
    value = math.floor(tonumber(value) or 0)
    if value > 0 then
        return value
    end
    return 0
end

-- Debug lines only while PocketCFO debug is on (MCG_Diagnostic enabled, or
-- /mcg debug). Players never have it (Brian, 2026-11-10).
local function PostingEvaluationDebugEnabled()
    return PocketCFO ~= nil and PocketCFO.debugEnabled == true
end

local function GetItemIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function GetMarketLadderService()
    return PocketCFO_AH and PocketCFO_AH.MarketLadderService or _G.MarketLadderService
end

local function AuctionQuantity(auction)
    local quantity = PositiveQuantity(auction and (auction.quantity or auction.count or auction.stackSize or auction.numItems))
    if quantity > 0 then
        return quantity
    end
    return 1
end

local function AuctionUnitPrice(auction)
    if type(auction) ~= "table" then
        return nil
    end

    local unitPrice = tonumber(auction.price)
    if unitPrice and unitPrice > 0 then
        return unitPrice
    end

    unitPrice = tonumber(auction.unitPrice or auction.pricePerUnit)
    if unitPrice and unitPrice > 0 then
        return unitPrice
    end

    local quantity = AuctionQuantity(auction)
    local buyout = tonumber(auction.buyoutAmount or auction.buyout or auction.buyoutPrice or auction.totalPrice)
    if auction.isCommodity == true and buyout and buyout > 0 and quantity > 0 then
        return math.floor((buyout / quantity) + 0.5)
    end
    if buyout and buyout > 0 then
        return buyout
    end
    return nil
end

-- Builds the owned auctionID set from AHListingService active listings.
-- AHListingService is the canonical owner of active auction identity.
local function BuildOwnedAuctionIDSet()
    local ahListing = PocketCFO_AH:GetModule("AHListingService", true)
    if not ahListing or not ahListing.GetActiveOwnedListings then
        return {}, 0
    end
    local listings = ahListing:GetActiveOwnedListings()
    local ownedIDs = {}
    local count = 0
    for _, listing in ipairs(listings) do
        local auctionID = listing.auctionID
        if auctionID ~= nil then
            ownedIDs[tostring(auctionID)] = true
            count = count + 1
        end
    end
    return ownedIDs, count
end

-- Stamps ownerIsPlayer/owned/isOwned on any auction whose auctionID appears in ownedIDs.
-- Only mutates rows that match by auctionID. Does not guess ownership.
-- row is the posting row and supplies ownerKey/owner to backfill if missing on the auction.
local function AnnotateAuctionsWithOwnership(auctions, ownedIDs, row)
    local annotatedCount = 0
    for _, auction in ipairs(auctions or {}) do
        local auctionID = auction.auctionID or auction.auctionId or auction.listingID or auction.listingId
        if auctionID ~= nil and ownedIDs[tostring(auctionID)] then
            auction.ownerIsPlayer = true
            auction.owned = true
            auction.isOwned = true
            auction.ownershipSource = "ownedAuctionID"
            if type(row) == "table" then
                if row.ownerKey ~= nil and auction.ownerKey == nil then
                    auction.ownerKey = row.ownerKey
                end
                if row.owner ~= nil and auction.owner == nil then
                    auction.owner = row.owner
                end
            end
            annotatedCount = annotatedCount + 1
        end
    end
    return annotatedCount
end

local function BuildAuctionDebugRow(index, auction, accepted, reason)
    return {
        index = index,
        accepted = accepted == true,
        reason = reason,
        itemID = auction and auction.itemID,
        itemName = auction and auction.itemName,
        itemLink = auction and auction.itemLink,
        quality = auction and (auction.craftingQuality or auction.qualityTier or auction.itemQuality),
        itemLevel = auction and (auction.ilvl or auction.itemLevel),
        statFingerprint = auction and auction.statFingerprint,
        buyout = auction and (auction.buyoutAmount or auction.buyout or auction.totalPrice),
        unitPrice = AuctionUnitPrice(auction),
        quantity = AuctionQuantity(auction),
        owner = auction and auction.owner,
        auctionID = auction and auction.auctionID,
    }
end

local function BuildMatchAnalysis(target, auctions)
    local identityService = GetItemIdentityService()
    local analysis = {
        rawAuctionCount = #(auctions or {}),
        matchedCompetitors = {},
        rejectedAuctions = {},
        candidateRows = {},
        targetIdentity = nil,
        matchingPath = target and target.matchingPath,
    }

    if not identityService or not identityService.Matches then
        for index, auction in ipairs(auctions or {}) do
            local row = BuildAuctionDebugRow(index, auction, false, "rejected: ItemIdentityService unavailable")
            analysis.rejectedAuctions[#analysis.rejectedAuctions + 1] = row
            analysis.candidateRows[#analysis.candidateRows + 1] = row
        end
        return analysis
    end

    -- target.identity is the canonical identity already resolved by ItemIdentityService
    -- when the candidate row was built; fall back to resolving it here if missing.
    local targetIdentity = target and target.identity
    if type(targetIdentity) ~= "table" or not targetIdentity.configKey then
        targetIdentity = identityService:Identify({
            evidenceType = "item",
            itemID = target and target.itemID,
            itemLink = target and target.itemLink,
            itemName = target and target.itemName,
        })
    end
    analysis.targetIdentity = targetIdentity
    local matchingPath = target and target.matchingPath
    for _, auction in ipairs(auctions or {}) do
        local index = #analysis.candidateRows + 1
        local auctionIdentity = identityService:FromAuctionRow(auction)
        local accepted, reason = identityService:Matches(targetIdentity, auctionIdentity)
        local debugReason = accepted and (reason or "matched") or ("rejected: " .. tostring(reason or "configKey mismatch"))
        local row = BuildAuctionDebugRow(index, auction, accepted, debugReason)
        analysis.candidateRows[#analysis.candidateRows + 1] = row
        if accepted then
            analysis.matchedCompetitors[#analysis.matchedCompetitors + 1] = auction
            analysis.matchingPath = matchingPath or analysis.matchingPath
        else
            analysis.rejectedAuctions[#analysis.rejectedAuctions + 1] = row
        end
    end

    return analysis
end

local function BuildMatchDebugReport(row, matchAnalysis, lookupMeta, result, marketSettings)
    local filterCounts = {
        rawNameCandidateCount = matchAnalysis and matchAnalysis.rawAuctionCount or 0,
        filteredByIlvlCount = 0,
        filteredByQualityCount = 0,
        filteredByStatCount = 0,
    }
    for _, rejected in ipairs(matchAnalysis and matchAnalysis.rejectedAuctions or {}) do
        local reason = tostring(rejected and rejected.reason or "")
        if reason:find("effectiveItemLevel", 1, true) then
            filterCounts.filteredByIlvlCount = filterCounts.filteredByIlvlCount + 1
        end
        if reason:find("statFingerprint", 1, true) then
            filterCounts.filteredByStatCount = filterCounts.filteredByStatCount + 1
        end
    end

    local resultDebug = result and result.debug or {}
    local canonical = result and result.canonical or result or {}
    return {
        displayItemName = row and (row.item or row.itemName),
        itemID = row and row.candidate and row.candidate.itemID or row and row.target and (row.target.debugItemID or row.target.targetItemID),
        itemLink = row and (row.itemLink or row.candidate and row.candidate.itemLink),
        quality = row and row.target and row.target.targetQuality,
        itemLevel = row and row.target and (row.target.effectiveItemLevel or row.target.targetIlvl),
        statFingerprint = row and row.target and (row.target.statFingerprint or row.target.statTarget),
        ruleProfileUsed = row and row.postingRules,
        path = lookupMeta and lookupMeta.path or row and row.target and row.target.matchPath,
        matchPath = lookupMeta and lookupMeta.path or row and row.target and row.target.matchPath,
        postAPI = row and (row.postAPI or row.target and row.target.postAPI),
        classificationSource = row and (row.classificationSource or row.target and row.target.classificationSource),
        targetMatchIdentity = matchAnalysis and matchAnalysis.targetIdentity or row and row.target,
        lookupMeta = lookupMeta,
        requestMade = lookupMeta and lookupMeta.requestMade,
        requestAPI = lookupMeta and lookupMeta.requestAPI,
        requestItemKey = lookupMeta and lookupMeta.requestItemKey,
        resultItemKey = lookupMeta and lookupMeta.resultItemKey,
        lookupCompleted = lookupMeta and lookupMeta.completed,
        source = lookupMeta and lookupMeta.source,
        internalCandidateSource = lookupMeta and lookupMeta.internalCandidateSource,
        sourceRowsBeforeFiltering = lookupMeta and lookupMeta.sourceRowsBeforeFiltering,
        fallbackFromPath = lookupMeta and lookupMeta.fallbackFromPath,
        fallbackReason = lookupMeta and lookupMeta.fallbackReason,
        browseRowsMatchedByName = lookupMeta and lookupMeta.browseRowsMatchedByName,
        itemAuctionDetailKeysQueued = lookupMeta and lookupMeta.itemAuctionDetailKeysQueued,
        commodityDetailKeysQueued = lookupMeta and lookupMeta.commodityDetailKeysQueued,
        itemAuctionRowsCollected = lookupMeta and lookupMeta.itemAuctionRowsCollected,
        commodityRowsCollected = lookupMeta and lookupMeta.commodityRowsCollected,
        rawNameCandidateCount = filterCounts.rawNameCandidateCount,
        filteredByIlvlCount = filterCounts.filteredByIlvlCount,
        filteredByQualityCount = filterCounts.filteredByQualityCount,
        filteredByStatCount = filterCounts.filteredByStatCount,
        sourceError = lookupMeta and lookupMeta.sourceError,
        zeroReason = lookupMeta and lookupMeta.zeroReason,
        itemKeyInfoAvailable = lookupMeta and lookupMeta.itemKeyInfoAvailable,
        lookupAttempts = lookupMeta and lookupMeta.attempts,
        hasSearchResults = lookupMeta and lookupMeta.hasSearchResults,
        hasFullItemSearchResults = lookupMeta and lookupMeta.hasFullItemSearchResults,
        itemSearchResultsQuantity = lookupMeta and lookupMeta.itemSearchResultsQuantity,
        rawCandidateCount = canonical.rawAuctionCount or tonumber(lookupMeta and lookupMeta.rawCount) or 0,
        rawMatchCount = #(canonical.matchedCompetitors or {}),
        validCandidateCount = tonumber(resultDebug.validAuctionCount) or 0,
        selectedCompetitionPrice = canonical.lowestMatchingPrice or resultDebug.selectedCompetitionPrice,
        finalPostingPrice = result and result.price,
        finalStatus = result and result.status,
        finalNote = result and result.note,
        decisionCode = canonical.decisionCode,
        decisionLabel = canonical.decisionLabel,
        targetPosted = canonical.targetPosted,
        remainingToPost = canonical.remainingToPost,
        ownedCoverage = canonical.ownedCoverage,
        competitionPrice = canonical.competitionPrice,
        priceValidation = canonical.priceValidation,
        protectionThreshold = resultDebug.protectionThreshold,
        marketProtectionThreshold = resultDebug.marketProtectionThreshold,
        evaluationMode = resultDebug.evaluationMode,
        baitFilteringApplied = resultDebug.baitFilteringApplied,
        ignoredBaitAuctionCount = resultDebug.ignoredBaitAuctionCount,
        cheapestMatchedAuctions = resultDebug.cheapestMatchedAuctions,
        marketSettings = marketSettings,
        matchedCompetitors = canonical.matchedCompetitors or {},
        rejectedAuctions = canonical.rejectedAuctions or {},
        candidates = matchAnalysis and matchAnalysis.candidateRows or {},
    }
end

local function AttachCanonicalResult(row, result, matchAnalysis)
    result = type(result) == "table" and result or {}
    local debug = type(result.debug) == "table" and result.debug or {}
    local rawAuctionCount = matchAnalysis and matchAnalysis.rawAuctionCount or 0
    local matchedCompetitors = matchAnalysis and matchAnalysis.matchedCompetitors or {}
    local rejectedAuctions = matchAnalysis and matchAnalysis.rejectedAuctions or {}
    local targetPosted = PositiveQuantity(debug.maxToPost)
    local remainingToPost = PositiveQuantity(debug.remainingToPost or result.toPost)
    local lowestMatchingPrice = debug.selectedCompetitionPrice
    local rule = type(row and row.resolvedRule) == "table" and row.resolvedRule or {}
    local decisionCode

    if result.shouldPost == true then
        if lowestMatchingPrice ~= nil and tonumber(result.price) == tonumber(lowestMatchingPrice) then
            decisionCode = "post_at_competition_price"
        else
            decisionCode = "post_at_rule_price"
        end
    elseif targetPosted > 0 and PositiveQuantity(debug.ownedNextBuyCoverage) >= targetPosted then
        decisionCode = "covered_at_lowest_price"
    elseif #(matchedCompetitors or {}) == 0 then
        decisionCode = "no_matched_competitors"
    elseif lowestMatchingPrice ~= nil and result.status == "Skipped" then
        decisionCode = "price_validation_failed"
    else
        decisionCode = "skipped"
    end

    local priceValidation = nil
    if lowestMatchingPrice ~= nil and PositiveQuantity(debug.ownedNextBuyCoverage) < targetPosted then
        priceValidation = {
            reached = true,
            valid = result.shouldPost == true,
            price = result.price or lowestMatchingPrice,
            minPrice = rule.minPrice,
            maxPrice = rule.maxPrice,
            note = result.note,
        }
    else
        priceValidation = {
            reached = false,
            valid = nil,
            note = result.note,
        }
    end

    result.rawAuctionCount = rawAuctionCount
    result.matchedCompetitors = matchedCompetitors
    result.rejectedAuctions = rejectedAuctions
    result.lowestMatchingPrice = lowestMatchingPrice
    result.competitionPrice = lowestMatchingPrice
    result.ownedCoverage = PositiveQuantity(debug.ownedNextBuyCoverage)
    result.targetPosted = targetPosted
    result.remainingToPost = remainingToPost
    result.decisionCode = decisionCode
    result.decisionLabel = result.note
    result.priceValidation = priceValidation
    return result
end

-- Smart view (Brian, 2026-11-07): the max must come from the same PCFO
-- Value the item tooltip shows. Bounds were worked out when the list was
-- built, before this row's AH search; the search then updates the price
-- cache (SearchRefresh), so the tooltip moved on and the max didn't. Feed
-- the search into the price cache here (the order SearchRefresh and this
-- lookup get the search event in isn't guaranteed), then work the bounds
-- out again. Rows without bounds (rules view) are left alone.
local function ValuationModule(name)
    local valuation = _G.PocketCFO_Valuation
    if not valuation or type(valuation.GetModule) ~= "function" then
        return nil
    end
    local ok, module = pcall(valuation.GetModule, valuation, name, true)
    return ok and module or nil
end

-- Feed an item search's results into the price cache (SearchRefresh).
-- Theoretical: each result row's itemKey is the key that was searched (one
-- search per item key).
local function FeedItemSearch(auctions)
    local refresh = ValuationModule("SearchRefresh")
    if not refresh or type(refresh.ProcessItemResults) ~= "function" then
        return
    end
    local seen = {}
    for _, auction in ipairs(auctions or {}) do
        local itemKey = auction and auction.rawRow and auction.rawRow.itemKey
        if type(itemKey) == "table" then
            local token = table.concat({
                tostring(itemKey.itemID), tostring(itemKey.itemLevel),
                tostring(itemKey.itemSuffix), tostring(itemKey.battlePetSpeciesID),
            }, ":")
            if not seen[token] then
                seen[token] = true
                pcall(refresh.ProcessItemResults, refresh, itemKey)
            end
        end
    end
end

local function RefreshSmartBounds(row, auctions)
    local rule = row and row.resolvedRule
    if type(rule) ~= "table" or type(rule.bounds) ~= "table" or not row.candidate then
        return
    end
    local smart = PocketCFO_AH:GetModule("SmartPricing", true)
    if not smart or type(smart.GetBounds) ~= "function" then
        return
    end
    local refresh = ValuationModule("SearchRefresh")
    if refresh then
        if row.target and row.target.postAPI == "PostCommodity" then
            local itemID = tonumber(row.candidate.itemID or row.target.targetItemID)
            if itemID and type(refresh.ProcessCommodityResults) == "function" then
                pcall(refresh.ProcessCommodityResults, refresh, itemID)
            end
        else
            FeedItemSearch(auctions)
        end
    end
    local ok, bounds = pcall(smart.GetBounds, smart, row.candidate)
    if ok and type(bounds) == "table" then
        rule.bounds = bounds
        -- Same fields the queue sets when it builds the row.
        rule.minPrice = bounds.floor
        rule.maxPrice = bounds.ceiling
    end
end

-- ---------------------------------------------------------------------------
-- Live better versions for like items (Brian, 2026-11-20). A green
-- profession tool/accessory is priced from its blue partner on the tool
-- ladder (Valuation ValuationRuleSet tool-tier-cap), so the blue needs the
-- same live look as the item itself: one search per blue item ID per
-- evaluation pass, shared by every row of that tool. Higher qualities of
-- the item's own ID come back with its own search.
-- After each finished search, price cache rows of that item ID it didn't
-- see are marked "not listed" (PricingCache MarkNotListed) so a sold-out
-- better version stops capping, in posting and in the item tooltip.
-- Search not finished: the row keeps the old ladder role (only lowers the
-- max) and goes to Check.
-- Theoretical: the equipment search (SendSellSearchQuery, item level 0)
-- returns every item level, so every quality, of the item ID. If it only
-- returned one, other qualities would be marked not listed wrongly; the
-- session log line "better versions" lists the item levels seen.
-- Flavor: Both (Forever has no tool pairs, so nothing runs there).
-- ---------------------------------------------------------------------------

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GREEN = 2

local function ServerNow()
    return (GetServerTime and GetServerTime()) or time()
end

-- Mark rows the finished search didn't see as not listed. Returns the
-- count marked, or nil when the search didn't finish (nothing marked).
local function MarkSearched(itemID, sentAt, meta)
    itemID = tonumber(itemID)
    if not itemID or not sentAt or type(meta) ~= "table" then
        return nil
    end
    if meta.completed ~= true or meta.requestMade ~= true or meta.sourceError then
        return nil
    end
    local cache = ValuationModule("PricingCache")
    if not cache or type(cache.MarkNotListed) ~= "function" then
        return nil
    end
    local ok, marked = pcall(cache.MarkNotListed, cache, itemID, sentAt, ServerNow())
    return ok and (tonumber(marked) or 0) or nil
end

local function ItemLevelsSeen(auctions)
    local levels, seen = {}, {}
    for _, auction in ipairs(auctions or {}) do
        local ilvl = tonumber(auction and auction.ilvl)
        if ilvl and not seen[ilvl] then
            seen[ilvl] = true
            levels[#levels + 1] = ilvl
        end
    end
    table.sort(levels)
    return table.concat(levels, ",")
end

-- Profession tool or accessory: the only items on the tool ladder.
local LADDER_SLOTS = { INVTYPE_PROFESSION_TOOL = true, INVTYPE_PROFESSION_GEAR = true }
local function IsLadderItem(candidate)
    if type(candidate) ~= "table" then
        return false
    end
    local equipLoc = candidate.equipLoc or candidate.inventoryType
    if not equipLoc or equipLoc == "" then
        local ok, _, _, _, _, _, _, _, _, loc = pcall(GetItemInfo, candidate.itemLink or candidate.itemID)
        equipLoc = ok and loc or nil
    end
    return LADDER_SLOTS[equipLoc] == true
end

-- The blue partner of a green tool/accessory, or nil.
local function BetterVersionPartner(candidate)
    local itemID = tonumber(candidate and candidate.itemID)
    local pairsModule = ValuationModule("ProfessionGearPairs")
    if not itemID or not pairsModule or type(pairsModule.GetPartner) ~= "function" then
        return nil
    end
    local okPartner, partnerID = pcall(pairsModule.GetPartner, pairsModule, itemID)
    partnerID = okPartner and tonumber(partnerID) or nil
    if not partnerID then
        return nil
    end
    local okInfo, _, _, rarity = pcall(GetItemInfo, candidate.itemLink or itemID)
    if not okInfo or tonumber(rarity) ~= GREEN then
        return nil
    end
    return partnerID
end

local function CheckBetterVersions(controller, generation, row, continue)
    local candidate = row and row.candidate
    if type(candidate) ~= "table" then
        continue()
        return
    end
    candidate.ladderUnchecked = nil
    local partnerID = IsLadderItem(candidate) and BetterVersionPartner(candidate) or nil
    if not partnerID then
        continue()
        return
    end
    controller.ladderChecks = controller.ladderChecks or {}
    local prior = controller.ladderChecks[partnerID]
    if prior and prior.generation == generation then
        candidate.ladderUnchecked = (not prior.ok) or nil
        continue()
        return
    end
    local lookup = PocketCFO_AH.AuctionLookupService or _G.AuctionLookupService
    if not lookup or type(lookup.GetAuctionsForRow) ~= "function" then
        candidate.ladderUnchecked = true
        continue()
        return
    end
    local partnerName, partnerLink, _, _, _, _, _, _, partnerEquipLoc = GetItemInfo(partnerID)
    local equipLoc = partnerEquipLoc
    if not equipLoc or equipLoc == "" then
        equipLoc = candidate.equipLoc or candidate.inventoryType or "INVTYPE_PROFESSION_TOOL"
    end
    local partnerRow = {
        itemName = partnerName,
        itemLink = partnerLink,
        candidate = { itemID = partnerID, itemName = partnerName, itemLink = partnerLink, equipLoc = equipLoc },
    }
    local sentAt = ServerNow()
    lookup:GetAuctionsForRow(partnerRow, function(auctions, meta)
        if generation ~= controller.generation then
            return
        end
        FeedItemSearch(auctions)
        local marked = MarkSearched(partnerID, sentAt, meta)
        local ok = marked ~= nil
        controller.ladderChecks[partnerID] = { generation = generation, ok = ok }
        candidate.ladderUnchecked = (not ok) or nil
        SessionLog("PostingEvaluationPipeline: better versions itemID=%s partnerID=%s finished=%s rows=%d itemLevels=%s markedNotListed=%s path=%s",
            tostring(candidate.itemID), tostring(partnerID), tostring(ok), #(auctions or {}),
            ItemLevelsSeen(auctions), tostring(marked), tostring(type(meta) == "table" and meta.path))
        continue()
    end)
end

local function SortEvaluatedRows(rows)
    local buckets = {
        {},
        {},
        {},
        {},
        {},
        {},
        {},
    }

    -- Smart view: a row in the middle of posting ("1 of 4 posted.") stays at
    -- the very top, above "Matched lowest price.", until the rest are posted
    -- (Brian, 2026-11-19). Without this its note changes after the first
    -- post and it drops below the Matched lowest price rows.
    local function InProgress(row)
        if not (row and row.resolvedRule and row.resolvedRule.smart == true) then
            return false
        end
        local status = row.evaluation and row.evaluation.status or row.status
        local posting = row.posting
        return status == "Ready" and type(posting) == "table"
            and PositiveQuantity(posting.postedCount) > 0
            and PositiveQuantity(posting.remainingToPost) > 0
    end

    -- Smart view groups (Brian, 2026-11-04, 2026-11-06): Ready to post;
    -- Check the price (Ready with evaluation.check, until the player types a
    -- price); Your call (Needs Price, errors, then Too Cheap); Probably not
    -- (Listed, Skipped, Posted). The rules view keeps Posted above Skipped.
    local function GetSortBucket(row)
        local status = row and row.evaluation and row.evaluation.status or row and row.status
        local smart = row and row.resolvedRule and row.resolvedRule.smart == true
        if InProgress(row) then
            return 1
        end
        if status == "Ready" then
            local check = row.evaluation and row.evaluation.check == true
                and not (row.overrides and row.overrides.price)
            return check and 2 or 1
        elseif status == "Too Cheap" then
            return 4
        elseif status == "Listed" then
            return 5
        elseif status == "Posted" then
            return smart and 7 or 6
        elseif status == "Skipped" then
            return smart and 6 or 7
        end
        return 3
    end

    -- Smart view: inside each group, rows with the same note sit together, and
    -- "Matched lowest price." goes first (Brian, 2026-11-16: those need no
    -- thought; the rest he reads one kind at a time). The key is the note's
    -- first sentence (two when it opens "No other listings."), cut at the
    -- first number, "(" or color code so gold amounts don't split a kind.
    -- Other kinds keep the order they first appear in, so re-sorting an
    -- already sorted list changes nothing. Rules view rows keep their order.
    local function NoteKey(row)
        if not (row and row.resolvedRule and row.resolvedRule.smart == true) then
            return ""
        end
        local note = tostring(row.evaluation and row.evaluation.note or row.note or "")
        local stop = note:find("%. ")
        if stop and note:sub(1, stop) == "No other listings." then
            stop = note:find("%. ", stop + 2)
        end
        local key = stop and note:sub(1, stop) or note
        local cut = key:find("[%d%(|]")
        if cut then
            key = key:sub(1, cut - 1)
        end
        return key
    end

    local function GroupByNote(bucketRows)
        local order, byKey = {}, {}
        local inProgress = {}
        for _, row in ipairs(bucketRows) do
            if InProgress(row) then
                inProgress[#inProgress + 1] = row
            else
                local key = NoteKey(row)
                if not byKey[key] then
                    byKey[key] = {}
                    if key == "Matched lowest price." then
                        table.insert(order, 1, key)
                    else
                        order[#order + 1] = key
                    end
                end
                byKey[key][#byKey[key] + 1] = row
            end
        end
        local sorted = {}
        for _, row in ipairs(inProgress) do
            sorted[#sorted + 1] = row
        end
        for _, key in ipairs(order) do
            for _, row in ipairs(byKey[key]) do
                sorted[#sorted + 1] = row
            end
        end
        return sorted
    end

    for _, row in ipairs(rows or {}) do
        local bucket = GetSortBucket(row)
        buckets[bucket][#buckets[bucket] + 1] = row
    end

    local index = 1
    for bucketIndex = 1, #buckets do
        for _, row in ipairs(GroupByNote(buckets[bucketIndex])) do
            rows[index] = row
            index = index + 1
        end
    end
    for removeIndex = index, #rows do
        rows[removeIndex] = nil
    end
end

function PostingEvaluationPipeline:SortRows(rows)
    SortEvaluatedRows(rows)
end

-- EvaluateRow is the full evaluation pipeline for a single posting row.
-- controller: the PostingController instance that owns rows, generation, and state.
-- generation: the evaluation generation at the time the caller requested evaluation.
-- Accesses controller.rows and controller.generation directly; calls back to
-- controller:ApplyEvaluation, controller:MarketSettingsForRow, controller:NotifyQueueChanged,
-- and controller:ReclassifyTarget for re-classification.
function PostingEvaluationPipeline:EvaluateRow(controller, generation)
    if generation ~= controller.generation then
        return
    end

    local row = nil
    for _, candidateRow in ipairs(controller.rows or {}) do
        if candidateRow.evaluation and candidateRow.evaluation.status == "Evaluating" then
            row = candidateRow
            break
        end
    end

    if not row then
        controller.evaluating = false
        SortEvaluatedRows(controller.rows)
        controller:NotifyQueueChanged("complete")
        SessionLog("PostingController: evaluation complete rows=%d", #(controller.rows or {}))
        -- Smart view: re-check once if mat prices were still loading.
        if type(controller.RetryLoadingPrices) == "function" then
            pcall(controller.RetryLoadingPrices, controller)
        end
        return
    end

    local lookup = PocketCFO_AH.AuctionLookupService or _G.AuctionLookupService
    local identityService = GetItemIdentityService()
    local evaluator = PocketCFO_AH.PostingEvaluator or _G.PostingEvaluator

    local missingService = nil
    if not lookup or not (lookup.GetAuctionsForRow or lookup.GetAuctionsByName) then
        missingService = "AuctionLookupService"
    elseif not identityService or not identityService.Matches then
        missingService = "ItemIdentityService"
    elseif not evaluator or not evaluator.Evaluate then
        missingService = "PostingEvaluator"
    end

    if missingService then
        controller:ApplyEvaluation(row, {
            shouldPost = false,
            price = nil,
            toPost = 0,
            status = "Skipped",
            note = "Skipped: " .. missingService .. " unavailable.",
            lowestAuction = nil,
            ownedLowestQuantity = 0,
            ownedNextBuyCoverage = 0,
        })
        SortEvaluatedRows(controller.rows)
        controller:NotifyQueueChanged("row")
        self:EvaluateRow(controller, generation)
        return
    end

    self.lookupCallActive = true
    self.continuePending = false

    local function FinishRow(auctions, lookupMeta)
        if generation ~= controller.generation then
            return
        end

        RefreshSmartBounds(row, auctions)

        -- Built once per evaluation pass, not once per row (2026-11-10).
        -- Posting is locked while a pass runs, so the set can't go stale.
        if controller.ownedIDsGeneration ~= generation then
            controller.ownedIDs, controller.ownedIDsCount = BuildOwnedAuctionIDSet()
            controller.ownedIDsGeneration = generation
        end
        local ownedIDs, ownedAuctionMapCount = controller.ownedIDs, controller.ownedIDsCount
        local annotatedCount = AnnotateAuctionsWithOwnership(auctions, ownedIDs, row)
        SessionLog("PostingEvaluationPipeline: ownership annotation ownedInMap=%d annotatedInResults=%d", ownedAuctionMapCount, annotatedCount)

        local matchAnalysis = BuildMatchAnalysis(row.target, auctions or {})
        local matchedAuctions = matchAnalysis.matchedCompetitors
        local marketSettings = controller:MarketSettingsForRow(row)
        local ladderService = GetMarketLadderService()
        local ladderResult = ladderService and ladderService:BuildFromMatchedAuctions(matchedAuctions, {
            source = "PostingEvaluationPipeline",
            targetConfigKey = row.target and row.target.configKey,
            targetIdentity = matchAnalysis.targetIdentity,
            auctionPath = row.target and row.target.postAPI == "PostCommodity" and "commodity" or "item",
        })
        local evaluationContext = {
            marketLadder = ladderResult,
            -- Search sent but never answered (timeout): the evaluator must
            -- not treat "no rows" as "nobody is listing" (2026-11-06).
            lookupIncomplete = type(lookupMeta) == "table" and lookupMeta.completed == false or nil,
        }
        local result = AttachCanonicalResult(row, evaluator:Evaluate(row, matchedAuctions, marketSettings, evaluationContext), matchAnalysis)
        -- Like item whose better versions couldn't be searched live this
        -- pass (CheckBetterVersions): priced the old way, player checks it.
        local rowBounds = row.resolvedRule and row.resolvedRule.bounds
        if row.candidate and row.candidate.ladderUnchecked and type(result) == "table" and result.shouldPost
            and type(rowBounds) == "table" and type(rowBounds.ruleCapFrom) == "table" and rowBounds.ruleCapFrom.ladder then
            result.check = true
            result.note = tostring(result.note or "") .. " Couldn't check the better versions."
        end
        row.matchDebug = BuildMatchDebugReport(row, matchAnalysis, lookupMeta or {}, result, marketSettings)
        local coverageDebug = result and result.debug or {}
        local coverageDecision = result and result.shouldPost == true and "post" or "skip"
        SessionLog("Posting ownership coverage itemName=%s itemID=%s targetStat=%s matchedAuctions=%d competitionPrice=%s maxToPost=%d ownedNextBuyCoverage=%d remainingToPost=%d decision=%s",
            tostring(row.itemName or row.item),
            tostring(row.candidate and row.candidate.itemID or row.target and row.target.targetItemID),
            tostring(row.target and row.target.statTarget),
            #matchedAuctions,
            tostring(coverageDebug.selectedCompetitionPrice),
            PositiveQuantity(coverageDebug.maxToPost or row.resolvedRule and row.resolvedRule.maxToPost),
            PositiveQuantity(coverageDebug.ownedNextBuyCoverage),
            PositiveQuantity(coverageDebug.remainingToPost),
            coverageDecision)
        if PostingEvaluationDebugEnabled() then
            local debug = result and result.debug or {}
            for rowIndex, coverageRow in ipairs(debug.coverageRows or {}) do
                SessionLog("coverage row index=%s owned=%s auctionID=%s price=%s quantity=%s",
                    tostring(coverageRow.index or rowIndex),
                    tostring(coverageRow.owned == true),
                    tostring(coverageRow.auctionID),
                    tostring(coverageRow.price),
                    tostring(coverageRow.quantity))
            end
            SessionLog("PostingController: evaluation debug item=%s itemID=%s itemLink=%s quality=%s ilvl=%s statFingerprint=%s path=%s rawResults=%d rawMatches=%d validMatches=%d selectedCompetitionPrice=%s finalPrice=%s status=%s note=%s",
                tostring(row.itemName or row.item),
                tostring(row.candidate and row.candidate.itemID or row.target and row.target.targetItemID),
                tostring(row.itemLink or row.candidate and row.candidate.itemLink),
                tostring(row.target and row.target.targetQuality),
                tostring(row.target and row.target.targetIlvl),
                tostring(row.target and row.target.statTarget),
                tostring(lookupMeta and lookupMeta.path or row.target and row.target.matchPath or "unknown"),
                tonumber(lookupMeta and lookupMeta.rawCount) or #(auctions or {}),
                #matchedAuctions,
                tonumber(debug.validAuctionCount) or 0,
                tostring(debug.selectedCompetitionPrice),
                tostring(result and result.price),
                tostring(result and result.status),
                tostring(result and result.note))
        end
        controller:ApplyEvaluation(row, result)
        SortEvaluatedRows(controller.rows)
        controller:NotifyQueueChanged("row")
        if self.lookupCallActive then
            self.continuePending = true
        else
            self:EvaluateRow(controller, generation)
        end
    end

    -- Own search first, then the better versions (like items only), then
    -- the bounds and the decision (FinishRow). Equipment only: commodities
    -- have no ladder.
    local searchSentAt = ServerNow()
    local function OnLookupComplete(auctions, lookupMeta)
        if generation ~= controller.generation then
            return
        end
        if not (row.target and row.target.postAPI == "PostCommodity") and IsLadderItem(row.candidate) then
            MarkSearched(row.candidate and row.candidate.itemID or row.target and row.target.targetItemID,
                searchSentAt, lookupMeta)
        end
        CheckBetterVersions(controller, generation, row, function()
            FinishRow(auctions, lookupMeta)
        end)
    end

    -- Re-resolve the posting API at evaluation time so item cache is warm.
    -- Classification at queue-build time runs before GetItemInfoInstant has
    -- cached item data, causing IsTradeGoodsItem to return false for commodities.
    if not controller.ReclassifyTarget then
        controller:ApplyEvaluation(row, {
            shouldPost = false,
            price = nil,
            toPost = 0,
            status = "Skipped",
            note = "Skipped: posting target classification unavailable.",
            lowestAuction = nil,
            ownedLowestQuantity = 0,
            ownedNextBuyCoverage = 0,
        })
        SortEvaluatedRows(controller.rows)
        controller:NotifyQueueChanged("row")
        self:EvaluateRow(controller, generation)
        return
    end
    local freshTarget = controller:ReclassifyTarget(row.candidate or row)
    if freshTarget.postAPI ~= row.target.postAPI then
        SessionLog("EvaluateRow: reclassified itemID=%s from postAPI=%s to postAPI=%s",
            tostring(row.candidate and row.candidate.itemID),
            tostring(row.target.postAPI),
            tostring(freshTarget.postAPI))
        row.target = freshTarget
        row.postAPI = freshTarget.postAPI
        row.classificationSource = freshTarget.classificationSource
    end

    if lookup.GetAuctionsForRow then
        lookup:GetAuctionsForRow(row, OnLookupComplete)
    else
        lookup:GetAuctionsByName(row.itemName, OnLookupComplete)
    end

    self.lookupCallActive = false
    if self.continuePending then
        self.continuePending = false
        self:EvaluateRow(controller, generation)
    end
end
