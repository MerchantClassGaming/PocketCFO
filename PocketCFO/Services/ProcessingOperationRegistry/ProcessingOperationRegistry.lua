-- PocketCFO/Services/ProcessingOperationRegistry/ProcessingOperationRegistry.lua
-- Curated static registry of which recipeIDs are Processing Operations and how
-- their operation profile key is identified. Unregistered recipeIDs are treated
-- as Crafting Operations by OperationProfileKeyService.
--
-- Entries are added only after in-game verification. Do not guess recipeIDs.
-- See CLAUDE.md "Never assume Blizzard API behavior".

local PocketCFO = _G.PocketCFO

local ProcessingOperationRegistry = {}

ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_ONLY = "recipeOnly"
ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT = "recipePlusPrimaryInput"
ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_PLUS_INPUT_ATTRIBUTE = "recipePlusInputAttribute"

ProcessingOperationRegistry.INPUT_ROLE_PROFILE_DRIVER = "profileDriver"
ProcessingOperationRegistry.INPUT_ROLE_DETERMINISTIC_OUTPUT_DRIVER = "deterministicOutputDriver"
ProcessingOperationRegistry.INPUT_ROLE_SELECTED_COST_INPUT = "selectedCostInput"
ProcessingOperationRegistry.INPUT_ROLE_FIXED_CATALYST = "fixedCatalyst"

local VALID_PROFILE_KEY_MODES = {
    [ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_ONLY] = true,
    [ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT] = true,
    [ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_PLUS_INPUT_ATTRIBUTE] = true,
}

local VALID_INPUT_ROLES = {
    [ProcessingOperationRegistry.INPUT_ROLE_PROFILE_DRIVER] = true,
    [ProcessingOperationRegistry.INPUT_ROLE_DETERMINISTIC_OUTPUT_DRIVER] = true,
    [ProcessingOperationRegistry.INPUT_ROLE_SELECTED_COST_INPUT] = true,
    [ProcessingOperationRegistry.INPUT_ROLE_FIXED_CATALYST] = true,
}

-- entriesByRecipeID[recipeID] = {
--     recipeID = number,
--     recipeName = string|nil,
--     expansion = number|nil,
--     profession = number|nil,
--     processingType = string,            -- e.g. "prospecting", "milling", "crushing", "recycling"
--     primaryInputSlotRule = string|nil,  -- curated note on which reagent slot carries the primary input
--     profileKeyMode = "recipeOnly" | "recipePlusPrimaryInput" | "recipePlusInputAttribute",
--     inputRoles = {
--         {
--             key = string,
--             role = "profileDriver" | "deterministicOutputDriver" | "selectedCostInput" | "fixedCatalyst",
--             profileDriver = boolean|nil,
--             deterministicOutputDriver = boolean|nil,
--             selectedCostInput = boolean|nil,
--             fixedCatalyst = boolean|nil,
--             selected = boolean|nil,
--             statisticalProfile = boolean|nil,
--             reagentType = number|nil,
--             quantityRequired = number|nil,
--             fixedItemID = number|nil,
--             slotRule = string|nil,
--         },
--     },
--     knownPrimaryInputs = {           -- curated list of all valid primary
--         { itemID = number, name = string|nil },  -- inputs for this
--     },                               -- operation family (e.g. every ore
--                                       -- Prospecting accepts). Verified/
--                                       -- curated only - never derived from
--                                       -- the live Blizzard reagent slot.
--                                       -- Used by "evaluate all inputs"
--                                       -- policies (Prospecting, Milling) to
--                                       -- render one comparison row per
--                                       -- input without requiring a
--                                       -- selected reagent. Omit or leave
--                                       -- empty until verified in-game.
-- }
ProcessingOperationRegistry.entriesByRecipeID = ProcessingOperationRegistry.entriesByRecipeID or {}

