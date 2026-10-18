-- PocketCFO_AH/Services/MarketDiscoveryService/AuctionMatchFilter.lua
-- Applies ConfigKey equality to candidate auctions.

local PocketCFO_AH = _G.PocketCFO_AH

local AuctionMatchFilter = {}

function AuctionMatchFilter:Filter(targetConfigKey, candidates, options)
    options = options or {}
    local matches = {}
    local rejected = {}
    local unresolved = {}

    for _, candidate in ipairs(candidates or {}) do
        if candidate.unresolved or not candidate.configKey then
            unresolved[#unresolved + 1] = {
                candidate = candidate,
                reason = candidate.unresolvedReason or "candidateConfigKeyUnavailable",
            }
        elseif candidate.configKey == targetConfigKey then
            matches[#matches + 1] = candidate
        elseif options.diagnostics == true then
            rejected[#rejected + 1] = {
                candidate = candidate,
                reason = string.format("configKey mismatch target=%s candidate=%s", tostring(targetConfigKey), tostring(candidate.configKey)),
            }
        end
    end

    return matches, rejected, unresolved
end

if PocketCFO_AH then
    PocketCFO_AH.AuctionMatchFilter = AuctionMatchFilter
end

_G.AuctionMatchFilter = AuctionMatchFilter
