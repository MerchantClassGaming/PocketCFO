-- PocketCFO/Services/ActivitySessions/ActivitySessions.lua
-- Sessions: what an activity of the player's choosing made, in gold.
-- Design agreed with Brian 2026-10-27.
--
-- Two kinds:
--   manual   - started and stopped by the player (Gold per Hour window), with
--              a name they pick. Time = wall clock while logged in (logging
--              out pauses it; /reload does not stop it).
--   instance - started automatically on entering a dungeon, raid or delve
--              (GetInstanceInfo instanceType party / raid / scenario), named
--              after the instance (+ difficulty unless Normal). Battlegrounds,
--              arenas and housing plots are never sessions.
--              Leaving and coming back into the same instance (same
--              instanceID + difficulty) within REENTER_SECONDS continues the
--              session; that time outside counts (repair trip, corpse run,
--              reset and rerun). Otherwise it ends at the moment you left.
--              Under MIN_INSTANCE_SECONDS it is not saved (zoning in by
--              accident). A manual session wins: while one runs, entering an
--              instance doesn't start another.
-- One session at a time per character. Automatic gathering runs
-- (ActivityRuns) keep recording underneath and are not affected.
--
-- What a session made = gold in - gold out + item value + currency value.
-- Since 2026-10-30 everything comes from one feed, the Item Ledger
-- (MCG_ITEM_LEDGER_ENTRY; claude/Ledger_Rebuild_Checklist.md item 9), so
-- every thing is counted once:
--   - Gold: every change GoldLedger records during the session, and only
--     gold earned during it (AH sale mail collected now for a sale before the
--     session doesn't count).
--   - Items: everything that came in during the session: loot of every kind,
--     container contents, order rewards and other mail, quest rewards, AH and
--     vendor purchases (their gold out is counted too, so a purchase nets to
--     what the item is worth).
--   - Containers opened during the session (MCG_CONTAINER_OPENING): the
--     contents count and the container is used up, so a payout bag received
--     in the session is never counted twice; one you already had counts as
--     contents minus the bag.
--   - Currencies (Moxie etc.): gained minus spent, valued where a currency
--     value exists (none yet: shown as a count).
--   - Not counted: "transfer" (moved between your own characters).
--   - Going out (2026-11-05): mats used in crafts and items disenchanted
--     subtract their book value (the value they came in at, from the Item
--     Ledger's book value record); units with no book value subtract at
--     today's price. BoP items (bound on pickup) are worth 0 while held; what
--     they bring when they leave is the gain.
--   - Crafts (Going Out step 1, 2026-11-05): output and resourcefulness
--     returns count as items in; mats used count as used (craft out entries),
--     so a craft adds output minus mats. A craft whose mats couldn't be read
--     (x.noMats) is not counted at all, so it never looks like pure profit.
--   - Sold during the session (vendor, AH; 2026-11-05): the sale gold counts
--     as gold in and the item comes off at its book value (an item looted
--     this session nets to the sale gold; one held from before nets to the
--     sale gold minus what it was worth). Replaced the name-matching rule.
--   - Still held at the end = what it's worth, at today's price when shown.
--     Sales after the session ends never change it.
--   - Item value: tradeable items use the valuation engine (via
--     ActivityRuns:GetUnitValue), else the vendor price. Bound items
--     (bind on pickup, quest, account/warband bound) use the vendor price, or
--     for a character with Enchanting the higher of the disenchant estimate and
--     the vendor price (Brian 2026-10-27).
--
-- Theoretical until seen in-game: GetInstanceInfo instance types for delves
-- (scenario) and Forever dungeons; roll wins on Forever reaching the ledger;
-- Enum.ItemBind numbering.
--
-- Storage: PocketCFO_DB.global.activitySessions = {
--   current = { [characterGUID] = session },
--   history = { [characterGUID] = { name, classFile, sessions = { session, ... } } },  -- oldest first
--   recentNames = { name, ... },   -- newest first
--   log = { line, ... },           -- last LOG_SIZE events, newest first (/mcg sessions)
-- }
-- session = { kind, name, instanceID, difficultyID, startedAt, endedAt,
--   seconds (counted so far), activeSince (time() the clock last resumed; nil
--   while paused or outside), outsideSince (instance only), lastBankAt,
--   entries (instance), enchanter,
--   gold = { [category] = { income, spend } },
--   items = { [link] = { itemID, name, looted (came in), sold, soldCopper, used (containers opened, mats used in crafts) } },
--   currencies = { [currencyID] = { gained, spent } } }
--
-- Messages: MCG_SESSIONS_UPDATED (live numbers), MCG_SESSIONS_FILED (session
-- started, ended or discarded).
-- Flavor: Both. Game events use a plain frame (CraftSim's bundled AceEvent
-- can shift callback arguments); AceEvent is used for addon messages only.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local ActivitySessions = PocketCFO:NewModule("ActivitySessions", "AceEvent-3.0")

local INSTANCE_TYPES = { party = true, raid = true, scenario = true }
local REENTER_SECONDS = 600
local MIN_INSTANCE_SECONDS = 120
local HISTORY_LIMIT = 200
local HISTORY_DAYS = 90
local TICK_SECONDS = 15
local RECENT_NAME_LIMIT = 10
local LOG_SIZE = 100
local DEFAULT_NAME = "Session"
-- Pause (2026-10-31): a session paused longer than this is filed, ended
-- where it was paused.
local PAUSE_LIMIT_SECONDS = 1800

-- Bound = can't be sold on the AH. Read from Enum.ItemBind by name when the
-- client has it; the literals are the fallback (Theoretical numbering).
local BOUND = {}
do
    local bind = Enum and Enum.ItemBind or {}
    BOUND[bind.OnAcquire or 1] = true
    BOUND[bind.Quest or 4] = true
    BOUND[bind.ToWoWAccount or 7] = true
    BOUND[bind.ToBnetAccount or 8] = true
    BOUND[bind.ToBnetAccountUntilEquipped or 9] = true
end

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo

local eventFrame = CreateFrame("Frame")
local messenger = LibStub and LibStub("AceEvent-3.0", true) and LibStub("AceEvent-3.0"):Embed({}) or nil

-- Item Ledger categories a session never counts (see header).
local NOT_COUNTED = { transfer = true }

-- Items going out that a session counts (Going Out, 2026-11-05): mats used in
-- crafts, items disenchanted and items sold to a vendor. Each subtracts its book value (the value it
-- came in at, entry.bv for entry.bvq units); units with no book value
-- subtract at today's price.
local OUT_COUNTED = { craft = true, disenchant = true, vendor = true, auction = true, used = true }

-- Item entries a session counts: everything coming in, plus mats used in a
-- craft going out. Craft entries without mats (x.noMats) are skipped.
local function CountsItem(entry)
    if entry.kind ~= "item" or (type(entry.x) == "table" and entry.x.noMats) then
        return false
    end
    return entry.dir == "in" or OUT_COUNTED[entry.cat] == true
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Now()
    return time()
end

local function PlayerGUID()
    return UnitGUID and UnitGUID("player") or nil
end

local function FormatCopper(copper)
    copper = tonumber(copper) or 0
    local sign = copper < 0 and "-" or "+"
    copper = math.abs(math.floor(copper))
    return string.format("%s%dg%02ds%02dc", sign,
        math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100)
end

local function DB()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    local db = globalDB.activitySessions or {}
    globalDB.activitySessions = db
    db.current = db.current or {}
    db.history = db.history or {}
    db.recentNames = db.recentNames or {}
    db.log = db.log or {}
    return db
end

local function Log(msg, ...)
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    local db = DB()
    if db then
        table.insert(db.log, 1, date("%m-%d %H:%M:%S") .. "  " .. tostring(msg))
        while #db.log > LOG_SIZE do
            table.remove(db.log)
        end
    end
    PocketCFO:AppendSessionLog("[MCG] ActivitySessions: " .. tostring(msg))
end

local function ItemName(link)
    local ok, name = pcall(GetItemInfo, link)
    if ok and name then
        return name
    end
    return type(link) == "string" and link:match("%[(.-)%]") or nil
end

local function IsEnchanter()
    local capture = PocketCFO:GetModule("DisenchantCapture", true)
    return capture and capture.IsEnchanter and capture:IsEnchanter() or false
end

-- ---------------------------------------------------------------------------
-- Clock
-- ---------------------------------------------------------------------------

-- Moves running time into session.seconds (up to now).
local function Bank(session, now)
    now = now or Now()
    if session.activeSince then
        session.seconds = (session.seconds or 0) + math.max(0, now - session.activeSince)
        session.activeSince = now
    end
    session.lastBankAt = now
end

-- Counted seconds. Live: an instance session outside its instance shows the
-- time outside (up to REENTER_SECONDS) so the clock doesn't freeze on a
-- repair trip; if you don't go back, that time is dropped when it ends.
function ActivitySessions:GetSeconds(session, now)
    if not session then
        return 0
    end
    now = now or Now()
    local seconds = session.seconds or 0
    if session.activeSince and not session.endedAt then
        seconds = seconds + math.max(0, now - session.activeSince)
    end
    if session.outsideSince and not session.endedAt then
        local until_ = session.pausedAt or now
        seconds = seconds + math.min(REENTER_SECONDS, math.max(0, until_ - session.outsideSince))
    end
    return seconds
end

-- ---------------------------------------------------------------------------
-- Pause (2026-10-31; Stop / Pause buttons through core ActivityControl)
--   The clock stops, and nothing starts, ends or switches the session (no
--   instance checks) until it is resumed, or until PAUSE_LIMIT_SECONDS, when
--   it is filed as ended where it was paused. Gold and items coming in while
--   paused are held and ActivityControl asks once whether to resume: yes
--   resumes and counts them; no leaves them out and doesn't ask again this
--   pause. Saved on the session: pausedAt, pauseDeclined (survive /reload).
-- ---------------------------------------------------------------------------

function ActivitySessions:IsPaused(session)
    session = session or self:GetCurrent()
    return session ~= nil and session.pausedAt ~= nil
end

function ActivitySessions:Pause()
    local session = self:GetCurrent()
    if not session or session.pausedAt then
        return false
    end
    local now = Now()
    Bank(session, now)
    session.activeSince = nil
    session.pausedAt = now
    session.pauseDeclined = nil
    Log("paused %s", tostring(session.name))
    self:SendMessage("MCG_SESSIONS_UPDATED")
    return true
end

-- The clock restarts now. An instance session that was outside its instance
-- keeps the outside time it had at the pause; the instance check then runs.
function ActivitySessions:Resume()
    local session = self:GetCurrent()
    if not session or not session.pausedAt then
        return false
    end
    local now = Now()
    local paused = math.max(0, now - session.pausedAt)
    if session.outsideSince then
        session.outsideSince = session.outsideSince + paused
    else
        session.activeSince = now
    end
    session.lastBankAt = now
    session.pausedAt, session.pauseDeclined = nil, nil
    Log("resumed %s after %ds paused", tostring(session.name), paused)
    self:SendMessage("MCG_SESSIONS_UPDATED")
    self:CheckInstance()
    return true
end

-- Something that would count on a paused session: held (and the player
-- asked) or dropped (they said stay paused). Returns true when the caller
-- must stop; fn is replayed if the player resumes.
function ActivitySessions:HoldIfPaused(fn)
    local session = self:GetCurrent()
    if not session or not session.pausedAt then
        return false
    end
    if session.pauseDeclined then
        return true
    end
    local control = PocketCFO.ActivityControl
    if control then
        control:Hold("session", fn)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Start / file
-- ---------------------------------------------------------------------------

function ActivitySessions:GetCurrent(guid)
    local db = DB()
    guid = guid or PlayerGUID()
    return db and guid and db.current[guid] or nil
end

local function NoteRecentName(db, name)
    for index, existing in ipairs(db.recentNames) do
        if existing == name then
            table.remove(db.recentNames, index)
            break
        end
    end
    table.insert(db.recentNames, 1, name)
    while #db.recentNames > RECENT_NAME_LIMIT do
        table.remove(db.recentNames)
    end
end

local function NewSession(kind, name, extra)
    local now = Now()
    local session = {
        kind = kind,
        name = name,
        startedAt = now,
        activeSince = now,
        lastBankAt = now,
        seconds = 0,
        enchanter = IsEnchanter(),
        gold = {},
        items = {},
    }
    for key, value in pairs(extra or {}) do
        session[key] = value
    end
    return session
end

local function PruneHistory(entry)
    local cutoff = Now() - HISTORY_DAYS * 86400
    local kept = {}
    for _, session in ipairs(entry.sessions or {}) do
        if (session.endedAt or 0) >= cutoff then
            kept[#kept + 1] = session
        end
    end
    while #kept > HISTORY_LIMIT do
        table.remove(kept, 1)
    end
    entry.sessions = kept
end

-- Ends the character's current session at endAt (default now) and saves it.
function ActivitySessions:File(guid, endAt)
    local db = DB()
    local session = db and db.current[guid]
    if not session then
        return
    end
    endAt = endAt or Now()
    session.pausedAt, session.pauseDeclined = nil, nil
    if session.activeSince then
        session.seconds = (session.seconds or 0) + math.max(0, endAt - session.activeSince)
        session.activeSince = nil
    end
    session.outsideSince = nil
    session.endedAt = endAt
    db.current[guid] = nil

    if session.kind == "instance" and (session.seconds or 0) < MIN_INSTANCE_SECONDS then
        Log("discarded %s (%ds, under %ds)", tostring(session.name), session.seconds or 0, MIN_INSTANCE_SECONDS)
    else
        local entry = db.history[guid] or { sessions = {} }
        db.history[guid] = entry
        -- Name / class only from the logged-in character (another
        -- character's abandoned session can be filed from here, 2026-10-31).
        if guid == PlayerGUID() then
            entry.name = UnitName and UnitName("player") or entry.name
            local _, classFile = UnitClass and UnitClass("player")
            entry.classFile = classFile or entry.classFile
        end
        entry.sessions[#entry.sessions + 1] = session
        PruneHistory(entry)
        Log("filed %s (%s) %ds", tostring(session.name), session.kind, session.seconds or 0)
    end
    self:SendMessage("MCG_SESSIONS_FILED")
end

-- Manual start. Ends any current session first (manual or instance).
function ActivitySessions:Start(name)
    local db = DB()
    local guid = PlayerGUID()
    if not db or not guid then
        return
    end
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        name = DEFAULT_NAME
    end
    if db.current[guid] then
        self:File(guid, nil)
    end
    db.current[guid] = NewSession("manual", name)
    NoteRecentName(db, name)
    Log("started %s (manual)", name)
    self:SendMessage("MCG_SESSIONS_FILED")
end

function ActivitySessions:Stop()
    local guid = PlayerGUID()
    if guid then
        self:File(guid, nil)
    end
end

-- Throws the character's running session away without saving it
-- (Ctrl-click Stop session, 2026-10-27).
function ActivitySessions:Discard()
    local db = DB()
    local guid = PlayerGUID()
    local session = db and guid and db.current[guid]
    if not session then
        return
    end
    db.current[guid] = nil
    Log("discarded %s (thrown away by the player)", tostring(session.name))
    self:SendMessage("MCG_SESSIONS_FILED")
end

-- Instance type of a session (2026-10-27): key + label for grouping in Gold
-- per Hour. nil for manual sessions (their name is their type).
--   party -> Dungeons, raid -> Raids, scenario with the delve difficulty ->
--   Delves, any other scenario -> Scenarios (renamed once the game shows what
--   labyrinths, ritual sites etc. report; each start is in the log with its
--   instanceType, instanceID and difficultyID).
-- Theoretical: delves use difficultyID 208.
local DELVE_DIFFICULTY = 208
local TYPE_LABELS = { dungeon = "Dungeons", raid = "Raids", delve = "Delves", scenario = "Scenarios" }

function ActivitySessions:GetSessionType(session)
    if not session or session.kind ~= "instance" then
        return nil, nil
    end
    local key
    if session.instanceType == "party" then
        key = "dungeon"
    elseif session.instanceType == "raid" then
        key = "raid"
    elseif session.instanceType == "scenario" and tonumber(session.difficultyID) == DELVE_DIFFICULTY then
        key = "delve"
    else
        key = "scenario"
    end
    return key, TYPE_LABELS[key]
end

-- filter = { name = <session name>, typeKey = <GetSessionType key> }.
--   name only    -> manual sessions with that name
--   typeKey only -> every instance session of that type
--   both         -> instance sessions of that type with that name
local function MatchesFilter(self, session, filter)
    local typeKey = self:GetSessionType(session)
    if filter.typeKey then
        if typeKey ~= filter.typeKey then
            return false
        end
    elseif typeKey ~= nil then
        return false
    end
    return filter.name == nil or session.name == filter.name
end

-- Number of saved sessions matching filter for this character (any age).
function ActivitySessions:CountSessions(guid, filter)
    local db = DB()
    local entry = db and db.history[guid]
    local count = 0
    for _, session in ipairs(entry and entry.sessions or {}) do
        if MatchesFilter(self, session, filter or {}) then
            count = count + 1
        end
    end
    return count
end

-- Deletes every saved session matching filter for this character (any age;
-- Ctrl-click a session row, 2026-10-27). A running session is not touched.
-- @return number deleted
function ActivitySessions:DeleteSessions(guid, filter)
    local db = DB()
    local entry = db and db.history[guid]
    filter = filter or {}
    if not entry or (filter.name == nil and filter.typeKey == nil) then
        return 0
    end
    local kept, deleted = {}, 0
    for _, session in ipairs(entry.sessions or {}) do
        if MatchesFilter(self, session, filter) then
            deleted = deleted + 1
        else
            kept[#kept + 1] = session
        end
    end
    entry.sessions = kept
    Log("deleted %d saved session(s) (name=%s type=%s)", deleted, tostring(filter.name), tostring(filter.typeKey))
    self:SendMessage("MCG_SESSIONS_FILED")
    return deleted
end

-- Renames this character's manual sessions called oldName (saved and running)
-- to newName (right-click a session row, 2026-10-27). If newName is already
-- used, they combine into one row. Instance sessions keep the game's names.
-- @return number of saved sessions renamed
function ActivitySessions:RenameSessions(guid, oldName, newName)
    local db = DB()
    newName = tostring(newName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not db or not guid or not oldName or newName == "" or newName == oldName then
        return 0
    end
    local renamed = 0
    local entry = db.history[guid]
    for _, session in ipairs(entry and entry.sessions or {}) do
        if session.kind == "manual" and session.name == oldName then
            session.name = newName
            renamed = renamed + 1
        end
    end
    local current = db.current[guid]
    if current and current.kind == "manual" and current.name == oldName then
        current.name = newName
    end
    for index, name in ipairs(db.recentNames) do
        if name == oldName then
            table.remove(db.recentNames, index)
            break
        end
    end
    NoteRecentName(db, newName)
    Log("renamed %d saved session(s) %s -> %s", renamed, tostring(oldName), newName)
    self:SendMessage("MCG_SESSIONS_FILED")
    return renamed
end

-- The character's most recently finished session, or nil.
function ActivitySessions:GetLastSession(guid)
    local entry = self:GetHistory()[guid or PlayerGUID() or ""]
    local list = entry and entry.sessions or {}
    return list[#list]
end

function ActivitySessions:GetRecentNames()
    local db = DB()
    return db and db.recentNames or {}
end

function ActivitySessions:GetHistory()
    local db = DB()
    return db and db.history or {}
end

-- current[characterGUID] = session
function ActivitySessions:GetCurrentSessions()
    local db = DB()
    return db and db.current or {}
end

-- ---------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------

local function InstanceName(name, difficultyName)
    if difficultyName and difficultyName ~= "" and difficultyName ~= "Normal" then
        return string.format("%s (%s)", tostring(name), difficultyName)
    end
    return tostring(name)
end

-- Run on zone changes, loading screens and every TICK_SECONDS.
function ActivitySessions:CheckInstance()
    local db = DB()
    local guid = PlayerGUID()
    if not db or not guid then
        return
    end
    local now = Now()
    local current = db.current[guid]
    if current and (current.kind == "manual" or current.pausedAt) then
        return
    end

    local inInstance = IsInInstance and IsInInstance()
    local name, instanceType, difficultyID, difficultyName, instanceID
    if inInstance and GetInstanceInfo then
        local info = { pcall(GetInstanceInfo) }
        if info[1] then
            name, instanceType, difficultyID, difficultyName = info[2], info[3], info[4], info[5]
            instanceID = info[9]
        end
    end
    local inside = inInstance and name and INSTANCE_TYPES[instanceType] or false

    if inside then
        local same = current and current.instanceID == instanceID and current.difficultyID == difficultyID
        if same and current.outsideSince then
            local gap = now - current.outsideSince
            if gap <= REENTER_SECONDS then
                current.seconds = (current.seconds or 0) + math.max(0, gap)
                current.outsideSince = nil
                current.activeSince = now
                current.entries = (current.entries or 1) + 1
                Log("back in %s after %ds (entry %d)", tostring(current.name), gap, current.entries)
                self:SendMessage("MCG_SESSIONS_UPDATED")
                return
            end
            self:File(guid, current.outsideSince)
            current = nil
        elseif same then
            if not current.activeSince then
                current.activeSince = now
            end
            return
        elseif current then
            self:File(guid, current.outsideSince or now)
            current = nil
        end
        db.current[guid] = NewSession("instance", InstanceName(name, difficultyName), {
            instanceID = instanceID,
            difficultyID = difficultyID,
            instanceType = instanceType,
            entries = 1,
        })
        Log("started %s (instance %s, id=%s, difficulty=%s)", InstanceName(name, difficultyName),
            tostring(instanceType), tostring(instanceID), tostring(difficultyID))
        self:SendMessage("MCG_SESSIONS_FILED")
        return
    end

    if current and current.kind == "instance" then
        if not current.outsideSince then
            Bank(current, now)
            current.activeSince = nil
            current.outsideSince = current.lastBankAt or now
            Log("left %s", tostring(current.name))
            self:SendMessage("MCG_SESSIONS_UPDATED")
        elseif now - current.outsideSince > REENTER_SECONDS then
            self:File(guid, current.outsideSince)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Loot and gold
-- ---------------------------------------------------------------------------

-- One item that came in during the session (Item Ledger entry).
local function AddItem(session, entry)
    local key = entry.link or ("item:" .. tostring(entry.iid))
    local item = session.items[key] or { looted = 0, sold = 0, soldCopper = 0 }
    session.items[key] = item
    item.itemID = entry.iid
    item.name = item.name or ItemName(key)
    item.looted = item.looted + (tonumber(entry.qty) or 1)
    Log("%s %s x%d", tostring(entry.cat), tostring(item.name or key), tonumber(entry.qty) or 1)
end

-- Mats used in a craft during the session (craft out entry): counted as used,
-- so their value comes off what the session made.
local function AddUsed(session, entry)
    local key = entry.link or ("item:" .. tostring(entry.iid))
    local item = session.items[key] or { looted = 0, sold = 0, soldCopper = 0 }
    session.items[key] = item
    item.itemID = entry.iid
    item.name = item.name or ItemName(key)
    local qty = tonumber(entry.qty) or 1
    local booked = math.min(qty, tonumber(entry.bvq) or 0)
    item.used = (item.used or 0) + (qty - booked)
    if booked > 0 then
        item.usedBook = (item.usedBook or 0) + (tonumber(entry.bv) or 0)
    end
    Log("%s used %s x%d (book value %d units %s)", tostring(entry.cat), tostring(item.name or key), qty,
        booked, FormatCopper(tonumber(entry.bv) or 0))
end

local function AddCurrency(session, entry)
    session.currencies = session.currencies or {}
    local row = session.currencies[entry.iid] or { gained = 0, spent = 0 }
    session.currencies[entry.iid] = row
    if entry.dir == "out" then
        row.spent = row.spent + (tonumber(entry.qty) or 0)
    else
        row.gained = row.gained + (tonumber(entry.qty) or 0)
    end
    Log("currency %s %s%d", tostring(entry.iid), entry.dir == "out" and "-" or "+", tonumber(entry.qty) or 0)
end

-- Every Item Ledger entry (gold, items, currencies) while a session runs.
function ActivitySessions:OnLedgerEntry(entry)
    local session = self:GetCurrent()
    if not session or type(entry) ~= "table" then
        return
    end
    -- Paused: only something this session would count asks to resume.
    local counts = (entry.kind == "gold" and entry.cat ~= "transfer")
        or (not NOT_COUNTED[entry.cat] and (CountsItem(entry) or entry.kind == "currency"))
    if counts and self:HoldIfPaused(function() ActivitySessions:OnLedgerEntry(entry) end) then
        return
    end
    if entry.kind == "gold" then
        local delta = (entry.dir == "out" and -1 or 1) * (tonumber(entry.qty) or 0)
        local item = entry.src and { name = entry.src, quantity = entry.units or 1 } or nil
        self:OnGoldRecorded(nil, delta, entry.cat, entry.prof, item, entry.at)
        return
    end
    if NOT_COUNTED[entry.cat] or (tonumber(entry.at) or Now()) < (session.startedAt or 0) then
        return
    end
    if CountsItem(entry) and entry.dir == "in" then
        AddItem(session, entry)
    elseif CountsItem(entry) then
        AddUsed(session, entry)
    elseif entry.kind == "currency" then
        AddCurrency(session, entry)
    else
        return
    end
    self:SendMessage("MCG_SESSIONS_UPDATED")
end

-- A container opened during the session is used up (its contents came in as
-- ledger entries just before this message).
function ActivitySessions:OnContainerOpening(opening)
    local session = self:GetCurrent()
    local opens = tonumber(opening and opening.opens) or 0
    local itemID = tonumber(opening and opening.itemID)
    if not session or opens <= 0 or not itemID then
        return
    end
    if self:HoldIfPaused(function() ActivitySessions:OnContainerOpening(opening) end) then
        return
    end
    local target, targetKey = nil, nil
    for key, item in pairs(session.items) do
        if item.itemID == itemID then
            target, targetKey = item, key
            break
        end
    end
    if not target then
        targetKey = opening.link or ("item:" .. tostring(itemID))
        target = { itemID = itemID, looted = 0, sold = 0, soldCopper = 0 }
        session.items[targetKey] = target
    end
    target.name = target.name or ItemName(targetKey)
    target.used = (target.used or 0) + opens
    Log("opened %s x%d", tostring(target.name or targetKey), opens)
    self:SendMessage("MCG_SESSIONS_UPDATED")
end

-- One gold change (from the ledger entry, see OnLedgerEntry).
function ActivitySessions:OnGoldRecorded(_, delta, category, professionKey, item, timestamp)
    local session = self:GetCurrent()
    delta = tonumber(delta) or 0
    if not session or delta == 0 or category == "transfer" then
        return
    end
    if (tonumber(timestamp) or Now()) < (session.startedAt or 0) then
        Log("gold %s %s earned before the session, not counted", FormatCopper(delta), tostring(category))
        return
    end
    -- Vendor and AH sales (2026-11-05) write the item out themselves (book
    -- value comes off), so sale gold is plain gold in. The old name-matching
    -- rule (sale gold replacing the loot's value) is gone: with both, the item
    -- would be subtracted twice.
    local rest = delta
    if rest ~= 0 then
        local row = session.gold[category] or { income = 0, spend = 0 }
        session.gold[category] = row
        if rest > 0 then
            row.income = row.income + rest
        else
            row.spend = row.spend - rest
        end
    end
    Log("gold %s %s", FormatCopper(delta), tostring(category))
    self:SendMessage("MCG_SESSIONS_UPDATED")
end

-- ---------------------------------------------------------------------------
-- Value
-- ---------------------------------------------------------------------------

-- Value of one unit of a looted item now (see the header for the rules).
-- @return copper or nil (no price at all)
function ActivitySessions:GetUnitValue(link, itemID, enchanter, priceCache)
    local cacheKey = tostring(link) .. (enchanter and "|e" or "")
    if priceCache and priceCache[cacheKey] ~= nil then
        return priceCache[cacheKey] or nil
    end
    local ok, name, _, _, _, _, _, _, _, _, _, sellPrice, _, _, bindType = pcall(GetItemInfo, link)
    sellPrice = ok and tonumber(sellPrice) or 0
    local value
    if ok and name and BOUND[tonumber(bindType)] then
        -- BoP (Brian 2026-11-05): no gold value while held. What it brings
        -- when it leaves (vendor gold, disenchant mats) is the gain. Was
        -- vendor price (or disenchant estimate for enchanters).
        value = 0
    else
        local runs = PocketCFO:GetModule("ActivityRuns", true)
        value = runs and runs.GetUnitValue and runs:GetUnitValue(itemID, link) or nil
        if not value and sellPrice > 0 then
            value = sellPrice
        end
    end
    if priceCache and (value or (ok and name)) then
        priceCache[cacheKey] = value or false
    end
    return value
end

-- Value of one unit of a currency now (a registered currency rule), or nil.
local function CurrencyUnitValue(currencyID)
    local valuation = _G.PocketCFO_Valuation
    local service = valuation and valuation.GetModule and valuation:GetModule("ValuationService", true)
    if not service then
        return nil
    end
    local ok, result = pcall(service.GetCurrencyValue, service, currencyID)
    if ok and type(result) == "table" and not result.unresolved then
        return tonumber(result.valuePerUnit or result.value)
    end
    return nil
end

-- { seconds, copper, perHour, goldIn, goldOut, soldCopper, keptCopper,
--   keptUnpriced, currencyCopper, currencies = { [id] = { net, unit } },
--   gold = { [category] = { income, spend } } } for a session.
-- Kept items are valued at today's price; containers opened count against
-- the container (used); currencies where a value exists.
function ActivitySessions:GetStats(session, priceCache, now)
    local stats = { seconds = self:GetSeconds(session, now), goldIn = 0, goldOut = 0,
        soldCopper = 0, keptCopper = 0, keptUnpriced = 0, currencyCopper = 0, currencies = {}, gold = {} }
    if not session then
        return stats
    end
    for category, row in pairs(session.gold or {}) do
        stats.goldIn = stats.goldIn + (tonumber(row.income) or 0)
        stats.goldOut = stats.goldOut + (tonumber(row.spend) or 0)
        stats.gold[category] = row
    end
    for link, entry in pairs(session.items or {}) do
        stats.soldCopper = stats.soldCopper + (tonumber(entry.soldCopper) or 0)
        stats.keptCopper = stats.keptCopper - (tonumber(entry.usedBook) or 0)
        local kept = (tonumber(entry.looted) or 0) - (tonumber(entry.sold) or 0) - (tonumber(entry.used) or 0)
        if kept ~= 0 then
            local unit = self:GetUnitValue(link, entry.itemID, session.enchanter, priceCache)
            if unit then
                stats.keptCopper = stats.keptCopper + unit * kept
            elseif kept > 0 then
                stats.keptUnpriced = stats.keptUnpriced + kept
            end
        end
    end
    for currencyID, row in pairs(session.currencies or {}) do
        local net = (tonumber(row.gained) or 0) - (tonumber(row.spent) or 0)
        local unit = net ~= 0 and CurrencyUnitValue(currencyID) or nil
        stats.currencies[currencyID] = { net = net, unit = unit }
        if unit then
            stats.currencyCopper = stats.currencyCopper + unit * net
        end
    end
    stats.copper = stats.goldIn - stats.goldOut + stats.soldCopper + stats.keptCopper + stats.currencyCopper
    local runs = PocketCFO:GetModule("ActivityRuns", true)
    stats.perHour = runs and runs.PerHour and runs:PerHour(stats.copper, stats.seconds) or nil
    return stats
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function ActivitySessions:OnTick()
    local session = self:GetCurrent()
    if session then
        if session.pausedAt and (Now() - session.pausedAt) > PAUSE_LIMIT_SECONDS then
            Log("%s paused over %ds, filed", tostring(session.name), PAUSE_LIMIT_SECONDS)
            self:File(PlayerGUID(), session.pausedAt)
            return
        end
        Bank(session)
    end
    self:CheckInstance()
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGOUT" then
        local session = ActivitySessions:GetCurrent()
        if session then
            Bank(session)
        end
    else
        ActivitySessions:CheckInstance()
    end
end)

-- Logging off (2026-10-31, agreed with Brian; custom sessions changed 2026-11-05):
--   An intentional logout / exit (core ActivityControl sees Logout() / Quit()
--   or the logout countdown) ends an instance session, filed at that moment
--   (EndForLogout). A custom (manual) session is NOT ended by a logout: a
--   restart to install an addon or patch looks the same as being done, so a
--   logout is treated like a disconnect. The clock was banked at logout, time
--   offline isn't counted, and logging back in within ABANDONED_SECONDS
--   continues it; otherwise FileAbandoned files it, ended at the logout.
--   A disconnect doesn't end any session: logging back in continues it.
--   Safety: on login, any character's session that has been offline longer
--   than ABANDONED_SECONDS (a disconnect you never came back from, Alt-F4, a
--   custom session left on another character) is filed, ended when it went
--   offline (its last bank, or where it was paused). /reload changes nothing.
local ABANDONED_SECONDS = 1800

function ActivitySessions:EndForLogout()
    local guid = PlayerGUID()
    local session = guid and self:GetCurrent(guid)
    if session and session.kind == "manual" then
        -- Custom sessions survive a logout (2026-11-05); the clock was banked.
        Log("logged out: %s kept (custom session)", tostring(session.name))
        return
    end
    if session then
        Log("logged out: %s ended", tostring(session.name))
        self:File(guid, session.pausedAt or Now())
    end
end

function ActivitySessions:FileAbandoned()
    local db = DB()
    if not db then
        return
    end
    local now = Now()
    local guids = {}
    for guid in pairs(db.current) do
        guids[#guids + 1] = guid
    end
    for _, guid in ipairs(guids) do
        local session = db.current[guid]
        local lastSeen = tonumber(session.lastBankAt) or tonumber(session.startedAt) or now
        if now - lastSeen > ABANDONED_SECONDS then
            Log("%s offline %ds, filed", tostring(session.name), now - lastSeen)
            self:File(guid, session.pausedAt or lastSeen)
        end
    end
end

function ActivitySessions:OnEnable()
    self:FileAbandoned()
    -- Back from a logout or reload: the clock was banked at logout (or at the
    -- last tick after a crash). A manual session resumes now; an instance
    -- session is settled by CheckInstance (back inside = continue).
    local session = self:GetCurrent()
    if session and session.pausedAt then
        -- Paused before the logout / reload: stays paused (clock stopped).
        session.activeSince = nil
    elseif session then
        if session.kind == "manual" then
            session.activeSince = Now()
        elseif not session.outsideSince then
            session.activeSince = nil
            session.outsideSince = session.lastBankAt or Now()
        end
    end
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("PLAYER_LOGOUT")
    if messenger and not self.listening then
        messenger:RegisterMessage("MCG_ITEM_LEDGER_ENTRY", function(_, entry)
            ActivitySessions:OnLedgerEntry(entry)
        end)
        messenger:RegisterMessage("MCG_CONTAINER_OPENING", function(_, opening)
            ActivitySessions:OnContainerOpening(opening)
        end)
        self.listening = true
    end
    if C_Timer and C_Timer.NewTicker then
        self.ticker = C_Timer.NewTicker(TICK_SECONDS, function() ActivitySessions:OnTick() end)
    end
end

-- ---------------------------------------------------------------------------
-- Diagnostics: /mcg sessions - current session, recent sessions, event log
-- ---------------------------------------------------------------------------

function ActivitySessions:BuildReport()
    local lines = {}
    local cache = {}
    local function Describe(prefix, session)
        local stats = self:GetStats(session, cache)
        lines[#lines + 1] = string.format("%s%s [%s] %ds  total=%s  in=%s out=%s sold=%s kept=%s currencies=%s%s",
            prefix, tostring(session.name), tostring(session.kind), stats.seconds, FormatCopper(stats.copper),
            FormatCopper(stats.goldIn), FormatCopper(-stats.goldOut), FormatCopper(stats.soldCopper),
            FormatCopper(stats.keptCopper), FormatCopper(stats.currencyCopper),
            stats.keptUnpriced > 0 and string.format(" (%d unpriced)", stats.keptUnpriced) or "")
    end
    local current = self:GetCurrent()
    lines[#lines + 1] = "=== Current ==="
    if current then
        Describe("  ", current)
        for link, entry in pairs(current.items or {}) do
            lines[#lines + 1] = string.format("    %s in=%d sold=%d used=%d soldCopper=%s", tostring(entry.name or link),
                entry.looted or 0, entry.sold or 0, entry.used or 0, FormatCopper(entry.soldCopper or 0))
        end
        for currencyID, row in pairs(current.currencies or {}) do
            lines[#lines + 1] = string.format("    currency %s gained=%d spent=%d", tostring(currencyID),
                row.gained or 0, row.spent or 0)
        end
        for category, row in pairs(current.gold or {}) do
            lines[#lines + 1] = string.format("    gold %s in=%s out=%s", category, FormatCopper(row.income),
                FormatCopper(-row.spend))
        end
    else
        lines[#lines + 1] = "  (none)"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== Recent (this character) ==="
    local entry = self:GetHistory()[PlayerGUID() or ""]
    local list = entry and entry.sessions or {}
    for index = #list, math.max(1, #list - 9), -1 do
        Describe("  " .. date("%m-%d %H:%M", list[index].startedAt or 0) .. "  ", list[index])
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== Log ==="
    for _, line in ipairs((DB() or {}).log or {}) do
        lines[#lines + 1] = "  " .. line
    end
    return table.concat(lines, "\n")
end

local diagnostics = PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("sessions", {
        name = "sessions",
        description = "Show the current session, recent sessions and the session event log.",
        usage = "/mcg sessions",
        category = "General",
    }, function()
        diagnostics:ShowDump("Sessions", ActivitySessions:BuildReport())
    end)
end
