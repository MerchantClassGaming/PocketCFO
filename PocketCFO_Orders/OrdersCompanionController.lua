-- PocketCFO_Orders/OrdersCompanionController.lua
-- Order Analysis mode provider for PocketCFO_Crafting's companion window
-- shell (see PocketCFO_Crafting/UI/InventoryManager/InventoryManagerWindow.lua
-- RegisterMode/ActivateMode/DeactivateMode). Owns:
--   - Detecting when the Blizzard Orders page is active
--   - Reading the selected order and evaluating current economics
--   - Refreshing when selected order or allocations change
--   - Rendering Order Analysis content inside the supplied shell content area
--   - Deactivating cleanly when returning to Recipes
--
-- Crafting owns shell creation/position/size/show-hide/parenting/mode
-- switching - this module never touches those. No Order business logic
-- lives in CraftQueueController; this is that logic's home instead.
--
-- Refresh triggers: OrdersPage/OrderView OnShow/OnHide (HookScript, standard
-- Frame API), TRADE_SKILL_SHOW/TRADE_SKILL_CLOSE (belt-and-suspenders re-check
-- in case OrdersPage's own OnHide never fires when the whole profession
-- window closes - IsVisible() is checked, not just IsShown(), for the same
-- reason), PCFO_PRICING_UPDATED, the OrderDetails.SchematicForm's
-- AllocationsModified callback (debounced - see InstallSchematicFormHook),
-- Item:ContinueOnItemLoad for any row whose name lagged its already-resolved
-- itemID (see ScheduleItemLoadRefresh), and a polling fallback while active
-- (normally gated on BuildOrderSignature changing, plus a small bounded
-- number of extra ticks when the last render was not fully settled - see
-- unsettledRetryCount).
--
-- CORRECTED: the original polling fallback compared only orderID:reagentCount
-- (order.reagents, the customer-committed list - see BuildOrderSignature),
-- which does not change when Blizzard's own OrderDetails.SchematicForm
-- transaction finishes populating asynchronously after an order is first
-- selected. That left the first render after /reload showing an incomplete
-- result (Unknown reagent/Unvalued rows for slots whose allocation hadn't
-- landed yet) until the user reselected the order (OrderView's OnShow firing
-- again, by which point the transaction had settled) - see git history for
-- the /mcgd capture that isolated this. AllocationsModified is confirmed
-- present on this same Blizzard SchematicForm mixin via
-- PocketCFO_Crafting/Crafting/CraftQueueController.lua's use of it on the
-- Crafting page's SchematicForm; reused here as the direct signal instead of
-- relying solely on the coarse signature poll.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Orders = _G.PocketCFO_Orders

local OrdersCompanionController = PocketCFO_Orders:NewModule("OrdersCompanionController", "AceEvent-3.0")

local POLL_INTERVAL_SECONDS = 1.0

-- Coalescing debounce for Blizzard's AllocationsModified callback - matches
-- CraftQueueController's ANALYSIS_INPUT_REFRESH_DEBOUNCE_SECONDS rationale:
-- Blizzard can fire this more than once for a single change (e.g. an old
-- allocation clearing, then the new one landing), so one coalesced refresh
-- avoids evaluating the order twice per change.
local ALLOCATIONS_MODIFIED_DEBOUNCE_SECONDS = 0.1

-- Bounds the extra poll ticks Refresh grants itself per order selection when
-- the last render was not fully settled (see IsUnsettled) - e.g. schematic
-- reagent-variant data or item data still hydrating. Resets to 0 whenever
-- BuildOrderSignature changes (a genuinely new order selection), so this can
-- never compound into an unbounded retry loop for one stuck order.
local MAX_UNSETTLED_POLL_RETRIES = 6

local function GetCraftingWindow()
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_Crafting"))
        or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_Crafting"))
    if not loaded then
        return nil
    end
    local crafting = _G.PocketCFO_Crafting
    return crafting and crafting.GetModule and crafting:GetModule("InventoryManagerWindow", true)
end

local function GetOrderEconomicsService()
    return PocketCFO_Orders:GetModule("OrderEconomicsService", true)
end

