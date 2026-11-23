-- PocketCFO/Services/ShoppingList/ShoppingListWindow.lua
-- The shopping list window (design: claude/Shopping_List_Design.md, steps 3
-- and 5). Flavor: Both. Moved from PocketCFO_AH/UI/ShoppingListUI.lua to
-- core on 2026-11-21 so it opens anywhere (PocketCFO_AH only loads with the
-- AH UI).
--
-- The list itself (what to buy, how much is covered) is core
-- PocketCFO.ShoppingList. This file draws it, opens a line in Blizzard's
-- buy screen, and tells the list when a purchase is confirmed.
--
-- Where it shows:
--   * At the AH: docked on the AH's right edge, same size and look as the
--     recipe analysis side window (350 x 400). Opens by itself when the AH
--     opens and the list has something to buy; the X keeps it closed until
--     the next AH open. Closes with the AH.
--   * Add row (Brian, 2026-11-22): type a name (matches from the price
--     cache), Shift-click an item link into the box, or drag an item onto
--     the window; set the amount; Add. A manual add buys exactly that many
--     (what you own is not taken off).
--   * Vendor (Brian, 2026-11-22): the list has an "Auction House" and a
--     "Vendor" section. An item with a buy-from-a-vendor price goes under
--     Vendor when the vendor is cheaper than the cheapest AH price, or the
--     AH has none (decided each draw). At a vendor that sells anything on the
--     list, the list opens docked to the vendor window; rows that vendor
--     sells are lit, the rest dimmed, and clicking a lit row buys what's
--     needed (BuyMerchantItem). Vendor buys, from the list or the vendor
--     window, are counted by the bag count going up afterwards, so a buy
--     that fails (gold, bag space) is never counted.
--   * Anywhere: Shift-click on the minimap button (MinimapButton.lua)
--     toggles it. Away from the AH it stands alone and can be dragged by its
--     title; clicking a line says to open the AH.
--
-- Opening a line (confirmed in-game on Forever and retail, 2026-11-21,
-- /mcgd buytest):
--   1. our own commodity search (C_AuctionHouse.SendSearchQuery)
--   2. AuctionHouseFrame:SelectBrowseResult({ itemKey, minPrice, totalQuantity })
--      minPrice is required: without it Blizzard_MoneyFrame errors.
--   3. BuyDisplay:SetQuantitySelected(toBuy) after every buy-screen results
--      update (each update resets it to 1), until the player changes the
--      quantity or presses Buy, or QUANTITY_HOLD_SECONDS pass.
-- Commodities only. Any other item: its name goes in Blizzard's search box
-- (Theoretical: AuctionHouseFrame.SearchBar SetSearchText / StartSearch).
--
-- Recording a purchase (confirmed 2026-11-21): COMMODITY_PURCHASE_SUCCEEDED
-- has no payload, so the item and quantity come from a hooked
-- C_AuctionHouse.ConfirmCommoditiesPurchase(itemID, quantity). Hooks go in
-- at the first AH open. Counts every confirmed commodity buy, clicked from
-- the list or not; items not on the list are ignored by the list.
--
-- Prices are PCFO Values from PocketCFO_Valuation; when that addon isn't
-- loaded yet (no AH or profession opened this session), lines say
-- "No price".

local PocketCFO = _G.PocketCFO
local ShoppingListWindow = PocketCFO:NewModule("ShoppingListWindow", "AceEvent-3.0")

local WIDTH, HEIGHT = 350, 400
local ROW_HEIGHT = 30
local TOP_OFFSET = 62
local FOOTER_HEIGHT = 56
local VISIBLE_ROWS = math.floor((HEIGHT - TOP_OFFSET - FOOTER_HEIGHT) / ROW_HEIGHT)
local QUANTITY_HOLD_SECONDS = 3

local NOTE_COLOR = { 0.6, 0.6, 0.6 }

local function Core()
    return PocketCFO
end

local function List()
    local core = Core()
    return core and core.ShoppingList or nil
end

local function Valuation(name)
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule(name, true) or nil
end

local function Money(value)
    local tooltip = Valuation("Tooltip")
    if tooltip and tooltip.FormatMoney then
        return tooltip:FormatMoney(value) or ""
    end
    local core = Core()
    if core and core.FormatMoney then
        return core:FormatMoney(value)
    end
    return tostring(math.floor((tonumber(value) or 0) + 0.5)) .. "c"
end

-- PCFO Value per unit, or nil when there is none (never 0 for missing).
local function UnitValue(itemID)
    local service = Valuation("ValuationService")
    if not service or not service.GetItemValue then
        return nil
    end
    local ok, result = pcall(service.GetItemValue, service, itemID)
    if not ok or type(result) ~= "table" or result.unresolved then
        return nil
    end
    return tonumber(result.valuePerUnit or result.value)
end

-- Buy-from-a-vendor price per unit (PocketCFO_Valuation VendorPriceService:
-- your own vendor visits first, then bundled defaults), or nil.
local function VendorUnitPrice(itemID)
    local service = Valuation("VendorPriceService")
    if not service or not service.GetPrice then
        return nil
    end
    local ok, result = pcall(service.GetPrice, service, itemID)
    if ok and type(result) == "table" and result.resolved then
        return tonumber(result.value)
    end
    return nil
end

