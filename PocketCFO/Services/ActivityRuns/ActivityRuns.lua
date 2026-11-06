-- PocketCFO/Services/ActivityRuns/ActivityRuns.lua
-- Automatic activity runs for gold per hour (core). A run is a stretch of
-- one character producing value with no long break. Nobody starts or stops
-- anything: the first loot starts a run, RUN_END_SECONDS without loot ends it.
-- Today the only source is gathering (GatheringCapture calls AddLoot). Later
-- sources (mob loot, dungeons, world quests) feed the same runs through
-- AddLoot with their own source / part key.
-- Design agreed with Brian 2026-10-23.
--
-- Run time (decided with Brian 2026-10-23):
--   - Measured from the first loot to the last loot: the 10 idle minutes that
--     end a run never count.
--   - Any gap between two loots longer than GAP_CAP_SECONDS counts as
--     GAP_CAP_SECONDS, so a break in the middle of a run is trimmed.
--   - While a run is going, the live timer adds the time since the last loot,
--     up to GAP_CAP_SECONDS (the same amount the next loot will add).
--   - Runs with fewer than MIN_RUN_LOOTS loots are not kept: picking up a
--     couple of nodes while flying through is not a run, and a 2-node run's
--     short clock gives a fake rate (2026-10-26). Their items still count in
--     the daily totals GatheringCapture keeps.
--
-- Activities (decided with Brian 2026-10-26):
--   - run.activity = "gathering" (default) or "beasts". A run with a great
--     beast skin in it is a Grand Beasts run (BeastSkinCapture calls
--     AddBeastExtras). Normal skinning along the route stays part of it.
--   - run.activity = "fishing" (2026-10-26): fishing is its own activity so
--     "fish or skin on this character" can be compared. Switching between
--     fishing and any other gathering files the current run and starts a new one.
--   - A beast run also counts the beast's kill loot, and subtracts the lure
--     used at its cost that day (run.costs, never re-priced).
--   - Beast run start/end (decided with Brian 2026-10-27, replaces "a beast
--     skin relabels whatever run is open"):
--       Beast event = a lure used (BeastSkinCapture -> AddLureUse) or a beast
--       skinned (GatheringCapture tags the skin window, AddLoot info.beastSkin).
--       A beast skin counts too so someone else's summon still makes a beast run.
--       With no beast run open, a beast event either relabels the current run
--       (fewer than MIN_RUN_LOOTS loots: the couple of skins near the lure
--       spot) or files it as its own run and opens a new beast run.
--       Everything looted while the beast run is open goes into it.
--       BEAST_RUN_END_SECONDS with no beast event ends it (run.lastBeastAt).
--     The lure is charged when its use is seen. Until lure use has been seen
--     at least once (lureUseSeen, Theoretical event), the skin charges it as
--     before, so beast runs don't go cost-free if lure detection never fires.
--   - Lures are bind on pickup, so they have no AH value. Their cost is the
--     lure recipe's Cost to Make from the lure analysis (PocketCFO_Crafting
--     LureAnalysisService), sent here with SetLureCost whenever Crafting loads
--     or a lure is viewed (2026-10-26). Until a lure's cost is known, runs
--     that used it have no rate ("no lure price"); they are filled in with the
--     first known cost when it arrives.
--
-- Value:
--   - copper on a run / part / zone = value locked in when looted (same rule
--     as the Gathering tab). Items with no price at loot time keep their
--     quantity (qty - valuedQty) and are priced when shown.
--   - The "Best use of your time" ranking re-prices every run's items at
--     today's prices (ValueAtToday), so old runs at old prices don't mislead.
--
-- Storage: PocketCFO_DB.global.activityRuns
--   current[characterGUID] = run           -- the run in progress (or just ended, not yet filed)
--   history[characterGUID] = { name, classFile, runs = { run, ... } }   -- finished, oldest first
--   ui = { shown, left, top, hidden }      -- Gold per Hour tracker window state, hidden rows
--   lureCosts[lureItemID] = { copper, at } -- latest Cost to Make per lure
--   professions[characterGUID] = { "182", "186" }  -- gathering professions at last login (2026-10-31)
--   run = {
--     startedAt, lastLootAt, endedAt (history only), seconds,   -- seconds = counted run time
--     loots, copper, activity,
--     items = { [itemID] = { qty, valuedQty, copper, link } },
--     parts = { [partKey] = { source, loots, copper, items } }, -- partKey: profession key for gathering
--     zones = { [zoneName] = { loots, seconds, copper, items } },
--     costs = { [itemID] = { qty, copper, unpriced } }, costUnpriced,  -- lures (beast runs)
--     castSeconds, casts,       -- gather cast time totals (run and each part), for
--                               -- later speed analysis (capture only, 2026-10-26)
--   Every items table entry also carries base, bonus, procs (2026-10-26):
--     base  = amount the loot source gave (GetLootSourceInfo), bonus = received
--     minus base (Finesse on base mats, Perception on rare mats - which stat is
--     Theoretical until analysed), procs = loots where this item got a bonus.
--   Each part also has buffs[spellID] = { loots, base, bonus, castSeconds, casts }
--     for every buff active at gather cast start (capture only, for later
--     Finesse / Perception / speed consumable analysis).
--   Each part also has nodeTypes[nodeName] = { recipeID, loots, base, bonus,
--     rareBase, rareBonus, statLoots, finesse, perception, deftness }:
--     per node type (Lush Tranquility Bloom, Rich Refulgent Copper...),
--     base/bonus split into base mats (quality below rare) and rare items, and
--     the sum of the player's stat % on that node type over statLoots loots
--     (average = sum / statLoots). Capture only (2026-10-26).
--     Buffs (phials, Wild Perception) swing the % a lot, so each node type also
--     keeps totals per STAT_BAND-point band of the % at loot time, for the
--     "per % point" analysis (data only, never displayed - Brian 2026-10-26):
--       finesseBands[band]    = { loots, base, bonus }        -- base mats
--       perceptionBands[band] = { loots, rareItems }          -- rare items found
--       deftnessBands[band]   = { casts, castSeconds }        -- cast time
--     Procs (2026-10-26): the game's "Your Finesse/Perception helps you
--     gather something extra:" toast adds finesseProcs / perceptionProcs on the
--     node type and procs on the band the % was in at that loot (AddProc).
--     Proc spread (2026-10-26, Finesse double/triple procs seen in-game):
--       finesseSpread[band][k] = { loots, bonus } - gathers by how many Finesse
--       procs they got (k = 0, 1, 2, 3 = three or more) and their base-mat
--       bonus. band "none" = no stats (creatures). Written once per gather,
--       after its toasts are in (AddProcSpread). Tests whether each proc is a
--       new roll at the Finesse % and whether every proc adds the same.
--   }
-- Kept: last HISTORY_LIMIT runs per character, none older than HISTORY_DAYS.
--
-- In memory only (not saved): every loot of the last RECENT_SECONDS as
-- { at, copper }, for later uses like "last 15 minutes" rates.
--
-- "Still gathering?" (agreed with Brian 2026-11-05): a gathering or fishing run
--   with MIN_RUN_LOOTS+ loots and GAP_CAP_SECONDS without loot gets a prompt
--   (ActivityControl, held until out of combat). Still gathering: this gap
--   counts in full (run.stillGathering, up to RUN_END_SECONDS) instead of
--   being capped. I'm done: the run is filed, ending at its last loot.
--   No answer: the gap is capped as before, and RUN_END_SECONDS still ends it.
--   Not for beast runs (they end at BEAST_RUN_END_SECONDS) or while paused.
--
-- Messages (split 2026-10-26: rebuilding the ranking on every loot lagged each skin):
--   MCG_ACTIVITY_RUNS_UPDATED - loot added to the run in progress (live numbers only)
--   MCG_ACTIVITY_RUNS_FILED   - a run was filed or saved runs changed (ranking)

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local ActivityRuns = PocketCFO:NewModule("ActivityRuns", "AceEvent-3.0")
PocketCFO.ActivityRuns = ActivityRuns

