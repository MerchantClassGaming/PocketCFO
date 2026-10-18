-- PocketCFO/Services/OperationDefinitionService/OperationDefinitionService.lua
-- Canonical owner of static Operation Definitions.
--
-- A definition describes one operation profile structurally: what inputs it
-- requires and what outputs/resourcefulness returns it can possibly produce.
--
-- This service must never store observed yields, averages, prices,
-- confidence, or recommendations. Expected quantities belong to the future
-- OperationOutcomeService. Pricing belongs to the future
-- OperationEconomicsService.
--
-- Three sources of definitions:
--   "registered"               - explicitly curated/static data (the
--                   authoritative source for Processing Operations whose
--                   output basket cannot be derived - e.g. an operation that
--                   splits into multiple named Statistical Profiles).
--   "derived"                  - structurally read from the Blizzard recipe
--                   schematic at call time for Crafting Operations, where
--                   recipeID alone identifies the operation and Blizzard
--                   exposes a fixed reagent/output schematic.
--   "derivedProcessingRegistry" - structurally built from
--                   ProcessingOperationRegistry's already-curated primary
--                   input quantity, for Processing Operations that have no
--                   explicitly registered definition. Only the required-input
--                   side is ever derived this way; output baskets are never
--                   guessed - OperationEconomicsService reads expected income
--                   from OperationOutcomeService's observed aggregate.

local PocketCFO = _G.PocketCFO

local OperationDefinitionService = {}

OperationDefinitionService.SOURCE_REGISTERED = "registered"
OperationDefinitionService.SOURCE_DERIVED = "derived"
OperationDefinitionService.SOURCE_DERIVED_PROCESSING_REGISTRY = "derivedProcessingRegistry"

-- definitionsByProfileKey[profileKey] = OperationDefinition
OperationDefinitionService.definitionsByProfileKey = OperationDefinitionService.definitionsByProfileKey or {}

local function GetProfileKeyService()
    return PocketCFO and PocketCFO.OperationProfileKeyService or _G.PocketCFO_OperationProfileKeyService
end

local function GetProcessingRegistry()
    return PocketCFO and PocketCFO.ProcessingOperationRegistry or _G.PocketCFO_ProcessingOperationRegistry
end

local function GetRecipeRegistry()
    return PocketCFO and PocketCFO.RecipeRegistry or _G.PocketCFO_RecipeRegistry
