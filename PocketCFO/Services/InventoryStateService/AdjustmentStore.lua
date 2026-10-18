-- PocketCFO/Services/InventoryStateService/AdjustmentStore.lua
-- Stores active inventory adjustments layered over baseline observations.

local PocketCFO = _G.PocketCFO

local AdjustmentStore = {}

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
    db.inventoryStateService.adjustments = db.inventoryStateService.adjustments or {}
    db.inventoryStateService.nextAdjustmentID = tonumber(db.inventoryStateService.nextAdjustmentID) or 0
    return db.inventoryStateService
end

local function NewAdjustmentID(root)
    root.nextAdjustmentID = (tonumber(root.nextAdjustmentID) or 0) + 1
    return tostring(root.nextAdjustmentID)
end

local function CopyScalarFields(source, target)
    if type(source) ~= "table" then
        return
    end
    for key, value in pairs(source) do
        local valueType = type(value)
        if valueType == "string" or valueType == "number" or valueType == "boolean" then
            target[key] = target[key] == nil and value or target[key]
        end
    end
end

function AdjustmentStore:Add(adjustment)
    if type(adjustment) ~= "table" then
        return nil, "missingAdjustment"
    end
    if not adjustment.configKey or adjustment.configKey == "" then
        return nil, "missingConfigKey"
    end
    local quantityDelta = tonumber(adjustment.quantityDelta or adjustment.delta)
    if not quantityDelta or quantityDelta == 0 then
        return nil, "missingQuantityDelta"
    end
    local ownerKey = adjustment.ownerKey
    local location = NormalizeLocation(adjustment.location)
    if not ownerKey or ownerKey == "" then
        return nil, "missingOwnerKey"
    end
    if not location or location == "" then
        return nil, "missingLocation"
    end

    local root = GetRoot()
    if not root then
        return nil, "dbUnavailable"
    end

    local stored = {
        adjustmentID = NewAdjustmentID(root),
        type = adjustment.type or "manual",
        ownerKey = ownerKey,
        location = location,
        configKey = adjustment.configKey,
        quantityDelta = quantityDelta,
        createdAt = adjustment.createdAt or (PocketCFO and PocketCFO.Now and PocketCFO:Now()) or time(),
        reason = adjustment.reason,
        active = adjustment.active ~= false,
    }
    CopyScalarFields(adjustment, stored)

    root.adjustments[#root.adjustments + 1] = stored
    return stored
end

function AdjustmentStore:AddTransfer(eventType, ownerKey, fromLocation, toLocation, configKey, quantity, metadata)
    quantity = math.abs(tonumber(quantity) or 0)
    if quantity <= 0 then
        return nil, "missingQuantity"
    end
    metadata = type(metadata) == "table" and metadata or {}

    local added = {}
    if fromLocation then
        local dec, err = self:Add({
            type = eventType,
            ownerKey = ownerKey,
            location = fromLocation,
            configKey = configKey,
            quantityDelta = -quantity,
            reason = metadata.reason,
            itemID = metadata.itemID,
            itemName = metadata.itemName,
            itemLink = metadata.itemLink,
            auctionID = metadata.auctionID,
        })
        if not dec then
            return nil, err
        end
        added[#added + 1] = dec
    end
    if toLocation then
        local inc, err = self:Add({
            type = eventType,
            ownerKey = ownerKey,
            location = toLocation,
            configKey = configKey,
            quantityDelta = quantity,
            reason = metadata.reason,
            itemID = metadata.itemID,
            itemName = metadata.itemName,
            itemLink = metadata.itemLink,
            auctionID = metadata.auctionID,
        })
        if not inc then
            return nil, err
        end
        added[#added + 1] = inc
    end
    return added
end

function AdjustmentStore:ClearForLocation(ownerKey, location, reason)
    location = NormalizeLocation(location)
    local root = GetRoot()
    local cleared = 0
    if not root then
        return 0
    end
    for _, adjustment in ipairs(root.adjustments or {}) do
        if adjustment.active ~= false
        and tostring(adjustment.ownerKey) == tostring(ownerKey)
        and NormalizeLocation(adjustment.location) == location then
            adjustment.active = false
            adjustment.clearedAt = (PocketCFO and PocketCFO.Now and PocketCFO:Now()) or time()
            adjustment.clearReason = reason or "authoritativeObservation"
            cleared = cleared + 1
        end
    end
    return cleared
end

function AdjustmentStore:List(options)
    local root = GetRoot()
    local rows = root and root.adjustments or {}
    if not options or options.includeInactive then
        return rows
    end

    local active = {}
    for _, adjustment in ipairs(rows) do
        if adjustment.active ~= false then
            active[#active + 1] = adjustment
        end
    end
    return active
end

if PocketCFO then
    PocketCFO.InventoryAdjustmentStore = AdjustmentStore
end

_G.PocketCFO_InventoryAdjustmentStore = AdjustmentStore
