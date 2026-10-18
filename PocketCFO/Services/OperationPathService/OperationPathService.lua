-- PocketCFO/Services/OperationPathService/OperationPathService.lua
-- Lookup layer over known Operation Definitions.
--
-- Answers "what operations produce/consume this item?" and "what operation
-- definitions are available?". Performs no economics, comparison, inventory
-- planning, or recommendations.
--
-- Producer lookup is seeded from PocketCFO.RecipeRegistry's existing
-- output-item index (built while browsing profession windows), then expanded
-- with OperationDefinitionService's own cache. Consumer lookup has no
-- equivalent reverse index in Core today, so it can only search definitions
-- OperationDefinitionService has already registered or derived/cached this
-- session. That is an acceptable MVP lookup boundary, not a bug: building a
-- full reverse input index would require enumerating recipes the player has
-- never opened, which is out of scope for this phase.

local PocketCFO = _G.PocketCFO

local OperationPathService = {}

local function GetDefinitionService()
    return PocketCFO and PocketCFO.OperationDefinitionService or _G.PocketCFO_OperationDefinitionService
end

local function GetRecipeRegistry()
    return PocketCFO and PocketCFO.RecipeRegistry or _G.PocketCFO_RecipeRegistry
end

local function NormalizeID(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function NonEmptyString(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return tostring(value)
end

local function ItemRefMatches(ref, itemID, configKey)
    if type(ref) ~= "table" then
        return false
    end
    if itemID and NormalizeID(ref.itemID) == itemID then
        return true
    end
    if configKey and NonEmptyString(ref.configKey) == configKey then
        return true
    end
    return false
end

local function DefinitionHasItemRef(definition, list, itemID, configKey)
    if type(definition) ~= "table" or definition.unresolved then
        return false
    end
    for _, ref in ipairs(definition[list] or {}) do
        if ItemRefMatches(ref, itemID, configKey) then
            return true
        end
    end
    return false
end

--- Finds known operation definitions whose outputs include the given item.
-- @param item number itemID, or string configKey
function OperationPathService:FindOperationsProducing(item)
    local itemID = NormalizeID(item)
    local configKey = itemID and nil or NonEmptyString(item)
    if not itemID and not configKey then
        return {}
    end

    local definitionService = GetDefinitionService()
    if not definitionService then
        return {}
    end

    local results = {}
    local seenProfileKeys = {}

    local registry = itemID and GetRecipeRegistry() or nil
    if registry and registry.GetRecipeIDsForOutput then
        for _, recipeID in ipairs(registry:GetRecipeIDsForOutput(itemID) or {}) do
            local definition = definitionService:GetDefinition(recipeID)
            if not seenProfileKeys[definition and definition.profileKey]
                and DefinitionHasItemRef(definition, "outputs", itemID, configKey) then
                seenProfileKeys[definition.profileKey] = true
                results[#results + 1] = definition
            end
        end
    end

    if definitionService.ListDefinitions then
        for _, definition in ipairs(definitionService:ListDefinitions()) do
            if not seenProfileKeys[definition.profileKey]
                and DefinitionHasItemRef(definition, "outputs", itemID, configKey) then
                seenProfileKeys[definition.profileKey] = true
                results[#results + 1] = definition
            end
        end
    end

    return results
end

--- Finds known operation definitions whose inputs include the given item.
-- Limited to definitions OperationDefinitionService has already registered
-- or derived/cached (see file header).
-- @param item number itemID, or string configKey
function OperationPathService:FindOperationsConsuming(item)
    local itemID = NormalizeID(item)
    local configKey = itemID and nil or NonEmptyString(item)
    if not itemID and not configKey then
        return {}
    end

    local definitionService = GetDefinitionService()
    if not definitionService or not definitionService.ListDefinitions then
        return {}
    end

    local results = {}
    for _, definition in ipairs(definitionService:ListDefinitions()) do
        if DefinitionHasItemRef(definition, "inputs", itemID, configKey) then
            results[#results + 1] = definition
        end
    end

    return results
end

--- Returns all known operation definitions available to the given
-- profession (or all known definitions when professionID is nil).
function OperationPathService:GetAvailableDefinitions(professionID)
    local definitionService = GetDefinitionService()
    if not definitionService or not definitionService.ListDefinitions then
        return {}
    end

    if professionID then
        return definitionService:ListDefinitions({ profession = professionID })
    end
    return definitionService:ListDefinitions()
end

if PocketCFO then
    PocketCFO.OperationPathService = OperationPathService
end

_G.PocketCFO_OperationPathService = OperationPathService
