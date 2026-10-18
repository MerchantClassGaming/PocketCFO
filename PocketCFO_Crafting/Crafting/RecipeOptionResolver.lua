-- PocketCFO_Crafting/Crafting/RecipeOptionResolver.lua
-- Crafting-owned recipe capability discovery for optional reagent and missive state.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local RecipeOptionResolver = PocketCFO_Crafting:NewModule("RecipeOptionResolver")

local function GetIdentityAdapters()
    local PocketCFO = _G.PocketCFO
    return PocketCFO and PocketCFO.ItemIdentityAdapters or _G.PocketCFO_ItemIdentityAdapters
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return false, nil
    end
    return pcall(fn, ...)
end

local function GetItemName(itemID, fallback)
    if itemID and GetItemInfo then
        local name = GetItemInfo(itemID)
        if name then
            return name
        end
    end
    return fallback
end

function RecipeOptionResolver:GetMissiveStatTargetFromName(itemName)
    local adapters = GetIdentityAdapters()
    if adapters and adapters.GetMissiveStatForItemName then
        return adapters:GetMissiveStatForItemName(itemName)
    end
    return nil
end

function RecipeOptionResolver:CollectMissiveOptions(schematicInfo)
    local options = {}
    local byStatTarget = {}
    for _, slotData in ipairs((schematicInfo and schematicInfo.reagentSlotSchematics) or {}) do
        local reagentType = tonumber(slotData.reagentType)
        if reagentType ~= 1 and not slotData.required then
            for _, reagent in ipairs(slotData.reagents or {}) do
                local itemID = tonumber(reagent.itemID)
                local itemName = GetItemName(itemID, reagent.name)
                local statTarget, label = self:GetMissiveStatTargetFromName(itemName)
                if statTarget and not byStatTarget[statTarget] then
                    local option = {
                        itemID = itemID,
                        label = label or itemName or statTarget,
                        variantKey = statTarget,
                        statTarget = statTarget,
                    }
                    byStatTarget[statTarget] = option
                    options[#options + 1] = option
                end
            end
        end
    end
    table.sort(options, function(a, b) return tostring(a.label) < tostring(b.label) end)
    return options
end

function RecipeOptionResolver:CollectOptionalReagentChoices(schematicInfo)
    local choices = {}
    for _, slotData in ipairs((schematicInfo and schematicInfo.reagentSlotSchematics) or {}) do
        local reagentType = tonumber(slotData.reagentType)
        if reagentType ~= 1 and not slotData.required then
            local slotChoices = {
                reagentType = reagentType,
                slotIndex = slotData.slotIndex,
                label = slotData.name,
                reagents = {},
            }
            for _, reagent in ipairs(slotData.reagents or {}) do
                local itemID = tonumber(reagent.itemID)
                slotChoices.reagents[#slotChoices.reagents + 1] = {
                    itemID = itemID,
                    itemName = GetItemName(itemID, reagent.name),
                    quantity = tonumber(reagent.quantity),
                }
            end
            choices[#choices + 1] = slotChoices
        end
    end
    return choices
end

function RecipeOptionResolver:ReadSelectedMissiveStat(sf, schematicInfo)
    local reagentSlots = sf and sf.reagentSlots
    if not reagentSlots then
        return nil, nil
    end

    local typeCounters = {}
    for _, slotData in ipairs((schematicInfo and schematicInfo.reagentSlotSchematics) or {}) do
        local reagentType = tonumber(slotData.reagentType)
        if reagentType ~= 1 and not slotData.required then
            typeCounters[reagentType] = (typeCounters[reagentType] or 0) + 1
            local slotFrame = reagentSlots[reagentType] and reagentSlots[reagentType][typeCounters[reagentType]]
            local itemID
            if slotFrame and slotFrame.Button and slotFrame.Button.GetItemID then
                local ok, result = SafeCall(function() return slotFrame.Button:GetItemID() end)
                if ok then
                    itemID = tonumber(result)
                end
            end
            if not itemID and slotFrame and slotFrame.GetItemID then
                local ok, result = SafeCall(function() return slotFrame:GetItemID() end)
                if ok then
                    itemID = tonumber(result)
                end
            end
            if itemID then
                local itemName = GetItemName(itemID)
                local statTarget, label = self:GetMissiveStatTargetFromName(itemName)
                if statTarget then
                    return statTarget, label or itemName
                end
            end
        end
    end
    return nil, nil
end

function RecipeOptionResolver:FindVariantByStatTarget(variants, statTarget)
    if not statTarget then
        return nil
    end
    for _, variant in ipairs(variants or {}) do
        if variant.statTarget == statTarget then
            return variant
        end
    end
    return nil
end

function RecipeOptionResolver:Resolve(recipeID, sf, schematicInfo)
    schematicInfo = schematicInfo
    if not schematicInfo and recipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
        local ok, result = SafeCall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if ok then
            schematicInfo = result
        end
    end

    local statTarget, statLabel = self:ReadSelectedMissiveStat(sf, schematicInfo)
    local missiveOptions = self:CollectMissiveOptions(schematicInfo)
    return {
        recipeID = tonumber(recipeID),
        schematicInfo = schematicInfo,
        missiveOptions = missiveOptions,
        optionalReagentChoices = self:CollectOptionalReagentChoices(schematicInfo),
        selectedMissiveStatTarget = statTarget,
        selectedMissiveStatLabel = statLabel,
        selectedMissiveOption = self:FindVariantByStatTarget(missiveOptions, statTarget),
    }
end
