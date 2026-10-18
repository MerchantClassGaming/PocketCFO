-- PocketCFO_Valuation/Modules/VendorPriceService.lua
-- Read-only vendor gold-price observation, normalization, and lookup.
--
-- This module is intentionally dumb: it owns merchant observation,
-- gold-only vendor price persistence, per-unit normalization, and lookup by
-- itemID. It does NOT decide whether a vendor price beats custom valuation
-- or Auction House price - that precedence decision belongs to
-- ValuationService and is explicitly out of scope for this phase.
--
-- API history / live-fix note:
-- The first implementation used the legacy global GetMerchantItemInfo as
-- its only item-info path. Live test at merchant "Deynna" produced
-- observedRows=87, validGoldOnlyRows=0, ignoredAPIUnavailable=87 - every
-- single row failed the same way, which meant GetMerchantItemInfo itself
-- was unusable on this client build (Warcraft Wiki confirms it was
-- deprecated in patch 11.0.5 "and will be removed in the future" - on this
-- client, `type(GetMerchantItemInfo) == "function"` evidently no longer
-- holds true, or it stopped returning data). Confirmed via warcraft.wiki.gg:
--   - C_MerchantFrame.GetItemInfo(index) is the current, non-deprecated
--     replacement, returning a MerchantItemInfo table with fields
--     name, texture, price, stackCount, numAvailable, isPurchasable,
--     isUsable, hasExtendedCost, currencyID, spellID, isQuestStartItem.
--     Note the quantity field is named `stackCount`, NOT `quantity` -
--     this is a real field-name change from the legacy positional return,
--     not just a namespace move.
--   - GetMerchantNumItems and GetMerchantItemLink are confirmed NOT
--     deprecated on Warcraft Wiki as of patch 12.1.0 (Midnight) - both are
--     kept as-is.
-- This is verified against Warcraft Wiki documentation, not against a live
-- client trace of the actual return values. Whether `price` on
-- C_MerchantFrame.GetItemInfo represents the total copper cost for
-- `stackCount` items (as the legacy `price` field did) is inferred by
-- continuity with the deprecated function it replaces, not independently
-- confirmed - the "Live-verification target" in the section below tells you
-- exactly what to check next.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local VendorPriceService = PocketCFO_Valuation:NewModule("VendorPriceService", "AceEvent-3.0")

local CURRENCY_COPPER = "copper"
local SOURCE_MERCHANT_OBSERVATION = "merchantObservation"
local SOURCE_BUNDLED_DEFAULT = "bundledDefault"
local MAX_FAILURE_SAMPLES = 8

VendorPriceService.diagnosticCounters = VendorPriceService.diagnosticCounters or {
    observedRows = 0,
    validGoldOnlyRows = 0,

    ignoredExtendedCost = 0,
    ignoredNotPurchasable = 0,
    ignoredZeroPrice = 0,
    ignoredInvalidQuantity = 0,

    ignoredMerchantCountAPIUnavailable = 0,
    ignoredItemInfoAPIUnavailable = 0,
    ignoredItemInfoError = 0,
    ignoredItemInfoNil = 0,
    ignoredItemInfoMalformed = 0,
    ignoredItemLinkAPIUnavailable = 0,
    ignoredItemLinkError = 0,
    ignoredItemLinkNil = 0,
    ignoredItemIDResolutionFailed = 0,

    -- Which concrete API this session actually used for each stage, so
    -- /mcgd vendorprices can prove which path was live-selected rather than
    -- just which path the code prefers.
    selectedCountAPI = nil,
    selectedItemInfoAPI = nil,
    selectedLinkAPI = nil,
    lastIdentityAPIUsed = nil,

    lastMerchantName = nil,
    lastScanAt = nil,

    -- Most recent scan's first few row-level failures, cleared at the start
    -- of every ScanMerchant() call. Each entry:
    --   { index, api, error, returnedType, fields }
    failureSamples = {},
}

local function GetDBRoot()
    local db = PocketCFO_Valuation.db
    if not db or not db.global then
        return nil
    end
    db.global.vendorPriceObservations = db.global.vendorPriceObservations or {}
    return db.global.vendorPriceObservations
end

local function DescribeFields(value)
    if type(value) ~= "table" then
        return nil
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    return table.concat(keys, ",")
end

local function RecordFailureSample(counters, index, api, err, returnedValue)
    if #counters.failureSamples >= MAX_FAILURE_SAMPLES then
        return
    end
    counters.failureSamples[#counters.failureSamples + 1] = {
        index = index,
        api = api,
        error = err,
        returnedType = type(returnedValue),
        fields = DescribeFields(returnedValue),
    }
