-- PocketCFO_AH/Services/MarketLadderService/MarketLadderService.lua
-- Canonical owner of auction purchase ordering and market ladder construction.
-- Phase 1 exposes the service without migrating Posting, Cancel, or Valuation.

local PocketCFO_AH = _G.PocketCFO_AH

local MarketLadderService = {}

local function GetDiscoveryService()
    return PocketCFO_AH and PocketCFO_AH.MarketDiscoveryService or _G.MarketDiscoveryService
end

local function GetBuilder()
    return PocketCFO_AH and PocketCFO_AH.LadderBuilder or _G.LadderBuilder
end

local function SafeCallback(callback, result)
    if type(callback) == "function" then
        callback(result)
    end
end

local function ContextFromDiscovery(discovery)
    return {
        source = "MarketDiscoveryService",
        targetSource = discovery and discovery.targetSource,
        targetConfigKey = discovery and discovery.targetConfigKey,
        targetIdentity = discovery and discovery.targetIdentity,
        auctionPath = discovery and discovery.auctionPath,
        discovery = {
            candidateCount = discovery and discovery.candidateCount or 0,
            matchedCount = discovery and discovery.matchedCount or 0,
            rejectedCount = discovery and discovery.rejectedCount or 0,
            unresolvedCount = discovery and discovery.unresolvedCount or 0,
            query = discovery and discovery.query,
            rejectedCandidates = discovery and discovery.rejectedCandidates,
            unresolvedCandidates = discovery and discovery.unresolvedCandidates,
        },
    }
end

function MarketLadderService:BuildFromMatchedAuctions(matchedAuctions, context, options)
    local result = GetBuilder():Build(matchedAuctions or {}, context or { source = "matchedAuctions" }, options or {})
    self.lastResult = result
    return result
end

function MarketLadderService:BuildFromDiscoveryResult(discoveryResult, options)
    local result = self:BuildFromMatchedAuctions(
        discoveryResult and discoveryResult.matchingAuctions or {},
        ContextFromDiscovery(discoveryResult),
        options
    )
    result.discoveryResult = discoveryResult
    self.lastResult = result
    return result
end

function MarketLadderService:BuildForTarget(target, callback, options)
    options = options or {}
    local discovery = GetDiscoveryService()
    if not discovery or type(discovery.Discover) ~= "function" then
        local result = self:BuildFromMatchedAuctions({}, {
            source = "MarketDiscoveryService",
            targetError = "marketDiscoveryServiceUnavailable",
            discovery = {
                candidateCount = 0,
                matchedCount = 0,
                rejectedCount = 0,
                unresolvedCount = 0,
                query = { path = "unavailable", zeroReason = "marketDiscoveryServiceUnavailable" },
            },
        }, options)
        SafeCallback(callback, result)
        return result
    end

    return discovery:Discover(target, function(discoveryResult)
        local result = self:BuildFromDiscoveryResult(discoveryResult, options)
        SafeCallback(callback, result)
    end, options)
end

function MarketLadderService:BuildByItemID(itemID, callback, options)
    return self:BuildForTarget({ source = "itemID", itemID = tonumber(itemID) }, callback, options)
end

function MarketLadderService:BuildByConfigKey(configKey, callback, options)
    return self:BuildForTarget({ source = "configKey", configKey = configKey }, callback, options)
end

function MarketLadderService:BuildByItemLink(itemLink, callback, options)
    return self:BuildForTarget({ source = "itemLink", itemLink = itemLink }, callback, options)
end

function MarketLadderService:BuildForOwnedAuctionRow(row, callback, options)
    options = options or {}
    options.source = options.source or "owned"
    return self:BuildForTarget({ source = "ownedAuctionRow", evidenceType = "ownedAuctionRow", row = row }, callback, options)
end

function MarketLadderService:GetLastResult()
    return self.lastResult
end

if PocketCFO_AH then
    PocketCFO_AH.MarketLadderService = MarketLadderService
end

_G.MarketLadderService = MarketLadderService
