-- PocketCFO/Services/InventoryStateService/InventoryStateService.lua
-- Canonical owner of current inventory availability. Phase 1 exposes the
-- service without migrating existing consumers.

local PocketCFO = _G.PocketCFO

local InventoryStateService = {}
local WARBAND_OWNER_KEY = "WARBAND"
local SNAPSHOT_STALE_SECONDS = 15 * 60

local VALID_LOCATIONS = {
    bags = true,
    bank = true,
    warbank = true,
    mail = true,
    ah = true,
}

local function GetObservationStore()
    return PocketCFO and PocketCFO.InventoryObservationStore or _G.PocketCFO_InventoryObservationStore
end

local function GetAdjustmentStore()
    return PocketCFO and PocketCFO.InventoryAdjustmentStore or _G.PocketCFO_InventoryAdjustmentStore
end

local function GetAggregator()
    return PocketCFO and PocketCFO.InventoryAggregator or _G.PocketCFO_InventoryAggregator
end

local function GetAvailability()
    return PocketCFO and PocketCFO.InventoryAvailabilityCalculator or _G.PocketCFO_InventoryAvailabilityCalculator
end

local function GetIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function NormalizeLocation(location)
    if location == "mailbox" then
        return "mail"
    end
    return location
end

local function Now()
    return PocketCFO and PocketCFO.Now and PocketCFO:Now() or time()
end

local function CurrentSessionID()
    return PocketCFO and PocketCFO.currentSessionID or nil
end

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function NotifyInventoryUpdated(ownerKey, location, rowCount, reason)
    if not PocketCFO or type(PocketCFO.SendMessage) ~= "function" then
        return
    end

    PocketCFO:SendMessage(
        "MCGCFO_INVENTORY_SNAPSHOT_UPDATED",
        ownerKey,
        location,
        rowCount or 0,
        reason or "updated"
    )
end

local function GetGlobalDB()
    return PocketCFO and PocketCFO.db and PocketCFO.db.global or nil
end

local function GetServiceRoot()
    local db = GetGlobalDB()
    if not db then return nil end
    db.inventoryStateService = db.inventoryStateService or {}
    db.inventoryStateService.snapshotFreshness = db.inventoryStateService.snapshotFreshness or {}
    return db.inventoryStateService
end

local function FreshnessKey(ownerKey, location)
    return tostring(ownerKey or "") .. ":" .. tostring(NormalizeLocation(location) or "")
end

local function GetFreshnessRoot()
    local root = GetServiceRoot()
    if not root then return nil end
    root.snapshotFreshness = root.snapshotFreshness or {}
    return root.snapshotFreshness
end

local function GetObservationRows(ownerKey, location)
    local observationStore = GetObservationStore()
    local observation = observationStore and observationStore:Get(ownerKey, NormalizeLocation(location))
    return observation and observation.rows or {}
end

local function GetObservation(ownerKey, location)
    local observationStore = GetObservationStore()
    return observationStore and observationStore:Get(ownerKey, NormalizeLocation(location)) or nil
end

local function CopyRow(row)
    if type(row) ~= "table" then
        return nil
    end
    local copy = {}
    for key, value in pairs(row) do
        copy[key] = value
    end
    return copy
end

local function NormalizeObservationRow(row, ownerKey, location)
    local copy = CopyRow(row)
    if not copy then
        return nil
    end

    local itemID = tonumber(copy.itemID)
    local quantity = tonumber(copy.quantity or copy.count or copy.stackCount)
    if not itemID or itemID <= 0 or not quantity or quantity <= 0 then
        return nil
    end

    copy.ownerKey = copy.ownerKey or ownerKey
    copy.location = NormalizeLocation(copy.location or location)
    copy.itemID = itemID
    copy.quantity = quantity
    copy.timestamp = tonumber(copy.timestamp) or Now()
    if copy.location == "ah" then
        copy.ahResolutionState = copy.ahResolutionState or "ACTIVE"
    end
    return copy
end

local function TableHasEntries(value)
    return type(value) == "table" and next(value) ~= nil
