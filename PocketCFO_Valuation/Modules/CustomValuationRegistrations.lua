-- PocketCFO_Valuation/Modules/CustomValuationRegistrations.lua
-- The one central place custom item/currency valuation strategies are
-- registered with ValuationService (see PocketCFO/CLAUDE.md "Prefer Canonical
-- Services Over Local Implementations" - this is that canonical place, not a
-- second copy of the container/Moxie lists scattered elsewhere).
--
-- Two responsibilities:
--   1. Register a container-outcome valuation strategy for every seeded
--      container itemID (PocketCFO.ContainerOutcomeService:GetSeedContainerItemIDs()
--      is the single source of truth for which 13 itemIDs those are - not
--      hardcoded a second time here), and for every container the player has
--      opened (GetObservedContainerItemIDs; new ones arrive by
--      MCG_CONTAINER_OPENED, 2026-10-26). Gold per opening counts in the value.
--   2. Register the 11 profession Moxie currency valuations (600 Moxie = 1
--      corresponding profession surplus bag).
--
-- No valuation-purpose modes, no generalized valuation graph, no
-- recommendation logic - just registration + two small evaluate() functions.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local function GetValuationService()
    return PocketCFO_Valuation:GetModule("ValuationService", true)
end

local function GetContainerOutcomeService()
    return _G.PocketCFO and _G.PocketCFO.ContainerOutcomeService
end

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

-- ─── Container valuation ────────────────────────────────────────────────────
-- Known expected unit value of one container = sum of (expected quantity x
-- current unit value) over every expected output that can currently be
-- priced. Outputs that can't be priced are excluded from the known value (not
-- dropped from the container's resolution) and retained in
-- unvaluedDependencies for diagnostics - a container with at least one
-- valuable output is never made fully unresolved by one unpriced ingredient.
--
-- Non-stackable outputs (recipes/designs, tools, pets...) are left out of the
-- value and returned as possibleDrops (Brian, 2026-10-20). They are rare
-- one-offs: a small sample can't estimate their drop rate (one Design in 9
-- Alchemist Surplus opens added 11,111g to every bag, at roughly 1 in 100 in
-- Brian's experience), and their price often rests on one listing. They're a
-- bonus, not what the bag is worth.
-- Exception (Brian, 2026-10-26): when one-off items are ALL a container has
-- ever given (Thalassian Recipe in a Bottle: one recipe per opening), they are
-- what it's worth, so they count like any other output.
--
-- An output with no market value (bound gear: Deepvine Shroud from the Apex
-- Cache) counts at its vendor sell price (Brian, 2026-10-27). No disenchant
-- comparison. Outputs with no market value and no sell price stay unvalued.
--
-- An output whose item data isn't loaded yet can't be classified, so it is
-- left out too and the result is flagged itemDataPending (never cached), so
-- the value doesn't swing with whichever items the client happens to have
-- loaded.

-- true / false, or nil while item data isn't loaded. maxStack is
-- GetItemInfo's 8th return (same read PricingIdentity uses).
local function IsStackableItem(itemID)
    if not itemID or not GetItemInfo then
        return nil
    end
    local ok, name, _, _, _, _, _, _, maxStack = pcall(GetItemInfo, itemID)
    maxStack = ok and name and tonumber(maxStack) or nil
    if not maxStack then
        return nil
    end
    return maxStack > 1
end

