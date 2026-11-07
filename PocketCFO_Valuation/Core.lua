-- PocketCFO_Valuation/Core.lua
-- Pricing identity and valuation cache foundation.

local ADDON_NAME = ...

local PocketCFO_Valuation = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME,
    "AceEvent-3.0"
)
_G.PocketCFO_Valuation = PocketCFO_Valuation

-- Value version (Brian, 2026-11-07, hover performance). Remembered values
-- (ValuationService's price sheet, the tooltip rows) are kept until
-- something they were worked out from changes. Anything that can change a
-- value bumps this number, and every remembered value made under an older
-- number is thrown away on its next read:
--   - a price cache write (full scan, item search) and the quality sibling /
--     profession gear pair rebuilds: PCFO_PRICING_UPDATED
--   - a container opened (its value comes from your own openings):
--     MCG_CONTAINER_OPENED
--   - a valuation rule added or removed (ValuationRules)
--   - a vendor purchase price seen at a merchant (VendorPriceService)
-- Things outside this addon that only nudge a value (your own sales, Cost
-- to Make, new disenchants) are covered by the sheet's time limit instead.
-- unstableCount: bumped whenever a lookup hits a recursion guard or missing
-- item data; a value worked out while it moved is not remembered.
PocketCFO_Valuation.valueVersion = 0
PocketCFO_Valuation.unstableCount = 0

function PocketCFO_Valuation:BumpValueVersion()
    self.valueVersion = (self.valueVersion or 0) + 1
end

function PocketCFO_Valuation:MarkUnstable()
    self.unstableCount = (self.unstableCount or 0) + 1
end

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
    -- Handlers ignore the message arguments (CraftSim's bundled
    -- CallbackHandler can shift them; see api-findings).
    self:RegisterMessage("PCFO_PRICING_UPDATED", function()
        PocketCFO_Valuation:BumpValueVersion()
    end)
    self:RegisterMessage("MCG_CONTAINER_OPENED", function()
        PocketCFO_Valuation:BumpValueVersion()
    end)
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
