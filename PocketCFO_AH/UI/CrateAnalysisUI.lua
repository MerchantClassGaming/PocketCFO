-- PocketCFO_AH/UI/CrateAnalysisUI.lua
-- Forever only (loaded by PocketCFO_AH_Camelot.toc).
--
-- The Analysis box on the AH Dashboard (right of Pricing), first entry:
-- Crate analysis (claude/Crate_Analysis_Design.md, step 1). One button
-- ranks the Waylaid Crates the character can use, cheapest gold per Favor
-- first, top 5. Runs only when clicked. No AH searches and no buying yet
-- (steps 2 and 4); the "Buy ..." text on each row becomes the buy buttons.

local PocketCFO_AH = _G.PocketCFO_AH
local CrateAnalysisUI = PocketCFO_AH:NewModule("CrateAnalysisUI")

local ROW_COUNT = 5
local ROW_HEIGHT = 44
local LINE_HEIGHT = 13
local GREEN = "ff1eff00"

local function Valuation(name)
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule(name, true) or nil
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
    local short = string.match(name, "^[^:]+:%s*(.+)$")
    return short or name
end

local function FormatAge(seconds)
    if not seconds then
        return nil
    end
    if seconds < 3600 then
        return math.max(1, math.floor(seconds / 60)) .. "m ago"
    elseif seconds < 48 * 3600 then
        return math.floor(seconds / 3600) .. "h ago"
    end
    return math.floor(seconds / 86400) .. "d ago"
end

