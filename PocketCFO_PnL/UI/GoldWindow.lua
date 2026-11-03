-- PocketCFO_PnL/UI/GoldWindow.lua
-- The Gold window. Tabs:
--   Gold per Hour - sessions and runs ranked by gold per hour, Start / Stop /
--              Pause, per-run detail (UI/GoldPerHourTab.lua; 2026-10-31, was
--              its own window, which is now the small tracker window).
--   Balances - current gold per character, warband bank, account total
--              (moved here from core GoldTracker; data still owned by core).
--   Income   - where gold came from, by period and character. Click a source
--              to split it by profession and/or see its top items. Auction
--              House sales are grouped by what was sold (Gear, Crafting
--              materials, ...; IncomeReport). Bars per day show income over time.
--   Spending - where gold went (2026-10-27). Same layout and pane as Income.
--              Both show earned / spent / net for the period (Income since 2026-10-31).
--   Orders   - what completed crafting orders earned (UI/OrdersTab.lua).
-- The Gathering tab was removed 2026-10-31 (Gold per Hour answers the same
-- question; the capture behind it is unchanged).
-- The window opens on the last tab used (saved in core settings,
-- goldWindowTab; Gold per Hour the first time). The gear button opens the
-- Pocket CFO settings page.
-- Opened by core: minimap left-click -> GoldTracker:OpenWindow() (last tab);
-- /mcg gold -> GoldTracker:OpenWindow("balances").
-- Numbers are built in full before anything is drawn (no partial redraws).

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL

local GoldWindow = PocketCFO_PnL:NewModule("GoldWindow", "AceEvent-3.0")

-- WoW Forever: no crafting orders and no warband bank (ACCOUNT_BANK_* events
-- invalid on the beta, none at the banker). The Orders tab and Warband Bank row
-- are hidden there. Retail: flavor is nil, nothing changes.
local IS_FOREVER = PocketCFO.flavor == "forever"
-- Shared helpers for tab files (UI/OrdersTab.lua) are exposed on GoldWindow.ui
-- at the bottom of this file.

local WINDOW_WIDTH = 440
local INNER_WIDTH = WINDOW_WIDTH - 24
local ROW_HEIGHT = 18
local MAX_BALANCE_ROWS = 24
local CHART_HEIGHT = 48
local CHART_GAP = 2
local MAX_BAR_WIDTH = 24
local MAX_ITEM_LINES = 10

local COL_LABEL = 140
local COL_BAR = 120
local COL_AMOUNT = 104
local COL_SHARE = 40

local BAR_COLOR = { 1.0, 0.82, 0.0, 0.85 }
local SUB_BAR_COLOR = { 1.0, 0.82, 0.0, 0.45 }

-- ---------------------------------------------------------------------------
-- Formatting
-- ---------------------------------------------------------------------------

-- Balances keep the exact gold/silver/copper format GoldTracker used.
local function FormatMoneyExact(copper)
    copper = math.floor(tonumber(copper) or 0)
    local gold = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop = copper % 100
    local goldText = tostring(gold):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if goldText:sub(1, 1) == "," then
        goldText = goldText:sub(2)
    end
    return string.format("|cffffd700%sg|r |cffc7c7cf%02ds|r |cffeda55f%02dc|r", goldText, silver, cop)
end

-- Income amounts round to whole gold (coin icons) once they reach 1 gold.
local function FormatIncome(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper >= 10000 then
        copper = math.floor(copper / 10000) * 10000
    end
    if GetMoneyString then
        return GetMoneyString(copper, true)
    end
    return FormatMoneyExact(copper)
end

local function FormatShare(share)
    local pct = math.floor((tonumber(share) or 0) * 100 + 0.5)
    if pct < 1 and (tonumber(share) or 0) > 0 then
        return "<1%"
    end
    return pct .. "%"
end

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

local function FormatAge(updatedAt)
    updatedAt = tonumber(updatedAt)
    if not updatedAt then
        return ""
    end
    local seconds = Now() - updatedAt
    if seconds < 3600 then
        return "now"
    end
    local days = math.floor(seconds / 86400)
    if days < 1 then
        return string.format("%dh ago", math.floor(seconds / 3600))
    end
    return string.format("%dd ago", days)
end

local function ClassColoredName(entry)
    local name = tostring(entry.name or "?")
    local color = entry.classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.classFile]
    if color and color.colorStr then
        return "|c" .. color.colorStr .. name .. "|r"
    end
    return name
end

