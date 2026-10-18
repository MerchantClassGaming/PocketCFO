-- PocketCFO_Crafting/UI/InventoryManager/InventoryManagerWindow.lua
-- Inventory Manager frame: creation, row pool, and visual rendering.
-- Receives render-ready category groups from CraftQueueController via Render().
-- Does not calculate shortages, resolve item identity, or query inventory directly.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
local GetCoinTextureString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString)
    or GetCoinTextureString
    or GetMoneyString

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local InventoryManagerWindow = PocketCFO_Crafting:NewModule("InventoryManagerWindow")

-- ---------------------------------------------------------------------------
-- Layout constants
-- ---------------------------------------------------------------------------

local FRAME_WIDTH         = 350
local FRAME_HEIGHT        = 400
local ROW_HEIGHT          = 32
local ROW_PADDING         =   4
local HEADER_HEIGHT       =  20
local FRAME_PADDING       =  10
local LIST_TOP_OFFSET     =  54
local LIST_BOTTOM_OFFSET  =  34

local DEFICIT_WIDTH   = 36
local QTY_BTN_WIDTH   = 18
local QTY_BOX_WIDTH   = 28

-- ---------------------------------------------------------------------------
-- Color definitions (RGBA 0-1)
-- ---------------------------------------------------------------------------

local COLOR_GREEN     = { r = 0.0, g = 0.8, b = 0.2, a = 1.0 }
local COLOR_YELLOW    = { r = 1.0, g = 0.8, b = 0.0, a = 1.0 }
local COLOR_RED       = { r = 0.9, g = 0.2, b = 0.1, a = 1.0 }
local COLOR_GREY      = { r = 0.55, g = 0.55, b = 0.55, a = 1.0 }
local COLOR_HEADER    = { r = 0.7, g = 0.6, b = 0.3, a = 1.0 }
local COLOR_BG        = { r = 0.05, g = 0.05, b = 0.08, a = 0.92 }
local COLOR_ROW_EVEN  = { r = 0.08, g = 0.08, b = 0.12, a = 0.8 }
local COLOR_ROW_ODD   = { r = 0.12, g = 0.12, b = 0.16, a = 0.8 }
local COLOR_HOVER     = { r = 0.20, g = 0.20, b = 0.30, a = 0.9 }
local COLOR_HIGHLIGHT = { r = 0.26, g = 0.22, b = 0.08, a = 0.95 }

-- Expansion filter options (newest first)
local EXP_FILTER_OPTIONS = {
    { label = "All Expansions", value = nil },
    { label = "Midnight",       value = 12  },
    { label = "Khaz Algar",     value = 11  },
    { label = "Dragon Isles",   value = 10  },
}

-- ---------------------------------------------------------------------------
-- Frame handles and pool state (module-level, created once per session)
-- ---------------------------------------------------------------------------

local mainFrame          = nil
local scrollFrame        = nil
local contentFrame       = nil
local modeContentFrame   = nil
local rowPool            = {}
local activeRows         = {}
local headerPool         = {}
local activeHeaders      = {}
local postingRulesBtn    = nil
local postingProfilesBtn = nil
local analysisToggleBtn  = nil
local analysisResultsToggleBtn = nil
local analysisBackBtn    = nil
local analysisInfoBtn    = nil
local emptyLabel         = nil
-- Live Recipe Analysis frame (child of contentFrame) - see RenderRecipeAnalysis.
-- Every other Render* hides it via HideRecipeAnalysisFrame.
local recipeAnalysisFrame = nil
local titleText          = nil
local showAllBtn         = nil
local expDropdown        = nil

-- Processing Analysis row pool (separate from the Inventory row pool above -
-- analysis rows have no qty controls/deficit badge, so they are a different
-- widget shape, not a reskin of the same frames). The crafting-quality
-- marker (see ApplyQualityOverlay below) is layered on top of the icon's
-- own corner rather than occupying a separate column, so name inset only
-- needs to clear the icon itself.
local ANALYSIS_ROW_HEIGHT             = 48
local ANALYSIS_ICON_SIZE              = 28
local ANALYSIS_QUALITY_OVERLAY_SIZE   = 14
local ANALYSIS_VALUE_WIDTH            = 70
local ANALYSIS_NAME_LEFT_INSET = ROW_PADDING + ANALYSIS_ICON_SIZE + 6

-- Analysis mode reuses the same scrollFrame/contentFrame as the Inventory
-- list, but lays out differently: no expansion dropdown to clear at the top,
-- no qty-cluster/deficit-badge gutter to reserve on the right, and the
-- Posting Rules/Profiles button row is hidden (see SetInventoryControlsVisible)
-- freeing the bottom strip for the footer note instead. Applied/reset via
-- ApplyScrollFrameLayout so returning to Inventory mode is never left with
-- Analysis's anchors.
local ANALYSIS_LIST_TOP_OFFSET    = 28
local ANALYSIS_LIST_BOTTOM_OFFSET = 30
local ANALYSIS_LIST_RIGHT_GUTTER  = 8

local analysisRowPool     = {}
local activeAnalysisRows  = {}
local analysisColumnHeader = nil
local analysisFooterNote   = nil

-- Processing Analysis detail-view line pool - each line is one "label:
-- value" (or list-item) row of plain text, used for the compact detail
-- breakdown a clicked analysis row switches into.
local DETAIL_LINE_HEIGHT  = 16
local detailLinePool      = {}
local activeDetailLines   = {}

-- Maps the semantic color names ProcessingAnalysisDisplayModelBuilder
-- produces onto this window's existing color constants. This is a color
-- lookup only - no thresholds or recommendation logic live here.
local STATUS_COLOR_BY_NAME = {
    green  = COLOR_GREEN,
    yellow = COLOR_YELLOW,
    red    = COLOR_RED,
    grey   = COLOR_GREY,
}

-- Display filter state — pure view preferences toggled by UI elements in this window
local showZeroDeficit  = false
local currentExpFilter = nil

-- configID of the currently highlighted row; updated on each Render call
local currentHighlightedConfigID = nil

-- Set to a configID before calling Render to scroll that row into view after layout
local scrollHighlightedAfterRender = nil

-- Tooltip state for the currently hovered row
InventoryManagerWindow.activeTooltipState = nil

-- Callbacks provided by CraftQueueController at Build time
local callbacks = {}

-- Minimal mode-registration overlay (see PocketCFO_Orders MVP spec Part 8).
-- Orthogonal to the existing Inventory/Analysis viewMode toggle above -
-- activating a registered mode simply hides the existing scroll content +
-- inventory-only chrome and shows one shared modeContentFrame the provider
-- renders into; deactivating restores the existing default Inventory render.
-- No existing viewMode/Render*/SetInventoryControlsVisible call site is
-- touched by this.
local registeredModes = {}
local activeModeName = nil

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function HideRecipeAnalysisFrame()
    if recipeAnalysisFrame then recipeAnalysisFrame:Hide() end
end

local function SetRowBaseBackground(row)
    if row._craftQueueConfigID and row._craftQueueConfigID == currentHighlightedConfigID then
        row.bg:SetColorTexture(COLOR_HIGHLIGHT.r, COLOR_HIGHLIGHT.g, COLOR_HIGHLIGHT.b, COLOR_HIGHLIGHT.a)
    elseif row._isEven then
        row.bg:SetColorTexture(COLOR_ROW_EVEN.r, COLOR_ROW_EVEN.g, COLOR_ROW_EVEN.b, COLOR_ROW_EVEN.a)
    else
        row.bg:SetColorTexture(COLOR_ROW_ODD.r, COLOR_ROW_ODD.g, COLOR_ROW_ODD.b, COLOR_ROW_ODD.a)
    end
end

local function DebugTime()
    return debugprofilestop and debugprofilestop() or (GetTime and GetTime() * 1000) or 0
end

local function LogTiming(label, startedAt, extra)
    if not PocketCFO or not PocketCFO.Debug then return end
    local elapsed = DebugTime() - (startedAt or DebugTime())
    if extra and extra ~= "" then
        PocketCFO:Debug("%s elapsed=%.1fms %s", label, elapsed, extra)
    else
        PocketCFO:Debug("%s elapsed=%.1fms", label, elapsed)
    end
end

local function TraceProcessingAnalysisUI(event, fmt, ...)
    local trace = _G.MCG_DiagnosticProcessingAnalysisUITrace
    if type(trace) ~= "table" then
        trace = { seq = 0, limit = 100, events = {} }
        _G.MCG_DiagnosticProcessingAnalysisUITrace = trace
    end
    trace.seq = (tonumber(trace.seq) or 0) + 1
    trace.limit = tonumber(trace.limit) or 100
    trace.events = type(trace.events) == "table" and trace.events or {}

    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    trace.events[#trace.events + 1] = {
        seq = trace.seq,
        time = date and date("%H:%M:%S") or tostring(GetTime and GetTime() or ""),
        event = tostring(event or "event"),
        message = msg,
    }
    while #trace.events > trace.limit do
        table.remove(trace.events, 1)
    end
end

local function UpdateScrollbarVisibility()
    if not scrollFrame or not contentFrame then return end
    local scrollbar = scrollFrame.ScrollBar or _G[(scrollFrame:GetName() or "") .. "ScrollBar"]
    if not scrollbar then return end
    local contentHeight = contentFrame:GetHeight() or 0
    local frameHeight   = scrollFrame:GetHeight()  or 0
    if contentHeight > frameHeight + 1 then
        scrollbar:Show()
    else
        scrollbar:Hide()
        if scrollFrame.SetVerticalScroll then
            scrollFrame:SetVerticalScroll(0)
        end
    end
end

-- Analysis mode reuses the same scrollFrame/contentFrame widgets as the
-- Inventory list, but needs different anchors (see the ANALYSIS_LIST_*
-- constants above). Re-applied at the top of every Render/RenderAnalysis/
-- RenderAnalysisDetail call so switching modes never leaves the scrollFrame
-- anchored the way a previous mode left it. The "false" branch reproduces
-- Build()'s original Inventory-mode formula exactly, so Inventory layout is
-- pixel-identical to before this ever existed.
local function ApplyScrollFrameLayout(isAnalysisList)
    if not scrollFrame or not contentFrame or not mainFrame then return end
    scrollFrame:ClearAllPoints()
    local width
    if isAnalysisList then
        scrollFrame:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",     FRAME_PADDING, -ANALYSIS_LIST_TOP_OFFSET)
        scrollFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -(FRAME_PADDING + ANALYSIS_LIST_RIGHT_GUTTER), ANALYSIS_LIST_BOTTOM_OFFSET)
        width = FRAME_WIDTH - FRAME_PADDING - (FRAME_PADDING + ANALYSIS_LIST_RIGHT_GUTTER)
    else
        scrollFrame:SetPoint("TOPLEFT",     mainFrame, "TOPLEFT",     FRAME_PADDING, -LIST_TOP_OFFSET)
        scrollFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -(FRAME_PADDING + 18), LIST_BOTTOM_OFFSET)
        width = FRAME_WIDTH - FRAME_PADDING * 2 - 18
    end
    contentFrame:SetWidth(width)
end

local ANALYSIS_FOOTER_DEFAULT_TEXT = "Expected values are based on your historical prospecting results and current market prices."

-- Lazily-created footer note, shown only for the Analysis list. Anchored to
-- mainFrame (not contentFrame) so it stays fixed at the bottom of the panel
-- rather than scrolling with the row list.
local function GetAnalysisFooterNote()
    if analysisFooterNote then
        return analysisFooterNote
    end
    local footer = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT",  mainFrame, "BOTTOMLEFT",  FRAME_PADDING, 8)
    footer:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -FRAME_PADDING, 8)
    footer:SetJustifyH("LEFT")
    footer:SetWordWrap(true)
    footer:SetText(ANALYSIS_FOOTER_DEFAULT_TEXT)
    footer:Hide()
    analysisFooterNote = footer
    return footer
