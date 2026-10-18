-- PocketCFO/Services/ContainerOutcomeService/ContainerOutcomeService.lua
-- Answers exactly one question: "Based on the published seed observations plus
-- this user's local observations, what contents are expected from opening this
-- container once?" Also records newly observed local container openings.
-- Does not value contents - see PocketCFO_Valuation's custom container
-- valuation strategies for that.
--
-- Published seed aggregate (ContainerOutcomeSeedData.lua) is immutable code.
-- Only local observations are persisted, in PocketCFO_DB.global.
-- containerOutcomeObservations - the two are combined at read time, never
-- merged into SavedVariables.

local PocketCFO = _G.PocketCFO

local ContainerOutcomeService = {}

ContainerOutcomeService.configKeyCache = ContainerOutcomeService.configKeyCache or {}

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function GetSeedData()
    return (PocketCFO and PocketCFO.ContainerOutcomeSeedData) or _G.PocketCFO_ContainerOutcomeSeedData
end

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

-- Resolves and caches itemID -> configKey via ItemIdentityService. Cache is
-- keyed by itemID only (never persisted) - safe to retry every call since a
-- prior "itemDataPending" miss should resolve once Blizzard's item data cache
-- fills in.
local function ResolveConfigKey(itemID)
    itemID = NumberOrNil(itemID)
    if not itemID then
        return nil, "missingItemID"
    end

    local cache = ContainerOutcomeService.configKeyCache
    if cache[itemID] then
        return cache[itemID], nil
    end

    local identityService = GetItemIdentityService()
    if not identityService then
        return nil, "itemIdentityServiceUnavailable"
    end

    local ok, identity = pcall(function()
        return identityService:FromItemID(itemID)
    end)
    if not ok or type(identity) ~= "table" or not identity.configKey then
        local reason = ok and type(identity) == "table" and identity.unresolvedReason or "identityResolutionFailed"
        return nil, reason
    end

    cache[itemID] = identity.configKey
    return identity.configKey, nil
end

local function ResolveContainerItemID(containerReference)
    if type(containerReference) == "number" then
        return containerReference
    end
    if type(containerReference) == "table" then
        return NumberOrNil(containerReference.itemID or containerReference.containerItemID)
    end
    return nil
end

local function GetGlobalDB()
    if not PocketCFO or not PocketCFO.db or type(PocketCFO.db.global) ~= "table" then
        return nil
    end
    PocketCFO.db.global.containerOutcomeObservations = PocketCFO.db.global.containerOutcomeObservations or {}
    return PocketCFO.db.global
end

local function LocalStorageKey(containerConfigKey, containerItemID)
    return containerConfigKey or ("itemID:" .. tostring(containerItemID))
end

--- Additive SavedVariables initialization - call once from Core.lua:OnInitialize.
function ContainerOutcomeService:InitializeDatabase(globalDB)
    if type(globalDB) ~= "table" then
        return
    end
    globalDB.containerOutcomeObservations = globalDB.containerOutcomeObservations or {}
end

