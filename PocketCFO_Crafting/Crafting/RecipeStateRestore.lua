-- PocketCFO_Crafting/Crafting/RecipeStateRestore.lua
-- Restores saved recipe configurations into the Blizzard crafting UI.

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local RecipeStateRestore = PocketCFO_Crafting:NewModule("RecipeStateRestore", "AceEvent-3.0")

local function GetProfessionRegistry()
    return PocketCFO and PocketCFO.ProfessionRegistry or _G.PocketCFO_ProfessionRegistry
end

local function GetProfessionContextService()
    return PocketCFO_Crafting:GetModule("ProfessionContextService", true)
end

local function GetConfig(configOrID)
    if type(configOrID) == "table" then
        return configOrID
    end
    local store = PocketCFO_Crafting:GetModule("RecipeConfigStore", true)
    if store and store.GetConfiguration then
        return store:GetConfiguration(configOrID)
    end
    return nil
end

function RecipeStateRestore:LoadConfigIntoCraftingWindow(configID, quantity)
    local config = GetConfig(configID)
    if not config then
        PocketCFO:Debug("Load: configID not found: %s", configID)
        return
    end

    local craftingPage = ProfessionsFrame and ProfessionsFrame.CraftingPage
    if not craftingPage then
        PocketCFO:Debug("Load: no craftingPage")
        return
    end

    local recipeInfo = C_TradeSkillUI.GetRecipeInfo(config.recipeID)
    if not recipeInfo then
        PocketCFO:Debug("Load: GetRecipeInfo nil for recipeID=%d", config.recipeID)
        return
    end

    -- Restore is committed to proceed past this point (config, craftingPage,
    -- and recipeInfo are all valid). Announce the start so listeners that
    -- must not read recipe state until optional/material slots are fully
    -- restored (e.g. RecipePostingRulesWindow) can defer until
    -- PCFO_CONFIG_LOADED_INTO_CRAFTING_WINDOW fires below.
    PocketCFO_Crafting:SendMessage("PCFO_CONFIG_LOAD_STARTED_INTO_CRAFTING_WINDOW", configID)

    local needsExpSwitch = false
    if config.expansionID and config.professionID then
        local registry = GetProfessionRegistry()
        local contextService = GetProfessionContextService()
        local targetChildID = registry and registry:GetChildSkillLineID(config.professionID, config.expansionID)
        local currentChildID = contextService and contextService:GetCurrentChildSkillLineID()
        if targetChildID and currentChildID and targetChildID ~= currentChildID then
            PocketCFO:Debug("Load: switching expansion childSkillLineID %d -> %d", currentChildID, targetChildID)
            if C_TradeSkillUI.SetProfessionChildSkillLineID then
                C_TradeSkillUI.SetProfessionChildSkillLineID(targetChildID)
                needsExpSwitch = true
            else
                PocketCFO:Debug("Load: SetProfessionChildSkillLineID not available - skipping switch")
            end
        end
    end

    local function DoSelectAndRestore()
        craftingPage:SelectRecipe(recipeInfo)
        PocketCFO:Debug("Load: SelectRecipe called for recipeID=%d", config.recipeID)

        C_Timer.After(0.1, function()
            local sf = ProfessionsFrame and ProfessionsFrame.CraftingPage
                and ProfessionsFrame.CraftingPage.SchematicForm
            if not sf then
                PocketCFO:Debug("Restore: SchematicForm gone")
                return
            end

            local transaction = sf:GetTransaction()
            if not transaction then
                PocketCFO:Debug("Restore: no transaction")
                return
            end

            local currentID = transaction:GetRecipeID()
            if currentID ~= config.recipeID then
                PocketCFO:Debug("Restore: recipe mismatch got=%s want=%d",
                    tostring(currentID), config.recipeID)
                return
            end

            local schematicInfo = C_TradeSkillUI.GetRecipeSchematic(config.recipeID, false)
            if not schematicInfo or not schematicInfo.reagentSlotSchematics then
                PocketCFO:Debug("Restore: GetRecipeSchematic nil")
                return
            end

            local reagentSlots = sf.reagentSlots
            if not reagentSlots then
                PocketCFO:Debug("Restore: sf.reagentSlots nil")
                return
            end

            local typeCounters = {}
            local slotFrameByIndex = {}
            for arrayIndex, slotData in ipairs(schematicInfo.reagentSlotSchematics) do
                local reagentType = slotData.reagentType
                local slotIndex = slotData.slotIndex

                if not (reagentType == 2 and slotData.required) then
                    typeCounters[reagentType] = (typeCounters[reagentType] or 0) + 1
                    local n = typeCounters[reagentType]
                    local slotFrame = reagentSlots[reagentType] and reagentSlots[reagentType][n]
                    if slotFrame then
                        slotFrameByIndex[slotIndex] = {
                            frame = slotFrame,
                            slotData = slotData,
                            arrayIndex = arrayIndex,
                        }
                    end
                end
            end

            if config.optionalSlots then
                for slotIndex, slotEntry in pairs(config.optionalSlots) do
                    local itemID = slotEntry and slotEntry.itemID
                    if itemID then
                        local entry = slotFrameByIndex[slotIndex]
                        if entry and entry.slotData.reagents then
                            for _, reagent in ipairs(entry.slotData.reagents) do
                                if reagent.itemID == itemID then
                                    local tok, terr = pcall(function()
                                        local allocTbl = transaction.allocationTbls[slotIndex]
                                        allocTbl:Clear()
                                        allocTbl:Allocate(reagent, 1)
                                    end)
                                    PocketCFO:Debug("Restore: opt slot %d itemID=%d allocationTbls:Allocate %s",
                                        slotIndex, itemID, tok and "OK" or ("FAIL: " .. tostring(terr)))

                                    pcall(function() entry.frame:SetTransaction(transaction) end)
                                    local fok, ferr = pcall(function()
                                        entry.frame:SetReagent(reagent)
                                    end)
                                    PocketCFO:Debug("Restore: opt slot %d itemID=%d frame:SetReagent %s",
                                        slotIndex, itemID, fok and "OK" or ("FAIL: " .. tostring(ferr)))

                                    if fok then pcall(function() entry.frame:Update() end) end
                                    break
                                end
                            end
                        end
                    end
                end
            end

            if quantity and quantity > 0 then
                local inputBox = craftingPage and craftingPage.CreateMultipleInputBox
                if inputBox and inputBox.SetValue then
                    pcall(function() inputBox:SetValue(quantity) end)
                    PocketCFO:Debug("Restore: CreateMultipleInputBox:SetValue(%d)", quantity)
                elseif inputBox and inputBox.SetText then
                    pcall(function() inputBox:SetText(tostring(quantity)) end)
                    PocketCFO:Debug("Restore: CreateMultipleInputBox:SetText(%d)", quantity)
                else
                    PocketCFO:Debug("Restore: CreateMultipleInputBox not found")
                end
            end

            if sf.UpdateAllSlots then sf:UpdateAllSlots() end

            if config.matSlots and next(config.matSlots) then
                for slotIndex, qualityEntries in pairs(config.matSlots) do
                    if type(qualityEntries) == "table" and #qualityEntries > 0 then
                        local reagentTbl = transaction.reagentTbls
                            and transaction.reagentTbls[slotIndex]
                        if not reagentTbl then
                            PocketCFO:Debug("Restore: mat slot %d - reagentTbls[%d] nil",
                                slotIndex, slotIndex)
                        else
                            local allocations = reagentTbl.allocations
                            local rss = reagentTbl.reagentSlotSchematic
                            if not allocations or not rss then
                                PocketCFO:Debug("Restore: mat slot %d - allocations or rss nil", slotIndex)
                            else
                                local reagentByID = {}
                                for _, r in ipairs(rss.reagents or {}) do
                                    if r.itemID then reagentByID[r.itemID] = r end
                                end

                                pcall(function() allocations:Clear() end)

                                for _, qe in ipairs(qualityEntries) do
                                    local reagent = reagentByID[qe.itemID]
                                    if reagent then
                                        local ok, err = pcall(function()
                                            allocations:Allocate(reagent, qe.quantity)
                                        end)
                                        PocketCFO:Debug("Restore: mat slot %d itemID=%d qty=%d %s",
                                            slotIndex, qe.itemID, qe.quantity,
                                            ok and "OK" or ("FAIL: " .. tostring(err)))
                                    else
                                        PocketCFO:Debug("Restore: mat slot %d itemID=%d - not in rss.reagents",
                                            slotIndex, qe.itemID)
                                    end
                                end
                            end
                        end
                    end
                end

                local ok, err = pcall(function()
                    transaction:SetManuallyAllocated(true)
                end)
                PocketCFO:Debug("Restore: SetManuallyAllocated %s",
                    ok and "OK" or ("FAIL: " .. tostring(err)))
            end

            if sf.UpdateAllSlots then sf:UpdateAllSlots() end

            PocketCFO:Debug("Restore: complete")
            PocketCFO_Crafting:SendMessage("PCFO_CONFIG_LOADED_INTO_CRAFTING_WINDOW", configID)
        end)
    end

    if needsExpSwitch then
        C_Timer.After(0.3, DoSelectAndRestore)
    else
        DoSelectAndRestore()
    end
end
