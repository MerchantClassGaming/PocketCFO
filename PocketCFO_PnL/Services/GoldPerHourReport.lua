-- PocketCFO_PnL/Services/GoldPerHourReport.lua
-- View models for Gold per Hour (the Gold window's Gold per Hour tab and the
-- tracker window), from core ActivityRuns and ActivitySessions.
--   Now / Last: this character's session or run in progress, or the last
--     finished one. Value at loot time (runs) / GetStats (sessions).
--   Best use of your time: every character + activity ranked by gold per hour
--     (a character's Grand beasts runs are their own row, 2026-10-26) over the
--     picked period (Today / 7 Days / 30 Days / All, 2026-10-31; was always
--     30 days) and toon (the Gold window's toon filter), every run re-priced
--     at today's prices (ActivityRuns:ValueAtToday) so old runs at old prices
--     don't mislead. A row needs MIN_RANK_SECONDS of run time to be ranked
--     (Today: no minimum beyond the one minute a rate needs, Brian
--     2026-10-31: a quick Grand Beasts route never reaches 10 minutes, and
--     today's numbers are today's numbers);
--     below that it is listed as not enough data yet. Beast rows subtract the
--     lures used, at their cost that day (never re-priced); a lure with no
--     cost yet shows "no lure price".
--   Expanding a row shows everything per hour (Brian 2026-10-26):
--     professions / beast loot: what each part adds per hour of the row's run
--       time (its value / the row's total seconds), so the parts add up to
--       the row's rate; lures as a negative per hour;
--     "By profession" (2026-10-31): only for gathering rows of a character
--       with 2+ gathering professions (ActivityRuns:GetGatheringProfessions,
--       what the character has, not what was gathered); a profession with
--       nothing gathered shows as zero;
--     zones: gold per hour while in that zone (zone value / zone seconds);
--     recent (2026-10-31): the RECENT_RUNS most recent runs (or custom
--       sessions) of the row, newest first, each with its own time and rate
--       (same today's-price rule, minus that run's lures).
--   Sessions (2026-10-27, core ActivitySessions): a session in progress takes
--     the top line ("Session: <name>"); with nothing running, the top line is
--     whichever finished last, session or run. Ranked rows: manual sessions
--     one per character + name; instance sessions one per character + type
--     (Dungeons, Raids, Delves, Scenarios) with each instance below. Valued by
--     ActivitySessions:GetStats (gold in - gold out + loot sold + loot kept at
--     today's price). Details are split into Items and Gold, per hour.
--   Hiding (2026-10-27): every automatic row has a hideKey ("gathering:<label>",
--     "fishing", "beasts", "type:<dungeon|raid|delve|scenario>"). Rows whose
--     key is hidden (ActivityRuns ui.hidden, account-wide, set from the
--     Pocket CFO settings page since 2026-10-31) are left out of the ranking
--     and the top line. Capture is never affected. GetHideable lists every
--     automatic row tracked so far, hidden or not. Manual sessions can't be
--     hidden.
-- Design agreed with Brian 2026-10-23.

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL

local GoldPerHourReport = {}
PocketCFO_PnL.GoldPerHourReport = GoldPerHourReport

local MIN_RANK_SECONDS = 600
local MIN_RATE_SECONDS = 60   -- ActivityRuns:PerHour gives no rate below a minute
local RECENT_RUNS = 10

GoldPerHourReport.MIN_RANK_SECONDS = MIN_RANK_SECONDS

-- Run time a row needs to be ranked in this period.
function GoldPerHourReport:GetMinRankSeconds(periodKey)
    return periodKey == "today" and MIN_RATE_SECONDS or MIN_RANK_SECONDS
end

local PART_LABELS = { beastkill = "Beast kill loot" }

local function Runs()
    return PocketCFO:GetModule("ActivityRuns", true)
end

local function Sessions()
    return PocketCFO:GetModule("ActivitySessions", true)
end

-- Hidden row keys (settings page), account-wide in ActivityRuns ui state.
local function Hidden()
    local runs = Runs()
    local ui = runs and runs:GetUIState()
    if not ui then
        return {}
    end
    ui.hidden = ui.hidden or {}
    return ui.hidden
end

function GoldPerHourReport:GetHidden()
    return Hidden()
end

-- Hide key of a gathering run's row (its activity, or the character's
-- gathering label for plain gathering).
local function RunHideKey(runs, guid, activity)
    activity = activity or "gathering"
    if activity == "gathering" then
        return "gathering:" .. runs:GetActivityLabel(guid, "gathering")
    end
    return activity
end

local HIDE_ORDER = { fishing = 2, beasts = 3, ["type:dungeon"] = 4, ["type:raid"] = 5,
    ["type:delve"] = 6, ["type:scenario"] = 7 }

local function MergeItems(target, items)
    for itemID, entry in pairs(items or {}) do
        local merged = target[itemID] or { qty = 0, valuedQty = 0, copper = 0 }
        target[itemID] = merged
        merged.qty = merged.qty + (tonumber(entry.qty) or 0)
        merged.valuedQty = merged.valuedQty + (tonumber(entry.valuedQty) or 0)
        merged.copper = merged.copper + (tonumber(entry.copper) or 0)
        merged.link = merged.link or entry.link
    end
end

local function ColoredName(name, classFile)
    name = tostring(name or "?")
    local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if color and color.colorStr then
        return "|c" .. color.colorStr .. name .. "|r"
    end
    return name
end

function GoldPerHourReport:FormatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%d:%02d", minutes, secs)
end

function GoldPerHourReport:FormatHours(seconds)
    seconds = tonumber(seconds) or 0
    if seconds < 3600 then
        return string.format("%d min", math.floor(seconds / 60))
    end
    return string.format("%.1f hrs", seconds / 3600)
end

-- Start of the picked period (time()), or 0 for All.
local function PeriodCutoff(periodKey)
    local income = PocketCFO_PnL.IncomeReport
    local period = income:GetPeriod(periodKey)
    if not period.days then
        return 0, period
    end
    local t = date("*t")
    local midnight = time({ year = t.year, month = t.month, day = t.day, hour = 0 })
    return midnight - (period.days - 1) * 86400, period
end

function GoldPerHourReport:GetPeriodCaption(periodKey)
    local _, period = PeriodCutoff(periodKey)
    if not period.days then
        return "Everything saved, at today's prices"
    elseif period.days == 1 then
        return "Today, at today's prices"
    end
    return string.format("Last %d days, at today's prices", period.days)
end

-- Is this character in the view? Same rule as the rest of the Gold window.
local function Includes(guid, characterGUID)
    return PocketCFO_PnL.IncomeReport:IncludesCharacter(guid, characterGUID)
end

-- ---------------------------------------------------------------------------
-- Now / Last (top line)
-- ---------------------------------------------------------------------------

-- Top line for a gathering run (in progress or finished).
local function RunNow(runs, run, active)
    local stats = runs:GetRunStats(run)
    local title = (active and "Now: " or "Last run: ") .. runs:GetActivityLabel(UnitGUID("player"), stats.activity)
    if stats.zone and stats.zone ~= "?" and stats.activity ~= "beasts" then
        title = title .. " - " .. stats.zone
    end
    if not active and run.endedAt then
        title = title .. "  |cff888888" .. date("%b %d %H:%M", run.endedAt) .. "|r"
    end
    return {
        active = active,
        paused = active and run.pausedAt ~= nil,
        title = title,
        seconds = stats.seconds,
        copper = stats.copper,
        perHour = stats.perHour,
    }
end

-- Top line (2026-10-27): what is running now (a session first, then a
-- gathering run); if nothing is, whichever finished most recently, session
-- or run. Returns { active, paused, session, title, seconds, copper, perHour } or nil.
function GoldPerHourReport:BuildNow()
    local sessions = Sessions()
    local hidden = Hidden()
    local guid = UnitGUID("player")
    local function SessionHidden(s)
        local typeKey = s and sessions:GetSessionType(s)
        return typeKey ~= nil and hidden["type:" .. typeKey] == true
    end
    local session = sessions and sessions:GetCurrent()
    if session and SessionHidden(session) then
        session = nil
    end
    if session then
        local stats = sessions:GetStats(session, {})
        return {
            active = true,
            paused = session.pausedAt ~= nil,
            session = true,
            title = "Session: " .. tostring(session.name),
            seconds = stats.seconds,
            copper = stats.copper,
            perHour = stats.perHour,
        }
    end
    local runs = Runs()
    local function RunHidden(r)
        return r ~= nil and hidden[RunHideKey(runs, guid, r.activity)] == true
    end
    local run = runs and runs:GetCurrentRun()
    if run and not RunHidden(run) then
        return RunNow(runs, run, true)
    end
    local lastRun = runs and runs:GetLastRun()
    if RunHidden(lastRun) then
        lastRun = nil
    end
    local lastSession = sessions and sessions:GetLastSession()
    if lastSession and SessionHidden(lastSession) then
        lastSession = nil
    end
    local runEnded = lastRun and (lastRun.endedAt or lastRun.lastLootAt or 0) or nil
    if lastSession and (not runEnded or (lastSession.endedAt or 0) >= runEnded) then
        local stats = sessions:GetStats(lastSession, {})
        local title = "Last session: " .. tostring(lastSession.name)
        if lastSession.endedAt then
            title = title .. "  |cff888888" .. date("%b %d %H:%M", lastSession.endedAt) .. "|r"
        end
        return {
            active = false,
            session = true,
            title = title,
            seconds = stats.seconds,
            copper = stats.copper,
            perHour = stats.perHour,
        }
    end
    if lastRun then
        return RunNow(runs, lastRun, false)
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Ranking
-- ---------------------------------------------------------------------------

local function CharacterInfo(guid, history)
    local entry = history[guid]
    local goldDB = PocketCFO.db and PocketCFO.db.global and PocketCFO.db.global.gold
    local gold = goldDB and goldDB.characters and goldDB.characters[guid]
    local name = (entry and entry.name) or (gold and gold.name) or "?"
    local classFile = (entry and entry.classFile) or (gold and gold.classFile) or nil
    return name, classFile
end

-- One run's own line for the "recent runs" list.
local function RecentRunLine(runs, run, priceCache)
    local gross = runs:ValueAtToday(run.items, priceCache)
    local cost, costUnpriced = runs:GetRunCost(run)
    local seconds = runs:GetRunSeconds(run)
    local copper = gross - cost
    return {
        at = run.startedAt or run.endedAt or 0,
        label = date("%b %d %H:%M", run.startedAt or run.endedAt or 0),
        active = run.endedAt == nil,
        seconds = seconds,
        copper = copper,
        costUnpriced = costUnpriced,
        perHour = (not costUnpriced) and runs:PerHour(copper, seconds) or nil,
    }
end

local function NewestFirst(list)
    table.sort(list, function(a, b) return (a.at or 0) > (b.at or 0) end)
    while #list > RECENT_RUNS do
        table.remove(list)
    end
    return list
end

-- Ranking for a period and toon (characterGUID nil = all shown toons):
-- { ranked = { row }, unranked = { row }, hideable = { { key, label } } }
-- row = { key, label (activity), name (character), activity, runs, seconds, copper, cost, costUnpriced, perHour,
--         showProfessions, parts = { { label, copper, share, loots, perHour } },
--         zones = { { label, seconds, copper, perHour } },
--         recent = { { label, active, seconds, copper, perHour, costUnpriced } } }
function GoldPerHourReport:BuildRanking(periodKey, characterGUID)
    local runs = Runs()
    local minSeconds = self:GetMinRankSeconds(periodKey)
    local model = { ranked = {}, unranked = {}, hideable = {}, minSeconds = minSeconds }
    if not runs then
        return model
    end
    local cutoff = PeriodCutoff(periodKey)
    local priceCache = {}   -- each item priced once per build
    local history = runs:GetHistory()
    local byCharacter = {}

    local function Collect(guid, run)
        local activity = run.activity or "gathering"
        local key = guid .. ":" .. activity
        local character = byCharacter[key] or { guid = guid, activity = activity, runs = 0, seconds = 0,
            cost = 0, items = {}, parts = {}, zones = {}, runList = {} }
        byCharacter[key] = character
        character.runs = character.runs + 1
        character.runList[#character.runList + 1] = run
        local cost, costUnpriced = runs:GetRunCost(run)
        character.cost = character.cost + cost
        character.costUnpriced = character.costUnpriced or costUnpriced
        character.seconds = character.seconds + runs:GetRunSeconds(run)
        MergeItems(character.items, run.items)
        for partKey, part in pairs(run.parts or {}) do
            local merged = character.parts[partKey] or { loots = 0, items = {} }
            character.parts[partKey] = merged
            merged.loots = merged.loots + (tonumber(part.loots) or 0)
            MergeItems(merged.items, part.items)
        end
        for zoneName, zone in pairs(run.zones or {}) do
            local merged = character.zones[zoneName] or { seconds = 0, items = {} }
            character.zones[zoneName] = merged
            merged.seconds = merged.seconds + (tonumber(zone.seconds) or 0)
            MergeItems(merged.items, zone.items)
        end
    end

    for guid, entry in pairs(history) do
        if Includes(guid, characterGUID) then
            for _, run in ipairs(entry.runs or {}) do
                if (run.endedAt or run.lastLootAt or 0) >= cutoff then
                    Collect(guid, run)
                end
            end
        end
    end
    for guid, run in pairs(runs:GetCurrentRuns()) do
        if Includes(guid, characterGUID) then
            Collect(guid, run)
        end
    end

    local income = PocketCFO_PnL.IncomeReport
    for key, character in pairs(byCharacter) do
        local name, classFile = CharacterInfo(character.guid, history)
        local gross = runs:ValueAtToday(character.items, priceCache)
        local copper = gross - character.cost
        local row = {
            key = key,
            hideKey = RunHideKey(runs, character.guid, character.activity),
            label = runs:GetActivityLabel(character.guid, character.activity),
            name = ColoredName(name, classFile),
            activity = character.activity,
            runs = character.runs,
            seconds = character.seconds,
            copper = copper,
            cost = character.cost,
            costUnpriced = character.costUnpriced,
            costPerHour = runs:PerHour(character.cost, character.seconds),
            perHour = (not character.costUnpriced) and runs:PerHour(copper, character.seconds) or nil,
            parts = {},
            zones = {},
            recent = {},
        }
        for partKey, part in pairs(character.parts) do
            local partCopper = runs:ValueAtToday(part.items, priceCache)
            row.parts[#row.parts + 1] = {
                key = partKey,
                label = PART_LABELS[partKey] or income:GetProfessionLabel(partKey),
                copper = partCopper,
                share = gross > 0 and (partCopper / gross) or 0,
                loots = part.loots,
                perHour = runs:PerHour(partCopper, character.seconds),
            }
        end
        -- By profession: what the character has (2026-10-31). Gathering rows
        -- only, 2+ professions; one it has but gathered nothing of shows as 0.
        if character.activity == "gathering" then
            local professions = runs:GetGatheringProfessions(character.guid)
            row.showProfessions = #professions >= 2
            local present = {}
            for _, part in ipairs(row.parts) do
                present[part.key] = true
            end
            for _, professionKey in ipairs(professions) do
                if not present[professionKey] then
                    row.parts[#row.parts + 1] = { key = professionKey, label = income:GetProfessionLabel(professionKey),
                        copper = 0, share = 0, loots = 0, perHour = row.seconds >= 60 and 0 or nil }
                end
            end
        end
        table.sort(row.parts, function(a, b)
            if a.copper ~= b.copper then
                return a.copper > b.copper
            end
            return a.label < b.label
        end)
        for zoneName, zone in pairs(character.zones) do
            local zoneCopper = runs:ValueAtToday(zone.items, priceCache)
            row.zones[#row.zones + 1] = {
                label = zoneName,
                seconds = zone.seconds,
                copper = zoneCopper,
                perHour = runs:PerHour(zoneCopper, zone.seconds),
            }
        end
        table.sort(row.zones, function(a, b) return (a.perHour or -1) > (b.perHour or -1) end)
        for _, run in ipairs(character.runList) do
            row.recent[#row.recent + 1] = RecentRunLine(runs, run, priceCache)
        end
        NewestFirst(row.recent)

        if character.seconds >= minSeconds and (row.perHour or row.costUnpriced) then
            model.ranked[#model.ranked + 1] = row
        else
            model.unranked[#model.unranked + 1] = row
        end
    end
    self:AddSessionRows(model, runs, cutoff, characterGUID, minSeconds)

    -- Hiding: list every automatic row, then drop hidden ones.
    local hidden = Hidden()
    local seenKeys = {}
    for _, listName in ipairs({ "ranked", "unranked" }) do
        local kept = {}
        for _, row in ipairs(model[listName]) do
            if row.hideKey and not seenKeys[row.hideKey] then
                seenKeys[row.hideKey] = true
                model.hideable[#model.hideable + 1] = { key = row.hideKey, label = row.label }
            end
            if not (row.hideKey and hidden[row.hideKey]) then
                kept[#kept + 1] = row
            end
        end
        model[listName] = kept
    end
    table.sort(model.hideable, function(a, b)
        local oa, ob = HIDE_ORDER[a.key] or 1, HIDE_ORDER[b.key] or 1
        if oa ~= ob then
            return oa < ob
        end
        return a.label < b.label
    end)

    table.sort(model.ranked, function(a, b) return (a.perHour or -1) > (b.perHour or -1) end)
    table.sort(model.unranked, function(a, b) return a.seconds > b.seconds end)
    return model
end

-- Every automatic row tracked so far (all time, all toons), hidden or not,
-- for the settings page: { { key, label } }.
function GoldPerHourReport:GetHideable()
    local runs = Runs()
    local list, seen = {}, {}
    local function Add(key, label)
        if key and not seen[key] then
            seen[key] = true
            list[#list + 1] = { key = key, label = label }
        end
    end
    if runs then
        local function Note(guid, run)
            Add(RunHideKey(runs, guid, run.activity), runs:GetActivityLabel(guid, run.activity))
        end
        for guid, entry in pairs(runs:GetHistory()) do
            for _, run in ipairs(entry.runs or {}) do
                Note(guid, run)
            end
        end
        for guid, run in pairs(runs:GetCurrentRuns()) do
            Note(guid, run)
        end
    end
    local sessions = Sessions()
    if sessions then
        local function NoteSession(session)
            local typeKey, typeLabel = sessions:GetSessionType(session)
            if typeKey then
                Add("type:" .. typeKey, typeLabel)
            end
        end
        for _, entry in pairs(sessions:GetHistory()) do
            for _, session in ipairs(entry.sessions or {}) do
                NoteSession(session)
            end
        end
        for _, session in pairs(sessions:GetCurrentSessions()) do
            NoteSession(session)
        end
    end
    table.sort(list, function(a, b)
        local oa, ob = HIDE_ORDER[a.key] or 1, HIDE_ORDER[b.key] or 1
        if oa ~= ob then
            return oa < ob
        end
        return a.label < b.label
    end)
    return list
end

-- Session rows (2026-10-27).
--   Manual sessions: one top row per character + session name, with its
--   RECENT_RUNS most recent sessions (2026-10-31).
--   Instance sessions: one top row per character + instance type (Dungeons,
--   Raids, Delves, Scenarios; ActivitySessions:GetSessionType), with one
--   child per instance (name includes difficulty).
-- row.isSession = true; row.deleteFilter / child.deleteFilter feed
-- ActivitySessions:DeleteSessions. Details: row.items / row.gold =
-- { { label, copper, perHour } } (gold spending negative).

local function NewGroup()
    return { runs = 0, seconds = 0, copper = 0, kept = 0, sold = 0, currencies = 0, keptUnpriced = 0, income = {}, spend = {} }
end

local function AddStats(group, stats)
    group.runs = group.runs + 1
    group.seconds = group.seconds + stats.seconds
    group.copper = group.copper + stats.copper
    group.kept = group.kept + stats.keptCopper
    group.sold = group.sold + stats.soldCopper
    group.currencies = group.currencies + (stats.currencyCopper or 0)
    group.keptUnpriced = group.keptUnpriced + stats.keptUnpriced
    for category, row in pairs(stats.gold) do
        group.income[category] = (group.income[category] or 0) + (tonumber(row.income) or 0)
        group.spend[category] = (group.spend[category] or 0) + (tonumber(row.spend) or 0)
    end
end

-- Fills the shared fields of a session row or child from a group.
local function FillFromGroup(target, group, runs)
    local income = PocketCFO_PnL.IncomeReport
    target.runs = group.runs
    target.seconds = group.seconds
    target.copper = group.copper
    target.perHour = runs:PerHour(group.copper, group.seconds)
    target.keptUnpriced = group.keptUnpriced
    target.items, target.gold = {}, {}
    local function Add(list, label, copper)
        if copper ~= 0 then
            list[#list + 1] = { label = label, copper = copper, perHour = runs:PerHour(copper, group.seconds) }
        end
    end
    Add(target.items, "Still in your bags", group.kept)
    Add(target.items, "Sold", group.sold)
    Add(target.items, "Currencies", group.currencies)
    local categories = {}
    for category in pairs(group.income) do
        categories[#categories + 1] = category
    end
    table.sort(categories, function(a, b) return (group.income[a] or 0) > (group.income[b] or 0) end)
    for _, category in ipairs(categories) do
        Add(target.gold, income:GetCategoryLabel(category), group.income[category])
    end
    for _, category in ipairs(categories) do
        Add(target.gold, income:GetCategoryLabel(category), -(group.spend[category] or 0))
    end
    return target
end

function GoldPerHourReport:AddSessionRows(model, runs, cutoff, characterGUID, minSeconds)
    local sessions = Sessions()
    if not sessions then
        return
    end
    local history = sessions:GetHistory()
    local cache = {}
    local tops = {}

    local function Collect(guid, session)
        local stats = sessions:GetStats(session, cache)
        local typeKey, typeLabel = sessions:GetSessionType(session)
        local name = tostring(session.name or "?")
        local topKey = typeKey and (guid .. ":type:" .. typeKey) or (guid .. ":session:" .. name)
        local top = tops[topKey]
        if not top then
            top = { guid = guid, key = topKey, label = typeLabel or name, typeKey = typeKey, name = name,
                group = NewGroup(), children = {}, recent = {} }
            tops[topKey] = top
        end
        AddStats(top.group, stats)
        if typeKey then
            local child = top.children[name]
            if not child then
                child = { name = name, group = NewGroup() }
                top.children[name] = child
            end
            AddStats(child.group, stats)
        else
            top.recent[#top.recent + 1] = {
                at = session.startedAt or 0,
                label = date("%b %d %H:%M", session.startedAt or 0),
                active = session.endedAt == nil,
                seconds = stats.seconds,
                copper = stats.copper,
                perHour = stats.perHour,
            }
        end
    end

    for guid, entry in pairs(history) do
        if Includes(guid, characterGUID) then
            for _, session in ipairs(entry.sessions or {}) do
                if (session.endedAt or 0) >= cutoff then
                    Collect(guid, session)
                end
            end
        end
    end
    for guid, session in pairs(sessions:GetCurrentSessions()) do
        if Includes(guid, characterGUID) then
            Collect(guid, session)
        end
    end

    for _, top in pairs(tops) do
        local name, classFile = CharacterInfo(top.guid, history)
        local row = FillFromGroup({
            key = top.key,
            label = top.label,
            name = ColoredName(name, classFile),
            activity = "session",
            isSession = true,
            isManual = top.typeKey == nil,
            typeKey = top.typeKey,
            hideKey = top.typeKey and ("type:" .. top.typeKey) or nil,
            guid = top.guid,
            deleteLabel = top.typeKey and top.label or ("\"" .. top.name .. "\""),
            deleteFilter = top.typeKey and { typeKey = top.typeKey } or { name = top.name },
            parts = {},
            zones = {},
            recent = NewestFirst(top.recent),
        }, top.group, runs)
        if top.typeKey then
            row.children = {}
            for childName, child in pairs(top.children) do
                row.children[#row.children + 1] = FillFromGroup({
                    key = top.key .. ":" .. childName,
                    label = childName,
                    deleteLabel = "\"" .. childName .. "\"",
                    deleteFilter = { typeKey = top.typeKey, name = childName },
                }, child.group, runs)
            end
            table.sort(row.children, function(a, b) return (a.perHour or -1) > (b.perHour or -1) end)
        end
        if row.seconds >= (minSeconds or MIN_RANK_SECONDS) and row.perHour then
            model.ranked[#model.ranked + 1] = row
        else
            model.unranked[#model.unranked + 1] = row
        end
    end
end
