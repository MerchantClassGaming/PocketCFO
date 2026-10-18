-- PocketCFO_AH/Services/AuctionPositionService/AuctionPositionService.lua
-- Shared auction ladder helpers for posting and cancel evaluation.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local AuctionPositionService = PocketCFO_AH:NewModule("AuctionPositionService")

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

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

local function GetItemIdentityAdapter()
    return PocketCFO and PocketCFO.ItemIdentityAdapter or _G.ItemIdentityAdapter
end

local function GetItemMatchingService()
    return PocketCFO and PocketCFO.ItemMatchingService or _G.ItemMatchingService
end

function AuctionPositionService:AuctionQuantity(auction)
    local quantity = PositiveQuantity(auction and (auction.quantity or auction.count or auction.stackSize or auction.numItems))
    if quantity > 0 then
        return quantity
    end
    return 1
end

function AuctionPositionService:AuctionPrice(auction)
    if type(auction) ~= "table" then
        return nil
    end

    local normalizedPrice = NumberOrNil(auction.price)
    if normalizedPrice and normalizedPrice > 0 then
        return normalizedPrice
    end

    local unitPrice = NumberOrNil(auction.unitPrice or auction.pricePerUnit)
    if auction.isCommodity == true and unitPrice and unitPrice > 0 then
        return unitPrice
    end

    local buyout = NumberOrNil(auction.buyoutAmount or auction.buyout or auction.buyoutPrice or auction.totalPrice)
    if buyout and buyout > 0 then
        if auction.isCommodity == true then
            local quantity = self:AuctionQuantity(auction)
            if quantity > 0 then
                return math.floor((buyout / quantity) + 0.5)
            end
        end
        return buyout
    end

    if unitPrice and unitPrice > 0 then
        return unitPrice
    end

    return nil
end

function AuctionPositionService:AuctionID(auction)
    if type(auction) ~= "table" then
        return nil
    end
    return auction.auctionID or auction.auctionId or auction.id or auction.listingID or auction.listingId
end

function AuctionPositionService:IsOwnedAuction(auction, row)
    if type(auction) ~= "table" then
        return false
    end

    if auction.isOwned == true
    or auction.owned == true
    or auction.ownerIsPlayer == true
    or auction.isPlayerOwned == true then
        return true
    end

    if type(row) == "table" then
        if auction.ownerKey ~= nil and row.ownerKey ~= nil
        and tostring(auction.ownerKey) == tostring(row.ownerKey) then
            return true
        end

        if auction.owner ~= nil and row.owner ~= nil
        and tostring(auction.owner) == tostring(row.owner) then
            return true
        end
    end

    return false
end

function AuctionPositionService:BuildOwnedAuctionIDSet()
    if not C_AuctionHouse or type(C_AuctionHouse.GetOwnedAuctions) ~= "function" then
        return {}, 0
    end
    local ok, auctions = pcall(C_AuctionHouse.GetOwnedAuctions)
    if not ok or type(auctions) ~= "table" then
        return {}, 0
    end
    local ownedIDs = {}
    local count = 0
    for _, auction in ipairs(auctions) do
        local auctionID = self:AuctionID(auction)
        if auctionID ~= nil then
            ownedIDs[tostring(auctionID)] = true
            count = count + 1
        end
    end
    return ownedIDs, count
end

function AuctionPositionService:AnnotateAuctionsWithOwnership(auctions, ownedIDs, row)
    local annotatedCount = 0
    for _, auction in ipairs(auctions or {}) do
        local auctionID = self:AuctionID(auction)
        if auctionID ~= nil and ownedIDs and ownedIDs[tostring(auctionID)] then
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

function AuctionPositionService:SortAuctionEntriesByPrice(entries)
    table.sort(entries or {}, function(a, b)
        if a.price ~= b.price then
            return a.price < b.price
        end
        return (tonumber(a.originalIndex) or 0) < (tonumber(b.originalIndex) or 0)
    end)
end

function AuctionPositionService:BuildPricedEntries(matchedAuctions, row, includeInvalid)
    local entries = {}
    for originalIndex, auction in ipairs(type(matchedAuctions) == "table" and matchedAuctions or {}) do
        local price = self:AuctionPrice(auction)
        if price and price > 0 then
            entries[#entries + 1] = {
                auction = auction,
                price = price,
                owned = self:IsOwnedAuction(auction, row),
                quantity = self:AuctionQuantity(auction),
                originalIndex = originalIndex,
            }
        elseif includeInvalid == true then
            entries[#entries + 1] = {
                auction = auction,
                price = nil,
                owned = self:IsOwnedAuction(auction, row),
                quantity = self:AuctionQuantity(auction),
                originalIndex = originalIndex,
            }
        end
    end
    self:SortAuctionEntriesByPrice(entries)
    return entries