-- Cheapest AH price per unit from the scanned price cache, or nil. Read
-- straight from the cache because an item's PCFO Value can itself be the
-- vendor price.
local function AuctionUnitPrice(itemID)
    local cache = Valuation("PricingCache")
    if not cache or not cache.GetCandidatesForItemID then
        return nil
    end
    local ok, rows = pcall(cache.GetCandidatesForItemID, cache, itemID)
    local best
    for _, row in ipairs(ok and rows or {}) do
        local value = type(row) == "table" and (tonumber(row.value) or tonumber(row.copperValue)
            or tonumber(row.unitPrice) or tonumber(row.buyout))
        if value and value > 0 and (not best or value < best) then
            best = value
        end
    end
    return best
end

local function ItemName(itemID)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    return name
end

local function ItemIcon(itemID)
    return (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID))
        or "Interface\\Icons\\INV_Misc_QuestionMark"
end

local function Log(fmt, ...)
    local core = Core()
    if core and core.Debug then
        core:Debug("ShoppingListWindow: " .. fmt, ...)
    end
end

local function Notify(text)
    local core = Core()
    if core and core.Print then
        core:Print(text)
    end
end

-- ---------------------------------------------------------------------------
-- Add row: find an item by name (2026-11-22)
-- Names come from this realm group's price cache (PocketCFO_Valuation
-- PricingCache:GetCache(): rows carry itemID, itemName, qualityTier), so
-- anything seen in an AH scan can be found. Built once in memory the first
-- time you type and rebuilt only if the cache table is replaced. Rows saved
-- without a name use the game's name if it's loaded.
-- ---------------------------------------------------------------------------

local MAX_SUGGESTIONS = 8
local nameIndex, nameIndexFor

