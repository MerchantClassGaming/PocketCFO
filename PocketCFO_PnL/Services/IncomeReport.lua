-- PocketCFO_PnL/Services/IncomeReport.lua
-- Builds the Income view model from core GoldLedger data.
-- Income only: transfers between your own characters are never counted.
-- "other" (gold changes we could not classify) is shown as "Everything else"
-- so the total matches the gold actually gained.

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL

local IncomeReport = {}
PocketCFO_PnL.IncomeReport = IncomeReport

local MAX_CHART_BARS = 30
local SECONDS_PER_DAY = 86400

IncomeReport.PERIODS = {
    { key = "today", label = "Today",   days = 1 },
    { key = "7",     label = "7 Days",  days = 7 },
    { key = "30",    label = "30 Days", days = 30 },
    { key = "all",   label = "All",     days = nil },
}
IncomeReport.DEFAULT_PERIOD = "7"

local CATEGORY_LABELS = {
    order_patron   = "Patron Orders",
    order_personal = "Personal Orders",
    order_public   = "Public Orders",
    order_guild    = "Guild Orders",
    order_unknown  = "Crafting Orders",
    auction        = "Auction House",
    vendor         = "Vendor",
    trade          = "Trade",
    mail           = "Mail",
    loot_quest     = "Loot & Quests",
    other          = "Unknown",
}

local EXCLUDED_CATEGORIES = {
    transfer = true,
}

-- ---------------------------------------------------------------------------
-- Dates (noon anchors so daylight saving changes never skip or repeat a day)
-- ---------------------------------------------------------------------------

local function NoonOf(year, month, day)
    return time({ year = year, month = month, day = day, hour = 12 })
end

local function TodayNoon()
    local t = date("*t")
    return NoonOf(t.year, t.month, t.day)
end

local function DayKeyAt(timestamp)
    return date("%Y-%m-%d", timestamp)
end

local function ParseDayKey(dayKey)
    local y, m, d = string.match(tostring(dayKey), "^(%d+)-(%d+)-(%d+)$")
    if not y then
        return nil
    end
    return NoonOf(tonumber(y), tonumber(m), tonumber(d))
end

