-- PocketCFO_Crafting/Services/ProcessingAnalysisRegistry/ProcessingAnalysisRegistry.lua
-- Static map of supported Processing Analysis categories to their
-- recommendation policy and display category label.
--
-- This is Crafting-side analysis taxonomy, not recipe data. It contains no
-- recipeIDs - those are owned by Core's ProcessingOperationRegistry
-- (PocketCFO/Services/ProcessingOperationRegistry), which is still empty
-- pending verified/captured data. A processingType listed here only
-- becomes reachable once a curated ProcessingOperationRegistry entry tags
-- a real recipeID with a matching processingType string.
--
-- MVP policy assignments (PocketCFO Docs/Implementation plan rev1.md, section 6):
--   Prospecting           -> EvaluateAllInputs
--   Milling                -> EvaluateAllInputs
--   Crushing                -> RecommendTopNPerOutputFamily (all known observed
--                              gem statistical profiles, grouped/ranked by
--                              output quality tier - see CrushingAnalysisPolicy;
--                              does not depend on the live selected gem)
--   Engineering Recycling   -> RecommendTopNPerOutputFamily
--   Alchemy Recycling       -> RecommendCheapestInput

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local ProcessingAnalysisRegistry = PocketCFO_Crafting:NewModule("ProcessingAnalysisRegistry")
PocketCFO_Crafting.ProcessingAnalysisRegistry = ProcessingAnalysisRegistry

ProcessingAnalysisRegistry.PROCESSING_TYPE_PROSPECTING = "prospecting"
ProcessingAnalysisRegistry.PROCESSING_TYPE_MILLING = "milling"
ProcessingAnalysisRegistry.PROCESSING_TYPE_CRUSHING = "crushing"
ProcessingAnalysisRegistry.PROCESSING_TYPE_ENGINEERING_RECYCLING = "engineeringRecycling"
ProcessingAnalysisRegistry.PROCESSING_TYPE_ALCHEMY_RECYCLING = "alchemyRecycling"

local POLICY_EVALUATE_ALL_INPUTS = "EvaluateAllInputs"
local POLICY_RECOMMEND_CHEAPEST_INPUT = "RecommendCheapestInput"
local POLICY_RECOMMEND_BEST_INPUT_PER_OUTPUT_FAMILY = "RecommendBestInputPerOutputFamily"
local POLICY_RECOMMEND_TOP_N_PER_OUTPUT_FAMILY = "RecommendTopNPerOutputFamily"

ProcessingAnalysisRegistry.entriesByProcessingType = {
    [ProcessingAnalysisRegistry.PROCESSING_TYPE_PROSPECTING] = {
        processingType = ProcessingAnalysisRegistry.PROCESSING_TYPE_PROSPECTING,
        policyName = POLICY_EVALUATE_ALL_INPUTS,
        label = "Prospecting",
    },
    [ProcessingAnalysisRegistry.PROCESSING_TYPE_MILLING] = {
        processingType = ProcessingAnalysisRegistry.PROCESSING_TYPE_MILLING,
        policyName = POLICY_EVALUATE_ALL_INPUTS,
        label = "Milling",
    },
    [ProcessingAnalysisRegistry.PROCESSING_TYPE_CRUSHING] = {
        processingType = ProcessingAnalysisRegistry.PROCESSING_TYPE_CRUSHING,
        policyName = POLICY_RECOMMEND_TOP_N_PER_OUTPUT_FAMILY,
        label = "Crushing",
    },
    [ProcessingAnalysisRegistry.PROCESSING_TYPE_ENGINEERING_RECYCLING] = {
        processingType = ProcessingAnalysisRegistry.PROCESSING_TYPE_ENGINEERING_RECYCLING,
        policyName = POLICY_RECOMMEND_TOP_N_PER_OUTPUT_FAMILY,
        label = "Engineering Recycling",
    },
    [ProcessingAnalysisRegistry.PROCESSING_TYPE_ALCHEMY_RECYCLING] = {
        processingType = ProcessingAnalysisRegistry.PROCESSING_TYPE_ALCHEMY_RECYCLING,
        policyName = POLICY_RECOMMEND_CHEAPEST_INPUT,
        label = "Alchemy Recycling",
        candidateSource = "observedOperationProfiles",
    },
}

function ProcessingAnalysisRegistry:GetEntry(processingType)
    if not processingType then
        return nil
    end
    return self.entriesByProcessingType[processingType]
end

function ProcessingAnalysisRegistry:IsSupportedProcessingType(processingType)
    return self:GetEntry(processingType) ~= nil
end

function ProcessingAnalysisRegistry:GetPolicyForProcessingType(processingType)
    local entry = self:GetEntry(processingType)
    return entry and entry.policyName
end

function ProcessingAnalysisRegistry:GetLabelForProcessingType(processingType)
    local entry = self:GetEntry(processingType)
    return entry and entry.label
end

function ProcessingAnalysisRegistry:ListSupportedProcessingTypes()
    local types = {}
    for processingType in pairs(self.entriesByProcessingType) do
        types[#types + 1] = processingType
    end
    table.sort(types)
    return types
end

function ProcessingAnalysisRegistry:OnEnable()
end

function ProcessingAnalysisRegistry:OnDisable()
end