local RUN_END_SECONDS = 600
local GAP_CAP_SECONDS = 180
-- Beast runs (decided with Brian 2026-10-27): a beast run ends after this long
-- with no beast event (a lure used or a beast skinned). Inside a beast run a
-- gap between loots counts up to this long too, so the summon and the fight
-- count in full instead of being trimmed to GAP_CAP_SECONDS.
local BEAST_RUN_END_SECONDS = 300
local MIN_RUN_LOOTS = 5
local HISTORY_LIMIT = 200
local HISTORY_DAYS = 90
-- Pause (2026-10-31): a run paused longer than this is filed, ended where it
-- was paused (a forgotten pause never hangs around).
local PAUSE_LIMIT_SECONDS = 1800
local RECENT_SECONDS = 7200
local CHECK_SECONDS = 30
local POOR_QUALITY = 0
-- Activity names shown to the player (decided with Brian 2026-10-26: the
-- Gold per Hour list ranks activities, character name second).
-- New activities add their label here; "gathering" is built from the
-- character's gathering professions (GATHER_LABELS, in this order).
local ACTIVITY_LABELS = { beasts = "Grand Beasts", fishing = "Fishing" }
local GATHER_LABELS = {
    { key = "182", label = "Herbs" },     -- Herbalism
    { key = "186", label = "Ore" },       -- Mining
    { key = "393", label = "Skinning" },  -- Skinning
}
local BEAST_EXTRAS_DELAY = 1   -- seconds; lets the skin window's loot land in the run first
local BEAST_PART = "beastkill"

local PRICE_CACHE_SECONDS = 1800

local recentLoot = {}   -- { { at, copper } } oldest first, not saved

-- Remembered unit values (not saved), keyed by item link (or itemID), so the
-- same mat isn't run through the valuation engine on every loot or every
-- second. Prices only change at the auction house (scan or search), so the
-- whole cache is cleared when the AH closes; entries also expire after
-- PRICE_CACHE_SECONDS as a safety net (e.g. a valuation rule changed).
-- "No price" is remembered too. Decided with Brian 2026-10-26.
local priceCache = {}   -- [key] = { value = copper | false, at = GetTime() }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function SessionLog(msg, ...)
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] ActivityRuns: " .. tostring(msg))
end

local function RunsDB()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    local db = globalDB.activityRuns or {}
    globalDB.activityRuns = db
    db.current = db.current or {}
    db.history = db.history or {}
    db.ui = db.ui or {}
    db.lureCosts = db.lureCosts or {}
    db.professions = db.professions or {}
    return db
end

local function PlayerGUID()
    return UnitGUID and UnitGUID("player") or nil
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

-- Same safe access pattern ValuationService documents: never force the
-- addon to load from a pricing query.
local function GetValuationService()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_Valuation"))
        or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_Valuation"))
    if not loaded then
        return nil
    end
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule("ValuationService", true) or nil
end

local function NewBucket()
    return { loots = 0, copper = 0, items = {} }
end

-- slot = { itemID, link, qty, unitValue (nil when unpriced) }
-- slot.base (optional): amount the loot source gave; received - base = bonus.
local function AddItem(items, slot)
    local entry = items[slot.itemID] or { qty = 0, valuedQty = 0, copper = 0 }
    items[slot.itemID] = entry
    entry.qty = entry.qty + slot.qty
    entry.link = slot.link or entry.link
    if slot.unitValue then
        entry.valuedQty = entry.valuedQty + slot.qty
        entry.copper = entry.copper + slot.unitValue * slot.qty
    end
    if slot.base then
        local bonus = math.max(0, slot.qty - slot.base)
        entry.base = (entry.base or 0) + slot.base
        entry.bonus = (entry.bonus or 0) + bonus
        if bonus > 0 then
            entry.procs = (entry.procs or 0) + 1
        end
    end
end

-- Buffs active at gather cast start: per buff, loots / base / bonus / cast time.
-- buffs = { spellID, ... }
local function AddBuffStats(bucket, buffs, slots, castSeconds)
    if type(buffs) ~= "table" or #buffs == 0 then
        return
    end
    local base, bonus = 0, 0
    for _, slot in ipairs(slots) do
        if slot.base then
            base = base + slot.base
            bonus = bonus + math.max(0, slot.qty - slot.base)
        end
    end
    bucket.buffs = bucket.buffs or {}
    for _, spellID in ipairs(buffs) do
        local stats = bucket.buffs[spellID] or { loots = 0, base = 0, bonus = 0, castSeconds = 0, casts = 0 }
        bucket.buffs[spellID] = stats
        stats.loots = stats.loots + 1
        stats.base = stats.base + base
        stats.bonus = stats.bonus + bonus
        if castSeconds then
            stats.castSeconds = stats.castSeconds + castSeconds
            stats.casts = stats.casts + 1
        end
    end
end

local RARE_QUALITY = 3
local STAT_BAND = 5

local function Band(pct)
    pct = tonumber(pct)
    return pct and (math.floor(pct / STAT_BAND) * STAT_BAND) or nil
end

