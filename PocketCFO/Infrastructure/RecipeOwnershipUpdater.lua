-- PocketCFO/Infrastructure/RecipeOwnershipUpdater.lua
-- Migrates Item Rules into Recipe Rules after RecipeRegistry adds new recipes.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local RecipeOwnershipUpdater = PocketCFO:NewModule("RecipeOwnershipUpdater")
PocketCFO.RecipeOwnershipUpdater = RecipeOwnershipUpdater

local function Debug(msg, ...)
    if PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug(msg, ...)
    end
end

local function NormalizeID(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function NormalizeQuality(value)
    value = tonumber(value)
    if value and value > 0 then
        return math.floor(value + 0.5)
    end
    return nil
end

local function CopyTableShallow(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function GetAHPostingConfig()
    local ah = _G.PocketCFO_AH
    if not ah or not ah.GetModule then
        return nil
    end
    return ah:GetModule("PostingRuleResolver", true)
end

local function GetRecipeRegistry()
    if PocketCFO and PocketCFO.GetModule then
        return PocketCFO:GetModule("RecipeRegistry", true)
    end
    return nil
end

local function GetRuleQuality(rule)
    return NormalizeQuality(rule and (rule.craftingQuality or rule.qualityTier or rule.itemQuality or rule.quality))
end

local function GetRuleItemID(rule, itemKey)
    local itemID = NormalizeID(rule and (rule.itemID or rule.outputItemID or rule.targetItemID))
    if itemID then
        return itemID
    end
    if type(itemKey) == "number" then
        return NormalizeID(itemKey)
    end
    if type(itemKey) == "string" then
        return NormalizeID(itemKey:match("^(%d+)") or itemKey:match("^item:(%d+)"))
    end
    return nil
end

local function RecipeRuleExists(recipeRules, recipeID)
    return recipeRules[tostring(recipeID)] ~= nil or recipeRules[recipeID] ~= nil
end

local function GetRecipeTargetCount(registry, outputItemID, outputItemName)
    if not registry or not registry.GetRecipeIDsForOutput then
        return 1
    end
    local recipeIDs = registry:GetRecipeIDsForOutput(outputItemID, outputItemName)
    if type(recipeIDs) ~= "table" then
        return 1
    end
    return #recipeIDs
end

local function RuleMatchesOutput(registry, itemKey, rule, outputItemID, outputItemName)
    local ruleItemID = GetRuleItemID(rule, itemKey)
    if not ruleItemID then
        return false
    end

    if ruleItemID == outputItemID then
        return true
    end

    local ruleName = rule and (rule.itemName or rule.outputItemName or rule.targetItemName)
    local normalizedRuleName = registry and registry.NormalizeItemName and registry:NormalizeItemName(ruleName) or nil
    local normalizedOutputName = registry and registry.NormalizeItemName and registry:NormalizeItemName(outputItemName) or nil
    return normalizedRuleName ~= nil and normalizedRuleName == normalizedOutputName
end

function RecipeOwnershipUpdater:FindMatchingItemRules(nonCraftedRules, outputItemID, outputItemName)
    local registry = GetRecipeRegistry()
    local matches = {}

    for itemKey, rule in pairs(nonCraftedRules or {}) do
        if type(rule) == "table" and RuleMatchesOutput(registry, itemKey, rule, outputItemID, outputItemName) then
            matches[#matches + 1] = {
                itemKey = tostring(itemKey),
                rawItemKey = itemKey,
                rule = rule,
                quality = GetRuleQuality(rule),
            }
        end
    end

    return matches
end

function RecipeOwnershipUpdater:BuildRecipeRule(recipeID, itemRule, itemKey, outputItemID, outputItemName)
    local recipeRule = CopyTableShallow(itemRule)
    recipeRule.recipeID = NormalizeID(recipeID)
    recipeRule.itemID = NormalizeID(itemRule.itemID) or NormalizeID(outputItemID)
    recipeRule.outputItemID = NormalizeID(outputItemID) or recipeRule.outputItemID
    recipeRule.itemName = itemRule.itemName or outputItemName
    recipeRule.outputItemName = itemRule.outputItemName or outputItemName
    recipeRule.itemKey = itemRule.itemKey or itemKey
    recipeRule.craftingQuality = GetRuleQuality(itemRule)
    return recipeRule
end

function RecipeOwnershipUpdater:OnRecipeOutputLearned(recipeID, outputItemID, metadata)
    recipeID = NormalizeID(recipeID)
    outputItemID = NormalizeID(outputItemID)
    if not recipeID or not outputItemID then
        return false, "missingIdentity"
    end

    local config = GetAHPostingConfig()
    if not config or not config.GetRecipeRulesDB or not config.GetNonCraftedRulesDB then
        return false, "postingConfigUnavailable"
    end

    local recipeRules = config:GetRecipeRulesDB()
    if RecipeRuleExists(recipeRules, recipeID) then
        return false, "recipeRuleExists"
    end

    local outputItemName = type(metadata) == "table" and metadata.outputItemName or nil
    local registry = GetRecipeRegistry()
    local targetCount = GetRecipeTargetCount(registry, outputItemID, outputItemName)
    if targetCount > 1 then
        return false, "ambiguousRecipeTarget"
    end

    local matches = self:FindMatchingItemRules(config:GetNonCraftedRulesDB(), outputItemID, outputItemName)
    if #matches == 0 then
        return false, "noItemRule"
    end
    if #matches > 1 then
        return false, "ambiguousMatch"
    end

    local match = matches[1]
    if not match.quality then
        return false, "unknownQuality"
    end

    local nonCraftedRules = config:GetNonCraftedRulesDB()
    local recipeKey = tostring(recipeID)
    recipeRules[recipeKey] = self:BuildRecipeRule(recipeID, match.rule, match.itemKey, outputItemID, outputItemName)
    nonCraftedRules[match.rawItemKey] = nil
    nonCraftedRules[match.itemKey] = nil

    Debug("RecipeOwnershipUpdater: migrated item rule to recipe rule itemKey=%s recipeID=%s outputItemID=%s quality=%s",
        tostring(match.itemKey), tostring(recipeID), tostring(outputItemID), tostring(match.quality))
    return true
end

function RecipeOwnershipUpdater:ReconcileRecipes(recipes)
    if type(recipes) ~= "table" then
        return 0
    end

    local migrated = 0
    for _, recipe in ipairs(recipes) do
        if type(recipe) == "table" and self:OnRecipeOutputLearned(recipe.recipeID, recipe.outputItemID, recipe) then
            migrated = migrated + 1
        end
    end
    return migrated
end

function RecipeOwnershipUpdater:ReconcileAllKnownOutputs()
    local registry = GetRecipeRegistry()
    local db = registry and registry.GetDB and registry:GetDB() or nil
    if not db or type(db.recipesByID) ~= "table" then
        return 0
    end

    local recipes = {}
    for recipeID, recipe in pairs(db.recipesByID) do
        if type(recipe) == "table" then
            local queuedRecipe = CopyTableShallow(recipe)
            queuedRecipe.recipeID = queuedRecipe.recipeID or recipeID
            recipes[#recipes + 1] = queuedRecipe
        end
    end
    return self:ReconcileRecipes(recipes)
end