--- Returns the sorted list of seeded container itemIDs. Used by
-- PocketCFO_Valuation's central registration file so the 13 seeded
-- containers only need to be enumerated in one place (the seed data file).
function ContainerOutcomeService:GetSeedContainerItemIDs()
    local seed = GetSeedData()
    local ids = {}
    if not seed or type(seed.containers) ~= "table" then
        return ids
    end
    for itemID in pairs(seed.containers) do
        ids[#ids + 1] = itemID
    end
    table.sort(ids)
    return ids
end

--- Returns { resolved, containerConfigKey, seedVersion, seedOpenCount,
-- localOpenCount, effectiveOpenCount, expectedContents = {{configKey, itemID,
-- expectedQuantity}} } for one container. expectedQuantity is never rounded.
function ContainerOutcomeService:GetExpectedContents(containerReference)
    local containerItemID = ResolveContainerItemID(containerReference)
    if not containerItemID then
        return { resolved = false, unresolvedReason = "missingContainerItemID" }
    end

    local seed = GetSeedData()
    local seedContainer = seed and type(seed.containers) == "table" and seed.containers[containerItemID] or nil
    local containerConfigKey = ResolveConfigKey(containerItemID)

    local globalDB = GetGlobalDB()
    local localRow = globalDB and globalDB.containerOutcomeObservations[LocalStorageKey(containerConfigKey, containerItemID)] or nil

    local seedOpenCount = (seedContainer and NumberOrNil(seedContainer.openCount)) or 0
    local localOpenCount = (localRow and NumberOrNil(localRow.openCount)) or 0
    local effectiveOpenCount = seedOpenCount + localOpenCount

    if effectiveOpenCount <= 0 then
        return {
            resolved = false,
            unresolvedReason = "noObservations",
            containerConfigKey = containerConfigKey,
        }
    end

    local totals = {}
    local order = {}

    local function AddTotal(itemID, quantity)
        quantity = NumberOrNil(quantity)
        if not quantity or quantity == 0 then
            return
        end
        itemID = NumberOrNil(itemID)
        if not itemID then
            return
        end
        local outputConfigKey = ResolveConfigKey(itemID)
        local key = outputConfigKey or ("itemID:" .. tostring(itemID))
        if not totals[key] then
            totals[key] = { itemID = itemID, configKey = outputConfigKey, quantity = 0 }
            order[#order + 1] = key
        end
        totals[key].quantity = totals[key].quantity + quantity
    end

    if seedContainer and type(seedContainer.outputs) == "table" then
        for _, row in ipairs(seedContainer.outputs) do
            AddTotal(row.itemID, row.quantity)
        end
    end

    if localRow and type(localRow.outputTotals) == "table" then
        for _, row in pairs(localRow.outputTotals) do
            AddTotal(row.itemID, row.quantity)
        end
    end

    local expectedContents = {}
    for _, key in ipairs(order) do
        local total = totals[key]
        expectedContents[#expectedContents + 1] = {
            configKey = total.configKey,
            itemID = total.itemID,
            expectedQuantity = total.quantity / effectiveOpenCount,
        }
    end

    return {
        resolved = true,
        containerConfigKey = containerConfigKey,
        seedVersion = seed and seed.seedVersion,
        seedOpenCount = seedOpenCount,
        localOpenCount = localOpenCount,
        effectiveOpenCount = effectiveOpenCount,
        expectedContents = expectedContents,
    }
end

--- Records one (or a coalesced batch of) real container opening(s) observed
-- locally. Writes only to the local observations branch - never touches the
-- published seed. Any output row whose itemID equals the container's own
-- itemID is dropped (see ContainerOutcomeSeedData.lua header - the same
-- self-referential capture-artifact shape observed in the published seed).
-- Output rows with no resolvable configKey are recorded diagnostically and
-- skipped rather than dropping the whole opening.
-- @param params table {
--     containerConfigKey = string|nil,
--     containerItemID = number|nil,
--     outputs = { { configKey = string|nil, itemID = number, quantity = number }, ... },
--     openCount = number|nil (defaults to 1),
--     evidenceKey = any (reserved; not required by the current caller),
-- }
-- @return boolean ok, table diagnostics|string reason
function ContainerOutcomeService:RecordOpening(params)
    params = type(params) == "table" and params or {}

    local containerItemID = NumberOrNil(params.containerItemID)
    local containerConfigKey = params.containerConfigKey
    if not containerConfigKey and containerItemID then
        containerConfigKey = ResolveConfigKey(containerItemID)
    end
    if not containerConfigKey and not containerItemID then
        return false, "missingContainerIdentity"
    end

    local globalDB = GetGlobalDB()
    if not globalDB then
        return false, "databaseUnavailable"
    end

    local openCount = NumberOrNil(params.openCount) or 1
    if openCount <= 0 then
        return false, "invalidOpenCount"
    end

    local key = LocalStorageKey(containerConfigKey, containerItemID)
    local row = globalDB.containerOutcomeObservations[key]
    if not row then
        row = { openCount = 0, outputTotals = {} }
        globalDB.containerOutcomeObservations[key] = row
    end
    row.outputTotals = row.outputTotals or {}
    row.openCount = (NumberOrNil(row.openCount) or 0) + openCount

    local diagnostics = { unresolvedOutputs = {}, suppressedSelfOutputs = {} }

    for _, output in ipairs(type(params.outputs) == "table" and params.outputs or {}) do
        local outputItemID = NumberOrNil(output.itemID)
        local quantity = NumberOrNil(output.quantity)

        if outputItemID and containerItemID and outputItemID == containerItemID then
            diagnostics.suppressedSelfOutputs[#diagnostics.suppressedSelfOutputs + 1] = {
                itemID = outputItemID,
                quantity = quantity,
            }
        elseif outputItemID and quantity and quantity > 0 then
            local outputConfigKey = output.configKey
            local reason
            if not outputConfigKey then
                outputConfigKey, reason = ResolveConfigKey(outputItemID)
            end

            if not outputConfigKey then
                diagnostics.unresolvedOutputs[#diagnostics.unresolvedOutputs + 1] = {
                    itemID = outputItemID,
                    quantity = quantity,
                    reason = reason,
                }
            else
                local outputKey = outputConfigKey
                local totalRow = row.outputTotals[outputKey]
                if not totalRow then
                    totalRow = { itemID = outputItemID, quantity = 0 }
                    row.outputTotals[outputKey] = totalRow
                end
                totalRow.quantity = (NumberOrNil(totalRow.quantity) or 0) + quantity
            end
        end
    end

    return true, diagnostics
end

if PocketCFO then
    PocketCFO.ContainerOutcomeService = ContainerOutcomeService
end

_G.PocketCFO_ContainerOutcomeService = ContainerOutcomeService
