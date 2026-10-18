-- PocketCFO_Orders/UI/OrderAnalysisContent.lua
-- Renders the Order Analysis display model into a content frame supplied by
-- PocketCFO_Crafting's companion window shell (see OrdersCompanionController's
-- RegisterMode contract). Extremely simple by design - see PocketCFO_Orders
-- Never performs valuation/economics itself - only renders the display model
-- OrderDisplayModelBuilder already produced.

local ADDON_NAME, _ = ...
local PocketCFO_Orders = _G.PocketCFO_Orders

local OrderAnalysisContent = {}

local COLOR_POSITIVE = { 0.40, 0.90, 0.40 }
local COLOR_NEGATIVE = { 1.00, 0.45, 0.45 }
local COLOR_MUTED = { 0.70, 0.70, 0.70 }
local COLOR_TEXT = { 1.00, 1.00, 1.00 }
local COLOR_HEADER = { 1.00, 0.82, 0.00 }

local ROW_HEIGHT = 16
local SECTION_GAP = 8
local LEFT_MARGIN = 8
local RIGHT_MARGIN = 8
local VALUE_WIDTH = 96
local COLUMN_GAP = 8
local ELLIPSIS = "..."
local UNVALUED_TEXT = "Unvalued"
local TOTAL_ROW_Y = -10
local DIVIDER_Y = -34
local ROWS_START_Y = -46
local RESOURCEFULNESS_TOOLTIP =
    "Estimated from historical resourcefulness returns for comparable crafts. Quantities represent long-run averages and are not literal amounts expected from this individual craft."

-- Local money formatter. No shared "12,345g 67s" helper exists anywhere in
-- the codebase today (PostingUI.lua/CancelAuctionsUI.lua/PostingRuleEditor.lua/
-- PostingProfileEditorUI.lua each carry their own copy; InventoryManagerWindow.lua
-- has a separate whole-gold-only signed formatter). Adding one here only, not
-- retrofitting the others - out of scope for this build.
local function FormatSignedGoldSilver(copperValue)
    copperValue = tonumber(copperValue) or 0
    local negative = copperValue < 0
    local absValue = math.floor(math.abs(copperValue) + 0.5)
    local gold = math.floor(absValue / 10000)
    local silver = math.floor((absValue % 10000) / 100)

    local goldText = tostring(gold)
    local withCommas = goldText:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if withCommas:sub(1, 1) == "," then
        withCommas = withCommas:sub(2)
    end

    return string.format("%s%sg %02ds", negative and "-" or "+", withCommas, silver)
end

local function SetColor(fontString, color)
    fontString:SetTextColor(color[1], color[2], color[3], 1)
end

