-- PocketCFO_AH/UI/CancelAuctionsUI.lua
-- Cancel Auctions page UI.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local CancelAuctionsUI = PocketCFO_AH:NewModule("CancelAuctionsUI")

local VISIBLE_ROWS = 12
local ROW_HEIGHT = 24

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function AddChild(parent, child)
    parent.children = parent.children or {}
    parent.children[#parent.children + 1] = child
    return child
end

local function CreateLabel(parent, text, x, y, width, font, justify)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetWidth(width or 100)
    label:SetJustifyH(justify or "LEFT")
    label:SetText(text)
    return label
end

local function CreateButton(parent, text, x, y, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width or 110, 22)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function FormatCopperString(value)
    value = tonumber(value)
    if not value or value < 0 then
        return ""
    end
    value = math.floor(value + 0.5)
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local copper = value % 100
    local text = ""
    if gold > 0 then
        text = text .. tostring(gold) .. "g"
    end
    if silver > 0 then
        text = text .. tostring(silver) .. "s"
    end
    if copper > 0 or text == "" then
        text = text .. tostring(copper) .. "c"
    end
    return text
end

local function DurationText(value)
    if value == nil then
        return ""
    end
    local duration = tonumber(value)
    if duration == 1 then
        return "Short"
    elseif duration == 2 then
        return "Medium"
    elseif duration == 3 then
        return "Long"
    elseif duration == 4 then
        return "Very Long"
    elseif duration then
        return tostring(duration)
    end
    return tostring(value)
end

local function RowID(row)
    return row and (row.rowID or row.groupKey or row.auctionID)
end

local function RowCanCancel(row)
    return row and row.status == "Undercut" and #(row.auctions or {}) > 0
end

local function FirstCancelableIndex(rows)
    for index, row in ipairs(rows or {}) do
        if RowCanCancel(row) then
            return index
        end
    end
    return nil
end

local function CountStatus(rows, status)
    local count = 0
    for _, row in ipairs(rows or {}) do
        if row and row.status == status then
            count = count + 1
        end
    end
    return count
end

local function GetVisibleListRows(listBox)
    local height = listBox and listBox.GetHeight and listBox:GetHeight() or 0
    if height <= 0 then
        return VISIBLE_ROWS
    end
    local available = height - 28
    if available <= 0 then
        return 1
    end
    return math.max(1, math.min(VISIBLE_ROWS, math.floor(available / ROW_HEIGHT)))
end

local function CreateListMessage(listBox, text, font)
    local frame = CreateFrame("Frame", nil, listBox)
    frame:SetPoint("TOPLEFT", listBox, "TOPLEFT", 4, -24)
    frame:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -4, 4)
    local label = frame:CreateFontString(nil, "OVERLAY", font or "GameFontDisableSmall")
    label:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6)
    label:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)
    label:SetJustifyH("CENTER")
    label:SetJustifyV("MIDDLE")
    label:SetText(text or "")
    frame.Text = label
    return frame
end

local function SetTextColor(button, r, g, b)
    button.ItemText:SetTextColor(r, g, b)
    button.QuantityText:SetTextColor(r, g, b)
    button.PriceText:SetTextColor(r, g, b)
    button.DurationText:SetTextColor(r, g, b)
    button.StatusText:SetTextColor(r, g, b)
    button.NoteText:SetTextColor(r, g, b)
end

