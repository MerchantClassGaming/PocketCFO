-- PocketCFO_Valuation/Modules/PricingCache.lua
-- Timestamped market-key price cache. No auction house scans happen here.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local PricingCache = PocketCFO_Valuation:NewModule("PricingCache")

local FRESH_SECONDS = 3 * 24 * 60 * 60

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

-- Prices are kept per connected realm group: realms that share one Auction
-- House share one cache (Brian, 2026-10-24). Key = the connected realm names,
-- sorted and joined ("Aggramar|Fizzcrank"). Confirmed in-game 2026-10-24:
-- GetAutoCompleteRealms() on Aggramar returns { "Aggramar", "Fizzcrank" }.
-- A realm with no connections falls back to GetNormalizedRealmName().
-- Only worked out after login, and kept once known.
local realmGroupKey

local function GetRealmGroupKey()
    if realmGroupKey then
        return realmGroupKey
    end
    if IsLoggedIn and not IsLoggedIn() then
        return nil
    end

    local names = {}
    if GetAutoCompleteRealms then
        local ok, realms = pcall(GetAutoCompleteRealms)
        if ok and type(realms) == "table" then
            for _, name in ipairs(realms) do
                if type(name) == "string" and name ~= "" then
                    names[#names + 1] = name
                end
            end
        end
    end
    if #names == 0 then
        local name = GetNormalizedRealmName and GetNormalizedRealmName()
        if type(name) ~= "string" or name == "" then
            return nil
        end
        names[1] = name
    end

    table.sort(names)
    realmGroupKey = table.concat(names, "|")
    return realmGroupKey
end

-- ---------------------------------------------------------------------------
-- Saved price size (Brian, 2026-11-07, memory). WoW loads the whole saved
-- file at login, so every realm group's prices sat in memory whether you
-- were on it or not (~243 MB with three groups; Burning Blade group alone
-- ~65 MB). Once per session, when the current realm group is known:
--   - Another realm group with no full scan in OTHER_GROUP_DAYS days: its
--     prices and scan history are dropped (all stale by then; one scan on
--     that realm rebuilds them). The current group is never dropped.
--   - Current group: rows not seen in ROW_MAX_DAYS days are dropped (items
--     nobody lists any more), at most once a day.
--   - Every row loses the saved scan diagnostics (rejected price levels,
--     only read by /mcgd value) and the "freshness" field (never read:
--     freshness is worked out from the timestamp). New rows are written
--     without them (SetPricingRow). Item searches keep their diagnostics
--     for this session only (GetSessionDiagnostics), so /mcgd value still
--     shows them for an item you just looked up.
-- Flavor: Both.
-- ---------------------------------------------------------------------------

local OTHER_GROUP_DAYS = 10
local ROW_MAX_DAYS = 30
local SECONDS_PER_DAY = 24 * 60 * 60
local maintained = false

-- marketKey -> diagnostics from an item search this session (never saved).
local SESSION_DIAGNOSTICS_MAX = 300
local sessionDiagnostics, sessionDiagnosticsCount = {}, 0

local function SlimRow(row)
    row.valuationDiagnostics = nil
    row.freshness = nil
end

local function MaintainSavedPrices(db, currentKey, store)
    if maintained then
        return
    end
    maintained = true
    local now = Now()

    local droppedGroups = 0
    for key, other in pairs(db.global.realmGroups) do
        if key ~= currentKey then
            local lastScan = type(other) == "table" and tonumber(other.timeOfLastReplicateScan) or nil
            if not lastScan or now - lastScan > OTHER_GROUP_DAYS * SECONDS_PER_DAY then
                db.global.realmGroups[key] = nil
                if type(db.global.scanHistory) == "table" then
                    db.global.scanHistory[key] = nil
                end
                droppedGroups = droppedGroups + 1
            end
        end
    end

    local cache = store.pricingCache
    local today = math.floor(now / SECONDS_PER_DAY)
    local droppedRows = 0
    if type(cache) == "table" and store.lastRowPruneDay ~= today then
        store.lastRowPruneDay = today
        local cutoff = now - ROW_MAX_DAYS * SECONDS_PER_DAY
        for marketKey, row in pairs(cache) do
            if type(row) ~= "table" or (tonumber(row.timestamp) or 0) < cutoff then
                cache[marketKey] = nil
                droppedRows = droppedRows + 1
            else
                SlimRow(row)
            end
        end
    end

    local core = _G.PocketCFO
    if core and core.AppendSessionLog then
        core:AppendSessionLog(string.format(
            "[MCG] PricingCache: saved prices trimmed - other realm groups dropped=%d, rows older than %dd dropped=%d",
            droppedGroups, ROW_MAX_DAYS, droppedRows))
    end
end

-- This realm group's saved data:
--   { pricingCache = {}, timeOfLastReplicateScan = n, timeOfLastReplicateRequest = n }
local function GetGroupStore()
    local db = PocketCFO_Valuation.db
    if not db or not db.global then
        return nil
    end
    local key = GetRealmGroupKey()
    if not key then
        return nil
    end

    db.global.realmGroups = db.global.realmGroups or {}
    local store = db.global.realmGroups[key]
    if not store then
        store = {}
        -- One-time move (2026-10-24): the old account-wide cache (no realm
        -- recorded) goes to whichever realm group is logged into first, so
        -- players keep their prices without a rescan. Remove once testers
        -- have updated.
        if type(db.global.pricingCache) == "table" then
            store.pricingCache = db.global.pricingCache
            store.timeOfLastReplicateScan = db.global.timeOfLastReplicateScan
            db.global.pricingCache = nil
            db.global.timeOfLastReplicateScan = nil
        end
        db.global.realmGroups[key] = store
    end
    store.pricingCache = store.pricingCache or {}
    MaintainSavedPrices(db, key, store)
    return store
end

local function GetCacheRoot()
    local store = GetGroupStore()
    return store and store.pricingCache or nil
end

-- Item ID index (Brian, 2026-11-07, hover performance): itemID -> set of
-- market keys in this realm group's cache. In memory only, never saved.
-- Built in one walk the first time it's asked for, then kept current by
-- SetValue / SetPricingRow, so GetCandidatesForItemID is a lookup instead
-- of a walk over every cached market (~27,500 rows) on each call. Rebuilt
-- if the cache table itself is replaced (e.g. a wipe).
local itemIndex, itemIndexFor

local function KeyItemID(marketKey)
    return tonumber(tostring(marketKey):match("^(%d+)|"))
end

local function GetItemIndex(cache)
    if itemIndex and itemIndexFor == cache then
        return itemIndex
    end
    local index = {}
    for marketKey in pairs(cache) do
        local itemID = KeyItemID(marketKey)
        if itemID then
            local keys = index[itemID]
            if not keys then
                keys = {}
                index[itemID] = keys
            end
            keys[marketKey] = true
        end
    end
    itemIndex, itemIndexFor = index, cache
    return index
end

-- Keeps a built index current after a write. Does nothing before the
-- index is first built (the first build picks the row up).
local function IndexKey(cache, marketKey)
    if not itemIndex or itemIndexFor ~= cache then
        return
    end
    local itemID = KeyItemID(marketKey)
    if not itemID then
        return
    end
    local keys = itemIndex[itemID]
    if not keys then
        keys = {}
        itemIndex[itemID] = keys
    end
    keys[marketKey] = true
end

local function NormalizeValue(row)
    if type(row) ~= "table" then
        return nil
    end
    return tonumber(row.value) or tonumber(row.copperValue) or tonumber(row.unitPrice) or tonumber(row.buyout)
end

function PricingCache:OnInitialize()
    GetCacheRoot()
end

function PricingCache:GetCache()
    return GetCacheRoot()
end

function PricingCache:GetRealmGroupKey()
    return GetRealmGroupKey()
end

-- When this realm group last finished a full scan (server time), or nil.
function PricingCache:GetLastScanTime()
    local store = GetGroupStore()
    return store and tonumber(store.timeOfLastReplicateScan) or nil
end

function PricingCache:SetLastScanTime(timestamp)
    local store = GetGroupStore()
    if store then
        store.timeOfLastReplicateScan = tonumber(timestamp)
    end
end

-- When this realm group last sent a full scan request (server time), or
-- nil. Drives the 15-minute cooldown: Blizzard's own cooldown counts from
-- the request, finished or not.
function PricingCache:GetLastRequestTime()
    local store = GetGroupStore()
    return store and tonumber(store.timeOfLastReplicateRequest) or nil
end

function PricingCache:SetLastRequestTime(timestamp)
    local store = GetGroupStore()
    if store then
        store.timeOfLastReplicateRequest = tonumber(timestamp)
    end
end

-- Broadcast so any addon/module holding a stale "no price" result (e.g.
-- Prospecting Analysis, evaluated before this market key ever had a price)
-- can react and recompute instead of waiting for an unrelated trigger to
-- happen to re-run. Fired on every successful cache write rather than
-- batched here - bursts (a FullScan chunk, a SearchRefresh batch) are cheap
-- to broadcast; consumers are expected to debounce their own reaction.
local function BroadcastPricingUpdated(marketKey, itemID, source)
    PocketCFO_Valuation:SendMessage("PCFO_PRICING_UPDATED", marketKey, itemID, source)
end

function PricingCache:SetValue(marketKey, value, timestamp, source)
    if not marketKey or tostring(marketKey) == "" then
        return nil
    end
    value = tonumber(value)
    if not value then
        return nil
    end

    local cache = GetCacheRoot()
    if not cache then
        return nil
    end

    marketKey = tostring(marketKey)
    cache[marketKey] = {
        marketKey = marketKey,
        value = value,
        timestamp = tonumber(timestamp) or Now(),
        source = source or "manual",
    }
    IndexKey(cache, marketKey)

    BroadcastPricingUpdated(marketKey, nil, cache[marketKey].source)
    return cache[marketKey]
end

function PricingCache:SetPricingRow(marketKey, row)
    if not marketKey or tostring(marketKey) == "" or type(row) ~= "table" then
        return nil
    end

    local value = tonumber(row.value)
    if not value then
        return nil
    end

    local cache = GetCacheRoot()
    if not cache then
        return nil
    end

    marketKey = tostring(marketKey)
    cache[marketKey] = {
        marketKey = marketKey,
        itemID = tonumber(row.itemID) or row.itemID,
        itemName = row.itemName,
        qualityTier = tonumber(row.qualityTier) or row.qualityTier,
        itemLevel = tonumber(row.itemLevel) or row.itemLevel,
        statFingerprint = row.statFingerprint,
        depthUsed = tonumber(row.depthUsed) or row.depthUsed,
        -- How much evidence the price came from (2026-11-04, value
        -- confidence): listings and units seen for this market. nil on
        -- prices saved before this existed.
        listingCount = tonumber(row.listingCount),
        unitCount = tonumber(row.unitCount),
        -- No saved valuationDiagnostics or freshness (2026-11-07, see
        -- "Saved price size" above).
        value = value,
        timestamp = tonumber(row.timestamp) or Now(),
        source = row.source or "pricing",
    }
    IndexKey(cache, marketKey)
    -- Item search diagnostics are kept for this session only.
    if row.valuationDiagnostics ~= nil and row.source == "search-refresh" then
        if sessionDiagnosticsCount >= SESSION_DIAGNOSTICS_MAX then
            sessionDiagnostics, sessionDiagnosticsCount = {}, 0
        end
        if sessionDiagnostics[marketKey] == nil then
            sessionDiagnosticsCount = sessionDiagnosticsCount + 1
        end
        sessionDiagnostics[marketKey] = row.valuationDiagnostics
    end

    BroadcastPricingUpdated(marketKey, cache[marketKey].itemID, cache[marketKey].source)

    return cache[marketKey]
end

-- Scan diagnostics (rejected price levels) for a market priced by an item
-- search this session, or nil. Read by ValuationService:ExplainValue.
function PricingCache:GetSessionDiagnostics(marketKey)
    return marketKey and sessionDiagnostics[tostring(marketKey)] or nil
end

function PricingCache:GetEntry(marketKey)
    if not marketKey or tostring(marketKey) == "" then
        return nil
    end

    local cache = GetCacheRoot()
    if not cache then
        return nil
    end

    return cache[tostring(marketKey)]
end

function PricingCache:GetCandidatesForItemID(itemID)
    itemID = tonumber(itemID)
    local cache = GetCacheRoot()
    if not itemID or not cache then
        return {}
    end

    local keys = GetItemIndex(cache)[itemID]
    local rows = {}
    if not keys then
        return rows
    end
    for marketKey in pairs(keys) do
        local row = cache[marketKey]
        if row ~= nil then
            rows[#rows + 1] = row
        end
    end
    if #rows > 1 then
        table.sort(rows, function(a, b)
            return tostring(a and a.marketKey or "") < tostring(b and b.marketKey or "")
        end)
    end
    return rows
end

-- True when the cache has any market for this item ID (one lookup). The
-- tooltip uses it to skip items that can't have an AH price.
function PricingCache:HasItemID(itemID)
    itemID = tonumber(itemID)
    local cache = GetCacheRoot()
    if not itemID or not cache then
        return false
    end
    local keys = GetItemIndex(cache)[itemID]
    return keys ~= nil and next(keys) ~= nil
end

function PricingCache:GetValueByMarketKey(marketKey)
    local row = self:GetEntry(marketKey)
    local value = NormalizeValue(row)
    if value == nil then
        return nil, "unknown"
    end
    return value, self:IsStale(marketKey) and "stale" or "fresh", row
end

function PricingCache:GetValue(itemLinkOrMarketKey)
    local identity = PocketCFO_Valuation:GetModule("PricingIdentity", true)
    local marketKey = itemLinkOrMarketKey
    if identity and identity.BuildMarketKey then
        marketKey = identity:BuildMarketKey(itemLinkOrMarketKey)
    end
    return self:GetValueByMarketKey(marketKey)
end

function PricingCache:IsStale(marketKey)
    local row = self:GetEntry(marketKey)
    if not row or NormalizeValue(row) == nil then
        return nil
    end

    local timestamp = tonumber(row.timestamp)
    if not timestamp then
        return true
    end

    return (Now() - timestamp) > FRESH_SECONDS
end

PricingCache.FRESH_SECONDS = FRESH_SECONDS
