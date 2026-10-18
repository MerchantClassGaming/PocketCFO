-- PocketCFO/Services/ItemIdentityService/AuctionPathResolver.lua
-- Derives auction routing from canonical commodity status.

local PocketCFO = _G.PocketCFO

local AuctionPathResolver = {}

local function BooleanOrNil(value)
    if value == true or value == "true" then
        return true
    end
    if value == false or value == "false" then
        return false
    end
    return nil
end

function AuctionPathResolver:Resolve(identity)
    local isCommodity = BooleanOrNil(identity and identity.isCommodity)
    if isCommodity == true then
        return "commodity"
    end

    return "item"
end

if PocketCFO then
    PocketCFO.ItemAuctionPathResolver = AuctionPathResolver
end

_G.PocketCFO_ItemAuctionPathResolver = AuctionPathResolver
