-- PocketCFO_Crafting/UI/InventoryManager/SaveToInventoryButton.lua
-- Owns the "Save to Inv. Manager" crafting window button.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local SaveToInventoryButton = PocketCFO_Crafting:NewModule("SaveToInventoryButton", "AceEvent-3.0")

local saveButton

local function GetProfessionRegistry()
    return PocketCFO and PocketCFO.ProfessionRegistry or _G.PocketCFO_ProfessionRegistry
end

local function GetProfessionContextService()
    return PocketCFO_Crafting:GetModule("ProfessionContextService", true)
end

local function GetCapture()
    return PocketCFO_Crafting:GetModule("RecipeStateCapture", true)
end

local function GetStore()
    return PocketCFO_Crafting:GetModule("RecipeConfigStore", true)
end

local function OnSaveButtonClick()
    local capture = GetCapture()
    local store = GetStore()
    local config, diagnosticPayload = capture and capture:CaptureCurrentDraft()
    if not config then
        PocketCFO:Print("Could not save - no recipe selected or item data unavailable.")
        return
    end
    if not store then
        PocketCFO:Print("Could not save - recipe configuration store unavailable.")
        return
    end

    local charGUID = PocketCFO.db.char.characterGUID
    local _, existing = store:FindMatchingSavedConfig(config, charGUID)
    if existing then
        local info = C_TradeSkillUI.GetRecipeInfo(config.recipeID)
        local name = info and info.name or "that item"
        PocketCFO:Print("%s with this configuration is already in your queue - shift-click it to adjust the quantity.", name)
        return
    end

    store:SaveConfiguration(config, diagnosticPayload)
end

local function CreateSaveButton()
    if saveButton then return saveButton end

    saveButton = CreateFrame("Button", "MCGCFOSaveConfigButton", UIParent, "UIPanelButtonTemplate")
    saveButton:SetSize(160, 22)
    saveButton:SetText("Save to Inv. Manager")
    saveButton:SetScript("OnClick", OnSaveButtonClick)
    saveButton:EnableMouse(false)
    saveButton:Hide()

    saveButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Save to Inventory Manager", 1, 1, 1)
        GameTooltip:AddLine(
            "Saves the current recipe configuration\n(mats, optionals, concentration)\nand adds it to your craft queue.",
            nil, nil, nil, true
        )
        GameTooltip:Show()
    end)
    saveButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return saveButton
end

local function IsGatheringProfessionContext(context)
    local registry = GetProfessionRegistry()
    return registry
        and registry.IsGatheringProfession
        and registry:IsGatheringProfession(context and context.professionID, context and context.professionName)
end

local function SetSaveButtonShown(shown)
    if not saveButton then return end

    saveButton:EnableMouse(shown == true)
    if shown then
        saveButton:Show()
    else
        saveButton:Hide()
    end
end

-- Inventory Manager beta toggle (PocketCFO/Infrastructure/BetaFeatures.lua).
-- This button only feeds the Inventory Manager, so it hides with it.
local function IsInventoryBetaEnabled()
    local beta = PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("BetaFeatures", true)
    return beta ~= nil and beta:IsInventoryManagerEnabled() == true
end

function SaveToInventoryButton:RefreshVisibility()
    if not saveButton then return end

    if not IsInventoryBetaEnabled() then
        SetSaveButtonShown(false)
        return
    end

    local contextService = GetProfessionContextService()
    local context = contextService and contextService:GetCurrentProfessionContext() or {}
    if IsGatheringProfessionContext(context) then
        SetSaveButtonShown(false)
        return
    end

    local recipeID = contextService and contextService:GetCurrentRecipeID()
    SetSaveButtonShown(recipeID ~= nil)
end

local function GetNormalChildFrameLevel(parent)
    local parentLevel = parent and parent.GetFrameLevel and parent:GetFrameLevel()
    return (tonumber(parentLevel) or 0) + 1
end

local function GetFrameStrataOrDefault(frame)
    if frame and frame.GetFrameStrata then
        return frame:GetFrameStrata() or "MEDIUM"
    end
    return "MEDIUM"