local function CreateText(parent, template, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    text:SetWordWrap(false)
    return text
end

-- ---------------------------------------------------------------------------
-- Core data access
-- ---------------------------------------------------------------------------

local function GetBalances()
    local tracker = PocketCFO:GetModule("GoldTracker", true)
    return tracker and tracker:GetBalances() or { characters = {} }
end

-- Characters still shown in the Gold window (hidden ones left out).
local function SortedCharacters(characters, hidden)
    local list = {}
    for guid, entry in pairs(characters or {}) do
        if not (hidden and hidden[guid]) then
            list[#list + 1] = { guid = guid, entry = entry }
        end
    end
    return list
end

local function Tracker()
    return PocketCFO:GetModule("GoldTracker", true)
end

-- Core settings table (the last tab used is kept there; PnL has no saved data).
local function SettingsTable()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return {}
    end
    globalDB.settings = globalDB.settings or {}
    return globalDB.settings
end

local VALID_TABS = { gph = true, balances = true, income = true, spending = true, orders = true }

local function SavedTab()
    local tab = SettingsTable().goldWindowTab
    if not VALID_TABS[tab] or (tab == "orders" and IS_FOREVER) then
        return "gph"
    end
    return tab
end

-- Character list behind the people button (top right, next to the X).
-- Built with Blizzard's DropdownButton menu (same approach WeeklyRewards
-- uses in Midnight). Click a name to check/uncheck it; Ctrl-click to remove.
local function BuildCharacterMenu(_, rootDescription)
    local tracker = Tracker()
    local balances = GetBalances()
    local hidden = balances.hidden or {}
    local list = {}
    local shown = 0
    for guid, entry in pairs(balances.characters or {}) do
        list[#list + 1] = { guid = guid, entry = entry }
        if not hidden[guid] then
            shown = shown + 1
        end
    end
    table.sort(list, function(a, b)
        local nameA, nameB = tostring(a.entry.name or ""), tostring(b.entry.name or "")
        if nameA ~= nameB then
            return nameA < nameB
        end
        return tostring(a.entry.realm or "") < tostring(b.entry.realm or "")
    end)

    rootDescription:CreateTitle(string.format("|cffffffffCharacters (%d/%d)|r", shown, #list))
    for _, item in ipairs(list) do
        -- Always show the server: same name on two servers is common.
        local guid, nameText = item.guid, ClassColoredName(item.entry)
        if item.entry.realm then
            nameText = nameText .. "|cff888888-" .. tostring(item.entry.realm) .. "|r"
        end
        local checkbox = rootDescription:CreateCheckbox(nameText, function()
            return not hidden[guid]
        end)
        checkbox:SetResponder(function()
            if not tracker then
                return MenuResponse.Refresh
            end
            if IsControlKeyDown() then
                if guid == (UnitGUID and UnitGUID("player")) then
                    PocketCFO:Print("You can't remove the character you are playing.")
                else
                    StaticPopup_ShowGenericConfirmation(
                        string.format("Remove %s from the list?\nThey come back if you log in on them.", nameText),
                        function()
                            tracker:RemoveCharacter(guid)
                        end)
                end
            else
                tracker:SetHidden(guid, not hidden[guid])
                hidden = GetBalances().hidden or {}
            end
            return MenuResponse.Refresh
        end)
    end
    rootDescription:CreateSpacer()
    rootDescription:CreateTitle("|cff20ff20Uncheck to hide. Ctrl-click to remove.|r")
end

-- ---------------------------------------------------------------------------
-- Window shell
-- ---------------------------------------------------------------------------

function GoldWindow:BuildWindow()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "MCGCFOGoldWindow", UIParent, "BackdropTemplate")
    frame:SetSize(WINDOW_WIDTH, 160)
    -- Anchored by its top edge so height changes grow/shrink from the bottom
    -- and the tabs and controls never move.
    frame:SetPoint("TOP", UIParent, "CENTER", 0, 200)
    frame:SetFrameStrata("DIALOG")
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- Re-anchor by the top-left corner after a drag (the game may pick a
        -- different anchor point when a drag ends).
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
    end)
    frame:Hide()

    local title = CreateText(frame, "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -10)
    title:SetText("Gold")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

    -- People button: pick which characters show (gap so it isn't the X).
    local people = CreateFrame("DropdownButton", nil, frame)
    people:SetSize(24, 24)
    people:SetPoint("RIGHT", close, "LEFT", -10, 0)
    people.icon = people:CreateTexture(nil, "ARTWORK")
    people.icon:SetAtlas("squad_size_trios")
    people.icon:SetSize(18, 18)
    people.icon:SetPoint("CENTER")
    people.icon:SetVertexColor(0.7, 0.7, 0.7, 1)
    people:SetScript("OnEnter", function(self)
        self.icon:SetVertexColor(1, 1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Characters", 1, 1, 1)
        GameTooltip:AddLine("Pick which characters show here.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    people:SetScript("OnLeave", function(self)
        self.icon:SetVertexColor(0.7, 0.7, 0.7, 1)
        GameTooltip:Hide()
    end)
    people:SetupMenu(BuildCharacterMenu)
    frame.peopleButton = people

    -- Settings: opens the Pocket CFO settings page (2026-10-31). The Gold
    -- window closes first so the settings page isn't hidden behind it.
    local gear = CreateFrame("Button", nil, frame)
    gear:SetSize(18, 18)
    gear:SetPoint("RIGHT", people, "LEFT", -6, 0)
    gear:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
    gear:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    gear:SetScript("OnClick", function()
        local beta = PocketCFO:GetModule("BetaFeatures", true)
        frame:Hide()
        if beta and beta.OpenSettings then
            beta:OpenSettings()
        end
    end)
    gear:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Settings", 1, 1, 1)
        GameTooltip:AddLine("Open the Pocket CFO settings.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    gear:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    frame.settingsButton = gear

    frame.tabs = {}
    local tabDefs = {
        { key = "gph",      label = "Gold per Hour", width = 96 },
        { key = "balances", label = "Balances", width = 76 },
        { key = "income",   label = "Income", width = 70 },
        { key = "spending", label = "Spending", width = 76 },
    }
    if not IS_FOREVER then
        tabDefs[#tabDefs + 1] = { key = "orders", label = "Orders", width = 70 }
    end
    local x = 12
    for _, def in ipairs(tabDefs) do
        local tab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        tab:SetSize(def.width, 22)
        tab:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -30)
        tab:SetText(def.label)
        tab:SetScript("OnClick", function()
            GoldWindow:ShowTab(def.key)
        end)
        frame.tabs[def.key] = tab
        x = x + def.width + 4
    end

    frame.balancesPane = CreateFrame("Frame", nil, frame)
    frame.balancesPane:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -60)
    frame.balancesPane:SetSize(INNER_WIDTH, 10)
    frame.balancesPane.rows = {}

    frame.incomePane = CreateFrame("Frame", nil, frame)
    frame.incomePane:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -60)
    frame.incomePane:SetSize(INNER_WIDTH, 10)

    frame.gphPane = CreateFrame("Frame", nil, frame)
    frame.gphPane:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -60)
    frame.gphPane:SetSize(INNER_WIDTH, 10)

    if not IS_FOREVER then
        frame.ordersPane = CreateFrame("Frame", nil, frame)
        frame.ordersPane:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -60)
        frame.ordersPane:SetSize(INNER_WIDTH, 10)
    end

    self.frame = frame
    self.activeTab = SavedTab()
    self.periodKey = PocketCFO_PnL.IncomeReport.DEFAULT_PERIOD
    self.characterGUID = nil
    self.expanded = {}

    self:BuildIncomeControls()
    self:BuildGoldPerHourPane()
    if not IS_FOREVER then
        self:BuildOrdersPane()
    end

    if UISpecialFrames then
        table.insert(UISpecialFrames, "MCGCFOGoldWindow")
    end

    self:RegisterMessage("MCG_GOLD_BALANCES_CHANGED", "OnDataChanged")
    self:RegisterMessage("MCG_GOLD_LEDGER_UPDATED", "OnDataChanged")
    self:RegisterMessage("MCG_ORDER_RESULTS_UPDATED", "OnDataChanged")
end

function GoldWindow:OnDataChanged()
    if self.frame and self.frame:IsShown() then
        self:Render()
    end
end

function GoldWindow:ShowTab(tabKey)
    if not VALID_TABS[tabKey] or (tabKey == "orders" and IS_FOREVER) then
        tabKey = "gph"
    end
    self.activeTab = tabKey
    SettingsTable().goldWindowTab = tabKey
    for key, tab in pairs(self.frame.tabs) do
        if key == self.activeTab then
            tab:LockHighlight()
        else
            tab:UnlockHighlight()
        end
    end
    self:Render()
end

-- tabKey nil = the last tab used.
function GoldWindow:Toggle(tabKey)
    self:BuildWindow()
    tabKey = tabKey or self.activeTab
    if self.frame:IsShown() and tabKey == self.activeTab then
        self.frame:Hide()
        return
    end
    self.frame:Show()
    self:ShowTab(tabKey)
end

function GoldWindow:Render()
    if not self.frame then
        return
    end
    -- The picked toon was unchecked or removed: go back to all toons.
    local tracker = Tracker()
    if self.characterGUID and tracker and tracker.IsShown and not tracker:IsShown(self.characterGUID) then
        self.characterGUID = nil
    end
    local panes = {
        balances = self.frame.balancesPane,
        income = self.frame.incomePane,
        spending = self.frame.incomePane,  -- Spending shares the Income pane
        orders = self.frame.ordersPane,
        gph = self.frame.gphPane,
    }
    for key, pane in pairs(panes) do
        if pane ~= panes[self.activeTab] then
            pane:Hide()
        end
    end
    local height
    if self.activeTab == "income" or self.activeTab == "spending" then
        height = self:RenderIncome()
    elseif self.activeTab == "orders" then
        height = self:RenderOrders()
    elseif self.activeTab == "gph" then
        height = self:RenderGoldPerHour()
    else
        height = self:RenderBalances()
    end
    panes[self.activeTab]:Show()
    self.frame:SetHeight(60 + height + 12)
end

-- ---------------------------------------------------------------------------
-- Balances tab
-- ---------------------------------------------------------------------------

function GoldWindow:GetBalanceRow(index)
    local pane = self.frame.balancesPane
    local row = pane.rows[index]
    if row then
        return row
    end
    row = CreateFrame("Frame", nil, pane)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, -(index - 1) * ROW_HEIGHT)
    row.name = CreateText(row, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.name:SetWidth(170)
    row.age = CreateText(row, "GameFontDisableSmall", "RIGHT")
    row.age:SetPoint("LEFT", row, "LEFT", 172, 0)
    row.age:SetWidth(60)
    row.money = CreateText(row, "GameFontHighlightSmall", "RIGHT")
    row.money:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.money:SetWidth(INNER_WIDTH - 236)
    pane.rows[index] = row
    return row
end

function GoldWindow:RenderBalances()
    local balances = GetBalances()
    local characters = SortedCharacters(balances.characters, balances.hidden)
    local anyHidden = next(balances.hidden or {}) ~= nil
    local characterTotal = 0
    for _, item in ipairs(characters) do
        characterTotal = characterTotal + (tonumber(item.entry.copper) or 0)
    end
    table.sort(characters, function(a, b)
        return (tonumber(a.entry.copper) or 0) > (tonumber(b.entry.copper) or 0)
    end)

    local warband = balances.warband
    local warbandCopper = warband and tonumber(warband.copper) or nil
    if IS_FOREVER then
        warbandCopper = nil
    end
    local lines = {}
    lines[#lines + 1] = {
        name = "|cffffd100Account Total|r",
        money = FormatMoneyExact(characterTotal + (warbandCopper or 0)),
    }
    if anyHidden then
        lines[#lines + 1] = { name = "|cff888888Unchecked characters not included|r" }
    end
    if not IS_FOREVER then
        lines[#lines + 1] = {
            name = "Warband Bank",
            money = warbandCopper and FormatMoneyExact(warbandCopper) or "|cff888888visit a bank to load|r",
            age = warband and FormatAge(warband.updatedAt) or "",
        }
    end
    lines[#lines + 1] = {}
    local currentRealm = GetRealmName and GetRealmName()
    local function NameWithRealm(entry)
        local name = ClassColoredName(entry)
        if entry.realm and entry.realm ~= currentRealm then
            name = name .. "|cff888888-" .. tostring(entry.realm) .. "|r"
        end
        return name
    end
    for _, item in ipairs(characters) do
        if #lines >= MAX_BALANCE_ROWS then
            break
        end
        local entry = item.entry
        lines[#lines + 1] = {
            name = NameWithRealm(entry),
            money = FormatMoneyExact(entry.copper),
            age = FormatAge(entry.updatedAt),
        }
    end

    local pane = self.frame.balancesPane
    for index, line in ipairs(lines) do
        local row = self:GetBalanceRow(index)
        row.name:SetText(line.name or "")
        row.money:SetText(line.money or "")
        row.age:SetText(line.age or "")
        row:Show()
    end
    for index = #lines + 1, #pane.rows do
        pane.rows[index]:Hide()
    end
    local height = #lines * ROW_HEIGHT
    pane:SetHeight(height)
    return height
end

-- ---------------------------------------------------------------------------
-- Income tab
-- ---------------------------------------------------------------------------

-- Period buttons + toon dropdown, used by the Income and Orders tabs. Both
-- tabs share GoldWindow.periodKey / GoldWindow.characterGUID.
function GoldWindow:BuildFilterControls(pane, dropdownName)
    local report = PocketCFO_PnL.IncomeReport

    pane.periodButtons = {}
    for index, period in ipairs(report.PERIODS) do
        local button = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
        button:SetSize(66, 20)
        button:SetPoint("TOPLEFT", pane, "TOPLEFT", (index - 1) * 68, 0)
        button:SetText(period.label)
        button:SetScript("OnClick", function()
            GoldWindow.periodKey = period.key
            GoldWindow:Render()
        end)
        pane.periodButtons[period.key] = button
    end

    local dropdown = CreateFrame("Frame", dropdownName, pane, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 10, 3)
    UIDropDownMenu_SetWidth(dropdown, 110)
    UIDropDownMenu_Initialize(dropdown, function()
        local info = UIDropDownMenu_CreateInfo()
        info.text = "All toons"
        info.checked = GoldWindow.characterGUID == nil
        info.func = function()
            GoldWindow.characterGUID = nil
            GoldWindow:Render()
        end
        UIDropDownMenu_AddButton(info)

        local balances = GetBalances()
        local list = SortedCharacters(balances.characters, balances.hidden)
        table.sort(list, function(a, b)
            return tostring(a.entry.name or "") < tostring(b.entry.name or "")
        end)
        for _, item in ipairs(list) do
            info = UIDropDownMenu_CreateInfo()
            info.text = ClassColoredName(item.entry)
            info.checked = GoldWindow.characterGUID == item.guid
            info.func = function()
                GoldWindow.characterGUID = item.guid
                GoldWindow:Render()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    pane.dropdown = dropdown
end

function GoldWindow:UpdateFilterControls(pane, activePeriodKey)
    for key, button in pairs(pane.periodButtons) do
        if key == activePeriodKey then
            button:LockHighlight()
        else
            button:UnlockHighlight()
        end
    end
    local dropdownText = "All toons"
    if self.characterGUID then
        local entry = GetBalances().characters[self.characterGUID]
        dropdownText = entry and ClassColoredName(entry) or "?"
    end
    UIDropDownMenu_SetText(pane.dropdown, dropdownText)
end

function GoldWindow:BuildIncomeControls()
    local pane = self.frame.incomePane
    self:BuildFilterControls(pane, "MCGCFOGoldWindowCharacterDropdown")

    pane.total = CreateText(pane, "GameFontNormal")
    pane.total:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -32)
    pane.total:SetWidth(INNER_WIDTH)

    -- Earned / spent / net for the period (Income and Spending).
    pane.net = CreateText(pane, "GameFontHighlightSmall")
    pane.net:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -50)
    pane.net:SetWidth(INNER_WIDTH)

    pane.empty = CreateText(pane, "GameFontDisableSmall")
    pane.empty:SetWordWrap(true)
    pane.empty:SetWidth(INNER_WIDTH)

    pane.sourceRows = {}

    pane.chartCaption = CreateText(pane, "GameFontDisableSmall")
    pane.chartCaption:SetText("Gold earned per day (hover a bar for details)")
    pane.chart = CreateFrame("Frame", nil, pane)
    pane.chart:SetSize(INNER_WIDTH, CHART_HEIGHT)
    pane.chartBars = {}

    pane.footer = CreateText(pane, "GameFontDisableSmall")
    pane.footer:SetWordWrap(true)
    pane.footer:SetWidth(INNER_WIDTH)
end

function GoldWindow:GetSourceRow(index)
    local pane = self.frame.incomePane
    local row = pane.sourceRows[index]
    if row then
        return row
    end
    row = CreateFrame("Button", nil, pane)
    row:SetHeight(ROW_HEIGHT)
    row:SetSize(INNER_WIDTH, ROW_HEIGHT)
    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 1, 1, 0.06)

    row.label = CreateText(row, "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.label:SetWidth(COL_LABEL)

    row.bar = row:CreateTexture(nil, "ARTWORK")
    row.bar:SetPoint("LEFT", row, "LEFT", COL_LABEL + 4, 0)
    row.bar:SetHeight(10)

    row.amount = CreateText(row, "GameFontHighlightSmall", "RIGHT")
    row.amount:SetPoint("LEFT", row, "LEFT", COL_LABEL + 4 + COL_BAR + 4, 0)
    row.amount:SetWidth(COL_AMOUNT)

    row.share = CreateText(row, "GameFontDisableSmall", "RIGHT")
    row.share:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.share:SetWidth(COL_SHARE)

    -- Right-click: personal spending menu (2026-11-02; Theoretical until seen).
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if self.menuItem then
                GoldWindow:ShowPersonalMenu(self)
            end
            return
        end
        -- Income and Spending share category keys; each line carries its own
        -- expand key (source, AH group, AH second level).
        if self.expandKey then
            GoldWindow.expanded[self.expandKey] = not GoldWindow.expanded[self.expandKey] or nil
            GoldWindow:Render()
        end
    end)
    row:SetScript("OnEnter", function(self)
        if self.sourceKey == "other" then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Unknown")
            GameTooltip:AddLine("Gold PocketCFO couldn't trace to a source.", 1, 1, 1, true)
            GameTooltip:Show()
        elseif self.menuItem then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.menuItem.name)
            GameTooltip:AddLine(self.menuItem.personal and "Right-click: this was for the business"
                or "Right-click: this was personal", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    pane.sourceRows[index] = row
    return row
end

function GoldWindow:GetChartBar(index)
    local pane = self.frame.incomePane
    local bar = pane.chartBars[index]
    if bar then
        return bar
    end
    bar = CreateFrame("Frame", nil, pane.chart)
    bar.fill = bar:CreateTexture(nil, "ARTWORK")
    bar.fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
    bar.fill:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
    bar.fill:SetColorTexture(BAR_COLOR[1], BAR_COLOR[2], BAR_COLOR[3], BAR_COLOR[4])
    bar.base = bar:CreateTexture(nil, "BACKGROUND")
    bar.base:SetAllPoints()
    bar.base:SetColorTexture(1, 1, 1, 0.04)
    bar:EnableMouse(true)
    bar:SetScript("OnEnter", function(self)
        GoldWindow:ShowBarTooltip(self)
    end)
    bar:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    pane.chartBars[index] = bar
    return bar
end

function GoldWindow:ShowBarTooltip(bar)
    local bucket = bar.bucket
    if not bucket then
        return
    end
    local report = PocketCFO_PnL.IncomeReport
    GameTooltip:SetOwner(bar, "ANCHOR_TOP")
    GameTooltip:AddLine(bucket.label)
    GameTooltip:AddDoubleLine("Total", FormatIncome(bucket.copper), 1, 1, 1, 1, 1, 1)
    local list = {}
    for category, copper in pairs(bucket.byCategory) do
        list[#list + 1] = { label = report:GetCategoryLabel(category), copper = copper }
    end
    table.sort(list, function(a, b) return a.copper > b.copper end)
    for _, item in ipairs(list) do
        GameTooltip:AddDoubleLine(item.label, FormatIncome(item.copper), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    GameTooltip:Show()
end

-- Right-click menu on a spending item or a personal item (2026-11-02).
-- Applies to what the row shows: the period and the characters in view.
-- MenuUtil.CreateContextMenu: Theoretical until seen in-game here.
function GoldWindow:ShowPersonalMenu(row)
    local item = row.menuItem
    if not item or not (MenuUtil and MenuUtil.CreateContextMenu) then
        return
    end
    local periodKey, characterGUID = self.periodKey, self.characterGUID
    MenuUtil.CreateContextMenu(row, function(_, rootDescription)
        rootDescription:CreateTitle(item.name)
        rootDescription:CreateButton(item.personal and "This was for the business" or "This was personal", function()
            GameTooltip:Hide()
            PocketCFO_PnL.IncomeReport:SetPersonal(item.name, item.category, periodKey, characterGUID,
                not item.personal)
        end)
    end)
end

-- Adds up to MAX_ITEM_LINES item lines (plus one "N more items" line).
-- menuCategory (Spending only, 2026-11-02): named item lines get a
-- right-click "This was personal" for that category.
local function AddItemLines(lines, items, indent, menuCategory)
    for index, item in ipairs(items or {}) do
        if index > MAX_ITEM_LINES then
            local restCopper = 0
            for rest = index, #items do
                restCopper = restCopper + items[rest].copper
            end
            lines[#lines + 1] = {
                label = string.format("%s|cff888888%d more items|r", indent, #items - MAX_ITEM_LINES),
                copper = restCopper,
                sub = true,
                wide = true,
            }
            return
        end
        lines[#lines + 1] = {
            label = string.format("%s|cffbbbbbb%s|r |cff888888x%d|r", indent, item.label, item.quantity or 0),
            copper = item.copper,
            sub = true,
            wide = true,
            menuItem = (menuCategory and item.label ~= "Unknown item")
                and { name = item.label, category = menuCategory, personal = false } or nil,
        }
    end
end

function GoldWindow:RenderIncome()
    local pane = self.frame.incomePane
    local report = PocketCFO_PnL.IncomeReport
    local isSpending = self.activeTab == "spending"
    local model = report:Build(self.periodKey, self.characterGUID, isSpending and "spend" or nil)
    -- The other side, for the earned / spent / net line.
    local otherModel = report:Build(self.periodKey, self.characterGUID, (not isSpending) and "spend" or nil)
    local other = otherModel.total or 0
    local earned = isSpending and other or model.total
    local spent = isSpending and model.total or other
    -- Personal spending (2026-11-02): not in any number above; its own line.
    local personal = (isSpending and model.personal or otherModel.personal) or { total = 0, items = {} }
    local hasPersonal = (personal.total or 0) > 0

    self:UpdateFilterControls(pane, model.period.key)

    local function Marker(isOpen)
        return isOpen and "- " or "+ "
    end

    -- Build the row list in full before drawing.
    local lines = {}
    for _, source in ipairs(model.sources) do
        local sourceExpandKey = self.activeTab .. ":" .. source.key
        local isOpen = source.expandable and self.expanded[sourceExpandKey]
        lines[#lines + 1] = {
            sourceKey = source.key,
            expandKey = source.expandable and sourceExpandKey or nil,
            label = (source.expandable and Marker(isOpen) or "") .. source.label,
            copper = source.copper,
            share = source.share,
            barShare = source.share,
            color = BAR_COLOR,
        }
        if isOpen and source.groups then
            -- Auction House: what was sold, then a second level, then items.
            for _, group in ipairs(source.groups) do
                local groupKey = sourceExpandKey .. ":g:" .. group.key
                local groupOpen = self.expanded[groupKey]
                lines[#lines + 1] = {
                    expandKey = groupKey,
                    label = "    " .. Marker(groupOpen) .. "|cffdddddd" .. group.label .. "|r",
                    copper = group.copper,
                    barShare = model.total > 0 and (group.copper / model.total) or 0,
                    color = SUB_BAR_COLOR,
                    sub = true,
                }
                if groupOpen then
                    AddItemLines(lines, group.items, "        ")
                    for _, sub in ipairs(group.subs) do
                        local subKey = groupKey .. ":s:" .. sub.key
                        local subOpen = self.expanded[subKey]
                        lines[#lines + 1] = {
                            expandKey = subKey,
                            label = "        " .. Marker(subOpen) .. "|cffbbbbbb" .. sub.label .. "|r",
                            copper = sub.copper,
                            sub = true,
                            wide = true,
                        }
                        if subOpen then
                            AddItemLines(lines, sub.items, "            ")
                        end
                    end
                end
            end
        elseif isOpen and source.showProfessions then
            for _, profession in ipairs(source.professions) do
                lines[#lines + 1] = {
                    label = "    |cffbbbbbb" .. profession.label .. "|r",
                    copper = profession.copper,
                    barShare = model.total > 0 and (profession.copper / model.total) or 0,
                    color = SUB_BAR_COLOR,
                    sub = true,
                }
                -- That profession's items, one level deeper.
                AddItemLines(lines, profession.items, "        ", isSpending and source.key or nil)
            end
        elseif isOpen then
            AddItemLines(lines, source.items, "    ", isSpending and source.key or nil)
        end
    end

    -- Personal spending (2026-11-02): one line right under earned / spent /
    -- net, on Income and Spending, only when the period has any. Click to
    -- list the items; right-click an item to put it back in business spending.
    if hasPersonal then
        local personalOpen = self.expanded.personal
        local personalLines = {
            {
                expandKey = "personal",
                label = "|cff999999" .. Marker(personalOpen) .. "Personal spending (not counted above)|r",
                copper = personal.total,
                sub = true,
                wide = true,
            },
        }
        if personalOpen then
            for _, item in ipairs(personal.items) do
                personalLines[#personalLines + 1] = {
                    label = string.format("    |cff999999%s|r |cff777777x%d|r", item.name, item.quantity or 0),
                    copper = item.copper,
                    sub = true,
                    wide = true,
                    menuItem = { name = item.name, category = item.category, personal = true },
                }
            end
        end
        personalLines[#personalLines].gapAfter = 6
        for index = #personalLines, 1, -1 do
            table.insert(lines, 1, personalLines[index])
        end
    end

    -- Draw.
    local y = -32
    if model.total > 0 or hasPersonal then
        pane.total:SetText((isSpending and "Total spent: " or "Total earned: ") .. FormatIncome(model.total))
        pane.total:Show()
        pane.empty:Hide()
        y = y - 22
        local net = earned - spent
        local netText = (net >= 0) and ("|cff33ff33+" .. FormatIncome(net) .. "|r")
            or ("|cffff4444-" .. FormatIncome(-net) .. "|r")
        pane.net:SetText("Earned " .. FormatIncome(earned) .. "   Spent " .. FormatIncome(spent)
            .. "   Net " .. netText)
        pane.net:Show()
        y = y - 20
    else
        pane.total:Hide()
        pane.net:Hide()
        pane.empty:ClearAllPoints()
        pane.empty:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        pane.empty:SetText(isSpending
            and "No spending recorded for this period yet. Spending is counted from the day PocketCFO was installed."
            or "No income recorded for this period yet. Gold is counted from the day PocketCFO was installed.")
        pane.empty:Show()
        y = y - 32
    end
    pane.chartCaption:SetText(isSpending and "Gold spent per day (hover a bar for details)"
        or "Gold earned per day (hover a bar for details)")
    pane.footer:SetText(isSpending
        and "Gold moved between your own characters is not counted."
        or "Open your mailbox to include your latest Auction House sales.")

    for index, line in ipairs(lines) do
        local row = self:GetSourceRow(index)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        row.sourceKey = line.sourceKey
        row.expandKey = line.expandKey
        row.menuItem = line.menuItem
        row.label:SetText(line.label)
        row.label:SetWidth(line.wide and (COL_LABEL + 4 + COL_BAR) or COL_LABEL)
        row.amount:SetText(FormatIncome(line.copper))
        row.share:SetText(line.sub and "" or FormatShare(line.share))
        local width = math.floor(COL_BAR * (line.barShare or 0))
        if not line.wide and width >= 1 then
            row.bar:SetWidth(width)
            row.bar:SetColorTexture(line.color[1], line.color[2], line.color[3], line.color[4])
            row.bar:Show()
        else
            row.bar:Hide()
        end
        row:Show()
        y = y - ROW_HEIGHT - (line.gapAfter or 0)
    end
    for index = #lines + 1, #pane.sourceRows do
        pane.sourceRows[index]:Hide()
    end

    -- Chart (hidden for Today or when there is nothing to show).
    local chart = model.chart
    if chart and model.total > 0 then
        y = y - 10
        pane.chartCaption:ClearAllPoints()
        pane.chartCaption:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        pane.chartCaption:Show()
        y = y - 14
        pane.chart:ClearAllPoints()
        pane.chart:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        pane.chart:Show()

        local count = #chart
        local barWidth = math.min(MAX_BAR_WIDTH,
            math.floor((INNER_WIDTH - (count - 1) * CHART_GAP) / count))
        local maxCopper = 0
        for _, bucket in ipairs(chart) do
            if bucket.copper > maxCopper then
                maxCopper = bucket.copper
            end
        end
        for index, bucket in ipairs(chart) do
            local bar = self:GetChartBar(index)
            bar:ClearAllPoints()
            bar:SetSize(barWidth, CHART_HEIGHT)
            bar:SetPoint("BOTTOMLEFT", pane.chart, "BOTTOMLEFT", (index - 1) * (barWidth + CHART_GAP), 0)
            bar.bucket = bucket
            local fillHeight = maxCopper > 0 and math.floor(CHART_HEIGHT * bucket.copper / maxCopper) or 0
            if bucket.copper > 0 and fillHeight < 1 then
                fillHeight = 1
            end
            if fillHeight > 0 then
                bar.fill:SetHeight(fillHeight)
                bar.fill:Show()
            else
                bar.fill:Hide()
            end
            bar:Show()
        end
        for index = count + 1, #pane.chartBars do
            pane.chartBars[index]:Hide()
        end
        y = y - CHART_HEIGHT
    else
        pane.chartCaption:Hide()
        pane.chart:Hide()
    end

    y = y - 10
    pane.footer:ClearAllPoints()
    pane.footer:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
    y = y - 14

    local height = -y
    pane:SetHeight(height)
    return height
end

-- ---------------------------------------------------------------------------
-- Shared helpers for tab files
-- ---------------------------------------------------------------------------

GoldWindow.ui = {
    CreateText = CreateText,
    FormatMoney = FormatIncome,
    ROW_HEIGHT = ROW_HEIGHT,
    INNER_WIDTH = INNER_WIDTH,
}
