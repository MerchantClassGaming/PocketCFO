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

local function SessionLog(text)
    local core = _G.PocketCFO
    if core and core.AppendSessionLog then
        core:AppendSessionLog("[MCG] PricingCache: " .. text)
    end
end

local function IsForever()
    local core = _G.PocketCFO
    return core and core.flavor == "forever" or false
end

-- ---------------------------------------------------------------------------
-- Forever markets (Brian, 2026-11-24). Forever has one Alliance, one Horde
-- and one Neutral Auction House per ruleset (Normal, PvP, Roleplay,
-- Hardcore), and the game gives no realm name (GetRealmName,
-- GetNormalizedRealmName and GetAutoCompleteRealms all empty). Each market
-- gets its own prices. Key = "Forever-<ruleset>-<side>":
--   ruleset  C_GameRules.GetCurrentGameModeRecordID(). Confirmed in-game
--            2026-11-24: 14 on PvP (Alliance), 15 on Normal (Horde).
--   side     While an AH is open: the auctioneer's faction, none = Neutral.
--            Confirmed: Golothas (Darnassus) Alliance, Thathung (Orgrimmar)
--            Horde, O'reely (Booty Bay) none. Otherwise: your character's
--            faction.
-- Two keys (Brian, 2026-11-24, claude/Forever_Markets_Design.md):
--   read key  Your faction's market, always (even at a Neutral AH). Every
--             price lookup: PCFO Value, Smart Posting, Cancel, recipes,
--             Shopping List, ledger values.
--   scan key  The open AH's market (your faction's when no AH is open).
--             Scans and item searches save here, and scan status (last
--             scan, 15-minute cooldown, "No prices yet") reads from here.
-- The tooltip's "Neutral AH" line reads the Neutral market on its own
-- (GetNeutralEntry). A full scan stops if the AH closes (FullScan), so one
-- scan never writes into two markets.
-- Theoretical: the record ID stays the same across logins and patches;
-- Gadgetzan / Everlook auctioneers also have no faction.
-- Replaces the Nov 21 "most recently scanned realm group" fallback.
-- Flavor: Forever-only (gated).
-- ---------------------------------------------------------------------------
local FOREVER_KEY_PREFIX = "Forever-"
local foreverRuleset, foreverFaction
local foreverAHSide -- "Alliance" / "Horde" / "Neutral" while an AH is open

local function ForeverRuleset()
    if foreverRuleset then
        return foreverRuleset
    end
    local fn = C_GameRules and C_GameRules.GetCurrentGameModeRecordID
    if type(fn) ~= "function" then
        return nil
    end
    local ok, id = pcall(fn)
    id = ok and tonumber(id) or nil
    if not id or id <= 0 then
        return nil
    end
    foreverRuleset = id
    return id
end

local function ForeverFaction()
    if foreverFaction then
        return foreverFaction
    end
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if faction == "Alliance" or faction == "Horde" then
        foreverFaction = faction
    end
    return foreverFaction
end

local function ForeverMarketKey(side)
    local ruleset = ForeverRuleset()
    if not ruleset or not side then
        return nil
    end
    return FOREVER_KEY_PREFIX .. ruleset .. "-" .. side
end

local function ForeverReadKey()
    return ForeverMarketKey(ForeverFaction())
end

local function ForeverScanKey()
    return ForeverMarketKey(foreverAHSide or ForeverFaction())
end

-- The open AH's side: the auctioneer's faction, none = Neutral. nil when
-- the game hasn't given an auctioneer (no npc unit).
local function AuctioneerSide()
    if not (UnitGUID and UnitGUID("npc")) then
        return nil
    end
    local faction = UnitFactionGroup and UnitFactionGroup("npc")
    if faction == "Alliance" or faction == "Horde" then
        return faction
    end
    return "Neutral"
end

-- Only the scan key moves with the open AH; price lookups never do, so
-- nothing needs recomputing. Logged when the scan market changes.
local function SetForeverAHSide(side)
    local before = ForeverScanKey()
    foreverAHSide = side
    local after = ForeverScanKey()
    if before ~= after then
        SessionLog(string.format("scan market %s -> %s", tostring(before), tostring(after)))
    end
end

if IsForever() then
    local ahOpen = false
    local sideFrame = CreateFrame("Frame")
    sideFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
    sideFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
    sideFrame:SetScript("OnEvent", function(_, event)
        if event == "AUCTION_HOUSE_CLOSED" then
            ahOpen = false
            SetForeverAHSide(nil)
            return
        end
        ahOpen = true
        local side = AuctioneerSide()
        if side then
            SetForeverAHSide(side)
            return
        end
        -- No auctioneer yet: try once more shortly. Still none = this AH is
        -- treated as your faction's.
        if C_Timer and C_Timer.After then
            C_Timer.After(0.3, function()
                if not ahOpen then
                    return
                end
                local later = AuctioneerSide()
                if later then
                    SetForeverAHSide(later)
                else
                    SessionLog("AH opened with no auctioneer; using your faction's market")
                end
            end)
        end
    end)
