-- PocketCFO_AH/Posting/Rules/PostingRuleRepository.lua
-- Rule storage, retrieval, creation, update, deletion, and persistence normalization.

local ADDON_NAME, _ = ...
local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingRuleRepository = PocketCFO_AH:NewModule("PostingRuleRepository")

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function GlobalDB()
    return PocketCFO_AH.db and PocketCFO_AH.db.global or {}
end

local function OwnerKey()
    return PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID or nil
end

local function OwnerName()
    if UnitFullName then
        local name, realm = UnitFullName("player")
        if name and realm and realm ~= "" then
            return name .. "-" .. realm
        end
        return name
    end
    return UnitName and UnitName("player") or nil
end

local function RecipeRules()
    local db = GlobalDB()
    db.recipePostingRules = db.recipePostingRules or {}
    return db.recipePostingRules
end

function PostingRuleRepository:GetRecipeRulesDB()
    return RecipeRules()
end

function PostingRuleRepository:GetRecipeRule(target)
    local rules = RecipeRules()

    -- Third return value exposes lookup diagnostics for /mcgd postingrule.
    -- Does not change resolution behavior for existing two-value callers.
    local diag = {
        targetKeyChecked = nil,
        legacyKeyChecked = nil,
        legacyKeyConfigKeyMatched = nil,
        configKeyChecked = nil,
        configKeyScanAttempted = false,
        selectedStorageKey = nil,
        matchPath = "notFound",
    }

    if not target then
        diag.matchPath = "noTarget"
        return nil, nil, diag
    end

    -- Primary: direct key lookup.
    local key = target.key and tostring(target.key) or nil
    diag.targetKeyChecked = key
    if key then
        local rule = rules[key]
        if rule then
            diag.selectedStorageKey = key
            diag.matchPath = "directKey"
            return rule, key, diag
        end
    end

    -- Secondary: legacy key lookup, guarded by configKey equality.
    local legacyKey = target.legacyKey and tostring(target.legacyKey) or nil
    diag.legacyKeyChecked = legacyKey
    if legacyKey then
        local legacyRule = rules[legacyKey]
        local ruleConfigKey = legacyRule and legacyRule.configKey
        local identityConfigKey = target.identity and target.identity.configKey
        diag.legacyKeyConfigKeyMatched = (ruleConfigKey ~= nil and identityConfigKey ~= nil and ruleConfigKey == identityConfigKey)
        if diag.legacyKeyConfigKeyMatched then
            diag.selectedStorageKey = legacyKey
            diag.matchPath = "legacyKey"
            return legacyRule, legacyKey, diag
        end
    end

    -- Tertiary: scan for a rule stored under a different key with a matching configKey.
    local configKey = target.identity and target.identity.configKey
    diag.configKeyChecked = configKey
    if configKey then
        diag.configKeyScanAttempted = true
        for existingKey, existingRule in pairs(rules) do
            if type(existingRule) == "table" and existingRule.configKey == configKey then
                diag.selectedStorageKey = tostring(existingKey)
                diag.matchPath = "configKeyScan"
                return existingRule, tostring(existingKey), diag
            end
        end
    end

    return nil, nil, diag
end

function PostingRuleRepository:ApplyRecipeIdentity(rule, target)
    local identity = target and target.identity
    if type(rule) ~= "table" or type(identity) ~= "table" then
        return rule
    end

    rule.recipeID = target.recipeID or identity.recipeID
    rule.configKey = identity.configKey or rule.configKey
    rule.itemKey = identity.configKey or identity.itemKey or rule.itemKey
    rule.itemID = identity.itemID
    rule.outputItemID = identity.outputItemID or identity.itemID
    rule.targetItemID = identity.targetItemID or identity.outputItemID or identity.itemID
    rule.itemName = identity.itemName
    rule.itemLink = identity.itemLink or rule.itemLink
    rule.craftingQuality = identity.craftingQuality
    rule.itemQuality = identity.itemQuality or identity.craftingQuality
    rule.qualityTier = identity.qualityTier or identity.craftingQuality
    rule.effectiveItemLevel = identity.effectiveItemLevel or identity.effectiveIlvl or identity.itemLevel or identity.ilvl
    rule.itemLevel = identity.itemLevel or identity.effectiveItemLevel or identity.effectiveIlvl
    rule.ilvl = identity.ilvl or identity.itemLevel or identity.effectiveItemLevel or identity.effectiveIlvl
    rule.targetIlvl = identity.targetIlvl or identity.effectiveItemLevel or identity.effectiveIlvl or identity.itemLevel
    rule.statTarget = identity.statTarget or identity.statFingerprint
    rule.statFingerprint = identity.statFingerprint or identity.statTarget
    rule.matchingPath = identity.matchingPath or rule.matchingPath
    rule.variantType = identity.variantType or rule.variantType
    rule.owner = rule.owner or OwnerKey()
    rule.ownerName = rule.ownerName or OwnerName()
    return rule
end

function PostingRuleRepository:SaveRecipeRule(target, mode, profileKey, values)
    local rules = RecipeRules()
    if not target or not target.key then
        return nil
    end

    local keptKey = tostring(target.key)
    local identityConfigKey = target.identity and target.identity.configKey
    if identityConfigKey then
        for existingKey, existingRule in pairs(rules) do
            if tostring(existingKey) ~= keptKey
            and type(existingRule) == "table"
            and existingRule.configKey == identityConfigKey then
                SessionLog("PostingRuleRepository: removed duplicate recipe rule itemName=%s configKey=%s removedKey=%s keptKey=%s oldProfile=%s newProfile=%s",
                    tostring(target.identity and target.identity.itemName),
                    tostring(identityConfigKey),
                    tostring(existingKey),
                    keptKey,
                    tostring(existingRule.profileKey or existingRule.profileID),
                    tostring(profileKey))
                rules[existingKey] = nil
            end
        end
    end

    local rule = rules[keptKey] or {}
    self:ApplyRecipeIdentity(rule, target)
    rule.mode = tostring(mode or "none")
    if rule.mode == "profile" then
        rule.profileKey = profileKey
        rule.profileID = profileKey
        rule.custom = nil
    elseif rule.mode == "custom" then
        rule.profileKey = nil
        rule.profileID = nil
        rule.custom = values or {}
    else
        rule.profileKey = nil
        rule.profileID = nil
        rule.custom = nil
    end
    rules[keptKey] = rule
    return rule
end

function PostingRuleRepository:DeleteRecipeRule(target)
    local rules = RecipeRules()
    local key = target and (target.storageKey or target.key)
    if key then
        rules[tostring(key)] = nil
    end
end
