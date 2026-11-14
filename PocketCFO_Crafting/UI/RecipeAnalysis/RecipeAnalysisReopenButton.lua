-- PocketCFO_Crafting/UI/RecipeAnalysis/RecipeAnalysisReopenButton.lua
-- Small "PCFO" button in the profession window title bar, just left of
-- Blizzard's minimize button. Clicking it reopens the Recipe Analysis window
-- through CraftQueueController:Show() (the same path as /mcg queue).
--
-- Both flavors: loaded from PocketCFO_Crafting.toc and _Camelot.toc. On
-- either client it also brings back a window that is open but hidden under
-- the profession window (InventoryManagerWindow:EnsureVisible).
--
-- Anchor: ProfessionsFrame.MaximizeMinimize, verified in Blizzard source
-- (Blizzard_ProfessionsFrame.xml: parentKey="MaximizeMinimize", anchored
-- RIGHT to CloseButton's LEFT). Blizzard hides it off the Recipes tab
-- (Blizzard_ProfessionsFrame.lua SetTab); anchors still resolve while it is
-- hidden, so this button keeps its spot on every tab.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local ReopenButton = PocketCFO_Crafting:NewModule("RecipeAnalysisReopenButton", "AceEvent-3.0")

local SIDE_PADDING  = 5 -- px each side of the text
local TEXT_NUDGE_Y  = -1 -- drop the label so it sits centered (matches PTS)
local BUTTON_HEIGHT = 22
local BUTTON_TEXT   = "PCFO"
local TOOLTIP_TEXT  = "Open Recipe Analysis"

local button = nil
local AnchorButton -- assigned below

local function OnClick()
    local controller = PocketCFO_Crafting:GetModule("CraftQueueController", true)
    if controller and controller.Show then
        controller:Show()
    end
    -- If it was already open but hidden under the profession window (or lost
    -- its position), put it back beside the profession window.
    local window = PocketCFO_Crafting:GetModule("InventoryManagerWindow", true)
    if window and window.EnsureVisible then
        window:EnsureVisible()
    end
end

-- Placement: one group of buttons by the minimize button, 4px apart.
-- If Profession Tool Switcher's button (PTS_HeaderButton) is there, it owns
-- the slot next to minimize and PCFO sits just left of it. Without PTS, PCFO
-- takes that slot. All sit 1px above minimize's center line.
local BUTTON_GAP = 4
local RAISE_Y    = 1

AnchorButton = function()
    local profFrame = _G.ProfessionsFrame
    if not button or not profFrame then
        return
    end
    button:ClearAllPoints()
    local pts = _G.PTS_HeaderButton
    local minimize = profFrame.MaximizeMinimize
    if pts and pts:GetParent() == profFrame then
        button:SetPoint("RIGHT", pts, "LEFT", -BUTTON_GAP, 0)
    elseif minimize then
        button:SetPoint("RIGHT", minimize, "LEFT", -BUTTON_GAP, RAISE_Y)
    else
        -- Fallback if Blizzard ever renames the frame: fixed spot near the
        -- top-right corner, left of where close + minimize sit.
        button:SetPoint("TOPRIGHT", profFrame, "TOPRIGHT", -52, 0)
    end
end

local function CreateButton()
    if button then
        return
    end
    local profFrame = _G.ProfessionsFrame
    if not profFrame then
        return
    end

    button = CreateFrame("Button", nil, profFrame, "UIPanelButtonTemplate")
    button:SetHeight(BUTTON_HEIGHT)
    -- The window border (NineSlice, frameLevel 500) and title bar
    -- (TitleContainer, 510) draw over the top strip (SharedUIPanelTemplates.xml,
    -- PortraitFrameBaseTemplate / NineSlicePanelTemplate). Neither takes the
    -- mouse, which is why the tooltip worked while the button was invisible.
    -- Sit above the highest of them.
    local topLevel = 510
    for _, key in ipairs({ "NineSlice", "TitleContainer", "CraftingPage" }) do
        local f = profFrame[key]
        local level = f and f.GetFrameLevel and f:GetFrameLevel()
        if level and level > topLevel then
            topLevel = level
        end
    end
    -- Same as the PTS header button, which does draw over the title bar.
    -- Strata first, then level (PTS order).
    button:SetFrameStrata("HIGH")
    button:SetFrameLevel(topLevel + 5)
    button:SetText(BUTTON_TEXT)
    local fs = button:GetFontString()
    if fs then
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", button, "CENTER", 0, TEXT_NUDGE_Y)
    end
    local textWidth = fs and fs:GetStringWidth() or 30
    button:SetWidth(math.ceil(textWidth) + SIDE_PADDING * 2)

    AnchorButton()
    -- PTS builds its header button on its own schedule (TRADE_SKILL_SHOW /
    -- OnUpdate), so it may not exist yet. Re-check whenever the window shows,
    -- and once a frame later.
    if profFrame.HookScript then
        profFrame:HookScript("OnShow", function()
            AnchorButton()
            if C_Timer and C_Timer.After then
                C_Timer.After(0, AnchorButton)
            end
        end)
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, AnchorButton)
    end

    button:SetScript("OnClick", OnClick)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(TOOLTIP_TEXT)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

function ReopenButton:OnEnable()
    CreateButton()
    -- Retry on open in case ProfessionsFrame did not exist yet at enable.
    if not button then
        self:RegisterEvent("TRADE_SKILL_SHOW", function()
            CreateButton()
            if button then
                self:UnregisterEvent("TRADE_SKILL_SHOW")
            end
        end)
    end
end

function ReopenButton:OnDisable()
end
