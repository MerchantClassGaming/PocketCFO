-- PocketCFO_Valuation/Modules/ValuationService.lua
-- Stable, addon-external API answering only "what is this item worth right
-- now?". Wraps the existing PricingIdentity (identity/market-key
-- resolution) and PricingCache (timestamped price storage) modules - no new
-- pricing math, no economics, no recommendations, no historical/trend
-- analysis. Calculating prices into the cache (PricingValuation, FullScan,
-- SearchRefresh) is unchanged and out of scope here.
--
-- Future Core consumers (e.g. the planned OperationEconomicsService) should
-- never touch PricingIdentity/PricingCache directly, and should never
-- assume this addon is loaded - PocketCFO_Valuation is LoadOnDemand. The
-- safe access pattern from another addon is:
--
--   local function GetValuationService()
--       local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_Valuation"))
--           or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_Valuation"))
--       if not loaded then
--           return nil
--       end
--       local valuation = _G.PocketCFO_Valuation
--       return valuation and valuation.GetModule and valuation:GetModule("ValuationService", true)
--   end
--
-- If GetValuationService() returns nil, treat the price as unresolved
-- (reason "valuationAddonUnavailable") rather than forcing the addon to
-- load as a side effect of a pricing query.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local ValuationService = PocketCFO_Valuation:NewModule("ValuationService")

local CURRENCY_COPPER = "copper"

-- Canonical valuation source/basis identity strings. "source" says which
-- system produced the value; "valuationBasis" says whether that value is a
-- literal fixed input, a directly observed market price, or a computed/
-- statistical model - see PocketCFO_Valuation Core.lua's GetItemValue
-- header and the CLAUDE.md architecture notes on valuation provenance.
local SOURCE_CUSTOM = "custom"
local SOURCE_VENDOR = "vendorPurchase"
local SOURCE_AH = "auctionHouse"

local BASIS_FIXED = "fixed"
local BASIS_MODELED = "modeled"
local BASIS_MARKET_OBSERVED = "marketObserved"
local BASIS_UNRESOLVED = "unresolved"

-- Minimal custom valuation registry (see PocketCFO_Orders MVP completion
-- report for the full design). Canonical resolution order for GetItemValue
-- is:
--   1. registered custom strategy (ResolveCustomItemValuation) - always
--      wins when it resolves, including both fixed and modeled strategies
--   2. vendor purchase price (VendorPriceService - player observation or
--      bundled default, both canonical)
--   3. AH-derived value (ResolveAHValue)
--   4. unresolved
-- Custom strategies are pcall-guarded and share a single recursion guard
-- with currency valuation so a container strategy that recursively prices
-- another container (or a currency strategy) can't infinite-loop.
-- Item strategies are stored as "value" rules in ValuationRules (2026-10-12)
-- so item, item-variant and category rules all resolve in one place. After
-- the source is picked, every matching "adjust" rule runs (cap, floor,
-- flag, reject) - see ApplyRuleAdjustments.
ValuationService.customCurrencyStrategies = ValuationService.customCurrencyStrategies or {}
ValuationService._customValuationStack = ValuationService._customValuationStack or {}

local function GetValuationRules()
    return PocketCFO_Valuation:GetModule("ValuationRules", true)
end

local function GetPricingIdentity()
    return PocketCFO_Valuation:GetModule("PricingIdentity", true)
end

local function GetPricingCache()
    return PocketCFO_Valuation:GetModule("PricingCache", true)
end

local function GetVendorPriceService()
    return PocketCFO_Valuation:GetModule("VendorPriceService", true)
end

