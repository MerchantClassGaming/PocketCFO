-- PocketCFO_AH/Services/AHListing/AHListingService.lua
-- AH-context delegation wrapper. All durable listing state is owned by
-- PocketCFO core's AuctionListingStateService. This module adds C_AuctionHouse
-- hydration on top of RecordAuctionCreated and forwards all other calls to Core.
-- Core never depends on this module; AH code may call either this wrapper or Core directly.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO    = _G.PocketCFO

local AHListingService = PocketCFO_AH:NewModule("AHListingService")

local AUCTION_CREATED_MAX_ATTEMPTS  = 4
local AUCTION_CREATED_RETRY_DELAY_SEC = 1

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function GetCoreService()
    return PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("AuctionListingStateService", true)
end

local function AuctionKey(auctionID)
    if auctionID == nil or auctionID == "" then
        return nil
    end
    return tostring(auctionID)
end

-- Helpers used only by HydrateAuctionCreated (C_AuctionHouse context)

local function GetItemIDFromLink(itemLink)
    if not itemLink then return nil end
    if GetItemInfoFromHyperlink then
        local ok, itemID = pcall(GetItemInfoFromHyperlink, itemLink)
        if ok and itemID then return tonumber(itemID) end
    end
    return tonumber(tostring(itemLink):match("item:(%d+)"))
end

local function ExtractAuctionID(info)
    return info and (info.auctionID or info.auctionId or info.listingID or info.listingId)
end

local function ExtractItemLink(info)
    return info and (info.itemLink or info.hyperlink or info.link) or nil
end

local function ExtractItemID(info, itemLink)
    if type(info) ~= "table" then return nil end
    if info.itemID or info.itemId then
        return tonumber(info.itemID or info.itemId)
    end
    if type(info.itemKey) == "table" and info.itemKey.itemID then
        return tonumber(info.itemKey.itemID)
    end
    return GetItemIDFromLink(itemLink or ExtractItemLink(info))
end

local function ExtractQuantity(info)
    local quantity = tonumber(info and (info.quantity or info.stackSize or info.count or info.numItems))
    if quantity and quantity > 0 then return quantity end
    return nil
end

local function ExtractUnitPrice(info)
    if type(info) ~= "table" then return nil end
    local unitPrice = tonumber(info.unitPrice or info.pricePerUnit or info.price)
    if unitPrice and unitPrice > 0 then return unitPrice end
    local buyout = tonumber(info.buyoutAmount or info.buyout or info.buyoutPrice or info.totalPrice)
    if buyout and buyout > 0 then return buyout end
    return nil
end

local function ExtractItemName(info, itemID, itemLink)
    if info and (info.itemName or info.name) then
        return info.itemName or info.name
    end
    if itemLink and GetItemInfo then
        local itemName = GetItemInfo(itemLink)
        if itemName then return itemName end
    end
    if itemID and GetItemInfo then
        local itemName = GetItemInfo(itemID)
        if itemName then return itemName end
    end
    if info and info.itemKey and C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
        local ok, itemKeyInfo = pcall(C_AuctionHouse.GetItemKeyInfo, info.itemKey)
        if ok and itemKeyInfo and itemKeyInfo.itemName then
            return itemKeyInfo.itemName
        end
    end
    return nil
end

local function GetOwnerKey()
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.char
        and PocketCFO.db.char.characterGUID
        or nil
end

