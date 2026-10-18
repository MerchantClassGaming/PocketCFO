-- PocketCFO_AH/Scanners/OwnedAuctionsScanner.lua
-- Current-state owned auction scanner.
-- This module observes owned auctions and writes the character-scoped AH
-- inventory snapshot only. It does not reconcile lifecycle state.

local ADDON_NAME, _ = ...
local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local OwnedAuctionsScanner = PocketCFO_AH:NewModule("OwnedAuctionsScanner")

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

local function GetOwnerKey()
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.char
        and PocketCFO.db.char.characterGUID
        or nil
end

local function GetItemIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function GetInventoryStateService()
    return PocketCFO and (PocketCFO.InventoryStateService or _G.InventoryStateService) or _G.InventoryStateService
end

local function ExtractItemLink(info)
    if not info then
        return nil
    end
    return info.itemLink
        or info.hyperlink
        or info.link
end

local function ExtractRawItemID(info)
    if not info then
        return nil
    end

    if info.itemID then
        return tonumber(info.itemID)
    end
    if info.itemId then
        return tonumber(info.itemId)
    end
    if info.itemKey and info.itemKey.itemID then
        return tonumber(info.itemKey.itemID)
    end

    return nil
end

local function ExtractAuctionID(info)
    return info and (info.auctionID or info.auctionId or info.listingID or info.listingId)
end

local function ExtractQuantity(info)
    if not info then
        return nil
    end

    local quantity = tonumber(info.quantity or info.stackSize or info.count or info.numItems)
    if quantity and quantity > 0 then
        return quantity
    end

    return nil
end

local function IsActiveOwnedAuction(info)
    if type(info) ~= "table" then
        return false
    end

    if info.status == nil then
        return true
    end

    return tonumber(info.status) == 0
end

local function ExtractRawItemName(info)
    if info and info.itemName then
        return info.itemName
    end
    if info and info.name then
        return info.name
    end

    if info and info.itemKey and C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
        local ok, itemKeyInfo = pcall(C_AuctionHouse.GetItemKeyInfo, info.itemKey)
        if ok and itemKeyInfo and itemKeyInfo.itemName then
            return itemKeyInfo.itemName
        end
    end

    return nil
end

local function ResolveOwnedAuctionIdentity(info)
    local identityService = GetItemIdentityService()
    if not identityService then
        return nil, "identityServiceUnavailable"
    end

    if type(identityService.FromOwnedAuctionRow) == "function" then
        local identity = identityService:FromOwnedAuctionRow(info)
        if identity and identity.configKey then
            return identity
        end
        return identity, identity and identity.unresolvedReason or "configKeyUnavailable"
    end

    if type(identityService.Identify) == "function" then
        local identity = identityService:Identify({
            evidenceType = "ownedAuctionRow",
            row = info,
        })
        if identity and identity.configKey then
            return identity
        end
        return identity, identity and identity.unresolvedReason or "configKeyUnavailable"
    end

    return nil, "ownedAuctionIdentityResolverUnavailable"
end

local function NormalizeOwnedAuction(info, ownerKey, timestamp)
    if type(info) ~= "table" then
        return nil, "noInfo"
    end

    if not IsActiveOwnedAuction(info) then
        return nil, "nonActiveStatus"
    end

    local itemLink = ExtractItemLink(info)
    local rawItemID = ExtractRawItemID(info)
    local quantity = ExtractQuantity(info)
    local identity, identityReason = ResolveOwnedAuctionIdentity(info)
    local itemID = tonumber(identity and identity.itemID) or rawItemID

    if not itemID or itemID <= 0 then
        return nil, "noItemID"
    end
    if not quantity or quantity <= 0 then
        return nil, "noQuantity"
    end

    return {
        ownerKey        = ownerKey,
        location        = "ah",
        configKey       = identity and identity.configKey,
        identity        = identity,
        identityReason  = identityReason,
        itemID          = itemID,
        itemName        = identity and identity.itemName or ExtractRawItemName(info),
        quantity        = quantity,
        itemQuality     = identity and identity.itemQuality,
        craftingQuality = identity and identity.craftingQuality,
        rarityQuality   = identity and (identity.rarityQuality or identity.quality),
        ilvl            = identity and (identity.effectiveIlvl or identity.effectiveItemLevel or identity.itemLevel),
        itemClassID     = identity and identity.itemClassID,
        itemSubClassID  = identity and identity.itemSubClassID,
        equipLoc        = identity and identity.equipLoc,
        itemLink        = identity and identity.itemLink or itemLink,
        itemGUID        = info.itemGUID or info.itemGuid or info.guid,
        statFingerprint = identity and identity.statFingerprint,
        itemStats       = identity and identity.itemStats,
        matchingPath    = identity and identity.matchingPath,
        auctionPath     = identity and identity.auctionPath,
        classification  = identity and identity.classification,
        variantType     = identity and identity.variantType,
        isStackable     = identity and identity.isStackable,
        isCommodity     = identity and identity.isCommodity,
        timestamp       = timestamp,
        source          = "OwnedAuctionsScanner",

        auctionID       = ExtractAuctionID(info),
        buyout          = info.buyoutAmount or info.buyout or info.buyoutPrice or 0,
        bid             = info.bidAmount or info.bid or info.bidPrice or 0,
        timeLeft        = info.timeLeft or info.durationLeft or info.duration,

        -- Raw Blizzard timing fields preserved separately for diagnostics.
        -- timeLeft is typically a bucket enum (1=Very Short .. 5=Very Long), not exact.
        rawTimeLeft     = info.timeLeft,
        rawDurationLeft = info.durationLeft,
        rawDuration     = info.duration,
    }, nil
