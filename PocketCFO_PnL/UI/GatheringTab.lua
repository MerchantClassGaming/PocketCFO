-- PocketCFO_PnL/UI/GatheringTab.lua
-- Gathering tab of the Gold window: what you gathered, valued at the price
-- when you picked it up, by profession (click to see items), recent
-- gathering sessions with gold per hour, and a start/stop session button.
-- Shares the period buttons and toon dropdown with Income and Orders.
-- Data: PocketCFO_PnL.GatheringReport (reads core GatheringCapture).

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL
local GoldWindow = PocketCFO_PnL:GetModule("GoldWindow")

local COL_LABEL = 210
local COL_COUNT = 80
local MAX_ITEM_LINES = 10

local NOTE_TEXT = "What you gathered, valued at the price when you picked it up. "
    .. "This is the value of the items, not gold you have made yet."

-- Vertical layout (pane-relative).
local Y_NOTE = -28
local Y_TOTAL = -60
local Y_ROWS = -82

local function UI()
    return GoldWindow.ui
end

local function Report()
    return PocketCFO_PnL.GatheringReport
end

local function NodesText(count)
    count = tonumber(count) or 0
    return count == 1 and "1 node" or (count .. " nodes")
end

function GoldWindow:BuildGatheringPane()
    local pane = self.frame.gatheringPane
    local ui = UI()
    self:BuildFilterControls(pane, "MCGCFOGoldWindowGatheringCharacterDropdown")

    pane.note = ui.CreateText(pane, "GameFontDisableSmall")
    pane.note:SetWordWrap(true)
    pane.note:SetWidth(ui.INNER_WIDTH)
    pane.note:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_NOTE)
    pane.note:SetText(NOTE_TEXT)

    pane.total = ui.CreateText(pane, "GameFontNormal")
    pane.total:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_TOTAL)
    pane.total:SetWidth(ui.INNER_WIDTH)

    pane.empty = ui.CreateText(pane, "GameFontDisableSmall")
    pane.empty:SetWordWrap(true)
    pane.empty:SetWidth(ui.INNER_WIDTH)

    pane.sessionsHeader = ui.CreateText(pane, "GameFontNormalSmall")
    pane.sessionsHeader:SetText("Recent gathering sessions")

    pane.sessionButton = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    pane.sessionButton:SetSize(200, 22)
    pane.sessionButton:SetScript("OnClick", function()
        local capture = PocketCFO:GetModule("GatheringCapture", true)
        if capture then
            capture:ToggleSession()
        end
    end)

    pane.rows = {}
    self.gatheringExpanded = {}
end

function GoldWindow:GetGatheringRow(index)
    local pane = self.frame.gatheringPane
    local row = pane.rows[index]
    if row then
        return row
    end
    local ui = UI()
    row = CreateFrame("Button", nil, pane)
    row:SetSize(ui.INNER_WIDTH, ui.ROW_HEIGHT)
    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 1, 1, 0.06)

    row.label = ui.CreateText(row, "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.label:SetWidth(COL_LABEL)

    row.count = ui.CreateText(row, "GameFontDisableSmall", "RIGHT")
    row.count:SetPoint("LEFT", row, "LEFT", COL_LABEL + 4, 0)
    row.count:SetWidth(COL_COUNT)

    row.amount = ui.CreateText(row, "GameFontHighlightSmall", "RIGHT")
    row.amount:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.amount:SetWidth(ui.INNER_WIDTH - COL_LABEL - COL_COUNT - 8)

    row:SetScript("OnClick", function(self)
        if self.professionKey then
            GoldWindow.gatheringExpanded[self.professionKey] = not GoldWindow.gatheringExpanded[self.professionKey] or nil
            GoldWindow:Render()
        end
    end)
    pane.rows[index] = row
    return row
end

local function AddItemLines(lines, items)
    for index, item in ipairs(items) do
        if index > MAX_ITEM_LINES then
            local restCopper = 0
            for rest = index, #items do
                restCopper = restCopper + items[rest].copper
            end
            lines[#lines + 1] = {
                label = string.format("        |cff888888%d more items|r", #items - MAX_ITEM_LINES),
                count = "",
                copper = restCopper,
            }
            return
        end
        lines[#lines + 1] = {
            label = "        " .. tostring(item.label),
            count = "x" .. tostring(item.quantity or 0),
            copper = item.copper,
        }
    end
end

function GoldWindow:RenderGathering()
    local pane = self.frame.gatheringPane
    local ui = UI()
    local report = Report()
    local model = report:Build(self.periodKey, self.characterGUID)
    self:UpdateFilterControls(pane, model.period.key)

    -- Build every line before drawing anything.
    local lines = {}
    for _, profession in ipairs(model.professions) do
        local isOpen = self.gatheringExpanded[profession.key]
        lines[#lines + 1] = {
            professionKey = profession.key,
            label = (isOpen and "- " or "+ ") .. profession.label,
            count = NodesText(profession.nodes),
            copper = profession.copper,
        }
        if isOpen then
            AddItemLines(lines, profession.items)
        end
    end

    local y
    if model.nodes > 0 then
        local text = string.format("Gathered: %s  |cff888888(%s)|r", ui.FormatMoney(model.total), NodesText(model.nodes))
        if model.unpriced > 0 then
            text = text .. "  |cff888888some items have no price yet|r"
        end
        pane.total:SetText(text)
        pane.total:Show()
        pane.empty:Hide()
        y = Y_ROWS
    else
        pane.total:Hide()
        pane.empty:ClearAllPoints()
        pane.empty:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_TOTAL)
        if not model.available then
            pane.empty:SetText("Gathering data is unavailable right now.")
        else
            pane.empty:SetText("Nothing gathered in this period yet. Herbs, ore and skins are counted as you loot them.")
        end
        pane.empty:Show()
        y = Y_TOTAL - 28
    end

    -- Sessions after the profession rows.
    local sessionLines = {}
    for _, session in ipairs(model.sessions) do
        local perHour = session.perHour and (ui.FormatMoney(session.perHour) .. "/hr") or "-"
        sessionLines[#sessionLines + 1] = {
            label = "    |cffbbbbbb" .. session.label .. "|r",
            count = report:FormatDuration(session.seconds),
            amountText = perHour,
        }
    end

    local index = 0
    local function DrawLine(line)
        index = index + 1
        local row = self:GetGatheringRow(index)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        row.professionKey = line.professionKey
        row.label:SetText(line.label)
        row.count:SetText(line.count or "")
        row.amount:SetText(line.amountText or ui.FormatMoney(line.copper))
        row:Show()
        y = y - ui.ROW_HEIGHT
    end
    for _, line in ipairs(lines) do
        DrawLine(line)
    end

    if #sessionLines > 0 then
        y = y - 8
        pane.sessionsHeader:ClearAllPoints()
        pane.sessionsHeader:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        pane.sessionsHeader:Show()
        y = y - 16
        for _, line in ipairs(sessionLines) do
            DrawLine(line)
        end
    else
        pane.sessionsHeader:Hide()
    end
    for rest = index + 1, #pane.rows do
        pane.rows[rest]:Hide()
    end

    y = y - 10
    pane.sessionButton:ClearAllPoints()
    pane.sessionButton:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
    pane.sessionButton:SetText(model.activeSession and "Stop Gathering Session" or "Start Gathering Session")
    y = y - 22

    local height = -y + 8
    pane:SetHeight(height)
    return height
end
