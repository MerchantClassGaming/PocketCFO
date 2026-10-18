-- PocketCFO_Crafting/Crafting/LureAnalysisService.lua
-- Answers: "Is crafting this skinning lure worth it?" for the five Midnight
-- great beast lures.
--
--   lure cost      = the lure recipe's Cost to Make (RecipeEconomicsService,
--                    same number the normal Recipe Analysis shows), per lure
--   average return = average kill loot + skin per skin for that beast
--                    (BeastSkinCapture running average, core),
--                    each item at today's full PocketCFO value (no AH cut,
--                    same basis as the reagents in lure cost - Brian)
--   profit         = average return - lure cost
--
-- The game only gives full reagent details for the selected recipe, so each
-- time a lure recipe is viewed its observation (reagents, Resourcefulness %,
-- Multicraft %) is saved. The other lures' costs are re-priced from those
-- saved observations with today's values via
-- RecipeEconomicsService:EvaluateObservation - no cost math here.
--
-- Storage: PocketCFO_Crafting_DB.global.lureRecipes[lureItemID] = observation

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local LureAnalysisService = PocketCFO_Crafting:NewModule("LureAnalysisService")

local function GetCapture()
    return PocketCFO and PocketCFO.BeastSkinCapture or nil
end

local function GetEconomicsService()
    return PocketCFO_Crafting:GetModule("RecipeEconomicsService", true)
end

-- Never force-loads PocketCFO_Valuation (same pattern as RecipeEconomicsService).
local function GetValuationService()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_Valuation"))
        or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_Valuation"))
    if not loaded then
        return nil
    end
    local valuation = _G.PocketCFO_Valuation
    local service = valuation and valuation.GetModule and valuation:GetModule("ValuationService", true)
    if service and type(service.GetItemValue) == "function" then
        return service
    end
    return nil
end

local function SavedLureRecipes()
    local db = PocketCFO_Crafting.db and PocketCFO_Crafting.db.global
    if not db then
        return nil
    end
    db.lureRecipes = db.lureRecipes or {}
    return db.lureRecipes
end

local function CopyRow(row)
    local copy = {}
    for key, value in pairs(row) do
        if type(value) ~= "table" and type(value) ~= "function" then
            copy[key] = value
        end
    end
    return copy
end

