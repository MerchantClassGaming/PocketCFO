-- PocketCFO_AH/Infrastructure/AHManager.lua
-- Thin event sink and coordinator. Delegates session, post capture, and lifecycle work
-- to AHSessionController, PostingEventCapture, and PostingLifecycleController.

local ADDON_NAME, _ = ...
local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local AHManager = PocketCFO_AH:NewModule("AHManager", "AceEvent-3.0")

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function FirstNumericArg(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "number" or tonumber(value) then
            return value
        end
    end
    return nil
end

-- Event handlers — delegate to the appropriate coordinator.

function AHManager:OnInitialize()
    SessionLog("AHManager OnInitialize")
end

function AHManager:OnAuctionHouseShow(event)
    PocketCFO_AH.AHSessionController:OnAuctionHouseShow(event)
end

function AHManager:OnOwnedAuctionsUpdated()
    PocketCFO_AH.AHSessionController:OnOwnedAuctionsUpdated()
end

function AHManager:OnAuctionCreated(event, ...)
    local postCapture = PocketCFO_AH.PostingEventCapture
    local pending = postCapture and postCapture:GetPendingPostAndClear() or nil
    local auctionID = FirstNumericArg(...)
    PocketCFO_AH.PostingLifecycleController:HandleAuctionCreated(auctionID, pending)
end

function AHManager:OnAuctionHouseClosed()
    PocketCFO_AH.AHSessionController:CloseSession()
    local postCapture = PocketCFO_AH.PostingEventCapture
    if postCapture then
        postCapture:ClearPendingPost()
    end
end

-- Public methods — signatures preserved for external callers.

function AHManager:RequestOwnedAuctionsRefresh(reason, callback, timeoutSeconds)
    return PocketCFO_AH.AHSessionController:RequestOwnedAuctionsRefresh(reason, callback, timeoutSeconds)
end

function AHManager:RunManualOwnedAuctionScan()
    return PocketCFO_AH.AHSessionController:RunManualOwnedAuctionScan()
end

function AHManager:StartAHOpenSessionIfAvailable(reason)
    return PocketCFO_AH.AHSessionController:StartAHOpenSessionIfAvailable(reason)
end

function AHManager:IsPendingPostGUID(itemGUID)
    local postCapture = PocketCFO_AH.PostingEventCapture
    return postCapture and postCapture:IsPendingPostGUID(itemGUID) or false
end

function AHManager:OnEnable()
    SessionLog("AHManager OnEnable")
    local postCapture = PocketCFO_AH.PostingEventCapture
    if postCapture then
        postCapture:ClearPendingPost()
        postCapture:HookPostMethods()
    end
    self:RegisterEvent("AUCTION_HOUSE_SHOW",           "OnAuctionHouseShow")
    self:RegisterEvent("OWNED_AUCTIONS_UPDATED",       "OnOwnedAuctionsUpdated")
    self:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED","OnAuctionCreated")
    self:RegisterEvent("AUCTION_HOUSE_CLOSED",         "OnAuctionHouseClosed")
    SessionLog("AHManager: events registered AUCTION_HOUSE_SHOW OWNED_AUCTIONS_UPDATED AUCTION_HOUSE_AUCTION_CREATED AUCTION_HOUSE_CLOSED")

    self:StartAHOpenSessionIfAvailable("manager-on-enable")
end
