-- PocketCFO/Services/OperationProfileKeyService/OperationProfileKeyService.lua
-- Canonical owner of Operation Profile Key generation.
--
-- Operation profile key identity:
--   Crafting Operation  = recipeID
--   Processing Operation = recipeID + primary input identity (when the
--                           ProcessingOperationRegistry entry requires it)
--
-- This service answers "which operation profile is this?". It does not
-- answer what the operation produces, what it is worth, or whether the
-- player should perform it.

local PocketCFO = _G.PocketCFO

local OperationProfileKeyService = {}

OperationProfileKeyService.OPERATION_TYPE_CRAFTING = "crafting"
OperationProfileKeyService.OPERATION_TYPE_PROCESSING = "processing"

local function GetRegistry()
    return PocketCFO and PocketCFO.ProcessingOperationRegistry or _G.PocketCFO_ProcessingOperationRegistry
end

local function NormalizeID(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function NonEmpty(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return tostring(value)
end

local function NewUnresolved(recipeID, reason, extra)
    local result = {
        recipeID = recipeID,
        unresolved = true,
        unresolvedReason = reason or "operationProfileKeyUnresolved",
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            result[k] = v
        end
    end
    return result
end

-- Resolves a primary input configKey from the supplied options.
-- Accepts either a pre-built identity table (e.g. from ItemIdentityService,
-- which exposes .configKey) or a raw configKey string.
local function ResolvePrimaryInputConfigKey(options)
    if type(options) ~= "table" then
        return nil
    end

    local configKey = NonEmpty(options.primaryInputConfigKey)
    if configKey then
        return configKey
    end

    local identity = options.primaryInputIdentity
    if type(identity) == "table" and not identity.unresolved then
        return NonEmpty(identity.configKey)
    end

    return nil
end

local function ResolveInputAttributeKey(options)
    if type(options) ~= "table" then
        return nil
    end
    return NonEmpty(options.inputAttributeKey)
        or NonEmpty(options.primaryInputAttributeKey)
        or NonEmpty(options.selectedInputAttributeKey)
end

--- Builds the canonical Operation Profile Key for one recipe execution/definition.
-- @param recipeID number
-- @param options table|nil { primaryInputIdentity = identity table, primaryInputConfigKey = string,
--                            inputAttributeKey = string }
-- @return table profile key result:
--   {
--     profileKey, operationType, profileKeyMode, recipeID,
--     primaryInputConfigKey, unresolved, unresolvedReason,
--   }
function OperationProfileKeyService:BuildKey(recipeID, options)
    recipeID = NormalizeID(recipeID)
    if not recipeID then
        return NewUnresolved(recipeID, "missingRecipeID")
    end

    local registry = GetRegistry()
    local entry = registry and registry:GetEntry(recipeID) or nil

    if not entry then
        return {
            profileKey = "recipe:" .. tostring(recipeID),
            operationType = self.OPERATION_TYPE_CRAFTING,
            profileKeyMode = registry and registry.PROFILE_KEY_MODE_RECIPE_ONLY or "recipeOnly",
            recipeID = recipeID,
        }
    end

    local profileKeyMode = entry.profileKeyMode

    if profileKeyMode == registry.PROFILE_KEY_MODE_RECIPE_ONLY then
        return {
            profileKey = "recipe:" .. tostring(recipeID),
            operationType = self.OPERATION_TYPE_PROCESSING,
            profileKeyMode = profileKeyMode,
            recipeID = recipeID,
        }
    end

    if profileKeyMode == registry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT then
        local primaryInputConfigKey = ResolvePrimaryInputConfigKey(options)
        if not primaryInputConfigKey then
            return NewUnresolved(recipeID, "missingPrimaryInputIdentity", {
                operationType = self.OPERATION_TYPE_PROCESSING,
                profileKeyMode = profileKeyMode,
            })
        end

        return {
            profileKey = "recipe:" .. tostring(recipeID) .. "|input:" .. primaryInputConfigKey,
            operationType = self.OPERATION_TYPE_PROCESSING,
            profileKeyMode = profileKeyMode,
            recipeID = recipeID,
            primaryInputConfigKey = primaryInputConfigKey,
        }
    end

    if profileKeyMode == registry.PROFILE_KEY_MODE_RECIPE_PLUS_INPUT_ATTRIBUTE then
        local inputAttributeKey = ResolveInputAttributeKey(options)
        if not inputAttributeKey then
            return NewUnresolved(recipeID, "missingInputAttributeKey", {
                operationType = self.OPERATION_TYPE_PROCESSING,
                profileKeyMode = profileKeyMode,
            })
        end

        return {
            profileKey = "recipe:" .. tostring(recipeID) .. "|attribute:" .. inputAttributeKey,
            operationType = self.OPERATION_TYPE_PROCESSING,
            profileKeyMode = profileKeyMode,
            recipeID = recipeID,
            inputAttributeKey = inputAttributeKey,
        }
    end

    return NewUnresolved(recipeID, "unknownProfileKeyMode", {
        operationType = self.OPERATION_TYPE_PROCESSING,
        profileKeyMode = profileKeyMode,
    })
end

--- Convenience accessor returning only the operation type for a recipeID
--- without requiring primary input evidence.
function OperationProfileKeyService:GetOperationType(recipeID)
    local registry = GetRegistry()
    local entry = registry and registry:GetEntry(recipeID) or nil
    if entry then
        return self.OPERATION_TYPE_PROCESSING
    end
    return self.OPERATION_TYPE_CRAFTING
end

--- True if this recipeID requires a primary input identity to fully resolve
--- its operation profile key.
function OperationProfileKeyService:RequiresPrimaryInput(recipeID)
    local registry = GetRegistry()
    local entry = registry and registry:GetEntry(recipeID) or nil
    return entry ~= nil and entry.profileKeyMode == registry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT
end

function OperationProfileKeyService:RequiresInputAttribute(recipeID)
    local registry = GetRegistry()
    local entry = registry and registry:GetEntry(recipeID) or nil
    return entry ~= nil and entry.profileKeyMode == registry.PROFILE_KEY_MODE_RECIPE_PLUS_INPUT_ATTRIBUTE
end

--- Reverses BuildKey's profile key format back into its constituent parts.
-- Lets consumers that only have a profileKey (no recipeID) re-derive enough
-- to ask OperationDefinitionService for a definition, without duplicating
-- the "recipe:<id>" / "recipe:<id>|input:<configKey>" format elsewhere.
-- @return number|nil recipeID, string|nil primaryInputConfigKey
function OperationProfileKeyService:ParseProfileKey(profileKey)
    profileKey = NonEmpty(profileKey)
    if not profileKey then
        return nil, nil
    end

    local recipeIDPart, primaryInputConfigKey = profileKey:match("^recipe:(%d+)|input:(.+)$")
    if recipeIDPart then
        return tonumber(recipeIDPart), primaryInputConfigKey
    end

    recipeIDPart = profileKey:match("^recipe:(%d+)|attribute:.+$")
    if recipeIDPart then
        return tonumber(recipeIDPart), nil
    end

    recipeIDPart = profileKey:match("^recipe:(%d+)$")
    if recipeIDPart then
        return tonumber(recipeIDPart), nil
    end

    return nil, nil
end

if PocketCFO then
    PocketCFO.OperationProfileKeyService = OperationProfileKeyService
end

_G.PocketCFO_OperationProfileKeyService = OperationProfileKeyService
