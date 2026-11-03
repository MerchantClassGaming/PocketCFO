-- PocketCFO/Services/GatheringCapture/GatheringCapture.lua
-- Gathering tracker, capture side (core). Records what every gathering loot
-- window gave (herbs, ore, skins, plus motes, gems and other extras in the same
-- window), valued at the moment it was looted, as daily totals, and feeds each
-- window to ActivityRuns (automatic runs for gold per hour).
-- Display lives in PocketCFO_PnL (Gathering tab of the Gold window, Gold per
-- Hour window).
--
-- What counts as a gathering window (decided with Brian 2026-10-23):
--   A loot window that opens within GATHER_CAST_TO_LOOT_SECONDS of a
--   successful cast of a known gathering spell (GATHER_SPELLS). Only slots
--   whose loot source matches the gather type are counted: a GameObject for
--   herb/mining nodes, a corpse (Creature/Vehicle) for skinning.
--   Confirmed in-game 2026-10-23 (/mcgd loot): node loot sources are
--   "GameObject-..." GUIDs, and the gathering cast succeeds 0.0s before
--   LOOT_READY. A GameObject source alone is not enough: chests and other
--   "Opening" casts (3365, 6477) also loot from GameObjects.
--   Gathering casts not in GATHER_SPELLS (older-expansion nodes, WoW Forever)
--   are not guessed: GameObject windows after an unknown cast, and creature
--   windows opening within MISS_CREATURE_CAST_SECONDS of an unknown cast
--   (gather casts finish 0.0-0.1s before the loot; kill loot comes 1s+ after
--   the last attack), are written to the miss log (/mcg gatherlog) so the
--   spell can be added.
--   Mining and herbing creatures (Rumbling Orelings, plant mobs at powered-up
--   nodes) use their own spells with a corpse loot source: 32606 Mining and
--   32605 Herb Gathering, confirmed in-game 2026-10-26 (/mcgd loot).
--   Great beast skins count too (their analysis keeps its own data in
--   BeastSkinCapture). Fishing and disenchanting are not gathering.
--   Lumber (Woodchopping, housing) is captured but HIDDEN (Brian 2026-10-26):
--   lumber is bind on pickup with no value yet, so it is kept only in the
--   daily rows under the "lumber" key, never fed to runs (Gold per Hour), and
--   left out of every display (IsHiddenProfession) until a value is designed.
--
-- Value: each item is valued when looted (ActivityRuns:GetUnitValue, same
-- answer as the tooltip). Items with no price yet keep their quantity and are
-- valued at display time. This is item value, never gold: not part of Income.
-- Profession comes from the gathering spell, not from each item (a mote from
-- an herb node counts as Herbalism).
--
-- Storage: PocketCFO_DB.global.gathering
--   days[dayKey][characterGUID][professionKey] = {
--     nodes = n,                -- gathering windows counted
--     castSeconds, casts,       -- gather cast time totals
--     buffs = { [spellID] = { loots, base, bonus, castSeconds, casts } },
--     nodeTypes = { [nodeName] = { recipeID, loots, base, bonus, rareBase, rareBonus,
--                   statLoots, finesse, perception, deftness } },  -- see ActivityRuns
--     copper = c,               -- value locked in at loot time
--     items = { [itemID] = { qty, valuedQty, copper, link, base, bonus, procs } },
--   }
--   missLog = { { at, character, spellID, spellName, slots } }  -- newest first
--   recipeByName = { [recipe name] = recipeID }   -- gathering recipes, all professions
-- dayKey is the local date "YYYY-MM-DD". professionKey is the base profession
-- skill line ID as a string ("182" Herbalism, "186" Mining, "393" Skinning),
-- same keys as GoldLedger.
--
-- Cast time (capture only, for later speed analysis, 2026-10-26): seconds
-- from UNIT_SPELLCAST_START to UNIT_SPELLCAST_SUCCEEDED of the gather spell,
-- added to the day row (castSeconds, casts) and the run (ActivityRuns).
-- Theoretical: that START/SUCCEEDED timing equals the gather cast time.
--
-- Bonus amounts (capture only, 2026-10-26): each slot's base = what the
-- matching loot source gave (GetLootSourceInfo), confirmed in-game for nodes
-- and creatures; received - base = Finesse / Perception bonus. Kept per item
-- (base, bonus, procs). Buffs active at gather cast start are kept per
-- profession (buffs[spellID] = { loots, base, bonus, castSeconds, casts }).
-- Fields and helpers are shared with ActivityRuns (AddItemTo, AddBuffStatsTo).
--
-- Node type and gathering stats (capture only, 2026-10-26):
--   - Every node type has its own gathering recipe with its own Finesse,
--     Perception and Deftness (confirmed in-game, /mcg gatherrecipes).
--   - UNIT_SPELLCAST_SENT arg2 is the node's name, matching the recipe name
--     ("Lush Tranquility Bloom", "Rich Refulgent Copper"); for creature
--     gathering it is the creature's name, which has no recipe (confirmed
--     in-game 2026-10-26).
--   - Opening a gathering profession window saves its gathering recipes by
--     name (recipeByName, account-wide: recipe IDs are the same for everyone).
--   - At loot: node name -> recipe -> GetGatheringOperationInfo for the
--     player's current %s (works with the window closed, confirmed for
--     skinning). Unknown node names are saved without stats. Nothing guessed.
--   - Stat names are read in English ("Finesse", "Perception", "Deftness"),
--     same as BeastSkinCapture (Theoretical on other client languages).
--
-- Procs (2026-10-26): DISPLAY_EVENT_TOAST_LINK arg1 "Your Finesse helps you
-- gather something extra:" (confirmed in-game) or the same text with
-- Perception (wording confirmed by Brian). It fires as the item is taken: in a
-- one-item window that is after LOOT_CLOSED (after Record); in a multi-item
-- window it can come BEFORE LOOT_CLOSED (confirmed in-game 2026-10-26, Rich
-- Brilliant Silver). So a toast while a gathering window is open is held on
-- that window and applied in Record; otherwise it goes to the last gather
-- recorded within PROC_TOAST_SECONDS. Credited to the day row and run node
-- type and the stat band at that loot. Text matching is English
-- (Theoretical on other client languages).
--
-- Messages: MCG_GATHERING_UPDATED (new loot recorded).
--
-- A plain event frame is used for game events instead of AceEvent because
-- CraftSim's bundled AceEvent can dispatch PocketCFO callbacks with shifted
-- arguments (same as BeastSkinCapture).
--
-- Loot reading (migrated to the loot reader 2026-10-30, claude/
-- Ledger_Rebuild_Checklist.md item 6): this module no longer reads loot
-- windows or tracks casts itself. It handles MCG_LOOT_WINDOW from LootReader:
--   - gathering: window.cast.spellID in LootReader.GATHER_SPELLS (the one
--     spell list, moved there from here); cast time and node / creature name
--     come from window.cast (castSeconds, target).
--   - fishing: window.context == "fishing" (LootReader decides: IsFishingLoot,
--     or a fished-up chest, whose rule moved to LootReader 2026-10-30).
--   - miss log: any other cast with a GameObject source, or a creature source
--     with the cast within MISS_CREATURE_CAST_SECONDS (window.cast.secondsBefore).
-- Kept here (not loot): buffs at gather cast start (UNIT_SPELLCAST_START),
-- Finesse / Perception toasts (held on the open window via
-- LootReader:GetOpenWindow, applied when that window's record arrives),
-- chest chat lines, gathering recipe scan.
--
-- Theoretical: WoW Forever gathering spell IDs and loot source GUID format.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local GatheringCapture = PocketCFO:NewModule("GatheringCapture", "AceEvent-3.0")
PocketCFO.GatheringCapture = GatheringCapture

local GATHER_CAST_TO_LOOT_SECONDS = 3
local MISS_LOG_SIZE = 30
local MISS_CREATURE_CAST_SECONDS = 0.5
local MAX_CAST_SECONDS = 10
local GATHERING_PROFESSIONS = { [182] = true, [186] = true, [393] = true }
local RECIPE_SCAN_DELAY = 1
local PROC_TOAST_SECONDS = 3

-- Gathering spell -> profession and loot source type: the one list lives in
-- LootReader (loaded before this file in both TOCs).
local GATHER_SPELLS = (PocketCFO.LootReader and PocketCFO.LootReader.GATHER_SPELLS) or {}

-- Fishing (confirmed in-game 2026-10-26, /mcgd loot): cast 131474, channel
-- 131476, bobber click is Opening (3365, same as chests). Loot comes 8-15s
-- after the cast, from a GameObject (the bobber), and IsFishingLoot() is true.
-- So a fishing window is recognized by IsFishingLoot, not by the cast.
-- No target name is sent, so there is no node type (pools look the same).
-- Slot qty can rise after the first LOOT_READY (1 -> 2 seen); the latest
-- reading is kept, same as gathering.
local FISHING = { profession = "fishing", source = "node", activity = "fishing" }

-- Fished-up chests: the rule and the chest list live in LootReader
-- (FISHING_CHESTS, since 2026-10-30); a chest window arrives as context
-- "fishing". New chest IDs show up in the miss log (/mcg gatherlog) with the
-- chat line, GUID and name, to be added to LootReader.FISHING_CHESTS.

-- Captured but not shown anywhere yet (no value): profession key -> true.
local HIDDEN_PROFESSIONS = { lumber = true }

local eventFrame = CreateFrame("Frame")
local messenger = LibStub and LibStub("AceEvent-3.0", true) and LibStub("AceEvent-3.0"):Embed({}) or nil

-- Session state (not saved).
local gatherCastStart = nil  -- { spellID, at, buffs } gather cast in progress
local heldProcs = {}         -- [loot reader window id] = { statName, ... } toasts before the window closed
local scannedProfessions = {} -- [professionID] = true once this session
local lastRecorded = nil      -- { at, stats, entries = { node type entries } } for proc toasts
-- Proc toast diagnostics (this session, shown in /mcg gatherlog): why procs
-- read 0 in-game on 2026-10-26 although bonuses happened.
local toastStats = { registered = false, seen = 0, matched = 0, held = 0, credited = 0, tooLate = 0, lastText = nil }
-- Fishing chest capture (2026-10-26): in Midnight a fished-up chest appears at
-- the player's feet and is opened by clicking it (Opening); a chat line says it
-- was fished up (Brian, wording and event unknown). The last chat/toast line
-- mentioning a chest, treasure or fishing is kept and saved on miss log
-- entries, with IsFishingLoot, the GameObject GUID, the cast's target name
-- and the items, to decide how to count chest contents as fishing.
local CHEST_CHAT_EVENTS = {
    "CHAT_MSG_SYSTEM", "CHAT_MSG_LOOT", "CHAT_MSG_OPENING", "CHAT_MSG_MONSTER_EMOTE",
    "CHAT_MSG_RAID_BOSS_EMOTE", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE", "CHAT_MSG_SKILL",
}
local CHEST_CHAT_SECONDS = 300
local lastChestChat = nil    -- { event, text, at }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function SessionLog(msg, ...)
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] GatheringCapture: " .. tostring(msg))
end

