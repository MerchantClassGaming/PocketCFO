-- PocketCFO/Services/RecipeRegistry/RecipeRegistry.lua
-- Shared account-wide source of truth for recipe output ownership.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local RecipeRegistry = PocketCFO:NewModule("RecipeRegistry", "AceEvent-3.0")
PocketCFO.RecipeRegistry = RecipeRegistry

local function NormalizeID(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end

    local ok, result = pcall(fn, ...)
    if ok then
        return result
    end
    return nil
end

local function AddRecipeID(target, recipeID)
    recipeID = NormalizeID(recipeID)
    if recipeID then
        target[recipeID] = true
    end
end

local function AddRecipeFromElement(target, element)
    if type(element) ~= "table" then
        return
    end

    AddRecipeID(target, element.recipeID)
    AddRecipeID(target, element.recipeInfo and element.recipeInfo.recipeID)
    AddRecipeID(target, element.data and element.data.recipeID)
    AddRecipeID(target, element.data and element.data.recipeInfo and element.data.recipeInfo.recipeID)
end

local function ForEachArray(value, callback)
    if type(value) ~= "table" then
        return
    end

    for _, entry in ipairs(value) do
        callback(entry)
    end
end

local function GetItemNameFromItemID(itemID)
    itemID = NormalizeID(itemID)
    if itemID and GetItemInfo then
        local itemName = GetItemInfo(itemID)
        return itemName
    end
    return nil
end

local function CountTableKeys(value)
    local count = 0
    for _ in pairs(value or {}) do
        count = count + 1
    end
    return count
end

local function GetProfessionContextService()
    local crafting = _G.PocketCFO_Crafting
    if crafting and crafting.GetModule then
        return crafting:GetModule("ProfessionContextService", true)
    end
    return nil
end

function RecipeRegistry:NormalizeItemName(name)
    name = tostring(name or "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("%s+[Qq]%d+$", "")
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        return nil
    end
    return name:lower()
end

function RecipeRegistry:RebuildIndexes()
    if not self.db or type(self.db.recipesByID) ~= "table" then
        return
    end

    self.db.outputsByItemID = {}
    self.db.outputsByName = {}

    for recipeID, recipe in pairs(self.db.recipesByID) do
        if type(recipe) == "table" then
            local outputItemID = NormalizeID(recipe.outputItemID)
            if outputItemID then
                self.db.outputsByItemID[outputItemID] = self.db.outputsByItemID[outputItemID] or {}
                self.db.outputsByItemID[outputItemID][tonumber(recipeID) or recipeID] = true
            end

            local outputItemName = recipe.outputItemName or GetItemNameFromItemID(outputItemID)
            local normalizedName = self:NormalizeItemName(outputItemName)
            if normalizedName then
                recipe.outputItemName = outputItemName
                self.db.outputsByName[normalizedName] = self.db.outputsByName[normalizedName] or {}
                self.db.outputsByName[normalizedName][tonumber(recipeID) or recipeID] = true
            end
        end
    end
end

function RecipeRegistry:RebuildOutputNameIndex()
    self:RebuildIndexes()
end

function RecipeRegistry:Initialize()
    local globalDB = PocketCFO and PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return
    end

    globalDB.recipeRegistry = globalDB.recipeRegistry or {}
    self.db = globalDB.recipeRegistry
    self.db.outputsByItemID = self.db.outputsByItemID or {}
    self.db.outputsByName = self.db.outputsByName or {}
    self.db.recipesByID = self.db.recipesByID or {}
    self.db.refreshByProfession = self.db.refreshByProfession or {}
    self:RebuildIndexes()
end

function RecipeRegistry:OnInitialize()
    self:Initialize()
end

function RecipeRegistry:OnEnable()
    self.pendingRefreshByProfession = self.pendingRefreshByProfession or {}
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
end

function RecipeRegistry:GetRefreshDay()
    local now = PocketCFO and PocketCFO.GetServerNow and PocketCFO:GetServerNow() or time()
    return date("%Y-%m-%d", now)
end

function RecipeRegistry:GetProfessionKey(metadata)
    metadata = type(metadata) == "table" and metadata or self:GetProfessionMetadata()
    local professionID = NormalizeID(metadata.professionID)
    if professionID then
        return "id:" .. tostring(professionID)
    end
    if metadata.professionName and metadata.professionName ~= "" then
        return "name:" .. tostring(metadata.professionName):lower()
    end
    return "unknown"
end

function RecipeRegistry:RecipeBelongsToProfession(recipe, metadata, professionKey)
    if type(recipe) ~= "table" then
        return false
    end

    if recipe.professionKey then
        return recipe.professionKey == professionKey
    end

    local professionID = NormalizeID(metadata and metadata.professionID)
    if professionID and NormalizeID(recipe.professionID) == professionID then
        return true
    end

    local professionName = metadata and metadata.professionName
    return professionName ~= nil and recipe.professionName == professionName
end

function RecipeRegistry:OnTradeSkillShow()
    self:Initialize()
    if not self.db then
        return
    end

    local metadata = self:GetProfessionMetadata()
    local professionKey = self:GetProfessionKey(metadata)
    local refreshDay = self:GetRefreshDay()
    if self.db.refreshByProfession[professionKey] == refreshDay
    or self.pendingRefreshByProfession[professionKey] == refreshDay then
        return
    end

    self.pendingRefreshByProfession[professionKey] = refreshDay
    if C_Timer and C_Timer.After then
        C_Timer.After(0.25, function()
            self:HarvestVisibleRecipes()
            if self.pendingRefreshByProfession then
                self.pendingRefreshByProfession[professionKey] = nil
            end
        end)
    else
        self:HarvestVisibleRecipes()
        self.pendingRefreshByProfession[professionKey] = nil
    end
end

function RecipeRegistry:GetDB()
    if not self.db then
        self:Initialize()
    end
    return self.db
end

function RecipeRegistry:GetRecipeRecord(recipeID)
    recipeID = NormalizeID(recipeID)
    local db = self:GetDB()
    if not recipeID or not db or type(db.recipesByID) ~= "table" then
        return nil
    end
    return db.recipesByID[recipeID] or db.recipesByID[tostring(recipeID)]
end

function RecipeRegistry:IsRecipeOutputItem(itemID, itemName)
    itemID = NormalizeID(itemID)
    local db = self:GetDB()
    if not db then
        return false
    end

    if itemID then
        local recipes = db.outputsByItemID and db.outputsByItemID[itemID]
        if type(recipes) == "table" and next(recipes) ~= nil then
            return true
        end
    end

    local normalizedName = self:NormalizeItemName(itemName)
    local recipesByName = normalizedName and db.outputsByName and db.outputsByName[normalizedName] or nil
    return type(recipesByName) == "table" and next(recipesByName) ~= nil
end

function RecipeRegistry:GetRecipeIDsForOutput(itemID, itemName)
    itemID = NormalizeID(itemID)
    local db = self:GetDB()
    local source = itemID and db and db.outputsByItemID and db.outputsByItemID[itemID] or nil
    local normalizedName = self:NormalizeItemName(itemName)
    local recipeIDs = {}

    if type(source) == "table" then
        for recipeID in pairs(source) do
            recipeIDs[recipeID] = true
        end
    end

    source = normalizedName and db and db.outputsByName and db.outputsByName[normalizedName] or nil
    if type(source) == "table" then
        for recipeID in pairs(source) do
            recipeIDs[recipeID] = true
        end
    end

    local result = {}
    for recipeID in pairs(recipeIDs) do
        result[#result + 1] = tonumber(recipeID) or recipeID
    end
    table.sort(result, function(a, b)
        return tostring(a) < tostring(b)
    end)
    return result
end

function RecipeRegistry:GetOutputItemID(recipeID)
    recipeID = NormalizeID(recipeID)
    local recipe = self:GetRecipeRecord(recipeID)
    return NormalizeID(recipe and recipe.outputItemID)
end

function RecipeRegistry:LearnRecipe(recipeID, outputItemID, metadata)
    recipeID = NormalizeID(recipeID)
    outputItemID = NormalizeID(outputItemID)
    if not recipeID or not outputItemID then
        return false
    end

    local db = self:GetDB()
    if not db then
        return false
    end

    metadata = type(metadata) == "table" and metadata or {}
    if type(self:GetRecipeRecord(recipeID)) == "table" then
        return false
    end

    db.recipesByID[recipeID] = {
        recipeID = recipeID,
        outputItemID = outputItemID,
        outputItemName = metadata.outputItemName or GetItemNameFromItemID(outputItemID),
        professionID = metadata.professionID,
        professionName = metadata.professionName,
        professionKey = self:GetProfessionKey(metadata),
        recipeName = metadata.recipeName,
    }

    return true
end

function RecipeRegistry:GetProfessionMetadata()
    local metadata = {}
    local contextService = GetProfessionContextService()
    local context = contextService and contextService.GetCurrentProfessionContext
        and contextService:GetCurrentProfessionContext() or nil
    if type(context) == "table" then
        metadata.professionID = context.professionID
        metadata.professionName = context.professionName
    end
    return metadata
end

function RecipeRegistry:GetRecipeOutputItemID(recipeID)
    if not C_TradeSkillUI then
        return nil
    end

    local outputData = SafeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
    if type(outputData) == "table" then
        local itemID = NormalizeID(outputData.itemID)
        if itemID then
            return itemID
        end
    end

    local schematic = SafeCall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if type(schematic) == "table" then
        return NormalizeID(schematic.outputItemID or schematic.itemID or schematic.outputItemInfo and schematic.outputItemInfo.itemID)
    end

    return nil
end

function RecipeRegistry:GetOutputItemName(outputItemID, recipeID)
    outputItemID = NormalizeID(outputItemID)
    local itemName = GetItemNameFromItemID(outputItemID)
    if itemName then
        return itemName
    end

    if recipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeOutputItemData then
        local outputData = SafeCall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        if type(outputData) == "table" then
            return outputData.itemName or outputData.name
        end
    end

    return nil
end

function RecipeRegistry:GetRecipeName(recipeID)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeInfo then
        return nil
    end

    local recipeInfo = SafeCall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    if type(recipeInfo) == "table" then
        return recipeInfo.name
    end
    return nil
end

function RecipeRegistry:CollectVisibleRecipeIDs()
    local recipeIDs = {}

    if C_TradeSkillUI then
        ForEachArray(SafeCall(C_TradeSkillUI.GetAllRecipeIDs), function(recipeID)
            AddRecipeID(recipeIDs, recipeID)
        end)

        ForEachArray(SafeCall(C_TradeSkillUI.GetFilteredRecipeIDs), function(recipeID)
            AddRecipeID(recipeIDs, recipeID)
        end)
    end

    local contextService = GetProfessionContextService()
    local currentRecipeID = contextService and contextService.GetCurrentRecipeID
        and contextService:GetCurrentRecipeID() or nil
    AddRecipeID(recipeIDs, currentRecipeID)

    local recipeList = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.RecipeList
    local scrollBox = recipeList and recipeList.ScrollBox
    local dataProvider = scrollBox and scrollBox.GetDataProvider and scrollBox:GetDataProvider()
    if dataProvider and dataProvider.ForEach then
        SafeCall(function()
            dataProvider:ForEach(function(element)
                AddRecipeFromElement(recipeIDs, element)
            end)
        end)
    end

    return recipeIDs
end

function RecipeRegistry:HarvestVisibleRecipes()
    if not C_TradeSkillUI then
        return {
            added = 0,
            removed = 0,
            found = 0,
            migrated = 0,
        }
    end

    self:Initialize()
    if not self.db then
        return {
            added = 0,
            removed = 0,
            found = 0,
            migrated = 0,
        }
    end

    local metadata = self:GetProfessionMetadata()
    local professionKey = self:GetProfessionKey(metadata)
    local refreshDay = self:GetRefreshDay()
    local foundRecipes = {}
    local newlyAdded = {}
    local added = 0
    local removed = 0

    for recipeID in pairs(self:CollectVisibleRecipeIDs()) do
        local outputItemID = self:GetRecipeOutputItemID(recipeID)
        if outputItemID then
            recipeID = NormalizeID(recipeID)
            if recipeID then
                foundRecipes[recipeID] = true

                if type(self:GetRecipeRecord(recipeID)) ~= "table" then
                    local recipeMetadata = {
                        professionID = metadata.professionID,
                        professionName = metadata.professionName,
                        recipeName = self:GetRecipeName(recipeID),
                        outputItemName = self:GetOutputItemName(outputItemID, recipeID),
                    }
                    if self:LearnRecipe(recipeID, outputItemID, recipeMetadata) then
                        added = added + 1
                        newlyAdded[#newlyAdded + 1] = self:GetRecipeRecord(recipeID)
                    end
                end
            end
        end
    end

    for recipeID, recipe in pairs(self.db.recipesByID) do
        if type(recipe) == "table" and self:RecipeBelongsToProfession(recipe, metadata, professionKey)
        and not foundRecipes[NormalizeID(recipeID)] then
            self.db.recipesByID[recipeID] = nil
            removed = removed + 1
        end
    end

    self:RebuildIndexes()
    self.db.refreshByProfession[professionKey] = refreshDay

    local migrated = 0
    if #newlyAdded > 0 then
        local updater = PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("RecipeOwnershipUpdater", true) or nil
        if updater and updater.ReconcileRecipes then
            migrated = updater:ReconcileRecipes(newlyAdded) or 0
        end
    end

    if PocketCFO and PocketCFO.AppendSessionLog then
        PocketCFO:AppendSessionLog(string.format(
            "[MCG] RecipeRegistry refresh profession=%s found=%d added=%d removed=%d migrated=%d",
            tostring(metadata.professionName or metadata.professionID or "unknown"),
            CountTableKeys(foundRecipes),
            added,
            removed,
            migrated
        ))
    end

    return {
        added = added,
        removed = removed,
        found = CountTableKeys(foundRecipes),
        migrated = migrated,
    }
end
