-- PocketCFO/Services/GatheringCapture/GatheringCapture.lua
-- Gathering tracker, capture side (core). Records what every gathering loot
-- window gave (herbs, ore, skins, plus motes, gems and other extras in the same
-- window), valued at the moment it was looted, and runs optional gathering
-- sessions for gold per hour. Display lives in PocketCFO_PnL
-- (Gathering tab of the Gold window + the session frame).
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
--   are not guessed: GameObject windows after an unknown cast are written to
--   the miss log (/mcg gatherlog) so the spell can be added.
--   Great beast skins count too (their analysis keeps its own data in
--   BeastSkinCapture). Fishing is out of scope for now.
--
-- Value (decided with Brian 2026-10-23): each item is valued when looted with
-- ValuationService (same answer as the tooltip). Items with no price yet keep
-- their quantity and are valued at display time with the current price
-- (qty - valuedQty). Poor quality (gray) items with no price use the vendor
-- sell price. This is item value, never gold: it is not part of Income.
-- Profession comes from the gathering spell, not from each item (a gem from
-- a mining node counts as Mining).
--
-- Storage: PocketCFO_DB.global.gathering
--   days[dayKey][characterGUID][professionKey] = {
--     nodes = n,                -- gathering windows counted
--     copper = c,               -- value locked in at loot time
--     items = { [itemID] = { qty, valuedQty, copper, link } },
--   }
--   active[characterGUID] = session (running)
--   sessions[characterGUID] = { session, ... }   -- finished, oldest first, last SESSION_LIMIT
--     session = { startedAt, endedAt, lastActiveAt, lastSeenAt, zone,
--                 nodes, copper, items = { [itemID] = { qty, valuedQty, copper, link } } }
--   missLog = { { at, character, spellID, spellName, slots } }  -- newest first
--   framePos = { left, top }    -- session frame position
-- dayKey is the local date "YYYY-MM-DD". professionKey is the base profession
-- skill line ID as a string ("182" Herbalism, "186" Mining, "393" Skinning),
-- same keys as GoldLedger.
--
-- Sessions are per character. Logging out ends a session at the last time the
-- character was seen (PLAYER_LOGOUT); a /reload keeps it running.
--
-- Messages: MCG_GATHERING_UPDATED (new loot recorded),
--           MCG_GATHERING_SESSION_CHANGED (session started or stopped).
--
-- A plain event frame is used for game events instead of AceEvent because
-- CraftSim's bundled AceEvent can dispatch PocketCFO callbacks with shifted
-- arguments (same as BeastSkinCapture).
--
-- Theoretical:
--   - PLAYER_ENTERING_WORLD args (isInitialLogin, isReloadingUi) used to tell a
--     login from a /reload.
--   - WoW Forever gathering spell IDs and loot source GUID format.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local GatheringCapture = PocketCFO:NewModule("GatheringCapture", "AceEvent-3.0")
PocketCFO.GatheringCapture = GatheringCapture

local GATHER_CAST_TO_LOOT_SECONDS = 3
local SESSION_LIMIT = 50
local MISS_LOG_SIZE = 30
local POOR_QUALITY = 0

-- Gathering spell -> profession and loot source type.
-- Confirmed in-game 2026-10-23 (/mcgd loot): 471009, 471013. 195125 confirmed
-- 2026-10-16 (BeastSkinCapture).
local GATHER_SPELLS = {
    [471009] = { profession = "182", source = "node" },   -- Herb Gathering
    [471013] = { profession = "186", source = "node" },   -- Midnight Mining
    [195125] = { profession = "393", source = "corpse" }, -- Skinning
}

local eventFrame = CreateFrame("Frame")

-- Session state (not saved).
local lastGatherCast = nil   -- { spellID, at }
local lastOtherCast = nil    -- { spellID, at } any other player cast (miss log)
local currentWindow = nil    -- { gather = GATHER_SPELLS entry | nil, spellID, slots, locked, sawGameObject }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Debug(msg, ...)
    if PocketCFO.Debug then
        PocketCFO:Debug("GatheringCapture: " .. tostring(msg), ...)
    end
end

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
    db.active = db.active or {}
    db.sessions = db.sessions or {}
    db.missLog = db.missLog or {}
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

local function GUIDType(guid)
    if type(guid) ~= "string" then
        return nil
    end
    return (strsplit("-", guid))
