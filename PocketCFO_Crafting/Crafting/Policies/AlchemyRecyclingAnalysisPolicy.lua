-- PocketCFO_Crafting/Crafting/Policies/AlchemyRecyclingAnalysisPolicy.lua
-- Alchemy Recycling analysis metadata. Stabilized Derivate is a quantity-only
-- output, so this policy ranks inputs by acquisition cost per Derivate rather
-- than profit.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local AlchemyRecyclingAnalysisPolicy = PocketCFO_Crafting:NewModule("AlchemyRecyclingAnalysisPolicy")
PocketCFO_Crafting.AlchemyRecyclingAnalysisPolicy = AlchemyRecyclingAnalysisPolicy

AlchemyRecyclingAnalysisPolicy.PROCESSING_TYPE = "alchemyRecycling"
AlchemyRecyclingAnalysisPolicy.TITLE = "Alchemy Recycling"
AlchemyRecyclingAnalysisPolicy.analysisMode = "unitAcquisitionCost"
AlchemyRecyclingAnalysisPolicy.outputItemID = 242651
AlchemyRecyclingAnalysisPolicy.outputItemName = "Stabilized Derivate"
AlchemyRecyclingAnalysisPolicy.analysisInfoTooltip = {
    title = "Stabilized Derivate acquisition cost",
    text = "Ranks observed potion and flask recycling profiles by current expected cost per Stabilized Derivate. The Derivate itself is not assigned a market value.",
}

function AlchemyRecyclingAnalysisPolicy:SortDisplayRows(rows)
    if type(rows) ~= "table" then
        return
    end
    table.sort(rows, function(a, b)
        local costA = a.currentCostPerUnitOutput
        local costB = b.currentCostPerUnitOutput
        if costA ~= nil and costB ~= nil and costA ~= costB then
            return costA < costB
        end
        if costA ~= nil and costB == nil then return true end
        if costA == nil and costB ~= nil then return false end
        return tostring(a.itemLabel or "") < tostring(b.itemLabel or "")
    end)
end

function AlchemyRecyclingAnalysisPolicy:OnEnable()
end

function AlchemyRecyclingAnalysisPolicy:OnDisable()
end