end

function AuctionPositionService:CalculateOwnedNextBuyCoverage(entries, competitionPrice)
    local coverage = 0
    local coverageRows = {}
    local started = false

    for _, entry in ipairs(entries or {}) do
        if entry.price == competitionPrice then
            started = true
            coverageRows[#coverageRows + 1] = {
                index = #coverageRows + 1,
                owned = entry.owned == true,
                auctionID = self:AuctionID(entry.auction),
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

function AuctionPositionService:OwnedAuctionIsInSequentialNextBuyBlock(entries, auctionID)
    if auctionID == nil then
        return false, { reason = "missingAuctionID" }
    end

    local pricedEntries = {}
    for _, entry in ipairs(entries or {}) do
        if entry.price ~= nil then
            pricedEntries[#pricedEntries + 1] = entry
        end
    end
    self:SortAuctionEntriesByPrice(pricedEntries)

    local lowestPrice = pricedEntries[1] and pricedEntries[1].price or nil
    local coverage, coverageRows = self:CalculateOwnedNextBuyCoverage(pricedEntries, lowestPrice)
    local inBlock = false
    local found = false
    local foundInPricedEntries = false
    for _, entry in ipairs(pricedEntries or {}) do
        local entryAuctionID = self:AuctionID(entry.auction)
        if entryAuctionID ~= nil and tostring(entryAuctionID) == tostring(auctionID) then
            foundInPricedEntries = true
            break
        end
    end
    for _, coverageRow in ipairs(coverageRows or {}) do
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

function AuctionPositionService:BuildAuctionDebugRow(index, auction, accepted, reason)
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
        unitPrice = self:AuctionPrice(auction),
        quantity = self:AuctionQuantity(auction),
        owner = auction and auction.owner,
        auctionID = auction and self:AuctionID(auction),
    }
end

function AuctionPositionService:BuildMatchAnalysis(target, auctions)
    local adapter = GetItemIdentityAdapter()
    local matcher = GetItemMatchingService()
    local analysis = {
        rawAuctionCount = #(auctions or {}),
        matchedCompetitors = {},
        rejectedAuctions = {},
        candidateRows = {},
        targetIdentity = nil,
        matchingPath = target and target.matchingPath,
    }

    if not adapter or not matcher or not matcher.Matches then
        for index, auction in ipairs(auctions or {}) do
            local row = self:BuildAuctionDebugRow(index, auction, false, "rejected: matching services unavailable")
            analysis.rejectedAuctions[#analysis.rejectedAuctions + 1] = row
            analysis.candidateRows[#analysis.candidateRows + 1] = row
        end
        return analysis
    end

    local targetIdentity = adapter:FromPostingTarget(target)
    analysis.targetIdentity = targetIdentity
    local matchingPath = target and target.matchingPath
    for _, auction in ipairs(auctions or {}) do
        local index = #analysis.candidateRows + 1
        local result = matcher:Matches(targetIdentity, adapter:FromAuctionRow(auction), matchingPath)
        local accepted = result and result.matches == true
        local reason = result and result.reason or "rejected: no match result"
        local row = self:BuildAuctionDebugRow(index, auction, accepted, reason)
        analysis.candidateRows[#analysis.candidateRows + 1] = row
        if result and result.matches == true then
            analysis.matchedCompetitors[#analysis.matchedCompetitors + 1] = auction
            analysis.matchingPath = result.matchingPath or analysis.matchingPath
        else
            analysis.rejectedAuctions[#analysis.rejectedAuctions + 1] = row
        end
    end

    return analysis
end

function AuctionPositionService:LogCancelRecommendation(row, decision, meta)
    SessionLog("Cancel evaluation auctionID=%s item=%s price=%s status=%s reason=%s lowestPrice=%s ownedNextBuyCoverage=%s",
        tostring(row and row.auctionID),
        tostring(row and row.itemName),
        tostring(row and row.price),
        tostring(decision),
        tostring(meta and meta.reason),
        tostring(meta and meta.lowestPrice),
        tostring(meta and meta.ownedNextBuyCoverage))
end
