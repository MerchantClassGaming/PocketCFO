-- PocketCFO/Services/AuctionListingStateService/AuctionListingStateService.lua
-- Core canonical source of truth for owned auction lifecycle state, keyed by auctionID.
-- Answers: is this auctionID currently owned? What active auctions exist for this configKey?
-- Does not own: market discovery, ladder ordering, posting/cancel decisions, mailbox reconciliation.
-- C_AuctionHouse hydration lives in PocketCFO_AH AHListingService, which delegates state
-- reads and writes here. Core can load and query listing state without PocketCFO_AH loaded.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local PocketCFO = _G.PocketCFO

local AuctionListingStateService = PocketCFO:NewModule("AuctionListingStateService")

local INACTIVE_RETENTION_DAYS = 30
local MAX_INACTIVE_ROWS = 5000

local VALID_CLOSE_STATUSES = {
    canceled  = true,
    cancelled = true,
    closed    = true,
    expired   = true,
    returned  = true,
    sold      = true,
}

local VALID_MAILBOX_RESOLUTIONS = {
    sold     = true,
    canceled = true,
    expired  = true,
}

-- Conservative upper bounds for Blizzard timeLeft buckets (seconds of maximum remaining time at scan time).
-- Numeric keys match Enum.AuctionHouseTimeLeftBand; string keys cover name-form values.
local TIME_LEFT_MAX_SECONDS = {
    [1] = 1800,   -- VeryShort: < 30 min      → max 30 min
    [2] = 7200,   -- Short:     30 min – 2 hr  → max 2 hr
    [3] = 28800,  -- Medium:    2 hr – 8 hr    → max 8 hr
    [4] = 86400,  -- Long:      8 hr – 24 hr   → max 24 hr
    [5] = 172800, -- VeryLong:  > 24 hr         → max 48 hr (conservative)
    ["VERY_SHORT"] = 1800,
    ["SHORT"]      = 7200,
    ["MEDIUM"]     = 28800,
    ["LONG"]       = 86400,
    ["VERY_LONG"]  = 172800,
}

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

local function AuctionKey(auctionID)
    if auctionID == nil or auctionID == "" then
        return nil
    end
    return tostring(auctionID)
end

local function ByAuctionIDTable()
    local db = PocketCFO.db.global
    db.ahListings = db.ahListings or {}
    return db.ahListings
end

local function ByConfigKeyTable()
    local db = PocketCFO.db.global
    db.ahListingsByConfigKey = db.ahListingsByConfigKey or {}
    return db.ahListingsByConfigKey
end

local function EnsureStorageShape()
    local db = PocketCFO.db.global
    db.ahListings              = db.ahListings or {}
    db.ahListingsByConfigKey   = db.ahListingsByConfigKey or {}
    db.ahListingPendingCreates = db.ahListingPendingCreates or {}
    return db
end

local function PendingCreatesTable()
    return EnsureStorageShape().ahListingPendingCreates
end

local function GetIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function IndexByConfigKey(configKey, auctionID)
    if not configKey or not auctionID then
        return
    end
    local index = ByConfigKeyTable()
    index[configKey] = index[configKey] or {}
    index[configKey][tostring(auctionID)] = true
end

local function UnindexByConfigKey(configKey, auctionID)
    if not configKey or not auctionID then
        return
    end
    local index = ByConfigKeyTable()
    local auctionIDSet = index[configKey]
    if not auctionIDSet then
        return
    end
    auctionIDSet[tostring(auctionID)] = nil
end

local function RebuildIndexes()
    local db = EnsureStorageShape()
    db.ahListingsByConfigKey = {}
    for key, row in pairs(db.ahListings or {}) do
        if type(row) == "table" then
            local auctionID = row.auctionID or key
            if row.configKey and auctionID then
                IndexByConfigKey(row.configKey, auctionID)
            end
        end
    end
end

local function ResolveIdentityFromEvidence(evidence, evidenceType)
    local identityService = GetIdentityService()
    if not identityService then
        return nil, evidence and evidence.configKey, "identityServiceUnavailable"
    end

    local identity
    if evidenceType == "ownedAuctionRow" and identityService.FromOwnedAuctionRow then
        identity = identityService:FromOwnedAuctionRow(evidence)
    elseif identityService.FromAuctionRow then
        identity = identityService:FromAuctionRow(evidence)
    elseif identityService.Resolve then
        local lookup = {}
        for key, value in pairs(evidence or {}) do
            lookup[key] = value
        end
        lookup.evidenceType = evidenceType or "auctionRow"
        identity = identityService:Resolve(lookup)
    end

    local configKey = identity and not identity.unresolved and identity.configKey or nil
    if not configKey then
        configKey = evidence and evidence.configKey or nil
    end
    return identity, configKey, (identity and identity.unresolvedReason) or (configKey and nil or "configKeyUnavailable")