end

local function ScrollHighlightedRowIntoView()
    if not scrollFrame or not contentFrame or not currentHighlightedConfigID then return end
    if not scrollFrame.GetVerticalScroll or not scrollFrame.SetVerticalScroll then return end

    local targetRow = nil
    for _, row in ipairs(activeRows) do
        if row._craftQueueConfigID == currentHighlightedConfigID then
            targetRow = row
            break
        end
    end
    if not targetRow then return end

    local rowTop        = targetRow._craftQueueScrollTop
    local rowBottom     = targetRow._craftQueueScrollBottom
    local viewHeight    = scrollFrame:GetHeight()
    local contentHeight = contentFrame:GetHeight()
    if not rowTop or not rowBottom or not viewHeight or not contentHeight then return end

    local currentOffset = scrollFrame:GetVerticalScroll() or 0
    local targetOffset  = currentOffset
    if rowTop < currentOffset then
        targetOffset = rowTop
    elseif rowBottom > currentOffset + viewHeight then
        targetOffset = rowBottom - viewHeight
    end

    local maxOffset = math.max(0, contentHeight - viewHeight)
    if targetOffset < 0 then targetOffset = 0 end
    if targetOffset > maxOffset then targetOffset = maxOffset end

    if math.abs(targetOffset - currentOffset) > 0.5 then
        scrollFrame:SetVerticalScroll(targetOffset)
    end
end

-- ---------------------------------------------------------------------------
-- Row pool
-- ---------------------------------------------------------------------------

local function GetRow()
    local row = table.remove(rowPool)
    if not row then
        row = CreateFrame("Button", nil, contentFrame)
        row:SetHeight(ROW_HEIGHT)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(24, 24)
        row.icon:SetPoint("LEFT", row, "LEFT", ROW_PADDING, 0)

        -- Name label — right boundary leaves room for deficit badge + qty cluster
        row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameLabel:SetPoint("LEFT",  row.icon, "RIGHT", 4, 4)
        row.nameLabel:SetPoint("RIGHT", row, "RIGHT", -116, 4)
        row.nameLabel:SetJustifyH("LEFT")
        row.nameLabel:SetWordWrap(false)
        row.nameLabel:SetHeight(14)

        row.stockLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.stockLabel:SetPoint("LEFT",  row.icon, "RIGHT", 4, -8)
        row.stockLabel:SetPoint("RIGHT", row, "RIGHT", -116, -8)
        row.stockLabel:SetJustifyH("LEFT")
        row.stockLabel:SetHeight(12)

        -- Deficit badge — far right
        row.deficitLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        row.deficitLabel:SetPoint("RIGHT", row, "RIGHT", -ROW_PADDING, 0)
        row.deficitLabel:SetJustifyH("RIGHT")
        row.deficitLabel:SetWidth(DEFICIT_WIDTH)

        -- [+] button — rightmost of qty cluster, adjacent to deficit badge
        row.plusBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.plusBtn:SetSize(QTY_BTN_WIDTH, QTY_BTN_WIDTH)
        row.plusBtn:SetPoint("RIGHT", row.deficitLabel, "LEFT", -2, 0)
        row.plusBtn:SetText("+")
        row.plusBtn:GetFontString():SetFont(row.plusBtn:GetFontString():GetFont(), 14, "OUTLINE")

        -- Quantity editbox — center of qty cluster
        row.qtyBox = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
        row.qtyBox:SetSize(QTY_BOX_WIDTH, 18)
        row.qtyBox:SetPoint("RIGHT", row.plusBtn, "LEFT", -2, 0)
        row.qtyBox:SetAutoFocus(false)
        row.qtyBox:SetNumeric(true)
        row.qtyBox:SetMaxLetters(4)
        row.qtyBox:SetJustifyH("CENTER")
        row.qtyBox:SetFontObject("GameFontNormalSmall")

        -- [-] button — leftmost of qty cluster
        row.minusBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.minusBtn:SetSize(QTY_BTN_WIDTH, QTY_BTN_WIDTH)
        row.minusBtn:SetPoint("RIGHT", row.qtyBox, "LEFT", -2, 0)
        row.minusBtn:SetText("-")
        row.minusBtn:GetFontString():SetFont(row.minusBtn:GetFontString():GetFont(), 14, "OUTLINE")

        -- Warning icon (shown if missing optional or quality mismatch)
        row.warnIcon = row:CreateTexture(nil, "OVERLAY")
        row.warnIcon:SetSize(14, 14)
        row.warnIcon:SetPoint("TOPRIGHT", row.deficitLabel, "TOPLEFT", -2, 0)
        row.warnIcon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertOther")
        row.warnIcon:Hide()

        -- Default hover highlight — overridden with full binding in Render
        row:SetScript("OnEnter", function(self)
            self.bg:SetColorTexture(COLOR_HOVER.r, COLOR_HOVER.g, COLOR_HOVER.b, COLOR_HOVER.a)
        end)
        row:SetScript("OnLeave", function(self)
            SetRowBaseBackground(self)
        end)
    end

    row:Show()
    return row
end

local function ReleaseRow(row)
    row:Hide()
    row:SetScript("OnClick",  nil)
    row:SetScript("OnEnter",  nil)
    row:SetScript("OnLeave",  nil)
    row._craftQueueConfigID     = nil
    row._craftQueueResult       = nil
    row._craftQueueItemName     = nil
    row._craftQueueCharGUID     = nil
    row._craftQueueScrollTop    = nil
    row._craftQueueScrollBottom = nil
    row.warnIcon:Hide()
    row.minusBtn:SetScript("OnClick",        nil)
    row.plusBtn:SetScript("OnClick",         nil)
    row.qtyBox:SetScript("OnEnterPressed",   nil)
    row.qtyBox:SetScript("OnEscapePressed",  nil)
    row.qtyBox:SetScript("OnEditFocusLost",  nil)
    row.qtyBox:ClearFocus()
    table.insert(rowPool, row)
end

local function ReleaseAllRows()
    for _, row in ipairs(activeRows) do
        ReleaseRow(row)
    end
    activeRows = {}
end

-- ---------------------------------------------------------------------------
-- Processing Analysis row pool
-- ---------------------------------------------------------------------------

local function FormatAnalysisValue(copperValue)
    if copperValue == nil then return "--" end
    local rounded = math.floor(copperValue + 0.5)
    if GetCoinTextureString then
        return GetCoinTextureString(rounded)
    end
    return tostring(rounded) .. "c"
end

-- Compact signed-gold text for the analysis list column ("+82g" / "-46g"),
-- per the "Expected / Craft" list-view spec - deliberately not the coin-icon
-- format FormatAnalysisValue uses for the detail view.
local function FormatSignedGold(copperValue)
    if copperValue == nil then return nil end
    local gold = math.floor(math.abs(copperValue) / 10000 + 0.5)
    if gold == 0 then return "0g" end
    return (copperValue < 0 and "-" or "+") .. tostring(gold) .. "g"
end

local function FormatROIPercent(pct)
    if pct == nil then return "--" end
    return string.format("%s%.1f%%", pct >= 0 and "+" or "", pct)
end

-- Craft Analysis-only detail formatters (row.craftProduction). Unsigned,
-- unlike FormatROIPercent - a multicraft proc rate is never negative.
local function FormatAnalysisQuantity(n)
    if n == nil then return "--" end
    return string.format("%.2f", n)
end

local function FormatAnalysisPercent(fraction)
    if fraction == nil then return "--" end
    return string.format("%.1f%%", fraction * 100)
end

local VALUE_UNAVAILABLE_TEXT = {
    needsPrice = "Needs Price",
    noData     = "No Data",
}

-- Row content is built entirely with center-relative anchor points (LEFT/
-- RIGHT, not TOPLEFT/BOTTOMLEFT) so every element is vertically centered in
-- the row for free, without per-element y-offset math.
local function GetAnalysisRow()
    local row = table.remove(analysisRowPool)
    if not row then
        row = CreateFrame("Button", nil, contentFrame)
        row:SetHeight(ANALYSIS_ROW_HEIGHT)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetColorTexture(COLOR_ROW_EVEN.r, COLOR_ROW_EVEN.g, COLOR_ROW_EVEN.b, COLOR_ROW_EVEN.a)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(ANALYSIS_ICON_SIZE, ANALYSIS_ICON_SIZE)
        row.icon:SetPoint("LEFT", row, "LEFT", ROW_PADDING, 0)

        -- Blizzard-style crafting-reagent-quality marker, layered on the
        -- icon's own upper-left corner (the profession reagent-slot
        -- convention) rather than a separate text badge. Hidden by default;
        -- ApplyQualityOverlay only shows it when the row has a quality tier
        -- AND the atlas actually resolves in this client - never a
        -- fabricated substitute.
        row.qualityOverlay = row:CreateTexture(nil, "OVERLAY")
        row.qualityOverlay:SetSize(ANALYSIS_QUALITY_OVERLAY_SIZE, ANALYSIS_QUALITY_OVERLAY_SIZE)
        row.qualityOverlay:SetPoint("TOPLEFT", row.icon, "TOPLEFT", -2, 2)
        row.qualityOverlay:Hide()

        row.nameLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.nameLabel:SetPoint("LEFT",  row, "LEFT",  ANALYSIS_NAME_LEFT_INSET, 0)
        row.nameLabel:SetPoint("RIGHT", row, "RIGHT", -(ROW_PADDING + ANALYSIS_VALUE_WIDTH + 8), 0)
        row.nameLabel:SetJustifyH("LEFT")
        row.nameLabel:SetWordWrap(false)

        row.valueLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.valueLabel:SetPoint("RIGHT", row, "RIGHT", -ROW_PADDING, 0)
        row.valueLabel:SetWidth(ANALYSIS_VALUE_WIDTH)
        row.valueLabel:SetJustifyH("RIGHT")

        row:SetScript("OnEnter", function(self)
            self.bg:SetColorTexture(COLOR_HOVER.r, COLOR_HOVER.g, COLOR_HOVER.b, COLOR_HOVER.a)
        end)
        row:SetScript("OnLeave", function(self)
            local c = self._analysisBaseColor or COLOR_ROW_EVEN
            self.bg:SetColorTexture(c.r, c.g, c.b, c.a)
        end)
    end

    row:Show()
    return row
end

local function ReleaseAnalysisRow(row)
    row:Hide()
    row:SetAlpha(1.0)
    row:SetScript("OnClick", nil)
    row._analysisRowData = nil
    row._analysisBaseColor = nil
    row.icon:SetTexture(nil)
    row.icon:Hide()
    row.qualityOverlay:Hide()
    table.insert(analysisRowPool, row)
end

local function ReleaseAllAnalysisRows()
    for _, row in ipairs(activeAnalysisRows) do
        ReleaseAnalysisRow(row)
    end
    activeAnalysisRows = {}
end

-- ---------------------------------------------------------------------------
-- Processing Analysis detail-view line pool
-- ---------------------------------------------------------------------------

local function GetDetailLine()
    local line = table.remove(detailLinePool)
    if not line then
        line = CreateFrame("Frame", nil, contentFrame)
        line:SetHeight(DETAIL_LINE_HEIGHT)

        line.label = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        line.label:SetPoint("TOPLEFT",  line, "TOPLEFT",  ROW_PADDING, 0)
        line.label:SetPoint("TOPRIGHT", line, "TOPRIGHT", -ROW_PADDING, 0)
        line.label:SetJustifyH("LEFT")
        line.label:SetWordWrap(false)
    end
    line:Show()
    return line
end

local function ReleaseDetailLine(line)
    line:Hide()
    table.insert(detailLinePool, line)
end

