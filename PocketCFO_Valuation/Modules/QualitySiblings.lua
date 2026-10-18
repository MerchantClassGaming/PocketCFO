-- PocketCFO_Valuation/Modules/QualitySiblings.lua
-- Which items are the same thing at different crafting qualities
-- (Writhing Hide Q1/Q2/Q3 = three itemIDs), so the "quality-sibling-cap"
-- valuation rule (ValuationRuleSet.lua) can make sure a lower quality is
-- never valued above a higher one (Brian, 2026-10-16: you're never punished
-- for using a higher-quality mat, so a lower one can't be worth more).
--
-- How siblings are found (Brian, 2026-10-16): same item name, different
-- crafting quality. Built from the pricing cache, which already stores
-- itemName + qualityTier per market row (FullScan reads the name straight
-- from the AH replicate data). A name group only counts when:
--   - it has 2+ different itemIDs,
--   - each itemID appears at exactly one quality (crafted gear keeps ONE
--     itemID across qualities, so it never forms a group),
--   - no two itemIDs share a quality (guards against two unrelated items
--     that happen to share a name, e.g. across expansions).
-- Anything that fails those checks is skipped, never guessed at.
--
-- Saved list: PocketCFO_ValuationDB.global.qualitySiblings
--   [itemID] = { tier = n, higher = { itemID, ... }, marketKey = "..." }
--   higher: ascending tier. marketKey: the item's own price-cache key, so the
--   cap can read a sibling's price even when the game hasn't sent that
--   sibling's item details yet (see quality-sibling-cap).
-- Rebuilt a few seconds after this addon loads and after every completed
-- full scan, in small chunks so it never hitches.

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local QualitySiblings = PocketCFO_Valuation:NewModule("QualitySiblings")

local ROWS_PER_CHUNK = 4000
local REBUILD_DELAY_AFTER_LOAD_SECONDS = 5

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
    db.global.qualitySiblings = db.global.qualitySiblings or {}
    return db.global.qualitySiblings
end

--- Higher-quality siblings of itemID (ascending quality), or nil.
function QualitySiblings:GetHigherSiblings(itemID)
    local store = GetStore()
    local entry = store and store[tonumber(itemID)]
    return entry and entry.higher or nil
end

--- This item's price-cache key as seen when the list was built, or nil.
function QualitySiblings:GetMarketKey(itemID)
    local store = GetStore()
    local entry = store and store[tonumber(itemID)]
    return entry and entry.marketKey or nil
end

--- This item's quality within its sibling group, or nil.
function QualitySiblings:GetTier(itemID)
    local store = GetStore()
    local entry = store and store[tonumber(itemID)]
    return entry and entry.tier or nil
end

local function RowName(row, itemID)
    local name = row.itemName
    if type(name) == "string" and name ~= "" then
        return name
    end
    -- Older rows (e.g. written by search refresh) may lack a name; use the
    -- client's item cache only if it already has it.
    local ok, cachedName = pcall(GetItemInfo, itemID)
    if ok and type(cachedName) == "string" and cachedName ~= "" then
        return cachedName
    end
    return nil
end

-- True when two saved lists hold exactly the same groups.
local function SameStore(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    for itemID, entry in pairs(a) do
        local other = b[itemID]
        if type(other) ~= "table" or other.tier ~= entry.tier
            or #(other.higher or {}) ~= #(entry.higher or {}) then
            return false
        end
        for index, higherID in ipairs(entry.higher or {}) do
            if other.higher[index] ~= higherID then
                return false
            end
        end
    end
    for itemID in pairs(b) do
        if a[itemID] == nil then
            return false
        end
    end
    return true
end

-- Turns name groups into the saved list. groups[name][itemID] = tier, or
-- false when that itemID was seen at more than one quality. marketKeys:
-- itemID -> the cache key it was seen under.
local function BuildStore(groups, marketKeys)
    local store, groupCount = {}, 0
    for _, members in pairs(groups) do
        local list, valid, seenTier = {}, true, {}
        for itemID, tier in pairs(members) do
            if tier == false or seenTier[tier] then
                valid = false
                break
            end
            seenTier[tier] = true
            list[#list + 1] = { itemID = itemID, tier = tier }
        end
        if valid and #list >= 2 then
            table.sort(list, function(a, b) return a.tier < b.tier end)
            groupCount = groupCount + 1
            for index, member in ipairs(list) do
                local higher = {}
                for upper = index + 1, #list do
                    higher[#higher + 1] = list[upper].itemID
                end
                store[member.itemID] = {
                    tier = member.tier,
                    higher = higher,
                    marketKey = marketKeys and marketKeys[member.itemID] or nil,
                }
            end
        end
    end
    return store, groupCount
end

--- Rebuilds the saved sibling list from the pricing cache, chunked.
function QualitySiblings:Rebuild()
    local cacheModule = PocketCFO_Valuation:GetModule("PricingCache", true)
    local cache = cacheModule and cacheModule:GetCache()
    if not cache or not C_Timer or not C_Timer.After then
        return
    end

    local token = (self.rebuildToken or 0) + 1
    self.rebuildToken = token
    local groups = {}
    local marketKeys = {}
    local lastKey = nil

    local function Step()
        if self.rebuildToken ~= token then
            return -- a newer rebuild started
        end
        -- next() over a table that gains keys mid-walk (a search refresh
        -- landing between chunks) is unsafe; pcall it and start over later.
        local ok, finished = pcall(function()
            local processed = 0
            local key, row = next(cache, lastKey)
            while key ~= nil do
                if type(row) == "table" then
                    local itemID = tonumber(row.itemID)
                    local tier = tonumber(row.qualityTier)
                    if itemID and tier and tier > 0 then
                        local name = RowName(row, itemID)
                        if name then
                            local members = groups[name]
                            if not members then
                                members = {}
                                groups[name] = members
                            end
                            local previous = members[itemID]
                            if previous == nil then
                                members[itemID] = tier
                                marketKeys[itemID] = key
                            elseif previous ~= tier then
                                members[itemID] = false
                            end
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
            SessionLog("QualitySiblings: rebuild interrupted (%s) - retrying", tostring(finished))
            C_Timer.After(REBUILD_DELAY_AFTER_LOAD_SECONDS, function()
                if self.rebuildToken == token then
                    self:Rebuild()
                end
            end)
            return
        end
        if not finished then
            C_Timer.After(0, Step)
            return
        end

        local store, groupCount = BuildStore(groups, marketKeys)
        local changed = not SameStore(store, GetStore())
        local db = PocketCFO_Valuation.db
        if db and db.global then
            db.global.qualitySiblings = store
        end
        SessionLog("QualitySiblings: rebuilt - %d sibling groups (%s)", groupCount, changed and "changed" or "unchanged")
        -- Values only change if the list did; an unchanged list (the usual
        -- case on login) must not make every open screen recalculate
        -- (Brian, 2026-10-16: second freeze on first board load).
        if changed then
            PocketCFO_Valuation:SendMessage("PCFO_PRICING_UPDATED", "qualitySiblings", nil, "qualitySiblings")
        end
    end

    C_Timer.After(0, Step)
end

function QualitySiblings:OnEnable()
    GetStore()
    if C_Timer and C_Timer.After then
        C_Timer.After(REBUILD_DELAY_AFTER_LOAD_SECONDS, function()
            self:Rebuild()
        end)
    end
end

if PocketCFO_Valuation then
    PocketCFO_Valuation.QualitySiblings = QualitySiblings
end
