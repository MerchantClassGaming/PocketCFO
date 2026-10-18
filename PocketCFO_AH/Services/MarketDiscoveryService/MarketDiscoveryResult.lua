-- PocketCFO_AH/Services/MarketDiscoveryService/MarketDiscoveryResult.lua
-- Result object helpers for market discovery runs.

local PocketCFO_AH = _G.PocketCFO_AH

local MarketDiscoveryResult = {}

local function CopyIdentitySummary(identity)
    if type(identity) ~= "table" then
        return nil
    end
    return {
        itemID = identity.itemID,
        itemName = identity.itemName,
        itemLink = identity.itemLink,
        configKey = identity.configKey,
        auctionPath = identity.auctionPath,
        matchingPath = identity.matchingPath,
        classification = identity.classification,
        variantType = identity.variantType,
        unresolved = identity.unresolved,
        unresolvedReason = identity.unresolvedReason,
    }
end

function MarketDiscoveryResult:New(target, metadata, options)
    options = options or {}
    local identity = target and target.identity or nil
    return {
        targetSource = target and target.source,
        targetConfigKey = target and target.configKey,
        targetIdentity = CopyIdentitySummary(identity),
        auctionPath = target and (target.auctionPath or identity and identity.auctionPath),
        query = metadata or {},
        candidates = {},
        matchingAuctions = {},
        rejectedCandidates = {},
        unresolvedCandidates = {},
        diagnosticsEnabled = options.diagnostics == true,
        completed = false,
    }
end

function MarketDiscoveryResult:Finalize(result)
    result.candidateCount = #(result.candidates or {})
    result.matchedCount = #(result.matchingAuctions or {})
    result.rejectedCount = #(result.rejectedCandidates or {})
    result.unresolvedCount = #(result.unresolvedCandidates or {})
    result.completed = true
    return result
end

if PocketCFO_AH then
    PocketCFO_AH.MarketDiscoveryResult = MarketDiscoveryResult
end

_G.MarketDiscoveryResult = MarketDiscoveryResult
