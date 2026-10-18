-- PocketCFO_Crafting/Crafting/CraftEventCapture.lua
-- Single listener for TRADE_SKILL_ITEM_CRAFTED_RESULT.
-- Owns only event-time-only UI reads: order-craft skip check, current
-- recipeID, and pending config lookup. All craft-completion side effects
-- (inventory adjustment, stat write, operation observation) are coordinated
-- by CraftCompletionDispatcher.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local CraftEventCapture = PocketCFO_Crafting:NewModule("CraftEventCapture", "AceEvent-3.0")

local function SessionLog(fmt, ...)
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    msg = "[MCG] " .. msg
    if PocketCFO and PocketCFO.AppendSessionLog then
        PocketCFO:AppendSessionLog(msg)
    end

    -- Craft result capture diagnostics must be visible even when normal debug
    -- logging is disabled; otherwise /mcgd session cannot answer whether the
    -- event path was reached.
    if PocketCFO and not PocketCFO.debugEnabled and not PocketCFO.traceEnabled then
        PocketCFO.sessionLog = PocketCFO.sessionLog or {}
        table.insert(PocketCFO.sessionLog, string.format("[%s] %s", date("%H:%M:%S"), msg))
    end
end

local function IsOrderCraft()
    local ordersPage = ProfessionsFrame and ProfessionsFrame.OrdersPage
    local orderView  = ordersPage and ordersPage.OrderView
    return ordersPage and ordersPage.IsShown and ordersPage:IsShown()
       and orderView  and orderView.IsShown  and orderView:IsShown()
       and orderView.order ~= nil
end

local function GetRecipeID()
    local sf = ProfessionsFrame
        and ProfessionsFrame.CraftingPage
        and ProfessionsFrame.CraftingPage.SchematicForm
    if sf and sf.GetRecipeInfo then
        local ok, info = pcall(function() return sf:GetRecipeInfo() end)
        if ok and info then return info.recipeID end
    end
    return nil
end

local function GetPendingConfigID()
    local controller = PocketCFO_Crafting:GetModule("CraftQueueController", true)
    return controller and controller.pendingCraftConfigID or nil
end

local function GetRecipeConfiguration(configID)
    if not configID then
        return nil
    end

    local store = PocketCFO_Crafting:GetModule("RecipeConfigStore", true)
    if store and store.GetConfiguration then
        return store:GetConfiguration(configID)
    end

    return nil
end

local function GetProcessingRegistry()
    return PocketCFO and PocketCFO.ProcessingOperationRegistry
        or _G.PocketCFO_ProcessingOperationRegistry
end

local function IsProcessingOp(recipeID)
    local registry = GetProcessingRegistry()
    return registry ~= nil
        and type(registry.IsProcessingOperation) == "function"
        and registry:IsProcessingOperation(recipeID)
end

local function GetProcessingEntry(recipeID)
    local registry = GetProcessingRegistry()
    if registry and type(registry.GetEntry) == "function" then
        return registry:GetEntry(recipeID)
    end
    return nil
end

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function GetIdentityAdapters()
    return PocketCFO and PocketCFO.ItemIdentityAdapters or _G.PocketCFO_ItemIdentityAdapters
end

local function ResolveIdentity(itemID)
    local identityService = GetItemIdentityService()
    if identityService and identityService.FromItemID then
        local ok, identity = pcall(function() return identityService:FromItemID(itemID) end)
        if ok and type(identity) == "table" and not identity.unresolved then
            return identity
        end
        return nil, ok and (identity and identity.unresolvedReason or "identityUnresolved") or "identityCallFailed"
    end
    return nil, "identityServiceUnavailable"
end

local function ResolveCraftingQuality(itemID, itemLink, identity)
    local quality = tonumber(identity and (identity.craftingQuality or identity.itemQuality))
    if quality and quality > 0 then
        return quality
    end

    local adapters = GetIdentityAdapters()
    if adapters and adapters.GetReagentCraftingQuality then
        local ok, result = pcall(function()
            return adapters:GetReagentCraftingQuality(nil, itemLink or itemID)
        end)
        quality = ok and tonumber(result) or nil
        if quality and quality > 0 then
            return quality
        end
    end

    return nil
end

local function GetReagentItemInfo(itemID)
    local itemName, itemLink
    if GetItemInfo then
        itemName, itemLink = GetItemInfo(itemID)
    end
    return itemName, itemLink
end

local function CountTableValues(value)
    if type(value) ~= "table" then
        return 0
    end
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    return count
end

local function SlotSummary(slotData)
    if type(slotData) ~= "table" then
        return "slotData=nil"
    end
    return string.format(
        "reagentType=%s slotIndex=%s required=%s quantityRequired=%s reagents=%d name=%s",
        tostring(slotData.reagentType),
        tostring(slotData.slotIndex),
        tostring(slotData.required),
        tostring(slotData.quantityRequired),
        CountTableValues(slotData.reagents),
        tostring(slotData.name))
end

-- Reads the SchematicForm's operation info at event time so callers get
-- accurate character stat percentages (Resourcefulness, Multicraft, etc.)
-- rather than values derived from an empty-reagent API call.
local function CaptureSchematicFormOpInfo()
    local sf = ProfessionsFrame and ProfessionsFrame.CraftingPage
        and ProfessionsFrame.CraftingPage.SchematicForm
    if not sf or type(sf.GetRecipeOperationInfo) ~= "function" then
        return nil
    end
    local ok, opInfo = pcall(function() return sf:GetRecipeOperationInfo() end)
    return (ok and type(opInfo) == "table") and opInfo or nil
