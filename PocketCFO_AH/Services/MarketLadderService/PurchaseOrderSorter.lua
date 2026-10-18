-- PocketCFO_AH/Services/MarketLadderService/PurchaseOrderSorter.lua
-- Purchase-order sorting rules for Auction House competitors.

local PocketCFO_AH = _G.PocketCFO_AH

local PurchaseOrderSorter = {}

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

function PurchaseOrderSorter:AuctionQuantity(auction)
    local quantity = math.floor(tonumber(auction and (auction.quantity or auction.count or auction.stackSize or auction.numItems)) or 0)
    if quantity > 0 then
        return quantity
    end
    return 1
end

function PurchaseOrderSorter:AuctionID(auction)
    if type(auction) ~= "table" then
        return nil
    end
    return auction.auctionID or auction.auctionId or auction.id or auction.listingID or auction.listingId
end

function PurchaseOrderSorter:AuctionPrice(auction)
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

function PurchaseOrderSorter:BuildEntry(auction, originalIndex)
    return {
        auction = auction,
        auctionID = self:AuctionID(auction),
        price = self:AuctionPrice(auction),
        quantity = self:AuctionQuantity(auction),
        originalIndex = originalIndex,
        owner = auction and (auction.owner or auction.ownerFullName or auction.seller or auction.ownerName),
        ownerKey = auction and auction.ownerKey,
        owned = auction and (auction.isOwned == true or auction.owned == true or auction.ownerIsPlayer == true or auction.isPlayerOwned == true) or false,
    }
end

function PurchaseOrderSorter:Sort(entries)
    table.sort(entries or {}, function(a, b)
        if a.price == nil and b.price ~= nil then
            return false
        end
        if a.price ~= nil and b.price == nil then
            return true
        end
        if a.price ~= b.price then
            return (a.price or 0) < (b.price or 0)
        end
        return (tonumber(a.originalIndex) or 0) < (tonumber(b.originalIndex) or 0)
    end)
    return entries
end

if PocketCFO_AH then
    PocketCFO_AH.PurchaseOrderSorter = PurchaseOrderSorter
end

_G.PurchaseOrderSorter = PurchaseOrderSorter