local function DayKey(timestamp)
    return date("%Y-%m-%d", timestamp or time())
end

local function GatherDB()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    local db = globalDB.gathering or {}
    globalDB.gathering = db
    db.days = db.days or {}
    db.missLog = db.missLog or {}
    db.recipeByName = db.recipeByName or {}
    -- Manual sessions were replaced by ActivityRuns (2026-10-24): clear their
    -- test data. Safe to delete this line after the next login.
    db.active, db.sessions, db.framePos = nil, nil, nil
    return db
end

local function PlayerGUID()
    return UnitGUID and UnitGUID("player") or nil
end

local function Runs()
    return PocketCFO:GetModule("ActivityRuns", true)
end

local function SourceMatches(sourceKind, guidType)
    if sourceKind == "node" then
        return guidType == "GameObject"
    end
    return guidType == "Creature" or guidType == "Vehicle"
end

-- True when a creature GUID is one of the great beasts (BeastSkinCapture's
-- list). Used to tag a skin window as a beast skin for activity runs
-- (2026-10-27).
local function IsBeastGUID(guid)
    local beastCapture = PocketCFO:GetModule("BeastSkinCapture", true)
    if not beastCapture or type(guid) ~= "string" then
        return false
    end
    local parts = { strsplit("-", guid) }
    local npcID = tonumber(parts[6])
    return npcID ~= nil and beastCapture:GetBeasts()[npcID] ~= nil