end

local function ResolveSlotFrameItemID(sf, slotData, slotOrdinal)
    local reagentSlots = sf and sf.reagentSlots
    if not reagentSlots then
        return nil
    end
    local slotFrame = reagentSlots[slotData.reagentType]
        and reagentSlots[slotData.reagentType][slotOrdinal]
    local button = slotFrame and slotFrame.Button
    if button and button.GetItemID then
        local ok, itemID = pcall(function() return button:GetItemID() end)
        if ok and tonumber(itemID) then
            SessionLog("CraftEventCapture: reagent slot frame itemID source=Button:GetItemID reagentType=%s ordinal=%s itemID=%s",
                tostring(slotData.reagentType), tostring(slotOrdinal), tostring(itemID))
            return tonumber(itemID)
        end
    end
    if slotFrame and slotFrame.GetItemID then
        local ok, itemID = pcall(function() return slotFrame:GetItemID() end)
        if ok and tonumber(itemID) then
            SessionLog("CraftEventCapture: reagent slot frame itemID source=slotFrame:GetItemID reagentType=%s ordinal=%s itemID=%s",
                tostring(slotData.reagentType), tostring(slotOrdinal), tostring(itemID))
            return tonumber(itemID)
        end
    end
    return nil
end

local function ReadFrameItemID(frame)
    if not frame then
        return nil, nil, nil
    end
    if type(frame.GetItemID) == "function" then
        local ok, itemID = pcall(function() return frame:GetItemID() end)
        if ok and tonumber(itemID) then
            local itemLink
            if type(frame.GetItemLink) == "function" then
                local okLink, link = pcall(function() return frame:GetItemLink() end)
                if okLink then itemLink = link end
            end
            return tonumber(itemID), itemLink, "GetItemID"
        end
    end
    for _, key in ipairs({ "itemID", "itemId", "item" }) do
        local ok, value = pcall(function() return frame[key] end)
        if ok and tonumber(value) then
            local itemLink
            local okLink, link = pcall(function() return frame.itemLink or frame.link end)
            if okLink then itemLink = link end
            return tonumber(value), itemLink, "field." .. key
        end
    end
    return nil, nil, nil
end

local function FindItemIDInFrameTree(root, maxDepth, maxFrames)
    local seen = {}
    local visited = 0
    local function Walk(frame, depth)
        if not frame or seen[frame] or depth > maxDepth or visited >= maxFrames then
            return nil, nil, nil
        end
        seen[frame] = true
        visited = visited + 1

        local itemID, itemLink, source = ReadFrameItemID(frame)
        if itemID then
            return itemID, itemLink, source
        end

        if type(frame.GetChildren) == "function" then
            local ok, children = pcall(function() return { frame:GetChildren() } end)
            if ok then
                for _, child in ipairs(children) do
                    local childItemID, childItemLink, childSource = Walk(child, depth + 1)
                    if childItemID then
                        return childItemID, childItemLink, childSource
                    end
                end
            end
        end
        return nil, nil, nil
    end

    local itemID, itemLink, source = Walk(root, 0)
    return itemID, itemLink, source, visited
end

local function FindProspectingInputFromSchematicForm(sf, recipeID, source)
    if not sf or type(sf.GetChildren) ~= "function" then
        return nil, "schematicFormChildrenUnavailable"
    end

    local maxDepth = 7
    local maxFrames = 260
    local seen = {}
    local visited = 0
    local bestReason = "noQuantityRequiredFrame"

    local function Walk(frame, depth)
        if not frame or seen[frame] or depth > maxDepth or visited >= maxFrames then
            return nil
        end
        seen[frame] = true
        visited = visited + 1

        local quantityRequired = nil
        local okQty, value = pcall(function() return frame.quantityRequired end)
        if okQty then quantityRequired = tonumber(value) end

        if quantityRequired == 5 then
            local itemID, itemLink, itemSource, childVisited = FindItemIDInFrameTree(frame, 3, 40)
            SessionLog("CraftEventCapture: SchematicForm visible reagent candidate source=%s recipeID=%s frame=%s quantityRequired=%s itemID=%s itemSource=%s childFrames=%s",
                tostring(source), tostring(recipeID), tostring(frame), tostring(quantityRequired),
                tostring(itemID), tostring(itemSource), tostring(childVisited))
            if itemID then
                return {
                    itemID = itemID,
                    itemLink = itemLink,
                    quantity = 5,
                    reason = "schematicFormVisibleQuantityRequired5:" .. tostring(itemSource),
                }
            end
            bestReason = "quantityRequired5FrameWithoutItem"
        end

        if type(frame.GetChildren) == "function" then
            local ok, children = pcall(function() return { frame:GetChildren() } end)
            if ok then
                for _, child in ipairs(children) do
                    local result = Walk(child, depth + 1)
                    if result then
                        return result
                    end
                end
            end
        end
        return nil
    end

    local result = Walk(sf, 0)
    if result then
        return result, nil
    end
    SessionLog("CraftEventCapture: SchematicForm visible reagent scan failed source=%s recipeID=%s visited=%d reason=%s",
        tostring(source), tostring(recipeID), visited, tostring(bestReason))
    return nil, bestReason
end

