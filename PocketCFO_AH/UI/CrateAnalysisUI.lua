-- PocketCFO_AH/UI/CrateAnalysisUI.lua
-- Forever only (loaded by PocketCFO_AH_Camelot.toc).
--
-- Crate analysis on the Analysis tab (claude/Crate_Analysis_Design.md,
-- 2026-11-24). Favor box + Analyze; a headline with the Favor asked for
-- ("100 Favor costs 1g 20s"), "+10 extra Favor" when the cheapest plan goes
-- over, the price note;
-- one row per crate + fill: Crate, Fill with, Count, Favor, Gold, Per Favor;
-- the "At level N" line and Add plan to shopping list. Analyze runs a full
-- scan through the Analysis tab (or uses one from the last 15 minutes).

local PocketCFO_AH = _G.PocketCFO_AH
local CrateAnalysisUI = PocketCFO_AH:NewModule("CrateAnalysisUI")

local KEY = "crates"
local DEFAULT_TARGET = 100
local MAX_ROWS = 18
local ROW_HEIGHT = 18
local LINE_HEIGHT = 13
local HEADLINE_Y = -32
local EXTRA_Y = -52
local NOTE_Y = -66
local HEADER_Y = -88
local LIST_Y = -104
local FOOTER_HEIGHT = 50
local CRATE_WIDTH = 170
local GREEN = "ff1eff00"
local GRAY = "ffa0a0a0"
-- Always shown (Brian, 2026-11-24): prices move between the scan and buying.
local PRICE_NOTE = "Prices can change before you buy. Some listings may be gone."

-- Number columns, right to left.
local COLUMNS = {
    { key = "PerFavor", title = "Per Favor", width = 76 },
    { key = "Gold", title = "Gold", width = 90 },
    { key = "Favor", title = "Favor", width = 50 },
    { key = "Count", title = "Count", width = 44 },
}
local COLUMN_GAP = 8

local function Valuation(name)
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule(name, true) or nil
end

-- Not at a Neutral AH (Brian, 2026-11-24, claude/Forever_Markets_Design.md):
-- nobody buys crate mats in Booty Bay, so Analyze there only shows this
-- note. The open AH is Neutral when the scan market (open AH) ends in
-- "-Neutral" (PricingCache).
local NEUTRAL_MESSAGE = "Crate analysis runs at your faction's Auction House only."

local function AtNeutralAH()
    local cache = Valuation("PricingCache")
    if not (cache and cache.GetScanMarketKey) then
        return false
    end
    local ok, key = pcall(cache.GetScanMarketKey, cache)
    return ok and type(key) == "string" and key:find("%-Neutral$") ~= nil
end

local function Money(value)
    local tooltip = Valuation("Tooltip")
    if tooltip and tooltip.FormatMoney then
        return tooltip:FormatMoney(value) or ""
    end
    return tostring(math.floor((tonumber(value) or 0) + 0.5)) .. "c"
end

-- "Waylaid Crate: Expert Fabrics" -> "Expert Fabrics" (text after the
-- first colon, any client language); the whole name if there is none.
local function ShortName(name)
    if type(name) ~= "string" then
        return "?"
    end
    return string.match(name, "^[^:]+:%s*(.+)$") or name
end

local function CrateLabel(row)
    local name = ShortName(row.name)
    if row.rarity == 2 then
        name = "|c" .. GREEN .. name .. "|r"
    end
    if row.favorEstimated then
        name = name .. " (Est.)"
    end
    return name
end

