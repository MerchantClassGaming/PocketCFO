-- PocketCFO_Valuation/Modules/ValuationRuleSet.lua
-- The valuation rules. This is the file to edit when pricing needs to
-- change for an item or a kind of item. The engine (ValuationRules.lua)
-- explains the rule format, the match fields and which rule wins.
--
-- The default market behavior (bait/clown filtering, depth) lives in
-- PricingValuation.lua; a market rule only overrides the settings it names:
--   depth                  how many units to sample (built-in default: 200)
--   lowOutlierMultiplier   bait cutoff: next price is more than N x this one (3.0)
--   lowOutlierMaxQuantity  ...and this one has at most N units (2)
--   upperMarketMultiplier  clown cutoff: stop at N x the cheapest real price (3.0)
--
-- Containers and Moxie are value rules registered from
-- CustomValuationRegistrations.lua.
--
-- Examples (not active):
--
--   Rules:Add({
--       id = "tool-sanity-flag",
--       note = "Tools priced off one listing are shown as estimates",
--       match = { classification = "professionTool" },
--       adjust = function(ctx)
--           if ctx.source == "auctionHouse" then
--               ctx:Flag("Few tools listed")
--           end
--       end,
--   })

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local Rules = PocketCFO_Valuation:GetModule("ValuationRules", true)
if not Rules then
    return
end

local R = Rules.RARITY       -- luacheck: ignore
local CLASS = Rules.CLASS    -- luacheck: ignore
local EQUIP = Rules.EQUIP    -- luacheck: ignore

-- Rules go below this line.

-- ─── Market depth by rarity (stackables) ──────────────────────────────────
-- How many of the cheapest units (after bait/clown filtering) the AH price
-- is taken from. Rarer items have thinner markets. Brian, 2026-10-12.
-- Cut from 200/100/25/5 to 50/20/10/2 so thin bottom ends do not pull the
-- sample up the price ladder (Brian, 2026-11-05).
-- Takes effect as items are rescanned or searched.

Rules:Add({
    id = "depth-common",
    note = "White stackables: sample the cheapest 50",
    match = { isStackable = true, rarity = R.Common },
    market = { depth = 50 },
})

Rules:Add({
    id = "depth-uncommon",
    note = "Green stackables: sample the cheapest 20",
    match = { isStackable = true, rarity = R.Uncommon },
    market = { depth = 20 },
})

Rules:Add({
    id = "depth-rare",
    note = "Blue stackables: sample the cheapest 10",
    match = { isStackable = true, rarity = R.Rare },
    market = { depth = 10 },
})

Rules:Add({
    id = "depth-epic",
    note = "Purple stackables: sample the cheapest 2",
    match = { isStackable = true, rarity = R.Epic },
    market = { depth = 2 },
})

-- ─── Gray items: vendor price only (Brian, 2026-10-28) ─────────────────────
-- Grays have no purpose except selling to a vendor, so their value is the
-- vendor sell price, never an AH price (Vibrant Wings had AH listings at
-- 39g and counted as 39g of beast kill loot). A gray a vendor won't buy is
-- worth 0. Rarity 0 = Poor (ValuationRules.RARITY has no Poor entry).
-- Needs item data loaded; on a cold item cache the rule is skipped
-- (rulesPending) like every rarity rule.

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

Rules:Add({
    id = "gray-vendor-only",
    note = "Gray items: vendor sell price only",
    match = { rarity = 0 },
    value = function(context)
        local ref = context.itemLink or context.itemID
        local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(GetItemInfo, ref)
        if not ok or not name then
            return { unresolved = true, unresolvedReason = "itemDataPending" }
        end
        local copper = math.max(0, tonumber(sellPrice) or 0)
        return { value = copper, valuePerUnit = copper, valuationBasis = "fixed" }
    end,
})

