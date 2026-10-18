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

local function PostingEvaluationDebugEnabled()
    local settings = PocketCFO_AH
        and PocketCFO_AH.db
        and PocketCFO_AH.db.global
        and PocketCFO_AH.db.global.postingSettings
        or nil
    return settings
        and settings.debug
        and settings.debug.captureCompetitionRows == true
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

local function SortEvaluatedRows(rows)
    local buckets = {
        {},
        {},
        {},
        {},
    }

    local function GetSortBucket(row)
        local status = row and row.evaluation and row.evaluation.status or row and row.status
        if status == "Ready" then
            return 1
        elseif status == "Posted" then
            return 3
        elseif status == "Skipped" then
            return 4
        end
        return 2
    end

    for _, row in ipairs(rows or {}) do
        local bucket = GetSortBucket(row)
        buckets[bucket][#buckets[bucket] + 1] = row
    end

    local index = 1
    for bucketIndex = 1, #buckets do
        for _, row in ipairs(buckets[bucketIndex]) do
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

    local function OnLookupComplete(auctions, lookupMeta)
        if generation ~= controller.generation then
            return
        end

        local ownedIDs, ownedAuctionMapCount = BuildOwnedAuctionIDSet()
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
        local evaluationContext = { marketLadder = ladderResult }
        local result = AttachCanonicalResult(row, evaluator:Evaluate(row, matchedAuctions, marketSettings, evaluationContext), matchAnalysis)
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
