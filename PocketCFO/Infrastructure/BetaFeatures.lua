-- PocketCFO/Infrastructure/BetaFeatures.lua
-- Account-wide beta feature toggles and the settings panel that controls them.
-- The panel also holds the Gold per Hour settings (2026-10-31, both flavors):
-- the tracker window's auto show / auto close (core ActivityControl) and
-- which automatic activities show in Gold per Hour (moved here from the old
-- Gold per Hour window's gear panel; ActivityRuns ui.hidden, tracking always
-- continues). The activity list needs PocketCFO_PnL, loaded when the panel opens.
--
-- Panel layout (Brian, 2026-11-06): three top-level sections, in order:
--   Gold per Hour
--   Show in Gold per Hour
--   Beta Features (retail only)
--       Inventory Manager
--       Auction House Posting
--           Smart Posting
-- Everything under Beta Features is off by default.
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
        description = "Adds Add to Inventory Manager and Show Inventory buttons to the crafting window for tracking how many of each item you want on hand.",
    },
    {
        key = KEY_AUCTION_HOUSE,
        label = "Auction House Posting",
        description = "Adds Post and Cancel pages to the auction house tab, using your own posting rules. Price scanning works without this.",
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

-- Smart Posting (PocketCFO_AH SmartPricing.lua): a beta option under
-- Auction House Posting (Brian, 2026-11-06). Off by default. It only counts
-- when Auction House Posting is also on: AH Posting on + Smart off = the
-- original rules view, both on = smart view, AH Posting off = scan only.
-- Retail only until Forever posting is tested.
--
-- The 2026-11-04 build saved "ahSmartView" and turned it on by itself for
-- anyone without the AH beta. That key is retired and cleared at login
-- (RetireOldSmartViewKey), so nobody gets Smart Posting until they check it.
local KEY_AH_SMART_POSTING = "ahSmartPosting"
local KEY_AH_SMART_VIEW_OLD = "ahSmartView"

function BetaFeatures:RetireOldSmartViewKey()
    local settings = SettingsTable()
    if settings and settings[KEY_AH_SMART_VIEW_OLD] ~= nil then
        settings[KEY_AH_SMART_VIEW_OLD] = nil
        PocketCFO:Debug("BetaFeatures: cleared old %s", KEY_AH_SMART_VIEW_OLD)
    end
end

-- The Smart Posting checkbox's own saved state (shown grayed out while
-- Auction House Posting is off).
function BetaFeatures:IsSmartPostingChecked()
    if IsForever() then
        return false
    end
    local settings = SettingsTable()
    return settings ~= nil and settings[KEY_AH_SMART_POSTING] == true
end

-- Whether the smart view is actually in use: AH Posting on and Smart checked.
function BetaFeatures:IsSmartAuctionHouseOn()
    return self:IsAuctionHouseEnabled() and self:IsSmartPostingChecked()
end

function BetaFeatures:SetSmartAuctionHouse(enabled)
    if IsForever() then
        return
    end
    local settings = SettingsTable()
    if not settings then
        return
    end
    settings[KEY_AH_SMART_POSTING] = enabled == true
    PocketCFO:Debug("BetaFeatures: %s=%s", KEY_AH_SMART_POSTING, tostring(enabled == true))
    self:SendMessage(self.SETTINGS_CHANGED_MESSAGE, KEY_AH_SMART_POSTING, enabled == true)
end

-- One-time check for players who already built posting rules (Brian,
-- 2026-11-06): turn Auction House Posting on for them; Smart Posting stays
-- off. Called by PocketCFO_AH when it loads (first AH open), because the
-- rules live in PocketCFO_AH's saved data. Runs once per account.
local KEY_AH_RULES_CHECKED = "ahRulesCheckDone"

function BetaFeatures:ApplyExistingRulesCheck(hasRules)
    if IsForever() then
        return
    end
    local settings = SettingsTable()
    if not settings or settings[KEY_AH_RULES_CHECKED] then
        return
    end
    settings[KEY_AH_RULES_CHECKED] = true
    if hasRules == true and not self:IsAuctionHouseEnabled() then
        self:SetEnabled(KEY_AUCTION_HOUSE, true)
        PocketCFO:Debug("BetaFeatures: existing posting rules found, Auction House Posting turned on")
    end
end

-- ---------------------------------------------------------------------------
-- Settings panel (Game Menu > Options > AddOns > Pocket CFO)
-- ---------------------------------------------------------------------------

-- Settings-style check button with a label and an optional description line.
-- offsetX / offsetY are from the anchor's bottom-left. The description sits
-- 25px in from the check button.
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
        text:SetWidth(510)
        text:SetJustifyH("LEFT")
        text:SetText(description)
        bottom = text
    end
    return checkButton, bottom
end

