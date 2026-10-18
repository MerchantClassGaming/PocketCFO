-- PocketCFO/Services/ResourcefulnessPredictionService/ResourcefulnessPredictionService.lua
-- Deterministic Resourcefulness prediction: given a displayed
-- Resourcefulness % and a set of reagents, predicts the expected returned
-- quantity per reagent using the published empirical model.
--
-- A pure function of its inputs. No historical observations, no statistical
-- profiles, no OperationOutcomeService dependency, no valuation, no
-- economics, no persistence, no UI, and no knowledge of Orders, Crafting, or
-- Processing. Reusable by Orders, future Craft Preview, Shopping, VCM, and
-- any future pre-craft workflow.
--
-- Owns exactly two things:
--   1. The centralized Resourcefulness eligibility exclusion registry
--      (EXCLUDED_REAGENT_CONFIG_KEYS below - add new exclusions here only,
--      never as scattered if-statements elsewhere).
--   2. The empirical prediction formula (EMPIRICAL_RETURN_COEFFICIENT).
--
-- The caller supplies the full reagent list; this service applies the
-- exclusion policy itself. It does not require recipe-specific knowledge,
-- does not inspect Blizzard recipe metadata, and does not infer returnability
-- from profession type.

local PocketCFO = _G.PocketCFO

local ResourcefulnessPredictionService = {}

-- Published, deterministic empirical coefficient. Single source of truth -
-- do not duplicate this literal anywhere else in the codebase.
local EMPIRICAL_RETURN_COEFFICIENT = 0.45

-- Centralized Resourcefulness eligibility exclusion registry.
--
-- Add a new exclusion by adding one entry here - nowhere else in the
-- codebase should special-case a reagent out of Resourcefulness prediction.
-- Keyed by the reagent's configKey (PocketCFO's opaque, canonical item
-- reference - see PocketCFO/CLAUDE.md "ConfigKey Is The Canonical Item
-- Reference"); value is a human-readable label used only for diagnostics.
--
-- Confirmed exclusions (Brian-provided item IDs), resolved to canonical
-- configKeys via ItemIdentityService's own deterministic rules rather than
-- hand-built: none of these four items are equippable gear or profession
-- tools/accessories (VariantResolver only appends an ilvl or stat suffix for
-- those categories), so ConfigKeyBuilder's matchingPath is "itemID" for all
-- of them, giving the plain "pcfo|item|v1|id:<itemID>|path:itemID" form.
--   256559 - Galactic Combatant's Heraldry
--   232875 - Spark of Radiance
--   245345 - Fused Vitality
--   256607 - Galactic Aspirant's Heraldry
--   256963 - Thalassian Lumber (Home Decor woodworking lumber)
--   248012 - Dornic Fir Lumber (Home Decor woodworking lumber)
-- Add further lumber (or other) exclusions here, in this same configKey
-- format, as they are identified - never as scattered if-statements.
local EXCLUDED_REAGENT_CONFIG_KEYS = {
    ["pcfo|item|v1|id:256559|path:itemID"] = "Galactic Combatant's Heraldry",
    ["pcfo|item|v1|id:232875|path:itemID"] = "Spark of Radiance",
    ["pcfo|item|v1|id:245345|path:itemID"] = "Fused Vitality",
    ["pcfo|item|v1|id:256607|path:itemID"] = "Galactic Aspirant's Heraldry",
    ["pcfo|item|v1|id:256963|path:itemID"] = "Thalassian Lumber",
    ["pcfo|item|v1|id:248012|path:itemID"] = "Dornic Fir Lumber",
}

--- Returns true if a reagent (identified by configKey) participates in
-- Resourcefulness prediction, false if it is centrally excluded. A reagent
-- with no configKey is treated as eligible (unresolved identity is not this
-- service's concern - the caller owns identity resolution).
local function IsEligibleForResourcefulness(configKey)
    if not configKey then
        return true
    end
    return EXCLUDED_REAGENT_CONFIG_KEYS[configKey] == nil
end

--- Predicts expected Resourcefulness-returned material quantities.
-- @param params table {
--     displayedResourcefulnessPct = number,
--     reagents = { { configKey = string, quantity = number }, ... },
-- }
-- @return table {
--     expectedReturnedReagents = { { configKey = string, expectedQuantity = number }, ... },
--     expectedReturnedQuantity = number,
--     diagnostics = { coefficient, displayedPct, excludedReagents },
-- }
function ResourcefulnessPredictionService:PredictExpectedReturns(params)
    params = type(params) == "table" and params or {}

    local displayedPct = tonumber(params.displayedResourcefulnessPct) or 0
    local reagents = type(params.reagents) == "table" and params.reagents or {}

    local expectedReturnedReagents = {}
    local expectedReturnedQuantity = 0
    local excludedReagents = {}

    for _, reagent in ipairs(reagents) do
        local configKey = type(reagent) == "table" and reagent.configKey or nil
        local eligibleQuantity = (type(reagent) == "table" and tonumber(reagent.quantity)) or 0

        if IsEligibleForResourcefulness(configKey) then
            local expectedQuantity = eligibleQuantity * (displayedPct / 100) * EMPIRICAL_RETURN_COEFFICIENT
            expectedReturnedReagents[#expectedReturnedReagents + 1] = {
                configKey = configKey,
                expectedQuantity = expectedQuantity,
            }
            expectedReturnedQuantity = expectedReturnedQuantity + expectedQuantity
        else
            excludedReagents[#excludedReagents + 1] = configKey
        end
    end

    return {
        expectedReturnedReagents = expectedReturnedReagents,
        expectedReturnedQuantity = expectedReturnedQuantity,
        diagnostics = {
            coefficient = EMPIRICAL_RETURN_COEFFICIENT,
            displayedPct = displayedPct,
            excludedReagents = excludedReagents,
        },
    }
end

-- Exposed read-only so diagnostics/UI can display the published coefficient
-- and the active exclusion registry without hand-copying values.
ResourcefulnessPredictionService.EMPIRICAL_RETURN_COEFFICIENT = EMPIRICAL_RETURN_COEFFICIENT
ResourcefulnessPredictionService.EXCLUDED_REAGENT_CONFIG_KEYS = EXCLUDED_REAGENT_CONFIG_KEYS

if PocketCFO then
    PocketCFO.ResourcefulnessPredictionService = ResourcefulnessPredictionService
end

_G.PocketCFO_ResourcefulnessPredictionService = ResourcefulnessPredictionService