end

local function FramesOverlap(a, b)
    if not a or not b or not a.GetLeft or not b.GetLeft then
        return false
    end

    local aLeft, aRight, aTop, aBottom = a:GetLeft(), a:GetRight(), a:GetTop(), a:GetBottom()
    local bLeft, bRight, bTop, bBottom = b:GetLeft(), b:GetRight(), b:GetTop(), b:GetBottom()
    if not aLeft or not aRight or not aTop or not aBottom
    or not bLeft or not bRight or not bTop or not bBottom then
        return false
    end

    return aLeft < bRight and aRight > bLeft and aBottom < bTop and aTop > bBottom
end

local function SaveButtonOverlapsConcentration(craftingPage)
    local cc = craftingPage and craftingPage.ConcentrationContainer
    return FramesOverlap(saveButton, cc) or FramesOverlap(saveButton, cc and cc.Button)
end

local function AnchorSaveButton(craftingPage)
    local cc = craftingPage and craftingPage.ConcentrationContainer

    saveButton:ClearAllPoints()
    if cc then
        saveButton:SetPoint("BOTTOMRIGHT", cc, "TOPRIGHT", 0, 6)
    elseif craftingPage.CreateButton then
        saveButton:SetPoint("BOTTOMLEFT", craftingPage, "BOTTOMLEFT", 311, 77)
    else
        saveButton:SetPoint("BOTTOMLEFT", craftingPage, "BOTTOMLEFT", 8, 8)
    end

    if SaveButtonOverlapsConcentration(craftingPage) then
        saveButton:ClearAllPoints()
        saveButton:SetPoint("TOPRIGHT", craftingPage, "TOPRIGHT", -36, -58)
    end
end

function SaveToInventoryButton:Position()
    if not saveButton then return end

    local craftingPage = ProfessionsFrame and ProfessionsFrame.CraftingPage
    saveButton:ClearAllPoints()
    if craftingPage then
        saveButton:SetParent(craftingPage)
        saveButton:SetFrameStrata(GetFrameStrataOrDefault(craftingPage))
        saveButton:SetFrameLevel(GetNormalChildFrameLevel(craftingPage))
        AnchorSaveButton(craftingPage)
    else
        saveButton:SetParent(UIParent)
        saveButton:SetFrameStrata(GetFrameStrataOrDefault(UIParent))
        saveButton:SetFrameLevel(GetNormalChildFrameLevel(UIParent))
        saveButton:SetPoint("CENTER", UIParent, "CENTER", 300, -200)
    end

    self:RefreshVisibility()
end

function SaveToInventoryButton:ClearState()
    if not saveButton then return end

    SetSaveButtonShown(false)
    saveButton:ClearAllPoints()
    saveButton:SetParent(UIParent)
    saveButton:SetFrameStrata(GetFrameStrataOrDefault(UIParent))
    saveButton:SetFrameLevel(GetNormalChildFrameLevel(UIParent))
end

function SaveToInventoryButton:OnEnable()
    CreateSaveButton()
    self:RegisterEvent("TRADE_SKILL_CLOSE", "OnTradeSkillClose")
    self:RegisterEvent("TRADE_SKILL_LIST_UPDATE", "OnRecipeSelected")
    self:RegisterMessage("PCFO_SETTINGS_CHANGED", "OnSettingsChanged")
end

-- Beta toggle flipped while the profession window is open: re-anchor and
-- re-apply visibility (Position ends with RefreshVisibility).
function SaveToInventoryButton:OnSettingsChanged()
    local profFrame = _G["ProfessionsFrame"]
    if profFrame and profFrame:IsShown() then
        self:Position()
    end
end

function SaveToInventoryButton:OnTradeSkillShow()
    if PocketCFO_Crafting.InstallSelectRecipeHook then
        PocketCFO_Crafting:InstallSelectRecipeHook()
    end
    self:Position()
end

function SaveToInventoryButton:OnTradeSkillClose()
    self:ClearState()
end

function SaveToInventoryButton:OnRecipeSelected()
    self:RefreshVisibility()
end
