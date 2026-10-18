-- PocketCFO_Crafting/Crafting/CraftAnalysisDisplayModelBuilder.lua
-- Craft Analysis-only extension of ProcessingAnalysisDisplayModelBuilder.
--
-- Reuses the shared/neutral builder for everything Processing Analysis and
-- Craft Analysis have in common (label formatting, status classification,
-- economics value rows, expected/craft, ROI) and adds only the craft-only
-- multicraft production fields Processing Analysis must never show
-- (processing operations do not support multicraft).
--
-- Owns no economics or quantity math of its own: every field here is either
-- read verbatim from OperationEconomicsService's Operation Summary (already
-- attached to the row by the shared builder) or derived by simple
-- subtraction of two of that summary's already-computed fields. This keeps
-- ProcessingAnalysisDisplayModelBuilder itself completely unaware of
-- multicraft/craft-only concepts - Processing rows never carry
-- row.craftProduction, so the window's rendering only ever shows the
-- section for a Craft Analysis detail row.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local CraftAnalysisDisplayModelBuilder = PocketCFO_Crafting:NewModule("CraftAnalysisDisplayModelBuilder")

local function GetSharedBuilder()
    return PocketCFO_Crafting:GetModule("ProcessingAnalysisDisplayModelBuilder", true)
end

-- a - b, nil-safe: nil (not a fabricated zero) if either operand is itself
-- unresolved, so a missing summary field never silently becomes zero here.
local function SafeSubtract(a, b)
    if a == nil or b == nil then
        return nil
    end
    return a - b
end

--- Builds the compact list row for one produced-output ConfigKey Statistical
-- Profile. Delegates entirely to the shared builder - Craft Analysis has no
-- output-family grouping and no craft-only fields belong on the list row
-- itself (multicraft detail is detail-view-only, per the recommended
-- display structure).
function CraftAnalysisDisplayModelBuilder:BuildRow(itemLabel, summary, extra)
    local shared = GetSharedBuilder()
    if not shared then
        return nil
    end
    return shared:BuildRow(itemLabel, summary, extra)
end

--- Builds the expanded detail-view model for one Craft Analysis row,
-- extending the shared economics detail row with a craft-only
-- `row.craftProduction` block. Every field is read from `summary` (already
-- computed by OperationEconomicsService:SummarizeStatisticalProfile) or
-- derived by simple arithmetic over two of its already-computed fields -
-- never a new economics/quantity calculation performed here.
function CraftAnalysisDisplayModelBuilder:BuildDetailRow(itemLabel, summary, extra)
    local shared = GetSharedBuilder()
    if not shared then
        return nil
    end

    local row = shared:BuildDetailRow(itemLabel, summary, extra)
    summary = type(summary) == "table" and summary or {}

    row.craftProduction = {
        runsObserved = summary.observationCount or 0,
        averageBaseOutputPerCraft = summary.avgBaseOutputPerCraft,
        multicraftProcRate = summary.multicraftProcRate,
        averageMulticraftBonusPerProc = summary.avgMulticraftBonusWhenProcs,
        averageTotalOutputWhenMulticraftProcs = summary.avgTotalOutputWhenMulticraftProcs,
        -- averageTotalOutputPerCraft - averageBaseOutputPerCraft is exactly
        -- multicraftExtraTotal / runCount (both operands already divide by
        -- the same runCount denominator), so this is arithmetic over two
        -- already-computed summary fields, not a re-derivation from raw
        -- stored totals.
        averageMulticraftBonusPerCraft = SafeSubtract(summary.avgTotalOutputPerCraft, summary.avgBaseOutputPerCraft),
        averageTotalOutputPerCraft = summary.avgTotalOutputPerCraft,
    }

    return row
end

if PocketCFO_Crafting then
    PocketCFO_Crafting.CraftAnalysisDisplayModelBuilder = CraftAnalysisDisplayModelBuilder
end
