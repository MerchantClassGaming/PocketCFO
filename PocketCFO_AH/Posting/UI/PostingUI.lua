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

-- Smart view: two-line column headers ("Usually / Post"), so rows start lower.
local LIST_TOP = 24
local SMART_LIST_TOP = 30

local function GetVisibleListRows(listBox, listTop)
    local height = listBox and listBox.GetHeight and listBox:GetHeight() or 0
    if height <= 0 then
        return VISIBLE_ROWS
    end

    local available = height - (listTop or LIST_TOP) - 4
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

-- Post Now: what's left to post on this row (gear posts one per click).
local function RowRemaining(row)
    return math.max(0, RowToPost(row) - RowPostedCount(row))
end

-- Usually Post: saved number, or the default (one stack, 1 if it doesn't
-- stack). Second return: true when the player saved it.
local function UsuallyPostFor(row)
    local bounds = row and row.resolvedRule and row.resolvedRule.bounds or {}
    local saved = tonumber(bounds.usuallyPost)
    if saved and saved > 0 then
        return saved, true
    end
    local stackSize = tonumber(bounds.stackSize) or 0
    return stackSize > 0 and math.floor(stackSize) or 1, false
end

-- Smart view groups (Brian, 2026-11-04; Check the price added 2026-11-06).
local GROUP_TITLES = { "Ready to post", "Check the price", "Your call", "Probably not" }

-- Ready, but we picked the price ourselves (no one at that price). A typed
-- price makes it the player's: back to Ready to post.
local function RowIsCheck(row)
    return RowStatus(row) == "Ready"
        and row.evaluation and row.evaluation.check == true
        and not (row.overrides and row.overrides.price)
end

local function RowGroup(row)
    local status = RowStatus(row)
    if status == "Ready" then
        return RowIsCheck(row) and 2 or 1
    elseif status == "Listed" or status == "Skipped" or status == "Posted" then
        return 4
    end
    return 3
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

-- ---------------------------------------------------------------------------
-- Price lines under the item tooltip (smart view): why this price, from the
-- bounds worked out when the list was built (SmartPricing:GetBounds), so a
-- hover only reads stored values (Brian, 2026-11-04; trimmed 2026-11-07).
-- ---------------------------------------------------------------------------

local function GoldText(copper)
    copper = tonumber(copper)
    if not copper then
        return "-"
    end
    -- Two biggest coins (core PocketCFO:FormatMoney, 2026-11-05).
    return PocketCFO:FormatMoney(copper)
end

-- "Capped by <item> Q2   999g" (Brian, 2026-11-07): the one better version
-- that set the most we'd post, in place of listing every better version.
-- Shown only when that cap is what set "Highest we'd post". Price = that
-- item's own price; "Highest we'd post" above shows what it works out to.
local function CappedByText(from)
    local itemID = type(from) == "table" and tonumber(from.itemID) or nil
    if not itemID then
        return nil
    end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local ok, name = pcall(getInfo, itemID)
    local text = "Capped by " .. ((ok and name) or "a better version")
    if tonumber(from.quality) then
        text = text .. " Q" .. tostring(from.quality)
    end
    return text
end