end

local function ApplyIdentity(row, evidence, evidenceType)
    local identity, configKey, unresolvedReason = ResolveIdentityFromEvidence(evidence, evidenceType)
    local previousConfigKey = row.configKey

    row.configKey = configKey or row.configKey
    if identity then
        row.itemID        = identity.itemID        or row.itemID
        row.itemName      = identity.itemName      or row.itemName
        row.itemLink      = identity.itemLink      or row.itemLink
        row.auctionPath   = identity.auctionPath   or row.auctionPath
        row.identitySource = identity.source       or row.identitySource
    end

    if row.configKey then
        row.unresolvedReason = nil
    else
        row.unresolvedReason = unresolvedReason or row.unresolvedReason
    end

    return previousConfigKey, row.configKey
end

local function GetOwnerKey()
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.char
        and PocketCFO.db.char.characterGUID
        or nil
end

local function GetItemIDFromLink(itemLink)
    if not itemLink then
        return nil
    end
    if GetItemInfoFromHyperlink then
        local ok, itemID = pcall(GetItemInfoFromHyperlink, itemLink)
        if ok and itemID then
            return tonumber(itemID)
        end
    end
    return tonumber(tostring(itemLink):match("item:(%d+)"))
end

local function ExtractItemLink(info)
    return info and (info.itemLink or info.hyperlink or info.link) or nil
end

local function ExtractItemID(info, itemLink)
    if type(info) ~= "table" then
        return nil
    end
    if info.itemID or info.itemId then
        return tonumber(info.itemID or info.itemId)
    end
    if type(info.itemKey) == "table" and info.itemKey.itemID then
        return tonumber(info.itemKey.itemID)
    end
    return GetItemIDFromLink(itemLink or ExtractItemLink(info))
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
    -- Defensive: C_AuctionHouse may be unavailable outside AH context; guarded below.
    if info and info.itemKey and C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
        local ok, itemKeyInfo = pcall(C_AuctionHouse.GetItemKeyInfo, info.itemKey)
        if ok and itemKeyInfo and itemKeyInfo.itemName then
            return itemKeyInfo.itemName
        end
    end
    return nil
end

local function ActiveListingIsComplete(row)
    return type(row) == "table"
        and row.status == "active"
        and row.configKey ~= nil
        and tonumber(row.itemID) ~= nil
        and tostring(row.itemName or "") ~= ""
        and tostring(row.itemName or "") ~= "Unknown"
        and (tonumber(row.unitPrice) or tonumber(row.postedPrice) or tonumber(row.buyout) or 0) > 0
        and (tonumber(row.quantity) or 0) > 0
end

local ClearPendingCreate  -- forward declaration; defined below StoreMergedListing

local function NormalizeEvidenceSource(source)
    source = tostring(source or "")
    if source == "auction_created_event" then
        return "auction_created"
    end
    if source == "auction_created_hydrate" or source == "owned_auction_hydrate" then
        return "owned_hydration"
    end
    if source == "" then
        return nil
    end
    return source
end

local function Useful(value)
    return value ~= nil and value ~= ""
end

local function SetUsefulField(row, field, value, overwrite)
    if not Useful(value) then return end
    if overwrite or row[field] == nil or row[field] == "" or row[field] == "Unknown" then
        row[field] = value
    end
end

local function SetUsefulNumber(row, field, value, overwrite)
    local number = tonumber(value)
    if not number then return end
    if overwrite or tonumber(row[field]) == nil then
        row[field] = number
    end
end

