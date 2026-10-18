-- PocketCFO_Crafting/Crafting/Policies/MillingAnalysisPolicy.lua
-- Milling-specific Processing Analysis metadata.
--
-- ProcessingAnalysisController resolves a dedicated policy module by naming
-- convention (processingType "milling" -> module "MillingAnalysisPolicy"),
-- the same way it already resolves ProspectingAnalysisPolicy and
-- CrushingAnalysisPolicy.
--
-- Row survival is EvaluateAllInputs, shared with Prospecting (see
-- ProspectingAnalysisPolicy) - "show every observed/registered herb input",
-- never a Top N slice. Milling additionally groups its rows by the
-- selected herb's OWN crafting-reagent quality tier (ResolveOutputFamily,
-- same mechanism CrushingAnalysisPolicy uses for its gem quality-tier
-- families) into "Low-Quality Herbs" / "High-Quality Herbs" sections, and
-- orders rows alphabetically within each section (SortDisplayRows) rather
-- than by expected value - Milling Analysis is input-oriented, not a
-- profitability ranking.
--
-- Because Milling's grouping is presentation-only (every row still renders,
-- never limited to a top slice), ProcessingAnalysisController's
-- supportsResultsLimit flag stays false for this policy even though rows
-- carry an outputFamilyKey - see ProcessingAnalysisController.EvaluateRecipe
-- and CraftQueueController's Top/All Results toggle gating. Do not confuse
-- "grouped for display" (outputFamilyKey/hasOutputFamilies) with "supports
-- the Top Results limit" (supportsResultsLimit) - only Crushing's
-- RecommendTopNPerOutputFamily policy sets the latter.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local MillingAnalysisPolicy = PocketCFO_Crafting:NewModule("MillingAnalysisPolicy")
PocketCFO_Crafting.MillingAnalysisPolicy = MillingAnalysisPolicy

MillingAnalysisPolicy.PROCESSING_TYPE = "milling"
MillingAnalysisPolicy.TITLE = "Milling Analysis"
MillingAnalysisPolicy.analysisInfoTooltip = {
    title = "Milling output quality",
    text = "PocketCFO requires Milling pigment quality to exactly match the quality of the herb used. If the output quality does not match the herb quality (in either direction), that craft is excluded from the observed results.",
}

MillingAnalysisPolicy.FAMILY_LOW_QUALITY = "lowQualityHerbs"
MillingAnalysisPolicy.FAMILY_HIGH_QUALITY = "highQualityHerbs"

-- Herb quality tier -> display family. Curated here (not derived/guessed) so
-- a herb's own resolved crafting-reagent quality tier maps to exactly one
-- section, ordered low before high. Additional tiers can be added here
-- without touching the controller or the recommendation policy.
local FAMILY_BY_QUALITY_TIER = {
    [1] = { key = MillingAnalysisPolicy.FAMILY_LOW_QUALITY,  label = "Low-Quality Herbs",  order = 1 },
    [2] = { key = MillingAnalysisPolicy.FAMILY_HIGH_QUALITY, label = "High-Quality Herbs", order = 2 },
}

--- Resolves the display family (key, label) a herb candidate belongs to,
-- from that candidate's own resolved crafting-reagent quality tier.
-- @param qualityTier number|nil
-- @return string|nil familyKey, string|nil familyLabel - nil, nil for an
--         unresolved/uncurated tier; such a candidate is left out of every
--         group rather than guessed into one.
function MillingAnalysisPolicy:ResolveOutputFamily(qualityTier)
    local family = FAMILY_BY_QUALITY_TIER[tonumber(qualityTier)]
    if not family then
        return nil, nil
    end
    return family.key, family.label
end

-- Ranking order for each family key, used only to order sections low-before-
-- high; row order WITHIN a section comes from the alphabetical sort below.
local ORDER_BY_FAMILY_KEY = {}
for _, family in pairs(FAMILY_BY_QUALITY_TIER) do
    ORDER_BY_FAMILY_KEY[family.key] = family.order
end

--- Orders already-built display rows (in place) for Milling Analysis:
-- Low-Quality Herbs before High-Quality Herbs, then alphabetically by
-- itemLabel within each group. Called generically by
-- ProcessingAnalysisController for any dedicated policy module that defines
-- this hook - Crushing does not define it, so its rows keep the
-- economics-ranked order ProcessingRecommendationPolicy already produced.
function MillingAnalysisPolicy:SortDisplayRows(rows)
    if type(rows) ~= "table" then
        return
    end
    table.sort(rows, function(a, b)
        local orderA = ORDER_BY_FAMILY_KEY[a.outputFamilyKey] or math.huge
        local orderB = ORDER_BY_FAMILY_KEY[b.outputFamilyKey] or math.huge
        if orderA ~= orderB then
            return orderA < orderB
        end
        return tostring(a.itemLabel or "") < tostring(b.itemLabel or "")
    end)
end

function MillingAnalysisPolicy:OnEnable()
end

function MillingAnalysisPolicy:OnDisable()
end
