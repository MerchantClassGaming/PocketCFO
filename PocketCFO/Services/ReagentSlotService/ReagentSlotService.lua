-- PocketCFO/Services/ReagentSlotService/ReagentSlotService.lua
-- Shared reading of a recipe's reagent slots: which mats a craft consumes,
-- which choice is loaded in each slot, and how much of it. Used by
-- PocketCFO_Orders' OrderObservationBuilder (Order Analysis + Patron Orders
-- board) and PocketCFO_Crafting's RecipeObservationBuilder (Recipe
-- Analysis). Lives in Core so both addons read slots the same way; before
-- this, each kept its own copy and the copies had already drifted.
--
-- Read-only. Customer/crafter ownership is NOT decided here - that is an
-- Orders concept and stays in OrderObservationBuilder. Every row this
-- service builds itself is a crafter cost (suppliedBy = "crafter").
--
-- Live-capture corrections carried over unchanged from the Orders builder:
--   - slotIndex is the authoritative slot key; dataSlotIndex repeats across
--     slot groups (see MatchesSlot).
--   - Required slots always cost their full quantityRequired, even when the
--     crafter does not hold enough to fill them (see EnsureRequiredSlotCoverage).
--   - Unallocated required slots get an estimated reagent quality (top
--     variant when the caller says the order needs top output quality).
--
-- API sources:
--   C_TradeSkillUI.GetRecipeSchematic(...).reagentSlotSchematics
--     -> slot structure/classification and possible-reagent choices.
--   SchematicForm:GetTransaction() (GetAllocations / CreateCraftingReagentInfoTbl)
--     -> live allocation state for every slot.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local PocketCFO = _G.PocketCFO

local ReagentSlotService = {}

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

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

--- Diagnostics table shape shared by both observation builders.
function ReagentSlotService.NewDiagnostics()
    return {
        unresolvedIdentities = {},
        unknownResponsibilityRows = {},
        unknownSlotClassifications = {},
        duplicateRowsSuppressed = {},
    }
end

function ReagentSlotService.AttachConfigKey(row, diagnostics, source)
    if type(row) ~= "table" or row.itemID == nil then
        return row
    end

    local identityService = GetItemIdentityService()
    if not identityService then
        diagnostics.unresolvedIdentities[#diagnostics.unresolvedIdentities + 1] = {
            source = source,
            itemID = row.itemID,
            reason = "itemIdentityServiceUnavailable",
        }
        return row
    end

    local identity
    local ok
    if row.itemLink and identityService.FromItemLink then
        ok, identity = pcall(function()
            return identityService:FromItemLink(row.itemLink)
        end)
    elseif identityService.FromItemID then
        ok, identity = pcall(function()
            return identityService:FromItemID(row.itemID)
        end)
    end

    if ok and type(identity) == "table" and identity.configKey then
        row.configKey = identity.configKey
    else
        diagnostics.unresolvedIdentities[#diagnostics.unresolvedIdentities + 1] = {
            source = source,
            itemID = row.itemID,
            itemLink = row.itemLink,
            reason = ok and type(identity) == "table" and identity.unresolvedReason or "identityResolutionFailed",
        }
    end

    return row
end

local function ClassifySlot(slot)
    if type(slot) ~= "table" then
        return "unknown"
    end

    local reagentType = NumberOrNil(slot.reagentType)
    local required = slot.required
    if required == nil then
        required = slot.requiredSlot
    end

    if reagentType == 2 then
        return "finishing"
    end
    if required == true then
        return "required"
    end
    return "optional"
end

local function ReagentSignature(row)
    return table.concat({
        tostring(row.slotOrdinal),
        tostring(row.slotIndex),
        tostring(row.dataSlotIndex),
        tostring(row.itemID),
        tostring(row.currencyID),
        tostring(row.quantity),
        tostring(row.suppliedBy),
        tostring(row.classification),
    }, ":")
end

