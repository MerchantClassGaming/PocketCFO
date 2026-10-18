-- PocketCFO_Orders/Services/OrderObservationBuilder.lua
-- Read-only normalization of the currently selected Blizzard crafting order.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Orders = _G.PocketCFO_Orders
local ReagentSlots = PocketCFO and PocketCFO.ReagentSlotService

local OrderObservationBuilder = PocketCFO_Orders:NewModule("OrderObservationBuilder")

-- CORRECTED after a live /mcgd orderdata capture on Arcanoweave Treads
-- (recipeID 1228986) falsified the previous "0 = customer, 1 = crafter"
-- reading of order.reagents[].source: Spark of Radiance appeared in
-- order.reagents with source=1 on an order where the customer definitely
-- supplied it. The same capture showed order.reagents holding only 4 rows
-- while the schematic defines 6 required slots and the live crafting form
-- has all 6 populated - order.reagents is not an incomplete/buggy dataset,
-- it is Blizzard's list of reagents the CUSTOMER committed to the order when
-- posting it, nothing more. It never lists crafter-filled slots at all.
--
-- API responsibility split (see BuildCurrentOrderObservation):
--   order.reagents (ProfessionsFrame.OrdersPage.OrderView.order.reagents)
--     -> ownership evidence only. A slot's presence here means the customer
--        supplied it, full stop - regardless of the row's .source value,
--        which is NOT a reliable customer/crafter enum (see above). Absence
--        from this list means the customer did not supply that slot.
--   OrderDetails.SchematicForm:GetTransaction() (GetAllocations /
--   CreateCraftingReagentInfoTbl)
--     -> the canonical, complete allocation state: the actual item + quantity
--        currently loaded into every schematic slot, customer- and
--        crafter-filled alike. This is the only source that is complete
--        across all slots; order.reagents is not.
--   C_TradeSkillUI.GetRecipeSchematic(...).reagentSlotSchematics
--     -> slot structure/classification (required/optional/finishing,
--        possible-reagent choices) only. slot.orderSource is a recipe-design
--        property, not a per-order ownership fact - do not use it to decide
--        who supplied a given order's reagent (same reason order.reagents'
--        row-level .source cannot be trusted for this).
--   C_TradeSkillUI.GetCraftingOperationInfoForOrder(...)
--     -> derived crafting stats (quality, Resourcefulness %) for a given
--        reagent table. Not an allocation source at all.
--
-- Net rule: for every schematic slot, the transaction supplies "what item is
-- here", and order.reagents supplies "did the customer put it here" - a slot
-- is customer-provided iff it has a matching order.reagents row (regardless
-- of that row's .source), otherwise it is crafter-provided (sourced from the
-- transaction). This is the single place that applies this rule - do not
-- re-derive ownership from source/orderSource elsewhere.

local SOURCE_PATHS = {
    order = "ProfessionsFrame.OrdersPage.OrderView.order",
    recipe = "C_TradeSkillUI.GetRecipeSchematic",
    transaction = "OrderDetails.SchematicForm:GetTransaction",
    operationInfo = "C_TradeSkillUI.GetCraftingOperationInfoForOrder",
}

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