local function NormalizeID(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function CopyInputRoles(inputRoles)
    local copied = {}
    for _, role in ipairs(type(inputRoles) == "table" and inputRoles or {}) do
        if type(role) == "table" then
            if not VALID_INPUT_ROLES[role.role] then
                return nil, "invalidInputRole"
            end
            copied[#copied + 1] = {
                key = role.key,
                role = role.role,
                profileDriver = role.profileDriver == true
                    or role.role == ProcessingOperationRegistry.INPUT_ROLE_PROFILE_DRIVER,
                deterministicOutputDriver = role.deterministicOutputDriver == true
                    or role.role == ProcessingOperationRegistry.INPUT_ROLE_DETERMINISTIC_OUTPUT_DRIVER,
                selectedCostInput = role.selectedCostInput == true
                    or role.role == ProcessingOperationRegistry.INPUT_ROLE_SELECTED_COST_INPUT,
                fixedCatalyst = role.fixedCatalyst == true
                    or role.role == ProcessingOperationRegistry.INPUT_ROLE_FIXED_CATALYST,
                selected = role.selected == true,
                statisticalProfile = role.statisticalProfile == true,
                reagentType = tonumber(role.reagentType),
                quantityRequired = tonumber(role.quantityRequired),
                fixedItemID = NormalizeID(role.fixedItemID),
                slotRule = role.slotRule,
            }
        end
    end
    return copied
end

local function CopyKnownPrimaryInputs(knownPrimaryInputs)
    local copied = {}
    for _, input in ipairs(type(knownPrimaryInputs) == "table" and knownPrimaryInputs or {}) do
        if type(input) == "table" then
            local itemID = NormalizeID(input.itemID)
            if itemID then
                copied[#copied + 1] = { itemID = itemID, name = input.name }
            end
        end
    end
    return copied
end

local function CopyKnownOutputs(knownOutputs)
    local copied = {}
    for _, output in ipairs(type(knownOutputs) == "table" and knownOutputs or {}) do
        if type(output) == "table" then
            local itemID = NormalizeID(output.itemID)
            if itemID then
                copied[#copied + 1] = {
                    itemID = itemID,
                    name = output.name,
                    quantityOnly = output.quantityOnly == true,
                }
            end
        end
    end
    return copied
end

function ProcessingOperationRegistry:RegisterEntry(entry)
    if type(entry) ~= "table" then
        return false, "entryNotTable"
    end

    local recipeID = NormalizeID(entry.recipeID)
    if not recipeID then
        return false, "missingRecipeID"
    end

    local profileKeyMode = entry.profileKeyMode
    if not VALID_PROFILE_KEY_MODES[profileKeyMode] then
        return false, "invalidProfileKeyMode"
    end

    if not entry.processingType or entry.processingType == "" then
        return false, "missingProcessingType"
    end

    local inputRoles, roleReason = CopyInputRoles(entry.inputRoles)
    if not inputRoles then
        return false, roleReason
    end

    self.entriesByRecipeID[recipeID] = {
        recipeID = recipeID,
        recipeName = entry.recipeName,
        expansion = entry.expansion,
        profession = entry.profession,
        processingType = entry.processingType,
        primaryInputSlotRule = entry.primaryInputSlotRule,
        profileKeyMode = profileKeyMode,
        inputRoles = inputRoles,
        knownPrimaryInputs = CopyKnownPrimaryInputs(entry.knownPrimaryInputs),
        knownOutputs = CopyKnownOutputs(entry.knownOutputs),
        unitAcquisitionOutputItemID = NormalizeID(entry.unitAcquisitionOutputItemID),
        outputValuationMode = entry.outputValuationMode,
    }

    return true
end

function ProcessingOperationRegistry:GetKnownOutputs(recipeID)
    local entry = self:GetEntry(recipeID)
    return (entry and entry.knownOutputs) or {}
end

function ProcessingOperationRegistry:GetEntry(recipeID)
    recipeID = NormalizeID(recipeID)
    if not recipeID then
        return nil
    end
    return self.entriesByRecipeID[recipeID]
end

function ProcessingOperationRegistry:IsProcessingOperation(recipeID)
    return self:GetEntry(recipeID) ~= nil
end

function ProcessingOperationRegistry:GetProfileKeyMode(recipeID)
    local entry = self:GetEntry(recipeID)
    if entry then
        return entry.profileKeyMode
    end
    return self.PROFILE_KEY_MODE_RECIPE_ONLY
end

--- Returns the curated list of all valid primary inputs for this operation
-- family (e.g. every ore a Prospecting recipe accepts), for "evaluate all
-- inputs" policies that must not depend on the currently selected Blizzard
-- reagent slot. Always returns a table (empty when nothing is curated yet).
function ProcessingOperationRegistry:GetKnownPrimaryInputs(recipeID)
    local entry = self:GetEntry(recipeID)
    return (entry and entry.knownPrimaryInputs) or {}
end

-- ---------------------------------------------------------------------------
-- Observed primary inputs (runtime-learned, SavedVariables-backed)
-- ---------------------------------------------------------------------------
-- Curated knownPrimaryInputs above requires manual verification per-item and
-- starts empty for every operation family. RecordObservedPrimaryInput lets
-- "evaluate all inputs" policies (Prospecting, Milling) grow their candidate
-- list automatically from real completed operations instead of waiting on
-- curation. This never writes to this Lua file - only to
-- PocketCFO.db.global.processingObservedPrimaryInputs.

local function GetObservedInputTable()
    local db = PocketCFO and PocketCFO.db
    if not db then
        return nil
    end
    db.global = db.global or {}
    db.global.processingObservedPrimaryInputs = db.global.processingObservedPrimaryInputs or {}
    return db.global.processingObservedPrimaryInputs
end

--- Records that itemID was actually consumed as the primary input for
-- recipeID during a successful processing completion. Caller (Crafting's
-- CraftCompletionDispatcher) is responsible for gating this to operations
-- whose Processing Analysis policy is "EvaluateAllInputs" - this method
-- itself does not check policy, it only persists what it is told.
-- @param observation table { recipeID, processingType, policy, itemID, itemName, configKey, itemLink }
-- itemLink (optional) is the real hyperlink captured from the actual item
-- instance consumed - preferred over a freshly rebuilt itemID-only link by
-- consumers (e.g. Processing Analysis's icon quality-tier overlay) since it
-- is more likely to carry the item's true quality-specific markup.
function ProcessingOperationRegistry:RecordObservedPrimaryInput(observation)
    observation = type(observation) == "table" and observation or {}
    local recipeID = NormalizeID(observation.recipeID)
    local itemID = NormalizeID(observation.itemID)
    if not recipeID or not itemID then
        return false, "missingRecipeIDOrItemID"
    end

    local observedByRecipe = GetObservedInputTable()
    if not observedByRecipe then
        return false, "dbUnavailable"
    end

    local configKey = observation.configKey
    local dedupeKey = configKey or ("item:" .. tostring(itemID))
    local now = (PocketCFO and PocketCFO.GetServerNow and PocketCFO:GetServerNow()) or time()

    observedByRecipe[recipeID] = observedByRecipe[recipeID] or {}
    local existing = observedByRecipe[recipeID][dedupeKey]

    if existing then
        existing.lastObservedAt = now
        existing.observedCount = (tonumber(existing.observedCount) or 0) + 1
        existing.itemName = existing.itemName or observation.itemName
        existing.configKey = existing.configKey or configKey
        existing.itemLink = observation.itemLink or existing.itemLink
    else
        observedByRecipe[recipeID][dedupeKey] = {
            recipeID = recipeID,
            processingType = observation.processingType,
            policy = observation.policy,
            itemID = itemID,
            itemName = observation.itemName,
            configKey = configKey,
            itemLink = observation.itemLink,
            firstObservedAt = now,
            lastObservedAt = now,
            observedCount = 1,
        }
    end

    return true
end

-- Published starter primary inputs (OperationOutcomeSeedData.lua), so
-- seeded ore/herb Operation Profiles have a candidate row to render on.
-- Immutable code - never written into SavedVariables.
local function GetSeedPrimaryInputs(recipeID)
    local seed = (PocketCFO and PocketCFO.OperationOutcomeSeedData) or _G.PocketCFO_OperationOutcomeSeedData
    local byRecipe = seed and type(seed.primaryInputs) == "table" and seed.primaryInputs or nil
    return byRecipe and byRecipe[recipeID] or nil
end

--- Returns the primary inputs observed for recipeID - this user's
-- runtime-learned inputs plus seeded starter inputs, local first and
-- deduplicated by configKey - shaped like GetKnownPrimaryInputs candidates
-- ({ itemID, name, configKey, itemLink }), so "evaluate all inputs" policies
-- can merge both sources. Seeded entries carry no itemLink. Always returns a
-- table (empty when nothing has been observed or seeded).
function ProcessingOperationRegistry:GetObservedPrimaryInputs(recipeID)
    recipeID = NormalizeID(recipeID)
    if not recipeID then
        return {}
    end

    local observedByRecipe = GetObservedInputTable()
    local byDedupeKey = observedByRecipe and observedByRecipe[recipeID]

    local list = {}
    local seen = {}
    for dedupeKey, entry in pairs(byDedupeKey or {}) do
        list[#list + 1] = { itemID = entry.itemID, name = entry.itemName, configKey = entry.configKey, itemLink = entry.itemLink }
        seen[dedupeKey] = true
    end

    for _, entry in ipairs(GetSeedPrimaryInputs(recipeID) or {}) do
        local dedupeKey = entry.configKey or ("item:" .. tostring(entry.itemID))
        if not seen[dedupeKey] then
            list[#list + 1] = { itemID = entry.itemID, name = entry.itemName, configKey = entry.configKey }
            seen[dedupeKey] = true
        end
    end
    return list
end

if PocketCFO then
    PocketCFO.ProcessingOperationRegistry = ProcessingOperationRegistry
end

_G.PocketCFO_ProcessingOperationRegistry = ProcessingOperationRegistry

-- ---------------------------------------------------------------------------
-- Verified processing recipes (The War Within, verified in-game)
-- ---------------------------------------------------------------------------
-- Prospecting uses recipePlusPrimaryInput so each distinct ore input is a
-- separate Operation Profile (a single "Default" Statistical Profile per
-- profile, since the profile key already separates the ore). Crushing uses
-- recipeOnly; the selected gem is flagged statisticalProfile = true, so each
-- distinct gem becomes its own Statistical Profile within one Operation
-- Profile rather than splitting the profile key itself.

-- knownPrimaryInputs (the full ore list Prospecting Analysis renders as
-- comparison rows) is intentionally not populated yet - no ore itemIDs have
-- been verified in-game for this recipe. Until curated, Prospecting Analysis
-- honestly reports "no inputs registered" rather than guessing itemIDs.
ProcessingOperationRegistry:RegisterEntry({
    recipeID             = 1231127,
    processingType       = "prospecting",
    profileKeyMode       = ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT,
    primaryInputSlotRule = "first reagentType==1 slot; the ore selected by the player",
    inputRoles = {
        {
            key = "selectedOre",
            role = ProcessingOperationRegistry.INPUT_ROLE_PROFILE_DRIVER,
            deterministicOutputDriver = true,
            selectedCostInput = true,
            selected = true,
            reagentType = 1,
            quantityRequired = 5,
            slotRule = "selected ore slot; consumed quantity 5",
        },
    },
    knownPrimaryInputs = {
        -- { itemID = 000000, name = "Ore Name" },
    },
})

ProcessingOperationRegistry:RegisterEntry({
    recipeID             = 1233129,
    recipeName           = "Recycle Potions",
    profession           = 171,
    processingType       = "alchemyRecycling",
    profileKeyMode       = ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT,
    primaryInputSlotRule = "selected potion slot; consumed quantity 3",
    outputValuationMode  = "quantityOnly",
    unitAcquisitionOutputItemID = 242651,
    inputRoles = {
        {
            key = "selectedPotion",
            role = ProcessingOperationRegistry.INPUT_ROLE_PROFILE_DRIVER,
            deterministicOutputDriver = true,
            selectedCostInput = true,
            selected = true,
            reagentType = 1,
            quantityRequired = 3,
            slotRule = "selected potion slot; consumed quantity 3",
        },
        {
            key = "oilOfHeartwood",
            role = ProcessingOperationRegistry.INPUT_ROLE_FIXED_CATALYST,
            fixedCatalyst = true,
            selected = false,
            quantityRequired = 2,
            fixedItemID = 247811,
            slotRule = "fixed Oil of Heartwood input; consumed quantity 2",
        },
    },
    knownPrimaryInputs = {
        -- Intentionally empty. Blizzard owns the selectable potion list;
        -- PocketCFO learns exact inputs only from completed recycling runs.
    },
    knownOutputs = {
        { itemID = 242651, name = "Stabilized Derivate", quantityOnly = true },
    },
})

ProcessingOperationRegistry:RegisterEntry({
    recipeID             = 1233130,
    recipeName           = "Recycle Flasks",
    profession           = 171,
    processingType       = "alchemyRecycling",
    profileKeyMode       = ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT,
    primaryInputSlotRule = "selected flask slot; consumed quantity 1",
    outputValuationMode  = "quantityOnly",
    unitAcquisitionOutputItemID = 242651,
    inputRoles = {
        {
            key = "selectedFlask",
            role = ProcessingOperationRegistry.INPUT_ROLE_PROFILE_DRIVER,
            deterministicOutputDriver = true,
            selectedCostInput = true,
            selected = true,
            reagentType = 1,
            quantityRequired = 1,
            slotRule = "selected flask slot; consumed quantity 1",
        },
        {
            key = "oilOfHeartwood",
            role = ProcessingOperationRegistry.INPUT_ROLE_FIXED_CATALYST,
            fixedCatalyst = true,
            selected = false,
            quantityRequired = 2,
            fixedItemID = 247811,
            slotRule = "fixed Oil of Heartwood input; consumed quantity 2",
        },
    },
    knownPrimaryInputs = {
        -- Intentionally empty. Blizzard owns the selectable flask list;
        -- PocketCFO learns exact inputs only from completed recycling runs.
    },
    knownOutputs = {
        { itemID = 242651, name = "Stabilized Derivate", quantityOnly = true },
    },
})

-- Milling uses recipePlusPrimaryInput, same mechanism as Prospecting: each
-- distinct herb input (already separated by quality, since low/high quality
-- raw materials are distinct itemIDs - confirmed via the Crushing gem/dust
-- itemID pairs in CrushingOutcomeRepairDiag) is its own Operation Profile.
-- reagentType=1 mirrors Prospecting's ore slot / Crushing's gem slot pattern
-- for "the material the player selects to process" - THEORETICAL for
-- Milling specifically, not yet confirmed in-game against the live Midnight
-- Milling recipe schematic. knownPrimaryInputs is intentionally left empty;
-- see ProcessingAnalysisController's GetRegisteredPrimaryInputCandidates -
-- CraftCompletionDispatcher's RecordObservedPrimaryInputIfApplicable grows
-- this list automatically from real completed crafts for
-- EvaluateAllInputs-policy operation types (Prospecting, Milling).
ProcessingOperationRegistry:RegisterEntry({
    recipeID             = 1269575,
    processingType       = "milling",
    profileKeyMode       = ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT,
    primaryInputSlotRule = "first reagentType==1 slot; the herb selected by the player (mirrors Prospecting's ore slot pattern - unverified in-game for Milling)",
    inputRoles = {
        {
            key = "selectedHerb",
            role = ProcessingOperationRegistry.INPUT_ROLE_PROFILE_DRIVER,
            deterministicOutputDriver = true,
            selectedCostInput = true,
            selected = true,
            reagentType = 1,
            quantityRequired = 10,
            slotRule = "selected herb slot; consumed quantity 10",
        },
    },
    knownPrimaryInputs = {
        -- Intentionally empty - no herb itemIDs curated. See comment above.
    },
})

ProcessingOperationRegistry:RegisterEntry({
    recipeID             = 1231132,
    processingType       = "crushing",
    profileKeyMode       = ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_ONLY,
    primaryInputSlotRule = "selected gem slot is evidence only; official profileKey is recipe-only",
    inputRoles = {
        {
            key = "selectedGem",
            role = ProcessingOperationRegistry.INPUT_ROLE_SELECTED_COST_INPUT,
            selectedCostInput = true,
            selected = true,
            statisticalProfile = true,
            reagentType = 1,
            quantityRequired = 3,
            slotRule = "selected gem slot; consumed quantity 3; evidence only",
        },
        {
            key = "duskshroudedStone",
            role = ProcessingOperationRegistry.INPUT_ROLE_FIXED_CATALYST,
            fixedCatalyst = true,
            selected = false,
            quantityRequired = 1,
            slotRule = "fixed Duskshrouded Stone catalyst; consumed quantity 1",
        },
    },
})

ProcessingOperationRegistry:RegisterEntry({
    recipeID             = 1229930,
    recipeName           = "Midnight Recycling",
    profession           = 202,
    processingType       = "engineeringRecycling",
    profileKeyMode       = ProcessingOperationRegistry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT,
    primaryInputSlotRule = "selected recyclable reagent slot; transaction allocation quantity 5",
    inputRoles = {
        {
            key = "selectedRecyclable",
            role = ProcessingOperationRegistry.INPUT_ROLE_PROFILE_DRIVER,
            deterministicOutputDriver = true,
            selectedCostInput = true,
            selected = true,
            reagentType = 1,
            quantityRequired = 5,
            slotRule = "selected recyclable reagent slot; consumed quantity 5",
        },
    },
    knownPrimaryInputs = {
        -- Intentionally empty. Blizzard owns the selectable recyclable list;
        -- PocketCFO learns exact inputs only from completed recycling runs.
    },
})