end

-- Stores/updates one item's observation. Conflict rule: last valid scan
-- wins. Every newly observed valid gold-only merchant row replaces the
-- existing player observation for that item outright - unconditionally,
-- regardless of whether the new unitPrice is lower, equal, or higher than
-- whatever was stored before. A more recent in-game observation is the
-- current fact available to the addon; an older, merely-cheaper observation
-- is not preserved over it. (Previous behavior compared unitPrice and kept
-- whichever was cheaper - that rule is no longer in effect.)
local function StoreObservation(itemID, unitPrice, purchasePrice, purchaseQuantity, merchantName, observedAt)
    local root = GetDBRoot()
    if not root then
        return
    end

    root[itemID] = {
        itemID = itemID,
        purchasePrice = purchasePrice,
        purchaseQuantity = purchaseQuantity,
        unitPrice = unitPrice,
        observedAt = observedAt,
        merchantName = merchantName,
        source = SOURCE_MERCHANT_OBSERVATION,
    }
end

-- Determines which item-info API this scan will use for every row. Picked
-- once per scan (not per row) so a single scan never mixes the structured
-- table result with the legacy positional-return result.
local function DetectItemInfoAPI()
    if type(C_MerchantFrame) == "table" and type(C_MerchantFrame.GetItemInfo) == "function" then
        return "structured", "C_MerchantFrame.GetItemInfo"
    end
    if type(GetMerchantItemInfo) == "function" then
        return "legacy", "GetMerchantItemInfo (legacy fallback - current API unavailable)"
    end
    return nil, "unavailable"
end

-- Reads one merchant row through the API path selected for this scan and
-- returns a normalized internal shape:
--   { name, itemID (may be nil), purchasePrice, purchaseQuantity, isPurchasable, hasExtendedCost }
-- or nil plus a specific failure reason and the raw pcall error/description.
local function ReadMerchantItemInfo(index, apiPath)
    if apiPath == "structured" then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
        if not ok then
            return nil, "itemInfoError", tostring(info)
        end
        if type(info) ~= "table" then
            return nil, "itemInfoNil", "C_MerchantFrame.GetItemInfo returned " .. type(info)
        end

        return {
            name = info.name,
            itemID = tonumber(info.itemID),
            purchasePrice = tonumber(info.price),
            purchaseQuantity = tonumber(info.stackCount),
            isPurchasable = info.isPurchasable == true,
            hasExtendedCost = info.hasExtendedCost == true,
        }, nil, nil
    end

    if apiPath == "legacy" then
        local ok, name, texture, price, quantity, numAvailable, isPurchasable, isUsable, extendedCost =
            pcall(GetMerchantItemInfo, index)
        if not ok then
            return nil, "itemInfoError", tostring(name)
        end
        if name == nil and price == nil and quantity == nil then
            return nil, "itemInfoNil", "GetMerchantItemInfo returned nil for all fields"
        end

        return {
            name = name,
            itemID = nil,
            purchasePrice = tonumber(price),
            purchaseQuantity = tonumber(quantity),
            isPurchasable = isPurchasable == true,
            hasExtendedCost = extendedCost == true,
        }, nil, nil
    end

    return nil, "itemInfoAPIUnavailable", "neither C_MerchantFrame.GetItemInfo nor GetMerchantItemInfo exist on this client"
end

local function ReadMerchantItemLink(index)
    if type(GetMerchantItemLink) ~= "function" then
        return nil, "itemLinkAPIUnavailable", nil
    end

    local ok, link = pcall(GetMerchantItemLink, index)
    if not ok then
        return nil, "itemLinkError", tostring(link)
    end
    if not link then
        return nil, "itemLinkNil", nil
    end
    return link, nil, nil
end