local function MergeAHListing(row, evidence, source, now)
    evidence = evidence or {}
    source   = NormalizeEvidenceSource(source or evidence.source) or "owned_scan"
    now      = now or Now()

    local isNew           = row == nil
    row                   = row or {}
    local auctionID       = evidence.auctionID or row.auctionID
    local previousConfigKey = row.configKey
    local fillOnly        = source == "owned_scan_backfill"
    local ownedHydration  = source == "owned_hydration" or source == "owned_scan" or source == "owned_scan_backfill"
    local listingObserved = source == "auction_created" or ownedHydration

    row.auctionID         = auctionID
    row.status            = evidence.status or row.status or "active"
    row.mailboxResolution = row.mailboxResolution or "unresolved"

    if source == "auction_created" then
        row.auctionCreatedSeen   = true
        row.auctionCreatedAt     = row.auctionCreatedAt or now
        row.auctionCreatedSource = "auction_created"
        row.createdAt            = row.createdAt or now
        if row.createdEvidenceSource ~= "auction_created" then
            row.createdEvidenceSource = "auction_created"
        end
        row.postedAt = tonumber(evidence.postedAt) or row.postedAt or now
    elseif isNew then
        row.createdEvidenceSource = source
    end

    if listingObserved then
        row.lastObservedAt = now
    end

    if ownedHydration then
        if row.status ~= "canceled" then
            row.status = "active"
        end
        row.ownedHydrated   = true
        row.ownedHydratedAt = now
        row.lastConfirmedAt = now
    end

    local overwrite = not fillOnly
    SetUsefulNumber(row, "itemID",         evidence.itemID,         overwrite)
    SetUsefulField (row, "itemName",       evidence.itemName,       overwrite)
    SetUsefulField (row, "itemLink",       evidence.itemLink,       overwrite)
    SetUsefulField (row, "itemGUID",       evidence.itemGUID,       overwrite)
    SetUsefulField (row, "ledgerID",       evidence.ledgerID,       overwrite)
    SetUsefulNumber(row, "quantity",       evidence.quantity,       overwrite)
    SetUsefulField (row, "ownerKey",       evidence.ownerKey,       overwrite)
    SetUsefulField (row, "itemKey",        evidence.itemKey,        overwrite)
    SetUsefulNumber(row, "itemQuality",    evidence.itemQuality,    overwrite)
    SetUsefulNumber(row, "craftingQuality",evidence.craftingQuality,overwrite)
    SetUsefulNumber(row, "rarityQuality",  evidence.rarityQuality,  overwrite)
    SetUsefulNumber(row, "ilvl",           evidence.ilvl,           overwrite)
    SetUsefulNumber(row, "itemClassID",    evidence.itemClassID,    overwrite)
    SetUsefulNumber(row, "itemSubClassID", evidence.itemSubClassID, overwrite)
    SetUsefulField (row, "equipLoc",       evidence.equipLoc,       overwrite)
    SetUsefulField (row, "statFingerprint",evidence.statFingerprint,overwrite)
    SetUsefulField (row, "itemStats",      evidence.itemStats,      overwrite)
    SetUsefulField (row, "isStackable",    evidence.isStackable,    overwrite)
    SetUsefulField (row, "timeLeft",  evidence.timeLeft  or evidence.durationLeft or evidence.duration, overwrite)
    SetUsefulField (row, "durationLeft", evidence.durationLeft or evidence.timeLeft or evidence.duration, overwrite)

    local unitPrice   = tonumber(evidence.unitPrice or evidence.pricePerUnit or evidence.price)
    local buyout      = tonumber(evidence.buyout or evidence.buyoutAmount or evidence.buyoutPrice or evidence.totalPrice)
    local postedPrice = tonumber(evidence.postedPrice or unitPrice or buyout)
    SetUsefulNumber(row, "postedPrice", postedPrice,                         overwrite)
    SetUsefulNumber(row, "unitPrice",   unitPrice or postedPrice or buyout,   overwrite)
    SetUsefulNumber(row, "buyout",      buyout or postedPrice or unitPrice,   overwrite)
    SetUsefulNumber(row, "price",       evidence.price or postedPrice or unitPrice or buyout, overwrite)
    SetUsefulNumber(row, "bid",         evidence.bid or evidence.bidAmount or evidence.bidPrice, overwrite)

    -- durationHours is PocketCFO post intent only; never inferred from Blizzard time-left fields.
    SetUsefulNumber(row, "durationHours", evidence.durationHours, overwrite)
    SetUsefulNumber(row, "postedAt",      evidence.postedAt,      overwrite)
    SetUsefulNumber(row, "listedAt",      evidence.listedAt,      overwrite)

    if row.status ~= "canceled" then
        row.closedAt    = nil
        row.closeReason = nil
    end
    row.updatedAt = now

    previousConfigKey = ApplyIdentity(row, evidence, ownedHydration and "ownedAuctionRow" or "auctionRow") or previousConfigKey
    row.configKeyResolved = row.configKey ~= nil

    if source == "owned_scan_backfill" and row.auctionCreatedSeen == true then
        row.lastEvidenceSource = row.lastEvidenceSource or "auction_created"
    elseif source == "post_confirmed" and row.auctionCreatedSeen == true then
        row.lastEvidenceSource = row.lastEvidenceSource or "auction_created"
    else
        row.lastEvidenceSource = source
    end

    return row, previousConfigKey, isNew
end

local function StoreMergedListing(auctionID, row, previousConfigKey)
    local key = AuctionKey(auctionID)
    if not key or not row then
        return nil
    end
    local byAuctionID = ByAuctionIDTable()
    byAuctionID[key] = row
    if previousConfigKey and previousConfigKey ~= row.configKey then
        UnindexByConfigKey(previousConfigKey, auctionID)
    end
    IndexByConfigKey(row.configKey, auctionID)
    if ActiveListingIsComplete(row) then
        ClearPendingCreate(auctionID)
    end
    return row
