-- PocketCFO/Services/InventoryStateService/AvailabilityCalculator.lua
-- Availability calculations over aggregated inventory state.

local PocketCFO = _G.PocketCFO

local AvailabilityCalculator = {}

local KNOWN_LOCATIONS = { "bags", "bank", "warbank", "mail", "ah" }

function AvailabilityCalculator:GetAvailableQuantity(state, configKey, options)
    local entry = state and state.byConfigKey and state.byConfigKey[configKey] or nil
    if not entry then
        return 0
    end

    if type(options) == "table" and options.location then
        local location = options.location == "mailbox" and "mail" or options.location
        local quantity = tonumber(entry.byLocation and entry.byLocation[location]) or 0
        return math.max(0, quantity)
    end

    return math.max(0, tonumber(entry.totalQuantity) or 0)
end

function AvailabilityCalculator:GetLocationQuantity(state, configKey, location)
    return self:GetAvailableQuantity(state, configKey, { location = location })
end

function AvailabilityCalculator:GetSummary(state)
    local summary = {
        uniqueConfigKeys = 0,
        totalQuantity = 0,
        byLocation = {},
        unresolvedRows = #(state and state.unresolvedRows or {}),
        observationCount = state and state.observationCount or 0,
        snapshotObservationCount = state and state.snapshotObservationCount or 0,
        adjustmentCount = state and state.adjustmentCount or 0,
        characterOwnerKey = state and state.characterOwnerKey or nil,
        warbandOwnerKey = state and state.warbandOwnerKey or nil,
    }

    for _, location in ipairs(KNOWN_LOCATIONS) do
        summary.byLocation[location] = 0
    end

    for _, entry in pairs(state and state.byConfigKey or {}) do
        summary.uniqueConfigKeys = summary.uniqueConfigKeys + 1
        summary.totalQuantity = summary.totalQuantity + math.max(0, tonumber(entry.totalQuantity) or 0)
        for location, quantity in pairs(entry.byLocation or {}) do
            summary.byLocation[location] = (summary.byLocation[location] or 0) + math.max(0, tonumber(quantity) or 0)
        end
    end

    return summary
end

if PocketCFO then
    PocketCFO.InventoryAvailabilityCalculator = AvailabilityCalculator
end

_G.PocketCFO_InventoryAvailabilityCalculator = AvailabilityCalculator