local function NonEmptyString(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return tostring(value)
end

local function NewUnresolved(itemID, configKey, reason)
    reason = reason or "valueUnresolved"
    return {
        value = nil,
        valuePerUnit = nil,
        currency = CURRENCY_COPPER,
        basis = nil,
        source = nil,
        strategyKey = nil,
        itemID = itemID,
        configKey = configKey,
        isFresh = nil,
        lastUpdated = nil,
        unresolved = true,
        unresolvedReason = reason,
        resolved = false,
        reason = reason,
        valuationBasis = BASIS_UNRESOLVED,
        provenance = nil,
    }
end

-- Normalizes the accepted itemRef shapes (itemID, itemLink string, or an
-- identity-like table carrying itemID/configKey/qualityTier/itemLevel/
-- statFingerprint/itemLink) into the fields BuildMarketKey needs.
--
-- Deliberately does NOT invent an itemID from a bare configKey string.
-- Core's ItemIdentityService configKey space and Valuation's marketKey
-- space are different identity systems with no reverse mapping today (see
-- PocketCFO/Services/ItemIdentityService/ItemIdentityService.lua
-- ResolveConfigKey, which is itself unsupported). A configKey is only
-- usable here when it arrives alongside an itemID on the same itemRef
-- table - guessing one from the other would violate "never guess missing
-- identity".
local function NormalizeItemRef(itemRef)
    if type(itemRef) == "number" then
        return { itemID = itemRef }, nil
    end

    if type(itemRef) == "string" then
        if itemRef:find("item:", 1, true) then
            return { itemLink = itemRef }, nil
        end
        return { configKey = itemRef }, "configKeyRequiresItemID"
    end

    if type(itemRef) == "table" then
        local itemID = tonumber(itemRef.itemID)
        local configKey = NonEmptyString(itemRef.configKey)
        if not itemID then
            return { configKey = configKey }, "configKeyRequiresItemID"
        end
        return {
            itemID = itemID,
            configKey = configKey,
            itemLink = itemRef.itemLink,
            qualityTier = itemRef.qualityTier or itemRef.craftingQuality,
            itemLevel = itemRef.itemLevel or itemRef.ilvl or itemRef.effectiveIlvl,
            statFingerprint = itemRef.statFingerprint,
        }, nil
    end

    return {}, "unsupportedItemRef"
end

-- Resolves a market key (and, when only an itemLink was supplied, the
-- itemID Blizzard's API derives from it) using only existing
-- PricingIdentity entry points.
local function ResolveMarketKey(identityModule, normalized)
    if normalized.itemID then
        local marketKey = identityModule:BuildMarketKey({
            itemID = normalized.itemID,
            itemLink = normalized.itemLink,
            qualityTier = normalized.qualityTier,
            itemLevel = normalized.itemLevel,
            statFingerprint = normalized.statFingerprint,
        })
        return marketKey, normalized.itemID
    end

    if normalized.itemLink then
        local identity = identityModule:BuildFromItemLink(normalized.itemLink)
        return identity and identity.marketKey, identity and identity.itemID
    end

    return nil, nil
end

-- Variable-stat items (e.g. a profession tool that can roll Multicraft,
-- Resourcefulness, Crafting Speed or Ingenuity): the AH scan saves each stat
-- version under its own key, "itemID|q5|stats:...". Something with no stats
-- of its own - Recipe Analysis's predicted output before you pick a stat -
-- builds "itemID|q5" and never matches any of them (Brian, 2026-10-12).
-- When that key has no price, this returns the plain average of every
-- priced stat version of the same item at the same quality/ilvl, marked
-- modeled so it shows as "(Estimated)". Computed on lookup, never stored:
-- the cache only ever holds real AH observations.
-- Only for a key without chosen stats (none, or Blizzard's placeholder - see
-- BaseKeyWithoutChosenStats) - a real item with its own stats keeps "no
-- price" rather than borrowing other versions' prices.
-- Blizzard's crafting-window preview of a variable-stat item carries a
-- placeholder stat instead of none: ITEM_MOD_MODIFIED_CRAFTING_STAT_1
-- ("a stat you'll choose"). Confirmed in-game (/mcgd recipeprice,
-- Sun-Blessed Blacksmith's Hammer, 2026-10-12): preview key
-- "238018|q5|stats:ITEM_MOD_MODIFIED_CRAFTING_STAT_1" vs real ones like
-- "238018|q5|stats:ITEM_MOD_MULTICRAFT_SHORT". A stat list made only of
-- these placeholders counts as "no stats picked". Theoretical: _2 etc. on
-- items with two choosable stats.
local PLACEHOLDER_STAT_PREFIX = "ITEM_MOD_MODIFIED_CRAFTING_STAT_"

-- Returns the key with its stats removed when it has no real stats
-- (none, or placeholders only); nil when it has real stats of its own.
local function BaseKeyWithoutChosenStats(marketKey)
    local statsAt = marketKey:find("|stats:", 1, true)
    if not statsAt then
        return marketKey
    end
    local fingerprint = marketKey:sub(statsAt + #"|stats:")
    for stat in string.gmatch(fingerprint, "[^|]+") do
        if stat:sub(1, #PLACEHOLDER_STAT_PREFIX) ~= PLACEHOLDER_STAT_PREFIX then
            return nil
        end
    end
    return marketKey:sub(1, statsAt - 1)
end

-- Interchangeable versions (Brian, 2026-10-23): Darkmoon Decks are trinkets
-- that come in several item levels and stats - "245846|ilvl90",
-- "245846|ilvl220|stats:ITEM_MOD_INTELLECT_SHORT" - but every version makes
-- the same Sigil (confirmed in-game: Darkmoon Sigil: Void crafted from a 90
-- deck and a 220 deck stack together). So every version is worth the
-- cheapest version.
-- Explicit item ID list. Matching a category instead would catch normal
-- trinkets/gear (and profession tools), where different item levels and
-- stats really are different values. Add an ID here only when another item
-- is confirmed to behave the same way. IDs from the saved price cache
-- (2026-10-23); works on every client language.
-- Used in two places so they can't drift apart:
--   ResolveAHValue - an item-ID-only lookup prices the cheapest version
--     instead of the base-item-level key (which is not a real item).
--   "interchangeable-version-cap" rule (ValuationRuleSet.lua) - a linked
--     version is capped at the cheapest version.
-- Cheapest fresh price first; cheapest of any age only when nothing is
-- fresh. Computed on lookup, never stored.
local INTERCHANGEABLE_ITEM_IDS = {
    [245855] = true, -- Darkmoon Deck: Blood
    [245829] = true, -- Darkmoon Deck: Hunt
    [245846] = true, -- Darkmoon Deck: Rot
    [245750] = true, -- Darkmoon Deck: Void
}

-- item: a ValuationRules facts view (facts:View()), or any table with itemID.
function ValuationService:IsInterchangeableVersionItem(item)
    local itemID = type(item) == "table" and tonumber(item.itemID) or nil
    return itemID ~= nil and INTERCHANGEABLE_ITEM_IDS[itemID] == true
end

local function IsItemIDOnlyLookup(normalized)
    return normalized.itemLink == nil
        and normalized.itemLevel == nil
        and normalized.statFingerprint == nil
        and normalized.qualityTier == nil
end

local function ResolveCheapestVersion(cacheModule, normalized, resolvedItemID, requestedKey)
    if type(cacheModule.GetCandidatesForItemID) ~= "function" then
        return nil
    end
    local itemID = normalized.itemID or resolvedItemID
    local cheapestFresh, cheapestAny
    local versionCount = 0
    for _, candidate in ipairs(cacheModule:GetCandidatesForItemID(itemID) or {}) do
        local candidateKey = type(candidate) == "table" and tostring(candidate.marketKey or "") or ""
        if candidateKey ~= "" then
            local value, freshness, row = cacheModule:GetValueByMarketKey(candidateKey)
            value = tonumber(value)
            if value then
                versionCount = versionCount + 1
                local entry = { key = candidateKey, value = value, freshness = freshness, row = row }
                if freshness == "fresh" and (not cheapestFresh or value < cheapestFresh.value) then
                    cheapestFresh = entry
                end
                if not cheapestAny or value < cheapestAny.value then
                    cheapestAny = entry
                end
            end
        end
    end
    local chosen = cheapestFresh or cheapestAny
    if not chosen then
        return nil
    end
    local row = chosen.row
    return {
        resolved = true,
        value = chosen.value,
        valuePerUnit = chosen.value,
        currency = CURRENCY_COPPER,
        basis = "cheapestVersion:" .. tostring(versionCount),
        source = SOURCE_AH,
        strategyKey = SOURCE_AH,
        valuationBasis = BASIS_MARKET_OBSERVED,
        itemID = itemID,
        configKey = normalized.configKey,
        isFresh = chosen.freshness == "fresh",
        lastUpdated = row and row.timestamp,
        unresolved = nil,
        unresolvedReason = nil,
        provenance = {
            marketKey = chosen.key,
            requestedMarketKey = requestedKey,
            cheapestVersion = true,
            versionCount = versionCount,
            depthUsed = row and row.depthUsed,
            cacheSource = row and row.source,
            timestamp = row and row.timestamp,
            isFresh = chosen.freshness == "fresh",
        },
    }
end

local function ResolveStatVariantAverage(cacheModule, marketKey, normalized, resolvedItemID)
    marketKey = tostring(marketKey or "")
    if marketKey == "" then
        return nil
    end
    local baseKey = BaseKeyWithoutChosenStats(marketKey)
    if not baseKey then
        return nil
    end
    if type(cacheModule.GetCandidatesForItemID) ~= "function" then
        return nil
    end
    local itemID = normalized.itemID or resolvedItemID
    local prefix = baseKey .. "|stats:"
    local total, count, keys = 0, 0, {}
    local anyFresh, newest = false, nil
    for _, candidate in ipairs(cacheModule:GetCandidatesForItemID(itemID) or {}) do
        local candidateKey = type(candidate) == "table" and tostring(candidate.marketKey or "") or ""
        if candidateKey:sub(1, #prefix) == prefix and BaseKeyWithoutChosenStats(candidateKey) == nil then
            local value, freshness, row = cacheModule:GetValueByMarketKey(candidateKey)
            value = tonumber(value)
            if value then
                total = total + value
                count = count + 1
                keys[#keys + 1] = candidateKey
                anyFresh = anyFresh or freshness == "fresh"
                local timestamp = row and tonumber(row.timestamp)
                if timestamp and (not newest or timestamp > newest) then
                    newest = timestamp
                end
            end
        end
    end
    if count == 0 then
        return nil
    end
    local average = math.floor(total / count + 0.5)
    return {
        resolved = true,
        value = average,
        valuePerUnit = average,
        currency = CURRENCY_COPPER,
        basis = "statVariantAverage:" .. tostring(count),
        source = SOURCE_AH,
        strategyKey = SOURCE_AH,
        valuationBasis = BASIS_MODELED,
        itemID = itemID,
        configKey = normalized.configKey,
        isFresh = anyFresh,
        lastUpdated = newest,
        unresolved = nil,
        unresolvedReason = nil,
        statVariantCount = count,
        provenance = {
            marketKey = marketKey,
            statVariantAverage = true,
            statVariantKeys = keys,
            isFresh = anyFresh,
            timestamp = newest,
        },
    }
end

--- Cheapest priced version of an item ID (see IsInterchangeableVersionItem),
-- in GetItemValue's result shape, or nil when no version has a price. Reads
-- the cache only, so a rule can call it without recursing into valuation.
function ValuationService:GetCheapestVersionValue(itemID)
    itemID = tonumber(itemID)
    local cacheModule = GetPricingCache()
    if not itemID or not cacheModule then
        return nil
    end
    return ResolveCheapestVersion(cacheModule, { itemID = itemID }, itemID, nil)
end

-- Resolves an AH-derived value for a normalized itemRef using only existing
-- PricingIdentity/PricingCache lookups - no new pricing math, all existing
-- protections (bait/clown-auction depth-averaging lives upstream in
-- PricingValuation.CalculateStackableValue) untouched. Returns nil, reason
-- when no AH value is available so the caller can fall through to a
-- registered custom strategy before giving up.
local function ResolveAHValue(normalized, facts)
    local identityModule = GetPricingIdentity()
    local cacheModule = GetPricingCache()
    if not identityModule or not cacheModule then
        return nil, "valuationModulesUnavailable"
    end

    local marketKey, resolvedItemID = ResolveMarketKey(identityModule, normalized)
    if not marketKey then
        return nil, "marketKeyUnresolved"
    end

    -- Base-item-level key from an item ID alone on an interchangeable
    -- reagent: price the cheapest version instead (see
    -- IsInterchangeableVersionItem).
    if IsItemIDOnlyLookup(normalized) and tostring(marketKey):match("^%d+|ilvl%d+$")
        and facts and ValuationService:IsInterchangeableVersionItem(facts:View()) then
        local cheapest = ResolveCheapestVersion(cacheModule, normalized, resolvedItemID, marketKey)
        if cheapest then
            return cheapest
        end
    end

    local value, freshness, row = cacheModule:GetValueByMarketKey(marketKey)
    if value == nil then
        local average = ResolveStatVariantAverage(cacheModule, marketKey, normalized, resolvedItemID)
        if average then
            return average
        end
        return nil, "noPriceData"
    end

    return {
        resolved = true,
        value = value,
        valuePerUnit = value,
        currency = CURRENCY_COPPER,
        basis = (row and row.depthUsed) and ("marketDepth:" .. tostring(row.depthUsed)) or "cached",
        source = SOURCE_AH,
        strategyKey = SOURCE_AH,
        valuationBasis = BASIS_MARKET_OBSERVED,
        itemID = normalized.itemID or resolvedItemID,
        configKey = normalized.configKey,
        isFresh = freshness == "fresh",
        lastUpdated = row and row.timestamp,
        unresolved = nil,
        unresolvedReason = nil,
        provenance = {
            marketKey = marketKey,
            depthUsed = row and row.depthUsed,
            cacheSource = row and row.source,
            timestamp = row and row.timestamp,
            isFresh = freshness == "fresh",
        },
    }
end

-- Queries VendorPriceService for a canonical vendor-purchase value (player
-- observation or bundled default - both equally canonical, see
-- VendorPriceService:GetPrice). pcall-guarded the same way ResolveAHValue's
-- module lookups are, so an unavailable or errored VendorPriceService
-- degrades to "no vendor price" rather than throwing. Returns nil, reason
-- when unresolved so the caller can fall through to Auction House pricing.
local function ResolveVendorValue(normalized)
    if not normalized.itemID then
        return nil, "vendorPriceRequiresItemID"
    end

    local vendorService = GetVendorPriceService()
    if not vendorService or type(vendorService.GetPrice) ~= "function" then
        return nil, "vendorPriceServiceUnavailable"
    end

    local ok, vendorResult = pcall(function()
        return vendorService:GetPrice(normalized.itemID)
    end)
    if not ok or type(vendorResult) ~= "table" or vendorResult.resolved ~= true then
        return nil, (ok and type(vendorResult) == "table" and vendorResult.reason) or "vendorPriceUnavailable"
    end

    return {
        resolved = true,
        value = vendorResult.value,
        valuePerUnit = vendorResult.value,
        currency = vendorResult.currency or CURRENCY_COPPER,
        basis = vendorResult.valuationBasis or BASIS_FIXED,
        source = SOURCE_VENDOR,
        strategyKey = vendorResult.strategyKey or SOURCE_VENDOR,
        valuationBasis = vendorResult.valuationBasis or BASIS_FIXED,
        itemID = normalized.itemID,
        configKey = normalized.configKey,
        isFresh = true,
        lastUpdated = vendorResult.provenance and vendorResult.provenance.observedAt or nil,
        unresolved = nil,
        unresolvedReason = nil,
        provenance = vendorResult.provenance,
    }
end

-- Looks up the most specific matching "value" rule for this item (a
-- configKey rule beats an itemID rule, which beats a category rule - see
-- ValuationRules.lua). Returns it in the strategy shape the code below
-- expects, or nil.
local function FindCustomItemStrategy(normalized, facts)
    local rules = GetValuationRules()
    if not rules or not facts then
        return nil
    end
    local rule = rules:FindValueRule(facts)
    if not rule then
        return nil
    end
    return {
        evaluate = rule.value,
        strategyKey = rule.strategyKey or rule.id,
        ruleID = rule.id,
    }
end

-- Executes a registered custom strategy under the shared recursion guard and
-- a pcall, so a strategy error or a valuation cycle (a container strategy
-- that ends up pricing itself again) never throws and never infinite-loops.
-- Returns nil when no strategy is registered (caller returns the plain
-- unresolved shape) or the strategy's result (already normalized to the
-- standard usable value shape) otherwise.
local function ResolveCustomItemValuation(normalized, options, facts)
    local strategy = FindCustomItemStrategy(normalized, facts)
    if not strategy then
        return nil
    end

    local visitKey = normalized.configKey or ("itemID:" .. tostring(normalized.itemID))
    local stack = ValuationService._customValuationStack
    if stack[visitKey] then
        return NewUnresolved(normalized.itemID, normalized.configKey, "valuationCycle")
    end

    stack[visitKey] = true
    local ok, result = pcall(strategy.evaluate, {
        itemID = normalized.itemID or (facts and facts:Get("itemID")),
        configKey = normalized.configKey,
        itemLink = normalized.itemLink,
        item = facts and facts:View(),
        valuationService = ValuationService,
        options = options,
    })
    stack[visitKey] = nil

    if not ok or type(result) ~= "table" then
        return NewUnresolved(normalized.itemID, normalized.configKey, "customStrategyError")
    end

    result.itemID = result.itemID or normalized.itemID
    result.configKey = result.configKey or normalized.configKey
    result.currency = result.currency or CURRENCY_COPPER
    result.strategyKey = result.strategyKey or strategy.strategyKey
    result.ruleID = strategy.ruleID
    if result.unresolved == nil then
        result.unresolved = result.valuePerUnit == nil or nil
        result.unresolvedReason = result.unresolvedReason or (result.valuePerUnit == nil and "customStrategyUnresolved" or nil)
    end

    if result.unresolved == true then
        result.resolved = false
        result.reason = result.reason or result.unresolvedReason
        result.valuationBasis = BASIS_UNRESOLVED
    else
        result.resolved = true
        result.value = result.value ~= nil and result.value or result.valuePerUnit
        result.valuePerUnit = result.valuePerUnit ~= nil and result.valuePerUnit or result.value
        result.source = SOURCE_CUSTOM
        -- A custom strategy that doesn't declare its own valuationBasis is
        -- treated as modeled/computed, not as a literal fixed input - see
        -- CustomValuationRegistrations.lua, where container-outcome and
        -- Moxie-bag-ratio strategies both explicitly set "modeled".
        result.valuationBasis = result.valuationBasis or BASIS_MODELED
        result.basis = result.basis or result.valuationBasis
        result.provenance = result.provenance or { strategyKey = result.strategyKey }
    end
    return result
end

--- Registers a custom valuation strategy for one item. A registered
-- strategy is always consulted first and wins whenever it resolves - see
-- ResolveItemValueTrace's canonical precedence (custom -> vendor -> AH ->
-- unresolved). Prefer configKey when the identity is known/stable; itemID
-- registration is supported for items (like these seeded containers) whose
-- identity is already fully described by itemID alone.
-- @param definition table {
--     itemID = number|nil,
--     configKey = string|nil,
--     strategyKey = string,
--     evaluate = function(context) -> result table (same usable shape
--         GetItemValue returns: value/valuePerUnit/unresolved/... plus
--         optional diagnostics-only unvaluedDependencies),
-- }
-- Stored as a ValuationRules "value" rule (id "custom:configKey:..." or
-- "custom:itemID:..."); re-registering the same item replaces it, as before.
function ValuationService:RegisterCustomItemValuation(definition)
    if type(definition) ~= "table" or type(definition.evaluate) ~= "function" then
        return false, "invalidDefinition"
    end
    local rules = GetValuationRules()
    if not rules then
        return false, "valuationRulesUnavailable"
    end
    if definition.configKey then
        return rules:Add({
            id = "custom:configKey:" .. tostring(definition.configKey),
            note = definition.strategyKey,
            match = { configKey = definition.configKey },
            value = definition.evaluate,
            strategyKey = definition.strategyKey,
        })
    end
    if definition.itemID then
        return rules:Add({
            id = "custom:itemID:" .. tostring(definition.itemID),
            note = definition.strategyKey,
            match = { itemID = tonumber(definition.itemID) },
            value = definition.evaluate,
            strategyKey = definition.strategyKey,
        })
    end
    return false, "missingIdentity"
end

-- Builds the item facts the rules engine matches against (lazy - costs
-- nothing unless a category rule needs them).
local function NewFacts(normalized)
    local rules = GetValuationRules()
    if not rules then
        return nil
    end
    return rules:NewFacts({
        itemID = normalized.itemID,
        itemLink = normalized.itemLink,
        configKey = normalized.configKey,
        qualityTier = normalized.qualityTier,
        itemLevel = normalized.itemLevel,
        statFingerprint = normalized.statFingerprint,
    })
end

-- Runs every matching "adjust" rule on the selected result.
local function ApplyRuleAdjustments(selected, facts)
    local rules = GetValuationRules()
    if not rules or not facts then
        return selected, {}
    end
    return rules:ApplyAdjustments(selected, facts, ValuationService)
end

-- The single canonical precedence implementation. Every public entry point
-- (GetItemValue, ExplainValue, and by extension GetValues) routes through
-- this so no consumer or diagnostic can end up seeing a different source
-- order - see PocketCFO_Valuation CLAUDE.md "Canonical valuation
-- precedence": custom rule -> vendor purchase price -> Auction House price
-- -> unresolved. Attempts all three sources (custom always; vendor/AH are
-- cheap read-only lookups) so ExplainValue can show every attempted source
-- even when a higher-priority one already won.
local function ResolveItemValueTrace(normalized, options)
    local facts = NewFacts(normalized)
    local customResult = ResolveCustomItemValuation(normalized, options, facts)
    local customAttempted = FindCustomItemStrategy(normalized, facts) ~= nil

    local vendorResult, vendorUnresolvedReason = ResolveVendorValue(normalized)
    local ahResult, ahUnresolvedReason = ResolveAHValue(normalized, facts)

    local selected
    if customResult and customResult.resolved == true then
        selected = customResult
    elseif vendorResult then
        selected = vendorResult
    elseif ahResult then
        selected = ahResult
    else
        -- AH reason before vendor reason (2026-10-16): almost no traded item
        -- has a vendor price, so "vendorPriceUnavailable" is the normal case
        -- and says nothing useful. The AH reason (marketKeyUnresolved /
        -- noPriceData) is the real "needs price" signal - reporting the vendor
        -- reason first made Processing Analysis classify unpriced gems/ore as
        -- "No Data" and skip its reload-when-item-data-arrives retry.
        local reason = (customResult and customResult.reason)
            or ahUnresolvedReason
            or vendorUnresolvedReason
            or "valueUnresolved"
        selected = NewUnresolved(normalized.itemID, normalized.configKey, reason)
    end

    local unadjustedSource = selected.source
    local adjustments
    selected, adjustments = ApplyRuleAdjustments(selected, facts)

    return {
        selected = selected,
        facts = facts,
        unadjustedSource = unadjustedSource,
        adjustments = adjustments,
        custom = customResult,
        customAttempted = customAttempted,
        vendor = vendorResult,
        vendorUnresolvedReason = vendorUnresolvedReason,
        ah = ahResult,
        ahUnresolvedReason = ahUnresolvedReason,
    }
end

--- Returns "what is this item worth right now?" for one itemRef.
-- Never returns zero for a missing price - returns unresolved instead.
-- Canonical resolution order: registered custom rule -> vendor purchase
-- price -> Auction House market price -> unresolved. See
-- ResolveItemValueTrace, the single shared precedence implementation this
-- and ExplainValue both call.
-- @param itemRef number itemID | string itemLink | string configKey |
--        table { itemID, configKey, itemLink, qualityTier, itemLevel, statFingerprint }
-- @param options table|nil reserved for future use; no options affect
--        behavior yet (no historical/trend lookups exist).
function ValuationService:GetItemValue(itemRef, options)
    local normalized, normalizeReason = NormalizeItemRef(itemRef)
    if normalizeReason then
        return NewUnresolved(normalized.itemID, normalized.configKey, normalizeReason)
    end

    return ResolveItemValueTrace(normalized, options).selected
end

-- Smallest canonical currency identity helper - the one place a currency
-- configKey string is assembled. Mirrors ItemIdentityService's item configKey
-- shape/versioning convention without depending on it (currencies are not
-- items - no matching path/ilvl/stat concerns apply).
local function BuildCurrencyConfigKey(currencyID)
    return "pcfo|currency|v1|id:" .. tostring(currencyID)
end

local function NewUnresolvedCurrency(currencyID, reason)
    reason = reason or "valueUnresolved"
    return {
        value = nil,
        valuePerUnit = nil,
        currency = CURRENCY_COPPER,
        basis = nil,
        source = nil,
        strategyKey = nil,
        currencyID = currencyID,
        configKey = currencyID and BuildCurrencyConfigKey(currencyID) or nil,
        isFresh = nil,
        lastUpdated = nil,
        unresolved = true,
        unresolvedReason = reason,
        resolved = false,
        reason = reason,
        valuationBasis = BASIS_UNRESOLVED,
        provenance = nil,
    }
end

--- Registers a custom valuation strategy for one currency. There is no
-- AH-first path for currencies (they can't be listed/bought on the AH) -
-- resolution is registered-strategy-only, otherwise unresolved.
-- @param definition table {
--     currencyID = number,
--     strategyKey = string,
--     evaluate = function(context) -> result table (same usable shape as
--         GetCurrencyValue: value/valuePerUnit/unresolved/...),
-- }
function ValuationService:RegisterCustomCurrencyValuation(definition)
    if type(definition) ~= "table" or type(definition.evaluate) ~= "function" or not definition.currencyID then
        return false, "invalidDefinition"
    end
    self.customCurrencyStrategies[tonumber(definition.currencyID)] = definition
    return true
end

--- Returns "what is this currency worth right now?" Registered-strategy-only
-- (no AH path exists for currencies). Never returns zero for a missing
-- value - returns unresolved instead. Same recursion-guard/pcall protections
-- as ResolveCustomItemValuation.
-- @param currencyRef number currencyID | table { currencyID }
-- @param options table|nil reserved for future use.
function ValuationService:GetCurrencyValue(currencyRef, options)
    local currencyID = tonumber(type(currencyRef) == "table" and currencyRef.currencyID or currencyRef)
    if not currencyID then
        return NewUnresolvedCurrency(nil, "invalidCurrencyID")
    end

    local strategy = self.customCurrencyStrategies[currencyID]
    if not strategy then
        return NewUnresolvedCurrency(currencyID, "noCurrencyValuation")
    end

    local visitKey = "currency:" .. tostring(currencyID)
    local stack = self._customValuationStack
    if stack[visitKey] then
        return NewUnresolvedCurrency(currencyID, "valuationCycle")
    end

    stack[visitKey] = true
    local ok, result = pcall(strategy.evaluate, {
        currencyID = currencyID,
        valuationService = self,
        options = options,
    })
    stack[visitKey] = nil

    if not ok or type(result) ~= "table" then
        return NewUnresolvedCurrency(currencyID, "customStrategyError")
    end

    result.currencyID = result.currencyID or currencyID
    result.configKey = result.configKey or BuildCurrencyConfigKey(currencyID)
    result.currency = result.currency or CURRENCY_COPPER
    result.strategyKey = result.strategyKey or strategy.strategyKey
    if result.unresolved == nil then
        result.unresolved = result.valuePerUnit == nil or nil
        result.unresolvedReason = result.unresolvedReason or (result.valuePerUnit == nil and "customStrategyUnresolved" or nil)
    end

    if result.unresolved == true then
        result.resolved = false
        result.reason = result.reason or result.unresolvedReason
        result.valuationBasis = BASIS_UNRESOLVED
    else
        result.resolved = true
        result.value = result.value ~= nil and result.value or result.valuePerUnit
        result.valuePerUnit = result.valuePerUnit ~= nil and result.valuePerUnit or result.value
        result.source = SOURCE_CUSTOM
        result.valuationBasis = result.valuationBasis or BASIS_MODELED
        result.basis = result.basis or result.valuationBasis
        result.provenance = result.provenance or { strategyKey = result.strategyKey }
    end
    return result
end

--- Batch form of GetItemValue. Returns one result per itemRef, in order.
-- Useful for OperationEconomicsService pricing several inputs/outputs at
-- once without N separate calls each re-deriving the same modules.
function ValuationService:GetValues(itemRefs, options)
    local results = {}
    if type(itemRefs) ~= "table" then
        return results
    end
    for i, itemRef in ipairs(itemRefs) do
        results[i] = self:GetItemValue(itemRef, options)
    end
    return results
end

--- Returns GetItemValue's result (via the same ResolveItemValueTrace
-- precedence every other entry point uses - see that function's header)
-- plus an explanation showing every source that was attempted (custom,
-- vendor, Auction House) and which one was selected, so source precedence
-- is visible without requiring the caller to re-derive it or inspect
-- strategy-name strings. Adds no new valuation logic - only surfaces
-- metadata the shared trace and PricingCache/PricingIdentity already track.
function ValuationService:ExplainValue(itemRef, options)
    local normalized, normalizeReason = NormalizeItemRef(itemRef)
    if normalizeReason then
        local result = NewUnresolved(normalized.itemID, normalized.configKey, normalizeReason)
        result.explanation = { reason = normalizeReason }
        return result
    end

    local trace = ResolveItemValueTrace(normalized, options)
    local result = trace.selected

    local identityModule = GetPricingIdentity()
    local cacheModule = GetPricingCache()
    local marketKey = identityModule and (ResolveMarketKey(identityModule, normalized))
    -- Show the key that was actually priced when the cheapest version won.
    local ahProvenance = trace.ah and trace.ah.provenance
    if ahProvenance and ahProvenance.cheapestVersion and ahProvenance.marketKey then
        marketKey = ahProvenance.marketKey
    end
    local cacheRow = (marketKey and cacheModule) and cacheModule:GetEntry(marketKey) or nil
    local candidates = (result.itemID and cacheModule and cacheModule.GetCandidatesForItemID)
        and cacheModule:GetCandidatesForItemID(result.itemID) or {}

    result.explanation = {
        -- Legacy top-level fields, kept for existing explanation-data
        -- consumers (see PocketCFO_Valuation CLAUDE.md compatibility note).
        marketKey = marketKey,
        cacheRow = cacheRow,
        candidates = candidates,

        custom = {
            attempted = trace.customAttempted,
            resolved = trace.custom ~= nil and trace.custom.resolved == true,
            value = trace.custom and trace.custom.value,
            strategyKey = trace.custom and trace.custom.strategyKey,
            valuationBasis = trace.custom and trace.custom.valuationBasis,
            unresolvedReason = (trace.custom and trace.custom.resolved ~= true) and trace.custom.reason or nil,
        },
        vendor = {
            resolved = trace.vendor ~= nil,
            value = trace.vendor and trace.vendor.value,
            sourceType = trace.vendor and trace.vendor.provenance and trace.vendor.provenance.sourceType,
            merchant = trace.vendor and trace.vendor.provenance and trace.vendor.provenance.merchantName,
            observedAt = trace.vendor and trace.vendor.provenance and trace.vendor.provenance.observedAt,
            unresolvedReason = (not trace.vendor) and trace.vendorUnresolvedReason or nil,
        },
        auctionHouse = {
            available = trace.ah ~= nil,
            value = trace.ah and trace.ah.value,
            marketKey = marketKey,
            cacheRow = cacheRow,
            candidates = candidates,
            -- Phase 2-6 market-representativeness decisions (anchor price,
            -- accepted/rejected bucket+quantity counts, per-rejected-bucket
            -- reason) from PricingValuation.CalculateStackableValue - see
            -- that module's header for the algorithm. nil for non-stackable
            -- items or cache rows priced before this diagnostic existed.
            valuationDiagnostics = cacheRow and cacheRow.valuationDiagnostics,
            unresolvedReason = (not trace.ah) and trace.ahUnresolvedReason or nil,
        },
        selected = {
            source = result.source,
            value = result.value,
            valuationBasis = result.valuationBasis,
        },

        -- Which rules touched this price (ValuationRules.lua). market shows
        -- the settings a scan would use for this item NOW; the cached row's
        -- valuationDiagnostics.marketRuleIDs shows what the last scan used.
        rules = {
            valueRuleID = trace.custom and trace.custom.ruleID or nil,
            sourceBeforeAdjust = trace.unadjustedSource,
            unadjustedValue = result.unadjustedValue,
            adjustments = trace.adjustments or {},
            notes = result.ruleNotes,
            pending = result.rulesPending == true,
            facts = trace.facts and trace.facts:Snapshot() or nil,
        },
    }

    local rules = GetValuationRules()
    if rules and identityModule then
        local identity
        if normalized.itemLink then
            identity = identityModule:BuildFromItemLink(normalized.itemLink)
        elseif result.itemID then
            identity = identityModule:BuildFromItemID(result.itemID)
        end
        local params, ruleIDs, pending = rules:GetMarketParams(identity)
        result.explanation.rules.marketParamsNow = params
        result.explanation.rules.marketRuleIDsNow = ruleIDs
        result.explanation.rules.marketPending = pending == true
    end

    return result
end

function ValuationService:OnEnable()
end

function ValuationService:OnDisable()
end

if PocketCFO_Valuation then
    PocketCFO_Valuation.ValuationService = ValuationService
end
