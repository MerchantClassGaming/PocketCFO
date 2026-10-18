-- PocketCFO/Services/CraftAnalysisEligibilityPolicy/CraftAnalysisEligibilityPolicy.lua
-- Curated registry of which ordinary (non-processing) Crafting Operation
-- recipeIDs are enabled for the ordinary Craft Analysis pilot.
--
-- This is the ONLY place that knows which ordinary recipes participate in
-- Craft Analysis. It must never classify a recipe as processing (that is
-- ProcessingOperationRegistry's job) and OperationOutcomeService must never
-- hardcode this recipe list itself.
--
-- Entries are added only after the recipeID has been verified (curated the
-- same way ProcessingOperationRegistry requires - see its header comment
-- "Do not guess recipeIDs"). Do not invent recipeIDs from memory or from
-- external sources; confirm them in-game (e.g. via /mcgd or the recipe
-- tooltip) or against Blizzard's own client data first.

local PocketCFO = _G.PocketCFO

local CraftAnalysisEligibilityPolicy = {}

-- enabledRecipeIDs[recipeID] = { recipeID = number, recipeName = string }
CraftAnalysisEligibilityPolicy.enabledRecipeIDs = CraftAnalysisEligibilityPolicy.enabledRecipeIDs or {}

local function NormalizeID(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

function CraftAnalysisEligibilityPolicy:Register(recipeID, recipeName)
    recipeID = NormalizeID(recipeID)
    if not recipeID then
        return false, "missingRecipeID"
    end
    self.enabledRecipeIDs[recipeID] = { recipeID = recipeID, recipeName = recipeName }
    return true
end

--- True if recipeID is enabled for the ordinary Craft Analysis pilot.
function CraftAnalysisEligibilityPolicy:IsEnabled(recipeID)
    recipeID = NormalizeID(recipeID)
    if not recipeID then
        return false
    end
    return self.enabledRecipeIDs[recipeID] ~= nil
end

--- Returns the curated entry (recipeID, recipeName) for one enabled
-- recipeID, or nil if it is not enabled.
function CraftAnalysisEligibilityPolicy:GetEntry(recipeID)
    recipeID = NormalizeID(recipeID)
    if not recipeID then
        return nil
    end
    return self.enabledRecipeIDs[recipeID]
end

--- Returns every enabled recipeID entry, for diagnostics/enumeration.
function CraftAnalysisEligibilityPolicy:ListEnabled()
    local list = {}
    for _, entry in pairs(self.enabledRecipeIDs) do
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b) return a.recipeID < b.recipeID end)
    return list
end

if PocketCFO then
    PocketCFO.CraftAnalysisEligibilityPolicy = CraftAnalysisEligibilityPolicy
end

_G.PocketCFO_CraftAnalysisEligibilityPolicy = CraftAnalysisEligibilityPolicy

-- ---------------------------------------------------------------------------
-- Pilot recipes (Midnight Inscription reagents)
-- ---------------------------------------------------------------------------
-- Confirmed recipeIDs (supplied 2026-07-11). Not registered in
-- ProcessingOperationRegistry - these are ordinary Crafting Operations, and
-- OperationProfileKeyService already treats any unregistered recipeID as
-- "crafting" by default.
CraftAnalysisEligibilityPolicy:Register(1230018, "Codified Azeroot")
CraftAnalysisEligibilityPolicy:Register(1230019, "Soul Cipher")
CraftAnalysisEligibilityPolicy:Register(1230016, "Sienna Ink")
CraftAnalysisEligibilityPolicy:Register(1230017, "Munsell Ink")