-- Resolves itemID using the strongest available evidence, in order:
--   1. a direct itemID field already on the normalized merchant info
--      (not present in the currently documented MerchantItemInfo schema,
--      but checked first in case a future client build adds it)
--   2. C_Item.GetItemInfoInstant(itemLink) - confirmed present elsewhere in
--      this codebase (PocketCFO/Services/ItemIdentityService)
--   3. global GetItemInfoInstant(itemLink)
--   4. GetItemInfoFromHyperlink(itemLink) - legacy, only used if the two
--      preferred tiers above are unavailable
--   5. regex match on the raw item link string - no game API call, last resort
local function ResolveItemID(itemLink)
    if not itemLink then
        return nil, nil
    end

    if type(C_Item) == "table" and type(C_Item.GetItemInfoInstant) == "function" then
        local ok, itemID = pcall(C_Item.GetItemInfoInstant, itemLink)
        itemID = ok and tonumber(itemID) or nil
        if itemID then
            return itemID, "C_Item.GetItemInfoInstant"
        end
    end

    if type(GetItemInfoInstant) == "function" then
        local ok, itemID = pcall(GetItemInfoInstant, itemLink)
        itemID = ok and tonumber(itemID) or nil
        if itemID then
            return itemID, "GetItemInfoInstant"
        end
    end

    if type(GetItemInfoFromHyperlink) == "function" then
        local ok, itemID = pcall(GetItemInfoFromHyperlink, itemLink)
        itemID = ok and tonumber(itemID) or nil
        if itemID then
            return itemID, "GetItemInfoFromHyperlink (legacy fallback)"
        end
    end

    local patternMatch = tonumber(tostring(itemLink):match("item:(%d+)"))
    if patternMatch then
        return patternMatch, "linkPatternMatch"
    end
    return nil, nil
end

local function ObserveMerchantItem(index, apiPath, merchantName, observedAt)
    local counters = VendorPriceService.diagnosticCounters
    counters.observedRows = counters.observedRows + 1

    local info, failReason, err = ReadMerchantItemInfo(index, apiPath)
    if not info then
        local apiName = apiPath == "structured" and "C_MerchantFrame.GetItemInfo"
            or apiPath == "legacy" and "GetMerchantItemInfo"
            or "(none available)"

        if failReason == "itemInfoAPIUnavailable" then
            counters.ignoredItemInfoAPIUnavailable = counters.ignoredItemInfoAPIUnavailable + 1
        elseif failReason == "itemInfoError" then
            counters.ignoredItemInfoError = counters.ignoredItemInfoError + 1
            RecordFailureSample(counters, index, apiName, err, nil)
        elseif failReason == "itemInfoNil" then
            counters.ignoredItemInfoNil = counters.ignoredItemInfoNil + 1
            RecordFailureSample(counters, index, apiName, err, nil)
        else
            counters.ignoredItemInfoMalformed = counters.ignoredItemInfoMalformed + 1
            RecordFailureSample(counters, index, apiName, err, info)
        end
        return
    end

    if info.hasExtendedCost then
        counters.ignoredExtendedCost = counters.ignoredExtendedCost + 1
        return
    end

    if info.isPurchasable ~= true then
        counters.ignoredNotPurchasable = counters.ignoredNotPurchasable + 1
        return
    end

    local price = info.purchasePrice
    if not price or price <= 0 then
        counters.ignoredZeroPrice = counters.ignoredZeroPrice + 1
        return
    end

    local quantity = info.purchaseQuantity
    if not quantity or quantity <= 0 then
        counters.ignoredInvalidQuantity = counters.ignoredInvalidQuantity + 1
        return
    end

    local itemID = info.itemID
    local identityAPIUsed = itemID and "directItemIDField" or nil

    if not itemID then
        local link, linkFailReason, linkErr = ReadMerchantItemLink(index)
        if linkFailReason == "itemLinkAPIUnavailable" then
            counters.ignoredItemLinkAPIUnavailable = counters.ignoredItemLinkAPIUnavailable + 1
            return
        elseif linkFailReason == "itemLinkError" then
            counters.ignoredItemLinkError = counters.ignoredItemLinkError + 1
            RecordFailureSample(counters, index, "GetMerchantItemLink", linkErr, nil)
            return
        elseif linkFailReason == "itemLinkNil" then
            counters.ignoredItemLinkNil = counters.ignoredItemLinkNil + 1
            return
        end

        itemID, identityAPIUsed = ResolveItemID(link)
        if not itemID then
            counters.ignoredItemIDResolutionFailed = counters.ignoredItemIDResolutionFailed + 1
            RecordFailureSample(counters, index, "ResolveItemID", "itemLink=" .. tostring(link), nil)
            return
        end
    end

    counters.lastIdentityAPIUsed = identityAPIUsed
    counters.validGoldOnlyRows = counters.validGoldOnlyRows + 1
    StoreObservation(itemID, price / quantity, price, quantity, merchantName, observedAt)
end

