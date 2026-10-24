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

    -- Recipe Analysis headline, one line just above the button. A child of
    -- the button, so it shows/hides with it. Text set by SetHeadline.
    local headlineText = saveButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headlineText:SetPoint("BOTTOMLEFT", saveButton, "TOPLEFT", 2, 4)
    headlineText:SetJustifyH("LEFT")
    headlineText:SetWordWrap(false)
    headlineText:Hide()
    saveButton.headlineText = headlineText

    return saveButton
end

-- Same colors as RecipeAnalysisContent (COLOR_HEADER/POSITIVE/NEGATIVE/TEXT).
local HEADLINE_LABEL_COLOR = "ffffd100"
local HEADLINE_POSITIVE_COLOR = "ff66e666"
local HEADLINE_NEGATIVE_COLOR = "ffff7373"
local HEADLINE_NEUTRAL_COLOR = "ffffffff"

-- Mirrors RecipeAnalysisContent: no numbers before the first price scan.
local function NeedsFirstPriceScan()
    local valuation = _G.PocketCFO_Valuation
    if not valuation or not valuation.HasCompletedPriceScan then
        return false
    end
    return not valuation:HasCompletedPriceScan()
end

--- Shows the Recipe Analysis headline (displayModel.headline) above the
-- button, or hides it when headline is nil. Display only, no math.
-- Called by CraftQueueController after every analysis evaluation.
function SaveToInventoryButton:SetHeadline(headline)
    local text = saveButton and saveButton.headlineText
    if not text then return end

    local content = PocketCFO_Crafting.RecipeAnalysisContent
    if type(headline) ~= "table" or not content or not content.FormatSignedGoldSilver
        or NeedsFirstPriceScan() then
        text:SetText("")
        text:Hide()
        return
    end

    local value = tonumber(headline.value) or 0
    local label, valueText, valueColor
    if headline.barLabel then
        label = headline.barLabel
        valueText = content.FormatGoldSilver(value)
        valueColor = HEADLINE_NEUTRAL_COLOR
    elseif headline.style == "profit" then
        label = "PocketCFO Profit/Loss:"
        valueText = content.FormatSignedGoldSilver(value)
        valueColor = value < 0 and HEADLINE_NEGATIVE_COLOR or HEADLINE_POSITIVE_COLOR
    else
        label = "PocketCFO Cost of Craft:"
        valueText = content.FormatGoldSilver(value)
        valueColor = HEADLINE_NEUTRAL_COLOR
    end

    text:SetText(string.format("|c%s%s|r |c%s%s|r", HEADLINE_LABEL_COLOR, label, valueColor, valueText))
    text:Show()
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
    self:SetHeadline(nil)
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
