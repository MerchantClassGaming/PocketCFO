-- PocketCFO_AH/Services/MarketDiscoveryService/MarketDiscoveryService.lua
-- Canonical owner of AH competitor discovery and ConfigKey-based matching.
-- Phase 1 exposes the service without migrating Posting, Cancel, or Valuation.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local MarketDiscoveryService = {}

local function GetIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function GetSearch()
    return PocketCFO_AH and PocketCFO_AH.AuctionCandidateSearch or _G.AuctionCandidateSearch
end

local function GetNormalizer()
    return PocketCFO_AH and PocketCFO_AH.AuctionCandidateNormalizer or _G.AuctionCandidateNormalizer
end

local function GetFilter()
    return PocketCFO_AH and PocketCFO_AH.AuctionMatchFilter or _G.AuctionMatchFilter
end

local function GetResultBuilder()
    return PocketCFO_AH and PocketCFO_AH.MarketDiscoveryResult or _G.MarketDiscoveryResult
end

local function SafeCallback(callback, result)
    if type(callback) == "function" then
        callback(result)
    end
end

local function ResolveTarget(target)
    local identityService = GetIdentityService()
    if not identityService then
        return nil, "itemIdentityServiceUnavailable"
    end

    if type(target) == "string" then
        return {
            source = "configKey",
            configKey = target,
            auctionPath = "unknown",
        }
    end

    if type(target) ~= "table" then
        return nil, "missingTarget"
    end

    if target.configKey and not target.itemID and not target.itemLink and not target.identity then
        return {
            source = target.source or "configKey",
            configKey = target.configKey,
            auctionPath = target.auctionPath or "unknown",
        }
    end

    local identity = target.identity
    if not identity then
        if target.evidenceType == "ownedAuctionRow" and identityService.FromOwnedAuctionRow then
            identity = identityService:FromOwnedAuctionRow(target.row or target)
        elseif target.evidenceType == "auctionRow" and identityService.FromAuctionRow then
            identity = identityService:FromAuctionRow(target.row or target)
        elseif target.itemLink and identityService.FromItemLink then
            identity = identityService:FromItemLink(target.itemLink)
        elseif target.itemID and identityService.FromItemID then
            identity = identityService:FromItemID(target.itemID)
        elseif identityService.Identify then
            identity = identityService:Identify(target)
        end
    elseif not identity.configKey and identityService.BuildConfigKey then
        local configKey = identityService:BuildConfigKey(identity)
        identity.configKey = identity.configKey or configKey
    end

    if not identity or identity.unresolved or not identity.configKey then
        return nil, identity and identity.unresolvedReason or "targetConfigKeyUnavailable"
    end

    return {
        source = target.source or target.evidenceType or "target",
        identity = identity,
        configKey = identity.configKey,
        auctionPath = identity.auctionPath,
    }
end

local function CandidateSource(options)
    if options and options.source == "owned" then
        return "ownedAuctionRow"
    end
    return "auctionRow"
end

function MarketDiscoveryService:Discover(target, callback, options)
    options = options or {}
    local resolvedTarget, targetError = ResolveTarget(target)
    if not resolvedTarget then
        local result = {
            completed = true,
            targetError = targetError,
            targetSource = type(target) == "table" and target.source or nil,
            targetConfigKey = type(target) == "table" and target.configKey or nil,
            matchingAuctions = {},
            rejectedCandidates = {},
            unresolvedCandidates = {},
            candidates = {},
            candidateCount = 0,
            matchedCount = 0,
            rejectedCount = 0,
            unresolvedCount = 0,
            query = { path = "unavailable", zeroReason = targetError },
        }
        self.lastResult = result
        SafeCallback(callback, result)
        return result
    end

    local result = GetResultBuilder():New(resolvedTarget, {
        path = "pending",
        source = "MarketDiscoveryService",
    }, options)

    GetSearch():Search(resolvedTarget, options, function(rows, metadata)
        result.query = metadata or result.query
        result.candidates = GetNormalizer():NormalizeMany(rows or {}, CandidateSource(options))
        local matches, rejected, unresolved = GetFilter():Filter(resolvedTarget.configKey, result.candidates, {
            diagnostics = options.diagnostics == true,
        })
        result.matchingAuctions = matches
        result.rejectedCandidates = rejected
        result.unresolvedCandidates = unresolved
        GetResultBuilder():Finalize(result)
        self.lastResult = result
        SafeCallback(callback, result)
    end)

    return result
end

function MarketDiscoveryService:DiscoverByConfigKey(configKey, callback, options)
    return self:Discover({ source = "configKey", configKey = configKey }, callback, options)
end

function MarketDiscoveryService:DiscoverByItemID(itemID, callback, options)
    return self:Discover({ source = "itemID", itemID = tonumber(itemID) }, callback, options)
end

function MarketDiscoveryService:DiscoverByItemLink(itemLink, callback, options)
    return self:Discover({ source = "itemLink", itemLink = itemLink }, callback, options)
end

function MarketDiscoveryService:DiscoverForAuctionRow(row, callback, options)
    options = options or {}
    return self:Discover({ source = "auctionRow", evidenceType = "auctionRow", row = row }, callback, options)
end

function MarketDiscoveryService:DiscoverForOwnedAuctionRow(row, callback, options)
    options = options or {}
    return self:Discover({ source = "ownedAuctionRow", evidenceType = "ownedAuctionRow", row = row }, callback, options)
end

function MarketDiscoveryService:GetLastResult()
    return self.lastResult
end

if PocketCFO_AH then
    PocketCFO_AH.MarketDiscoveryService = MarketDiscoveryService
end

_G.MarketDiscoveryService = MarketDiscoveryService
