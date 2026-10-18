-- PocketCFO_Orders/KnowledgePointLog.lua
-- Stub: profession knowledge point gain tracking.

local ADDON_NAME, _ = ...
local PocketCFO_Orders = _G.PocketCFO_Orders

local KnowledgePointLog = PocketCFO_Orders:NewModule("KnowledgePointLog", "AceEvent-3.0")

-- TODO: implement knowledge point gain detection and recording to
--       PocketCFO_Orders.db.global.knowledgePoints.

function KnowledgePointLog:OnEnable()
end

function KnowledgePointLog:OnDisable()
    self:UnregisterAllEvents()
end