end

function ClearPendingCreate(auctionID)
    local key = AuctionKey(auctionID)
    if key then
        PendingCreatesTable()[key] = nil
    end
end

local function StorePendingCreate(auctionID, evidence, attempts, reason)
    local key = AuctionKey(auctionID)
    if not key then
        return nil
    end
    local pending = PendingCreatesTable()
    local row = pending[key] or {
        auctionID = auctionID,
        createdAt = Now(),
    }
    row.updatedAt = Now()
    row.attempts  = attempts or row.attempts or 0
    row.reason    = reason   or row.reason   or "ownedAuctionHydrationPending"
    row.evidence  = evidence
    pending[key]  = row
    return row
end

-- ─── Expiry estimation helpers ───────────────────────────────────────────────

-- Returns true only when the row carries enough fields to compute a latest-possible expiry.
local function ListingHasTimingData(row)
    if tonumber(row.postedAt) and tonumber(row.durationHours) then
        return true
    end
    local tl = row.timeLeft
    if tonumber(row.lastConfirmedAt) and (TIME_LEFT_MAX_SECONDS[tl] or TIME_LEFT_MAX_SECONDS[tonumber(tl)]) then
        return true
    end
    return false
end

-- Returns estimatedExpiresAt (epoch seconds), why ("posted timing" | "Blizzard bucket" | "insufficient data").
-- Uses the most conservative (latest) bound so false-negatives are avoided.
local function EstimateLatestExpiry(row, now)
    local postedAt      = tonumber(row.postedAt)
    local durationHours = tonumber(row.durationHours)
    if postedAt and durationHours then
        return postedAt + durationHours * 3600, "posted timing"
    end

    local lastConfirmedAt = tonumber(row.lastConfirmedAt)
    local tl              = row.timeLeft
    if lastConfirmedAt and tl ~= nil then
        local maxSeconds = TIME_LEFT_MAX_SECONDS[tl] or TIME_LEFT_MAX_SECONDS[tonumber(tl)]
        if maxSeconds then
            return lastConfirmedAt + maxSeconds, "Blizzard bucket"
        end
    end

    return nil, "insufficient data"
end

-- Returns couldStillBeActive (bool), estimatedExpiresAt (epoch or nil), why (string).
-- Conservative: missing timing data → true.
local function CouldStillBeActive(row, now)
    if VALID_CLOSE_STATUSES[tostring(row.status or "")] then
        return false, nil, "durable lifecycle state"
    end
    if not ListingHasTimingData(row) then
        return true, nil, "insufficient data"
    end
    local estimatedExpiresAt, why = EstimateLatestExpiry(row, now)
    if not estimatedExpiresAt then
        return true, nil, "insufficient data"
    end
    if estimatedExpiresAt >= now then
        return true, estimatedExpiresAt, why
    end
    return false, estimatedExpiresAt, why
end

-- Public API

function AuctionListingStateService:GetListing(auctionID)
    local key = AuctionKey(auctionID)
    if not key then return nil end
    return ByAuctionIDTable()[key]
end

function AuctionListingStateService:UpsertListingEvidence(evidence, source)
    evidence = evidence or {}
    local auctionID = evidence.auctionID
    local key = AuctionKey(auctionID)
    if not key then
        SessionLog("AuctionListingStateService:UpsertListingEvidence skipped reason=no-auctionID")
        return nil
    end
    evidence.source = NormalizeEvidenceSource(source or evidence.source) or "owned_scan"
    local row, previousConfigKey = MergeAHListing(ByAuctionIDTable()[key], evidence, evidence.source, Now())
    return StoreMergedListing(auctionID, row, previousConfigKey)
end

function AuctionListingStateService:RecordPostedAuction(evidence)
    evidence = evidence or {}
    local auctionID = evidence.auctionID
    local key = AuctionKey(auctionID)
    if not key then
        SessionLog("AuctionListingStateService:RecordPostedAuction skipped reason=no-auctionID")
        return nil
    end
    evidence.auctionID = auctionID
    evidence.source    = "post_confirmed"
    local row, previousConfigKey = MergeAHListing(ByAuctionIDTable()[key], evidence, "post_confirmed", Now())
    StoreMergedListing(auctionID, row, previousConfigKey)
    SessionLog("AuctionListingStateService: recorded post auctionID=%s configKey=%s item=%s qty=%d price=%s durationHours=%s",
        tostring(auctionID), tostring(row.configKey), tostring(row.itemName),
        tonumber(row.quantity) or 0, tostring(row.postedPrice), tostring(row.durationHours))
    return row
end

