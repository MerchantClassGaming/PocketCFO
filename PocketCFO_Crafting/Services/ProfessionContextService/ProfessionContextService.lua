-- PocketCFO_Crafting/Services/ProfessionContextService/ProfessionContextService.lua
-- Crafting-owned current profession and selected recipe UI context.

local PocketCFO = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

if not PocketCFO_Crafting or type(PocketCFO_Crafting.NewModule) ~= "function" then
    return
end

local ProfessionContextService = PocketCFO_Crafting:NewModule("ProfessionContextService")
PocketCFO_Crafting.ProfessionContextService = ProfessionContextService

local function GetProfessionRegistry()
    return PocketCFO and PocketCFO.ProfessionRegistry or _G.PocketCFO_ProfessionRegistry
end

function ProfessionContextService:GetBaseProfessionInfo()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetBaseProfessionInfo then
        return nil
    end
    return C_TradeSkillUI.GetBaseProfessionInfo()
end

function ProfessionContextService:GetChildProfessionInfo()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetChildProfessionInfo then
        return nil
    end
    return C_TradeSkillUI.GetChildProfessionInfo()
end

function ProfessionContextService:GetCurrentChildSkillLineID()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetProfessionChildSkillLineID then
        return nil
    end
    local id = C_TradeSkillUI.GetProfessionChildSkillLineID()
    if id and id > 0 then
        return id
    end
    return nil
end

function ProfessionContextService:GetCurrentRecipeID()
    if not ProfessionsFrame or not ProfessionsFrame:IsShown() then
        return nil
    end

    local craftingPage = ProfessionsFrame.CraftingPage
    if not craftingPage then
        return nil
    end

    local schematicForm = craftingPage.SchematicForm
    if not schematicForm or not schematicForm.GetRecipeInfo then
        return nil
    end

    local recipeInfo = schematicForm:GetRecipeInfo()
    if not recipeInfo or not recipeInfo.recipeID or recipeInfo.recipeID == 0 then
        return nil
    end

    return recipeInfo.recipeID
end

function ProfessionContextService:GetCurrentProfessionContext()
    local registry = GetProfessionRegistry()
    local professionID
    local professionName
    local childSkillLineID
    local expansionID

    local baseInfo = self:GetBaseProfessionInfo()
    if baseInfo and baseInfo.professionID and registry and registry:IsSupportedProfessionID(baseInfo.professionID) then
        professionID = baseInfo.professionID
        professionName = baseInfo.professionName
    end

    if not professionID then
        local childInfo = self:GetChildProfessionInfo()
        if childInfo and registry then
            if childInfo.professionID and registry:IsSupportedProfessionID(childInfo.professionID) then
                professionID = childInfo.professionID
                professionName = childInfo.professionName
            elseif childInfo.profession then
                local mapped = registry:GetProfessionIDFromEnum(childInfo.profession)
                if mapped and registry:IsSupportedProfessionID(mapped) then
                    professionID = mapped
                    professionName = childInfo.professionName
                end
            end
        end
    end

    childSkillLineID = self:GetCurrentChildSkillLineID()

    if professionID and childSkillLineID and registry then
        expansionID = registry:GetExpansionIDFromChildSkillLineID(professionID, childSkillLineID)
    end

    return {
        professionID = professionID,
        professionName = professionName,
        childSkillLineID = childSkillLineID,
        expansionID = expansionID,
    }
end

function ProfessionContextService:GetCurrentProfessionID()
    return self:GetCurrentProfessionContext().professionID
end

function ProfessionContextService:GetCurrentProfessionName()
    return self:GetCurrentProfessionContext().professionName
end

function ProfessionContextService:GetCurrentExpansionID()
    return self:GetCurrentProfessionContext().expansionID
end
