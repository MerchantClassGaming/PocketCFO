-- PocketCFO/Infrastructure/BetaFeatures.lua
-- Account-wide beta feature toggles and the settings panel that controls them.
--
-- Beta features stay fully built and loaded; turning a toggle off only hides
-- the buttons that lead to them. Each consumer reads its flag through this
-- module and listens for PCFO_SETTINGS_CHANGED to show/hide its buttons live.
--
-- Settings panel registration follows the pattern used by BetterFishing
-- (Interface 120100): Settings.RegisterCanvasLayoutCategory +
-- Settings.RegisterAddOnCategory + Settings.OpenToCategory(categoryID), with
-- SettingsCheckBoxTemplate check buttons. Confirmed (third-party) - not yet
-- tested in-game for PocketCFO.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local BetaFeatures = PocketCFO:NewModule("BetaFeatures", "AceEvent-3.0")

BetaFeatures.SETTINGS_CHANGED_MESSAGE = "PCFO_SETTINGS_CHANGED"

local KEY_INVENTORY_MANAGER = "betaInventoryManager"
local KEY_AUCTION_HOUSE     = "betaAuctionHouse"

local FLAG_DEFINITIONS = {
    {
        key = KEY_INVENTORY_MANAGER,
        label = "Inventory Manager",
        description = "Adds a Show Inventory button to the crafting window for tracking how many of each item you want on hand.",
    },
    {
        key = KEY_AUCTION_HOUSE,
        label = "Auction House Posting",
        description = "Adds Post, Cancel, and posting rule pages to the auction house tab. Price scanning works without this.",
    },
}

local function SettingsTable()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    globalDB.settings = globalDB.settings or {}
    return globalDB.settings
end

function BetaFeatures:IsEnabled(key)
    local settings = SettingsTable()
    return settings ~= nil and settings[key] == true
end

function BetaFeatures:SetEnabled(key, enabled)
    local settings = SettingsTable()
    if not settings then
        return
    end
    enabled = enabled == true
    if (settings[key] == true) == enabled then
        return
    end
    settings[key] = enabled
    PocketCFO:Debug("BetaFeatures: %s=%s", tostring(key), tostring(enabled))
    self:SendMessage(self.SETTINGS_CHANGED_MESSAGE, key, enabled)
end

function BetaFeatures:IsInventoryManagerEnabled()
    return self:IsEnabled(KEY_INVENTORY_MANAGER)
end

function BetaFeatures:IsAuctionHouseEnabled()
    return self:IsEnabled(KEY_AUCTION_HOUSE)
end

-- ---------------------------------------------------------------------------
-- Settings panel (Game Menu > Options > AddOns > Pocket CFO)
-- ---------------------------------------------------------------------------

function BetaFeatures:CreateSettingsPanel()
    if self.categoryID then
        return
    end
    local blizzSettings = _G.Settings
    if not blizzSettings or not blizzSettings.RegisterCanvasLayoutCategory or not blizzSettings.RegisterAddOnCategory then
        PocketCFO:Debug("BetaFeatures: Settings API unavailable, panel not registered")
        return
    end

    local panel = CreateFrame("Frame")

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightHuge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("Pocket CFO")

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -20)
    header:SetText("Beta Features")

    local intro = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
    intro:SetWidth(560)
    intro:SetJustifyH("LEFT")
    intro:SetText("These features are still being built. Turn them on to try them out. Some things may not work yet.")

    local checkButtons = {}
    local anchor = intro
    for _, definition in ipairs(FLAG_DEFINITIONS) do
        local checkButton = CreateFrame("CheckButton", nil, panel, "SettingsCheckBoxTemplate")
        checkButton:SetSize(21, 20)
        checkButton:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -18)
        checkButton.HoverBackground = nil

        checkButton.text = checkButton:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        checkButton.text:SetPoint("LEFT", checkButton, "RIGHT", 4, 0)
        checkButton.text:SetText(definition.label)
        checkButton:SetHitRectInsets(0, -checkButton.text:GetStringWidth() - 4, 0, 0)

        local description = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        description:SetPoint("TOPLEFT", checkButton, "BOTTOMLEFT", 25, -2)
        description:SetWidth(535)
        description:SetJustifyH("LEFT")
        description:SetText(definition.description)

        local flagKey = definition.key
        checkButton:SetScript("OnClick", function(button)
            BetaFeatures:SetEnabled(flagKey, button:GetChecked() and true or false)
            button:SetChecked(BetaFeatures:IsEnabled(flagKey))
        end)

        checkButtons[flagKey] = checkButton
        anchor = description
    end

    panel:SetScript("OnShow", function()
        for flagKey, checkButton in pairs(checkButtons) do
            checkButton:SetChecked(BetaFeatures:IsEnabled(flagKey))
        end
    end)

    local category = blizzSettings.RegisterCanvasLayoutCategory(panel, "Pocket CFO")
    blizzSettings.RegisterAddOnCategory(category)
    self.categoryID = category:GetID()
end

function BetaFeatures:OpenSettings()
    self:CreateSettingsPanel()
    local blizzSettings = _G.Settings
    if self.categoryID and blizzSettings and blizzSettings.OpenToCategory then
        blizzSettings.OpenToCategory(self.categoryID)
    else
        PocketCFO:Print("Settings panel unavailable.")
    end
end

function BetaFeatures:OnEnable()
    self:CreateSettingsPanel()
end

-- ---------------------------------------------------------------------------
-- Minimap Addon Compartment entry
-- ---------------------------------------------------------------------------
-- Wired from PocketCFO.toc via ## AddonCompartmentFunc / FuncOnEnter /
-- FuncOnLeave, which take global function names. Same TOC pattern CraftSim
-- uses on Interface 120100 - confirmed (third-party), not yet tested in-game
-- for PocketCFO. Arguments Blizzard passes in are ignored.

function PocketCFO_OnAddonCompartmentClick()
    BetaFeatures:OpenSettings()
end

function PocketCFO_OnAddonCompartmentEnter(_, menuButtonFrame)
    if not menuButtonFrame or not GameTooltip then
        return
    end
    GameTooltip:SetOwner(menuButtonFrame, "ANCHOR_LEFT")
    GameTooltip:SetText("Pocket CFO")
    GameTooltip:AddLine("Click to open settings.", 1, 1, 1)
    GameTooltip:Show()
end

function PocketCFO_OnAddonCompartmentLeave()
    if GameTooltip then
        GameTooltip:Hide()
    end
end

local diagnostics = PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("settings", {
        name = "settings",
        description = "Open the settings panel (beta feature toggles).",
        usage = "/mcg settings",
        category = "General",
        playerFacing = true,
    }, function()
        BetaFeatures:OpenSettings()
    end)
end
