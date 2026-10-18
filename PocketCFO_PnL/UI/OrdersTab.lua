-- PocketCFO_PnL/UI/OrdersTab.lua
-- Orders tab of the Gold window: what completed crafting orders earned,
-- by profession, with each profession expandable into order types.
-- Order type checkboxes (all checked by default, not saved) filter every
-- number on the tab. The explanation note sits at the top so it is read
-- before the numbers.
-- Data: PocketCFO_PnL.OrderReport (reads PocketCFO_Orders' OrdersLedger).

local PocketCFO_PnL = _G.PocketCFO_PnL
local GoldWindow = PocketCFO_PnL:GetModule("GoldWindow")

local COL_LABEL = 200
local COL_COUNT = 90
local CHECKBOX_SIZE = 20
local CHECKBOX_SPACING = 100

local NOTE_TEXT = "Gold paid plus the value of rewards and returned mats, minus the mats you used. "
    .. "Values are from when each order was completed."

local TYPE_FILTERS = {
    { key = "patron",   label = "Patron" },
    { key = "personal", label = "Personal" },
    { key = "public",   label = "Public" },
    { key = "guild",    label = "Guild" },
}

-- Vertical layout (pane-relative).
local Y_CHECKBOXES = -28
local Y_NOTE = -54
local Y_TOTAL = -86
local Y_PARTS = -104
local PARTS_ROW_HEIGHT = 16
local Y_ROWS = -144

-- Breakdown shown as two rows of two: label left, amount right-aligned.
local PART_CELLS = {
    { field = "goldPaid",        label = "Gold paid",       row = 1, col = 1 },
    { field = "rewards",         label = "Rewards",         row = 1, col = 2 },
    { field = "resourcefulness", label = "Resourcefulness", row = 2, col = 1 },
    { field = "mats",            label = "Mats used",       row = 2, col = 2, negative = true },
}
local PART_COLUMN_GAP = 16

local function UI()
    return GoldWindow.ui
end

local function FormatSigned(copper)
    copper = tonumber(copper) or 0
    if copper < 0 then
        return "|cffff6060-" .. UI().FormatMoney(-copper) .. "|r"
    end
    return UI().FormatMoney(copper)
end

local function OrdersText(count)
    count = tonumber(count) or 0
    return count == 1 and "1 order" or (count .. " orders")
end

-- Plain check button from Blizzard's standard checkbox textures (no template).
local function CreateCheckbox(parent, label)
    local check = CreateFrame("CheckButton", nil, parent)
    check:SetSize(CHECKBOX_SIZE, CHECKBOX_SIZE)
    check:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    check:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    check:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    check:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    check.label = UI().CreateText(check, "GameFontHighlightSmall")
    check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
    check.label:SetText(label)
    check:SetHitRectInsets(0, -60, 0, 0)
    return check
end

function GoldWindow:BuildOrdersPane()
    local pane = self.frame.ordersPane
    local ui = UI()
    self:BuildFilterControls(pane, "MCGCFOGoldWindowOrdersCharacterDropdown")

    self.ordersTypeHidden = {}
    pane.typeChecks = {}
    for index, filter in ipairs(TYPE_FILTERS) do
        local check = CreateCheckbox(pane, filter.label)
        check:SetPoint("TOPLEFT", pane, "TOPLEFT", (index - 1) * CHECKBOX_SPACING, Y_CHECKBOXES)
        check:SetChecked(true)
        check:SetScript("OnClick", function(button)
            GoldWindow.ordersTypeHidden[filter.key] = not button:GetChecked() or nil
            GoldWindow:Render()
        end)
        pane.typeChecks[filter.key] = check
    end

    pane.note = ui.CreateText(pane, "GameFontDisableSmall")
    pane.note:SetWordWrap(true)
    pane.note:SetWidth(ui.INNER_WIDTH)
    pane.note:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_NOTE)
    pane.note:SetText(NOTE_TEXT)

    pane.total = ui.CreateText(pane, "GameFontNormal")
    pane.total:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_TOTAL)
    pane.total:SetWidth(ui.INNER_WIDTH)

    local columnWidth = math.floor((ui.INNER_WIDTH - PART_COLUMN_GAP) / 2)
    pane.partCells = {}
    for _, cell in ipairs(PART_CELLS) do
        local x = (cell.col - 1) * (columnWidth + PART_COLUMN_GAP)
        local y = Y_PARTS - (cell.row - 1) * PARTS_ROW_HEIGHT
        local label = ui.CreateText(pane, "GameFontDisableSmall")
        label:SetPoint("TOPLEFT", pane, "TOPLEFT", x, y)
        label:SetText(cell.label)
        local value = ui.CreateText(pane, "GameFontHighlightSmall", "RIGHT")
        value:SetPoint("TOPLEFT", pane, "TOPLEFT", x, y)
        value:SetWidth(columnWidth)
        pane.partCells[#pane.partCells + 1] = { spec = cell, label = label, value = value }
    end

    pane.empty = ui.CreateText(pane, "GameFontDisableSmall")
    pane.empty:SetWordWrap(true)
    pane.empty:SetWidth(ui.INNER_WIDTH)
    pane.empty:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_TOTAL)

    pane.rows = {}
    self.ordersExpanded = {}
