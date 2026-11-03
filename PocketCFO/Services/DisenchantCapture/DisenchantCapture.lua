-- PocketCFO/Services/DisenchantCapture/DisenchantCapture.lua
-- Records what every disenchant gives, so PocketCFO can later show an
-- expected disenchant value on item tooltips (seed table first, observed
-- data on top, same model as the other crafting captures).
-- Capture only. No UI, no chat output (session log only).
--
-- Confirmed in-game 2026-10-25 (/mcgd loot, 12 disenchants):
--   - Disenchant (spellID 13262) UNIT_SPELLCAST_SUCCEEDED fires 0.0-0.1s
--     before the loot window's LOOT_READY.
--   - Every slot's GetLootSourceInfo source is an "Item-..." GUID for the
--     item being disenchanted.
--   - That GUID still resolves while the loot window is open:
--     C_Item.GetItemLinkByGUID returns the item link, and
--     C_Item.GetDetailedItemLevelInfo(link) returns effective, preview and
--     base item level.
--   - GetLootSlotInfo: r3 = quantity, r5 = rarity.
--   - LOOT_READY fires twice and LOOT_OPENED once per window, so the window
--     is re-read until items start leaving it (same as GatheringCapture).
--   - Disenchant mats come in quality tiers with different itemIDs
--     (Radiant Shard tier 1 = 243602, tier 2 = 243603). Mats are stored by
--     exact itemID.
--   - Extra non-enchanting mats appear in the same window (seen: motes,
--     Void-Tempered Scales, Refulgent Copper Ore). Brian: these come from
--     enchanting knowledge points and can be any baseline resource (ore,
--     cloth, leather, scales, motes). They are stored like any other mat;
--     nothing is classified or limited at capture time.
--
-- What drives mat tier is not documented by Blizzard. Brian's working theory
-- (2026-10-25): each disenchant is an independent random roll, e.g. a 200
-- ilvl blue gives the high tier ~90% of the time; the odds probably depend
-- on skill and/or tools. The real odds are to be measured from these
-- records, the same way resourcefulness and multicraft were. So each record
-- also stores, read at cast start:
--   - Enchanting skill
--   - Links of everything in the six profession equipment slots
-- Confirmed in-game 2026-10-25 (/mcg delog):
--   - GetProfessionInfo(index) for Enchanting (333) returns skill/max/bonus
--     matching the game (100/100 +40 from equipment).
--   - C_TradeSkillUI.GetProfessionInfoBySkillLineID(2909) returns 0/0 with
--     the profession window closed; not used.
--   - Profession equipment slots are 20-25 (20-22 first profession,
--     23-25 second).
--   - C_TradeSkillUI.GetItemReagentQualityByItemInfo returns the mat tier
--     (1, 2) and nil for untiered mats (Glimmering Powder).
-- Every read is pcall-wrapped; a value that comes back nil is stored as nil.
-- Not captured yet: enchanting knowledge point spend (C_ProfSpecs). Flagged
-- as a follow-up.
--
-- Storage: PocketCFO_DB.global.disenchants[characterGUID] = {
--   name, realm,
--   count = n,                          -- all-time disenchants recorded
--   gear = { "slot=link;...", ... },    -- distinct profession gear sets seen
--   records = {                         -- oldest first, capped at RECORD_LIMIT
--     { at,
--       item = { id, link, rarity, ilvl, previewIlvl, baseIlvl, sellPrice,
--                classID, subClassID, equipLoc, expacID },
--       mats = { { id, qty, rarity, tier, link } },
--       skill = { profLevel, profMax, profModifier },   -- modifier = bonus from equipment
--       gear = index into gear (nil if unreadable) },
--   },
-- }
-- One raw record per disenchant (not averages) so the data can be regrouped
-- once we learn what actually drives the results.
--
-- Flavor: Both. Listed in PocketCFO.toc and PocketCFO_Camelot.toc
-- (Forever added 2026-10-27). Every read is pcall-wrapped, so values Forever
-- lacks (profession gear slots, mat tiers) are stored as nil.
-- Theoretical on Forever: Disenchant is spellID 13262, and the loot source
-- of a disenchant window is an "Item-..." GUID. If either is wrong, nothing
-- is recorded; check /mcg delog after the first Forever disenchant.
--
-- Loot reading (migrated to the loot reader 2026-10-30): this module no
-- longer reads loot windows itself. It listens for MCG_LOOT_WINDOW from
-- LootReader and records windows with context "disenchant" (Disenchant cast
-- attached, first window only). Mats = item slots with an Item source. The
-- disenchanted item = that source's id / link, which LootReader resolves
-- from the GUID while the window is open. Item level, rarity, sell price and
-- class are read from that link after the window closes (the item is gone by
-- then). Theoretical until tested: GetDetailedItemLevelInfo(link) and
-- GetItemInfo(link) still answer for a destroyed item's link.
-- The cast-start snapshot (skill, profession gear) stays here.
--
-- A plain event frame is used for game events instead of AceEvent because
-- CraftSim's bundled AceEvent can dispatch PocketCFO callbacks with shifted
-- arguments (same as BeastSkinCapture and GatheringCapture). The loot reader
-- message uses an embedded AceEvent messenger (same as
-- ContainerOutcomeService).

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local DisenchantCapture = PocketCFO:NewModule("DisenchantCapture")
PocketCFO.DisenchantCapture = DisenchantCapture

