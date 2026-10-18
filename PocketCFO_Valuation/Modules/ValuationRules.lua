-- PocketCFO_Valuation/Modules/ValuationRules.lua
-- The valuation rules engine. Rules themselves live in ValuationRuleSet.lua
-- (and CustomValuationRegistrations.lua for containers/Moxie); this file
-- only knows how to store them, decide which ones match an item, and apply
-- them. Adding a rule never requires editing this file.
--
-- A rule is a table:
--   {
--     id     = "unique-id",                -- re-adding the same id replaces it
--     note   = "short human description",  -- shown in diagnostics
--     match  = { ...fields... },           -- which items (see MATCH FIELDS)
--     market = { depth = N, ... },         -- how the AH price is worked out (scan time)
--     value  = function(context) ... end,  -- replace the price entirely (lookup time)
--     adjust = function(ctx) ... end,      -- cap/floor/flag/reject a price (lookup time)
--     strategyKey = "...",                 -- optional, value rules only
--   }
-- A rule may carry any combination of market/value/adjust.
--
-- MATCH FIELDS (every field listed must match; a list means "any of"):
--   configKey, itemID, craftingQuality, rarity, itemLevel, classID,
--   subClassID, equipLoc, classification, isStackable, test = function(item)
--   An empty or missing match matches every item.
--
-- WHICH RULE WINS (specificity, most specific first):
--   configKey > itemID > subClassID > equipLoc > classID > classification
--   > isStackable > (no match fields). Each craftingQuality / rarity /
--   itemLevel / test filter adds one point on top, so "item + tier 4" beats
--   "item". Equal scores: the rule added later wins.
--   market: every matching rule applies, general first, so a specific rule
--           only overrides the settings it names.
--   value:  only the most specific matching rule runs.
--   adjust: every matching rule runs, general first, specific last.
--
-- ITEM FACTS: classID/subClassID/equipLoc/rarity/maxStack come from
-- GetItemInfo (memory api-findings: GetItemInfoInstant classID is
-- unreliable on a cold cache). classification comes from core's
-- ItemClassifier. craftingQuality comes from PricingIdentity (the same
-- source the market key uses). Blizzard's quality is not reliable in every
-- case (nil on profession tools); where it isn't, match on itemLevel
-- instead (Brian, 2026-10-12). When item data has not loaded yet
-- (cold cache right after login) a rule that needs it can't be decided: it
-- is skipped and the result is marked rulesPending = true.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local ValuationRules = PocketCFO_Valuation:NewModule("ValuationRules")

-- Named values for rule files. Only values confirmed in-game are listed
-- (/mcgd identity hover, 2026-10-12: Sun-Blessed Sickle classID 19 /
-- subClassID 3 / INVTYPE_PROFESSION_TOOL; Majestic Claw classID 7 /
-- subClassID 6). Add more as they are captured.
ValuationRules.CLASS = {
    Tradeskill = 7,
    Profession = 19,
}

ValuationRules.EQUIP = {
    ProfessionTool = "INVTYPE_PROFESSION_TOOL",
}

ValuationRules.RARITY = {
    Common = 1,
    Uncommon = 2,
    Rare = 3,
    Epic = 4,
}

ValuationRules.rules = ValuationRules.rules or {}
ValuationRules._order = ValuationRules._order or 0
ValuationRules._adjustStack = ValuationRules._adjustStack or {}

-- ─── Specificity ───────────────────────────────────────────────────────────

local SPECIFICITY = {
    { field = "configKey", weight = 100 },
    { field = "itemID", weight = 80 },
    { field = "subClassID", weight = 50 },
    { field = "equipLoc", weight = 45 },
    { field = "classID", weight = 40 },
    { field = "classification", weight = 35 },
    { field = "isStackable", weight = 20 },
}

local FILTER_FIELDS = {
    craftingQuality = true,
    rarity = true,
    itemLevel = true,
    test = true,
}

local KNOWN_FIELDS = {
    configKey = true, itemID = true, subClassID = true, equipLoc = true,
    classID = true, classification = true, isStackable = true,
    craftingQuality = true, rarity = true, itemLevel = true, test = true,
}

local function Score(match)
    if type(match) ~= "table" then
        return 0
    end
    local base = 0
    for _, entry in ipairs(SPECIFICITY) do
        if match[entry.field] ~= nil and entry.weight > base then
            base = entry.weight
        end
    end
    local filters = 0
    for field in pairs(FILTER_FIELDS) do
        if match[field] ~= nil then
            filters = filters + 1
        end
    end
    return base + filters