local function ReleaseAllDetailLines()
    for _, line in ipairs(activeDetailLines) do
        ReleaseDetailLine(line)
    end
    activeDetailLines = {}
end

-- ---------------------------------------------------------------------------
-- Category headers
-- ---------------------------------------------------------------------------

local function CreateCategoryHeader(parent, text)
    local header = table.remove(headerPool)
    if not header then
        header = CreateFrame("Frame", nil, parent)
        header:SetHeight(HEADER_HEIGHT)

        header.bg = header:CreateTexture(nil, "BACKGROUND")
        header.bg:SetAllPoints()
        header.bg:SetColorTexture(COLOR_HEADER.r, COLOR_HEADER.g, COLOR_HEADER.b, 0.4)

        header.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header.label:SetAllPoints()
        header.label:SetJustifyH("LEFT")
        header.label:SetJustifyV("MIDDLE")
        header.label:SetPoint("LEFT", header, "LEFT", 6, 0)
    end
    header.label:SetText(text)
    header.label:SetTextColor(COLOR_HEADER.r + 0.2, COLOR_HEADER.g + 0.1, COLOR_HEADER.b, 1)

    header:Show()
    table.insert(activeHeaders, header)
    return header
end

local function ReleaseAllHeaders()
    for _, header in ipairs(activeHeaders) do
        header:Hide()
        header:ClearAllPoints()
        if header.rightLabel then
            header.rightLabel:SetText("")
            header.rightLabel:Hide()
        end
        table.insert(headerPool, header)
    end
    activeHeaders = {}
end

-- Dedicated Analysis list column header ("Input Option | Expected / Craft").
-- Deliberately NOT routed through CreateCategoryHeader/headerPool: that pool
-- is shared with Inventory mode's per-category headers, and this header's
-- left label needs a wider left inset (to line up with row icon + quality
-- badge + name) that must never leak onto a pooled frame later reused as a
-- plain Inventory category header. A single persistent singleton avoids that
-- cross-mode risk entirely.
local function GetAnalysisColumnHeader()
    if analysisColumnHeader then
        analysisColumnHeader:Show()
        return analysisColumnHeader
    end

    local header = CreateFrame("Frame", nil, contentFrame)
    header:SetHeight(HEADER_HEIGHT)

    header.bg = header:CreateTexture(nil, "BACKGROUND")
    header.bg:SetAllPoints()
    header.bg:SetColorTexture(COLOR_HEADER.r, COLOR_HEADER.g, COLOR_HEADER.b, 0.4)

    header.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header.label:SetPoint("LEFT", header, "LEFT", ANALYSIS_NAME_LEFT_INSET, 0)
    header.label:SetJustifyH("LEFT")
    header.label:SetJustifyV("MIDDLE")
    header.label:SetTextColor(COLOR_HEADER.r + 0.2, COLOR_HEADER.g + 0.1, COLOR_HEADER.b, 1)
    header.label:SetText("Input Option")

    header.rightLabel = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    header.rightLabel:SetPoint("RIGHT", header, "RIGHT", -ROW_PADDING, 0)
    header.rightLabel:SetWidth(ANALYSIS_VALUE_WIDTH)
    header.rightLabel:SetJustifyH("RIGHT")
    header.rightLabel:SetJustifyV("MIDDLE")
    header.rightLabel:SetTextColor(COLOR_HEADER.r + 0.2, COLOR_HEADER.g + 0.1, COLOR_HEADER.b, 1)
    header.rightLabel:SetText("Expected / Craft")

    analysisColumnHeader = header
    return header
end

local function ConfigureAnalysisColumnHeader(header, analysisResult)
    if not header then
        return
    end
    header.label:SetText("Input Option")
    if analysisResult and analysisResult.analysisMode == "unitAcquisitionCost" then
        header.rightLabel:SetText("Cost / Deriv.")
    else
        header.rightLabel:SetText("Expected / Craft")
    end
end

-- ---------------------------------------------------------------------------
-- Tooltip state helpers
-- ---------------------------------------------------------------------------

local function TooltipIsOwnedBy(row)
    if not row or not GameTooltip or not GameTooltip.IsOwned then return false end
    local ok, owned = pcall(function() return GameTooltip:IsOwned(row) end)
    return ok and owned
end

local function RowIsMouseOver(row)
    if not row or not row.IsMouseOver then return false end
    local ok, isMouseOver = pcall(function() return row:IsMouseOver() end)
    return ok and isMouseOver
end

local function FindActiveRowByConfigID(configID)
    if not configID then return nil end
    for _, row in ipairs(activeRows) do
        if row._craftQueueConfigID == configID and row.IsShown and row:IsShown() then
            return row
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function InventoryManagerWindow:GetFilterState()
    return { showZeroDeficit = showZeroDeficit, currentExpFilter = currentExpFilter }
end

function InventoryManagerWindow:GetFrame()
    return mainFrame
end

function InventoryManagerWindow:IsShown()
    return mainFrame ~= nil and mainFrame:IsShown()
end

function InventoryManagerWindow:ClearState()
    currentHighlightedConfigID       = nil
    self.activeTooltipState          = nil
end

function InventoryManagerWindow:SetScrollHighlightAfterRender(configID)
    scrollHighlightedAfterRender = configID
end

function InventoryManagerWindow:ScrollHighlightedRowIntoView()
    ScrollHighlightedRowIntoView()
end

function InventoryManagerWindow:ResetExpFilter()
    currentExpFilter = nil
    if MCGCFOExpFilterDropdown then
        UIDropDownMenu_SetText(MCGCFOExpFilterDropdown, "All Expansions")
    end
end

function InventoryManagerWindow:Show()
    if not mainFrame then return end
    if PocketCFO_Crafting.HelperWindow then
        PocketCFO_Crafting.HelperWindow:ShowOrRaise(mainFrame)
    else
        mainFrame:Show()
    end
end

function InventoryManagerWindow:Hide()
    if mainFrame then mainFrame:Hide() end
end

-- ---------------------------------------------------------------------------
-- Registered content modes (e.g. PocketCFO_Orders' Order Analysis) — an
-- orthogonal overlay on top of the existing Inventory/Analysis viewMode
-- toggle above. See PocketCFO_Orders MVP spec Part 8: Crafting owns the
-- shell (frame creation, position/size, show/hide, parenting, switching the
-- active mode); the registering addon owns everything rendered inside the
-- supplied content frame.
-- ---------------------------------------------------------------------------

--- Registers a content provider for modeName. provider must implement
-- OnActivate(contentFrame) and OnDeactivate(). Registration itself does not
-- activate the mode.
function InventoryManagerWindow:RegisterMode(modeName, provider)
    if type(modeName) ~= "string" or modeName == "" or type(provider) ~= "table" then
        return false, "invalidModeRegistration"
    end
    registeredModes[modeName] = provider
    return true
end

--- Returns the currently active registered mode name, or nil when the
-- window is showing its normal Inventory/Analysis content.
function InventoryManagerWindow:GetActiveMode()
    return activeModeName
end

local function GetProviderShellState(provider)
    if provider and type(provider.GetShellState) == "function" then
        local ok, state = pcall(provider.GetShellState, provider)
        if ok and type(state) == "table" then
            return state
        end
    end
    return {}
end

function InventoryManagerWindow:ApplyModeShellState(state)
    state = type(state) == "table" and state or {}

    self:SetTitle(state.title or "Inventory Manager")
    self:SetInventoryControlsVisible(state.inventoryControlsVisible == true)
    self:SetAnalysisInfoTooltip(nil)

    if analysisToggleBtn then analysisToggleBtn:Hide() end
    if analysisResultsToggleBtn then analysisResultsToggleBtn:Hide() end
    if analysisBackBtn then analysisBackBtn:Hide() end
    if analysisColumnHeader then analysisColumnHeader:Hide() end
    if analysisFooterNote then analysisFooterNote:Hide() end

    ApplyScrollFrameLayout(true)
end

function InventoryManagerWindow:RefreshActiveModeShell()
    if not activeModeName then
        return false
    end

    local provider = registeredModes[activeModeName]
    if scrollFrame then scrollFrame:Hide() end
    if modeContentFrame then modeContentFrame:Show() end
    self:ApplyModeShellState(GetProviderShellState(provider))
    return true
end

--- Switches the window to a registered mode: ensures the window is shown,
-- hides the normal scroll content, applies the provider's shell state, shows
-- the shared mode content frame, and hands it to the provider. A no-op if
-- the mode is already active.
function InventoryManagerWindow:ActivateMode(modeName)
    local provider = registeredModes[modeName]
    if not provider or not mainFrame or not modeContentFrame then
        return false, "modeUnavailable"
    end
    if activeModeName == modeName then
        self:RefreshActiveModeShell()
        return true
    end

    self:Show()

    if scrollFrame then scrollFrame:Hide() end
    self:ApplyModeShellState(GetProviderShellState(provider))

    activeModeName = modeName
    modeContentFrame:Show()

    if type(provider.OnActivate) == "function" then
        local ok, err = pcall(provider.OnActivate, provider, modeContentFrame)
        if not ok then
            PocketCFO:Debug("InventoryManagerWindow:ActivateMode(%s) OnActivate error: %s", tostring(modeName), tostring(err))
        end
    end

    return true
end

--- Leaves whatever registered mode is active (no-op if none is), restoring
-- the window's normal default Inventory chrome/content. Does not rebuild
-- Inventory row data itself - triggers the existing onRerender callback
-- (the same one dropdown/filter changes already use) so the controller's
-- existing data-refresh path repopulates it.
function InventoryManagerWindow:DeactivateMode()
    if not activeModeName then
        return
    end

    local provider = registeredModes[activeModeName]
    activeModeName = nil

    if provider and type(provider.OnDeactivate) == "function" then
        local ok, err = pcall(provider.OnDeactivate, provider)
        if not ok then
            PocketCFO:Debug("InventoryManagerWindow:DeactivateMode OnDeactivate error: %s", tostring(err))
        end
    end

    if modeContentFrame then modeContentFrame:Hide() end
    if scrollFrame then scrollFrame:Show() end
    self:SetInventoryControlsVisible(true)
    self:SetTitle("Inventory Manager")
    self:SetAnalysisInfoTooltip(nil)
    if analysisToggleBtn then analysisToggleBtn:Show() end
    ApplyScrollFrameLayout(false)

    if callbacks.onRerender then
        callbacks.onRerender()
    end
end

function InventoryManagerWindow:Position()
    if not mainFrame then return end
    local saved = PocketCFO.db.char.craftQueuePosition
    if saved and saved.x and saved.y then
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved.x, saved.y)
        PocketCFO:Debug("InventoryManagerWindow: restored position x=%.0f y=%.0f", saved.x, saved.y)
    else
        local profFrame = _G["ProfessionsFrame"]
        if profFrame then
            mainFrame:ClearAllPoints()
            mainFrame:SetPoint("TOPLEFT", profFrame, "TOPRIGHT", 4, -300)
        end
    end
end

function InventoryManagerWindow:UpdatePostingRulesButton()
    if not postingRulesBtn then return end
    local rulesWindow = PocketCFO_Crafting:GetModule("RecipePostingRulesWindow", true)
    postingRulesBtn:SetText(
        rulesWindow and rulesWindow:IsOpen() and "Hide Posting Rules" or "Show Posting Rules"
    )
end

function InventoryManagerWindow:UpdatePostingProfilesButton()
    if not postingProfilesBtn then return end
    local profilesWindow = PocketCFO_Crafting:GetModule("PostingProfilesWindow", true)
    postingProfilesBtn:SetText(
        profilesWindow and profilesWindow:IsOpen() and "Hide Posting Profiles" or "Open Posting Profiles"
    )
end

