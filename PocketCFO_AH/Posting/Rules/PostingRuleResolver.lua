-- PocketCFO_AH/Posting/Rules/PostingRuleResolver.lua
-- Resolves saved posting rules into effective read-only rule tables.

local ADDON_NAME, _ = ...
local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingRuleResolver = PocketCFO_AH:NewModule("PostingRuleResolver")

local COPPER_FIELDS = {
    minPrice = true,
    normalPrice = true,
    maxPrice = true,
    fallbackPrice = true,
    undercutAmount = true,
    postPrice = true,
    intendedPostPrice = true,
    minProfitGold = true,
}

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function CopyTableShallow(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function Copper(value)
    value = tonumber(value)
    if not value or value < 0 then
        return nil
    end
    return math.floor(value + 0.5)
end

local function NormalizeMode(mode)
    mode = tostring(mode or "none"):lower()
    if mode ~= "profile" and mode ~= "custom" then
        return "none"
    end
    return mode
end

local function NormalizeRuleValues(values)
    local normalized = CopyTableShallow(values)
    for field in pairs(COPPER_FIELDS) do
        if normalized[field] ~= nil then
            normalized[field] = Copper(normalized[field]) or 0
        end
    end
    if normalized.minProfitPct ~= nil then
        normalized.minProfitPct = tonumber(normalized.minProfitPct)
    end
    if normalized.targetPosted ~= nil then
        normalized.targetPosted = math.max(0, math.floor(tonumber(normalized.targetPosted) or 0))
    end
    return normalized
end

local function GlobalDB()
    return PocketCFO_AH.db and PocketCFO_AH.db.global or {}
end

local function CurrentOwnerKey()
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.char
        and PocketCFO.db.char.characterGUID
        or nil
end

local function CurrentOwnerName()
    if UnitFullName then
        local name, realm = UnitFullName("player")
        if name and realm and realm ~= "" then
            return name .. "-" .. realm
        end
        return name
    end
    if UnitName then
        return UnitName("player")
    end
    return nil
end

local function RuleRoot(rootName)
    local db = GlobalDB()
    db[rootName] = db[rootName] or {}
    return db[rootName]
end

function PostingRuleResolver:GetRecipeRulesDB()
    return RuleRoot("recipePostingRules")
end

function PostingRuleResolver:GetNonCraftedRulesDB()
    return RuleRoot("nonCraftedPostingRules")
end

function PostingRuleResolver:GetSettingsDB()
    local db = GlobalDB()
    db.postingSettings = db.postingSettings or {}
    return db.postingSettings
end

function PostingRuleResolver:NormalizeRule(rule, sourceType, sourceKey)
    if type(rule) ~= "table" then
        return nil, "missingRule"
    end

    local mode = NormalizeMode(rule.mode)
    if mode == "none" then
        return nil, "modeNone"
    end

    local effective
    if mode == "profile" then
        local profiles = PocketCFO_AH:GetModule("PostingProfileRepository", true)
        local profileKey = rule.profileKey or rule.profileID or rule.profile
        local profile = profiles and profiles:GetProfile(profileKey)
        if not profile then
            return nil, "missingProfile"
        end
        effective = NormalizeRuleValues(profile)
        effective.profileID = profile.profileID or profile.profileKey or profileKey
        effective.profileKey = effective.profileID
    elseif mode == "custom" then
        if type(rule.custom) ~= "table" then
            return nil, "missingCustom"
        end
        effective = NormalizeRuleValues(rule.custom)
    end

    if not effective then
        return nil, "unresolved"
    end

    effective.mode = mode
    effective.sourceType = sourceType
    effective.sourceKey = tostring(sourceKey or "")
    effective.ruleKey = tostring(sourceKey or "")
    effective.matchingPath = rule.matchingPath or effective.matchingPath
    effective.itemID = tonumber(rule.itemID or rule.outputItemID or rule.targetItemID or effective.itemID)
    effective.outputItemID = tonumber(rule.outputItemID or rule.itemID or rule.targetItemID or effective.outputItemID)
    effective.targetItemID = tonumber(rule.targetItemID or rule.itemID or rule.outputItemID or effective.targetItemID)
    effective.itemName = rule.itemName or rule.outputItemName or rule.targetItemName or effective.itemName
    effective.outputItemName = rule.outputItemName or rule.itemName or rule.targetItemName or effective.outputItemName
    effective.targetItemName = rule.targetItemName or rule.itemName or rule.outputItemName or effective.targetItemName
    effective.itemLink = rule.itemLink or rule.outputItemLink or effective.itemLink
    effective.outputItemLink = rule.outputItemLink or rule.itemLink or effective.outputItemLink
    effective.itemKey = rule.itemKey or effective.itemKey
    effective.craftingQuality = tonumber(rule.craftingQuality or rule.qualityTier or rule.itemQuality or effective.craftingQuality)
    effective.itemQuality = tonumber(rule.itemQuality or rule.craftingQuality or rule.qualityTier or effective.itemQuality)
    effective.qualityTier = tonumber(rule.qualityTier or rule.craftingQuality or rule.itemQuality or effective.qualityTier)
    effective.effectiveItemLevel = tonumber(rule.effectiveItemLevel or rule.itemLevel or rule.ilvl or rule.targetIlvl or effective.effectiveItemLevel or effective.itemLevel or effective.ilvl)
    effective.itemLevel = tonumber(rule.itemLevel or rule.ilvl or rule.targetIlvl or effective.itemLevel or effective.effectiveItemLevel)
    effective.ilvl = tonumber(rule.ilvl or rule.itemLevel or rule.targetIlvl or effective.ilvl or effective.effectiveItemLevel)
    effective.targetIlvl = tonumber(rule.targetIlvl or rule.effectiveItemLevel or rule.itemLevel or rule.ilvl or effective.targetIlvl or effective.effectiveItemLevel)
    effective.statTarget = rule.statTarget or rule.statFingerprint or rule.statKey or effective.statTarget or effective.statFingerprint
    effective.statFingerprint = rule.statFingerprint or rule.statTarget or rule.statKey or effective.statFingerprint or effective.statTarget
    effective.statKey = rule.statKey or rule.statFingerprint or rule.statTarget or effective.statKey
    effective.recipeID = tonumber(rule.recipeID or sourceKey) or effective.recipeID
    effective.owner = rule.owner or CurrentOwnerKey()
    effective.ownerName = rule.ownerName or CurrentOwnerName()
    effective.readOnly = true

    return effective, nil
end

function PostingRuleResolver:GetEffectiveRecipeRule(recipeID)
    if recipeID == nil or recipeID == "" then
        return nil, "missingRecipeID"
    end
    local key = tostring(recipeID)
    local rule = self:GetRecipeRulesDB()[key] or self:GetRecipeRulesDB()[tonumber(recipeID)]
    local sourceKey = rule and (rule.recipeID or key) or key
    return self:NormalizeRule(rule, "recipe", sourceKey)
end

function PostingRuleResolver:GetEffectiveNonCraftedRule(itemKey)
    if itemKey == nil or itemKey == "" then
        return nil, "missingItemKey"
    end
    local key = tostring(itemKey)
    return self:NormalizeRule(self:GetNonCraftedRulesDB()[key], "noncrafted", key)
end

function PostingRuleResolver:IsConfigured(itemKeyOrRecipeID)
    if itemKeyOrRecipeID == nil or itemKeyOrRecipeID == "" then
        return false
    end

    local key = tostring(itemKeyOrRecipeID)
    local recipeRule = self:GetRecipeRulesDB()[key] or self:GetRecipeRulesDB()[tonumber(itemKeyOrRecipeID)]
    if self:NormalizeRule(recipeRule, "recipe", key) then
        return true
    end

    local nonCraftedRule = self:GetNonCraftedRulesDB()[key]
    if self:NormalizeRule(nonCraftedRule, "noncrafted", key) then
        return true
    end

    return false
end

function PostingRuleResolver:GetDebugRecipeRules()
    local rows = {}
    for recipeID, rule in pairs(self:GetRecipeRulesDB()) do
        local effective, err = self:NormalizeRule(rule, "recipe", recipeID)
        rows[#rows + 1] = {
            recipeID = recipeID,
            rawRule = rule,
            effectiveRule = effective,
            configured = effective ~= nil,
            ignoredReason = err,
        }
    end
    table.sort(rows, function(a, b) return tostring(a.recipeID) < tostring(b.recipeID) end)
    return rows
end

function PostingRuleResolver:GetDebugNonCraftedRules()
    local rows = {}
    for itemKey, rule in pairs(self:GetNonCraftedRulesDB()) do
        local effective, err = self:NormalizeRule(rule, "noncrafted", itemKey)
        rows[#rows + 1] = {
            itemKey = itemKey,
            rawRule = rule,
            effectiveRule = effective,
            configured = effective ~= nil,
            ignoredReason = err,
        }
    end
    table.sort(rows, function(a, b) return tostring(a.itemKey) < tostring(b.itemKey) end)
    return rows
end

function PostingRuleResolver:OnInitialize()
    local db = GlobalDB()
    db.recipePostingRules = db.recipePostingRules or {}
    db.nonCraftedPostingRules = db.nonCraftedPostingRules or {}
    db.postingSettings = db.postingSettings or {}
    SessionLog("PostingRuleResolver OnInitialize recipeRules=%d nonCraftedRules=%d",
        #self:GetDebugRecipeRules(), #self:GetDebugNonCraftedRules())
end
