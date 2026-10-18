-- PocketCFO_Crafting/Crafting/Policies/ProspectingAnalysisPolicy.lua
-- Prospecting-specific Processing Analysis metadata.
--
-- ProcessingAnalysisController resolves a dedicated policy module by naming
-- convention (processingType "prospecting" -> module "ProspectingAnalysisPolicy")
-- and, when one exists, prefers its .TITLE over ProcessingAnalysisRegistry's
-- generic label - this is "the policy provides the analysis title", per
-- architecture, without hardcoding processing-type titles in the window or
-- duplicating the registry's supported-type gate.
--
-- Row survival for Prospecting is "show every scoped candidate input" -
-- already exactly what ProcessingRecommendationPolicy.EvaluateAllInputs
-- does, and that policy is shared with Milling for the same reason. This
-- module does not reimplement it. Candidate scoping (which ores are valid
-- for this recipe) comes from Core's ProcessingOperationRegistry's curated
-- knownPrimaryInputs list - deliberately not the live recipe schematic's
-- reagent slot, since Prospecting Analysis must render without a selected
-- ore. An empty knownPrimaryInputs list is an honest "not curated yet"
-- empty state, not a failure.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local ProspectingAnalysisPolicy = PocketCFO_Crafting:NewModule("ProspectingAnalysisPolicy")
PocketCFO_Crafting.ProspectingAnalysisPolicy = ProspectingAnalysisPolicy

ProspectingAnalysisPolicy.PROCESSING_TYPE = "prospecting"
ProspectingAnalysisPolicy.TITLE = "Prospecting Analysis"

function ProspectingAnalysisPolicy:OnEnable()
end

function ProspectingAnalysisPolicy:OnDisable()
end
