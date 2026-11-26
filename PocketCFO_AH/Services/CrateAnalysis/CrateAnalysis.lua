-- PocketCFO_AH/Services/CrateAnalysis/CrateAnalysis.lua
-- Forever only (loaded by PocketCFO_AH_Camelot.toc).
--
-- Crate analysis (claude/Crate_Analysis_Design.md, 2026-11-24): "I want N
-- Merchant's Favor; what's the cheapest way to get it right now?"
--
-- Prices: the listings of every crate and mat from the last full scan
-- (FullScan:AddListingKeeper hands them over at the end of every finished
-- scan, Analyze or Scan prices; saved per realm group). Never a stored
-- PCFO Value.
--
-- The plan: the least total gold that reaches at least the Favor asked
-- for (going over is fine when it's cheaper). Listings are used up as the
-- plan takes them (a mat in several crates' bundles is shared), and one
-- crate kind can be filled two ways (two rows).
--
-- Everything is priced at market value, owned or not (Brian: you could
-- sell it instead). What you own (bags + bank, ShoppingList:GetOwned) adds
-- supply priced at the item's cheapest listing; with nothing listed it has
-- no price and isn't used. Owned only changes the shopping list (which
-- takes it off), never the cost.

local PocketCFO_AH = _G.PocketCFO_AH
local CrateAnalysis = PocketCFO_AH:NewModule("CrateAnalysis")

-- Character level needed to use a crate (wow.gg, 2026-11-18: a character
-- level requirement, not profession skill).
local TIER_MIN_LEVEL = {
    Apprentice = 10,
    Journeyman = 10,
    Expert = 20,
    Artisan = 35,
}

local KEEPER_KEY = "CrateAnalysis"

local function SafeLoad(name)
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(name))
        or (IsAddOnLoaded and IsAddOnLoaded(name))
    if loaded then
        return true
    end
    local loadFn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if not loadFn then
        return false
    end
    local ok, result = pcall(loadFn, name)
    return ok and result and true or false
end

local function Valuation(name)
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule(name, true) or nil
end

local function ServerNow()
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

local function Owned(itemID)
    local list = _G.PocketCFO and _G.PocketCFO.ShoppingList
    if list and list.GetOwned then
        local ok, total = pcall(list.GetOwned, list, itemID)
        return ok and tonumber(total) or 0
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Listings from the full scan
-- ---------------------------------------------------------------------------

