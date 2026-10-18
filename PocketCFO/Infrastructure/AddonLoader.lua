-- PocketCFO/Infrastructure/AddonLoader.lua
-- Tier 2 lazy-load coordinator.
-- Provides SafeLoad for on-demand addon loading by slash commands and event handlers.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local AddonLoader = PocketCFO:NewModule("AddonLoader", "AceEvent-3.0")

function AddonLoader:SafeLoad(name)
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(name))
                or (IsAddOnLoaded and IsAddOnLoaded(name))
    if loaded then return true end

    local loadFn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if not loadFn then return false end

    local ok, _ = loadFn(name)
    return ok and true or false
end

function AddonLoader:OnEnable()
    self:RegisterEvent("TRADE_SKILL_SHOW", "OnTradeSkillShow")
    self:RegisterEvent("AUCTION_HOUSE_SHOW", "OnAuctionHouseShow")
    self:SafeLoad("PocketCFO_Valuation")
end

function AddonLoader:OnTradeSkillShow()
    self:SafeLoad("PocketCFO_Crafting")
    self:SafeLoad("PocketCFO_Orders")
    self:SafeLoad("PocketCFO_Valuation")
end

function AddonLoader:OnAuctionHouseShow()
    self:SafeLoad("PocketCFO_AH")
    self:SafeLoad("PocketCFO_Valuation")
end
