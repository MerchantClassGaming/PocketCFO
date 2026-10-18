-- PocketCFO_AH/Services/MarketDiscoveryService/AuctionCandidateNormalizer.lua
-- Normalizes auction rows and resolves their canonical identities.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local AuctionCandidateNormalizer = {}

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

local function GetIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function ExtractItemID(row)
    if type(row) ~= "table" then
        return nil
    end
    if row.itemID or row.itemId then
        return NumberOrNil(row.itemID or row.itemId)
    end
    if type(row.itemKey) == "table" then
        return NumberOrNil(row.itemKey.itemID)
    end
    local itemLink = row.itemLink or row.hyperlink or row.link
    if itemLink and GetItemInfoFromHyperlink then
        local ok, itemID = pcall(GetItemInfoFromHyperlink, itemLink)
        if ok then
            return NumberOrNil(itemID)
        end
    end
    return itemLink and NumberOrNil(tostring(itemLink):match("item:(%d+)")) or nil
end

local function Summary(row, identity, source)
    return {
        source = source,
        auctionID = row and (row.auctionID or row.auctionId or row.listingID or row.listingId),
        itemID = identity and identity.itemID or ExtractItemID(row),
        itemName = identity and identity.itemName or row and (row.itemName or row.name),
        itemLink = identity and identity.itemLink or row and (row.itemLink or row.hyperlink or row.link),
        quantity = row and (row.quantity or row.stackSize or row.count or row.numItems),
        unitPrice = row and (row.unitPrice or row.pricePerUnit or row.price),
        buyoutAmount = row and (row.buyoutAmount or row.buyout or row.buyoutPrice or row.totalPrice),
        owner = row and (row.owner or row.ownerFullName or row.seller or row.ownerName),
        timeLeft = row and (row.timeLeft or row.durationLeft or row.duration),
        configKey = identity and identity.configKey,
        auctionPath = identity and identity.auctionPath,
        unresolved = identity and identity.unresolved,
        unresolvedReason = identity and identity.unresolvedReason,
    }
end

function AuctionCandidateNormalizer:Normalize(row, source)
    source = source or "auctionRow"
    local identityService = GetIdentityService()
    local identity
    if identityService then
        if source == "ownedAuctionRow" and identityService.FromOwnedAuctionRow then
            identity = identityService:FromOwnedAuctionRow(row)
        elseif identityService.FromAuctionRow then
            identity = identityService:FromAuctionRow(row)
        end
    end

    local normalized = Summary(row, identity, source)
    normalized.raw = row
    normalized.identity = identity
    if not identity or identity.unresolved or not identity.configKey then
        normalized.unresolved = true
        normalized.unresolvedReason = identity and identity.unresolvedReason or "identityUnavailable"
    end
    return normalized
end

function AuctionCandidateNormalizer:NormalizeMany(rows, source)
    local normalized = {}
    for _, row in ipairs(rows or {}) do
        normalized[#normalized + 1] = self:Normalize(row, source)
    end
    return normalized
end

if PocketCFO_AH then
    PocketCFO_AH.AuctionCandidateNormalizer = AuctionCandidateNormalizer
end

_G.AuctionCandidateNormalizer = AuctionCandidateNormalizer
