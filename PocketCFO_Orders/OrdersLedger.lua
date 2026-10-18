-- PocketCFO_Orders/OrdersLedger.lua
-- Order results: what completed crafting orders actually earned.
--
-- For each completed order:
--   earned = gold paid (crafter payout)
--          + rewards (items and currency, valued; unpriced rewards count as 0)
--          + resourcefulness (mats the craft actually returned, valued)
--          - mats used (your mats + finishing reagents)
-- Valued with the same OrderEconomicsService / ValuationService rules Order
-- Analysis uses for its estimate, at the time the order is completed. Only the
-- resourcefulness part differs: the actual returns replace the expected ones.
--
-- Storage (running totals, no per-order rows):
--   PocketCFO_Orders_DB.global.orderResults.days[dayKey][characterGUID][professionKey][orderTypeKey]
--     = { orders, goldPaid, rewards, resourcefulness, mats, earned }
-- dayKey = local "YYYY-MM-DD"; professionKey = base profession ID as string;
-- orderTypeKey = "patron" | "personal" | "public" | "guild" | "unknown".
--
-- Flow (keyed by orderID):
--   1. Craft start (post-hook C_TradeSkillUI.CraftRecipe): evaluate the order
--      while its mats are still allocated.
--   2. Craft result (TRADE_SKILL_ITEM_CRAFTED_RESULT): add the actual
--      resourcesReturned value. Evaluates here instead if step 1 missed.
--   3. Order completed (post-hook C_CraftingOrders.FulfillOrder): add the
--      order to the day's totals. Evaluates here as a last resort.
--
-- Theoretical until seen in-game (session log shows each step):
--   - CraftRecipe is the call used for order crafts, and the order's mats are
--     still allocated in its post-hook.
--   - TRADE_SKILL_ITEM_CRAFTED_RESULT fires for order crafts with
--     resourcesReturned ({ reagent = { itemID }, quantity }, shape confirmed
--     for normal crafts in CraftEventCapture).
--
-- Sends AceEvent message "MCG_ORDER_RESULTS_UPDATED" after each saved order.
-- The Orders tab in PocketCFO_PnL reads GetDays().

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Orders = _G.PocketCFO_Orders

local OrdersLedger = PocketCFO_Orders:NewModule("OrdersLedger", "AceEvent-3.0")

-- Enum.CraftingOrderType: Public = 0, Guild = 1, Personal = 2, Npc = 3
local ORDER_TYPE_KEY = {
    [0] = "public",
    [1] = "guild",
    [2] = "personal",
    [3] = "patron",
}

OrdersLedger.pending = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] OrdersLedger: " .. tostring(msg))
end

local function FormatCopper(copper)
    copper = tonumber(copper) or 0
    local sign = copper < 0 and "-" or ""
    copper = math.abs(math.floor(copper))
    return string.format("%s%dg%02ds%02dc", sign,
        math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100)
end

local function ResultsDB()
    local db = PocketCFO_Orders.db and PocketCFO_Orders.db.global
    if not db then
        return nil
    end
    db.orderResults = db.orderResults or {}
    db.orderResults.days = db.orderResults.days or {}
    return db.orderResults
end

-- Same frame path as OrderObservationBuilder / CraftEventCapture.IsOrderCraft.
local function CurrentOrder()
    local ordersPage = ProfessionsFrame and ProfessionsFrame.OrdersPage
    local orderView = ordersPage and ordersPage.OrderView
    if ordersPage and ordersPage.IsShown and ordersPage:IsShown()
        and orderView and orderView.IsShown and orderView:IsShown() then
        return orderView.order
    end
    return nil
end

-- Same guarded access OrderEconomicsService uses; never force-loads.
local function GetValuationService()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_Valuation"))
        or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_Valuation"))
    if not loaded then
        return nil
    end
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule("ValuationService", true)
end

local function ProfessionKey(professionEnum)
    local registry = PocketCFO and PocketCFO.ProfessionRegistry
    if professionEnum and registry and registry.GetProfessionIDFromEnum then
        local professionID = registry:GetProfessionIDFromEnum(professionEnum)
        if professionID then
            return tostring(professionID)
        end
    end
    if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
        local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
        if ok and type(info) == "table" and info.professionID then
            return tostring(info.professionID)
        end
    end
    return "none"
end

-- ---------------------------------------------------------------------------
-- Capture
-- ---------------------------------------------------------------------------

function OrdersLedger:Evaluate(orderID, stage)
    local order = CurrentOrder()
    if not order or tonumber(order.orderID) ~= tonumber(orderID) then
        SessionLog("evaluate skipped stage=%s orderID=%s reason=order-not-in-view", tostring(stage), tostring(orderID))
        return false
    end
    local economicsService = PocketCFO_Orders:GetModule("OrderEconomicsService", true)
    if not economicsService or not economicsService.EvaluateCurrentOrder then
        SessionLog("evaluate skipped stage=%s orderID=%s reason=economics-unavailable", tostring(stage), tostring(orderID))
        return false
    end
    local ok, result = pcall(economicsService.EvaluateCurrentOrder, economicsService)
    if not ok or type(result) ~= "table" or not result.resolved or type(result.economics) ~= "table" then
        SessionLog("evaluate failed stage=%s orderID=%s reason=%s", tostring(stage), tostring(orderID),
            tostring(ok and type(result) == "table" and result.unresolvedReason or result))
        return false
    end
    local entry = self.pending[orderID] or { returnsValue = 0 }
    self.pending[orderID] = entry
    entry.economics = result.economics
    entry.orderType = tonumber(order.orderType)
    entry.stage = stage
    SessionLog("evaluated stage=%s orderID=%s orderType=%s payout=%s rewards=%s mats=%s",
        tostring(stage), tostring(orderID), tostring(entry.orderType),
        FormatCopper(result.economics.crafterPayout),
        FormatCopper(result.economics.valuedRewardValue),
        FormatCopper((tonumber(result.economics.crafterMaterialCost) or 0)
            + (tonumber(result.economics.finishingReagentCost) or 0)))
    return true