local function GetDisplayModelBuilder()
    return PocketCFO_Orders:GetModule("OrderDisplayModelBuilder", true)
end

local function GetContent()
    return PocketCFO_Orders.OrderAnalysisContent
end

local function RegisterWithCraftingWindow(provider)
    local craftingWindow = GetCraftingWindow()
    if craftingWindow and craftingWindow.RegisterMode then
        craftingWindow:RegisterMode("orders", provider)
        return true
    end
    return false
end

local function SafeRead(parent, key)
    if parent == nil then
        return false, nil
    end
    return pcall(function() return parent[key] end)
end

-- IsVisible() (not IsShown()) - reflects the whole ancestor chain, so a
-- profession-window close that never fires OrdersPage's own OnHide script
-- (Blizzard hiding an ancestor doesn't fire a child's OnHide) still reads as
-- "not visible" here once something re-runs this check (TRADE_SKILL_CLOSE
-- below is that trigger).
local function SafeVisible(frame)
    if not frame then
        return false
    end
    local ok, visible = pcall(frame.IsVisible, frame)
    if ok then
        return visible == true
    end
    local okShown, shown = pcall(frame.IsShown, frame)
    return okShown and shown == true
end

local function ResolveOrdersPage()
    local professionsFrame = _G.ProfessionsFrame
    local okOrdersPage, ordersPage = SafeRead(professionsFrame, "OrdersPage")
    if not okOrdersPage then
        return nil
    end
    return ordersPage
end

local function ResolveOrderView(ordersPage)
    local okOrderView, orderView = SafeRead(ordersPage, "OrderView")
    if not okOrderView then
        return nil
    end
    return orderView
end

-- Same OrderDetails.SchematicForm path OrderObservationBuilder's
-- ResolveOrderForm reads (see that file's SOURCE_PATHS.transaction) - kept
-- as a separate, read-only local copy here rather than a shared export,
-- since this controller only needs it to install a callback hook, not to
-- read allocation data itself.
local function ResolveSchematicForm(orderView)
    local okDetails, details = SafeRead(orderView, "OrderDetails")
    if not okDetails or not details then
        return nil
    end
    local okForm, form = SafeRead(details, "SchematicForm")
    if not okForm then
        return nil
    end
    return form
end

-- Cheap signature of "what's currently selected/allocated," used only by the
-- polling fallback to decide whether a refresh is worth running. Deliberately
-- coarse - a false positive (refreshing when nothing meaningfully changed) is
-- cheap; a false negative (missing a real change) is the failure mode this
-- exists to avoid.
local function BuildOrderSignature()
    local orderView = ResolveOrderView(ResolveOrdersPage())
    local okOrder, order = SafeRead(orderView, "order")
    if not okOrder or not order then
        return "none"
    end
    local okOrderID, orderID = SafeRead(order, "orderID")
    local okReagents, reagents = SafeRead(order, "reagents")
    local reagentCount = (okReagents and type(reagents) == "table") and #reagents or 0
    return tostring(okOrderID and orderID or "?") .. ":" .. tostring(reagentCount)
end

-- True when the just-rendered result still has a reason to expect a delayed
-- dependency (Blizzard schematic/transaction data, item data, valuation
-- cache) to arrive later: an "unavailable" display state (order selected but
-- the pipeline couldn't resolve it - e.g. transactionUnavailable,
-- operationInfoUnavailable), or any row still marked unvalued. Used only to
-- decide whether to spend a few of the poll's bounded extra retries (see
-- MAX_UNSETTLED_POLL_RETRIES) - a genuinely, permanently unresolved/unvalued
-- row (Cases 8/9: real valuation failure, real identity failure) harmlessly
-- exhausts that bounded budget and then stays in its correct final state; it
-- is never retried forever.
local function RowsUnvalued(rows)
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        if row.unvalued then
            return true
        end
    end
    return false
end

local function IsUnsettled(displayModel)
    if type(displayModel) ~= "table" then
        return false
    end
    if displayModel.state == "unavailable" then
        return true
    end
    if displayModel.state ~= "resolved" then
        return false
    end
    return RowsUnvalued(displayModel.crafterMaterials)
        or RowsUnvalued(displayModel.finishingReagents)
        or RowsUnvalued(displayModel.expectedResourcefulness)
        or RowsUnvalued(displayModel.rewards)