end

local function SpellName(spellID)
    if C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
        if ok and type(info) == "table" then
            return info.name
        end
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellID)
        if ok then
            return name
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

-- Player's current Finesse / Perception / Deftness % on a gathering recipe,
-- or nil. Stat names are English (same as BeastSkinCapture).
local function ReadNodeStats(recipeID)
    if not recipeID or not C_TradeSkillUI or type(C_TradeSkillUI.GetGatheringOperationInfo) ~= "function" then
        return nil
    end
    local ok, info = pcall(C_TradeSkillUI.GetGatheringOperationInfo, recipeID)
    if not ok or type(info) ~= "table" or type(info.bonusStats) ~= "table" then
        return nil
    end
    local stats = {}
    for _, stat in ipairs(info.bonusStats) do
        local pct = tonumber(stat.ratingPct)
        if stat.bonusStatName == "Finesse" then
            stats.finesse = pct
        elseif stat.bonusStatName == "Perception" then
            stats.perception = pct
        elseif stat.bonusStatName == "Deftness" then
            stats.deftness = pct
        end
    end
    if stats.finesse or stats.perception or stats.deftness then
        return stats
    end
    return nil
end

-- Saves the open profession's gathering recipes by name (once per
-- profession per session). Only for gathering professions.
local function ScanGatheringRecipes()
    if not C_TradeSkillUI or type(C_TradeSkillUI.GetBaseProfessionInfo) ~= "function" then
        return
    end
    local okBase, base = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    local professionID = okBase and type(base) == "table" and tonumber(base.professionID) or nil
    if not professionID or not GATHERING_PROFESSIONS[professionID] or scannedProfessions[professionID] then
        return
    end
    local db = GatherDB()
    local okIDs, recipeIDs = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not db or not okIDs or type(recipeIDs) ~= "table" or #recipeIDs == 0 then
        return
    end
    local found = 0
    for _, recipeID in ipairs(recipeIDs) do
        local okInfo, info = pcall(C_TradeSkillUI.GetGatheringOperationInfo, recipeID)
        if okInfo and type(info) == "table" then
            local okRecipe, recipe = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
            local name = okRecipe and type(recipe) == "table" and recipe.name or nil
            if name and name ~= "" then
                db.recipeByName[name] = recipeID
                found = found + 1
            end
        end
    end
    if found > 0 then
        scannedProfessions[professionID] = true
        SessionLog("saved %d gathering recipes for profession %d", found, professionID)
    end
