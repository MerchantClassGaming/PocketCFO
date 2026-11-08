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
--      bundled default, both canonical), unless a confident AH value is
--      lower: the vendor price is a ceiling (2026-11-05)
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

-- Scan history fallback (stage 2 step 3, Brian 2026-11-06). ScanHistory
-- (FullScan + item searches) keeps each market key's recent average over
-- the last ~14 days seen and a lifetime average. Used when:
--   - there's no cached price at all: recent average, else lifetime;
--   - the cached price is stale (older than PricingCache's 3-day fresh
--     window) and history has >= HISTORY_MIN_DAYS days: the recent average
--     (it includes that same observation plus the other days seen, so one
--     odd day doesn't carry the value).
-- Same AH source, so every rule (ladder cap etc.) still applies.
local HISTORY_MIN_DAYS = 2

local function GetScanHistory()
    return PocketCFO_Valuation:GetModule("ScanHistory", true)
end

local function HistoryResult(normalized, resolvedItemID, marketKey, needDays, staleRow)
    local history = GetScanHistory()
    if not history or type(history.Get) ~= "function" or not marketKey then
        return nil
    end
    local ok, rec = pcall(history.Get, history, marketKey)
    if not ok or type(rec) ~= "table" or (tonumber(rec.daysSeen) or 0) < needDays then
        return nil
    end
    local value, which = tonumber(rec.recent), "recent"
    if not value or value <= 0 then
        value, which = tonumber(rec.lifetime), "lifetime"
    end
    if not value or value <= 0 then
        return nil
    end
    value = math.floor(value + 0.5)
    local lastSeen = history.SECONDS_PER_DAY and tonumber(rec.lastDay)
        and tonumber(rec.lastDay) * history.SECONDS_PER_DAY or nil
    return {
        resolved = true,
        value = value,
        valuePerUnit = value,
        currency = CURRENCY_COPPER,
        basis = "scanHistory:" .. which .. ":" .. tostring(rec.daysSeen),
        source = SOURCE_AH,
        strategyKey = SOURCE_AH,
        valuationBasis = BASIS_MODELED,
        itemID = normalized.itemID or resolvedItemID,
        configKey = normalized.configKey,
        isFresh = false,
        lastUpdated = lastSeen,
        unresolved = nil,
        unresolvedReason = nil,
        provenance = {
            marketKey = marketKey,
            scanHistory = which,
            historyDays = tonumber(rec.daysSeen),
            staleCacheValue = staleRow and staleRow.value or nil,
            staleCacheTimestamp = staleRow and staleRow.timestamp or nil,
            timestamp = lastSeen,
            isFresh = false,
        },
    }
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
        -- This exact version's own history first, then the average of the
        -- other stat versions (recipe previews), then nothing.
        local fromHistory = HistoryResult(normalized, resolvedItemID, marketKey, 1, nil)
        if fromHistory then
            return fromHistory
        end
        local average = ResolveStatVariantAverage(cacheModule, marketKey, normalized, resolvedItemID)
        if average then
            return average
        end
        return nil, "noPriceData"
    end
    if freshness == "stale" then
        local fromHistory = HistoryResult(normalized, resolvedItemID, marketKey, HISTORY_MIN_DAYS, row)
        if fromHistory then
            return fromHistory
        end
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
        PocketCFO_Valuation:MarkUnstable()
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

-- Vendor sell floor (Brian, 2026-11-07): the last step of every lookup. A
-- merchant always buys at a fixed price, so an item is never worth less than
-- what a vendor pays for it, whatever the AH or a rule says. Runs after the
-- adjust rules so no cap can push the value back under it. Unpriced items
-- stay unpriced (smart posting treats "no value" as Needs Price). Source and
-- basis are kept (a vendor price is fixed, not an estimate);
-- vendorSellFloor / unflooredValue record what happened.
-- Real state: sellPrice from GetItemInfo (same field as the tooltip's
-- Vendor row); 0 or nil (merchant won't buy) means no floor.
local function ApplyVendorSellFloor(selected, facts)
    if type(selected) ~= "table" or selected.resolved ~= true or not facts then
        return selected
    end
    local value = tonumber(selected.value)
    if not value then
        return selected
    end
    local info = facts:Info()
    local sellPrice = info and tonumber(info.sellPrice) or nil
    if not sellPrice or sellPrice <= 0 or value >= sellPrice then
        return selected
    end
    selected.unflooredValue = value
    selected.vendorSellFloor = true
    selected.value = sellPrice
    selected.valuePerUnit = sellPrice
    return selected
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

    -- Vendor purchase price is a ceiling, not the value (2026-11-05): a vendor
    -- that sells an item for more than the AH clears it is overpriced. When a
    -- confident AH value is below the vendor price, the AH value wins. Thin
    -- AH evidence (GetConfidence "uncertain") keeps the vendor price so one
    -- dump listing can't drag a vendor item down.
    local ahBelowVendor = false
    if vendorResult and ahResult
        and tonumber(ahResult.value) and tonumber(vendorResult.value)
        and tonumber(ahResult.value) < tonumber(vendorResult.value) then
        local ok, level = pcall(ValuationService.GetConfidence, ValuationService, ahResult)
        ahBelowVendor = ok and level == "confident"
    end

    local selected
    if customResult and customResult.resolved == true then
        selected = customResult
    elseif ahBelowVendor then
        selected = ahResult
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
    selected = ApplyVendorSellFloor(selected, facts)

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

-- Same precedence and same answer as ResolveItemValueTrace, but stops at
-- the first source that wins (Brian, 2026-11-07, hover performance). The
-- trace version resolves every source so ExplainValue can show them all;
-- GetItemValue doesn't need that: when a custom rule resolves, the vendor
-- and AH lookups are skipped, and the custom rule is matched once, not twice.
local function ResolveItemValueFast(normalized, options)
    local facts = NewFacts(normalized)
    local customResult = ResolveCustomItemValuation(normalized, options, facts)

    local selected
    if customResult and customResult.resolved == true then
        selected = customResult
    else
        local vendorResult, vendorUnresolvedReason = ResolveVendorValue(normalized)
        local ahResult, ahUnresolvedReason = ResolveAHValue(normalized, facts)
        if vendorResult then
            local ahBelowVendor = false
            if ahResult and tonumber(ahResult.value) and tonumber(vendorResult.value)
                and tonumber(ahResult.value) < tonumber(vendorResult.value) then
                local ok, level = pcall(ValuationService.GetConfidence, ValuationService, ahResult)
                ahBelowVendor = ok and level == "confident"
            end
            selected = ahBelowVendor and ahResult or vendorResult
        elseif ahResult then
            selected = ahResult
        else
            local reason = (customResult and customResult.reason)
                or ahUnresolvedReason
                or vendorUnresolvedReason
                or "valueUnresolved"
            selected = NewUnresolved(normalized.itemID, normalized.configKey, reason)
        end
    end

    selected = ApplyRuleAdjustments(selected, facts)
    selected = ApplyVendorSellFloor(selected, facts)
    return selected, facts
end

-- ---------------------------------------------------------------------------
-- Price sheet (Brian, 2026-11-07, hover performance). An item's value only
-- changes when what it's worked out from changes, so each answer is
-- remembered and reused until then:
--   - PocketCFO_Valuation.valueVersion moves (price cache write, container
--     opened, rule or vendor price change; see Core.lua), or
--   - SHEET_SECONDS pass, for inputs outside this addon that don't bump the
--     version (your own sales for confidence, Cost to Make for the tool
--     ladder) and for the 3-day fresh -> stale switch.
-- Kept in memory only, never saved. Shared by every caller (tooltip,
-- recipe analysis, posting, ledger pricing, the cap rules and disenchant
-- mats), so each item is valued once per change, not once per look.
-- Not remembered: answers worked out while item data was still loading or
-- a recursion guard tripped (PocketCFO_Valuation.unstableCount moved), or
-- with rules still pending; those are tried again next time, as before.
-- Callers get their own copy of the top-level result table, so a caller
-- writing a field on it (SmartPricing sets configKey) never changes the
-- remembered answer.
-- ---------------------------------------------------------------------------

local SHEET_SECONDS = 10 * 60
local SHEET_MAX_ENTRIES = 4000

local sheet, sheetCount, sheetVersion = {}, 0, nil

local function SheetClock()
    return GetTime and GetTime() or 0
end

-- Empties the sheet when the value version has moved.
local function CheckSheetVersion()
    local version = PocketCFO_Valuation.valueVersion or 0
    if sheetVersion ~= version then
        sheet, sheetCount, sheetVersion = {}, 0, version
        ValuationService._confidenceMemo = {}
    end
end

local function SheetKey(normalized)
    return table.concat({
        tostring(normalized.itemID),
        tostring(normalized.itemLink),
        tostring(normalized.configKey),
        tostring(normalized.qualityTier),
        tostring(normalized.itemLevel),
        tostring(normalized.statFingerprint),
    }, "#")
end

local function CopyResult(result)
    local copy = {}
    for key, value in pairs(result) do
        copy[key] = value
    end
    return copy
end

-- Reasons that mean "not known yet", not "no value": never remembered.
local TRANSIENT_REASONS = {
    marketKeyUnresolved = true,
    itemDataPending = true,
    valuationCycle = true,
    customStrategyError = true,
    valuationModulesUnavailable = true,
    valuationRulesUnavailable = true,
    vendorPriceServiceUnavailable = true,
}

local function IsRememberable(result, facts)
    if type(result) ~= "table" or result.rulesPending then
        return false
    end
    if result.unresolved and TRANSIENT_REASONS[tostring(result.unresolvedReason or result.reason)] then
        return false
    end
    -- Item data asked for during the lookup but not loaded yet.
    if facts and facts.infoDone and facts.info == nil then
        return false
    end
    return true
end

--- Returns "what is this item worth right now?" for one itemRef.
-- Never returns zero for a missing price - returns unresolved instead.
-- Canonical resolution order: registered custom rule -> vendor purchase
-- price -> Auction House market price -> unresolved. See
-- ResolveItemValueTrace (the full trace ExplainValue uses) and
-- ResolveItemValueFast (same answer, used here). Answers come from the
-- price sheet above when nothing has changed since the last lookup.
-- @param itemRef number itemID | string itemLink | string configKey |
--        table { itemID, configKey, itemLink, qualityTier, itemLevel, statFingerprint }
-- @param options table|nil reserved for future use; no options affect
--        behavior yet (no historical/trend lookups exist). A lookup with
--        options is never taken from or saved to the sheet.
function ValuationService:GetItemValue(itemRef, options)
    local normalized, normalizeReason = NormalizeItemRef(itemRef)
    if normalizeReason then
        return NewUnresolved(normalized.itemID, normalized.configKey, normalizeReason)
    end

    if options ~= nil then
        return (ResolveItemValueFast(normalized, options))
    end

    CheckSheetVersion()
    local key = SheetKey(normalized)
    local now = SheetClock()
    local entry = sheet[key]
    if entry and now - entry.at < SHEET_SECONDS then
        return CopyResult(entry.result)
    end

    local unstableBefore = PocketCFO_Valuation.unstableCount or 0
    local result, facts = ResolveItemValueFast(normalized, nil)
    if (PocketCFO_Valuation.unstableCount or 0) == unstableBefore and IsRememberable(result, facts) then
        -- A nested lookup during this one may have moved the version (it
        -- can't today, but a stale entry must never be stored as current).
        CheckSheetVersion()
        if sheetCount >= SHEET_MAX_ENTRIES then
            sheet, sheetCount = {}, 0
        end
        if not sheet[key] then
            sheetCount = sheetCount + 1
        end
        sheet[key] = { result = result, at = now }
    elseif not IsRememberable(result, facts) then
        -- Lookups wrapping this one must not remember an answer built on it.
        PocketCFO_Valuation:MarkUnstable()
    end
    return CopyResult(result)
end

--- True when a custom value rule (containers, Moxie bags, gray items...)
-- covers this item. Lets the tooltip value a bound item that has one and
-- skip bound items that don't. ref: itemID and/or itemLink.
function ValuationService:HasValueRule(itemID, itemLink)
    local facts = NewFacts({ itemID = tonumber(itemID), itemLink = itemLink })
    return FindCustomItemStrategy({ itemID = tonumber(itemID), itemLink = itemLink }, facts) ~= nil
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
        PocketCFO_Valuation:MarkUnstable()
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
            -- items. Since 2026-11-07 not saved on cache rows: only kept for
            -- markets priced by an item search this session.
            valuationDiagnostics = (cacheRow and cacheRow.valuationDiagnostics)
                or (cacheModule and cacheModule.GetSessionDiagnostics and cacheModule:GetSessionDiagnostics(marketKey))
                or nil,
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

-- ---------------------------------------------------------------------------
-- Value confidence (Brian, 2026-11-04). GetItemValue is unchanged; this is a
-- separate question asked only by callers that care: is there enough
-- evidence behind this value to trust it? A thin market (one listing, seen
-- once) can't tell a dump or a clown from a real price, so the honest answer
-- there is "not sure", not a confident wrong number.
--
-- result: a GetItemValue result. Returns "confident" | "uncertain", reason.
-- Confident:
--   - not an AH price (custom rule, vendor purchase price)
--   - our own sale of it in the last SALE_DAYS days (SaleIndex), only when
--     the value is within 50%-2x of that sale price (2026-11-06)
--   - stackable priced from >= MIN_UNITS units across >= 2 listings
--   - anything else with >= MIN_LISTINGS listings of that exact version
--   - seen on >= MIN_DAYS days (ScanHistory)
-- Uncertain, whatever the above: today's price under 50% or over 2x the
-- item's recent history (MIN_DAYS+ days) - a dump or a clown.
-- ---------------------------------------------------------------------------

local CONFIDENCE_MIN_UNITS = 10
local CONFIDENCE_MIN_LISTINGS = 3
local CONFIDENCE_MIN_DAYS = 3
local CONFIDENCE_SALE_DAYS = 30
local CONFIDENCE_LOW_PCT = 0.5
local CONFIDENCE_HIGH_X = 2

-- Answers are remembered with the price sheet (same version and time
-- limit; Brian, 2026-11-07): the tooltip, the vendor-ceiling check and smart
-- posting ask about the same result several times.
ValuationService._confidenceMemo = ValuationService._confidenceMemo or {}

local ComputeConfidence

function ValuationService:GetConfidence(result)
    if type(result) ~= "table" or result.unresolved or not tonumber(result.value) then
        return "uncertain", "noValue"
    end
    if result.source ~= "auctionHouse" then
        return "confident", "notAuctionHouse"
    end
    CheckSheetVersion()
    local key = table.concat({
        tostring(result.provenance and result.provenance.marketKey),
        tostring(result.value),
        tostring(result.provenance and result.provenance.scanHistory),
        tostring(result.configKey),
        tostring(result.itemID),
    }, "#")
    local now = SheetClock()
    local memo = self._confidenceMemo[key]
    if memo and now - memo.at < SHEET_SECONDS then
        return memo.level, memo.reason
    end
    local level, reason = ComputeConfidence(result)
    self._confidenceMemo[key] = { level = level, reason = reason, at = now }
    return level, reason
end

ComputeConfidence = function(result)
    local value = tonumber(result.value)
    local marketKey = result.provenance and result.provenance.marketKey
    local cache = PocketCFO_Valuation:GetModule("PricingCache", true)
    local history = PocketCFO_Valuation:GetModule("ScanHistory", true)
    local sales = PocketCFO_Valuation:GetModule("SaleIndex", true)

    local row = cache and marketKey and cache:GetEntry(marketKey) or nil
    local rec = history and marketKey and history:Get(marketKey) or nil
    local daysSeen = rec and tonumber(rec.daysSeen) or 0
    local recent = rec and tonumber(rec.recent)

    if daysSeen >= CONFIDENCE_MIN_DAYS and recent and recent > 0 then
        -- A value from scan history is history: compare it, not the stale
        -- cached row it replaced (2026-11-06).
        local fromHistory = result.provenance and result.provenance.scanHistory
        local before = (not fromHistory and tonumber(row and row.value)) or value
        -- Which side matters to smart posting (Brian, 2026-11-06): a value
        -- thrown out for being far BELOW usual is still a lower bound on the
        -- max; one far ABOVE usual may be a clown and never is.
        if before < recent * CONFIDENCE_LOW_PCT then
            return "uncertain", "farBelowUsual"
        end
        if before > recent * CONFIDENCE_HIGH_X then
            return "uncertain", "farAboveUsual"
        end
    end

    if sales then
        local ok, price, at = pcall(sales.GetLastSale, sales, result.configKey, result.itemID)
        local now = GetServerTime and GetServerTime() or time()
        -- A recent sale only backs the value up when it's close to it (same
        -- 50%-2x band as the history check; Brian 2026-11-06: a 400g sale
        -- made a 1,285g value "confident"). Far off, it says nothing either
        -- way and the checks below decide.
        price = tonumber(price)
        if ok and price and price > 0 and at and now - at <= CONFIDENCE_SALE_DAYS * 86400
            and value >= price * CONFIDENCE_LOW_PCT and value <= price * CONFIDENCE_HIGH_X then
            return "confident", "soldRecently"
        end
    end

    local listings = row and tonumber(row.listingCount)
    local units = row and tonumber(row.unitCount)
    if listings and units and units > listings then
        -- Stackable: units across listings.
        if units >= CONFIDENCE_MIN_UNITS and listings >= 2 then
            return "confident", "manyUnits"
        end
    elseif listings and listings >= CONFIDENCE_MIN_LISTINGS then
        return "confident", "manyListings"
    end
    if daysSeen >= CONFIDENCE_MIN_DAYS then
        return "confident", "seenManyDays"
    end
    return "uncertain", "fewListings"
end

function ValuationService:OnEnable()
end

function ValuationService:OnDisable()
end

if PocketCFO_Valuation then
    PocketCFO_Valuation.ValuationService = ValuationService
end
