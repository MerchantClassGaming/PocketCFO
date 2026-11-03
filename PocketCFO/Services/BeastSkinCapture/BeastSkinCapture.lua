-- PocketCFO/Services/BeastSkinCapture/BeastSkinCapture.lua
-- Records what each Midnight great beast returns (kill loot + skin) so the
-- Skinning Beast Analysis can show average return per lure.
-- Design doc: claude/Skinning_Beast_Analysis_Design.md (project docs).
-- Capture only. No UI, no chat output (debug log only).
--
-- Every API behavior used here was confirmed in-game on 2026-10-16 with
-- /mcgd loot and /mcgd gatherstats:
--   - Kill loot and skin loot arrive as separate loot windows, both with the
--     beast's corpse GUID in GetLootSourceInfo.
--   - Skinning (spellID 195125) UNIT_SPELLCAST_SUCCEEDED fires 0.0-0.1s
--     before the skin window's LOOT_READY; UNIT_SPELLCAST_START fires with
--     the same spellID.
--   - GetLootSlotInfo: r3 = quantity received, r5 = quality (0 = poor).
--   - GetLootSourceInfo: (GUID, qty) pairs, one per contributing corpse.
--     Area loot merges corpses into one window and can fill in across
--     successive LOOT_READY events, so the window is re-read on every event
--     and the last reading is used at LOOT_CLOSED.
--   - Skin windows: source qty = base amount, slot qty = received; the
--     difference is the Finesse (base mats) or Perception (rare mats) bonus.
--   - C_TradeSkillUI.GetGatheringOperationInfo(recipeID) returns live
--     Finesse/Perception with the profession window closed, buffs included.
--   - C_UnitAuras.GetAuraDataByIndex returns readable buff spellIDs.
-- A plain event frame is used instead of AceEvent because CraftSim's bundled
-- AceEvent can dispatch PocketCFO callbacks with shifted arguments.
--
-- Loot reading (migrated to the loot reader 2026-10-30, claude/
-- Ledger_Rebuild_Checklist.md item 7): this module no longer reads loot
-- windows. It handles MCG_LOOT_WINDOW from LootReader: a window is a skin
-- window when its attached cast is Skinning (the loot reader attaches a cast
-- to the first window after it only; before the migration a second window
-- within 3s of a skin cast also counted as a skin, which was drift). Beast
-- slots = slots with a Creature / Vehicle source whose npcID is a great beast;
-- base, received and source count from the record, same rules as before.
-- Kept here (not loot): the cast-start snapshot (buffs, Finesse /
-- Perception) and lure use.
--
-- Rules (decided with Brian 2026-10-16):
--   - Only the beast's own corpse counts. Nearby trash mobs are ignored.
--   - Kill loot counts toward the return, but is only saved together with
--     that corpse's skin.
--   - Repeat skin: if every item in the skin window is poor (gray), the skin
--     is a repeat. The whole encounter (kill loot too) is thrown out.
--   - One kill window and one skin window per corpse; reopened windows on
--     the same corpse are ignored.
--
-- Storage: PocketCFO_DB.global.beastSkins[characterGUID]
--   name, realm
--   beasts[npcID] = {
--     averageSkins = n,                   -- skins folded into averages
--     averages = { [itemID] = qty },      -- running average per skin, kill + skin
--                                         -- (what Lure Analysis reads; see below)
--     skins = n,                          -- counted skins, all time
--     killItems = { [itemID] = qty },     -- all-time kill loot totals
--     skinItems = { [itemID] = qty },     -- all-time skin totals (received)
--     recent = {                          -- last 20 skins, oldest first
--       { at, kill = { [itemID] = qty },
--         skin = { [itemID] = { qty = received, base = base } },
--         stats = { finesse, finessePct, perception, perceptionPct } | nil,
--         buffs = { spellID, ... } },
--     },
--   }
--
-- Running average (decided with Brian 2026-10-16): one row per beast, like
-- the bag data. Each skin moves every item's average 1/N of the way toward
-- what that skin gave, N = skins so far capped at AVERAGE_WINDOW (so it is a
-- plain average until 100 skins). Recent skins count more, so the average
-- follows knowledge-point growth (more items, T1 -> T2) without detecting it;
-- an old skin's weight halves about every 70 skins. All-time totals and the
-- recent list are kept as raw data for later stat/knowledge-point research.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local BeastSkinCapture = PocketCFO:NewModule("BeastSkinCapture")
PocketCFO.BeastSkinCapture = BeastSkinCapture