end

-- Node type for a gather: { name, recipeID, stats } or nil when no name.
local function ResolveNode(target)
    if type(target) ~= "string" or target == "" then
        return nil
    end
    local db = GatherDB()
    local recipeID = db and db.recipeByName[target] or nil
    return { name = target, recipeID = recipeID, stats = recipeID and ReadNodeStats(recipeID) or nil }
end

-- Helpful buff spellIDs on the player (same read as BeastSkinCapture).
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

function GatheringCapture:Record(gather, slots, castSeconds, buffs, target, procs, beastSkin)
    local db = GatherDB()
    local guid = PlayerGUID()
    local runs = Runs()
    if not db or not guid or #slots == 0 then
        return
    end
    local professionKey = gather.profession
    local AddItem = runs and runs.AddItemTo
    local AddBuffStats = runs and runs.AddBuffStatsTo
    local AddNodeStats = runs and runs.AddNodeStatsTo
    if not AddItem then
        return
    end

    local windowCopper = 0
    for _, slot in ipairs(slots) do
        slot.unitValue = runs and runs:GetUnitValue(slot.itemID, slot.link, slot.quality) or nil
        if slot.unitValue then
            windowCopper = windowCopper + slot.unitValue * slot.qty
        end
    end

    local dayKey = DayKey()
    local day = db.days[dayKey] or {}
    db.days[dayKey] = day
    local character = day[guid] or {}
    day[guid] = character
    local row = character[professionKey] or { nodes = 0, copper = 0, items = {} }
    character[professionKey] = row
    row.nodes = row.nodes + 1
    row.copper = row.copper + windowCopper
    if castSeconds then
        row.castSeconds = (row.castSeconds or 0) + castSeconds
        row.casts = (row.casts or 0) + 1
    end
    AddBuffStats(row, buffs, slots, castSeconds)
    local node = ResolveNode(target)
    local dayEntry = AddNodeStats(row, node, slots, castSeconds)
    for _, slot in ipairs(slots) do
        AddItem(row.items, slot)
    end

    local runEntry = nil
    if runs and not gather.hidden then
        runEntry = runs:AddLoot("gathering", professionKey, slots, windowCopper,
            { castSeconds = castSeconds, buffs = buffs, node = node, activity = gather.activity,
              beastSkin = beastSkin or nil })
    end
    -- Base-mat bonus of this gather (for the Finesse proc spread).
    local baseBonus = 0
    for _, slot in ipairs(slots) do
        if slot.base and (tonumber(slot.quality) or 0) < 3 then
            baseBonus = baseBonus + math.max(0, slot.qty - slot.base)
        end
    end
    local record = { at = GetTime(), stats = node and node.stats or nil, entries = { dayEntry, runEntry },
        finesseProcs = 0, bonus = baseBonus }
    lastRecorded = record
    -- Procs whose toast came before the window closed.
    for _, statName in ipairs(procs or {}) do
        self:CreditProc(statName, true)
    end
    -- Close out this gather's Finesse proc count once its toasts are in.
    if node and C_Timer and C_Timer.After then
        C_Timer.After(PROC_TOAST_SECONDS + 0.5, function()
            local addSpread = runs and runs.AddProcSpreadTo
            if addSpread then
                for _, entry in pairs(record.entries) do
                    addSpread(entry, record.stats, record.finesseProcs, record.bonus)
                end
            end
        end)
    end

    SessionLog("profession=%s slots=%d value=%d", professionKey, #slots, windowCopper)
    self:SendMessage("MCG_GATHERING_UPDATED")
end

function GatheringCapture:LogMiss(window)
    local db = GatherDB()
    if not db then
        return
    end
    local items = {}
    for slot = 1, 10 do
        if window.missItems and window.missItems[slot] then
            items[#items + 1] = window.missItems[slot]
        end
    end
    local chat = nil
    if lastChestChat and (GetTime() - lastChestChat.at) <= CHEST_CHAT_SECONDS then
        chat = { event = lastChestChat.event, text = lastChestChat.text,
            ago = math.floor((GetTime() - lastChestChat.at) * 10 + 0.5) / 10 }
    end
    table.insert(db.missLog, 1, {
        at = time(),
        character = UnitName and UnitName("player") or "?",
        spellID = window.spellID,
        spellName = window.spellID and SpellName(window.spellID) or nil,
        slots = window.slotCount or 0,
        target = window.castTarget,
        objectGUID = window.objectGUID,
        fishingLoot = window.fishingLoot,
        items = #items > 0 and table.concat(items, ", ") or nil,
        chat = chat,
    })
    while #db.missLog > MISS_LOG_SIZE do
        table.remove(db.missLog)
    end
end

-- ---------------------------------------------------------------------------
-- Loot reader windows (2026-10-30; see header)
-- ---------------------------------------------------------------------------

-- Keeps a chat/toast line if it mentions a chest, treasure or fishing.
local function NoteChestChat(event, text)
    if type(text) ~= "string" then
        return
    end
    local ok, lower = pcall(string.lower, text)
    if not ok or type(lower) ~= "string" then
        return
    end
    if lower:find("chest", 1, true) or lower:find("treasure", 1, true) or lower:find("fish", 1, true) then
        lastChestChat = { event = event, text = text, at = GetTime() }
    end
end

-- What a loot reader window is for this module: { gather, spellID,
-- castSeconds, buffs, target } or nil when it isn't gathering / fishing.
local function GatherFor(window)
    local cast = window.cast
    if window.context == "fishing" then
        return { gather = FISHING, buffs = ReadBuffSpellIDs(),
            target = window.fishingChest and cast and cast.target or nil }
    elseif cast and GATHER_SPELLS[cast.spellID] then
        local info = { gather = GATHER_SPELLS[cast.spellID], spellID = cast.spellID,
            castSeconds = cast.castSeconds, target = cast.target }
        if gatherCastStart and gatherCastStart.spellID == cast.spellID
            and (GetTime() - gatherCastStart.at) <= MAX_CAST_SECONDS + GATHER_CAST_TO_LOOT_SECONDS then
            info.buffs = gatherCastStart.buffs
        end
        gatherCastStart = nil
        return info
    end
    return nil
end

-- Slots whose source matches the gather type: { itemID, link, qty, base,
-- quality }. Also flags a great beast corpse (skin window).
local function GatherSlots(window, gather)
    local slots, beastCorpse = {}, false
    for _, slot in ipairs(window.slots or {}) do
        local quantity = tonumber(slot.quantity) or 0
        if slot.itemID and quantity > 0 then
            local matches, base = false, 0
            for _, source in ipairs(slot.sources or {}) do
                if SourceMatches(gather.source, source.type) then
                    matches = true
                    base = base + (tonumber(source.qty) or 0)
                    if gather.source == "corpse" and IsBeastGUID(source.guid) then
                        beastCorpse = true
                    end
                end
            end
            if matches then
                slots[#slots + 1] = { itemID = slot.itemID, link = slot.link, qty = quantity, base = base,
                    quality = tonumber(slot.quality) }
            end
        end
    end
    return slots, beastCorpse
end

-- A window after a cast we don't know that looted from a GameObject (chest,
-- or a node gathering spell missing from GATHER_SPELLS), or from a creature
-- right as the cast finished (a creature-gathering spell missing). Same rule
-- as before the migration.
local function MissWindow(window)
    local cast = window.cast
    local types = window.sourceTypes or {}
    if not cast then
        return nil
    end
    if not (types.GameObject or ((types.Creature or types.Vehicle)
        and (tonumber(cast.secondsBefore) or 99) <= MISS_CREATURE_CAST_SECONDS)) then
        return nil
    end
    local miss = { spellID = cast.spellID, castTarget = cast.target, fishingLoot = window.fishing,
        slotCount = #(window.slots or {}), missItems = {} }
    for index, slot in ipairs(window.slots or {}) do
        for _, source in ipairs(slot.sources or {}) do
            if source.type == "GameObject" then
                miss.objectGUID = miss.objectGUID or source.guid
            end
        end
        local quantity = tonumber(slot.quantity) or 0
        if index <= 10 and quantity > 0 and (slot.link or slot.name) then
            miss.missItems[index] = string.format("%s x%d", tostring(slot.link or slot.name), quantity)
        end
    end
    return miss
end

function GatheringCapture:OnLootWindow(window)
    if type(window) ~= "table" then
        return
    end
    local procs = window.id and heldProcs[window.id] or nil
    if window.id then
        heldProcs[window.id] = nil
    end
    local info = GatherFor(window)
    if info then
        local slots, beastCorpse = GatherSlots(window, info.gather)
        if #slots > 0 then
            -- Beast skin: a great beast's corpse with at least one non-gray
            -- item (all gray = repeat skin, same rule as BeastSkinCapture).
            local beastSkin = false
            if beastCorpse then
                for _, slot in ipairs(slots) do
                    if (tonumber(slot.quality) or 0) > 0 then
                        beastSkin = true
                        break
                    end
                end
            end
            self:Record(info.gather, slots, info.castSeconds, info.buffs, info.target, procs, beastSkin)
        end
        return
    end
    local miss = MissWindow(window)
    if miss then
        self:LogMiss(miss)
    end
end

-- True when the loot reader's open window is a gathering / fishing window
-- (proc toasts are held for it).
local function OpenGatherWindow()
    local lootReader = PocketCFO.LootReader
    local window = lootReader and lootReader.GetOpenWindow and lootReader:GetOpenWindow() or nil
    if not window then
        return nil
    end
    if window.fishing or (window.cast and GATHER_SPELLS[window.cast.spellID])
        or (window.objectID and lootReader.FISHING_CHESTS and lootReader.FISHING_CHESTS[window.objectID]) then
        return window
    end
    return nil
end

-- A Finesse / Perception proc toast. While a gathering loot window is open it
-- is held for that window (by the loot reader's window id; applied when its
-- record arrives at LOOT_CLOSED); otherwise it is credited to the last gather
-- recorded within PROC_TOAST_SECONDS.
function GatheringCapture:CreditProc(statName, fromRecord)
    local openWindow = not fromRecord and OpenGatherWindow() or nil
    if openWindow and openWindow.id then
        local held = heldProcs[openWindow.id] or {}
        held[#held + 1] = statName
        heldProcs[openWindow.id] = held
        toastStats.held = toastStats.held + 1
        return
    end
    local runs = Runs()
    if not lastRecorded or (GetTime() - lastRecorded.at) > PROC_TOAST_SECONDS or not runs or not runs.AddProcTo then
        toastStats.tooLate = toastStats.tooLate + 1
        return
    end
    for _, entry in pairs(lastRecorded.entries) do
        runs.AddProcTo(entry, statName, lastRecorded.stats)
    end
    if statName == "finesse" then
        lastRecorded.finesseProcs = lastRecorded.finesseProcs + 1
    end
    toastStats.credited = toastStats.credited + 1
    SessionLog("%s proc", statName)
end

-- ---------------------------------------------------------------------------
-- Read API (PocketCFO_PnL). Callers must not modify the returned tables.
-- ---------------------------------------------------------------------------

-- True for profession keys that are captured but not displayed yet (lumber).
function GatheringCapture:IsHiddenProfession(professionKey)
    return HIDDEN_PROFESSIONS[professionKey] == true
end

-- days[dayKey][characterGUID][professionKey] = { nodes, copper, items }
-- Includes hidden professions: displays must skip IsHiddenProfession keys.
function GatheringCapture:GetDays()
    local db = GatherDB()
    return db and db.days or {}
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "DISPLAY_EVENT_TOAST_LINK" then
        local text = ...
        NoteChestChat(event, text)
        toastStats.seen = toastStats.seen + 1
        toastStats.lastText = text
        if type(text) == "string" then
            local statName = nil
            if text:find("Finesse", 1, true) then
                statName = "finesse"
            elseif text:find("Perception", 1, true) then
                statName = "perception"
            end
            if statName then
                toastStats.matched = toastStats.matched + 1
                GatheringCapture:CreditProc(statName)
            end
        end
    elseif event == "TRADE_SKILL_SHOW" then
        C_Timer.After(RECIPE_SCAN_DELAY, ScanGatheringRecipes)
    elseif event == "TRADE_SKILL_LIST_UPDATE" then
        ScanGatheringRecipes()
    elseif event == "UNIT_SPELLCAST_START" then
        local unit, _, spellID = ...
        if unit == "player" and spellID and GATHER_SPELLS[spellID] then
            gatherCastStart = { spellID = spellID, at = GetTime(), buffs = ReadBuffSpellIDs() }
        end
    elseif event:find("^CHAT_MSG_") then
        NoteChestChat(event, (...))
    end
end)

if messenger then
    messenger:RegisterMessage("MCG_LOOT_WINDOW", function(_, window)
        GatheringCapture:OnLootWindow(window)
    end)
end

function GatheringCapture:OnEnable()
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
    eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
    toastStats.registered = pcall(eventFrame.RegisterEvent, eventFrame, "DISPLAY_EVENT_TOAST_LINK") and true or false
    eventFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
    for _, chatEvent in ipairs(CHEST_CHAT_EVENTS) do
        pcall(eventFrame.RegisterEvent, eventFrame, chatEvent)
    end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local function FormatCopper(copper)
    copper = math.floor(tonumber(copper) or 0)
    return string.format("%dg%02ds%02dc", math.floor(copper / 10000),
        math.floor((copper % 10000) / 100), copper % 100)
end

local diagnostics = PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    -- /mcg gatherlog: today's gathering per character/profession, runs in
    -- progress, and GameObject loot after casts that are not known gathering
    -- spells (saved, works with debug off).
    diagnostics:RegisterCommand("gatherlog", {
        name = "gatherlog",
        description = "Show today's gathering capture, runs in progress, and loot from unrecognized casts.",
        usage = "/mcg gatherlog",
        category = "General",
    }, function()
        local db = GatherDB()
        local characters = PocketCFO.db.global.gold and PocketCFO.db.global.gold.characters or {}
        local lines = { "=== Today (" .. DayKey() .. ") ===" }
        local day = db and db.days[DayKey()] or {}
        for guid, professions in pairs(day) do
            local who = characters[guid] and characters[guid].name or guid
            for professionKey, row in pairs(professions) do
                local avgCast = (row.casts or 0) > 0 and string.format("%.2fs", row.castSeconds / row.casts) or "-"
                lines[#lines + 1] = string.format("  %s  profession=%s  windows=%d  locked=%s  avgCast=%s",
                    tostring(who), professionKey, row.nodes or 0, FormatCopper(row.copper), avgCast)
                for itemID, entry in pairs(row.items or {}) do
                    lines[#lines + 1] = string.format("      %d  %s  qty=%d valuedQty=%d  %s  base=%d bonus=%d procs=%d",
                        itemID, tostring(entry.link), entry.qty or 0, entry.valuedQty or 0, FormatCopper(entry.copper),
                        entry.base or 0, entry.bonus or 0, entry.procs or 0)
                end
                for spellID, stats in pairs(row.buffs or {}) do
                    lines[#lines + 1] = string.format("      buff %d %s  loots=%d base=%d bonus=%d avgCast=%s",
                        spellID, tostring(SpellName(spellID)), stats.loots or 0, stats.base or 0, stats.bonus or 0,
                        (stats.casts or 0) > 0 and string.format("%.2fs", stats.castSeconds / stats.casts) or "-")
                end
                for nodeName, node in pairs(row.nodeTypes or {}) do
                    local avg = function(sum)
                        return (node.statLoots or 0) > 0 and string.format("%.1f%%", sum / node.statLoots) or "-"
                    end
                    lines[#lines + 1] = string.format(
                        "      node %s  recipe=%s loots=%d base=%d bonus=%d rareBase=%d rareBonus=%d finesse=%s perception=%s deftness=%s procs F=%d P=%d",
                        tostring(nodeName), tostring(node.recipeID or "-"), node.loots or 0, node.base or 0, node.bonus or 0,
                        node.rareBase or 0, node.rareBonus or 0, avg(node.finesse or 0), avg(node.perception or 0),
                        avg(node.deftness or 0), node.finesseProcs or 0, node.perceptionProcs or 0)
                    -- Gathers by Finesse proc count: k=loots/bonus.
                    for band, spread in pairs(node.finesseSpread or {}) do
                        local parts = {}
                        for k = 0, 3 do
                            local cell = spread[k]
                            if cell then
                                parts[#parts + 1] = string.format("%s=%d/%d", k == 3 and "3+" or tostring(k),
                                    cell.loots, cell.bonus)
                            end
                        end
                        lines[#lines + 1] = string.format("        F band %s  procs loots/bonus: %s",
                            tostring(band), table.concat(parts, "  "))
                    end
                end
            end
        end
        if #lines == 1 then
            lines[#lines + 1] = "  (nothing yet)"
        end
        local recipeCount = 0
        for _ in pairs(db and db.recipeByName or {}) do
            recipeCount = recipeCount + 1
        end
        lines[#lines + 1] = string.format("  Gathering recipes known: %d (open a gathering profession window to add more)", recipeCount)

        lines[#lines + 1] = string.format(
            "  Proc toasts this session: registered=%s seen=%d matched=%d heldOnWindow=%d credited=%d droppedTooLate=%d last=%s",
            tostring(toastStats.registered), toastStats.seen, toastStats.matched, toastStats.held,
            toastStats.credited, toastStats.tooLate, tostring(toastStats.lastText))

        local runs = Runs()
        lines[#lines + 1] = ""
        lines[#lines + 1] = "=== Runs in progress ==="
        local anyRun = false
        for guid, run in pairs(runs and runs:GetCurrentRuns() or {}) do
            anyRun = true
            local stats = runs:GetRunStats(run)
            lines[#lines + 1] = string.format("  %s  started %s  last loot %s  loots=%d  seconds=%d  value=%s  perHour=%s",
                tostring(characters[guid] and characters[guid].name or guid),
                date("%H:%M:%S", run.startedAt or 0), date("%H:%M:%S", run.lastLootAt or 0),
                stats.loots, stats.seconds, FormatCopper(stats.copper),
                stats.perHour and FormatCopper(stats.perHour) or "-")
            -- Per item: value locked at loot vs what valuation says now (2026-10-26:
            -- a fished-up container's value didn't reach the run).
            local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_Valuation"))
                or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_Valuation"))
            local valuation = loaded and _G.PocketCFO_Valuation
            local service = valuation and valuation.GetModule and valuation:GetModule("ValuationService", true) or nil
            lines[#lines + 1] = "    activity=" .. tostring(run.activity) .. "  valuation loaded=" .. tostring(loaded and true or false)
            for itemID, entry in pairs(run.items or {}) do
                local now = "-"
                if service then
                    local ok, result = pcall(service.GetItemValue, service, { itemID = itemID, itemLink = entry.link })
                    if ok and type(result) == "table" then
                        now = result.unresolved and ("no price (" .. tostring(result.unresolvedReason) .. ")")
                            or string.format("%s each (%s%s)", FormatCopper(result.value or 0), tostring(result.source),
                                result.strategyKey and ("/" .. tostring(result.strategyKey)) or "")
                    else
                        now = "error " .. tostring(result)
                    end
                end
                lines[#lines + 1] = string.format("      %s (%d)  qty=%d valuedQty=%d  locked=%s  now=%s  cached=%s",
                    tostring(entry.link), itemID, entry.qty or 0, entry.valuedQty or 0, FormatCopper(entry.copper),
                    now, tostring(runs:GetUnitValue(itemID, entry.link)))
            end
        end
        if not anyRun then
            lines[#lines + 1] = "  (none)"
        end

        lines[#lines + 1] = ""
        lines[#lines + 1] = "=== GameObject loot after unrecognized casts (newest first) ==="
        for _, entry in ipairs(db and db.missLog or {}) do
            lines[#lines + 1] = string.format("  %s  %s  spellID=%s  %s  slots=%d",
                date("%m-%d %H:%M:%S", entry.at or 0), tostring(entry.character),
                tostring(entry.spellID), tostring(entry.spellName), entry.slots or 0)
            if entry.objectGUID or entry.target or entry.items or entry.chat or entry.fishingLoot ~= nil then
                lines[#lines + 1] = string.format("      target=%s  guid=%s  IsFishingLoot=%s",
                    tostring(entry.target), tostring(entry.objectGUID), tostring(entry.fishingLoot))
                if entry.items then
                    lines[#lines + 1] = "      items: " .. entry.items
                end
                if entry.chat then
                    lines[#lines + 1] = string.format("      chat %.1fs before: %s  %s",
                        entry.chat.ago or 0, tostring(entry.chat.event), tostring(entry.chat.text))
                end
            end
        end
        diagnostics:ShowDump("Gathering Log", table.concat(lines, "\n"))
    end)
end

-- ---------------------------------------------------------------------------
-- DIAGNOSTIC (2026-10-26): /mcg gatherrecipes
-- Finds the gathering recipe IDs that C_TradeSkillUI.GetGatheringOperationInfo
-- needs to read Finesse / Perception (only the two skinning ones are known,
-- from BeastSkinCapture). Open the profession window first (Mining,
-- Herbalism or Skinning), then run it. Lists every recipe the open
-- profession has that GetGatheringOperationInfo answers for, with its stats.
-- Theoretical: that GetGatheringOperationInfo returns nil for non-gathering
-- recipes, and that GetAllRecipeIDs includes the gathering recipes.
-- Delete once the recipe IDs are recorded in GatheringCapture.
-- ---------------------------------------------------------------------------
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("gatherrecipes", {
        name = "gatherrecipes",
        description = "List gathering recipe IDs and their Finesse/Perception (open the profession window first).",
        usage = "/mcg gatherrecipes",
        category = "General",
    }, function()
        local lines = {}
        local ok, err = pcall(function()
            local base = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
            local child = C_TradeSkillUI.GetChildProfessionInfo and C_TradeSkillUI.GetChildProfessionInfo()
            lines[#lines + 1] = string.format("Profession: %s (%s)  expansion: %s (%s)",
                tostring(base and base.professionName), tostring(base and base.professionID),
                tostring(child and child.professionName), tostring(child and child.professionID))
            local recipeIDs = C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetAllRecipeIDs() or {}
            lines[#lines + 1] = string.format("Recipes in window: %d", #recipeIDs)
            local found = 0
            for _, recipeID in ipairs(recipeIDs) do
                local okInfo, info = pcall(C_TradeSkillUI.GetGatheringOperationInfo, recipeID)
                if okInfo and type(info) == "table" then
                    found = found + 1
                    local recipe = C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID)
                    local stats = {}
                    for _, stat in ipairs(info.bonusStats or {}) do
                        stats[#stats + 1] = string.format("%s=%s (%s%%)", tostring(stat.bonusStatName),
                            tostring(stat.bonusStatValue), tostring(stat.ratingPct))
                    end
                    lines[#lines + 1] = string.format("  recipeID=%d  %s  %s", recipeID,
                        tostring(recipe and recipe.name), table.concat(stats, "  "))
                end
            end
            lines[#lines + 1] = string.format("Gathering recipes found: %d", found)
        end)
        if not ok then
            lines[#lines + 1] = "error: " .. tostring(err)
        end
        diagnostics:ShowDump("Gathering Recipes", table.concat(lines, "\n"))
    end)
end
