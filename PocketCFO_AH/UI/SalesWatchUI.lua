-- PocketCFO_AH/UI/SalesWatchUI.lua
-- Item Watch page in the Pocket CFO AH tab (engine: Services/SalesWatch;
-- player-facing name "Item Watch" since 2026-11-16, code names unchanged).
-- Pick an item: type a name and press Enter for a list from the AH search
-- (same search as Blizzard's Buy tab), or drag / shift-click an item, or
-- paste a link / item ID. Hit Watch, stay on the page. Results show here.
-- Leaving the page or closing the AH stops the watch. Flavor: Both.

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local PocketCFO_AH = _G.PocketCFO_AH

local SalesWatchUI = PocketCFO_AH:NewModule("SalesWatchUI")

local HINT = "Type an item name and press Enter, or drag / shift-click an item."
local LIST_ROWS = 10
local LIST_ROW_HEIGHT = 22
local VERSION_ROW_HEIGHT = 16
local VERSION_ROW_POOL = 40
-- Gear breakdown box columns. share = part of the box's width, so the
-- columns always fit whatever width the page gives the box (Brian,
-- 2026-11-16: fixed positions ran past the right edge).
local VERSION_COLUMNS = {
    { key = "label", title = "Version", share = 0.24, justify = "LEFT" },
    { key = "listed", title = "Listed", share = 0.12, justify = "RIGHT" },
    { key = "lowest", title = "Cheapest", share = 0.24, justify = "RIGHT" },
    { key = "sold", title = "Sold (likely)", share = 0.13, justify = "RIGHT" },
    { key = "gone", title = "Canceled or expired", share = 0.18, justify = "RIGHT" },
    { key = "new", title = "New", share = 0.09, justify = "RIGHT" },
}
local VERSION_COLUMN_GAP = 6
local DETAIL_ROWS = {
    { key = "soldMine", label = "You sold" },
    { key = "soldCheap", label = "Sold by others (likely)" },
    { key = "leftHigher", label = "Canceled or expired" },
    { key = "newListed", label = "New listed" },
    { key = "lowest", label = "Cheapest price", gearLabel = "Cheapest price (any version)" },
    { key = "total", label = "Total listed" },
    { key = "refreshes", label = "Refreshes" },
}

local function GetEngine()
    return PocketCFO_AH:GetModule("SalesWatch", true)
end

local function Money(copper)
    copper = tonumber(copper)
    if not copper then
        return "-"
    end
    if GetMoneyString then
        local ok, text = pcall(GetMoneyString, copper, true)
        if ok and text then
            return text
        end
    end
    return string.format("%.2fg", copper / 10000)
end

local function Clock(seconds)
    seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function Number(value)
    value = tonumber(value) or 0
    if BreakUpLargeNumbers then
        return BreakUpLargeNumbers(value)
    end
    return tostring(value)
end

local function BuildSorts()
    if _G.Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
        return { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    end
    return {}
end

---------------------------------------------------------------------------
-- Picking an item: link / ID / drag / shift-click
---------------------------------------------------------------------------

-- The watch covers every version of the item, so show the base item (no
-- suffix such as "of the Monkey") whatever version was linked.
local function ItemFromInfo(itemID, ref)
    local name, link, _, _, _, _, _, _, equipLoc, icon = GetItemInfo(ref or itemID)
    if not name then
        return nil
    end
    local id = tonumber(itemID) or tonumber(tostring(link or ""):match("item:(%d+)"))
    if id then
        local baseName, baseLink, _, _, _, _, _, _, baseEquip, baseIcon = GetItemInfo(id)
        if baseName then
            name, link = baseName, baseLink
            equipLoc, icon = baseEquip or equipLoc, baseIcon or icon
        end
    end
    return { itemID = id, itemName = name, itemLink = link, icon = icon, equipLoc = equipLoc }
end

-- Links and item IDs resolve directly; any other text runs the AH search.
function SalesWatchUI:HandleTyped(text)
    text = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return
    end
    if text:find("|Hitem:") or tonumber(text) then
        self:SetItemFromRef(text)
    else
        self:StartSearch(text)
    end
end

function SalesWatchUI:SetItemFromRef(ref)
    if ref == nil then
        return
    end
    local text = tostring(ref):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return
    end
    local itemID = tonumber(text:match("item:(%d+)")) or tonumber(text)
    local lookup = text:find("|H") and text or itemID or text
    local item = ItemFromInfo(itemID, lookup)
    if item then
        self:SetItem(item)
        return
    end
    if itemID and Item and Item.CreateFromItemID then
        local pending = Item:CreateFromItemID(itemID)
        self:SetMessage("Loading item...")
        pending:ContinueOnItemLoad(function()
            local loaded = ItemFromInfo(itemID, lookup)
            if loaded then
                self:SetItem(loaded)
            else
                self:SetMessage("Item not found. Type its name and press Enter to search.")
            end
        end)
        return
    end
    self:SetMessage("Item not found. Type its name and press Enter to search.")
end

function SalesWatchUI:SetItem(item)
    local engine = GetEngine()
    if engine and engine:IsRunning() then
        return
    end
    self.item = item
    local w = self.widgets
    if not w then
        return
    end
    self:HideList()
    w.slotIcon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    local header = item.itemLink or item.itemName or ""
    if (tonumber(item.versions) or 0) > 1 then
        header = header .. "  |cff9d9d9d(" .. item.versions .. " versions)|r"
    end
    w.itemName:SetText(header)
    w.input:SetText("")
    w.input:ClearFocus()
    self:SetMessage(string.format("Ready. Hit Watch and stay on this page for %s.",
        Clock(engine and engine.DURATION or 180)))
    self:Refresh()
end

-- Right-click the slot: empty the page (Brian, 2026-11-16). Not while a
-- watch is running.
function SalesWatchUI:ClearItem()
    local engine = GetEngine()
    if engine and engine:IsRunning() then
        self:SetMessage("Stop the watch to clear the item.")
        return
    end
    self.item = nil
    local w = self.widgets
    if not w then
        return
    end
    self:HideList()
    w.slotIcon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
    w.itemName:SetText("")
    w.input:SetText("")
    self:SetMessage(HINT)
    self:Refresh()
end

function SalesWatchUI:TakeCursorItem()
    if not GetCursorInfo then
        return
    end
    local kind, itemID, itemLink = GetCursorInfo()
    if kind == "item" then
        ClearCursor()
        self:SetItemFromRef(itemLink or itemID)
    end
end

-- Shift-clicking an item calls the chat link insert. While this page is
-- open and idle, take the link. Confirmed in-game 2026-11-16 (bags, recipes).
function SalesWatchUI:HookLinkInsert()
    if self.linkHooked then
        return
    end
    self.linkHooked = true
    local function OnInsert(link)
        local page = self.widgets and self.widgets.page
        local engine = GetEngine()
        if page and page:IsVisible() and not (engine and engine:IsRunning())
            and type(link) == "string" and link:find("|Hitem:") then
            self:SetItemFromRef(link)
        end
    end
    if type(_G.ChatEdit_InsertLink) == "function" then
        hooksecurefunc("ChatEdit_InsertLink", OnInsert)
    end

    -- Shift-click on a stack also means "split stack". Blizzard's
    -- ChatFrameUtil.InsertLink (Mainline ChatFrameUtilOverrides.lua) offers the
    -- link to AuctionHouseFrame:SetSearchText, which says yes only on the Buy
    -- tab; a yes means handled, so no split box opens. On this page it said
    -- no, the split box opened and took the keyboard (Brian, 2026-11-16).
    -- While this page is open and idle, say yes like the Buy tab does; the
    -- hook above takes the item. Everywhere else it is Blizzard's original.
    local ah = _G.AuctionHouseFrame
    if ah and type(ah.SetSearchText) == "function" then
        local original = ah.SetSearchText
        ah.SetSearchText = function(frame, text, ...)
            local page = self.widgets and self.widgets.page
            local engine = GetEngine()
            if page and page:IsVisible() and not (engine and engine:IsRunning()) then
                return true
            end
            return original(frame, text, ...)
        end
    end
    if type(_G.ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsert)
    end
end

---------------------------------------------------------------------------
-- Picking an item: AH search list (same browse search as the Buy tab)
---------------------------------------------------------------------------

local function ItemKeyInfo(itemKey)
    if not (C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo) then
        return nil
    end
    local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
    return ok and type(info) == "table" and info or nil
end

function SalesWatchUI:StartSearch(text)
    if not (C_AuctionHouse and C_AuctionHouse.SendBrowseQuery) then
        self:SetMessage("The Auction House search isn't available.")
        return
    end
    self.searchText = text
    self.searching = true
    self.results = {}
    self.listOffset = 0
    local ok = pcall(C_AuctionHouse.SendBrowseQuery, {
        searchString = text,
        sorts = BuildSorts(),
        filters = {},
        itemClassFilters = {},
    })
    if not ok then
        self.searching = false
        self:SetMessage("Search failed. Try again.")
        return
    end
    self:SetMessage("Searching for \"" .. text .. "\"...")
    self:ShowList()
end

-- One row per item (gear at several item levels collapses into one; a
-- watch covers every version). Exact name matches first, then most listed.
function SalesWatchUI:BuildResults()
    local rows = {}
    if C_AuctionHouse and C_AuctionHouse.GetBrowseResults then
        local ok, result = pcall(C_AuctionHouse.GetBrowseResults)
        if ok and type(result) == "table" then
            rows = result
        end
    end
    local byItem, list = {}, {}
    for _, row in ipairs(rows) do
        local key = row.itemKey
        local itemID = key and tonumber(key.itemID)
        if itemID then
            local entry = byItem[itemID]
            if not entry then
                entry = { itemID = itemID, itemKey = key, quantity = 0, versions = 0 }
                byItem[itemID] = entry
                list[#list + 1] = entry
            end
            entry.versions = entry.versions + 1
            entry.quantity = entry.quantity + (tonumber(row.totalQuantity) or 0)
            local price = tonumber(row.minPrice)
            if price and price > 0 and (not entry.minPrice or price < entry.minPrice) then
                entry.minPrice = price
            end
        end
    end
    local wanted = tostring(self.searchText or ""):lower()
    for _, entry in ipairs(list) do
        local info = ItemKeyInfo(entry.itemKey)
        local name, link, quality, _, _, _, _, _, equipLoc, icon = GetItemInfo(entry.itemID)
        -- Base name from the item ID first: the browse row's name can carry
        -- one version's suffix ("of Agility") while the watch covers all.
        entry.name = name or (info and info.itemName)
        entry.icon = info and info.iconFileID or icon
        entry.quality = info and info.quality or quality
        entry.isEquipment = info and info.isEquipment == true or nil
        entry.equipLoc = equipLoc
        entry.link = link
        entry.exact = entry.name and entry.name:lower() == wanted or false
    end
    table.sort(list, function(a, b)
        if a.exact ~= b.exact then
            return a.exact
        end
        if a.quantity ~= b.quantity then
            return a.quantity > b.quantity
        end
        return (a.name or "") < (b.name or "")
    end)
    self.results = list
end

function SalesWatchUI:OnBrowseEvent(event)
    if event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
        if self.results and #self.results > 0 and self.widgets and self.widgets.list:IsShown() then
            self:BuildResults()
            self:DrawList()
        end
        return
    end
    if not self.searching then
        return
    end
    if event == "AUCTION_HOUSE_BROWSE_FAILURE" then
        self.searching = false
        self:SetMessage("Search failed. Try again.")
        return
    end
    self:BuildResults()
    self.searching = false
    if #self.results == 0 then
        self:SetMessage("Nothing listed for \"" .. tostring(self.searchText) .. "\". Try another name.")
    else
        self:SetMessage(string.format("%d found. Click one to pick it.", #self.results))
    end
    self:DrawList()
end

function SalesWatchUI:ShowList()
    local w = self.widgets
    if w then
        w.list:Show()
        self:DrawList()
    end
end

function SalesWatchUI:HideList()
    local w = self.widgets
    if w then
        w.list:Hide()
    end
    self.searching = false
end

function SalesWatchUI:DrawList()
    local w = self.widgets
    if not w then
        return
    end
    local results = self.results or {}
    local maxOffset = math.max(0, #results - LIST_ROWS)
    self.listOffset = math.min(math.max(0, self.listOffset or 0), maxOffset)
    for i, button in ipairs(w.listRows) do
        local entry = results[i + self.listOffset]
        if entry then
            button.entry = entry
            button.Icon:SetTexture(entry.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            local name = entry.name or ("Item " .. entry.itemID)
            local color = entry.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[entry.quality]
            if color and color.hex then
                name = color.hex .. name .. "|r"
            end
            button.Name:SetText(name)
            local info = Number(entry.quantity) .. " listed, from " .. Money(entry.minPrice)
            if (entry.versions or 0) > 1 then
                info = entry.versions .. " versions, " .. info
            end
            button.Info:SetText(info)
            button:Show()
        else
            button.entry = nil
            button:Hide()
        end
    end
    if #results > LIST_ROWS then
        w.listMore:SetText(string.format("%d-%d of %d (scroll for more)", self.listOffset + 1,
            math.min(#results, self.listOffset + LIST_ROWS), #results))
    else
        w.listMore:SetText("")
    end
end

function SalesWatchUI:PickResult(entry)
    if not entry then
        return
    end
    self:SetItem({
        itemID = entry.itemID,
        itemName = entry.name,
        itemLink = entry.link,
        icon = entry.icon,
        equipLoc = entry.equipLoc,
        isEquipment = entry.isEquipment,
        versions = entry.versions,
    })
end

function SalesWatchUI:EnsureBrowseEvents()
    if self.browseFrame then
        return
    end
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    frame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
    frame:RegisterEvent("ITEM_KEY_ITEM_INFO_RECEIVED")
    frame:SetScript("OnEvent", function(_, event)
        self:OnBrowseEvent(event)
    end)
    self.browseFrame = frame
end

---------------------------------------------------------------------------
-- Building the page (once per page frame)
---------------------------------------------------------------------------

local function Label(parent, font, x, y, width)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetWidth(width or 200)
    label:SetJustifyH("LEFT")
    return label
end

local function Button(parent, text, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

function SalesWatchUI:BuildList(parent)
    local w = self.widgets
    local list = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    list:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -68)
    list:SetSize(560, LIST_ROWS * LIST_ROW_HEIGHT + 34)
    list:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    list:SetBackdropColor(0.04, 0.04, 0.04, 0.98)
    list:SetFrameLevel(parent:GetFrameLevel() + 20)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        self.listOffset = (self.listOffset or 0) - delta * 3
        self:DrawList()
    end)
    list:Hide()

    w.listRows = {}
    for i = 1, LIST_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(540, LIST_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 10, -6 - (i - 1) * LIST_ROW_HEIGHT)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        local icon = row:CreateTexture(nil, "ARTWORK")
        icon:SetSize(18, 18)
        icon:SetPoint("LEFT", row, "LEFT", 2, 0)
        local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        name:SetWidth(300)
        name:SetJustifyH("LEFT")
        local info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        info:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        info:SetWidth(220)
        info:SetJustifyH("RIGHT")
        row.Icon, row.Name, row.Info = icon, name, info
        row:SetScript("OnClick", function(button)
            self:PickResult(button.entry)
        end)
        row:Hide()
        w.listRows[i] = row
    end

    local more = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    more:SetPoint("BOTTOMLEFT", list, "BOTTOMLEFT", 12, 8)
    w.listMore = more
    local close = Button(list, "Close", 70, function() self:HideList() end)
    close:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", -8, 6)
    w.list = list
end

-- Gear: one row per version that had activity, in a box that scrolls with
-- the mouse wheel so a busy item never runs off the page (Brian, 2026-11-16).
function SalesWatchUI:BuildVersionBox(parent, top)
    local w = self.widgets
    local box = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    box:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, top)
    box:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -16, 6)
    box:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    box:SetBackdropColor(0.04, 0.04, 0.04, 0.6)
    if box.SetClipsChildren then box:SetClipsChildren(true) end
    box:EnableMouseWheel(true)
    box:SetScript("OnMouseWheel", function(_, delta)
        self.versionOffset = (self.versionOffset or 0) - delta * 3
        self:DrawVersions()
    end)
    box:SetScript("OnSizeChanged", function()
        self:LayoutVersionColumns()
        self:DrawVersions()
    end)
    box:Hide()

    -- Positions are set by LayoutVersionColumns once the box has a width.
    w.versionCells = {}
    local function Cell(row, col, font)
        local text = row:CreateFontString(nil, "OVERLAY", font)
        text:SetJustifyH(col.justify)
        if text.SetWordWrap then text:SetWordWrap(false) end
        w.versionCells[#w.versionCells + 1] = { text = text, row = row, key = col.key }
        return text
    end

    local header = CreateFrame("Frame", nil, box)
    header:SetPoint("TOPLEFT", box, "TOPLEFT", 4, -6)
    header:SetPoint("TOPRIGHT", box, "TOPRIGHT", -4, -6)
    header:SetHeight(VERSION_ROW_HEIGHT)
    for _, col in ipairs(VERSION_COLUMNS) do
        Cell(header, col, "GameFontNormalSmall"):SetText(col.title)
    end
    w.versionMore = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    w.versionMore:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -8, 6)

    w.versionRows = {}
    for i = 1, VERSION_ROW_POOL do
        local row = CreateFrame("Frame", nil, box)
        row:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2 - (i - 1) * VERSION_ROW_HEIGHT)
        row:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -2 - (i - 1) * VERSION_ROW_HEIGHT)
        row:SetHeight(VERSION_ROW_HEIGHT)
        row.cells = {}
        for _, col in ipairs(VERSION_COLUMNS) do
            row.cells[col.key] = Cell(row, col, "GameFontHighlightSmall")
        end
        row:Hide()
        w.versionRows[i] = row
    end
    w.versionBox = box
end

-- Spread the columns across the box's current width.
function SalesWatchUI:LayoutVersionColumns()
    local w = self.widgets
    local box = w and w.versionBox
    if not box or not w.versionCells then
        return
    end
    local width = (box:GetWidth() or 0) - 24   -- row insets + left padding
    if width <= 0 then
        return
    end
    local spots, x = {}, 8
    for _, col in ipairs(VERSION_COLUMNS) do
        local colWidth = math.floor(width * col.share) - VERSION_COLUMN_GAP
        spots[col.key] = { x = x, width = math.max(10, colWidth) }
        x = x + math.floor(width * col.share)
    end
    for _, cell in ipairs(w.versionCells) do
        local spot = spots[cell.key]
        cell.text:ClearAllPoints()
        cell.text:SetPoint("LEFT", cell.row, "LEFT", spot.x, 0)
        cell.text:SetWidth(spot.width)
    end
end

-- How many rows fit in the box right now (header and footer left out).
local function VisibleVersionRows(box)
    local height = box and box:GetHeight() or 0
    return math.max(0, math.min(VERSION_ROW_POOL, math.floor((height - VERSION_ROW_HEIGHT - 30) / VERSION_ROW_HEIGHT)))
end

function SalesWatchUI:DrawVersions()
    local w = self.widgets
    if not w or not w.versionBox then
        return
    end
    local lines = self.versionLines or {}
    local visible = VisibleVersionRows(w.versionBox)
    local maxOffset = math.max(0, #lines - visible)
    self.versionOffset = math.min(math.max(0, self.versionOffset or 0), maxOffset)
    for i, row in ipairs(w.versionRows) do
        local line = i <= visible and lines[i + self.versionOffset] or nil
        if line then
            for _, col in ipairs(VERSION_COLUMNS) do
                row.cells[col.key]:SetText(line[col.key] or "")
            end
            row:Show()
        else
            row:Hide()
        end
    end
    if #lines > visible and visible > 0 then
        w.versionMore:SetText(string.format("%d-%d of %d (scroll for more)", self.versionOffset + 1,
            math.min(#lines, self.versionOffset + visible), #lines))
    else
        w.versionMore:SetText("")
    end
end

function SalesWatchUI:UpdateVersions(engine, run)
    local w = self.widgets
    if not w or not w.versionBox then
        return
    end
    if not run or run.mode ~= "item" or not engine.GetVersionRows then
        w.versionBox:Hide()
        self.versionLines = nil
        return
    end
    local active, quiet = engine:GetVersionRows(run)
    local lines = {}
    for _, item in ipairs(active) do
        local entry = item.entry
        lines[#lines + 1] = {
            label = item.label,
            listed = Number(entry.firstListed) .. " -> " .. Number(entry.lastListed),
            lowest = Money(entry.firstLowest) .. " -> " .. Money(entry.lastLowest),
            sold = Number(item.sold),
            gone = Number(entry.leftHigher),
            new = Number(entry.newListed),
        }
    end
    if #active == 0 then
        lines[#lines + 1] = { label = "|cff9d9d9dNo changes yet.|r" }
    end
    if quiet > 0 and #active > 0 then
        lines[#lines + 1] = { label = string.format("|cff9d9d9d%d other version%s: no change|r", quiet,
            quiet == 1 and "" or "s") }
    end
    self.versionLines = lines
    w.versionBox:Show()
    self:LayoutVersionColumns()
    self:DrawVersions()
end

function SalesWatchUI:Render(parent)
    self:HookLinkInsert()
    self:EnsureBrowseEvents()
    if self.widgets and self.widgets.page == parent then
        self:Refresh()
        return
    end

    local w = { page = parent }
    self.widgets = w

    local slot = CreateFrame("Button", nil, parent, "BackdropTemplate")
    slot:SetSize(40, 40)
    slot:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -4)
    slot:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    local icon = slot:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 3, -3)
    icon:SetPoint("BOTTOMRIGHT", -3, 3)
    icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
    slot:RegisterForDrag("LeftButton")
    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    slot:SetScript("OnReceiveDrag", function() self:TakeCursorItem() end)
    slot:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            self:ClearItem()
        else
            self:TakeCursorItem()
        end
    end)
    slot:SetScript("OnEnter", function(button)
        if self.item and self.item.itemLink and GameTooltip then
            GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.item.itemLink)
            GameTooltip:Show()
        end
    end)
    slot:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    w.slot, w.slotIcon = slot, icon

    local input = CreateFrame("EditBox", nil, parent, "SearchBoxTemplate")
    input:SetSize(220, 20)
    input:SetPoint("TOPLEFT", parent, "TOPLEFT", 70, -6)
    input:SetAutoFocus(false)
    input:SetScript("OnEnterPressed", function(box)
        self:HandleTyped(box:GetText())
        box:ClearFocus()
    end)
    input:HookScript("OnEscapePressed", function() self:HideList() end)
    input:SetScript("OnReceiveDrag", function() self:TakeCursorItem() end)
    w.input = input

    local watch = Button(parent, "Watch", 80, function() self:StartWatch() end)
    watch:SetPoint("TOPLEFT", parent, "TOPLEFT", 300, -5)
    w.watch = watch

    local stop = Button(parent, "Stop", 64, function()
        local engine = GetEngine()
        if engine then engine:Stop("stop-button") end
    end)
    stop:SetPoint("LEFT", watch, "RIGHT", 6, 0)
    w.stop = stop

    local more = Button(parent, "Watch 3 more minutes", 160, function() self:ExtendWatch() end)
    more:SetPoint("LEFT", stop, "RIGHT", 6, 0)
    w.more = more
    -- Why the button is gray once a watch hits the cap (Brian, 2026-11-16).
    local capNote = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    capNote:SetPoint("TOP", more, "BOTTOM", 0, -2)
    capNote:SetText("Capped at 10 minutes")
    capNote:Hide()
    w.capNote = capNote

    w.itemName = Label(parent, "GameFontNormal", 72, -30, 380)
    w.itemName:SetText("")
    w.message = Label(parent, "GameFontHighlightSmall", 16, -52, 740)

    local bar = CreateFrame("StatusBar", nil, parent, "BackdropTemplate")
    bar:SetSize(500, 12)
    bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -70)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.2, 0.7, 0.3)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    bar:SetBackdropColor(0.12, 0.12, 0.12, 1)
    w.bar = bar
    w.clock = Label(parent, "GameFontHighlightSmall", 524, -69, 160)

    w.headline = Label(parent, "GameFontNormalLarge", 16, -92, 740)
    if w.headline.SetWordWrap then w.headline:SetWordWrap(true) end

    w.rows = {}
    local y = -132
    for _, def in ipairs(DETAIL_ROWS) do
        local name = Label(parent, "GameFontHighlightSmall", 16, y, 230)
        name:SetText(def.label)
        local value = Label(parent, "GameFontHighlightSmall", 250, y, 210)
        w.rows[def.key] = value
        w.rowLabels = w.rowLabels or {}
        w.rowLabels[def.key] = name
        y = y - 16
    end

    -- Note sits to the right of the stats (Brian, 2026-11-16: it overlapped
    -- the page tabs when stacked under them).
    w.note = Label(parent, "GameFontDisableSmall", 470, -132, 260)
    if w.note.SetWordWrap then w.note:SetWordWrap(true) end
    w.note:SetText("Your sales are certain. Buyers can only buy the cheapest units, so anything that "
        .. "left while something cheaper was still listed was canceled or expired, and the rest most "
        .. "likely sold. Counts are minimums: a cheap listing bought within seconds can't be seen. A "
        .. "slow seller can show nothing in a few minutes and still sell later.")

    self:BuildVersionBox(parent, y - 8)
    self:BuildList(parent)

    -- Leaving the page stops the watch (the player has to stay here).
    -- keepRunningOffPage: dev-only test switch, /mcgd saleswatch keep.
    parent:HookScript("OnHide", function()
        self:HideList()
        local engine = GetEngine()
        if engine and engine:IsRunning() and not engine.keepRunningOffPage then
            engine:Stop("left-page")
        end
    end)

    local engine = GetEngine()
    if engine then
        engine:SetListener(function()
            self:Refresh()
        end)
    end

    self:SetMessage(HINT)
    self:Refresh()
end

---------------------------------------------------------------------------
-- Drawing state
---------------------------------------------------------------------------

function SalesWatchUI:SetMessage(text)
    if self.widgets then
        self.widgets.message:SetText(text or "")
    end
end

function SalesWatchUI:StartWatch()
    local engine = GetEngine()
    if not engine then
        self:SetMessage("Item Watch isn't loaded.")
        return
    end
    if not self.item then
        self:SetMessage(HINT)
        return
    end
    self:HideList()
    local ok, err = engine:Start(self.item)
    if not ok then
        self:SetMessage(err)
    end
    self:Refresh()
end

function SalesWatchUI:ExtendWatch()
    local engine = GetEngine()
    if not engine then
        return
    end
    self:HideList()
    local ok, err = engine:Extend(self.item)
    if not ok then
        self:SetMessage(err)
    end
    self:Refresh()
end

local STOP_REASONS = {
    ["left-page"] = "Stopped: you left the page.",
    ["ah-closed"] = "Stopped: the Auction House closed.",
    ["stop-button"] = "Stopped.",
}

function SalesWatchUI:Headline(engine, run)
    if #run.steps == 0 then
        if run.status == "running" then
            return "Watching..."
        end
        return "Not enough refreshes to tell. Try again."
    end
    local totals = run.totals
    local window = Clock(engine:WatchedSeconds(run))
    local sold = totals.soldMine + totals.soldCheap
    local parts = {}
    if sold > 0 then
        local text = string.format("In %s, at least %s sold", window, Number(sold))
        local extra = {}
        -- Gear with several versions: name the version when all sales were in one.
        if run.mode == "item" and engine.GetVersionRows then
            local active, _, total = engine:GetVersionRows(run)
            local withSales = {}
            for _, item in ipairs(active) do
                if item.sold > 0 then withSales[#withSales + 1] = item end
            end
            if total > 1 and #withSales == 1 then
                extra[#extra + 1] = withSales[1].label
            end
        end
        if totals.soldMine > 0 then
            extra[#extra + 1] = string.format("%s of them yours", Number(totals.soldMine))
        end
        if #extra > 0 then
            text = text .. " (" .. table.concat(extra, ", ") .. ")"
        end
        parts[#parts + 1] = text .. "."
    else
        parts[#parts + 1] = string.format("No sales seen in %s.", window)
    end
    if totals.leftHigher > 0 then
        parts[#parts + 1] = string.format("%s canceled or expired.", Number(totals.leftHigher))
    end
    parts[#parts + 1] = string.format("%s new listed.", Number(totals.newListed))
    local snaps = run.snapshots
    local first, last = snaps[1], snaps[#snaps]
    if first.lowestAll and last.lowestAll then
        if last.lowestAll < first.lowestAll then
            parts[#parts + 1] = "Price dropped."
        elseif last.lowestAll > first.lowestAll then
            parts[#parts + 1] = "Price went up."
        else
            parts[#parts + 1] = "Price held."
        end
    end
    return table.concat(parts, " ")
end

function SalesWatchUI:Refresh()
    local w = self.widgets
    if not w then
        return
    end
    local engine = GetEngine()
    local run = engine and engine:GetRun()
    local running = engine and engine:IsRunning() or false

    -- A run only shows while its item is still the one picked.
    if run and not running and (not self.item or run.item.itemID ~= self.item.itemID) then
        run = nil
    end

    w.watch:SetEnabled(not running and self.item ~= nil)
    w.stop:SetEnabled(running)
    local extend = (run and engine) and engine:ExtendAmount(self.item) or 0
    if extend > 0 and extend < (engine.EXTEND or 180) then
        w.more:SetText("Watch " .. Clock(extend) .. " more")
    else
        w.more:SetText("Watch 3 more minutes")
    end
    w.more:SetEnabled(extend > 0)
    local capped = run ~= nil and extend <= 0 and #run.snapshots > 0
        and (run.planned or 0) >= (engine.MAX_TOTAL or 600) - 0.5
    w.capNote:SetShown(capped)
    if running then
        w.input:Disable()
    else
        w.input:Enable()
    end

    if not run then
        w.bar:SetValue(0)
        w.clock:SetText("")
        w.headline:SetText("")
        for _, def in ipairs(DETAIL_ROWS) do
            w.rows[def.key]:SetText("")
        end
        self:UpdateVersions(engine, nil)
        return
    end

    local watched = engine:WatchedSeconds(run)
    local planned = math.max(1, run.planned or 1)
    w.bar:SetValue(math.min(1, watched / planned))
    if running then
        w.clock:SetText(Clock(run.segmentEnd - GetTime()) .. " left")
    else
        w.clock:SetText(Clock(watched) .. " watched")
    end

    if running then
        w.message:SetText("Watching. Stay on this page. Leaving it stops the watch.")
    elseif run.status == "done" then
        if extend > 0 then
            w.message:SetText("Done. Not sure yet? Watch 3 more minutes.")
        else
            w.message:SetText("Done.")
        end
    else
        w.message:SetText(STOP_REASONS[run.stopReason] or "Stopped.")
    end
    w.headline:SetText(self:Headline(engine, run))

    local totals = run.totals
    local snaps = run.snapshots
    local first, last = snaps[1], snaps[#snaps]
    local values = {
        soldMine = Number(totals.soldMine),
        soldCheap = Number(totals.soldCheap),
        leftHigher = Number(totals.leftHigher),
        newListed = Number(totals.newListed),
        lowest = first and (Money(first.lowestAll) .. "  ->  " .. Money(last.lowestAll)) or "-",
        total = first and (Number(first.total) .. "  ->  " .. Number(last.total)) or "-",
        refreshes = Number(#snaps) .. (run.missed > 0 and ("  (" .. run.missed .. " missed)") or ""),
    }
    for _, def in ipairs(DETAIL_ROWS) do
        w.rows[def.key]:SetText(values[def.key] or "")
        if w.rowLabels and w.rowLabels[def.key] then
            w.rowLabels[def.key]:SetText(run.mode == "item" and def.gearLabel or def.label)
        end
    end
    self:UpdateVersions(engine, run)
end