local function ScanMerchant()
    local counters = VendorPriceService.diagnosticCounters
    counters.failureSamples = {}

    if type(GetMerchantNumItems) ~= "function" then
        counters.ignoredMerchantCountAPIUnavailable = counters.ignoredMerchantCountAPIUnavailable + 1
        counters.selectedCountAPI = "unavailable"
        return
    end
    counters.selectedCountAPI = "GetMerchantNumItems"

    local okCount, numItems = pcall(GetMerchantNumItems)
    numItems = (okCount and tonumber(numItems)) or 0
    if numItems <= 0 then
        return
    end

    local apiPath, apiLabel = DetectItemInfoAPI()
    counters.selectedItemInfoAPI = apiLabel
    counters.selectedLinkAPI = type(GetMerchantItemLink) == "function" and "GetMerchantItemLink" or "unavailable"

    local merchantName = (UnitExists and UnitExists("npc") and UnitName and UnitName("npc")) or nil
    local observedAt = (GetServerTime and GetServerTime()) or time()

    counters.lastMerchantName = merchantName
    counters.lastScanAt = observedAt

    for index = 1, numItems do
        ObserveMerchantItem(index, apiPath, merchantName, observedAt)
    end
end

function VendorPriceService:MERCHANT_SHOW()
    ScanMerchant()
end

function VendorPriceService:MERCHANT_UPDATE()
    ScanMerchant()
end

function VendorPriceService:OnEnable()
    self:RegisterEvent("MERCHANT_SHOW")
    self:RegisterEvent("MERCHANT_UPDATE")
end

function VendorPriceService:OnDisable()
    self:UnregisterEvent("MERCHANT_SHOW")
    self:UnregisterEvent("MERCHANT_UPDATE")
end

local function GetDefaultsTable()
    return PocketCFO_Valuation and PocketCFO_Valuation.VendorPriceDefaults
end

--- Returns the per-unit copper vendor price for an itemID, or an unresolved
-- shape when neither a valid player observation nor a bundled default row
-- exists. Never decides whether this beats another valuation source - that
-- is ValuationService's job, not this module's.
--
-- Effective lookup order: valid player observation -> bundled default ->
-- unresolved. Both observation-sourced and default-sourced results are
-- equally canonical vendor-purchase values to the caller; the only
-- difference is provenance.sourceType ("merchantObservation" or
-- "bundledDefault"), so callers can tell which one supplied the value
-- without needing a second lookup. Bundled defaults are never merged into
-- the persisted observation table (db.global.vendorPriceObservations) - the
-- default registry stays code-only and immutable.
-- @param itemID number
function VendorPriceService:GetPrice(itemID)
    itemID = tonumber(itemID)
    if not itemID then
        return { resolved = false, itemID = itemID, reason = "vendorPriceUnavailable" }
    end

    local root = GetDBRoot()
    local observation = root and root[itemID]
    if observation then
        return {
            resolved = true,
            itemID = itemID,
            value = observation.unitPrice,
            currency = CURRENCY_COPPER,
            source = "vendorPurchase",
            strategyKey = "vendorPurchase",
            valuationBasis = "fixed",
            provenance = {
                sourceType = SOURCE_MERCHANT_OBSERVATION,
                purchasePrice = observation.purchasePrice,
                purchaseQuantity = observation.purchaseQuantity,
                observedAt = observation.observedAt,
                merchantName = observation.merchantName,
            },
        }
    end

    local defaults = GetDefaultsTable()
    local default = defaults and defaults[itemID]
    if default then
        return {
            resolved = true,
            itemID = itemID,
            value = default.unitPrice,
            currency = CURRENCY_COPPER,
            source = "vendorPurchase",
            strategyKey = "vendorPurchase",
            valuationBasis = "fixed",
            provenance = {
                sourceType = SOURCE_BUNDLED_DEFAULT,
                purchasePrice = default.purchasePrice,
                purchaseQuantity = default.purchaseQuantity,
            },
        }
    end

    return { resolved = false, itemID = itemID, reason = "vendorPriceUnavailable" }
end

--- Diagnostic/export access: returns every stored observation, sorted by
-- itemID. Read-only - callers must not mutate the returned rows in place.
function VendorPriceService:GetAllObservations()
    local root = GetDBRoot()
    local list = {}
    if not root then
        return list
    end

    for _, row in pairs(root) do
        list[#list + 1] = row
    end
    table.sort(list, function(a, b) return (a.itemID or 0) < (b.itemID or 0) end)
    return list
end

--- Diagnostic/export access: cumulative session counters explaining what was
-- observed vs. ignored, and why, plus the API paths this session actually
-- selected and the most recent scan's first few row-level failures.
function VendorPriceService:GetDiagnosticCounters()
    return self.diagnosticCounters
end

if PocketCFO_Valuation then
    PocketCFO_Valuation.VendorPriceService = VendorPriceService
end