end

function GoldWindow:GetOrdersRow(index)
    local pane = self.frame.ordersPane
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
            GoldWindow.ordersExpanded[self.professionKey] = not GoldWindow.ordersExpanded[self.professionKey] or nil
            GoldWindow:Render()
        end
    end)
    pane.rows[index] = row
    return row
end

function GoldWindow:RenderOrders()
    local pane = self.frame.ordersPane
    local ui = UI()
    local model = PocketCFO_PnL.OrderReport:Build(self.periodKey, self.characterGUID, self.ordersTypeHidden)
    self:UpdateFilterControls(pane, model.period.key)

    -- Build every line before drawing anything.
    local lines = {}
    for _, profession in ipairs(model.professions) do
        local isOpen = self.ordersExpanded[profession.key]
        lines[#lines + 1] = {
            professionKey = profession.key,
            label = (isOpen and "- " or "+ ") .. profession.label,
            count = OrdersText(profession.totals.orders),
            amount = FormatSigned(profession.totals.earned),
        }
        if isOpen then
            for _, orderType in ipairs(profession.types) do
                lines[#lines + 1] = {
                    label = "    |cffbbbbbb" .. orderType.label .. "|r",
                    count = OrdersText(orderType.totals.orders),
                    amount = FormatSigned(orderType.totals.earned),
                }
            end
        end
    end

    local totals = model.totals
    local y
    if totals.orders > 0 then
        pane.total:SetText(string.format("Earned from orders: %s  |cff888888(%s)|r",
            FormatSigned(totals.earned), OrdersText(totals.orders)))
        for _, cell in ipairs(pane.partCells) do
            local amount = tonumber(totals[cell.spec.field]) or 0
            cell.value:SetText(FormatSigned(cell.spec.negative and -amount or amount))
            cell.label:Show()
            cell.value:Show()
        end
        pane.total:Show()
        pane.empty:Hide()
        y = Y_ROWS
    else
        pane.total:Hide()
        for _, cell in ipairs(pane.partCells) do
            cell.label:Hide()
            cell.value:Hide()
        end
        local anyHidden = next(self.ordersTypeHidden) ~= nil
        if not model.available then
            pane.empty:SetText("Order results are unavailable right now.")
        elseif anyHidden then
            pane.empty:SetText("No completed orders of the checked types for this period.")
        else
            pane.empty:SetText("No completed orders recorded for this period yet.")
        end
        pane.empty:Show()
        y = Y_TOTAL - 28
    end

    for index, line in ipairs(lines) do
        local row = self:GetOrdersRow(index)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, y)
        row.professionKey = line.professionKey
        row.label:SetText(line.label)
        row.count:SetText(line.count)
        row.amount:SetText(line.amount)
        row:Show()
        y = y - ui.ROW_HEIGHT
    end
    for index = #lines + 1, #pane.rows do
        pane.rows[index]:Hide()
    end

    local height = -y + 8
    pane:SetHeight(height)
    return height
end