local function CopyRows(rows)
    local copy = {}
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        copy[#copy + 1] = CopyRow(row)
    end
    return copy
end

-- Only the fields RecipeEconomicsService:EvaluateObservation reads.
local function CopyObservation(observation)
    return {
        recipeID = observation.recipeID,
        outputItemID = observation.outputItemID,
        outputConfigKey = observation.outputConfigKey,
        outputItemLink = observation.outputItemLink,
        baseOutputQuantity = observation.baseOutputQuantity,
        reagents = CopyRows(observation.reagents),
        finishingReagents = CopyRows(observation.finishingReagents),
        displayedResourcefulnessPct = observation.displayedResourcefulnessPct,
        displayedMulticraftPct = observation.displayedMulticraftPct,
        concentrating = false,
    }
end

-- Cost per lure: cost per item when Multicraft makes extra lures, else Cost to Make.
local function LureCost(economics)
    if type(economics) ~= "table" then
        return nil
    end
    return tonumber(economics.costPerItem) or tonumber(economics.costToMake)
end

local function ValuePerUnit(valuationService, itemID)
    if not valuationService or not itemID then
        return nil
    end
    local ok, priced = pcall(function()
        return valuationService:GetItemValue({ itemID = itemID })
    end)
    if not ok or type(priced) ~= "table" or priced.unresolved then
        return nil
    end
    return tonumber(priced.valuePerUnit)
end

-- npcID, beast for a lure itemID, or nil.
function LureAnalysisService:GetBeastForLure(lureItemID)
    local capture = GetCapture()
    if not capture or type(capture.GetBeastByLureItemID) ~= "function" then
        return nil
    end
    return capture:GetBeastByLureItemID(lureItemID)
end

function LureAnalysisService:IsLureResult(economicsResult)
    if type(economicsResult) ~= "table" or economicsResult.resolved ~= true then
        return false
    end
    local economics = economicsResult.economics
    return economics ~= nil and self:GetBeastForLure(economics.outputItemID) ~= nil
end

--- Average kill loot + skin per skin for one beast: BeastSkinCapture's
-- running average (plain average until 100 skins, then recent-weighted).
-- @return { skins, rows = { { itemID, quantity, valuePerUnit, lineValue, unvalued } }, total, hasUnpriced }
function LureAnalysisService:GetAverageReturn(npcID)
    local result = { skins = 0, rows = {}, total = 0, hasUnpriced = false }
    local capture = GetCapture()
    local average = capture and capture.GetAverage and capture:GetAverage(npcID)
    local skins = average and tonumber(average.skins) or 0
    result.skins = skins
    if skins == 0 then
        return result
    end

    local valuationService = GetValuationService()
    for itemID, averageQty in pairs(average.items or {}) do
        local quantity = tonumber(averageQty) or 0
        local valuePerUnit = ValuePerUnit(valuationService, itemID)
        local row = { itemID = itemID, quantity = quantity }
        if valuePerUnit then
            row.valuePerUnit = valuePerUnit
            row.lineValue = valuePerUnit * quantity
            result.total = result.total + row.lineValue
        else
            row.unvalued = true
            result.hasUnpriced = true
        end
        result.rows[#result.rows + 1] = row
    end

    table.sort(result.rows, function(a, b)
        local av, bv = a.lineValue or -1, b.lineValue or -1
        if av ~= bv then
            return av > bv
        end
        return a.itemID < b.itemID
    end)
    return result
end

local function SummarizeLure(self, lureItemID, npcID, economics)
    local cost = LureCost(economics)
    local averageReturn = self:GetAverageReturn(npcID)
    local entry = {
        lureItemID = lureItemID,
        npcID = npcID,
        skins = averageReturn.skins,
        cost = cost,
        averageReturn = averageReturn,
    }
    if cost == nil then
        entry.state = "noCost"
    elseif averageReturn.skins == 0 then
        entry.state = "noSkins"
    else
        entry.state = "ok"
        entry.profit = averageReturn.total - cost
    end
    return entry
end

--- Full lure analysis for the selected lure recipe.
-- economicsResult: RecipeEconomicsService:EvaluateCurrentRecipe() result for
-- a lure recipe (IsLureResult true).
function LureAnalysisService:Evaluate(economicsResult)
    local economics = economicsResult.economics
    local lureItemID = economics.outputItemID
    local npcID, beast = self:GetBeastForLure(lureItemID)

    -- Remember this lure's recipe so the All Lures list can price it later.
    local saved = SavedLureRecipes()
    if saved and economicsResult.observation then
        saved[lureItemID] = CopyObservation(economicsResult.observation)
    end

    local selected = SummarizeLure(self, lureItemID, npcID, economics)
    selected.beastName = beast and beast.name

    -- Every lure, the selected one included, for the comparison list.
    local allLures = {}
    local capture = GetCapture()
    local beasts = capture and capture.GetBeasts and capture:GetBeasts() or {}
    local economicsService = GetEconomicsService()
    for otherNpcID, otherBeast in pairs(beasts) do
        local otherLureItemID = otherBeast.lureItemID
        if otherLureItemID and otherLureItemID > 0 then
            local entry
            if otherLureItemID == lureItemID then
                entry = selected
            else
                local otherEconomics = nil
                local observation = saved and saved[otherLureItemID]
                if observation and economicsService and economicsService.EvaluateObservation then
                    local ok, result = pcall(function()
                        return economicsService:EvaluateObservation(observation)
                    end)
                    otherEconomics = ok and type(result) == "table" and result.resolved and result.economics or nil
                end
                entry = SummarizeLure(self, otherLureItemID, otherNpcID, otherEconomics)
            end
            entry.isSelected = (otherLureItemID == lureItemID)
            allLures[#allLures + 1] = entry
        end
    end

    -- Known profits first, best first; then lures still missing data.
    table.sort(allLures, function(a, b)
        if (a.profit ~= nil) ~= (b.profit ~= nil) then
            return a.profit ~= nil
        end
        if a.profit and b.profit and a.profit ~= b.profit then
            return a.profit > b.profit
        end
        return a.lureItemID < b.lureItemID
    end)

    selected.allLures = allLures
    return selected
end

function LureAnalysisService:GetLureName(lureItemID)
    local ok, name = pcall(GetItemInfo, lureItemID)
    return ok and name or nil
end

if PocketCFO_Crafting then
    PocketCFO_Crafting.LureAnalysisService = LureAnalysisService
end