-- Every crate and every mat.
function CrateAnalysis:GetItems()
    local crateMats = Valuation("ForeverCrateMats")
    local items = {}
    if not crateMats then
        return items
    end
    for crateID in pairs(crateMats.CRATES or {}) do
        items[#items + 1] = crateID
    end
    for matID in pairs(crateMats.MATS or {}) do
        items[#items + 1] = matID
    end
    table.sort(items)
    return items
end

-- The listings belong to the AH they were scanned at, so they're saved and
-- read under the scan key (Forever, 2026-11-24: the open AH's market; a
-- Neutral scan must not replace your faction's saved listings). Same as the
-- realm group on retail.
local function RealmKey()
    local cache = Valuation("PricingCache")
    local ok, key = pcall(function()
        if cache and cache.GetScanMarketKey then
            return cache:GetScanMarketKey()
        end
        return cache and cache:GetRealmGroupKey()
    end)
    return ok and key or (GetRealmName and GetRealmName()) or "unknown"
end

local function Store()
    local db = PocketCFO_AH.db and PocketCFO_AH.db.global
    if not db then
        return nil
    end
    db.crateListings = db.crateListings or {}
    return db.crateListings
end

-- Registers with the full scan so every finished scan saves the listings.
function CrateAnalysis:EnsureKeeper()
    if self.keeperAdded then
        return true
    end
    SafeLoad("PocketCFO_Valuation")
    local scan = Valuation("FullScan")
    if not scan or not scan.AddListingKeeper then
        return false
    end
    local items = self:GetItems()
    if #items == 0 then
        return false
    end
    scan:AddListingKeeper(KEEPER_KEY, items, function(listings, startedAt)
        local store = Store()
        if store then
            store[RealmKey()] = { at = tonumber(startedAt) or ServerNow(), items = listings }
        end
    end)
    self.keeperAdded = true
    return true
end

function CrateAnalysis:OnEnable()
    self:EnsureKeeper()
end

-- Saved listings older than this aren't used (Brian, 2026-11-24: a 2-day-old
-- plan beats nothing when a scan can't run; older than 3 days, no plan).
CrateAnalysis.MAX_LISTINGS_AGE = 3 * 24 * 60 * 60

-- Asks the game to load every crate and mat (names, tooltips), so the fill
-- lists are ready when the plan is built (started when Analyze is pressed).
function CrateAnalysis:RequestItemData()
    SafeLoad("PocketCFO_Valuation")
    local crateMats = Valuation("ForeverCrateMats")
    if crateMats and crateMats.RequestLoad then
        pcall(crateMats.RequestLoad, crateMats)
    end
end

-- True when every crate's fill list is loaded (a plan built before that
-- leaves crates out and comes out wrong; Brian, 2026-11-24).
function CrateAnalysis:IsReady()
    local crates, loading = self:ReadCrates()
    return crates ~= nil and loading == 0
end

-- Saved listings for this realm group: { at = scan start, items = { [itemID] = levels } } or nil.
function CrateAnalysis:GetSavedListings()
    local store = Store()
    local saved = store and store[RealmKey()]
    if type(saved) == "table" and type(saved.items) == "table" then
        return saved
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Crates
-- ---------------------------------------------------------------------------

-- Crate facts (bundles, Favor, name) for every crate. Crates whose tooltip
-- data isn't loaded yet are counted in `loading`.
function CrateAnalysis:ReadCrates()
    local crateMats = Valuation("ForeverCrateMats")
    local tooltip = Valuation("Tooltip")
    local crates, loading = {}, 0
    if not crateMats or not crateMats.CRATES or not tooltip or not tooltip.GetCrateFill then
        return nil, 0
    end
    for crateID, info in pairs(crateMats.CRATES) do
        local fill = tooltip:GetCrateFill(crateID)
        if not fill or fill.pending or not fill.favor then
            loading = loading + 1
        else
            local bundles = {}
            for _, row in ipairs(fill.rows or {}) do
                if row.itemID and tonumber(row.count) and row.count > 0 then
                    bundles[#bundles + 1] = { itemID = row.itemID, count = row.count, name = row.name }
                end
            end
            if #bundles > 0 then
                crates[#crates + 1] = {
                    crateID = crateID,
                    name = fill.itemName or info.name,
                    rarity = fill.rarity,
                    favor = fill.favor,
                    favorEstimated = fill.favorEstimated,
                    minLevel = TIER_MIN_LEVEL[info.tier] or 0,
                    bundles = bundles,
                }
            else
                loading = loading + 1
            end
        end
    end
    table.sort(crates, function(a, b)
        return a.crateID < b.crateID
    end)
    return crates, loading
end

-- ---------------------------------------------------------------------------
-- What items cost. A plan is just how many of each item it uses; buying q
-- units of an item costs the first q units of its supply: what you own
-- first (priced at the item's cheapest listing, its market value; nothing
-- listed = no price), then the listings, cheapest first. So the plan's
-- total is exact even when several crates share a mat.
-- ---------------------------------------------------------------------------

local function NewMarket(listings)
    return { listings = listings or {}, items = {} }
end

-- Cumulative supply for one item: qty[k] units cost cost[k] in total.
local function Supply(market, itemID)
    local supply = market.items[itemID]
    if supply then
        return supply
    end
    local levels = market.listings[itemID] or {}
    supply = { qty = { 0 }, cost = { 0 }, price = { 0 } }
    local cheapest = levels[1] and levels[1].price or nil
    local owned = cheapest and Owned(itemID) or 0
    local function Add(units, price)
        if units > 0 then
            local n = #supply.qty
            supply.qty[n + 1] = supply.qty[n] + units
            supply.cost[n + 1] = supply.cost[n] + units * price
            supply.price[n + 1] = price
        end
    end
    Add(owned, cheapest or 0)
    for _, level in ipairs(levels) do
        Add(tonumber(level.qty) or 0, tonumber(level.price) or 0)
    end
    market.items[itemID] = supply
    return supply
end

-- Total cost of the first q units, or nil when there aren't q.
local function UnitsCost(market, itemID, q)
    if q <= 0 then
        return 0
    end
    local supply = Supply(market, itemID)
    local qty = supply.qty
    if q > qty[#qty] then
        return nil
    end
    -- First step whose running total reaches q (binary search).
    local lo, hi = 2, #qty
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        if qty[mid] >= q then
            hi = mid
        else
            lo = mid + 1
        end
    end
    return supply.cost[lo - 1] + (q - qty[lo - 1]) * supply.price[lo]
end

-- ---------------------------------------------------------------------------
-- The plan: least total gold that reaches at least `target` Favor
-- (Brian, 2026-11-24). Per Favor is only shown, never the goal.
--   1. Build it the quick way: repeatedly add the crate + fill with the
--      cheapest next Favor.
--   2. Improve it by trading: remove a crate, swap one crate for another
--      kind or fill, one for two, two for one; keep any trade that lowers
--      the total and still reaches the target; stop when none does.
-- The result is the cheapest plan no single trade can beat.
-- ---------------------------------------------------------------------------

local MAX_PASSES = 100

local function NewState(market)
    return { market = market, qty = {}, cost = {}, counts = {}, favor = 0, gold = 0 }
end

-- Changes `qty` of the given items by `deltas` (itemID -> units); returns
-- the change in total gold, or nil if any item runs out. Doesn't apply it.
local function CostDelta(state, deltas)
    local total = 0
    for itemID, delta in pairs(deltas) do
        if delta ~= 0 then
            local q = (state.qty[itemID] or 0) + delta
            if q < 0 then
                return nil
            end
            local newCost = UnitsCost(state.market, itemID, q)
            if not newCost then
                return nil
            end
            total = total + newCost - (state.cost[itemID] or 0)
        end
    end
    return total
end

local function ApplyDeltas(state, deltas)
    for itemID, delta in pairs(deltas) do
        if delta ~= 0 then
            local q = (state.qty[itemID] or 0) + delta
            state.qty[itemID] = q
            state.cost[itemID] = UnitsCost(state.market, itemID, q) or 0
        end
    end
end

-- Item deltas for a set of combo changes { { combo, n }, ... }, and the
-- Favor change.
local function MoveDeltas(changes)
    local deltas, favor = {}, 0
    for _, change in ipairs(changes) do
        local combo, n = change[1], change[2]
        deltas[combo.crateID] = (deltas[combo.crateID] or 0) + n
        deltas[combo.bundle.itemID] = (deltas[combo.bundle.itemID] or 0) + n * combo.bundle.count
        favor = favor + n * combo.favor
    end
    return deltas, favor
end

local function ApplyMove(state, changes, deltas, favorDelta, goldDelta)
    ApplyDeltas(state, deltas)
    for _, change in ipairs(changes) do
        local combo, n = change[1], change[2]
        state.counts[combo] = (state.counts[combo] or 0) + n
    end
    state.favor = state.favor + favorDelta
    state.gold = state.gold + goldDelta
end

local function Greedy(state, combos, target)
    while state.favor < target do
        local best, bestDeltas, bestGold, bestPer
        for _, combo in ipairs(combos) do
            local changes = { { combo, 1 } }
            local deltas = MoveDeltas(changes)
            local gold = CostDelta(state, deltas)
            if gold then
                local per = gold / combo.favor
                if not bestPer or per < bestPer then
                    best, bestDeltas, bestGold, bestPer = changes, deltas, gold, per
                end
            end
        end
        if not best then
            return false -- the AH ran out
        end
        ApplyMove(state, best, bestDeltas, best[1][1].favor, bestGold)
    end
    return true
end

local function Improve(state, combos, target)
    local function Try(changes)
        local deltas, favorDelta = MoveDeltas(changes)
        if state.favor + favorDelta < target then
            return false
        end
        local gold = CostDelta(state, deltas)
        if gold and gold < -0.5 then
            ApplyMove(state, changes, deltas, favorDelta, gold)
            return true
        end
        return false
    end
    for _ = 1, MAX_PASSES do
        local improved = false
        for _, a in ipairs(combos) do
            if (state.counts[a] or 0) > 0 then
                if Try({ { a, -1 } }) then
                    improved = true
                end
                for _, b in ipairs(combos) do
                    if b ~= a and (state.counts[a] or 0) > 0 then
                        if Try({ { a, -1 }, { b, 1 } }) or Try({ { a, -1 }, { b, 2 } }) then
                            improved = true
                        end
                        if (state.counts[a] or 0) >= 2 and Try({ { a, -2 }, { b, 1 } }) then
                            improved = true
                        end
                    end
                end
            end
        end
        if not improved then
            return
        end
    end
end

-- Plan for `target` Favor using crates usable at `level`.
-- plan = { rows, favor, gold, target, short = the AH ran out first,
--          items = { [itemID] = units the plan uses, owned included },
--          estimated = an Artisan (Est.) crate is in it }
-- row (one per crate + fill, cheapest per Favor first) = { crateID, name,
--          rarity, favorEstimated, minLevel, fillItemID, fillName, fillQty,
--          count, favor, gold }
-- Row gold: the row's share at each item's average price in the plan, so
-- the rows add up to the total.
function CrateAnalysis:BuildPlan(crates, listings, target, level)
    local combos = {}
    for _, crate in ipairs(crates or {}) do
        if (level or 0) >= crate.minLevel then
            for _, bundle in ipairs(crate.bundles) do
                combos[#combos + 1] = { crate = crate, crateID = crate.crateID, bundle = bundle, favor = crate.favor }
            end
        end
    end

    local state = NewState(NewMarket(listings))
    local reached = Greedy(state, combos, target)
    if reached then
        Improve(state, combos, target)
    end

    local plan = { rows = {}, favor = state.favor, gold = state.gold, target = target, items = {}, short = not reached }
    for itemID, q in pairs(state.qty) do
        if q > 0 then
            plan.items[itemID] = q
        end
    end
    local function Average(itemID)
        local q = state.qty[itemID] or 0
        return q > 0 and (state.cost[itemID] or 0) / q or 0
    end
    for _, combo in ipairs(combos) do
        local count = state.counts[combo] or 0
        if count > 0 then
            local crate = combo.crate
            local fillQty = count * combo.bundle.count
            plan.rows[#plan.rows + 1] = {
                crateID = crate.crateID,
                name = crate.name,
                rarity = crate.rarity,
                favorEstimated = crate.favorEstimated,
                minLevel = crate.minLevel,
                fillItemID = combo.bundle.itemID,
                fillName = combo.bundle.name,
                fillQty = fillQty,
                count = count,
                favor = count * crate.favor,
                gold = count * Average(crate.crateID) + fillQty * Average(combo.bundle.itemID),
            }
            if crate.favorEstimated then
                plan.estimated = true
            end
        end
    end
    table.sort(plan.rows, function(a, b)
        local pa, pb = a.gold / a.favor, b.gold / b.favor
        if pa ~= pb then
            return pa < pb
        end
        return a.crateID < b.crateID
    end)
    return plan
end

-- The first level above the character's that would make the same Favor
-- cheaper: { level, saving, crate = the first locked row used } or nil.
function CrateAnalysis:FindCheaperAtLevel(crates, listings, target, level, plan)
    if plan.short then
        return nil
    end
    local levels, seen = {}, {}
    for _, minLevel in pairs(TIER_MIN_LEVEL) do
        if minLevel > level and not seen[minLevel] then
            seen[minLevel] = true
            levels[#levels + 1] = minLevel
        end
    end
    table.sort(levels)
    for _, minLevel in ipairs(levels) do
        local other = self:BuildPlan(crates, listings, target, minLevel)
        if not other.short and other.gold < plan.gold then
            for _, row in ipairs(other.rows) do
                if row.minLevel > level then
                    return { level = minLevel, saving = plan.gold - other.gold, crate = row }
                end
            end
        end
    end
    return nil
end

-- Everything the screen shows, from the saved listings.
function CrateAnalysis:Analyze(target)
    target = math.max(1, math.floor(tonumber(target) or 0))
    local saved = self:GetSavedListings()
    if not saved then
        return { noListings = true }
    end
    if ServerNow() - (tonumber(saved.at) or 0) > self.MAX_LISTINGS_AGE then
        return { noListings = true, tooOld = true }
    end
    local crates, loading = self:ReadCrates()
    if not crates then
        return { unavailable = true }
    end
    local level = (UnitLevel and UnitLevel("player")) or 0
    local plan = self:BuildPlan(crates, saved.items, target, level)
    plan.loading = loading
    plan.level = level
    plan.pricesAt = saved.at
    plan.cheaperAtLevel = self:FindCheaperAtLevel(crates, saved.items, target, level, plan)
    return plan
end