local function NormalizeOwnedAuctionEvidence(info)
    if type(info) ~= "table" then
        return nil, "missingOwnedAuctionInfo"
    end
    local auctionID = ExtractAuctionID(info)
    local itemLink  = ExtractItemLink(info)
    local itemID    = ExtractItemID(info, itemLink)
    local quantity  = ExtractQuantity(info)
    local unitPrice = ExtractUnitPrice(info)
    local itemName  = ExtractItemName(info, itemID, itemLink)

    return {
        auctionID      = auctionID,
        itemID         = itemID,
        itemName       = itemName,
        itemLink       = itemLink,
        itemGUID       = info.itemGUID or info.itemGuid or info.guid,
        quantity       = quantity,
        unitPrice      = unitPrice,
        buyout         = unitPrice,
        ownerKey       = info.ownerKey or GetOwnerKey(),
        itemKey        = info.itemKey,
        rarityQuality  = info.rarityQuality or info.quality,
        itemQuality    = info.itemQuality or info.craftingQuality,
        craftingQuality = info.craftingQuality or info.itemQuality,
        ilvl           = info.ilvl or info.itemLevel,
        itemClassID    = info.itemClassID or info.classID,
        itemSubClassID = info.itemSubClassID or info.subClassID or info.subclassID,
        equipLoc       = info.equipLoc or info.inventoryType,
        isStackable    = info.isStackable,
        timeLeft       = info.timeLeft or info.durationLeft or info.duration,
        durationLeft   = info.durationLeft or info.timeLeft or info.duration,
        source         = "owned_hydration",
    }, nil
end

local function FindOwnedAuctionInfo(auctionID)
    local wanted = AuctionKey(auctionID)
    if not wanted or not C_AuctionHouse then return nil end

    if type(C_AuctionHouse.GetOwnedAuctions) == "function" then
        local ok, infos = pcall(C_AuctionHouse.GetOwnedAuctions)
        if ok and type(infos) == "table" then
            for _, info in ipairs(infos) do
                if AuctionKey(ExtractAuctionID(info)) == wanted then return info end
            end
            for _, info in pairs(infos) do
                if type(info) == "table" and AuctionKey(ExtractAuctionID(info)) == wanted then return info end
            end
        end
    end

    if type(C_AuctionHouse.GetNumOwnedAuctions) == "function" and type(C_AuctionHouse.GetOwnedAuctionInfo) == "function" then
        local okCount, count = pcall(C_AuctionHouse.GetNumOwnedAuctions)
        count = okCount and tonumber(count) or 0
        for index = 1, count do
            local okInfo, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, index)
            if okInfo and AuctionKey(ExtractAuctionID(info)) == wanted then return info end
        end
    end

    return nil
end

local function QueryOwnedAuctions()
    if not C_AuctionHouse or type(C_AuctionHouse.QueryOwnedAuctions) ~= "function" then
        return false
    end
    local ok = pcall(C_AuctionHouse.QueryOwnedAuctions, {})
    if not ok then
        ok = pcall(C_AuctionHouse.QueryOwnedAuctions)
    end
    return ok and true or false
end

-- Delegation methods: all durable state passes through Core AuctionListingStateService

function AHListingService:GetListing(auctionID)
    local s = GetCoreService()
    return s and s:GetListing(auctionID)
end

function AHListingService:UpsertListingEvidence(evidence, source)
    local s = GetCoreService()
    return s and s:UpsertListingEvidence(evidence, source)
end

function AHListingService:RecordPostedAuction(evidence)
    local s = GetCoreService()
    return s and s:RecordPostedAuction(evidence)
end

-- RecordAuctionCreated: writes to Core then triggers C_AuctionHouse hydration.
function AHListingService:RecordAuctionCreated(evidence)
    evidence = evidence or {}
    local auctionID = evidence.auctionID
    local s = GetCoreService()
    if not s then return nil end
    local row = s:RecordAuctionCreated(evidence)
    QueryOwnedAuctions()
    return self:HydrateAuctionCreated(auctionID, evidence, 1) or row
end