local DISENCHANT_SPELL_ID = 13262
local RECORD_LIMIT = 5000

local ENCHANTING_SKILL_LINE = 333

-- Profession tool + 2 accessories for each of the two primary professions.
-- Theoretical: slot numbers. Global constants are used when present.
local PROFESSION_SLOTS = {
    _G.INVSLOT_PROF0TOOL or 20,
    _G.INVSLOT_PROF0GEAR0 or 21,
    _G.INVSLOT_PROF0GEAR1 or 22,
    _G.INVSLOT_PROF1TOOL or 23,
    _G.INVSLOT_PROF1GEAR0 or 24,
    _G.INVSLOT_PROF1GEAR1 or 25,
}

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo

local eventFrame = CreateFrame("Frame")
local messenger = LibStub and LibStub("AceEvent-3.0", true) and LibStub("AceEvent-3.0"):Embed({}) or nil

-- Session state (not saved).
local castSnapshot = nil    -- { skill, gearKey } read at Disenchant cast start

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

local function SessionLog(msg, ...)
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] DisenchantCapture: " .. tostring(msg))
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

local function CaptureDB()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    globalDB.disenchants = globalDB.disenchants or {}
    return globalDB.disenchants
end

local function CharacterEntry()
    local db = CaptureDB()
    local guid = UnitGUID and UnitGUID("player")
    if not db or not guid then
        return nil
    end
    local entry = db[guid]
    if not entry then
        entry = { count = 0, gear = {}, records = {} }
        db[guid] = entry
    end
    entry.gear = entry.gear or {}
    entry.records = entry.records or {}
    entry.count = entry.count or 0
    entry.name = UnitName("player")
    entry.realm = GetRealmName and GetRealmName() or entry.realm
    return entry
end

-- ---------------------------------------------------------------------------
-- Cast-start snapshot: skill and profession gear
-- ---------------------------------------------------------------------------

-- Enchanting skill from the primary profession list (confirmed in-game).
local function ReadSkill()
    local skill = {}

    if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
        local okList, prof1, prof2 = pcall(GetProfessions)
        if okList then
            for _, index in ipairs({ prof1 or false, prof2 or false }) do
                if index then
                    local ok, _, _, level, maxLevel, _, _, skillLine, modifier = pcall(GetProfessionInfo, index)
                    if ok and tonumber(skillLine) == ENCHANTING_SKILL_LINE then
                        skill.profLevel = tonumber(level)
                        skill.profMax = tonumber(maxLevel)
                        skill.profModifier = tonumber(modifier)
                    end
                end
            end
        end
    end

    return skill
end

