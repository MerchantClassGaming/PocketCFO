-- PocketCFO_AH/Infrastructure/AHSessionController.lua
-- Owns AH session state, owned auction query orchestration, and untracked auction detection.

local ADDON_NAME, _ = ...
local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local AHSessionController = {}
PocketCFO_AH.AHSessionController = AHSessionController

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

local function IsAuctionHouseAvailable()
    if AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown() then
        return true
    end
    return C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions ~= nil
end

local function CopyArray(values)
    local copy = {}
    for index, value in ipairs(values or {}) do
        copy[index] = value
    end
    return copy
end

local function AddCallback(callbacks, callback)
    if type(callback) == "function" then
        callbacks[#callbacks + 1] = callback
    end
end

local function ExtractAuctionID(info)
    if type(info) ~= "table" then
        return nil
    end
    return info.auctionID or info.auctionId or info.listingID or info.listingId
end

local function HasTrackedAHListing(auctionID)
    if auctionID == nil or auctionID == "" then
        return false
    end
    local listings = PocketCFO_AH
        and PocketCFO_AH.db
        and PocketCFO_AH.db.global
        and PocketCFO_AH.db.global.ahListings
        or nil
    if type(listings) ~= "table" then
        return false
    end
    local key = tostring(auctionID)
    if listings[key] or listings[auctionID] then
        return true
    end
    return false
end

local function MakeNewSession(extra)
    local s = {
        openedAt              = Now(),
        bagObservation        = nil,
        ahObservation         = nil,
        reconciled            = false,
        listingsWritten       = 0,
        untrackedAuctionIDs   = {},
        untrackedCount        = 0,
        untrackedSampleAuctionIDs = {},
        untrackedWarningShown = false,
    }
    if extra then
        for k, v in pairs(extra) do
            s[k] = v
        end
    end
    return s
end

-- State

AHSessionController.session = nil
AHSessionController.pendingOwnedAuctionRefresh = nil
AHSessionController.ownedAuctionRefreshRequestID = 0
-- True only while we are waiting on the response to a query WE issued
-- (AH-open sync or an explicit refresh). OWNED_AUCTIONS_UPDATED fires for
-- reasons outside our control too (e.g. AHListingService's post-hydration
-- query, Blizzard's own post-cancel refresh) and those must not trigger a
-- full owned-auction snapshot rescan.
AHSessionController.awaitingOwnedAuctionSync = false

function AHSessionController:GetSession()
    return self.session
end

function AHSessionController:ScanBagsForAH(reason)
    local bagScanner = PocketCFO and PocketCFO:GetModule("BagScanner", true)
    if not bagScanner or not bagScanner.ScanBags then
        Debug("AHManager: bag scan skipped; BagScanner unavailable")
        SessionLog("Scan trigger skipped: %s locations=bags reason=BagScanner-unavailable", tostring(reason or "ah-open"))
        return nil
    end
    SessionLog("Scan trigger: %s locations=bags", tostring(reason or "ah-open"))
    return bagScanner:ScanBags({ reason = reason or "ah-open" })
end

function AHSessionController:BuildCombinedGUIDMap(bagObservation, ahObservation)
    local combinedGUIDMap = {}

    for _, row in ipairs((bagObservation and bagObservation.rows) or {}) do
        if row and HasGUID(row.itemGUID) then
            local guid = tostring(row.itemGUID)
            combinedGUIDMap[guid] = { itemGUID = guid, location = "bags", row = row }
        end
    end

    for guid in pairs((bagObservation and bagObservation.scannedGUIDs) or {}) do
        if HasGUID(guid) then
            guid = tostring(guid)
            if not combinedGUIDMap[guid] then
                combinedGUIDMap[guid] = { itemGUID = guid, location = "bags", row = nil }
            end
        end
    end

    for _, row in ipairs((ahObservation and ahObservation.rows) or {}) do
        if row and HasGUID(row.itemGUID) then
            local guid = tostring(row.itemGUID)
            combinedGUIDMap[guid] = { itemGUID = guid, location = "ah", row = row }
            Debug("AHManager: combined GUID add source=ah itemGUID=%s itemID=%s itemName=%s location=ah guidSource=%s",
                tostring(guid), tostring(row.itemID), tostring(row.itemName), tostring(row.guidSource))
            SessionLog("AHManager: combined GUID add source=ah itemGUID=%s itemID=%s itemName=%s location=ah guidSource=%s",
                tostring(guid), tostring(row.itemID), tostring(row.itemName), tostring(row.guidSource))
        end
    end

    return combinedGUIDMap
end

function AHSessionController:RunAHOpenReconciliation(reason)
    if not self.session or self.session.reconciled then
        return
    end
    if not self.session.ahObservation then
        return
    end

    local ahOwnedCount    = tonumber(self.session.ahObservation.ownedCount) or 0
    local ahGUIDRowCount  = tonumber(self.session.ahObservation.guidRowCount)
        or #((self.session.ahObservation and self.session.ahObservation.rows) or {})
    local ahComplete      = self.session.ahObservation.complete == true
    local untrackedCount  = tonumber(self.session.untrackedCount) or 0

    SessionLog("AHManager: owned scan state reason=%s ahOwnedCount=%d ahGUIDRowCount=%d untrackedCount=%d ahComplete=%s",
        tostring(reason), ahOwnedCount, ahGUIDRowCount, untrackedCount, tostring(ahComplete))

    if not ahComplete then
        SessionLog("AHManager: owned scan warning deferred reason=%s ahOwnedCount=%d ahGUIDRowCount=%d untrackedCount=%d",
            "owned-auctions-not-ready", ahOwnedCount, ahGUIDRowCount, untrackedCount)
        return
    end

    self.session.reconciled    = true
    self.session.listingsWritten = 0
    self:WarnUntrackedAuctionsOnce()

    SessionLog("AHManager: AH owned scan warning-only complete reason=%s ahOwnedCount=%d ahGUIDRowCount=%d untrackedCount=%d listingsWritten=0",
        tostring(reason), ahOwnedCount, ahGUIDRowCount, untrackedCount)
end

function AHSessionController:CountMap(map)
    local count = 0
    for _ in pairs(map or {}) do
        count = count + 1
    end
    return count
end

function AHSessionController:ReadRawOwnedAuctionInfos(scanner)
    if not scanner or not scanner.GetOwnedAuctionInfos then
        return {}
    end
    local ok, rows = pcall(function()
        return scanner:GetOwnedAuctionInfos()
    end)
    if ok and type(rows) == "table" then
        return rows
    end
    SessionLog("AHManager: raw owned auction read failed error=%s", tostring(rows))
    return {}
end

function AHSessionController:UpdateUntrackedAuctions(rawRows)
    if not self.session then
        return
    end

    local untracked = {}
    local samples   = {}
    local count     = 0

    for _, rawRow in ipairs(rawRows or {}) do
        local auctionID = ExtractAuctionID(rawRow)
        if auctionID ~= nil and auctionID ~= "" and not HasTrackedAHListing(auctionID) then
            local key = tostring(auctionID)
            if not untracked[key] then
                untracked[key] = true
                count = count + 1
                if #samples < 5 then
                    samples[#samples + 1] = key
                end
            end
        end
    end

    self.session.untrackedAuctionIDs        = untracked
    self.session.untrackedCount             = count
    self.session.untrackedSampleAuctionIDs  = samples

    if self.session.ahObservation then
        self.session.ahObservation.untrackedCount            = count
        self.session.ahObservation.untrackedSampleAuctionIDs = CopyArray(samples)
    end

    SessionLog("AHManager: untracked owned auction detection complete count=%d", count)
end

function AHSessionController:WarnUntrackedAuctionsOnce()
    if not self.session or self.session.untrackedWarningShown then
        return
    end
    local count = tonumber(self.session.untrackedCount) or 0
    if count <= 0 then
        return
    end
    self.session.untrackedWarningShown = true
    if PocketCFO and PocketCFO.Print then
        PocketCFO:Print("AH: %d untracked auctions detected (/mcgd ahscan)", count)
    end
end

function AHSessionController:OnAuctionHouseShow(event)
    SessionLog("AHManager: OnAHShow called event=%s", tostring(event or "direct"))
    self.session = MakeNewSession({
        bagObservation = self:ScanBagsForAH("ah-open"),
    })
    SessionLog("AHManager: session created openedAt=%s", tostring(self.session.openedAt))

    local scanner = PocketCFO_AH:GetModule("OwnedAuctionsScanner", true)
    if scanner and scanner.QueryOwnedAuctions then
        local queryOK = scanner:QueryOwnedAuctions()
        self.awaitingOwnedAuctionSync = queryOK and true or false
        SessionLog("AHManager: owned auction query requested ok=%s", tostring(queryOK))
    else
        self.awaitingOwnedAuctionSync = false
        SessionLog("AHManager: owned auction query skipped scannerUnavailable=true")
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0.8, function()
            if not self.session or self.session.reconciled or self.session.ahObservation then
                return
            end
            SessionLog("AHManager: owned auction fallback scan firing reason=%s", tostring(event or "direct"))
            self.awaitingOwnedAuctionSync = true
            self:OnOwnedAuctionsUpdated()
        end)
    end
end

function AHSessionController:OnOwnedAuctionsUpdated()
    SessionLog("AHManager: OWNED_AUCTIONS_UPDATED received session=%s reconciled=%s awaitingSync=%s",
        tostring(self.session), tostring(self.session and self.session.reconciled), tostring(self.awaitingOwnedAuctionSync))

    if not self.awaitingOwnedAuctionSync then
        -- This update was not caused by a query we issued (e.g. posting's
        -- AHListingService hydration query, or Blizzard's own post-cancel
        -- refresh). A full snapshot scan is not warranted; the next AH-open
        -- sync will reconcile the authoritative state.
        SessionLog("AHManager: OWNED_AUCTIONS_UPDATED ignored reason=no-pending-owned-auction-query")
        return
    end

    if not self.session then
        SessionLog("AHManager: OWNED_AUCTIONS_UPDATED ignored reason=ah-session-closed")
        self.awaitingOwnedAuctionSync = false
        return
    end

    local scanner = PocketCFO_AH:GetModule("OwnedAuctionsScanner", true)
    if not scanner or not scanner.ScanOwnedAuctions then
        Debug("AHManager: owned auction observe skipped; scanner unavailable")
        self.awaitingOwnedAuctionSync = false
        return
    end

    SessionLog("Scan trigger: owned-auctions-updated locations=ah")
    self.session.ahObservation = scanner:ScanOwnedAuctions()

    if self.session.ahObservation and self.session.ahObservation.complete == true then
        -- Sync satisfied. Leave the flag set (awaiting more events) if the
        -- result was not yet complete, so a later, ready OWNED_AUCTIONS_UPDATED
        -- for the same query still gets processed.
        self.awaitingOwnedAuctionSync = false
    end

    local postLifecycle = PocketCFO_AH.PostingLifecycleController
    if postLifecycle and postLifecycle.LogPostOwnedAuctionCycle then
        postLifecycle:LogPostOwnedAuctionCycle(self.session.ahObservation)
    end

    if self.pendingOwnedAuctionRefresh then
        local pending = self.pendingOwnedAuctionRefresh
        if not (self.session.ahObservation and self.session.ahObservation.complete == true) then
            SessionLog("AHManager: owned auction refresh waiting requestID=%s reason=%s snapshotWriteReason=%s",
                tostring(pending.requestID), tostring(pending.reason),
                tostring(self.session.ahObservation and self.session.ahObservation.snapshotWriteReason))
            return
        end
        self.pendingOwnedAuctionRefresh = nil
        SessionLog("AHManager: owned auction refresh complete requestID=%s reason=%s snapshotWritten=%s snapshotWriteReason=%s callbacks=%d",
            tostring(pending.requestID), tostring(pending.reason),
            tostring(self.session.ahObservation and self.session.ahObservation.snapshotWritten),
            tostring(self.session.ahObservation and self.session.ahObservation.snapshotWriteReason),
            #(pending.callbacks or {}))
        for _, callback in ipairs(pending.callbacks or {}) do
            callback(true, self.session.ahObservation, nil)
        end
    end
end

function AHSessionController:RequestOwnedAuctionsRefresh(reason, callback, timeoutSeconds)
    reason         = reason or "owned-auctions-refresh"
    timeoutSeconds = tonumber(timeoutSeconds) or 2

    if self.pendingOwnedAuctionRefresh then
        AddCallback(self.pendingOwnedAuctionRefresh.callbacks, callback)
        SessionLog("AHManager: owned auction refresh joined requestID=%s reason=%s callbacks=%d",
            tostring(self.pendingOwnedAuctionRefresh.requestID), tostring(reason),
            #(self.pendingOwnedAuctionRefresh.callbacks or {}))
        return true
    end

    local scanner = PocketCFO_AH:GetModule("OwnedAuctionsScanner", true)
    if not scanner or not scanner.QueryOwnedAuctions then
        SessionLog("AHManager: owned auction refresh failed reason=%s error=scanner-unavailable", tostring(reason))
        if type(callback) == "function" then
            callback(false, self.session and self.session.ahObservation or nil, "scannerUnavailable")
        end
        return false, "scannerUnavailable"
    end

    if not self.session then
        self.session = MakeNewSession({ postingRefresh = true })
        SessionLog("AHManager: owned auction refresh session created reason=%s openedAt=%s",
            tostring(reason), tostring(self.session.openedAt))
    end

    self.ownedAuctionRefreshRequestID = (tonumber(self.ownedAuctionRefreshRequestID) or 0) + 1
    local requestID = self.ownedAuctionRefreshRequestID
    local pending = {
        requestID = requestID,
        reason    = reason,
        callbacks = {},
    }
    AddCallback(pending.callbacks, callback)
    self.pendingOwnedAuctionRefresh = pending

    SessionLog("AHManager: owned auction refresh requested requestID=%s reason=%s timeout=%.2f",
        tostring(requestID), tostring(reason), timeoutSeconds)
    local queryOK = scanner:QueryOwnedAuctions()
    if queryOK then
        self.awaitingOwnedAuctionSync = true
    end
    if not queryOK then
        if self.pendingOwnedAuctionRefresh == pending then
            self.pendingOwnedAuctionRefresh = nil
        end
        SessionLog("AHManager: owned auction refresh failed requestID=%s reason=%s error=query-failed",
            tostring(requestID), tostring(reason))
        for _, pendingCallback in ipairs(pending.callbacks or {}) do
            pendingCallback(false, self.session and self.session.ahObservation or nil, "queryFailed")
        end
        return false, "queryFailed"
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(timeoutSeconds, function()
            if self.pendingOwnedAuctionRefresh ~= pending then
                return
            end
            self.pendingOwnedAuctionRefresh = nil
            SessionLog("AHManager: owned auction refresh timeout requestID=%s reason=%s; continuing with last known snapshot",
                tostring(requestID), tostring(reason))
            for _, pendingCallback in ipairs(pending.callbacks or {}) do
                pendingCallback(false, self.session and self.session.ahObservation or nil, "timeout")
            end
        end)
    end

    return true
end

function AHSessionController:StartAHOpenSessionIfAvailable(reason)
    if self.session then
        SessionLog("AHManager: startup skipped reason=%s existingSession=true", tostring(reason))
        return false
    end
    if not IsAuctionHouseAvailable() then
        SessionLog("AHManager: startup skipped reason=%s auctionHouseAvailable=false", tostring(reason))
        return false
    end
    SessionLog("AHManager: startup path invoking OnAHShow reason=%s", tostring(reason))
    self:OnAuctionHouseShow(reason or "startup")
    return true
end

function AHSessionController:RunManualOwnedAuctionScan()
    if not self.session then
        self.session = MakeNewSession({
            bagObservation = self:ScanBagsForAH("manual-ahscan"),
            manual         = true,
        })
        SessionLog("AHManager: manual session created openedAt=%s", tostring(self.session.openedAt))
    else
        self.session.reconciled             = false
        self.session.listingsWritten        = 0
        self.session.untrackedAuctionIDs    = {}
        self.session.untrackedCount         = 0
        self.session.untrackedSampleAuctionIDs = {}
        self.session.manual                 = true
    end

    local scanner = PocketCFO_AH:GetModule("OwnedAuctionsScanner", true)
    if not scanner or not scanner.ScanOwnedAuctions then
        SessionLog("AHManager: manual scan skipped scannerUnavailable=true")
        return nil, "OwnedAuctionsScanner unavailable"
    end

    self.session.ahObservation = scanner:ScanOwnedAuctions()

    local observation = self.session.ahObservation or {}
    observation.listingsWritten           = self.session.listingsWritten or 0
    observation.untrackedCount            = self.session.untrackedCount or 0
    observation.untrackedSampleAuctionIDs = CopyArray(self.session.untrackedSampleAuctionIDs)
    observation.storagePath               = "PocketCFO.db.global.inventorySnapshots[currentOwner].ah"
    SessionLog("AHManager: manual ahscan complete ownedCount=%d rows=%d skipped=%d snapshotWritten=%s snapshotWriteReason=%s storage=%s",
        tonumber(observation.ownedCount) or 0,
        tonumber(observation.normalizedRowCount or observation.rowCount) or 0,
        tonumber(observation.skippedCount) or 0,
        tostring(observation.snapshotWritten),
        tostring(observation.snapshotWriteReason),
        tostring(observation.storagePath))
    return observation
end

function AHSessionController:CloseSession()
    SessionLog("AHManager: AH close; skipped scans locations=ah,bags reason=close-event")
    self.session = nil
    self.awaitingOwnedAuctionSync = false
end