-- ─── Quality siblings (Brian, 2026-10-16) ─────────────────────────────────
-- A lower crafting quality is never worth more than a higher quality of the
-- same item: you're never punished for using a higher-quality mat, so
-- nobody should pay more for the lower one (TWW Writhing Hide: Q2 listed at
-- 18,888g while Q3 sat at 46g -> Q2 is worth 46g). Matched exactly, no
-- discount - if the lower quality is actually cheaper, its own price
-- already wins. Compares against each higher sibling's full PocketCFO value
-- (custom/vendor/AH, after its own rules); only looks upward, so it can't
-- loop. Siblings come from QualitySiblings.lua (same name, different
-- quality). Applies at lookup time, so the cached AH price stays as
-- observed and the cap always uses the siblings' current values.

-- The lowest "never worth more than a better version" cap a rule worked
-- out, kept on the result even when it didn't change the value (the item's
-- own price was already lower). Smart posting uses it as the most an item
-- posts at (Brian, 2026-11-04: green rod's ladder cap was ~369g from the
-- blues, but its own 350g price hid it, and posting matched a 2,547g green).
-- Adds a field only; no value changes.
-- from (2026-11-07): the better item that set this cap, kept with the
-- lowest cap as result.ladderCapFrom = { itemID, quality, price } (price =
-- that item's own price). The post window shows it as one "Capped by" line
-- instead of listing every better version.
local function NoteCap(ctx, cap, from)
    cap = tonumber(cap)
    local result = ctx and ctx.result
    if not cap or type(result) ~= "table" then
        return
    end
    if not result.ladderCap or cap < result.ladderCap then
        result.ladderCap = cap
        result.ladderCapFrom = from
    end
end

Rules:Add({
    id = "quality-sibling-cap",
    note = "Never worth more than a higher quality of the same item",
    adjust = function(ctx)
        local siblings = PocketCFO_Valuation:GetModule("QualitySiblings", true)
        local higher = siblings and siblings:GetHigherSiblings(ctx.item.itemID)
        if not higher then
            return
        end
        for _, siblingID in ipairs(higher) do
            local tier = siblings:GetTier(siblingID)
            local cap
            local sibling = ctx:GetValue({ itemID = siblingID, qualityTier = tier })
            if type(sibling) == "table" and not sibling.unresolved and tonumber(sibling.value) then
                cap = tonumber(sibling.value)
            else
                -- The full lookup needs the sibling's item details, which
                -- the game may not have sent yet (a sibling that isn't in
                -- the order or your bags) - that's how the patron board
                -- priced Q2 Writhing Hide uncapped at 18,888g while the
                -- open order, a moment later, capped it (Brian,
                -- 2026-10-16). Fall back to the sibling's cached AH price,
                -- which needs no item details.
                local cache = PocketCFO_Valuation:GetModule("PricingCache", true)
                local marketKey = siblings:GetMarketKey(siblingID)
                    or (tier and (tostring(siblingID) .. "|q" .. tostring(tier)))
                local value = cache and marketKey and cache:GetValueByMarketKey(marketKey)
                cap = tonumber(value)
            end
            if cap then
                NoteCap(ctx, cap, { itemID = siblingID, quality = tier, price = cap })
                ctx:Cap(cap, string.format("Capped at the quality %s price", tostring(tier or "?")))
            end
        end
    end,
})

-- ─── Interchangeable versions (Brian, 2026-10-23) ─────────────────────────
-- Darkmoon Decks come in several item levels and stats, but every version
-- makes the same Sigil (a Sigil crafted from a 90 deck and a 220 deck stack
-- together). So no version is worth more than the cheapest one (an ilvl 90
-- Rot deck listed at 65,000g while the 220 sat at 136g -> worth 136g). Only
-- AH prices are capped. Which items count is the explicit item ID list in
-- ValuationService:IsInterchangeableVersionItem, shared with the
-- item-ID-only lookup; nothing else (tools, other gear) is touched.

Rules:Add({
    id = "interchangeable-version-cap",
    note = "Darkmoon Decks: never worth more than the cheapest version",
    -- No match fields: the item ID list lives only in ValuationService
    -- (INTERCHANGEABLE_ITEM_IDS); the check below is a plain table lookup.
    adjust = function(ctx)
        if ctx.source ~= "auctionHouse" or not ctx.valuationService then
            return
        end
        if not ctx.valuationService:IsInterchangeableVersionItem(ctx.item) then
            return
        end
        local cheapest = ctx.valuationService:GetCheapestVersionValue(ctx.item.itemID)
        local cap = type(cheapest) == "table" and tonumber(cheapest.value) or nil
        if cap then
            ctx:Cap(cap, "Capped at the cheapest version")
        end
    end,
})

-- ─── Profession tool / accessory ladder (Brian, 2026-10-13, 2026-10-23) ───
-- Buyers want the best (blue quality 5) or the cheapest thing that works,
-- so the middle qualities rarely sell and their listings are often old or
-- wishful (a 225 Sin'dorei Quill listed at 19,999g while the 232 sat at
-- 3,100g). Every quality is capped at a share of the blue quality 5:
--   blue  Q5 100  Q4 90  Q3 80  Q2 70  Q1 60
--   green Q5 40   Q4 35  Q3 30  Q2 25  Q1 20
-- (Green Q5/Q4 were 50/40 until 2026-11-06: green Q5 Farstrider Fabric
-- Cutters valued ~1,285g against a 2,666g blue Q5 while buyers paid ~900g.
-- A tuning lever: adjust from sales data as it builds up.)
-- When blue Q5 has no price, every better quality that has one stands in,
-- scaled by the ratio of their shares (no Q5, Q4 at 1,350g -> Q3 capped at
-- 1,350 x 80/90 = 1,200g). The lowest cap wins; a lower own price stays.
-- Each better quality is priced as: same stats if listed, otherwise the
-- cheapest listed stat in the same stat group (Resourcefulness = Multicraft,
-- Perception = Finesse; 2026-11-06), otherwise the average of every stat
-- listed at that quality (a recipe preview has no stat yet, so it always
-- uses the average).
-- Deals never cap (2026-11-06): a better quality priced below 50% of the
-- next priced quality above it (scaled by the shares) AND at or below its
-- own cost to make +10% is a dump listing, not a market price, and is
-- skipped (see DEAL_PCT, FLOOR_MARKUP).
--
-- Out-of-date prices (Brian, 2026-10-23): a price counts as current when it
-- was seen within 3 days of the NEWEST price for that tool (green and blue
-- together) - not 3 days from today, so values don't vanish when someone
-- doesn't log in for a week. Out-of-date prices are just old data (a Q3
-- Hobbyist rod at 70g from 4 months ago, never relisted):
--   - they never cap anything else;
--   - an item whose own price is out of date gets its ladder value instead.
--     A real stat version only ever uses its own stat's price - another
--     stat's price never stands in for it (architecture: a cheaper stat
--     version must never lower another's value).
--
-- Every quality of a tool is the same item ID (so quality-sibling-cap never
-- sees them); green and blue are different items, linked by
-- ProfessionGearPairs.lua. An unpaired green (older expansions, where blues
-- are BoP) still gets its own green ladder.
-- Reads the price cache directly: a better quality's raw price gives the
-- same lowest cap as its capped value, and needs no recursion.
-- Only AH prices are adjusted.