function AHListingService:HydrateAuctionCreated(auctionID, eventEvidence, attempt)
    local key = AuctionKey(auctionID)
    if not key then return nil end
    local s = GetCoreService()
    if not s then return nil end

    attempt = tonumber(attempt) or 1
    local ownedInfo = FindOwnedAuctionInfo(auctionID)
    if ownedInfo then
        local evidence = NormalizeOwnedAuctionEvidence(ownedInfo)
        evidence = evidence or {}
        eventEvidence = type(eventEvidence) == "table" and eventEvidence or {}
        evidence.auctionID   = auctionID
        evidence.source      = "owned_hydration"
        evidence.itemID      = evidence.itemID    or eventEvidence.itemID
        evidence.itemName    = evidence.itemName  or eventEvidence.itemName
        evidence.itemLink    = evidence.itemLink  or eventEvidence.itemLink
        evidence.itemGUID    = evidence.itemGUID  or eventEvidence.itemGUID
        evidence.quantity    = evidence.quantity  or eventEvidence.quantity
        evidence.unitPrice   = evidence.unitPrice or eventEvidence.unitPrice or eventEvidence.buyout
        evidence.buyout      = evidence.buyout    or evidence.unitPrice
        evidence.ownerKey    = evidence.ownerKey  or eventEvidence.ownerKey
        evidence.postedAt    = eventEvidence.postedAt
        evidence.durationHours = eventEvidence.durationHours

        local row = s:ConfirmOwnedAuction(evidence, "owned_hydration")
        if row then
            SessionLog("AHListingService: auction-created hydrated auctionID=%s attempt=%d configKey=%s",
                tostring(auctionID), attempt, tostring(row.configKey))
            return row
        end
    end

    if attempt < AUCTION_CREATED_MAX_ATTEMPTS and C_Timer and C_Timer.After then
        C_Timer.After(AUCTION_CREATED_RETRY_DELAY_SEC, function()
            QueryOwnedAuctions()
            self:HydrateAuctionCreated(auctionID, eventEvidence, attempt + 1)
        end)
        return nil
    end

    SessionLog("AHListingService: auction-created pending auctionID=%s attempts=%d reason=%s",
        tostring(auctionID), attempt,
        ownedInfo and "ownedAuctionHydrationIncomplete" or "ownedAuctionNotYetAvailable")
    return s:GetListing(auctionID)
end

function AHListingService:ConfirmOwnedAuction(evidence, source)
    local s = GetCoreService()
    return s and s:ConfirmOwnedAuction(evidence, source)
end

function AHListingService:CloseAuction(auctionID, status, evidence)
    local s = GetCoreService()
    return s and s:CloseAuction(auctionID, status, evidence)
end

function AHListingService:MarkCancelled(auctionID, evidence)
    local s = GetCoreService()
    return s and s:MarkCancelled(auctionID, evidence)
end

function AHListingService:RecordAuctionEnded(auctionID, outcome, evidence)
    local s = GetCoreService()
    return s and s:RecordAuctionEnded(auctionID, outcome, evidence)
end

function AHListingService:IsOwnedAuctionID(auctionID)
    local s = GetCoreService()
    return s and s:IsOwnedAuctionID(auctionID) or false
end

function AHListingService:GetActiveOwnedByConfigKey(configKey)
    local s = GetCoreService()
    return s and s:GetActiveOwnedByConfigKey(configKey) or {}
end

function AHListingService:GetActiveOwnedListings(options)
    local s = GetCoreService()
    return s and s:GetActiveOwnedListings(options) or {}
end

function AHListingService:BackfillMissingOwnedAuctions(ownedAuctionRows)
    local s = GetCoreService()
    if not s then return 0, 0 end
    return s:BackfillMissingOwnedAuctions(ownedAuctionRows)
end

function AHListingService:ReconcileActiveOwnedAuctions(ownedAuctionRows, options)
    local s = GetCoreService()
    if not s then return 0, 0, 0 end
    return s:ReconcileActiveOwnedAuctions(ownedAuctionRows, options)
end

function AHListingService:PruneInactiveListings(options)
    local s = GetCoreService()
    return s and s:PruneInactiveListings(options)
end

function AHListingService:GetRetentionPolicy()
    local s = GetCoreService()
    return s and s:GetRetentionPolicy() or { retentionDays = 30, maxInactiveRows = 5000 }
end

function AHListingService:GetLastPruneStats()
    local s = GetCoreService()
    return s and s:GetLastPruneStats() or {
        retentionDays = 30, maxInactiveRows = 5000, prunedByAge = 0, prunedByCap = 0,
    }
end

function AHListingService:ClearForDiagnostics()
    local s = GetCoreService()
    return s and s:ClearForDiagnostics()
end

function AHListingService:OnInitialize()
    SessionLog("AHListingService OnInitialize (delegates to AuctionListingStateService)")
end

function AHListingService:OnEnable()
end