local function DayKeysFor(days, ledgerDays)
    local today = TodayNoon()
    local count = days
    if not count then
        local earliest = today
        for dayKey in pairs(ledgerDays) do
            local noon = ParseDayKey(dayKey)
            if noon and noon < earliest then
                earliest = noon
            end
        end
        count = math.floor((today - earliest) / SECONDS_PER_DAY + 0.5) + 1
    end
    local keys = {}
    for offset = count - 1, 0, -1 do
        keys[#keys + 1] = DayKeyAt(today - offset * SECONDS_PER_DAY)
    end
    return keys
end

-- Shared with OrderReport: the day keys covered by a period ("all" starts at
-- the earliest day present in ledgerDays).
function IncomeReport:GetDayKeys(periodDays, ledgerDays)
    return DayKeysFor(periodDays, ledgerDays or {})
end

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------

function IncomeReport:GetCategoryLabel(category)
    return CATEGORY_LABELS[category] or tostring(category)
end

function IncomeReport:GetProfessionLabel(professionKey)
    if professionKey == nil or professionKey == "none" then
        return "No profession"
    end
    local registry = PocketCFO.ProfessionRegistry
    local config = registry and registry.GetProfessionConfig
        and registry:GetProfessionConfig(tonumber(professionKey))
    return config and config.name or tostring(professionKey)
end

-- ---------------------------------------------------------------------------
-- Model
-- ---------------------------------------------------------------------------

local function GetPeriod(periodKey)
    for _, period in ipairs(IncomeReport.PERIODS) do
        if period.key == periodKey then
            return period
        end
    end
    return IncomeReport.PERIODS[2]
end

function IncomeReport:GetPeriod(periodKey)
    return GetPeriod(periodKey)
end

local function SortedList(map, labelFn)
    local list = {}
    for key, copper in pairs(map) do
        list[#list + 1] = { key = key, label = labelFn(key), copper = copper }
    end
    table.sort(list, function(a, b)
        if a.copper ~= b.copper then
            return a.copper > b.copper
        end
        return a.label < b.label
    end)
    return list
end

local function SortedItems(itemMap)
    local items = {}
    for itemName, entry in pairs(itemMap or {}) do
        items[#items + 1] = { label = itemName, copper = entry.copper, quantity = entry.quantity }
    end
    table.sort(items, function(a, b)
        if a.copper ~= b.copper then
            return a.copper > b.copper
        end
        return a.label < b.label
    end)
    return items
end

local function BuildChartBuckets(daily)
    local bucketSize = math.max(1, math.ceil(#daily / MAX_CHART_BARS))
    local buckets = {}
    local index = 1
    while index <= #daily do
        local bucket = { firstDay = daily[index].dayKey, copper = 0, byCategory = {} }
        local last = math.min(#daily, index + bucketSize - 1)
        for i = index, last do
            local day = daily[i]
            bucket.lastDay = day.dayKey
            bucket.copper = bucket.copper + day.copper
            for category, copper in pairs(day.byCategory) do
                bucket.byCategory[category] = (bucket.byCategory[category] or 0) + copper
            end
        end
        if bucket.firstDay == bucket.lastDay then
            bucket.label = bucket.firstDay
        else
            bucket.label = bucket.firstDay .. " to " .. bucket.lastDay
        end
        buckets[#buckets + 1] = bucket
        index = last + 1
    end
    return buckets
end

-- Returns:
-- { total, period, sources = { { key, label, copper, share, expandable,
--     showProfessions, professions = {...}, items = { { label, copper, quantity } } } },
--   chart = { { label, copper, byCategory } } }
function IncomeReport:Build(periodKey, characterGUID)
    local period = GetPeriod(periodKey)
    local ledger = PocketCFO:GetModule("GoldLedger", true)
    local ledgerDays = ledger and ledger:GetDays() or {}

    local byCategory = {}
    local byCategoryProfession = {}
    local byCategoryItem = {}
    local daily = {}
    local total = 0

    for _, dayKey in ipairs(DayKeysFor(period.days, ledgerDays)) do
        local dayEntry = { dayKey = dayKey, copper = 0, byCategory = {} }
        local day = ledgerDays[dayKey]
        if day then
            for guid, categories in pairs(day) do
                if not characterGUID or guid == characterGUID then
                    for category, professions in pairs(categories) do
                        if not EXCLUDED_CATEGORIES[category] then
                            for professionKey, row in pairs(professions) do
                                local income = tonumber(row.income) or 0
                                if income > 0 then
                                    total = total + income
                                    dayEntry.copper = dayEntry.copper + income
                                    dayEntry.byCategory[category] = (dayEntry.byCategory[category] or 0) + income
                                    byCategory[category] = (byCategory[category] or 0) + income
                                    local split = byCategoryProfession[category] or {}
                                    byCategoryProfession[category] = split
                                    split[professionKey] = (split[professionKey] or 0) + income
                                    if type(row.items) == "table" then
                                        local byProfession = byCategoryItem[category] or {}
                                        byCategoryItem[category] = byProfession
                                        local items = byProfession[professionKey] or {}
                                        byProfession[professionKey] = items
                                        for itemName, detail in pairs(row.items) do
                                            local entry = items[itemName] or { copper = 0, quantity = 0 }
                                            items[itemName] = entry
                                            entry.copper = entry.copper + (tonumber(detail.copper) or 0)
                                            entry.quantity = entry.quantity + (tonumber(detail.quantity) or 0)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        daily[#daily + 1] = dayEntry
    end

    local sources = SortedList(byCategory, function(key) return self:GetCategoryLabel(key) end)
    -- "Unknown" always sits at the bottom.
    for index, source in ipairs(sources) do
        if source.key == "other" then
            table.remove(sources, index)
            sources[#sources + 1] = source
            break
        end
    end
    for _, source in ipairs(sources) do
        source.share = total > 0 and (source.copper / total) or 0
        source.professions = SortedList(byCategoryProfession[source.key] or {},
            function(key) return self:GetProfessionLabel(key) end)
        local onlyNone = #source.professions == 1 and source.professions[1].key == "none"
        source.showProfessions = #source.professions > 0 and not onlyNone

        -- Items stay grouped under the profession they were credited to.
        local itemsByProfession = byCategoryItem[source.key] or {}
        local itemCount = 0
        for _, profession in ipairs(source.professions) do
            profession.items = SortedItems(itemsByProfession[profession.key])
            itemCount = itemCount + #profession.items
        end
        -- Single "No profession" source: its items list directly under the source.
        source.items = onlyNone and source.professions[1].items or {}

        source.expandable = source.showProfessions or itemCount > 0
    end

    return {
        period = period,
        total = total,
        sources = sources,
        chart = (#daily > 1) and BuildChartBuckets(daily) or nil,
    }
end
