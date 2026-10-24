-- PocketCFO_Orders/UI/PatronOrdersBoard.lua
-- Patron Orders board: our own list drawn OVER Blizzard's patron order list
-- (ProfessionsFrame.OrdersPage.BrowseFrame.OrderList) so you can see which
-- orders are worth making without opening each one.
--
-- Blizzard's frames are never modified, re-parented or hidden - the board is
-- an opaque frame layered on top of the list area, and the "Blizzard view"
-- button takes it away again. Only shown while the Patron tab is active.
--
-- Rows (Brian's priority order): item + required quality, estimated profit
-- (sorted best first), knowledge reward, time left, customer mats marker.
-- Hover a row for the full breakdown; click it to open the order in
-- Blizzard's detail view, where the exact Order Analysis takes over.
--
-- Estimates: OrderObservationBuilder:BuildObservationFromListOrder ->
-- OrderEconomicsService:EvaluateObservation (same valuation as Order
-- Analysis, but crafter mats are estimated - see that builder method).
--
-- Confirmed via /mcgd orderlist + /mcgd events (2026-10-11):
--   frame path OrdersPage.BrowseFrame.OrderList; C_CraftingOrders.
--   GetCrafterOrders() fields; CRAFTINGORDERS_UPDATE_ORDER_COUNT(orderType,
--   count) on list load; SetProfessionChildSkillLineID switches expansion
--   and Blizzard reloads the patron list by itself after a few seconds.
-- Theoretical: OrdersPage:ViewOrder(order) argument and taint behavior;
--   SetCraftingOrderType(orderType) hook argument; quality icon atlas names.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemIcon = (C_Item and C_Item.GetItemIconByID) or GetItemIcon

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Orders = _G.PocketCFO_Orders

local PatronOrdersBoard = PocketCFO_Orders:NewModule("PatronOrdersBoard", "AceEvent-3.0")

local NPC_ORDER_TYPE = (Enum and Enum.CraftingOrderType and Enum.CraftingOrderType.Npc) or 3
local REFRESH_DEBOUNCE_SECONDS = 0.2
local EXPANSION_LOAD_TIMEOUT_SECONDS = 20
local MAX_THROTTLE_RETRIES = 3
local ORDER_RESULT_OK = (Enum and Enum.CraftingOrderResult and Enum.CraftingOrderResult.Ok) or 0
local MAX_EXPANSION_BUTTONS = 3

local HEADER_HEIGHT = 30
local COLUMN_HEADER_HEIGHT = 24 -- 18 -> 24 for the two-line "Conc Cost" header
local ROW_HEIGHT = 22
local SIDE_PAD = 10

-- Column layout (x offset from row left, width). Name takes what is left.
-- Concentration has its own column so profit (what you earn) and
-- concentration (what you spend) are never read as one number (Brian,
-- 2026-10-23). Its 50 + gap comes from profit (110 -> 100) and rewards
-- (150 -> 100), so the name column keeps its width.
local COL_PROFIT_W = 100
local COL_CONC_W = 50
local COL_KP_W = 60
local COL_TIME_W = 70
local COL_MATS_W = 60
local COL_REWARDS_W = 100
local COL_GAP = 10

local COLOR_POSITIVE = { 0.40, 0.90, 0.40 }
local COLOR_NEGATIVE = { 1.00, 0.45, 0.45 }
local COLOR_MUTED = { 0.65, 0.65, 0.65 }
local COLOR_TEXT = { 1.00, 1.00, 1.00 }
local COLOR_HEADER = { 1.00, 0.82, 0.00 }
local COLOR_KP = { 0.40, 0.75, 1.00 }

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function SafeRead(parent, key)
    if parent == nil then
        return nil
    end
    local ok, value = pcall(function() return parent[key] end)
    return ok and value or nil
end

local function SafeVisible(frame)
    if not frame then
        return false
    end
    local ok, visible = pcall(frame.IsVisible, frame)
    return ok and visible == true
end

local function SetColor(fontString, color)
    fontString:SetTextColor(color[1], color[2], color[3], 1)
end

local function GetOrdersPage()
    return SafeRead(_G.ProfessionsFrame, "OrdersPage")
end

local function GetOrderList(ordersPage)
    return SafeRead(SafeRead(ordersPage, "BrowseFrame"), "OrderList")
end

-- Is Blizzard's Patron tab the selected one? Read straight from the tab
-- button so the board knows the moment the tab is picked, before any orders
-- arrive. Confirmed via /mcgd objectscan (2026-10-13):
-- OrdersPage.BrowseFrame.NpcOrdersButton has orderType=3 and isSelected=true
-- while the Patron tab is open (false on the other three tabs).
-- Returns true/false, or nil when the button/field can't be read.
local function IsPatronTabSelected(ordersPage)
    local button = SafeRead(SafeRead(ordersPage, "BrowseFrame"), "NpcOrdersButton")
    if not button then
        return nil
    end
    local ok, selected = pcall(function() return button.isSelected end)
    if not ok or selected == nil then
        return nil
    end
    return selected == true
end

local function GetObservationBuilder()
    return PocketCFO_Orders:GetModule("OrderObservationBuilder", true)
end

local function GetEconomicsService()
    return PocketCFO_Orders:GetModule("OrderEconomicsService", true)
end

local function FormatGold(copperValue, signed)
    copperValue = tonumber(copperValue) or 0
    local negative = copperValue < 0
    local absValue = math.floor(math.abs(copperValue) + 0.5)
    local gold = math.floor(absValue / 10000)
    local silver = math.floor((absValue % 10000) / 100)
    local goldText = tostring(gold):reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if goldText:sub(1, 1) == "," then
        goldText = goldText:sub(2)
    end
    local sign = ""
    if signed then
        sign = negative and "-" or "+"
    elseif negative then
        sign = "-"
    end
    return string.format("%s%sg %02ds", sign, goldText, silver)
end

local function FormatTimeLeft(expirationTime)
    expirationTime = tonumber(expirationTime)
    if not expirationTime then
        return "?"
    end
    local now = (GetServerTime and GetServerTime()) or time()
    local seconds = expirationTime - now
    if seconds <= 0 then
        return "Expired"
    end
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if days > 0 then
        return string.format("%dd %dh", days, hours)
    end
    if hours > 0 then
        return string.format("%dh %dm", hours, minutes)
    end
    return string.format("%dm", math.max(1, minutes))
end

-- Required-quality icon. Midnight uses its own two-tier icons (silver
-- diamond / gold pentagon), TWW its tier icons - so the atlas is never
-- hardcoded. Same idea as InventoryManagerWindow's ExtractQualityAtlasFromLink:
-- reuse the exact "|A:...Quality...|a" markup Blizzard already rendered -
-- here, from Blizzard's own (covered) row for the same orderID. No icon is
-- shown rather than a wrong one if it can't be found.
-- Theoretical: ScrollBox:ForEachFrame / frame:GetElementData() row access.
local function FindQualityMarkupInFrame(frame, depth)
    if not frame or depth > 3 then
        return nil
    end
    local okRegions, regions = pcall(function() return { frame:GetRegions() } end)
    for _, region in ipairs(okRegions and regions or {}) do
        if region.GetObjectType and region:GetObjectType() == "FontString" then
            local text = region:GetText()
            local markup = type(text) == "string" and text:match("(|A:[^|]*Quality[^|]*|a)")
            if markup then
                return markup
            end
        end
    end
    local okChildren, children = pcall(function() return { frame:GetChildren() } end)
    for _, child in ipairs(okChildren and children or {}) do
        local markup = FindQualityMarkupInFrame(child, depth + 1)
        if markup then
            return markup
        end
    end
    return nil
end

local function CollectBlizzardQualityMarkups(orderList)
    local markups = {}
    local scrollBox = SafeRead(orderList, "ScrollBox")
    if not scrollBox or type(scrollBox.ForEachFrame) ~= "function" then
        return markups
    end
    pcall(scrollBox.ForEachFrame, scrollBox, function(frame)
        local okData, data = pcall(frame.GetElementData, frame)
        local orderID = okData and type(data) == "table" and SafeRead(SafeRead(data, "option"), "orderID")
        if orderID then
            markups[orderID] = FindQualityMarkupInFrame(frame, 0)
        end
    end)
    return markups
end

local function ItemName(itemID)
    if not itemID then
        return nil
    end
    local ok, name = pcall(GetItemInfo, itemID)
    return ok and name or nil
end

local function CurrencyName(currencyID)
    if not currencyID or not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyInfo then
        return nil
    end
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    return ok and type(info) == "table" and info.name or nil
end

-- ---------------------------------------------------------------------------
-- Data: one entry per patron order
-- ---------------------------------------------------------------------------

-- Your concentration right now. Read fresh on every draw/hover, never cached
-- (it recharges). The currency ID comes from the game's own crafting answer
-- (GetCraftingOperationInfo .concentrationCurrencyID). CONFIRMED 2026-10-23:
-- C_CurrencyInfo.GetCurrencyInfo(3166) returns quantity and iconFileID for
-- Jewelcrafting Concentration.
local function GetConcentration(currencyID)
    if not currencyID or not C_CurrencyInfo or type(C_CurrencyInfo.GetCurrencyInfo) ~= "function" then
        return nil, nil
    end
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    if not ok or type(info) ~= "table" then
        return nil, nil
    end
    return tonumber(info.quantity), info.iconFileID
end

-- Conc column text: "<icon>257" when the chosen way uses concentration,
-- blank when it needs none; red when you don't have that much right now.
local function ConcentrationMarkup(entry)
    local option = entry.chosenOption
    local cost = option and tonumber(option.concentrationCost) or 0
    if cost <= 0 then
        return ""
    end
    local have, icon = GetConcentration(option.concentrationCurrencyID)
    local text = icon and ("|T" .. tostring(icon) .. ":12:12|t" .. tostring(cost)) or tostring(cost)
    if have and have < cost then
        return "|cffff7373" .. text .. "|r"
    end
    return text
end

local function OptionLabel(option)
    local label = option.key == "best" and "Best mats" or "Cheap mats"
    local cost = tonumber(option.concentrationCost) or 0
    if cost > 0 then
        label = label .. " + " .. tostring(cost) .. " Concentration"
    end
    return label
end

local function ClassifyKnowledge(itemRewards)
    local registry = PocketCFO_Orders.KnowledgeRewardRegistry
    if not registry then
        return nil
    end
    local found, totalPoints, unknownAmount = false, 0, false
    for _, reward in ipairs(type(itemRewards) == "table" and itemRewards or {}) do
        local isKnowledge, points = registry:Classify(reward.itemID)
        if isKnowledge then
            found = true
            if points then
                totalPoints = totalPoints + points * (tonumber(reward.quantity) or 1)
            else
                unknownAmount = true
            end
        end
    end
    if not found then
        return nil
    end
    if unknownAmount or totalPoints == 0 then
        return "KP"
    end
    return string.format("+%d KP", totalPoints)
end

-- The observation with one quality option's mats in place of the existing
-- estimate, for EvaluateObservation. Shallow copy; the original is untouched.
local function CopyWithCrafterRows(observation, crafterRows)
    local copy = {}
    for key, value in pairs(observation) do
        copy[key] = value
    end
    copy.crafterProvidedReagents = crafterRows
    return copy
end

local function BuildEntry(order)
    local entry = {
        order = order,
        orderID = SafeRead(order, "orderID"),
        itemID = SafeRead(order, "itemID"),
        minQuality = SafeRead(order, "minQuality"),
        expirationTime = SafeRead(order, "expirationTime"),
    }

    -- Can this character craft it at all? Same check Blizzard's order view
    -- uses to disable Create (Blizzard_ProfessionsCrafterOrderView.lua:
    -- "not recipeInfo or not recipeInfo.learned"); recipeInfo.learned
    -- confirmed in-game via /mcgd orderdata (2026-10-16). An API error
    -- leaves the order treated as known rather than wrongly flagged.
    local okRecipe, recipeInfo = pcall(C_TradeSkillUI.GetRecipeInfo, SafeRead(order, "spellID"))
    entry.recipeKnown = not okRecipe or (type(recipeInfo) == "table" and recipeInfo.learned == true)

    local builder = GetObservationBuilder()
    local economicsService = GetEconomicsService()
    if not builder or not builder.BuildObservationFromListOrder or not economicsService then
        entry.unresolvedReason = "servicesUnavailable"
        return entry
    end

    local okBuild, built = pcall(builder.BuildObservationFromListOrder, builder, order)
    if not okBuild or type(built) ~= "table" or built.resolved ~= true then
        entry.unresolvedReason = okBuild and type(built) == "table" and built.unresolvedReason or "observationFailed"
        return entry
    end
    local observation = built.observation
    entry.itemID = entry.itemID or observation.outputItemID
    entry.resourcefulnessPct = observation.displayedResourcefulnessPct
    entry.customerMatCount = #(observation.customerProvidedReagents or {})
    -- "All": customer gives mats and there is no required slot left for you
    -- to fill (crafterProvidedReagents only holds unclaimed required slots in
    -- list mode - see BuildObservationFromListOrder).
    entry.allMatsProvided = entry.customerMatCount > 0 and #(observation.crafterProvidedReagents or {}) == 0
    entry.rewardIcons = {}
    for _, reward in ipairs(observation.itemRewards or {}) do
        entry.rewardIcons[#entry.rewardIcons + 1] = { itemID = reward.itemID, quantity = reward.quantity }
    end
    for _, reward in ipairs(observation.currencyRewards or {}) do
        entry.rewardIcons[#entry.rewardIcons + 1] = { currencyID = reward.currencyID, quantity = reward.quantity }
    end
    entry.knowledge = ClassifyKnowledge(observation.itemRewards)

    local okEval, result = pcall(economicsService.EvaluateObservation, economicsService, observation)
    if not okEval or type(result) ~= "table" or result.resolved ~= true then
        entry.unresolvedReason = okEval and type(result) == "table" and result.unresolvedReason or "economicsFailed"
        return entry
    end

    -- Quality options (OrderObservationBuilder BuildQualityOptions): each way
    -- of reaching the required quality - cheap or best mats, with
    -- concentration when needed - is priced, and the best profit is shown;
    -- a tie goes to the one using less concentration (Brian, 2026-10-23).
    -- No options = the existing single estimate above stands.
    entry.cannotReachQuality = observation.qualityUnreachable == true
    if type(observation.qualityOptions) == "table" and #observation.qualityOptions > 0 then
        local bestOption, bestResult, bestNet
        entry.optionResults = {}
        for _, option in ipairs(observation.qualityOptions) do
            local optionObservation = CopyWithCrafterRows(observation, option.crafterProvidedReagents)
            local okOption, optionResult = pcall(economicsService.EvaluateObservation, economicsService, optionObservation)
            if okOption and type(optionResult) == "table" and optionResult.resolved == true then
                local net = tonumber(optionResult.economics.estimatedNetValue)
                entry.optionResults[#entry.optionResults + 1] = { option = option, net = net }
                if net and (bestNet == nil or net > bestNet
                    or (net == bestNet and (option.concentrationCost or 0) < (bestOption.concentrationCost or 0))) then
                    bestOption, bestResult, bestNet = option, optionResult, net
                end
            end
        end
        if bestOption then
            result = bestResult
            entry.chosenOption = bestOption
        end
    end

    local economics = result.economics
    entry.economics = economics
    entry.estimatedNet = tonumber(economics.estimatedNetValue)

    -- Asterisk only for mats YOU supply that have no price: they are left out
    -- of cost, so profit is overstated. Unpriced rewards (knowledge items
    -- etc.) only make the estimate conservative and are not flagged; customer
    -- mats never appear in these rows (Brian, 2026-10-12).
    local hasUnvalued = false
    for _, rows in ipairs({ economics.crafterMaterialRows, economics.finishingReagentRows }) do
        for _, row in ipairs(type(rows) == "table" and rows or {}) do
            if row.unvalued then
                hasUnvalued = true
            end
        end
    end
    entry.hasUnvalued = hasUnvalued
    return entry
end

local function RewardIconsMarkup(icons)
    local parts = {}
    for _, icon in ipairs(icons or {}) do
        local texture
        if icon.itemID then
            if C_Item and C_Item.GetItemIconByID then
                local ok, value = pcall(C_Item.GetItemIconByID, icon.itemID)
                texture = ok and value or nil
            elseif GetItemIcon then
                local ok, value = pcall(GetItemIcon, icon.itemID)
                texture = ok and value or nil
            end
        elseif icon.currencyID and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, icon.currencyID)
            texture = ok and type(info) == "table" and info.iconFileID or nil
        end
        if texture then
            local count = tonumber(icon.quantity) or 1
            parts[#parts + 1] = string.format("|T%s:16:16|t", tostring(texture))
                .. (count > 1 and ("|cffdddddd" .. tostring(count) .. "|r") or "")
        end
    end
    return table.concat(parts, " ")
end

local function CollectPatronOrders()
    if not C_CraftingOrders or not C_CraftingOrders.GetCrafterOrders then
        return {}, false
    end
    local ok, orders = pcall(C_CraftingOrders.GetCrafterOrders)
    if not ok or type(orders) ~= "table" then
        return {}, false
    end
    local patron = {}
    local sawNonPatron = false
    for _, order in ipairs(orders) do
        if SafeRead(order, "orderType") == NPC_ORDER_TYPE then
            patron[#patron + 1] = order
        else
            sawNonPatron = true
        end
    end
    return patron, sawNonPatron
end

-- ---------------------------------------------------------------------------
-- UI construction
-- ---------------------------------------------------------------------------

local function CreateText(parent, template, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    text:SetWordWrap(false)
    return text
end

function PatronOrdersBoard:LayoutColumns(frame, isHeader)
    local width = (self.overlay and self.overlay:GetWidth() or 777) - SIDE_PAD * 2
    local right = width
    local function Place(fontString, colWidth)
        right = right - colWidth
        fontString:ClearAllPoints()
        fontString:SetPoint("LEFT", frame, "LEFT", right, 0)
        fontString:SetWidth(colWidth)
        right = right - COL_GAP
    end
    Place(frame.mats, COL_MATS_W)
    Place(frame.time, COL_TIME_W)
    -- Left to right: Order, Rewards, Profit, Knowledge (what you get), then
    -- Conc Cost (what you spend), Time Left, Mats Given (Brian, 2026-10-23).
    Place(frame.conc, COL_CONC_W)
    Place(frame.kp, COL_KP_W)
    Place(frame.profit, COL_PROFIT_W)
    Place(frame.rewards, COL_REWARDS_W)
    frame.name:ClearAllPoints()
    frame.name:SetPoint("LEFT", frame, "LEFT", isHeader and 0 or 4, 0)
    frame.name:SetWidth(math.max(120, right - 4))
end

function PatronOrdersBoard:BuildFrames(orderList)
    if self.overlay and self.overlayParent == orderList then
        return
    end
    self.overlayParent = orderList

    local overlay = CreateFrame("Frame", nil, orderList)
    overlay:SetAllPoints(orderList)
    overlay:SetFrameLevel((orderList:GetFrameLevel() or 1) + 50)
    overlay:EnableMouse(true)
    overlay:EnableMouseWheel(true)
    overlay:SetScript("OnMouseWheel", function() end)

    local background = overlay:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints(overlay)
    background:SetColorTexture(0.05, 0.05, 0.07, 0.97)

    -- Header bar: expansion buttons on the left, status text after them.
    local header = CreateFrame("Frame", nil, overlay)
    header:SetPoint("TOPLEFT", overlay, "TOPLEFT", SIDE_PAD, -6)
    header:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -SIDE_PAD, -6)
    header:SetHeight(HEADER_HEIGHT - 6)
    overlay.header = header

    overlay.expansionButtons = {}
    for index = 1, MAX_EXPANSION_BUTTONS do
        local button = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
        button:SetSize(110, 22)
        button:SetPoint("LEFT", header, "LEFT", (index - 1) * 114, 0)
        button:SetNormalFontObject("GameFontNormalSmall")
        button:Hide()
        button:SetScript("OnClick", function(clicked)
            self:SwitchExpansion(clicked.professionID, clicked.expansionName, clicked.professionInfo)
        end)
        overlay.expansionButtons[index] = button
    end

    local status = CreateText(header, "GameFontNormalSmall", "RIGHT")
    status:SetPoint("RIGHT", header, "RIGHT", 0, 0)
    status:SetWidth(440)
    overlay.status = status

    -- Column header
    local columns = CreateFrame("Frame", nil, overlay)
    columns:SetPoint("TOPLEFT", overlay, "TOPLEFT", SIDE_PAD, -HEADER_HEIGHT - 4)
    columns:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -SIDE_PAD, -HEADER_HEIGHT - 4)
    columns:SetHeight(COLUMN_HEADER_HEIGHT)
    columns.name = CreateText(columns, "GameFontNormalSmall")
    columns.profit = CreateText(columns, "GameFontNormalSmall", "RIGHT")
    columns.conc = CreateText(columns, "GameFontNormalSmall", "CENTER")
    columns.kp = CreateText(columns, "GameFontNormalSmall", "CENTER")
    columns.time = CreateText(columns, "GameFontNormalSmall", "RIGHT")
    columns.mats = CreateText(columns, "GameFontNormalSmall", "CENTER")
    columns.rewards = CreateText(columns, "GameFontNormalSmall")
    columns.rewards:SetText("Rewards")
    columns.name:SetText("Order")
    columns.profit:SetText("Est. Profit")
    -- Two-line header so the column stays narrow. Theoretical: that the
    -- explicit line break renders with word wrap on (CreateText turns it off).
    columns.conc:SetWordWrap(true)
    columns.conc:SetText("Conc\nCost")
    columns.kp:SetText("Knowledge")
    columns.time:SetText("Time Left")
    columns.mats:SetText("Mats Given")
    for _, key in ipairs({ "name", "rewards", "profit", "conc", "kp", "time", "mats" }) do
        SetColor(columns[key], COLOR_HEADER)
    end
    overlay.columns = columns

    local divider = overlay:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(COLOR_MUTED[1], COLOR_MUTED[2], COLOR_MUTED[3], 0.35)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", columns, "BOTTOMLEFT", 0, -2)
    divider:SetPoint("TOPRIGHT", columns, "BOTTOMRIGHT", 0, -2)

    local message = CreateText(overlay, "GameFontNormal", "CENTER")
    message:SetPoint("CENTER", overlay, "CENTER", 0, 0)
    message:SetWidth(500)
    message:Hide()
    overlay.message = message

    overlay.rows = {}
    self.overlay = overlay

    -- "Blizzard view" toggle lives just above the list's top-right corner so
    -- it stays reachable while the board is hidden.
    local toggle = CreateFrame("Button", nil, orderList, "UIPanelButtonTemplate")
    toggle:SetSize(120, 20)
    toggle:SetPoint("BOTTOMRIGHT", orderList, "TOPRIGHT", -4, 4)
    toggle:SetNormalFontObject("GameFontNormalSmall")
    toggle:SetFrameLevel((orderList:GetFrameLevel() or 1) + 60)
    toggle:SetScript("OnClick", function()
        self.showBlizzard = not self.showBlizzard
        self:Refresh()
    end)
    toggle:Hide()
    self.toggle = toggle

    overlay:SetScript("OnSizeChanged", function()
        self:QueueRefresh()
    end)
    overlay:Hide()
end

function PatronOrdersBoard:GetRow(index)
    local overlay = self.overlay
    local row = overlay.rows[index]
    if row then
        return row
    end

    row = CreateFrame("Button", nil, overlay)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("TOPLEFT", overlay.columns, "BOTTOMLEFT", 0, -6 - (index - 1) * ROW_HEIGHT)
    row:SetPoint("TOPRIGHT", overlay.columns, "BOTTOMRIGHT", 0, -6 - (index - 1) * ROW_HEIGHT)
    row:RegisterForClicks("LeftButtonUp")

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    local shade = (index % 2 == 0) and 0.10 or 0.07
    row.bg:SetColorTexture(shade, shade, shade + 0.03, 0.9)

    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints(row)
    row.highlight:SetColorTexture(0.30, 0.30, 0.45, 0.35)

    row.name = CreateText(row, "GameFontHighlight")
    row.profit = CreateText(row, "GameFontHighlight", "RIGHT")
    row.conc = CreateText(row, "GameFontHighlightSmall", "CENTER")
    row.kp = CreateText(row, "GameFontHighlightSmall", "CENTER")
    row.time = CreateText(row, "GameFontHighlightSmall", "RIGHT")
    row.mats = CreateText(row, "GameFontHighlightSmall", "CENTER")
    row.rewards = CreateText(row, "GameFontHighlightSmall")

    row:SetScript("OnClick", function(clicked)
        self:OpenOrder(clicked.entry)
    end)
    row:SetScript("OnEnter", function(hovered)
        self:ShowRowTooltip(hovered)
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    overlay.rows[index] = row
    return row
end

-- ---------------------------------------------------------------------------
-- Tooltip: full breakdown (optional - the row already shows the decision)
-- ---------------------------------------------------------------------------

local function AddValueLine(label, value, signed, unvalued)
    if unvalued then
        GameTooltip:AddDoubleLine(label, "Unvalued", 1, 1, 1, 0.6, 0.6, 0.6)
        return
    end
    local number = tonumber(value) or 0
    local r, g, b = 1, 1, 1
    if signed then
        if number < 0 then r, g, b = 1, 0.45, 0.45 else r, g, b = 0.4, 0.9, 0.4 end
    end
    GameTooltip:AddDoubleLine(label, FormatGold(number, signed), 1, 1, 1, r, g, b)
end

function PatronOrdersBoard:ShowRowTooltip(row)
    local entry = row.entry
    if not entry then
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(ItemName(entry.itemID) or "Order", 1, 1, 1)
    if entry.recipeKnown == false then
        GameTooltip:AddLine("You don't know this recipe on this character.", 1, 0.45, 0.45, true)
    end
    if entry.cannotReachQuality then
        GameTooltip:AddLine("Your skill can't reach the quality this order needs, even with concentration.", 1, 0.45, 0.45, true)
        GameTooltip:Show()
        return
    end
    local economics = entry.economics
    if not economics then
        GameTooltip:AddLine("Couldn't estimate this order (" .. tostring(entry.unresolvedReason) .. ").", 1, 0.45, 0.45, true)
        GameTooltip:AddLine("Click to open it for the exact analysis.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
        return
    end

    AddValueLine("Commission", economics.crafterPayout, true)
    for _, reward in ipairs(economics.rewardRows or {}) do
        local name = reward.rewardType == "currency" and CurrencyName(reward.currencyID) or ItemName(reward.itemID)
        local label = string.format("%s x%s", name or "Reward", tostring(reward.quantity or 1))
        AddValueLine(label, reward.lineValue, true, reward.unvalued)
    end
    local resourcefulnessPct = tonumber(entry.resourcefulnessPct)
    if resourcefulnessPct then
        AddValueLine(string.format("Expected Resourcefulness (%d%%)", math.floor(resourcefulnessPct + 0.5)),
            economics.expectedResourcefulnessValue or 0, true)
    else
        GameTooltip:AddDoubleLine("Expected Resourcefulness", "Unknown", 1, 1, 1, 0.6, 0.6, 0.6)
    end
    for _, rows in ipairs({ economics.crafterMaterialRows, economics.finishingReagentRows }) do
        for _, mat in ipairs(rows or {}) do
            local label = string.format("%s x%s", ItemName(mat.itemID) or "Mat not chosen", tostring(mat.quantity or 1))
            AddValueLine(label, mat.lineValue and -mat.lineValue or nil, true, mat.unvalued)
        end
    end
    GameTooltip:AddLine(" ")
    AddValueLine("Estimated Profit", entry.estimatedNet, true)
    if entry.hasUnvalued then
        GameTooltip:AddLine("* One of your mats has no price, so actual profit may be lower.", 0.7, 0.7, 0.7, true)
    end
    local chosen = entry.chosenOption
    if chosen then
        GameTooltip:AddLine("Made with: " .. OptionLabel(chosen), 1, 1, 1, true)
        local cost = tonumber(chosen.concentrationCost) or 0
        local have = cost > 0 and GetConcentration(chosen.concentrationCurrencyID) or nil
        if have and have < cost then
            GameTooltip:AddLine(string.format("You only have %d Concentration right now.", have), 1, 0.45, 0.45, true)
        end
        local shownOther = false
        for _, optionResult in ipairs(entry.optionResults or {}) do
            if optionResult.option ~= chosen then
                if not shownOther then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("Other way to make it:", 0.7, 0.7, 0.7)
                    shownOther = true
                end
                AddValueLine(OptionLabel(optionResult.option), optionResult.net, true)
            end
        end
    end
    GameTooltip:AddLine("Estimate: your mats are priced at an estimated quality. Click the order for the exact number.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function PatronOrdersBoard:OpenOrder(entry)
    local ordersPage = GetOrdersPage()
    if not entry or not entry.order or not ordersPage or type(ordersPage.ViewOrder) ~= "function" then
        return
    end
    local ok, err = pcall(ordersPage.ViewOrder, ordersPage, entry.order)
    if not ok then
        PocketCFO:Print("Couldn't open that order from the board. Use Blizzard view and click it there.")
        PocketCFO:Debug("PatronOrdersBoard: ViewOrder failed: %s", tostring(err))
    end
end

-- Patron orders exist from The War Within onward (no Dragon Isles). Child
-- skill line IDs per profession for TWW (Khaz Algar) and Midnight, from the
-- installed knowledge-point tracker's data; Tailoring's 2883/2918 confirmed
-- by /mcgd orderlist. The newest expansion in the list is always allowed so
-- a future expansion works before it is added here.
local PATRON_ORDER_SKILL_LINES = {
    -- The War Within
    [2871] = true, [2872] = true, [2874] = true, [2875] = true, [2877] = true, [2878] = true,
    [2879] = true, [2880] = true, [2881] = true, [2882] = true, [2883] = true,
    -- Midnight
    [2906] = true, [2907] = true, [2909] = true, [2910] = true, [2912] = true, [2913] = true,
    [2914] = true, [2915] = true, [2916] = true, [2917] = true, [2918] = true,
}

local function GetExpansionOptions()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetChildProfessionInfos then
        return {}
    end
    local ok, infos = pcall(C_TradeSkillUI.GetChildProfessionInfos)
    if not ok or type(infos) ~= "table" then
        return {}
    end
    local options = {}
    for index, info in ipairs(infos) do
        if type(info) == "table" and (tonumber(info.skillLevel) or 0) > 0 and info.professionID
            and (PATRON_ORDER_SKILL_LINES[info.professionID] or index == 1) then
            options[#options + 1] = { professionID = info.professionID, expansionName = info.expansionName, info = info }
            if #options >= MAX_EXPANSION_BUTTONS then
                break
            end
        end
    end
    return options
end

local function GetCurrentSkillLineID()
    if not C_TradeSkillUI or not C_TradeSkillUI.GetProfessionChildSkillLineID then
        return nil
    end
    local ok, value = pcall(C_TradeSkillUI.GetProfessionChildSkillLineID)
    return ok and value or nil
end

local function SessionLog(fmt, ...)
    if PocketCFO and PocketCFO.AppendSessionLog then
        PocketCFO:AppendSessionLog("[MCG] " .. string.format(fmt, ...))
    end
end

-- Expansion switching - done exactly the way Blizzard's own expansion
-- dropdown does it (Blizzard 12.1.0 source, Blizzard_Professions.lua
-- InitFilterMenu -> SetExpansionChecked): fire the "Professions.SelectSkillLine"
-- EventRegistry event with the child profession info. ProfessionsFrame's
-- handler (Blizzard_ProfessionsFrame.lua OnLoad) then calls
-- SetProfessionInfo(info, false), which sets the skill line AND refreshes
-- every page; the Orders page's Init sees the profession changed and runs
-- its own StartDefaultSearch, so the patron list reloads immediately.
--
-- Earlier versions called C_TradeSkillUI.SetProfessionChildSkillLineID
-- directly: the skill line changed but no page refreshed (the list only
-- updated after leaving and re-entering the Orders tab), and calling
-- OrdersPage:RequestOrders on top of that cancelled Blizzard's own request.
-- The board never requests orders itself.
-- Loading ends when Blizzard's OrderRequestCallback delivers the patron list
-- (hooked in InstallHooks), or after the timeout.
function PatronOrdersBoard:SwitchExpansion(professionID, expansionName, professionInfo)
    if not professionID or professionID == GetCurrentSkillLineID() then
        return
    end
    local before = GetCurrentSkillLineID()
    local ok, err, path
    if professionInfo and EventRegistry and type(EventRegistry.TriggerEvent) == "function" then
        path = "SelectSkillLine"
        ok, err = pcall(EventRegistry.TriggerEvent, EventRegistry, "Professions.SelectSkillLine", professionInfo)
    elseif C_TradeSkillUI and type(C_TradeSkillUI.SetProfessionChildSkillLineID) == "function" then
        path = "SetProfessionChildSkillLineID"
        ok, err = pcall(C_TradeSkillUI.SetProfessionChildSkillLineID, professionID)
    else
        return
    end
    SessionLog("PatronOrdersBoard: switch %s -> %s (%s) via=%s ok=%s err=%s after=%s",
        tostring(before), tostring(professionID), tostring(expansionName), tostring(path),
        tostring(ok), tostring(err), tostring(GetCurrentSkillLineID()))
    if not ok then
        PocketCFO:Print("Couldn't switch expansion.")
        return
    end

    local token = (self.loadingToken or 0) + 1
    self.loadingToken = token
    self.loadingExpansion = expansionName or "orders"
    self:BeginHold()
    self.retryPending = nil
    self.retryCount = 0

    C_Timer.After(EXPANSION_LOAD_TIMEOUT_SECONDS, function()
        if self.loadingToken == token and self.loadingExpansion then
            SessionLog("PatronOrdersBoard: load timed out skillLine=%s", tostring(GetCurrentSkillLineID()))
            self.loadingExpansion = nil
            self:Refresh()
        end
    end)
    self:Refresh()
end

-- Retry after a throttled/failed response by re-running Blizzard's OWN
-- default search (Blizzard 12.1.0 StartDefaultSearch - the same call the
-- Orders page makes when it opens), so the request always carries Blizzard's
-- correct arguments. Only while a board-initiated switch is still loading.
function PatronOrdersBoard:OnCanRequest()
    if not self.retryPending or not self.loadingExpansion then
        return
    end
    self.retryPending = nil
    self.retryCount = (self.retryCount or 0) + 1
    if self.retryCount > MAX_THROTTLE_RETRIES then
        SessionLog("PatronOrdersBoard: giving up after %d retries", MAX_THROTTLE_RETRIES)
        return
    end
    local ordersPage = GetOrdersPage()
    if ordersPage and type(ordersPage.StartDefaultSearch) == "function" then
        local ok, err = pcall(ordersPage.StartDefaultSearch, ordersPage)
        SessionLog("PatronOrdersBoard: retry %d StartDefaultSearch ok=%s err=%s",
            self.retryCount, tostring(ok), tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Refresh / render
-- ---------------------------------------------------------------------------

function PatronOrdersBoard:QueueRefresh()
    if self.refreshPending then
        return
    end
    self.refreshPending = true
    C_Timer.After(REFRESH_DEBOUNCE_SECONDS, function()
        self.refreshPending = false
        self:Refresh()
    end)
end

-- forcedOrderType: the order type Blizzard just switched to (passed straight
-- from the SetCraftingOrderType hook, which may run before the tab button's
-- isSelected flag updates). Otherwise the Patron tab button decides; the
-- list-contents guess below is only a fallback if that can't be read.
function PatronOrdersBoard:IsPatronTabActive(patronOrders, sawNonPatron, ordersPage, forcedOrderType)
    if forcedOrderType ~= nil then
        return tonumber(forcedOrderType) == NPC_ORDER_TYPE
    end
    local selected = IsPatronTabSelected(ordersPage)
    if selected ~= nil then
        return selected
    end
    if #patronOrders > 0 and not sawNonPatron then
        return true
    end
    if sawNonPatron then
        return false
    end
    -- Empty list: fall back to the last order type Blizzard was asked for.
    return self.currentOrderType == NPC_ORDER_TYPE
end

function PatronOrdersBoard:ScheduleItemLoads(entries)
    if not Item or type(Item.CreateFromItemID) ~= "function" then
        return
    end
    self.pendingItemLoads = self.pendingItemLoads or {}
    self.itemToOrderIDs = self.itemToOrderIDs or {}
    -- When a watched item loads, the cached results of the orders that use
    -- it are dropped so the next redraw recalculates just those orders.
    local function Watch(itemID, orderID)
        itemID = tonumber(itemID)
        if not itemID or ItemName(itemID) then
            return
        end
        if orderID then
            self.itemToOrderIDs[itemID] = self.itemToOrderIDs[itemID] or {}
            self.itemToOrderIDs[itemID][orderID] = true
        end
        if self.pendingItemLoads[itemID] then
            return
        end
        self.pendingItemLoads[itemID] = true
        local ok, item = pcall(Item.CreateFromItemID, Item, itemID)
        if ok and item and item.ContinueOnItemLoad then
            item:ContinueOnItemLoad(function()
                self.pendingItemLoads[itemID] = nil
                for staleOrderID in pairs(self.itemToOrderIDs[itemID] or {}) do
                    if self.entryCache then
                        self.entryCache[staleOrderID] = nil
                    end
                end
                self.itemToOrderIDs[itemID] = nil
                self:QueueRefresh()
            end)
        else
            self.pendingItemLoads[itemID] = nil
        end
    end
    for _, entry in ipairs(entries) do
        Watch(entry.itemID, entry.orderID)
        local economics = entry.economics or {}
        for _, reward in ipairs(economics.rewardRows or {}) do
            Watch(reward.itemID, entry.orderID)
        end
        -- Unpriced mats too: right after login the game hasn't sent their
        -- item details yet, so pricing can't resolve them and they show as
        -- unvalued until the board is redrawn (Brian, 2026-10-12 - off by
        -- 1000g+ on first open). Watch() skips items already loaded, so a
        -- mat that is loaded and still has no price is never re-watched.
        for _, rows in ipairs({ economics.crafterMaterialRows, economics.finishingReagentRows, economics.resourcefulnessRows }) do
            for _, row in ipairs(type(rows) == "table" and rows or {}) do
                if row.unvalued then
                    Watch(row.itemID, entry.orderID)
                end
            end
        end
    end
end

function PatronOrdersBoard:RenderExpansionButtons()
    local overlay = self.overlay
    local options = GetExpansionOptions()
    local current = GetCurrentSkillLineID()
    for index, button in ipairs(overlay.expansionButtons) do
        local option = #options > 1 and options[index] or nil
        if option then
            button.professionID = option.professionID
            button.expansionName = option.expansionName
            button.professionInfo = option.info
            button:SetText(option.expansionName or "?")
            if option.professionID == current then
                button:Disable()
            else
                button:Enable()
            end
            button:Show()
        else
            button:Hide()
        end
    end
end

-- Called when the Patron tab is picked or the list is shown: until Blizzard
-- delivers the patron list (OnBlizzardOrdersDelivered), the board shows
-- "Loading patron orders..." over a stale or empty list instead of letting
-- Blizzard's list show through and then flipping (Brian, 2026-10-13).
-- Safety timeout so a request that never answers can't leave it stuck.
local PATRON_LOAD_TIMEOUT_SECONDS = 10

-- Loading hold (Brian, 2026-10-16): on a fresh load the numbers change
-- several times as data arrives (the order list, item details, prices),
-- and flashing each version reads as "this addon is broken". So a fresh
-- load shows "Loading patron orders..." and draws nothing until the data
-- has stopped changing for HOLD_QUIET_SECONDS (and no item details are
-- still on the way), or HOLD_MAX_SECONDS have passed - then draws once.
-- Fresh load = profession window opened, Patron tab picked, list shown
-- (not coming back from an order), expansion switch, or a different set of
-- orders delivered. "Changing" means the board's numbers actually changed
-- (BoardSignature) - a recheck or price update that changes nothing on the
-- board doesn't restart the quiet timer.
local HOLD_QUIET_SECONDS = 1.0
local HOLD_MAX_SECONDS = 6

function PatronOrdersBoard:BeginHold()
    local now = GetTime()
    self.holdStartedAt = now
    -- Quiet time counts from the last real data change; with none seen yet
    -- it counts from now.
    self.lastChangeAt = self.lastChangeAt or now
end

function PatronOrdersBoard:NoteBoardChange()
    self.lastChangeAt = GetTime()
end

-- Resourcefulness % counts as settled only once it's a number above 0.
-- Seen in-game (Brian, 2026-10-23, Silvermoon Spire Fountain): the first
-- calculation got 0%, the cache kept it, and leaving the expansion and coming
-- back showed 20%. Theoretical: that 0 means the skill line's data hadn't
-- finished loading yet.
local function ResourcefulnessSettled(entry)
    local pct = tonumber(entry and entry.resourcefulnessPct)
    return pct ~= nil and pct > 0
end

-- Everything the board would show for these entries, as one string, so a
-- redraw can tell whether anything visible actually changed.
local function BoardSignature(entries)
    local parts = {}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = table.concat({
            tostring(entry.orderID),
            tostring(entry.estimatedNet),
            tostring(entry.hasUnvalued),
            tostring(entry.recipeKnown),
            tostring(entry.resourcefulnessPct),
            tostring(entry.cannotReachQuality),
            tostring(entry.chosenOption and entry.chosenOption.key),
            tostring(entry.chosenOption and entry.chosenOption.concentrationCost),
            tostring(ItemName(entry.itemID) ~= nil),
        }, ":")
    end
    return table.concat(parts, "|")
end

-- Loading message with cycling dots so a long stage doesn't look frozen.
-- base is the message without dots; the ticker only runs while a loading
-- message is up and stops as soon as the board draws or hides.
function PatronOrdersBoard:ShowLoadingMessage(base)
    local overlay = self.overlay
    self.loadingBase = base
    local function Paint()
        if not self.loadingBase or not self.overlay then
            return
        end
        local dots = (math.floor(GetTime() * 2) % 3) + 1
        self.overlay.message:SetText(self.loadingBase .. string.rep(".", dots))
    end
    overlay.status:SetText("")
    Paint()
    SetColor(overlay.message, COLOR_MUTED)
    overlay.message:Show()
    for _, row in ipairs(overlay.rows) do
        row:Hide()
    end
    if not self.loadingTicker and C_Timer and C_Timer.NewTicker then
        self.loadingTicker = C_Timer.NewTicker(0.5, function()
            if not self.loadingBase or not self.overlay or not self.overlay:IsVisible() then
                self:StopLoadingMessage()
                return
            end
            Paint()
        end)
    end
end

function PatronOrdersBoard:StopLoadingMessage()
    self.loadingBase = nil
    if self.loadingTicker then
        self.loadingTicker:Cancel()
        self.loadingTicker = nil
    end
end

-- One wake-up timer at a time so the hold re-checks itself once the data
-- has gone quiet (or the maximum is reached) even if no event arrives.
function PatronOrdersBoard:ScheduleHoldWake(delay)
    if self.holdWakePending then
        return
    end
    self.holdWakePending = true
    C_Timer.After(math.max(0.05, delay), function()
        self.holdWakePending = nil
        self:QueueRefresh()
    end)
end

function PatronOrdersBoard:BeginPatronLoad()
    if not self.keepLastBoard then
        self:BeginHold()
    end
    self.patronDelivered = false
    local token = (self.patronLoadToken or 0) + 1
    self.patronLoadToken = token
    C_Timer.After(PATRON_LOAD_TIMEOUT_SECONDS, function()
        if self.patronLoadToken == token and not self.patronDelivered then
            SessionLog("PatronOrdersBoard: patron load timed out - showing current list")
            self.patronDelivered = true
            self.keepLastBoard = nil
            self:Refresh()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Per-order result cache (Brian, 2026-10-16: moving around orders was laggy -
-- every redraw recalculated every order from scratch). A patron order's
-- numbers only change when prices change, when one of its items finishes
-- loading, or when the profession window is reopened (skill/knowledge may
-- have changed), so redraws reuse the last result per orderID otherwise.
-- Invalidation: OnPricingUpdated / OnTradeSkillShow wipe it all;
-- ScheduleItemLoads drops the orders that use a just-loaded item;
-- ScheduleUnpricedRecheck drops the orders it is re-checking; orders no
-- longer in Blizzard's list are pruned each normal redraw. Only fully
-- calculated entries are cached - a failed one is retried every redraw.
-- ---------------------------------------------------------------------------

function PatronOrdersBoard:ClearEntryCache()
    self.entryCache = {}
    self.itemToOrderIDs = {}
end

-- Short fingerprint of the order's own data. Blizzard can hand out an
-- order before its details are filled in (rewards especially - a reward
-- link can arrive as "[]" and fill in later), so a cached entry is only
-- reused while this still matches (Brian, 2026-10-16: rewards and KP
-- vanished from the board after the cache went in).
local function OrderFingerprint(order)
    local parts = {
        tostring(SafeRead(order, "tipAmount")),
        tostring(SafeRead(order, "consortiumCut")),
        tostring(SafeRead(order, "minQuality")),
    }
    local reagents = SafeRead(order, "reagents")
    parts[#parts + 1] = tostring(type(reagents) == "table" and #reagents or 0)
    local rewards = SafeRead(order, "npcOrderRewards")
    for _, reward in ipairs(type(rewards) == "table" and rewards or {}) do
        if type(reward) == "table" then
            parts[#parts + 1] = table.concat({
                tostring(reward.itemID or reward.itemId),
                tostring(reward.itemLink or reward.link or reward.hyperlink),
                tostring(reward.currencyType or reward.currencyID or reward.currencyId),
                tostring(reward.count or reward.quantity or reward.amount),
            }, "/")
        end
    end
    return table.concat(parts, "|")
end

function PatronOrdersBoard:GetEntry(order)
    self.entryCache = self.entryCache or {}
    local orderID = SafeRead(order, "orderID")
    local fingerprint = OrderFingerprint(order)
    local cached = orderID and self.entryCache[orderID]
    if cached and cached.fingerprint ~= fingerprint then
        cached = nil
    end
    if cached then
        -- Blizzard hands out a fresh order table per list delivery; keep the
        -- newest one so OpenOrder views the current order.
        cached.order = order
        return cached
    end
    local entry = BuildEntry(order)
    entry.fingerprint = fingerprint
    -- Not cached until Resourcefulness % has settled, so a 0% first read
    -- gets recalculated on the next redraw (see ResourcefulnessSettled).
    if orderID and entry.economics and ResourcefulnessSettled(entry) then
        self.entryCache[orderID] = entry
    end
    return entry
end

function PatronOrdersBoard:PruneEntryCache(patronOrders)
    local live = {}
    for _, order in ipairs(patronOrders) do
        local orderID = SafeRead(order, "orderID")
        if orderID then
            live[orderID] = true
        end
    end
    for orderID in pairs(self.entryCache or {}) do
        if not live[orderID] then
            self.entryCache[orderID] = nil
        end
    end
end

function PatronOrdersBoard:OnPricingUpdated()
    self:ClearEntryCache()
    self:QueueRefresh()
end

function PatronOrdersBoard:Refresh(forcedOrderType)
    local ordersPage = GetOrdersPage()
    local orderList = GetOrderList(ordersPage)
    if not orderList then
        return
    end
    self:BuildFrames(orderList)

    local patronOrders, sawNonPatron = CollectPatronOrders()
    -- Orders you just completed stay off the board even while the game's
    -- list still holds them (see OnFulfillOrderResponse).
    if self.completedOrderIDs and next(self.completedOrderIDs) then
        local kept = {}
        for _, order in ipairs(patronOrders) do
            if not self.completedOrderIDs[SafeRead(order, "orderID")] then
                kept[#kept + 1] = order
            end
        end
        patronOrders = kept
    end
    local active = SafeVisible(orderList)
        and self:IsPatronTabActive(patronOrders, sawNonPatron, ordersPage, forcedOrderType)

    if not active then
        self.overlay:Hide()
        self.toggle:Hide()
        self.boardVisible = false
        self:StopLoadingMessage()
        return
    end

    self.toggle:Show()
    self.toggle:SetText(self.showBlizzard and "PocketCFO view" or "Blizzard view")
    if self.showBlizzard then
        self.overlay:Hide()
        self.boardVisible = false
        self:StopLoadingMessage()
        return
    end
    -- Every time the board goes from not showing to showing, start the
    -- loading hold - whatever event got us here. (The first version only
    -- started it from specific events, and on the first open after a
    -- login/reload none of them reach us: this addon is loaded inside
    -- core's TRADE_SKILL_SHOW handler, after the Orders page has already
    -- shown, so the board's first draws went straight out unheld.)
    -- Coming back from an order keeps the last board instead.
    if not self.boardVisible and not self.keepLastBoard then
        self:BeginHold()
    end
    self.boardVisible = true
    self.overlay:Show()
    self:RenderExpansionButtons()
    self:LayoutColumns(self.overlay.columns, true)

    local overlay = self.overlay
    -- Patron tab open but the list still holds another tab's orders, or is
    -- empty and Blizzard hasn't answered yet: show loading, not that list.
    local waitingForPatronList = sawNonPatron
        or (#patronOrders == 0 and self.patronDelivered == false)
    if self.loadingExpansion or waitingForPatronList then
        -- Back from an order (same tab, same expansion): keep showing the
        -- last board while Blizzard re-requests the list (CloseOrder ->
        -- StartDefaultSearch, Blizzard source) instead of "Loading...".
        if not self.loadingExpansion and self.keepLastBoard and self.lastEntries then
            self:RenderEntries(self.lastEntries, false)
            return
        end
        self:ShowLoadingMessage(self.loadingExpansion
            and ("Getting " .. tostring(self.loadingExpansion) .. " patron orders")
            or "Getting patron orders")
        return
    end

    -- Quality icons are read off Blizzard's own rows; remembered per order
    -- so a redraw while Blizzard's rows are hidden keeps them.
    self.qualityMarkupCache = self.qualityMarkupCache or {}
    for orderID, markup in pairs(CollectBlizzardQualityMarkups(orderList)) do
        self.qualityMarkupCache[orderID] = markup
    end

    local entries = {}
    for _, order in ipairs(patronOrders) do
        entries[#entries + 1] = self:GetEntry(order)
    end
    self:PruneEntryCache(patronOrders)
    table.sort(entries, function(a, b)
        -- Orders you can't craft go to the bottom whatever they'd pay -
        -- you can't complete them (Brian, 2026-10-16). Same for orders
        -- whose required quality you can't reach (Brian, 2026-10-23).
        local aCanMake = a.recipeKnown == true and not a.cannotReachQuality
        local bCanMake = b.recipeKnown == true and not b.cannotReachQuality
        if aCanMake ~= bCanMake then
            return aCanMake
        end
        local av, bv = a.estimatedNet, b.estimatedNet
        if av ~= nil and bv ~= nil then
            return av > bv
        end
        if av ~= nil then return true end
        if bv ~= nil then return false end
        return tostring(a.orderID) < tostring(b.orderID)
    end)
    self.lastEntries = entries

    local signature = BoardSignature(entries)
    if signature ~= self.lastBoardSignature then
        self.lastBoardSignature = signature
        self:NoteBoardChange()
    end

    -- Follow-ups run while holding too, so the data they fetch lands
    -- before the first draw rather than after it.
    self:ScheduleItemLoads(entries)
    self:ScheduleUnpricedRecheck(entries)

    -- Loading hold (see HOLD_QUIET_SECONDS): keep the loading message up
    -- until the data has settled, then draw once.
    if self.holdStartedAt then
        local now = GetTime()
        local heldFor = now - self.holdStartedAt
        local quietFor = now - (self.lastChangeAt or self.holdStartedAt)
        local itemsPending = next(self.pendingItemLoads or {}) ~= nil
        -- Also wait for Blizzard's fresh list if one was requested, rather
        -- than drawing the list the game still holds from last time.
        local listPending = self.patronDelivered == false
        if heldFor < HOLD_MAX_SECONDS and (quietFor < HOLD_QUIET_SECONDS or itemsPending or listPending) then
            -- Say what we're actually waiting on.
            self:ShowLoadingMessage((listPending and "Getting patron orders")
                or (itemsPending and "Loading item details")
                or "Calculating estimated profits")
            local untilQuiet = HOLD_QUIET_SECONDS - quietFor
            local untilMax = HOLD_MAX_SECONDS - heldFor
            self:ScheduleHoldWake((untilQuiet > 0 and math.min(untilQuiet, untilMax) or math.min(0.25, untilMax)) + 0.02)
            return
        end
        self.holdStartedAt = nil
    end

    self:RenderEntries(entries, false)
end

-- Draws already-calculated entries. scheduleFollowUps = false for the
-- "keep last board" redraw (nothing new was calculated, so no item-load or
-- unpriced re-checks to schedule).
function PatronOrdersBoard:RenderEntries(entries, scheduleFollowUps)
    local overlay = self.overlay
    self:StopLoadingMessage()
    local qualityMarkups = self.qualityMarkupCache or {}

    local available = overlay:GetHeight() - HEADER_HEIGHT - COLUMN_HEADER_HEIGHT - 20
    local maxRows = math.max(1, math.floor(available / ROW_HEIGHT))
    local shown = math.min(#entries, maxRows)

    if #entries == 0 then
        overlay.message:SetText("No patron orders right now.")
        SetColor(overlay.message, COLOR_MUTED)
        overlay.message:Show()
    else
        overlay.message:Hide()
    end
    local anyUnpricedMat = false
    for index = 1, shown do
        if entries[index].hasUnvalued then
            anyUnpricedMat = true
        end
    end
    local statusParts = {}
    if anyUnpricedMat then
        statusParts[#statusParts + 1] = "* One of your mats has no price, so actual profit may be lower"
    end
    if #entries > shown then
        statusParts[#statusParts + 1] = string.format("Showing best %d of %d", shown, #entries)
    end
    -- First-run guidance: until one full price scan has finished, the status
    -- line says how to get prices instead (short form - the line is one row,
    -- 440px wide). Missing Valuation addon is treated as "scanned".
    local valuation = _G.PocketCFO_Valuation
    local needsScan = valuation and valuation.HasCompletedPriceScan and not valuation:HasCompletedPriceScan()
    if needsScan then
        statusParts = { "No prices yet: open the Auction House > Pocket CFO tab > Scan Prices" }
    end
    overlay.status:SetText(table.concat(statusParts, "  |  "))
    SetColor(overlay.status, needsScan and COLOR_HEADER or COLOR_MUTED)

    for index = 1, shown do
        local entry = entries[index]
        local row = self:GetRow(index)
        self:LayoutColumns(row, false)
        row.entry = entry

        local qualityMarkup = qualityMarkups[entry.orderID]
        row.name:SetText((ItemName(entry.itemID) or ("Item " .. tostring(entry.itemID)))
            .. (qualityMarkup and (" " .. qualityMarkup) or ""))
        row.rewards:SetText(RewardIconsMarkup(entry.rewardIcons))
        SetColor(row.name, (entry.recipeKnown == false or entry.cannotReachQuality) and COLOR_NEGATIVE or COLOR_TEXT)

        if entry.cannotReachQuality then
            -- Same treatment as an unknown recipe: red name, no profit
            -- (Brian, 2026-10-23). Full reason is in the tooltip.
            row.profit:SetText("Can't make")
            SetColor(row.profit, COLOR_NEGATIVE)
        elseif entry.estimatedNet ~= nil then
            row.profit:SetText(FormatGold(entry.estimatedNet, true) .. (entry.hasUnvalued and "*" or ""))
            SetColor(row.profit, entry.estimatedNet < 0 and COLOR_NEGATIVE or COLOR_POSITIVE)
        else
            row.profit:SetText("?")
            SetColor(row.profit, COLOR_MUTED)
        end

        row.conc:SetText(entry.cannotReachQuality and "" or ConcentrationMarkup(entry))

        row.kp:SetText(entry.knowledge or "")
        SetColor(row.kp, COLOR_KP)

        row.time:SetText(FormatTimeLeft(entry.expirationTime))
        SetColor(row.time, COLOR_TEXT)

        if entry.allMatsProvided then
            row.mats:SetText("All")
            SetColor(row.mats, COLOR_POSITIVE)
        else
            row.mats:SetText((entry.customerMatCount or 0) > 0 and "Some" or "None")
            SetColor(row.mats, COLOR_MUTED)
        end

        row:Show()
    end
    for index = shown + 1, #overlay.rows do
        overlay.rows[index]:Hide()
        overlay.rows[index].entry = nil
    end

    if scheduleFollowUps then
        self:ScheduleItemLoads(entries)
        self:ScheduleUnpricedRecheck(entries)
    end
end

-- First-open safety net: some of your mats (Charged Alloy, Aqirite, Bismuth)
-- showed unpriced on the first draw and priced fine moments later.
-- CONFIRMED cause (session log, 2026-10-12): their item data wasn't cached
-- yet (ItemIdentityService "cache.base.miss ... itemDataRequest ...
-- pendingItemData"), so pricing couldn't build the market key. Blizzard's
-- reagent quality lookup was fine (q=2 at draw). The main fix is the
-- item-load watch in ScheduleItemLoads; this bounded re-draw catches
-- anything that watch misses.
-- While any of your mats is unpriced, re-draw a few times (1.5s, 3s, 6s).
-- Bounded: the count resets only when Blizzard delivers a list with a
-- different set of orders (not on every delivery - going back from an order
-- re-delivers the same list), so a mat with genuinely no price costs three
-- redraws, then stops.
local UNPRICED_RECHECK_DELAYS = { 1.5, 3, 6 }

function PatronOrdersBoard:ScheduleUnpricedRecheck(entries)
    if self.unpricedRecheckPending then
        return
    end
    local attempt = (self.unpricedRecheckCount or 0) + 1
    local delay = UNPRICED_RECHECK_DELAYS[attempt]
    if not delay or not C_Timer or not C_Timer.After then
        return
    end

    local unpriced = {}
    local recheckOrderIDs = {}
    for _, entry in ipairs(entries or {}) do
        -- Same bounded recheck for a Resourcefulness % that hasn't settled.
        if entry.economics and entry.orderID and not ResourcefulnessSettled(entry) then
            recheckOrderIDs[entry.orderID] = true
            unpriced[#unpriced + 1] = string.format("rf(%s)=%s", tostring(entry.orderID), tostring(entry.resourcefulnessPct))
        end
        local economics = entry.economics or {}
        for _, rows in ipairs({ economics.crafterMaterialRows, economics.finishingReagentRows }) do
            for _, row in ipairs(type(rows) == "table" and rows or {}) do
                if row.unvalued and entry.orderID then
                    recheckOrderIDs[entry.orderID] = true
                end
                if row.unvalued and row.itemID then
                    local okQuality, quality = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, row.itemID)
                    unpriced[#unpriced + 1] = string.format("%s(q=%s)", tostring(row.itemID),
                        okQuality and tostring(quality) or "ERR")
                end
            end
        end
    end
    if #unpriced == 0 then
        return
    end

    SessionLog("PatronOrdersBoard: unpriced mats on draw, recheck %d in %.1fs: %s",
        attempt, delay, table.concat(unpriced, ", "))
    self.unpricedRecheckCount = attempt
    self.unpricedRecheckPending = true
    C_Timer.After(delay, function()
        self.unpricedRecheckPending = nil
        -- Re-check means recalculate: drop those orders' cached results.
        for orderID in pairs(recheckOrderIDs) do
            if self.entryCache then
                self.entryCache[orderID] = nil
            end
        end
        self:QueueRefresh()
    end)
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function PatronOrdersBoard:InstallHooks()
    if self.hooksInstalled then
        return
    end
    local ordersPage = GetOrdersPage()
    local orderList = GetOrderList(ordersPage)
    if not ordersPage or not orderList then
        return
    end

    if type(ordersPage.SetCraftingOrderType) == "function" then
        hooksecurefunc(ordersPage, "SetCraftingOrderType", function(_, orderType)
            self.currentOrderType = tonumber(orderType)
            self:BeginPatronLoad()
            -- Immediate, not debounced: cover Blizzard's list on the same
            -- frame the tab is picked.
            self:Refresh(orderType)
        end)
    end
    -- Blizzard's own "orders arrived" path: OrderRequestCallback(result,
    -- orderType, ...) runs once the server answers and the list is shown.
    if type(ordersPage.OrderRequestCallback) == "function" then
        hooksecurefunc(ordersPage, "OrderRequestCallback", function(_, result, orderType)
            self:OnBlizzardOrdersDelivered(result, orderType)
        end)
    end
    -- Opening an order hides the list; Back (CloseOrder) shows it again and
    -- re-requests the same list. Remember an order was open so the return
    -- trip keeps the last board up instead of "Loading..." (see Refresh).
    if type(ordersPage.ViewOrder) == "function" then
        hooksecurefunc(ordersPage, "ViewOrder", function()
            self.viewingOrder = true
        end)
    end
    if type(ordersPage.HookScript) == "function" then
        ordersPage:HookScript("OnHide", function()
            self.viewingOrder = nil
            self.keepLastBoard = nil
        end)
    end
    orderList:HookScript("OnShow", function()
        self.keepLastBoard = self.viewingOrder and self.lastEntries ~= nil or nil
        self.viewingOrder = nil
        self:BeginPatronLoad()
        self:Refresh()
    end)
    self.hooksInstalled = true
end

function PatronOrdersBoard:OnBlizzardOrdersDelivered(result, orderType)
    -- Every Blizzard order response, so a slow expansion switch can be traced
    -- (result: Enum.CraftingOrderResult - 0 = Ok; throttling shows here).
    SessionLog("PatronOrdersBoard: Blizzard order response result=%s orderType=%s skillLine=%s loading=%s",
        tostring(result), tostring(orderType), tostring(GetCurrentSkillLineID()), tostring(self.loadingExpansion))
    if tonumber(orderType) == NPC_ORDER_TYPE then
        -- Patron list answered (even a failed answer ends the "Loading"
        -- screen - the throttle retry below still runs for expansion switches).
        -- Except an empty list or a failed answer: Blizzard often gets the
        -- first request wrong (see TryEmptyListRetry), so keep loading and
        -- ask again. A failed answer during an expansion switch is left to
        -- the switch's own throttle retry below.
        local resultOK = tonumber(result) == ORDER_RESULT_OK
        local shouldRetry = (resultOK and #(CollectPatronOrders()) == 0)
            or (not resultOK and not self.loadingExpansion)
        if shouldRetry and self:TryEmptyListRetry(resultOK and "empty" or ("result=" .. tostring(result))) then
            -- still loading; the retry's answer comes back through here
        else
            self.patronDelivered = true
            self.emptyRetryCount = 0
        end
    end
    if tonumber(orderType) == NPC_ORDER_TYPE and self.loadingExpansion
        and tonumber(result) ~= ORDER_RESULT_OK then
        -- Throttled or failed: Blizzard does not retry on its own (the list
        -- just stays stale - the likely cause of the 30s switch on
        -- 2026-10-12). Retry once the game says requests are allowed.
        self.retryPending = true
        SessionLog("PatronOrdersBoard: response not OK (result=%s) - retry on CRAFTINGORDERS_CAN_REQUEST",
            tostring(result))
        self:QueueRefresh()
        return
    end
    if tonumber(orderType) == NPC_ORDER_TYPE and self.loadingExpansion then
        self.loadingExpansion = nil
        self.retryPending = nil
        self.retryCount = 0
        local patronOrders = CollectPatronOrders()
        SessionLog("PatronOrdersBoard: patron list delivered result=%s skillLine=%s orders=%d firstItemID=%s",
            tostring(result), tostring(GetCurrentSkillLineID()), #patronOrders,
            tostring(patronOrders[1] and SafeRead(patronOrders[1], "itemID")))
    end
    if tonumber(orderType) == NPC_ORDER_TYPE then
        self.keepLastBoard = nil
    end
    if tonumber(result) == ORDER_RESULT_OK then
        -- A different set of orders gets a fresh unpriced-mat recheck
        -- budget; the same list re-delivered (back from an order) does not.
        local ids = {}
        local delivered = {}
        for _, order in ipairs((CollectPatronOrders())) do
            local orderID = SafeRead(order, "orderID")
            delivered[orderID or false] = true
            ids[#ids + 1] = tostring(orderID)
        end
        -- A completed order the server no longer lists can stop being
        -- filtered out.
        for orderID in pairs(self.completedOrderIDs or {}) do
            if not delivered[orderID] then
                self.completedOrderIDs[orderID] = nil
            end
        end
        table.sort(ids)
        local orderSetSignature = table.concat(ids, ",")
        if orderSetSignature ~= self.lastOrderSetSignature then
            self.lastOrderSetSignature = orderSetSignature
            -- Only orders the board hasn't calculated yet make this a fresh
            -- load (hold + loading messages). Orders merely gone - completed,
            -- expired - redraw straight from the cache (Brian, 2026-10-16:
            -- completing an order re-ran the whole loading sequence).
            local shown = {}
            for _, entry in ipairs(self.lastEntries or {}) do
                shown[entry.orderID or false] = true
            end
            local hasNewOrders = self.lastEntries == nil
            for orderID in pairs(delivered) do
                if not shown[orderID] and not (self.completedOrderIDs and self.completedOrderIDs[orderID]) then
                    hasNewOrders = true
                end
            end
            if hasNewOrders then
                self.unpricedRecheckCount = 0
                self:BeginHold()
            end
        end
    end
    self:QueueRefresh()
end

-- Blizzard bug (Brian, 2026-10-16, present since patron orders launched):
-- on the first load the Patron tab often shows 0 orders - tab count
-- included - until you click another tab and back. That click runs
-- ClearCachedRequests() + StartDefaultSearch() (Blizzard source,
-- Blizzard_ProfessionsCrafterOrderPage.lua InitOrderTypeTabs). When the
-- patron list comes back empty, or Blizzard answers with a failure result
-- (Brian, 2026-10-16: the bug still hit with the empty-only check), we run
-- those same two calls ourselves, up
-- to EMPTY_LIST_MAX_RETRIES times, while the board keeps "Getting patron
-- orders...". Only then does it say there are none. The tab count is wrong
-- too in the bug, so there's no way to tell "bug" from "really zero" -
-- a real zero just costs a few seconds and two extra requests.
-- Theoretical: the cause (likely the first request racing
-- OpenCrafterCraftingOrders); the fix doesn't depend on it.
local EMPTY_LIST_RETRY_DELAY_SECONDS = 1.5
local EMPTY_LIST_MAX_RETRIES = 2

function PatronOrdersBoard:TryEmptyListRetry(reason)
    local ordersPage = GetOrdersPage()
    if not ordersPage or SafeRead(ordersPage, "orderType") ~= NPC_ORDER_TYPE then
        return false
    end
    if (self.emptyRetryCount or 0) >= EMPTY_LIST_MAX_RETRIES then
        SessionLog("PatronOrdersBoard: patron list still empty after %d retries", EMPTY_LIST_MAX_RETRIES)
        return false
    end
    self.emptyRetryCount = (self.emptyRetryCount or 0) + 1
    local attempt = self.emptyRetryCount
    C_Timer.After(EMPTY_LIST_RETRY_DELAY_SECONDS, function()
        local page = GetOrdersPage()
        if not page or SafeRead(page, "orderType") ~= NPC_ORDER_TYPE or not SafeVisible(GetOrderList(page)) then
            self.patronDelivered = true
            self.emptyRetryCount = 0
            self:QueueRefresh()
            return
        end
        local okClear = type(page.ClearCachedRequests) == "function" and pcall(page.ClearCachedRequests, page)
        local okSearch, err = false, "StartDefaultSearch missing"
        if type(page.StartDefaultSearch) == "function" then
            okSearch, err = pcall(page.StartDefaultSearch, page)
        end
        SessionLog("PatronOrdersBoard: patron list %s - retry %d clear=%s search=%s err=%s",
            tostring(reason), attempt, tostring(okClear), tostring(okSearch), tostring(err))
        if not okSearch then
            self.patronDelivered = true
            self.emptyRetryCount = 0
            self:QueueRefresh()
        end
    end)
    return true
end

-- Handler args are read defensively: CraftSim bundles its own AceEvent that
-- has been seen to dispatch PocketCFO callbacks without the event name as
-- the first argument (see project API findings).
-- Server confirmed an order was completed: take it off the board right
-- away instead of waiting for Blizzard's refreshed list. Payload (result,
-- orderID) confirmed in Blizzard source (Blizzard_ProfessionsCrafterOrderView
-- .lua, CRAFTINGORDERS_FULFILL_ORDER_RESPONSE); not yet watched in-game.
-- Args read defensively for the CraftSim AceEvent shift (see below).
function PatronOrdersBoard:OnFulfillOrderResponse(first, second, third)
    local result, orderID
    if type(first) == "string" then
        result, orderID = second, third
    else
        result, orderID = first, second
    end
    if tonumber(result) ~= ORDER_RESULT_OK or orderID == nil then
        return
    end
    self.completedOrderIDs = self.completedOrderIDs or {}
    self.completedOrderIDs[orderID] = true
    if self.entryCache then
        self.entryCache[orderID] = nil
    end
    if self.lastEntries then
        local kept = {}
        for _, entry in ipairs(self.lastEntries) do
            if entry.orderID ~= orderID then
                kept[#kept + 1] = entry
            end
        end
        self.lastEntries = kept
    end
    self:QueueRefresh()
end

function PatronOrdersBoard:OnOrderCountUpdated(first, second)
    local orderType = (type(first) == "string") and second or first
    -- Tab counts only; the loading state ends in OnBlizzardOrdersDelivered.
    self:QueueRefresh()
end

function PatronOrdersBoard:OnTradeSkillShow()
    -- Skill or knowledge may have changed since the window was last open,
    -- and the last board may be another expansion's - start clean.
    self:ClearEntryCache()
    self.lastEntries = nil
    self:BeginHold()
    self:InstallHooks()
    self:QueueRefresh()
end

function PatronOrdersBoard:OnEnable()
    self:RegisterEvent("CRAFTINGORDERS_UPDATE_ORDER_COUNT", "OnOrderCountUpdated")
    self:RegisterEvent("CRAFTINGORDERS_CAN_REQUEST", "OnCanRequest")
    self:RegisterEvent("CRAFTINGORDERS_FULFILL_ORDER_RESPONSE", "OnFulfillOrderResponse")
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
    self:RegisterMessage("PCFO_PRICING_UPDATED", "OnPricingUpdated")
    self:InstallHooks()
    self:QueueRefresh()
end