local function FormatAge(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    if seconds < 90 then
        return "1 minute ago"
    elseif seconds < 3600 then
        return math.floor(seconds / 60 + 0.5) .. " minutes ago"
    end
    local hours = math.floor(seconds / 3600)
    return hours .. (hours == 1 and " hour ago" or " hours ago")
end

local function FormatClock(seconds)
    seconds = math.max(0, math.ceil(tonumber(seconds) or 0))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function ServerNow()
    return (GetServerTime and GetServerTime()) or (time and time()) or 0
end

local function SavedTarget()
    local db = PocketCFO_AH.db and PocketCFO_AH.db.char
    local value = db and tonumber(db.crateFavorTarget)
    return value and value > 0 and math.floor(value) or DEFAULT_TARGET
end

local function SaveTarget(value)
    local db = PocketCFO_AH.db and PocketCFO_AH.db.char
    if db then
        db.crateFavorTarget = value
    end
end

local function CreateText(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    if text.SetWordWrap then
        text:SetWordWrap(false)
    end
    return text
end

-- Crate, Fill with and the number columns on one line of `parent`.
local function PlaceLine(parent, font)
    local line = {}
    local right = 0
    for _, column in ipairs(COLUMNS) do
        local text = CreateText(parent, font, "RIGHT")
        text:SetWidth(column.width)
        text:SetHeight(LINE_HEIGHT)
        text:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -right, 0)
        line[column.key] = text
        right = right + column.width + COLUMN_GAP
    end
    line.Crate = CreateText(parent, font, "LEFT")
    line.Crate:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    line.Crate:SetWidth(CRATE_WIDTH)
    line.Crate:SetHeight(LINE_HEIGHT)
    line.Fill = CreateText(parent, font, "LEFT")
    line.Fill:SetPoint("TOPLEFT", parent, "TOPLEFT", CRATE_WIDTH + COLUMN_GAP, 0)
    line.Fill:SetPoint("RIGHT", parent, "RIGHT", -right, 0)
    line.Fill:SetHeight(LINE_HEIGHT)
    return line
end

local function CreateRow(list, index)
    local row = CreateFrame("Frame", nil, list)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
    row.line = PlaceLine(row, "GameFontHighlightSmall")
    row:Hide()
    return row
end

-- ---------------------------------------------------------------------------
-- Analysis tab entry
-- ---------------------------------------------------------------------------

local Entry = { key = KEY, buttonText = "Crate analysis" }

function Entry:Build(content)
    local ui = CrateAnalysisUI
    ui.content = content

    local label = CreateText(content, "GameFontNormal", "LEFT")
    label:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -4)
    label:SetText("Favor")

    local box = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    box:SetSize(64, 20)
    box:SetPoint("LEFT", label, "RIGHT", 10, 0)
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(6)
    box:SetJustifyH("CENTER")
    box:SetFontObject("GameFontHighlightSmall")
    box:SetText(tostring(SavedTarget()))
    box:SetScript("OnEnterPressed", function(editBox)
        editBox:ClearFocus()
        ui:Analyze()
    end)
    box:SetScript("OnEscapePressed", function(editBox)
        editBox:ClearFocus()
    end)
    ui.box = box

    local analyze = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    analyze:SetSize(80, 22)
    analyze:SetPoint("LEFT", box, "RIGHT", 8, 0)
    analyze:SetText("Analyze")
    analyze:SetScript("OnClick", function()
        box:ClearFocus()
        ui:Analyze()
    end)
    ui.analyzeButton = analyze

    local headline = CreateText(content, "GameFontNormalLarge", "LEFT")
    headline:SetPoint("TOPLEFT", content, "TOPLEFT", 0, HEADLINE_Y)
    headline:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    ui.headline = headline

    local extra = CreateText(content, "GameFontHighlight", "LEFT")
    extra:SetPoint("TOPLEFT", content, "TOPLEFT", 0, EXTRA_Y)
    extra:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    ui.extra = extra

    local note = CreateText(content, "GameFontHighlightSmall", "LEFT")
    note:SetPoint("TOPLEFT", content, "TOPLEFT", 0, NOTE_Y)
    note:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    ui.note = note

    local header = CreateFrame("Frame", nil, content)
    header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, HEADER_Y)
    header:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    header:SetHeight(LINE_HEIGHT)
    local headerLine = PlaceLine(header, "GameFontNormalSmall")
    headerLine.Crate:SetText("Crate")
    headerLine.Fill:SetText("Fill with")
    for _, column in ipairs(COLUMNS) do
        headerLine[column.key]:SetText(column.title)
    end
    header:Hide()
    ui.header = header

    -- Rows (scroll with the mouse wheel)
    local list = CreateFrame("Frame", nil, content)
    list:SetPoint("TOPLEFT", content, "TOPLEFT", 0, LIST_Y)
    list:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, FOOTER_HEIGHT)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        ui:Scroll(delta > 0 and -1 or 1)
    end)
    ui.list = list
    ui.rows = {}
    for index = 1, MAX_ROWS do
        ui.rows[index] = CreateRow(list, index)
    end

    local message = CreateText(content, "GameFontHighlightSmall", "LEFT")
    message:SetPoint("TOPLEFT", content, "TOPLEFT", 0, HEADLINE_Y)
    message:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    if message.SetWordWrap then
        message:SetWordWrap(true)
    end
    ui.message = message

    -- Footer
    local footer = CreateFrame("Frame", nil, content)
    footer:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    footer:SetHeight(FOOTER_HEIGHT)
    ui.footer = footer

    local shopping = _G.PocketCFO and _G.PocketCFO.ShoppingList
    if shopping and shopping.CreateAddControl then
        ui.add = shopping:CreateAddControl(footer, { buttonText = "Add plan to shopping list", buttonWidth = 180 })
        ui.add.frame:SetPoint("BOTTOMRIGHT", footer, "BOTTOMRIGHT", 0, 2)
    end

    local levelLine = CreateText(footer, "GameFontHighlightSmall", "LEFT")
    levelLine:SetPoint("BOTTOMLEFT", footer, "BOTTOMLEFT", 0, 6)
    if ui.add then
        levelLine:SetPoint("RIGHT", ui.add.frame, "LEFT", -8, 0)
    else
        levelLine:SetPoint("RIGHT", footer, "RIGHT", 0, 0)
    end
    ui.levelLine = levelLine

    ui:ShowIdle()
