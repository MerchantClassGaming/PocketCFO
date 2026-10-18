-- PocketCFO/Services/InventoryStateService/CraftInventoryAdapter.lua
-- Best-known inventory adjustments for craft completion events.
-- Extracted from CraftEventCapture. Owns consumption construction and
-- inventory adjustment application for the craft workflow. Does not own
-- craft event listening or stat logging.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local PocketCFO = _G.PocketCFO

local CraftInventoryAdapter = {}

local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

local function GetIdentityAdapters()
    return PocketCFO and PocketCFO.ItemIdentityAdapters or _G.PocketCFO_ItemIdentityAdapters
end

local function GetInventoryStateService()
    return PocketCFO and PocketCFO.InventoryStateService or _G.InventoryStateService
end

-- ---------------------------------------------------------------------------
-- Reagent quality helpers
-- ---------------------------------------------------------------------------

local function NormalizeCraftingQuality(quality)
    quality = tonumber(quality)
    if quality and quality > 0 then return quality end
    return nil
end

-- Routes through IdentityAdapters when available; falls back to direct API.
local function GetReagentQuality(reagent, itemRef)
    local adapters = GetIdentityAdapters()
    if adapters and adapters.GetReagentCraftingQuality then
        return adapters:GetReagentCraftingQuality(reagent, itemRef)
    end
    local q = NormalizeCraftingQuality(
        reagent and (reagent.craftingQuality or reagent.quality or reagent.itemQuality)
    )
    if q then return q end
    if itemRef and C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityByItemInfo then
        local ok, v = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, itemRef)
        if ok then return NormalizeCraftingQuality(v) end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Consumption list construction
-- ---------------------------------------------------------------------------

local function AddConsumption(consumption, itemID, quantity, craftingQuality)
    itemID   = tonumber(itemID)
    quantity = tonumber(quantity) or 0
    if not itemID or itemID <= 0 or quantity <= 0 then return end
    craftingQuality = NormalizeCraftingQuality(craftingQuality)
    local key   = tostring(itemID) .. "|" .. tostring(craftingQuality or 0)
    local entry = consumption[key]
    if not entry then
        local itemName
        if GetItemInfo then
            itemName = GetItemInfo(itemID)
        end
        entry = {
            itemID          = itemID,
            itemName        = itemName or ("item:" .. tostring(itemID)),
            quantity        = 0,
            craftingQuality = craftingQuality,
            itemQuality     = craftingQuality,
            isStackable     = true,
        }
        consumption[key] = entry
    end
    entry.quantity = entry.quantity + quantity
end