function ReagentSlotService.AddUniqueRow(list, row, seen, diagnostics, source)
    local signature = ReagentSignature(row)
    if seen[signature] then
        diagnostics.duplicateRowsSuppressed[#diagnostics.duplicateRowsSuppressed + 1] = {
            source = source,
            signature = signature,
            itemID = row.itemID,
            dataSlotIndex = row.dataSlotIndex,
            slotIndex = row.slotIndex,
        }
        return
    end
    seen[signature] = true
    list[#list + 1] = row
end
local AddUniqueRow = ReagentSlotService.AddUniqueRow

-- One row per schematic slot. orderSource is recorded as raw evidence only;
-- it is a recipe-design property, never a per-order customer/crafter fact
-- (see OrderObservationBuilder's header comment).
function ReagentSlotService.BuildSlotRows(schematicInfo, diagnostics)
    local slots = type(schematicInfo) == "table" and schematicInfo.reagentSlotSchematics or nil
    local rows = {}
    if type(slots) ~= "table" then
        return rows
    end

    for index, slot in ipairs(slots) do
        if type(slot) == "table" then
            local classification = ClassifySlot(slot)
            if classification == "unknown" then
                diagnostics.unknownSlotClassifications[#diagnostics.unknownSlotClassifications + 1] = {
                    source = "schematic.reagentSlotSchematics",
                    slotOrdinal = index,
                    slotIndex = slot.slotIndex,
                    dataSlotIndex = slot.dataSlotIndex,
                    reagentType = slot.reagentType,
                    required = slot.required,
                    requiredSlot = slot.requiredSlot,
                }
            end

            rows[#rows + 1] = {
                slot = slot,
                slotOrdinal = index,
                slotIndex = NumberOrNil(slot.slotIndex),
                dataSlotIndex = NumberOrNil(slot.dataSlotIndex),
                orderSource = NumberOrNil(slot.orderSource),
                reagentType = NumberOrNil(slot.reagentType),
                required = slot.required == true or slot.requiredSlot == true,
                classification = classification,
            }
        end
    end
    return rows
end

local function ExtractRowItem(row)
    if type(row) ~= "table" then
        return nil, nil
    end
    local reagent = row.reagent
    return NumberOrNil(row.itemID or reagent and reagent.itemID),
        NumberOrNil(row.currencyID or reagent and reagent.currencyID)
end

local function PossibleReagentSet(slot)
    local set = {}
    local reagents = type(slot) == "table" and slot.reagents or nil
    if type(reagents) ~= "table" then
        return set
    end
    for _, reagent in ipairs(reagents) do
        local itemID = NumberOrNil(type(reagent) == "table" and reagent.itemID or nil)
        local currencyID = NumberOrNil(type(reagent) == "table" and reagent.currencyID or nil)
        if itemID then
            set["item:" .. tostring(itemID)] = true
        end
        if currencyID then
            set["currency:" .. tostring(currencyID)] = true
        end
    end
    return set
end

function ReagentSlotService.MatchesSlot(row, slotRow)
    local itemID, currencyID = ExtractRowItem(row)
    if itemID == nil and currencyID == nil then
        return false
    end

    -- Primary, authoritative signal: slotIndex. CORRECTED after a live
    -- /mcgd orderdata capture on Thalassian Competitor's Cloth Hood
    -- (recipeID 1228992) proved dataSlotIndex is NOT globally unique - it is
    -- local to a slot group and repeats across different slot groups (e.g.
    -- slot 1 and slot 4 both reported dataSlotIndex=1). Matching on
    -- dataSlotIndex first caused rows for one slot group to be matched
    -- against an unrelated slot in another group. slotIndex is confirmed
    -- authoritative and does not repeat.
    local rowSlotIndex = NumberOrNil(row.slotIndex)
    if rowSlotIndex and slotRow.slotIndex then
        return rowSlotIndex == slotRow.slotIndex
    end

    -- Fallback only when slotIndex is unavailable on either side.
    -- dataSlotIndex alone is not trustworthy (see above), so a dataSlotIndex
    -- match additionally requires the row's item identity to be one of this
    -- slot's possible reagents before it is accepted.
    local rowDataSlotIndex = NumberOrNil(row.dataSlotIndex)
    if rowDataSlotIndex and slotRow.dataSlotIndex and rowDataSlotIndex == slotRow.dataSlotIndex then
        local possible = PossibleReagentSet(slotRow.slot)
        if itemID and possible["item:" .. tostring(itemID)] then
            return true
        end
        if currencyID and possible["currency:" .. tostring(currencyID)] then
            return true
        end
        return false
    end

    local possible = PossibleReagentSet(slotRow.slot)
    if itemID and possible["item:" .. tostring(itemID)] then
        return true
    end
    if currencyID and possible["currency:" .. tostring(currencyID)] then
        return true
    end
    return false
end
local MatchesSlot = ReagentSlotService.MatchesSlot

-- identityBasis is diagnostic provenance only - it never gates valuation or
-- classification. "actualAllocation" covers every row whose item identity
-- came from a real Blizzard source (order.reagents, GetAllocations,
-- CreateCraftingReagentInfoTbl). "estimatedQualityFallback" marks the one
-- path (EnsureRequiredSlotCoverage's unallocated-required-slot branch) where
-- PocketCFO picks a reagent quality itself because Blizzard has not
-- allocated one yet - see that function's header comment.
function ReagentSlotService.BuildNormalizedReagent(base, diagnostics, identitySource)
    local row = {
        slotOrdinal = base.slotOrdinal,
        slotIndex = base.slotIndex,
        dataSlotIndex = base.dataSlotIndex,
        itemID = base.itemID,
        currencyID = base.currencyID,
        quantity = base.quantity,
        reagentType = base.reagentType,
        dataSlotType = base.dataSlotType,
        required = base.required == true,
        orderSource = base.orderSource,
        suppliedBy = base.suppliedBy,
        classification = base.classification or "unknown",
        identityBasis = base.identityBasis or "actualAllocation",
    }
    return ReagentSlotService.AttachConfigKey(row, diagnostics, identitySource)
end
local BuildNormalizedReagent = ReagentSlotService.BuildNormalizedReagent

local function AddAllocationRowsFromGetAllocations(list, seen, transaction, slotRow, diagnostics)
    local ok, allocations = SafeMethod(transaction, "GetAllocations", slotRow.slotOrdinal)
    if not ok or not allocations or type(slotRow.slot) ~= "table" or type(slotRow.slot.reagents) ~= "table" then
        return 0
    end

    local added = 0
    for _, reagent in ipairs(slotRow.slot.reagents) do
        if type(reagent) == "table" then
            local okAlloc, allocation = SafeMethod(allocations, "FindAllocationByReagent", reagent)
            if okAlloc and allocation then
                local okQty, quantity = SafeMethod(allocation, "GetQuantity")
                quantity = okQty and NumberOrNil(quantity) or nil
                if quantity and quantity > 0 then
                    local row = BuildNormalizedReagent({
                        slotOrdinal = slotRow.slotOrdinal,
                        slotIndex = slotRow.slotIndex,
                        dataSlotIndex = slotRow.dataSlotIndex,
                        itemID = NumberOrNil(reagent.itemID),
                        currencyID = NumberOrNil(reagent.currencyID),
                        quantity = quantity,
                        reagentType = slotRow.reagentType,
                        dataSlotType = slotRow.dataSlotType,
                        required = slotRow.required,
                        orderSource = slotRow.orderSource,
                        suppliedBy = "crafter",
                        classification = slotRow.classification,
                    }, diagnostics, "transaction:GetAllocations")
                    AddUniqueRow(list, row, seen, diagnostics, "transaction:GetAllocations")
                    added = added + 1
                end
            end
        end
    end
    return added
end

local function AddAllocationRowsFromReagentTbl(list, seen, reagentTbl, consumedReagentRows, slotRow, diagnostics)
    if type(reagentTbl) ~= "table" then
        return 0
    end

    local added = 0
    for index, reagentRow in ipairs(reagentTbl) do
        if not consumedReagentRows[index] and type(reagentRow) == "table" and MatchesSlot(reagentRow, slotRow) then
            local itemID, currencyID = ExtractRowItem(reagentRow)
            local quantity = NumberOrNil(reagentRow.quantity)
            if quantity and quantity > 0 then
                local row = BuildNormalizedReagent({
                    slotOrdinal = slotRow.slotOrdinal,
                    slotIndex = slotRow.slotIndex,
                    dataSlotIndex = NumberOrNil(reagentRow.dataSlotIndex) or slotRow.dataSlotIndex,
                    itemID = itemID,
                    currencyID = currencyID,
                    quantity = quantity,
                    reagentType = slotRow.reagentType,
                    dataSlotType = slotRow.dataSlotType,
                    required = slotRow.required,
                    orderSource = slotRow.orderSource,
                    suppliedBy = "crafter",
                    classification = slotRow.classification,
                }, diagnostics, "transaction:CreateCraftingReagentInfoTbl")
                AddUniqueRow(list, row, seen, diagnostics, "transaction:CreateCraftingReagentInfoTbl")
                consumedReagentRows[index] = true
                added = added + 1
            end
        end
    end
    return added
end

-- Compares the options' item name and rarity (quality tiers of one mat
-- share both; Season 1 vs Season 2 sparks or different heraldries don't).
-- @return "same" | "different" | "unknown" (some item data not cached yet)
local function CompareOptionNameAndRarity(possibleReagents)
    local firstName, firstRarity
    for index, reagent in ipairs(possibleReagents) do
        local itemID = NumberOrNil(type(reagent) == "table" and reagent.itemID or nil)
        if not itemID or not GetItemInfo then
            return "unknown"
        end
        local ok, name, _, rarity = pcall(GetItemInfo, itemID)
        if not ok or name == nil or rarity == nil then
            return "unknown"
        end
        if index == 1 then
            firstName, firstRarity = name, rarity
        elseif name ~= firstName or rarity ~= firstRarity then
            return "different"
        end
    end
    return "same"
end

-- Is this slot's option list the quality tiers of ONE mat (pick a tier), or
-- a choice between different items (sparks, heraldry - the player has to
-- choose)?
-- Primary: Blizzard's own rule - Confirmed in Blizzard 12.1.0 source,
-- Blizzard_Professions.lua Professions.GetReagentInputMode: a slot with
-- reagentType == Enum.CraftingReagentType.Basic and more than one reagent
-- shows the quality-tier buttons; every other slot shows the pick-an-item
-- flyout. Needs no item data, so it works on a cold item cache (Patron
-- Orders board right after login).
-- Belt and braces: a Basic slot whose options are cached and clearly
-- different items is still treated as "not chosen". Without the Enum (should
-- not happen) the name/rarity check decides alone, uncached = not chosen.
local function IsQualityTierSlot(slot, possibleReagents)
    local basicType = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic
    local reagentType = NumberOrNil(type(slot) == "table" and slot.reagentType or nil)
    local comparison = CompareOptionNameAndRarity(possibleReagents)
    if basicType ~= nil and reagentType ~= nil then
        return reagentType == basicType and comparison ~= "different"
    end
    return comparison == "same"
end

-- Deterministic quality-variant fallback for a required slot that Blizzard
-- has not allocated at all (player owns none of any variant, so
-- GetAllocations/CreateCraftingReagentInfoTbl produced nothing to identify
-- the reagent). slot.reagents is the schematic's list of possible reagent
-- items for the slot; for a quality-tiered required reagent Blizzard
-- populates this list in ascending quality order - the same order the
-- crafting UI displays the quality-tier buttons in. Theoretical: that
-- ordering has not been re-confirmed with a fresh /mcgd capture.
-- Only 1-3 variants are handled because that covers every quality-tiered
-- reagent shape. Any other count is an unexpected slot shape - do not guess,
-- surface it as unresolved instead.
-- A 2/3-option slot that is NOT quality tiers of one mat (sparks, heraldry)
-- stays "not chosen" instead of costing whichever option is listed first
-- (Brian).
-- preferTopQuality (Brian, 2026-10-16): when the order requires the output's
-- top rank, cost the top mat variant instead - a top-rank order is assumed
-- to need top mats. Below the top rank the cheapest variant stays the
-- estimate; the open order view warns if higher mats end up slotted.
local function SelectEstimatedQualityReagent(slot, preferTopQuality)
    local possibleReagents = type(slot) == "table" and slot.reagents or nil
    local count = type(possibleReagents) == "table" and #possibleReagents or 0
    if (count == 2 or count == 3) and not IsQualityTierSlot(slot, possibleReagents) then
        return nil, "differentItemsNotChosen"
    end
    if count == 1 then
        return possibleReagents[1], nil
    end
    if count == 2 then
        if preferTopQuality then
            return possibleReagents[2], nil -- high quality variant
        end
        return possibleReagents[1], nil -- low quality variant
    end
    if count == 3 then
        if preferTopQuality then
            return possibleReagents[3], nil -- top quality variant
        end
        return possibleReagents[2], nil -- middle quality variant
    end
    if count == 0 then
        return nil, "noPossibleReagentsListed"
    end
    return nil, "unsupportedReagentVariantCount"
end

-- Required slots must always contribute their full recipe-required quantity
-- to the cost rows, regardless of whether Blizzard's crafting form has
-- actually allocated that quantity right now. CONFIRMED live (see
-- OrderDataDiagnostic.lua slot.quantityRequired capture): Blizzard only
-- auto-fills a required slot once the crafter holds the FULL required
-- amount - below that threshold the live transaction reports zero allocation
-- for the slot, which previously silently dropped the reagent from cost
-- (the observed Sterling Alloy bug: inventory 4 of 7 produced no cost row;
-- inventory 7 of 7 did). Operation economics ("what does this craft
-- consume") must not depend on current inventory ("can I craft this right
-- now"). Live allocation is still used to determine identity (which reagent
-- choice) when available; only the quantity is forced up to
-- slot.quantityRequired.
local function EnsureRequiredSlotCoverage(target, seen, slotRow, diagnostics, preferTopQuality)
    if slotRow.classification ~= "required" then
        return
    end
    local requiredQty = NumberOrNil(type(slotRow.slot) == "table" and slotRow.slot.quantityRequired)
    if not requiredQty or requiredQty <= 0 then
        return
    end

    local matched, total, rowCount = nil, 0, 0
    for _, row in ipairs(target) do
        if row.slotOrdinal == slotRow.slotOrdinal then
            total = total + (NumberOrNil(row.quantity) or 0)
            rowCount = rowCount + 1
            matched = row
        end
    end

    if total >= requiredQty then
        return
    end

    if rowCount == 1 and matched then
        -- One reagent choice already identified by the live allocation;
        -- correct its quantity up to the full recipe-required amount.
        matched.quantity = requiredQty
        return
    end

    if rowCount == 0 then
        -- No live allocation at all (unmet required slot). Identity comes
        -- from the schematic's own possible-reagent list when the slot shape
        -- is deterministic (see SelectEstimatedQualityReagent); otherwise an
        -- identity-less row is emitted so the shortfall surfaces as an
        -- unpriced cost rather than disappearing. This is an *estimated*
        -- reagent quality for valuation only - see identityBasis on the row.
        local selected, unresolvedReason = SelectEstimatedQualityReagent(slotRow.slot, preferTopQuality)
        local itemID = NumberOrNil(selected and selected.itemID)
        local currencyID = NumberOrNil(selected and selected.currencyID)

        local row = BuildNormalizedReagent({
            slotOrdinal = slotRow.slotOrdinal,
            slotIndex = slotRow.slotIndex,
            dataSlotIndex = slotRow.dataSlotIndex,
            itemID = itemID,
            currencyID = currencyID,
            quantity = requiredQty,
            reagentType = slotRow.reagentType,
            dataSlotType = slotRow.dataSlotType,
            required = slotRow.required,
            orderSource = slotRow.orderSource,
            suppliedBy = "crafter",
            classification = slotRow.classification,
            identityBasis = (itemID or currencyID) and "estimatedQualityFallback" or nil,
        }, diagnostics, "schematic.estimatedQualityFallback")
        AddUniqueRow(target, row, seen, diagnostics, "schematic.estimatedQualityFallback")

        if not itemID and not currencyID then
            diagnostics.unresolvedIdentities[#diagnostics.unresolvedIdentities + 1] = {
                source = "schematic.estimatedQualityFallback",
                slotOrdinal = slotRow.slotOrdinal,
                slotIndex = slotRow.slotIndex,
                reason = unresolvedReason or "ambiguousReagentChoiceUnallocated",
            }
        end
        return
    end

    -- rowCount > 1: multiple different reagent choices are partially
    -- allocated for this slot and together still fall short of the required
    -- quantity. Rare (split reagent-choice slot) - surfaced for visibility
    -- rather than guessed at.
    diagnostics.unresolvedIdentities[#diagnostics.unresolvedIdentities + 1] = {
        source = "schematic.quantityRequired",
        slotOrdinal = slotRow.slotOrdinal,
        slotIndex = slotRow.slotIndex,
        reason = "multiReagentShortfallUnresolved",
    }
end

--- Adds the crafter's cost rows for one slot to target: the live allocation
-- (GetAllocations, falling back to CreateCraftingReagentInfoTbl), then the
-- full-required-quantity correction for required slots. transaction may be
-- nil (Patron Orders board list estimates) - required slots are then costed
-- from the schematic alone.
-- @param consumedReagentRows table shared across all slots of one craft so
--        a reagentTbl row is never claimed by two slots.
-- @param preferTopQuality optional; true = an unallocated quality-tier slot
--        is costed at its top variant (see SelectEstimatedQualityReagent).
--        nil/false keeps the existing estimate.
function ReagentSlotService.AddCrafterSlotRows(target, seen, consumedReagentRows, transaction, reagentTbl, slotRow, diagnostics, preferTopQuality)
    local added = AddAllocationRowsFromGetAllocations(target, seen, transaction, slotRow, diagnostics)
    if added == 0 then
        AddAllocationRowsFromReagentTbl(target, seen, reagentTbl, consumedReagentRows, slotRow, diagnostics)
    end
    EnsureRequiredSlotCoverage(target, seen, slotRow, diagnostics, preferTopQuality)
end

--- Where itemID sits among a quality-tier slot's variants.
-- Uses the same ascending-order reading of slot.reagents as
-- SelectEstimatedQualityReagent (Theoretical ordering - see there).
-- @return index, count - or nil when the slot is not quality tiers of one
--         mat or itemID is not one of its variants.
function ReagentSlotService.GetQualityVariantIndex(slotRow, itemID)
    local slot = type(slotRow) == "table" and slotRow.slot or nil
    local possibleReagents = type(slot) == "table" and slot.reagents or nil
    local count = type(possibleReagents) == "table" and #possibleReagents or 0
    itemID = NumberOrNil(itemID)
    if count < 2 or not itemID or not IsQualityTierSlot(slot, possibleReagents) then
        return nil, nil
    end
    for index, reagent in ipairs(possibleReagents) do
        if NumberOrNil(type(reagent) == "table" and reagent.itemID or nil) == itemID then
            return index, count
        end
    end
    return nil, nil
end

--- A row with no item identity is a slot with nothing chosen yet (e.g. a
-- heraldry or spark slot). Marks it notChosen and attaches the slot's
-- display name so the analysis can say "Heraldry (not chosen)" instead of
-- "Unknown reagent". slot.slotInfo.slotText: Theoretical (not yet confirmed
-- in-game) - consumers fall back to a generic label when it is missing.
-- @param lists array of row lists to mark in place
function ReagentSlotService.MarkNotChosenRows(lists, slotRows)
    local slotByOrdinal = {}
    for _, slotRow in ipairs(slotRows or {}) do
        slotByOrdinal[slotRow.slotOrdinal] = slotRow
    end
    for _, list in ipairs(lists or {}) do
        for _, row in ipairs(list) do
            if row.itemID == nil and row.currencyID == nil then
                row.notChosen = true
                local slot = slotByOrdinal[row.slotOrdinal] and slotByOrdinal[row.slotOrdinal].slot
                local slotInfo = type(slot) == "table" and slot.slotInfo or nil
                row.slotName = NonEmpty(type(slotInfo) == "table" and slotInfo.slotText or nil)
            end
        end
    end
end

if PocketCFO then
    PocketCFO.ReagentSlotService = ReagentSlotService
end
