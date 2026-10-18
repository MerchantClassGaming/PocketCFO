-- PocketCFO_Crafting/UI/RecipeAnalysis/RecipeAnalysisContent.lua
-- Renders the Recipe Analysis display model into a frame inside the
-- crafting companion window (InventoryManagerWindow:RenderRecipeAnalysis).
-- Copied from PocketCFO_Orders' OrderAnalysisContent so both analyses look
-- the same (Crafting cannot depend on PocketCFO_Orders). Differences: a
-- configurable headline (Profit per Craft / Cost to Make), a "Sells For"
-- section instead of Gold Payout/Rewards, per-row info tooltips (used by
-- the Multicraft row), and a muted note row.
-- Never performs valuation/economics itself.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local RecipeAnalysisContent = {}

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
    "Expected mats back from Resourcefulness, based on your current Resourcefulness %. These are long-run averages, not what any single craft will return."

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

-- Unsigned version for facts (Cost to Make, Cost per Item) - no +/-.
local function FormatGoldSilver(copperValue)
    local signed = FormatSignedGoldSilver(math.abs(tonumber(copperValue) or 0))
    return signed:sub(2)
end

local function SetColor(fontString, color)
    fontString:SetTextColor(color[1], color[2], color[3], 1)
end

--- Creates the (static, reused) FontStrings inside parentFrame. Safe to call
-- more than once - a second call is a no-op.
function RecipeAnalysisContent:Build(parentFrame)
    if self.built and self.parentFrame == parentFrame then
        return
    end

    self.parentFrame = parentFrame

    local netValueHeader = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    netValueHeader:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", LEFT_MARGIN, TOTAL_ROW_Y)
    netValueHeader:SetText("Profit per Craft")

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

    local statusText = parentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    statusText:SetPoint("TOPLEFT", parentFrame, "TOPLEFT", 8, -10)
    statusText:SetPoint("RIGHT", parentFrame, "RIGHT", -8, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetJustifyV("TOP")
    statusText:Hide()

    self.netValueHeader = netValueHeader
    self.netValueText = netValueText
    self.divider = divider
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
    self.statusText:Hide()
    HideRows(self)
end

function RecipeAnalysisContent:ShowLoading()
    if not self.built then
        return
    end
    HideAll(self)
    self.statusText:SetText("Loading...")
    SetColor(self.statusText, COLOR_MUTED)
    self.statusText:Show()
end

function RecipeAnalysisContent:ShowNoRecipeSelected()
    if not self.built then
        return
    end
    HideAll(self)
    self.statusText:SetText("Select a recipe to see what it makes.")
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

function RecipeAnalysisContent:ShowNeedsPriceScan()
    if not self.built then
        return
    end
    HideAll(self)
    local valuation = _G.PocketCFO_Valuation
    self.statusText:SetText((valuation and valuation.NO_SCAN_MESSAGE) or "No prices yet.")
    SetColor(self.statusText, COLOR_HEADER)
    self.statusText:Show()
end

function RecipeAnalysisContent:ShowUnavailable()
    if not self.built then
        return
    end
    HideAll(self)
    self.statusText:SetText("Unable to read this recipe yet.")
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
        GameTooltip:SetText(button._tooltipTitle or "Estimated Resourcefulness Returns", 1, 1, 1)
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

    SetColor(row.left, options.header and COLOR_HEADER or (options.note and COLOR_MUTED or COLOR_TEXT))
    if options.unvalued then
        SetColor(row.right, COLOR_MUTED)
    elseif options.neutral then
        SetColor(row.right, COLOR_TEXT)
    else
        SetColor(row.right, options.negative and COLOR_NEGATIVE or COLOR_POSITIVE)
    end

    -- Note rows (muted, no value) wrap onto multiple lines across the full
    -- row width instead of truncating; every other row stays one line.
    -- Word wrap is reset each time because row frames are reused.
    if options.note then
        row.left:SetWidth(rowWidth)
        row.left:SetWordWrap(true)
        if row.left.SetMaxLines then row.left:SetMaxLines(4) end
        row.left:SetText(tostring(leftText or ""))
        row._tooltipText = nil
        row.infoButton:Hide()
        local height = math.max(ROW_HEIGHT, math.ceil((row.left:GetStringHeight() or ROW_HEIGHT) + 4))
        row:SetHeight(height)
        row.left:ClearAllPoints()
        row.left:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
        row:Show()
        return yOffset - height, index + 1, leftText
    end
    row.left:SetWordWrap(false)
    if row.left.SetMaxLines then row.left:SetMaxLines(1) end
    row.left:ClearAllPoints()
    row.left:SetPoint("LEFT", row, "LEFT", 0, 0)

    local shownText, truncated = TruncateLabel(row.left, leftText, leftWidth)
    row._tooltipText = (truncated and options.fullText) or nil

    if options.infoTooltip then
        row.infoButton._tooltipText = options.infoTooltip
        row.infoButton._tooltipTitle = options.infoTitle
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
        infoTitle = options.infoTitle,
    })

    for _, row in ipairs(rows) do
        local label = BuildNameQuantityLabel(row)
        -- A row may override the section's sign (Sells For's AH Cut row).
        local rowSign = row.valueSign or valueSign
        local negative = rowSign == "negative"
        local unvalued = row.unvalued == true
        local valueText

        if row.valueText then
            valueText = row.valueText
        elseif unvalued then
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
            valueText = FormatRowValue(row.lineValue, rowSign)
        end

        yOffset, index = LayoutRow(self, index, yOffset, label, valueText, {
            negative = negative,
            unvalued = unvalued,
            fullText = label,
            infoTooltip = row.infoTooltip,
            infoTitle = row.infoTitle,
        })
    end

    return index, yOffset