end

local function SourceMatches(sourceKind, guidType)
    if sourceKind == "node" then
        return guidType == "GameObject"
    end
    return guidType == "Creature" or guidType == "Vehicle"
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
-- Valuation
-- ---------------------------------------------------------------------------

-- Value of one unit right now, in copper, or nil when unpriced.
-- ValuationService first (custom -> vendor purchase -> AH). Gray items with
-- no price fall back to the vendor sell price.
function GatheringCapture:GetUnitValue(itemID, link, quality)
    itemID = tonumber(itemID) or ItemIDFromLink(link)
    if not itemID then
        return nil
    end
    local service = GetValuationService()
    if service and service.GetItemValue then
        local ok, result = pcall(service.GetItemValue, service, { itemID = itemID, itemLink = link })
        if ok and type(result) == "table" and not result.unresolved and tonumber(result.value) then
            return math.floor(tonumber(result.value) + 0.5)
        end
    end

    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if getInfo then
        local ok, _, _, rarity, _, _, _, _, _, _, _, sellPrice = pcall(getInfo, link or itemID)
        quality = tonumber(quality) or (ok and tonumber(rarity)) or nil
        if ok and quality == POOR_QUALITY and tonumber(sellPrice) and sellPrice > 0 then
            return sellPrice
        end
    end
    return nil
end

-- Value of an items table ({ [itemID] = { qty, valuedQty, copper, link } }):
-- value locked in at loot time plus unpriced quantities at today's price.
-- @return copper, unpricedQty (still no price at all)
function GatheringCapture:ValueItems(items)
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

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

local function AddItem(items, slot)
    local entry = items[slot.itemID] or { qty = 0, valuedQty = 0, copper = 0 }
    items[slot.itemID] = entry
    entry.qty = entry.qty + slot.qty
    entry.link = slot.link or entry.link
    if slot.unitValue then
        entry.valuedQty = entry.valuedQty + slot.qty
        entry.copper = entry.copper + slot.unitValue * slot.qty
    end
end

function GatheringCapture:Record(gather, slots)
    local db = GatherDB()
    local guid = PlayerGUID()
    if not db or not guid or #slots == 0 then
        return
    end
    local now = time()
    local professionKey = gather.profession

    local windowCopper = 0
    for _, slot in ipairs(slots) do
        slot.unitValue = self:GetUnitValue(slot.itemID, slot.link, slot.quality)
        if slot.unitValue then
            windowCopper = windowCopper + slot.unitValue * slot.qty
        end
    end

    local dayKey = DayKey(now)
    local day = db.days[dayKey] or {}
    db.days[dayKey] = day
    local character = day[guid] or {}
    day[guid] = character
    local row = character[professionKey] or { nodes = 0, copper = 0, items = {} }
    character[professionKey] = row
    row.nodes = row.nodes + 1
    row.copper = row.copper + windowCopper
    for _, slot in ipairs(slots) do
        AddItem(row.items, slot)
    end

    local session = db.active[guid]
    if session then
        session.nodes = (session.nodes or 0) + 1
        session.copper = (session.copper or 0) + windowCopper
        session.items = session.items or {}
        session.lastActiveAt = now
        for _, slot in ipairs(slots) do
            AddItem(session.items, slot)
        end
    end

    SessionLog("profession=%s slots=%d value=%d session=%s", professionKey, #slots, windowCopper,
        session and "yes" or "no")
    self:SendMessage("MCG_GATHERING_UPDATED")
end

function GatheringCapture:LogMiss(window)
    local db = GatherDB()
    if not db then
        return
    end
    table.insert(db.missLog, 1, {
        at = time(),
        character = UnitName and UnitName("player") or "?",
        spellID = window.spellID,
        spellName = window.spellID and SpellName(window.spellID) or nil,
        slots = window.slotCount or 0,
    })
    while #db.missLog > MISS_LOG_SIZE do
        table.remove(db.missLog)
    end
end

-- ---------------------------------------------------------------------------
-- Loot window reading
-- ---------------------------------------------------------------------------