end

-- ─── Item facts ────────────────────────────────────────────────────────────

local function GetItemIDFromLink(itemLink)
    if not itemLink then
        return nil
    end
    if GetItemInfoFromHyperlink then
        local ok, itemID = pcall(GetItemInfoFromHyperlink, itemLink)
        if ok and itemID then
            return tonumber(itemID)
        end
    end
    return tonumber(tostring(itemLink):match("item:(%d+)"))
end

local function SafeGetItemInfo(itemRef)
    if not itemRef or not GetItemInfo then
        return nil
    end
    local ok, itemName, _, itemRarity, itemLevel, _, _, _, maxStack, equipLoc, _, _, classID, subClassID = pcall(GetItemInfo, itemRef)
    if not ok or not itemName then
        return nil
    end
    return {
        rarity = tonumber(itemRarity),
        itemLevel = tonumber(itemLevel),
        maxStack = tonumber(maxStack),
        equipLoc = equipLoc,
        classID = tonumber(classID),
        subClassID = tonumber(subClassID),
    }
end

local function GetPricingIdentityModule()
    return PocketCFO_Valuation:GetModule("PricingIdentity", true)
end

local function Classify(classID, equipLoc)
    local classifier = _G.PocketCFO and _G.PocketCFO.ItemClassifier
    if not classifier or type(classifier.Classify) ~= "function" then
        return nil
    end
    local ok, classification = pcall(classifier.Classify, classifier, { classID = classID, equipLoc = equipLoc })
    return ok and classification or nil
end

-- Facts are computed lazily: a lookup that only meets itemID rules never
-- calls GetItemInfo or builds a pricing identity.
local Facts = {}
Facts.__index = Facts

-- ref fields: itemID, itemLink, configKey, qualityTier, itemLevel,
-- statFingerprint, identity (an existing PricingIdentity identity).
function ValuationRules:NewFacts(ref)
    ref = type(ref) == "table" and ref or {}
    local facts = setmetatable({ ref = ref, values = {}, done = {} }, Facts)
    local identity = ref.identity
    facts.values.itemID = tonumber(ref.itemID) or (identity and tonumber(identity.itemID)) or GetItemIDFromLink(ref.itemLink)
    facts.done.itemID = true
    facts.itemLink = ref.itemLink or (identity and identity.itemLink)
    return facts
end

function Facts:Info()
    if self.infoDone then
        return self.info
    end
    self.infoDone = true
    self.info = SafeGetItemInfo(self.itemLink) or SafeGetItemInfo(self.values.itemID)
    return self.info
end

function Facts:Identity()
    if self.identityDone then
        return self.identity
    end
    self.identityDone = true
    self.identity = self.ref.identity
    if not self.identity then
        local module = GetPricingIdentityModule()
        if module then
            local ok, identity
            if self.itemLink then
                ok, identity = pcall(module.BuildFromItemLink, self.itemLink)
            elseif self.values.itemID then
                ok, identity = pcall(module.BuildFromItemID, self.values.itemID)
            end
            self.identity = ok and identity or nil
        end
    end
    return self.identity
end

-- Item data loaded? When false, category facts are unknown, not empty.
function Facts:IsLoaded()
    return self:Info() ~= nil
end

local FACT_GETTERS = {}

FACT_GETTERS.configKey = function(facts)
    if facts.ref.configKey then
        return facts.ref.configKey
    end
    local service = _G.PocketCFO and _G.PocketCFO.ItemIdentityService
    if facts.itemLink and service and type(service.FromItemLink) == "function" then
        local ok, identity = pcall(service.FromItemLink, service, facts.itemLink)
        if ok and type(identity) == "table" and not identity.unresolved then
            return identity.configKey
        end
    end
    return nil
end

FACT_GETTERS.rarity = function(facts)
    local info = facts:Info()
    return info and info.rarity
end

FACT_GETTERS.classID = function(facts)
    local info = facts:Info()
    return info and info.classID
end

FACT_GETTERS.subClassID = function(facts)
    local info = facts:Info()
    return info and info.subClassID
end

FACT_GETTERS.equipLoc = function(facts)
    local info = facts:Info()
    return info and info.equipLoc