-- What a merchant pays for one (GetItemInfo's 11th return), or nil when it
-- pays nothing. Container-only fallback for outputs with no market value
-- (Brian, 2026-10-27): ValuationService stays "worth to other players" and
-- never uses sell prices.
local function VendorSellPrice(itemID)
    if not itemID or not GetItemInfo then
        return nil
    end
    local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(GetItemInfo, itemID)
    sellPrice = ok and name and tonumber(sellPrice) or nil
    if sellPrice and sellPrice > 0 then
        return sellPrice
    end
    return nil
end

local function ComputeContainerValue(context)
    local containerOutcomeService = GetContainerOutcomeService()
    if not containerOutcomeService or type(containerOutcomeService.GetExpectedContents) ~= "function" then
        return { unresolved = true, unresolvedReason = "containerOutcomeServiceUnavailable" }
    end

    local expected = containerOutcomeService:GetExpectedContents({ itemID = context.itemID })
    if type(expected) ~= "table" or expected.resolved ~= true then
        return {
            unresolved = true,
            unresolvedReason = (type(expected) == "table" and expected.unresolvedReason) or "containerOutcomeUnresolved",
        }
    end

    -- Gold that comes out of the container (local openings only).
    local expectedCopper = tonumber(expected.expectedCopper) or 0
    local total = expectedCopper
    local anyValued = expectedCopper > 0
    local unvaluedDependencies = {}
    local possibleDrops = {}
    local vendorSellOutputs = {}
    -- ContainerOutcomeService couldn't sort local one-offs yet (item data
    -- loading; 2026-11-07 confidence filter): never cache this result.
    local itemDataPending = expected.itemDataPending == true
    local openCount = tonumber(expected.effectiveOpenCount) or 0

    -- One-offs count when every output is a one-off (no stackable output and
    -- none still loading).
    local onlyOneOffs = #(expected.expectedContents or {}) > 0
    for _, row in ipairs(expected.expectedContents or {}) do
        if IsStackableItem(row.itemID) ~= false then
            onlyOneOffs = false
            break
        end
    end

    for _, row in ipairs(expected.expectedContents or {}) do
        local stackable = IsStackableItem(row.itemID)
        if onlyOneOffs then
            stackable = true
        end
        if stackable == nil then
            itemDataPending = true
            unvaluedDependencies[#unvaluedDependencies + 1] = {
                itemID = row.itemID,
                configKey = row.configKey,
                expectedQuantity = row.expectedQuantity,
                reason = "itemDataPending",
            }
        elseif stackable == false then
            possibleDrops[#possibleDrops + 1] = {
                itemID = row.itemID,
                configKey = row.configKey,
                expectedQuantity = row.expectedQuantity,
                -- Total copies seen across all opens (one per drop for a
                -- non-stackable).
                timesSeen = math.floor((tonumber(row.expectedQuantity) or 0) * openCount + 0.5),
                openCount = openCount,
            }
        else
            local priced = context.valuationService:GetItemValue({ itemID = row.itemID, configKey = row.configKey })
            local sellPrice = nil
            if not (priced and not priced.unresolved and priced.valuePerUnit ~= nil) then
                sellPrice = VendorSellPrice(row.itemID)
            end
            if priced and not priced.unresolved and priced.valuePerUnit ~= nil then
                total = total + priced.valuePerUnit * row.expectedQuantity
                anyValued = true
            elseif sellPrice then
                -- No market value (e.g. bound gear): counted at what a
                -- merchant pays for it (Brian, 2026-10-27).
                total = total + sellPrice * row.expectedQuantity
                anyValued = true
                vendorSellOutputs[#vendorSellOutputs + 1] = {
                    itemID = row.itemID,
                    expectedQuantity = row.expectedQuantity,
                    sellPrice = sellPrice,
                }
            else
                unvaluedDependencies[#unvaluedDependencies + 1] = {
                    itemID = row.itemID,
                    configKey = row.configKey,
                    expectedQuantity = row.expectedQuantity,
                }
            end
        end
    end

    if not anyValued then
        return {
            unresolved = true,
            unresolvedReason = itemDataPending and "itemDataPending" or "noValuedContents",
            unvaluedDependencies = unvaluedDependencies,
            possibleDrops = possibleDrops,
        }
    end

    return {
        value = total,
        valuePerUnit = total,
        strategyKey = "containerOutcome",
        -- Statistical model (expected contents x current unit value), never
        -- a literal fixed input - ValuationService surfaces this as
        -- valuationBasis="modeled" so Orders shows "(Estimated)".
        valuationBasis = "modeled",
        unvaluedDependencies = unvaluedDependencies,
        possibleDrops = possibleDrops,
        vendorSellOutputs = vendorSellOutputs,
        itemDataPending = itemDataPending,
    }
end

-- ─── Container value cache ──────────────────────────────────────────────────
-- Pricing one container means a full value lookup for every expected output
-- (41 for the Midnight Consortium Payout) plus quality-sibling lookups, and
-- tooltips ask again on every redraw while the bag is hovered - that was the
-- hover lag (2026-10-16). Resolved container values are kept per itemID and
-- thrown away when any price changes (PCFO_PRICING_UPDATED) or after
-- CONTAINER_CACHE_SECONDS, which covers changes that don't broadcast
-- (vendor price observations, new local bag opens). Unresolved results are
-- never cached so a container whose item data is still loading retries.
-- The cached table is never handed out directly - callers downstream
-- (ValuationService, rule adjustments) write into the result they get.
local CONTAINER_CACHE_SECONDS = 60
local containerValueCache = {}

local function ClearContainerValueCache()
    wipe(containerValueCache)
end

local function ShallowCopy(source)
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

local function EvaluateContainerValue(context)
    local itemID = tonumber(context and context.itemID)
    local now = GetTime()
    local cached = itemID and containerValueCache[itemID]
    if cached and (now - cached.at) < CONTAINER_CACHE_SECONDS then
        return ShallowCopy(cached.result)
    end

    local result = ComputeContainerValue(context)
    -- A result missing not-yet-loaded items is a partial value - never cached.
    if itemID and type(result) == "table" and not result.unresolved and result.valuePerUnit ~= nil
        and not result.itemDataPending then
        containerValueCache[itemID] = { at = now, result = ShallowCopy(result) }
    end
    return result