local function ConsumptionMapToList(consumption)
    local rows = {}
    for _, entry in pairs(consumption or {}) do
        rows[#rows + 1] = entry
    end
    table.sort(rows, function(a, b)
        if a.itemID == b.itemID then
            return (a.craftingQuality or 0) < (b.craftingQuality or 0)
        end
        return a.itemID < b.itemID
    end)
    return rows
end

-- Saved-configuration evidence, keyed by schematic slotIndex, for every
-- reagentType (1, 2, 3) the saved config captured. A slot missing from this
-- map is not "no consumption" - it means the saved config does not reliably
-- cover that slot (e.g. an older config saved before RecipeStateCapture
-- captured required reagentType==2 slots), and the live transaction below
-- fills it instead. Each slot maps to a list of allocation rows because a
-- single reagentType==1 slot can legitimately carry more than one quality
-- entry (mixed-quality allocation).
local function BuildConfigSlotEvidence(config, recipeID)
    local bySlotIndex = {}
    if not config or (recipeID and tonumber(config.recipeID) ~= tonumber(recipeID)) then
        if config then
            SessionLog("CraftInventoryAdapter: ignored pending config reason=recipe-mismatch configID=%s configRecipeID=%s eventRecipeID=%s",
                tostring(config.configID), tostring(config.recipeID), tostring(recipeID))
        end
        return bySlotIndex
    end

    if type(config.matSlots) == "table" then
        for slotIndex, qualityEntries in pairs(config.matSlots) do
            if type(qualityEntries) == "table" then
                local rows = {}
                for _, entry in ipairs(qualityEntries) do
                    if entry and entry.itemID then
                        rows[#rows + 1] = {
                            itemID = entry.itemID,
                            quantity = tonumber(entry.quantity),
                            craftingQuality = entry.craftingQuality or entry.quality or entry.itemQuality
                                or GetReagentQuality(nil, entry.itemID),
                        }
                    end
                end
                if #rows > 0 then
                    bySlotIndex[slotIndex] = rows
                end
            end
        end
    end

    -- Optional/modifying/finishing reagents - missives, embellishments,
    -- finishing reagents. RecipeStateCapture does not record a quantity for
    -- these (single-item slot selection), so quantity resolves below via
    -- ResolveConsumedQuantity's slot-required/fallback tiers, never guessed
    -- here. Not quality-tiered (quality only applies to reagentType==1 mats).
    if type(config.optionalSlots) == "table" then
        for slotIndex, slotEntry in pairs(config.optionalSlots) do
            if type(slotEntry) == "table" and slotEntry.itemID then
                bySlotIndex[slotIndex] = { { itemID = slotEntry.itemID, quantity = nil, craftingQuality = nil } }
            end
        end
    end

    return bySlotIndex
end

-- Resolves the consumed quantity for one slot allocation using the
-- strongest available evidence:
--   1. actual transaction allocation quantity;
--   2/3. a reliable selected-reagent quantity (recorded on the saved
--        config) or the schematic's own quantityRequired - in this
--        codebase both resolve to the same kind of structural fact, so they
--        are tried as one combined tier;
--   4. fallback of 1, logged as a structured diagnostic. Acceptable only
--      because optional/modifying/missive/embellishment/finishing slots are
--      single-item allocations - not extended with speculative handling for
--      a hypothetical multi-quantity optional slot.
local function ResolveConsumedQuantity(recipeID, slotIndex, reagentType, itemID, allocationQty, reliableQty, slotData)
    if allocationQty and allocationQty > 0 then
        return allocationQty
    end
    if reliableQty and reliableQty > 0 then
        return reliableQty
    end
    local schematicQty = tonumber(slotData and slotData.quantityRequired) or 0
    if schematicQty > 0 then
        return schematicQty
    end
    SessionLog("CraftInventoryAdapter: consumed quantity fallback recipeID=%s slotIndex=%s reagentType=%s itemID=%s reason=consumed-quantity-fallback-one",
        tostring(recipeID), tostring(slotIndex), tostring(reagentType), tostring(itemID))
    return 1
end

-- Builds the single normalized consumed-input list for one recipeID/config
-- pair: every schematic reagent slot (reagentType 1, 2, or 3 - required or
-- optional) that has an item actually allocated to it, visited exactly
-- once. Saved-configuration evidence is preferred per slot where present;
-- the live crafting transaction (or, failing that, the live slot button)
-- fills any slot the saved config does not cover. The same list this
-- returns feeds the physical inventory decrement below, and (via
-- CraftCompletionDispatcher/OperationObservationBuilder reusing
-- adjResult.consumedRows) Craft Analysis observation and historical
-- valuation enrichment - one shared normalized list, not three.
local function BuildConsumedInputs(recipeID, config)
    local consumption = {}
    if not recipeID or not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeSchematic then
        return consumption, false
    end

    local schematicInfo = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    if not schematicInfo or not schematicInfo.reagentSlotSchematics then
        return consumption, false
    end

    local configSlots = BuildConfigSlotEvidence(config, recipeID)
    local usedAnyConfig = next(configSlots) ~= nil

    local sf = ProfessionsFrame
        and ProfessionsFrame.CraftingPage
        and ProfessionsFrame.CraftingPage.SchematicForm
    local transaction = nil
    if sf and sf.GetTransaction then
        local ok, res = pcall(function() return sf:GetTransaction() end)
        if ok then transaction = res end
    end
    local reagentSlots = sf and sf.reagentSlots or nil
    local typeCounters = {}

    for arrayIndex, slotData in ipairs(schematicInfo.reagentSlotSchematics) do
        local slotIndex   = slotData.slotIndex
        local reagentType = slotData.reagentType

        -- Advance the per-type slot-frame counter for every slot regardless
        -- of which evidence path resolves it below, so the Nth slot of a
        -- reagentType always maps to the Nth live slot frame of that type.
        typeCounters[reagentType] = (typeCounters[reagentType] or 0) + 1
        local slotFrame = reagentSlots and reagentSlots[reagentType]
            and reagentSlots[reagentType][typeCounters[reagentType]]

        local configRows = configSlots[slotIndex]
        if configRows then
            -- Saved configuration evidence, preferred where present - one
            -- resolved allocation per recorded row (never merged away by
            -- slot; a single itemID appearing in two different slots still
            -- gets its per-slot quantity added into the same output entry
            -- by AddConsumption below, which is correct total consumption,
            -- not a double count of one allocation).
            for _, row in ipairs(configRows) do
                local quantity = ResolveConsumedQuantity(recipeID, slotIndex, reagentType, row.itemID, nil, row.quantity, slotData)
                AddConsumption(consumption, row.itemID, quantity, row.craftingQuality)
            end
        else
            -- Live transaction / slot-frame evidence fills any slot the
            -- saved config did not reliably cover. A single slot can carry
            -- more than one allocated reagent (e.g. a required quantity
            -- split across two quality tiers) - every reagent with an
            -- actual allocated quantity > 0 is added, not just the first
            -- or last one found.
            local addedFromAllocations = false

            if transaction and slotData.reagents then
                local ok, allocs = pcall(function()
                    return transaction:GetAllocations(arrayIndex)
                end)
                if ok and allocs then
                    pcall(function()
                        for _, reagent in ipairs(slotData.reagents) do
                            if reagent.itemID then
                                local alloc = allocs:FindAllocationByReagent(reagent)
                                local qty   = alloc and alloc:GetQuantity() or 0
                                if qty and qty > 0 then
                                    local craftingQuality = (reagentType == 1)
                                        and GetReagentQuality(reagent, reagent.itemID) or nil
                                    AddConsumption(consumption, reagent.itemID, qty, craftingQuality)
                                    addedFromAllocations = true
                                end
                            end
                        end
                    end)
                end
            end

            if not addedFromAllocations then
                local itemID = nil
                if slotFrame and slotFrame.Button and slotFrame.Button.GetItemID then
                    local ok, res = pcall(function() return slotFrame.Button:GetItemID() end)
                    if ok and res then itemID = tonumber(res) end
                end
                if itemID then
                    local craftingQuality = (reagentType == 1) and GetReagentQuality(nil, itemID) or nil
                    local quantity = ResolveConsumedQuantity(recipeID, slotIndex, reagentType, itemID, nil, nil, slotData)
                    AddConsumption(consumption, itemID, quantity, craftingQuality)
                end
            end
        end
    end

    return ConsumptionMapToList(consumption), (usedAnyConfig or next(consumption) ~= nil)
end

-- ---------------------------------------------------------------------------
-- Resourcefulness return rows
-- ---------------------------------------------------------------------------

local function BuildResourcefulnessReturnRows(result)
    local rows = {}
    for _, entry in ipairs((result and result.resourcesReturned) or {}) do
        local reagent  = entry and entry.reagent
        local itemID   = tonumber(reagent and reagent.itemID)
        local quantity = tonumber(entry and entry.quantity) or 0
        if itemID and itemID > 0 and quantity > 0 then
            local quality  = GetReagentQuality(reagent, itemID)
            local itemName
            if GetItemInfo then itemName = GetItemInfo(itemID) end
            rows[#rows + 1] = {
                itemID          = itemID,
                itemName        = itemName or ("item:" .. tostring(itemID)),
                quantity        = quantity,
                craftingQuality = quality,
                itemQuality     = quality,
                isStackable     = true,
            }
        end
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- ConfigKey resolution via IdentityAdapters
-- ---------------------------------------------------------------------------

local function ResolveConfigKeyForRow(adapters, row)
    if not adapters then return nil, nil end
    local identity = adapters:FromSnapshotRow({
        itemID          = row.itemID,
        craftingQuality = row.craftingQuality or row.itemQuality,
    })
    return identity and identity.configKey or nil, identity
end

-- ---------------------------------------------------------------------------
-- Adjustment application
-- ---------------------------------------------------------------------------

-- Distributes consumption across bags → warbank → bank in that order,
-- querying current state to determine available quantities per location.
local function ApplyConsumptionAdjustments(iss, adapters, ownerKey, warbandKey, remaining, state)
    local decremented = 0
    local meta        = { reason = "craft-consumption", source = "CraftInventoryAdapter" }

    for _, reagent in ipairs(remaining) do
        reagent.requestedQuantity = tonumber(reagent.quantity) or 0
        reagent.removedByLocation = { bags = 0, warbank = 0, bank = 0 }

        local configKey, identity = ResolveConfigKeyForRow(adapters, reagent)
        if not configKey then
            reagent.remainingQuantity = reagent.requestedQuantity
            SessionLog("CraftInventoryAdapter: reagent configKey unresolved itemID=%s",
                tostring(reagent.itemID))
        else
            local evidence = {
                configKey = configKey,
                itemID    = reagent.itemID,
                itemName  = reagent.itemName or (identity and identity.itemName),
                itemLink  = identity and identity.itemLink,
            }
            local stateEntry = state.byConfigKey and state.byConfigKey[configKey]
            local byLoc      = stateEntry and stateEntry.byLocation or {}
            local stillNeeded = reagent.requestedQuantity

            local steps = {
                { key = ownerKey,   location = "bags"    },
                { key = warbandKey, location = "warbank" },
                { key = ownerKey,   location = "bank"    },
            }
            for _, step in ipairs(steps) do
                if stillNeeded <= 0 then break end
                local avail = math.max(0, tonumber(byLoc[step.location]) or 0)
                local take  = math.min(stillNeeded, avail)
                if take > 0 then
                    local added = iss:AddTransfer(
                        "craftCompleted", step.key, step.location, nil,
                        evidence, take, meta)
                    if added then
                        reagent.removedByLocation[step.location] = take
                        stillNeeded  = stillNeeded - take
                        decremented  = decremented + take
                    end
                end
            end
            reagent.remainingQuantity = stillNeeded
        end
    end

    return decremented
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function CraftInventoryAdapter:ApplyCraftSnapshotAdjustments(ownerKey, configID, config, recipeID, result)
    local iss      = GetInventoryStateService()
    local adapters = GetIdentityAdapters()

    if not iss then
        SessionLog("CraftInventoryAdapter: adjustment skipped reason=inventory-service-unavailable configID=%s recipeID=%s",
            tostring(configID), tostring(recipeID))
        return { skipped = true, skipReason = "inventory-service-unavailable" }
    end
    if not ownerKey then
        SessionLog("CraftInventoryAdapter: adjustment skipped reason=no-character-guid configID=%s recipeID=%s",
            tostring(configID), tostring(recipeID))
        return { skipped = true, skipReason = "no-character-guid" }
    end

    -- Build consumption rows: one normalized list, merged per-slot from
    -- saved-config (preferred where present) and live-transaction (fills
    -- any slot the saved config does not cover) evidence.
    local remaining = BuildConsumedInputs(recipeID, config)
    local matSource = "merged"

    if not next(remaining) then
        SessionLog("CraftInventoryAdapter: craft mat decrement skipped reason=no-reagent-data configID=%s recipeID=%s",
            tostring(configID), tostring(recipeID))
    end

    -- Get current state once for location-aware distribution.
    local warbandKey = iss:GetWarbandOwnerKey()
    local state      = iss:GetCurrentState({ characterOwnerKey = ownerKey })
    local decremented = ApplyConsumptionAdjustments(iss, adapters, ownerKey, warbandKey, remaining, state)

    -- Resourcefulness returns → bags.
    local returnRows = BuildResourcefulnessReturnRows(result)
    local returned   = 0
    for _, row in ipairs(returnRows) do
        local configKey = ResolveConfigKeyForRow(adapters, row)
        if configKey then
            local added = iss:AddTransfer("craftCompleted", ownerKey, nil, "bags",
                { configKey = configKey, itemID = row.itemID, itemName = row.itemName },
                row.quantity,
                { reason = "craft-resourcefulness", source = "CraftInventoryAdapter" })
            if added then returned = returned + row.quantity end
        end
    end

    -- Craft output increment → bags.
    local outputRow  = nil
    local incremented = 0
    if adapters and adapters.FromCraftResult then
        local identity = adapters:FromCraftResult(result)
        if identity and identity.itemID then
            local now = PocketCFO and PocketCFO.Now and PocketCFO:Now() or time()
            outputRow = {
                itemID          = identity.itemID,
                itemName        = identity.itemName or ("item:" .. tostring(identity.itemID)),
                quantity        = identity.quantity or 1,
                itemQuality     = identity.itemQuality,
                craftingQuality = identity.craftingQuality,
                rarityQuality   = identity.rarityQuality or identity.quality,
                ilvl            = identity.effectiveIlvl,
                itemLink        = identity.itemLink,
                itemGUID        = identity.itemGUID,
                statFingerprint = identity.statFingerprint,
                itemStats       = identity.itemStats,
                isStackable     = identity.isStackable,
                timestamp       = now,
                ownerKey        = ownerKey,
                location        = "bags",
            }
            if identity.configKey then
                local qty   = identity.quantity or 1
                local added = iss:AddTransfer("craftCompleted", ownerKey, nil, "bags",
                    { configKey  = identity.configKey,
                      itemID     = identity.itemID,
                      itemName   = outputRow.itemName,
                      itemLink   = identity.itemLink },
                    qty,
                    { reason = "craft-output", source = "CraftInventoryAdapter" })
                if added then incremented = qty end
            end
        end
    end

    return {
        decremented  = decremented,
        matSource    = matSource,
        consumedRows = remaining,
        returned     = returned,
        returnRows   = returnRows,
        incremented  = incremented,
        outputRow    = outputRow,
    }
end

if PocketCFO then
    PocketCFO.CraftInventoryAdapter = CraftInventoryAdapter
end

_G.PocketCFO_CraftInventoryAdapter = CraftInventoryAdapter