end

FACT_GETTERS.maxStack = function(facts)
    local info = facts:Info()
    return info and info.maxStack
end

FACT_GETTERS.isStackable = function(facts)
    local maxStack = facts:Get("maxStack")
    if maxStack == nil then
        return nil
    end
    return maxStack > 1
end

FACT_GETTERS.classification = function(facts)
    local info = facts:Info()
    if not info then
        return nil
    end
    return Classify(info.classID, info.equipLoc)
end

FACT_GETTERS.itemLevel = function(facts)
    local level = tonumber(facts.ref.itemLevel)
    if level then
        return level
    end
    local identity = facts:Identity()
    if identity and tonumber(identity.itemLevel) then
        return tonumber(identity.itemLevel)
    end
    local info = facts:Info()
    return info and info.itemLevel
end

FACT_GETTERS.craftingQuality = function(facts)
    local quality = tonumber(facts.ref.qualityTier)
    if quality and quality > 0 then
        return quality, "given"
    end
    local identity = facts:Identity()
    quality = identity and tonumber(identity.qualityTier)
    if quality and quality > 0 then
        return quality, "blizzardQuality"
    end
    return nil
end

function Facts:Get(field)
    if field == "itemID" then
        return self.values.itemID
    end
    if not self.done[field] then
        self.done[field] = true
        local getter = FACT_GETTERS[field]
        if getter then
            local value, how = getter(self)
            self.values[field] = value
            if how then
                self.values[field .. "Source"] = how
            end
        end
    end
    return self.values[field]
end

-- Read-only view handed to rule code as ctx.item / test(item).
function Facts:View()
    if not self.view then
        local facts = self
        self.view = setmetatable({}, {
            __index = function(_, key)
                return facts:Get(key)
            end,
            __newindex = function() end,
        })
    end
    return self.view
end

local ALL_FACT_FIELDS = {
    "itemID", "configKey", "craftingQuality", "rarity", "itemLevel", "classID",
    "subClassID", "equipLoc", "classification", "maxStack", "isStackable",
}

-- Plain copy of every fact, for diagnostics.
function Facts:Snapshot()
    local snapshot = { loaded = self:IsLoaded(), itemLink = self.itemLink }
    for _, field in ipairs(ALL_FACT_FIELDS) do
        snapshot[field] = self:Get(field)
    end
    snapshot.craftingQualitySource = self.values.craftingQualitySource
    return snapshot
end

-- ─── Matching ──────────────────────────────────────────────────────────────

local function ValueMatches(expected, actual)
    if type(expected) == "table" then
        for _, option in ipairs(expected) do
            if option == actual then
                return true
            end
        end
        return false
    end
    return expected == actual
end

-- Fields that are only known once item data has loaded. A nil here on a
-- cold cache means "can't tell yet", not "doesn't match".
local NEEDS_ITEM_DATA = {
    rarity = true, classID = true, subClassID = true, equipLoc = true,
    classification = true, isStackable = true, craftingQuality = true,
    itemLevel = true,
}

-- Returns true (matches), false (doesn't), or nil (can't tell yet).
local function Matches(rule, facts)
    local match = rule.match
    if type(match) ~= "table" then
        return true
    end
    -- Cheap identity fields first so most rules exit without item data.
    if match.itemID ~= nil and not ValueMatches(match.itemID, facts:Get("itemID")) then
        return false
    end
    if match.configKey ~= nil then
        local configKey = facts:Get("configKey")
        if configKey == nil then
            return false
        end
        if not ValueMatches(match.configKey, configKey) then
            return false
        end
    end
    for field, expected in pairs(match) do
        if field ~= "itemID" and field ~= "configKey" and field ~= "test" then
            local actual = facts:Get(field)
            if actual == nil and NEEDS_ITEM_DATA[field] and not facts:IsLoaded() then
                return nil
            end
            if not ValueMatches(expected, actual) then
                return false
            end
        end
    end
    if type(match.test) == "function" then
        if not facts:IsLoaded() then
            return nil
        end
        local ok, result = pcall(match.test, facts:View())
        if not ok then
            return false
        end
        return result and true or false
    end
    return true
end

local function SortAscending(a, b)
    if a._score ~= b._score then
        return a._score < b._score
    end
    return a._order < b._order
end

