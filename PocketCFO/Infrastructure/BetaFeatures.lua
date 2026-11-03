-- PocketCFO/Infrastructure/BetaFeatures.lua
-- Account-wide beta feature toggles and the settings panel that controls them.
-- The panel also holds the Gold per Hour settings (2026-10-31, both flavors):
-- the tracker window's auto show / auto close (core ActivityControl) and
-- which automatic activities show in Gold per Hour (moved here from the old
-- Gold per Hour window's gear panel; ActivityRuns ui.hidden, tracking always
-- continues). The activity list needs PocketCFO_PnL, loaded when the panel opens.
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

-- WoW Forever ships without the beta features: both flags read off and the
-- toggles are not shown. PocketCFO.flavor is set by Flavor_Forever.lua.
local function IsForever()
    return PocketCFO.flavor == "forever"
end

local function SettingsTable()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    globalDB.settings = globalDB.settings or {}
    return globalDB.settings
end

function BetaFeatures:IsEnabled(key)
    if IsForever() then
        return false
    end
    local settings = SettingsTable()
    return settings ~= nil and settings[key] == true
end

function BetaFeatures:SetEnabled(key, enabled)
    if IsForever() then
        return
    end
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
    local definitions = FLAG_DEFINITIONS
    if IsForever() then
        -- No beta features on Forever: the Gold per Hour section comes first.
        header:Hide()
        intro:Hide()
        anchor = title
        definitions = {}
    end
    for _, definition in ipairs(definitions) do
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

    -- anchor is the last beta description (25px in), or the title on Forever.
    local gph = self:BuildGoldPerHourSection(panel, anchor, anchor == title and 0 or -25)

    panel:SetScript("OnShow", function()
        for flagKey, checkButton in pairs(checkButtons) do
            checkButton:SetChecked(BetaFeatures:IsEnabled(flagKey))
        end
        gph.Refresh()
    end)

    local category = blizzSettings.RegisterCanvasLayoutCategory(panel, "Pocket CFO")
    blizzSettings.RegisterAddOnCategory(category)
    self.categoryID = category:GetID()
end

-- Settings-style check button with a label and an optional description line.
local function CreateSettingsCheck(panel, anchor, label, description, offsetY, offsetX)
    local checkButton = CreateFrame("CheckButton", nil, panel, "SettingsCheckBoxTemplate")
    checkButton:SetSize(21, 20)
    checkButton:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", offsetX or 0, offsetY or -18)
    checkButton.HoverBackground = nil
    checkButton.text = checkButton:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    checkButton.text:SetPoint("LEFT", checkButton, "RIGHT", 4, 0)
    checkButton.text:SetText(label)
    checkButton:SetHitRectInsets(0, -checkButton.text:GetStringWidth() - 4, 0, 0)
    local bottom = checkButton
    if description then
        local text = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
        text:SetPoint("TOPLEFT", checkButton, "BOTTOMLEFT", 25, -2)
        text:SetWidth(535)
        text:SetJustifyH("LEFT")
        text:SetText(description)
        bottom = text
    end
    return checkButton, bottom
end

local ACTIVITY_COLUMNS = 3
local ACTIVITY_COLUMN_WIDTH = 190
local ACTIVITY_ROW_HEIGHT = 24

-- Gold per Hour section. Returns { Refresh = fn } (called when the panel shows).
function BetaFeatures:BuildGoldPerHourSection(panel, anchor, anchorX)
    local function Control()
        return PocketCFO.ActivityControl
    end

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    -- Beta descriptions sit 25px in from the panel's text edge; line the
    -- header up with the title instead.
    header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchorX or 0, -28)
    header:SetText("Gold per Hour")

    local autoShow, bottom = CreateSettingsCheck(panel, header, "Show the tracker when tracking starts",
        "Opens the small Gold per Hour window when you start gathering, fishing, a dungeon or a session.", -10)
    autoShow:SetScript("OnClick", function(button)
        local control = Control()
        if control then
            control:SetSetting("trackerAutoShow", button:GetChecked())
        end
    end)
    local autoClose
    autoClose, bottom = CreateSettingsCheck(panel, bottom, "Close the tracker when tracking ends",
        "Otherwise the tracker keeps showing your result until you close it.", -12, -25)
    autoClose:SetScript("OnClick", function(button)
        local control = Control()
        if control then
            control:SetSetting("trackerAutoClose", button:GetChecked())
        end
    end)

    local listHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    listHeader:SetPoint("TOPLEFT", bottom, "BOTTOMLEFT", -25, -20)
    listHeader:SetText("Show in Gold per Hour")
    local listHint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    listHint:SetPoint("TOPLEFT", listHeader, "BOTTOMLEFT", 0, -4)
    listHint:SetWidth(560)
    listHint:SetJustifyH("LEFT")
    listHint:SetText("Uncheck to hide an activity. Tracking continues. Running the same dungeon over and over for gold? Start a custom session first so it gets its own row.")
    local listEmpty = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    listEmpty:SetPoint("TOPLEFT", listHint, "BOTTOMLEFT", 0, -10)
    listEmpty:SetText("Nothing tracked automatically yet.")

    local activityChecks = {}

    local function Hidden()
        local runs = PocketCFO:GetModule("ActivityRuns", true)
        local ui = runs and runs:GetUIState()
        if not ui then
            return {}
        end
        ui.hidden = ui.hidden or {}
        return ui.hidden
    end

    local function Hideable()
        local loader = PocketCFO:GetModule("AddonLoader", true)
        if not loader or not loader:SafeLoad("PocketCFO_PnL") then
            return {}
        end
        local pnl = _G.PocketCFO_PnL
        local report = pnl and pnl.GoldPerHourReport
        return report and report:GetHideable() or {}
    end

    local function Refresh()
        local control = Control()
        autoShow:SetChecked(control ~= nil and control:GetSetting("trackerAutoShow"))
        autoClose:SetChecked(control ~= nil and control:GetSetting("trackerAutoClose"))
        local hidden = Hidden()
        local list = Hideable()
        for index, entry in ipairs(list) do
            local check = activityChecks[index]
            if not check then
                local column = (index - 1) % ACTIVITY_COLUMNS
                local row = math.floor((index - 1) / ACTIVITY_COLUMNS)
                check = CreateSettingsCheck(panel, listHint, "", nil,
                    -10 - row * ACTIVITY_ROW_HEIGHT, column * ACTIVITY_COLUMN_WIDTH)
                check:SetScript("OnClick", function(button)
                    Hidden()[button.hideKey] = (not button:GetChecked()) or nil
                    BetaFeatures:SendMessage("MCG_ACTIVITY_RUNS_FILED")
                end)
                activityChecks[index] = check
            end
            check.hideKey = entry.key
            check.text:SetText(entry.label)
            check:SetHitRectInsets(0, -check.text:GetStringWidth() - 4, 0, 0)
            check:SetChecked(not hidden[entry.key])
            check:Show()
        end
        for index = #list + 1, #activityChecks do
            activityChecks[index]:Hide()
        end
        listEmpty:SetShown(#list == 0)
    end

    return { Refresh = Refresh }
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
