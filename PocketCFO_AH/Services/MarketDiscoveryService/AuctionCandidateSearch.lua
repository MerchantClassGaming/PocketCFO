-- PocketCFO_AH/Services/MarketDiscoveryService/AuctionCandidateSearch.lua
-- Candidate auction search orchestration. Matching is handled elsewhere.

local PocketCFO_AH = _G.PocketCFO_AH

local AuctionCandidateSearch = {}

local function SafeCallback(callback, result, metadata)
    if type(callback) == "function" then
        callback(result, metadata)
    end
end

local function GetAuctionLookupService()
    return PocketCFO_AH and PocketCFO_AH.AuctionLookupService or _G.AuctionLookupService
end

local function GetOwnedAuctionsScanner()
    if PocketCFO_AH and PocketCFO_AH.GetModule then
        local ok, scanner = pcall(PocketCFO_AH.GetModule, PocketCFO_AH, "OwnedAuctionsScanner", true)
        if ok and scanner then
            return scanner
        end
    end
    return nil
end

local function BuildLookupRow(target)
    local identity = target and target.identity or {}
    return {
        itemID = identity.itemID,
        targetItemID = identity.itemID,
        itemName = identity.itemName,
        itemLink = identity.itemLink,
        candidate = identity,
        target = {
            debugItemID = identity.itemID,
            targetItemID = identity.itemID,
            postAPI = target and target.auctionPath == "commodity" and "PostCommodity" or nil,
        },
    }
end

function AuctionCandidateSearch:Search(target, options, callback)
    options = options or {}

    if type(options.candidates) == "table" then
        SafeCallback(callback, options.candidates, {
            path = "providedCandidates",
            source = "options.candidates",
            rawCount = #options.candidates,
            completed = true,
        })
        return true
    end

    if options.source == "owned" then
        local scanner = GetOwnedAuctionsScanner()
        local rows = scanner and scanner.GetOwnedAuctionInfos and scanner:GetOwnedAuctionInfos() or {}
        SafeCallback(callback, rows, {
            path = "ownedAuctions",
            source = "OwnedAuctionsScanner:GetOwnedAuctionInfos",
            rawCount = #rows,
            completed = true,
        })
        return true
    end

    if not target or not target.identity or not target.identity.itemID then
        SafeCallback(callback, {}, {
            path = "unavailable",
            source = "none",
            rawCount = 0,
            completed = true,
            zeroReason = "target has no searchable itemID",
        })
        return false
    end

    local lookup = GetAuctionLookupService()
    if not lookup or type(lookup.GetAuctionsForRow) ~= "function" then
        SafeCallback(callback, {}, {
            path = "unavailable",
            source = "AuctionLookupService",
            rawCount = 0,
            completed = true,
            zeroReason = "AuctionLookupService unavailable",
        })
        return false
    end

    lookup:GetAuctionsForRow(BuildLookupRow(target), function(rows, metadata)
        metadata = metadata or {}
        metadata.path = metadata.path or target.auctionPath or "itemAuction"
        metadata.source = metadata.source or "AuctionLookupService:GetAuctionsForRow"
        metadata.rawCount = metadata.rawCount or #(rows or {})
        SafeCallback(callback, rows or {}, metadata)
    end)
    return true
end

if PocketCFO_AH then
    PocketCFO_AH.AuctionCandidateSearch = AuctionCandidateSearch
end

_G.AuctionCandidateSearch = AuctionCandidateSearch