-- Records auction_created evidence. Does not trigger C_AuctionHouse hydration.
-- AHListingService in PocketCFO_AH wraps this to add hydration after calling here.
function AuctionListingStateService:RecordAuctionCreated(evidence)
    evidence = evidence or {}
    local auctionID = evidence.auctionID
    local key = AuctionKey(auctionID)
    if not key then
        SessionLog("AuctionListingStateService:RecordAuctionCreated skipped reason=no-auctionID")
        return nil
    end
    evidence.source    = "auction_created"
    evidence.auctionID = auctionID
    local row, previousConfigKey = MergeAHListing(ByAuctionIDTable()[key], evidence, "auction_created", Now())
    StoreMergedListing(auctionID, row, previousConfigKey)
    return row
end

function AuctionListingStateService:ConfirmOwnedAuction(evidence, source)
    evidence = evidence or {}
    local auctionID = evidence.auctionID
    local key = AuctionKey(auctionID)
    if not key then return nil end

    local now = Now()
    source = NormalizeEvidenceSource(source or evidence.source) or "owned_scan"
    evidence.auctionID = auctionID
    evidence.source    = source

    local row, previousConfigKey, isNew = MergeAHListing(ByAuctionIDTable()[key], evidence, source, now)
    StoreMergedListing(auctionID, row, previousConfigKey)

    if not ActiveListingIsComplete(row) then
        StorePendingCreate(auctionID, evidence, nil, "ownedAuctionEvidenceIncomplete")
        SessionLog("AuctionListingStateService: owned evidence pending auctionID=%s source=%s",
            tostring(auctionID), tostring(source))
    elseif isNew then
        SessionLog("AuctionListingStateService: scan-discovered auctionID=%s configKey=%s item=%s",
            tostring(auctionID), tostring(row.configKey), tostring(row.itemName))
    end
    return row
end

function AuctionListingStateService:CloseAuction(auctionID, status, evidence)
    if status == "cancelled" then
        status = "canceled"
    end
    if not VALID_CLOSE_STATUSES[status] then
        SessionLog("AuctionListingStateService:CloseAuction rejected invalid status=%s auctionID=%s",
            tostring(status), tostring(auctionID))
        return nil
    end

    local key = AuctionKey(auctionID)
    if not key then return nil end

    local byAuctionID = ByAuctionIDTable()
    local row = byAuctionID[key]
    if not row then
        SessionLog("AuctionListingStateService:CloseAuction row not found auctionID=%s status=%s",
            tostring(auctionID), tostring(status))
        return nil
    end

    evidence = evidence or {}
    local now = Now()
    row.status             = status
    row.closedAt           = now
    row.updatedAt          = now
    row.closeReason        = evidence.reason   or row.closeReason
    row.closeOutcome       = evidence.outcome  or evidence.reason or status
    row.closeEvidenceKey   = evidence.evidenceKey or row.closeEvidenceKey
    row.closeMailIndex     = evidence.mailIndex   or row.closeMailIndex
    row.closedQuantity     = tonumber(evidence.quantity) or row.closedQuantity
    row.lastEvidenceSource = evidence.source or ("close_" .. status)
    byAuctionID[key]       = row
    UnindexByConfigKey(row.configKey, auctionID)

    SessionLog("AuctionListingStateService: closed auctionID=%s status=%s configKey=%s",
        tostring(auctionID), tostring(status), tostring(row.configKey))
    return row
end

function AuctionListingStateService:MarkCancelled(auctionID, evidence)
    return self:CloseAuction(auctionID, "canceled", evidence)
end

function AuctionListingStateService:RecordAuctionEnded(auctionID, outcome, evidence)
    evidence = evidence or {}
    outcome  = tostring(outcome or evidence.outcome or "closed")
    evidence.outcome = outcome
    evidence.reason  = evidence.reason or outcome

    local status = outcome
    if outcome == "cancelled" then
        status = "canceled"
    elseif outcome == "unresolved" then
        status = "closed"
    end
    return self:CloseAuction(auctionID, status, evidence)
end

function AuctionListingStateService:IsOwnedAuctionID(auctionID)
    local key = AuctionKey(auctionID)
    if not key then return false end
    local row = ByAuctionIDTable()[key]
    if not row then return false end
    return row.status == "active"
end

