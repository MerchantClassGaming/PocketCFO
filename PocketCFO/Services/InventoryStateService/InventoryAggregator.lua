-- PocketCFO/Services/InventoryStateService/InventoryAggregator.lua
-- Builds current inventory state from baselines plus active adjustments.

local PocketCFO = _G.PocketCFO

local InventoryAggregator = {}

local WARBAND_OWNER_KEY = "WARBAND"

-- Returns true if the ownerKey should be included for this location given the
-- current character scope. Warbank is always WARBAND. Character-scoped locations
-- (bags/bank/mail/ah) must match the current character. If characterOwnerKey is
-- nil we cannot determine the current character and fall back to including all
-- non-warband data to avoid a silent empty result.
local function OwnerMatchesScope(ownerKey, location, characterOwnerKey)
    if location == "warbank" then
        return ownerKey == WARBAND_OWNER_KEY
    end
    if not characterOwnerKey then
        return ownerKey ~= WARBAND_OWNER_KEY
    end
    return ownerKey == characterOwnerKey
end

local function NormalizeLocation(location)
    if location == "mailbox" then
        return "mail"
    end
    return location
end

local function GetIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function Quantity(row)
    return tonumber(row and (row.quantity or row.count or row.stackCount)) or 1
end

local function ResolveIdentity(row, evidenceType)
    local service = GetIdentityService()
    if not service then
        return nil
    end
    if evidenceType == "adjustment" then
        return service:Identify(row)
    end
    return service:FromSnapshotRow(row)
end

local function AddQuantity(state, ownerKey, location, configKey, quantity, source, row)
    quantity = tonumber(quantity) or 0
    if quantity == 0 or not configKey or configKey == "" then
        return
    end

    local entry = state.byConfigKey[configKey]
    if not entry then
        entry = {
            configKey = configKey,
            totalQuantity = 0,
            byLocation = {},
            byOwner = {},
            rows = {},
        }
        state.byConfigKey[configKey] = entry
    end

    entry.totalQuantity = entry.totalQuantity + quantity
    entry.byLocation[location] = (entry.byLocation[location] or 0) + quantity
    entry.byOwner[ownerKey] = (entry.byOwner[ownerKey] or 0) + quantity
    entry.rows[#entry.rows + 1] = {
        source = source,
        ownerKey = ownerKey,
        location = location,
        quantity = quantity,
        row = row,
    }

    state.byLocation[location] = state.byLocation[location] or {}
    state.byLocation[location][configKey] = (state.byLocation[location][configKey] or 0) + quantity
end

local function AddBaselineRows(state, rows, ownerKey, location, source)
    for _, row in ipairs(rows or {}) do
        local identity = ResolveIdentity(row, "snapshotRow")
        local configKey = identity and identity.configKey
        if configKey then
            AddQuantity(state, ownerKey, location, configKey, Quantity(row), source, row)
        else
            state.unresolvedRows[#state.unresolvedRows + 1] = {
                source = source,
                ownerKey = ownerKey,
                location = location,
                row = row,
                reason = identity and identity.unresolvedReason or "identityUnavailable",
            }
        end
    end
end

local function AddServiceObservations(state, observations)
    local characterOwnerKey = state.characterOwnerKey
    for ownerKey, ownerObservations in pairs(observations or {}) do
        for location, observation in pairs(ownerObservations or {}) do
            if type(observation) == "table" and type(observation.rows) == "table" then
                local normalizedLocation = NormalizeLocation(location)
                if OwnerMatchesScope(ownerKey, normalizedLocation, characterOwnerKey) then
                    AddBaselineRows(state, observation.rows, ownerKey, normalizedLocation, "InventoryStateService")
                    state.observationCount = state.observationCount + 1
                end
            end
        end
    end
end

local function AddAdjustments(state, adjustments)
    local characterOwnerKey = state.characterOwnerKey
    for _, adjustment in ipairs(adjustments or {}) do
        if adjustment.active ~= false then
            local normalizedLocation = NormalizeLocation(adjustment.location)
            if OwnerMatchesScope(adjustment.ownerKey, normalizedLocation, characterOwnerKey) then
                AddQuantity(
                    state,
                    adjustment.ownerKey,
                    normalizedLocation,
                    adjustment.configKey,
                    adjustment.quantityDelta,
                    "Adjustment",
                    adjustment
                )
                state.adjustmentCount = state.adjustmentCount + 1
            end
        end
    end
end

function InventoryAggregator:BuildState(observations, adjustments, options)
    local state = {
        byConfigKey = {},
        byLocation = {},
        unresolvedRows = {},
        observationCount = 0,
        snapshotObservationCount = 0,
        adjustmentCount = 0,
        characterOwnerKey = options and options.characterOwnerKey or nil,
        warbandOwnerKey = WARBAND_OWNER_KEY,
    }

    AddServiceObservations(state, observations)
    AddAdjustments(state, adjustments)

    for _, entry in pairs(state.byConfigKey) do
        if entry.totalQuantity < 0 then
            entry.availableQuantity = 0
        else
            entry.availableQuantity = entry.totalQuantity
        end
    end

    return state
end

function InventoryAggregator:GetWarbandOwnerKey()
    return WARBAND_OWNER_KEY
end

if PocketCFO then
    PocketCFO.InventoryAggregator = InventoryAggregator
end

_G.PocketCFO_InventoryAggregator = InventoryAggregator
