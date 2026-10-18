-- PocketCFO_AH/Posting/Components/PostingEventCapture.lua
-- Captures AH posting events, maintains pending-post correlation state,
-- and provides pending-post information to downstream consumers.

local ADDON_NAME, _ = ...
local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingEventCapture = {}
PocketCFO_AH.PostingEventCapture = PostingEventCapture

local function Debug(msg, ...)
    if PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug(msg, ...)
    end
end

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function HasGUID(value)
    return value ~= nil and tostring(value) ~= ""
end

local function GetItemLink(itemLocation)
    if not itemLocation or not C_Item or not C_Item.GetItemLink then
        return nil
    end
    if itemLocation.IsValid and not itemLocation:IsValid() then
        return nil
    end
    local ok, itemLink = pcall(C_Item.GetItemLink, itemLocation)
    if ok then
        return itemLink
    end
    return nil
end

local function GetItemGUID(itemLocation)
    if not itemLocation or not C_Item or not C_Item.GetItemGUID then
        return nil
    end
    if itemLocation.IsValid and not itemLocation:IsValid() then
        return nil
    end
    local ok, itemGUID = pcall(C_Item.GetItemGUID, itemLocation)
    if ok then
        return itemGUID
    end
    return nil
end

local function GetItemIDFromLink(itemLink)
    if not itemLink then
        return nil
    end
    if GetItemInfoFromHyperlink then
        local itemID = GetItemInfoFromHyperlink(itemLink)
        if itemID then
            return itemID
        end
    end
    return tonumber(tostring(itemLink):match("item:(%d+)"))
end

local function GetIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

-- State

PostingEventCapture.pendingPost        = nil
PostingEventCapture.postHooksInstalled = false

local ATTEMPT_TIMESTAMP_TOLERANCE_SECONDS = 5

-- Best-effort match between a PostingExecution pending-post attempt (evidence) and this
-- module's independently-hooked pendingPost. Preference order: shared attemptID, then
-- row identity (configKey), then itemGUID, then itemID+quantity+price, then timestamp
-- proximity. See PostingExecution:BuildPendingPostEvidence for the evidence shape.
local function EvidenceMatchesPendingPost(evidence, pendingPost)
    if type(evidence) ~= "table" or type(pendingPost) ~= "table" then
        return false
    end

    if evidence.attemptID and pendingPost.attemptID then
        return tostring(evidence.attemptID) == tostring(pendingPost.attemptID)
    end

    if evidence.configKey and pendingPost.configKey then
        return tostring(evidence.configKey) == tostring(pendingPost.configKey)
    end

    if evidence.itemGUID and pendingPost.itemGUID then
        return tostring(evidence.itemGUID) == tostring(pendingPost.itemGUID)
    end

    if evidence.itemID and pendingPost.itemID and tonumber(evidence.itemID) ~= tonumber(pendingPost.itemID) then
        return false
    end

    if evidence.quantity and pendingPost.quantity
        and tonumber(evidence.quantity) ~= tonumber(pendingPost.quantity) then
        return false
    end

    if evidence.unitPrice and pendingPost.buyout
        and tonumber(evidence.unitPrice) ~= tonumber(pendingPost.buyout) then
        return false
    end

    local evidenceTime = tonumber(evidence.requestedAt)
    local captureTime = tonumber(pendingPost.capturedAt)
    if evidenceTime and captureTime and math.abs(evidenceTime - captureTime) > ATTEMPT_TIMESTAMP_TOLERANCE_SECONDS then
        return false
    end

    return evidence.itemID ~= nil or pendingPost.itemID ~= nil
end

-- Read-only correlation check, reused by ClearPendingPost and by stuck-post diagnostics
-- so both paths agree on whether the two independent pending-post trackers match.
function PostingEventCapture:MatchesEvidence(evidence)
    return EvidenceMatchesPendingPost(evidence, self.pendingPost)
end

-- Clears the captured pending post. With no expectedEvidence, clears unconditionally
-- (existing behavior, used by AUCTION_HOUSE_CLOSED/OnEnable). With expectedEvidence,
-- only clears when it appears to belong to the same attempt - unrelated pending
-- evidence (e.g. a TSM/Auctionator post) is left alone.
function PostingEventCapture:ClearPendingPost(reason, expectedEvidence)
    if self.pendingPost == nil then
        return false
    end

    if expectedEvidence ~= nil and not EvidenceMatchesPendingPost(expectedEvidence, self.pendingPost) then
        SessionLog("AHManager: pending post clear skipped reason=%s (evidence did not match captured pending post)",
            tostring(reason or "unspecified"))
        return false
    end

    self.pendingPost = nil
    if reason then
        SessionLog("AHManager: pending post cleared reason=%s", tostring(reason))
    end
    return true
end

function PostingEventCapture:GetPendingPostAndClear()
    local pending = self.pendingPost
    self.pendingPost = nil
    return pending
end

function PostingEventCapture:IsPendingPostGUID(itemGUID)
    return self.pendingPost
        and HasGUID(itemGUID)
        and HasGUID(self.pendingPost.itemGUID)
        and tostring(self.pendingPost.itemGUID) == tostring(itemGUID)
