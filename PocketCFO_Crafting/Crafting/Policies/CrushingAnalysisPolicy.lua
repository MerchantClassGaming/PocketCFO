-- PocketCFO_Crafting/Crafting/Policies/CrushingAnalysisPolicy.lua
-- Crushing-specific Processing Analysis metadata: owns the two output
-- quality-tier families ("Low-Quality Outputs" / "High-Quality Outputs")
-- Crushing's Analysis recommendation groups by - per architecture,
-- "Crushing recommendation policy owns output families and ranking."
--
-- ProcessingAnalysisController resolves this module by naming convention
-- (processingType "crushing" -> module "CrushingAnalysisPolicy"), the same
-- way it already resolves ProspectingAnalysisPolicy, and asks it to
-- classify each candidate's resolved quality tier into a family key/label
-- rather than hardcoding Crushing's families in the controller.
--
-- Family membership is keyed by the SELECTED GEM's own crafting-reagent
-- quality tier (1, 2, ...) - resolved the same way
-- ProcessingAnalysisController already resolves live reagent quality
-- (IdentityAdapters:GetReagentCraftingQuality), just from a stored itemID
-- instead of a live reagent slot object. This never depends on or guesses
-- specific produced-output item IDs (e.g. a distinct "Glass" item) - only
-- the gem's own quality tier, which C_TradeSkillUI already reports per
-- itemID. The "Q1 Dust + Q1 Glass" / "Q2 Dust + Q2 Glass" wording is
-- curated display text describing what that tier represents, not a
-- computed fact about this specific recipe's observed output basket.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local CrushingAnalysisPolicy = PocketCFO_Crafting:NewModule("CrushingAnalysisPolicy")
PocketCFO_Crafting.CrushingAnalysisPolicy = CrushingAnalysisPolicy

CrushingAnalysisPolicy.PROCESSING_TYPE = "crushing"
CrushingAnalysisPolicy.TITLE = "Crushing Analysis"
CrushingAnalysisPolicy.analysisInfoTooltip = {
    title = "Crushing output quality",
    text = "PocketCFO expects the quality of Crushing dust and glass to match the quality of the gems used. If the output quality does not match the gem quality, that craft is excluded from the observed results.",
}

CrushingAnalysisPolicy.FAMILY_LOW_QUALITY = "lowQualityOutputs"
CrushingAnalysisPolicy.FAMILY_HIGH_QUALITY = "highQualityOutputs"

-- Quality tier -> output family. Curated here (not derived/guessed) so a
-- gem's own resolved crafting-reagent quality tier maps to exactly one
-- recommendation group. Additional tiers can be added here without
-- touching the controller or the recommendation policy.
local FAMILY_BY_QUALITY_TIER = {
    [1] = { key = CrushingAnalysisPolicy.FAMILY_LOW_QUALITY,  label = "Low-Quality Outputs - Q1 Dust + Q1 Glass" },
    [2] = { key = CrushingAnalysisPolicy.FAMILY_HIGH_QUALITY, label = "High-Quality Outputs - Q2 Dust + Q2 Glass" },
}

--- Resolves the output family (key, label) a candidate belongs to, from
-- that candidate's own resolved crafting-reagent quality tier.
-- @param qualityTier number|nil
-- @return string|nil familyKey, string|nil familyLabel - nil, nil for an
--         unresolved/uncurated tier; such a candidate is left out of every
--         group rather than guessed into one.
function CrushingAnalysisPolicy:ResolveOutputFamily(qualityTier)
    local family = FAMILY_BY_QUALITY_TIER[tonumber(qualityTier)]
    if not family then
        return nil, nil
    end
    return family.key, family.label
end

function CrushingAnalysisPolicy:OnEnable()
end

function CrushingAnalysisPolicy:OnDisable()
end