-- All six profession slots as one string, e.g. "20=link;21=link;...".
-- Empty slots are left out. Returns nil when nothing is readable.
local function ReadGearKey()
    if type(GetInventoryItemLink) ~= "function" then
        return nil
    end
    local parts = {}
    for _, slot in ipairs(PROFESSION_SLOTS) do
        local ok, link = pcall(GetInventoryItemLink, "player", slot)
        if ok and type(link) == "string" then
            parts[#parts + 1] = tostring(slot) .. "=" .. link
        end
    end
    if #parts == 0 then
        return nil
    end
    return table.concat(parts, ";")
end

local function TakeCastSnapshot()
    castSnapshot = {
        skill = ReadSkill(),
        gearKey = ReadGearKey(),
    }
end

-- Index of this gear set in the character's gear list (added if new).
local function GearIndex(characterEntry, gearKey)
    if not gearKey then
        return nil
    end
    for index, key in ipairs(characterEntry.gear) do
        if key == gearKey then
            return index
        end
    end
    characterEntry.gear[#characterEntry.gear + 1] = gearKey
    return #characterEntry.gear
end

-- ---------------------------------------------------------------------------
-- Loot window reading
-- ---------------------------------------------------------------------------

local function ReadMatTier(itemID)
    if not C_TradeSkillUI or type(C_TradeSkillUI.GetItemReagentQualityByItemInfo) ~= "function" then
        return nil
    end
    local ok, tier = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, itemID)
    return ok and tonumber(tier) or nil
end

-- Item being disenchanted, from the Item source LootReader resolved while
-- the window was open. Details come from the link (the item itself is gone
-- by the time the window record arrives; Theoretical that the link still
-- answers, see header).
local function ReadSourceItem(source)
    local link = source and source.link
    if type(link) ~= "string" then
        return nil
    end
    local item = { id = ItemIDFromLink(link) or tonumber(source.id), link = link }
    if C_Item and type(C_Item.GetDetailedItemLevelInfo) == "function" then
        local okIlvl, ilvl, preview, base = pcall(C_Item.GetDetailedItemLevelInfo, link)
        if okIlvl then
            item.ilvl = tonumber(ilvl)
            item.previewIlvl = tonumber(preview)
            item.baseIlvl = tonumber(base)
        end
    end
    if type(GetItemInfo) == "function" then
        local okInfo, _, _, rarity, _, _, _, _, _, equipLoc, _, sellPrice, classID, subClassID, _, expacID = pcall(GetItemInfo, link)
        if okInfo then
            item.rarity = tonumber(rarity)
            item.sellPrice = tonumber(sellPrice)
            item.equipLoc = equipLoc
            item.classID = tonumber(classID)
            item.subClassID = tonumber(subClassID)
            item.expacID = tonumber(expacID)
        end
    end
    return item
end

-- Returns { sourceGUID, item, mats } from a LootReader window record, using
-- only item slots with an Item source (same rule as before the migration).
-- nil when the window has no such slots. The record is read, never changed.
local function ReadWindowRecord(window)
    local itemSource = nil
    local mats = {}
    for _, slot in ipairs(window.slots or {}) do
        local itemID = slot.itemID
        local quantity = tonumber(slot.quantity) or 0
        if itemID and quantity > 0 then
            local slotSource = nil
            for _, source in ipairs(slot.sources or {}) do
                if source.type == "Item" then
                    slotSource = source
                    break
                end
            end
            if slotSource then
                itemSource = itemSource or slotSource
                mats[#mats + 1] = {
                    id = itemID,
                    qty = quantity,
                    rarity = tonumber(slot.quality),
                    tier = ReadMatTier(itemID),
                    link = slot.link,
                }
            end
        end
    end

    if not itemSource or #mats == 0 then
        return nil
    end
    return { sourceGUID = itemSource.guid, item = ReadSourceItem(itemSource), mats = mats }
end

-- ---------------------------------------------------------------------------
-- Commit
-- ---------------------------------------------------------------------------

local function Commit(read, snapshot)
    local characterEntry = CharacterEntry()
    if not characterEntry or not read.item or not read.item.id then
        SessionLog("skipped: source item unreadable guid=%s", tostring(read.sourceGUID))
        return
    end

    local record = {
        at = Now(),
        item = read.item,
        mats = read.mats,
        skill = snapshot and snapshot.skill or nil,
        gear = snapshot and GearIndex(characterEntry, snapshot.gearKey) or nil,
    }

    characterEntry.records[#characterEntry.records + 1] = record
    while #characterEntry.records > RECORD_LIMIT do
        table.remove(characterEntry.records, 1)
    end
    characterEntry.count = characterEntry.count + 1

    SessionLog("item=%s ilvl=%s mats=%d", tostring(read.item.id), tostring(read.item.ilvl), #read.mats)
end

-- One finished loot window from LootReader. Only "disenchant" windows count.
function DisenchantCapture:OnLootWindow(window)
    if type(window) ~= "table" or window.context ~= "disenchant" then
        return
    end
    local read = ReadWindowRecord(window)
    if read then
        Commit(read, castSnapshot)
    end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "UNIT_SPELLCAST_START" then
        local unit, _, spellID = ...
        if unit == "player" and spellID == DISENCHANT_SPELL_ID then
            TakeCastSnapshot()
        end
    end
end)

if messenger then
    messenger:RegisterMessage("MCG_LOOT_WINDOW", function(_, window)
        DisenchantCapture:OnLootWindow(window)
    end)
end

function DisenchantCapture:OnEnable()
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
end

-- ---------------------------------------------------------------------------
-- Read API (for the seed builder and the future tooltip). Callers must not
-- modify the returned tables.
-- ---------------------------------------------------------------------------

-- characterGUID -> character entry (see Storage above).
-- True when the current character has Enchanting (primary profession list).
-- Used by ActivitySessions for soulbound loot (2026-10-27).
function DisenchantCapture:IsEnchanter()
    local ok, skill = pcall(ReadSkill)
    return ok and type(skill) == "table" and skill.profLevel ~= nil or false
end

function DisenchantCapture:GetAllData()
    return CaptureDB() or {}
end

-- One character's entry (defaults to the current character), or nil.
function DisenchantCapture:GetCharacterData(characterGUID)
    local db = CaptureDB()
    characterGUID = characterGUID or (UnitGUID and UnitGUID("player"))
    return db and characterGUID and db[characterGUID] or nil
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local RARITY_NAMES = { [2] = "green", [3] = "blue", [4] = "purple" }
local DELOG_RECENT = 25

local function FormatSkill(skill)
    if type(skill) ~= "table" then
        return "skill=?"
    end
    return string.format("skill=%s/%s(+%s)",
        tostring(skill.profLevel), tostring(skill.profMax), tostring(skill.profModifier))
end

local function FormatMats(mats)
    local parts = {}
    for _, mat in ipairs(mats or {}) do
        parts[#parts + 1] = string.format("%s x%d (id=%d tier=%s)",
            tostring(mat.link), mat.qty or 0, mat.id or 0, tostring(mat.tier))
    end
    return table.concat(parts, ", ")
end

local diagnostics = PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    -- /mcg delog: per character, a summary by source item rarity + item
    -- level, then the most recent disenchants with skill and gear.
    diagnostics:RegisterCommand("delog", {
        name = "delog",
        description = "Show captured disenchants: summary by rarity and item level, then recent records.",
        usage = "/mcg delog",
        category = "General",
    }, function()
        local lines = {}
        local any = false
        for _, entry in pairs(CaptureDB() or {}) do
            any = true
            local records = entry.records or {}
            lines[#lines + 1] = string.format("=== %s-%s  disenchants=%d (stored %d) gearSets=%d ===",
                tostring(entry.name), tostring(entry.realm), entry.count or 0, #records, #(entry.gear or {}))

            -- Summary: rarity + effective ilvl -> count and average qty per mat.
            local groups, order = {}, {}
            for _, record in ipairs(records) do
                local item = record.item or {}
                local key = string.format("%s ilvl=%s", RARITY_NAMES[item.rarity] or tostring(item.rarity), tostring(item.ilvl))
                local group = groups[key]
                if not group then
                    group = { count = 0, mats = {}, links = {} }
                    groups[key] = group
                    order[#order + 1] = key
                end
                group.count = group.count + 1
                for _, mat in ipairs(record.mats or {}) do
                    group.mats[mat.id] = (group.mats[mat.id] or 0) + (mat.qty or 0)
                    group.links[mat.id] = mat.link
                end
            end
            table.sort(order)
            lines[#lines + 1] = "-- Summary (average per disenchant)"
            for _, key in ipairs(order) do
                local group = groups[key]
                lines[#lines + 1] = string.format("  %s  n=%d", key, group.count)
                for matID, total in pairs(group.mats) do
                    lines[#lines + 1] = string.format("      %s (id=%d)  avg=%.2f  total=%d",
                        tostring(group.links[matID]), matID, total / group.count, total)
                end
            end

            lines[#lines + 1] = "-- Recent (newest first)"
            local first = math.max(1, #records - DELOG_RECENT + 1)
            for i = #records, first, -1 do
                local record = records[i]
                local item = record.item or {}
                lines[#lines + 1] = string.format("  %s  %s  id=%s %s ilvl=%s base=%s class=%s/%s %s expac=%s",
                    date("%m-%d %H:%M:%S", record.at or 0), tostring(item.link), tostring(item.id),
                    RARITY_NAMES[item.rarity] or tostring(item.rarity), tostring(item.ilvl), tostring(item.baseIlvl),
                    tostring(item.classID), tostring(item.subClassID), tostring(item.equipLoc), tostring(item.expacID))
                lines[#lines + 1] = "      -> " .. FormatMats(record.mats)
                lines[#lines + 1] = "      " .. FormatSkill(record.skill) .. "  gear=" .. tostring(record.gear)
            end

            lines[#lines + 1] = "-- Gear sets"
            for index, key in ipairs(entry.gear or {}) do
                lines[#lines + 1] = string.format("  [%d] %s", index, key)
            end
            lines[#lines + 1] = ""
        end
        if not any then
            lines[1] = "No disenchants captured yet."
        end
        diagnostics:ShowDump("Disenchant Log", table.concat(lines, "\n"))
    end)
end
