-- PocketCFO_AH/Services/CrateAnalysis/CrateAnalysis.lua
-- Forever only (loaded by PocketCFO_AH_Camelot.toc).
--
-- Crate analysis, step 1 (claude/Crate_Analysis_Design.md): rank every
-- Waylaid Crate the character can use by gold per Merchant's Favor, using
-- current PCFO Values (no AH searches yet; step 2 adds the live re-check).
--
-- Per Favor = (crate cost + cheapest bundle still needed) / Favor.
--   crate cost: 0 if a crate of that kind is in the bags, else its PCFO Value
--   bundle: only the mats not already in the bags count
--     ("Buy 8 Peacebloom", have 12 of 20)
-- The crate numbers (bundles, Favor, values) come from the Valuation
-- Tooltip module (Tooltip:GetCrateFill), the same ones the crate tooltip
-- shows, so the two never disagree.

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

local DEFAULT_LIMIT = 5

local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount

local function Valuation(name)
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule(name, true) or nil
end

-- Bags only: crates are filled from the bags.
-- Theoretical on Forever: GetItemCount(itemID) default counts bags only.
local function BagCount(itemID)
    if not GetItemCount or not itemID then
        return 0
    end
    local ok, count = pcall(GetItemCount, itemID)
    return ok and tonumber(count) or 0
end

-- The cheapest way to fill one crate with what's already in the bags.
-- Returns { row, need, have, cost } or nil when no bundle can be priced.
-- A bundle the bags fully cover costs 0 even if it has no price.
local function CheapestBundle(fill)
    local best
    for _, row in ipairs(fill.rows or {}) do
        if row.itemID and row.count then
            local have = BagCount(row.itemID)
            local need = math.max(0, row.count - have)
            local cost
            if need == 0 then
                cost = 0
            elseif row.each then
                cost = need * row.each
            end
            if cost and (not best or cost < best.cost) then
                best = { row = row, need = need, have = have, cost = cost }
            end
        end
    end
    return best
end

-- result = {
--   ranked = { entry, ... } cheapest per Favor first, at most `limit`,
--   aboveLevel, unpriced, loading = how many crates were left out and why,
-- }
-- entry = { crateID, name, rarity, favor, favorEstimated, haveCrate,
--           crateCost, bundle = { row, need, have, cost }, total, perFavor }
function CrateAnalysis:Rank(limit)
    limit = limit or DEFAULT_LIMIT
    local result = { ranked = {}, aboveLevel = 0, unpriced = 0, loading = 0 }
    local crateMats = Valuation("ForeverCrateMats")
    local tooltip = Valuation("Tooltip")
    if not crateMats or not crateMats.CRATES or not tooltip or not tooltip.GetCrateFill then
        result.unavailable = true
        return result
    end

    local level = (UnitLevel and UnitLevel("player")) or 0
    local all = {}
    for crateID, crate in pairs(crateMats.CRATES) do
        local minLevel = TIER_MIN_LEVEL[crate.tier] or 0
        if level < minLevel then
            result.aboveLevel = result.aboveLevel + 1
        else
            local fill = tooltip:GetCrateFill(crateID)
            if not fill or fill.pending then
                result.loading = result.loading + 1
            elseif not fill.favor then
                result.unpriced = result.unpriced + 1
            else
                local haveCrate = BagCount(crateID) > 0
                local crateCost = haveCrate and 0 or fill.crateValue
                local bundle = CheapestBundle(fill)
                if not crateCost or not bundle then
                    result.unpriced = result.unpriced + 1
                else
                    local total = crateCost + bundle.cost
                    all[#all + 1] = {
                        crateID = crateID,
                        name = fill.itemName,
                        rarity = fill.rarity,
                        favor = fill.favor,
                        favorEstimated = fill.favorEstimated,
                        haveCrate = haveCrate,
                        crateCost = crateCost,
                        bundle = bundle,
                        total = total,
                        perFavor = total / fill.favor,
                    }
                end
            end
        end
    end

    table.sort(all, function(a, b)
        if a.perFavor ~= b.perFavor then
            return a.perFavor < b.perFavor
        end
        if a.total ~= b.total then
            return a.total < b.total
        end
        return a.crateID < b.crateID
    end)
    for i = 1, math.min(limit, #all) do
        result.ranked[i] = all[i]
    end
    result.considered = #all
    return result
end

-- Seconds since the last full AH price scan (server time), or nil.
function CrateAnalysis:GetPriceAge()
    local cache = Valuation("PricingCache")
    local last = cache and cache.GetLastScanTime and cache:GetLastScanTime() or nil
    local now = (GetServerTime and GetServerTime()) or (time and time()) or nil
    if not tonumber(last) or not now then
        return nil
    end
    return math.max(0, now - tonumber(last))
end