local function FindVisibleInputForRole(sf, recipeID, source, role)
    if not sf or type(sf.GetChildren) ~= "function" then
        return nil, "schematicFormChildrenUnavailable"
    end
    if type(role) ~= "table" then
        return nil, "roleUnavailable"
    end

    local targetQty = tonumber(role.quantityRequired)
    if not targetQty then
        return nil, "roleQuantityUnavailable"
    end

    local maxDepth = 7
    local maxFrames = 260
    local seen = {}
    local visited = 0
    local bestReason = "noMatchingQuantityRequiredFrame"

    local function Walk(frame, depth)
        if not frame or seen[frame] or depth > maxDepth or visited >= maxFrames then
            return nil
        end
        seen[frame] = true
        visited = visited + 1

        local quantityRequired = nil
        local okQty, value = pcall(function() return frame.quantityRequired end)
        if okQty then quantityRequired = tonumber(value) end

        if quantityRequired == targetQty then
            local itemID, itemLink, itemSource, childVisited = FindItemIDInFrameTree(frame, 3, 40)
            SessionLog("CraftEventCapture: visible role candidate source=%s recipeID=%s role=%s quantityRequired=%s itemID=%s itemSource=%s childFrames=%s",
                tostring(source), tostring(recipeID), tostring(role.key or role.role),
                tostring(quantityRequired), tostring(itemID), tostring(itemSource), tostring(childVisited))
            if itemID then
                return {
                    itemID = itemID,
                    itemLink = itemLink,
                    quantity = targetQty,
                    reason = "schematicFormVisibleRoleQuantity:" .. tostring(itemSource),
                }
            end
            bestReason = "matchingQuantityFrameWithoutItem"
        end

        if type(frame.GetChildren) == "function" then
            local ok, children = pcall(function() return { frame:GetChildren() } end)
            if ok then
                for _, child in ipairs(children) do
                    local result = Walk(child, depth + 1)
                    if result then
                        return result
                    end
                end
            end
        end
        return nil
    end

    local result = Walk(sf, 0)
    if result then
        return result, nil
    end
    SessionLog("CraftEventCapture: visible role scan failed source=%s recipeID=%s role=%s quantityRequired=%s visited=%d reason=%s",
        tostring(source), tostring(recipeID), tostring(role.key or role.role),
        tostring(targetQty), visited, tostring(bestReason))
    return nil, bestReason
end