-- Every rule carrying `kind` that matches, least specific first, plus
-- whether any rule couldn't be decided yet.
local function Collect(kind, facts)
    local matched, pending = {}, false
    for _, rule in pairs(ValuationRules.rules) do
        if rule[kind] ~= nil then
            local result = Matches(rule, facts)
            if result == true then
                matched[#matched + 1] = rule
            elseif result == nil then
                pending = true
            end
        end
    end
    table.sort(matched, SortAscending)
    return matched, pending
end

-- ─── Registration ──────────────────────────────────────────────────────────

function ValuationRules:Add(rule)
    if type(rule) ~= "table" or type(rule.id) ~= "string" or rule.id == "" then
        return false, "ruleNeedsID"
    end
    if rule.market == nil and rule.value == nil and rule.adjust == nil then
        return false, "ruleNeedsMarketValueOrAdjust"
    end
    if rule.market ~= nil and type(rule.market) ~= "table" then
        return false, "marketMustBeTable"
    end
    if rule.value ~= nil and type(rule.value) ~= "function" then
        return false, "valueMustBeFunction"
    end
    if rule.adjust ~= nil and type(rule.adjust) ~= "function" then
        return false, "adjustMustBeFunction"
    end
    if rule.match ~= nil and type(rule.match) ~= "table" then
        return false, "matchMustBeTable"
    end
    for field in pairs(rule.match or {}) do
        if not KNOWN_FIELDS[field] then
            return false, "unknownMatchField:" .. tostring(field)
        end
    end

    self._order = self._order + 1
    rule._score = Score(rule.match)
    rule._order = self._order
    self.rules[rule.id] = rule
    return true
end

function ValuationRules:Remove(id)
    self.rules[id] = nil
end

function ValuationRules:GetRule(id)
    return self.rules[id]
end

-- All rules, most specific first, for diagnostics.
function ValuationRules:ListRules()
    local list = {}
    for _, rule in pairs(self.rules) do
        list[#list + 1] = rule
    end
    table.sort(list, function(a, b) return SortAscending(b, a) end)
    return list
end

-- ─── market: scan-time settings ────────────────────────────────────────────

-- Merged market settings for one scanned market (pass the PricingIdentity
-- identity the scan built). Returns nil when no market rule matches, so the
-- scan prices exactly as it did before rules existed.
function ValuationRules:GetMarketParams(identity)
    if type(identity) ~= "table" then
        return nil
    end
    local any = false
    for _, rule in pairs(self.rules) do
        if rule.market ~= nil then
            any = true
            break
        end
    end
    if not any then
        return nil
    end

    local facts = self:NewFacts({
        itemID = identity.itemID,
        itemLink = identity.itemLink,
        qualityTier = identity.qualityTier,
        itemLevel = identity.itemLevel,
        statFingerprint = identity.statFingerprint,
        identity = identity,
    })
    local matched, pending = Collect("market", facts)
    if #matched == 0 then
        return nil, nil, pending
    end
    local params, ruleIDs = {}, {}
    for _, rule in ipairs(matched) do
        for key, value in pairs(rule.market) do
            params[key] = value
        end
        ruleIDs[#ruleIDs + 1] = rule.id
    end
    return params, ruleIDs, pending
end

-- ─── value: replace the price ──────────────────────────────────────────────

-- The single most specific value rule for these facts, or nil.
function ValuationRules:FindValueRule(facts)
    local matched, pending = Collect("value", facts)
    return matched[#matched], pending
end

-- ─── adjust: cap / floor / flag / reject ──────────────────────────────────

local Ctx = {}
Ctx.__index = Ctx

function Ctx:GetValue(itemRef, options)
    if not self.valuationService then
        return { unresolved = true, unresolvedReason = "valuationServiceUnavailable" }
    end
    return self.valuationService:GetItemValue(itemRef, options)
end

local function Record(ctx, action, before, after, note)
    ctx.records[#ctx.records + 1] = {
        ruleID = ctx.ruleID,
        action = action,
        before = before,
        after = after,
        note = note,
    }
    if note and note ~= "" then
        ctx.notes[#ctx.notes + 1] = note
    end
end

-- Price is at most maxValue.
function Ctx:Cap(maxValue, note)
    maxValue = tonumber(maxValue)
    if not maxValue or self.rejected or self.price == nil then
        return
    end
    if self.price > maxValue then
        local before = self.price
        self.price = math.floor(maxValue + 0.5)
        self.changed = true
        Record(self, "cap", before, self.price, note)
    end
end

-- Price is at least minValue.
function Ctx:Floor(minValue, note)
    minValue = tonumber(minValue)
    if not minValue or self.rejected or self.price == nil then
        return
    end
    if self.price < minValue then
        local before = self.price
        self.price = math.floor(minValue + 0.5)
        self.changed = true
        Record(self, "floor", before, self.price, note)
    end
end

-- Keep the price but show it as (Estimated).
function Ctx:Flag(note)
    if self.rejected then
        return
    end
    self.flagged = true
    Record(self, "flag", self.price, self.price, note)
end

-- Throw the price out: the item becomes unpriced.
function Ctx:Reject(note)
    if self.rejected then
        return
    end
    self.rejected = true
    Record(self, "reject", self.price, nil, note)
end

local function AdjustVisitKey(facts)
    return table.concat({
        tostring(facts:Get("itemID")),
        tostring(facts.ref.configKey),
        tostring(facts.ref.qualityTier),
        tostring(facts.ref.itemLevel),
        tostring(facts.ref.statFingerprint),
        tostring(facts.itemLink),
    }, "#")
end

-- Runs every matching adjust rule against a resolved result, in place.
-- Unresolved results are left alone (nothing to adjust). Returns the
-- result plus the adjustment records for ExplainValue.
function ValuationRules:ApplyAdjustments(result, facts, valuationService)
    if type(result) ~= "table" or result.resolved ~= true or result.value == nil then
        return result, {}
    end

    local matched, pending = Collect("adjust", facts)
    if pending then
        result.rulesPending = true
    end
    if #matched == 0 then
        return result, {}
    end

    local visitKey = AdjustVisitKey(facts)
    if self._adjustStack[visitKey] then
        return result, { { action = "skipped", note = "adjustCycle" } }
    end

    local ctx = setmetatable({
        price = result.value,
        source = result.source,
        valuationBasis = result.valuationBasis,
        result = result,
        item = facts:View(),
        valuationService = valuationService,
        records = {},
        notes = {},
    }, Ctx)

    self._adjustStack[visitKey] = true
    for _, rule in ipairs(matched) do
        if ctx.rejected then
            break
        end
        ctx.ruleID = rule.id
        local ok, err = pcall(rule.adjust, ctx)
        if not ok then
            ctx.records[#ctx.records + 1] = { ruleID = rule.id, action = "error", note = tostring(err) }
        end
    end
    self._adjustStack[visitKey] = nil

    if ctx.rejected then
        local rejectedValue = result.value
        result.resolved = false
        result.unresolved = true
        result.unresolvedReason = "rejectedByRule"
        result.reason = "rejectedByRule"
        result.rejectedValue = rejectedValue
        result.value = nil
        result.valuePerUnit = nil
        result.valuationBasis = "unresolved"
    elseif ctx.changed or ctx.flagged then
        result.unadjustedValue = result.value
        result.value = ctx.price
        result.valuePerUnit = ctx.price
        result.valuationBasis = "modeled"
    end
    if #ctx.notes > 0 then
        result.ruleNotes = ctx.notes
    end
    result.provenance = result.provenance or {}
    result.provenance.adjustments = ctx.records
    return result, ctx.records
end

-- ─── Diagnostics ───────────────────────────────────────────────────────────

-- Every rule and whether it matches this item. ref: same shape as NewFacts.
function ValuationRules:Inspect(ref)
    local facts = self:NewFacts(ref)
    local rows = {}
    for _, rule in ipairs(self:ListRules()) do
        local result = Matches(rule, facts)
        local kinds = {}
        if rule.market ~= nil then kinds[#kinds + 1] = "market" end
        if rule.value ~= nil then kinds[#kinds + 1] = "value" end
        if rule.adjust ~= nil then kinds[#kinds + 1] = "adjust" end
        rows[#rows + 1] = {
            id = rule.id,
            note = rule.note,
            score = rule._score,
            kinds = table.concat(kinds, ","),
            matches = result == true and "yes" or (result == nil and "pending" or "no"),
        }
    end
    return {
        facts = facts:Snapshot(),
        rules = rows,
    }
end

function ValuationRules:OnEnable()
end

function ValuationRules:OnDisable()
end

if PocketCFO_Valuation then
    PocketCFO_Valuation.ValuationRules = ValuationRules
end