-- Per node type stats. node = { name, recipeID, stats = { finesse, perception, deftness } | nil }
local function AddNodeStats(bucket, node, slots, castSeconds)
    if type(node) ~= "table" or not node.name then
        return
    end
    bucket.nodeTypes = bucket.nodeTypes or {}
    local entry = bucket.nodeTypes[node.name] or { loots = 0, base = 0, bonus = 0, rareBase = 0, rareBonus = 0,
        statLoots = 0, finesse = 0, perception = 0, deftness = 0 }
    bucket.nodeTypes[node.name] = entry
    entry.recipeID = node.recipeID or entry.recipeID
    entry.loots = entry.loots + 1
    local base, bonus, rareItems = 0, 0, 0
    for _, slot in ipairs(slots) do
        if slot.base then
            local slotBonus = math.max(0, slot.qty - slot.base)
            if (tonumber(slot.quality) or 0) >= RARE_QUALITY then
                entry.rareBase = entry.rareBase + slot.base
                entry.rareBonus = entry.rareBonus + slotBonus
                rareItems = rareItems + slot.qty
            else
                entry.base = entry.base + slot.base
                entry.bonus = entry.bonus + slotBonus
                base = base + slot.base
                bonus = bonus + slotBonus
            end
        end
    end
    local stats = node.stats
    if type(stats) == "table" then
        entry.statLoots = entry.statLoots + 1
        entry.finesse = entry.finesse + (tonumber(stats.finesse) or 0)
        entry.perception = entry.perception + (tonumber(stats.perception) or 0)
        entry.deftness = entry.deftness + (tonumber(stats.deftness) or 0)

        local band = Band(stats.finesse)
        if band then
            entry.finesseBands = entry.finesseBands or {}
            local b = entry.finesseBands[band] or { loots = 0, base = 0, bonus = 0 }
            entry.finesseBands[band] = b
            b.loots = b.loots + 1
            b.base = b.base + base
            b.bonus = b.bonus + bonus
        end
        band = Band(stats.perception)
        if band then
            entry.perceptionBands = entry.perceptionBands or {}
            local b = entry.perceptionBands[band] or { loots = 0, rareItems = 0 }
            entry.perceptionBands[band] = b
            b.loots = b.loots + 1
            b.rareItems = b.rareItems + rareItems
        end
        band = Band(stats.deftness)
        castSeconds = tonumber(castSeconds)
        if band and castSeconds then
            entry.deftnessBands = entry.deftnessBands or {}
            local b = entry.deftnessBands[band] or { casts = 0, castSeconds = 0 }
            entry.deftnessBands[band] = b
            b.casts = b.casts + 1
            b.castSeconds = b.castSeconds + castSeconds
        end
    end
    return entry
end

-- One Finesse or Perception proc on a node type entry (from AddNodeStats).
-- statName = "finesse" | "perception"; stats = the % read at that loot.
local function AddProc(entry, statName, stats)
    if type(entry) ~= "table" then
        return
    end
    local key = statName .. "Procs"
    entry[key] = (entry[key] or 0) + 1
    local band = Band(type(stats) == "table" and stats[statName] or nil)
    local bands = entry[statName .. "Bands"]
    if band and bands and bands[band] then
        bands[band].procs = (bands[band].procs or 0) + 1
    end
end

-- One finished gather's Finesse proc count (0, 1, 2, 3+) and its bonus.
local function AddProcSpread(entry, stats, procs, bonus)
    if type(entry) ~= "table" then
        return
    end
    local band = Band(type(stats) == "table" and stats.finesse or nil) or "none"
    local k = math.min(tonumber(procs) or 0, 3)
    entry.finesseSpread = entry.finesseSpread or {}
    local spread = entry.finesseSpread[band] or {}
    entry.finesseSpread[band] = spread
    local cell = spread[k] or { loots = 0, bonus = 0 }
    spread[k] = cell
    cell.loots = cell.loots + 1
    cell.bonus = cell.bonus + (tonumber(bonus) or 0)
end

-- Shared with GatheringCapture's daily rows so both keep the same fields.
ActivityRuns.AddProcSpreadTo = AddProcSpread
ActivityRuns.AddItemTo = AddItem
ActivityRuns.AddBuffStatsTo = AddBuffStats
ActivityRuns.AddNodeStatsTo = AddNodeStats
ActivityRuns.AddProcTo = AddProc

-- Longest gap between two loots that counts as run time.
local function GapCap(run)
    if run and run.activity == "beasts" then
        return BEAST_RUN_END_SECONDS
    end
    -- "Still gathering" answered for this gap: the search time counts in full.
    if run and run.stillGathering then
        return RUN_END_SECONDS
    end
    return GAP_CAP_SECONDS
end

-- The run's bucket for the zone the player is in now (created if needed).
local function CurrentZoneBucket(run)
    local zoneName = (GetZoneText and GetZoneText()) or "?"
    if zoneName == "" then
        zoneName = "?"
    end
    run.zones = run.zones or {}
    local zone = run.zones[zoneName] or { loots = 0, copper = 0, items = {} }
    run.zones[zoneName] = zone
    return zone
end

local function AddToBucket(bucket, slots, copper)
    bucket.loots = (bucket.loots or 0) + 1
    bucket.copper = (bucket.copper or 0) + copper
    bucket.items = bucket.items or {}
    for _, slot in ipairs(slots) do
        AddItem(bucket.items, slot)
    end
end

-- ---------------------------------------------------------------------------
-- Valuation (shared by GatheringCapture and the PocketCFO_PnL views)
-- ---------------------------------------------------------------------------

-- Value of one unit right now, in copper, or nil when unpriced (remembered
-- until the auction house closes; see priceCache).
-- ValuationService first (custom -> vendor purchase -> AH). Gray items with
-- no price fall back to the vendor sell price.
function ActivityRuns:GetUnitValue(itemID, link, quality)
    itemID = tonumber(itemID) or ItemIDFromLink(link)
    if not itemID then
        return nil
    end
    local key = link or itemID
    local cached = priceCache[key]
    local now = GetTime()
    if cached and (now - cached.at) < PRICE_CACHE_SECONDS then
        return cached.value or nil
    end
    local value, notLoaded = self:LookupUnitValue(itemID, link, quality)
    -- Don't remember "no price" for an item the client hasn't loaded yet
    -- (cold item cache): the next lookup may succeed.
    if value or not notLoaded then
        priceCache[key] = { value = value or false, at = now }
    end
    return value
end

function ActivityRuns:ClearPriceCache()
    priceCache = {}
end