-- Reads the open loot window. For a gathering window, returns the slots whose
-- source matches the gather type: { itemID, link, qty, quality }.
-- Also notes whether any source was a GameObject (for the miss log).
local function ReadLootWindow(window)
    local slots = {}
    local okCount, numItems = pcall(GetNumLootItems)
    numItems = okCount and tonumber(numItems) or 0
    local sawGameObject = false

    for slot = 1, numItems do
        local okLink, link = pcall(GetLootSlotLink, slot)
        local itemID = okLink and ItemIDFromLink(link) or nil
        if itemID then
            local okInfo, _, _, quantity, _, quality = pcall(GetLootSlotInfo, slot)
            local sources = { pcall(GetLootSourceInfo, slot) }
            local matches = false
            if sources[1] then
                local i = 2
                while i <= #sources do
                    local guidType = GUIDType(sources[i])
                    if guidType == "GameObject" then
                        sawGameObject = true
                    end
                    if window.gather and SourceMatches(window.gather.source, guidType) then
                        matches = true
                    end
                    i = i + 2
                end
            end
            quantity = okInfo and tonumber(quantity) or 0
            if matches and quantity > 0 then
                slots[#slots + 1] = {
                    itemID = itemID,
                    link = link,
                    qty = quantity,
                    quality = tonumber(quality),
                }
            end
        end
    end
    window.sawGameObject = window.sawGameObject or sawGameObject
    window.slotCount = numItems
    return slots
end

local function RecentCast(cast)
    return cast ~= nil and (GetTime() - cast.at) <= GATHER_CAST_TO_LOOT_SECONDS
end

local function OnLootReady()
    if not currentWindow then
        local window = { slots = {} }
        if RecentCast(lastGatherCast) then
            window.gather = GATHER_SPELLS[lastGatherCast.spellID]
            window.spellID = lastGatherCast.spellID
            lastGatherCast = nil
        elseif RecentCast(lastOtherCast) then
            window.spellID = lastOtherCast.spellID
        end
        currentWindow = window
    end
    -- Keep the latest reading until items start leaving the window.
    if not currentWindow.locked then
        currentWindow.slots = ReadLootWindow(currentWindow)
    end
end

local function OnLootClosed()
    local window = currentWindow
    currentWindow = nil
    if not window then
        return
    end
    if window.gather then
        if #window.slots > 0 then
            GatheringCapture:Record(window.gather, window.slots)
        end
    elseif window.sawGameObject and window.spellID then
        -- A cast we don't know looted from a GameObject: chest, or a
        -- gathering spell missing from GATHER_SPELLS.
        GatheringCapture:LogMiss(window)
    end
end

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

function GatheringCapture:GetActiveSession(characterGUID)
    local db = GatherDB()
    characterGUID = characterGUID or PlayerGUID()
    return db and characterGUID and db.active[characterGUID] or nil
end

function GatheringCapture:StartSession()
    local db = GatherDB()
    local guid = PlayerGUID()
    if not db or not guid or db.active[guid] then
        return db and guid and db.active[guid] or nil
    end
    local now = time()
    db.active[guid] = {
        startedAt = now,
        lastActiveAt = now,
        zone = GetZoneText and GetZoneText() or nil,
        nodes = 0,
        copper = 0,
        items = {},
    }
    SessionLog("session started")
    self:SendMessage("MCG_GATHERING_SESSION_CHANGED")
    return db.active[guid]
end

