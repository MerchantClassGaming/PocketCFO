-- PocketCFO_AH/Posting/UI/PostingUI.lua
-- Posting queue display and selection wiring. No auction posting is performed.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingUI = PocketCFO_AH:NewModule("PostingUI")

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

local function RowStatus(row)
    return tostring(row and (row.status or row.evaluation and row.evaluation.status) or "")
end

local function IsEvaluationStatus(status)
    return status == "Evaluating"
        or status == "Pending evaluation"
        or status == "Refreshing owned auctions..."
end

local function IsEvaluationInProgress(controller, rows)
    if controller and controller.IsEvaluationInProgress and controller:IsEvaluationInProgress() then
        return true
    end
    for _, row in ipairs(rows or {}) do
        if IsEvaluationStatus(RowStatus(row)) then
            return true
        end
    end
    return false
end

local function IsPostingInProgress(controller, rows)
    if controller and controller.IsPostingInProgress and controller:IsPostingInProgress() then
        return true
    end
    for _, row in ipairs(rows or {}) do
        if row and row.posting and row.posting.pending == true then
            return true
        end
    end
    return false
end

local function RowNote(row)
    return tostring(row and (row.note or row.notes or row.evaluation and row.evaluation.note) or "")
end

local function RowPrice(row)
    if RowStatus(row) ~= "Ready" then
        return nil
    end
    return tonumber(row and (row.price or row.postingPrice or row.evaluation and row.evaluation.price))
end

local function RowToPost(row)
    return tonumber(row and (row.toPost or row.evaluation and row.evaluation.toPost)) or 0
end

local function RowPostedCount(row)
    return tonumber(row and row.posting and row.posting.postedCount) or 0
end

local function RowCanPost(row)
    return RowStatus(row) == "Ready"
        and row and row.evaluation and row.evaluation.shouldPost == true
        and RowToPost(row) > RowPostedCount(row)
        and not (row.posting and row.posting.pending == true)
end

local function RowID(row)
    return row and (row.rowID or row.itemKey or row.itemName)
end

local function IsButtonEnabled(button)
    return button ~= nil and button:IsEnabled() and true or false
end

-- Best-effort, diagnostic-only explanation of why the selected row can't currently be
-- posted. Purely descriptive text - never used to make posting decisions.
local function DescribeRowPostBlocker(controller, rows, row)
    if IsEvaluationInProgress(controller, rows) then
        return "evaluation in progress"
    end
    if IsPostingInProgress(controller, rows) then
        return "posting in progress"
    end
    if not row then
        return "no row selected"
    end
    if RowStatus(row) ~= "Ready" then
        return "status is not Ready (" .. RowStatus(row) .. ")"
    end
    if not (row.evaluation and row.evaluation.shouldPost == true) then
        return "evaluation.shouldPost is not true"
    end
    if not (RowToPost(row) > RowPostedCount(row)) then
        return "no remaining quantity to post"
    end
    if row.posting and row.posting.pending == true then
        return "row is pending"
    end
    return nil
end

local function FirstPostableIndex(rows)
    for index, row in ipairs(rows or {}) do
        if RowCanPost(row) then
            return index
        end
    end
    return nil
end

local function RowItemID(row)
    return tonumber(row and row.candidate and row.candidate.itemID)
        or tonumber(row and row.itemID)
        or tonumber(row and row.target and (row.target.debugItemID or row.target.targetItemID))
end