end

-- forScan: the scan key (Forever: the open AH's market). Otherwise the
-- read key. Retail has one key for both.
local function GetRealmGroupKey(forScan)
    if IsForever() then
        if IsLoggedIn and not IsLoggedIn() then
            return nil
        end
        if forScan then
            return ForeverScanKey()
        end
        return ForeverReadKey()
    end
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

-- ---------------------------------------------------------------------------
-- Market key migration (Item_Identity_Unification_Design.md 7, 2026-11-10).
-- Market keys now take their stats from ItemIdentityService: short names
-- joined with "+", armor left out, profession accessories without stats, and
-- fixed-stat gear keyed with its stats ("4308|ilvl12|stats:SPIRIT"). Saved
-- prices and scan history move to the new keys automatically so players
-- keep their prices and history without a rescan:
--   key with stats      -> its stats in the new form (or none, accessories)
--   "id|ilvlN", no stats -> + the row's saved stats when the item is gear
--   anything else        -> unchanged
-- Two old keys landing on one new key keep the newer price / the history
-- with more days seen. A row whose item type can't be read yet (no item
-- data) stays as it is and is tried again next session; the work is marked
-- done (marketKeyVersion) once nothing is left. Runs before anything reads
-- the cache, every realm group.
-- ---------------------------------------------------------------------------

local MARKET_KEY_VERSION = 2
local migrationChecked = false

local function IdentityService()
    local core = _G.PocketCFO
    return core and core.ItemIdentityService or nil
end