local function ShowRowTooltip(button)
    local row = button and button.queueRow
    if not row or not GameTooltip then
        return
    end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(tostring(row.item or row.itemName or "Auction"), 1, 1, 1)
    if row.auctionIDs and #row.auctionIDs > 0 then
        GameTooltip:AddLine("Auction IDs: " .. table.concat(row.auctionIDs, ", "), 0.7, 0.7, 0.7, true)
    end
    if row.note and row.note ~= "" then
        GameTooltip:AddLine(row.note, 0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
end

function CancelAuctionsUI:GetController()
    return PocketCFO_AH:GetModule("CancelAuctionsController", true)
end

function CancelAuctionsUI:CreateQueueRow(parent, x, y, width, height)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(width, height)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    row:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.ItemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ItemText:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.ItemText:SetWidth(180)
    row.ItemText:SetJustifyH("LEFT")

    row.QuantityText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.QuantityText:SetPoint("LEFT", row, "LEFT", 194, 0)
    row.QuantityText:SetWidth(58)
    row.QuantityText:SetJustifyH("CENTER")

    row.PriceText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.PriceText:SetPoint("LEFT", row, "LEFT", 260, 0)
    row.PriceText:SetWidth(92)
    row.PriceText:SetJustifyH("CENTER")

    row.DurationText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.DurationText:SetPoint("LEFT", row, "LEFT", 360, 0)
    row.DurationText:SetWidth(72)
    row.DurationText:SetJustifyH("CENTER")

    row.StatusText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.StatusText:SetPoint("LEFT", row, "LEFT", 440, 0)
    row.StatusText:SetWidth(80)
    row.StatusText:SetJustifyH("CENTER")

    row.NoteText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.NoteText:SetPoint("LEFT", row, "LEFT", 528, 0)
    row.NoteText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.NoteText:SetJustifyH("LEFT")

    return row
end

function CancelAuctionsUI:SelectRow(index, automatic)
    local row = self.rows and self.rows[index] or nil
    self.selectedIndex = row and index or nil
    self.selectedRowID = row and RowID(row) or nil
    self.autoSelected = automatic == true and row ~= nil or false
    self:RefreshRows()
end

function CancelAuctionsUI:RestoreSelection()
    if not self.selectedRowID then
        self.selectedIndex = nil
        return
    end
    self.selectedIndex = nil
    for index, row in ipairs(self.rows or {}) do
        if RowID(row) == self.selectedRowID then
            self.selectedIndex = index
            return
        end
    end
    self.selectedRowID = nil
end

function CancelAuctionsUI:SelectInitialRow()
    local firstCancelable = FirstCancelableIndex(self.rows)
    if firstCancelable then
        self:SelectRow(firstCancelable, true)
    else
        self.selectedIndex = nil
        self.selectedRowID = nil
        self.autoSelected = false
        self:RefreshRows()
    end
end

function CancelAuctionsUI:RefreshRows()
    local list = self.list
    if not list then
        return
    end

    self.rows = self.rows or {}
    self:RestoreSelection()

    local offset = FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(list.scrollFrame) or 0
    local visibleRows = GetVisibleListRows(list.listBox)
    if FauxScrollFrame_Update then
        FauxScrollFrame_Update(list.scrollFrame, #self.rows, visibleRows, ROW_HEIGHT)
    end

    for index, button in ipairs(list.buttons or {}) do
        if index > visibleRows then
            button:Hide()
        else
            local rowIndex = offset + index
            local row = self.rows[rowIndex]
            if row then
                local isInactiveRow =
                    row.status == "OK"
                    or row.status == "Canceled"

                button.queueIndex = rowIndex
                button.queueRow = row
                button.ItemText:SetText(tostring(row.item or row.itemName or ""))
                button.QuantityText:SetText(tostring(row.quantityPosted or row.quantity or 0))
                button.PriceText:SetText(FormatCopperString(row.price))
                button.DurationText:SetText(DurationText(row.duration))
                button.StatusText:SetText(tostring(row.status or ""))
                button.NoteText:SetText(tostring(row.note or row.notes or ""))
                button:Enable()
                button:Show()

                if rowIndex == self.selectedIndex then
                    button:SetBackdropColor(0.18, 0.24, 0.34, 0.95)
                elseif isInactiveRow then
                    button:SetBackdropColor(0.04, 0.04, 0.04, 0.65)
                else
                    button:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
                end

                if isInactiveRow then
                    SetTextColor(button, 0.55, 0.55, 0.55)
                else
                    SetTextColor(button, 1, 1, 1)
                end
            else
                button.queueIndex = nil
                button.queueRow = nil
                button.ItemText:SetText("")
                button.QuantityText:SetText("")
                button.PriceText:SetText("")
                button.DurationText:SetText("")
                button.StatusText:SetText("")
                button.NoteText:SetText("")
                button:Disable()
                button:SetBackdropColor(0.04, 0.04, 0.04, 0.45)
                button:Show()
            end
        end
    end

    local controller = self:GetController()
    local evaluating = controller and controller.IsEvaluationInProgress and controller:IsEvaluationInProgress()
    local cancelling = self.cancelInProgress == true
        or (controller and controller.IsCancelInProgress and controller:IsCancelInProgress() == true)
    local selected = self.selectedIndex and self.rows[self.selectedIndex] or nil
    local cancelButtonEnabled = false
    if self.cancelSelectedButton then
        if cancelling then
            self.cancelSelectedButton:SetText("Cancelling...")
            self.cancelSelectedButton:Disable()
        elseif evaluating then
            self.cancelSelectedButton:SetText("Evaluating...")
            self.cancelSelectedButton:Disable()
        elseif RowCanCancel(selected) then
            self.cancelSelectedButton:SetText("Cancel Selected")
            self.cancelSelectedButton:Enable()
            cancelButtonEnabled = true
        else
            self.cancelSelectedButton:SetText("Cancel Selected")
            self.cancelSelectedButton:Disable()
        end
    end
    if self.lastRowsChangedReason == "cancel-requested" then
        SessionLog("CancelAuctionsUI: cancel refresh state rows=%d undercut=%d selectedIndex=%s selectedRowID=%s selectedStatus=%s cancelButtonEnabled=%s",
            #(self.rows or {}), CountStatus(self.rows, "Undercut"),
            tostring(self.selectedIndex), tostring(self.selectedRowID),
            tostring(selected and selected.status), tostring(cancelButtonEnabled))
        self.lastRowsChangedReason = nil
    end
end

function CancelAuctionsUI:OnRowsChanged(rows, reason)
    self.rows = rows or {}
    self.lastRowsChangedReason = reason
    if reason == "cancel-processing-started" then
        self.cancelInProgress = true
    elseif reason == "cancel-requested" or reason == "cancel-failed" or reason == "complete" or reason == "refreshing" then
        self.cancelInProgress = false
    end
    SessionLog("CancelAuctionsUI: rows changed reason=%s rows=%d undercut=%d previousSelectedIndex=%s previousSelectedRowID=%s",
        tostring(reason), #(self.rows or {}), CountStatus(self.rows, "Undercut"),
        tostring(self.selectedIndex), tostring(self.selectedRowID))
    if self.loadingLabel then
        self.loadingLabel:Hide()
    end
    if #self.rows > 0 then
        if self.emptyLabel then
            self.emptyLabel:Hide()
        end
    else
        if not self.emptyLabel and self.listContainer then
            self.emptyLabel = CreateListMessage(self.listContainer, "No active owned auctions for this character.", "GameFontDisableSmall")
        elseif self.emptyLabel then
            self.emptyLabel:Show()
        end
    end
    if reason == "complete" or reason == "cancel-requested" then
        self:SelectInitialRow()
    else
        self:RefreshRows()
    end
end

function CancelAuctionsUI:HandleCancelSelected()
    local controller = self:GetController()
    local row = self.selectedIndex and self.rows and self.rows[self.selectedIndex] or nil
    if self.cancelInProgress == true
    or (controller and controller.IsCancelInProgress and controller:IsCancelInProgress() == true) then
        SessionLog("CancelAuctionsUI: cancel selected ignored reason=cancel-in-progress rowID=%s", tostring(RowID(row)))
        return
    end
    if not controller or not controller.CancelSelectedRow or not RowCanCancel(row) then
        return
    end
    self.cancelInProgress = true
    self:RefreshRows()
    local ok, err = controller:CancelSelectedRow(row)
    if not ok then
        self.cancelInProgress = false
        self:RefreshRows()
        SessionLog("CancelAuctionsUI: cancel selected failed rowID=%s err=%s", tostring(RowID(row)), tostring(err))
    end
end

function CancelAuctionsUI:RefreshQueue(reason)
    local controller = self:GetController()
    self.cancelInProgress = false
    self.selectedIndex = nil
    self.selectedRowID = nil
    self.autoSelected = false
    self.rows = {}
    self:RefreshRows()
    if self.loadingLabel then
        self.loadingText:SetText("Refreshing owned auctions...")
        self.loadingLabel:Show()
    end
    if self.emptyLabel then
        self.emptyLabel:Hide()
    end
    if controller and controller.OpenCancelAuctions then
        C_Timer.After(0, function()
            controller:OpenCancelAuctions(reason or "cancel-auctions-refresh")
        end)
    else
        SessionLog("CancelAuctionsUI: refresh skipped reason=controller-unavailable")
    end
end

function CancelAuctionsUI:Render(parent)
    self.parent = parent
    self.cancelInProgress = false
    self.selectedIndex = nil
    self.selectedRowID = nil
    self.autoSelected = false
    self.emptyLabel = nil

    self.cancelSelectedButton = AddChild(parent, CreateButton(parent, "Cancel Selected", 10, -8, 120, function()
        self:HandleCancelSelected()
    end))
    self.cancelSelectedButton:Disable()

    self.refreshButton = AddChild(parent, CreateButton(parent, "Refresh", 138, -8, 90, function()
        self:RefreshQueue("cancel-auctions-refresh")
    end))

    local listBox = AddChild(parent, CreateFrame("Frame", nil, parent, "BackdropTemplate"))
    listBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -36)
    listBox:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -16, 16)
    listBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listBox:SetBackdropColor(0.025, 0.025, 0.025, 0.9)
    listBox:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.85)

    AddChild(parent, CreateLabel(listBox, "Auction", 8, -6, 170, "GameFontDisableSmall", "LEFT"))
    AddChild(parent, CreateLabel(listBox, "Quantity", 194, -6, 58, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Price", 260, -6, 92, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Duration", 360, -6, 72, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Status", 440, -6, 80, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Notes", 528, -6, 150, "GameFontDisableSmall", "LEFT"))

    local buttons = {}
    for index = 1, VISIBLE_ROWS do
        local button = AddChild(parent, self:CreateQueueRow(listBox, 4, -24 - ((index - 1) * ROW_HEIGHT), 706, ROW_HEIGHT - 2))
        button:SetScript("OnClick", function(clicked)
            self:SelectRow(clicked.queueIndex, false)
        end)
        button:SetScript("OnEnter", ShowRowTooltip)
        button:SetScript("OnLeave", function()
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
        buttons[index] = button
    end

    local scrollFrame = AddChild(parent, CreateFrame("ScrollFrame", nil, listBox, "FauxScrollFrameTemplate"))
    scrollFrame:SetPoint("TOPLEFT", listBox, "TOPLEFT", 0, -24)
    scrollFrame:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -26, 4)
    scrollFrame:SetScript("OnVerticalScroll", function(frame, offset)
        if FauxScrollFrame_OnVerticalScroll then
            FauxScrollFrame_OnVerticalScroll(frame, offset, ROW_HEIGHT, function()
                self:RefreshRows()
            end)
        end
    end)

    self.list = {
        buttons = buttons,
        scrollFrame = scrollFrame,
        listBox = listBox,
    }
    self.listContainer = listBox

    local controller = self:GetController()
    local hasController = controller and controller.SetRowsChangedCallback
    if hasController then
        controller:SetRowsChangedCallback(function(rows, reason)
            self:OnRowsChanged(rows, reason)
        end)
        self.rows = controller:GetRows() or {}
    else
        self.rows = {}
    end

    local loadingFrame = CreateListMessage(listBox, hasController and "Preparing owned auctions..." or "Cancel controller unavailable.", "GameFontNormalSmall")
    self.loadingLabel = loadingFrame
    self.loadingText = loadingFrame.Text

    self:RefreshRows()
    if controller and controller.OpenCancelAuctions then
        C_Timer.After(0, function()
            controller:OpenCancelAuctions("pocketcfo-tab-open")
        end)
    end
end