end

local function MigrateSnapshotRootToObservations(globalDB)
    local observationStore = GetObservationStore()
    if not observationStore or not TableHasEntries(globalDB.inventorySnapshots) then
        return 0, 0
    end

    local observations = globalDB.inventoryStateService and globalDB.inventoryStateService.observations
    if TableHasEntries(observations) then
        return 0, 0
    end

    local migratedOwners = 0
    local migratedRows = 0
    for ownerKey, ownerSnapshots in pairs(globalDB.inventorySnapshots or {}) do
        if type(ownerSnapshots) == "table" then
            migratedOwners = migratedOwners + 1
            for location, rows in pairs(ownerSnapshots) do
                location = NormalizeLocation(location)
                if VALID_LOCATIONS[location] and type(rows) == "table" then
                    local observation = observationStore:Replace(ownerKey, location, rows, {
                        source = "inventorySnapshots-migration",
                        reason = "initialize",
                    })
                    migratedRows = migratedRows + #(observation and observation.rows or {})
                end
            end
        end
    end
    return migratedOwners, migratedRows
end

local function CountSnapshotRows(snapshotRoot)
    local owners = 0
    local rows = 0

    if type(snapshotRoot) ~= "table" then
        return owners, rows
    end

    for _, ownerSnapshots in pairs(snapshotRoot) do
        if type(ownerSnapshots) == "table" then
            owners = owners + 1
            for _, locationRows in pairs(ownerSnapshots) do
                if type(locationRows) == "table" then
                    rows = rows + #locationRows
                end
            end
        end
    end

    return owners, rows
end

local function CurrentOwnerKey()
    return PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID
        or UnitGUID and UnitGUID("player")
        or nil
end

function InventoryStateService:InitializeDatabase(globalDB)
    if type(globalDB) ~= "table" then
        return {
            snapshotOwners = 0,
            snapshotRows = 0,
        }
    end

    if not TableHasEntries(globalDB.inventorySnapshots) and TableHasEntries(globalDB.observedInventory) then
        globalDB.inventorySnapshots = globalDB.observedInventory
    else
        globalDB.inventorySnapshots = globalDB.inventorySnapshots or globalDB.observedInventory or {}
    end
    globalDB.observedInventory = globalDB.inventorySnapshots
    globalDB.pendingAHSnapshotReductions = globalDB.pendingAHSnapshotReductions or {}
    globalDB.pendingAHMailboxEvidence = globalDB.pendingAHMailboxEvidence or {}
    globalDB.mailboxResolutionEvidenceScans = globalDB.mailboxResolutionEvidenceScans or {}
    globalDB.inventoryStateService = globalDB.inventoryStateService or {}
    globalDB.inventoryStateService.observations = globalDB.inventoryStateService.observations or {}
    globalDB.inventoryStateService.adjustments = globalDB.inventoryStateService.adjustments or {}
    globalDB.inventoryStateService.snapshotFreshness = globalDB.inventoryStateService.snapshotFreshness or {}
    globalDB.inventoryStateService.nextAdjustmentID = tonumber(globalDB.inventoryStateService.nextAdjustmentID) or 0
    globalDB.inventoryStateService.pendingAHReductions =
        globalDB.inventoryStateService.pendingAHReductions or globalDB.pendingAHSnapshotReductions or {}
    globalDB.inventoryStateService.pendingAHMailboxEvidence =
        globalDB.inventoryStateService.pendingAHMailboxEvidence or globalDB.pendingAHMailboxEvidence or {}
    globalDB.inventoryStateService.mailboxResolutionEvidenceScans =
        globalDB.inventoryStateService.mailboxResolutionEvidenceScans or globalDB.mailboxResolutionEvidenceScans or {}
    globalDB.inventoryStateService.appliedAHMailboxReconciliations =
        globalDB.inventoryStateService.appliedAHMailboxReconciliations or {}
    local migratedOwners, migratedRows = MigrateSnapshotRootToObservations(globalDB)

    local snapshotOwners, snapshotRows = CountSnapshotRows(globalDB.inventorySnapshots)
    return {
        snapshotOwners = snapshotOwners,
        snapshotRows = snapshotRows,
        migratedOwners = migratedOwners,
        migratedRows = migratedRows,
    }