function AuctionListingStateService:GetActiveOwnedByConfigKey(configKey)
    if not configKey then return {} end

    local byConfigKey  = ByConfigKeyTable()
    local auctionIDSet = byConfigKey[configKey]
    if not auctionIDSet then return {} end

    local byAuctionID = ByAuctionIDTable()
    local active   = {}
    local toRemove = {}

    for auctionIDStr in pairs(auctionIDSet) do
        local row = byAuctionID[auctionIDStr]
        if not row then
            toRemove[#toRemove + 1] = auctionIDStr
        elseif row.status ~= "active" then
            toRemove[#toRemove + 1] = auctionIDStr
        else
            active[#active + 1] = row
        end
    end
    for _, auctionIDStr in ipairs(toRemove) do
        auctionIDSet[auctionIDStr] = nil
    end
    return active
end

function AuctionListingStateService:GetActiveOwnedListings(options)
    options = options or {}
    local ownerKey    = options.ownerKey
    local active      = {}
    local byAuctionID = ByAuctionIDTable()

    for key, row in pairs(byAuctionID or {}) do
        if type(row) == "table" and row.status == "active" then
            if not ownerKey or tostring(row.ownerKey or "") == tostring(ownerKey) then
                row.auctionID = row.auctionID or key
                active[#active + 1] = row
            end
        end
    end

    table.sort(active, function(a, b)
        return tostring(a.auctionID or "") < tostring(b.auctionID or "")
    end)
    return active
end

function AuctionListingStateService:BackfillMissingOwnedAuctions(ownedAuctionRows)
    local backfilled = 0
    local skipped    = 0
    local filled     = 0

    for _, row in ipairs(ownedAuctionRows or {}) do
        local auctionID = row and row.auctionID
        local key = AuctionKey(auctionID)
        if key then
            local existingRow = ByAuctionIDTable()[key]
            row.auctionID = auctionID
            row.source    = "owned_scan_backfill"
            if existingRow then
                local merged, previousConfigKey = MergeAHListing(existingRow, row, "owned_scan_backfill", Now())
                StoreMergedListing(auctionID, merged, previousConfigKey)
                filled = filled + 1
            else
                local merged, previousConfigKey = MergeAHListing(nil, row, "owned_scan_backfill", Now())
                if not ActiveListingIsComplete(merged) then
                    StorePendingCreate(auctionID, row, nil, "ownedScanBackfillIncomplete")
                    skipped = skipped + 1
                else
                    StoreMergedListing(auctionID, merged, previousConfigKey)
                    backfilled = backfilled + 1
                end
            end
        end
    end

    SessionLog("AuctionListingStateService: backfill complete backfilled=%d filled=%d skipped=%d total=%d",
        backfilled, filled, skipped, #(ownedAuctionRows or {}))
    return backfilled, skipped
end

function AuctionListingStateService:ReconcileActiveOwnedAuctions(ownedAuctionRows, options)
    options = options or {}
    -- Blizzard's owned-auction scan only returns auctions for the currently logged-in
    -- character. Restrict closure to that character's listings so a scan by Character B
    -- cannot falsely close Character A's active listings.
    local filterOwnerKey = options.ownerKey
    local observed      = {}
    local observedCount = 0
    for _, row in ipairs(ownedAuctionRows or {}) do
        local key = AuctionKey(row and row.auctionID)
        if key and not observed[key] then
            observed[key] = true
            observedCount = observedCount + 1
        end
    end

    local closed      = 0
    local kept        = 0
    local byAuctionID = ByAuctionIDTable()
    for key, listing in pairs(byAuctionID) do
        if type(listing) == "table" and listing.status == "active" then
            if filterOwnerKey and tostring(listing.ownerKey or "") ~= tostring(filterOwnerKey) then
                -- Different character: not visible in this scan, leave untouched.
                kept = kept + 1
            else
                local auctionID  = listing.auctionID or key
                local auctionKey = AuctionKey(auctionID)
                if auctionKey and observed[auctionKey] then
                    kept = kept + 1
                else
                    self:CloseAuction(auctionID, "closed", {
                        source = options.source or "owned_scan_reconcile",
                        reason = options.reason or "notObservedInReliableOwnedScan",
                    })
                    closed = closed + 1
                end
            end
        end
    end

    SessionLog("AuctionListingStateService: owned scan reconcile complete observed=%d keptActive=%d closed=%d",
        observedCount, kept, closed)
    self:PruneInactiveListings({ source = "owned_scan_reconcile" })
    return closed, kept, observedCount
end

local function InactiveAgeTimestamp(row)
    return tonumber(row and (row.closedAt or row.updatedAt or row.lastObservedAt or row.createdAt or row.postedAt)) or 0
end

function AuctionListingStateService:PruneInactiveListings(options)
    options = options or {}
    local db              = EnsureStorageShape()
    local now             = Now()
    local retentionDays   = INACTIVE_RETENTION_DAYS
    local maxInactiveRows = MAX_INACTIVE_ROWS
    local cutoff          = now - (retentionDays * 86400)

    local inactive       = {}
    local totalRowsBefore = 0
    local prunedByAge    = 0
    local prunedByCap    = 0

    for key, row in pairs(db.ahListings or {}) do
        totalRowsBefore = totalRowsBefore + 1
        if type(row) == "table" and row.status == "active" then
            -- Active listings are always retained regardless of age.
            -- They represent auctions we believe are currently on the AH.
        else
            -- All inactive listings (canceled, closed, expired, returned, sold) are subject
            -- to pruning. This includes unresolved listings whose mailboxResolution is still
            -- "unresolved": WoW mail expires after 30 days, so any evidence that would have
            -- resolved them is also gone by the time these rows age out.
            local ageAt = InactiveAgeTimestamp(row)
            if ageAt > 0 and ageAt < cutoff then
                db.ahListings[key] = nil
                prunedByAge = prunedByAge + 1
            else
                inactive[#inactive + 1] = { key = key, ageAt = ageAt }
            end
        end
    end

    if #inactive > maxInactiveRows then
        table.sort(inactive, function(a, b)
            if a.ageAt == b.ageAt then
                return tostring(a.key) < tostring(b.key)
            end
            return a.ageAt < b.ageAt
        end)
        local excess = #inactive - maxInactiveRows
        for index = 1, excess do
            local entry = inactive[index]
            if entry and entry.key and db.ahListings[entry.key] then
                db.ahListings[entry.key] = nil
                prunedByCap = prunedByCap + 1
            end
        end
    end

    RebuildIndexes()

    local activeRowsAfter   = 0
    local inactiveRowsAfter = 0
    local totalRowsAfter    = 0
    for _, row in pairs(db.ahListings or {}) do
        totalRowsAfter = totalRowsAfter + 1
        if type(row) == "table" and row.status == "active" then
            activeRowsAfter   = activeRowsAfter + 1
        else
            inactiveRowsAfter = inactiveRowsAfter + 1
        end
    end

    db.ahListingPruneStats = {
        ranAt           = now,
        source          = options.source or "manual",
        retentionDays   = retentionDays,
        maxInactiveRows = maxInactiveRows,
        prunedByAge     = prunedByAge,
        prunedByCap     = prunedByCap,
        totalRowsBefore = totalRowsBefore,
        totalRowsAfter  = totalRowsAfter,
        activeRows      = activeRowsAfter,
        inactiveRows    = inactiveRowsAfter,
    }

    SessionLog("AuctionListingStateService: prune complete source=%s active=%d inactive=%d prunedByAge=%d prunedByCap=%d retentionDays=%d maxInactiveRows=%d",
        tostring(db.ahListingPruneStats.source), activeRowsAfter, inactiveRowsAfter,
        prunedByAge, prunedByCap, retentionDays, maxInactiveRows)
    return db.ahListingPruneStats
end

function AuctionListingStateService:GetUnresolvedListings(options)
    options = options or {}
    local ownerKey    = options.ownerKey
    local unresolved  = {}
    local byAuctionID = ByAuctionIDTable()

    for key, row in pairs(byAuctionID or {}) do
        if type(row) == "table" and (row.mailboxResolution or "unresolved") == "unresolved" then
            if not ownerKey or tostring(row.ownerKey or "") == tostring(ownerKey) then
                row.auctionID = row.auctionID or key
                unresolved[#unresolved + 1] = row
            end
        end
    end

    table.sort(unresolved, function(a, b)
        return tostring(a.auctionID or "") < tostring(b.auctionID or "")
    end)
    return unresolved
end

function AuctionListingStateService:MarkMailboxResolved(auctionID, resolution, evidence)
    if not VALID_MAILBOX_RESOLUTIONS[resolution] then
        SessionLog("AuctionListingStateService:MarkMailboxResolved rejected invalid resolution=%s auctionID=%s",
            tostring(resolution), tostring(auctionID))
        return nil, "invalidResolution"
    end

    local key = AuctionKey(auctionID)
    if not key then return nil, "invalidAuctionID" end

    local byAuctionID = ByAuctionIDTable()
    local row = byAuctionID[key]
    if not row then
        SessionLog("AuctionListingStateService:MarkMailboxResolved row not found auctionID=%s resolution=%s",
            tostring(auctionID), tostring(resolution))
        return nil, "notFound"
    end

    local current = row.mailboxResolution or "unresolved"

    if current == resolution then
        return row, "alreadyResolved"
    end

    if current ~= "unresolved" then
        SessionLog("AuctionListingStateService:MarkMailboxResolved conflict auctionID=%s existing=%s new=%s",
            tostring(auctionID), tostring(current), tostring(resolution))
        return row, "conflict"
    end

    evidence = evidence or {}
    local now = Now()
    row.mailboxResolution       = resolution
    row.mailboxResolvedAt       = now
    row.mailboxResolutionSource = "mailbox_reconciler"
    row.mailboxEvidenceType     = evidence.evidenceType or evidence.type
    row.mailboxEvidenceKey      = evidence.evidenceKey
    row.mailboxMailIndex        = evidence.mailIndex
    row.updatedAt               = now
    byAuctionID[key]            = row

    SessionLog("AuctionListingStateService: mailbox resolved auctionID=%s resolution=%s configKey=%s",
        tostring(auctionID), tostring(resolution), tostring(row.configKey))
    return row, nil
end

function AuctionListingStateService:GetRetentionPolicy()
    return {
        retentionDays   = INACTIVE_RETENTION_DAYS,
        maxInactiveRows = MAX_INACTIVE_ROWS,
    }
end

function AuctionListingStateService:GetLastPruneStats()
    local db = EnsureStorageShape()
    return db.ahListingPruneStats or {
        retentionDays   = INACTIVE_RETENTION_DAYS,
        maxInactiveRows = MAX_INACTIVE_ROWS,
        prunedByAge     = 0,
        prunedByCap     = 0,
    }
end

-- Returns true if any listing for ownerKey could still plausibly be active on the AH.
-- Returns false only when every listing can be proven expired/inactive.
-- Conservative: missing timing data or nil ownerKey → true.
function AuctionListingStateService:CanAnyListingStillBeActive(ownerKey)
    if not ownerKey then
        SessionLog("AuctionListingStateService:CanAnyListingStillBeActive called without ownerKey, returning true (conservative)")
        return true
    end
    local now         = Now()
    local byAuctionID = ByAuctionIDTable()
    for _, row in pairs(byAuctionID) do
        if type(row) == "table" and tostring(row.ownerKey or "") == tostring(ownerKey) then
            if not VALID_CLOSE_STATUSES[tostring(row.status or "")] then
                local couldBeActive = CouldStillBeActive(row, now)
                if couldBeActive then
                    return true
                end
            end
        end
    end
    return false
end

-- Returns expiry estimate for a single listing row. Used by diagnostics.
-- Fields: couldStillBeActive (bool), estimatedExpiresAt (epoch or nil), why (string).
function AuctionListingStateService:EstimateListingActivity(row)
    if not row then
        return { couldStillBeActive = true, estimatedExpiresAt = nil, why = "insufficient data" }
    end
    local now = Now()
    local couldBeActive, estimatedExpiresAt, why = CouldStillBeActive(row, now)
    return {
        couldStillBeActive = couldBeActive,
        estimatedExpiresAt = estimatedExpiresAt,
        why                = why,
    }
end

function AuctionListingStateService:ClearForDiagnostics()
    local db = EnsureStorageShape()
    db.ahListings              = {}
    db.ahListingsByConfigKey   = {}
    db.ahListingsByAuctionID   = nil
    db.ahListingsByOwner       = nil
    db.ahListingsByStatus      = nil
    db.ahListingPendingCreates = nil
    db.ahListingPendingBackfills = nil
    db.ahListingPruneStats     = nil
    EnsureStorageShape()
    SessionLog("AuctionListingStateService: cleared for diagnostics")
    return true
end

function AuctionListingStateService:OnInitialize()
    EnsureStorageShape()

    -- One-time migration: copy ahListings from PocketCFO_AH_DB into Core DB if Core is empty.
    -- PocketCFO_AH_DB is accessible as a raw SavedVariable even when PocketCFO_AH is not loaded.
    -- Migration is idempotent: only runs when Core table is empty. Old AH data is left in place.
    local ahDB = _G.PocketCFO_AH_DB
    if ahDB and type(ahDB.global) == "table" and type(ahDB.global.ahListings) == "table" then
        local coreDB = PocketCFO.db.global
        if not next(coreDB.ahListings) then
            SessionLog("AuctionListingStateService: migrating ahListings from PocketCFO_AH_DB")
            for k, v in pairs(ahDB.global.ahListings) do
                coreDB.ahListings[k] = v
            end
            for k, v in pairs(ahDB.global.ahListingsByConfigKey or {}) do
                coreDB.ahListingsByConfigKey[k] = v
            end
            for k, v in pairs(ahDB.global.ahListingPendingCreates or {}) do
                coreDB.ahListingPendingCreates[k] = v
            end
            RebuildIndexes()
            local count = 0
            for _ in pairs(coreDB.ahListings) do
                count = count + 1
            end
            SessionLog("AuctionListingStateService: migration complete rows=%d", count)
        end
    end

    -- Normalize mailboxResolution on all records (field added in v0.2).
    -- Runs after migration so imported rows are also normalized.
    for _, row in pairs(ByAuctionIDTable()) do
        if type(row) == "table" and row.mailboxResolution == nil then
            row.mailboxResolution = "unresolved"
        end
    end

    self:PruneInactiveListings({ source = "initialize" })
    SessionLog("AuctionListingStateService OnInitialize")
end

function AuctionListingStateService:OnEnable()
end