local function AddCompareLines(tooltip, row)
    tooltip:AddLine(" ")

    -- Why this price: the range we'd post in and what set each end.
    local bounds = row.resolvedRule and row.resolvedRule.bounds or {}
    local function Times(multiplier)
        multiplier = tonumber(multiplier)
        if not multiplier then
            return ""
        end
        local text = string.format("%.1f", multiplier):gsub("%.0$", "")
        return text .. "x "
    end
    local FLOOR_SOURCES = { cost = "cost to make", disenchant = "disenchant value", vendor = "vendor price" }
    if tonumber(bounds.floor) then
        tooltip:AddDoubleLine("Lowest we'd post",
            GoldText(bounds.floor) .. "  |cff999999" .. (FLOOR_SOURCES[bounds.floorSource] or "?") .. " +10%|r",
            1, 0.82, 0, 1, 1, 1)
    elseif bounds.needsRecipe then
        local why = bounds.needsRecipe == "ours" and "Open the recipe, then Refresh" or "Materials not priced yet"
        if bounds.pricesLoading then
            why = "Loading prices..."
        end
        tooltip:AddDoubleLine("Lowest we'd post", "|cff999999" .. why .. "|r", 1, 0.82, 0, 1, 1, 1)
    end
    if tonumber(bounds.ceiling) then
        local why
        if bounds.ceilingBase == "sale" then
            why = Times(bounds.multiplier) .. "your last sale"
        elseif bounds.ceilingBase == "cost" then
            why = Times(bounds.multiplier) .. "cost to make"
        elseif bounds.ceilingBase == "value" then
            why = "market value"
        elseif bounds.ceilingBase == "market" then
            why = "market value, few listings"
        elseif bounds.ceilingBase == "pastmarket" then
            why = "market value (older expansion)"
        elseif bounds.ceilingBase == "lowvalue" then
            why = "market value (lower than usual)"
        elseif bounds.ceilingBase == "rule" then
            why = "below the better version"
        else
            why = "?"
        end
        -- Raised to the floor (SmartPricing bounds.ceilingAtFloor, 2026-11-07).
        if bounds.ceilingAtFloor then
            why = "lowest match"
        end
        tooltip:AddDoubleLine("Highest we'd post", GoldText(bounds.ceiling) .. "  |cff999999" .. why .. "|r",
            1, 0.82, 0, 1, 1, 1)
        if bounds.ceilingBase == "rule" then
            local cappedBy = CappedByText(bounds.ruleCapFrom)
            if cappedBy then
                tooltip:AddDoubleLine(cappedBy, GoldText(bounds.ruleCapFrom.price), 1, 0.82, 0, 1, 1, 1)
            end
        end
    end
    -- No "Market value" line (2026-11-07): it's the PCFO Value already shown
    -- in the item tooltip above, few-listings note included.
    local cheapest = row.evaluation and tonumber(row.evaluation.lowestMatchingPrice)
    if cheapest then
        tooltip:AddDoubleLine("Cheapest listing", GoldText(cheapest), 1, 0.82, 0, 1, 1, 1)
    end
    -- No cost yet but one of our characters knows the recipe: say how to get
    -- it (Brian, 2026-11-04). Costs are read when the list is built, and so
    -- is "ours" (bounds.needsRecipe, SmartPricing:GetBounds).
    local costText = bounds.costToMake and GoldText(bounds.costToMake) or "-"
    -- From the recipe at today's prices, not recipe analysis (no
    -- Resourcefulness / multicraft, so a little high). Brian, 2026-11-06.
    if bounds.costToMake and bounds.costSource == "estimate" then
        costText = costText .. "  |cff999999estimate|r"
    end
    if not bounds.costToMake and bounds.needsRecipe == "ours" then
        costText = "|cff999999Open the recipe, then Refresh|r"
    end
    tooltip:AddDoubleLine("Cost to make", costText, 1, 0.82, 0, 1, 1, 1)
    tooltip:AddDoubleLine("Your last sale", bounds.lastSale and GoldText(bounds.lastSale) or "-", 1, 0.82, 0, 1, 1, 1)
end

local function ShowRowTooltip(button)
    local row = button and button.queueRow
    if not row or not GameTooltip then
        return
    end

    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    -- The game's own item tooltip (with PocketCFO's value lines), as
    -- anywhere else in the game (Brian, 2026-11-04).
    local itemLink = row.itemLink or (row.candidate and row.candidate.itemLink)
    if type(itemLink) == "string" and itemLink:find("|H") then
        local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, itemLink)
        if ok then
            local status = RowStatus(row)
            -- Every smart row (Brian, 2026-11-04): check a price without
            -- leaving the window.
            if row.resolvedRule and row.resolvedRule.smart then
                pcall(AddCompareLines, GameTooltip, row)
            end
            GameTooltip:Show()
            return
        end
    end
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

-- ---------------------------------------------------------------------------
-- Smart AH view: Qty / Price / Duration are edited in place (this post only).
-- Design: claude/AH_Smart_Posting_Design.md.
-- ---------------------------------------------------------------------------

local OVERRIDE_R, OVERRIDE_G, OVERRIDE_B = 1, 0.82, 0
local DURATION_CYCLE = { [12] = 24, [24] = 48, [48] = 12 }

local function IsSmartView()
    local smart = PocketCFO_AH:GetModule("SmartPricing", true)
    return smart ~= nil and smart:IsSmartView() == true
end