end

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function NormalizeID(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function NewUnresolved(recipeID, reason, extra)
    local result = {
        recipeID = recipeID,
        unresolved = true,
        unresolvedReason = reason or "operationDefinitionUnresolved",
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            result[k] = v
        end
    end
    return result
end

--- Builds an item reference for inputs/outputs/resourcefulness returns.
-- Best-effort attaches a configKey via ItemIdentityService; does not block
-- on full identity resolution since reagents are commonly plain items.
local function BuildItemRef(itemID, quantity)
    itemID = NormalizeID(itemID)
    if not itemID then
        return nil
    end

    local ref = { itemID = itemID, quantity = NormalizeID(quantity) }

    local identityService = GetItemIdentityService()
    if identityService and identityService.FromItemID then
        local ok, identity = pcall(function() return identityService:FromItemID(itemID) end)
        if ok and type(identity) == "table" and not identity.unresolved then
            ref.configKey = identity.configKey
        end
    end

    return ref
end

local function BuildItemRefFromRole(role, fallback)
    role = type(role) == "table" and role or {}
    fallback = type(fallback) == "table" and fallback or {}

    local quantity = tonumber(role.quantityRequired) or tonumber(fallback.quantity)
    if not quantity or quantity <= 0 then
        return nil, "inputQuantityMissing"
    end

    if role.fixedCatalyst == true or role.fixedItemID then
        local ref = BuildItemRef(role.fixedItemID, quantity)
        if not ref then
            return nil, "fixedInputIdentityMissing"
        end
        ref.inputRoleKey = role.key
        ref.inputRole = role.role
        ref.fixedCatalyst = role.fixedCatalyst == true
        return ref
    end

    local configKey = fallback.configKey
    if not configKey or configKey == "" then
        return nil, "primaryInputMissing"
    end

    return {
        configKey = configKey,
        itemID = fallback.itemID,
        itemName = fallback.itemName,
        quantity = quantity,
        inputRoleKey = role.key,
        inputRole = role.role,
        profileDriver = role.profileDriver == true,
        selectedCostInput = role.selectedCostInput == true,
    }, nil
end

local function BuildKnownOutputRefs(entry)
    local outputs = {}
    for _, output in ipairs(type(entry and entry.knownOutputs) == "table" and entry.knownOutputs or {}) do
        local ref = BuildItemRef(output.itemID)
        if ref then
            ref.itemName = output.name or ref.itemName
            ref.quantityOnly = output.quantityOnly == true
            outputs[#outputs + 1] = ref
        end
    end
    return outputs
end

local function ResolveOutputItemID(recipeID, schematicInfo)
    local outputItemID = NormalizeID(schematicInfo and schematicInfo.outputItemID)
    if outputItemID then
        return outputItemID
    end

    local registry = GetRecipeRegistry()
    if registry and registry.GetOutputItemID then
        outputItemID = NormalizeID(registry:GetOutputItemID(recipeID))
        if outputItemID then
            return outputItemID
        end
    end

    if registry and registry.GetRecipeOutputItemID then
        outputItemID = NormalizeID(registry:GetRecipeOutputItemID(recipeID))
    end

    return outputItemID
end

--- Derives a Crafting Operation definition from the live recipe schematic.
-- Only valid for Crafting Operations (recipeID-only profile keys). Returns
-- nil, reason on failure rather than guessing missing structural facts.
function OperationDefinitionService:DeriveCraftingDefinition(recipeID, keyResult, options)
    if not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeSchematic then
        return nil, "tradeSkillUIUnavailable"
    end

    local ok, schematicInfo = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or type(schematicInfo) ~= "table" then
        return nil, "schematicUnavailable"
    end

    local inputs = {}
    for _, slot in ipairs(schematicInfo.reagentSlotSchematics or {}) do
        if slot.reagentType == 1 then
            local reagent = slot.reagents and slot.reagents[1]
            local itemID = reagent and reagent.itemID
            local ref = itemID and BuildItemRef(itemID, slot.quantityRequired)
            if ref then
                inputs[#inputs + 1] = ref
            end
        end
    end

    if #inputs == 0 then
        return nil, "noResolvableInputs"
    end

    local outputItemID = ResolveOutputItemID(recipeID, schematicInfo)
    if not outputItemID then
        return nil, "outputItemUnresolved"
    end

    local outputRef = BuildItemRef(outputItemID)
    if not outputRef then
        return nil, "outputItemUnresolved"
    end

    options = type(options) == "table" and options or {}

    return {
        profileKey = keyResult.profileKey,
        operationType = keyResult.operationType,
        recipeID = recipeID,
        profession = options.profession or options.professionID,
        expansion = options.expansion or options.expansionID,
        inputs = inputs,
        outputs = { outputRef },
        resourcefulnessReturnItems = {},
        source = self.SOURCE_DERIVED,
    }
end

-- Finds the ProcessingOperationRegistry input role flagged as the profile
-- driver - the primary input whose identity distinguishes this Operation
-- Profile from others sharing the same recipeID (e.g. the selected ore for
-- Prospecting). Mirrors the profileDriver convention CraftCompletionDispatcher
-- already applies to captured runtime rows, applied here to the curated
-- inputRoles entry instead.
local function FindProfileDriverInputRole(entry)
    for _, role in ipairs(type(entry) == "table" and type(entry.inputRoles) == "table" and entry.inputRoles or {}) do
        if type(role) == "table" and role.profileDriver == true then
            return role
        end
    end
    return nil
end

--- Derives a structural Processing Operation definition from
-- ProcessingOperationRegistry's already-curated primary-input quantity, for
-- registered processing operations that have no explicitly RegisterDefinition-
-- ed definition. Only valid when the operation's profile key mode resolved a
-- single primaryInputConfigKey (recipePlusPrimaryInput - Prospecting,
-- Milling); other profile key modes (e.g. Crushing's recipeOnly, where cost
-- evidence comes from a selected-input role, not a single primary input)
-- naturally fall through to unresolved here rather than being guessed at.
--
-- Never guesses possible outputs and never requires a static output basket:
-- outputs is left nil, and expected income continues to come from
-- OperationOutcomeService's observed aggregate. Input quantity always comes
-- from the curated ProcessingOperationRegistry entry, never hardcoded here.
-- Returns nil, reason on failure rather than guessing missing structural facts.
-- @param recipeID number
-- @param keyResult table an already-resolved (non-unresolved) result from
--        OperationProfileKeyService:BuildKey
-- @param options table|nil { primaryInputIdentity, primaryInputConfigKey,
--        primaryInputItemID, primaryInputItemName }
function OperationDefinitionService:DeriveProcessingDefinition(recipeID, keyResult, options)
    options = type(options) == "table" and options or {}

    local registry = GetProcessingRegistry()
    local entry = registry and registry:GetEntry(recipeID)
    if not entry then
        return nil, "processingOperationNotRegistered"
    end

    -- keyResult.primaryInputConfigKey is only populated for profile key modes
    -- that resolve around one primary input (recipePlusPrimaryInput); its
    -- absence here means either the mode does not have one (Crushing) or the
    -- caller genuinely never supplied primary input evidence.
    local primaryInputConfigKey = keyResult.primaryInputConfigKey
    if not primaryInputConfigKey then
        return nil, "primaryInputMissing"
    end

    local driverRole = FindProfileDriverInputRole(entry)
    if not driverRole then
        return nil, "primaryInputRoleMissing"
    end

    local identity = options.primaryInputIdentity
    local hasIdentity = type(identity) == "table" and not identity.unresolved
    local itemID = NormalizeID(options.primaryInputItemID)
        or (hasIdentity and NormalizeID(identity.itemID))
        or nil
    local itemName = options.primaryInputItemName
        or (hasIdentity and identity.itemName)
        or nil

    local inputs = {}
    for _, role in ipairs(type(entry.inputRoles) == "table" and entry.inputRoles or {}) do
        if role.profileDriver == true or role.fixedCatalyst == true or role.fixedItemID then
            local input, reason = BuildItemRefFromRole(role, {
                configKey = primaryInputConfigKey,
                itemID = itemID,
                itemName = itemName,
            })
            if not input then
                return nil, reason
            end
            inputs[#inputs + 1] = input
        end
    end

    if #inputs == 0 then
        return nil, "noResolvableInputs"
    end

    return {
        operationType = keyResult.operationType,
        processingType = entry.processingType,
        recipeID = recipeID,
        profileKey = keyResult.profileKey,
        operationProfileKey = keyResult.profileKey,
        primaryInputConfigKey = primaryInputConfigKey,
        inputs = inputs,
        outputs = BuildKnownOutputRefs(entry),
        outputValuationMode = entry.outputValuationMode,
        unitAcquisitionOutputItemID = entry.unitAcquisitionOutputItemID,
        resourcefulnessReturnItems = {},
        source = self.SOURCE_DERIVED_PROCESSING_REGISTRY,
    }
end

--- Returns the Operation Definition for a recipeID, deriving a Crafting
-- Operation definition on demand when one isn't already registered/cached.
-- Processing Operations prefer an explicitly registered definition; when none
-- exists, a structural definition is derived from ProcessingOperationRegistry
-- (see DeriveProcessingDefinition) rather than immediately refusing - this
-- service still never guesses processing output baskets.
-- @param recipeID number
-- @param options table|nil forwarded to OperationProfileKeyService.BuildKey,
--        plus optional profession/expansion metadata for derived definitions.
function OperationDefinitionService:GetDefinition(recipeID, options)
    recipeID = NormalizeID(recipeID)
    if not recipeID then
        return NewUnresolved(recipeID, "missingRecipeID")
    end

    local profileKeyService = GetProfileKeyService()
    if not profileKeyService then
        return NewUnresolved(recipeID, "profileKeyServiceUnavailable")
    end

    local keyResult = profileKeyService:BuildKey(recipeID, options)
    if keyResult.unresolved then
        return NewUnresolved(recipeID, keyResult.unresolvedReason, {
            operationType = keyResult.operationType,
            profileKeyMode = keyResult.profileKeyMode,
        })
    end

    local existing = self.definitionsByProfileKey[keyResult.profileKey]
    if existing then
        return existing
    end

    if keyResult.operationType == profileKeyService.OPERATION_TYPE_CRAFTING then
        local derived, reason = self:DeriveCraftingDefinition(recipeID, keyResult, options)
        if derived then
            self.definitionsByProfileKey[keyResult.profileKey] = derived
            return derived
        end
        return NewUnresolved(recipeID, reason or "schematicUnavailable", {
            profileKey = keyResult.profileKey,
            operationType = keyResult.operationType,
        })
    end

    local derived, derivedReason = self:DeriveProcessingDefinition(recipeID, keyResult, options)
    if derived then
        self.definitionsByProfileKey[keyResult.profileKey] = derived
        return derived
    end

    return NewUnresolved(recipeID, derivedReason or "definitionNotRegistered", {
        profileKey = keyResult.profileKey,
        operationType = keyResult.operationType,
        primaryInputConfigKey = keyResult.primaryInputConfigKey,
    })
end

--- Pure lookup by profile key. Does not attempt derivation.
function OperationDefinitionService:GetDefinitionByProfileKey(profileKey)
    if not profileKey then
        return nil
    end
    return self.definitionsByProfileKey[profileKey]
end

--- Explicitly registers a static/curated definition (required for Processing
-- Operations; also usable to override/seed a Crafting Operation definition).
function OperationDefinitionService:RegisterDefinition(definition)
    if type(definition) ~= "table" then
        return false, "definitionNotTable"
    end
    if not definition.profileKey or definition.profileKey == "" then
        return false, "missingProfileKey"
    end
    if not definition.operationType then
        return false, "missingOperationType"
    end
    if type(definition.inputs) ~= "table" or #definition.inputs == 0 then
        return false, "missingInputs"
    end
    if type(definition.outputs) ~= "table" or #definition.outputs == 0 then
        return false, "missingOutputs"
    end

    definition.resourcefulnessReturnItems = definition.resourcefulnessReturnItems or {}
    definition.source = definition.source or self.SOURCE_REGISTERED

    self.definitionsByProfileKey[definition.profileKey] = definition
    return true
end

--- Returns all known definitions (registered and previously derived/cached),
-- optionally filtered by operationType and/or profession.
function OperationDefinitionService:ListDefinitions(filter)
    filter = type(filter) == "table" and filter or nil
    local results = {}
    for _, definition in pairs(self.definitionsByProfileKey) do
        local matchesType = not filter or not filter.operationType or definition.operationType == filter.operationType
        local matchesProfession = not filter or not filter.profession or definition.profession == filter.profession
        if matchesType and matchesProfession then
            results[#results + 1] = definition
        end
    end
    return results
end

if PocketCFO then
    PocketCFO.OperationDefinitionService = OperationDefinitionService
end

_G.PocketCFO_OperationDefinitionService = OperationDefinitionService
