-- PocketCFO_Valuation/Modules/ProfessionGearPairs.lua
-- Which green profession tool/accessory is the same piece as which blue one
-- (Hobbyist Alchemist's Mixing Rod <-> Sin'dorei Alchemist's Mixing Rod), so
-- the "tool-tier-cap" rule (ValuationRuleSet.lua) can cap a green at a share
-- of the blue's price (Brian, 2026-10-13 / 2026-10-23).
--
-- How pairs are found (designed 2026-10-13, confirmed against
-- /mcgd professiongear 2026-10-23 - every Midnight group paired):
--   - candidates: items in the price cache whose slot is profession tool or
--     profession accessory, rarity green or blue. Epics are BoP and never
--     reach the AH, so they never show up.
--   - group by expansion + profession (subClassID) + slot. Accessories also
--     group by their stats: head and chest accessories both read
--     INVTYPE_PROFESSION_GEAR, but the matching green and blue share stats.
--   - a group with exactly one green and one blue is a pair.
--   - still tied (Alchemy: all four accessories are Ingenuity+Multicraft):
--     a green and a blue that share an icon pair up, if that icon is unique
--     to them in the group (confirmed: Apron/Coveralls and Cap/Hat).
--   - anything else is left unpaired and logged - never guessed at. An
--     unpaired item still gets its own quality ladder.
-- Older expansions only have greens on the AH (blues are BoP), so they form
-- no pairs.
--
-- Saved list: PocketCFO_ValuationDB.global.professionGearPairs
--   [itemID] = partnerItemID (both directions)
-- Rebuilt a few seconds after this addon loads and after every completed
-- full scan, in small chunks so it never hitches. Items whose details the
-- game hasn't sent yet are requested and retried a few times.
--
-- Theoretical: GetItemInfoInstant's slot (equipLoc) is used to pick the
-- candidates without waiting for item data. Our earlier finding is that its
-- classID is unreliable on a cold cache; its slot hasn't been tested. If
-- pairs go missing, check the rebuild line in the session log.

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local ProfessionGearPairs = PocketCFO_Valuation:NewModule("ProfessionGearPairs")

local SLOTS = {
    INVTYPE_PROFESSION_TOOL = "tool",
    INVTYPE_PROFESSION_GEAR = "gear",
}
local GREEN, BLUE = 2, 3
local PLACEHOLDER_STAT_PREFIX = "ITEM_MOD_MODIFIED_CRAFTING_STAT_"

local ROWS_PER_CHUNK = 4000
local ITEMS_PER_CHUNK = 200
local REBUILD_DELAY_AFTER_LOAD_SECONDS = 5
local RETRY_DELAY_SECONDS = 3
local MAX_RETRIES = 5

local function SessionLog(fmt, ...)
    local core = _G.PocketCFO
    if not core or not core.AppendSessionLog then
        return
    end
    core:AppendSessionLog("[MCG] " .. string.format(fmt, ...))
end

local function GetStore()
    local db = PocketCFO_Valuation.db
    if not db or not db.global then
        return nil
    end
    db.global.professionGearPairs = db.global.professionGearPairs or {}
    return db.global.professionGearPairs
end

--- The other-rarity version of this tool/accessory, or nil.
function ProfessionGearPairs:GetPartner(itemID)
    local store = GetStore()
    return store and store[tonumber(itemID)] or nil
end

-- Real stats from a cache key ("id|q3|stats:A|B" -> "A|B"); nil when the key
-- has none or only Blizzard's "a stat you'll choose" placeholder.
local function RealStatsFromKey(marketKey)
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

local function InstantSlotAndIcon(itemID)
    if not GetItemInfoInstant then
        return nil
    end
    local ok, _, _, _, equipLoc, icon = pcall(GetItemInfoInstant, itemID)
    if not ok or not SLOTS[equipLoc] then
        return nil
    end
    return SLOTS[equipLoc], icon
end

-- rarity, expansion, subClassID from full item data, or nil when the game
-- hasn't sent it yet.
local function FullInfo(itemID)
    local ok, name, _, rarity, _, _, _, _, _, _, _, _, _, subClassID, _, expacID = pcall(GetItemInfo, itemID)
    if not ok or not name then
        return nil
    end
    return tonumber(rarity), tonumber(expacID), tonumber(subClassID)
end

local function RequestLoad(itemID)
    if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
end

local function Link(store, greenID, blueID)
    store[greenID] = blueID
    store[blueID] = greenID
end

-- members: { itemID, rarity, icon }. Returns the number of pairs made and
-- the IDs that have a partner color in the group but couldn't be paired.
local function PairGroup(members, store)
    local greens, blues = {}, {}
    for _, member in ipairs(members) do
        if member.rarity == GREEN then
            greens[#greens + 1] = member
        elseif member.rarity == BLUE then
            blues[#blues + 1] = member
        end
    end
    if #greens == 0 or #blues == 0 then
        return 0, nil
    end
    if #greens == 1 and #blues == 1 then
        Link(store, greens[1].itemID, blues[1].itemID)
        return 1, nil
    end

    -- Tiebreak: a green and a blue that are the only two with their icon.
    local byIcon = {}
    for _, member in ipairs(members) do
        if member.icon then
            local bucket = byIcon[member.icon] or { greens = {}, blues = {} }
            byIcon[member.icon] = bucket
            local list = member.rarity == GREEN and bucket.greens or bucket.blues
            list[#list + 1] = member
        end
    end
    local paired, made = {}, 0
    for _, bucket in pairs(byIcon) do
        if #bucket.greens == 1 and #bucket.blues == 1 then
            Link(store, bucket.greens[1].itemID, bucket.blues[1].itemID)
            paired[bucket.greens[1].itemID] = true
            paired[bucket.blues[1].itemID] = true
            made = made + 1
        end
    end
    local left = {}
    for _, member in ipairs(members) do
        if not paired[member.itemID] then
            left[#left + 1] = member.itemID
        end
    end
    return made, (#left > 0) and left or nil
end

local function SameStore(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for itemID, partner in pairs(a) do
        if b[itemID] ~= partner then
            return false
        end
    end
    for itemID in pairs(b) do
        if a[itemID] == nil then
            return false
        end
    end
    return true
end

--- Rebuilds the saved pair list from the pricing cache, chunked.
function ProfessionGearPairs:Rebuild()
    local cacheModule = PocketCFO_Valuation:GetModule("PricingCache", true)
    local cache = cacheModule and cacheModule:GetCache()
    if not cache or not C_Timer or not C_Timer.After then
        return
    end

    local token = (self.rebuildToken or 0) + 1
    self.rebuildToken = token

    local seen = {}        -- itemID -> true once checked
    local candidates = {}  -- itemID -> { slot, icon, stats = { [fp] = true } }
    local lastKey = nil

    local function Stale()
        return self.rebuildToken ~= token
    end

    local function Finish(resolved, unloaded)
        local groups, order = {}, {}
        for itemID, entry in pairs(resolved) do
            local statsKey = ""
            if entry.slot == "gear" then
                -- Accessories pair by stats; one item with several different
                -- stat sets in the cache can't be grouped safely.
                local only, count = nil, 0
                for fp in pairs(entry.stats) do
                    only, count = fp, count + 1
                end
                statsKey = (count == 1) and only or ("?" .. tostring(itemID))
            end
            local groupKey = table.concat({
                tostring(entry.expacID), tostring(entry.subClassID), entry.slot, statsKey,
            }, "#")
            if not groups[groupKey] then
                groups[groupKey] = {}
                order[#order + 1] = groupKey
            end
            table.insert(groups[groupKey], {
                itemID = itemID, rarity = entry.rarity, icon = entry.icon,
            })
        end

        local store, pairCount, notPaired = {}, 0, {}
        for _, groupKey in ipairs(order) do
            local made, left = PairGroup(groups[groupKey], store)
            pairCount = pairCount + made
            for _, itemID in ipairs(left or {}) do
                notPaired[#notPaired + 1] = tostring(itemID)
            end
        end

        local changed = not SameStore(store, GetStore())
        local db = PocketCFO_Valuation.db
        if db and db.global then
            db.global.professionGearPairs = store
        end
        self.lastBuild = { pairs = pairCount, notPaired = notPaired, unloaded = unloaded }
        SessionLog("ProfessionGearPairs: rebuilt - %d pairs, not paired: %s, item data never loaded: %d (%s)",
            pairCount, (#notPaired > 0) and table.concat(notPaired, ",") or "none", unloaded,
            changed and "changed" or "unchanged")
        if changed then
            PocketCFO_Valuation:SendMessage("PCFO_PRICING_UPDATED", "professionGearPairs", nil, "professionGearPairs")
        end
    end

    -- Phase 2: full item data for the candidates, with load requests and a
    -- few retries for items the game hasn't sent yet.
    local function ResolveCandidates(list, resolved, attempt)
        local index = 1
        local pending = {}
        local function Step()
            if Stale() then
                return
            end
            local stopAt = math.min(index + ITEMS_PER_CHUNK - 1, #list)
            for i = index, stopAt do
                local itemID = list[i]
                local rarity, expacID, subClassID = FullInfo(itemID)
                if rarity then
                    if rarity == GREEN or rarity == BLUE then
                        local entry = candidates[itemID]
                        resolved[itemID] = {
                            rarity = rarity, expacID = expacID, subClassID = subClassID,
                            slot = entry.slot, icon = entry.icon, stats = entry.stats,
                        }
                    end
                else
                    RequestLoad(itemID)
                    pending[#pending + 1] = itemID
                end
            end
            index = stopAt + 1
            if index <= #list then
                C_Timer.After(0, Step)
                return
            end
            if #pending > 0 and attempt < MAX_RETRIES then
                C_Timer.After(RETRY_DELAY_SECONDS, function()
                    if not Stale() then
                        ResolveCandidates(pending, resolved, attempt + 1)
                    end
                end)
                return
            end
            Finish(resolved, #pending)
        end
        C_Timer.After(0, Step)
    end

    -- Phase 1: walk the cache once, keep profession tools/accessories.
    local function Walk()
        if Stale() then
            return
        end
        -- next() over a table that gains keys mid-walk (a search refresh
        -- landing between chunks) is unsafe; pcall it and start over later.
        local ok, finished = pcall(function()
            local processed = 0
            local key, row = next(cache, lastKey)
            while key ~= nil do
                local itemID = type(row) == "table" and tonumber(row.itemID)
                    or tonumber(tostring(key):match("^(%d+)|"))
                if itemID then
                    if not seen[itemID] then
                        seen[itemID] = true
                        local slot, icon = InstantSlotAndIcon(itemID)
                        if slot then
                            candidates[itemID] = { slot = slot, icon = icon, stats = {} }
                        end
                    end
                    local entry = candidates[itemID]
                    if entry then
                        local fp = RealStatsFromKey(tostring(key))
                        if fp then
                            entry.stats[fp] = true
                        end
                    end
                end
                lastKey = key
                processed = processed + 1
                if processed >= ROWS_PER_CHUNK then
                    return false
                end
                key, row = next(cache, lastKey)
            end
            return true
        end)

        if not ok then
            SessionLog("ProfessionGearPairs: rebuild interrupted (%s) - retrying", tostring(finished))
            C_Timer.After(REBUILD_DELAY_AFTER_LOAD_SECONDS, function()
                if not Stale() then
                    self:Rebuild()
                end
            end)
            return
        end
        if not finished then
            C_Timer.After(0, Walk)
            return
        end

        local list = {}
        for itemID in pairs(candidates) do
            list[#list + 1] = itemID
        end
        table.sort(list)
        ResolveCandidates(list, {}, 1)
    end

    C_Timer.After(0, Walk)
end

function ProfessionGearPairs:OnEnable()
    GetStore()
    if C_Timer and C_Timer.After then
        C_Timer.After(REBUILD_DELAY_AFTER_LOAD_SECONDS, function()
            self:Rebuild()
        end)
    end
end

if PocketCFO_Valuation then
    PocketCFO_Valuation.ProfessionGearPairs = ProfessionGearPairs
end