-- New key for an old one; nil, "unknown" when it can't be worked out yet.
local function MigratedKey(service, marketKey, row)
    marketKey = tostring(marketKey)
    local itemID = tonumber(marketKey:match("^(%d+)|"))
    if not itemID then
        return marketKey
    end
    local statsAt = marketKey:find("|stats:", 1, true)
    local base = statsAt and marketKey:sub(1, statsAt - 1) or marketKey
    local oldStats = statsAt and marketKey:sub(statsAt + #"|stats:") or nil
    if not oldStats then
        local savedStats = type(row) == "table" and row.statFingerprint or nil
        if not base:match("^%d+|ilvl%d+$") or not savedStats or tostring(savedStats) == "" then
            return marketKey
        end
        oldStats = savedStats
    end
    local stats, reason = service:GetVariantStats(nil, itemID, oldStats)
    if reason == "unknown" then
        return nil, "unknown"
    end
    if stats and tostring(stats) ~= "" then
        return base .. "|stats:" .. tostring(stats), stats
    end
    return base
end

local function MigrateGroupPrices(service, store, keyMap)
    local cache = store.pricingCache
    if type(cache) ~= "table" then
        return 0, 0, 0
    end
    local migrated, moved, pending, merged = {}, 0, 0, 0
    for oldKey, row in pairs(cache) do
        local newKey, stats = MigratedKey(service, oldKey, row)
        if not newKey then
            newKey = tostring(oldKey)
            pending = pending + 1
        elseif newKey ~= tostring(oldKey) then
            moved = moved + 1
            keyMap[tostring(oldKey)] = newKey
            if type(row) == "table" then
                row.marketKey = newKey
                row.statFingerprint = type(stats) == "string" and stats or nil
            end
        end
        local existing = migrated[newKey]
        if existing == nil then
            migrated[newKey] = row
        else
            merged = merged + 1
            local rowTime = type(row) == "table" and tonumber(row.timestamp) or 0
            local existingTime = type(existing) == "table" and tonumber(existing.timestamp) or 0
            if rowTime > existingTime then
                migrated[newKey] = row
            end
        end
    end
    store.pricingCache = migrated
    return moved, pending, merged
end

local function MigrateGroupHistory(service, history, keyMap)
    if type(history) ~= "table" then
        return 0, 0
    end
    local migrated, moved, pending = {}, 0, 0
    for oldKey, rec in pairs(history) do
        local newKey = keyMap[tostring(oldKey)]
        if not newKey then
            local reason
            newKey, reason = MigratedKey(service, oldKey, nil)
            if not newKey then
                newKey = tostring(oldKey)
                pending = pending + 1
            end
        end
        if newKey ~= tostring(oldKey) then
            moved = moved + 1
        end
        local existing = migrated[newKey]
        if existing == nil
            or (type(rec) == "table" and (tonumber(rec.n) or 0) > (type(existing) == "table" and tonumber(existing.n) or 0)) then
            migrated[newKey] = rec
        end
    end
    return moved, pending, migrated
end

local function MigrateMarketKeys(db)
    if migrationChecked then
        return
    end
    migrationChecked = true
    local service = IdentityService()
    if not service or type(service.GetVariantStats) ~= "function" or type(db.global.realmGroups) ~= "table" then
        return
    end
    db.global.scanHistory = db.global.scanHistory or {}
    local totals = { moved = 0, pending = 0, merged = 0, historyMoved = 0 }
    for groupKey, store in pairs(db.global.realmGroups) do
        if type(store) == "table" and store.marketKeyVersion ~= MARKET_KEY_VERSION then
            local ok, err = pcall(function()
                local keyMap = {}
                local moved, pending, merged = MigrateGroupPrices(service, store, keyMap)
                local historyMoved, historyPending, history = MigrateGroupHistory(service, db.global.scanHistory[groupKey], keyMap)
                if history then
                    db.global.scanHistory[groupKey] = history
                end
                totals.moved = totals.moved + moved
                totals.pending = totals.pending + pending + historyPending
                totals.merged = totals.merged + merged
                totals.historyMoved = totals.historyMoved + historyMoved
                if pending == 0 and historyPending == 0 then
                    store.marketKeyVersion = MARKET_KEY_VERSION
                end
            end)
            if not ok then
                totals.error = tostring(err)
            end
        end
    end
    local core = _G.PocketCFO
    if core and core.AppendSessionLog then
        core:AppendSessionLog(string.format(
            "[MCG] PricingCache: market keys moved to identity form - prices moved=%d merged=%d, history moved=%d, waiting on item data=%d%s",
            totals.moved, totals.merged, totals.historyMoved, totals.pending,
            totals.error and (" error=" .. totals.error) or ""))
    end
end

-- Forever: prices saved before markets were split (2026-11-24) sit under
-- an old key ("Forever", or the realm name the beta still gave, e.g.
-- "CAMWOWUS2Realm6PvP"). The first faction market created on this install
-- takes the most recently scanned of them, with its scan history; the rest
-- are dropped. Not a Neutral market: nearly every old scan was at a faction
-- AH. Anything already blended in is replaced item by item by the next
-- full scan at each AH. Flavor: Forever-only (gated).
local function MoveOldForeverPrices(db, key, store)
    if not IsForever() or key:find("%-Neutral$") then
        return
    end
    local bestKey, bestScan
    for oldKey, oldStore in pairs(db.global.realmGroups) do
        if type(oldKey) == "string" and oldKey:sub(1, #FOREVER_KEY_PREFIX) ~= FOREVER_KEY_PREFIX then
            local lastScan = type(oldStore) == "table" and tonumber(oldStore.timeOfLastReplicateScan) or 0
            if not bestKey or lastScan > bestScan then
                bestKey, bestScan = oldKey, lastScan
            end
        end
    end
    if not bestKey then
        return
    end
    local old = db.global.realmGroups[bestKey]
    if type(old) == "table" then
        for field, value in pairs(old) do
            store[field] = value
        end
    end
    local history = type(db.global.scanHistory) == "table" and db.global.scanHistory or nil
    if history and history[bestKey] ~= nil then
        history[key] = history[bestKey]
    end
    local dropped = 0
    for oldKey in pairs(db.global.realmGroups) do
        if type(oldKey) == "string" and oldKey:sub(1, #FOREVER_KEY_PREFIX) ~= FOREVER_KEY_PREFIX then
            db.global.realmGroups[oldKey] = nil
            if history then
                history[oldKey] = nil
            end
            if oldKey ~= bestKey then
                dropped = dropped + 1
            end
        end
    end
    SessionLog(string.format("old Forever prices moved %s -> %s (other old groups dropped=%d)",
        tostring(bestKey), tostring(key), dropped))
end

-- This realm group's saved data:
--   { pricingCache = {}, timeOfLastReplicateScan = n, timeOfLastReplicateRequest = n }
-- forScan: the scan key's store (Forever: the open AH's market), else the
-- read key's store. Same store on retail.
local function GetGroupStore(forScan)
    local db = PocketCFO_Valuation.db
    if not db or not db.global then
        return nil
    end
    local key = GetRealmGroupKey(forScan)
    if not key then
        return nil
    end

    db.global.realmGroups = db.global.realmGroups or {}
    MigrateMarketKeys(db)
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
        MoveOldForeverPrices(db, key, store)
        db.global.realmGroups[key] = store
    end
    store.pricingCache = store.pricingCache or {}
    MaintainSavedPrices(db, key, store)
    return store
end

local function GetCacheRoot(forScan)
    local store = GetGroupStore(forScan)
    return store and store.pricingCache or nil
end

-- Item ID index (Brian, 2026-11-07, hover performance): itemID -> set of
-- market keys in this realm group's cache. In memory only, never saved.
-- Built in one walk the first time it's asked for, then kept current by
-- SetValue / SetPricingRow, so GetCandidatesForItemID is a lookup instead
-- of a walk over every cached market (~27,500 rows) on each call. Rebuilt
-- if the cache table itself is replaced (e.g. a wipe). One index per cache
-- table (Forever, 2026-11-24): at a Neutral AH, lookups read your faction's
-- market while searches write the Neutral one, so the two indexes are kept
-- side by side instead of rebuilding on every switch. Weak keys: a
-- replaced cache table's index goes with it.
local itemIndexes = setmetatable({}, { __mode = "k" })

local function KeyItemID(marketKey)
    return tonumber(tostring(marketKey):match("^(%d+)|"))
end

local function GetItemIndex(cache)
    local existing = itemIndexes[cache]
    if existing then
        return existing
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
    itemIndexes[cache] = index
    return index
end

-- Keeps a built index current after a write. Does nothing before the
-- index is first built (the first build picks the row up).
local function IndexKey(cache, marketKey)
    local itemIndex = itemIndexes[cache]
    if not itemIndex then
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

-- The read key: where price lookups come from (Forever: your faction's
-- market).
function PricingCache:GetRealmGroupKey()
    return GetRealmGroupKey()
end

-- The scan key: where scans and item searches save, and what scan status
-- describes (Forever: the open AH's market). Same as GetRealmGroupKey on
-- retail.
function PricingCache:GetScanMarketKey()
    return GetRealmGroupKey(true)
end

-- The Neutral AH's saved price for a market key on your ruleset, for the
-- tooltip's "Neutral AH" line (Brian, 2026-11-24). Returns value,
-- timestamp, or nil when not Forever, no Neutral scan, or no price for
-- this key. Reads only: never creates the Neutral market's store.
-- Flavor: Forever-only (gated).
function PricingCache:GetNeutralEntry(marketKey)
    if not IsForever() or not marketKey or tostring(marketKey) == "" then
        return nil
    end
    local key = ForeverMarketKey("Neutral")
    local db = PocketCFO_Valuation.db
    local groups = key and db and db.global and db.global.realmGroups
    local store = type(groups) == "table" and groups[key] or nil
    local cache = type(store) == "table" and store.pricingCache or nil
    local row = type(cache) == "table" and cache[tostring(marketKey)] or nil
    local value = NormalizeValue(row)
    if not value then
        return nil
    end
    return value, tonumber(row.timestamp)
end

-- When this realm group last finished a full scan (server time), or nil.
-- Scan status: the scan key (Forever: the open AH's market).
function PricingCache:GetLastScanTime()
    local store = GetGroupStore(true)
    return store and tonumber(store.timeOfLastReplicateScan) or nil
end

function PricingCache:SetLastScanTime(timestamp)
    local store = GetGroupStore(true)
    if store then
        store.timeOfLastReplicateScan = tonumber(timestamp)
    end
end

-- When this realm group last sent a full scan request (server time), or
-- nil. Drives the 15-minute cooldown: Blizzard's own cooldown counts from
-- the request, finished or not.
function PricingCache:GetLastRequestTime()
    local store = GetGroupStore(true)
    return store and tonumber(store.timeOfLastReplicateRequest) or nil
end

function PricingCache:SetLastRequestTime(timestamp)
    local store = GetGroupStore(true)
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

    local cache = GetCacheRoot(true)
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

    local cache = GetCacheRoot(true)
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

-- Searched, not listed (Brian, 2026-11-20): a live AH search for this item
-- ID finished, and rows last seen before it started (timestamp < seenSince)
-- weren't in it, so nothing is listed at that price right now. They get
-- notListedAt = at. A new price for the row (SetPricingRow) replaces the
-- whole row, which clears the mark. Only the tool ladder reads it
-- (ValuationRuleSet CurrentValue): a sold-out better version stops capping
-- other items, while its own value keeps its last price. Returns how many
-- rows were marked. Flavor: Both.
function PricingCache:MarkNotListed(itemID, seenSince, at)
    itemID = tonumber(itemID)
    seenSince = tonumber(seenSince)
    local cache = GetCacheRoot(true)
    if not itemID or not seenSince or not cache then
        return 0
    end
    at = tonumber(at) or Now()
    local marked, firstKey = 0, nil
    for marketKey in pairs(GetItemIndex(cache)[itemID] or {}) do
        local row = cache[marketKey]
        if type(row) == "table" and (tonumber(row.timestamp) or 0) < seenSince
            and (tonumber(row.notListedAt) or 0) < at then
            row.notListedAt = at
            marked = marked + 1
            firstKey = firstKey or marketKey
        end
    end
    if marked > 0 then
        BroadcastPricingUpdated(firstKey, itemID, "not-listed")
    end
    return marked
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