local function ShowRowTooltip(button)
    local row = button and button.queueRow
    if not row or not GameTooltip then
        return
    end

    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(tostring(row.item or row.itemName or "Item"), 1, 1, 1)
    local itemID = RowItemID(row)
    if itemID then
        GameTooltip:AddLine("Item ID: " .. tostring(itemID), 0.7, 0.7, 0.7)
    end
    local note = RowNote(row)
    if note ~= "" then
        GameTooltip:AddLine(note, 0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
end

local function SetTextColor(button, r, g, b)
    if not button or not button.ItemText or not button.ItemText.SetTextColor then
        return
    end
    button.ItemText:SetTextColor(r, g, b)
    button.InBagsText:SetTextColor(r, g, b)
    button.ToPostText:SetTextColor(r, g, b)
    button.PriceText:SetTextColor(r, g, b)
    button.DurationText:SetTextColor(r, g, b)
    button.StatusText:SetTextColor(r, g, b)
    button.NoteText:SetTextColor(r, g, b)
end

function PostingUI:GetController()
    return PocketCFO_AH:GetModule("PostingController", true)
end

function PostingUI:CreateQueueRow(parent, x, y, width, height)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(width, height)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    row:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.ItemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ItemText:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.ItemText:SetWidth(160)
    row.ItemText:SetJustifyH("LEFT")

    row.InBagsText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.InBagsText:SetPoint("LEFT", row, "LEFT", 170, 0)
    row.InBagsText:SetWidth(48)
    row.InBagsText:SetJustifyH("CENTER")

    row.ToPostText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ToPostText:SetPoint("LEFT", row, "LEFT", 226, 0)
    row.ToPostText:SetWidth(48)
    row.ToPostText:SetJustifyH("CENTER")

    row.PriceText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.PriceText:SetPoint("LEFT", row, "LEFT", 286, 0)
    row.PriceText:SetWidth(86)
    row.PriceText:SetJustifyH("CENTER")

    row.DurationText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.DurationText:SetPoint("LEFT", row, "LEFT", 384, 0)
    row.DurationText:SetWidth(62)
    row.DurationText:SetJustifyH("CENTER")

    row.StatusText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.StatusText:SetPoint("LEFT", row, "LEFT", 456, 0)
    row.StatusText:SetWidth(70)
    row.StatusText:SetJustifyH("CENTER")

    row.NoteText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.NoteText:SetPoint("LEFT", row, "LEFT", 532, 0)
    row.NoteText:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.NoteText:SetJustifyH("LEFT")

    return row
end

function PostingUI:SelectRow(index, automatic)
    local row = self.rows and self.rows[index] or nil
    self.selectedIndex = row and index or nil
    self.selectedRowID = row and RowID(row) or nil
    self.autoSelected = automatic == true and row ~= nil or false
    self:RefreshRows()
end

function PostingUI:SelectInitialRow()
    if self.selectedRowID and not self.autoSelected then
        return
    end

    local firstRowIndex = nil
    for index, row in ipairs(self.rows or {}) do
        firstRowIndex = firstRowIndex or index
    end

    local firstPostableIndex = FirstPostableIndex(self.rows)
    local selectedIndex = firstPostableIndex or firstRowIndex
    if selectedIndex and RowID((self.rows or {})[selectedIndex]) ~= self.selectedRowID then
        self:SelectRow(selectedIndex, true)
    elseif not selectedIndex then
        self.selectedIndex = nil
        self.selectedRowID = nil
        self.autoSelected = false
    end
end

function PostingUI:RestoreSelection()
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

function PostingUI:AdjustSelectionAfterPostConfirmed()
    local controller = self:GetController()
    local confirmedRowID = controller and controller.lastConfirmedRowID

    -- Search by stable confirmed-row identity before falling back to the stored selection.
    -- This avoids bouncing when sort reorders rows after a partial post.
    if confirmedRowID then
        for index, row in ipairs(self.rows or {}) do
            if RowID(row) == confirmedRowID then
                if RowCanPost(row) then
                    self.selectedIndex = index
                    self.selectedRowID = confirmedRowID
                    self.autoSelected = false
                    return true
                end
                -- Row found but no longer postable (fully posted or error); advance below.
                break
            end
        end
    else
        self:RestoreSelection()
        local selected = self.selectedIndex and self.rows and self.rows[self.selectedIndex] or nil
        if RowCanPost(selected) then
            return true
        end
    end

    local firstPostableIndex = FirstPostableIndex(self.rows)
    if firstPostableIndex then
        self.selectedIndex = firstPostableIndex
        self.selectedRowID = RowID(self.rows[firstPostableIndex])
        self.autoSelected = true
        return true
    end
    return false
end

function PostingUI:RefreshRows()
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
                local status = RowStatus(row)
                local price = RowPrice(row)
                local isInactiveRow =
                    status == "Skipped"
                    or status == "Posted"

                button.queueIndex = rowIndex
                button.queueRow = row
                button.ItemText:SetText(tostring(row.item or row.itemName or ""))
                button.InBagsText:SetText(tostring(row.inBags or 0))
                button.ToPostText:SetText(tostring(RowToPost(row)))
                button.PriceText:SetText(price and FormatCopperString(price) or "")
                button.DurationText:SetText(row.duration and (tostring(row.duration) .. "h") or "")
                button.StatusText:SetText(status)
                button.NoteText:SetText(RowNote(row))
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
                button.InBagsText:SetText("")
                button.ToPostText:SetText("")
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

    if self.postSelectedButton then
        local selected = self.selectedIndex and self.rows[self.selectedIndex] or nil
        local controller = self:GetController()
        local evaluating = IsEvaluationInProgress(controller, self.rows)
        local posting = IsPostingInProgress(controller, self.rows)
        if evaluating then
            self.postSelectedButton:SetText("Evaluating...")
            self.postSelectedButton:Disable()
        elseif posting then
            self.postSelectedButton:SetText("Posting...")
            self.postSelectedButton:Disable()
        elseif RowCanPost(selected) then
            self.postSelectedButton:SetText("Post Selected")
            self.postSelectedButton:Enable()
        else
            self.postSelectedButton:SetText("Post Selected")
            self.postSelectedButton:Disable()
        end

        if self.unstickButton then
            if posting then
                self.unstickButton:Enable()
            else
                self.unstickButton:Disable()
            end
        end
    end
end

function PostingUI:OnQueueChanged(rows, reason)
    self.rows = rows or {}
    if self.loadingLabel then
        self.loadingLabel:Hide()
    end
    if #self.rows > 0 then
        if self.emptyLabel then
            self.emptyLabel:Hide()
        end
    else
        if not self.emptyLabel and self.listContainer then
            self.emptyLabel = CreateListMessage(self.listContainer, "No configured bag candidates with posting rules.", "GameFontDisableSmall")
        elseif self.emptyLabel then
            self.emptyLabel:Show()
        end
    end
    if reason == "post-confirmed" and self:AdjustSelectionAfterPostConfirmed() then
        -- Preserve the selected ready row, or move to the next ready row once posted.
    else
        self:SelectInitialRow()
    end
    self:RefreshRows()
end

function PostingUI:HandlePostSelected()
    local row = self.selectedIndex and self.rows and self.rows[self.selectedIndex] or nil
    local controller = self:GetController()
    if IsEvaluationInProgress(controller, self.rows) or IsPostingInProgress(controller, self.rows) or not RowCanPost(row) then
        return
    end

    if not controller or not controller.PostSelectedRow then
        SessionLog("PostingUI: Post Selected skipped reason=controller-unavailable rowID=%s", tostring(RowID(row)))
        return
    end

    local ok, err = controller:PostSelectedRow(row)
    if not ok then
        SessionLog("PostingUI: Post Selected request failed rowID=%s item=%s err=%s",
            tostring(RowID(row)), tostring(row.itemName), tostring(err))
    end
end

-- Best-effort forensic capture for MCG_Diagnostic, if installed. Read-only: gathers
-- evidence before Unstick Post changes any state. Never blocks or fails recovery -
-- any failure here (missing addon, missing method, thrown error) is swallowed.
function PostingUI:CaptureStuckPostDiagnostic(controller)
    local diagnostic = _G.MCG_Diagnostic
    if not diagnostic or type(diagnostic.RecordStuckPost) ~= "function" then
        return
    end

    local selected = self.selectedIndex and self.rows and self.rows[self.selectedIndex] or nil
    local payload = {
        trigger = "Unstick Post",
        capturedAt = GetServerTime and GetServerTime() or time(),
        ui = {
            selectedRowID = RowID(selected),
            selectedIndex = self.selectedIndex,
            postSelectedButtonEnabled = IsButtonEnabled(self.postSelectedButton),
            postSelectedButtonText = self.postSelectedButton and self.postSelectedButton:GetText() or nil,
            refreshButtonEnabled = IsButtonEnabled(self.refreshButton),
            unstickButtonEnabled = IsButtonEnabled(self.unstickButton),
            rowCanPost = RowCanPost(selected),
            controllerCanPostRow = controller and controller.CanPostRow and selected and controller:CanPostRow(selected) or false,
            notPostableReason = DescribeRowPostBlocker(controller, self.rows, selected),
        },
        controller = controller and controller.BuildDiagnosticSnapshot and controller:BuildDiagnosticSnapshot(self.selectedIndex) or nil,
    }

    local ok, err = pcall(diagnostic.RecordStuckPost, diagnostic, payload)
    if not ok then
        SessionLog("PostingUI: stuck post diagnostic capture failed err=%s", tostring(err))
    end
end

function PostingUI:HandleUnstickPost()
    local controller = self:GetController()
    if not IsPostingInProgress(controller, self.rows) then
        return
    end

    -- Capture forensic evidence before any recovery state changes.
    self:CaptureStuckPostDiagnostic(controller)

    if not controller or not controller.UnstickPendingPost then
        SessionLog("PostingUI: Unstick Post skipped reason=controller-unavailable")
        return
    end

    local ok, err = controller:UnstickPendingPost("manual-unstick")
    if not ok then
        SessionLog("PostingUI: Unstick Post request failed err=%s", tostring(err))
    end
end

function PostingUI:RefreshQueue(reason)
    local controller = self:GetController()
    self.selectedIndex = nil
    self.selectedRowID = nil
    self.autoSelected = false
    self.rows = {}
    self:RefreshRows()
    if self.loadingLabel then
        if self.loadingText then
            self.loadingText:SetText("Refreshing owned auctions...")
        end
        self.loadingLabel:Show()
    end
    if self.emptyLabel then
        self.emptyLabel:Hide()
    end
    if controller and controller.Refresh then
        C_Timer.After(0, function()
            controller:Refresh()
        end)
    else
        SessionLog("PostingUI: Refresh skipped reason=controller-unavailable")
    end
end

function PostingUI:HandleRefresh()
    self:RefreshQueue("post-auctions-refresh")
end

function PostingUI:RefreshFromAuctionHouseOpen()
    self:RefreshQueue("post-auctions-ah-open")
end

function PostingUI:Render(parent)
    self.parent = parent
    self.selectedIndex = nil
    self.selectedRowID = nil
    self.autoSelected = false
    self.emptyLabel = nil

    self.postSelectedButton = AddChild(parent, CreateButton(parent, "Post Selected", 10, -8, 115, function()
        self:HandlePostSelected()
    end))
    self.postSelectedButton:Disable()

    self.refreshButton = AddChild(parent, CreateButton(parent, "Refresh", 132, -8, 90, function()
        self:HandleRefresh()
    end))

    self.unstickButton = AddChild(parent, CreateButton(parent, "Unstick Post", 232, -8, 110, function()
        self:HandleUnstickPost()
    end))
    self.unstickButton:Disable()

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

    AddChild(parent, CreateLabel(listBox, "Item", 8, -6, 150, "GameFontDisableSmall", "LEFT"))
    AddChild(parent, CreateLabel(listBox, "In Bags", 170, -6, 48, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "To Post", 226, -6, 48, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Price", 286, -6, 86, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Duration", 384, -6, 62, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Status", 456, -6, 70, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Note", 532, -6, 150, "GameFontDisableSmall", "LEFT"))

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

    local controller = self:GetController()
    local hasController = controller and controller.SetQueueChangedCallback
    if hasController then
        controller:SetQueueChangedCallback(function(rows, reason)
            self:OnQueueChanged(rows, reason)
        end)
        self.rows = controller:GetRows() or {}
    else
        self.rows = {}
    end

    self.listContainer = listBox
    local loadingFrame = CreateListMessage(listBox, hasController and "Preparing possible auctions..." or "Posting controller unavailable.", "GameFontNormalSmall")
    self.loadingLabel = loadingFrame
    self.loadingText = loadingFrame.Text
    self.emptyLabel = nil

    self:SelectInitialRow()
    self:RefreshRows()

    if controller and controller.OpenPostAuctions then
        C_Timer.After(0, function()
            controller:OpenPostAuctions("pocketcfo-tab-open")
        end)
    end
end
