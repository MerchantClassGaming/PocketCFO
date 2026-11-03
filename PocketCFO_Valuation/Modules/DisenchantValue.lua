-- PocketCFO_Valuation/Modules/DisenchantValue.lua
-- Estimated disenchant value of an item, from the disenchants PocketCFO has
-- recorded (core DisenchantCapture). Used by Tooltip.lua.
--
-- Rules (decided with Brian 2026-10-25, revised 2026-10-27):
--   - Retail: per character, never pooled: results differ a lot between
--     enchanters. The hovering character's own disenchants are used. A
--     character with no disenchants (an alt that is not an enchanter) uses
--     the account's character with the most disenchants instead.
--   - Forever (2026-10-27): every character's disenchants are pooled. Results
--     depend on the item, not the enchanter (Classic behavior, Theoretical on
--     Forever until the data shows it).
--   - Match: same item quality (green/blue/purple), same expansion (retail
--     only) and same item class (weapon 2 / armor 4 / profession gear 19,
--     added 2026-10-27: in Classic weapons and armor disenchant differently;
--     tracked on retail too so the data can show whether it matters there).
--     Then the same item level; if none, the closest item level of that
--     group, at any distance (one item level only, never a blend). Ties go
--     to the item level with more disenchants, then the higher one.
--   - If the item's class has no records yet, the same quality (+ expansion)
--     across all classes is used instead, so something shows rather than
--     nothing until that class has data.
--   - Expansion (retail): an item only ever gives mats from its own
--     expansion (Brian: a Midnight green never gives War Within mats), so
--     records from another expansion never count. Uses GetItemInfo's expacID,
--     where Midnight = 11 (seen in-game 2026-10-25). Not the same numbering as
--     ProfessionRegistry (Midnight = 12); do not mix them. Forever ignores
--     expansion (one game, and expacID there is Theoretical).
--   - Estimate = average gold per disenchant over the matched records: every
--     mat counted (each quality tier is its own itemID, knowledge-point extras
--     included), average quantity per disenchant x the valuation engine's
--     price. The average carries the random tier roll (e.g. 60% tier 2 / 40%
--     tier 1) without modelling it.
--   - Mats with no price are left out (the estimate can run low until a scan
--     prices them). Nothing errors on a missing price.
--   - No seed data: no line until at least one matching disenchant exists.
--
-- Which items get an estimate: green, blue or purple weapons (class 2),
-- armor (4) and profession gear (19). Known gap: a few such items cannot be
-- disenchanted and would still get the line if matching data exists.
--
-- Flavor: Both. Listed in PocketCFO_Valuation.toc and
-- PocketCFO_Valuation_Camelot.toc (Forever added 2026-10-27). Forever-only
-- behavior (pooling, no expansion) is gated on PocketCFO.flavor == "forever".

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local DisenchantValue = PocketCFO_Valuation:NewModule("DisenchantValue")

local DISENCHANT_RARITY = { [2] = true, [3] = true, [4] = true }
local DISENCHANT_CLASS = { [2] = true, [4] = true, [19] = true }

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo

-- cacheKey -> { stamp, groups = { ["rarity|expac|class"] = { [ilvl] = { n, mats = { [itemID] = { qty, link } } } } } }
-- Each record also goes into the "rarity|expac|any" group (class fallback).
local indexCache = {}

local function Capture()
    local core = _G.PocketCFO
    return core and core.GetModule and core:GetModule("DisenchantCapture", true) or nil
end

local function IsForever()
    local core = _G.PocketCFO
    return core and core.flavor == "forever" or false
end