local function NonEmpty(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return tostring(value)
end

local function NewDiagnostics()
    return ReagentSlots.NewDiagnostics()
end

local function Unresolved(reason, diagnostics)
    return {
        resolved = false,
        unresolvedReason = reason,
        diagnostics = diagnostics or NewDiagnostics(),
    }
end

local function SafeRead(parent, key)
    if parent == nil then
        return false, nil
    end
    return pcall(function()
        return parent[key]
    end)
end

local function SafeMethod(object, methodName, ...)
    if object == nil then
        return false, nil
    end
    local args = { ... }
    local okMethod, method = SafeRead(object, methodName)
    if not okMethod or type(method) ~= "function" then
        return false, nil
    end
    return pcall(function()
        return method(object, unpack(args))
    end)
end

local function ApiCall(apiTable, functionName, ...)
    if type(apiTable) ~= "table" or type(apiTable[functionName]) ~= "function" then
        return false, nil, "missingAPI"
    end
    local args = { pcall(apiTable[functionName], ...) }
    local ok = table.remove(args, 1)
    if not ok then
        return false, nil, args[1]
    end
    return true, args[1], nil
end

local function IsShownIfAvailable(frame)
    local ok, shown = SafeMethod(frame, "IsShown")
    if ok then
        return shown == true
    end
    return true
end

local function ResolveOrdersContext(diagnostics)
    local professionsFrame = _G.ProfessionsFrame
    if not professionsFrame then
        return nil, Unresolved("professionFrameUnavailable", diagnostics)
    end

    local okOrdersPage, ordersPage = SafeRead(professionsFrame, "OrdersPage")
    if not okOrdersPage or not ordersPage then
        return nil, Unresolved("ordersPageUnavailable", diagnostics)
    end
    if not IsShownIfAvailable(ordersPage) then
        return nil, Unresolved("ordersPageNotShown", diagnostics)
    end

    local okOrderView, orderView = SafeRead(ordersPage, "OrderView")
    if not okOrderView or not orderView then
        return nil, Unresolved("orderViewUnavailable", diagnostics)
    end
    if not IsShownIfAvailable(orderView) then
        return nil, Unresolved("orderViewNotShown", diagnostics)
    end

    local okOrder, order = SafeRead(orderView, "order")
    if not okOrder or not order then
        return nil, Unresolved("selectedOrderUnavailable", diagnostics)
    end

    return {
        professionsFrame = professionsFrame,
        ordersPage = ordersPage,
        orderView = orderView,
        order = order,
    }, nil
end

local function ResolveOrderForm(orderView, diagnostics)
    local okDetails, details = SafeRead(orderView, "OrderDetails")
    if not okDetails or not details then
        return nil, Unresolved("orderFormUnavailable", diagnostics)
    end

    local okForm, form = SafeRead(details, "SchematicForm")
    if not okForm or not form then
        return nil, Unresolved("orderFormUnavailable", diagnostics)
    end

    return form, nil
end

local function ResolveRecipeID(order)
    local candidates = { "spellID", "recipeID", "recipeId", "recipeSpellID", "recipeSpellId" }
    for _, fieldName in ipairs(candidates) do
        local ok, value = SafeRead(order, fieldName)
        value = ok and NumberOrNil(value) or nil
        if value then
            return value, fieldName
        end
    end
    return nil, nil
end

local function ResolveOrderID(order)
    local candidates = { "orderID", "orderId", "craftingOrderID", "craftingOrderId" }
    for _, fieldName in ipairs(candidates) do
        local ok, value = SafeRead(order, fieldName)
        value = ok and NumberOrNil(value) or nil
        if value then
            return value, fieldName
        end
    end
    return nil, nil
end

local function ResolveOutputItemID(order, recipeInfo, schematicInfo)
    return NumberOrNil(recipeInfo and recipeInfo.outputItemID)
        or NumberOrNil(recipeInfo and recipeInfo.itemID)
        or NumberOrNil(schematicInfo and schematicInfo.outputItemID)
        or NumberOrNil(order and order.itemID)
end

-- Canonical key for correlating an order.reagents row's slot to a schematic
-- slotRow. slotIndex first - confirmed authoritative and globally unique
-- (see header comment and ReagentSlotService.MatchesSlot). dataSlotIndex is only used when
-- slotIndex is unavailable on either side - CORRECTED after a live capture
-- proved dataSlotIndex repeats across slot groups (e.g. slot 1 and slot 4
-- both reported dataSlotIndex=1 on Thalassian Competitor's Cloth Hood,
-- recipeID 1228992), which previously caused a customer row on one slot
-- group to wrongly suppress an unrelated crafter-filled slot in another
-- group that happened to share the same dataSlotIndex. Used to build/check
-- the "did the customer already claim this slot" set that
-- NormalizeCrafterReagents consults. Exposed publicly (see bottom of file)
-- so /mcgd orderdata's slot-resolution diagnostic can match slots using this
-- exact same rule instead of a separately maintained copy.
local function SlotClaimKey(slotIndex, dataSlotIndex)
    if slotIndex then
        return "slot:" .. tostring(slotIndex)
    end
    if dataSlotIndex then
        return "data:" .. tostring(dataSlotIndex)
    end
    return nil
end

-- Builds customerProvidedReagents from order.reagents and returns the set of
-- schematic slots the customer claimed, keyed by SlotClaimKey. Every row
-- Blizzard returns in order.reagents is, by definition, a reagent the
-- customer selected and committed to the order when they posted it (see
-- header comment) - presence here IS the ownership signal. orderRow.source
-- is recorded on the row for diagnostic evidence only and never gates
-- inclusion or classification.
local function NormalizeCustomerReagents(order, slotRows, diagnostics)
    local result = {}
    local seen = {}
    local claimedSlotKeys = {}
    local slotByDataIndex = {}
    local slotBySlotAndDataIndex = {}
    for _, slotRow in ipairs(slotRows or {}) do
        if slotRow.slotIndex and slotRow.dataSlotIndex then
            slotBySlotAndDataIndex[tostring(slotRow.slotIndex) .. ":" .. tostring(slotRow.dataSlotIndex)] = slotRow
        end
        if slotRow.dataSlotIndex then
            slotByDataIndex[slotRow.dataSlotIndex] = slotByDataIndex[slotRow.dataSlotIndex] or slotRow
        end
    end

    local reagents = type(order) == "table" and order.reagents or nil
    if type(reagents) ~= "table" then
        return result, claimedSlotKeys
    end

    for _, orderRow in ipairs(reagents) do
        if type(orderRow) == "table" then
            local reagentInfo = type(orderRow.reagentInfo) == "table" and orderRow.reagentInfo or {}
            local reagent = type(reagentInfo.reagent) == "table" and reagentInfo.reagent or {}
            local dataSlotIndex = NumberOrNil(reagentInfo.dataSlotIndex)
            local slotIndex = NumberOrNil(orderRow.slotIndex)
            local slotRow = slotIndex and dataSlotIndex
                and slotBySlotAndDataIndex[tostring(slotIndex) .. ":" .. tostring(dataSlotIndex)]
                or dataSlotIndex and slotByDataIndex[dataSlotIndex]
                or nil

            local row = ReagentSlots.BuildNormalizedReagent({
                slotOrdinal = slotRow and slotRow.slotOrdinal,
                slotIndex = slotIndex,
                dataSlotIndex = dataSlotIndex,
                itemID = NumberOrNil(reagent.itemID),
                currencyID = NumberOrNil(reagent.currencyID),
                quantity = NumberOrNil(reagentInfo.quantity),
                reagentType = slotRow and slotRow.reagentType,
                dataSlotType = slotRow and slotRow.dataSlotType,
                required = slotRow and slotRow.required,
                orderSource = NumberOrNil(orderRow.source),
                suppliedBy = "customer",
                classification = slotRow and slotRow.classification or "unknown",
            }, diagnostics, "order.reagents")

            if row.itemID or row.currencyID then
                ReagentSlots.AddUniqueRow(result, row, seen, diagnostics, "order.reagents")
                local claimKey = SlotClaimKey(slotIndex, dataSlotIndex)
                if claimKey then
                    claimedSlotKeys[claimKey] = true
                end
            end
        end
    end

    return result, claimedSlotKeys
end

-- Builds crafterProvidedReagents/finishingReagents from the live crafting
-- transaction - the canonical, complete allocation state across every
-- schematic slot (see header comment). A slot is processed here iff the
-- customer did NOT already claim it via an order.reagents row
-- (claimedSlotKeys, from NormalizeCustomerReagents) - this replaces the old
-- slotRow.responsibility gate, which relied on schematicSlot.orderSource and
-- produced exactly the observed failure: required slots the crafter actually
-- filled (e.g. a fixed-reagent slot with no order.reagents row) were skipped
-- entirely because their schematic orderSource didn't resolve to "crafter",
-- while a customer-supplied special reagent whose orderSource did resolve to
-- "crafter" was wrongly pulled in here. Convention: crafterProvidedReagents
-- contains required/optional non-finishing costs only. finishingReagents
-- contains finishing-slot costs, so future valuation consumers do not
-- double-count the same allocation. Slots with no live allocation (quantity
-- 0, e.g. an empty optional/finishing slot) naturally produce no row, unless
-- the slot is required, in which case Core's ReagentSlotService forces a
-- full-required-quantity row so operation economics never depend on current
-- inventory. Per-slot reading lives in ReagentSlotService.AddCrafterSlotRows
-- (shared with Recipe Analysis).
local function NormalizeCrafterReagents(transaction, reagentTbl, slotRows, claimedSlotKeys, diagnostics, preferTopQuality)
    local crafterProvided = {}
    local finishing = {}
    local seen = {}
    local consumedReagentRows = {}

    for _, slotRow in ipairs(slotRows or {}) do
        local claimKey = SlotClaimKey(slotRow.slotIndex, slotRow.dataSlotIndex)
        local claimedByCustomer = claimKey and claimedSlotKeys and claimedSlotKeys[claimKey]
        if not claimedByCustomer then
            local target = slotRow.classification == "finishing" and finishing or crafterProvided
            ReagentSlots.AddCrafterSlotRows(target, seen, consumedReagentRows, transaction, reagentTbl, slotRow, diagnostics, preferTopQuality)
        end
    end

    ReagentSlots.MarkNotChosenRows({ crafterProvided, finishing }, slotRows)
    return crafterProvided, finishing
end

-- Does this order require the output item's top rank?
-- minQuality is a rank on the item's own scale (2 can be the top of a
-- 2-rank item or a low rank of a 5-rank item - Brian, 2026-10-16 captures).
-- Confirmed in Blizzard source (wow-ui-source, Blizzard_ProfessionsCrafter
-- OrderPage.lua): the order list calls C_TradeSkillUI.GetQualitiesForRecipe
-- (spellID) for orders that are not open, one quality ID per rank, and
-- Blizzard_ProfessionsTemplates.lua only shows a requirement icon when
-- minQuality > 1.
-- @return true (top rank required) | false (no requirement or below top) |
--         nil (requirement exists but the rank count could not be read)
local function ResolveNeedsTopQuality(recipeID, minQuality)
    local minRank = NumberOrNil(minQuality) or 1
    local okQualities, qualityIDs = ApiCall(C_TradeSkillUI, "GetQualitiesForRecipe", recipeID)
    local topRank = (okQualities and type(qualityIDs) == "table") and #qualityIDs or 0
    if topRank > 1 then
        return minRank >= topRank
    end
    if minRank <= 1 then
        return false
    end
    return nil