end

local function ResolveConfigKey(evidence)
    if type(evidence) == "string" then
        return evidence, {}
    end
    if type(evidence) ~= "table" then
        return nil, nil, "missingEvidence"
    end
    if evidence.configKey and evidence.configKey ~= "" then
        return evidence.configKey, evidence
    end

    local identityService = GetIdentityService()
    if not identityService then
        return nil, evidence, "identityServiceUnavailable"
    end

    local identity
    if evidence.itemLink and identityService.FromItemLink then
        identity = identityService:FromItemLink(evidence.itemLink)
    elseif evidence.itemID and identityService.FromItemID then
        identity = identityService:FromItemID(evidence.itemID)
    elseif identityService.Identify then
        identity = identityService:Identify(evidence)
    end

    if identity and identity.configKey then
        return identity.configKey, identity
    end
    return nil, identity, identity and identity.unresolvedReason or "configKeyUnavailable"
end

local function BuildState(options)
    local observations = GetObservationStore() and GetObservationStore():List() or {}
    local adjustments = GetAdjustmentStore() and GetAdjustmentStore():List({ includeInactive = false }) or {}
    local characterOwnerKey = (type(options) == "table" and options.characterOwnerKey) or CurrentOwnerKey()
    local scopedOptions = { characterOwnerKey = characterOwnerKey }
    if type(options) == "table" then
        for k, v in pairs(options) do
            if scopedOptions[k] == nil then
                scopedOptions[k] = v
            end
        end
    end
    return GetAggregator():BuildState(observations, adjustments, scopedOptions)
end

function InventoryStateService:ReplaceObservation(ownerKey, location, rows, metadata)
    local observationStore = GetObservationStore()
    local adjustmentStore = GetAdjustmentStore()
    if not observationStore then
        return nil, "observationStoreUnavailable"
    end

    location = NormalizeLocation(location)
    local observation, err = observationStore:Replace(ownerKey, location, rows, metadata)
    if not observation then
        return nil, err
    end

    local cleared = adjustmentStore and adjustmentStore:ClearForLocation(ownerKey, location, "authoritativeObservation") or 0
    observation.clearedAdjustmentCount = cleared
    if cleared > 0 then
        SessionLog("InventoryStateService: authoritative observation cleared adjustments owner=%s location=%s clearedCount=%d",
            tostring(ownerKey), tostring(location), cleared)
    end
    return observation
end

