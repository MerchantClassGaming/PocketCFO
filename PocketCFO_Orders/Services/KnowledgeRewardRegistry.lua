-- PocketCFO_Orders/Services/KnowledgeRewardRegistry.lua
-- Recognizes profession knowledge point items among patron order rewards.
--
-- Two layers, no item names (names break on non-English clients):
--   1. KNOWN_POINTS: itemID -> knowledge points. Exact +1/+2 for items we
--      have confirmed. Add new items here as they are seen.
--   2. Fallback: any reward whose on-use spell is "Studying" (spellID
--      1241734, confirmed in-game on Flicker of Midnight Tailoring Knowledge
--      via /mcgd orderlist) is still flagged as knowledge, just without a
--      point value. Theoretical: whether every knowledge item uses this same
--      spellID - unconfirmed for +2 items and other professions.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemSpell = (C_Item and C_Item.GetItemSpell) or GetItemSpell

local ADDON_NAME, _ = ...
local PocketCFO_Orders = _G.PocketCFO_Orders

local KnowledgeRewardRegistry = {}

-- Confirmed by Brian (2026-10-11).
local KNOWN_POINTS = {
    [246322] = 1, -- Flicker of Midnight Blacksmithing Knowledge
    [246323] = 2, -- Glimmer of Midnight Blacksmithing Knowledge
    [246334] = 1, -- Flicker of Midnight Tailoring Knowledge
}

-- Knowledge item ID blocks. Each crafting profession has a Flicker (+1)
-- and a Glimmer (+2) with consecutive IDs - Flicker on the even ID, Glimmer
-- on the next odd one (confirmed: Blacksmithing 246322/246323; Tailoring's
-- Flicker 246334 fits the same block). Theoretical for the rest of each
-- block, including the TWW block (TWW Flicker IDs 228724-228738 taken from
-- the installed knowledge-point tracker's data). KNOWN_POINTS always wins.
local ID_BLOCKS = {
    { first = 246322, last = 246337 }, -- Midnight
    { first = 228724, last = 228739 }, -- The War Within
}

local STUDYING_SPELL_IDS = {
    [1241734] = true,
}

local function PointsFromBlocks(itemID)
    for _, block in ipairs(ID_BLOCKS) do
        if itemID >= block.first and itemID <= block.last then
            return ((itemID - block.first) % 2 == 0) and 1 or 2
        end
    end
    return nil
end

local function GetSpellName(spellID)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        return ok and name or nil
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellID)
        return ok and name or nil
    end
    return nil
end

local function GetUseSpell(itemID)
    if C_Item and C_Item.GetItemSpell then
        local ok, spellName, spellID = pcall(C_Item.GetItemSpell, itemID)
        if ok then return spellName, tonumber(spellID) end
    elseif GetItemSpell then
        local ok, spellName, spellID = pcall(GetItemSpell, itemID)
        if ok then return spellName, tonumber(spellID) end
    end
    return nil, nil
end

-- Fallback for items outside the known blocks: the item's use spell is the
-- "Studying" spell, matched by ID or by the spell's name in this client's
-- own language (so it still works if other knowledge items use a different
-- spell ID with the same name). Needs item data cached; the board re-runs
-- when item data loads.
local function IsStudyingItem(itemID)
    local spellName, spellID = GetUseSpell(itemID)
    if spellID and STUDYING_SPELL_IDS[spellID] then
        return true
    end
    if spellName then
        for knownID in pairs(STUDYING_SPELL_IDS) do
            local knownName = GetSpellName(knownID)
            if knownName and knownName == spellName then
                return true
            end
        end
    end
    return false
end

--- @return isKnowledge boolean, points number|nil (nil = knowledge, amount unknown)
function KnowledgeRewardRegistry:Classify(itemID)
    itemID = tonumber(itemID)
    if not itemID then
        return false, nil
    end
    if KNOWN_POINTS[itemID] then
        return true, KNOWN_POINTS[itemID]
    end
    local blockPoints = PointsFromBlocks(itemID)
    if blockPoints then
        return true, blockPoints
    end
    if IsStudyingItem(itemID) then
        return true, nil
    end
    return false, nil
end

KnowledgeRewardRegistry.KNOWN_POINTS = KNOWN_POINTS

if PocketCFO_Orders then
    PocketCFO_Orders.KnowledgeRewardRegistry = KnowledgeRewardRegistry
end