local SKINNING_SPELL_ID = 195125
local RECENT_LIMIT = 20
local AVERAGE_WINDOW = 100
-- Averages below this are dropped so items that stop dropping (e.g. T1 once
-- a skinner gets T2) don't sit in the row forever.
local AVERAGE_FLOOR = 0.0005
local POOR_QUALITY = 0

local RECIPE_LEATHER = 1225901 -- Void-Tempered Leather (gathering recipe)
local RECIPE_SCALES = 1225897  -- Void-Tempered Scales (gathering recipe)

-- npcID -> beast. lureItemID values were read in-game by Brian.
local BEASTS = {
    [247101] = { name = "Netherscythe", lureItemID = 238656, statRecipeID = RECIPE_SCALES },  -- Grand Beast Lure
    [245688] = { name = "Gloomclaw", lureItemID = 238652, statRecipeID = RECIPE_LEATHER },    -- Majestic Eversong Lure
    [245699] = { name = "Silverscale", lureItemID = 238653, statRecipeID = RECIPE_SCALES },   -- Majestic Zul'Aman Lure
    [245690] = { name = "Lumenfin", lureItemID = 238654, statRecipeID = RECIPE_SCALES },      -- Majestic Harandar Lure
    [247096] = { name = "Umbrafang", lureItemID = 238655, statRecipeID = RECIPE_LEATHER },    -- Majestic Voidstorm Lure
}

local eventFrame = CreateFrame("Frame")
local messenger = LibStub and LibStub("AceEvent-3.0", true) and LibStub("AceEvent-3.0"):Embed({}) or nil

-- Lure use (2026-10-27): using a lure casts the lure item's spell. The spell
-- ID is read from the item (C_Item.GetItemSpell) rather than hard-coded.
-- Theoretical until a lure run confirms it: each match writes a session log
-- line ("lure use seen").
local lureSpellToItem = {}   -- [spellID] = lureItemID
local lureSpellsResolved = false

local function ResolveLureSpells()
    if lureSpellsResolved then
        return
    end
    local getItemSpell = (C_Item and C_Item.GetItemSpell) or GetItemSpell
    if not getItemSpell then
        return
    end
    local missing = false
    for _, beast in pairs(BEASTS) do
        local ok, _, spellID = pcall(getItemSpell, beast.lureItemID)
        spellID = ok and tonumber(spellID) or nil
        if spellID then
            lureSpellToItem[spellID] = beast.lureItemID
        else
            -- Item not cached yet: ask again on the next cast.
            missing = true
        end
    end
    lureSpellsResolved = not missing
end

-- Session state (not saved).
local skinCastSnapshot = nil   -- { at, buffs, stats = { [recipeID] = {...} } }
local pendingKill = {}         -- [corpseGUID] = { [itemID] = qty }
local seenKillWindow = {}      -- [corpseGUID] = true
local seenSkinWindow = {}      -- [corpseGUID] = true

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

local function Debug(msg, ...)
    if PocketCFO.Debug then
        PocketCFO:Debug("BeastSkinCapture: " .. tostring(msg), ...)
    end
end

local function CaptureDB()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    globalDB.beastSkins = globalDB.beastSkins or {}
    return globalDB.beastSkins
end

local function CharacterEntry()
    local db = CaptureDB()
    local guid = UnitGUID and UnitGUID("player")
    if not db or not guid then
        return nil
    end
    local entry = db[guid]
    if not entry then
        entry = { beasts = {} }
        db[guid] = entry
    end
    entry.beasts = entry.beasts or {}
    entry.name = UnitName("player")
    entry.realm = GetRealmName and GetRealmName() or entry.realm
    return entry
