-- PocketCFO_Crafting/Crafting/QueueGeneration.lua
-- Queue row generation and shaping.
-- Calls InventoryTargetEvaluator, applies filters, groups by category, and sorts.
-- Returns render-ready category groups. Does not create UI.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local QueueGeneration = PocketCFO_Crafting:NewModule("QueueGeneration")

local function DebugTime()
    return debugprofilestop and debugprofilestop() or (GetTime and GetTime() * 1000) or 0
end

local function LogTiming(label, startedAt, extra)
    if not PocketCFO or not PocketCFO.Debug then return end
    local elapsed = DebugTime() - (startedAt or DebugTime())
    if extra and extra ~= "" then
        PocketCFO:Debug("%s elapsed=%.1fms %s", label, elapsed, extra)
    else
        PocketCFO:Debug("%s elapsed=%.1fms", label, elapsed)
    end
end

local function GetProfessionRegistry()
    return PocketCFO and PocketCFO.ProfessionRegistry or _G.PocketCFO_ProfessionRegistry
end

-- Resolves the display icon and output itemID for a recipe.
-- Returns iconID, outputItemID. Either may be nil on failure.
local function ResolveIconAndOutputItemID(recipeID, recipeInfo)
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeOutputItemData then
        local outputData = C_TradeSkillUI.GetRecipeOutputItemData(recipeID)
        local outputItemID = outputData and outputData.itemID and outputData.itemID ~= 0 and outputData.itemID
        if outputItemID then
            local _, _, _, _, _, _, _, _, _, iconID = GetItemInfo(outputItemID)
            if iconID then return iconID, outputItemID end
        end
    end

    if recipeInfo and recipeInfo.spellID then
        -- C_Spell.GetSpellInfo returns a table (iconID field); the global
        -- GetSpellInfo is gone on newer clients.
        local spellIcon
        if C_Spell and C_Spell.GetSpellInfo then
            local spellInfo = C_Spell.GetSpellInfo(recipeInfo.spellID)
            spellIcon = spellInfo and spellInfo.iconID
        elseif GetSpellInfo then
            spellIcon = select(3, GetSpellInfo(recipeInfo.spellID))
        end
        if spellIcon then return spellIcon, nil end
    end

    return nil, nil
end

local function GetCategoryName(catID)
    if catID and catID ~= 0 and C_TradeSkillUI.GetCategoryInfo then
        local catInfo = C_TradeSkillUI.GetCategoryInfo(catID)
        if catInfo then
            return catInfo.name or ("Category " .. catID)
        end
    end
    return "Other"
end

local function GetGroupLabel(category)
    local registry = GetProfessionRegistry()
    local expName = category.expansionID and registry and registry:GetExpansionName(category.expansionID)
    return expName
        and string.format("%s: %s", expName:upper(), category.catName:upper())
        or  category.catName:upper()
end

local function ResultPassesFilters(result, showZeroDeficit, currentExpFilter)
    if not showZeroDeficit and result.deficit <= 0 then
        return false
    end
    if currentExpFilter and result.config.expansionID ~= currentExpFilter then
        return false
    end
    return true
end

local function BuildCategoryGroups(results, categoryOrder, categoryMeta, showZeroDeficit, currentExpFilter)
    local categoryMap = {}
    for _, catID in ipairs(categoryOrder or {}) do
        local meta = categoryMeta and categoryMeta[catID]
        if meta then
            categoryMap[catID] = {
                label       = GetGroupLabel(meta),
                expansionID = meta.expansionID,
                results     = {},
            }
        end
    end

    for _, result in ipairs(results or {}) do
        if ResultPassesFilters(result, showZeroDeficit, currentExpFilter) then
            local catID = result.categoryID or 0
            if categoryMap[catID] then
                table.insert(categoryMap[catID].results, result)
            end
        end
    end

    local categoryGroups = {}
    for _, catID in ipairs(categoryOrder or {}) do
        local group = categoryMap[catID]
        if group and #group.results > 0 then
            table.insert(categoryGroups, group)
        end
    end
    return categoryGroups
end

local function ApplyStaticMetadata(result, static)
    result.itemName     = static.itemName
    result.iconID       = static.iconID
    result.outputItemID = static.outputItemID
    result.categoryID   = static.categoryID
end

local function SortResultsByCategory(results, categoryOrder)
    table.sort(results, function(a, b)
        if (a.categoryID or 0) == (b.categoryID or 0) then
            return (a.itemName or "") < (b.itemName or "")
        end
        local aOrder, bOrder = 0, 0
        for index, catID in ipairs(categoryOrder) do
            if catID == (a.categoryID or 0) then aOrder = index end
            if catID == (b.categoryID or 0) then bOrder = index end
        end
        return aOrder < bOrder
    end)