end

function OrdersLedger:OnCraftRecipe()
    local order = CurrentOrder()
    local orderID = order and tonumber(order.orderID)
    if orderID then
        self:Evaluate(orderID, "craft-start")
    end
end

-- Values the reagents the craft actually returned. Unpriced returns count as 0.
local function ValueReturns(resourcesReturned)
    local valuation = GetValuationService()
    local total, quantity = 0, 0
    for _, entry in ipairs(type(resourcesReturned) == "table" and resourcesReturned or {}) do
        local itemID = tonumber(entry and entry.reagent and entry.reagent.itemID)
        local qty = tonumber(entry and entry.quantity) or 0
        if itemID and qty > 0 then
            quantity = quantity + qty
            if valuation then
                local ok, priced = pcall(valuation.GetItemValue, valuation, itemID)
                if ok and type(priced) == "table" and not priced.unresolved and priced.valuePerUnit ~= nil then
                    total = total + (tonumber(priced.valuePerUnit) or 0) * qty
                end
            end
        end
    end
    return total, quantity
end

function OrdersLedger:OnCraftResult(event, result)
    -- Guard for the shifted AceEvent signature some bundled copies use.
    if type(event) == "table" and result == nil then
        result = event
    end
    if type(result) ~= "table" then
        return
    end
    local order = CurrentOrder()
    local orderID = order and tonumber(order.orderID)
    if not orderID then
        return
    end
    if not (self.pending[orderID] and self.pending[orderID].economics) then
        self:Evaluate(orderID, "craft-result")
    end
    local entry = self.pending[orderID] or { returnsValue = 0 }
    self.pending[orderID] = entry
    local value, quantity = ValueReturns(result.resourcesReturned)
    entry.returnsValue = (entry.returnsValue or 0) + value
    SessionLog("craft result orderID=%s resourcefulness qty=%d value=%s",
        tostring(orderID), quantity, FormatCopper(value))
end

function OrdersLedger:OnFulfillOrder(orderID, _, professionEnum)
    orderID = tonumber(orderID)
    if not orderID then
        return
    end
    if not (self.pending[orderID] and self.pending[orderID].economics) then
        self:Evaluate(orderID, "fulfill")
    end
    local entry = self.pending[orderID]
    self.pending[orderID] = nil
    if not entry or not entry.economics then
        SessionLog("order completed but not recorded orderID=%s reason=no-evaluation", tostring(orderID))
        return
    end
    self:Record(entry, ProfessionKey(professionEnum))
end

function OrdersLedger:Record(entry, professionKey)
    local results = ResultsDB()
    local guid = UnitGUID and UnitGUID("player")
    if not results or not guid then
        return
    end
    local economics = entry.economics
    local goldPaid = tonumber(economics.crafterPayout) or 0
    local rewards = tonumber(economics.valuedRewardValue) or 0
    local resourcefulness = tonumber(entry.returnsValue) or 0
    local mats = (tonumber(economics.crafterMaterialCost) or 0) + (tonumber(economics.finishingReagentCost) or 0)
    local earned = goldPaid + rewards + resourcefulness - mats

    local dayKey = date("%Y-%m-%d")
    local typeKey = ORDER_TYPE_KEY[entry.orderType] or "unknown"

    local day = results.days[dayKey] or {}
    results.days[dayKey] = day
    local character = day[guid] or {}
    day[guid] = character
    local profession = character[professionKey] or {}
    character[professionKey] = profession
    local row = profession[typeKey] or { orders = 0, goldPaid = 0, rewards = 0, resourcefulness = 0, mats = 0, earned = 0 }
    profession[typeKey] = row

    row.orders = row.orders + 1
    row.goldPaid = row.goldPaid + goldPaid
    row.rewards = row.rewards + rewards
    row.resourcefulness = row.resourcefulness + resourcefulness
    row.mats = row.mats + mats
    row.earned = row.earned + earned

    SessionLog("recorded day=%s profession=%s type=%s earned=%s (gold=%s rewards=%s resourcefulness=%s mats=%s)",
        dayKey, professionKey, typeKey, FormatCopper(earned), FormatCopper(goldPaid),
        FormatCopper(rewards), FormatCopper(resourcefulness), FormatCopper(mats))
    self:SendMessage("MCG_ORDER_RESULTS_UPDATED")
end

-- Read-only view for display code (PocketCFO_PnL). Callers must not modify it.
function OrdersLedger:GetDays()
    local results = ResultsDB()
    return results and results.days or {}
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function OrdersLedger:InstallHooks()
    if self.hooksInstalled then
        return
    end
    self.hooksInstalled = true
    if C_TradeSkillUI and type(C_TradeSkillUI.CraftRecipe) == "function" then
        hooksecurefunc(C_TradeSkillUI, "CraftRecipe", function() OrdersLedger:OnCraftRecipe() end)
    end
    if C_CraftingOrders and type(C_CraftingOrders.FulfillOrder) == "function" then
        hooksecurefunc(C_CraftingOrders, "FulfillOrder", function(...) OrdersLedger:OnFulfillOrder(...) end)
    end
end

function OrdersLedger:OnEnable()
    self:InstallHooks()
    self:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", "OnCraftResult")
end

function OrdersLedger:OnDisable()
    self:UnregisterAllEvents()
end