end

local function BeastEntry(characterEntry, npcID)
    local beast = characterEntry.beasts[npcID]
    if not beast then
        beast = { skins = 0, killItems = {}, skinItems = {}, recent = {}, averageSkins = 0, averages = {} }
        characterEntry.beasts[npcID] = beast
    end
    return beast
end

-- Beasts saved before running averages existed get them seeded once from
-- their all-time totals (a plain average, correct while under 100 skins).
local function EnsureAverages(beast)
    if beast.averages then
        return
    end
    beast.averages = {}
    local skins = tonumber(beast.skins) or 0
    beast.averageSkins = skins
    if skins <= 0 then
        return
    end
    for itemID, qty in pairs(beast.killItems or {}) do
        beast.averages[itemID] = (beast.averages[itemID] or 0) + qty / skins
    end
    for itemID, qty in pairs(beast.skinItems or {}) do
        beast.averages[itemID] = (beast.averages[itemID] or 0) + qty / skins
    end
end

-- Folds one skin (kill + skin quantities) into the running averages.
local function UpdateAverages(beast, record)
    local thisSkin = {}
    for itemID, qty in pairs(record.kill or {}) do
        thisSkin[itemID] = (thisSkin[itemID] or 0) + (tonumber(qty) or 0)
    end
    for itemID, entry in pairs(record.skin or {}) do
        thisSkin[itemID] = (thisSkin[itemID] or 0) + (tonumber(entry.qty) or 0)
    end

    local count = (tonumber(beast.averageSkins) or 0) + 1
    local divisor = math.min(count, AVERAGE_WINDOW)

    local itemIDs = {}
    for itemID in pairs(beast.averages) do
        itemIDs[itemID] = true
    end
    for itemID in pairs(thisSkin) do
        itemIDs[itemID] = true
    end
    for itemID in pairs(itemIDs) do
        local average = beast.averages[itemID] or 0
        average = average + ((thisSkin[itemID] or 0) - average) / divisor
        beast.averages[itemID] = (average >= AVERAGE_FLOOR) and average or nil
    end
    beast.averageSkins = count
end

-- ---------------------------------------------------------------------------
-- Snapshots taken at Skinning cast start
-- ---------------------------------------------------------------------------