-- The actual lookup behind GetUnitValue (no caching).
-- @return copper | nil, notLoaded (true when item info wasn't available yet)
function ActivityRuns:LookupUnitValue(itemID, link, quality)
    local service = GetValuationService()
    if service and service.GetItemValue then
        local ok, result = pcall(service.GetItemValue, service, { itemID = itemID, itemLink = link })
        if ok and type(result) == "table" and not result.unresolved and tonumber(result.value) then
            return math.floor(tonumber(result.value) + 0.5)
        end
    end

    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if getInfo then
        local ok, name, _, rarity, _, _, _, _, _, _, _, sellPrice = pcall(getInfo, link or itemID)
        quality = tonumber(quality) or (ok and tonumber(rarity)) or nil
        if ok and quality == POOR_QUALITY and tonumber(sellPrice) and sellPrice > 0 then
            return sellPrice
        end
        if not ok or not name then
            return nil, true
        end
    end
    return nil
end

-- Value locked in at loot time, plus unpriced quantities at today's price.
-- @return copper, unpricedQty (still no price at all)
function ActivityRuns:ValueItems(items)
    local copper, unpriced = 0, 0
    for itemID, entry in pairs(items or {}) do
        copper = copper + (tonumber(entry.copper) or 0)
        local missing = (tonumber(entry.qty) or 0) - (tonumber(entry.valuedQty) or 0)
        if missing > 0 then
            local unit = self:GetUnitValue(itemID, entry.link)
            if unit then
                copper = copper + unit * missing
            else
                unpriced = unpriced + missing
            end
        end
    end
    return copper, unpriced
end

-- Every unit at today's price. Items with no price today fall back to their
-- average value at loot time; items never priced count as zero.
-- priceCache (optional): { [itemID] = unit | false } shared across calls so
-- each item is looked up once per ranking build.
-- @return copper, unpricedQty
function ActivityRuns:ValueAtToday(items, priceCache)
    local copper, unpriced = 0, 0
    for itemID, entry in pairs(items or {}) do
        local qty = tonumber(entry.qty) or 0
        local unit
        if priceCache and priceCache[itemID] ~= nil then
            unit = priceCache[itemID] or nil
        else
            unit = self:GetUnitValue(itemID, entry.link)
            if priceCache then
                priceCache[itemID] = unit or false
            end
        end
        if unit then
            copper = copper + unit * qty
        elseif (tonumber(entry.valuedQty) or 0) > 0 then
            copper = copper + qty * (tonumber(entry.copper) or 0) / entry.valuedQty
        else
            unpriced = unpriced + qty
        end
    end
    return math.floor(copper), unpriced
end

-- ---------------------------------------------------------------------------
-- Runs
-- ---------------------------------------------------------------------------

local function PruneHistory(entry, now)
    local cutoff = now - HISTORY_DAYS * 86400
    local kept = {}
    for _, run in ipairs(entry.runs) do
        if (run.endedAt or run.lastLootAt or 0) >= cutoff then
            kept[#kept + 1] = run
        end
    end
    while #kept > HISTORY_LIMIT do
        table.remove(kept, 1)
    end
    entry.runs = kept
end

-- Files the character's current run if it has ended (or force is set).
-- Returns true when something changed.
function ActivityRuns:FinishRunIfEnded(characterGUID, now, force)
    local db = RunsDB()
    local run = db and characterGUID and db.current[characterGUID]
    now = now or time()
    if not run then
        return false
    end
    if not force then
        if run.pausedAt then
            -- Paused: never auto-ends, until the pause limit (2026-10-31).
            if (now - run.pausedAt) <= PAUSE_LIMIT_SECONDS then
                return false
            end
            SessionLog("paused run filed after %ds paused", now - run.pausedAt)
        else
            -- Beast runs end on beast events only (normal skins don't keep them open).
            local isBeasts = run.activity == "beasts"
            local last = isBeasts and (run.lastBeastAt or run.lastLootAt) or run.lastLootAt
            local limit = isBeasts and BEAST_RUN_END_SECONDS or RUN_END_SECONDS
            if (now - (last or 0)) <= limit then
                return false
            end
        end
    end
    run.pausedAt, run.pauseDeclined = nil, nil
    db.current[characterGUID] = nil
    -- Beast runs are kept at any size (a short route of 2-3 beasts still counts).
    if (run.loots or 0) < MIN_RUN_LOOTS and run.activity ~= "beasts" then
        SessionLog("run dropped (loots=%d)", run.loots or 0)
        return true
    end
    run.endedAt = run.lastLootAt
    local entry = db.history[characterGUID] or { runs = {} }
    db.history[characterGUID] = entry
    entry.runs = entry.runs or {}
    if characterGUID == PlayerGUID() then
        local _, classFile = UnitClass("player")
        entry.name = UnitName("player")
        entry.classFile = classFile
    end
    entry.runs[#entry.runs + 1] = run
    PruneHistory(entry, now)
    SessionLog("run filed loots=%d seconds=%d copper=%d", run.loots or 0, run.seconds or 0, run.copper or 0)
    return true
end

-- Files every ended run (all characters). Sends the update message if any.
function ActivityRuns:CheckEndedRuns()
    local db = RunsDB()
    if not db then
        return
    end
    local now = time()
    local changed = false
    local guids = {}
    for guid in pairs(db.current) do
        guids[#guids + 1] = guid
    end
    for _, guid in ipairs(guids) do
        if self:FinishRunIfEnded(guid, now) then
            changed = true
        end
    end
    if changed then
        self:SendMessage("MCG_ACTIVITY_RUNS_FILED")
    end
end

-- Adds one loot window to the current character's run.
-- source: "gathering" (later: other activity sources)
-- partKey: what the loot came from within the source (profession key for gathering)
-- slots: { { itemID, link, qty, unitValue } }; copper: value of the window at loot time
-- Returns the run part's node type entry (for procs reported after the loot).
-- info (optional): { castSeconds = how long the gather cast took,
--                    buffs = { spellID, ... } active at gather cast start,
--                    node = { name, recipeID, stats } node type gathered,
--                    activity = "fishing" | nil (nil = "gathering") }
function ActivityRuns:AddLoot(source, partKey, slots, copper, info)
    info = info or {}
    local castSeconds, buffs = info.castSeconds, info.buffs
    local db = RunsDB()
    local guid = PlayerGUID()
    if not db or not guid or #slots == 0 then
        return
    end
    local now = time()
    copper = tonumber(copper) or 0
    if self:FinishRunIfEnded(guid, now) then
        self:SendMessage("MCG_ACTIVITY_RUNS_FILED")
    end
    if self:HoldIfPaused(guid, function()
        return ActivityRuns:AddLoot(source, partKey, slots, copper, info)
    end) then
        return nil
    end

    local zoneName = (GetZoneText and GetZoneText()) or "?"
    if zoneName == "" then
        zoneName = "?"
    end

    -- Fishing and other gathering never share a run.
    local activity = info.activity or "gathering"
    local current = db.current[guid]
    if current and ((current.activity == "fishing") ~= (activity == "fishing")) then
        self:FinishRunIfEnded(guid, now, true)
        self:SendMessage("MCG_ACTIVITY_RUNS_FILED")
    end

    -- A beast skin opens or extends a beast run before its loot lands.
    if info.beastSkin then
        self:BeginBeastEvent(guid, now)
    end

    local run = db.current[guid]
    local gap = 0
    if not run then
        run = { startedAt = now, lastLootAt = now, seconds = 0, loots = 0, copper = 0,
                activity = activity, items = {}, parts = {}, zones = {} }
        db.current[guid] = run
    else
        gap = math.min(math.max(0, now - (run.lastLootAt or now)), GapCap(run))
        run.seconds = (run.seconds or 0) + gap
    end
    run.lastLootAt = now
    run.stillGathering = nil  -- a new gap starts; the prompt can come again
    AddToBucket(run, slots, copper)

    local part = run.parts[partKey] or NewBucket()
    run.parts[partKey] = part
    part.source = source
    AddToBucket(part, slots, copper)

    castSeconds = tonumber(castSeconds)
    if castSeconds then
        run.castSeconds = (run.castSeconds or 0) + castSeconds
        run.casts = (run.casts or 0) + 1
        part.castSeconds = (part.castSeconds or 0) + castSeconds
        part.casts = (part.casts or 0) + 1
    end
    AddBuffStats(part, buffs, slots, castSeconds)
    local nodeEntry = AddNodeStats(part, info.node, slots, castSeconds)

    local zone = run.zones[zoneName] or NewBucket()
    run.zones[zoneName] = zone
    zone.seconds = (zone.seconds or 0) + gap
    AddToBucket(zone, slots, copper)

    recentLoot[#recentLoot + 1] = { at = now, copper = copper }
    while recentLoot[1] and (now - recentLoot[1].at) > RECENT_SECONDS do
        table.remove(recentLoot, 1)
    end

    self:SendMessage("MCG_ACTIVITY_RUNS_UPDATED")
    return nodeEntry
end

-- Beast kill loot and lure cost on a run (marks it a Grand Beasts run).
-- killItems = { [itemID] = qty }. Values at today's price.
local function ApplyBeastExtras(run, killItems, lureItemID)
    run.activity = "beasts"
    local slots, copper = {}, 0
    for itemID, qty in pairs(killItems or {}) do
        qty = tonumber(qty) or 0
        if qty > 0 then
            local unit = ActivityRuns:GetUnitValue(itemID)
            slots[#slots + 1] = { itemID = itemID, qty = qty, unitValue = unit }
            copper = copper + (unit or 0) * qty
        end
    end
    if #slots > 0 then
        run.copper = (run.copper or 0) + copper
        for _, slot in ipairs(slots) do
            AddItem(run.items, slot)
        end
        local part = run.parts[BEAST_PART] or NewBucket()
        run.parts[BEAST_PART] = part
        part.source = "beasts"
        AddToBucket(part, slots, copper)
        -- Kill loot belongs to the zone the beast died in (2026-10-28: it
        -- was missing from every zone, so zone lines didn't add up).
        AddToBucket(CurrentZoneBucket(run), slots, copper)
    end
    if lureItemID then
        ActivityRuns:ChargeLure(run, lureItemID)
    end
end

-- One lure used on a run, at its latest Cost to Make (or unpriced).
function ActivityRuns:ChargeLure(run, lureItemID)
    run.costs = run.costs or {}
    local cost = run.costs[lureItemID] or { qty = 0, copper = 0 }
    run.costs[lureItemID] = cost
    cost.qty = cost.qty + 1
    local unit = self:GetLureCost(lureItemID)
    if unit then
        cost.copper = cost.copper + unit
    else
        cost.unpriced = (cost.unpriced or 0) + 1
        run.costUnpriced = true
    end
end

-- A beast event (lure used or beast skinned) for this character: opens a
-- beast run or keeps the open one going (2026-10-27).
--   - Beast run open: just marks the time.
--   - Current run is small (< MIN_RUN_LOOTS) gathering: relabeled as the beast run.
--   - Current run is a full run, or fishing: filed, and a new beast run opens.
-- Advances the run clock to now (gap capped at BEAST_RUN_END_SECONDS).
-- Returns the beast run.
function ActivityRuns:BeginBeastEvent(guid, now)
    local db = RunsDB()
    if not db or not guid then
        return nil
    end
    now = now or time()
    local filed = self:FinishRunIfEnded(guid, now)
    local run = db.current[guid]
    if run and run.activity ~= "beasts"
        and ((run.loots or 0) >= MIN_RUN_LOOTS or run.activity == "fishing") then
        self:FinishRunIfEnded(guid, now, true)
        filed = true
        run = nil
    end
    if not run then
        run = { startedAt = now, lastLootAt = now, seconds = 0, loots = 0, copper = 0,
                activity = "beasts", items = {}, parts = {}, zones = {} }
        db.current[guid] = run
        SessionLog("beast run started")
    else
        if run.activity ~= "beasts" then
            run.activity = "beasts"
            SessionLog("small run relabeled as beast run (loots=%d)", run.loots or 0)
        end
        local gap = math.min(math.max(0, now - (run.lastLootAt or now)), BEAST_RUN_END_SECONDS)
        run.seconds = (run.seconds or 0) + gap
        -- The same time goes to the zone the event happened in (2026-10-28:
        -- lure-use time was counted on the run but in no zone, e.g. Harandar
        -- showed 206g in 0 seconds).
        local zone = CurrentZoneBucket(run)
        zone.seconds = (zone.seconds or 0) + gap
        run.lastLootAt = now
    end
    run.lastBeastAt = now
    if filed then
        self:SendMessage("MCG_ACTIVITY_RUNS_FILED")
    end
    return run
end

-- Called by BeastSkinCapture when the player uses a great beast lure.
-- Opens or extends a beast run and charges the lure (2026-10-27).
function ActivityRuns:AddLureUse(lureItemID)
    local db = RunsDB()
    local guid = PlayerGUID()
    lureItemID = tonumber(lureItemID)
    if not db or not guid or not lureItemID then
        return
    end
    db.lureUseSeen = true
    if self:FinishRunIfEnded(guid, time()) then
        self:SendMessage("MCG_ACTIVITY_RUNS_FILED")
    end
    if self:HoldIfPaused(guid, function() ActivityRuns:AddLureUse(lureItemID) end) then
        return
    end
    local run = self:BeginBeastEvent(guid, time())
    if run then
        self:ChargeLure(run, lureItemID)
        SessionLog("lure used %d", lureItemID)
        self:SendMessage("MCG_ACTIVITY_RUNS_UPDATED")
    end
end

-- Called by BeastSkinCapture when a great beast skin is saved. Applied a
-- moment later so the skin window (GatheringCapture) is already in the run,
-- whichever addon frame handled LOOT_CLOSED first.
function ActivityRuns:AddBeastExtras(npcID, killItems, lureItemID)
    local guid = PlayerGUID()
    C_Timer.After(BEAST_EXTRAS_DELAY, function()
        local db = RunsDB()
        local run = db and guid and db.current[guid]
        if not run then
            return
        end
        if ActivityRuns:HoldIfPaused(guid, function()
            ActivityRuns:AddBeastExtras(npcID, killItems, lureItemID)
        end) then
            return
        end
        -- The lure is charged at lure use once that has been seen working;
        -- until then the skin charges it (2026-10-27).
        ApplyBeastExtras(run, killItems, (not db.lureUseSeen) and lureItemID or nil)
        SessionLog("beast extras npcID=%s lure=%s", tostring(npcID), tostring(lureItemID))
        ActivityRuns:SendMessage("MCG_ACTIVITY_RUNS_UPDATED")
    end)
end

-- Latest known Cost to Make for a lure (copper), or nil.
function ActivityRuns:GetLureCost(lureItemID)
    local db = RunsDB()
    local entry = db and db.lureCosts[tonumber(lureItemID)]
    return entry and tonumber(entry.copper) or nil
end

-- Lures still missing a price on a cost entry. Entries saved before
-- 2026-10-26 have no unpriced count: copper 0 on an unpriced run = all of them.
local function UnpricedLures(run, cost)
    if cost.unpriced then
        return cost.unpriced
    end
    if run.costUnpriced and (tonumber(cost.copper) or 0) == 0 then
        return tonumber(cost.qty) or 0
    end
    return 0
end

-- Fills lures that had no price on a run; returns true when it changed.
local function FillLureCost(run, lureItemID, copper)
    local cost = run.costs and run.costs[lureItemID]
    if not cost or not run.costUnpriced then
        return false
    end
    local missing = UnpricedLures(run, cost)
    if missing <= 0 then
        return false
    end
    cost.copper = (tonumber(cost.copper) or 0) + copper * missing
    cost.unpriced = 0
    local stillMissing = false
    for _, other in pairs(run.costs) do
        if UnpricedLures(run, other) > 0 then
            stillMissing = true
        end
    end
    run.costUnpriced = stillMissing or nil
    return true
end

-- Called by PocketCFO_Crafting (LureAnalysisService) with each lure's Cost
-- to Make. Saves it and fills runs that used this lure before it had a price.
function ActivityRuns:SetLureCost(lureItemID, copper)
    local db = RunsDB()
    lureItemID = tonumber(lureItemID)
    copper = tonumber(copper)
    if not db or not lureItemID or not copper then
        return
    end
    db.lureCosts[lureItemID] = { copper = math.floor(copper + 0.5), at = time() }
    local changed = false
    for _, entry in pairs(db.history) do
        for _, run in ipairs(entry.runs or {}) do
            if FillLureCost(run, lureItemID, db.lureCosts[lureItemID].copper) then
                changed = true
            end
        end
    end
    for _, run in pairs(db.current) do
        if FillLureCost(run, lureItemID, db.lureCosts[lureItemID].copper) then
            changed = true
        end
    end
    if changed then
        SessionLog("lure %d cost filled into earlier runs", lureItemID)
        self:SendMessage("MCG_ACTIVITY_RUNS_FILED")
    end
end

-- Gathering professions a character has (2026-10-31, Brian: the Gold per
-- Hour "By profession" breakout goes by what the character has, not what a
-- run happened to find). Keys in GATHER_LABELS order: every gathering
-- profession seen in that character's gathering runs, plus the professions
-- saved for it at its last login (db.professions[guid], SaveGatheringProfessions).
function ActivityRuns:GetGatheringProfessions(characterGUID)
    local db = RunsDB()
    local seen = {}
    local function Note(run)
        if run and (run.activity or "gathering") == "gathering" then
            for partKey in pairs(run.parts or {}) do
                seen[partKey] = true
            end
        end
    end
    local entry = db and db.history[characterGUID]
    for _, run in ipairs(entry and entry.runs or {}) do
        Note(run)
    end
    Note(db and db.current[characterGUID])
    for _, key in ipairs(db and db.professions[characterGUID or ""] or {}) do
        seen[key] = true
    end
    local keys = {}
    for _, gather in ipairs(GATHER_LABELS) do
        if seen[gather.key] then
            keys[#keys + 1] = gather.key
        end
    end
    return keys
end

-- Saves the logged-in character's gathering professions (GetProfessions ->
-- GetProfessionInfo skillLine, which should match the profession keys used on
-- runs: 182 / 186 / 393). Theoretical: skillLine is the 7th return in Midnight.
function ActivityRuns:SaveGatheringProfessions()
    local db = RunsDB()
    local guid = PlayerGUID()
    if not db or not guid or not GetProfessions or not GetProfessionInfo then
        return
    end
    local wanted = {}
    for _, gather in ipairs(GATHER_LABELS) do
        wanted[gather.key] = true
    end
    local ok, prof1, prof2 = pcall(GetProfessions)
    if not ok then
        return
    end
    local keys = {}
    for _, index in ipairs({ prof1, prof2 }) do
        if index then
            local okInfo, _, _, _, _, _, _, skillLine = pcall(GetProfessionInfo, index)
            local key = okInfo and skillLine and tostring(skillLine) or nil
            if key and wanted[key] then
                keys[#keys + 1] = key
            end
        end
    end
    db.professions[guid] = keys
end

-- Player-facing name of a character's activity: "Grand Beasts", or for
-- gathering the gathering professions the character has ("Herbs + Ore",
-- "Skinning"; GetGatheringProfessions), so a run that happened to find no
-- ore never splits the character into a second row.
function ActivityRuns:GetActivityLabel(characterGUID, activity)
    activity = activity or "gathering"
    if activity ~= "gathering" then
        return ACTIVITY_LABELS[activity] or activity
    end
    local labels = {}
    for _, gather in ipairs(GATHER_LABELS) do
        labels[gather.key] = gather.label
    end
    local names = {}
    for _, key in ipairs(self:GetGatheringProfessions(characterGUID)) do
        names[#names + 1] = labels[key]
    end
    return #names > 0 and table.concat(names, " + ") or "Gathering"
end

-- Lure cost on a run (locked at the cost that day), and whether a lure had no price.
function ActivityRuns:GetRunCost(run)
    local copper = 0
    for _, cost in pairs(run and run.costs or {}) do
        copper = copper + (tonumber(cost.copper) or 0)
    end
    return copper, run and run.costUnpriced or false
end

-- ---------------------------------------------------------------------------
-- Read API (PocketCFO_PnL, minimap button). Callers must not modify tables.
-- ---------------------------------------------------------------------------

-- The run in progress for a character (current one by default), or nil.
-- A run whose 10 minutes have passed is filed first.
function ActivityRuns:GetCurrentRun(characterGUID)
    local db = RunsDB()
    characterGUID = characterGUID or PlayerGUID()
    if not db or not characterGUID then
        return nil
    end
    if self:FinishRunIfEnded(characterGUID) then
        self:SendMessage("MCG_ACTIVITY_RUNS_FILED")
    end
    return db.current[characterGUID]
end

-- The last finished run for a character (current one by default), or nil.
function ActivityRuns:GetLastRun(characterGUID)
    local db = RunsDB()
    characterGUID = characterGUID or PlayerGUID()
    local entry = db and characterGUID and db.history[characterGUID]
    return entry and entry.runs and entry.runs[#entry.runs] or nil
end

-- history[characterGUID] = { name, classFile, runs }
function ActivityRuns:GetHistory()
    local db = RunsDB()
    return db and db.history or {}
end

-- current[characterGUID] = run
function ActivityRuns:GetCurrentRuns()
    local db = RunsDB()
    return db and db.current or {}
end

-- Counted seconds for a run. For a run in progress, includes the time since
-- the last loot up to the gap cap (the live timer).
function ActivityRuns:GetRunSeconds(run, now)
    if not run then
        return 0
    end
    local seconds = tonumber(run.seconds) or 0
    if not run.endedAt then
        -- Paused: the clock stops where it was paused.
        now = run.pausedAt or now or time()
        seconds = seconds + math.min(math.max(0, now - (run.lastLootAt or now)), GapCap(run))
    end
    return seconds
end

-- ---------------------------------------------------------------------------
-- Stop / pause (2026-10-31; Stop / Pause buttons through core ActivityControl)
--   Stop: files the run now. The next loot starts a new run.
--   Pause: the clock stops and the run never auto-ends (until
--     PAUSE_LIMIT_SECONDS, then it is filed as ended where it was paused).
--     Loot while paused is held and ActivityControl asks once whether to
--     resume: yes resumes and counts it; no leaves it out of the run (it still
--     counts in the day's gathering totals) and doesn't ask again this pause.
--   Saved on the run: pausedAt, pauseDeclined (survive /reload).
-- ---------------------------------------------------------------------------

function ActivityRuns:IsRunPaused(run)
    return run ~= nil and run.pausedAt ~= nil
end

function ActivityRuns:StopRun(characterGUID)
    characterGUID = characterGUID or PlayerGUID()
    if self:FinishRunIfEnded(characterGUID, time(), true) then
        SessionLog("run stopped by the player")
        self:SendMessage("MCG_ACTIVITY_RUNS_FILED")
        return true
    end
    return false
end

function ActivityRuns:PauseRun(characterGUID)
    local db = RunsDB()
    characterGUID = characterGUID or PlayerGUID()
    local run = db and characterGUID and db.current[characterGUID]
    if not run or run.pausedAt then
        return false
    end
    run.pausedAt = time()
    run.pauseDeclined = nil
    SessionLog("run paused")
    self:SendMessage("MCG_ACTIVITY_RUNS_UPDATED")
    return true
end

-- The time from the last loot to the pause (capped like any gap) is counted;
-- the paused time is not. The clock (and the beast-run end timer) restart now.
function ActivityRuns:ResumeRun(characterGUID)
    local db = RunsDB()
    characterGUID = characterGUID or PlayerGUID()
    local run = db and characterGUID and db.current[characterGUID]
    if not run or not run.pausedAt then
        return false
    end
    local now = time()
    local gap = math.min(math.max(0, run.pausedAt - (run.lastLootAt or run.pausedAt)), GapCap(run))
    run.seconds = (run.seconds or 0) + gap
    local zone = CurrentZoneBucket(run)
    zone.seconds = (zone.seconds or 0) + gap
    run.lastLootAt = now
    if run.lastBeastAt then
        run.lastBeastAt = now
    end
    SessionLog("run resumed after %ds paused", now - run.pausedAt)
    run.pausedAt, run.pauseDeclined = nil, nil
    run.stillGathering = nil
    self:SendMessage("MCG_ACTIVITY_RUNS_UPDATED")
    return true
end

-- Something that would count on a paused run: held (and the player asked)
-- or dropped (they already said stay paused). Returns true when the caller
-- must stop; fn is replayed if the player resumes.
function ActivityRuns:HoldIfPaused(characterGUID, fn)
    local db = RunsDB()
    local run = db and characterGUID and db.current[characterGUID]
    if not run or not run.pausedAt then
        return false
    end
    if run.pauseDeclined then
        return true
    end
    local control = PocketCFO.ActivityControl
    if control then
        control:Hold("run", fn)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- "Still gathering?" prompt (2026-11-05; the popup is in ActivityControl)
-- ---------------------------------------------------------------------------

-- True when this run should ask "Still gathering?" now: a gathering or
-- fishing run, not paused, not already answered for this gap, with at least
-- MIN_RUN_LOOTS loots and GAP_CAP_SECONDS since the last loot.
function ActivityRuns:NeedsStillGatheringPrompt(run, now)
    if not run or run.endedAt or run.pausedAt or run.stillGathering then
        return false
    end
    if run.activity == "beasts" or (run.loots or 0) < MIN_RUN_LOOTS then
        return false
    end
    now = now or time()
    return (now - (run.lastLootAt or now)) >= GAP_CAP_SECONDS
end

-- "Still gathering": the time since the last loot counts in full (up to
-- RUN_END_SECONDS, when the run ends anyway) until the next loot.
function ActivityRuns:KeepGathering(characterGUID)
    local db = RunsDB()
    characterGUID = characterGUID or PlayerGUID()
    local run = db and characterGUID and db.current[characterGUID]
    if not run or run.pausedAt or run.activity == "beasts" then
        return false
    end
    run.stillGathering = true
    SessionLog("still gathering (%ds since last loot)", time() - (run.lastLootAt or time()))
    self:SendMessage("MCG_ACTIVITY_RUNS_UPDATED")
    return true
end

-- Gold per hour, or nil while there is less than a minute of run time.
function ActivityRuns:PerHour(copper, seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 60 then
        return nil
    end
    return math.floor((tonumber(copper) or 0) * 3600 / seconds)
end

-- { seconds, copper, perHour, loots, zone, activity } for a run: value at
-- loot time, minus lures for beast runs. perHour is nil when a lure had no price.
function ActivityRuns:GetRunStats(run, now)
    if not run then
        return nil
    end
    local cost, costUnpriced = self:GetRunCost(run)
    local copper = self:ValueItems(run.items) - cost
    local seconds = self:GetRunSeconds(run, now)
    local zone, zoneLoots = nil, -1
    for name, bucket in pairs(run.zones or {}) do
        if (bucket.loots or 0) > zoneLoots then
            zone, zoneLoots = name, bucket.loots or 0
        end
    end
    return {
        seconds = seconds,
        copper = copper,
        perHour = (not costUnpriced) and self:PerHour(copper, seconds) or nil,
        loots = tonumber(run.loots) or 0,
        zone = zone,
        activity = run.activity or "gathering",
    }
end

-- Loots of the last RECENT_SECONDS: { { at, copper } } oldest first. Not saved.
function ActivityRuns:GetRecentLoot()
    return recentLoot
end

-- Tracker window state (the window lives in PocketCFO_PnL).
function ActivityRuns:GetUIState()
    local db = RunsDB()
    return db and db.ui or {}
end

function ActivityRuns:ToggleWindow()
    local loader = PocketCFO:GetModule("AddonLoader", true)
    if not loader or not loader:SafeLoad("PocketCFO_PnL") then
        PocketCFO:Print("Could not load the tracker window.")
        return
    end
    local pnl = _G.PocketCFO_PnL
    local window = pnl and pnl:GetModule("GoldPerHourWindow", true)
    if window then
        window:Toggle()
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function ActivityRuns:OnEnteringWorld()
    self:CheckEndedRuns()
    self:SaveGatheringProfessions()
    local ui = self:GetUIState()
    if ui.shown then
        local loader = PocketCFO:GetModule("AddonLoader", true)
        if loader and loader:SafeLoad("PocketCFO_PnL") then
            local pnl = _G.PocketCFO_PnL
            local window = pnl and pnl:GetModule("GoldPerHourWindow", true)
            if window then
                window:Show()
            end
        end
    end
end

-- Auction house closed: prices may have changed (scan or search).
-- AUCTION_HOUSE_CLOSED and the interaction-manager hide are both registered:
-- in Midnight, closing the mailbox does not fire MAIL_CLOSED (only the
-- interaction hide), so the same is assumed possible for the AH (Theoretical).
function ActivityRuns:OnAuctionHouseClosed()
    self:ClearPriceCache()
end

function ActivityRuns:OnInteractionHide(_, interactionType)
    local types = Enum and Enum.PlayerInteractionType
    if types and types.Auctioneer and interactionType == types.Auctioneer then
        self:ClearPriceCache()
    end
end

function ActivityRuns:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
    self:RegisterEvent("AUCTION_HOUSE_CLOSED", "OnAuctionHouseClosed")
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "OnInteractionHide")
    -- A container's average contents changed: its value may have too.
    self:RegisterMessage("MCG_CONTAINER_OPENED", "ClearPriceCache")
    if C_Timer and C_Timer.NewTicker then
        self.ticker = C_Timer.NewTicker(CHECK_SECONDS, function()
            ActivityRuns:CheckEndedRuns()
        end)
    end
end

-- ---------------------------------------------------------------------------
-- ONE-TIME FIX (2026-10-26): /mcg beastrunfix
-- Runs saved before beast runs existed: any run whose time span contains a
-- great beast skin BeastSkinCapture recorded (its last 20 skins per beast) is
-- relabeled Grand Beasts, with that beast's kill loot and lure added at
-- today's prices. Lists every run it changed. Safe to run more than once.
-- No window needed. Delete after it has been run.
-- ---------------------------------------------------------------------------
local diagnostics = PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("beastrunfix", {
        name = "beastrunfix",
        description = "One-time: relabel saved runs that included great beast skins as Grand Beasts runs.",
        usage = "/mcg beastrunfix",
        category = "General",
    }, function()
        local ok, err = pcall(function()
            local db = RunsDB()
            local beastCapture = PocketCFO:GetModule("BeastSkinCapture", true)
            if not db or not beastCapture then
                PocketCFO:Print("beastrunfix: data unavailable, nothing changed.")
                return
            end
            local beasts = beastCapture:GetBeasts()
            local SLACK = 60
            local changed = 0
            local function FixRun(guid, run, who)
                if run.activity == "beasts" then
                    return
                end
                local data = beastCapture:GetCharacterData(guid)
                local last = run.endedAt or run.lastLootAt or run.startedAt or 0
                local found = 0
                for npcID, beast in pairs(data and data.beasts or {}) do
                    for _, record in ipairs(beast.recent or {}) do
                        local at = tonumber(record.at) or 0
                        if at >= (run.startedAt or 0) - SLACK and at <= last + SLACK then
                            ApplyBeastExtras(run, record.kill, beasts[npcID] and beasts[npcID].lureItemID)
                            found = found + 1
                        end
                    end
                end
                if found > 0 then
                    changed = changed + 1
                    PocketCFO:Print("beastrunfix: %s run %s, %d min, %d beast(s) -> Grand Beasts",
                        tostring(who), date("%b %d %H:%M", run.startedAt or 0),
                        math.floor((tonumber(run.seconds) or 0) / 60), found)
                end
            end
            for guid, entry in pairs(db.history) do
                for _, run in ipairs(entry.runs or {}) do
                    FixRun(guid, run, entry.name or guid)
                end
            end
            for guid, run in pairs(db.current) do
                FixRun(guid, run, (db.history[guid] and db.history[guid].name) or guid)
            end
            PocketCFO:Print("beastrunfix: %d run(s) relabeled.", changed)
            ActivityRuns:SendMessage("MCG_ACTIVITY_RUNS_FILED")
        end)
        if not ok then
            PocketCFO:Print("beastrunfix error: " .. tostring(err))
        end
    end)
end
