-- PocketCFO_AH/Services/MarketLadderService/OwnedPositionAnalyzer.lua
-- Determines owned auction positions and ownership coverage.
-- Items use auctionID/ownerKey/ownerName matching.
-- Commodities use price-bucket matching against AHListingService.

local PocketCFO_AH = _G.PocketCFO_AH

local OwnedPositionAnalyzer = {}

local function GetAHListingService()
    local ah = _G.PocketCFO_AH
    return ah and ah.GetModule and ah:GetModule("AHListingService", true) or nil
end

local function AuctionID(row)
    return row and (row.auctionID or row.auctionId or row.id or row.listingID or row.listingId)
end

local function OwnerKey()
    local core = _G.PocketCFO
    return core and core.db and core.db.char and core.db.char.characterGUID or nil
end

local function OwnerName()
    if UnitFullName then
        local name, realm = UnitFullName("player")
        if name and realm and realm ~= "" then
            return name .. "-" .. realm
        end
        return name
    end
    return UnitName and UnitName("player") or nil
end

function OwnedPositionAnalyzer:BuildOwnedAuctionIDSet(ownedRows)
    local set = {}
    local count = 0
    for _, row in ipairs(ownedRows or {}) do
        local auctionID = AuctionID(row)
        if auctionID ~= nil then
            set[tostring(auctionID)] = true
            count = count + 1
        end
    end
    if count > 0 then
        return set, count
    end

    if C_AuctionHouse and type(C_AuctionHouse.GetOwnedAuctions) == "function" then
        local ok, rows = pcall(C_AuctionHouse.GetOwnedAuctions)
        if ok and type(rows) == "table" then
            for _, row in ipairs(rows) do
                local auctionID = AuctionID(row)
                if auctionID ~= nil then
                    set[tostring(auctionID)] = true
                    count = count + 1
                end
            end
        end
    end
    return set, count
end

function OwnedPositionAnalyzer:IsOwned(entry, ownedIDSet, ownerKey, ownerName)
    local auction = entry and entry.auction or nil
    if entry and entry.owned == true then
        return true, "flag"
    end
    local auctionID = entry and entry.auctionID
    if auctionID ~= nil and ownedIDSet and ownedIDSet[tostring(auctionID)] then
        return true, "auctionID"
    end
    if ownerKey and auction and auction.ownerKey ~= nil and tostring(auction.ownerKey) == tostring(ownerKey) then
        return true, "ownerKey"
    end
    local owner = auction and (auction.owner or auction.ownerFullName or auction.seller or auction.ownerName)
    if ownerName and owner ~= nil and tostring(owner) == tostring(ownerName) then
        return true, "ownerName"
    end
    return false, nil
end

function OwnedPositionAnalyzer:Analyze(entries, options)
    options = options or {}
    local ownedIDSet = options.ownedAuctionIDSet
    local ownedIDCount = options.ownedAuctionIDCount
    if not ownedIDSet then
        ownedIDSet, ownedIDCount = self:BuildOwnedAuctionIDSet(options.ownedAuctionRows)
    end

    local ownerKey = options.ownerKey or OwnerKey()
    local ownerName = options.ownerName or OwnerName()
    local positions = {}
    local coverage = {
        ownedQuantity = 0,
        nextBuyOwnedCoverage = 0,
        competitorQuantityBeforeFirstOwned = 0,
        ownedAuctionCount = 0,
        totalQuantity = 0,
        ownedAuctionIDCount = ownedIDCount or 0,
        coverageRows = {},
    }

    local firstOwnedSeen = false
    local lowestPrice = entries and entries[1] and entries[1].price or nil
    local nextBuyBlockOpen = lowestPrice ~= nil

    for index, entry in ipairs(entries or {}) do
        local owned, source = self:IsOwned(entry, ownedIDSet, ownerKey, ownerName)
        entry.owned = owned
        entry.ownershipSource = source
        entry.position = index
        coverage.totalQuantity = coverage.totalQuantity + (tonumber(entry.quantity) or 0)

        if owned then
            coverage.ownedQuantity = coverage.ownedQuantity + (tonumber(entry.quantity) or 0)
            coverage.ownedAuctionCount = coverage.ownedAuctionCount + 1
            firstOwnedSeen = true
            positions[#positions + 1] = {
                position = index,
                auctionID = entry.auctionID,
                price = entry.price,
                quantity = entry.quantity,
                ownershipSource = source,
            }
        elseif not firstOwnedSeen then
            coverage.competitorQuantityBeforeFirstOwned = coverage.competitorQuantityBeforeFirstOwned + (tonumber(entry.quantity) or 0)
        end

        if nextBuyBlockOpen and entry.price == lowestPrice then
            coverage.coverageRows[#coverage.coverageRows + 1] = {
                index = #coverage.coverageRows + 1,
                position = index,
                owned = owned,
                auctionID = entry.auctionID,
                price = entry.price,
                quantity = entry.quantity,
            }
            if owned then
                coverage.nextBuyOwnedCoverage = coverage.nextBuyOwnedCoverage + (tonumber(entry.quantity) or 0)
            else
                nextBuyBlockOpen = false
            end
        end
    end

    coverage.blockedQuantity = coverage.competitorQuantityBeforeFirstOwned
    coverage.coveredQuantity = coverage.nextBuyOwnedCoverage
    return positions, coverage
end

-- Commodity ownership is price-bucket-based, not auctionID-based.
-- Blizzard does not expose queue position within a commodity bucket.
-- Ownership means: the player has active quantity at the lowest visible price.
function OwnedPositionAnalyzer:AnalyzeCommodity(entries, configKey)
    local lowestBucketPrice   = entries and entries[1] and entries[1].price or nil
    local lowestBucketQuantity = 0
    local totalQuantity        = 0

    for _, entry in ipairs(entries or {}) do
        local qty = tonumber(entry.quantity) or 0
        totalQuantity = totalQuantity + qty
        if entry.price == lowestBucketPrice then
            lowestBucketQuantity = lowestBucketQuantity + qty
        end
    end

    local ownedQuantity          = 0
    local quantityInLowestBucket = 0
    if configKey then
        local ahListing = GetAHListingService()
        if ahListing then
            local ownedListings = ahListing:GetActiveOwnedByConfigKey(configKey)
            for _, listing in ipairs(ownedListings or {}) do
                local listingQty   = tonumber(listing.quantity) or 0
                local listingPrice = tonumber(listing.unitPrice) or tonumber(listing.postedPrice) or 0
                ownedQuantity = ownedQuantity + listingQty
                if lowestBucketPrice and listingPrice == lowestBucketPrice then
                    quantityInLowestBucket = quantityInLowestBucket + listingQty
                end
            end
        end
    end

    local coverage = {
        lowestBucketPrice    = lowestBucketPrice,
        lowestBucketQuantity = lowestBucketQuantity,
        ownedQuantity        = ownedQuantity,
        quantityInLowestBucket = quantityInLowestBucket,
        inLowestBucket       = quantityInLowestBucket > 0,
        totalQuantity        = totalQuantity,
    }
    return {}, coverage
end

if PocketCFO_AH then
    PocketCFO_AH.OwnedPositionAnalyzer = OwnedPositionAnalyzer
end

_G.OwnedPositionAnalyzer = OwnedPositionAnalyzer