end

function RecipeAnalysisContent:ShowResolved(displayModel)
    if not self.built then
        return
    end
    HideAll(self)

    local headline = displayModel.headline or {}
    local headlineValue = tonumber(headline.value) or 0
    self.netValueHeader:SetText(headline.label or "Cost to Make")
    self.netValueHeader:Show()
    self.netValueText:Show()
    self.divider:Show()
    if headline.style == "profit" then
        self.netValueText:SetText(FormatSignedGoldSilver(headlineValue))
        SetColor(self.netValueText, headlineValue < 0 and COLOR_NEGATIVE or COLOR_POSITIVE)
    else
        self.netValueText:SetText(FormatGoldSilver(headlineValue))
        SetColor(self.netValueText, COLOR_TEXT)
    end

    local index = 1
    local yOffset = ROWS_START_Y

    -- Facts: neutral color, no sign.
    for _, row in ipairs(displayModel.summaryRows or {}) do
        yOffset, index = LayoutRow(self, index, yOffset, row.name, FormatGoldSilver(row.lineValue), {
            neutral = true,
            fullText = row.name,
            infoTooltip = row.infoTooltip,
            infoTitle = row.infoTitle,
        })
    end

    -- Optional extra muted notes (Lure Analysis).
    for _, noteText in ipairs(displayModel.noteRows or {}) do
        yOffset, index = LayoutRow(self, index, yOffset, noteText, nil, {
            note = true,
            fullText = noteText,
        })
    end

    if displayModel.unchosenNote then
        yOffset, index = LayoutRow(self, index, yOffset, displayModel.unchosenNote, nil, {
            note = true,
            fullText = displayModel.unchosenNote,
        })
    end

    if displayModel.boundMatsNote then
        yOffset, index = LayoutRow(self, index, yOffset, displayModel.boundMatsNote, nil, {
            note = true,
            fullText = displayModel.boundMatsNote,
        })
    end

    if displayModel.unpricedWarning then
        yOffset, index = LayoutRow(self, index, yOffset, displayModel.unpricedWarning, nil, {
            note = true,
            fullText = displayModel.unpricedWarning,
        })
    end

    local boundMatRow = displayModel.boundMatRow
    if boundMatRow then
        yOffset, index = LayoutRow(self, index, yOffset, boundMatRow.name, FormatRowValue(boundMatRow.lineValue), {
            negative = (tonumber(boundMatRow.lineValue) or 0) < 0,
            fullText = boundMatRow.name,
            infoTooltip = boundMatRow.infoTooltip,
            infoTitle = boundMatRow.infoTitle,
        })
    end

    -- Optional extra titled sections (Lure Analysis).
    for _, section in ipairs(displayModel.sections or {}) do
        index, yOffset = AddSection(self, index, yOffset, section.title, section.rows, section.valueSign, {
            infoTooltip = section.infoTooltip,
            infoTitle = section.title,
        })
    end

    if displayModel.outputRows then
        index, yOffset = AddSection(self, index, yOffset, displayModel.outputSectionTitle or "Sells For", displayModel.outputRows, "positive")
    elseif displayModel.noPriceNote then
        yOffset = yOffset - SECTION_GAP
        yOffset, index = LayoutRow(self, index, yOffset, displayModel.noPriceNote, nil, {
            note = true,
            fullText = displayModel.noPriceNote,
        })
    end

    local concentration = displayModel.concentrationRow
    if concentration then
        local valueText = concentration.lineValue ~= nil and FormatRowValue(concentration.lineValue) or nil
        yOffset = yOffset - SECTION_GAP
        yOffset, index = LayoutRow(self, index, yOffset, concentration.name, valueText, {
            negative = (tonumber(concentration.lineValue) or 0) < 0,
            fullText = concentration.name,
            infoTooltip = concentration.infoTooltip,
            infoTitle = concentration.infoTitle,
        })
    end

    index, yOffset = AddSection(self, index, yOffset, "Estimated Resourcefulness Returns", displayModel.expectedResourcefulness, "positive", {
        infoTooltip = RESOURCEFULNESS_TOOLTIP,
    })
    index, yOffset = AddSection(self, index, yOffset, "Costs", displayModel.costs, "negative")

    for extraIndex = index, #(self.rowFrames or {}) do
        self.rowFrames[extraIndex]:Hide()
    end

    if self.parentFrame and self.parentFrame.SetHeight then
        self.parentFrame:SetHeight(math.max(120, math.abs(yOffset) + ROW_HEIGHT))
    end
end

--- Renders one RecipeAnalysisDisplayModelBuilder result. Dispatches purely on
-- displayModel.state - no valuation/economics decisions made here.
function RecipeAnalysisContent:Render(displayModel)
    if type(displayModel) ~= "table" then
        self:ShowUnavailable()
        return
    end

    if NeedsFirstPriceScan() then
        self:ShowNeedsPriceScan()
        return
    end

    if displayModel.state == "resolved" then
        self:ShowResolved(displayModel)
    else
        self:ShowUnavailable()
    end
end

function RecipeAnalysisContent:Clear()
    if not self.built then
        return
    end
    HideAll(self)
end

if PocketCFO_Crafting then
    PocketCFO_Crafting.RecipeAnalysisContent = RecipeAnalysisContent
end
