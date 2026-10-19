-- PocketCFO_PnL/UI/GoldWindow.lua
-- The Gold window: two tabs.
--   Balances - current gold per character, warband bank, account total
--              (moved here from core GoldTracker; data still owned by core).
--   Orders   - what completed crafting orders earned (UI/OrdersTab.lua).
--   Income   - where gold came from, by period and character. Click a source
--              to split it by profession and/or see its top items (AH sales).
--              Bars per day show income over time.
-- Opened by core: /mcg gold -> GoldTracker:OpenWindow("balances").
-- Numbers are built in full before anything is drawn (no partial redraws).

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL

local GoldWindow = PocketCFO_PnL:NewModule("GoldWindow", "AceEvent-3.0")
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

local COL_LABEL = 120
local COL_BAR = 140
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

local function SortedCharacters(characters)
    local list = {}
    for guid, entry in pairs(characters or {}) do
        list[#list + 1] = { guid = guid, entry = entry }
    end
    return list
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

    frame.tabs = {}
    local tabDefs = {
        { key = "balances", label = "Balances" },
        { key = "income",   label = "Income" },
        { key = "orders",   label = "Orders" },
    }
    for index, def in ipairs(tabDefs) do
        local tab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        tab:SetSize(90, 22)
        tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + (index - 1) * 94, -30)
        tab:SetText(def.label)
        tab:SetScript("OnClick", function()
            GoldWindow:ShowTab(def.key)
        end)
        frame.tabs[def.key] = tab
    end

    frame.balancesPane = CreateFrame("Frame", nil, frame)
    frame.balancesPane:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -60)
    frame.balancesPane:SetSize(INNER_WIDTH, 10)
    frame.balancesPane.rows = {}

    frame.incomePane = CreateFrame("Frame", nil, frame)
    frame.incomePane:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -60)
    frame.incomePane:SetSize(INNER_WIDTH, 10)

    frame.ordersPane = CreateFrame("Frame", nil, frame)
    frame.ordersPane:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -60)
    frame.ordersPane:SetSize(INNER_WIDTH, 10)

    self.frame = frame
    self.activeTab = "balances"
    self.periodKey = PocketCFO_PnL.IncomeReport.DEFAULT_PERIOD
    self.characterGUID = nil
    self.expanded = {}

    self:BuildIncomeControls()
    self:BuildOrdersPane()

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
    if tabKey ~= "income" and tabKey ~= "orders" then
        tabKey = "balances"
    end
    self.activeTab = tabKey
    for key, tab in pairs(self.frame.tabs) do
        if key == self.activeTab then
            tab:LockHighlight()
        else
            tab:UnlockHighlight()
        end
    end
    self:Render()
end

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
    local panes = {
        balances = self.frame.balancesPane,
        income = self.frame.incomePane,
        orders = self.frame.ordersPane,
    }
    for key, pane in pairs(panes) do
        if key ~= self.activeTab then
            pane:Hide()
        end
    end
    local height
    if self.activeTab == "income" then
        height = self:RenderIncome()
    elseif self.activeTab == "orders" then
        height = self:RenderOrders()
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
    local characters = {}
    local characterTotal = 0
    for _, item in ipairs(SortedCharacters(balances.characters)) do
        characters[#characters + 1] = item.entry
        characterTotal = characterTotal + (tonumber(item.entry.copper) or 0)
    end
    table.sort(characters, function(a, b)
        return (tonumber(a.copper) or 0) > (tonumber(b.copper) or 0)
    end)

    local warband = balances.warband
    local warbandCopper = warband and tonumber(warband.copper) or nil
    local lines = {}
    lines[#lines + 1] = {
        name = "|cffffd100Account Total|r",
        money = FormatMoneyExact(characterTotal + (warbandCopper or 0)),
    }
    lines[#lines + 1] = {
        name = "Warband Bank",
        money = warbandCopper and FormatMoneyExact(warbandCopper) or "|cff888888visit a bank to load|r",
        age = warband and FormatAge(warband.updatedAt) or "",
    }
    lines[#lines + 1] = {}
    local currentRealm = GetRealmName and GetRealmName()
    for _, entry in ipairs(characters) do
        if #lines >= MAX_BALANCE_ROWS then
            break
        end
        local name = ClassColoredName(entry)
        if entry.realm and entry.realm ~= currentRealm then
            name = name .. "|cff888888-" .. tostring(entry.realm) .. "|r"
        end
        lines[#lines + 1] = {
            name = name,
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

        local list = SortedCharacters(GetBalances().characters)
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
    pane.footer:SetText("Open your mailbox to include your latest Auction House sales.")
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

    row:SetScript("OnClick", function(self)
        if self.sourceKey and self.expandable then
            GoldWindow.expanded[self.sourceKey] = not GoldWindow.expanded[self.sourceKey] or nil
            GoldWindow:Render()
        end
    end)
    row:SetScript("OnEnter", function(self)
        if self.sourceKey == "other" then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Unknown")
            GameTooltip:AddLine("Gold PocketCFO couldn't trace to a source.", 1, 1, 1, true)
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

-- Adds up to MAX_ITEM_LINES item lines (plus one "N more items" line).
local function AddItemLines(lines, items, indent)
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
        }
    end
end

function GoldWindow:RenderIncome()
    local pane = self.frame.incomePane
    local report = PocketCFO_PnL.IncomeReport
    local model = report:Build(self.periodKey, self.characterGUID)

    self:UpdateFilterControls(pane, model.period.key)

    -- Build the row list in full before drawing.
    local lines = {}
    for _, source in ipairs(model.sources) do
        local isOpen = source.expandable and self.expanded[source.key]
        local marker = ""
        if source.expandable then
            marker = isOpen and "- " or "+ "
        end
        lines[#lines + 1] = {
            sourceKey = source.key,
            expandable = source.expandable,
            label = marker .. source.label,
            copper = source.copper,
            share = source.share,
            barShare = source.share,
            color = BAR_COLOR,
        }
        if isOpen and source.showProfessions then
            for _, profession in ipairs(source.professions) do
                lines[#lines + 1] = {
                    label = "    |cffbbbbbb" .. profession.label .. "|r",
                    copper = profession.copper,
                    barShare = model.total > 0 and (profession.copper / model.total) or 0,
                    color = SUB_BAR_COLOR,
                    sub = true,
                }
                -- That profession's items, one level deeper.
                AddItemLines(lines, profession.items, "        ")
            end
        elseif isOpen then
            AddItemLines(lines, source.items, "    ")
        end
    end

    -- Draw.
    local y = -32
    if model.total > 0 then
        pane.total:SetText("Total earned: " .. FormatIncome(model.total))
        pane.total:Show()
        pane.empty:Hide()
        y = y - 22
    else
        pane.total:Hide()
        pane.empty:ClearAllPoints()
        pane.empty:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        pane.empty:SetText("No income recorded for this period yet. Gold is counted from the day PocketCFO was installed.")
        pane.empty:Show()
        y = y - 32
    end

    for index, line in ipairs(lines) do
        local row = self:GetSourceRow(index)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        row.sourceKey = line.sourceKey
        row.expandable = line.expandable
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
        y = y - ROW_HEIGHT
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