local LADDER = {
    [3] = { [5] = 100, [4] = 90, [3] = 80, [2] = 70, [1] = 60 }, -- blue
    [2] = { [5] = 40, [4] = 35, [3] = 30, [2] = 25, [1] = 20 },  -- green (Q5/Q4 lowered 2026-11-06)
}
local RARITY_NAME = { [2] = "green", [3] = "blue" }
local PLACEHOLDER_STAT_PREFIX = "ITEM_MOD_MODIFIED_CRAFTING_STAT_"
local CURRENT_WINDOW_SECONDS = 3 * 24 * 60 * 60 -- same as PricingCache's fresh window

-- Real stats in a market key, or nil (none, or only Blizzard's "a stat
-- you'll choose" placeholder - see ValuationService BaseKeyWithoutChosenStats).
local function RealStats(marketKey)
    marketKey = tostring(marketKey or "")
    local statsAt = marketKey:find("|stats:", 1, true)
    if not statsAt then
        return nil
    end
    local fingerprint = marketKey:sub(statsAt + #"|stats:")
    for stat in string.gmatch(fingerprint, "[^|]+") do
        if stat:sub(1, #PLACEHOLDER_STAT_PREFIX) == PLACEHOLDER_STAT_PREFIX then
            return nil
        end
    end
    return fingerprint ~= "" and fingerprint or nil
end

-- Current price of a row, or nil when it has no price or is out of date.
local function CurrentValue(row, cutoff)
    if type(row) ~= "table" then
        return nil
    end
    local timestamp = tonumber(row.timestamp)
    if not timestamp or timestamp < cutoff then
        return nil
    end
    return tonumber(row.value)
end

-- Average current price of every real-stat version at one quality, or a
-- plain (no-stats) key's current price.
local function QualityAverage(rows, base, cutoff)
    local plain = CurrentValue(rows[base], cutoff)
    if plain then
        return plain
    end
    local prefix = base .. "|stats:"
    local total, count = 0, 0
    for key, row in pairs(rows) do
        if key:sub(1, #prefix) == prefix and RealStats(key) then
            local value = CurrentValue(row, cutoff)
            if value then
                total = total + value
                count = count + 1
            end
        end
    end
    if count == 0 then
        return nil
    end
    return total / count
end

-- Profession gear stat groups (Brian, 2026-11-06): stats a buyer treats as
-- the same. Crafting tools: Resourcefulness = Multicraft (Ingenuity and
-- Crafting Speed only match themselves). Gathering tools: Perception =
-- Finesse (Deftness only matches itself). Returns a key that is equal for
-- stat strings in the same group ("A|B" fingerprints compared stat by stat).
-- Matched by name fragment: the exact Perception / Finesse key names are
-- Theoretical until seen in a market key.
local STAT_GROUPS = {
    { "MULTICRAFT", "craft-yield" },
    { "RESOURCEFULNESS", "craft-yield" },
    { "PERCEPTION", "gather-yield" },
    { "FINESSE", "gather-yield" },
}

local function StatGroupKey(stats)
    if type(stats) ~= "string" or stats == "" then
        return nil
    end
    local parts = {}
    for stat in string.gmatch(stats, "[^|]+") do
        local upper = stat:upper()
        local key = stat
        for _, group in ipairs(STAT_GROUPS) do
            if upper:find(group[1], 1, true) then
                key = group[2]
                break
            end
        end
        parts[#parts + 1] = key
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

-- Shared with smart AH posting (match a similar-stat listing).
PocketCFO_Valuation.StatGroupKey = StatGroupKey

-- A better quality's price for capping: same stats if current, otherwise
-- the cheapest current price in the same stat group (2026-11-06), otherwise
-- the current average at that quality.
local function BetterQualityPrice(rows, itemID, quality, stats, cutoff)
    local base = tostring(itemID) .. "|q" .. tostring(quality)
    if stats then
        local value = CurrentValue(rows[base .. "|stats:" .. stats], cutoff)
        if value then
            return value
        end
        local group = StatGroupKey(stats)
        local prefix = base .. "|stats:"
        local cheapest
        for key, row in pairs(rows) do
            if key:sub(1, #prefix) == prefix then
                local otherStats = RealStats(key)
                if otherStats and StatGroupKey(otherStats) == group then
                    local other = CurrentValue(row, cutoff)
                    if other and (not cheapest or other < cheapest) then
                        cheapest = other
                    end
                end
            end
        end
        if cheapest then
            return cheapest
        end
    end
    return QualityAverage(rows, base, cutoff)
end

-- A better version priced far below the version above it is a deal (a
-- dump listing), not a market price: it never caps anything (Brian,
-- 2026-11-06: a 225 blue Sin'dorei Snippers dumped at 200g capped green Q5
-- Farstrider Fabric Cutters at 125g while the 232 blue sat at 2,666g).
-- Same 50% as the posting gear gap check.
local DEAL_PCT = 0.50

-- ...but only when the seller is losing money or close to it (Brian,
-- 2026-11-06): a price is a dump only if it is ALSO at or below that
-- version's floor, cost to make +10% (same markup as the smart posting
-- floor). Someone making a good profit is a real price, even if it's far
-- below the version above it (green Q5 Bright Linen Enchanting Hat at 125g,
-- costs ~6g: real, so it caps the Q4. Accepted: Turbo Junker's blue Q2 at
-- 400g, costs ~200g, now caps the green Q5 at ~229g). Cost unknown -> the
-- share check alone decides, as before.
local FLOOR_MARKUP = 1.10
local COST_CACHE_SECONDS = 60

-- Cost to Make per itemID from core CostToMakeStore (saved recipe at
-- today's prices, else the recipe estimate; Theoretical on a character
-- without the profession). Mats priced with GetItemValue. Mats are never
-- profession tools, so this doesn't recurse into this rule; the guard is
-- there in case one ever is. A known cost is cached briefly (valuation runs
-- per tooltip); an unknown one never is.
local costCache = {}
local costing = false

local function MatValue(matID, matConfigKey)
    local service = PocketCFO_Valuation:GetModule("ValuationService", true)
    if not service then
        return nil
    end
    local ok, result = pcall(service.GetItemValue, service, { itemID = matID, configKey = matConfigKey })
    if not ok or type(result) ~= "table" or result.unresolved then
        return nil
    end
    local value = tonumber(result.valuePerUnit or result.value)
    if not value or value <= 0 then
        return nil
    end
    return value
end

local function CostToMake(itemID)
    local store = _G.PocketCFO_CostToMakeStore
    if costing or not itemID or not store or type(store.GetCost) ~= "function" then
        return nil
    end
    local now = GetTime and GetTime() or 0
    local cached = costCache[itemID]
    if cached and now - cached.t < COST_CACHE_SECONDS then
        return cached.cost
    end
    costing = true
    local ok, cost = pcall(store.GetCost, store, nil, itemID, nil, MatValue, nil)
    costing = false
    cost = ok and tonumber(cost) or nil
    if cost and cost <= 0 then
        cost = nil
    end
    -- Only a known cost is kept. "Unknown" (mats not loaded yet, e.g. while
    -- the posting list builds) is tried again on the next look, so the same
    -- item doesn't get a different value depending on timing (Brian,
    -- 2026-11-06: Apprentice Jeweler's Apron row max 1,251g while its hover
    -- value a minute later was 285g).
    if cost then
        costCache[itemID] = { cost = cost, t = now }
    end
    return cost
end

-- The item's own current price: its own stat only when it has a real stat,
-- otherwise the current average at its quality.
local function OwnCurrentPrice(rows, itemID, quality, stats, cutoff)
    local base = tostring(itemID) .. "|q" .. tostring(quality)
    if stats then
        return CurrentValue(rows[base .. "|stats:" .. stats], cutoff)
    end
    return QualityAverage(rows, base, cutoff)
end

Rules:Add({
    id = "tool-tier-cap",
    note = "Profession tools/accessories: capped at a share of the blue quality 5",
    match = { equipLoc = { EQUIP.ProfessionTool, "INVTYPE_PROFESSION_GEAR" } },
    adjust = function(ctx)
        if ctx.source ~= "auctionHouse" or ctx.price == nil then
            return
        end
        local rarity = tonumber(ctx.item.rarity)
        local quality = tonumber(ctx.item.craftingQuality)
        local ownLadder = rarity and LADDER[rarity]
        local ownShare = ownLadder and quality and ownLadder[quality]
        local itemID = tonumber(ctx.item.itemID)
        if not ownShare or not itemID then
            return
        end
        local cache = PocketCFO_Valuation:GetModule("PricingCache", true)
        if not cache then
            return
        end
        local pairsModule = PocketCFO_Valuation:GetModule("ProfessionGearPairs", true)
        local partnerID = pairsModule and pairsModule:GetPartner(itemID)

        -- This tool's cache rows by key (own item + its green/blue partner).
        local rowsByItem = {}
        local function RowsFor(id)
            if not rowsByItem[id] then
                local map = {}
                for _, row in ipairs(cache:GetCandidatesForItemID(id) or {}) do
                    if type(row) == "table" and row.marketKey then
                        map[tostring(row.marketKey)] = row
                    end
                end
                rowsByItem[id] = map
            end
            return rowsByItem[id]
        end

        local newest
        for _, id in ipairs({ itemID, partnerID }) do
            for _, row in pairs(RowsFor(id)) do
                local timestamp = tonumber(row.timestamp)
                if timestamp and tonumber(row.value) and (not newest or timestamp > newest) then
                    newest = timestamp
                end
            end
        end
        if not newest then
            return
        end
        local cutoff = newest - CURRENT_WINDOW_SECONDS

        local provenance = ctx.result and ctx.result.provenance
        local stats = RealStats(provenance and provenance.marketKey)

        -- Every better position on the ladder: higher qualities of this
        -- item, plus (for a green) every quality of its blue partner.
        local better = {}
        for q = quality + 1, 5 do
            better[#better + 1] = { itemID = itemID, quality = q, rarity = rarity, share = ownLadder[q] }
        end
        if rarity == 2 and partnerID then
            for q = 1, 5 do
                better[#better + 1] = { itemID = partnerID, quality = q, rarity = 3, share = LADDER[3][q] }
            end
        end

        -- Price every better position, lowest share first, then skip deals:
        -- a price below DEAL_PCT of the next position up (scaled by the
        -- shares) never caps. The top priced position has nothing above it
        -- and always counts.
        local priced = {}
        for _, position in ipairs(better) do
            local price = BetterQualityPrice(RowsFor(position.itemID), position.itemID, position.quality, stats, cutoff)
            if price then
                priced[#priced + 1] = { position = position, price = price }
            end
        end
        table.sort(priced, function(a, b) return a.position.share < b.position.share end)

        local lowestCap, lowestFrom, lowestFromPrice
        for index, entry in ipairs(priced) do
            local above
            for later = index + 1, #priced do
                if priced[later].position.share > entry.position.share then
                    above = priced[later]
                    break
                end
            end
            local isDeal = above ~= nil
                and entry.price < above.price * entry.position.share / above.position.share * DEAL_PCT
            if isDeal then
                local cost = CostToMake(entry.position.itemID)
                if cost and entry.price > cost * FLOOR_MARKUP then
                    isDeal = false -- far below, but the seller makes a profit: a real price
                end
            end
            if not isDeal then
                local cap = entry.price * ownShare / entry.position.share
                if not lowestCap or cap < lowestCap then
                    lowestCap, lowestFrom, lowestFromPrice = cap, entry.position, entry.price
                end
            end
        end

        NoteCap(ctx, lowestCap, lowestFrom and {
            itemID = lowestFrom.itemID,
            quality = lowestFrom.quality,
            price = lowestFromPrice,
        } or nil)
        local ownCurrent = OwnCurrentPrice(RowsFor(itemID), itemID, quality, stats, cutoff)
        local target, note
        if ownCurrent and (not lowestCap or ownCurrent <= lowestCap) then
            target = ownCurrent
            note = "Old listings left out"
        elseif lowestCap then
            target = lowestCap
            local share = math.floor(ownShare * 100 / lowestFrom.share + 0.5)
            local from = string.format("%s quality %d", RARITY_NAME[lowestFrom.rarity] or "?", lowestFrom.quality)
            if ownCurrent then
                note = string.format("Capped at %d%% of the %s price", share, from)
            else
                note = string.format("No current listing: %d%% of the %s price", share, from)
            end
        end
        if not target then
            return -- nothing current to compare with; keep the price as is
        end
        if target < ctx.price then
            ctx:Cap(target, note)
        elseif target > ctx.price then
            ctx:Floor(target, note)
        end
    end,
})