end

local function BuildFullRows(self, results)
    local categoryOrder = {}
    local categoryMeta  = {}
    local staticByConfigID = {}

    for _, r in ipairs(results) do
        local recipeInfo = C_TradeSkillUI.GetRecipeInfo(r.config.recipeID)
        local iconID, outputItemID = ResolveIconAndOutputItemID(r.config.recipeID, recipeInfo)
        local catID = (recipeInfo and recipeInfo.categoryID) or 0

        local static = {
            itemName     = (recipeInfo and recipeInfo.name) or "Unknown",
            iconID       = iconID,
            outputItemID = outputItemID,
            categoryID   = catID,
        }
        staticByConfigID[r.config.configID] = static
        ApplyStaticMetadata(r, static)

        if not categoryMeta[catID] then
            categoryMeta[catID] = {
                catName     = GetCategoryName(catID),
                expansionID = r.config.expansionID,
            }
            table.insert(categoryOrder, catID)
        end
    end

    SortResultsByCategory(results, categoryOrder)

    self.staticCache = {
        staticByConfigID = staticByConfigID,
        categoryOrder    = categoryOrder,
        categoryMeta     = categoryMeta,
        configCount      = #results,
    }
end

local function StaticCacheMatches(cache, charGUID, profID, results)
    if not cache or cache.charGUID ~= charGUID or cache.profID ~= profID then
        return false, "context"
    end
    if cache.configCount ~= #results then
        return false, "count-mismatch"
    end
    local staticByConfigID = cache.staticByConfigID or {}
    for _, result in ipairs(results or {}) do
        if not staticByConfigID[result.config and result.config.configID] then
            return false, "missing-config"
        end
    end
    return true
end

-- Returns a list of category groups ready for InventoryManagerWindow:Render().
-- Each group: { label, expansionID, results[] }
-- Each result is the InventoryTargetEvaluator result augmented with static display metadata.
--
-- showZeroDeficit: include results where deficit == 0
-- currentExpFilter: nil = all expansions; integer = filter to that expansionID
function QueueGeneration:GenerateRows(charGUID, profID, showZeroDeficit, currentExpFilter)
    local startedAt = DebugTime()
    local targetEvaluator = PocketCFO_Crafting:GetModule("InventoryTargetEvaluator", true)
    if not targetEvaluator then return {} end

    local results = targetEvaluator:Calculate(charGUID, profID)
    local cacheOk, cacheMissReason = StaticCacheMatches(self.staticCache, charGUID, profID, results)
    if cacheOk then
        for _, result in ipairs(results) do
            ApplyStaticMetadata(result, self.staticCache.staticByConfigID[result.config.configID])
        end
        SortResultsByCategory(results, self.staticCache.categoryOrder)
    else
        BuildFullRows(self, results)
        self.staticCache.charGUID = charGUID
        self.staticCache.profID   = profID
    end
    local categoryGroups = BuildCategoryGroups(
        results,
        self.staticCache.categoryOrder,
        self.staticCache.categoryMeta,
        showZeroDeficit,
        currentExpFilter
    )
    LogTiming("QueueGeneration:GenerateRows", startedAt, string.format(
        "cacheHit=%s%s results=%d groups=%d",
        tostring(cacheOk),
        cacheOk and "" or (" miss=" .. tostring(cacheMissReason)),
        #results,
        #categoryGroups
    ))
    return categoryGroups
end

function QueueGeneration:GenerateInventoryRows(charGUID, profID, showZeroDeficit, currentExpFilter)
    local startedAt = DebugTime()
    local targetEvaluator = PocketCFO_Crafting:GetModule("InventoryTargetEvaluator", true)
    if not targetEvaluator then return {}, "no-evaluator" end

    local results = targetEvaluator:Calculate(charGUID, profID)
    local ok, reason = StaticCacheMatches(self.staticCache, charGUID, profID, results)
    if not ok then
        LogTiming("QueueGeneration:GenerateRows", startedAt, "mode=inventory cacheMiss=" .. tostring(reason))
        return nil, reason
    end

    for _, result in ipairs(results) do
        ApplyStaticMetadata(result, self.staticCache.staticByConfigID[result.config.configID])
    end

    local categoryGroups = BuildCategoryGroups(
        results,
        self.staticCache.categoryOrder,
        self.staticCache.categoryMeta,
        showZeroDeficit,
        currentExpFilter
    )
    LogTiming("QueueGeneration:GenerateRows", startedAt, string.format(
        "mode=inventory results=%d groups=%d",
        #results,
        #categoryGroups
    ))
    return categoryGroups
end
