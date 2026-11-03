-- PocketCFO_Orders/Init.lua
-- Sibling addon for order tracking, knowledge points, and Moxie.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local PocketCFO_Orders = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceEvent-3.0")
_G.PocketCFO_Orders = PocketCFO_Orders

local DB_DEFAULTS = {
    global = {
        orders          = {},
        orderResults    = { days = {} },  -- OrdersLedger: daily totals of completed orders
    },
}

function PocketCFO_Orders:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("PocketCFO_Orders_DB", DB_DEFAULTS, true)
    -- BagOpens.lua was retired 2026-10-30 (container openings now come from
    -- core LootReader). Clears its saved data; delete these lines in a later
    -- release.
    self.db.global.bagOpens = nil
    self.db.global.bagOpensAggregated = nil
end

function PocketCFO_Orders:OnEnable()
end
