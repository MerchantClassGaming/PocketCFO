-- PocketCFO_AH/Posting/Components/PostingLifecycleController.lua
-- Coordinates auction-created side effects: AHListingService write, snapshot adjustment,
-- lifecycle ledger transition, and AHLedger upsert.

local ADDON_NAME, _ = ...
local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingLifecycleController = {}
PocketCFO_AH.PostingLifecycleController = PostingLifecycleController

local function Debug(msg, ...)
    if PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug(msg, ...)
    end
end

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function HasGUID(value)
    return value ~= nil and tostring(value) ~= ""
end

local function NormalizeKeyNumber(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function GetInventoryQuality(row)
    return NormalizeKeyNumber(row and row.craftingQuality)
        or NormalizeKeyNumber(row and row.itemQuality)
        or 0
end

local function DebugIdentityKey(row)
    return string.format("%d|%s|%s|%s",
        tonumber(row and row.itemID) or 0,
        tostring(GetInventoryQuality(row)),
        tostring(row and row.ilvl or 0),
        tostring(row and row.statFingerprint or ""))
end

local function DebugRowSummary(row)
    if type(row) ~= "table" then
        return "nil"
    end
    return string.format("itemID=%s itemName=%s qty=%s quality=%s craftedQuality=%s ilvl=%s itemGUID=%s itemLink=%s key=%s",
        tostring(row.itemID), tostring(row.itemName), tostring(row.quantity),
        tostring(row.itemQuality), tostring(row.craftingQuality), tostring(row.ilvl),
        tostring(row.itemGUID), tostring(row.itemLink), DebugIdentityKey(row))
end

local function RowMatchesDebugIdentity(row, identity)
    if type(row) ~= "table" or type(identity) ~= "table" then
        return false
    end
    return DebugIdentityKey(row) == DebugIdentityKey(identity)
end

local function FindDebugIdentityRow(rows, identity)
    for index, row in ipairs(rows or {}) do
        if RowMatchesDebugIdentity(row, identity) then
            return row, index, "exact"
        end
    end
    for index, row in ipairs(rows or {}) do
        if tonumber(row and row.itemID) == tonumber(identity and identity.itemID) then
            return row, index, "itemID"
        end
    end
    return nil, nil, "none"
end

local function GetInventoryStateService()
    return PocketCFO and (PocketCFO.InventoryStateService or _G.InventoryStateService) or _G.InventoryStateService
end

local function GetAHSnapshotRows(ownerKey)
    local inventoryState = GetInventoryStateService()
    if inventoryState and inventoryState.GetLocationSnapshot then
        return inventoryState:GetLocationSnapshot(ownerKey, "ah") or {}
    end
    return {}
end

local function GetLocationSnapshotMatch(ownerKey, location, identity)
    local inventoryState = GetInventoryStateService()
    local rows = inventoryState and inventoryState.GetLocationSnapshot and inventoryState:GetLocationSnapshot(ownerKey, location) or {}
    local row, index, tier = FindDebugIdentityRow(rows, identity)
    return row, index, tier, #(rows or {})
end

local function MissingDB()
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.global
        and PocketCFO.db.global.missingLedger
        or {}
end

local function ClearMissingEntry(row)
    if not row then
        return
    end
    local missingLedger = MissingDB()
    missingLedger[row.ledgerID] = nil
    missingLedger[tostring(row.ledgerID)] = nil
    for key, entry in pairs(missingLedger) do
        if entry
        and (entry.ledgerID == row.ledgerID
            or tostring(entry.ledgerID) == tostring(row.ledgerID)
            or entry.itemGUID == row.itemGUID
            or tostring(entry.itemGUID or "") == tostring(row.itemGUID)) then
            missingLedger[key] = nil
        end
    end
end

local function EnsureAHLifecycleRowForPost(ledger, pending, auctionID)
    if not ledger or not pending or not HasGUID(pending.itemGUID) then
        return nil, "ledger_unavailable"
    end

    local row = ledger:GetActiveRowByItemGUID(pending.itemGUID)
    if row then
        return row, nil
    end

    local ownerKey = pending.ownerKey
        or (PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID)
        or ""
    local ledgerID = ledger:OpenRow({
        characterGUID   = ownerKey,
        ownerKey        = ownerKey,
        itemID          = pending.itemID or 0,
        itemName        = pending.itemName or "Unknown",
        itemGUID        = pending.itemGUID,
        craftingQuality = pending.craftingQuality or pending.itemQuality,
        itemQuality     = pending.itemQuality or pending.craftingQuality,
        ilvl            = pending.ilvl,
        statFingerprint = pending.statFingerprint,
        source          = "unknown",
        location        = "ah",
        auctionID       = auctionID,
        soulbound       = false,
        acquiredAt      = Now(),
    })

    if ledgerID and ledger.GetRow then
        return ledger:GetRow(ledgerID), "opened_unknown_ah_row"
    end

    return nil, "open_failed"
end

-- Records the newly created auction in AuctionListingStateService with full posting metadata.
-- Requires auctionID from the AUCTION_HOUSE_AUCTION_CREATED event. If auctionID is nil
-- (event arg delivery unverified in-game), this is a no-op and the listing will instead be
-- discovered on the next OWNED_AUCTIONS_UPDATED scan via BackfillMissingOwnedAuctions.
-- That backfilled listing will lack postedAt and durationHours.
-- HandleAuctionCreated logs the received auctionID value for in-game verification.
local function RecordAuctionCreatedInAHListing(auctionID, pending)
    if auctionID == nil or auctionID == "" then
        return
    end
    local ahListing = PocketCFO_AH and PocketCFO_AH.GetModule and PocketCFO_AH:GetModule("AHListingService", true)
    if not ahListing or type(ahListing.RecordAuctionCreated) ~= "function" then
        return
    end
    pending = type(pending) == "table" and pending or {}
    ahListing:RecordAuctionCreated({
        source          = "auction_created_event",
        auctionID       = auctionID,
        itemID          = pending.itemID,
        itemName        = pending.itemName,
        itemLink        = pending.itemLink,
        itemGUID        = pending.itemGUID,
        quantity        = pending.quantity,
        unitPrice       = pending.buyout or pending.unitPrice,
        buyout          = pending.buyout,
        durationHours   = pending.durationHours,
        ownerKey        = pending.ownerKey or (PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID),
        postedAt        = pending.capturedAt or Now(),
        itemQuality     = pending.itemQuality,
        craftingQuality = pending.craftingQuality,
        rarityQuality   = pending.rarityQuality,
        ilvl            = pending.ilvl,
        statFingerprint = pending.statFingerprint,
        itemStats       = pending.itemStats,
        isStackable     = pending.isStackable,
    })
end

function PostingLifecycleController:StartPostDebugContext(pending, auctionID)
    if not PocketCFO or type(pending) ~= "table" then
        return
    end
    PocketCFO.ahPostDebugContext = {
        ownerKey        = pending.ownerKey,
        auctionID       = auctionID,
        row             = pending,
        cyclesRemaining = 3,
        cyclesSeen      = 0,
        startedAt       = Now(),
    }
    SessionLog("AHManager: post debug context started auctionID=%s owner=%s %s",
        tostring(auctionID), tostring(pending.ownerKey), DebugRowSummary(pending))
end

function PostingLifecycleController:LogPostOwnedAuctionCycle(observation)
    local context = PocketCFO and PocketCFO.ahPostDebugContext
    if not context or (tonumber(context.cyclesRemaining) or 0) <= 0 then
        return
    end

    context.cyclesSeen      = (tonumber(context.cyclesSeen) or 0) + 1
    context.cyclesRemaining = (tonumber(context.cyclesRemaining) or 0) - 1

    local identity       = context.row or {}
    local normalizedRows = (observation and (observation.rows or observation.items)) or {}
    local normalizedMatch, normalizedIndex, normalizedTier = FindDebugIdentityRow(normalizedRows, identity)
    local storedRows     = (observation and observation.storedRows) or GetAHSnapshotRows(context.ownerKey)
    local snapshotMatch, snapshotIndex, snapshotTier = FindDebugIdentityRow(storedRows, identity)

    SessionLog("AHManager: post owned-auctions debug cycle=%d remaining=%d auctionID=%s owner=%s normalizedRows=%d normalizedFound=%s normalizedTier=%s normalizedIndex=%s normalizedRow={%s} snapshotWritten=%s finalSnapshotRows=%d snapshotFound=%s snapshotTier=%s snapshotIndex=%s snapshotRow={%s}",
        tonumber(context.cyclesSeen) or 0,
        tonumber(context.cyclesRemaining) or 0,
        tostring(context.auctionID),
        tostring(context.ownerKey),
        #normalizedRows,
        tostring(normalizedMatch ~= nil),
        tostring(normalizedTier),
        tostring(normalizedIndex),
        DebugRowSummary(normalizedMatch),
        tostring(observation and observation.snapshotWritten),
        #storedRows,
        tostring(snapshotMatch ~= nil),
        tostring(snapshotTier),
        tostring(snapshotIndex),
        DebugRowSummary(snapshotMatch))

    if context.cyclesRemaining <= 0 then
        SessionLog("AHManager: post owned-auctions debug complete auctionID=%s key=%s",
            tostring(context.auctionID), DebugIdentityKey(identity))
    end
end

-- Routes post inventory movement through InventoryStateService as an adjustment
-- (bags -quantity, ah +quantity) layered over the last authoritative snapshot.
-- This is best-known current-state only; it does not write a new snapshot or
-- claim a scan occurred. The next AH-open sync scan clears this adjustment and
-- replaces it with observed truth.
function PostingLifecycleController:ApplyPostInventoryAdjustment(pendingPost, auctionID)
    if type(pendingPost) ~= "table" then
        SessionLog("AHManager: post inventory adjustment skipped reason=no-pending-post")
        return false, "noPendingPost"
    end

    local ownerKey = pendingPost.ownerKey
        or (PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID)
    local itemID   = tonumber(pendingPost.itemID)
    local quantity = tonumber(pendingPost.quantity) or 0

    if not ownerKey or ownerKey == "" then
        SessionLog("AHManager: post inventory adjustment skipped reason=missing-ownerKey itemID=%s quantity=%s",
            tostring(itemID), tostring(quantity))
        return false, "missingOwnerKey"
    end
    if not itemID or itemID <= 0 then
        SessionLog("AHManager: post inventory adjustment skipped reason=missing-itemID owner=%s quantity=%s",
            tostring(ownerKey), tostring(quantity))
        return false, "missingItemID"
    end
    if quantity <= 0 then
        SessionLog("AHManager: post inventory adjustment skipped reason=missing-quantity owner=%s itemID=%s quantity=%s",
            tostring(ownerKey), tostring(itemID), tostring(pendingPost.quantity))
        return false, "missingQuantity"
    end

    local inventoryState = GetInventoryStateService()
    if not inventoryState or not inventoryState.RecordAuctionPosted then
        SessionLog("AHManager: post inventory adjustment skipped reason=inventory-state-service-unavailable owner=%s itemID=%s quantity=%d",
            tostring(ownerKey), tostring(itemID), quantity)
        return false, "inventoryStateServiceUnavailable"
    end

    local evidence = {
        configKey       = pendingPost.configKey,
        itemID          = itemID,
        itemName        = pendingPost.itemName,
        itemLink        = pendingPost.itemLink,
        itemGUID        = pendingPost.itemGUID,
        itemQuality     = pendingPost.itemQuality,
        craftingQuality = pendingPost.craftingQuality,
        rarityQuality   = pendingPost.rarityQuality,
        ilvl            = pendingPost.ilvl,
        statFingerprint = pendingPost.statFingerprint,
        itemStats       = pendingPost.itemStats,
        isStackable     = pendingPost.isStackable,
    }

    local beforeRows = GetAHSnapshotRows(ownerKey)
    local beforeMatch, beforeIndex, beforeTier = FindDebugIdentityRow(beforeRows, evidence)
    SessionLog("AHManager: post inventory normalized identity %s", DebugRowSummary(evidence))
    SessionLog("AHManager: post inventory AH before adjustment owner=%s rows=%d found=%s tier=%s index=%s row={%s}",
        tostring(ownerKey), #beforeRows, tostring(beforeMatch ~= nil), tostring(beforeTier),
        tostring(beforeIndex), DebugRowSummary(beforeMatch))

    local adjustments, err = inventoryState:RecordAuctionPosted(ownerKey, evidence, quantity, {
        reason    = "ah-post",
        itemID    = itemID,
        itemName  = pendingPost.itemName,
        itemLink  = pendingPost.itemLink,
        auctionID = auctionID,
    })

    if not adjustments then
        SessionLog("AHManager: post inventory adjustment failed owner=%s itemID=%s quantity=%d err=%s",
            tostring(ownerKey), tostring(itemID), quantity, tostring(err))
        return false, err
    end

    SessionLog("AHManager: post inventory adjustment written owner=%s itemID=%s quantity=%d bagsAdjustmentID=%s ahAdjustmentID=%s",
        tostring(ownerKey), tostring(itemID), quantity,
        tostring(adjustments[1] and adjustments[1].adjustmentID), tostring(adjustments[2] and adjustments[2].adjustmentID))
    return true, nil
end

function PostingLifecycleController:HandleAuctionCreated(auctionID, pending)
    SessionLog("AHManager: auction created auctionID=%s pendingPost=%s", tostring(auctionID), tostring(pending ~= nil))
    RecordAuctionCreatedInAHListing(auctionID, pending)

    if pending then
        self:StartPostDebugContext(pending, auctionID)
        self:ApplyPostInventoryAdjustment(pending, auctionID)
    else
        SessionLog("AHManager: post inventory adjustment skipped reason=no-pending-post auctionID=%s", tostring(auctionID))
    end

    if not pending or not HasGUID(pending.itemGUID) then
        SessionLog("AHManager: post lifecycle itemGUID=%s auctionID=%s rowFound=%s previousLocation=%s action=%s",
            tostring(pending and pending.itemGUID), tostring(auctionID), "false", "nil", "skipped_no_guid")
        Debug("AHManager: post lifecycle itemGUID=%s auctionID=%s rowFound=%s previousLocation=%s action=%s",
            tostring(pending and pending.itemGUID), tostring(auctionID), "false", "nil", "skipped_stackable")
        return
    end

    if pending.isStackable == true then
        SessionLog("AHManager: post lifecycle itemGUID=%s auctionID=%s rowFound=%s previousLocation=%s action=%s",
            tostring(pending.itemGUID), tostring(auctionID), "false", "nil", "skipped_stackable")
        Debug("AHManager: post lifecycle itemGUID=%s auctionID=%s rowFound=%s previousLocation=%s action=%s",
            tostring(pending.itemGUID), tostring(auctionID), "false", "nil", "skipped_stackable")
        return
    end

    local ledger          = PocketCFO and PocketCFO:GetModule("LifecycleLedger", true)
    local row             = ledger and ledger:GetActiveRowByItemGUID(pending.itemGUID)
    local previousLocation = row and row.location or nil
    local action          = nil
    local lookupKey       = DebugIdentityKey(pending)
    local ahSnapshotRow, _, ahSnapshotTier, ahSnapshotRows   = GetLocationSnapshotMatch(pending.ownerKey, "ah",   pending)
    local bagSnapshotRow, _, bagSnapshotTier, bagSnapshotRows = GetLocationSnapshotMatch(pending.ownerKey, "bags", pending)

    if not row then
        SessionLog("AHManager: post lifecycle initial rowFound=false detail itemGUID=%s auctionID=%s lookupKey=%s ahSnapshotFound=%s ahTier=%s ahRows=%d ahRow={%s} bagSnapshotFound=%s bagTier=%s bagRows=%d bagRow={%s}",
            tostring(pending.itemGUID), tostring(auctionID), tostring(lookupKey),
            tostring(ahSnapshotRow ~= nil), tostring(ahSnapshotTier), tonumber(ahSnapshotRows) or 0, DebugRowSummary(ahSnapshotRow),
            tostring(bagSnapshotRow ~= nil), tostring(bagSnapshotTier), tonumber(bagSnapshotRows) or 0, DebugRowSummary(bagSnapshotRow))
        row, action = EnsureAHLifecycleRowForPost(ledger, pending, auctionID)
        if row then
            previousLocation = nil
        end
    elseif previousLocation == "missing" then
        ledger:ResolveMissingFound(row.ledgerID, "ah", row.ownerKey or row.characterGUID)
        action = "resolved_missing_to_ah"
    else
        ClearMissingEntry(row)
        ledger:UpdateLocation(row.ledgerID, "ah", row.ownerKey or row.characterGUID)
        action = "moved_to_ah"
    end

    local ahLedger = PocketCFO_AH:GetModule("AHLedger", true)
    if ahLedger and auctionID and HasGUID(pending.itemGUID) then
        ahLedger:UpsertListing(auctionID, {
            itemGUID        = pending.itemGUID,
            ledgerID        = row and row.ledgerID or nil,
            ownerKey        = pending.ownerKey,
            itemID          = pending.itemID,
            itemName        = pending.itemName,
            price           = pending.buyout,
            buyout          = pending.buyout,
            bid             = pending.bid,
            quantity        = pending.quantity or 1,
            itemQuality     = pending.itemQuality,
            craftingQuality = pending.craftingQuality,
            rarityQuality   = pending.rarityQuality,
            ilvl            = pending.ilvl,
            itemLink        = pending.itemLink,
            statFingerprint = pending.statFingerprint,
            itemStats       = pending.itemStats,
            isStackable     = pending.isStackable,
            status          = "active",
            listedAt        = Now(),
        })
    end

    SessionLog("AHManager: post lifecycle itemGUID=%s auctionID=%s rowFound=%s previousLocation=%s action=%s",
        tostring(pending.itemGUID), tostring(auctionID), tostring(row ~= nil), tostring(previousLocation), tostring(action))
    if not row then
        SessionLog("AHManager: post lifecycle rowFound=false detail itemGUID=%s auctionID=%s lookupKey=%s ahSnapshotFound=%s ahTier=%s ahRows=%d ahRow={%s} bagSnapshotFound=%s bagTier=%s bagRows=%d bagRow={%s}",
            tostring(pending.itemGUID), tostring(auctionID), tostring(lookupKey),
            tostring(ahSnapshotRow ~= nil), tostring(ahSnapshotTier), tonumber(ahSnapshotRows) or 0, DebugRowSummary(ahSnapshotRow),
            tostring(bagSnapshotRow ~= nil), tostring(bagSnapshotTier), tonumber(bagSnapshotRows) or 0, DebugRowSummary(bagSnapshotRow))
    end
    Debug("AHManager: post lifecycle itemGUID=%s auctionID=%s rowFound=%s previousLocation=%s action=%s",
        tostring(pending.itemGUID), tostring(auctionID), tostring(row ~= nil), tostring(previousLocation), tostring(action))
end
