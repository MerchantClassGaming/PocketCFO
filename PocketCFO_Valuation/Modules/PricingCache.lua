-- PocketCFO_Valuation/Modules/PricingCache.lua
-- Timestamped market-key price cache. No auction house scans happen here.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local PricingCache = PocketCFO_Valuation:NewModule("PricingCache")

local FRESH_SECONDS = 3 * 24 * 60 * 60

-- Temporary diagnostics for the "Prospecting Analysis needs-price delay"
-- investigation. Remove once the rerender-on-price-update fix is confirmed
-- working in-game.
local function SessionLog(fmt, ...)
    local core = _G.PocketCFO
    if not core or not core.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    core:AppendSessionLog("[MCG] " .. msg)
end

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function GetCacheRoot()
    local db = PocketCFO_Valuation.db
    if not db or not db.global then
        return nil
    end
    db.global.pricingCache = db.global.pricingCache or {}
    return db.global.pricingCache
end

local function NormalizeValue(row)
    if type(row) ~= "table" then
        return nil
    end
    return tonumber(row.value) or tonumber(row.copperValue) or tonumber(row.unitPrice) or tonumber(row.buyout)
end

function PricingCache:OnInitialize()
    GetCacheRoot()
end

function PricingCache:GetCache()
    return GetCacheRoot()
end

-- Broadcast so any addon/module holding a stale "no price" result (e.g.
-- Prospecting Analysis, evaluated before this market key ever had a price)
-- can react and recompute instead of waiting for an unrelated trigger to
-- happen to re-run. Fired on every successful cache write rather than
-- batched here - bursts (a FullScan chunk, a SearchRefresh batch) are cheap
-- to broadcast; consumers are expected to debounce their own reaction.
local function BroadcastPricingUpdated(marketKey, itemID, source)
    PocketCFO_Valuation:SendMessage("PCFO_PRICING_UPDATED", marketKey, itemID, source)
    SessionLog("PricingCache: price resolved marketKey=%s itemID=%s source=%s timestamp=%s",
        tostring(marketKey), tostring(itemID), tostring(source), tostring(Now()))
end

function PricingCache:SetValue(marketKey, value, timestamp, source)
    if not marketKey or tostring(marketKey) == "" then
        return nil
    end
    value = tonumber(value)
    if not value then
        return nil
    end

    local cache = GetCacheRoot()
    if not cache then
        return nil
    end

    marketKey = tostring(marketKey)
    cache[marketKey] = {
        marketKey = marketKey,
        value = value,
        timestamp = tonumber(timestamp) or Now(),
        source = source or "manual",
    }

    BroadcastPricingUpdated(marketKey, nil, cache[marketKey].source)
    return cache[marketKey]
end

function PricingCache:SetPricingRow(marketKey, row)
    if not marketKey or tostring(marketKey) == "" or type(row) ~= "table" then
        return nil
    end

    local value = tonumber(row.value)
    if not value then
        return nil
    end

    local cache = GetCacheRoot()
    if not cache then
        return nil
    end

    marketKey = tostring(marketKey)
    cache[marketKey] = {
        marketKey = marketKey,
        itemID = tonumber(row.itemID) or row.itemID,
        itemName = row.itemName,
        qualityTier = tonumber(row.qualityTier) or row.qualityTier,
        itemLevel = tonumber(row.itemLevel) or row.itemLevel,
        statFingerprint = row.statFingerprint,
        depthUsed = tonumber(row.depthUsed) or row.depthUsed,
        valuationDiagnostics = row.valuationDiagnostics,
        value = value,
        freshness = row.freshness or "fresh",
        timestamp = tonumber(row.timestamp) or Now(),
        source = row.source or "pricing",
    }

    BroadcastPricingUpdated(marketKey, cache[marketKey].itemID, cache[marketKey].source)

    return cache[marketKey]
end

function PricingCache:GetEntry(marketKey)
    if not marketKey or tostring(marketKey) == "" then
        return nil
    end

    local cache = GetCacheRoot()
    if not cache then
        return nil
    end

    return cache[tostring(marketKey)]
end

function PricingCache:GetCandidatesForItemID(itemID)
    itemID = tonumber(itemID)
    local cache = GetCacheRoot()
    if not itemID or not cache then
        return {}
    end

    local prefix = tostring(itemID) .. "|"
    local rows = {}
    for marketKey, row in pairs(cache) do
        if tostring(marketKey):sub(1, #prefix) == prefix then
            rows[#rows + 1] = row
        end
    end
    table.sort(rows, function(a, b)
        return tostring(a and a.marketKey or "") < tostring(b and b.marketKey or "")
    end)
    return rows
end

function PricingCache:GetValueByMarketKey(marketKey)
    local row = self:GetEntry(marketKey)
    local value = NormalizeValue(row)
    if value == nil then
        return nil, "unknown"
    end
    return value, self:IsStale(marketKey) and "stale" or "fresh", row
end

function PricingCache:GetValue(itemLinkOrMarketKey)
    local identity = PocketCFO_Valuation:GetModule("PricingIdentity", true)
    local marketKey = itemLinkOrMarketKey
    if identity and identity.BuildMarketKey then
        marketKey = identity:BuildMarketKey(itemLinkOrMarketKey)
    end
    return self:GetValueByMarketKey(marketKey)
end

function PricingCache:IsStale(marketKey)
    local row = self:GetEntry(marketKey)
    if not row or NormalizeValue(row) == nil then
        return nil
    end

    local timestamp = tonumber(row.timestamp)
    if not timestamp then
        return true
    end

    return (Now() - timestamp) > FRESH_SECONDS
end

PricingCache.FRESH_SECONDS = FRESH_SECONDS