local function Stamp(entry)
    return tostring(entry.count or 0) .. ":" .. tostring(#(entry.records or {}))
end

-- Forever ignores expansion; retail needs it.
local function ExpacKey(expacID)
    if IsForever() then
        return "all"
    end
    return expacID and tostring(expacID) or nil
end

local function GroupKey(rarity, expacKey, classKey)
    return tostring(rarity) .. "|" .. tostring(expacKey) .. "|" .. tostring(classKey)
end

local function AddToGroup(groups, key, ilvl, record)
    groups[key] = groups[key] or {}
    local group = groups[key][ilvl]
    if not group then
        group = { n = 0, mats = {} }
        groups[key][ilvl] = group
    end
    group.n = group.n + 1
    for _, mat in ipairs(record.mats or {}) do
        local id = tonumber(mat.id)
        if id then
            local total = group.mats[id] or { qty = 0 }
            group.mats[id] = total
            total.qty = total.qty + (tonumber(mat.qty) or 0)
            total.link = mat.link or total.link
        end
    end
end

-- Records grouped by quality + expansion + class, then item level. Rebuilt
-- only when the records change. entries = list of character entries.
local function GetIndex(cacheKey, stamp, entries)
    local cached = indexCache[cacheKey]
    if cached and cached.stamp == stamp then
        return cached.groups
    end

    local groups = {}
    for _, entry in ipairs(entries) do
        for _, record in ipairs(entry.records or {}) do
            local item = record.item
            local rarity = item and tonumber(item.rarity)
            local ilvl = item and tonumber(item.ilvl)
            local expacKey = item and ExpacKey(tonumber(item.expacID))
            if rarity and ilvl and expacKey then
                local classID = tonumber(item.classID)
                if classID then
                    AddToGroup(groups, GroupKey(rarity, expacKey, classID), ilvl, record)
                end
                AddToGroup(groups, GroupKey(rarity, expacKey, "any"), ilvl, record)
            end
        end
    end

    indexCache[cacheKey] = { stamp = stamp, groups = groups }
    return groups
end

-- The hovering character, or the account's character with the most
-- disenchants when the hovering character has none.
local function PickCharacter(capture)
    local currentGUID = UnitGUID and UnitGUID("player")
    local all = capture:GetAllData() or {}
    local current = currentGUID and all[currentGUID]
    if current and #(current.records or {}) > 0 then
        return currentGUID, current
    end
    local bestGUID, best = nil, nil
    for guid, entry in pairs(all) do
        local count = #(entry.records or {})
        if count > 0 and (not best or count > #(best.records or {})) then
            bestGUID, best = guid, entry
        end
    end
    return bestGUID, best
end

-- Exact item level, else the closest one at any distance. Ties: more
-- disenchants, then the higher item level.
local function MatchGroup(byIlvl, ilvl)
    if not byIlvl then
        return nil, nil
    end
    if byIlvl[ilvl] then
        return byIlvl[ilvl], ilvl
    end
    local bestGroup, bestIlvl, bestDistance = nil, nil, nil
    for groupIlvl, group in pairs(byIlvl) do
        local distance = math.abs(groupIlvl - ilvl)
        local better = not bestDistance
            or distance < bestDistance
            or (distance == bestDistance and group.n > bestGroup.n)
            or (distance == bestDistance and group.n == bestGroup.n and groupIlvl > bestIlvl)
        if better then
            bestGroup, bestIlvl, bestDistance = group, groupIlvl, distance
        end
    end
    return bestGroup, bestIlvl
end

local function PriceOf(valuationService, itemID, itemLink)
    local ok, result = pcall(valuationService.GetItemValue, valuationService, { itemID = itemID, itemLink = itemLink })
    if ok and type(result) == "table" and not result.unresolved then
        return tonumber(result.value)
    end
    return nil
end

-- Estimated disenchant value in copper for an item link, or nil.
-- Second return: details for diagnostics.
function DisenchantValue:GetEstimate(itemLink)
    if type(itemLink) ~= "string" then
        return nil
    end
    local capture = Capture()
    local valuationService = PocketCFO_Valuation:GetModule("ValuationService", true)
    if not capture or not valuationService or type(GetItemInfo) ~= "function" then
        return nil
    end

    local okInfo, _, _, rarity, _, _, _, _, _, _, _, _, classID, _, _, expacID = pcall(GetItemInfo, itemLink)
    rarity = okInfo and tonumber(rarity) or nil
    classID = okInfo and tonumber(classID) or nil
    expacID = okInfo and tonumber(expacID) or nil
    if not DISENCHANT_RARITY[rarity] or not DISENCHANT_CLASS[classID] then
        return nil
    end

    local ilvl
    if C_Item and type(C_Item.GetDetailedItemLevelInfo) == "function" then
        local okIlvl, effective = pcall(C_Item.GetDetailedItemLevelInfo, itemLink)
        ilvl = okIlvl and tonumber(effective) or nil
    end
    if not ilvl then
        return nil
    end

    local expacKey = ExpacKey(expacID)
    if not expacKey then
        return nil
    end

    local groups, characterGUID, characterName, pooled
    if IsForever() then
        -- Pool every character (Forever only).
        local all = capture:GetAllData() or {}
        local guids, entries, stampParts = {}, {}, {}
        for guid in pairs(all) do
            guids[#guids + 1] = guid
        end
        table.sort(guids)
        for _, guid in ipairs(guids) do
            entries[#entries + 1] = all[guid]
            stampParts[#stampParts + 1] = guid .. "=" .. Stamp(all[guid])
        end
        if #entries == 0 then
            return nil
        end
        groups = GetIndex("ALL", table.concat(stampParts, ";"), entries)
        pooled = true
    else
        local entry
        characterGUID, entry = PickCharacter(capture)
        if not entry then
            return nil
        end
        characterName = entry.name
        groups = GetIndex(characterGUID, Stamp(entry), { entry })
    end

    local matchedClass = classID
    local group, matchedIlvl = MatchGroup(groups[GroupKey(rarity, expacKey, classID)], ilvl)
    if not group or group.n == 0 then
        matchedClass = "any"
        group, matchedIlvl = MatchGroup(groups[GroupKey(rarity, expacKey, "any")], ilvl)
    end
    if not group or group.n == 0 then
        return nil
    end

    local copper, pricedMats, unpricedMats = 0, 0, 0
    for itemID, total in pairs(group.mats) do
        local price = PriceOf(valuationService, itemID, total.link)
        if price then
            copper = copper + price * total.qty / group.n
            pricedMats = pricedMats + 1
        else
            unpricedMats = unpricedMats + 1
        end
    end
    if pricedMats == 0 then
        return nil
    end

    local details = {
        characterGUID = characterGUID,
        characterName = characterName,
        pooled = pooled or false,
        rarity = rarity,
        expacID = expacID,
        classID = classID,
        matchedClass = matchedClass,
        ilvl = ilvl,
        matchedIlvl = matchedIlvl,
        disenchants = group.n,
        pricedMats = pricedMats,
        unpricedMats = unpricedMats,
    }
    self.lastEstimate = { itemLink = itemLink, value = copper, details = details }
    return copper, details
end

function DisenchantValue:GetLastEstimate()
    return self.lastEstimate
end