end

function Entry:OnScanning()
    -- Load every crate and mat while the scan runs (Brian, 2026-11-24: a
    -- plan built before the crates loaded left the cheap ones out).
    local analysis = PocketCFO_AH:GetModule("CrateAnalysis", true)
    if analysis then
        analysis:RequestItemData()
    end
    CrateAnalysisUI:ShowScanning()
end

function Entry:IsReady()
    local analysis = PocketCFO_AH:GetModule("CrateAnalysis", true)
    return not analysis or analysis:IsReady()
end

function Entry:OnPrices(info)
    CrateAnalysisUI:ShowResults(info)
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

function CrateAnalysisUI:OnInitialize()
    local tab = PocketCFO_AH:GetModule("AnalysisTab", true)
    if tab and tab.Register then
        tab:Register(Entry)
    end
end

function CrateAnalysisUI:GetTarget()
    local value = math.floor(tonumber(self.box and self.box:GetText()) or 0)
    if value < 1 then
        value = SavedTarget()
    end
    if self.box then
        self.box:SetText(tostring(value))
    end
    SaveTarget(value)
    return value
end

function CrateAnalysisUI:Analyze()
    if AtNeutralAH() then
        self:ShowMessage(NEUTRAL_MESSAGE)
        return
    end
    local tab = PocketCFO_AH:GetModule("AnalysisTab", true)
    if tab and not tab:IsRunning() then
        tab:Run(KEY)
    end
end

function CrateAnalysisUI:HideResults()
    self.plan = nil
    self.headline:SetText("")
    self.extra:SetText("")
    self.note:SetText("")
    self.header:Hide()
    for _, row in ipairs(self.rows or {}) do
        row:Hide()
    end
    self.levelLine:SetText("")
    if self.add then
        self.add.frame:Hide()
    end
end

function CrateAnalysisUI:ShowMessage(text)
    self:HideResults()
    self.message:SetText(text)
    self.message:Show()
end

function CrateAnalysisUI:ShowIdle()
    self.analyzeButton:Enable()
    if AtNeutralAH() then
        self:ShowMessage(NEUTRAL_MESSAGE)
        return
    end
    self:ShowMessage("Type how much Favor you want and press Analyze.")
end

function CrateAnalysisUI:ShowScanning()
    self.analyzeButton:Disable()
    self:HideResults()
    self.message:Hide()
end

function CrateAnalysisUI:VisibleRows()
    local height = self.list and self.list:GetHeight() or 0
    if height <= 0 then
        return 10
    end
    return math.max(1, math.min(MAX_ROWS, math.floor(height / ROW_HEIGHT)))
end