local function NameIndex()
    local cacheModule = Valuation("PricingCache")
    local cache = cacheModule and cacheModule.GetCache and cacheModule:GetCache()
    if type(cache) ~= "table" then
        return nil
    end
    if nameIndex and nameIndexFor == cache then
        return nameIndex
    end
    local byID = {}
    for _, row in pairs(cache) do
        local itemID = type(row) == "table" and tonumber(row.itemID)
        if itemID and not byID[itemID] then
            local name = row.itemName or ItemName(itemID)
            if type(name) == "string" and name ~= "" then
                byID[itemID] = { itemID = itemID, name = name, lower = name:lower(),
                    quality = tonumber(row.qualityTier) }
            end
        end
    end
    local list = {}
    for _, entry in pairs(byID) do
        list[#list + 1] = entry
    end
    nameIndex, nameIndexFor = list, cache
    return list
end

-- Up to MAX_SUGGESTIONS items whose name contains the text; names that
-- start with it first, then shorter names.
local function FindItems(text)
    text = (text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if #text < 2 then
        return {}
    end
    local index = NameIndex()
    if not index then
        return {}
    end
    local hits = {}
    for _, entry in ipairs(index) do
        local at = entry.lower:find(text, 1, true)
        if at then
            hits[#hits + 1] = { entry = entry, prefix = at == 1 }
        end
    end
    table.sort(hits, function(a, b)
        if a.prefix ~= b.prefix then
            return a.prefix
        end
        if #a.entry.name ~= #b.entry.name then
            return #a.entry.name < #b.entry.name
        end
        if a.entry.name ~= b.entry.name then
            return a.entry.name < b.entry.name
        end
        return (a.entry.quality or 0) < (b.entry.quality or 0)
    end)
    local results = {}
    for i = 1, math.min(MAX_SUGGESTIONS, #hits) do
        results[i] = hits[i].entry
    end
    return results
end

local function DisplayName(entry)
    if entry.quality and entry.quality > 0 then
        return entry.name .. "  Q" .. entry.quality
    end
    return entry.name
end

-- ---------------------------------------------------------------------------
-- Confirmations
-- ---------------------------------------------------------------------------

-- Never assign StaticPopupDialogs itself: writing that global from addon
-- code taints it, and Blizzard's logout / Escape menu then get blocked
-- ("blocked from an action only available to the Blizzard UI", 2026-11-21).
-- Adding our own keys to the table is fine.
StaticPopupDialogs["MCG_SHOPPING_LIST_CLEAR"] = {
    text = "Clear your whole shopping list?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
        local list = List()
        if list then
            list:Clear()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
StaticPopupDialogs["MCG_SHOPPING_LIST_REMOVE"] = {
    text = "Remove %s from your shopping list?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function(_, data)
        local list = List()
        if list and data then
            list:Remove(data)
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- ---------------------------------------------------------------------------
-- Opening a line in Blizzard's buy screen
-- ---------------------------------------------------------------------------

local function BuyDisplay()
    local ah = _G.AuctionHouseFrame
    local buyFrame = ah and ah.CommoditiesBuyFrame
    return buyFrame and buyFrame.BuyDisplay or nil
end

-- Theoretical: ItemKeyInfo.isCommodity (nil until the item key info is
-- loaded; treated as a commodity then, since list items are mats and crates).
local function IsCommodity(itemKey)
    if C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
        local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
        if ok and type(info) == "table" and info.isCommodity ~= nil then
            return info.isCommodity == true
        end
    end
    return true
end

function ShoppingListWindow:StopHoldingQuantity()
    self.hold = nil
end

function ShoppingListWindow:ApplyHeldQuantity()
    local hold = self.hold
    if not hold then
        return
    end
    if (GetTime and GetTime() or 0) > hold.untilTime then
        self.hold = nil
        return
    end
    local display = BuyDisplay()
    if display and display.SetQuantitySelected then
        local ok = pcall(display.SetQuantitySelected, display, hold.qty)
        hold.lastSet = hold.qty
        Log("quantity set itemID=%d qty=%d ok=%s", hold.itemID, hold.qty, tostring(ok))
    end
end

function ShoppingListWindow:OpenInBuyScreen(line)
    local ah = _G.AuctionHouseFrame
    if not ah or not ah:IsShown() or not C_AuctionHouse then
        Notify("Open the Auction House to buy.")
        return
    end
    self.selectedItemID = line.itemID
    self:Refresh()

    local itemKey = C_AuctionHouse.MakeItemKey and C_AuctionHouse.MakeItemKey(line.itemID)
    if not itemKey then
        return
    end

    if not IsCommodity(itemKey) then
        -- Theoretical: the Buy tab search box methods.
        local name = ItemName(line.itemID)
        local bar = ah.SearchBar
        -- Clear any category the player had picked (Weapons, etc.) so the
        -- name search covers everything (Brian, 2026-11-21: with Weapons
        -- selected, Green Linen Bracers searched inside Weapons and found
        -- nothing). Theoretical: AuctionHouseFrame.CategoriesList
        -- :SetSelectedCategory(nil) = no category (all).
        local categories = ah.CategoriesList
        if categories and categories.SetSelectedCategory then
            local ok, err = pcall(categories.SetSelectedCategory, categories, nil, nil, nil)
            Log("clear category ok=%s err=%s selected=%s", tostring(ok), tostring(err),
                tostring(categories.selectedCategoryIndex))
        else
            Log("clear category: no CategoriesList:SetSelectedCategory")
        end
        if name and bar and bar.SetSearchText and bar.StartSearch then
            pcall(bar.SetSearchText, bar, name)
            pcall(bar.StartSearch, bar)
        end
        return
    end

    self.pendingOpen = { itemID = line.itemID, itemKey = itemKey, qty = line.toBuy }
    self.hold = nil
    local sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    local ok, err = pcall(C_AuctionHouse.SendSearchQuery, itemKey, sorts, false)
    Log("open itemID=%d qty=%d search ok=%s err=%s", line.itemID, line.toBuy, tostring(ok), tostring(err))
    if not ok then
        self.pendingOpen = nil
    end
end

-- Our own search is back: open the buy screen with the cheapest price.
function ShoppingListWindow:FinishOpen(itemID)
    local pending = self.pendingOpen
    if not pending or pending.itemID ~= itemID then
        return
    end
    self.pendingOpen = nil
    local first = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, 1)
    if not first or not first.unitPrice then
        Notify("Nobody is selling " .. (ItemName(itemID) or ("item " .. itemID)) .. " right now.")
        return
    end
    local total = C_AuctionHouse.GetCommoditySearchResultsQuantity
        and C_AuctionHouse.GetCommoditySearchResultsQuantity(itemID) or nil
    local ah = _G.AuctionHouseFrame
    self.hold = {
        itemID = itemID,
        qty = pending.qty,
        untilTime = (GetTime and GetTime() or 0) + QUANTITY_HOLD_SECONDS,
    }
    local ok, err = pcall(ah.SelectBrowseResult, ah,
        { itemKey = pending.itemKey, minPrice = first.unitPrice, totalQuantity = total })
    Log("select itemID=%d minPrice=%s ok=%s err=%s", itemID, tostring(first.unitPrice), tostring(ok), tostring(err))
    if not ok then
        self.hold = nil
        return
    end
    self:HookQuantityTyping()
end

-- Stop holding the quantity as soon as the player types one.
-- Theoretical: BuyDisplay.QuantityInput.InputBox (the report on 2026-11-21
-- listed QuantityInput, not its children).
function ShoppingListWindow:HookQuantityTyping()
    if self.quantityTypingHooked then
        return
    end
    local display = BuyDisplay()
    local input = display and display.QuantityInput
    local box = input and input.InputBox
    if box and box.HookScript then
        box:HookScript("OnTextChanged", function(_, userInput)
            if userInput then
                self:StopHoldingQuantity()
            end
        end)
        self.quantityTypingHooked = true
    end
end

-- ---------------------------------------------------------------------------
-- Events: search results, purchase confirmed
-- ---------------------------------------------------------------------------

function ShoppingListWindow:OnSearchResults(itemID)
    itemID = tonumber(itemID)
    if not itemID then
        return
    end
    if self.pendingOpen and self.pendingOpen.itemID == itemID then
        C_Timer.After(0, function()
            self:FinishOpen(itemID)
        end)
    elseif self.hold and self.hold.itemID == itemID then
        C_Timer.After(0.05, function()
            self:ApplyHeldQuantity()
        end)
    end
end

function ShoppingListWindow:InstallPurchaseCapture()
    if self.purchaseHooked or not C_AuctionHouse or not hooksecurefunc then
        return
    end
    if type(C_AuctionHouse.StartCommoditiesPurchase) == "function" then
        hooksecurefunc(C_AuctionHouse, "StartCommoditiesPurchase", function()
            self:StopHoldingQuantity()
        end)
    end
    if type(C_AuctionHouse.ConfirmCommoditiesPurchase) == "function" then
        hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", function(itemID, quantity)
            self.pendingPurchase = { itemID = tonumber(itemID), qty = tonumber(quantity) }
        end)
    end
    self.purchaseHooked = true
end

function ShoppingListWindow:OnPurchaseSucceeded()
    local purchase = self.pendingPurchase
    self.pendingPurchase = nil
    local list = List()
    if purchase and purchase.itemID and purchase.qty and list then
        Log("purchase confirmed itemID=%d qty=%d", purchase.itemID, purchase.qty)
        list:RecordPurchase(purchase.itemID, purchase.qty)
    end
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Vendor (2026-11-22)
-- ---------------------------------------------------------------------------

local function ItemIDFromLink(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function MerchantOpen()
    local merchant = _G.MerchantFrame
    return merchant ~= nil and merchant:IsShown() and type(GetMerchantNumItems) == "function"
end

-- itemID -> merchant slot index for the open vendor.
function ShoppingListWindow:ScanMerchant()
    local items = {}
    if MerchantOpen() then
        for index = 1, GetMerchantNumItems() or 0 do
            local itemID = ItemIDFromLink(GetMerchantItemLink(index))
            if itemID and not items[itemID] then
                items[itemID] = index
            end
        end
    end
    self.merchantItems = items
    return items
end

local function MerchantSlotInfo(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
        if ok and type(info) == "table" then
            return tonumber(info.stackCount) or 1
        end
    end
    if type(_G.GetMerchantItemInfo) == "function" then
        local ok, _, _, _, quantity = pcall(_G.GetMerchantItemInfo, index)
        if ok then
            return tonumber(quantity) or 1
        end
    end
    return 1
end

-- One click buys what the line still needs. Items sold one at a time are
-- bought in calls of up to the item's max stack; items sold in bundles
-- (e.g. 5 per purchase) one bundle per call. Theoretical: BuyMerchantItem's
-- quantity for bundles; several calls in one click going through.
function ShoppingListWindow:BuyFromMerchant(line)
    local index = self.merchantItems and self.merchantItems[line.itemID]
    if not index or type(BuyMerchantItem) ~= "function" then
        return
    end
    local perPurchase = MerchantSlotInfo(index)
    local remaining = line.toBuy
    local calls = 0
    if perPurchase > 1 then
        while remaining > 0 and calls < 20 do
            BuyMerchantItem(index)
            remaining = remaining - perPurchase
            calls = calls + 1
        end
    else
        local maxStack = (type(GetMerchantItemMaxStack) == "function" and tonumber(GetMerchantItemMaxStack(index))) or 1
        maxStack = math.max(1, maxStack)
        while remaining > 0 and calls < 20 do
            local qty = math.min(remaining, maxStack)
            BuyMerchantItem(index, qty)
            remaining = remaining - qty
            calls = calls + 1
        end
    end
    Log("vendor buy itemID=%d toBuy=%d perPurchase=%d calls=%d", line.itemID, line.toBuy, perPurchase, calls)
end

-- Every vendor buy (list click or the vendor window): note the bag count
-- before; BAG_UPDATE_DELAYED records what arrived. Kept 3s so late bag
-- updates still count.
function ShoppingListWindow:InstallMerchantCapture()
    if self.merchantHooked or not hooksecurefunc or type(BuyMerchantItem) ~= "function" then
        return
    end
    self.pendingVendor = {}
    hooksecurefunc("BuyMerchantItem", function(index)
        local itemID = ItemIDFromLink(GetMerchantItemLink(index))
        local list = List()
        if not itemID or not list or not list:GetAllLines()[itemID] then
            return
        end
        local pending = self.pendingVendor[itemID]
        local now = GetTime()
        if not pending then
            local count = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID)) or GetItemCount(itemID) or 0
            self.pendingVendor[itemID] = { before = count, untilTime = now + 3 }
        else
            pending.untilTime = now + 3
        end
    end)
    self.merchantHooked = true
end

function ShoppingListWindow:OnBagsChanged()
    local pendingVendor = self.pendingVendor
    if not pendingVendor or not next(pendingVendor) then
        return
    end
    local list = List()
    local now = GetTime()
    for itemID, pending in pairs(pendingVendor) do
        local count = (C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID)) or GetItemCount(itemID) or 0
        local arrived = count - pending.before
        if arrived > 0 and list then
            Log("vendor purchase itemID=%d arrived=%d", itemID, arrived)
            list:RecordPurchase(itemID, arrived)
            pending.before = count
        end
        if now > pending.untilTime then
            pendingVendor[itemID] = nil
        end
    end
end

function ShoppingListWindow:OnMerchantShown()
    local items = self:ScanMerchant()
    local list = List()
    local sellsSomething = false
    for _, line in ipairs(list and list:GetLines() or {}) do
        if items[line.itemID] then
            sellsSomething = true
            break
        end
    end
    if self.frame and self.frame:IsShown() then
        self:Place()
        self:Refresh()
    elseif sellsSomething then
        self:Open()
        self.openedByMerchant = true
    end
end

function ShoppingListWindow:OnMerchantClosed()
    self.merchantItems = nil
    if self.openedByMerchant and self.frame then
        self.frame:Hide()
    end
    self.openedByMerchant = nil
    if self.frame and self.frame:IsShown() then
        self:Place()
        self:Refresh()
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

function ShoppingListWindow:CreateRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -TOP_OFFSET - (index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local highlight = row:CreateTexture(nil, "BACKGROUND")
    highlight:SetAllPoints(row)
    highlight:SetColorTexture(1, 1, 1, 0.08)
    highlight:Hide()
    row.Selected = highlight
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(24, 24)
    row.Icon:SetPoint("LEFT", row, "LEFT", 2, 0)

    row.Cost = CreateText(row, "GameFontHighlightSmall", "RIGHT")
    row.Cost:SetPoint("TOPRIGHT", row, "TOPRIGHT", -2, -3)

    row.Name = CreateText(row, "GameFontNormalSmall", "LEFT")
    row.Name:SetPoint("TOPLEFT", row.Icon, "TOPRIGHT", 6, 0)
    row.Name:SetPoint("RIGHT", row.Cost, "LEFT", -6, 0)

    row.Detail = CreateText(row, "GameFontHighlightSmall", "LEFT")
    row.Detail:SetPoint("BOTTOMLEFT", row.Icon, "BOTTOMRIGHT", 6, 0)
    row.Detail:SetPoint("RIGHT", row, "RIGHT", -2, 0)

    row:SetScript("OnClick", function(button, mouseButton)
        local line = button.line
        if not line then
            return
        end
        if line.header then
            return
        end
        if mouseButton == "RightButton" then
            local name = ItemName(line.itemID) or ("item " .. line.itemID)
            StaticPopup_Show("MCG_SHOPPING_LIST_REMOVE", name, nil, line.itemID)
        elseif MerchantOpen() and self.merchantItems and self.merchantItems[line.itemID] then
            self:BuyFromMerchant(line)
        elseif line.vendor then
            Notify("Buy " .. (ItemName(line.itemID) or "this") .. " from a vendor.")
        else
            self:OpenInBuyScreen(line)
        end
    end)
    row:SetScript("OnEnter", function(button)
        local line = button.line
        if line and not line.header and GameTooltip then
            GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(line.itemID)
            local hint
            if MerchantOpen() and self.merchantItems and self.merchantItems[line.itemID] then
                hint = "Click: buy from this vendor. Right-click: remove."
            elseif line.vendor then
                hint = "Buy from a vendor. Right-click: remove."
            else
                hint = "Click: open in the Buy tab. Right-click: remove."
            end
            GameTooltip:AddLine(hint, NOTE_COLOR[1], NOTE_COLOR[2], NOTE_COLOR[3])
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    row:Hide()
    return row
end

-- ---------------------------------------------------------------------------
-- Add row widgets
-- ---------------------------------------------------------------------------

function ShoppingListWindow:PickItem(itemID, name)
    itemID = tonumber(itemID)
    if not itemID or not self.nameBox then
        return
    end
    self.pickedItemID = itemID
    self.settingText = true
    self.nameBox:SetText(name or ItemName(itemID) or ("item " .. itemID))
    self.settingText = false
    self.nameBox:SetCursorPosition(0)
    self:HideSuggestions()
end

function ShoppingListWindow:PickFromLink(link)
    if type(link) ~= "string" then
        return false
    end
    local itemID = tonumber(link:match("item:(%d+)"))
    if not itemID then
        return false
    end
    self:PickItem(itemID, link:match("%[(.-)%]"))
    return true
end

function ShoppingListWindow:HideSuggestions()
    self.suggestions = nil
    if self.suggestFrame then
        self.suggestFrame:Hide()
    end
end

function ShoppingListWindow:UpdateSuggestions()
    local frame = self.suggestFrame
    local results = FindItems(self.nameBox:GetText())
    self.suggestions = results
    if #results == 0 then
        frame:Hide()
        return
    end
    for i, button in ipairs(self.suggestButtons) do
        local entry = results[i]
        if entry then
            button.entry = entry
            button.Text:SetText(DisplayName(entry))
            button:Show()
        else
            button.entry = nil
            button:Hide()
        end
    end
    frame:SetHeight(#results * 18 + 8)
    frame:Show()
end

function ShoppingListWindow:AddPicked()
    local list = List()
    if not list then
        return
    end
    -- Only a picked item is added (Brian, 2026-11-22): an empty box, or text
    -- typed without picking a match, adds nothing.
    if not self.pickedItemID or self.nameBox:GetText() == "" then
        self.pickedItemID = nil
        self.addButton:SetText("Pick one")
        C_Timer.After(2, function() self.addButton:SetText("Add") end)
        return
    end
    local qty = math.floor(tonumber(self.qtyBox:GetText()) or 1)
    if qty < 1 then
        qty = 1
    end
    list:Add(self.pickedItemID, qty, "manual", { exact = true })
    -- The item and amount stay (Brian, 2026-11-22): Add again adds the same
    -- amount again (10, then 10 more). Typing a new name starts a new pick.
    self.qtyBox:SetText(tostring(qty))
    self.nameBox:ClearFocus()
    self.qtyBox:ClearFocus()
    self:HideSuggestions()
    self.addButton:SetText("Added")
    C_Timer.After(2, function() self.addButton:SetText("Add") end)
end

-- Item dropped on the window or the box (dragged from bags).
function ShoppingListWindow:AcceptCursorItem()
    local kind, itemID, link = GetCursorInfo()
    if kind ~= "item" then
        return
    end
    ClearCursor()
    if not self:PickFromLink(link) then
        self:PickItem(itemID)
    end
    self.qtyBox:SetFocus()
    self.qtyBox:HighlightText()
end

function ShoppingListWindow:CreateAddRow(frame)
    local nameBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    nameBox:SetSize(206, 20)
    nameBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -32)
    nameBox:SetAutoFocus(false)
    nameBox:SetFontObject("GameFontHighlightSmall")
    self.nameBox = nameBox

    local hint = nameBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", nameBox, "LEFT", 2, 0)
    hint:SetText("Type an item name, or Shift-click one")
    self.nameHint = hint

    local qtyBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    qtyBox:SetSize(40, 20)
    qtyBox:SetPoint("LEFT", nameBox, "RIGHT", 10, 0)
    qtyBox:SetAutoFocus(false)
    qtyBox:SetNumeric(true)
    qtyBox:SetMaxLetters(5)
    qtyBox:SetJustifyH("CENTER")
    qtyBox:SetFontObject("GameFontHighlightSmall")
    qtyBox:SetText("1")
    self.qtyBox = qtyBox

    local addButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    addButton:SetSize(58, 20)
    addButton:SetPoint("LEFT", qtyBox, "RIGHT", 6, 0)
    addButton:SetText("Add")
    addButton:SetScript("OnClick", function() self:AddPicked() end)
    self.addButton = addButton

    nameBox:SetScript("OnTextChanged", function(box, userInput)
        hint:SetShown(box:GetText() == "")
        if self.settingText or not userInput then
            return
        end
        self.pickedItemID = nil
        self:UpdateSuggestions()
    end)
    nameBox:SetScript("OnEnterPressed", function()
        if self.pickedItemID then
            self:AddPicked()
        elseif self.suggestions and self.suggestions[1] then
            local first = self.suggestions[1]
            self:PickItem(first.itemID, first.name)
            qtyBox:SetFocus()
            qtyBox:HighlightText()
        end
    end)
    nameBox:SetScript("OnEscapePressed", function(box)
        self:HideSuggestions()
        box:ClearFocus()
    end)
    nameBox:SetScript("OnEditFocusLost", function()
        -- Let a click on a suggestion land first.
        C_Timer.After(0.2, function()
            if not nameBox:HasFocus() then
                self:HideSuggestions()
            end
        end)
    end)
    nameBox:SetScript("OnReceiveDrag", function() self:AcceptCursorItem() end)
    nameBox:SetScript("OnMouseUp", function()
        if GetCursorInfo() == "item" then
            self:AcceptCursorItem()
        end
    end)
    qtyBox:SetScript("OnEnterPressed", function() self:AddPicked() end)
    qtyBox:SetScript("OnEscapePressed", function(box) box:ClearFocus() end)

    local suggest = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    suggest:SetPoint("TOPLEFT", nameBox, "BOTTOMLEFT", -6, -2)
    suggest:SetWidth(230)
    suggest:SetFrameLevel(frame:GetFrameLevel() + 20)
    if suggest.SetBackdrop then
        suggest:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        suggest:SetBackdropColor(0.08, 0.08, 0.08, 0.98)
        suggest:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    suggest:Hide()
    self.suggestFrame = suggest
    self.suggestButtons = {}
    for i = 1, MAX_SUGGESTIONS do
        local button = CreateFrame("Button", nil, suggest)
        button:SetHeight(18)
        button:SetPoint("TOPLEFT", suggest, "TOPLEFT", 6, -4 - (i - 1) * 18)
        button:SetPoint("RIGHT", suggest, "RIGHT", -6, 0)
        button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        button.Text = CreateText(button, "GameFontHighlightSmall", "LEFT")
        button.Text:SetPoint("LEFT", button, "LEFT", 2, 0)
        button.Text:SetPoint("RIGHT", button, "RIGHT", -2, 0)
        button:SetScript("OnClick", function(clicked)
            if clicked.entry then
                self:PickItem(clicked.entry.itemID, clicked.entry.name)
                qtyBox:SetFocus()
                qtyBox:HighlightText()
            end
        end)
        self.suggestButtons[i] = button
    end

    -- Dropping an item anywhere on the window picks it too.
    frame:EnableMouse(true)
    frame:SetScript("OnReceiveDrag", function() self:AcceptCursorItem() end)
    frame:SetScript("OnMouseUp", function()
        if GetCursorInfo() == "item" then
            self:AcceptCursorItem()
        end
    end)
end

-- Shift-click an item while the name box has focus puts it in the box.
-- Theoretical: retail may route links through ChatFrameUtil.InsertLink
-- instead of ChatEdit_InsertLink; both are hooked when they exist.
function ShoppingListWindow:HookLinkInsert()
    if self.linkHooked or not hooksecurefunc then
        return
    end
    local function OnInsert(link)
        if self.nameBox and self.nameBox:HasFocus() then
            self:PickFromLink(link)
            self.qtyBox:SetFocus()
            self.qtyBox:HighlightText()
        end
    end
    if type(_G.ChatEdit_InsertLink) == "function" then
        hooksecurefunc("ChatEdit_InsertLink", OnInsert)
    end
    local util = _G.ChatFrameUtil
    if type(util) == "table" and type(util.InsertLink) == "function" then
        hooksecurefunc(util, "InsertLink", OnInsert)
    end
    self.linkHooked = true
end

function ShoppingListWindow:CreateWindow()
    if self.frame then
        return self.frame
    end
    local frame = CreateFrame("Frame", "MCGShoppingListFrame", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = false, edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        frame:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
        frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        self.offset = math.max(0, (self.offset or 0) - delta)
        self:Refresh()
    end)

    local title = CreateText(frame, "GameFontNormal", "LEFT")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -10)
    title:SetText("Shopping list")
    self.title = title

    -- Away from the AH the window can be dragged by its title bar.
    frame:SetMovable(true)
    local drag = CreateFrame("Frame", nil, frame)
    drag:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    drag:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -28, 0)
    drag:SetHeight(28)
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function()
        if not self.docked then
            frame:StartMoving()
        end
    end)
    drag:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
    end)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    close:SetScript("OnClick", function()
        self.closedThisVisit = true
        frame:Hide()
    end)

    self:CreateAddRow(frame)
    self:HookLinkInsert()

    self.rows = {}
    for i = 1, VISIBLE_ROWS do
        self.rows[i] = self:CreateRow(frame, i)
    end

    local empty = CreateText(frame, "GameFontHighlightSmall", "LEFT")
    if empty.SetWordWrap then
        empty:SetWordWrap(true)
    end
    empty:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -TOP_OFFSET)
    empty:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    empty:SetText("Nothing to buy. Add items above, or from recipe analysis.")
    self.empty = empty

    local more = CreateText(frame, "GameFontHighlightSmall", "RIGHT")
    more:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, FOOTER_HEIGHT - 4)
    more:SetTextColor(NOTE_COLOR[1], NOTE_COLOR[2], NOTE_COLOR[3])
    self.more = more

    local total = CreateText(frame, "GameFontNormalSmall", "LEFT")
    total:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 36)
    total:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    self.total = total

    local clear = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    clear:SetSize(80, 22)
    clear:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)
    clear:SetText("Clear")
    clear:SetScript("OnClick", function()
        StaticPopup_Show("MCG_SHOPPING_LIST_CLEAR")
    end)
    self.clear = clear

    frame:Hide()
    self.frame = frame
    return frame
