-- PocketCFO_Crafting/UI/InventoryManager/InventoryTargetDialogs.lua
-- Popup dialogs for the Inventory Manager: quantity edit and delete confirmation.

local PocketCFO_Crafting = _G.PocketCFO_Crafting

function MCGCFO_ShowDeleteDialog(configID, itemName)
    StaticPopupDialogs["MCGCFO_DELETE_CONFIG"] = {
        text         = "Delete inventory target?\n\n" .. (itemName or "Unknown"),
        button1      = "Delete",
        button2      = "Cancel",
        OnAccept     = function()
            PocketCFO_Crafting:GetModule("RecipeConfigStore"):DeleteConfiguration(configID)
        end,
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("MCGCFO_DELETE_CONFIG")
end

function MCGCFO_ShowQuantityDialog(configID, itemName, currentQuantity)
    local PocketCFO = _G.PocketCFO
    StaticPopupDialogs["MCGCFO_SET_QUANTITY"] = {
        text         = "Set target quantity for:\n" .. (itemName or "Unknown"),
        button1      = "OK",
        button2      = "Cancel",
        hasEditBox   = true,
        editBoxWidth = 80,
        OnShow       = function(self)
            local eb = _G[self:GetName() .. "EditBox"]
            if eb then
                eb:SetNumeric(true)
                eb:SetText(tostring(currentQuantity or 1))
                eb:HighlightText()
            end
        end,
        OnAccept     = function(self)
            local eb = _G[self:GetName() .. "EditBox"]
            local val = eb and tonumber(eb:GetText())
            if val and val >= 1 then
                PocketCFO_Crafting:GetModule("RecipeConfigStore"):SetTargetQuantity(configID, val)
            else
                PocketCFO:Print("Invalid quantity — must be 1 or more.")
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local val = tonumber(self:GetText())
            if val and val >= 1 then
                PocketCFO_Crafting:GetModule("RecipeConfigStore"):SetTargetQuantity(configID, val)
                self:GetParent():Hide()
            end
        end,
        timeout      = 0,
        whileDead    = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("MCGCFO_SET_QUANTITY")
end
