-- PocketCFO_Orders/Init.lua
-- Sibling addon for order tracking, bag opens, knowledge points, and Moxie.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local PocketCFO_Orders = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceEvent-3.0")
_G.PocketCFO_Orders = PocketCFO_Orders

local DB_DEFAULTS = {
    global = {
        orders          = {},
        bagOpens        = {},
        bagOpensAggregated = { bags = 0 },  -- aggregated totals: bags count + itemID totals
        knowledgePoints = {},
        moxieEvents     = {},
        orderResults    = { days = {} },  -- OrdersLedger: daily totals of completed orders
    },
}

function PocketCFO_Orders:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("PocketCFO_Orders_DB", DB_DEFAULTS, true)
end

function PocketCFO_Orders:OnEnable()
end