--- Creates the (static, reused) FontStrings inside parentFrame. Safe to call
-- more than once - a second call is a no-op.
function OrderAnalysisContent:Build(parentFrame)
    if self.built and self.parentFrame == parentFrame then
        return
    end

    self.parentFrame = parentFrame

    local netValueHeader = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    netValueHeader:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", LEFT_MARGIN, TOTAL_ROW_Y)
    netValueHeader:SetText("Estimated Net Value Total")

    -- Right-aligned onto the same row/column the rest of the breakdown uses,
    -- kept in the larger font so the total stays visually prominent - only
    -- its horizontal alignment changed.
    local netValueText = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    netValueText:SetPoint("TOPRIGHT", parentFrame, "TOPRIGHT", -RIGHT_MARGIN, TOTAL_ROW_Y)
    netValueText:SetJustifyH("RIGHT")

    local divider = parentFrame:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(COLOR_MUTED[1], COLOR_MUTED[2], COLOR_MUTED[3], 0.35)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", LEFT_MARGIN, DIVIDER_Y)
    divider:SetPoint("TOPRIGHT", parentFrame, "TOPRIGHT", -RIGHT_MARGIN, DIVIDER_Y)

    -- "Check your mats" note under the total (see OrderDisplayModelBuilder
    -- matQualityNote). Pushes the divider and rows down while shown.
    local matNoteText = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    matNoteText:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", LEFT_MARGIN, DIVIDER_Y + 4)
    matNoteText:SetPoint("RIGHT", parentFrame, "RIGHT", -RIGHT_MARGIN, 0)
    matNoteText:SetJustifyH("LEFT")
    matNoteText:SetJustifyV("TOP")
    matNoteText:SetTextColor(1.00, 0.82, 0.00, 1)
    matNoteText:Hide()

    local statusText = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 8, -10)
    statusText:SetPoint("RIGHT", parentFrame, "RIGHT", -8, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetJustifyV("TOP")
    statusText:Hide()

    self.netValueHeader = netValueHeader
    self.netValueText = netValueText
    self.divider = divider
    self.matNoteText = matNoteText
    self.statusText = statusText
    self.rowFrames = self.rowFrames or {}
    self.built = true
end

local function HideRows(self)
    for _, row in ipairs(self.rowFrames or {}) do
        row:Hide()
        if row.infoButton then
            row.infoButton:Hide()
        end
    end
end

local function HideAll(self)
    self.netValueHeader:Hide()
    self.netValueText:Hide()
    self.divider:Hide()
    self.matNoteText:Hide()
    self.statusText:Hide()
    HideRows(self)
end

function OrderAnalysisContent:ShowLoading()
    if not self.built then
        return
    end
    HideAll(self)
    self.statusText:SetText("Loading...")
    SetColor(self.statusText, COLOR_MUTED)
    self.statusText:Show()
end

function OrderAnalysisContent:ShowNoOrderSelected()
    if not self.built then
        return
    end
    HideAll(self)
    self.statusText:SetText("Select an order to view its estimated value.")
    SetColor(self.statusText, COLOR_MUTED)
    self.statusText:Show()
end

-- First-run guidance: shown in place of the analysis until one full price
-- scan has finished (PocketCFO_Valuation:HasCompletedPriceScan). Treats a
-- missing Valuation addon as "scanned" so this can never block the panel.
local function NeedsFirstPriceScan()
    local valuation = _G.PocketCFO_Valuation
    if not valuation or not valuation.HasCompletedPriceScan then
        return false
    end
    return not valuation:HasCompletedPriceScan()
end

function OrderAnalysisContent:ShowNeedsPriceScan()
    if not self.built then
        return
    end
    HideAll(self)
    local valuation = _G.PocketCFO_Valuation
    self.statusText:SetText((valuation and valuation.NO_SCAN_MESSAGE) or "No prices yet.")
    SetColor(self.statusText, COLOR_HEADER)
    self.statusText:Show()
end

function OrderAnalysisContent:ShowUnavailable()
    if not self.built then
        return
    end
    HideAll(self)
    self.statusText:SetText("Unable to read the selected order.")
    SetColor(self.statusText, COLOR_NEGATIVE)
    self.statusText:Show()
end

local function FormatQuantity(quantity)
    local value = tonumber(quantity) or 0
    if math.abs(value - math.floor(value + 0.000001)) < 0.000001 then
        return tostring(math.floor(value + 0.000001))
    end
    return string.format("%.2f", value)
end

local function BuildNameQuantityLabel(row)
    local name = tostring(row.name or row.label or "Unknown reagent")
    local quantity = tonumber(row.quantity) or 1
    if quantity ~= 1 then
        return string.format("%s x%s", name, FormatQuantity(quantity))
    end
    return name
end

local function FormatRowValue(lineValue, valueSign)
    local signedValue = tonumber(lineValue) or 0
    if valueSign == "negative" then
        signedValue = -math.abs(signedValue)
    elseif valueSign == "positive" then
        signedValue = math.abs(signedValue)
    end
    return FormatSignedGoldSilver(signedValue)
end

local function TruncateLabel(fontString, text, maxWidth)
    text = tostring(text or "")
    fontString:SetText(text)
    if fontString:GetStringWidth() <= maxWidth then
        return text, false
    end

    for length = #text, 1, -1 do
        local candidate = text:sub(1, length) .. ELLIPSIS
        fontString:SetText(candidate)
        if fontString:GetStringWidth() <= maxWidth then
            return candidate, true
        end
    end

    fontString:SetText(ELLIPSIS)
    return ELLIPSIS, true
end

local function GetRow(self, index)
    self.rowFrames = self.rowFrames or {}
    local row = self.rowFrames[index]
    if row then
        return row
    end

    row = CreateFrame("Frame", nil, self.parentFrame)
    row:SetHeight(ROW_HEIGHT)
    row:EnableMouse(true)

    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.left:SetJustifyH("LEFT")
    row.left:SetWordWrap(false)
    if row.left.SetMaxLines then
        row.left:SetMaxLines(1)
    end

    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.right:SetJustifyH("RIGHT")
    row.right:SetWidth(VALUE_WIDTH)
    row.right:SetWordWrap(false)

    row.infoButton = CreateFrame("Button", nil, row)
    row.infoButton:SetSize(14, 14)
    row.infoButton.icon = row.infoButton:CreateTexture(nil, "ARTWORK")
    row.infoButton.icon:SetAllPoints()
    row.infoButton.icon:SetTexture("Interface\\Common\\help-i")
    row.infoButton:Hide()

    row:SetScript("OnEnter", function(frame)
        if not frame._tooltipText or not GameTooltip then
            return
        end
        GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
        GameTooltip:SetText("Full Label", 1, 1, 1)
        GameTooltip:AddLine(frame._tooltipText, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)

    row.infoButton:SetScript("OnEnter", function(button)
        local tooltipText = button._tooltipText
        if not tooltipText or not GameTooltip then
            return
        end
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetText("Estimated Resourcefulness Returns", 1, 1, 1)
        GameTooltip:AddLine(tooltipText, 0.9, 0.85, 0.65, true)
        GameTooltip:Show()
    end)
    row.infoButton:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)

    self.rowFrames[index] = row
    return row
end

local function LayoutRow(self, index, yOffset, leftText, rightText, options)
    options = type(options) == "table" and options or {}

    local row = GetRow(self, index)
    local parentWidth = (self.parentFrame and self.parentFrame.GetWidth and self.parentFrame:GetWidth()) or 280
    local rowWidth = math.max(160, parentWidth - LEFT_MARGIN - RIGHT_MARGIN)
    local leftWidth = math.max(72, rowWidth - VALUE_WIDTH - COLUMN_GAP)

    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", self.parentFrame, "TOPLEFT", LEFT_MARGIN, yOffset)
    row:SetWidth(rowWidth)
    row:SetHeight(ROW_HEIGHT)

    row.left:SetWidth(leftWidth)
    row.right:SetWidth(VALUE_WIDTH)
    row.right:SetText(rightText or "")

    SetColor(row.left, options.header and COLOR_HEADER or COLOR_TEXT)
    if options.unvalued then
        SetColor(row.right, COLOR_MUTED)
    else
        SetColor(row.right, options.negative and COLOR_NEGATIVE or COLOR_POSITIVE)
    end

    local shownText, truncated = TruncateLabel(row.left, leftText, leftWidth)
    row._tooltipText = (truncated and options.fullText) or nil

    if options.infoTooltip then
        row.infoButton._tooltipText = options.infoTooltip
        row.infoButton:ClearAllPoints()
        row.infoButton:SetPoint("LEFT", row.left, "LEFT", math.min(row.left:GetStringWidth() + 6, leftWidth - 14), 0)
        row.infoButton:Show()
    else
        row.infoButton:Hide()
    end

    row:Show()
    return yOffset - ROW_HEIGHT, index + 1, shownText
end

local function AddSection(self, index, yOffset, title, rows, valueSign, options)
    rows = type(rows) == "table" and rows or {}
    if #rows == 0 then
        return index, yOffset
    end
    -- Normalized once so every section gets the same top margin regardless
    -- of whether the caller passed an options table - a caller omitting
    -- options entirely (nil) previously short-circuited "options and
    -- options.addGap ~= false" to falsy, silently skipping the gap only for
    -- that section (this is what happened to Costs, the one call site with
    -- no options argument).
    options = type(options) == "table" and options or {}

    if options.addGap ~= false then
        yOffset = yOffset - SECTION_GAP
    end

    yOffset, index = LayoutRow(self, index, yOffset, title, nil, {
        header = true,
        infoTooltip = options.infoTooltip,
    })

    for _, row in ipairs(rows) do
        local label = BuildNameQuantityLabel(row)
        local negative = valueSign == "negative"
        local unvalued = row.unvalued == true
        local valueText

        if unvalued then
            valueText = UNVALUED_TEXT
        elseif row.lineValue ~= nil then
            -- Only a genuinely modeled/statistical value (e.g. a container-
            -- outcome or Moxie-bag-ratio result) gets "(Estimated)" - driven
            -- by ValuationService's valuationBasis classification, not by
            -- inspecting strategy-name strings. A fixed or directly
            -- market-observed value never shows it, regardless of section.
            if row.valuationBasis == "modeled" then
                label = label .. " (Estimated)"
            end
            valueText = FormatRowValue(row.lineValue, valueSign)
        end

        yOffset, index = LayoutRow(self, index, yOffset, label, valueText, {
            negative = negative,
            unvalued = unvalued,
            fullText = label,
        })
    end

    return index, yOffset
end

-- Costs = crafter-provided required-reagent cost + crafter-provided
-- finishing-reagent cost, concatenated for display only. Both arrays are
-- already customer-filtered and already-valued by OrderDisplayModelBuilder -
-- this merge is presentation grouping, not a valuation change. Since Costs
-- now renders every crafterMaterials/finishingReagents row (valued and
-- unvalued alike, unvalued ones showing "Unvalued" inline per AddSection),
-- displayModel.itemsNotValued - which is built only from crafterMaterials -
-- would be a pure duplicate of rows already visible here, so it is
-- intentionally not rendered as a separate section anymore.
local function BuildCostRows(displayModel)
    local rows = {}
    for _, row in ipairs(displayModel.crafterMaterials or {}) do
        rows[#rows + 1] = row
    end
    for _, row in ipairs(displayModel.finishingReagents or {}) do
        rows[#rows + 1] = row
    end
    return rows
end

function OrderAnalysisContent:ShowResolved(displayModel)
    if not self.built then
        return
    end
    HideAll(self)

    self.netValueHeader:Show()
    self.netValueText:Show()
    self.divider:Show()

    local netValue = tonumber(displayModel.estimatedNetValue) or 0
    self.netValueText:SetText(FormatSignedGoldSilver(netValue))
    SetColor(self.netValueText, netValue < 0 and COLOR_NEGATIVE or COLOR_POSITIVE)

    -- Note sits where the divider normally is; divider and rows shift down
    -- by the note's height.
    local noteShift = 0
    if displayModel.matQualityNote then
        self.matNoteText:SetText(displayModel.matQualityNote)
        self.matNoteText:Show()
        noteShift = math.ceil(self.matNoteText:GetStringHeight() or 0) + 4
    end
    self.divider:ClearAllPoints()
    self.divider:SetPoint("TOPLEFT", self.parentFrame, "TOPLEFT", LEFT_MARGIN, DIVIDER_Y - noteShift)
    self.divider:SetPoint("TOPRIGHT", self.parentFrame, "TOPRIGHT", -RIGHT_MARGIN, DIVIDER_Y - noteShift)

    local index = 1
    local yOffset = ROWS_START_Y - noteShift

    yOffset, index = LayoutRow(self, index, yOffset, "Gold Payout", FormatRowValue(displayModel.commission, "positive"), {
        fullText = "Gold Payout",
    })

    index, yOffset = AddSection(self, index, yOffset, "Rewards", displayModel.rewards, "positive")
    index, yOffset = AddSection(self, index, yOffset, "Estimated Resourcefulness Returns", displayModel.expectedResourcefulness, "positive", {
        infoTooltip = RESOURCEFULNESS_TOOLTIP,
    })
    index, yOffset = AddSection(self, index, yOffset, "Costs", BuildCostRows(displayModel), "negative")

    for extraIndex = index, #(self.rowFrames or {}) do
        self.rowFrames[extraIndex]:Hide()
    end

    -- Keep the content frame's height honest for future shell scrollability,
    -- without changing the companion's current positioning behavior.
    if self.parentFrame and self.parentFrame.SetHeight then
        self.parentFrame:SetHeight(math.max(120, math.abs(yOffset) + ROW_HEIGHT))
    end
end

--- Renders one OrderDisplayModelBuilder result. Dispatches purely on
-- displayModel.state - no valuation/economics decisions made here.
function OrderAnalysisContent:Render(displayModel)
    if type(displayModel) ~= "table" then
        self:ShowUnavailable()
        return
    end

    if NeedsFirstPriceScan() then
        self:ShowNeedsPriceScan()
        return
    end

    if displayModel.state == "noOrderSelected" then
        self:ShowNoOrderSelected()
    elseif displayModel.state == "resolved" then
        self:ShowResolved(displayModel)
    else
        self:ShowUnavailable()
    end
end

function OrderAnalysisContent:Clear()
    if not self.built then
        return
    end
    HideAll(self)
end

if PocketCFO_Orders then
    PocketCFO_Orders.OrderAnalysisContent = OrderAnalysisContent
end