local function ReadBuffSpellIDs()
    local spellIDs = {}
    if not C_UnitAuras or type(C_UnitAuras.GetAuraDataByIndex) ~= "function" then
        return spellIDs
    end
    for index = 1, 80 do
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, "HELPFUL")
        if not ok or type(aura) ~= "table" then
            break
        end
        local spellID = tonumber(aura.spellId)
        if spellID then
            spellIDs[#spellIDs + 1] = spellID
        end
    end
    return spellIDs
end

local function ReadGatheringStats(recipeID)
    if not C_TradeSkillUI or type(C_TradeSkillUI.GetGatheringOperationInfo) ~= "function" then
        return nil
    end
    local ok, info = pcall(C_TradeSkillUI.GetGatheringOperationInfo, recipeID)
    if not ok or type(info) ~= "table" or type(info.bonusStats) ~= "table" then
        return nil
    end
    -- bonusStatName is localized; enUS names confirmed in-game.
    local stats = {}
    for _, stat in ipairs(info.bonusStats) do
        if stat.bonusStatName == "Finesse" then
            stats.finesse = tonumber(stat.bonusStatValue)
            stats.finessePct = tonumber(stat.ratingPct)
        elseif stat.bonusStatName == "Perception" then
            stats.perception = tonumber(stat.bonusStatValue)
            stats.perceptionPct = tonumber(stat.ratingPct)
        end
    end
    if stats.finesse or stats.perception then
        return stats
    end
    return nil
end

local function SnapshotAtSkinCastStart()
    skinCastSnapshot = {
        at = GetTime(),
        buffs = ReadBuffSpellIDs(),
        stats = {
            [RECIPE_LEATHER] = ReadGatheringStats(RECIPE_LEATHER),
            [RECIPE_SCALES] = ReadGatheringStats(RECIPE_SCALES),
        },
    }
end

-- ---------------------------------------------------------------------------
-- Loot window reading
-- ---------------------------------------------------------------------------

-- Beast slots of a loot reader window record: slots with at least one beast
-- corpse as a source:
-- { itemID, quantity, quality, beastSources = { { guid, npcID, qty } }, sourceCount }
local function BeastSlots(window)
    local slots = {}
    for _, slot in ipairs(window.slots or {}) do
        if slot.itemID then
            local beastSources = {}
            local sources = slot.sources or {}
            for _, source in ipairs(sources) do
                if (source.type == "Creature" or source.type == "Vehicle") and source.id and BEASTS[source.id] then
                    beastSources[#beastSources + 1] = { guid = source.guid, npcID = source.id, qty = tonumber(source.qty) or 0 }
                end
            end
            if #beastSources > 0 then
                slots[#slots + 1] = {
                    itemID = slot.itemID,
                    quantity = tonumber(slot.quantity) or 0,
                    quality = tonumber(slot.quality),
                    beastSources = beastSources,
                    sourceCount = #sources,
                }
            end
        end
    end
    return slots
end

-- Groups a window's beast slots by corpse GUID.
local function GroupByCorpse(slots)
    local corpses = {}
    for _, slot in ipairs(slots) do
        for _, source in ipairs(slot.beastSources) do
            local corpse = corpses[source.guid]
            if not corpse then
                corpse = { npcID = source.npcID, items = {} }
                corpses[source.guid] = corpse
            end
            corpse.items[#corpse.items + 1] = {
                itemID = slot.itemID,
                quality = slot.quality,
                -- Base amount from this corpse.
                base = source.qty,
                -- Amount received: slot quantity when this corpse is the
                -- slot's only source (skin windows); otherwise the
                -- corpse's own share.
                received = (slot.sourceCount == 1) and slot.quantity or source.qty,
            }
        end
    end
    return corpses
end

-- ---------------------------------------------------------------------------
-- Commit
-- ---------------------------------------------------------------------------

local function HandleKillWindow(corpses)
    for guid, corpse in pairs(corpses) do
        if not seenKillWindow[guid] then
            seenKillWindow[guid] = true
            local items = {}
            for _, item in ipairs(corpse.items) do
                items[item.itemID] = (items[item.itemID] or 0) + item.received
            end
            pendingKill[guid] = items
            Debug("kill loot held for %s (%s)", BEASTS[corpse.npcID].name, tostring(guid))
        end
    end
end

-- Adds one skin record to a character's totals and recent list.
-- record = { at, kill = { [itemID] = qty }, skin = { [itemID] = { qty, base } }, stats, buffs }
local function ApplyRecord(characterEntry, npcID, record)
    local beast = BeastEntry(characterEntry, npcID)
    EnsureAverages(beast)
    UpdateAverages(beast, record)

    beast.skins = (beast.skins or 0) + 1
    for itemID, qty in pairs(record.kill or {}) do
        beast.killItems[itemID] = (beast.killItems[itemID] or 0) + qty
    end
    for itemID, entry in pairs(record.skin or {}) do
        beast.skinItems[itemID] = (beast.skinItems[itemID] or 0) + entry.qty
    end

    beast.recent[#beast.recent + 1] = record
    while #beast.recent > RECENT_LIMIT do
        table.remove(beast.recent, 1)
    end
    return beast
end

local function CommitSkin(guid, corpse)
    local beastInfo = BEASTS[corpse.npcID]

    local allPoor = true
    for _, item in ipairs(corpse.items) do
        if item.quality ~= POOR_QUALITY then
            allPoor = false
            break
        end
    end
    if allPoor then
        pendingKill[guid] = nil
        Debug("repeat skin of %s discarded (gray only)", beastInfo.name)
        return
    end

    local characterEntry = CharacterEntry()
    if not characterEntry then
        return
    end

    local kill = pendingKill[guid] or {}
    pendingKill[guid] = nil

    local skin = {}
    for _, item in ipairs(corpse.items) do
        local existing = skin[item.itemID]
        if existing then
            existing.qty = existing.qty + item.received
            existing.base = existing.base + item.base
        else
            skin[item.itemID] = { qty = item.received, base = item.base }
        end
    end

    local snapshot = skinCastSnapshot
    local record = {
        at = Now(),
        kill = kill,
        skin = skin,
        stats = snapshot and snapshot.stats and snapshot.stats[beastInfo.statRecipeID] or nil,
        buffs = snapshot and snapshot.buffs or {},
    }
    local beast = ApplyRecord(characterEntry, corpse.npcID, record)

    -- Gold per Hour: adds this beast's kill loot (and, until lure use has been
    -- seen, the lure) to the beast run (ActivityRuns, 2026-10-26 / 10-27).
    local activityRuns = PocketCFO:GetModule("ActivityRuns", true)
    if activityRuns then
        activityRuns:AddBeastExtras(corpse.npcID, kill, beastInfo.lureItemID)
    end

    Debug("skin of %s saved (skins=%d)", beastInfo.name, beast.skins)
end

local function HandleSkinWindow(corpses)
    for guid, corpse in pairs(corpses) do
        if not seenSkinWindow[guid] then
            seenSkinWindow[guid] = true
            CommitSkin(guid, corpse)
        end
    end
end

function BeastSkinCapture:OnLootWindow(window)
    if type(window) ~= "table" then
        return
    end
    local slots = BeastSlots(window)
    if #slots == 0 then
        return
    end
    local corpses = GroupByCorpse(slots)
    if window.cast and window.cast.spellID == SKINNING_SPELL_ID then
        HandleSkinWindow(corpses)
    else
        HandleKillWindow(corpses)
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "UNIT_SPELLCAST_START" then
        local unit, _, spellID = ...
        if unit == "player" and spellID == SKINNING_SPELL_ID then
            SnapshotAtSkinCastStart()
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and spellID and spellID ~= SKINNING_SPELL_ID then
            ResolveLureSpells()
            local lureItemID = lureSpellToItem[spellID]
            if lureItemID then
                PocketCFO:AppendSessionLog(string.format(
                    "[MCG] BeastSkinCapture: lure use seen spellID=%d lure=%d", spellID, lureItemID))
                local activityRuns = PocketCFO:GetModule("ActivityRuns", true)
                if activityRuns and activityRuns.AddLureUse then
                    activityRuns:AddLureUse(lureItemID)
                end
            end
        end
    end
end)

if messenger then
    messenger:RegisterMessage("MCG_LOOT_WINDOW", function(_, window)
        BeastSkinCapture:OnLootWindow(window)
    end)
end

function BeastSkinCapture:OnEnable()
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
end

-- ---------------------------------------------------------------------------
-- Read API (for the Phase 2 analysis panel and diagnostics)
-- ---------------------------------------------------------------------------

-- npcID -> { name, lureItemID, statRecipeID }. Treat as read-only.
function BeastSkinCapture:GetBeasts()
    return BEASTS
end

function BeastSkinCapture:GetBeastByLureItemID(lureItemID)
    lureItemID = tonumber(lureItemID)
    for npcID, beast in pairs(BEASTS) do
        if beast.lureItemID == lureItemID then
            return npcID, beast
        end
    end
    return nil
end

-- Running average per skin for one beast (current character by default).
-- @return { skins = n, items = { [itemID] = averageQty } }; skins = 0 when none.
function BeastSkinCapture:GetAverage(npcID, characterGUID)
    local data = self:GetCharacterData(characterGUID)
    local beast = data and data.beasts and data.beasts[tonumber(npcID)]
    if not beast then
        return { skins = 0, items = {} }
    end
    EnsureAverages(beast)
    return { skins = tonumber(beast.averageSkins) or 0, items = beast.averages }
end

-- Saved data for one character (defaults to the current one), or nil.
function BeastSkinCapture:GetCharacterData(characterGUID)
    local db = CaptureDB()
    characterGUID = characterGUID or (UnitGUID and UnitGUID("player"))
    return db and characterGUID and db[characterGUID] or nil
end