function InventoryManagerWindow:RefreshActiveTooltip()
    local state = self.activeTooltipState
    if not state or not mainFrame or not mainFrame:IsShown() then return end

    local row = FindActiveRowByConfigID(state.configID) or state.row
    if not row or not row.IsShown or not row:IsShown() then return end
    if row._craftQueueConfigID ~= state.configID then return end
    if not TooltipIsOwnedBy(row) and not RowIsMouseOver(row) then return end

    local result = row._craftQueueResult or state.result
    if not result or not result.config then return end

    state.row      = row
    state.result   = result
    state.itemName = row._craftQueueItemName or state.itemName
    state.charGUID = row._craftQueueCharGUID or state.charGUID

    local tooltipBuilder = PocketCFO_Crafting:GetModule("CraftTooltipBuilder", true)
    if tooltipBuilder then
        tooltipBuilder:ShowRowTooltip(row, result, state.itemName, state.charGUID)
    end
end

-- ---------------------------------------------------------------------------
-- Processing Analysis toggle + render (mode state is owned by
-- CraftQueueController - this window only displays whatever mode/result it
-- is told to show)
-- ---------------------------------------------------------------------------

-- Frame title is policy-driven in Analysis mode (see RenderAnalysis) - this
-- window never hardcodes a processing-type title itself.
function InventoryManagerWindow:SetTitle(text)
    if titleText then titleText:SetText(text or "Inventory Manager") end
end

function InventoryManagerWindow:SetAnalysisInfoTooltip(info)
    if not analysisInfoBtn then return end
    if type(info) ~= "table" or not info.text or info.text == "" then
        analysisInfoBtn._analysisInfoTooltip = nil
        analysisInfoBtn:Hide()
        return
    end
    analysisInfoBtn._analysisInfoTooltip = info
    analysisInfoBtn:Show()
end

-- Auction House beta toggle (PocketCFO/Infrastructure/BetaFeatures.lua).
-- Posting Rules/Profiles are AH features, so they stay hidden while it is off
-- even when the rest of the Inventory-only controls are showing.
local function IsAuctionHouseBetaEnabled()
    local beta = PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("BetaFeatures", true)
    return beta ~= nil and beta:IsAuctionHouseEnabled() == true
end

-- Expansion dropdown, Show All toggle, Posting Rules, Posting Profiles -
-- Inventory-only controls, hidden for both Analysis list and Analysis
-- detail modes.
function InventoryManagerWindow:SetInventoryControlsVisible(visible)
    if visible then
        local showPosting = IsAuctionHouseBetaEnabled()
        if expDropdown then expDropdown:Show() end
        if showAllBtn then showAllBtn:Show() end
        if postingRulesBtn then postingRulesBtn:SetShown(showPosting) end
        if postingProfilesBtn then postingProfilesBtn:SetShown(showPosting) end
    else
        if expDropdown then expDropdown:Hide() end
        if showAllBtn then showAllBtn:Hide() end
        if postingRulesBtn then postingRulesBtn:Hide() end
        if postingProfilesBtn then postingProfilesBtn:Hide() end
    end
end

function InventoryManagerWindow:SetAnalysisToggleVisible(visible)
    if not analysisToggleBtn then return end
    if visible then
        analysisToggleBtn:Show()
    else
        analysisToggleBtn:Hide()
    end
end

-- mode is the view currently being shown; the button label always offers
-- the *other* view, matching the existing "Show All"/"Deficits" toggle
-- convention in this file.
function InventoryManagerWindow:SetAnalysisToggleMode(mode)
    if not analysisToggleBtn then return end
    analysisToggleBtn:SetText(mode == "analysis" and "Show Inventory" or "Show Analysis")
end

-- Top Results/All Results toggle, shown only for Analysis results that
-- support grouped/ranked output families (currently Crushing) - owned and
-- gated entirely by CraftQueueController (see UpdateAnalysisResultsToggleUI);
-- this window just displays whatever visibility/mode it is told.
function InventoryManagerWindow:SetAnalysisResultsToggleVisible(visible)
    if not analysisResultsToggleBtn then return end
    if visible then
        analysisResultsToggleBtn:Show()
    else
        analysisResultsToggleBtn:Hide()
    end

    -- Temporary diagnostic for the "click never reaches onToggleAnalysisResults"
    -- investigation - full physical/hit-test state of the button every time
    -- its visibility is set, so a hidden showAllBtn (or any other sibling)
    -- occupying the SAME rect can be ruled in or out by comparing frame
    -- levels/points directly, not by assumption.
    --
    -- Calls PocketCFO:AppendSessionLog directly (NOT the local SessionLog
    -- helper below) - this function runs before that local function's
    -- declaration later in the file, and Lua locals are not visible above
    -- their own declaration; referencing it here would silently resolve to
    -- an undefined global and error at runtime.
    if PocketCFO and PocketCFO.AppendSessionLog then
        local point, relTo, relPoint, x, y = analysisResultsToggleBtn:GetPoint(1)
        PocketCFO:AppendSessionLog(string.format(
            "[MCG] InventoryManagerWindow:SetAnalysisResultsToggleVisible: DIAG visible=%s shown=%s enabled=%s isMouseEnabled=%s frameLevel=%s frameStrata=%s point=%s relTo=%s relPoint=%s x=%s y=%s showAllBtnShown=%s",
            tostring(visible), tostring(analysisResultsToggleBtn:IsShown()),
            tostring(analysisResultsToggleBtn.IsEnabled and analysisResultsToggleBtn:IsEnabled()),
            tostring(analysisResultsToggleBtn.IsMouseEnabled and analysisResultsToggleBtn:IsMouseEnabled()),
            tostring(analysisResultsToggleBtn:GetFrameLevel()), tostring(analysisResultsToggleBtn:GetFrameStrata()),
            tostring(point), tostring(relTo and (relTo.GetName and relTo:GetName() or tostring(relTo))),
            tostring(relPoint), tostring(x), tostring(y),
            tostring(showAllBtn and showAllBtn:IsShown())))
    end
    do
        local point, relTo, relPoint, x, y = analysisResultsToggleBtn:GetPoint(1)
        TraceProcessingAnalysisUI("SetAnalysisResultsToggleVisible",
            "visible=%s shown=%s enabled=%s isMouseEnabled=%s frameLevel=%s frameStrata=%s point=%s relTo=%s relPoint=%s x=%s y=%s showAllBtnShown=%s",
            tostring(visible), tostring(analysisResultsToggleBtn:IsShown()),
            tostring(analysisResultsToggleBtn.IsEnabled and analysisResultsToggleBtn:IsEnabled()),
            tostring(analysisResultsToggleBtn.IsMouseEnabled and analysisResultsToggleBtn:IsMouseEnabled()),
            tostring(analysisResultsToggleBtn:GetFrameLevel()), tostring(analysisResultsToggleBtn:GetFrameStrata()),
            tostring(point), tostring(relTo and (relTo.GetName and relTo:GetName() or tostring(relTo))),
            tostring(relPoint), tostring(x), tostring(y),
            tostring(showAllBtn and showAllBtn:IsShown()))
    end
end

-- showingAllResults reflects the mode currently being shown; the button
-- label always offers the *other* mode, matching SetAnalysisToggleMode's
-- convention above. Short labels ("Show All"/"Show Top") - this button
-- sits in the same compact header row as "Show Analysis"/"Show Inventory",
-- not room for the longer "...Results" wording.
function InventoryManagerWindow:SetAnalysisResultsToggleMode(showingAllResults)
    if not analysisResultsToggleBtn then return end
    analysisResultsToggleBtn:SetText(showingAllResults and "Show Top" or "Show All")
end

-- Resolves an item icon texture for one analysis row. Prefers icon data the
-- row already carries (iconID/itemLink), falling back to a live itemID
-- lookup via standard WoW item APIs. Never fabricates a placeholder - a row
-- whose icon can't be resolved simply renders with no icon.
local function ResolveAnalysisRowIcon(row)
    if not row then return nil end
    if row.iconID then return row.iconID end
    if row.itemLink and GetItemIcon then
        local ok, icon = pcall(GetItemIcon, row.itemLink)
        if ok and icon then return icon end
    end
    local itemID = row.itemID
    if not itemID then return nil end
    if C_Item and C_Item.GetItemIconByID then
        local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
        if ok and icon then return icon end
    end
    if GetItemIcon then
        local ok, icon = pcall(GetItemIcon, itemID)
        if ok and icon then return icon end
    end
    return nil
end

-- Temporary diagnostics for the "quality overlay disappeared" investigation.
-- Remove once the fix is confirmed working in-game.
local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

-- Blizzard embeds a "|A:AtlasName:h:w...|a" escape sequence directly inside
-- a crafted/reagent-quality item's own hyperlink text whenever that item has
-- a crafting-quality tier - the exact same markup Blizzard's own chat links
-- and tooltips render for that item. Extracting and reusing it verbatim
-- means PocketCFO never has to know or hardcode the atlas name itself, and
-- automatically follows whatever icon set any future expansion introduces
-- (e.g. Midnight's silver diamond/gold pentagon vs Dragonflight/TWW's
-- tier-star icons) with no expansion-specific logic here.
--
-- Confirmed by reading TradeSkillMaster's ItemInfo.lua (a mature, widely
-- used addon), which parses this same "|A:Professions-ChatIcon-Quality..." -
-- Tier N|a" token out of GetItemInfo's link return value to detect crafted
-- quality. The atlas markup commonly carries extra colon-separated size
-- parameters before the closing "|a" (e.g. "|A:name:12:12|a") - matching
-- only up to the next ":" or "|" (rather than requiring "|a" immediately
-- after the name) avoids silently failing to match those.
local function ExtractQualityAtlasFromLink(itemLink)
    if not itemLink then return nil end
    local atlasName = itemLink:match("|A:([^:|]+)")
    if atlasName and atlasName ~= "" and atlasName:find("Quality", 1, true) then
        return atlasName
    end
    return nil
end

-- Derives an item hyperlink from a bare itemID via standard WoW item APIs -
-- used only as the fallback when the row has no observed link of its own.
local function DeriveItemLinkFromItemID(itemID)
    if not itemID then return nil end
    if C_Item and C_Item.GetItemInfo then
        local ok, _, link = pcall(C_Item.GetItemInfo, itemID)
        if ok and link then return link end
    end
    if GetItemInfo then
        local ok, _, link = pcall(GetItemInfo, itemID)
        if ok and link then return link end
    end
    return nil
end

-- Applies Blizzard's own crafting-quality atlas marker (extracted from an
-- item hyperlink, never guessed or hardcoded) to one row's icon-corner
-- overlay texture. Two sources are tried, in order:
--   1. The row's own observed itemLink (captured from the real item
--      instance at craft-completion time) - preferred, since a freshly
--      rebuilt itemID-only link does not always carry the same
--      quality-specific markup.
--   2. A live itemID lookup (the same Blizzard reagent-quality-aware item
--      data IdentityAdapters:GetReagentCraftingQuality already reads the
--      quality tier from).
-- Never renders a fabricated text substitute: if the row has no quality
-- tier, or neither source yields an atlas token, the overlay simply stays
-- hidden - the plain item icon renders on its own, unaffected either way.
local function ApplyQualityOverlay(overlay, row)
    local itemID       = row and row.itemID
    local quality      = row and tonumber(row.quality)
    local hasRowLink   = row and row.itemLink ~= nil

    if not quality or quality <= 0 then
        SessionLog("ProspectingAnalysis quality overlay: itemID=%s itemName=%s quality=%s rowHasItemLink=%s overlayState=hidden reason=noQualityTier",
            tostring(itemID), tostring(row and row.itemLabel), tostring(row and row.quality), tostring(hasRowLink))
        overlay:Hide()
        return
    end

    local atlasName, resolvedLink, source

    if hasRowLink then
        atlasName = ExtractQualityAtlasFromLink(row.itemLink)
        resolvedLink = row.itemLink
        source = "observedItemLink"
    end

    if not atlasName then
        local derivedLink = DeriveItemLinkFromItemID(itemID)
        if derivedLink then
            local derivedAtlas = ExtractQualityAtlasFromLink(derivedLink)
            if derivedAtlas then
                atlasName = derivedAtlas
                resolvedLink = derivedLink
                source = "itemIDLookup"
            end
        end
    end

    SessionLog("ProspectingAnalysis quality overlay: itemID=%s itemName=%s quality=%s rowHasItemLink=%s resolvedItemLink=%s atlasName=%s source=%s overlayState=%s",
        tostring(itemID), tostring(row.itemLabel), tostring(row.quality), tostring(hasRowLink),
        tostring(resolvedLink), tostring(atlasName), tostring(source), tostring(atlasName ~= nil))

    if not atlasName then
        overlay:Hide()
        return
    end

    local ok = pcall(overlay.SetAtlas, overlay, atlasName, false)
    if ok then
        overlay:Show()
    else
        SessionLog("ProspectingAnalysis quality overlay: itemID=%s SetAtlas failed atlasName=%s", tostring(itemID), tostring(atlasName))
        overlay:Hide()
    end