end

local function AddSkip(skippedReasons, reason)
    reason = reason or "unknown"
    skippedReasons[reason] = (skippedReasons[reason] or 0) + 1
end

local function FormatSkipReasons(skippedReasons)
    local parts = {}
    for reason, count in pairs(skippedReasons or {}) do
        parts[#parts + 1] = tostring(reason) .. "=" .. tostring(count)
    end
    table.sort(parts)
    if #parts == 0 then
        return "none"
    end
    return table.concat(parts, ",")
end

local function OnlySkippedNonActiveStatus(skippedReasons, skippedCount, sourceCount)
    if (tonumber(sourceCount) or 0) <= 0 then
        return false
    end
    if (tonumber(skippedCount) or 0) ~= (tonumber(sourceCount) or 0) then
        return false
    end
    if tonumber(skippedReasons and skippedReasons.nonActiveStatus) ~= tonumber(sourceCount) then
        return false
    end

    for reason in pairs(skippedReasons or {}) do
        if reason ~= "nonActiveStatus" then
            return false
        end
    end

    return true
end

function OwnedAuctionsScanner:QueryOwnedAuctions()
    if not C_AuctionHouse or not C_AuctionHouse.QueryOwnedAuctions then
        SessionLog("OwnedAuctionsScanner: owned auction query unavailable")
        return false
    end

    local ok = pcall(C_AuctionHouse.QueryOwnedAuctions, {})
    if not ok then
        ok = pcall(C_AuctionHouse.QueryOwnedAuctions)
    end
    SessionLog("OwnedAuctionsScanner: owned auction query requested ok=%s", tostring(ok and true or false))
    return ok and true or false
end

function OwnedAuctionsScanner:GetOwnedAuctionCount()
    if C_AuctionHouse and C_AuctionHouse.GetNumOwnedAuctions then
        local ok, count = pcall(C_AuctionHouse.GetNumOwnedAuctions)
        if ok then
            return tonumber(count) or 0
        end
    end
    return 0
end

function OwnedAuctionsScanner:GetOwnedAuctionInfo(index)
    if not C_AuctionHouse or not C_AuctionHouse.GetOwnedAuctionInfo then
        return nil
    end

    local ok, info = pcall(C_AuctionHouse.GetOwnedAuctionInfo, index)
    if ok then
        return info
    end
    return nil
end

function OwnedAuctionsScanner:GetOwnedAuctionInfos()
    if C_AuctionHouse and type(C_AuctionHouse.GetOwnedAuctions) == "function" then
        local ok, infos = pcall(C_AuctionHouse.GetOwnedAuctions)
        if ok and type(infos) == "table" then
            local rows = {}
            for _, info in ipairs(infos) do
                rows[#rows + 1] = info
            end
            if #rows == 0 then
                for _, info in pairs(infos) do
                    if type(info) == "table" then
                        rows[#rows + 1] = info
                    end
                end
            end
            if #rows > 0 then
                return rows
            end
        end
    end

    local rows = {}
    local ownedCount = self:GetOwnedAuctionCount()
    for index = 1, ownedCount do
        rows[#rows + 1] = self:GetOwnedAuctionInfo(index)
    end
    return rows
end

function OwnedAuctionsScanner:OwnedAuctionResultsReady()
    if C_AuctionHouse and type(C_AuctionHouse.HasFullOwnedAuctionResults) == "function" then
        local ok, ready = pcall(C_AuctionHouse.HasFullOwnedAuctionResults)
        if ok then
            return ready == true
        end
    end
    return true
end

function OwnedAuctionsScanner:WriteAHSnapshot(ownerKey, rows, ready, ownedCount, options)
    options = options or {}
    if not ready then
        SessionLog("OwnedAuctionsScanner: AH snapshot preserved reason=owned-auctions-not-ready owner=%s previousSnapshotKept=true",
            tostring(ownerKey))
        return false, "notReady"
    end

    if ownedCount > 0 and #(rows or {}) == 0 then
        if options.allowEmptySnapshot then
            SessionLog("OwnedAuctionsScanner: AH snapshot empty allowed reason=%s owner=%s ownedCount=%d skippedReasons=%s",
                tostring(options.emptyReason or "all-non-active"), tostring(ownerKey), ownedCount, tostring(options.skippedReasonText or "none"))
        else
            SessionLog("OwnedAuctionsScanner: AH snapshot preserved reason=no-normalized-rows owner=%s ownedCount=%d skippedReasons=%s previousSnapshotKept=true",
                tostring(ownerKey), ownedCount, tostring(options.skippedReasonText or "none"))
            return false, "noNormalizedRows"
        end
    end

    local inventoryStateService = GetInventoryStateService()
    if not inventoryStateService or type(inventoryStateService.ReplaceSnapshot) ~= "function" then
        SessionLog("OwnedAuctionsScanner: AH snapshot write skipped reason=inventory-state-service-unavailable owner=%s rows=%d",
            tostring(ownerKey), #(rows or {}))
        return false, "inventoryStateServiceUnavailable"
    end

    local storedRows, err = inventoryStateService:ReplaceSnapshot(ownerKey, "ah", rows or {}, {
        source = "OwnedAuctionsScanner",
        reason = options.reason or "owned-auctions-scan",
    })
    if not storedRows then
        SessionLog("OwnedAuctionsScanner: AH snapshot preserved reason=replace-failed owner=%s err=%s",
            tostring(ownerKey), tostring(err))
        return false, "replaceFailed"
    end

    if PocketCFO and PocketCFO.db and PocketCFO.db.char then
        PocketCFO.db.char.initialScanComplete = PocketCFO.db.char.initialScanComplete or {}
        PocketCFO.db.char.initialScanComplete.ah = true
        PocketCFO.db.char.lastAHScan = PocketCFO:Now()
    end

    SessionLog("OwnedAuctionsScanner: AH snapshot written owner=%s rows=%d ownedCount=%d",
        tostring(ownerKey), #(storedRows or {}), ownedCount)
    return true, "written", storedRows
end

function OwnedAuctionsScanner:ScanOwnedAuctions()
    local ownerKey = GetOwnerKey()
    local timestamp = PocketCFO and PocketCFO.Now and PocketCFO:Now() or time()
    local rows = {}
    local skippedReasons = {}
    local skippedCount = 0
    local unresolvedIdentityRows = 0

    SessionLog("OwnedAuctionsScanner: scan start owner=%s", tostring(ownerKey))

    if not ownerKey or ownerKey == "" then
        SessionLog("OwnedAuctionsScanner: scan skipped reason=no-owner-key")
        return {
            ownerKey = ownerKey,
            location = "ah",
            ownedCount = 0,
            rowCount = 0,
            normalizedRowCount = 0,
            skippedCount = 0,
            skippedReasons = {},
            rows = {},
            items = {},
            complete = false,
            snapshotWritten = false,
            snapshotWriteReason = "noOwnerKey",
        }
    end

    local ready = self:OwnedAuctionResultsReady()
    local ownedInfos = self:GetOwnedAuctionInfos() or {}
    local ownedCount = #ownedInfos
    if ownedCount == 0 then
        ownedCount = self:GetOwnedAuctionCount()
    end

    SessionLog("OwnedAuctionsScanner: owned auction source count=%d ready=%s", ownedCount, tostring(ready))

    local observedOwnedAuctionIDs = {}
    for index = 1, #ownedInfos do
        local info = ownedInfos[index]
        local observedAuctionID = IsActiveOwnedAuction(info) and ExtractAuctionID(info) or nil
        if observedAuctionID ~= nil and observedAuctionID ~= "" then
            observedOwnedAuctionIDs[#observedOwnedAuctionIDs + 1] = { auctionID = observedAuctionID }
        end

        local row, skipReason = NormalizeOwnedAuction(info, ownerKey, timestamp)
        if row then
            if not row.configKey then
                unresolvedIdentityRows = unresolvedIdentityRows + 1
                SessionLog("OwnedAuctionsScanner: unresolved identity auctionID=%s itemID=%s itemName=%s reason=%s",
                    tostring(row.auctionID), tostring(row.itemID), tostring(row.itemName), tostring(row.identityReason))
            end
            rows[#rows + 1] = row
        else
            skippedCount = skippedCount + 1
            AddSkip(skippedReasons, skipReason)
        end
    end

    local skippedReasonText = FormatSkipReasons(skippedReasons)
    SessionLog("OwnedAuctionsScanner: normalized rows=%d skipped=%d reasons=%s",
        #rows, skippedCount, skippedReasonText)

    local ahListing = PocketCFO_AH:GetModule("AHListingService", true)
    if ahListing and ahListing.BackfillMissingOwnedAuctions then
        ahListing:BackfillMissingOwnedAuctions(rows)
    end
    local reconciledClosed, reconciledKept, reconciledObserved = 0, 0, 0
    if ready and ahListing and ahListing.ReconcileActiveOwnedAuctions then
        reconciledClosed, reconciledKept, reconciledObserved = ahListing:ReconcileActiveOwnedAuctions(observedOwnedAuctionIDs, {
            source   = "owned_scan_reconcile",
            reason   = "notObservedInReliableOwnedScan",
            ownerKey = ownerKey,
        })
    elseif not ready then
        SessionLog("OwnedAuctionsScanner: AHListing reconcile skipped reason=owned-auctions-not-ready")
    end

    local allowEmptySnapshot = OnlySkippedNonActiveStatus(skippedReasons, skippedCount, #ownedInfos)
    local snapshotWritten, snapshotWriteReason, storedRows = self:WriteAHSnapshot(ownerKey, rows, ready, ownedCount, {
        allowEmptySnapshot = allowEmptySnapshot,
        emptyReason = allowEmptySnapshot and "all-owned-auctions-non-active" or nil,
        skippedReasonText = skippedReasonText,
        reason = "owned-auctions-scan",
    })
    local storedAHRows = nil
    local inventoryStateService = GetInventoryStateService()
    if inventoryStateService and type(inventoryStateService.GetLocationSnapshot) == "function" then
        storedAHRows = inventoryStateService:GetLocationSnapshot(ownerKey, "ah")
    end

    self.lastObservation = {
        ownerKey = ownerKey,
        location = "ah",
        ownedCount = ownedCount,
        rowCount = #rows,
        normalizedRowCount = #rows,
        skippedCount = skippedCount,
        skippedReasons = skippedReasons,
        skippedReasonText = skippedReasonText,
        unresolvedIdentityRows = unresolvedIdentityRows,
        allowEmptySnapshot = allowEmptySnapshot,
        complete = ready,
        snapshotWritten = snapshotWritten,
        snapshotWriteReason = snapshotWriteReason,
        storedAHRowCount = #(storedAHRows or {}),
        ahListingReconcileClosed = reconciledClosed,
        ahListingReconcileKept = reconciledKept,
        ahListingReconcileObserved = reconciledObserved,
    }

    Debug("OwnedAuctionsScanner: scan complete ready=%s ownedCount=%d rows=%d skipped=%d snapshotWritten=%s reason=%s",
        tostring(ready), ownedCount, #rows, skippedCount, tostring(snapshotWritten), tostring(snapshotWriteReason))
    SessionLog("OwnedAuctionsScanner: scan complete ready=%s ownedCount=%d rows=%d skipped=%d snapshotWritten=%s reason=%s",
        tostring(ready), ownedCount, #rows, skippedCount, tostring(snapshotWritten), tostring(snapshotWriteReason))

    return {
        ownerKey = ownerKey,
        location = "ah",
        ownedCount = ownedCount,
        rowCount = #rows,
        normalizedRowCount = #rows,
        skippedCount = skippedCount,
        skippedReasons = skippedReasons,
        skippedReasonText = skippedReasonText,
        unresolvedIdentityRows = unresolvedIdentityRows,
        allowEmptySnapshot = allowEmptySnapshot,
        rows = rows,
        items = rows,
        storedRows = storedRows,
        storedAHRowCount = #(storedAHRows or {}),
        complete = ready,
        snapshotWritten = snapshotWritten,
        snapshotWriteReason = snapshotWriteReason,
        ahListingReconcileClosed = reconciledClosed,
        ahListingReconcileKept = reconciledKept,
        ahListingReconcileObserved = reconciledObserved,
    }
end

function OwnedAuctionsScanner:OnInitialize()
    SessionLog("OwnedAuctionsScanner OnInitialize")
end