-- endedAt: optional (used when a logout ended the session).
function GatheringCapture:StopSession(endedAt, characterGUID)
    local db = GatherDB()
    local guid = characterGUID or PlayerGUID()
    local session = db and guid and db.active[guid]
    if not session then
        return nil
    end
    db.active[guid] = nil
    session.endedAt = math.max(session.startedAt, endedAt or time())
    local list = db.sessions[guid] or {}
    db.sessions[guid] = list
    list[#list + 1] = session
    while #list > SESSION_LIMIT do
        table.remove(list, 1)
    end
    SessionLog("session stopped nodes=%d seconds=%d", session.nodes or 0, session.endedAt - session.startedAt)
    self:SendMessage("MCG_GATHERING_SESSION_CHANGED")
    return session
end

function GatheringCapture:ToggleSession()
    if self:GetActiveSession() then
        self:StopSession()
        PocketCFO:Print("Gathering session stopped.")
    else
        self:StartSession()
        PocketCFO:Print("Gathering session started.")
    end
    self:ShowSessionFrame()
end

-- The session frame lives in PocketCFO_PnL (display only).
function GatheringCapture:ShowSessionFrame()
    local loader = PocketCFO:GetModule("AddonLoader", true)
    if not loader or not loader:SafeLoad("PocketCFO_PnL") then
        return
    end
    local pnl = _G.PocketCFO_PnL
    local frame = pnl and pnl:GetModule("GatheringSessionFrame", true)
    if frame then
        frame:Refresh()
    end
end

function GatheringCapture:GetFramePosition()
    local db = GatherDB()
    return db and db.framePos or nil
end

function GatheringCapture:SetFramePosition(left, top)
    local db = GatherDB()
    if db and left and top then
        db.framePos = { left = left, top = top }
    end
end

-- ---------------------------------------------------------------------------
-- Read API (PocketCFO_PnL). Callers must not modify the returned tables.
-- ---------------------------------------------------------------------------

-- days[dayKey][characterGUID][professionKey] = { nodes, copper, items }
function GatheringCapture:GetDays()
    local db = GatherDB()
    return db and db.days or {}
end

-- sessions[characterGUID] = { session, ... } oldest first
function GatheringCapture:GetSessions()
    local db = GatherDB()
    return db and db.sessions or {}
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "LOOT_READY" or event == "LOOT_OPENED" then
        OnLootReady()
    elseif event == "LOOT_SLOT_CLEARED" then
        if currentWindow then
            currentWindow.locked = true
        end
    elseif event == "LOOT_CLOSED" then
        OnLootClosed()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and spellID then
            if GATHER_SPELLS[spellID] then
                lastGatherCast = { spellID = spellID, at = GetTime() }
            else
                lastOtherCast = { spellID = spellID, at = GetTime() }
            end
        end
    elseif event == "PLAYER_LOGOUT" then
        local session = GatheringCapture:GetActiveSession()
        if session then
            session.lastSeenAt = time()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isInitialLogin = ...
        local session = GatheringCapture:GetActiveSession()
        if session and isInitialLogin then
            -- Logging out ends the session at the last time this character
            -- was seen (falls back to its last loot after a crash).
            GatheringCapture:StopSession(session.lastSeenAt or session.lastActiveAt or session.startedAt)
        elseif session then
            GatheringCapture:ShowSessionFrame()
        end
    end
end)

function GatheringCapture:OnEnable()
    eventFrame:RegisterEvent("LOOT_READY")
    eventFrame:RegisterEvent("LOOT_OPENED")
    eventFrame:RegisterEvent("LOOT_SLOT_CLEARED")
    eventFrame:RegisterEvent("LOOT_CLOSED")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    eventFrame:RegisterEvent("PLAYER_LOGOUT")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
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
    diagnostics:RegisterCommand("gather", {
        name = "gather",
        description = "Start or stop a gathering session (shows gold per hour).",
        usage = "/pcfo gather",
        category = "General",
        playerFacing = true,
    }, function()
        GatheringCapture:ToggleSession()
    end)

    -- /mcg gatherlog: today's gathering per character/profession, and GameObject
    -- loot after casts that are not known gathering spells (saved, works with
    -- debug off).
    diagnostics:RegisterCommand("gatherlog", {
        name = "gatherlog",
        description = "Show today's gathering capture and loot from unrecognized casts.",
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
                lines[#lines + 1] = string.format("  %s  profession=%s  windows=%d  locked=%s",
                    tostring(who), professionKey, row.nodes or 0, FormatCopper(row.copper))
                for itemID, entry in pairs(row.items or {}) do
                    lines[#lines + 1] = string.format("      %d  %s  qty=%d valuedQty=%d  %s",
                        itemID, tostring(entry.link), entry.qty or 0, entry.valuedQty or 0, FormatCopper(entry.copper))
                end
            end
        end
        if #lines == 1 then
            lines[#lines + 1] = "  (nothing yet)"
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "=== GameObject loot after unrecognized casts (newest first) ==="
        for _, entry in ipairs(db and db.missLog or {}) do
            lines[#lines + 1] = string.format("  %s  %s  spellID=%s  %s  slots=%d",
                date("%m-%d %H:%M:%S", entry.at or 0), tostring(entry.character),
                tostring(entry.spellID), tostring(entry.spellName), entry.slots or 0)
        end
        diagnostics:ShowDump("Gathering Log", table.concat(lines, "\n"))
    end)
end