end

local function AuctionHouseOpen()
    local ah = _G.AuctionHouseFrame
    return ah ~= nil and ah:IsShown()
end

-- Docked on the AH's right edge while the AH is open; otherwise standing
-- alone where it was last dragged (this session), first time right of center.
function ShoppingListWindow:Place()
    local frame = self.frame
    if not frame then
        return
    end
    local ah = _G.AuctionHouseFrame
    if ah and ah:IsShown() then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", ah, "TOPRIGHT", 2, 0)
        self.docked = true
    elseif MerchantOpen() then
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", _G.MerchantFrame, "TOPRIGHT", 2, 0)
        self.docked = true
    elseif self.docked or not self.placedFree then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 260, 40)
        self.docked = false
        self.placedFree = true
    end
end

function ShoppingListWindow:Refresh()
    local frame = self.frame
    if not frame or not frame:IsShown() then
        return
    end
    local list = List()
    local lines = list and list:GetLines() or {}

    -- Price each line and sort it into the Auction House or Vendor section.
    local totalValue, unpriced, loading = 0, 0, false
    local auctionLines, vendorLines = {}, {}
    for _, line in ipairs(lines) do
        local vendorPrice = VendorUnitPrice(line.itemID)
        local auctionPrice = vendorPrice and AuctionUnitPrice(line.itemID)
        line.vendor = vendorPrice ~= nil and (auctionPrice == nil or vendorPrice <= auctionPrice)
        local each = line.vendor and vendorPrice or UnitValue(line.itemID)
        line.cost = each and (each * line.toBuy) or nil
        if line.cost then
            totalValue = totalValue + line.cost
        else
            unpriced = unpriced + 1
        end
        if line.vendor then
            vendorLines[#vendorLines + 1] = line
        else
            auctionLines[#auctionLines + 1] = line
        end
    end
    -- Section headers only when there's a vendor section.
    local shown = {}
    if #vendorLines > 0 then
        if #auctionLines > 0 then
            shown[#shown + 1] = { header = "Auction House" }
            for _, line in ipairs(auctionLines) do shown[#shown + 1] = line end
        end
        shown[#shown + 1] = { header = "Vendor" }
        for _, line in ipairs(vendorLines) do shown[#shown + 1] = line end
    else
        shown = auctionLines
    end

    local maxOffset = math.max(0, #shown - VISIBLE_ROWS)
    self.offset = math.min(self.offset or 0, maxOffset)
    local atMerchant = MerchantOpen() and self.merchantItems ~= nil

    for i, row in ipairs(self.rows) do
        local line = shown[i + self.offset]
        row.line = line
        if line and line.header then
            row.Icon:SetTexture(nil)
            row.Name:SetText(line.header)
            row.Detail:SetText("")
            row.Cost:SetText("")
            row.Selected:Hide()
            row:SetAlpha(1)
            row:Show()
        elseif line then
            local name = ItemName(line.itemID)
            if not name then
                loading = true
            end
            row.Icon:SetTexture(ItemIcon(line.itemID))
            row.Name:SetText(name or "Loading...")
            local detail = "Buy " .. line.toBuy
            if line.inBank then
                detail = detail .. " \194\183 " .. line.inBank .. " in bank"
            end
            local soldHere = atMerchant and self.merchantItems[line.itemID] ~= nil
            if soldHere then
                detail = detail .. " \194\183 sold here"
            end
            row.Detail:SetText(detail)
            row.Cost:SetText(line.cost and Money(line.cost) or "No price")
            if line.cost then
                row.Cost:SetTextColor(1, 1, 1)
            else
                row.Cost:SetTextColor(NOTE_COLOR[1], NOTE_COLOR[2], NOTE_COLOR[3])
            end
            row.Selected:SetShown(soldHere or line.itemID == self.selectedItemID)
            row:SetAlpha((atMerchant and not soldHere) and 0.45 or 1)
            row:Show()
        else
            row:Hide()
        end
    end

    self.empty:SetShown(#lines == 0)
    self.more:SetText(maxOffset > 0 and (self.offset + 1 .. "-" .. math.min(#shown, self.offset + VISIBLE_ROWS)
        .. " of " .. #shown .. " (scroll)") or "")
    if #lines == 0 then
        self.total:SetText("")
    else
        local text = "Total (est.): " .. Money(totalValue)
        if unpriced > 0 then
            text = text .. "  + " .. unpriced .. " with no price"
        end
        self.total:SetText(text)
    end
    self.clear:SetEnabled(list ~= nil and next(list:GetAllLines()) ~= nil)
    self.waitingForNames = loading
end

function ShoppingListWindow:Open()
    self:CreateWindow()
    self:Place()
    self.closedThisVisit = false
    self.frame:Show()
    self:Refresh()
end

function ShoppingListWindow:Toggle()
    if self.frame and self.frame:IsShown() then
        self.closedThisVisit = true
        self.frame:Hide()
    else
        self:Open()
    end
end

function ShoppingListWindow:OnAuctionHouseShown()
    self.closedThisVisit = false
    local list = List()
    if (self.frame and self.frame:IsShown()) or (list and #list:GetLines() > 0) then
        self:Open()
    end
end

function ShoppingListWindow:OnAuctionHouseHidden()
    self.pendingOpen = nil
    self.hold = nil
    self.selectedItemID = nil
    if self.frame then
        self.frame:Hide()
    end
end

function ShoppingListWindow:OnListChanged()
    local frame = self.frame
    local list = List()
    local count = list and #list:GetLines() or 0
    if self.selectedItemID and list and not list:GetAllLines()[self.selectedItemID] then
        self.selectedItemID = nil
    end
    if frame and frame:IsShown() then
        self:Refresh()
    elseif count > 0 and AuctionHouseOpen() and not self.closedThisVisit then
        self:Open()
    end
end

-- First AH open of the session: purchase capture and event watching.
function ShoppingListWindow:EnsureAuctionHooks()
    if self.events then
        return
    end
    self:InstallPurchaseCapture()
    local events = CreateFrame("Frame")
    local function Register(name)
        pcall(events.RegisterEvent, events, name)
    end
    Register("COMMODITY_SEARCH_RESULTS_UPDATED")
    Register("COMMODITY_PURCHASE_SUCCEEDED")
    Register("COMMODITY_PURCHASE_FAILED")
    events:SetScript("OnEvent", function(_, event, arg1)
        if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
            self:OnSearchResults(arg1)
        elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
            self:OnPurchaseSucceeded()
        elseif event == "COMMODITY_PURCHASE_FAILED" then
            self.pendingPurchase = nil
        end
    end)
    self.events = events
end

function ShoppingListWindow:OnEnable()
    local list = List()
    self:RegisterMessage(list and list.CHANGED_MESSAGE or "MCG_SHOPPING_LIST_CHANGED", "OnListChanged")
    self:RegisterEvent("GET_ITEM_INFO_RECEIVED", function()
        if self.waitingForNames then
            self:Refresh()
        end
    end)
    -- The AH frame is created when Blizzard's AH UI loads, around this
    -- event, so wait a frame before docking.
    self:RegisterEvent("AUCTION_HOUSE_SHOW", function()
        C_Timer.After(0, function()
            self:EnsureAuctionHooks()
            self:OnAuctionHouseShown()
        end)
    end)
    self:RegisterEvent("AUCTION_HOUSE_CLOSED", function()
        self:OnAuctionHouseHidden()
    end)
    -- Vendor (2026-11-22).
    self:InstallMerchantCapture()
    self:RegisterEvent("MERCHANT_SHOW", function()
        C_Timer.After(0, function()
            self:OnMerchantShown()
        end)
    end)
    self:RegisterEvent("MERCHANT_UPDATE", function()
        if MerchantOpen() then
            self:ScanMerchant()
            self:Refresh()
        end
    end)
    self:RegisterEvent("MERCHANT_CLOSED", function()
        self:OnMerchantClosed()
    end)
    self:RegisterEvent("BAG_UPDATE_DELAYED", function()
        self:OnBagsChanged()
    end)
end

-- Minimap Shift-click and anything else that wants the list open.
PocketCFO.OpenShoppingList = function()
    ShoppingListWindow:Toggle()
end
