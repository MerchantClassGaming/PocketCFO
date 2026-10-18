-- PocketCFO/Scanners/BagScanner.lua
-- Scans player inventory bags and writes current-state snapshot rows.
-- Bag scans do not participate in lifecycle, accounting, or reconciliation.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local BagScanner = PocketCFO:NewModule("BagScanner", "AceEvent-3.0")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function DebugTime()
    if GetTime then return GetTime() end
    return PocketCFO:Now() or 0
end

local function ElapsedMs(startTime)
    if not startTime then return 0 end
    return math.floor(((DebugTime() - startTime) * 1000) + 0.5)
end

local function SessionLog(msg, ...)
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function GetItemLinkFromLocation(itemLocation)
    if not itemLocation or not C_Item or not C_Item.GetItemLink then
        return nil
    end
    if itemLocation.IsValid and not itemLocation:IsValid() then
        return nil
    end
    local ok, itemLink = pcall(C_Item.GetItemLink, itemLocation)
    if ok then
        return itemLink
    end
    return nil
end

local function GetItemGUIDFromLocation(itemLocation)
    if not itemLocation or not C_Item or not C_Item.GetItemGUID then
        return nil
    end
    if itemLocation.IsValid and not itemLocation:IsValid() then
        return nil
    end

    local ok, itemGUID = pcall(C_Item.GetItemGUID, itemLocation)
    if ok and itemGUID and itemGUID ~= "" then
        return itemGUID
    end
    return nil
end

local function GetItemIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function GetInventoryStateService()
    return PocketCFO and (PocketCFO.InventoryStateService or _G.InventoryStateService) or _G.InventoryStateService
end

local function GetSoulboundClassifier()
    return PocketCFO and PocketCFO.SoulboundClassifier or _G.PocketCFO_SoulboundClassifier
end

local function ResolveBagSlotIdentity(containerID, slot)
    local identityService = GetItemIdentityService()
    if not identityService then
        return nil, "identityServiceUnavailable"
    end

    if type(identityService.FromBagSlot) == "function" then
        local identity = identityService:FromBagSlot(containerID, slot)
        if identity and identity.configKey then
            return identity
        end
        return identity, identity and identity.unresolvedReason or "configKeyUnavailable"
    end

    if type(identityService.Identify) == "function" then
        local identity = identityService:Identify({
            evidenceType = "bagSlot",
            containerID = containerID,
            bag = containerID,
            slot = slot,
        })
        if identity and identity.configKey then
            return identity
        end
        return identity, identity and identity.unresolvedReason or "configKeyUnavailable"
    end

    return nil, "bagSlotIdentityResolverUnavailable"
end

-- ---------------------------------------------------------------------------
-- Slot-level identity cache for diff-based scan optimization.
-- Keyed by ownerKey, then by "containerID:slot".
-- Session-only; not persisted. Cleared implicitly when ownerKey changes.
-- ---------------------------------------------------------------------------

local slotCacheByOwner = {}

local function SlotKey(containerID, slot)
    return tostring(containerID) .. ":" .. tostring(slot)
end

-- Returns true when the prior slot cache entry can supply reusable identity
-- for the current slot without calling ItemIdentityService again.
-- Requires: prior must have a resolved configKey, matching itemID, and
-- matching itemLink. A nil itemLink on either side is treated as a mismatch
-- so that unresolved-link slots always re-resolve until the cache warms.
local function SlotSignatureMatches(prior, itemID, itemLink)
    if not prior or not prior.configKey then
        return false
    end
    if tonumber(prior.itemID) ~= tonumber(itemID) then
        return false
    end
    if (prior.itemLink or "") ~= (itemLink or "") then
        return false
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Scan
--
-- Returns:
--   readable (bool)       — whether any container was accessible
--   scannedItems (table)  — array of aggregated item rows
--   scannedGUIDs (table)  — set of GUIDs seen, [guid]=true
--   readableContainers (number)
--   totalSlots (number)
--   skippedSoulboundFinishedGoods (number)
--   skippedSoulboundDetails (table)
--   unresolvedIdentitySlots (number)
--   diffStats (table)     — per-scan diff counters for diagnostics
--
-- Inventory rows are quantity-based and aggregated by ItemIdentityService
-- ConfigKey. Identity fields for unchanged slots are reused from the prior
-- scan's slot cache; ItemIdentityService is only called for new or changed
-- slots. This function only observes — no DB writes.
-- ---------------------------------------------------------------------------