function InventoryStateService:ReplaceSnapshot(ownerKey, location, rows, options)
    location = NormalizeLocation(location)
    if not ownerKey or ownerKey == "" then
        return nil, "missingOwnerKey"
    end
    if not VALID_LOCATIONS[location] then
        return nil, "invalidLocation"
    end

    local incomingRows = rows or {}
    local normalizedRows = {}
    for _, row in ipairs(incomingRows) do
        local normalized = NormalizeObservationRow(row, ownerKey, location)
        if normalized then
            normalizedRows[#normalizedRows + 1] = normalized
        end
    end

    if ownerKey == WARBAND_OWNER_KEY
    and location == "warbank"
    and #incomingRows == 0
    and #normalizedRows == 0
    and #GetObservationRows(ownerKey, location) > 0 then
        local preservedRows = GetObservationRows(ownerKey, location)
        self:RecordSnapshotScan(ownerKey, location, {
            reason = options and options.reason or "preserve",
            succeeded = true,
        })
        SessionLog("InventoryStateService:ReplaceSnapshot preserved owner=%s location=%s incomingRows=%d storedRows=%d reason=empty-warbank-write",
            tostring(ownerKey), tostring(location), #incomingRows, #preservedRows)
        NotifyInventoryUpdated(ownerKey, location, #preservedRows, "preserve")
        return preservedRows
    end

    local observation, err = self:ReplaceObservation(ownerKey, location, normalizedRows, options)
    if not observation then
        self:RecordSnapshotScan(ownerKey, location, {
            reason = options and options.reason or err or "replace-failed",
            succeeded = false,
        })
        return nil, err
    end

    self:RecordSnapshotScan(ownerKey, location, {
        reason = options and options.reason or "replace",
        succeeded = true,
    })

    SessionLog("InventoryStateService:ReplaceSnapshot owner=%s location=%s incomingRows=%d storedRows=%d",
        tostring(ownerKey), tostring(location), #incomingRows, #(observation.rows or {}))
    NotifyInventoryUpdated(ownerKey, location, #(observation.rows or {}), "replace")
    return observation.rows or {}
end

function InventoryStateService:GetLocationSnapshot(ownerKey, location)
    return GetObservationRows(ownerKey, location)
end

function InventoryStateService:GetSnapshotRoot()
    local root = {}
    local observations = GetObservationStore() and GetObservationStore():List() or {}
    for ownerKey, ownerObservations in pairs(observations or {}) do
        root[ownerKey] = root[ownerKey] or {}
        for location, observation in pairs(ownerObservations or {}) do
            root[ownerKey][NormalizeLocation(location)] = observation.rows or {}
        end
    end
    return root
end

function InventoryStateService:RecordSnapshotScan(ownerKey, location, metadata)
    location = NormalizeLocation(location)
    ownerKey = ownerKey or CurrentOwnerKey()
    if not ownerKey or ownerKey == "" or not VALID_LOCATIONS[location] then
        return nil
    end

    local freshness = GetFreshnessRoot()
    if not freshness then return nil end

    metadata = type(metadata) == "table" and metadata or {}
    local key = FreshnessKey(ownerKey, location)
    local now = Now()
    freshness[key] = freshness[key] or {}
    local record = freshness[key]
    record.ownerKey = ownerKey
    record.location = location
    record.lastScanAt = now
    record.lastScanReason = metadata.reason or metadata.source or "unknown"
    record.lastScanSucceeded = metadata.succeeded ~= false
    if record.lastScanSucceeded then
        record.dirtySinceLastScan = false
        record.dirtyReason = nil
        record.dirtyAt = nil
        if location == "bags" then
            record.lastScanSessionID = CurrentSessionID()
        end
    end

    SessionLog("InventoryStateService: snapshot freshness owner=%s location=%s succeeded=%s reason=%s dirty=%s sessionID=%s",
        tostring(ownerKey), tostring(location), tostring(record.lastScanSucceeded),
        tostring(record.lastScanReason), tostring(record.dirtySinceLastScan == true), tostring(record.lastScanSessionID))
    return record
end

function InventoryStateService:MarkSnapshotDirty(ownerKey, location, reason)
    location = NormalizeLocation(location)
    ownerKey = ownerKey or CurrentOwnerKey()
    if not ownerKey or ownerKey == "" or not VALID_LOCATIONS[location] then
        return nil
    end

    local freshness = GetFreshnessRoot()
    if not freshness then return nil end

    local key = FreshnessKey(ownerKey, location)
    freshness[key] = freshness[key] or {
        ownerKey = ownerKey,
        location = location,
    }
    local record = freshness[key]
    record.ownerKey = ownerKey
    record.location = location
    record.dirtySinceLastScan = true
    record.dirtyReason = reason or "dirty"
    record.dirtyAt = Now()
    SessionLog("InventoryStateService: snapshot marked dirty owner=%s location=%s reason=%s",
        tostring(ownerKey), tostring(location), tostring(record.dirtyReason))
    return record
end

function InventoryStateService:GetSnapshotFreshness(ownerKey, location)
    location = NormalizeLocation(location)
    ownerKey = ownerKey or CurrentOwnerKey()
    local freshness = GetFreshnessRoot()
    if not freshness or not ownerKey or ownerKey == "" then return nil end
    return freshness[FreshnessKey(ownerKey, location)]
end

function InventoryStateService:IsSnapshotUsable(location, ownerKey, options)
    location = NormalizeLocation(location)
    ownerKey = ownerKey or CurrentOwnerKey()
    if not ownerKey or ownerKey == "" or not VALID_LOCATIONS[location] then
        return false, "invalidContext"
    end

    local observation = GetObservation(ownerKey, location)
    if type(observation) ~= "table" or type(observation.rows) ~= "table" then
        return false, "missingSnapshot"
    end

    local record = self:GetSnapshotFreshness(ownerKey, location)
    if not record then
        return false, "missingFreshness"
    end
    if record.lastScanSucceeded ~= true then
        return false, "lastScanFailed"
    end
    if record.dirtySinceLastScan == true then
        return false, "dirty"
    end

    if location == "bags" then
        local sessionID = CurrentSessionID()
        if not sessionID or record.lastScanSessionID ~= sessionID then
            return false, "differentSession"
        end
        return true, "usable"
    end

    local staleSeconds = tonumber(options and options.staleSeconds) or SNAPSHOT_STALE_SECONDS
    local lastScanAt = tonumber(record.lastScanAt)
    if not lastScanAt then
        return false, "missingLastScanAt"
    end
    if staleSeconds > 0 and Now() - lastScanAt > staleSeconds then
        return false, "stale"
    end

    return true, "usable"
end

function InventoryStateService:GetWarbandOwnerKey()
    return WARBAND_OWNER_KEY
end

function InventoryStateService:MarkMailboxResolutionEvidenceScan(ownerKey, scanTimestamp)
    local root = GetServiceRoot()
    if not root or not ownerKey or ownerKey == "" then
        return nil
    end
    root.mailboxResolutionEvidenceScans = root.mailboxResolutionEvidenceScans or {}
    root.mailboxResolutionEvidenceScans[ownerKey] = {
        ownerKey = ownerKey,
        sessionID = tostring(scanTimestamp or Now()) .. ":" .. tostring(math.random(1, 1000000)),
        scanTimestamp = tonumber(scanTimestamp) or Now(),
    }
    return root.mailboxResolutionEvidenceScans[ownerKey]
end

function InventoryStateService:GetPendingAHReductions(ownerKey)
    local root = GetServiceRoot()
    if not root or not ownerKey or ownerKey == "" then
        return {}
    end
    root.pendingAHReductions = root.pendingAHReductions or {}
    root.pendingAHReductions[ownerKey] = root.pendingAHReductions[ownerKey] or {}
    return root.pendingAHReductions[ownerKey]
end

local function PendingEvidenceKey(evidence)
    return tostring(evidence and evidence.mailboxScanSessionID or "")
        .. "|"
        .. tostring(evidence and evidence.mailIndex or "")
        .. "|"
        .. tostring(evidence and evidence.itemID or evidence and evidence.itemName or "")
        .. "|"
        .. tostring(evidence and evidence.quantity or "")
end

function InventoryStateService:StorePendingAHMailboxEvidence(ownerKey, evidence, reason, source)
    local root = GetServiceRoot()
    if not root or not ownerKey or ownerKey == "" or type(evidence) ~= "table" then
        return nil
    end
    root.pendingAHMailboxEvidence = root.pendingAHMailboxEvidence or {}
    root.pendingAHMailboxEvidence[ownerKey] = root.pendingAHMailboxEvidence[ownerKey] or {}

    local key = PendingEvidenceKey(evidence)
    local stored = CopyRow(evidence) or {}
    stored.ownerKey = ownerKey
    stored.reason = reason
    stored.source = source
    stored.storedAt = Now()
    root.pendingAHMailboxEvidence[ownerKey][key] = stored
    return stored
end

function InventoryStateService:StorePendingAHMailboxEvidenceRows(ownerKey, rows, source)
    local storedCount = 0
    for _, evidence in ipairs(rows or {}) do
        if self:StorePendingAHMailboxEvidence(ownerKey, evidence, "unresolved", source) then
            storedCount = storedCount + 1
        end
    end
    return storedCount
end

function InventoryStateService:ResolvePendingAHMailboxEvidence(ownerKey, source)
    local root = GetServiceRoot()
    if not root or not ownerKey or ownerKey == "" then
        return 0
    end
    root.pendingAHMailboxEvidence = root.pendingAHMailboxEvidence or {}
    local pending = root.pendingAHMailboxEvidence[ownerKey] or {}
    local count = 0
    for _ in pairs(pending) do
        count = count + 1
    end
    SessionLog("InventoryStateService: pending AH mailbox evidence retained owner=%s rows=%d source=%s",
        tostring(ownerKey), count, tostring(source))
    return 0
end

function InventoryStateService:RecordObservation(observation)
    if type(observation) ~= "table" then
        return nil, "missingObservation"
    end
    return self:ReplaceObservation(
        observation.ownerKey,
        observation.location,
        observation.rows or observation.items or {},
        observation
    )
end

function InventoryStateService:AddAdjustment(adjustment)
    local adjustmentStore = GetAdjustmentStore()
    if not adjustmentStore then
        return nil, "adjustmentStoreUnavailable"
    end

    local configKey, identity, err = ResolveConfigKey(adjustment)
    if not configKey then
        return nil, err
    end
    adjustment.configKey = configKey
    adjustment.itemID = adjustment.itemID or identity and identity.itemID
    adjustment.itemName = adjustment.itemName or identity and identity.itemName
    return adjustmentStore:Add(adjustment)
end

function InventoryStateService:AddTransfer(eventType, ownerKey, fromLocation, toLocation, evidence, quantity, metadata)
    local adjustmentStore = GetAdjustmentStore()
    if not adjustmentStore then
        return nil, "adjustmentStoreUnavailable"
    end

    local configKey, identity, err = ResolveConfigKey(evidence)
    if not configKey then
        return nil, err
    end
    metadata = type(metadata) == "table" and metadata or {}
    metadata.itemID = metadata.itemID or identity and identity.itemID
    metadata.itemName = metadata.itemName or identity and identity.itemName
    metadata.itemLink = metadata.itemLink or identity and identity.itemLink
    return adjustmentStore:AddTransfer(eventType, ownerKey, fromLocation, toLocation, configKey, quantity, metadata)
end

function InventoryStateService:RecordAuctionPosted(ownerKey, evidence, quantity, metadata)
    return self:AddTransfer("auctionPosted", ownerKey or CurrentOwnerKey(), "bags", "ah", evidence, quantity, metadata)
end

function InventoryStateService:RecordAuctionCancelled(ownerKey, evidence, quantity, metadata)
    return self:AddTransfer("auctionCancelled", ownerKey or CurrentOwnerKey(), "ah", "mail", evidence, quantity, metadata)
end

function InventoryStateService:RecordAuctionSold(ownerKey, evidence, quantity, metadata)
    return self:AddTransfer("auctionSold", ownerKey or CurrentOwnerKey(), "ah", nil, evidence, quantity, metadata)
end

function InventoryStateService:RecordAuctionExpired(ownerKey, evidence, quantity, metadata)
    return self:AddTransfer("auctionExpired", ownerKey or CurrentOwnerKey(), "ah", "mail", evidence, quantity, metadata)
end

function InventoryStateService:RecordAuctionReturned(ownerKey, evidence, quantity, metadata)
    return self:AddTransfer("auctionReturned", ownerKey or CurrentOwnerKey(), "ah", "mail", evidence, quantity, metadata)
end

function InventoryStateService:RecordMailCollected(ownerKey, evidence, quantity, metadata)
    return self:AddTransfer("mailCollected", ownerKey or CurrentOwnerKey(), "mail", "bags", evidence, quantity, metadata)
end

local function ReconciliationResultKey(ownerKey, result)
    if type(result) ~= "table" then
        return nil
    end
    local evidenceKey = result.evidenceKey
    if evidenceKey and evidenceKey ~= "" then
        return table.concat({
            tostring(ownerKey or result.ownerKey or ""),
            tostring(result.auctionID or ""),
            tostring(result.outcome or ""),
            tostring(evidenceKey),
        }, "|")
    end
    if result.auctionID and result.outcome and result.configKey then
        return table.concat({
            tostring(ownerKey or result.ownerKey or ""),
            tostring(result.auctionID),
            tostring(result.outcome),
            tostring(result.configKey),
            tostring(result.quantity or ""),
        }, "|")
    end
    return nil
end

local function BuildReconciliationEvidence(result)
    local evidence = CopyRow(result) or {}
    evidence.evidenceType = evidence.evidenceType or "ahMailboxReconciliation"
    evidence.source = evidence.source or "ah-mailbox-reconciler"
    evidence.location = evidence.location or "ah"
    return evidence
end

function InventoryStateService:ApplyAHMailboxReconciliationResults(ownerKey, results, options)
    options = type(options) == "table" and options or {}
    ownerKey = ownerKey or CurrentOwnerKey()
    if not ownerKey or ownerKey == "" then
        return nil, "missingOwnerKey"
    end

    local root = GetServiceRoot()
    if not root then
        return nil, "dbUnavailable"
    end
    root.appliedAHMailboxReconciliations = root.appliedAHMailboxReconciliations or {}

    local applied = {}
    local skipped = {}
    local adjustmentCount = 0
    for _, result in ipairs(results or {}) do
        if type(result) == "table" then
            local key = ReconciliationResultKey(ownerKey, result)
            if key and root.appliedAHMailboxReconciliations[key] then
                skipped[#skipped + 1] = {
                    result = result,
                    reason = "alreadyApplied",
                }
            else
                local quantity = tonumber(result.quantity) or 0
                local evidence = BuildReconciliationEvidence(result)
                local metadata = {
                    reason = result.reason or result.outcome,
                    itemID = result.itemID,
                    itemName = result.itemName,
                    itemLink = result.itemLink,
                    auctionID = result.auctionID,
                    evidenceKey = result.evidenceKey,
                    source = options.source or "ah-mailbox-reconciler",
                    outcome = result.outcome,
                }
                local adjustments, err
                local eventType
                if result.outcome == "sold" then
                    eventType = "auctionSold"
                elseif result.outcome == "expired" then
                    eventType = "auctionExpired"
                elseif result.outcome == "cancelled" or result.outcome == "canceled" then
                    eventType = "auctionCancelled"
                elseif result.outcome == "returned" then
                    eventType = "auctionReturned"
                end
                if eventType then
                    -- Remove from AH only. MailboxScanner already writes returned items into the mail snapshot.
                    adjustments, err = self:AddTransfer(eventType, ownerKey, "ah", nil, evidence, quantity, metadata)
                else
                    err = "unsupportedOutcome"
                end

                if adjustments then
                    adjustmentCount = adjustmentCount + #adjustments
                    applied[#applied + 1] = {
                        result = result,
                        adjustments = adjustments,
                    }
                    if key then
                        root.appliedAHMailboxReconciliations[key] = {
                            ownerKey = ownerKey,
                            auctionID = result.auctionID,
                            configKey = result.configKey,
                            outcome = result.outcome,
                            quantity = quantity,
                            evidenceKey = result.evidenceKey,
                            appliedAt = Now(),
                        }
                    end
                else
                    skipped[#skipped + 1] = {
                        result = result,
                        reason = err or "adjustmentRejected",
                    }
                end
            end
        end
    end

    if options.unresolvedEvidence then
        self:StorePendingAHMailboxEvidenceRows(ownerKey, options.unresolvedEvidence, options.source or "ah-mailbox-reconciler")
    end

    if adjustmentCount > 0 then
        NotifyInventoryUpdated(ownerKey, "ah", adjustmentCount, "ahMailboxReconciliation")
    end

    SessionLog("InventoryStateService: applied AH mailbox reconciliation owner=%s results=%d applied=%d adjustments=%d skipped=%d",
        tostring(ownerKey), #(results or {}), #applied, adjustmentCount, #skipped)

    return {
        applied = applied,
        skipped = skipped,
        adjustmentCount = adjustmentCount,
    }
end

function InventoryStateService:RecordCraftCompleted(ownerKey, consumedRows, producedRows, metadata)
    ownerKey = ownerKey or CurrentOwnerKey()
    local added = {}
    for _, row in ipairs(consumedRows or {}) do
        local result, err = self:AddTransfer("craftCompleted", ownerKey, NormalizeLocation(row.location or "bags"), nil, row, row.quantity or row.count or 1, metadata)
        if not result then
            return nil, err
        end
        for _, adjustment in ipairs(result) do
            added[#added + 1] = adjustment
        end
    end
    for _, row in ipairs(producedRows or {}) do
        local result, err = self:AddTransfer("craftCompleted", ownerKey, nil, NormalizeLocation(row.location or "bags"), row, row.quantity or row.count or 1, metadata)
        if not result then
            return nil, err
        end
        for _, adjustment in ipairs(result) do
            added[#added + 1] = adjustment
        end
    end
    return added
end

function InventoryStateService:ClearAdjustmentsForLocation(ownerKey, location, reason)
    local adjustmentStore = GetAdjustmentStore()
    if not adjustmentStore then
        return 0
    end
    return adjustmentStore:ClearForLocation(ownerKey, location, reason)
end

function InventoryStateService:GetCurrentState(options)
    return BuildState(options)
end

function InventoryStateService:GetCurrentQuantityByConfigKey(configKey, options)
    local state = BuildState(options)
    return GetAvailability():GetAvailableQuantity(state, configKey, options)
end

function InventoryStateService:GetQuantityByLocation(configKey, location, options)
    local state = BuildState(options)
    return GetAvailability():GetLocationQuantity(state, configKey, location)
end

function InventoryStateService:GetTotalQuantity(configKey, options)
    return self:GetCurrentQuantityByConfigKey(configKey, options)
end

function InventoryStateService:GetAvailability(configKeyOrEvidence, options)
    local configKey, identity, err = ResolveConfigKey(configKeyOrEvidence)
    if not configKey then
        return {
            configKey = nil,
            availableQuantity = 0,
            unresolved = true,
            unresolvedReason = err,
        }
    end

    local state = BuildState(options)
    local entry = state.byConfigKey[configKey]
    return {
        configKey = configKey,
        identity = identity,
        availableQuantity = GetAvailability():GetAvailableQuantity(state, configKey, options),
        totalQuantity = entry and entry.totalQuantity or 0,
        byLocation = entry and entry.byLocation or {},
        byOwner = entry and entry.byOwner or {},
    }
end

function InventoryStateService:GetSummary(options)
    return GetAvailability():GetSummary(BuildState(options))
end

function InventoryStateService:BuildCurrentState(options)
    return BuildState(options)
end

function InventoryStateService:GetAvailabilityFromState(state, configKeyOrEvidence, options)
    local configKey, identity, err = ResolveConfigKey(configKeyOrEvidence)
    if not configKey then
        return {
            configKey = nil,
            availableQuantity = 0,
            unresolved = true,
            unresolvedReason = err,
        }
    end
    local entry = state and state.byConfigKey and state.byConfigKey[configKey]
    return {
        configKey = configKey,
        identity = identity,
        availableQuantity = GetAvailability():GetAvailableQuantity(state, configKey, options),
        totalQuantity = entry and entry.totalQuantity or 0,
        byLocation = entry and entry.byLocation or {},
        byOwner = entry and entry.byOwner or {},
    }
end

function InventoryStateService:GetObservations()
    return GetObservationStore() and GetObservationStore():List() or {}
end

function InventoryStateService:GetAdjustments(options)
    return GetAdjustmentStore() and GetAdjustmentStore():List(options) or {}
end

if PocketCFO then
    PocketCFO.InventoryStateService = InventoryStateService
end

_G.InventoryStateService = InventoryStateService
