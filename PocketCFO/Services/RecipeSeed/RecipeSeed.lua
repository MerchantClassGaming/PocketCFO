-- PocketCFO/Services/RecipeSeed/RecipeSeed.lua
-- Which recipes make an item, for every profession, without anyone opening a
-- profession window (Brian, 2026-11-06). Used by smart AH posting so a fresh
-- install knows crafted items are crafted (Cost to Make floor and estimate).
--
-- Two sources, merged:
--   1. Shipped seed: PocketCFO_RecipeSeedLive (RecipeSeedLive.lua, generated
--      from the developer's install by MCG_Diagnostic RecipeSeedExport and
--      the git pre-commit hook). Output itemID -> recipeIDs, all professions.
--   2. Live RecipeRegistry: anything this account's profession windows list.
--      Self-heal: a recipe added in a patch after the seed was built is
--      picked up the first time any character opens that profession, and the
--      developer's export adds it to the next release.
--
-- Mats are NOT shipped: C_TradeSkillUI.GetRecipeSchematic gives the current
-- mat list for any recipeID (confirmed 2026-11-06), so it never goes stale.
--
-- Separate from RecipeRegistry on purpose: the registry means "recipes this
-- account's professions list" (ownership; its harvest removes recipes a
-- window no longer shows), so the seed must not be written into it.
-- Flavor: Retail-only (loaded by PocketCFO.toc only).
--
-- Quality conversions are not crafts (Brian, 2026-11-06): a recipe whose
-- materials include an item with the same name as its output (miner's
-- refining: 5 Bismuth Q1 -> 1 Bismuth Q2) is left out of every lookup here.
-- Otherwise a gathered mat gets a Cost to Make (Bismuth Q2 "34g estimate",
-- floor and max both 37.41g). May come back later as a special case.

local PocketCFO = _G.PocketCFO

local RecipeSeed = {}

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function NormalizeID(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function ItemName(itemID)
    if not itemID or type(GetItemInfo) ~= "function" then
        return nil
    end
    local ok, name = pcall(GetItemInfo, itemID)
    if ok and type(name) == "string" and name ~= "" then
        return name:lower()
    end
    return nil
end

-- recipeID -> true (conversion) | false (real craft). Session only, and only
-- definite answers: a recipe whose names weren't loaded yet is asked again.
local conversionCache = {}

-- True when any material of the recipe has the output's name. Names come from
-- GetItemInfo; a material whose data isn't loaded yet can't be compared, so
-- the recipe counts as a real craft this time (not cached) and its data is
-- requested. At the AH, SmartPricing:PrewarmMats loads every material of
-- every craftable bag item before the list is built, so names are normally
-- there. Theoretical until checked in game: Bismuth / Aqirite drop out.
function RecipeSeed:IsConversionRecipe(recipeID, outputItemID, outputName)
    recipeID = NormalizeID(recipeID)
    if not recipeID then
        return false
    end
    if conversionCache[recipeID] ~= nil then
        return conversionCache[recipeID]
    end
    if not C_TradeSkillUI or type(C_TradeSkillUI.GetRecipeSchematic) ~= "function" then
        return false
    end
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then
        return false
    end
    local name = ItemName(NormalizeID(outputItemID)) or ItemName(NormalizeID(schematic.outputItemID))
        or (type(outputName) == "string" and outputName ~= "" and outputName:lower() or nil)
    if not name then
        return false
    end
    local unknown = false
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        for _, reagent in ipairs(type(slot.reagents) == "table" and slot.reagents or {}) do
            local matID = NormalizeID(reagent.itemID)
            if matID then
                local matName = ItemName(matID)
                if matName == name then
                    conversionCache[recipeID] = true
                    return true
                elseif not matName then
                    unknown = true
                    if C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
                        pcall(C_Item.RequestLoadItemDataByID, matID)
                    end
                end
            end
        end
    end
    if not unknown then
        conversionCache[recipeID] = false
    end
    return false
end

local function SeedOutputs()
    local seed = _G.PocketCFO_RecipeSeedLive
    return type(seed) == "table" and type(seed.outputs) == "table" and seed.outputs or nil
end

local function AddRecipes(set, recipes)
    if type(recipes) ~= "table" then
        return
    end
    for key, value in pairs(recipes) do
        -- Seed rows are { [recipeID] = true }; registry returns an array.
        local recipeID = NormalizeID(value == true and key or value)
        if recipeID then
            set[recipeID] = true
        end
    end
end

-- Returns an array of recipeIDs that make the item (sorted), or {}.
function RecipeSeed:GetRecipeIDsForOutput(itemID, itemName)
    itemID = NormalizeID(itemID)
    local set = {}
    local outputs = SeedOutputs()
    if itemID and outputs then
        AddRecipes(set, outputs[itemID])
    end
    local registry = PocketCFO and PocketCFO.RecipeRegistry
    if registry and type(registry.GetRecipeIDsForOutput) == "function" then
        local ok, recipeIDs = pcall(registry.GetRecipeIDsForOutput, registry, itemID, itemName)
        if ok then
            AddRecipes(set, recipeIDs)
        end
    end
    local result = {}
    for recipeID in pairs(set) do
        if not self:IsConversionRecipe(recipeID, itemID, itemName) then
            result[#result + 1] = recipeID
        end
    end
    table.sort(result)
    return result
end

-- Anyone can craft it (seed or this account's professions).
function RecipeSeed:IsCraftable(itemID, itemName)
    return #self:GetRecipeIDsForOutput(itemID, itemName) > 0
end

-- One of this account's characters can craft it (live registry only).
-- Quality conversions don't count (2026-11-06).
function RecipeSeed:IsOurs(itemID, itemName)
    local registry = PocketCFO and PocketCFO.RecipeRegistry
    if not registry or type(registry.GetRecipeIDsForOutput) ~= "function" then
        return false
    end
    local ok, recipeIDs = pcall(registry.GetRecipeIDsForOutput, registry, itemID, itemName)
    if not ok or type(recipeIDs) ~= "table" then
        return false
    end
    for _, recipeID in ipairs(recipeIDs) do
        if not self:IsConversionRecipe(recipeID, itemID, itemName) then
            return true
        end
    end
    return false
end

-- Diagnostics: number of output items in the shipped seed.
function RecipeSeed:SeedCount()
    local count = 0
    for _ in pairs(SeedOutputs() or {}) do
        count = count + 1
    end
    return count
end

if PocketCFO then
    PocketCFO.RecipeSeed = RecipeSeed
end
_G.PocketCFO_RecipeSeed = RecipeSeed
