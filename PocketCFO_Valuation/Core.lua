-- PocketCFO_Valuation/Core.lua
-- Pricing identity and valuation cache foundation.

local ADDON_NAME = ...

local PocketCFO_Valuation = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME,
    "AceEvent-3.0"
)
_G.PocketCFO_Valuation = PocketCFO_Valuation

local DB_DEFAULTS = {
    global = {
        -- Prices and last-scan time live per connected realm group in
        -- global.realmGroups (see PricingCache.lua).
        vendorPriceObservations = {},
    },
}

local function Debug(msg, ...)
    local PocketCFO = _G.PocketCFO
    if PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug(msg, ...)
    end
end

function PocketCFO_Valuation:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("PocketCFO_ValuationDB", DB_DEFAULTS, true)
    self.db.global.vendorPriceObservations = self.db.global.vendorPriceObservations or {}
    Debug("PocketCFO_Valuation initialized.")
end

function PocketCFO_Valuation:OnEnable()
end

function PocketCFO_Valuation:OnDisable()
end

-- First-run guidance. Every value in the addon depends on at least one
-- finished full price scan on this realm group. The last-scan time is only
-- written when a scan reaches the end of finalize
-- (FullScan:ProcessFinalizeChunk), so a failed or interrupted scan does not
-- count.
PocketCFO_Valuation.NO_SCAN_MESSAGE =
    "No prices yet. Open the Auction House, click the Pocket CFO tab, and press Scan Prices."

function PocketCFO_Valuation:HasCompletedPriceScan()
    local cache = self:GetModule("PricingCache", true)
    return (cache and cache:GetLastScanTime() ~= nil) and true or false
end

function PocketCFO_Valuation:GetValue(itemLinkOrMarketKey)
    local cache = self:GetModule("PricingCache", true)
    if cache and cache.GetValue then
        return cache:GetValue(itemLinkOrMarketKey)
    end
    return nil, "unknown"
end

function PocketCFO_Valuation:GetValueByMarketKey(marketKey)
    local cache = self:GetModule("PricingCache", true)
    if cache and cache.GetValueByMarketKey then
        return cache:GetValueByMarketKey(marketKey)
    end
    return nil, "unknown"
end

function PocketCFO_Valuation:IsStale(marketKey)
    local cache = self:GetModule("PricingCache", true)
    if cache and cache.IsStale then
        return cache:IsStale(marketKey)
    end
    return nil
end

function PocketCFO_Valuation:GetItemValue(itemRef, options)
    local service = self:GetModule("ValuationService", true)
    if service and service.GetItemValue then
        return service:GetItemValue(itemRef, options)
    end
    return {
        value = nil, valuePerUnit = nil, currency = "copper", basis = nil, source = nil,
        itemID = nil, configKey = nil, isFresh = nil, lastUpdated = nil,
        unresolved = true, unresolvedReason = "valuationServiceUnavailable",
    }
end

function PocketCFO_Valuation:GetValues(itemRefs, options)
    local service = self:GetModule("ValuationService", true)
    if service and service.GetValues then
        return service:GetValues(itemRefs, options)
    end
    return {}
end

function PocketCFO_Valuation:ExplainValue(itemRef, options)
    local service = self:GetModule("ValuationService", true)
    if service and service.ExplainValue then
        return service:ExplainValue(itemRef, options)
    end
    return {
        value = nil, valuePerUnit = nil, currency = "copper", basis = nil, source = nil,
        itemID = nil, configKey = nil, isFresh = nil, lastUpdated = nil,
        unresolved = true, unresolvedReason = "valuationServiceUnavailable",
    }
end

function PocketCFO_Valuation:StartFullScan()
    Debug("PocketCFO_Valuation:StartFullScan called")
    local fullScan = self:GetModule("FullScan", true)
    if fullScan and fullScan.StartFullScan then
        return fullScan:StartFullScan()
    end
    return false, "FullScan module unavailable"
end

function PocketCFO_Valuation:GetFullScanStatus()
    local fullScan = self:GetModule("FullScan", true)
    if fullScan and fullScan.GetStatus then
        return fullScan:GetStatus()
    end
    return {
        state = "failed",
        running = false,
        rowsProcessed = 0,
        rowsTotal = 0,
        marketsPriced = 0,
        startedAt = nil,
        completedAt = nil,
        lastError = "FullScan module unavailable",
        rejectReason = "FullScan module unavailable",
    }
end
