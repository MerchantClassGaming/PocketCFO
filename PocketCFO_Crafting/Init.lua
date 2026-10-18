-- PocketCFO_Crafting/Init.lua
-- Crafting addon initialization. Registers as a standalone AceAddon.
-- Depends on PocketCFO core for shared utilities and inventory snapshots.

local ADDON_NAME = ...

local PocketCFO_Crafting = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME,
    "AceEvent-3.0"
)
_G.PocketCFO_Crafting = PocketCFO_Crafting

local DB_DEFAULTS = {
    global = {
        recipeConfigurations = {},
        postingRulesWindow = {
            open = false,
        },
    },
}

function PocketCFO_Crafting:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("PocketCFO_Crafting_DB", DB_DEFAULTS, true)
    self.db.global.postingRulesWindow = self.db.global.postingRulesWindow or { open = false }
    local PocketCFO = _G.PocketCFO
    if PocketCFO then
        PocketCFO:Debug("PocketCFO_Crafting initialized.")
    end
end

local function SessionLog(fmt, ...)
    local PocketCFO = _G.PocketCFO
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

function PocketCFO_Crafting:OnEnable()
    self:InstallSelectRecipeHook()
end

function PocketCFO_Crafting:SetViewedRecipe(recipeID, source)
    if not recipeID then
        return
    end

    if self.viewedRecipeID == recipeID then
        return
    end

    self.viewedRecipeID = recipeID
    SessionLog("SetViewedRecipe: recipeID=%s source=%s -> SendMessage PCFO_VIEWED_RECIPE_CHANGED", tostring(recipeID), tostring(source))
    self:SendMessage("PCFO_VIEWED_RECIPE_CHANGED", recipeID, source)
end

function PocketCFO_Crafting:ReadSelectedRecipeID()
    local sf = ProfessionsFrame
        and ProfessionsFrame.CraftingPage
        and ProfessionsFrame.CraftingPage.SchematicForm
    if not sf or not sf.GetRecipeInfo then
        return nil
    end

    local ok, recipeInfo = pcall(function()
        return sf:GetRecipeInfo()
    end)
    if ok and recipeInfo and recipeInfo.recipeID then
        return recipeInfo.recipeID
    end
    return nil
end

function PocketCFO_Crafting:NotifySelectedRecipeFromHook()
    if not C_Timer or not C_Timer.After then
        return
    end

    C_Timer.After(0, function()
        local recipeID = self:ReadSelectedRecipeID()
        if recipeID then
            self:SetViewedRecipe(recipeID, "select-recipe")
        end
    end)
end

function PocketCFO_Crafting:InstallSelectRecipeHook()
    local craftingPage = ProfessionsFrame and ProfessionsFrame.CraftingPage
    if not craftingPage then
        SessionLog("InstallSelectRecipeHook: skipped reason=noCraftingPage ProfessionsFrame=%s", tostring(ProfessionsFrame ~= nil))
        return
    end
    if craftingPage.__pcfoSelectRecipeHooked then
        return
    end
    if not craftingPage.SelectRecipe or not hooksecurefunc then
        SessionLog("InstallSelectRecipeHook: skipped reason=missingSelectRecipeOrHooksecurefunc hasSelectRecipe=%s hasHooksecurefunc=%s",
            tostring(craftingPage.SelectRecipe ~= nil), tostring(hooksecurefunc ~= nil))
        return
    end

    hooksecurefunc(craftingPage, "SelectRecipe", function()
        PocketCFO_Crafting:NotifySelectedRecipeFromHook()
    end)
    SessionLog("InstallSelectRecipeHook: installed")
    craftingPage.__pcfoSelectRecipeHooked = true
end

function PocketCFO_Crafting:OnDisable()
end