end

-- ---------------------------------------------------------------------------
-- Render (Analysis list mode) — lays out ProcessingAnalysisController's
-- already-built, already-sorted display-model rows as a single "Input
-- Option | Expected / Craft" column. Reads only documented display model
-- fields (itemLabel, itemID, quality, expectedPerCraft, valueUnavailableReason,
-- statusColor, statusKind) - no economics, no policy, no recipe lookups, and
-- no sorting happen here.
-- ---------------------------------------------------------------------------

function InventoryManagerWindow:RenderAnalysis(analysisResult)
    local startedAt = DebugTime()
    if not mainFrame or not mainFrame:IsShown() then return end
    if self:RefreshActiveModeShell() then return end
    HideRecipeAnalysisFrame()

    self:SetTitle((analysisResult and analysisResult.label) or "Processing Analysis")
    self:SetInventoryControlsVisible(false)
    self:SetAnalysisInfoTooltip(analysisResult and analysisResult.analysisInfoTooltip)
    if analysisBackBtn then analysisBackBtn:Hide() end
    ApplyScrollFrameLayout(true)
    -- Starter-data label replaces the default footer while any row shown is
    -- built from published starter data instead of the user's own crafts.
    GetAnalysisFooterNote():SetText((analysisResult and analysisResult.seedDataNote) or ANALYSIS_FOOTER_DEFAULT_TEXT)
    GetAnalysisFooterNote():Show()

    ReleaseAllRows()
    ReleaseAllHeaders()
    ReleaseAllAnalysisRows()
    ReleaseAllDetailLines()

    -- First-run guidance: until one full price scan has finished, show how
    -- to get prices instead of rows of N/A. Missing Valuation addon is
    -- treated as "scanned" so this can never block the window.
    local valuation = _G.PocketCFO_Valuation
    if valuation and valuation.HasCompletedPriceScan and not valuation:HasCompletedPriceScan() then
        GetAnalysisFooterNote():Hide()
        if analysisColumnHeader then analysisColumnHeader:Hide() end
        if not emptyLabel then
            emptyLabel = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            emptyLabel:SetPoint("CENTER", contentFrame, "CENTER", 0, 0)
        end
        emptyLabel:SetWidth(math.max(160, (contentFrame:GetWidth() or 300) - 24))
        emptyLabel:SetText(valuation.NO_SCAN_MESSAGE or "No prices yet.")
        emptyLabel:Show()
        contentFrame:SetHeight(80)
        UpdateScrollbarVisibility()
        return
    end

    local rows = (analysisResult and analysisResult.rows) or {}

    -- Temporary diagnostic for the "toggle doesn't change rendered rows"
    -- investigation - confirms what this render call actually received
    -- from CraftQueueController, independent of what was requested.
    do
        local countByFamily, familyLogOrder = {}, {}
        for _, row in ipairs(rows) do
            local key = row.outputFamilyKey or "(ungrouped)"
            if not countByFamily[key] then
                countByFamily[key] = 0
                familyLogOrder[#familyLogOrder + 1] = key
            end
            countByFamily[key] = countByFamily[key] + 1
        end
        local familyParts = {}
        for _, key in ipairs(familyLogOrder) do
            familyParts[#familyParts + 1] = string.format("%s=%d", key, countByFamily[key])
        end
        SessionLog("InventoryManagerWindow:RenderAnalysis: DIAG ENTRY rowsReceived=%d perFamily=%s resultTable=%s",
            #rows, #familyParts > 0 and table.concat(familyParts, ",") or "(none)", tostring(analysisResult))
        TraceProcessingAnalysisUI("RenderAnalysis.entry",
            "rowsReceived=%d perFamily=%s resultTable=%s",
            #rows, #familyParts > 0 and table.concat(familyParts, ",") or "(none)", tostring(analysisResult))
    end

    local yOffset     = -(ROW_PADDING + 12)
    local totalHeight = 0

    local columnHeader = GetAnalysisColumnHeader()
    ConfigureAnalysisColumnHeader(columnHeader, analysisResult)
    columnHeader:SetPoint("TOPLEFT",  contentFrame, "TOPLEFT",  0, yOffset)
    columnHeader:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, yOffset)
    yOffset     = yOffset - HEADER_HEIGHT
    totalHeight = totalHeight + HEADER_HEIGHT

    if #rows == 0 then
        if not emptyLabel then
            emptyLabel = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            emptyLabel:SetPoint("CENTER", contentFrame, "CENTER", 0, 0)
        end
        emptyLabel:SetText((analysisResult and analysisResult.emptyMessage) or "No processing analysis rows available.")
        emptyLabel:Show()
        contentFrame:SetHeight(math.max(80, totalHeight + 40))
        UpdateScrollbarVisibility()
        LogTiming("InventoryManagerWindow:RenderAnalysis", startedAt, "rows=0")
        return
    end

    if emptyLabel then emptyLabel:Hide() end

    -- DIAG counter: incremented once per RenderAnalysisRow call, independent
    -- of #activeAnalysisRows (the widget-pool count) - if these two ever
    -- diverge, GetAnalysisRow() is silently failing to return a usable
    -- frame for some rows rather than the family/toggle logic dropping them.
    local rowsIteratedCount = 0

    local function RenderAnalysisRow(row)
        rowsIteratedCount = rowsIteratedCount + 1
        local rowFrame = GetAnalysisRow()
        rowFrame:SetPoint("TOPLEFT",  contentFrame, "TOPLEFT",  0, yOffset)
        rowFrame:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, yOffset)

        local color = STATUS_COLOR_BY_NAME[row.statusColor] or COLOR_GREY
        local muted = (row.statusKind == "unavailable" or row.statusKind == "lowConfidence")

        local iconTexture = ResolveAnalysisRowIcon(row)
        if iconTexture then
            rowFrame.icon:SetTexture(iconTexture)
            rowFrame.icon:Show()
        else
            rowFrame.icon:SetTexture(nil)
            rowFrame.icon:Hide()
        end

        ApplyQualityOverlay(rowFrame.qualityOverlay, row)

        rowFrame.nameLabel:SetText(row.itemLabel or "Unknown")
        rowFrame.nameLabel:SetTextColor(1, 1, 1, 1)

        if row.expectedPerCraft ~= nil then
            if row.analysisMode == "unitAcquisitionCost" then
                rowFrame.valueLabel:SetText(FormatAnalysisValue(row.expectedPerCraft))
            else
                rowFrame.valueLabel:SetText(FormatSignedGold(row.expectedPerCraft))
            end
            rowFrame.valueLabel:SetTextColor(color.r, color.g, color.b, 1)
        else
            rowFrame.valueLabel:SetText(VALUE_UNAVAILABLE_TEXT[row.valueUnavailableReason] or "N/A")
            rowFrame.valueLabel:SetTextColor(COLOR_GREY.r, COLOR_GREY.g, COLOR_GREY.b, 1)
        end

        rowFrame:SetAlpha(muted and 0.65 or 1.0)
        rowFrame._analysisRowData = row
        rowFrame._analysisBaseColor = (#activeAnalysisRows % 2 == 0) and COLOR_ROW_EVEN or COLOR_ROW_ODD
        rowFrame.bg:SetColorTexture(rowFrame._analysisBaseColor.r, rowFrame._analysisBaseColor.g, rowFrame._analysisBaseColor.b, rowFrame._analysisBaseColor.a)
        rowFrame:SetScript("OnClick", function(self)
            if callbacks.onSelectAnalysisRow then
                callbacks.onSelectAnalysisRow(self._analysisRowData)
            end
        end)

        table.insert(activeAnalysisRows, rowFrame)
        yOffset     = yOffset - ANALYSIS_ROW_HEIGHT - 1
        totalHeight = totalHeight + ANALYSIS_ROW_HEIGHT + 1
    end

    -- Optional grouping: rows tagged with outputFamilyKey/outputFamilyLabel
    -- (e.g. Crushing's quality-tier recommendation groups) render under a
    -- section header per family, in first-seen order. Rows with no
    -- outputFamilyKey (every other processing type) render as the original
    -- flat list - grouping here is purely a layout concern; family
    -- membership and ranking already happened in
    -- ProcessingRecommendationPolicy, not in this window.
    local groupOrder, rowsByGroup = {}, {}
    for _, row in ipairs(rows) do
        local key = row.outputFamilyKey
        if key then
            if not rowsByGroup[key] then
                rowsByGroup[key] = { label = row.outputFamilyLabel or key, rows = {} }
                groupOrder[#groupOrder + 1] = key
            end
            table.insert(rowsByGroup[key].rows, row)
        end
    end

    -- DIAG: which branch this render actually took, and (for the grouped
    -- branch) exactly how many rows landed in each group's OWN rows table
    -- before any widget is created - if this already shows only 3 rows in
    -- one group, the loss happened upstream of this function entirely
    -- (contradicting the rowsReceived/perFamily ENTRY log above would mean
    -- the bug is between ENTRY and here, inside this grouping loop itself).
    local renderBranch = (#groupOrder > 0) and "grouped" or "flat"
    do
        local groupSizeParts = {}
        for _, key in ipairs(groupOrder) do
            groupSizeParts[#groupSizeParts + 1] = string.format("%s=%d", key, #rowsByGroup[key].rows)
        end
        SessionLog("InventoryManagerWindow:RenderAnalysis: DIAG branch=%s groupCount=%d groupSizes=%s",
            renderBranch, #groupOrder, #groupSizeParts > 0 and table.concat(groupSizeParts, ",") or "(none)")
        TraceProcessingAnalysisUI("RenderAnalysis.branch",
            "branch=%s groupCount=%d groupSizes=%s",
            renderBranch, #groupOrder, #groupSizeParts > 0 and table.concat(groupSizeParts, ",") or "(none)")
    end

    if #groupOrder > 0 then
        for _, key in ipairs(groupOrder) do
            local group = rowsByGroup[key]
            local header = CreateCategoryHeader(contentFrame, group.label)
            header:SetPoint("TOPLEFT",  contentFrame, "TOPLEFT",  0, yOffset)
            header:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, yOffset)
            yOffset     = yOffset - HEADER_HEIGHT
            totalHeight = totalHeight + HEADER_HEIGHT

            for _, row in ipairs(group.rows) do
                RenderAnalysisRow(row)
            end
        end
    else
        for _, row in ipairs(rows) do
            RenderAnalysisRow(row)
        end
    end

    contentFrame:SetHeight(totalHeight + ROW_PADDING * 2)
    UpdateScrollbarVisibility()

    -- Temporary diagnostic for the "rows below the third entry might be
    -- created but unreachable" investigation - confirms actual widget
    -- counts, final content height, and viewport height, so a truncated
    -- scroll RANGE (vs. a truncated ROW SET, already covered by the
    -- rowsReceived DIAG above) can be ruled in or out empirically.
    do
        local contentHeight  = (contentFrame and contentFrame.GetHeight and contentFrame:GetHeight()) or -1
        local viewportHeight = (scrollFrame and scrollFrame.GetHeight and scrollFrame:GetHeight()) or -1
        SessionLog("InventoryManagerWindow:RenderAnalysis: DIAG EXIT branch=%s rowsIterated=%d headerWidgets=%d rowWidgetsShown=%d contentHeight=%.0f viewportHeight=%.0f scrollRange=%.0f",
            renderBranch, rowsIteratedCount, #groupOrder, #activeAnalysisRows, contentHeight, viewportHeight, contentHeight - viewportHeight)
        TraceProcessingAnalysisUI("RenderAnalysis.exit",
            "branch=%s rowsIterated=%d headerWidgets=%d rowWidgetsShown=%d contentHeight=%.0f viewportHeight=%.0f scrollRange=%.0f",
            renderBranch, rowsIteratedCount, #groupOrder, #activeAnalysisRows, contentHeight, viewportHeight, contentHeight - viewportHeight)
    end

    LogTiming("InventoryManagerWindow:RenderAnalysis", startedAt, string.format("rows=%d groups=%d", #rows, #groupOrder))
end

-- ---------------------------------------------------------------------------
-- Render (Analysis loading) — brief placeholder CraftQueueController shows
-- the first time Analysis mode opens each crafting-window session, while it
-- waits for item/pricing data to have a chance to resolve before evaluating
-- for real. Reuses the same centered emptyLabel widget as RenderAnalysis's
-- "no rows" state. Owns no timing/retry logic - that's CraftQueueController's.
-- ---------------------------------------------------------------------------

function InventoryManagerWindow:RenderAnalysisLoading(analysisResult)
    local startedAt = DebugTime()
    if not mainFrame or not mainFrame:IsShown() then return end
    if self:RefreshActiveModeShell() then return end
    HideRecipeAnalysisFrame()

    self:SetTitle((analysisResult and analysisResult.label) or "Processing Analysis")
    self:SetInventoryControlsVisible(false)
    self:SetAnalysisInfoTooltip(analysisResult and analysisResult.analysisInfoTooltip)
    if analysisBackBtn then analysisBackBtn:Hide() end
    ApplyScrollFrameLayout(true)
    GetAnalysisFooterNote():Hide()
    if analysisColumnHeader then analysisColumnHeader:Hide() end

    ReleaseAllRows()
    ReleaseAllHeaders()
    ReleaseAllAnalysisRows()
    ReleaseAllDetailLines()

    if not emptyLabel then
        emptyLabel = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        emptyLabel:SetPoint("CENTER", contentFrame, "CENTER", 0, 0)
    end
    emptyLabel:SetText("Loading analysis...")
    emptyLabel:Show()

    contentFrame:SetHeight(80)
    UpdateScrollbarVisibility()
    LogTiming("InventoryManagerWindow:RenderAnalysisLoading", startedAt, "")
end

-- ---------------------------------------------------------------------------
-- Render (Live Recipe Analysis) — shows RecipeAnalysisController's display
-- model (Order Analysis-style breakdown) using RecipeAnalysisContent. Pure
-- rendering: no economics here.
-- ---------------------------------------------------------------------------

function InventoryManagerWindow:RenderRecipeAnalysis(analysisResult)
    local startedAt = DebugTime()
    if not mainFrame or not mainFrame:IsShown() then return end
    if self:RefreshActiveModeShell() then return end

    self:SetTitle((analysisResult and analysisResult.label) or "Recipe Analysis")
    self:SetInventoryControlsVisible(false)
    self:SetAnalysisInfoTooltip(nil)
    if analysisBackBtn then analysisBackBtn:Hide() end
    ApplyScrollFrameLayout(true)
    GetAnalysisFooterNote():Hide()
    if analysisColumnHeader then analysisColumnHeader:Hide() end
    if emptyLabel then emptyLabel:Hide() end

    ReleaseAllRows()
    ReleaseAllHeaders()
    ReleaseAllAnalysisRows()
    ReleaseAllDetailLines()

    if not recipeAnalysisFrame then
        recipeAnalysisFrame = CreateFrame("Frame", nil, contentFrame)
        recipeAnalysisFrame:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", 0, 0)
        recipeAnalysisFrame:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, 0)
        recipeAnalysisFrame:SetHeight(120)
    end
    recipeAnalysisFrame:Show()

    local content = PocketCFO_Crafting.RecipeAnalysisContent
    if content then
        content:Build(recipeAnalysisFrame)
        content:Render(analysisResult and analysisResult.displayModel)
    end

    contentFrame:SetHeight(recipeAnalysisFrame:GetHeight() or 120)
    UpdateScrollbarVisibility()
    LogTiming("InventoryManagerWindow:RenderRecipeAnalysis", startedAt, "")
end

-- ---------------------------------------------------------------------------
-- Render (Analysis unavailable) — shown when the Inventory Manager beta is
-- off and the selected recipe has no analysis, so there is nothing else to
-- show. Same centered emptyLabel as RenderAnalysisLoading.
-- ---------------------------------------------------------------------------

function InventoryManagerWindow:RenderAnalysisUnavailable()
    local startedAt = DebugTime()
    if not mainFrame or not mainFrame:IsShown() then return end
    if self:RefreshActiveModeShell() then return end
    HideRecipeAnalysisFrame()

    self:SetTitle("Recipe Analysis")
    self:SetInventoryControlsVisible(false)
    self:SetAnalysisInfoTooltip(nil)
    if analysisBackBtn then analysisBackBtn:Hide() end
    ApplyScrollFrameLayout(true)
    GetAnalysisFooterNote():Hide()
    if analysisColumnHeader then analysisColumnHeader:Hide() end

    ReleaseAllRows()
    ReleaseAllHeaders()
    ReleaseAllAnalysisRows()
    ReleaseAllDetailLines()

    if not emptyLabel then
        emptyLabel = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        emptyLabel:SetPoint("CENTER", contentFrame, "CENTER", 0, 0)
    end
    emptyLabel:SetText("No analysis for this recipe yet.")
    emptyLabel:Show()

    contentFrame:SetHeight(80)
    UpdateScrollbarVisibility()
    LogTiming("InventoryManagerWindow:RenderAnalysisUnavailable", startedAt, "")
end

-- ---------------------------------------------------------------------------
-- Render (Analysis detail mode) — compact breakdown of one already-built
-- ProcessingAnalysisController detail view model (as returned by
-- ProcessingAnalysisController:BuildDetailViewModel). Pure formatting: every
-- number displayed here already exists on the model, this function just
-- turns it into text/color.
-- ---------------------------------------------------------------------------

local function AddDetailLine(yOffset, totalHeight, text, color)
    local line = GetDetailLine()
    line:SetPoint("TOPLEFT",  contentFrame, "TOPLEFT",  0, yOffset)
    line:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, yOffset)
    line.label:SetText(text or "")
    if color then
        line.label:SetTextColor(color.r, color.g, color.b, 1)
    else
        line.label:SetTextColor(1, 1, 1, 1)
    end
    table.insert(activeDetailLines, line)
    return yOffset - DETAIL_LINE_HEIGHT, totalHeight + DETAIL_LINE_HEIGHT
end

local function AddDetailItemLines(yOffset, totalHeight, sectionLabel, itemRows)
    yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, sectionLabel, COLOR_HEADER)
    if type(itemRows) ~= "table" or #itemRows == 0 then
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "  (none)", COLOR_GREY)
        return yOffset, totalHeight
    end
    for _, item in ipairs(itemRows) do
        local qty = tonumber(item.quantityPerRun) or 0
        local text
        if item.unresolved then
            text = string.format("  %.2fx %s - Needs Price", qty, item.itemName or "Unknown")
        elseif item.countedAsFree then
            text = string.format("  %.2fx %s - No price (counted as free)", qty, item.itemName or "Unknown")
        else
            text = string.format("  %.2fx %s = %s", qty, item.itemName or "Unknown", FormatAnalysisValue(item.lineValue))
        end
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, text)
    end
    return yOffset, totalHeight
end

function InventoryManagerWindow:RenderAnalysisDetail(detailModel, analysisResult)
    local startedAt = DebugTime()
    if not mainFrame or not mainFrame:IsShown() then return end
    if self:RefreshActiveModeShell() then return end
    HideRecipeAnalysisFrame()

    self:SetTitle((analysisResult and analysisResult.label) or "Processing Analysis")
    self:SetInventoryControlsVisible(false)
    self:SetAnalysisInfoTooltip(analysisResult and analysisResult.analysisInfoTooltip)
    if analysisBackBtn then analysisBackBtn:Show() end
    ApplyScrollFrameLayout(false)
    if analysisColumnHeader then analysisColumnHeader:Hide() end
    if analysisFooterNote then analysisFooterNote:Hide() end

    ReleaseAllRows()
    ReleaseAllHeaders()
    ReleaseAllAnalysisRows()
    ReleaseAllDetailLines()

    if emptyLabel then emptyLabel:Hide() end

    local yOffset     = -(ROW_PADDING + 12)
    local totalHeight = 0

    if not detailModel then
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "Detail unavailable.", COLOR_GREY)
        contentFrame:SetHeight(math.max(80, totalHeight + 40))
        UpdateScrollbarVisibility()
        LogTiming("InventoryManagerWindow:RenderAnalysisDetail", startedAt, "detail=nil")
        return
    end

    local color = STATUS_COLOR_BY_NAME[detailModel.statusColor] or COLOR_GREY

    yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, detailModel.itemLabel or "Unknown", color)
    yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "")

    -- Historical Operation Cost: preserved historical average cost of
    -- completed operations. Informational only - never drives Expected
    -- / Craft or Expected ROI % below, which are always current-cost-based.
    yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
        "Historical Operation Cost: " .. FormatAnalysisValue(detailModel.historicalOperationCost), COLOR_GREY)
    yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
        "Current Input Cost: " .. FormatAnalysisValue(detailModel.currentInputCost))
    if detailModel.analysisMode == "unitAcquisitionCost" then
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
            "Expected Derivates: " .. FormatAnalysisQuantity(detailModel.expectedUnitOutputQuantity))
    else
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
            "Expected Output Value: " .. FormatAnalysisValue(detailModel.expectedOutputValue))
    end
    yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
        "Expected Resourcefulness Value: " .. FormatAnalysisValue(detailModel.expectedResourcefulnessValue))
    if detailModel.analysisMode ~= "unitAcquisitionCost" then
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
            "Expected Total Value: " .. FormatAnalysisValue(detailModel.expectedTotalValue))
    end

    if detailModel.expectedPerCraft ~= nil then
        if detailModel.analysisMode == "unitAcquisitionCost" then
            yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
                "Cost / Derivate: " .. FormatAnalysisValue(detailModel.expectedPerCraft), color)
            yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
                "Historical Cost / Derivate: " .. FormatAnalysisValue(detailModel.historicalCostPerUnitOutput), COLOR_GREY)
        else
            yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
                "Expected / Craft: " .. FormatSignedGold(detailModel.expectedPerCraft), color)
            yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
                "Expected ROI %: " .. FormatROIPercent(detailModel.expectedROIPercent), color)
        end
    else
        local unavailableText = VALUE_UNAVAILABLE_TEXT[detailModel.valueUnavailableReason] or "N/A"
        if detailModel.analysisMode == "unitAcquisitionCost" then
            yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "Cost / Derivate: " .. unavailableText, COLOR_GREY)
        else
            yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "Expected / Craft: " .. unavailableText, COLOR_GREY)
            yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "Expected ROI %: " .. unavailableText, COLOR_GREY)
        end
    end

    yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
        "Runs Observed: " .. tostring(detailModel.observationCount or 0))

    if detailModel.seedDataNote then
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, detailModel.seedDataNote, COLOR_GREY)
    end

    -- Craft Analysis only: row.craftProduction is set exclusively by
    -- CraftAnalysisDisplayModelBuilder:BuildDetailRow - a Processing
    -- Analysis detail model never carries this field (processing operations
    -- do not support multicraft), so this section never renders for
    -- Prospecting/Crushing/Milling.
    if detailModel.craftProduction then
        local cp = detailModel.craftProduction
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "")
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "Craft Production:", COLOR_HEADER)
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
            "  Average Base Output / Craft: " .. FormatAnalysisQuantity(cp.averageBaseOutputPerCraft))
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
            "  Multicraft Proc Rate: " .. FormatAnalysisPercent(cp.multicraftProcRate))
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
            "  Average Multicraft Bonus / Proc: " .. FormatAnalysisQuantity(cp.averageMulticraftBonusPerProc))
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
            "  Average Total Output When Multicraft Procs: " .. FormatAnalysisQuantity(cp.averageTotalOutputWhenMulticraftProcs))
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
            "  Average Multicraft Bonus / Craft: " .. FormatAnalysisQuantity(cp.averageMulticraftBonusPerCraft))
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight,
            "  Average Total Output / Craft: " .. FormatAnalysisQuantity(cp.averageTotalOutputPerCraft))
    end

    if detailModel.note and detailModel.note ~= "" then
        yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, detailModel.note, COLOR_GREY)
    end

    yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "")
    yOffset, totalHeight = AddDetailItemLines(yOffset, totalHeight, "Expected Outputs:", detailModel.outputs)
    yOffset, totalHeight = AddDetailLine(yOffset, totalHeight, "")
    yOffset, totalHeight = AddDetailItemLines(yOffset, totalHeight, "Expected Resourcefulness Returns:", detailModel.resourcefulnessReturns)

    contentFrame:SetHeight(totalHeight + ROW_PADDING * 2)
    UpdateScrollbarVisibility()
    LogTiming("InventoryManagerWindow:RenderAnalysisDetail", startedAt, "ok")
