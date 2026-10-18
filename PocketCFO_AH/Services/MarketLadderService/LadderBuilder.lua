-- PocketCFO_AH/Services/MarketLadderService/LadderBuilder.lua
-- Constructs ordered market ladders from matched competitor auctions.

local PocketCFO_AH = _G.PocketCFO_AH

local LadderBuilder = {}

local function GetSorter()
    return PocketCFO_AH and PocketCFO_AH.PurchaseOrderSorter or _G.PurchaseOrderSorter
end

local function GetAnalyzer()
    return PocketCFO_AH and PocketCFO_AH.OwnedPositionAnalyzer or _G.OwnedPositionAnalyzer
end

local function GetResultBuilder()
    return PocketCFO_AH and PocketCFO_AH.LadderResult or _G.MarketLadderResult
end

local function SourceAuction(row)
    return row and (row.auction or row.raw or row)
end

local function IsCommodity(matchedAuctions, context)
    if context and context.auctionPath == "commodity" then
        return true
    end
    local first = matchedAuctions and matchedAuctions[1]
    return first and first.auctionPath == "commodity" or false
end

local function BuildLadderRow(entry)
    local auction = entry.auction
    return {
        position = entry.position,
        auctionID = entry.auctionID,
        price = entry.price,
        quantity = entry.quantity,
        owner = entry.owner,
        ownerKey = entry.ownerKey,
        owned = entry.owned == true,
        ownershipSource = entry.ownershipSource,
        itemID = auction and auction.itemID,
        itemName = auction and auction.itemName,
        configKey = auction and auction.configKey,
        auction = auction,
    }
end

function LadderBuilder:Build(matchedAuctions, context, options)
    options = options or {}
    local result = GetResultBuilder():New(context or {})
    local sorter = GetSorter()
    local entries = {}

    for index, row in ipairs(matchedAuctions or {}) do
        entries[#entries + 1] = sorter:BuildEntry(SourceAuction(row), index)
    end
    sorter:Sort(entries)

    local ownedPositions, coverage
    if IsCommodity(matchedAuctions, context) then
        local configKey = context and context.targetConfigKey
        ownedPositions, coverage = GetAnalyzer():AnalyzeCommodity(entries, configKey)
    else
        ownedPositions, coverage = GetAnalyzer():Analyze(entries, options)
    end
    result.ownedPositions = ownedPositions
    result.ownershipCoverage = coverage

    for _, entry in ipairs(entries) do
        result.ladder[#result.ladder + 1] = BuildLadderRow(entry)
    end

    result.metadata.source = context and context.source or "matchedAuctions"
    result.metadata.inputCount = #(matchedAuctions or {})
    return GetResultBuilder():Finalize(result)
end

if PocketCFO_AH then
    PocketCFO_AH.LadderBuilder = LadderBuilder
end

_G.LadderBuilder = LadderBuilder