end

local cacheListener = LibStub("AceEvent-3.0"):Embed({})
cacheListener:RegisterMessage("PCFO_PRICING_UPDATED", ClearContainerValueCache)

local registeredContainers = {}

local function RegisterContainer(valuationService, itemID)
    itemID = tonumber(itemID)
    if not itemID or registeredContainers[itemID] then
        return
    end
    registeredContainers[itemID] = true
    valuationService:RegisterCustomItemValuation({
        itemID = itemID,
        strategyKey = "containerOutcome",
        evaluate = EvaluateContainerValue,
    })
end

local function RegisterContainerStrategies()
    local valuationService = GetValuationService()
    local containerOutcomeService = GetContainerOutcomeService()
    if not valuationService or not containerOutcomeService then
        return
    end

    for _, itemID in ipairs(containerOutcomeService:GetSeedContainerItemIDs()) do
        RegisterContainer(valuationService, itemID)
    end
    if type(containerOutcomeService.GetObservedContainerItemIDs) == "function" then
        for _, itemID in ipairs(containerOutcomeService:GetObservedContainerItemIDs()) do
            RegisterContainer(valuationService, itemID)
        end
    end
end

-- A container was just opened: value it from now on, and drop cached values
-- so its new average is used.
cacheListener:RegisterMessage("MCG_CONTAINER_OPENED", function(_, itemID)
    local valuationService = GetValuationService()
    if valuationService then
        pcall(RegisterContainer, valuationService, itemID)
    end
    ClearContainerValueCache()
end)

-- ─── Moxie currency valuation ───────────────────────────────────────────────
-- 600 profession Moxie -> 1 corresponding profession surplus bag, so the unit
-- value of one Moxie point is that bag's current expected value / 600.
local MOXIE_CURRENCY_TO_BAG_ITEM_ID = {
    [3256] = 260534, -- Alchemy -> Alchemist Surplus
    [3257] = 260536, -- Blacksmithing -> Smith Surplus
    [3258] = 260537, -- Enchanting -> Enchanter Surplus
    [3259] = 260538, -- Engineering -> Engineer Surplus
    [3260] = 260539, -- Herbalism -> Herbalist Surplus
    [3261] = 260540, -- Inscription -> Scribe Surplus
    [3262] = 260541, -- Jewelcrafting -> Jewelcrafter Surplus
    [3263] = 260542, -- Leatherworking -> Leatherworker Surplus
    [3264] = 260543, -- Mining -> Miner Surplus
    [3265] = 260544, -- Skinning -> Skinner Surplus
    [3266] = 260545, -- Tailoring -> Master Tailor's Surplus Reagents
}

local MOXIE_TO_BAG_RATIO = 600

local function MakeMoxieEvaluator(bagItemID)
    return function(context)
        local bagValue = context.valuationService:GetItemValue({ itemID = bagItemID })
        if not bagValue or bagValue.unresolved or bagValue.valuePerUnit == nil then
            return { unresolved = true, unresolvedReason = "bagValueUnavailable" }
        end

        local unitValue = bagValue.valuePerUnit / MOXIE_TO_BAG_RATIO
        return {
            value = unitValue,
            valuePerUnit = unitValue,
            strategyKey = "moxieBagRatio",
            -- Derived from a ratio applied to the bag's own current value,
            -- never a literal fixed input - surfaced as valuationBasis=
            -- "modeled" so Orders shows "(Estimated)" for Moxie rewards.
            valuationBasis = "modeled",
            basis = "bagItemID:" .. tostring(bagItemID),
        }
    end
end

local function RegisterMoxieCurrencyStrategies()
    local valuationService = GetValuationService()
    if not valuationService then
        return
    end

    for currencyID, bagItemID in pairs(MOXIE_CURRENCY_TO_BAG_ITEM_ID) do
        valuationService:RegisterCustomCurrencyValuation({
            currencyID = currencyID,
            strategyKey = "moxieBagRatio",
            evaluate = MakeMoxieEvaluator(bagItemID),
        })
    end
end

local function RegisterAll()
    local ok, err = pcall(function()
        RegisterContainerStrategies()
        RegisterMoxieCurrencyStrategies()
    end)
    if not ok then
        local diagnostics = _G.PocketCFO and _G.PocketCFO.Diagnostics
        if diagnostics and diagnostics.Debug then
            diagnostics:Debug("[CustomValuationRegistrations] registration failed: %s", tostring(err))
        end
    end
end

RegisterAll()

if PocketCFO_Valuation then
    PocketCFO_Valuation.MOXIE_CURRENCY_TO_BAG_ITEM_ID = MOXIE_CURRENCY_TO_BAG_ITEM_ID
end