end

-- ---------------------------------------------------------------------------
-- Frame construction (called once; subsequent calls are no-ops)
-- ---------------------------------------------------------------------------

function InventoryManagerWindow:Build(cbs)
    callbacks = cbs or {}
    if mainFrame then return end

    mainFrame = CreateFrame("Frame", "MCGCFOCraftQueueFrame", UIParent, "BackdropTemplate")
    mainFrame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    if PocketCFO_Crafting.HelperWindow then
        PocketCFO_Crafting.HelperWindow:Configure(mainFrame)
    else
        mainFrame:SetFrameStrata("HIGH")
    end
    mainFrame:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    mainFrame:SetBackdropColor(COLOR_BG.r, COLOR_BG.g, COLOR_BG.b, COLOR_BG.a)
    mainFrame:SetBackdropBorderColor(0.4, 0.35, 0.25, 0.9)

    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:RegisterForDrag("LeftButton")
    mainFrame:SetScript("OnDragStart", mainFrame.StartMoving)
    mainFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x = self:GetLeft()
        local y = self:GetTop()
        if x and y then
            PocketCFO.db.char.craftQueuePosition = { x = x, y = y }
            PocketCFO:Debug("InventoryManagerWindow: saved position x=%.0f y=%.0f", x, y)
        end
    end)
    mainFrame:SetClampedToScreen(true)
    mainFrame:SetScript("OnHide", function()
        currentHighlightedConfigID              = nil
        InventoryManagerWindow.activeTooltipState = nil
    end)
    mainFrame:Hide()

    -- Title bar
    titleText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOPLEFT",  mainFrame, "TOPLEFT",  8, -8)
    titleText:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -8, -8)
    titleText:SetJustifyH("LEFT")
    titleText:SetText("Inventory Manager")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -6, -6)
    closeBtn:SetScript("OnClick", function()
        if mainFrame then
            InventoryManagerWindow.activeTooltipState = nil
            GameTooltip:Hide()
            mainFrame:Hide()
        end
    end)

    analysisInfoBtn = CreateFrame("Button", nil, mainFrame)
    analysisInfoBtn:SetSize(16, 16)
    analysisInfoBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -13, -34)
    analysisInfoBtn:SetFrameLevel(closeBtn:GetFrameLevel())
    analysisInfoBtn.icon = analysisInfoBtn:CreateTexture(nil, "ARTWORK")
    analysisInfoBtn.icon:SetAllPoints()
    analysisInfoBtn.icon:SetTexture("Interface\\Common\\help-i")
    analysisInfoBtn:SetScript("OnEnter", function(self)
        local info = self._analysisInfoTooltip
        if not info or not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tostring(info.title or "Processing Analysis"), 1, 1, 1)
        GameTooltip:AddLine(tostring(info.text), 0.9, 0.85, 0.65, true)
        GameTooltip:Show()
    end)
    analysisInfoBtn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    analysisInfoBtn:Hide()

    -- "Show All" / "Deficits" toggle (Inventory mode only)
    showAllBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    showAllBtn:SetSize(70, 18)
    showAllBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, 0)
    showAllBtn:SetText("Show All")
    showAllBtn:SetNormalFontObject("GameFontNormalSmall")
    showAllBtn:SetScript("OnClick", function()
        showZeroDeficit = not showZeroDeficit
        showAllBtn:SetText(showZeroDeficit and "Deficits" or "Show All")
        if callbacks.onRerender then callbacks.onRerender() end
    end)

    -- Top Results / All Results toggle (Analysis mode only, grouped results
    -- only) - anchored to the SAME slot as showAllBtn (closeBtn's left
    -- edge, same width) rather than after it. showAllBtn and this button
    -- are mutually exclusive (Inventory-only vs Analysis-only), so sharing
    -- the slot keeps analysisToggleBtn's anchor below fixed regardless of
    -- which mode is active - required header order is
    -- "title | Show Inventory/Analysis | Show All/Top | X", so this must
    -- sit between analysisToggleBtn and the close button, never to
    -- analysisToggleBtn's title-side. Hidden until CraftQueueController
    -- reports the current Analysis result supports grouped/ranked output
    -- families. Presentation-only: the click handler re-slices
    -- already-evaluated rows, it never re-evaluates.
    analysisResultsToggleBtn = CreateFrame("Button", "MCGCFOAnalysisResultsToggleBtn", mainFrame, "UIPanelButtonTemplate")
    analysisResultsToggleBtn:SetSize(70, 18)
    analysisResultsToggleBtn:SetPoint("TOPRIGHT", closeBtn, "TOPLEFT", -4, 0)
    analysisResultsToggleBtn:SetText("Show All")
    analysisResultsToggleBtn:SetNormalFontObject("GameFontNormalSmall")

    -- Defensive hardening for the "click never reaches onToggleAnalysisResults"
    -- investigation: analysisResultsToggleBtn and showAllBtn share the exact
    -- same rect by design (mutually exclusive by mode - see the comment
    -- above showAllBtn's creation), relying on WoW's default sibling
    -- creation-order-wins hit-testing to give this (later-created) button
    -- priority. That default behavior is Theoretical, not verified - make
    -- it deterministic instead of assumed, so an overlapping-frame defect
    -- (hypothesis E) is eliminated regardless of how WoW actually resolves
    -- equal-level sibling overlap.
    if showAllBtn and showAllBtn.GetFrameLevel then
        analysisResultsToggleBtn:SetFrameLevel(showAllBtn:GetFrameLevel() + 1)
    end

    -- OnMouseDown fires before OnClick and before any click-cancelling
    -- interaction could occur - logs unconditionally, every physical click
    -- on this exact widget, independent of whether OnClick itself ever
    -- runs. If this line never appears in the session log when the visible
    -- "Show All" button is clicked, the click is not reaching this frame at
    -- all (hypothesis A/E - wrong frame under the cursor). If it appears
    -- but the controller's onToggleAnalysisResults ENTRY log does not, the
    -- callback wiring itself is the defect (hypothesis B/C).
    analysisResultsToggleBtn:SetScript("OnMouseDown", function(self)
        if PocketCFO and PocketCFO.AppendSessionLog then
            PocketCFO:AppendSessionLog(string.format(
                "[MCG] analysisResultsToggleBtn: DIAG OnMouseDown name=%s shown=%s enabled=%s isMouseEnabled=%s frameLevel=%s frameStrata=%s hasCallback=%s",
                tostring(self:GetName()), tostring(self:IsShown()),
                tostring(self.IsEnabled and self:IsEnabled()),
                tostring(self.IsMouseEnabled and self:IsMouseEnabled()),
                tostring(self:GetFrameLevel()), tostring(self:GetFrameStrata()),
                tostring(callbacks.onToggleAnalysisResults ~= nil)))
        end
        TraceProcessingAnalysisUI("analysisResultsToggleBtn.OnMouseDown",
            "name=%s shown=%s enabled=%s isMouseEnabled=%s frameLevel=%s frameStrata=%s hasCallback=%s",
            tostring(self:GetName()), tostring(self:IsShown()),
            tostring(self.IsEnabled and self:IsEnabled()),
            tostring(self.IsMouseEnabled and self:IsMouseEnabled()),
            tostring(self:GetFrameLevel()), tostring(self:GetFrameStrata()),
            tostring(callbacks.onToggleAnalysisResults ~= nil))
    end)

    analysisResultsToggleBtn:SetScript("OnClick", function(self)
        if PocketCFO and PocketCFO.AppendSessionLog then
            PocketCFO:AppendSessionLog(string.format(
                "[MCG] analysisResultsToggleBtn: DIAG OnClick name=%s hasCallback=%s callbackType=%s",
                tostring(self:GetName()), tostring(callbacks.onToggleAnalysisResults ~= nil),
                tostring(type(callbacks.onToggleAnalysisResults))))
        end
        TraceProcessingAnalysisUI("analysisResultsToggleBtn.OnClick",
            "name=%s hasCallback=%s callbackType=%s",
            tostring(self:GetName()), tostring(callbacks.onToggleAnalysisResults ~= nil),
            tostring(type(callbacks.onToggleAnalysisResults)))
        if callbacks.onToggleAnalysisResults then callbacks.onToggleAnalysisResults() end
    end)
    analysisResultsToggleBtn:Hide()

    -- Inventory / Analysis toggle - hidden until CraftQueueController reports
    -- a Processing Analysis result is applicable for the selected recipe.
    -- Anchored to analysisResultsToggleBtn (not showAllBtn) so its position
    -- is identical regardless of which mode is active - both
    -- showAllBtn/analysisResultsToggleBtn occupy the same 70px-wide slot
    -- next to the close button, so anchoring here never leaves a gap or
    -- overlap depending on which one is actually shown.
    analysisToggleBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    analysisToggleBtn:SetSize(92, 18)
    analysisToggleBtn:SetPoint("TOPRIGHT", analysisResultsToggleBtn, "TOPLEFT", -4, 0)
    analysisToggleBtn:SetText("Show Analysis")
    analysisToggleBtn:SetNormalFontObject("GameFontNormalSmall")
    analysisToggleBtn:SetScript("OnClick", function()
        if callbacks.onToggleViewMode then callbacks.onToggleViewMode() end
    end)
    analysisToggleBtn:Hide()

    -- Back button - only shown in Analysis detail mode, returns to the
    -- Analysis list without leaving Analysis mode.
    analysisBackBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    analysisBackBtn:SetSize(60, 18)
    analysisBackBtn:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 8, -22)
    analysisBackBtn:SetText("< Back")
    analysisBackBtn:SetNormalFontObject("GameFontNormalSmall")
    analysisBackBtn:SetScript("OnClick", function()
        if callbacks.onAnalysisDetailBack then callbacks.onAnalysisDetailBack() end
    end)
    analysisBackBtn:Hide()

    -- Expansion filter dropdown
    expDropdown = CreateFrame("Frame", "MCGCFOExpFilterDropdown", mainFrame, "UIDropDownMenuTemplate")
    expDropdown:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", -8, -22)
    UIDropDownMenu_SetWidth(expDropdown, 130)
    UIDropDownMenu_SetText(expDropdown, "All Expansions")
    UIDropDownMenu_Initialize(expDropdown, function(self, level)
        for _, opt in ipairs(EXP_FILTER_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text    = opt.label
            info.value   = opt.value
            info.checked = (currentExpFilter == opt.value)
            info.func    = function()
                currentExpFilter = opt.value
                UIDropDownMenu_SetText(expDropdown, opt.label)
                if callbacks.onRerender then callbacks.onRerender() end
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    -- Scroll frame
    scrollFrame = CreateFrame("ScrollFrame", "MCGCFOCraftQueueScroll", mainFrame, "UIPanelScrollFrameTemplate")
    if scrollFrame.SetClipsChildren then
        scrollFrame:SetClipsChildren(true)
    end

    contentFrame = CreateFrame("Frame", nil, scrollFrame)
    contentFrame:SetHeight(1)
    scrollFrame:SetScrollChild(contentFrame)

    -- Establishes the default (Inventory-mode) anchors/width; Render(),
    -- RenderAnalysis(), and RenderAnalysisDetail() each reapply the anchors
    -- for their own mode on every call (see ApplyScrollFrameLayout above).
    ApplyScrollFrameLayout(false)

    -- Generic registered-mode content area, overlaid on the same region as
    -- scrollFrame. Hidden by default - only ActivateMode shows it.
    modeContentFrame = CreateFrame("Frame", nil, mainFrame)
    modeContentFrame:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT")
    modeContentFrame:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT")
    modeContentFrame:Hide()

    -- Posting Rules button
    postingRulesBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    postingRulesBtn:SetSize(136, 22)
    postingRulesBtn:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 28, 8)
    postingRulesBtn:SetText("Show Posting Rules")
    postingRulesBtn:SetNormalFontObject("GameFontNormalSmall")
    postingRulesBtn:SetScript("OnClick", function()
        if callbacks.onPostingRulesToggle then callbacks.onPostingRulesToggle() end
    end)

    -- Posting Profiles button
    postingProfilesBtn = CreateFrame("Button", nil, mainFrame, "UIPanelButtonTemplate")
    postingProfilesBtn:SetSize(154, 22)
    postingProfilesBtn:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -28, 8)
    postingProfilesBtn:SetText("Open Posting Profiles")
    postingProfilesBtn:SetNormalFontObject("GameFontNormalSmall")
    postingProfilesBtn:SetScript("OnClick", function()
        if callbacks.onPostingProfilesToggle then callbacks.onPostingProfilesToggle() end
    end)