local function ScanContainerSet(containers, ownerKey, timestamp)
    local aggregatedRows = {}
    local scannedGUIDs = {}
    local readable = false
    local readableContainers = 0
    local totalSlots = 0
    local skippedSoulboundFinishedGoods = 0
    local skippedSoulboundDetails = {}
    local unresolvedIdentitySlots = 0

    -- Diff counters.
    local occupiedSlots  = 0
    local reuseCount     = 0
    local newSlotCount   = 0
    local changedSlotCount = 0

    local priorCache = slotCacheByOwner[ownerKey] or {}
    local newCache   = {}

    -- Count prior cache size once to compute removedSlotCount at the end.
    local priorCacheSize = 0
    for _ in pairs(priorCache) do
        priorCacheSize = priorCacheSize + 1
    end

    for _, containerID in ipairs(containers) do
        local numSlots = C_Container.GetContainerNumSlots(containerID)
        if numSlots and numSlots > 0 then
            readable = true
            readableContainers = readableContainers + 1
            totalSlots = totalSlots + numSlots
        end

        for slot = 1, (numSlots or 0) do
            local info = C_Container.GetContainerItemInfo(containerID, slot)
            if info and info.itemID and info.itemID ~= 0 then
                occupiedSlots = occupiedSlots + 1
                local itemID   = info.itemID
                local quantity = tonumber(info.stackCount) or 1
                local loc      = ItemLocation:CreateFromBagAndSlot(containerID, slot)
                local itemLink = info.hyperlink or GetItemLinkFromLocation(loc)
                local itemName = info.itemName

                if not itemName then
                    PocketCFO:Debug("BagScanner: item data not cached container=%d slot=%d", containerID, slot)
                end

                local itemGUID = GetItemGUIDFromLocation(loc)
                if itemGUID then scannedGUIDs[itemGUID] = true end

                -- Diff: compare against prior slot cache entry.
                local slotKey = SlotKey(containerID, slot)
                local prior   = priorCache[slotKey]
                local identity, identityErr
                local reused = false

                if SlotSignatureMatches(prior, itemID, itemLink) then
                    -- Slot unchanged: reuse prior resolved identity.
                    -- ItemIdentityService is not called for this slot.
                    identity = prior.identity
                    reused   = true
                    reuseCount = reuseCount + 1
                elseif prior then
                    -- Slot occupied but item changed (different itemID or itemLink).
                    identity, identityErr = ResolveBagSlotIdentity(containerID, slot)
                    changedSlotCount = changedSlotCount + 1
                else
                    -- New slot (not present in prior cache at all).
                    identity, identityErr = ResolveBagSlotIdentity(containerID, slot)
                    newSlotCount = newSlotCount + 1
                end

                local configKey = identity and identity.configKey

                -- Update slot cache for this slot regardless of reuse/resolve outcome.
                newCache[slotKey] = {
                    containerID = containerID,
                    slot        = slot,
                    itemID      = itemID,
                    itemLink    = itemLink or "",
                    quantity    = quantity,
                    configKey   = configKey,
                    identity    = identity,
                }

                if not configKey then
                    unresolvedIdentitySlots = unresolvedIdentitySlots + 1
                    if not reused then
                        SessionLog("BagScanner: skipped unresolved identity itemName=%s itemID=%s location=bags container=%s slot=%s itemGUID=%s reason=%s",
                            tostring(itemName), tostring(itemID), tostring(containerID), tostring(slot), tostring(itemGUID), tostring(identityErr))
                    end
                elseif identity then
                    local key = configKey
                    if not aggregatedRows[key] then
                        aggregatedRows[key] = {
                            ownerKey        = ownerKey,
                            location        = "bags",
                            configKey       = configKey,
                            itemID          = tonumber(identity.itemID) or itemID,
                            itemName        = identity.itemName or itemName,
                            itemQuality     = identity.itemQuality,
                            craftingQuality = identity.craftingQuality,
                            rarityQuality   = identity.rarityQuality or identity.quality,
                            ilvl            = identity.effectiveIlvl or identity.effectiveItemLevel or identity.itemLevel,
                            itemLink        = identity.itemLink or itemLink,
                            itemGUID        = itemGUID,
                            statFingerprint = identity.statFingerprint,
                            itemStats       = identity.itemStats,
                            matchingPath    = identity.matchingPath,
                            auctionPath     = identity.auctionPath,
                            classification  = identity.classification,
                            variantType     = identity.variantType,
                            quantity        = 0,
                            timestamp       = timestamp,
                            source          = "BagScanner",
                        }
                    else
                        local existing = aggregatedRows[key]
                        existing.itemName  = existing.itemName  or identity.itemName  or itemName
                        existing.itemLink  = existing.itemLink  or identity.itemLink  or itemLink
                        existing.itemGUID  = existing.itemGUID  or itemGUID
                        existing.itemStats = existing.itemStats or identity.itemStats
                    end

                    aggregatedRows[key].quantity = (tonumber(aggregatedRows[key].quantity) or 0) + quantity

                    -- Annotate bind-state while bag/slot context is available.
                    -- Conservative: if any slot aggregated under this configKey is bound,
                    -- the whole row is marked bound.
                    -- InventoryFilterService uses row.isBound to exclude bound items from
                    -- posting workflows. Post-scan rows (from InventoryStateService) lack
                    -- bag/slot context; this is the only place it can be detected.
                    if not aggregatedRows[key].isBound then
                        local classifier = GetSoulboundClassifier()
                        if classifier and type(classifier.BagSlotHasBoundTooltip) == "function" then
                            if classifier:BagSlotHasBoundTooltip(containerID, slot) then
                                aggregatedRows[key].isBound = true
                            end
                        end
                    end

                    if quantity > 1 then
                        SessionLog("BagScanner: slot quantity itemID=%s itemName=%s container=%s slot=%s itemGUID=%s stackCount=%s selectedQuantity=%d aggregateQuantity=%d",
                            tostring(itemID), tostring(itemName), tostring(containerID), tostring(slot),
                            tostring(itemGUID), tostring(info.stackCount), quantity,
                            tonumber(aggregatedRows[key].quantity) or 0)
                    end
                end
            end
        end
    end

    -- Commit the updated slot cache for this ownerKey.
    slotCacheByOwner[ownerKey] = newCache

    local scannedItems = {}
    for _, row in pairs(aggregatedRows) do
        scannedItems[#scannedItems + 1] = row
    end

    -- removedSlotCount: prior slots that no longer appear as occupied.
    -- = priorCacheSize - (reused + changed); new slots were absent from prior.
    local removedSlotCount = priorCacheSize - reuseCount - changedSlotCount
    if removedSlotCount < 0 then removedSlotCount = 0 end

    local diffStats = {
        occupiedSlots          = occupiedSlots,
        reuseCount             = reuseCount,
        resolvedCount          = newSlotCount + changedSlotCount,
        newSlotCount           = newSlotCount,
        changedSlotCount       = changedSlotCount,
        removedSlotCount       = removedSlotCount,
        identityCallsAvoided   = reuseCount,
        priorCacheSize         = priorCacheSize,
    }

    return readable, scannedItems, scannedGUIDs, readableContainers, totalSlots, skippedSoulboundFinishedGoods, skippedSoulboundDetails, unresolvedIdentitySlots, diffStats
end

local function BuildBagObservation(reason)
    local containers = { BACKPACK_CONTAINER }
    for i = 1, NUM_BAG_SLOTS do containers[#containers + 1] = i end
    containers[#containers + 1] = 5  -- reagent bag

    local ownerKey  = PocketCFO.db.char.characterGUID
    local timestamp = PocketCFO:Now()
    local readable, rows, scannedGUIDs, readableContainers, totalSlots,
          skippedSoulboundFinishedGoods, skippedSoulboundDetails,
          unresolvedIdentitySlots, diffStats = ScanContainerSet(containers, ownerKey, timestamp)
    return {
        location                      = "bags",
        ownerKey                      = ownerKey,
        rows                          = rows,
        items                         = rows,
        readable                      = readable,
        readableContainers            = readableContainers,
        totalSlots                    = totalSlots,
        complete                      = readable or #(rows or {}) > 0,
        scannedGUIDs                  = scannedGUIDs,
        skippedSoulboundFinishedGoods = skippedSoulboundFinishedGoods or 0,
        skippedSoulboundDetails       = skippedSoulboundDetails or {},
        unresolvedIdentitySlots       = unresolvedIdentitySlots or 0,
        diffStats                     = diffStats or {},
        reason                        = reason,
        timestamp                     = timestamp,
    }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function BagScanner:CaptureBagSnapshot()
    local observation = BuildBagObservation("capture")
    return observation.readable, observation.rows, observation.scannedGUIDs
end

function BagScanner:ObserveBags(reason)
    local observation = BuildBagObservation(reason or "observe")
    SessionLog("Bag scan observeOnly complete reason=%s locations=bags rows=%d skippedSoulboundFinishedGoods=%d",
        tostring(reason or "observe"), #(observation.rows or {}), tonumber(observation.skippedSoulboundFinishedGoods) or 0)
    return observation
end

function BagScanner:ScanBags(options)
    local startedAt = DebugTime()
    options = options or {}
    local reason        = options.reason or "manual"
    local mode          = options.mode or "normal"
    local characterGUID = PocketCFO.db.char.characterGUID
    PocketCFO:Debug("BagScanner:ScanBags started reason=%s", tostring(reason))
    if not characterGUID then
        PocketCFO:Debug("BagScanner:ScanBags skipped reason=no-character-guid elapsed=%dms", ElapsedMs(startedAt))
        local inventoryStateService = GetInventoryStateService()
        if inventoryStateService and inventoryStateService.RecordSnapshotScan then
            inventoryStateService:RecordSnapshotScan(characterGUID, "bags", {
                reason = reason,
                succeeded = false,
            })
        end
        return {
            ownerKey = characterGUID,
            location = "bags",
            readable = false,
            complete = false,
            items = {},
            scannedGUIDs = {},
        }
    end

    if mode == "observeOnly" then
        return self:ObserveBags(reason)
    end

    local observation   = BuildBagObservation(reason)
    local readable      = observation.readable
    local scannedItems  = observation.rows
    local scannedGUIDs  = observation.scannedGUIDs
    local diffStats     = observation.diffStats or {}

    if not readable and #scannedItems == 0 then
        PocketCFO:Debug("BagScanner:ScanBags no readable bag containers elapsed=%dms", ElapsedMs(startedAt))
        local inventoryStateService = GetInventoryStateService()
        if inventoryStateService and inventoryStateService.RecordSnapshotScan then
            inventoryStateService:RecordSnapshotScan(characterGUID, "bags", {
                reason = reason,
                succeeded = false,
            })
        end
        return {
            ownerKey = characterGUID,
            location = "bags",
            readable = false,
            readableContainers = observation.readableContainers,
            totalSlots = observation.totalSlots,
            complete = false,
            items = scannedItems or {},
            rows = scannedItems or {},
            scannedGUIDs = scannedGUIDs or {},
            skippedSoulboundFinishedGoods = observation.skippedSoulboundFinishedGoods or 0,
            diffStats = diffStats,
        }
    end

    local inventoryStateService = GetInventoryStateService()
    local storedRows = scannedItems
    if inventoryStateService and inventoryStateService.ReplaceSnapshot then
        storedRows = inventoryStateService:ReplaceSnapshot(characterGUID, "bags", scannedItems, {
            reason = reason,
            source = "BagScanner",
        }) or {}
    else
        PocketCFO:Debug("BagScanner:ScanBags inventory write skipped reason=inventory-state-service-unavailable elapsed=%dms", ElapsedMs(startedAt))
    end

    PocketCFO.db.char.initialScanComplete.bags = true
    PocketCFO.db.char.lastBagScan = PocketCFO:Now()
    PocketCFO:SendMessage("MCGCFO_BAG_SCAN_COMPLETE", characterGUID, scannedGUIDs)

    local elapsed = ElapsedMs(startedAt)
    SessionLog("Bag snapshot updated trigger=%s locations=bags owner=%s rows=%d readable=%s skippedSoulbound=%d occupiedSlots=%d reused=%d resolved=%d newSlots=%d changedSlots=%d removedSlots=%d identityCallsAvoided=%d elapsed=%dms",
        tostring(reason),
        tostring(characterGUID), #(storedRows or {}), tostring(readable),
        tonumber(observation.skippedSoulboundFinishedGoods) or 0,
        diffStats.occupiedSlots      or 0,
        diffStats.reuseCount         or 0,
        diffStats.resolvedCount      or 0,
        diffStats.newSlotCount       or 0,
        diffStats.changedSlotCount   or 0,
        diffStats.removedSlotCount   or 0,
        diffStats.identityCallsAvoided or 0,
        elapsed)
    PocketCFO:Debug("BagScanner:ScanBags finished reason=%s observedItems=%d storedRows=%d skippedSoulbound=%d occupiedSlots=%d reused=%d resolved=%d newSlots=%d changedSlots=%d removedSlots=%d identityCallsAvoided=%d elapsed=%dms",
        tostring(reason), #scannedItems, #(storedRows or {}),
        tonumber(observation.skippedSoulboundFinishedGoods) or 0,
        diffStats.occupiedSlots      or 0,
        diffStats.reuseCount         or 0,
        diffStats.resolvedCount      or 0,
        diffStats.newSlotCount       or 0,
        diffStats.changedSlotCount   or 0,
        diffStats.removedSlotCount   or 0,
        diffStats.identityCallsAvoided or 0,
        elapsed)
    return {
        ownerKey = characterGUID,
        location = "bags",
        readable = readable,
        readableContainers = observation.readableContainers,
        totalSlots = observation.totalSlots,
        complete = true,
        items = scannedItems,
        rows = scannedItems,
        scannedGUIDs = scannedGUIDs,
        skippedSoulboundFinishedGoods = observation.skippedSoulboundFinishedGoods or 0,
        diffStats = diffStats,
    }
end

function BagScanner:OnEnable()
    self:RegisterEvent("BAG_UPDATE_DELAYED", "OnBagUpdateDelayed")
end

function BagScanner:OnBagUpdateDelayed()
    local characterGUID = PocketCFO.db.char and PocketCFO.db.char.characterGUID
    local inventoryStateService = GetInventoryStateService()
    if inventoryStateService and inventoryStateService.MarkSnapshotDirty then
        inventoryStateService:MarkSnapshotDirty(characterGUID, "bags", "BAG_UPDATE_DELAYED")
    end
    self:ScanBags({ reason = "bag-update-delayed" })
end

function BagScanner:GetLastScanTimes()
    return {
        bags        = PocketCFO.db.char.lastBagScan,
        bank        = PocketCFO.db.char.lastBankScan,
        warbandBank = PocketCFO.db.global.lastWarbandBankScan,
        ah          = PocketCFO.db.char.lastAHScan,
        mailbox     = PocketCFO.db.char.lastMailboxScan,
    }
end
