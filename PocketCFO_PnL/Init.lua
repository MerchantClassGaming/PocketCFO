-- PocketCFO_PnL/Init.lua
-- Display-only addon for gold and profit views. Owns no SavedVariables:
-- everything it shows is read from core modules (GoldTracker, GoldLedger).
-- Loaded on demand by core when the Gold window is opened (/mcg gold).

local ADDON_NAME, _ = ...

local PocketCFO_PnL = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceEvent-3.0")
_G.PocketCFO_PnL = PocketCFO_PnL

function PocketCFO_PnL:OnInitialize()
end

function PocketCFO_PnL:OnEnable()
end