end

function PostingEventCapture:CapturePendingPost(itemLocation, duration, quantity, bid, buyout)
    local itemGUID       = GetItemGUID(itemLocation)
    local itemLink       = GetItemLink(itemLocation)
    local itemID         = GetItemIDFromLink(itemLink)
    local postedQuantity = tonumber(quantity) or 1
    if not itemID or itemID <= 0 or postedQuantity <= 0 then
        self.pendingPost = nil
        SessionLog("AHManager: pending post capture skipped reason=missing_item_or_quantity itemGUID=%s itemID=%s quantity=%s itemLinkPresent=%s",
            tostring(itemGUID), tostring(itemID), tostring(quantity), tostring(itemLink ~= nil))
        return
    end

    local identityService = GetIdentityService()
    local identity = identityService and identityService:FromItemLink(itemLink) or nil

    self.pendingPost = {
        ownerKey        = PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID or nil,
        itemGUID        = HasGUID(itemGUID) and tostring(itemGUID) or nil,
        itemID          = (identity and identity.itemID) or itemID or 0,
        itemName        = (identity and identity.itemName) or "Unknown",
        itemLink        = (identity and identity.itemLink) or itemLink,
        configKey       = identity and identity.configKey or nil,
        quantity        = postedQuantity,
        itemQuality     = (identity and identity.itemQuality) or 0,
        craftingQuality = (identity and identity.craftingQuality) or 0,
        rarityQuality   = (identity and identity.rarityQuality) or nil,
        ilvl            = (identity and identity.effectiveIlvl) or nil,
        statFingerprint = (identity and identity.statFingerprint) or nil,
        itemStats       = (identity and identity.itemStats) or nil,
        isStackable     = (identity and identity.isCommodity) or false,
        bid             = bid or 0,
        buyout          = buyout or 0,
        duration        = duration,
        capturedAt      = Now(),
    }
    SessionLog("AHManager: pending post captured source=item itemGUID=%s itemID=%s quantity=%d quality=%s itemLinkPresent=%s",
        tostring(self.pendingPost.itemGUID), tostring(self.pendingPost.itemID), self.pendingPost.quantity,
        tostring(self.pendingPost.craftingQuality), tostring(self.pendingPost.itemLink ~= nil))
    Debug("AHManager: pending post captured itemGUID=%s itemID=%s itemName=%s quantity=%d",
        tostring(self.pendingPost.itemGUID), tostring(self.pendingPost.itemID),
        tostring(self.pendingPost.itemName), self.pendingPost.quantity)
end

function PostingEventCapture:CapturePendingCommodityPost(itemID, duration, quantity, unitPrice)
    itemID = tonumber(itemID)
    local postedQuantity = tonumber(quantity) or 0
    if not itemID or itemID <= 0 or postedQuantity <= 0 then
        self.pendingPost = nil
        SessionLog("AHManager: pending post capture skipped source=commodity reason=missing_item_or_quantity itemID=%s quantity=%s",
            tostring(itemID), tostring(quantity))
        return
    end

    local identityService = GetIdentityService()
    local identity = identityService and identityService:FromItemID(itemID) or nil

    self.pendingPost = {
        ownerKey        = PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID or nil,
        itemGUID        = nil,
        itemID          = (identity and identity.itemID) or itemID,
        itemName        = (identity and identity.itemName) or "Unknown",
        itemLink        = (identity and identity.itemLink) or nil,
        configKey       = identity and identity.configKey or nil,
        quantity        = postedQuantity,
        itemQuality     = (identity and identity.itemQuality) or 0,
        craftingQuality = (identity and identity.craftingQuality) or 0,
        rarityQuality   = (identity and identity.rarityQuality) or nil,
        ilvl            = (identity and identity.effectiveIlvl) or nil,
        statFingerprint = (identity and identity.statFingerprint) or nil,
        itemStats       = (identity and identity.itemStats) or nil,
        isStackable     = true,
        buyout          = unitPrice or 0,
        bid             = 0,
        duration        = duration,
        capturedAt      = Now(),
    }
    SessionLog("AHManager: pending post captured source=commodity itemID=%s quantity=%d quality=%s itemLinkPresent=%s",
        tostring(self.pendingPost.itemID), self.pendingPost.quantity,
        tostring(self.pendingPost.craftingQuality), tostring(self.pendingPost.itemLink ~= nil))
end

function PostingEventCapture:HookPostMethods()
    if self.postHooksInstalled or not C_AuctionHouse or not hooksecurefunc then
        return
    end

    if C_AuctionHouse.PostItem then
        hooksecurefunc(C_AuctionHouse, "PostItem", function(itemLocation, duration, quantity, bid, buyout)
            self:CapturePendingPost(itemLocation, duration, quantity, bid, buyout)
        end)
    end

    if C_AuctionHouse.PostCommodity then
        hooksecurefunc(C_AuctionHouse, "PostCommodity", function(itemID, duration, quantity, unitPrice)
            self:CapturePendingCommodityPost(itemID, duration, quantity, unitPrice)
        end)
    end

    self.postHooksInstalled = true
end
