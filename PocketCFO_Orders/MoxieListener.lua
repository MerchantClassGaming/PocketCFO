-- PocketCFO_Orders/MoxieListener.lua
-- Stub: Moxie currency event listener.

local ADDON_NAME, _ = ...
local PocketCFO_Orders = _G.PocketCFO_Orders

local MoxieListener = PocketCFO_Orders:NewModule("MoxieListener", "AceEvent-3.0")

-- TODO: implement Moxie gain/spend detection and recording to
--       PocketCFO_Orders.db.global.moxieEvents.

function MoxieListener:OnEnable()
end

function MoxieListener:OnDisable()
    self:UnregisterAllEvents()
end
