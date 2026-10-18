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
-- Takes effect as items are rescanned or searched.

Rules:Add({
    id = "depth-common",
    note = "White stackables: sample the cheapest 200",
    match = { isStackable = true, rarity = R.Common },
    market = { depth = 200 },
})

Rules:Add({
    id = "depth-uncommon",
    note = "Green stackables: sample the cheapest 100",
    match = { isStackable = true, rarity = R.Uncommon },
    market = { depth = 100 },
})

Rules:Add({
    id = "depth-rare",
    note = "Blue stackables: sample the cheapest 25",
    match = { isStackable = true, rarity = R.Rare },
    market = { depth = 25 },
})

Rules:Add({
    id = "depth-epic",
    note = "Purple stackables: sample the cheapest 5",
    match = { isStackable = true, rarity = R.Epic },
    market = { depth = 5 },
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
                ctx:Cap(cap, string.format("Capped at the quality %s price", tostring(tier or "?")))
            end
        end
    end,
})
