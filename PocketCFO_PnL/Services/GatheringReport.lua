-- PocketCFO_PnL/Services/GatheringReport.lua
-- Builds the Gathering tab and session frame view models from core
-- GatheringCapture data. Value = value locked in when looted, plus items that
-- had no price then, valued at today's price (GatheringCapture:ValueItems).
-- Item value only: none of this is gold, so it never feeds Income.

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL

local GatheringReport = {}
PocketCFO_PnL.GatheringReport = GatheringReport

local MAX_SESSIONS = 5
local MIN_SECONDS_FOR_RATE = 60

local function Capture()
    return PocketCFO:GetModule("GatheringCapture", true)
end

local function ItemLabel(itemID, entry)
    if entry.link then
        return entry.link
    end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local ok, name = pcall(getInfo, itemID)
    return (ok and name) or ("item " .. tostring(itemID))
end

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

-- Gold per hour, or nil while the session is too short for a fair number.
function GatheringReport:PerHour(copper, seconds)
    seconds = tonumber(seconds) or 0
    if seconds < MIN_SECONDS_FOR_RATE then
        return nil
    end
    return math.floor((tonumber(copper) or 0) * 3600 / seconds)
end

function GatheringReport:FormatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then
        return string.format("%d:%02d:%02d", hours, minutes, secs)
    end
    return string.format("%d:%02d", minutes, secs)
end

-- Session numbers: { seconds, copper, unpriced, nodes, perHour }.
function GatheringReport:SessionStats(session, now)
    local capture = Capture()
    if not session or not capture then
        return nil
    end
    local copper, unpriced = capture:ValueItems(session.items)
    local seconds = (session.endedAt or now or time()) - (session.startedAt or 0)
    return {
        seconds = seconds,
        copper = copper,
        unpriced = unpriced,
        nodes = tonumber(session.nodes) or 0,
        perHour = self:PerHour(copper, seconds),
    }
end

-- Returns:
-- { available, period, total, nodes, unpriced,
--   professions = { { key, label, copper, nodes, items = { { label, copper, quantity } } } },
--   sessions = { { label, seconds, copper, perHour, nodes } } (newest first),
--   activeSession = session | nil }
function GatheringReport:Build(periodKey, characterGUID)
    local income = PocketCFO_PnL.IncomeReport
    local period = income:GetPeriod(periodKey)
    local capture = Capture()
    local model = {
        available = capture ~= nil,
        period = period,
        total = 0,
        nodes = 0,
        unpriced = 0,
        professions = {},
        sessions = {},
    }
    if not capture then
        return model
    end

    local days = capture:GetDays()
    local byProfession = {}
    for _, dayKey in ipairs(income:GetDayKeys(period.days, days)) do
        for guid, professions in pairs(days[dayKey] or {}) do
            if not characterGUID or guid == characterGUID then
                for professionKey, row in pairs(professions) do
                    local entry = byProfession[professionKey] or { nodes = 0, items = {} }
                    byProfession[professionKey] = entry
                    entry.nodes = entry.nodes + (tonumber(row.nodes) or 0)
                    MergeItems(entry.items, row.items)
                end
            end
        end
    end

    for professionKey, entry in pairs(byProfession) do
        local items = {}
        local professionCopper = 0
        for itemID, item in pairs(entry.items) do
            local copper, unpriced = capture:ValueItems({ [itemID] = item })
            professionCopper = professionCopper + copper
            model.unpriced = model.unpriced + unpriced
            items[#items + 1] = { label = ItemLabel(itemID, item), copper = copper, quantity = item.qty }
        end
        table.sort(items, function(a, b)
            if a.copper ~= b.copper then
                return a.copper > b.copper
            end
            return tostring(a.label) < tostring(b.label)
        end)
        model.professions[#model.professions + 1] = {
            key = professionKey,
            label = income:GetProfessionLabel(professionKey),
            copper = professionCopper,
            nodes = entry.nodes,
            items = items,
        }
        model.total = model.total + professionCopper
        model.nodes = model.nodes + entry.nodes
    end
    table.sort(model.professions, function(a, b)
        if a.copper ~= b.copper then
            return a.copper > b.copper
        end
        return a.label < b.label
    end)

    -- Recent finished sessions (all characters unless one is picked).
    local list = {}
    for guid, sessions in pairs(capture:GetSessions()) do
        if not characterGUID or guid == characterGUID then
            for _, session in ipairs(sessions) do
                list[#list + 1] = session
            end
        end
    end
    table.sort(list, function(a, b)
        return (a.startedAt or 0) > (b.startedAt or 0)
    end)
    for index = 1, math.min(MAX_SESSIONS, #list) do
        local session = list[index]
        local stats = self:SessionStats(session)
        model.sessions[#model.sessions + 1] = {
            label = date("%b %d %H:%M", session.startedAt or 0) .. (session.zone and ("  " .. session.zone) or ""),
            seconds = stats.seconds,
            copper = stats.copper,
            perHour = stats.perHour,
            nodes = stats.nodes,
        }
    end

    model.activeSession = capture:GetActiveSession()
    return model
end
