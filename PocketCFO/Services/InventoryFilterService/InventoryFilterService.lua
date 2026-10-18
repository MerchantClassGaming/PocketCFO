-- PocketCFO/Services/InventoryFilterService/InventoryFilterService.lua
-- Applies reusable use-case filters to inventory/scanner result arrays.
--
-- Scanners answer: "What is present?"
-- InventoryFilterService answers: "Which observed items matter for this use case?"
--
-- This service does not scan containers, own inventory state, aggregate inventory,
-- generate ConfigKeys, or make posting/cancel/pricing decisions.
--
-- Known gap: the "sellable" filter's tooltip-based soulbound detection requires
-- bag+slot context. Rows from post-scan arrays (e.g. InventoryStateService) do
-- not carry bag/slot position. Soulbound detection in that path relies on
-- explicit row flags (isSoulbound, isBound, isSellable). Scan-time enrichment
-- (embedding these flags at BagScanner/BankScanner call time) is the recommended
-- future path for reliable filtering.

local PocketCFO = _G.PocketCFO

local InventoryFilterService = {}

-- ---------------------------------------------------------------------------
-- Internal filter registry
-- ---------------------------------------------------------------------------

local Filters = {}

-- ---------------------------------------------------------------------------
-- Dependency accessors
-- ---------------------------------------------------------------------------

local function GetSoulboundClassifier()
    return PocketCFO and PocketCFO.SoulboundClassifier or _G.PocketCFO_SoulboundClassifier
end

local function DebugLog(msg, ...)
    if not PocketCFO or not PocketCFO.Debug then return end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:Debug("[InventoryFilterService] " .. tostring(msg))
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Apply a named filter to an array of inventory rows.
-- Returns a new array (input is not mutated).
-- Errors if filterName is not registered.
function InventoryFilterService:Apply(rows, filterName, options)
    if type(rows) ~= "table" then
        return {}
    end

    local fn = Filters[filterName]
    if not fn then
        error("InventoryFilterService: unknown filter '" .. tostring(filterName) .. "'")
    end

    local result = {}
    for _, row in ipairs(rows) do
        if fn(row, options) then
            result[#result + 1] = row
        end
    end
    return result
end

-- Register a named filter predicate.
-- fn(row, options) should return true to keep the row, false to exclude it.
function InventoryFilterService:RegisterFilter(filterName, fn)
    if type(filterName) ~= "string" or filterName == "" then
        error("InventoryFilterService:RegisterFilter requires a non-empty string name")
    end
    if type(fn) ~= "function" then
        error("InventoryFilterService:RegisterFilter requires a function")
    end
    Filters[filterName] = fn
end

-- Convenience: test a single row against the sellable filter.
-- Returns true/false, or nil if the sellable filter is not registered.
function InventoryFilterService:IsSellable(row, options)
    local fn = Filters.sellable
    if not fn then return nil end
    return fn(row, options)
end

-- Returns a sorted list of registered filter names.
-- Used by diagnostics to enumerate valid filter options without hardcoding them.
function InventoryFilterService:GetRegisteredFilters()
    local names = {}
    for name in pairs(Filters) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

-- ---------------------------------------------------------------------------
-- Built-in: sellable filter
--
-- Returns true for rows that are candidates for auction/posting workflows.
--
-- Exclusion criteria (evaluated in order):
--   1. Explicit row flag isSoulbound == true
--   2. Explicit row flag isBound == true
--   3. Explicit row flag isSellable == false
--   4. Tooltip inspection via SoulboundClassifier when row carries bag+slot context
--
-- When sellability cannot be determined (no explicit flags, no bag+slot context),
-- the row is INCLUDED. Post-scan arrays lack tooltip context; the posting pipeline
-- is responsible for any remaining sellability gates at execution time.
--
-- See file header for the known gap on post-scan tooltip detection.
-- ---------------------------------------------------------------------------

Filters.sellable = function(row, options)
    if not row then return false end

    -- Explicit flags set by callers or future scan-time enrichment
    if row.isSoulbound == true then
        DebugLog("sellable: excluded isSoulbound=true configKey=%s", tostring(row.configKey or row.itemID))
        return false
    end

    if row.isBound == true then
        DebugLog("sellable: excluded isBound=true configKey=%s", tostring(row.configKey or row.itemID))
        return false
    end

    if row.isSellable == false then
        DebugLog("sellable: excluded isSellable=false configKey=%s", tostring(row.configKey or row.itemID))
        return false
    end

    -- Tooltip inspection when bag+slot context is available on the row.
    -- This path is valid for rows produced inline (e.g. during an active scan
    -- that embeds position metadata) but not for archived snapshot rows.
    local bag  = row.bag or row.containerID
    local slot = row.slot

    if bag ~= nil and slot ~= nil then
        local classifier = GetSoulboundClassifier()
        if classifier and type(classifier.BagSlotHasBoundTooltip) == "function" then
            local bound = classifier:BagSlotHasBoundTooltip(bag, slot)
            if bound then
                DebugLog("sellable: excluded tooltip-bound configKey=%s bag=%s slot=%s",
                    tostring(row.configKey or row.itemID), tostring(bag), tostring(slot))
                return false
            end
        end
    end

    -- Sellability undetermined: include with a debug note.
    -- No bag+slot context and no explicit flags means we cannot tooltip-inspect.
    -- The row is included; downstream pipeline gates handle remaining checks.
    if bag == nil or slot == nil then
        DebugLog("sellable: included (no tooltip context) configKey=%s location=%s",
            tostring(row.configKey or row.itemID), tostring(row.location))
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Registration
-- ---------------------------------------------------------------------------

if PocketCFO then
    PocketCFO.InventoryFilterService = InventoryFilterService
end

_G.PocketCFO_InventoryFilterService = InventoryFilterService