-- "125" = 125 gold; also accepts "12g 50s 3c" and "12.5".
local function ParsePrice(text)
    text = tostring(text or ""):lower():gsub(",", "")
    if text:match("^%s*$") then
        return nil
    end
    if text:find("[gsc]") then
        local gold = tonumber(text:match("([%d%.]+)%s*g")) or 0
        local silver = tonumber(text:match("([%d%.]+)%s*s")) or 0
        local copper = tonumber(text:match("([%d%.]+)%s*c")) or 0
        local total = math.floor(gold * 10000 + silver * 100 + copper + 0.5)
        return total > 0 and total or nil
    end
    local gold = tonumber(text)
    if not gold or gold <= 0 then
        return nil
    end
    return math.floor(gold * 10000 + 0.5)
end

local function PriceForEdit(copper)
    copper = tonumber(copper)
    if not copper or copper <= 0 then
        return ""
    end
    local gold = copper / 10000
    if gold == math.floor(gold) then
        return tostring(math.floor(gold))
    end
    return string.format("%.2f", gold)
end

local function RowEditable(controller, rows, row)
    if not row or not row.evaluation then
        return false
    end
    if IsEvaluationInProgress(controller, rows) or IsPostingInProgress(controller, rows) then
        return false
    end
    if row.posting and row.posting.pending == true then
        return false
    end
    return RowStatus(row) ~= "Posted"
end

function PostingUI:EnsureEditBox(parent)
    if self.editBox and self.editBox:GetParent() == parent then
        return self.editBox
    end
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetFrameStrata("DIALOG")
    box:Hide()
    box:SetScript("OnEnterPressed", function(edit)
        self:FinishEdit(true)
        edit:ClearFocus()
    end)
    box:SetScript("OnEscapePressed", function(edit)
        self:FinishEdit(false)
        edit:ClearFocus()
    end)
    box:SetScript("OnEditFocusLost", function()
        self:FinishEdit(true)
    end)
    self.editBox = box
    return box
end

function PostingUI:StartEdit(button, field)
    local row = button and button.queueRow
    local controller = self:GetController()
    if not row then
        return
    end
    -- Usually Post can be set on any row, Posted included.
    if not RowEditable(controller, self.rows, row)
        and not (field == "usually" and row.evaluation and not (row.posting and row.posting.pending == true)
            and not IsEvaluationInProgress(controller, self.rows) and not IsPostingInProgress(controller, self.rows)) then
        return
    end
    self:SelectRow(button.queueIndex, false)
    if field == "duration" then
        local current = tonumber(row.duration) or 12
        controller:ApplyOverride(row, "duration", DURATION_CYCLE[current] or 12)
        return
    end
    local cell = (field == "price" and button.PriceText) or (field == "usually" and button.InBagsText) or button.ToPostText
    local box = self:EnsureEditBox(self.list and self.list.listBox or button)
    box:ClearAllPoints()
    box:SetPoint("LEFT", cell, "LEFT", 4, 0)
    box:SetSize(field == "price" and 80 or 44, 18)
    local value
    if field == "price" then
        value = PriceForEdit(RowPrice(row) or (row.evaluation and row.evaluation.suggestedPrice))
    elseif field == "usually" then
        value = tostring(UsuallyPostFor(row))
    elseif RowRemaining(row) > 0 then
        value = tostring(RowRemaining(row))
    else
        value = tostring(RowToPost(row) > 0 and RowToPost(row)
            or (row.evaluation and row.evaluation.suggestedQuantity) or (row.inBags or ""))
    end
    self.editing = { row = row, field = field, done = false }
    box:SetText(value)
    box:Show()
    box:SetFocus()
    box:HighlightText()
end

-- commit = true: apply what was typed (empty = smart value back);
-- false (Esc): put the smart value back.
function PostingUI:FinishEdit(commit)
    local editing = self.editing
    if not editing or editing.done then
        return
    end
    editing.done = true
    self.editing = nil
    local box = self.editBox
    local text = box and box:GetText() or ""
    if box then
        box:Hide()
    end
    local controller = self:GetController()
    if not controller or not controller.ApplyOverride then
        return
    end
    if editing.field == "usually" then
        if commit and controller.SetUsuallyPost then
            -- Blank = back to the default.
            controller:SetUsuallyPost(editing.row, tonumber(text))
        end
        return
    end
    local value = nil
    if commit then
        if editing.field == "price" then
            value = ParsePrice(text)
        else
            value = tonumber(text)
        end
    end
    -- Stay in place while working down a group (Brian, 2026-11-06): if the
    -- edit moves the row to another group, select the row that came after it.
    local row = editing.row
    local groupBefore = RowGroup(row)
    local nextRowID = nil
    for index, other in ipairs(self.rows or {}) do
        if other == row then
            local nextRow = self.rows[index + 1]
            nextRowID = nextRow and RowID(nextRow) or nil
            break
        end
    end
    controller:ApplyOverride(row, editing.field, value)
    if nextRowID and RowGroup(row) ~= groupBefore then
        self.selectedRowID = nextRowID
        self.autoSelected = false
        self:RefreshRows()
    end
