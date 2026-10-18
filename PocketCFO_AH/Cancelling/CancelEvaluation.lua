-- PocketCFO_AH/Cancelling/CancelEvaluation.lua
-- Owns cancel evaluation decisions and diagnostics.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local CancelEvaluation = {}

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function GetMarketLadderService()
    return PocketCFO_AH and PocketCFO_AH.MarketLadderService or _G.MarketLadderService
end

local function AuctionID(auction)
    if type(auction) ~= "table" then
        return nil
    end
    return auction.auctionID or auction.auctionId or auction.id or auction.listingID or auction.listingId
end

local function AuctionIDMatches(auction, auctionID)
    local currentID = AuctionID(auction)
    return currentID ~= nil and auctionID ~= nil and tostring(currentID) == tostring(auctionID)
end

local function SourceAuction(row)
    return row and (row.auction or row.raw or row)
end

local function AuctionIDSetFromRow(row)
    local set = {}
    local count = 0
    for _, auction in ipairs(row and row.auctions or {}) do
        local auctionID = AuctionID(auction)
        if auctionID ~= nil and not set[tostring(auctionID)] then
            set[tostring(auctionID)] = true
            count = count + 1
        end
    end
    return set, count
end

local function LadderAuctions(result)
    local auctions = {}
    for _, ladderRow in ipairs(result and result.ladder or {}) do
        auctions[#auctions + 1] = ladderRow.auction or ladderRow
    end
    return auctions
end

local function BuildResultFromMatchedAuctions(matchedAuctions, row)
    local service = GetMarketLadderService()
    if not service or type(service.BuildFromMatchedAuctions) ~= "function" then
        return nil
    end
    return service:BuildFromMatchedAuctions(matchedAuctions or {}, {
        source = "CancelEvaluation",
        targetSource = "cancelRow",
        targetConfigKey = row and row.configKey,
        targetIdentity = row and row.identity,
        auctionPath = row and row.auctionPath,
    }, {
        source = "owned",
        ownerKey = row and row.ownerKey,
        ownerName = row and row.owner,
    })
end

local function InSequentialNextBuyBlock(result, auctionID)
    if auctionID == nil then
        return false, { reason = "missingAuctionID" }
    end

    local ladder = result and result.ladder or {}
    local lowestPrice = ladder[1] and ladder[1].price or nil
    local coverageRows = {}
    local coverage = 0
    local started = false

    if lowestPrice ~= nil then
        for _, ladderRow in ipairs(ladder) do
            if ladderRow.price == lowestPrice then
                started = true
                local coverageRow = {
                    index = #coverageRows + 1,
                    position = ladderRow.position,
                    owned = ladderRow.owned == true,
                    auctionID = ladderRow.auctionID,
                    price = ladderRow.price,
                    quantity = ladderRow.quantity,
                }
                coverageRows[#coverageRows + 1] = coverageRow
                if ladderRow.owned then
                    coverage = coverage + (tonumber(ladderRow.quantity) or 0)
                else
                    break
                end
            elseif started then
                break
            end
        end
    end

    local foundInPricedEntries = false
    for _, ladderRow in ipairs(ladder) do
        if ladderRow.price ~= nil and AuctionIDMatches(ladderRow, auctionID) then
            foundInPricedEntries = true
            break
        end
    end

    local found = false
    local inBlock = false
    for _, coverageRow in ipairs(coverageRows) do
        if coverageRow.auctionID ~= nil and tostring(coverageRow.auctionID) == tostring(auctionID) then
            found = true
            inBlock = coverageRow.owned == true
            break
        end
    end

    return inBlock == true, {
        reason = found and "withinSequentialOwnedBlock" or "outsideSequentialOwnedBlock",
        auctionFound = foundInPricedEntries,
        lowestPrice = lowestPrice,
        ownedNextBuyCoverage = coverage,
        coverageRows = coverageRows,
    }
end

local function BuildPositionTrace(row, result)
    local trace = {
        entries = {},
        ownedIndexes = {},
        targetOwnedIndexes = {},
        outsideSequentialOwnedBlockAuctionIDs = {},
        auctionResults = {},
        totalOwnedEntries = 0,
        totalCompetitorEntries = 0,
        firstNonOwnedIndex = nil,
        sequentialOwnedBlockDetected = false,
    }

    if not result then
        trace.reason = "market-ladder-service-unavailable"
        return trace
    end

    local targetAuctionIDs = AuctionIDSetFromRow(row)
    trace.rawEntries = result.ladder or {}
    for index, ladderRow in ipairs(result.ladder or {}) do
        local auctionID = ladderRow.auctionID
        local owned = ladderRow.owned == true
        if owned then
            trace.totalOwnedEntries = trace.totalOwnedEntries + 1
            trace.ownedIndexes[#trace.ownedIndexes + 1] = index
        else
            trace.totalCompetitorEntries = trace.totalCompetitorEntries + 1
            if trace.firstNonOwnedIndex == nil then
                trace.firstNonOwnedIndex = index
            end
        end
        if auctionID ~= nil and targetAuctionIDs[tostring(auctionID)] then
            trace.targetOwnedIndexes[#trace.targetOwnedIndexes + 1] = index
        end
        trace.entries[#trace.entries + 1] = {
            index = index,
            originalIndex = ladderRow.originalIndex,
            auctionID = auctionID,
            itemID = ladderRow.itemID,
            price = ladderRow.price,
            quantity = ladderRow.quantity,
            owned = owned,
            isTargetOwnedAuction = auctionID ~= nil and targetAuctionIDs[tostring(auctionID)] == true,
            owner = ladderRow.owner,
            ownerKey = ladderRow.ownerKey,
            ownerIsPlayer = owned,
            ownershipSource = ladderRow.ownershipSource,
        }
    end

    local firstAuction = row and row.auctions and row.auctions[1] or nil
    local _, firstMeta = InSequentialNextBuyBlock(result, AuctionID(firstAuction))
    trace.reason = firstMeta and firstMeta.reason
    trace.lowestPrice = firstMeta and firstMeta.lowestPrice
    trace.ownedNextBuyCoverage = firstMeta and firstMeta.ownedNextBuyCoverage
    trace.coverageRows = firstMeta and firstMeta.coverageRows or {}
    trace.sequentialOwnedBlockDetected = #(trace.coverageRows or {}) > 0

    local blockSet = {}
    for _, coverageRow in ipairs(trace.coverageRows or {}) do
        if coverageRow.auctionID ~= nil then
            blockSet[tostring(coverageRow.auctionID)] = true
        end
    end
    for _, auction in ipairs(row and row.auctions or {}) do
        local auctionID = AuctionID(auction)
        local ok, meta = InSequentialNextBuyBlock(result, auctionID)
        trace.auctionResults[#trace.auctionResults + 1] = {
            auctionID = auctionID,
            ok = ok == true,
            status = ok and "OK" or "Undercut",
            reason = meta and meta.reason,
            auctionFound = meta and meta.auctionFound,
            lowestPrice = meta and meta.lowestPrice,
            ownedNextBuyCoverage = meta and meta.ownedNextBuyCoverage,
        }
        if auctionID ~= nil and not blockSet[tostring(auctionID)] then
            trace.outsideSequentialOwnedBlockAuctionIDs[#trace.outsideSequentialOwnedBlockAuctionIDs + 1] = auctionID
        end
    end

    return trace
end

local function EvaluateCommodity(row, result, matchedAuctions)
    local lowestPrice = result and result.ladder and result.ladder[1] and result.ladder[1].price or nil
    local status
    local note
    local reason
    if not lowestPrice then
        status = "OK"
        note = "Unable to confirm in current auction ladder."
        reason = "no-ladder-entries"
    elseif (tonumber(row and row.price) or 0) <= lowestPrice then
        status = "OK"
        note = "Still next to buy auction."
        reason = "commodity-price-comparison"
    else
        status = "Undercut"
        note = "No longer next to buy auction."
        reason = "commodity-price-comparison"
    end

    return {
        status = status,
        note = note,
        okAuctions = status == "OK" and (row and row.auctions or {}) or {},
        undercutAuctions = status == "Undercut" and (row and row.auctions or {}) or {},
        matchedAuctions = matchedAuctions,
        ladderResult = result,
        matchDebug = {
            itemName = row and row.itemName,
            auctionIDs = row and row.auctionIDs,
            matchedAuctions = matchedAuctions,
            sequentialOwnedNextBuyBlock = {},
            decision = status,
            reason = reason,
        },
        positionTrace = BuildPositionTrace(row, result),
    }
end

local function EvaluateItem(row, result, matchedAuctions)
    local okAuctions = {}
    local undercutAuctions = {}
    local debugMeta = nil

    for _, auction in ipairs(row and row.auctions or {}) do
        local ok, meta = InSequentialNextBuyBlock(result, AuctionID(auction))
        debugMeta = meta or debugMeta
        if meta and meta.auctionFound == false then
            okAuctions[#okAuctions + 1] = auction
            debugMeta = meta
        elseif ok then
            okAuctions[#okAuctions + 1] = auction
        else
            undercutAuctions[#undercutAuctions + 1] = auction
        end
    end

    local status
    local note
    if #undercutAuctions > 0 then
        status = "Undercut"
        note = "No longer next to buy auction."
    elseif debugMeta and debugMeta.auctionFound == false then
        status = "OK"
        note = "Unable to confirm in current auction ladder."
    else
        status = "OK"
        note = "Still next to buy auction."
    end

    return {
        status = status,
        note = note,
        okAuctions = okAuctions,
        undercutAuctions = undercutAuctions,
        matchedAuctions = matchedAuctions,
        ladderResult = result,
        matchDebug = {
            itemName = row and row.itemName,
            auctionIDs = row and row.auctionIDs,
            matchedAuctions = matchedAuctions,
            sequentialOwnedNextBuyBlock = debugMeta and debugMeta.coverageRows or {},
            decision = status,
            reason = debugMeta and debugMeta.reason,
        },
        debugMeta = debugMeta,
        positionTrace = BuildPositionTrace(row, result),
    }
end

function CancelEvaluation:Evaluate(row, options)
    options = options or {}
    local result = options.ladderResult
    local matchedAuctions = options.matchedAuctions

    if not result and matchedAuctions then
        result = BuildResultFromMatchedAuctions(matchedAuctions, row)
    end
    if result and not matchedAuctions then
        matchedAuctions = LadderAuctions(result)
    end

    if not result then
        return {
            status = "OK",
            note = "Cancel evaluation unavailable.",
            okAuctions = row and row.auctions or {},
            undercutAuctions = {},
            matchedAuctions = matchedAuctions or {},
            matchDebug = {
                itemName = row and row.itemName,
                auctionIDs = row and row.auctionIDs,
                matchedAuctions = matchedAuctions or {},
                sequentialOwnedNextBuyBlock = {},
                decision = "OK",
                reason = "market-ladder-service-unavailable",
            },
            positionTrace = BuildPositionTrace(row, nil),
        }
    end

    if row and row.isCommodity == true or row and row.auctionPath == "commodity" then
        local evaluation = EvaluateCommodity(row, result, matchedAuctions or {})
        self:LogRecommendation(row, evaluation.status, evaluation.debugMeta or { reason = evaluation.matchDebug.reason })
        return evaluation
    end

    local evaluation = EvaluateItem(row, result, matchedAuctions or {})
    self:LogRecommendation(row, evaluation.status, evaluation.debugMeta)
    return evaluation
end

function CancelEvaluation:BuildTrace(row, options)
    options = options or {}
    local result = options.ladderResult
    if not result and options.matchedAuctions then
        result = BuildResultFromMatchedAuctions(options.matchedAuctions, row)
    end
    return BuildPositionTrace(row, result)
end

function CancelEvaluation:LogRecommendation(row, decision, meta)
    SessionLog("Cancel evaluation auctionID=%s item=%s price=%s status=%s reason=%s lowestPrice=%s ownedNextBuyCoverage=%s",
        tostring(row and row.auctionID),
        tostring(row and row.itemName),
        tostring(row and row.price),
        tostring(decision),
        tostring(meta and meta.reason),
        tostring(meta and meta.lowestPrice),
        tostring(meta and meta.ownedNextBuyCoverage))
end

function CancelEvaluation:WithoutAuctionID(matchedAuctions, auctionID)
    local filtered = {}
    for _, row in ipairs(matchedAuctions or {}) do
        if not AuctionIDMatches(SourceAuction(row), auctionID) and not AuctionIDMatches(row, auctionID) then
            filtered[#filtered + 1] = row
        end
    end
    return filtered
end

if PocketCFO_AH then
    PocketCFO_AH.CancelEvaluation = CancelEvaluation
end

_G.CancelEvaluation = CancelEvaluation