local function LogProcessingEntryRoles(recipeID, entry)
    SessionLog("CraftEventCapture: processing registry entry recipeID=%s processingType=%s profileKeyMode=%s roles=%d",
        tostring(recipeID), tostring(entry and entry.processingType),
        tostring(entry and entry.profileKeyMode),
        type(entry and entry.inputRoles) == "table" and #entry.inputRoles or 0)
    for index, role in ipairs((entry and entry.inputRoles) or {}) do
        SessionLog("CraftEventCapture: registry role recipeID=%s index=%d key=%s role=%s qty=%s reagentType=%s fixedItemID=%s profileDriver=%s selectedCostInput=%s fixedCatalyst=%s statisticalProfile=%s",
            tostring(recipeID), index, tostring(role.key), tostring(role.role),
            tostring(role.quantityRequired), tostring(role.reagentType),
            tostring(role.fixedItemID), tostring(role.profileDriver == true),
            tostring(role.selectedCostInput == true), tostring(role.fixedCatalyst == true),
            tostring(role.statisticalProfile == true))
    end
end

local function IsProspectingPrimaryInputSlot(slotData)
    local reagentCount = CountTableValues(slotData and slotData.reagents)
    local quantityRequired = tonumber(slotData and slotData.quantityRequired) or 0
    if reagentCount == 0 then
        return false, "noReagents"
    end
    if quantityRequired == 5 then
        return true, "quantityRequired5"
    end
    if slotData and slotData.required == true and quantityRequired > 0 then
        return true, "requiredQuantity"
    end
    return false, "notRequiredProspectingQuantity"
end

local function IsPrimaryInputSlot(slotData, processingType)
    if tonumber(slotData and slotData.reagentType) == 1 then
        return true, "reagentType1"
    end
    if processingType == "prospecting" then
        return IsProspectingPrimaryInputSlot(slotData)
    end
    return false, "unsupportedProcessingSlotType"
end

local function RoleMatchesSlot(role, slotData)
    if type(role) ~= "table" or type(slotData) ~= "table" then
        return false
    end

    if role.fixedItemID and type(slotData.reagents) == "table" then
        for _, reagent in ipairs(slotData.reagents) do
            if tonumber(reagent and reagent.itemID) == tonumber(role.fixedItemID) then
                return true
            end
        end
    end

    local reagentType = tonumber(role.reagentType)
    if reagentType and tonumber(slotData.reagentType) ~= reagentType then
        return false
    end

    local quantityRequired = tonumber(role.quantityRequired)
    if quantityRequired and tonumber(slotData.quantityRequired) ~= quantityRequired then
        return false
    end

    return reagentType ~= nil or quantityRequired ~= nil
end

local function ResolveFixedSlotItemID(slotData)
    if type(slotData) ~= "table" or type(slotData.reagents) ~= "table" then
        return nil
    end
    local firstItemID
    local count = 0
    for _, reagent in ipairs(slotData.reagents) do
        if reagent and reagent.itemID then
            firstItemID = firstItemID or tonumber(reagent.itemID)
            count = count + 1
        end
    end
    if count == 1 then
        return firstItemID
    end
    return nil
end

local function ResolveFallbackItemIDFromResult(result)
    for _, entry in ipairs((result and result.resourcesReturned) or {}) do
        local itemID = tonumber(entry and entry.reagent and entry.reagent.itemID)
        local quantity = tonumber(entry and entry.quantity) or 0
        if itemID and quantity > 0 then
            return itemID, quantity
        end
    end
    return nil, nil
end

local function BuildCapturedInput(recipeID, source, itemID, quantity, reason, capturedItemLink, role)
    itemID = tonumber(itemID)
    if not itemID then
        return nil, "primaryInputItemIDUnavailable:" .. tostring(reason)
    end

    local itemName, itemLink = GetReagentItemInfo(itemID)
    itemLink = capturedItemLink or itemLink
    local identity, identityReason = ResolveIdentity(itemID)
    if (not identity or not identity.configKey)
    and (not role or role.profileDriver == true) then
        return nil, "primaryInputIdentityUnavailable:" .. tostring(identityReason)
    end

    local row = {
        itemID    = itemID,
        itemLink  = itemLink,
        itemName  = itemName or (identity and identity.itemName) or ("item:" .. tostring(itemID)),
        quantity  = tonumber(quantity) or 5,
        configKey = identity and identity.configKey or nil,
        craftingQuality = ResolveCraftingQuality(itemID, itemLink, identity),
    }
    if type(role) == "table" then
        row.inputRoleKey = role.key
        row.inputRole = role.role
        row.profileDriver = role.profileDriver == true
        row.deterministicOutputDriver = role.deterministicOutputDriver == true
        row.selectedCostInput = role.selectedCostInput == true
        row.fixedCatalyst = role.fixedCatalyst == true
        row.selected = role.selected == true
        row.statisticalProfile = role.statisticalProfile == true
        row.slotRule = role.slotRule
    end

    SessionLog("CraftEventCapture: processing input capture success source=%s recipeID=%s role=%s itemID=%s itemName=%s configKey=%s quality=%s quantity=%d reason=%s",
        tostring(source), tostring(recipeID), tostring(row.inputRoleKey or row.inputRole),
        tostring(itemID), tostring(row.itemName), tostring(row.configKey),
        tostring(row.craftingQuality), tonumber(row.quantity) or 0, tostring(reason))

    return row, nil
end

local function BuildCapturedInputList(recipeID, source, itemID, quantity, reason, capturedItemLink, role)
    local row, rowReason = BuildCapturedInput(recipeID, source, itemID, quantity, reason, capturedItemLink, role)
    if row then
        return { row }, nil
    end
    return nil, rowReason
end

local function ReadSlotAllocation(transaction, slotData, arrayIndex, recipeID, source)
    local itemID, allocatedQty
    local allocationRead = "notAttempted"
    if not transaction or type(transaction.GetAllocations) ~= "function" then
        SessionLog("CraftEventCapture: transaction allocation unavailable source=%s recipeID=%s slotIndex=%d reason=transactionUnavailable",
            tostring(source), tostring(recipeID), arrayIndex)
        return nil, nil, "transactionUnavailable"
    end

    local ok3, allocs = pcall(function() return transaction:GetAllocations(arrayIndex) end)
    if ok3 and allocs and slotData and slotData.reagents then
        allocationRead = "empty"
        local ok4, err4 = pcall(function()
            for _, reagent in ipairs(slotData.reagents) do
                if reagent.itemID then
                    local alloc = allocs:FindAllocationByReagent(reagent)
                    local qty = alloc and alloc:GetQuantity() or 0
                    SessionLog("CraftEventCapture: transaction allocation source=%s recipeID=%s slotIndex=%d reagentItemID=%s qty=%s",
                        tostring(source), tostring(recipeID), arrayIndex,
                        tostring(reagent.itemID), tostring(qty))
                    if not itemID and qty and qty > 0 then
                        itemID = tonumber(reagent.itemID)
                        allocatedQty = tonumber(qty)
                        allocationRead = "matched"
                    end
                end
            end
        end)
        if not ok4 then
            SessionLog("CraftEventCapture: transaction allocation inspect failed source=%s recipeID=%s slotIndex=%d reason=%s",
                tostring(source), tostring(recipeID), arrayIndex, tostring(err4))
        end
    elseif not ok3 then
        allocationRead = "failed"
        SessionLog("CraftEventCapture: transaction allocation unavailable source=%s recipeID=%s slotIndex=%d reason=%s",
            tostring(source), tostring(recipeID), arrayIndex, tostring(allocs))
    else
        SessionLog("CraftEventCapture: transaction allocation empty source=%s recipeID=%s slotIndex=%d reason=no-allocations-or-reagents",
            tostring(source), tostring(recipeID), arrayIndex)
    end
    return itemID, allocatedQty, allocationRead
end

local function CaptureProcessingInputsFromRoles(entry, recipeID, source, schematic, transaction, sf)
    local roles = entry and entry.inputRoles
    if type(roles) ~= "table" or #roles == 0 then
        return nil, "noInputRoles"
    end

    LogProcessingEntryRoles(recipeID, entry)

    local inputs = {}
    local typeCounters = {}
    local lastFailure = "noMatchingInputRole"
    local usedSlots = {}
    local registry = GetProcessingRegistry()
    local recipePlusPrimaryInputMode = registry and registry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT
        or "recipePlusPrimaryInput"
    local requiresProfileDriver = entry.profileKeyMode == recipePlusPrimaryInputMode

    for arrayIndex, slotData in ipairs(schematic.reagentSlotSchematics or {}) do
        local typeKey = tostring(slotData and slotData.reagentType)
        typeCounters[typeKey] = (typeCounters[typeKey] or 0) + 1
        local slotOrdinal = typeCounters[typeKey]
        local allocatedItemID, allocatedQty, allocationRead =
            ReadSlotAllocation(transaction, slotData, arrayIndex, recipeID, source)
        SessionLog("CraftEventCapture: role matching slot source=%s recipeID=%s slotIndex=%d reagentType=%s quantityRequired=%s required=%s allocatedItemID=%s allocatedQty=%s allocationRead=%s reagents=%d",
            tostring(source), tostring(recipeID), arrayIndex,
            tostring(slotData and slotData.reagentType),
            tostring(slotData and slotData.quantityRequired),
            tostring(slotData and slotData.required),
            tostring(allocatedItemID), tostring(allocatedQty), tostring(allocationRead),
            CountTableValues(slotData and slotData.reagents))

        for _, role in ipairs(roles) do
            local roleKey = role.key or role.role or tostring(_)
            local roleMatchesSlot = RoleMatchesSlot(role, slotData)
            local roleMatchesAllocation = role.selectedCostInput == true
                and allocatedItemID ~= nil
                and tonumber(role.quantityRequired) ~= nil
                and tonumber(allocatedQty) == tonumber(role.quantityRequired)

            if not usedSlots[roleKey] and (roleMatchesSlot or roleMatchesAllocation) then
                local itemID = allocatedItemID
                local reason = roleMatchesAllocation and "selectedCostInputAllocationQuantity" or allocationRead
                SessionLog("CraftEventCapture: role matched source=%s recipeID=%s slotIndex=%d role=%s roleMatchesSlot=%s roleMatchesAllocation=%s itemID=%s qty=%s",
                    tostring(source), tostring(recipeID), arrayIndex, tostring(roleKey),
                    tostring(roleMatchesSlot), tostring(roleMatchesAllocation),
                    tostring(itemID), tostring(allocatedQty))

                if not itemID and role.fixedCatalyst then
                    itemID = role.fixedItemID or ResolveFixedSlotItemID(slotData)
                    if itemID then
                        reason = tostring(reason) .. "+fixedSlot"
                    end
                end

                if not itemID then
                    itemID = ResolveSlotFrameItemID(sf, slotData, slotOrdinal)
                    if itemID then
                        reason = tostring(reason) .. "+slotFrame"
                    end
                end

                local quantity = tonumber(role.quantityRequired)
                    or tonumber(slotData and slotData.quantityRequired)
                    or tonumber(allocatedQty)
                    or 1

                if itemID then
                    local row, rowReason = BuildCapturedInput(recipeID, source, itemID, quantity, reason, nil, role)
                    if row then
                        inputs[#inputs + 1] = row
                        usedSlots[roleKey] = true
                    else
                        lastFailure = rowReason
                    end
                else
                    lastFailure = "roleInputItemIDUnavailable:" .. tostring(role.key or role.role) .. ":" .. tostring(reason)
                    SessionLog("CraftEventCapture: role input slot unresolved source=%s recipeID=%s slotIndex=%d role=%s reason=%s",
                        tostring(source), tostring(recipeID), arrayIndex,
                        tostring(role.key or role.role), tostring(lastFailure))
                end
            elseif not usedSlots[roleKey] then
                local rejectReason = "slotMismatch"
                if role.selectedCostInput == true and allocatedItemID == nil then
                    rejectReason = "selectedCostInputNoAllocation"
                elseif role.selectedCostInput == true and tonumber(role.quantityRequired) ~= nil then
                    rejectReason = "selectedCostInputQuantityMismatch"
                end
                SessionLog("CraftEventCapture: role rejected source=%s recipeID=%s slotIndex=%d role=%s reason=%s roleQty=%s slotQty=%s roleReagentType=%s slotReagentType=%s allocatedItemID=%s allocatedQty=%s",
                    tostring(source), tostring(recipeID), arrayIndex, tostring(roleKey),
                    tostring(rejectReason), tostring(role.quantityRequired),
                    tostring(slotData and slotData.quantityRequired),
                    tostring(role.reagentType), tostring(slotData and slotData.reagentType),
                    tostring(allocatedItemID), tostring(allocatedQty))
            end
        end
    end

    for _, role in ipairs(roles) do
        local roleKey = role.key or role.role or tostring(_)
        if role.selectedCostInput == true and not usedSlots[roleKey] then
            local visibleInput, visibleReason = FindVisibleInputForRole(sf, recipeID, source, role)
            if visibleInput and visibleInput.itemID then
                local row, rowReason = BuildCapturedInput(
                    recipeID,
                    source,
                    visibleInput.itemID,
                    visibleInput.quantity,
                    visibleInput.reason,
                    visibleInput.itemLink,
                    role)
                if row then
                    inputs[#inputs + 1] = row
                    usedSlots[roleKey] = true
                    SessionLog("CraftEventCapture: role matched via visible fallback source=%s recipeID=%s role=%s itemID=%s qty=%s",
                        tostring(source), tostring(recipeID), tostring(roleKey),
                        tostring(row.itemID), tostring(row.quantity))
                else
                    lastFailure = rowReason
                    SessionLog("CraftEventCapture: visible fallback row rejected source=%s recipeID=%s role=%s reason=%s",
                        tostring(source), tostring(recipeID), tostring(roleKey), tostring(rowReason))
                end
            else
                lastFailure = "visibleRoleUnavailable:" .. tostring(roleKey) .. ":" .. tostring(visibleReason)
                SessionLog("CraftEventCapture: role visible fallback failed source=%s recipeID=%s role=%s reason=%s",
                    tostring(source), tostring(recipeID), tostring(roleKey), tostring(visibleReason))
            end
        end
    end

    if #inputs > 0 then
        if requiresProfileDriver then
            local profileDriverInput = nil
            for _, input in ipairs(inputs) do
                if type(input) == "table" and input.profileDriver == true then
                    profileDriverInput = input
                    break
                end
            end
            if not profileDriverInput then
                SessionLog("CraftEventCapture: role capture incomplete source=%s recipeID=%s captured=%d reason=missingProfileDriverInput",
                    tostring(source), tostring(recipeID), #inputs)
                return nil, "missingProfileDriverInput"
            end
        end
        SessionLog("CraftEventCapture: role capture result source=%s recipeID=%s captured=%d", tostring(source), tostring(recipeID), #inputs)
        return inputs, nil
    end

    return nil, lastFailure
end

-- Reads the selected primary reagent from the live profession UI. Prefer the
-- transaction allocations before craft dispatch; fall back to the visible slot
-- itemID because result-time transactions can be empty after Blizzard consumes
-- the reagent.
local function CaptureProcessingInputs(recipeID, source, result)
    if not recipeID
    or not C_TradeSkillUI
    or not C_TradeSkillUI.GetRecipeSchematic then
        return nil, "tradeSkillUIUnavailable"
    end
    local sf = ProfessionsFrame and ProfessionsFrame.CraftingPage
        and ProfessionsFrame.CraftingPage.SchematicForm
    if not sf then
        return nil, "schematicFormUnavailable"
    end

    local ok1, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok1 or not schematic or not schematic.reagentSlotSchematics then
        return nil, "schematicUnavailable"
    end

    local transaction
    if type(sf.GetTransaction) == "function" then
        local ok2, t = pcall(function() return sf:GetTransaction() end)
        if ok2 then transaction = t end
    end
    if not transaction then
        SessionLog("CraftEventCapture: SchematicForm transaction unavailable source=%s recipeID=%s",
            tostring(source), tostring(recipeID))
    end

    local entry = GetProcessingEntry(recipeID)
    local processingType = entry and entry.processingType
    local roleInputs, roleReason = CaptureProcessingInputsFromRoles(entry, recipeID, source, schematic, transaction, sf)
    if roleInputs and #roleInputs > 0 then
        return roleInputs, nil
    end
    if roleReason and roleReason ~= "noInputRoles" then
        SessionLog("CraftEventCapture: role input capture failed source=%s recipeID=%s reason=%s",
            tostring(source), tostring(recipeID), tostring(roleReason))
    end

    local typeCounters = {}
    local slotCount = CountTableValues(schematic.reagentSlotSchematics)
    local lastPrimaryFailure = "noPrimaryInputSlot"
    SessionLog("CraftEventCapture: schematic inspection source=%s recipeID=%s processingType=%s slotCount=%d",
        tostring(source), tostring(recipeID), tostring(processingType), slotCount)

    for arrayIndex, slotData in ipairs(schematic.reagentSlotSchematics) do
        local typeKey = tostring(slotData and slotData.reagentType)
        typeCounters[typeKey] = (typeCounters[typeKey] or 0) + 1
        local slotOrdinal = typeCounters[typeKey]
        local acceptSlot, slotReason = IsPrimaryInputSlot(slotData, processingType)
        local allocatedItemID, allocatedQty, allocationRead =
            ReadSlotAllocation(transaction, slotData, arrayIndex, recipeID, source)
        if not acceptSlot and processingType == "prospecting" and allocatedItemID then
            acceptSlot = true
            slotReason = "positiveTransactionAllocation"
        end

        SessionLog("CraftEventCapture: schematic slot index=%d %s accepted=%s reason=%s",
            arrayIndex, SlotSummary(slotData), tostring(acceptSlot), tostring(slotReason))

        if acceptSlot then
            local quantityRequired = tonumber(slotData.quantityRequired) or 0
            if processingType == "prospecting" then
                quantityRequired = 5
            end
            local itemID = allocatedItemID

            if not itemID then
                itemID = ResolveSlotFrameItemID(sf, slotData, slotOrdinal)
                if itemID then
                    allocationRead = allocationRead .. "+slotFrame"
                end
            end

            local quantity = quantityRequired > 0 and quantityRequired or allocatedQty or 1
            if itemID then
                return BuildCapturedInputList(recipeID, source, itemID, quantity, allocationRead)
            end

            lastPrimaryFailure = "primaryInputItemIDUnavailable:" .. tostring(allocationRead)
            SessionLog("CraftEventCapture: primary input slot unresolved source=%s recipeID=%s slotIndex=%d reason=%s",
                tostring(source), tostring(recipeID), arrayIndex, tostring(lastPrimaryFailure))
        end
    end

    if processingType == "prospecting" then
        local visibleInput, visibleReason = FindProspectingInputFromSchematicForm(sf, recipeID, source)
        if visibleInput and visibleInput.itemID then
            return BuildCapturedInputList(
                recipeID,
                source,
                visibleInput.itemID,
                visibleInput.quantity or 5,
                visibleInput.reason or "schematicFormVisibleReagent",
                visibleInput.itemLink)
        end
        lastPrimaryFailure = "schematicFormVisibleReagentUnavailable:" .. tostring(visibleReason)
    end

    local fallbackItemID, returnedQty = ResolveFallbackItemIDFromResult(result)
    if processingType == "prospecting" and fallbackItemID then
        SessionLog("CraftEventCapture: primary input fallback using resourcefulness return source=%s recipeID=%s itemID=%s returnedQty=%s",
            tostring(source), tostring(recipeID), tostring(fallbackItemID), tostring(returnedQty))
        return BuildCapturedInputList(recipeID, source, fallbackItemID, 5, "resourcefulnessReturnFallback")
    end

    return nil, lastPrimaryFailure
end

-- Read-only query for Processing Analysis: resolves the inputs currently
-- allocated in the live profession window for recipeID (role matching ->
-- transaction allocation -> slot frame -> visible-frame fallback), without
-- requiring a craft-completion event. Reuses the exact same resolution
-- CapturePendingProcessingInputs already uses at craft time, so Analysis
-- and capture never disagree about what "the selected gem" is. Safe to call
-- at recipe-selection time - CaptureProcessingInputs only reads live UI/
-- transaction state, it does not mutate or persist anything.
function CraftEventCapture:GetLiveProcessingInputs(recipeID, source)
    if not recipeID then
        return nil, "missingRecipeID"
    end
    return CaptureProcessingInputs(recipeID, source or "AnalysisLiveRead", nil)
end

function CraftEventCapture:CapturePendingProcessingInputs(recipeID, source, result)
    recipeID = recipeID or GetRecipeID()
    if not recipeID then
        SessionLog("CraftEventCapture: primary input capture skipped source=%s reason=missingRecipeID",
            tostring(source))
        return nil
    end
    local entry = GetProcessingEntry(recipeID)
    if not entry then
        SessionLog("CraftEventCapture: registry entry missing source=%s recipeID=%s",
            tostring(source), tostring(recipeID))
        return nil
    end

    SessionLog("CraftEventCapture: registry entry found source=%s recipeID=%s processingType=%s profileKeyMode=%s",
        tostring(source), tostring(recipeID), tostring(entry.processingType), tostring(entry.profileKeyMode))

    local inputs, reason = CaptureProcessingInputs(recipeID, source, result)
    local primary = nil
    for _, input in ipairs(inputs or {}) do
        if type(input) == "table" and input.profileDriver == true then
            primary = input
            break
        end
    end
    local capture = {
        recipeID = recipeID,
        source = source,
        inputs = inputs,
        primaryInputItemID = primary and primary.itemID or nil,
        primaryInputConfigKey = primary and primary.configKey or nil,
        failureReason = reason,
        capturedAt = GetTime and GetTime() or time(),
    }
    self.pendingProcessingCapture = capture

    if primary then
        SessionLog("CraftEventCapture: primaryInputItemID=%s configKey=%s source=%s",
            tostring(primary.itemID), tostring(primary.configKey), tostring(source))
    elseif inputs and #inputs > 0 then
        SessionLog("CraftEventCapture: processing inputs captured without profile driver source=%s recipeID=%s count=%d",
            tostring(source), tostring(recipeID), #inputs)
    else
        SessionLog("CraftEventCapture: primary input capture failed source=%s recipeID=%s reason=%s",
            tostring(source), tostring(recipeID), tostring(reason))
    end

    return capture
end

local function InstallCraftStartHooks()
    if hooksecurefunc and C_TradeSkillUI and C_TradeSkillUI.CraftRecipe
    and not CraftEventCapture.__processingCaptureCraftRecipeHooked then
        hooksecurefunc(C_TradeSkillUI, "CraftRecipe", function(recipeID)
            if recipeID and IsProcessingOp(recipeID) then
                CraftEventCapture:CapturePendingProcessingInputs(recipeID, "CraftRecipeHook")
            end
        end)
        CraftEventCapture.__processingCaptureCraftRecipeHooked = true
    end

    local function HookButton(button, label)
        if button and button.HookScript and not button.__mcgCFOProcessingCaptureHooked then
            local ok, err = pcall(function()
                button:HookScript("PreClick", function()
                    local recipeID = GetRecipeID()
                    if recipeID and IsProcessingOp(recipeID) then
                        CraftEventCapture:CapturePendingProcessingInputs(recipeID, label)
                    end
                end)
            end)
            if not ok then
                SessionLog("CraftEventCapture: craft button hook failed label=%s script=PreClick reason=%s",
                    tostring(label), tostring(err))
            else
                button.__mcgCFOProcessingCaptureHooked = true
                SessionLog("CraftEventCapture: craft button hook installed label=%s script=PreClick",
                    tostring(label))
            end
        end
    end

    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    HookButton(page and page.CreateButton, "CreateButtonPreClick")
    HookButton(page and page.CreateAllButton, "CreateAllButtonPreClick")
end

local function SafeInstallCraftStartHooks(source)
    local ok, err = pcall(InstallCraftStartHooks)
    if not ok then
        SessionLog("CraftEventCapture: craft start hook install failed source=%s reason=%s",
            tostring(source), tostring(err))
        return false
    end
    return true
end

local function LogResultEventStart(event, result)
    SessionLog("CraftEventCapture: craft result event entered event=%s resultType=%s resultItemID=%s quantity=%s",
        tostring(event),
        tostring(type(result)),
        tostring(result and result.itemID),
        tostring(result and result.quantity))
end

local function LogResultClassification(recipeID)
    local entry = GetProcessingEntry(recipeID)
    SessionLog("CraftEventCapture: result classification recipeID=%s isProcessing=%s registryEntry=%s processingType=%s profileKeyMode=%s",
        tostring(recipeID),
        tostring(IsProcessingOp(recipeID)),
        tostring(entry ~= nil),
        tostring(entry and entry.processingType),
        tostring(entry and entry.profileKeyMode))
end

function CraftEventCapture:OnCraftResult(event, result)
    LogResultEventStart(event, result)
    SafeInstallCraftStartHooks("OnCraftResult")

    if type(event) == "table" and result == nil then
        result = event
        event  = "TRADE_SKILL_ITEM_CRAFTED_RESULT"
    end

    if not result or type(result) ~= "table" then
        SessionLog("CraftEventCapture: craft event skipped reason=result-not-table event=%s resultType=%s",
            tostring(event), tostring(type(result)))
        return
    end

    PocketCFO._lastCraftRawResult = result

    if IsOrderCraft() then
        SessionLog("CraftEventCapture: craft event skipped reason=order-craft")
        return
    end

    local configID = GetPendingConfigID()
    local config    = GetRecipeConfiguration(configID)

    -- The live SchematicForm's currently-displayed recipe is not a reliable
    -- source of recipe identity at TRADE_SKILL_ITEM_CRAFTED_RESULT time for
    -- Processing Operations (e.g. Alchemy Recycling): Blizzard can already
    -- have reset/changed the crafting page's recipe selection by the time
    -- this event fires, silently sending the completion down the wrong path
    -- (or dropping it entirely, since IsProcessingOp(nil) is false) with no
    -- rejection ever reaching OperationOutcomeService to explain why.
    -- Prefer, in order: the live read (works for ordinary crafts and the
    -- common case), then the pending processing capture recorded by the
    -- pre-craft CraftRecipe/PreClick hooks (recipeID captured at the moment
    -- the player actually initiated THIS craft - see
    -- InstallCraftStartHooks/CapturePendingProcessingInputs), then the saved
    -- recipe configuration draft tied to this configID.
    local liveRecipeID = GetRecipeID()
    local recipeID = liveRecipeID
    local recipeIDSource = "liveSchematicForm"
    if not recipeID and self.pendingProcessingCapture and self.pendingProcessingCapture.recipeID then
        recipeID = self.pendingProcessingCapture.recipeID
        recipeIDSource = "pendingProcessingCapture"
    end
    if not recipeID and config and config.recipeID then
        recipeID = config.recipeID
        recipeIDSource = "pendingCraftConfig"
    end

    if recipeID ~= liveRecipeID then
        SessionLog("CraftEventCapture: recipeID resolution fallback used liveRecipeID=%s resolvedRecipeID=%s source=%s configID=%s",
            tostring(liveRecipeID), tostring(recipeID), tostring(recipeIDSource), tostring(configID))
    end
    LogResultClassification(recipeID)

    -- Capture SchematicForm operation info at event time so downstream
    -- services get accurate character stat percentages (Resourcefulness %,
    -- Multicraft %, Ingenuity %) from the live UI state, not from a
    -- separate API call with empty reagents.
    local capturedOpInfo = CaptureSchematicFormOpInfo()

    -- For processing operations (prospecting, milling, etc.), prefer the
    -- pre-craft capture. Result-time capture is only a diagnostic fallback
    -- because the transaction can be empty after Blizzard dispatches the craft.
    local preOperationInputs = nil
    local primaryInputConfigKey = nil
    if recipeID and IsProcessingOp(recipeID) then
        local pending = self.pendingProcessingCapture
        if pending and pending.recipeID == recipeID and pending.inputs then
            preOperationInputs = pending.inputs
            primaryInputConfigKey = pending.primaryInputConfigKey
            SessionLog("CraftEventCapture: processing input capture source=pending recipeID=%s captured=%s primaryInputConfigKey=%s",
                tostring(recipeID), tostring(#preOperationInputs), tostring(primaryInputConfigKey))
        else
            local capture = self:CapturePendingProcessingInputs(recipeID, "resultEventFallback", result)
            preOperationInputs = capture and capture.inputs or nil
            primaryInputConfigKey = capture and capture.primaryInputConfigKey or nil
            SessionLog("CraftEventCapture: processing input capture source=resultEventFallback recipeID=%s captured=%s reason=%s",
                tostring(recipeID),
                preOperationInputs and tostring(#preOperationInputs) or "nil",
                tostring(capture and capture.failureReason))
        end
    end

    if recipeID and IsProcessingOp(recipeID) then
        SessionLog("CraftEventCapture: processing event received event=%s recipeID=%s configID=%s primaryInputConfigKey=%s",
            tostring(event), tostring(recipeID), tostring(configID), tostring(primaryInputConfigKey))
    else
        SessionLog("CraftEventCapture: event received event=%s recipeID=%s configID=%s",
            tostring(event), tostring(recipeID), tostring(configID))
    end

    local dispatcher = PocketCFO_Crafting:GetModule("CraftCompletionDispatcher", true)
    if dispatcher and dispatcher.Dispatch then
        SessionLog("CraftEventCapture: dispatch called recipeID=%s configID=%s isProcessing=%s primaryInputConfigKey=%s",
            tostring(recipeID), tostring(configID), tostring(IsProcessingOp(recipeID)), tostring(primaryInputConfigKey))
        dispatcher:Dispatch({
            event              = event,
            result             = result,
            recipeID           = recipeID,
            configID           = configID,
            config             = config,
            capturedOpInfo     = capturedOpInfo,
            preOperationInputs = preOperationInputs,
            primaryInputConfigKey = primaryInputConfigKey,
        })
    else
        SessionLog("CraftEventCapture: dispatch skipped reason=dispatcher-unavailable recipeID=%s", tostring(recipeID))
    end
end

function CraftEventCapture:OnEnable()
    SessionLog("CraftEventCapture: enabled registering event=TRADE_SKILL_ITEM_CRAFTED_RESULT")
    SafeInstallCraftStartHooks("OnEnable")
    self:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT", "OnCraftResult")
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
end

function CraftEventCapture:OnDisable()
    SessionLog("CraftEventCapture: disabled unregistering events")
    self:UnregisterAllEvents()
end

function CraftEventCapture:OnTradeSkillShow()
    SafeInstallCraftStartHooks("OnTradeSkillShow")
end
