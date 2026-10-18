-- PocketCFO_Crafting/Infrastructure/AddonLoader.lua
-- Crafting-owned profession window initialization dispatcher.

local PocketCFO_Crafting = _G.PocketCFO_Crafting

local AddonLoader = PocketCFO_Crafting:NewModule("AddonLoader", "AceEvent-3.0")

local function IsProfessionWindowVisible()
    return (ProfessionsFrame and ProfessionsFrame:IsVisible())
        or (TradeSkillFrame and TradeSkillFrame:IsVisible())
end

function AddonLoader:OnEnable()
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")

    if IsProfessionWindowVisible() and C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            self:OnTradeSkillShow()
        end)
    end
end

function AddonLoader:OnTradeSkillShow()
    local controller = PocketCFO_Crafting:GetModule("CraftQueueController", true)
    if controller and controller.OnTradeSkillShow then
        controller:OnTradeSkillShow()
    end

    local saveButton = PocketCFO_Crafting:GetModule("SaveToInventoryButton", true)
    if saveButton and saveButton.OnTradeSkillShow then
        saveButton:OnTradeSkillShow()
        if saveButton.OnRecipeSelected then
            saveButton:OnRecipeSelected()
        end
    end
end