end

-- Collects itemIDs whose display name is a client-side cache miss even
-- though identity/value already resolved (OrderDisplayModelBuilder's
-- row.namePending - see that file). Deduped so ScheduleItemLoadRefresh
-- schedules at most one Item:ContinueOnItemLoad per itemID per call.
local function CollectPendingItemIDs(displayModel)
    local itemIDs = {}
    if type(displayModel) ~= "table" then
        return itemIDs
    end
    local seen = {}
    for _, rows in ipairs({
        displayModel.crafterMaterials,
        displayModel.finishingReagents,
        displayModel.expectedResourcefulness,
        displayModel.rewards,
    }) do
        for _, row in ipairs(type(rows) == "table" and rows or {}) do
            if row.namePending and row.itemID and not seen[row.itemID] then
                seen[row.itemID] = true
                itemIDs[#itemIDs + 1] = row.itemID
            end
        end
    end
    return itemIDs
end

function OrdersCompanionController:OnEnable()
    self.generation = 0
    self.lastSignature = nil
    self.active = false
    self.hooksInstalled = false
    self.unsettledRetryCount = 0
    self.pendingItemLoads = {}

    RegisterWithCraftingWindow(self)

    self:RegisterMessage("PCFO_PRICING_UPDATED", "OnPricingUpdated")
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
    self:RegisterEvent("TRADE_SKILL_CLOSE", "OnTradeSkillClose")

    self:InstallFrameHooks()
    self:EvaluateOrdersPageVisibility()
end

function OrdersCompanionController:InstallFrameHooks()
    if self.hooksInstalled then
        return
    end

    local ordersPage = ResolveOrdersPage()
    if not ordersPage or type(ordersPage.HookScript) ~= "function" then
        return
    end

    ordersPage:HookScript("OnShow", function() self:EvaluateOrdersPageVisibility() end)
    ordersPage:HookScript("OnHide", function() self:EvaluateOrdersPageVisibility() end)

    local orderView = ResolveOrderView(ordersPage)
    if orderView and type(orderView.HookScript) == "function" then
        orderView:HookScript("OnShow", function() self:Refresh() end)
    end

    self.hooksInstalled = true
end

-- Blizzard's SchematicForm (ProfessionsRecipeSchematicFormMixin, a
-- CallbackRegistryMixin) exposes an AllocationsModified callback - confirmed
-- present on the Crafting page's SchematicForm instance (see
-- PocketCFO_Crafting/Crafting/CraftQueueController.lua's
-- InstallAllocationsModifiedRefreshHook: "RegisterCallback/
-- Event.AllocationsModified/TriggerEvent all present" via a live /mcgd dump)
-- and reused here on the Orders page's OrderDetails.SchematicForm, the same
-- underlying Blizzard mixin. This is the direct signal for "Blizzard's order
-- transaction/allocation state just changed," including the async
-- transition from "not yet populated" to "populated" that happens shortly
-- after first selecting an order - the exact transition BuildOrderSignature
-- cannot see (order.reagents, the customer-committed list, does not change
-- when the transaction populates).
--
-- Unlike InstallFrameHooks, this is NOT gated on self.hooksInstalled: the
-- SchematicForm does not exist until an order has actually been selected at
-- least once, so this is called from Refresh() (cheap once installed, via
-- the guard flag on the form instance below) so it keeps attempting
-- installation on every meaningful refresh trigger until it succeeds.
function OrdersCompanionController:InstallSchematicFormHook()
    local sf = ResolveSchematicForm(ResolveOrderView(ResolveOrdersPage()))
    if not sf or not sf.RegisterCallback or not sf.Event or not sf.Event.AllocationsModified then
        return
    end
    if sf.__pcfoOrdersAllocationsModifiedHooked then
        return
    end

    sf:RegisterCallback(sf.Event.AllocationsModified, function()
        self:QueueDebouncedRefresh()
    end, self)
    -- "Use Best Quality Reagents" checkbox. Confirmed in Blizzard 12.1.0
    -- source: the checkbox only fires UseBestQualityModified
    -- (Blizzard_ProfessionsRecipeSchematicForm.lua); the order view's own
    -- handler then re-allocates the mats straight on the transaction
    -- (Blizzard_ProfessionsCrafterOrderView.lua, AllocateAllBasicReagents)
    -- without firing AllocationsModified - so the checkbox only refreshed
    -- by luck before (Brian, 2026-10-12). Blizzard registered its handler
    -- first, and the debounce runs after it, so we read the new mats.
    if sf.Event.UseBestQualityModified then
        sf:RegisterCallback(sf.Event.UseBestQualityModified, function()
            self:QueueDebouncedRefresh()
        end, self)
    end
    sf.__pcfoOrdersAllocationsModifiedHooked = true