end

-- ---------------------------------------------------------------------------
-- Render — lays out pre-computed category groups into the scroll frame
-- ---------------------------------------------------------------------------

function InventoryManagerWindow:Render(categoryGroups, highlightedConfigID, charGUID)
    local startedAt = DebugTime()
    if not mainFrame or not mainFrame:IsShown() then return end
    if self:RefreshActiveModeShell() then return end
    HideRecipeAnalysisFrame()

    self:SetTitle("Inventory Manager")
    self:SetInventoryControlsVisible(true)
    self:SetAnalysisInfoTooltip(nil)
    if analysisBackBtn then analysisBackBtn:Hide() end
    ApplyScrollFrameLayout(false)
    if analysisColumnHeader then analysisColumnHeader:Hide() end
    if analysisFooterNote then analysisFooterNote:Hide() end

    currentHighlightedConfigID = highlightedConfigID

    ReleaseAllRows()
    ReleaseAllHeaders()
    ReleaseAllAnalysisRows()
    ReleaseAllDetailLines()

    -- Empty state
    if not categoryGroups or #categoryGroups == 0 then
        if not emptyLabel then
            emptyLabel = contentFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            emptyLabel:SetPoint("CENTER", contentFrame, "CENTER", 0, 0)
        end
        emptyLabel:SetText("All items fully stocked.")
        emptyLabel:Show()
        contentFrame:SetHeight(80)
        UpdateScrollbarVisibility()
        LogTiming("InventoryManagerWindow:Render", startedAt, "groups=0 rows=0")
        return
    end

    if emptyLabel then emptyLabel:Hide() end

    local recipeConfig   = PocketCFO_Crafting:GetModule("RecipeConfigStore", true)
    local tooltipBuilder = PocketCFO_Crafting:GetModule("CraftTooltipBuilder", true)

    local yOffset     = -(ROW_PADDING + 12)
    local rowIndex    = 0
    local totalHeight = 0

    for _, group in ipairs(categoryGroups) do
        -- Category header
        local header = CreateCategoryHeader(contentFrame, group.label)
        header:SetPoint("TOPLEFT",  contentFrame, "TOPLEFT",  0, yOffset)
        header:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, yOffset)
        yOffset     = yOffset - HEADER_HEIGHT
        totalHeight = totalHeight + HEADER_HEIGHT

        for _, result in ipairs(group.results) do
            rowIndex = rowIndex + 1
            local row = GetRow()
            row:SetPoint("TOPLEFT",  contentFrame, "TOPLEFT",  0, yOffset)
            row:SetPoint("TOPRIGHT", contentFrame, "TOPRIGHT", 0, yOffset)
            row._isEven = (rowIndex % 2 == 0)

            -- Icon (pre-resolved by QueueGeneration)
            if result.iconID then
                row.icon:SetTexture(result.iconID)
            end

            -- Name and stock string
            row.nameLabel:SetText(result.itemName or "Unknown")
            row.stockLabel:SetText(string.format("have %d  /  want %d",
                result.currentStock,
                result.config.targetQuantity
            ))

            -- Deficit badge color
            local c
            if result.missingOptionals and #result.missingOptionals > 0 then
                c = COLOR_RED
            elseif result.matStatus == "red" then
                c = COLOR_RED
            elseif result.deficit == 0 then
                c = COLOR_GREEN
            elseif result.matStatus == "green" then
                c = COLOR_GREEN
            elseif result.matStatus == "yellow" then
                c = COLOR_YELLOW
            else
                c = COLOR_RED
            end
            row.deficitLabel:SetText(result.deficit > 0 and tostring(result.deficit) or "0")
            row.deficitLabel:SetTextColor(c.r, c.g, c.b, 1)

            -- Warning icon
            local hasWarnings = (result.missingOptionals  and #result.missingOptionals  > 0)
                             or (result.qualityMismatches and #result.qualityMismatches > 0)
            if hasWarnings then
                row.warnIcon:Show()
                if result.qualityMismatches and #result.qualityMismatches > 0 then
                    row.warnIcon:SetVertexColor(1.0, 0.5, 0.0)
                else
                    row.warnIcon:SetVertexColor(1.0, 0.9, 0.0)
                end
            end

            -- Quantity controls
            local capturedConfigID = result.config.configID
            row.qtyBox:SetText(tostring(result.config.targetQuantity))

            row.plusBtn:SetScript("OnClick", function()
                if not recipeConfig then return end
                local cfg = recipeConfig and recipeConfig:GetConfiguration(capturedConfigID)
                if cfg then
                    recipeConfig:SetTargetQuantity(capturedConfigID, cfg.targetQuantity + 1)
                end
            end)

            row.minusBtn:SetScript("OnClick", function()
                if not recipeConfig then return end
                local cfg = recipeConfig and recipeConfig:GetConfiguration(capturedConfigID)
                if cfg and cfg.targetQuantity > 1 then
                    recipeConfig:SetTargetQuantity(capturedConfigID, cfg.targetQuantity - 1)
                end
            end)

            row.qtyBox:SetScript("OnEnterPressed", function(self)
                if not recipeConfig then self:ClearFocus(); return end
                local val = tonumber(self:GetText())
                if val and val >= 1 then
                    recipeConfig:SetTargetQuantity(capturedConfigID, math.floor(val))
                else
                    local cfg = recipeConfig and recipeConfig:GetConfiguration(capturedConfigID)
                    if cfg then self:SetText(tostring(cfg.targetQuantity)) end
                end
                self:ClearFocus()
            end)

            row.qtyBox:SetScript("OnEscapePressed", function(self)
                local cfg = recipeConfig and recipeConfig:GetConfiguration(capturedConfigID)
                if cfg then self:SetText(tostring(cfg.targetQuantity)) end
                self:ClearFocus()
            end)

            row.qtyBox:SetScript("OnEditFocusLost", function(self)
                local val = tonumber(self:GetText())
                if not val or val < 1 then
                    local cfg = recipeConfig and recipeConfig:GetConfiguration(capturedConfigID)
                    if cfg then self:SetText(tostring(cfg.targetQuantity)) end
                end
            end)

            -- Row metadata for tooltip tracking
            local capturedResult   = result
            local capturedItemName = result.itemName
            local capturedCharGUID = charGUID
            local capturedDeficit  = result.deficit

            row._craftQueueConfigID     = capturedConfigID
            row._craftQueueResult       = capturedResult
            row._craftQueueItemName     = capturedItemName
            row._craftQueueCharGUID     = capturedCharGUID
            row._craftQueueScrollTop    = -yOffset
            row._craftQueueScrollBottom = -yOffset + ROW_HEIGHT
            SetRowBaseBackground(row)

            row:SetScript("OnEnter", function(self)
                self.bg:SetColorTexture(COLOR_HOVER.r, COLOR_HOVER.g, COLOR_HOVER.b, COLOR_HOVER.a)
                InventoryManagerWindow.activeTooltipState = {
                    row      = self,
                    configID = capturedConfigID,
                    result   = capturedResult,
                    itemName = capturedItemName,
                    charGUID = capturedCharGUID,
                }
                if tooltipBuilder then
                    tooltipBuilder:ShowRowTooltip(self, capturedResult, capturedItemName, capturedCharGUID)
                end
            end)

            row:SetScript("OnLeave", function(self)
                SetRowBaseBackground(self)
                local ts = InventoryManagerWindow.activeTooltipState
                if ts and ts.row == self then
                    InventoryManagerWindow.activeTooltipState = nil
                end
                GameTooltip:Hide()
            end)

            -- Click handlers delegate to controller callbacks
            row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            row:SetScript("OnClick", function(self, btn)
                if btn == "RightButton" then
                    if callbacks.onDeleteConfig then
                        callbacks.onDeleteConfig(capturedConfigID, capturedItemName)
                    end
                else
                    if callbacks.onLoadConfig then
                        callbacks.onLoadConfig(capturedConfigID, capturedDeficit > 0 and capturedDeficit or 1)
                    end
                end
            end)

            table.insert(activeRows, row)
            yOffset     = yOffset - ROW_HEIGHT - 1
            totalHeight = totalHeight + ROW_HEIGHT + 1
        end

        -- Small gap between categories
        yOffset     = yOffset - 4
        totalHeight = totalHeight + 4
    end

    contentFrame:SetHeight(totalHeight + ROW_PADDING * 2)
    UpdateScrollbarVisibility()

    if scrollHighlightedAfterRender then
        scrollHighlightedAfterRender = nil
        ScrollHighlightedRowIntoView()
    end
    LogTiming("InventoryManagerWindow:Render", startedAt, string.format(
        "groups=%d rows=%d",
        #categoryGroups,
        rowIndex
    ))
end
