-- PocketCFO_Valuation/Modules/ScanHistory.lua
-- Price history built from full scans (design: claude/AH_Smart_Posting_Design.md,
-- "Scan history capture", 2026-11-04). Capture only: nothing reads this yet.
-- The tooltip line and pricing use come in the follow-up.
--
-- One small record per market key, per connected realm group:
--   r  = recent price: running average over the last ~14 days the item was
--        seen (days seen, not calendar days, so rarely listed items keep a
--        recent number)
--   rp = recent price before today's day was added (so a second scan on the
--        same day replaces today's number instead of counting the day twice)
--   s  = sum of every day's price (lifetime average = s / n)
--   n  = days seen
--   t  = today's price (the day in l)
--   f  = first day seen, l = last day seen (day = server time / 86400)
--   lo = low days in a row, dd = today was a dump day (see dump guard)
--
-- A day's price: stackables = the scan's Valuation value (bait/clown
-- filtered); non-stackables = median of that market key's listings, not the
-- lowest, so one cheap listing doesn't drag the history down.
--
-- Kept apart from PricingCache, which holds real AH observations only
-- (decision 2026-10-12). Every write is wrapped in pcall by the caller path:
-- a failure here is logged and skipped and never breaks the full scan.
-- Flavor: Both.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local ScanHistory = PocketCFO_Valuation:NewModule("ScanHistory")

local RECENT_DAYS = 14
local SECONDS_PER_DAY = 24 * 60 * 60

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function Today()
    return math.floor(Now() / SECONDS_PER_DAY)
end

local function Debug(msg, ...)
    local PocketCFO = _G.PocketCFO
    if PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug(msg, ...)
    end
end

-- This realm group's history table, or nil before the group is known.
local function GetGroupHistory()
    local db = PocketCFO_Valuation.db
    if not db or not db.global then
        return nil
    end
    local cache = PocketCFO_Valuation:GetModule("PricingCache", true)
    local key = cache and cache.GetRealmGroupKey and cache:GetRealmGroupKey()
    if not key then
        return nil
    end
    db.global.scanHistory = db.global.scanHistory or {}
    local group = db.global.scanHistory[key]
    if not group then
        group = {}
        db.global.scanHistory[key] = group
    end
    return group
end

local function Median(values)
    local count = #values
    if count == 0 then
        return nil
    end
    table.sort(values)
    if count % 2 == 1 then
        return values[(count + 1) / 2]
    end
    return math.floor((values[count / 2] + values[count / 2 + 1]) / 2)
end

-- The day's price for one full-scan bucket (see FullScan.lua AddObservation).
local function DayPrice(bucket, scanValue)
    if bucket.isStackable then
        return tonumber(scanValue)
    end
    local buyouts = {}
    for _, observation in ipairs(bucket.observations or {}) do
        local buyout = tonumber(observation.buyout or observation.buyoutAmount)
        if buyout and buyout > 0 then
            buyouts[#buyouts + 1] = buyout
        end
    end
    return Median(buyouts)
end

-- Dump guard (Brian, 2026-11-04): once an item has DUMP_MIN_DAYS of history,
-- a day's price under DUMP_PCT of its recent price is a dump (someone
-- clearing inventory), not the item's value: the day is noted (lo = how many
-- low days in a row, dd = today was one) but changes no average. If it stays
-- low DUMP_ACCEPT_DAYS days in a row, it's a real market move (e.g. a patch)
-- and becomes the new recent price.
local DUMP_MIN_DAYS = 3
local DUMP_PCT = 0.5
local DUMP_ACCEPT_DAYS = 3

local function IsDumpPrice(rec, price)
    local recent = tonumber(rec.r)
    return (tonumber(rec.n) or 0) >= DUMP_MIN_DAYS and recent ~= nil and price < recent * DUMP_PCT
end

local function FoldNewDay(rec, price, day)
    rec.n = (tonumber(rec.n) or 0) + 1
    rec.s = (tonumber(rec.s) or 0) + price
    rec.rp = tonumber(rec.r) or price
    local k = math.min(rec.n, RECENT_DAYS)
    rec.r = math.floor(rec.rp + (price - rec.rp) / k)
    rec.t = price
    rec.l = day
end

local function RecordDay(group, marketKey, price, day)
    local rec = group[marketKey]
    if not rec then
        group[marketKey] = { r = price, rp = nil, s = price, n = 1, t = price, f = day, l = day }
        return
    end

    if rec.l == day then
        if rec.dd then
            -- Today was counted as a dump; a later look today decides again.
            if IsDumpPrice(rec, price) then
                rec.t = price
                return
            end
            rec.dd = nil
            rec.lo = math.max(0, (tonumber(rec.lo) or 1) - 1)
            FoldNewDay(rec, price, day)
            return
        end
        -- Same day again: replace today's price.
        rec.s = (tonumber(rec.s) or 0) - (tonumber(rec.t) or 0) + price
        rec.t = price
        local before = rec.rp
        if before == nil then
            rec.r = price
        else
            local k = math.min(tonumber(rec.n) or 1, RECENT_DAYS)
            rec.r = math.floor(before + (price - before) / k)
        end
        return
    end

    -- New day seen.
    if IsDumpPrice(rec, price) then
        local lows = (tonumber(rec.lo) or 0) + 1
        if lows < DUMP_ACCEPT_DAYS then
            rec.lo = lows
            rec.dd = true
            rec.t = price
            rec.l = day
            return
        end
        -- Low for DUMP_ACCEPT_DAYS days in a row: the market moved.
        rec.r = price
    end
    rec.lo = nil
    rec.dd = nil
    FoldNewDay(rec, price, day)
end

-- Called by FullScan for every market it finalizes. Never throws.
function ScanHistory:RecordFromBucket(marketKey, bucket, scanValue)
    if not marketKey or type(bucket) ~= "table" then
        return
    end
    local ok, err = pcall(function()
        local price = DayPrice(bucket, scanValue)
        if not price or price <= 0 then
            return
        end
        local group = GetGroupHistory()
        if not group then
            return
        end
        RecordDay(group, tostring(marketKey), price, Today())
    end)
    if not ok and not self.loggedError then
        -- Log once per session so a bad market can't flood the debug log.
        self.loggedError = true
        Debug("ScanHistory: record failed marketKey=%s err=%s", tostring(marketKey), tostring(err))
    end
end

-- Read-only access for diagnostics (and the follow-up tooltip/pricing work).
-- Returns { recent, lifetime, daysSeen, today, firstDay, lastDay } or nil.
function ScanHistory:Get(marketKey)
    local group = GetGroupHistory()
    local rec = group and marketKey and group[tostring(marketKey)]
    if type(rec) ~= "table" then
        return nil
    end
    local n = tonumber(rec.n) or 0
    return {
        recent = tonumber(rec.r),
        lifetime = n > 0 and math.floor((tonumber(rec.s) or 0) / n) or nil,
        daysSeen = n,
        today = tonumber(rec.t),
        firstDay = tonumber(rec.f),
        lastDay = tonumber(rec.l),
    }
end

function ScanHistory:Count()
    local group = GetGroupHistory()
    local count = 0
    for _ in pairs(group or {}) do
        count = count + 1
    end
    return count
end

ScanHistory.SECONDS_PER_DAY = SECONDS_PER_DAY