end

function PostingUI:HandleSkipSelected()
    local row = self.selectedIndex and self.rows and self.rows[self.selectedIndex] or nil
    local controller = self:GetController()
    if not row or not controller or not controller.SkipRow then
        return
    end
    if IsEvaluationInProgress(controller, self.rows) or IsPostingInProgress(controller, self.rows) then
        return
    end
    self.selectedIndex = nil
    self.selectedRowID = nil
    controller:SkipRow(row)
end

function PostingUI:HandleKeepSelected()
    local row = self.selectedIndex and self.rows and self.rows[self.selectedIndex] or nil
    local controller = self:GetController()
    if not row or not controller or not controller.KeepRow then
        return
    end
    if IsEvaluationInProgress(controller, self.rows) or IsPostingInProgress(controller, self.rows) then
        return
    end
    self.selectedIndex = nil
    self.selectedRowID = nil
    controller:KeepRow(row)
end

local function CreateCellButton(row, anchor, width, onClick)
    local cell = CreateFrame("Button", nil, row)
    cell:SetPoint("LEFT", anchor, "LEFT", 0, 0)
    cell:SetSize(width, row:GetHeight())
    cell:SetScript("OnClick", onClick)
    cell:SetScript("OnEnter", function()
        ShowRowTooltip(row)
    end)
    cell:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    cell:Hide()
    return cell
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
    -- Never spill into the next row: 2 lines max, the rest cut off.
    if row.NoteText.SetMaxLines then
        row.NoteText:SetMaxLines(2)
    end

    -- Smart view: click a cell to edit it (shown only in the smart view).
    -- The In Bags spot holds Usually Post there.
    row.UsuallyCell = CreateCellButton(row, row.InBagsText, 48, function()
        self:StartEdit(row, "usually")
    end)
    row.QtyCell = CreateCellButton(row, row.ToPostText, 48, function()
        self:StartEdit(row, "quantity")
    end)
    row.PriceCell = CreateCellButton(row, row.PriceText, 86, function()
        self:StartEdit(row, "price")
    end)
    row.DurationCell = CreateCellButton(row, row.DurationText, 62, function()
        self:StartEdit(row, "duration")
    end)

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

    -- Smart view: a header over each group once evaluation is done (Brian,
    -- 2026-11-04). display = { {header = title} | {rowIndex = n} }.
    local display = {}
    local controller = self:GetController()
    local showGroups = self.smart and not IsEvaluationInProgress(controller, self.rows)
    local lastGroup = nil
    for rowIndex, row in ipairs(self.rows) do
        if showGroups then
            local group = RowGroup(row)
            if group ~= lastGroup then
                display[#display + 1] = { header = GROUP_TITLES[group] }
                lastGroup = group
            end
        end
        display[#display + 1] = { rowIndex = rowIndex }
    end

    local offset = FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(list.scrollFrame) or 0
    local visibleRows = GetVisibleListRows(list.listBox, self.listTop)
    if FauxScrollFrame_Update then
        FauxScrollFrame_Update(list.scrollFrame, #display, visibleRows, ROW_HEIGHT)
    end

    for index, button in ipairs(list.buttons or {}) do
        if index > visibleRows then
            button:Hide()
        else
            local entry = display[offset + index]
            local rowIndex = entry and entry.rowIndex
            local row = rowIndex and self.rows[rowIndex] or nil
            if row then
                local status = RowStatus(row)
                local price = RowPrice(row)
                local isInactiveRow =
                    status == "Skipped"
                    or status == "Posted"
                    or (self.smart and status == "Listed")

                button.queueIndex = rowIndex
                button.queueRow = row
                button.ItemText:SetText(tostring(row.item or row.itemName or ""))
                local usuallyPost, usuallySaved = UsuallyPostFor(row)
                button.InBagsText:SetText(self.smart and tostring(usuallyPost) or tostring(row.inBags or 0))
                local shownQuantity = self.smart and RowRemaining(row) or RowToPost(row)
                if self.smart and shownQuantity <= 0 and (status == "Skipped" or status == "Needs Price"
                    or status == "Too Cheap") then
                    -- Starting Post Now for rows that won't post as they are.
                    shownQuantity = tonumber(row.evaluation and row.evaluation.suggestedQuantity) or 0
                end
                button.ToPostText:SetText(tostring(shownQuantity))
                local shownPrice = price
                if self.smart and not shownPrice and (status == "Skipped" or status == "Listed"
                    or status == "Too Cheap") then
                    -- Starting value for rows that won't post as they are.
                    shownPrice = row.evaluation and row.evaluation.suggestedPrice
                end
                button.PriceText:SetText(shownPrice and FormatCopperString(shownPrice) or "")
                button.DurationText:SetText(row.duration and (tostring(row.duration) .. "h") or "")
                button.StatusText:SetText((self.smart and RowIsCheck(row)) and "Check" or status)
                button.NoteText:SetText(RowNote(row))
                button:Enable()
                button:Show()
                button.InBagsText:SetShown(true)
                button.UsuallyCell:SetShown(self.smart)
                button.QtyCell:SetShown(self.smart)
                button.PriceCell:SetShown(self.smart)
                button.DurationCell:SetShown(self.smart)

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
                if self.smart and usuallySaved then
                    button.InBagsText:SetTextColor(OVERRIDE_R, OVERRIDE_G, OVERRIDE_B)
                end
                local overrides = self.smart and row.overrides or nil
                if overrides then
                    if overrides.quantity then button.ToPostText:SetTextColor(OVERRIDE_R, OVERRIDE_G, OVERRIDE_B) end
                    if overrides.price then button.PriceText:SetTextColor(OVERRIDE_R, OVERRIDE_G, OVERRIDE_B) end
                    if overrides.duration then button.DurationText:SetTextColor(OVERRIDE_R, OVERRIDE_G, OVERRIDE_B) end
                end
            else
                button.queueIndex = nil
                button.queueRow = nil
                button.ItemText:SetText(entry and entry.header or "")
                button.InBagsText:SetText("")
                button.ToPostText:SetText("")
                button.PriceText:SetText("")
                button.DurationText:SetText("")
                button.StatusText:SetText("")
                button.NoteText:SetText("")
                button.UsuallyCell:Hide()
                button.QtyCell:Hide()
                button.PriceCell:Hide()
                button.DurationCell:Hide()
                button:Disable()
                if entry and entry.header then
                    -- Group header: gold text, no backdrop.
                    button.ItemText:SetTextColor(1, 0.82, 0)
                    button:SetBackdropColor(0, 0, 0, 0)
                else
                    button:SetBackdropColor(0.04, 0.04, 0.04, 0.45)
                end
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

        if self.keepButton then
            if selected and not evaluating and not posting then
                self.keepButton:Enable()
            else
                self.keepButton:Disable()
            end
        end
        if self.skipButton then
            if selected and not evaluating and not posting and not selected.userSkipped
                and RowStatus(selected) ~= "Posted" then
                self.skipButton:Enable()
            else
                self.skipButton:Disable()
            end
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
    if reason == "complete" then
        self.evaluatedAt = GetTime and GetTime() or nil
    end
    if self.loadingLabel then
        self.loadingLabel:Hide()
    end
    if #self.rows > 0 then
        if self.emptyLabel then
            self.emptyLabel:Hide()
        end
    else
        if not self.emptyLabel and self.listContainer then
            self.emptyLabel = CreateListMessage(self.listContainer, self.smart
                and "Nothing to post. Everything in your bags is on your Keep List or can't be sold."
                or "No configured bag candidates with posting rules.", "GameFontDisableSmall")
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

-- Smart view: coming back to Post Auctions within this long shows the list
-- that was already evaluated instead of evaluating everything again
-- (Brian, 2026-11-04). Refresh always re-evaluates.
local SAVED_LIST_SECONDS = 5 * 60

function PostingUI:CanReuseList()
    local controller = self:GetController()
    if not self.smart or not self.evaluatedAt or not GetTime or not controller then
        return false
    end
    if GetTime() - self.evaluatedAt > SAVED_LIST_SECONDS then
        return false
    end
    local rows = controller:GetRows() or {}
    -- A post that was in flight (e.g. when the AH closed) may or may not
    -- have gone through: evaluate fresh rather than guess.
    for _, row in ipairs(rows) do
        if row.posting and row.posting.pending == true then
            return false
        end
    end
    return #rows > 0 and not IsEvaluationInProgress(controller, rows) and not IsPostingInProgress(controller, rows)
end

function PostingUI:ShowSavedList()
    local controller = self:GetController()
    self.rows = controller and controller:GetRows() or {}
    if self.loadingLabel then
        self.loadingLabel:Hide()
    end
    self:SelectInitialRow()
    self:RefreshRows()
end

function PostingUI:RefreshQueue(reason)
    self.evaluatedAt = nil
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

-- Smart view: reopening the AH within this long of it closing (an
-- accidental dismount) restores the list instead of evaluating again
-- (Brian, 2026-11-04). The saved-list window (SAVED_LIST_SECONDS) applies too.
local REOPEN_RESTORE_SECONDS = 3 * 60

function PostingUI:OnAuctionHouseClosed()
    self.closedAt = GetTime and GetTime() or nil
end

function PostingUI:RefreshFromAuctionHouseOpen()
    local closedAt = self.closedAt
    self.closedAt = nil
    if closedAt and GetTime and GetTime() - closedAt <= REOPEN_RESTORE_SECONDS and self:CanReuseList() then
        self:ShowSavedList()
        return
    end
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

    self.smart = IsSmartView()
    self.editing = nil
    self.keepButton = nil
    self.skipButton = nil
    if self.smart then
        self.keepButton = AddChild(parent, CreateButton(parent, "Keep", 352, -8, 80, function()
            self:HandleKeepSelected()
        end))
        self.keepButton:Disable()
        self.keepButton:SetScript("OnEnter", function(button)
            if GameTooltip then
                GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
                GameTooltip:SetText("Keep", 1, 1, 1)
                GameTooltip:AddLine("Don't sell this item on this character. Change how many to keep on the Keep List tab.", 0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end
        end)
        self.keepButton:SetScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)

        self.skipButton = AddChild(parent, CreateButton(parent, "Skip", 440, -8, 80, function()
            self:HandleSkipSelected()
        end))
        self.skipButton:Disable()
        self.skipButton:SetScript("OnEnter", function(button)
            if GameTooltip then
                GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
                GameTooltip:SetText("Skip", 1, 1, 1)
                GameTooltip:AddLine("Don't post this now. It comes back next time.", 0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end
        end)
        self.skipButton:SetScript("OnLeave", function()
            if GameTooltip then GameTooltip:Hide() end
        end)

        -- Smart view order (Brian, 2026-11-04): the two most-used buttons
        -- side by side, then Keep, then the rarely used Refresh and Unstick.
        local x = 10
        for _, button in ipairs({ self.postSelectedButton, self.skipButton, self.keepButton,
            self.refreshButton, self.unstickButton }) do
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -8)
            x = x + button:GetWidth() + 7
        end
    end

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

    local listTop = self.smart and SMART_LIST_TOP or LIST_TOP
    self.listTop = listTop
    -- Single-line headers sit on the bottom line of the two-line ones.
    local headerY = self.smart and -16 or -6
    AddChild(parent, CreateLabel(listBox, "Item", 8, headerY, 150, "GameFontDisableSmall", "LEFT"))
    if self.smart then
        AddChild(parent, CreateLabel(listBox, "Usually\nPost", 170, -5, 48, "GameFontDisableSmall", "CENTER"))
        AddChild(parent, CreateLabel(listBox, "Post\nNow", 226, -5, 48, "GameFontDisableSmall", "CENTER"))
    else
        AddChild(parent, CreateLabel(listBox, "In Bags", 170, -6, 48, "GameFontDisableSmall", "CENTER"))
        AddChild(parent, CreateLabel(listBox, "To Post", 226, -6, 48, "GameFontDisableSmall", "CENTER"))
    end
    AddChild(parent, CreateLabel(listBox, "Price", 286, headerY, 86, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Duration", 384, headerY, 62, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Status", 456, headerY, 70, "GameFontDisableSmall", "CENTER"))
    AddChild(parent, CreateLabel(listBox, "Note", 532, headerY, 150, "GameFontDisableSmall", "LEFT"))

    local buttons = {}
    for index = 1, VISIBLE_ROWS do
        local button = AddChild(parent, self:CreateQueueRow(listBox, 4, -listTop - ((index - 1) * ROW_HEIGHT), 706, ROW_HEIGHT - 2))
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
    scrollFrame:SetPoint("TOPLEFT", listBox, "TOPLEFT", 0, -listTop)
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