function CrateAnalysisUI:Scroll(step)
    local plan = self.plan
    if not plan then
        return
    end
    local maxOffset = math.max(0, #plan.rows - self:VisibleRows())
    self.offset = math.max(0, math.min(maxOffset, (self.offset or 0) + step))
    self:DrawRows()
end

function CrateAnalysisUI:DrawRows()
    local plan = self.plan
    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    if not plan then
        return
    end
    for index = 1, self:VisibleRows() do
        local data = plan.rows[(self.offset or 0) + index]
        local row = self.rows[index]
        if not data or not row then
            break
        end
        local line = row.line
        line.Crate:SetText(CrateLabel(data))
        line.Fill:SetText(data.fillQty .. " " .. (data.fillName or ("item " .. data.fillItemID)))
        line.Count:SetText(tostring(data.count))
        line.Favor:SetText(tostring(data.favor))
        line.Gold:SetText(Money(data.gold))
        line.PerFavor:SetText(Money(data.gold / data.favor))
        row:Show()
    end
end

local function ScanWait()
    local valuation = _G.PocketCFO_Valuation
    local scan = valuation and valuation:GetModule("FullScan", true)
    return scan and scan:GetCooldownRemaining() or 0
end

-- " A new scan is available in 12:30." while the 15-minute wait runs.
local function WaitText()
    local wait = ScanWait()
    if wait > 0 then
        return " A new scan is available in " .. FormatClock(wait) .. "."
    end
    return ""
end

-- No usable saved prices (none yet, or older than 3 days).
function CrateAnalysisUI:NoListingsText(plan, failed)
    local text = plan.tooOld and "Your last scan is more than 3 days old." or "No crate prices yet."
    if failed then
        text = "The scan stopped (" .. tostring(failed) .. "). " .. text
    end
    if ScanWait() > 0 then
        return text .. WaitText() .. " Press Analyze again then."
    end
    return text .. " Press Analyze to scan."
end

function CrateAnalysisUI:ShowResults(info)
    self.analyzeButton:Enable()
    self.offset = 0
    -- A scan that stopped (AH closed, failed) falls back to the last saved
    -- scan up to 3 days old, clearly dated (Brian, 2026-11-24).
    local analysis = PocketCFO_AH:GetModule("CrateAnalysis", true)
    if not analysis then
        self:ShowMessage("Crate data isn't available.")
        return
    end
    analysis:EnsureKeeper()
    local plan = analysis:Analyze(self:GetTarget())
    local tab = PocketCFO_AH:GetModule("AnalysisTab", true)
    if plan.noListings then
        if tab then
            tab:SetStatus("")
        end
        self:ShowMessage(self:NoListingsText(plan, info.failed))
        return
    end
    if plan.unavailable then
        self:ShowMessage("Crate data isn't available.")
        return
    end

    if tab then
        if info.notReady then
            tab:SetStatus("|cffff4040Some crates didn't load, so cheaper options may be missing. Press Analyze again.|r")
        elseif not info.fresh and plan.pricesAt then
            local stopped = info.failed and ("The scan stopped (" .. tostring(info.failed) .. "). ") or ""
            tab:SetStatus(stopped .. "Prices from " .. FormatAge(ServerNow() - plan.pricesAt) .. "." .. WaitText())
        else
            tab:SetStatus("")
        end
    end

    if #plan.rows == 0 then
        self:ShowMessage("No crate can be filled from what's for sale right now.")
        return
    end

    self.plan = plan
    self.message:Hide()
    -- Headline: the Favor asked for (Brian, 2026-11-24: never a number they
    -- didn't type); extra Favor on its own line. Per Favor = gold / all the
    -- Favor you actually get.
    local est = plan.estimated and " (Est.)" or ""
    local perFavor = Money(plan.gold / plan.favor) .. " per Favor"
    if plan.short then
        self.headline:SetText("Only " .. plan.favor .. " Favor" .. est .. " for sale: " .. Money(plan.gold)
            .. " (" .. perFavor .. ")")
        self.extra:SetText("")
    else
        self.headline:SetText(plan.target .. " Favor" .. est .. " costs " .. Money(plan.gold) .. " (" .. perFavor .. ")")
        local over = plan.favor - plan.target
        self.extra:SetText(over > 0 and ("+" .. over .. " extra Favor") or "")
    end
    self.note:SetText("|c" .. GRAY .. PRICE_NOTE .. "|r")
    self.header:Show()
    self:DrawRows()

    -- Unloaded crates are warned about at the top (status line), not here.
    if plan.cheaperAtLevel then
        local cheaper = plan.cheaperAtLevel
        self.levelLine:SetText("At level " .. cheaper.level .. " this would cost " .. Money(cheaper.saving)
            .. " less (" .. CrateLabel(cheaper.crate) .. ")")
    else
        self.levelLine:SetText("")
    end

    if self.add then
        local items = {}
        for itemID, qty in pairs(plan.items) do
            items[#items + 1] = { itemID = itemID, qty = qty }
        end
        table.sort(items, function(a, b)
            return a.itemID < b.itemID
        end)
        self.add:SetItems(items, "crate")
        self.add.frame:Show()
    end
end