local function FavorText(entry)
    local parts = {}
    if entry.rarity == 2 then
        parts[#parts + 1] = "green"
    end
    parts[#parts + 1] = entry.favor .. " Favor"
    if entry.favorEstimated then
        parts[#parts + 1] = "Est."
    end
    return "(" .. table.concat(parts, ", ") .. ")"
end

local function BuyText(entry)
    local parts = {}
    if entry.haveCrate then
        parts[#parts + 1] = "You have the crate"
    else
        parts[#parts + 1] = "Buy crate " .. Money(entry.crateCost)
    end
    local bundle = entry.bundle
    local row = bundle.row
    if bundle.need == 0 then
        parts[#parts + 1] = "You have " .. row.count .. " " .. row.name
    elseif bundle.have > 0 then
        parts[#parts + 1] = "Buy " .. bundle.need .. " " .. row.name
            .. " (" .. bundle.have .. " of " .. row.count .. ") " .. Money(bundle.cost)
    else
        parts[#parts + 1] = "Buy " .. bundle.need .. " " .. row.name .. " " .. Money(bundle.cost)
    end
    return table.concat(parts, " \194\183 ")
end

local function CreateText(parent, font, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    if text.SetWordWrap then
        text:SetWordWrap(false)
    end
    return text
end

local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    row.PerFavor = CreateText(row, "GameFontNormalSmall", "RIGHT")
    row.PerFavor:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
    row.PerFavor:SetHeight(LINE_HEIGHT)

    row.Title = CreateText(row, "GameFontNormalSmall", "LEFT")
    row.Title:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.Title:SetPoint("RIGHT", row.PerFavor, "LEFT", -8, 0)
    row.Title:SetHeight(LINE_HEIGHT)

    -- Shopping list (2026-11-21, claude/Shopping_List_Design.md step 4):
    -- "Add" puts the crate and the cheapest bundle on the list; the list
    -- takes off what you already own (bags and bank).
    local list = _G.PocketCFO and _G.PocketCFO.ShoppingList
    if list and list.CreateAddControl then
        row.Add = list:CreateAddControl(row, { buttonText = "Add", buttonWidth = 110 })
        row.Add.frame:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -LINE_HEIGHT - 2)
    end

    row.Buy = CreateText(row, "GameFontHighlightSmall", "LEFT")
    row.Buy:SetPoint("TOPLEFT", row, "TOPLEFT", 18, -LINE_HEIGHT - 1)
    if row.Add then
        row.Buy:SetPoint("RIGHT", row.Add.frame, "LEFT", -6, 0)
    else
        row.Buy:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    end
    row.Buy:SetHeight(LINE_HEIGHT)

    row.Total = CreateText(row, "GameFontHighlightSmall", "LEFT")
    row.Total:SetPoint("TOPLEFT", row, "TOPLEFT", 18, -(LINE_HEIGHT + 1) * 2)
    row.Total:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.Total:SetHeight(LINE_HEIGHT)

    row:Hide()
    return row
end

-- Builds the box once inside `parent` (the Dashboard's right-hand mount).
function CrateAnalysisUI:Render(parent)
    if not parent or not CreateFrame then
        return nil
    end
    local frame = self.frame
    if not frame then
        frame = CreateFrame("Frame", "PocketCFOCrateAnalysisFrame", parent)
        self.frame = frame

        local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        button:SetSize(130, 24)
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        button:SetText("Crate analysis")
        button:SetScript("OnClick", function()
            self:Run()
        end)
        self.button = button

        local status = CreateText(frame, "GameFontHighlightSmall", "LEFT")
        status:SetPoint("LEFT", button, "RIGHT", 10, 0)
        status:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
        self.status = status

        local header = CreateText(frame, "GameFontNormal", "LEFT")
        header:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -10)
        header:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
        self.header = header

        local list = CreateFrame("Frame", nil, frame)
        list:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
        list:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        self.list = list

        self.rows = {}
        for i = 1, ROW_COUNT do
            self.rows[i] = CreateRow(list, i)
        end

        local message = CreateText(list, "GameFontHighlightSmall", "LEFT")
        if message.SetWordWrap then
            message:SetWordWrap(true)
        end
        self.message = message

        self:ShowIdle()
    end
    frame:SetParent(parent)
    frame:ClearAllPoints()
    frame:SetAllPoints(parent)
    frame:Show()
    return frame
end

-- The message line sits at the top of the list, or under the last shown row.
function CrateAnalysisUI:ShowMessage(text, belowRow)
    self.message:ClearAllPoints()
    if belowRow then
        self.message:SetPoint("TOPLEFT", belowRow, "BOTTOMLEFT", 0, -4)
    else
        self.message:SetPoint("TOPLEFT", self.list, "TOPLEFT", 0, 0)
    end
    self.message:SetPoint("RIGHT", self.list, "RIGHT", 0, 0)
    self.message:SetText(text)
    self.message:Show()
end

function CrateAnalysisUI:ShowIdle()
    self.status:SetText("")
    self.header:SetText("")
    for _, row in ipairs(self.rows) do
        row:Hide()
    end
    self:ShowMessage("Click Crate analysis to find the cheapest Merchant's Favor.")
end

function CrateAnalysisUI:Run()
    local analysis = PocketCFO_AH:GetModule("CrateAnalysis", true)
    if not analysis or not self.frame then
        return
    end
    local result = analysis:Rank(ROW_COUNT)

    local age = FormatAge(analysis:GetPriceAge())
    self.status:SetText(age and ("Prices from last scan, " .. age) or "No price scan yet")

    for _, row in ipairs(self.rows) do
        row:Hide()
    end

    if #result.ranked == 0 then
        self.header:SetText("")
        local text = "No crate prices yet. Scan prices first."
        if result.loading > 0 then
            text = text .. "\nSome crates are still loading. Click again in a moment."
        end
        self:ShowMessage(text)
        return
    end

    self.message:Hide()
    self.header:SetText("Cheapest Favor right now:")
    for i, entry in ipairs(result.ranked) do
        local row = self.rows[i]
        local name = ShortName(entry.name)
        if entry.rarity == 2 then
            name = "|c" .. GREEN .. name .. "|r"
        end
        row.Title:SetText(i .. "   " .. name .. "  " .. FavorText(entry))
        row.PerFavor:SetText(Money(entry.perFavor) .. " / Favor")
        row.Buy:SetText(BuyText(entry))
        row.Total:SetText("Total " .. Money(entry.total))
        if row.Add then
            row.Add:SetItems({
                { itemID = entry.crateID, qty = 1 },
                { itemID = entry.bundle.row.itemID, qty = entry.bundle.row.count },
            }, "crate")
        end
        row:Show()
    end
    if result.loading > 0 and #result.ranked < ROW_COUNT then
        self:ShowMessage("Some crates are still loading. Click again in a moment.", self.rows[#result.ranked])
    end
end