end

-- True when the order does not need top quality and at least one mat the
-- crafter is supplying (from Blizzard's live allocation, not our estimate)
-- is above the lowest quality variant of its slot. Feeds the "check your
-- mats" note only - never changes cost.
local function UsesHigherQualityMatsThanNeeded(needsTopQuality, crafterProvided, slotRows)
    if needsTopQuality ~= false then
        return false
    end
    local slotByOrdinal = {}
    for _, slotRow in ipairs(slotRows or {}) do
        slotByOrdinal[slotRow.slotOrdinal] = slotRow
    end
    for _, row in ipairs(crafterProvided or {}) do
        local slotRow = slotByOrdinal[row.slotOrdinal]
        if slotRow and row.itemID and row.identityBasis ~= "estimatedQualityFallback" then
            local index = ReagentSlots.GetQualityVariantIndex(slotRow, row.itemID)
            if index and index > 1 then
                return true
            end
        end
    end
    return false
end

local function NormalizeRewards(order, diagnostics)
    local itemRewards = {}
    local currencyRewards = {}
    local rewards = type(order) == "table" and order.npcOrderRewards or nil
    if type(rewards) ~= "table" then
        return itemRewards, currencyRewards
    end

    for _, reward in ipairs(rewards) do
        if type(reward) == "table" then
            local currencyID = NumberOrNil(reward.currencyType or reward.currencyID or reward.currencyId)
            local quantity = NumberOrNil(reward.count or reward.quantity or reward.amount) or 1
            if currencyID then
                currencyRewards[#currencyRewards + 1] = {
                    currencyID = currencyID,
                    quantity = quantity,
                }
            else
                local itemLink = NonEmpty(reward.itemLink or reward.link or reward.hyperlink)
                local itemID = NumberOrNil(reward.itemID or reward.itemId)
                if not itemID and itemLink and GetItemInfoFromHyperlink then
                    local ok, parsedItemID = pcall(GetItemInfoFromHyperlink, itemLink)
                    itemID = ok and NumberOrNil(parsedItemID) or nil
                end
                if itemID or itemLink then
                    local row = ReagentSlots.AttachConfigKey({
                        itemLink = itemLink,
                        itemID = itemID,
                        quantity = quantity,
                    }, diagnostics, "order.npcOrderRewards")
                    itemRewards[#itemRewards + 1] = row
                end
            end
        end
    end

    return itemRewards, currencyRewards
end

local function ExtractDisplayedResourcefulnessPct(operationInfo)
    local bonusStats = type(operationInfo) == "table" and operationInfo.bonusStats or nil
    if type(bonusStats) ~= "table" then
        return nil
    end

    for _, stat in ipairs(bonusStats) do
        if type(stat) == "table" and stat.bonusStatName == "Resourcefulness" then
            return NumberOrNil(stat.ratingPct)
        end
    end
    return nil
end

local function ConfirmOrderUnchanged(orderID)
    local order = _G.ProfessionsFrame
        and _G.ProfessionsFrame.OrdersPage
        and _G.ProfessionsFrame.OrdersPage.OrderView
        and _G.ProfessionsFrame.OrdersPage.OrderView.order
    local currentOrderID = NumberOrNil(order and order.orderID)
    return currentOrderID ~= nil and currentOrderID == orderID
end

function OrderObservationBuilder:BuildCurrentOrderObservation()
    local diagnostics = NewDiagnostics()

    local context, unresolved = ResolveOrdersContext(diagnostics)
    if unresolved then
        return unresolved
    end

    local order = context.order
    local orderID = ResolveOrderID(order)
    if not orderID then
        return Unresolved("selectedOrderUnavailable", diagnostics)
    end

    local recipeID = ResolveRecipeID(order)
    if not recipeID then
        return Unresolved("recipeIDUnavailable", diagnostics)
    end

    local isRecraft = order.isRecraft == true
    local okRecipeInfo, recipeInfo = ApiCall(C_TradeSkillUI, "GetRecipeInfo", recipeID)
    if not okRecipeInfo or type(recipeInfo) ~= "table" then
        return Unresolved("recipeSchematicUnavailable", diagnostics)
    end

    local okSchematic, schematicInfo = ApiCall(C_TradeSkillUI, "GetRecipeSchematic", recipeID, isRecraft)
    if not okSchematic or type(schematicInfo) ~= "table" then
        return Unresolved("recipeSchematicUnavailable", diagnostics)
    end

    local form
    form, unresolved = ResolveOrderForm(context.orderView, diagnostics)
    if unresolved then
        return unresolved
    end

    local okTransaction, transaction = SafeMethod(form, "GetTransaction")
    if not okTransaction or not transaction then
        return Unresolved("transactionUnavailable", diagnostics)
    end

    local okReagentTbl, reagentTbl = SafeMethod(transaction, "CreateCraftingReagentInfoTbl")
    if not okReagentTbl or type(reagentTbl) ~= "table" then
        return Unresolved("transactionUnavailable", diagnostics)
    end

    local okConcentrating, concentrating = SafeMethod(transaction, "IsApplyingConcentration")
    concentrating = okConcentrating and concentrating == true or false

    local okOperationInfo, operationInfo = ApiCall(
        C_TradeSkillUI,
        "GetCraftingOperationInfoForOrder",
        recipeID,
        reagentTbl,
        orderID,
        concentrating
    )
    if not okOperationInfo or type(operationInfo) ~= "table" then
        return Unresolved("operationInfoUnavailable", diagnostics)
    end

    local slotRows = ReagentSlots.BuildSlotRows(schematicInfo, diagnostics)
    local customerProvidedReagents, claimedSlotKeys = NormalizeCustomerReagents(order, slotRows, diagnostics)
    local needsTopQuality = ResolveNeedsTopQuality(recipeID, order.minQuality)
    local crafterProvidedReagents, finishingReagents = NormalizeCrafterReagents(transaction, reagentTbl, slotRows, claimedSlotKeys, diagnostics, needsTopQuality == true)
    local itemRewards, currencyRewards = NormalizeRewards(order, diagnostics)

    local tipAmount = NumberOrNil(order.tipAmount)
    local consortiumCut = NumberOrNil(order.consortiumCut)
    if tipAmount == nil and order.tipAmount == nil then
        tipAmount = 0
    end
    if consortiumCut == nil and order.consortiumCut == nil then
        consortiumCut = 0
    end

    local outputItemID = ResolveOutputItemID(order, recipeInfo, schematicInfo)
    local outputIdentity
    if outputItemID then
        local outputRow = ReagentSlots.AttachConfigKey({ itemID = outputItemID }, diagnostics, "recipe.outputItem")
        outputIdentity = outputRow.configKey and {
            itemID = outputItemID,
            configKey = outputRow.configKey,
        } or nil
    end

    local observation = {
        orderID = orderID,
        orderType = NumberOrNil(order.orderType),
        orderState = NumberOrNil(order.orderState),

        recipeID = recipeID,
        outputItemID = outputItemID,
        outputConfigKey = outputIdentity and outputIdentity.configKey,
        isRecraft = isRecraft,
        minQuality = NumberOrNil(order.minQuality),
        needsTopQuality = needsTopQuality,
        usesHigherQualityMatsThanNeeded = UsesHigherQualityMatsThanNeeded(needsTopQuality, crafterProvidedReagents, slotRows),

        customerName = NonEmpty(order.customerName),
        customerGuid = NonEmpty(order.customerGuid),
        crafterGuid = NonEmpty(order.crafterGuid),

        tipAmount = tipAmount,
        consortiumCut = consortiumCut,
        crafterPayout = tipAmount and consortiumCut and (tipAmount - consortiumCut) or nil,

        customerProvidedReagents = customerProvidedReagents,
        crafterProvidedReagents = crafterProvidedReagents,
        finishingReagents = finishingReagents,

        itemRewards = itemRewards,
        currencyRewards = currencyRewards,

        displayedResourcefulnessPct = ExtractDisplayedResourcefulnessPct(operationInfo),
        concentrating = concentrating,

        source = SOURCE_PATHS,
    }

    if not ConfirmOrderUnchanged(orderID) then
        return Unresolved("orderChangedDuringObservation", diagnostics)
    end

    return {
        resolved = true,
        observation = observation,
        diagnostics = diagnostics,
    }
end

-- ---------------------------------------------------------------------------
-- List-mode observation (Patron Orders board)
-- ---------------------------------------------------------------------------
-- Builds the same observation shape as BuildCurrentOrderObservation for an
-- order taken from C_CraftingOrders.GetCrafterOrders() - i.e. WITHOUT the
-- order being open. Additive: BuildCurrentOrderObservation is unchanged.
--
-- Differences from the open-order path (this is an ESTIMATE for ranking):
--   - No live transaction: crafter-supplied required slots are costed by
--     NormalizeCrafterReagents' required-slot fallback (Core ReagentSlotService)
--     (full quantityRequired, estimated reagent quality: top variant when
--     the order requires the output's top rank, see ResolveNeedsTopQuality)
--     - the same path the
--     open-order view already uses for slots the crafter can't fill yet.
--   - Resourcefulness %: GetCraftingOperationInfoForOrder first, then
--     GetCraftingOperationInfo(recipeID, {}, nil, false), which is the one
--     that works for list orders (see below). concentrating=false.
function OrderObservationBuilder:BuildObservationFromListOrder(order)
    local diagnostics = NewDiagnostics()
    if type(order) ~= "table" then
        return Unresolved("invalidOrder", diagnostics)
    end

    local orderID = ResolveOrderID(order)
    local recipeID = ResolveRecipeID(order)
    if not orderID or not recipeID then
        return Unresolved(not orderID and "selectedOrderUnavailable" or "recipeIDUnavailable", diagnostics)
    end

    local isRecraft = order.isRecraft == true
    local okRecipeInfo, recipeInfo = ApiCall(C_TradeSkillUI, "GetRecipeInfo", recipeID)
    local okSchematic, schematicInfo = ApiCall(C_TradeSkillUI, "GetRecipeSchematic", recipeID, isRecraft)
    if not okSchematic or type(schematicInfo) ~= "table" then
        return Unresolved("recipeSchematicUnavailable", diagnostics)
    end
    if not okRecipeInfo or type(recipeInfo) ~= "table" then
        recipeInfo = nil
    end

    local slotRows = ReagentSlots.BuildSlotRows(schematicInfo, diagnostics)
    local customerProvidedReagents, claimedSlotKeys = NormalizeCustomerReagents(order, slotRows, diagnostics)
    local needsTopQuality = ResolveNeedsTopQuality(recipeID, order.minQuality)
    local crafterProvidedReagents, finishingReagents = NormalizeCrafterReagents(nil, {}, slotRows, claimedSlotKeys, diagnostics, needsTopQuality == true)
    local itemRewards, currencyRewards = NormalizeRewards(order, diagnostics)

    local reagentTbl = {}
    for _, orderRow in ipairs(type(order.reagents) == "table" and order.reagents or {}) do
        if type(orderRow) == "table" and type(orderRow.reagentInfo) == "table" then
            reagentTbl[#reagentTbl + 1] = orderRow.reagentInfo
        end
    end
    local okOperationInfo, operationInfo = ApiCall(
        C_TradeSkillUI, "GetCraftingOperationInfoForOrder", recipeID, reagentTbl, orderID, false)
    local resourcefulnessPct = (okOperationInfo and type(operationInfo) == "table")
        and ExtractDisplayedResourcefulnessPct(operationInfo) or nil
    if resourcefulnessPct == nil then
        -- Confirmed in-game (/mcgd orderlist, 2026-10-12): for an order that
        -- is not open, GetCraftingOperationInfoForOrder and
        -- GetCraftingOperationInfo(recipe, customer mats) both return nil,
        -- but GetCraftingOperationInfo(recipeID, {}, nil, false) returns the
        -- crafter's bonusStats for the recipe (Resourcefulness 37.9% on
        -- Darkmoon Dominion). Theoretical: that the % never depends on the
        -- mats used.
        local okRecipeInfo, recipeOperationInfo = ApiCall(
            C_TradeSkillUI, "GetCraftingOperationInfo", recipeID, {}, nil, false)
        resourcefulnessPct = (okRecipeInfo and type(recipeOperationInfo) == "table")
            and ExtractDisplayedResourcefulnessPct(recipeOperationInfo) or nil
    end

    local tipAmount = NumberOrNil(order.tipAmount) or 0
    local consortiumCut = NumberOrNil(order.consortiumCut) or 0

    local outputItemID = ResolveOutputItemID(order, recipeInfo, schematicInfo)

    return {
        resolved = true,
        observation = {
            orderID = orderID,
            orderType = NumberOrNil(order.orderType),
            recipeID = recipeID,
            outputItemID = outputItemID,
            isRecraft = isRecraft,
            minQuality = NumberOrNil(order.minQuality),
            needsTopQuality = needsTopQuality,
            expirationTime = NumberOrNil(order.expirationTime),

            tipAmount = tipAmount,
            consortiumCut = consortiumCut,
            crafterPayout = tipAmount - consortiumCut,

            customerProvidedReagents = customerProvidedReagents,
            crafterProvidedReagents = crafterProvidedReagents,
            finishingReagents = finishingReagents,

            itemRewards = itemRewards,
            currencyRewards = currencyRewards,

            displayedResourcefulnessPct = resourcefulnessPct,
            concentrating = false,
            isListEstimate = true,
        },
        diagnostics = diagnostics,
    }
end

-- Exposed read-only so /mcgd orderdata's ORDER REAGENT SLOT RESOLUTION
-- diagnostic can match order.reagents rows to schematic slots using this
-- exact same rule instead of maintaining a second, independently-drifting
-- copy of the matching logic (see SlotClaimKey/MatchesSlot header comments).
OrderObservationBuilder.SlotClaimKey = SlotClaimKey
OrderObservationBuilder.MatchesSlot = ReagentSlots.MatchesSlot

if PocketCFO_Orders then
    PocketCFO_Orders.OrderObservationBuilder = OrderObservationBuilder
end