end

function OrdersCompanionController:QueueDebouncedRefresh()
    if self.allocationsRefreshPending then
        return
    end
    if not C_Timer or type(C_Timer.After) ~= "function" then
        self:Refresh()
        return
    end

    self.allocationsRefreshPending = true
    C_Timer.After(ALLOCATIONS_MODIFIED_DEBOUNCE_SECONDS, function()
        self.allocationsRefreshPending = false
        if self.active then
            self:Refresh()
        end
    end)
end

-- Item names can lag behind item identity by a client-side cache miss
-- (Blizzard's Item Data API, not addon-controlled): GetItemInfo/
-- C_Item.GetItemInfo can return nil for an item PocketCFO has never
-- requested before, even though itemID/ConfigKey/value are already resolved
-- (see OrderDisplayModelBuilder's row.namePending). Item:ContinueOnItemLoad
-- is the standard Blizzard Item Data API callback for "this item's data
-- just finished loading." It is used here only to retrigger the full
-- pipeline (OrderObservationBuilder -> OrderEconomicsService ->
-- OrderDisplayModelBuilder -> render) via Refresh(), never to patch the
-- rendered row's text directly - the stale display model could still be
-- missing other things (see Refresh()'s Required behavior #2).
--
-- signatureAtSchedule pins this callback to the order that was selected
-- when the pending name was observed (BuildOrderSignature, the same stable
-- per-selection token Refresh already maintains in self.lastSignature) - if
-- the player has since switched to a different order by the time the item
-- finishes loading, self.lastSignature will have moved on and this callback
-- is a no-op instead of overwriting the newer selection's result.
function OrdersCompanionController:ScheduleItemLoadRefresh(displayModel, signatureAtSchedule)
    if not Item or type(Item.CreateFromItemID) ~= "function" then
        return
    end

    self.pendingItemLoads = self.pendingItemLoads or {}
    for _, itemID in ipairs(CollectPendingItemIDs(displayModel)) do
        if not self.pendingItemLoads[itemID] then
            self.pendingItemLoads[itemID] = true
            local item = Item:CreateFromItemID(itemID)
            item:ContinueOnItemLoad(function()
                self.pendingItemLoads[itemID] = nil
                if self.active and self.lastSignature == signatureAtSchedule then
                    self:Refresh()
                end
            end)
        end
    end
end

function OrdersCompanionController:OnTradeSkillShow()
    RegisterWithCraftingWindow(self)
    self:InstallFrameHooks()
    self:EvaluateOrdersPageVisibility()
end

function OrdersCompanionController:OnTradeSkillClose()
    self:EvaluateOrdersPageVisibility()
end

function OrdersCompanionController:EvaluateOrdersPageVisibility()
    self:InstallFrameHooks()

    local visible = SafeVisible(ResolveOrdersPage())

    if visible and not self.active then
        self:Activate()
    elseif not visible and self.active then
        self:Deactivate()
    elseif visible then
        self:Refresh()
    end
end

function OrdersCompanionController:Activate()
    RegisterWithCraftingWindow(self)
    local craftingWindow = GetCraftingWindow()
    if not craftingWindow or not craftingWindow.ActivateMode then
        return
    end
    craftingWindow:ActivateMode("orders")
end

function OrdersCompanionController:Deactivate()
    local craftingWindow = GetCraftingWindow()
    if craftingWindow and craftingWindow.DeactivateMode then
        craftingWindow:DeactivateMode()
    end
end

-- RegisterMode contract (InventoryManagerWindow calls these) ----------------

function OrdersCompanionController:GetShellState()
    return {
        title = "Orders Manager",
        inventoryControlsVisible = false,
    }
end

function OrdersCompanionController:OnActivate(contentFrame)
    self.active = true
    self.contentFrame = contentFrame

    local content = GetContent()
    if content then
        content:Build(contentFrame)
        content:ShowLoading()
    end

    self:StartPolling()
    self:Refresh()
end

function OrdersCompanionController:OnDeactivate()
    self.active = false
    self:StopPolling()
    self.unsettledRetryCount = 0
    self.pendingItemLoads = {}

    local content = GetContent()
    if content then
        content:Clear()
    end
end

-- Refresh triggers ------------------------------------------------------------

function OrdersCompanionController:OnPricingUpdated()
    if self.active then
        self:Refresh()
    end
end

function OrdersCompanionController:StartPolling()
    self:StopPolling()
    if not C_Timer or type(C_Timer.NewTicker) ~= "function" then
        return
    end
    self.pollTicker = C_Timer.NewTicker(POLL_INTERVAL_SECONDS, function()
        if not self.active then
            return
        end
        -- Refresh either when the coarse selection signature changed, or
        -- when the last render was unsettled and still has budget left (see
        -- IsUnsettled/MAX_UNSETTLED_POLL_RETRIES) - the correctness net for
        -- any delayed dependency not already covered by
        -- InstallSchematicFormHook/ScheduleItemLoadRefresh/
        -- OnPricingUpdated.
        if BuildOrderSignature() ~= self.lastSignature or (self.unsettledRetryCount or 0) > 0 then
            self:Refresh()
        end
    end)
end

function OrdersCompanionController:StopPolling()
    if self.pollTicker then
        self.pollTicker:Cancel()
        self.pollTicker = nil
    end
end

--- Re-evaluates the currently selected order and renders the result. Always
-- runs the full pipeline (OrderEconomicsService:EvaluateCurrentOrder rebuilds
-- the observation from scratch via OrderObservationBuilder, then
-- OrderDisplayModelBuilder reshapes it) - never patches the existing display
-- model or row text in place, since a stale model can be missing item IDs,
-- ConfigKeys, values, or names, not just a name string.
-- Generation-counter guarded so a slower/stale evaluation can never
-- overwrite a result produced by a newer selection/refresh.
function OrdersCompanionController:Refresh()
    if not self.active then
        return
    end

    self:InstallSchematicFormHook()

    local signature = BuildOrderSignature()
    if signature ~= self.lastSignature then
        -- A genuinely new order selection gets its own fresh budget of
        -- bounded unsettled-retry poll ticks (see MAX_UNSETTLED_POLL_RETRIES)
        -- rather than inheriting whatever count the previous order left
        -- behind.
        self.unsettledRetryCount = 0
    end
    self.lastSignature = signature

    local economicsService = GetOrderEconomicsService()
    local displayModelBuilder = GetDisplayModelBuilder()
    local content = GetContent()
    if not economicsService or not displayModelBuilder or not content then
        return
    end

    self.generation = (self.generation or 0) + 1
    local thisGeneration = self.generation

    local ok, result = pcall(function()
        return economicsService:EvaluateCurrentOrder()
    end)
    if not ok then
        result = { resolved = false, unresolvedReason = "economicsEvaluationError" }
    end

    if thisGeneration ~= self.generation or not self.active then
        return
    end

    local displayModel = displayModelBuilder:Build(result)
    content:Render(displayModel)

    if IsUnsettled(displayModel) and (self.unsettledRetryCount or 0) < MAX_UNSETTLED_POLL_RETRIES then
        self.unsettledRetryCount = (self.unsettledRetryCount or 0) + 1
    else
        self.unsettledRetryCount = 0
    end

    self:ScheduleItemLoadRefresh(displayModel, signature)
end

if PocketCFO_Orders then
    PocketCFO_Orders.OrdersCompanionController = OrdersCompanionController
end
