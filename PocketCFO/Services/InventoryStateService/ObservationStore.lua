-- PocketCFO/Services/InventoryStateService/ObservationStore.lua
-- Stores authoritative baseline observations by owner and location.

local PocketCFO = _G.PocketCFO

local ObservationStore = {}

local VALID_LOCATIONS = {
    bags = true,
    bank = true,
    warbank = true,
    mail = true,
    ah = true,
}

local function NormalizeLocation(location)
    if location == "mailbox" then
        return "mail"
    end
    return location
end

local function GetRoot()
    if not PocketCFO or not PocketCFO.db or not PocketCFO.db.global then
        return nil
    end
    local db = PocketCFO.db.global
    db.inventoryStateService = db.inventoryStateService or {}
    db.inventoryStateService.observations = db.inventoryStateService.observations or {}
    return db.inventoryStateService.observations
end

local function CopyRow(row)
    if type(row) ~= "table" then
        return nil
    end
    local copy = {}
    for key, value in pairs(row) do
        local valueType = type(value)
        if valueType == "string" or valueType == "number" or valueType == "boolean" then
            copy[key] = value
        elseif key == "itemStats" and valueType == "table" then
            copy[key] = value
        end
    end
    return copy
end

local function GetOwnerBucket(root, ownerKey)
    if not root or not ownerKey or ownerKey == "" then
        return nil
    end
    root[ownerKey] = root[ownerKey] or {}
    return root[ownerKey]
end

function ObservationStore:NormalizeLocation(location)
    return NormalizeLocation(location)
end

function ObservationStore:IsValidLocation(location)
    return VALID_LOCATIONS[NormalizeLocation(location)] == true
end

function ObservationStore:Replace(ownerKey, location, rows, metadata)
    location = NormalizeLocation(location)
    if not ownerKey or ownerKey == "" then
        return nil, "missingOwnerKey"
    end
    if not VALID_LOCATIONS[location] then
        return nil, "invalidLocation"
    end

    local root = GetRoot()
    if not root then
        return nil, "dbUnavailable"
    end

    local owner = GetOwnerBucket(root, ownerKey)
    local storedRows = {}
    for _, row in ipairs(rows or {}) do
        local copy = CopyRow(row)
        if copy then
            copy.ownerKey = copy.ownerKey or ownerKey
            copy.location = NormalizeLocation(copy.location or location)
            copy.quantity = tonumber(copy.quantity or copy.count or copy.stackCount) or 1
            copy.timestamp = tonumber(copy.timestamp) or (PocketCFO and PocketCFO.Now and PocketCFO:Now()) or time()
            storedRows[#storedRows + 1] = copy
        end
    end

    owner[location] = {
        ownerKey = ownerKey,
        location = location,
        rows = storedRows,
        replacedAt = (PocketCFO and PocketCFO.Now and PocketCFO:Now()) or time(),
        source = type(metadata) == "table" and metadata.source or nil,
        reason = type(metadata) == "table" and metadata.reason or nil,
    }

    return owner[location]
end

function ObservationStore:Get(ownerKey, location)
    location = NormalizeLocation(location)
    local root = GetRoot()
    local owner = root and ownerKey and root[ownerKey] or nil
    local observation = owner and owner[location] or nil
    if type(observation) == "table" and type(observation.rows) == "table" then
        return observation
    end
    return nil
end

function ObservationStore:List()
    return GetRoot() or {}
end

if PocketCFO then
    PocketCFO.InventoryObservationStore = ObservationStore
end

_G.PocketCFO_InventoryObservationStore = ObservationStore