local BETA_INDENT = 20   -- Inventory Manager / Auction House Posting, from the section header
local SUB_INDENT  = 25   -- Smart Posting, from Auction House Posting

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

    -- Sections 1 and 2: Gold per Hour, Show in Gold per Hour (both flavors).
    local gph = self:BuildGoldPerHourSection(panel, title)

    -- Section 3: Beta Features (retail only).
    local beta = nil
    if not IsForever() then
        beta = self:BuildBetaSection(panel, gph.bottom)
    end

    panel:SetScript("OnShow", function()
        gph.Refresh()
        if beta then
            beta.Refresh()
        end
    end)

    local category = blizzSettings.RegisterCanvasLayoutCategory(panel, "Pocket CFO")
    blizzSettings.RegisterAddOnCategory(category)
    self.categoryID = category:GetID()
end

-- Beta Features section. Returns { Refresh = fn }.
function BetaFeatures:BuildBetaSection(panel, anchor)
    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -24)
    header:SetText("Beta Features")

    local intro = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    intro:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
    intro:SetWidth(560)
    intro:SetJustifyH("LEFT")
    intro:SetText("These features are still being built. Turn them on to try them out. Some things may not work yet.")

    local inventoryDef = FLAG_DEFINITIONS[1]
    local ahDef = FLAG_DEFINITIONS[2]

    local inventoryCheck, bottom = CreateSettingsCheck(panel, intro, inventoryDef.label, inventoryDef.description,
        -14, BETA_INDENT)
    -- bottom is the description, 25px further in than the check button.
    local ahCheck
    ahCheck, bottom = CreateSettingsCheck(panel, bottom, ahDef.label, ahDef.description, -12, -25)
    local smartCheck
    smartCheck = CreateSettingsCheck(panel, bottom, "Smart Posting",
        "Prices everything in your bags for you. No rules to set up. Leave off to post with your own rules.",
        -12, SUB_INDENT - 25)

    local function RefreshSmartEnabled()
        local ahOn = BetaFeatures:IsAuctionHouseEnabled()
        smartCheck:SetEnabled(ahOn)
        smartCheck.text:SetFontObject(ahOn and "GameFontNormal" or "GameFontDisable")
    end

    local function Refresh()
        inventoryCheck:SetChecked(BetaFeatures:IsInventoryManagerEnabled())
        ahCheck:SetChecked(BetaFeatures:IsAuctionHouseEnabled())
        smartCheck:SetChecked(BetaFeatures:IsSmartPostingChecked())
        RefreshSmartEnabled()
    end

    inventoryCheck:SetScript("OnClick", function(button)
        BetaFeatures:SetEnabled(KEY_INVENTORY_MANAGER, button:GetChecked() and true or false)
        button:SetChecked(BetaFeatures:IsInventoryManagerEnabled())
    end)
    ahCheck:SetScript("OnClick", function(button)
        BetaFeatures:SetEnabled(KEY_AUCTION_HOUSE, button:GetChecked() and true or false)
        button:SetChecked(BetaFeatures:IsAuctionHouseEnabled())
        RefreshSmartEnabled()
        -- The smart view depends on both boxes; tell listeners it may have changed.
        BetaFeatures:SendMessage(BetaFeatures.SETTINGS_CHANGED_MESSAGE, KEY_AH_SMART_POSTING,
            BetaFeatures:IsSmartAuctionHouseOn())
    end)
    smartCheck:SetScript("OnClick", function(button)
        BetaFeatures:SetSmartAuctionHouse(button:GetChecked() and true or false)
        button:SetChecked(BetaFeatures:IsSmartPostingChecked())
    end)

    return { Refresh = Refresh }
end

local ACTIVITY_COLUMNS = 3
local ACTIVITY_COLUMN_WIDTH = 190
local ACTIVITY_ROW_HEIGHT = 24

-- Gold per Hour sections. Returns { Refresh = fn, bottom = frame }; bottom
-- is a spacer under the activity list, resized in Refresh so the Beta
-- Features section always sits below however many activity rows there are.
function BetaFeatures:BuildGoldPerHourSection(panel, anchor)
    local function Control()
        return PocketCFO.ActivityControl
    end

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -18)
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

    local listHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    listHeader:SetPoint("TOPLEFT", bottom, "BOTTOMLEFT", -25, -24)
    listHeader:SetText("Show in Gold per Hour")
    local listHint = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    listHint:SetPoint("TOPLEFT", listHeader, "BOTTOMLEFT", 0, -4)
    listHint:SetWidth(560)
    listHint:SetJustifyH("LEFT")
    listHint:SetText("Uncheck to hide an activity. Tracking continues. Running the same dungeon over and over for gold? Start a session first so it gets its own row.")
    local listEmpty = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    listEmpty:SetPoint("TOPLEFT", listHint, "BOTTOMLEFT", 0, -10)
    listEmpty:SetText("Nothing tracked automatically yet.")

    -- Spacer under the activity grid (height set in Refresh).
    local spacer = CreateFrame("Frame", nil, panel)
    spacer:SetPoint("TOPLEFT", listHint, "BOTTOMLEFT", 0, 0)
    spacer:SetSize(1, 24)

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
        local rows = math.ceil(#list / ACTIVITY_COLUMNS)
        spacer:SetHeight(rows > 0 and (10 + rows * ACTIVITY_ROW_HEIGHT) or 24)
    end

    return { Refresh = Refresh, bottom = spacer }
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
    self:RetireOldSmartViewKey()
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
