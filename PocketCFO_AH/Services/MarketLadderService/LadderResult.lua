-- PocketCFO_AH/Services/MarketLadderService/LadderResult.lua
-- Result helpers for ordered market ladders.

local PocketCFO_AH = _G.PocketCFO_AH

local LadderResult = {}

function LadderResult:New(context)
    context = context or {}
    return {
        targetSource = context.targetSource,
        targetConfigKey = context.targetConfigKey,
        targetIdentity = context.targetIdentity,
        auctionPath = context.auctionPath,
        discovery = context.discovery,
        ladder = {},
        nextBuy = nil,
        ownedPositions = {},
        ownershipCoverage = {
            ownedQuantity = 0,
            nextBuyOwnedCoverage = 0,
            competitorQuantityBeforeFirstOwned = 0,
            ownedAuctionCount = 0,
            totalQuantity = 0,
        },
        metadata = {
            source = context.source or "MarketLadderService",
        },
        completed = false,
    }
end

function LadderResult:Finalize(result)
    result.ladderCount = #(result.ladder or {})
    result.ownedPositionCount = #(result.ownedPositions or {})
    result.nextBuy = result.ladder and result.ladder[1] or nil
    result.completed = true
    return result
end

if PocketCFO_AH then
    PocketCFO_AH.LadderResult = LadderResult
end

_G.MarketLadderResult = LadderResult
