-- PocketCFO_AH/Posting/Execution/PostingExecution.lua
-- Owns post execution mechanics: bag item lookup, validation, API call, pending state,
-- and post confirmation/failure handling.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingExecution = PocketCFO_AH:NewModule("PostingExecution", "AceEvent-3.0")

-- Utilities duplicated from PostingController (originals remain there for queue/eval paths)

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local MAX_TRANSITIONS = 25

local attemptSequence = 0
local function NextAttemptID()
    attemptSequence = attemptSequence + 1
    return string.format("pe-%d-%d", attemptSequence, GetServerTime and GetServerTime() or time())
end

local function PositiveQuantity(value)
    value = math.floor(tonumber(value) or 0)
    if value > 0 then
        return value
    end
    return 0
end

local function PositiveInteger(value)
    value = tonumber(value)
    if value and value > 0 and value == math.floor(value) then
        return value
    end
    return nil
end

local function NormalizeDuration(value, fallback)
    local duration = tonumber(value) or tonumber(fallback) or 12
    if duration ~= 12 and duration ~= 24 and duration ~= 48 then
        duration = 12
    end
    return duration
end

local function GetGlobalDuration()
    local settings = PocketCFO_AH
        and PocketCFO_AH.db
        and PocketCFO_AH.db.global
        and PocketCFO_AH.db.global.postingSettings
        or nil
    return NormalizeDuration(settings and (settings.defaultDuration or settings.duration), 12)
end

local function RuleDuration(rule)
    return NormalizeDuration(rule and rule.duration, GetGlobalDuration())
end

local function AuctionDurationEnum(hours)
    hours = NormalizeDuration(hours, GetGlobalDuration())
    if _G.Enum and Enum.AuctionHouseDuration then
        if hours == 48 and Enum.AuctionHouseDuration.Long then
            return Enum.AuctionHouseDuration.Long
        end
        if hours == 24 and Enum.AuctionHouseDuration.Medium then
            return Enum.AuctionHouseDuration.Medium
        end
        if Enum.AuctionHouseDuration.Short then
            return Enum.AuctionHouseDuration.Short
        end
    end
    if hours == 48 then
        return 3
    end
    if hours == 24 then
        return 2
    end
    return 1
end

local function ApplyEvaluationAliases(row)
    local evaluation = row.evaluation or {}
    row.toPost = PositiveQuantity(evaluation.toPost)
    row.postingPrice = evaluation.price
    row.price = evaluation.price
    row.status = evaluation.status
    row.notes = evaluation.note
    row.note = evaluation.note
    row.selectable = false
end

local function IsDebugCaptureEnabled()
    local settings = PocketCFO_AH
        and PocketCFO_AH.db
        and PocketCFO_AH.db.global
        and PocketCFO_AH.db.global.postingSettings
        or nil
    return settings
        and settings.debug
        and settings.debug.captureCompetitionRows == true
end

-- Bag and item location helpers

local function GetLiveBagContainers()
    local containers = { BACKPACK_CONTAINER or 0 }
    for containerID = 1, (tonumber(NUM_BAG_SLOTS) or 4) do
        containers[#containers + 1] = containerID
    end
    containers[#containers + 1] = 5
    return containers
end

local function GetItemLinkFromLocation(itemLocation)
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

local function GetItemIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function BuildBagSlotCandidate(containerID, slot)
    if not C_Container or not C_Container.GetContainerItemInfo
    or not ItemLocation or not ItemLocation.CreateFromBagAndSlot then
        return nil
    end

    local okInfo, info = pcall(C_Container.GetContainerItemInfo, containerID, slot)
    if not okInfo or type(info) ~= "table" or not info.itemID then
        return nil
    end

    local itemLocation = ItemLocation:CreateFromBagAndSlot(containerID, slot)
    if itemLocation and itemLocation.IsValid and not itemLocation:IsValid() then
        return nil
    end

    return {
        itemID = tonumber(info.itemID),
        itemName = info.itemName,
        itemLink = info.hyperlink or GetItemLinkFromLocation(itemLocation),
        quantity = PositiveQuantity(info.stackCount),
        containerID = containerID,
        slot = slot,
        itemLocation = itemLocation,
        currentInfo = info,
    }
end

local function ExpectedItemID(row)
    return tonumber(row and row.candidate and row.candidate.itemID
        or row and row.target and (row.target.debugItemID or row.target.targetItemID or row.target.itemID)
        or row and row.itemID)
end

local function ExpectedItemLink(row)
    return row and (row.itemLink
        or row.candidate and row.candidate.itemLink
        or row.target and row.target.itemLink)
end

local function ExpectedConfigKey(row)
    return row and (row.configKey
        or row.target and row.target.configKey
        or row.target and row.target.identity and row.target.identity.configKey
        or row.candidate and row.candidate.configKey
        or row.candidate and row.candidate.identity and row.candidate.identity.configKey)
end

local function ResolveBagSlotIdentity(containerID, slot)
    local identityService = GetItemIdentityService()
    if not identityService then
        return nil, "identityServiceUnavailable"
    end
    if type(identityService.FromBagSlot) == "function" then
        return identityService:FromBagSlot(containerID, slot)
    end
    if type(identityService.Identify) == "function" then
        return identityService:Identify({
            evidenceType = "bagSlot",
            containerID = containerID,
            bag = containerID,
            slot = slot,
        })
    end
    return nil, "bagSlotIdentityResolverUnavailable"
end

local function RowMatchesBagSlot(row, bagSlot)
    if type(row) ~= "table" or type(bagSlot) ~= "table" then
        return false
    end

    local expectedConfigKey = ExpectedConfigKey(row)
    if expectedConfigKey and tostring(expectedConfigKey) ~= "" then
        local identity = ResolveBagSlotIdentity(bagSlot.containerID, bagSlot.slot)
        if identity and identity.configKey then
            return tostring(identity.configKey) == tostring(expectedConfigKey)
        end
    end

    local expectedItemID = ExpectedItemID(row)
    if expectedItemID and tonumber(bagSlot.itemID) ~= expectedItemID then
        return false
    end

    local expectedLink = ExpectedItemLink(row)
    if expectedLink and bagSlot.itemLink then
        return tostring(expectedLink) == tostring(bagSlot.itemLink)
    end

    return expectedItemID ~= nil
end

local function CurrentBagSlotInfo(bagSlot)
    if type(bagSlot) ~= "table" or not C_Container or not C_Container.GetContainerItemInfo then
        return nil
    end
    local ok, info = pcall(C_Container.GetContainerItemInfo, bagSlot.containerID, bagSlot.slot)
    if ok and type(info) == "table" then
        return info
    end
    return nil
end

local function BagSlotStillMatches(row, bagSlot)
    local info = CurrentBagSlotInfo(bagSlot)
    if type(info) ~= "table" then
        return false, "bag slot is empty or unreadable", info
    end

    local expectedItemID = ExpectedItemID(row)
    local currentItemID = tonumber(info.itemID)
    if expectedItemID and currentItemID and expectedItemID ~= currentItemID then
        return false, "bag slot itemID changed", info
    end

    local expectedLink = ExpectedItemLink(row)
    local currentLink = info.hyperlink
    if expectedLink and currentLink and tostring(expectedLink) ~= tostring(currentLink) then
        return false, "bag slot itemLink changed", info
    end

    return true, nil, info
end

local function ItemLocationExists(itemLocation)
    return itemLocation ~= nil
end

local function ItemLocationIsValid(itemLocation)
    if not itemLocation then
        return false
    end
    if itemLocation.IsValid then
        return itemLocation:IsValid() == true
    end
    return true
end

local function AuctionHouseOpenReady()
    local frame = _G.AuctionHouseFrame
    return C_AuctionHouse ~= nil
        and frame ~= nil
        and (not frame.IsShown or frame:IsShown())
end

-- Debug dump helpers

local function DebugString(value)
    local ok, text = pcall(tostring, value)
    if ok then
        return text
    end
    return "<tostring error:" .. tostring(text) .. ">"
end

local function SortedTableKeys(tbl)
    local keys = {}
    for key in pairs(tbl or {}) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(left, right)
        return DebugString(left) < DebugString(right)
    end)
    return keys
end

local function SafeObjectCall(object, methodName)
    if not object then
        return nil
    end
    local methodOk, method = pcall(function()
        return object[methodName]
    end)
    if not methodOk then
        return "ERROR: " .. DebugString(method)
    end
    if type(method) ~= "function" then
        return nil
    end
    local ok, value1, value2 = pcall(method, object)
    if ok then
        if value2 ~= nil then
            return DebugString(value1) .. "," .. DebugString(value2)
        end
        return value1
    end
    return "ERROR: " .. DebugString(value1)
end

local function DumpValueLines(lines, label, value, indent, seen)
    indent = indent or ""
    seen = seen or {}
    local valueType = type(value)

    if valueType ~= "table" then
        lines[#lines + 1] = indent .. DebugString(label) .. " = (" .. valueType .. ") " .. DebugString(value)
        return
    end

    if seen[value] then
        lines[#lines + 1] = indent .. DebugString(label) .. " = <cycle:" .. DebugString(value) .. ">"
        return
    end

    seen[value] = true
    lines[#lines + 1] = indent .. DebugString(label) .. " = {"
    for _, key in ipairs(SortedTableKeys(value)) do
        DumpValueLines(lines, "[" .. DebugString(key) .. "]", value[key], indent .. "  ", seen)
    end
    lines[#lines + 1] = indent .. "}"
end

local function DumpItemLocationLines(lines, label, itemLocation)
    lines[#lines + 1] = DebugString(label) .. " itemLocation:"
    lines[#lines + 1] = "  object=" .. DebugString(itemLocation)
    lines[#lines + 1] = "  type=" .. type(itemLocation)
    lines[#lines + 1] = "  exists=" .. DebugString(ItemLocationExists(itemLocation))
    lines[#lines + 1] = "  isValid=" .. DebugString(ItemLocationIsValid(itemLocation))
    lines[#lines + 1] = "  IsBagAndSlot=" .. DebugString(SafeObjectCall(itemLocation, "IsBagAndSlot"))
    lines[#lines + 1] = "  GetBagAndSlot=" .. DebugString(SafeObjectCall(itemLocation, "GetBagAndSlot"))
    lines[#lines + 1] = "  GetEquipmentSlot=" .. DebugString(SafeObjectCall(itemLocation, "GetEquipmentSlot"))
    lines[#lines + 1] = "  GetItemGUID=" .. DebugString(itemLocation and C_Item and C_Item.GetItemGUID and select(2, pcall(C_Item.GetItemGUID, itemLocation)) or nil)
    lines[#lines + 1] = "  GetItemLink=" .. DebugString(GetItemLinkFromLocation(itemLocation))
end

-- Methods

function PostingExecution:SetRowPostError(row, message)
    if type(row) ~= "table" then
        return
    end
    row.posting = row.posting or {}
    row.posting.pending = false
    row.evaluation = row.evaluation or {}
    row.evaluation.status = "Error"
    row.evaluation.shouldPost = false
    row.evaluation.note = tostring(message or "Posting error.")
    row.evaluation.toPost = 0
    row.status = row.evaluation.status
    row.toPost = 0
    row.note = row.evaluation.note
    row.notes = row.evaluation.note
    self.pendingPost = nil
    if self.controller then
        self.controller:NotifyQueueChanged("post-validation-failed")
    end
end

function PostingExecution:FindMatchingBagItem(row, requiredQuantity)
    requiredQuantity = PositiveQuantity(requiredQuantity)
    if requiredQuantity <= 0 then
        return nil, "missingQuantity"
    end
    if not C_Container or not C_Container.GetContainerNumSlots then
        return nil, "containerApiUnavailable"
    end

    for _, containerID in ipairs(GetLiveBagContainers()) do
        local okSlots, slots = pcall(C_Container.GetContainerNumSlots, containerID)
        if okSlots and slots and slots > 0 then
            for slot = 1, slots do
                local bagSlot = BuildBagSlotCandidate(containerID, slot)
                if bagSlot and bagSlot.quantity >= requiredQuantity and RowMatchesBagSlot(row, bagSlot) then
                    return bagSlot, nil
                end
            end
        end
    end

    return nil, "noMatchingBagItem"
end

function PostingExecution:LogPostAttemptDump(row, bagSlot, call)
    local lines = {
        "=== POST ATTEMPT START ===",
    }

    DumpValueLines(lines, "Selected Row", row)
    lines[#lines + 1] = "Posting Path:"
    lines[#lines + 1] = DebugString(call and call.functionName)
    DumpValueLines(lines, "Intermediate bagSlot", bagSlot)
    DumpValueLines(lines, "Intermediate currentBagInfo", call and call.currentBagInfo)
    DumpValueLines(lines, "Intermediate postReport", call and call.postReport)
    DumpItemLocationLines(lines, "Posting Arguments", call and call.itemLocation)
    DumpValueLines(lines, "Posting Arguments", call)
    lines[#lines + 1] = "=== POST ATTEMPT END ==="

    for _, line in ipairs(lines) do
        SessionLog("%s", line)
    end
end

function PostingExecution:BuildPostDebugReport(row, bagSlot, payload)
    payload = payload or {}
    local currentInfo = payload.currentBagInfo
    return {
        itemName = row and (row.itemName or row.item),
        itemID = row and row.candidate and row.candidate.itemID or row and row.target and (row.target.debugItemID or row.target.targetItemID),
        itemLink = row and (row.itemLink or row.candidate and row.candidate.itemLink),
        bag = bagSlot and bagSlot.containerID,
        slot = bagSlot and bagSlot.slot,
        itemLocationExists = ItemLocationExists(bagSlot and bagSlot.itemLocation),
        itemLocationIsValid = ItemLocationIsValid(bagSlot and bagSlot.itemLocation),
        postAPI = payload.postAPI,
        classificationSource = row and (row.classificationSource or row.target and row.target.classificationSource),
        quantity = payload.quantity,
        stackSize = currentInfo and currentInfo.stackCount or bagSlot and bagSlot.quantity,
        durationRaw = payload.durationRaw,
        durationResolved = payload.durationResolved,
        bidPrice = payload.bidPrice,
        buyoutPrice = payload.buyoutPrice,
        ahOpenReady = AuctionHouseOpenReady(),
        expectedItemID = row and row.candidate and row.candidate.itemID,
        currentItemID = currentInfo and currentInfo.itemID,
        expectedItemLink = row and (row.itemLink or row.candidate and row.candidate.itemLink),
        currentItemLink = currentInfo and currentInfo.hyperlink,
        bagSlotStillMatches = payload.bagSlotStillMatches,
        bagSlotMismatchReason = payload.bagSlotMismatchReason,
        validationStatus = payload.validationStatus,
        validationError = payload.validationError,
        apiError = payload.apiError,
        requestedAt = GetServerTime and GetServerTime() or time(),
    }
end

function PostingExecution:RecordPostDebugReport(report)
    self.postDebugReports = self.postDebugReports or {}
    self.postDebugReports[#self.postDebugReports + 1] = report
    while #self.postDebugReports > 20 do
        table.remove(self.postDebugReports, 1)
    end

    if IsDebugCaptureEnabled() then
        SessionLog("PostingController: pre-post payload item=%s itemID=%s bag=%s slot=%s postAPI=%s classification=%s qty=%s stackSize=%s durationRaw=%s duration=%s bid=%s buyout=%s itemLocationExists=%s itemLocationValid=%s ahOpenReady=%s bagSlotStillMatches=%s validation=%s error=%s",
            tostring(report and report.itemName),
            tostring(report and report.itemID),
            tostring(report and report.bag),
            tostring(report and report.slot),
            tostring(report and report.postAPI),
            tostring(report and report.classificationSource),
            tostring(report and report.quantity),
            tostring(report and report.stackSize),
            tostring(report and report.durationRaw),
            tostring(report and report.durationResolved),
            tostring(report and report.bidPrice),
            tostring(report and report.buyoutPrice),
            tostring(report and report.itemLocationExists),
            tostring(report and report.itemLocationIsValid),
            tostring(report and report.ahOpenReady),
            tostring(report and report.bagSlotStillMatches),
            tostring(report and report.validationStatus),
            tostring(report and report.validationError))
    end
end

function PostingExecution:GetPostDebugReports()
    return self.postDebugReports or {}
end

function PostingExecution:IsPostingInProgress()
    return self.pendingPost ~= nil
end

-- Bounded, session-only forensic history of posting transitions. Not persisted to
-- SavedVariables. Used by the stuck-post diagnostic capture, not by any decision logic.
function PostingExecution:RecordTransition(name, details)
    self.transitions = self.transitions or {}
    self.transitions[#self.transitions + 1] = {
        name      = name,
        timestamp = GetServerTime and GetServerTime() or time(),
        attemptID = details and details.attemptID or (self.pendingPost and self.pendingPost.attemptID),
        rowID     = details and details.rowID,
        details   = details,
    }
    while #self.transitions > MAX_TRANSITIONS do
        table.remove(self.transitions, 1)
    end
end

function PostingExecution:GetTransitions()
    return self.transitions or {}
end

-- Evidence describing a PostingExecution pending post, used to correlate it with
-- PostingEventCapture's independently-tracked pending post (see CorrelatesWithEvidence
-- in PostingEventCapture.lua).
function PostingExecution:BuildPendingPostEvidence(pending)
    pending = pending or self.pendingPost
    if not pending then
        return nil
    end
    return {
        attemptID   = pending.attemptID,
        configKey   = ExpectedConfigKey(pending.row),
        itemID      = ExpectedItemID(pending.row),
        itemGUID    = pending.itemGUID,
        quantity    = pending.quantity,
        unitPrice   = pending.unitPrice,
        requestedAt = pending.requestedAt,
    }
end

-- Read-only, best-effort snapshot for the stuck-post diagnostic capture. Only plain
-- values are included (no item locations, row tables, or other live objects) so it is
-- always safe to format and display.
function PostingExecution:BuildDiagnosticSnapshot()
    local pending = self.pendingPost
    local row = pending and pending.row or nil
    local now = GetServerTime and GetServerTime() or time()

    local rowSnapshot = nil
    if row then
        rowSnapshot = {
            rowID           = row.rowID,
            itemID          = ExpectedItemID(row),
            itemName        = row.itemName or row.item,
            configKey       = ExpectedConfigKey(row),
            postAPI         = row.postAPI or row.target and row.target.postAPI,
            status          = row.evaluation and row.evaluation.status or row.status,
            note            = row.evaluation and row.evaluation.note or row.note,
            pending         = row.posting and row.posting.pending,
            postedCount     = row.posting and row.posting.postedCount,
            remainingToPost = row.posting and row.posting.remainingToPost,
            toPost          = row.evaluation and row.evaluation.toPost or row.toPost,
            price           = row.evaluation and row.evaluation.price or row.price,
            duration        = row.duration,
        }
    end

    local pendingSnapshot = nil
    if pending then
        local rowStillTracked = nil
        if row and self.controller then
            rowStillTracked = false
            for _, existing in ipairs(self.controller.rows or {}) do
                if existing == row then
                    rowStillTracked = true
                    break
                end
            end
        end
        pendingSnapshot = {
            attemptID         = pending.attemptID,
            rowID             = pending.rowID,
            quantity          = pending.quantity,
            durationHours     = pending.durationHours,
            unitPrice         = pending.unitPrice,
            itemGUID          = pending.itemGUID,
            requestedAt       = pending.requestedAt,
            elapsedSeconds    = pending.requestedAt and (now - pending.requestedAt) or nil,
            retryCount        = pending.retryCount,
            bag               = pending.bagSlot and pending.bagSlot.containerID,
            slot              = pending.bagSlot and pending.bagSlot.slot,
            itemLocationValid = pending.bagSlot and ItemLocationIsValid(pending.bagSlot.itemLocation),
            rowStillTracked   = rowStillTracked,
        }
    end

    local eventCaptureExists = false
    local eventCaptureSnapshot = nil
    local eventCapture = PocketCFO_AH.PostingEventCapture
    if eventCapture and eventCapture.pendingPost then
        eventCaptureExists = true
        local captured = eventCapture.pendingPost
        eventCaptureSnapshot = {
            itemID    = captured.itemID,
            configKey = captured.configKey,
            quantity  = captured.quantity,
            price     = captured.buyout or captured.bid,
            timestamp = captured.capturedAt,
            attemptID = captured.attemptID,
            correlatesWithExecution = pending ~= nil
                and type(eventCapture.MatchesEvidence) == "function"
                and eventCapture:MatchesEvidence(self:BuildPendingPostEvidence(pending)) == true,
        }
    end

    return {
        row                       = rowSnapshot,
        pendingPostExists         = pending ~= nil,
        pendingPost               = pendingSnapshot,
        eventCapturePendingExists = eventCaptureExists,
        eventCapturePending       = eventCaptureSnapshot,
        transitions               = self:GetTransitions(),
    }
end

function PostingExecution:MarkPending(row, bagSlot, quantity, durationHours, unitPrice, retryCount, attemptID)
    local itemGUID = nil
    if bagSlot and bagSlot.itemLocation and C_Item and C_Item.GetItemGUID then
        local ok, guid = pcall(C_Item.GetItemGUID, bagSlot.itemLocation)
        itemGUID = ok and guid or nil
    end
    row.posting.pending = true
    self.pendingPost = {
        row           = row,
        rowID         = row.rowID,
        bagSlot       = bagSlot,
        quantity      = quantity,
        durationHours = durationHours,
        unitPrice     = unitPrice,
        itemGUID      = itemGUID,
        requestedAt   = GetServerTime and GetServerTime() or time(),
        retryCount    = tonumber(retryCount) or 0,
        attemptID     = attemptID,
    }
    if self.controller then
        self.controller:NotifyQueueChanged("post-pending")
    end
end

function PostingExecution:ClearPending()
    if self.pendingPost and self.pendingPost.row and self.pendingPost.row.posting then
        self.pendingPost.row.posting.pending = false
    end
    self.pendingPost = nil
end

-- Safe external entry point for workflow-level resets (e.g. PostingController:Refresh).
-- Unlike FinalizePostFailure, this does not assume a post actually failed at the AH server -
-- it only discards local pending-post bookkeeping so the UI is no longer stuck on "Posting...".
function PostingExecution:ResetPendingPost(reason)
    local hadPending = self.pendingPost ~= nil
    if hadPending then
        self:RecordTransition("pending-cleared", {
            attemptID = self.pendingPost.attemptID,
            rowID = self.pendingPost.rowID,
            reason = reason,
        })
    end
    self:ClearPending()
    if hadPending then
        SessionLog("PostingController: pending post state reset reason=%s", tostring(reason or "unknown"))
    end
end

-- Manual recovery entry point for a stuck pending post (UI -> Controller -> here).
-- Releases the local pending-post lock without assuming the server-side result: the
-- auction may have reached the AH even though PocketCFO never received confirmation.
-- Only the active posting attempt is touched - the evaluated queue, prices, quantities,
-- durations, and other rows are left exactly as they were.
function PostingExecution:UnstickPendingPost(reason)
    local pending = self.pendingPost
    if not pending then
        return false, "noPendingPost"
    end

    local row = pending.row
    local attemptID = pending.attemptID

    self:RecordTransition("manual-unstick-requested", {
        attemptID = attemptID,
        rowID = pending.rowID,
        reason = reason,
    })

    -- Only clear PostingEventCapture's separate pending-post evidence if it appears to
    -- belong to this same attempt; unrelated pending evidence (e.g. a TSM/Auctionator
    -- post) is left untouched.
    local eventCapture = PocketCFO_AH.PostingEventCapture
    if eventCapture and type(eventCapture.ClearPendingPost) == "function" then
        eventCapture:ClearPendingPost(reason or "manual-unstick", self:BuildPendingPostEvidence(pending))
    end

    self:ClearPending()

    if row then
        row.posting = row.posting or {}
        row.posting.pending = false
        row.evaluation = row.evaluation or {}

        local toPost = PositiveQuantity(row.evaluation.toPost)
        local postedCount = PositiveQuantity(row.posting.postedCount)
        row.posting.remainingToPost = math.max(0, toPost - postedCount)

        -- Restore to Ready only when the row still has remaining quantity, a prior
        -- evaluation decision to post, and was Ready immediately before the pending
        -- lock was set. We do not reevaluate the row merely because it was unstuck.
        local hasRemaining = row.posting.remainingToPost > 0
        local wasEligible = row.evaluation.shouldPost == true
        local priorStatusReady = row.evaluation.status == "Ready"

        row.evaluation.note = "Posting state manually reset; server result was not confirmed."
        if hasRemaining and wasEligible and priorStatusReady then
            row.evaluation.status = "Ready"
        end

        ApplyEvaluationAliases(row)
        row.status = row.evaluation.status
        row.note = row.evaluation.note
        row.notes = row.evaluation.note
    end

    self:RecordTransition("manual-unstick-completed", {
        attemptID = attemptID,
        rowID = pending.rowID,
        reason = reason,
    })

    SessionLog("PostingController: pending post manually unstuck rowID=%s item=%s attemptID=%s reason=%s",
        tostring(pending.rowID), tostring(row and row.itemName), tostring(attemptID), tostring(reason or "manual-unstick"))

    if self.controller then
        self.controller:NotifyQueueChanged("post-manually-reset")
    end

    return true
end

function PostingExecution:PostSelectedRow(row, retryCount)
    retryCount = tonumber(retryCount) or 0
    local controller = self.controller
    if not controller then
        return false, "controllerUnavailable"
    end
    if self:IsPostingInProgress() then
        return false, "postInProgress"
    end
    if controller.IsEvaluationInProgress and controller:IsEvaluationInProgress() then
        return false, "evaluationInProgress"
    end
    if not controller:CanPostRow(row) then
        self:SetRowPostError(row, "Error: selected row is not ready to post.")
        return false, "rowNotReady"
    end
    if not C_AuctionHouse then
        self:SetRowPostError(row, "Error: Auction House API is unavailable.")
        return false, "auctionHouseUnavailable"
    end

    local attemptID = NextAttemptID()
    self:RecordTransition("post-requested", { attemptID = attemptID, rowID = row.rowID, retryCount = retryCount })

    local function recordEarlyPostFailure(message, code, payload)
        payload = payload or {}
        payload.postAPI = payload.postAPI or row and (row.postAPI or row.target and row.target.postAPI) or "PostItem"
        payload.validationStatus = "failed"
        payload.validationError = message
        self:RecordPostDebugReport(self:BuildPostDebugReport(row, nil, payload))
        self:SetRowPostError(row, message)
        return false, code
    end

    local rawPrice = tonumber(row.evaluation.price)
    local price = PositiveInteger(rawPrice)
    if not price then
        return recordEarlyPostFailure("Error: posting price is missing or invalid.", "missingPrice", {
            bidPrice = rawPrice,
            buyoutPrice = rawPrice,
        })
    end

    local postedCount = PositiveQuantity(row.posting.postedCount)
    local toPost = PositiveQuantity(row.evaluation.toPost)
    local remaining = math.max(0, toPost - postedCount)
    if remaining <= 0 then
        return recordEarlyPostFailure("Error: no remaining quantity to post.", "nothingRemaining", {
            bidPrice = price,
            buyoutPrice = price,
            quantity = remaining,
        })
    end

    local quantity = row.isStackable and remaining or 1
    if quantity <= 0 then
        return recordEarlyPostFailure("Error: posting quantity is missing or invalid.", "missingQuantity", {
            bidPrice = price,
            buyoutPrice = price,
            quantity = quantity,
        })
    end

    local bagSlot, findErr = self:FindMatchingBagItem(row, quantity)
    if not bagSlot then
        return recordEarlyPostFailure("Error: matching bag item was not found.", findErr or "noMatchingBagItem", {
            bidPrice = price,
            buyoutPrice = price,
            quantity = quantity,
        })
    end
    self:RecordTransition("bag-item-resolved", {
        attemptID = attemptID, rowID = row.rowID, bag = bagSlot.containerID, slot = bagSlot.slot,
    })

    local durationHours = RuleDuration(row.resolvedRule)
    local duration = AuctionDurationEnum(durationHours)
    local postAPI = row.postAPI or row.target and row.target.postAPI or "PostItem"
    local bidPrice = nil
    local buyoutPrice = price
    local bagSlotMatches, bagSlotMismatchReason, currentInfo = BagSlotStillMatches(row, bagSlot)
    local postReport = self:BuildPostDebugReport(row, bagSlot, {
        postAPI = postAPI,
        quantity = quantity,
        durationRaw = row.resolvedRule and row.resolvedRule.duration or durationHours,
        durationResolved = duration,
        bidPrice = bidPrice,
        buyoutPrice = buyoutPrice,
        currentBagInfo = currentInfo,
        bagSlotStillMatches = bagSlotMatches,
        bagSlotMismatchReason = bagSlotMismatchReason,
        validationStatus = "pending",
    })

    local function failPostValidation(message, code)
        postReport.validationStatus = "failed"
        postReport.validationError = message
        self:RecordPostDebugReport(postReport)
        self:SetRowPostError(row, message)
        return false, code
    end

    if not postReport.itemLocationExists or not postReport.itemLocationIsValid then
        return failPostValidation("Error: item location is invalid.", "invalidItemLocation")
    end

    if not bagSlotMatches then
        return failPostValidation("Error: selected bag slot no longer contains the expected item.", "staleBagSlot")
    end

    if not duration then
        return failPostValidation("Error: posting duration is missing or invalid.", "missingDuration")
    end

    if not buyoutPrice or buyoutPrice <= 0 or buyoutPrice ~= math.floor(buyoutPrice) then
        return failPostValidation("Error: posting buyout price is missing or invalid.", "invalidBuyoutPrice")
    end

    if postAPI == "PostItem" and bidPrice ~= nil and (bidPrice <= 0 or bidPrice ~= math.floor(bidPrice)) then
        return failPostValidation("Error: posting bid price is missing or invalid.", "invalidBidPrice")
    end

    local stackSize = PositiveQuantity(bagSlot.quantity)
    if quantity <= 0 or quantity ~= math.floor(quantity) or quantity > stackSize then
        return failPostValidation("Error: posting quantity is invalid for the selected bag stack.", "invalidQuantity")
    end

    if postAPI == "PostCommodity" and not C_AuctionHouse.PostCommodity then
        return failPostValidation("Error: commodity posting API is unavailable.", "postApiUnavailable")
    end

    if postAPI ~= "PostCommodity" and not C_AuctionHouse.PostItem then
        return failPostValidation("Error: item posting API is unavailable.", "postApiUnavailable")
    end

    postReport.validationStatus = "passed"
    self:RecordPostDebugReport(postReport)

    local ok, err
    local call = {
        functionName = postAPI == "PostCommodity" and "C_AuctionHouse.PostCommodity" or "C_AuctionHouse.PostItem",
        postAPI = postAPI,
        itemLocation = bagSlot.itemLocation,
        bag = bagSlot.containerID,
        slot = bagSlot.slot,
        duration = duration,
        durationHours = durationHours,
        quantity = quantity,
        bidPrice = bidPrice,
        buyoutPrice = buyoutPrice,
        unitPrice = postAPI == "PostCommodity" and buyoutPrice or nil,
        currentBagInfo = currentInfo,
        postReport = postReport,
        positionalArguments = postAPI == "PostCommodity"
            and {
                [1] = bagSlot.itemLocation,
                [2] = duration,
                [3] = quantity,
                [4] = buyoutPrice,
            }
            or {
                [1] = bagSlot.itemLocation,
                [2] = duration,
                [3] = quantity,
                [4] = bidPrice,
                [5] = buyoutPrice,
            },
    }
    self:LogPostAttemptDump(row, bagSlot, call)
    self:RecordTransition("post-api-called", {
        attemptID = attemptID, rowID = row.rowID, postAPI = postAPI, quantity = quantity, price = buyoutPrice,
    })

    if postAPI == "PostCommodity" and C_AuctionHouse.PostCommodity then
        ok, err = pcall(C_AuctionHouse.PostCommodity, bagSlot.itemLocation, duration, quantity, buyoutPrice)
    elseif C_AuctionHouse.PostItem then
        ok, err = pcall(C_AuctionHouse.PostItem, bagSlot.itemLocation, duration, quantity, bidPrice, buyoutPrice)
    else
        self:SetRowPostError(row, "Error: posting API is unavailable.")
        return false, "postApiUnavailable"
    end

    self:RecordTransition("post-api-returned", { attemptID = attemptID, rowID = row.rowID, ok = ok })

    if not ok then
        postReport.apiError = err
        self:SetRowPostError(row, "Error: post request failed.")
        SessionLog("PostingController: post request failed rowID=%s item=%s err=%s",
            tostring(row.rowID), tostring(row.itemName), tostring(err))
        return false, err or "postFailed"
    end

    -- hooksecurefunc-based PostingEventCapture fires synchronously inside the pcall above,
    -- so by this point its pendingPost (if any) is usually the one just captured for this
    -- same API call. Only stamp the shared attemptID when the capture is very recent and
    -- (if known) matches our itemID - this avoids mis-attributing a stale, unrelated
    -- pending post (e.g. left behind by TSM/Auctionator) to our attempt.
    local eventCapture = PocketCFO_AH.PostingEventCapture
    if eventCapture and eventCapture.pendingPost and not eventCapture.pendingPost.attemptID then
        local captured = eventCapture.pendingPost
        local nowTime = GetServerTime and GetServerTime() or time()
        local capturedRecently = type(captured.capturedAt) == "number" and math.abs(nowTime - captured.capturedAt) <= 2
        local expectedItemID = ExpectedItemID(row)
        local itemMatches = not expectedItemID or not captured.itemID or tonumber(captured.itemID) == expectedItemID
        if capturedRecently and itemMatches then
            captured.attemptID = attemptID
        end
    end

    self:MarkPending(row, bagSlot, quantity, durationHours, buyoutPrice, retryCount, attemptID)
    self:RecordTransition("pending-marked", { attemptID = attemptID, rowID = row.rowID })
    SessionLog("PostingController: post requested rowID=%s item=%s stackable=%s quantity=%d price=%s durationHours=%s durationEnum=%s retryCount=%d",
        tostring(row.rowID), tostring(row.itemName), tostring(row.isStackable), quantity, tostring(price), tostring(durationHours), tostring(duration), retryCount)
    return true
end

function PostingExecution:ApplyPostConfirmation(auctionID)
    local pending = self.pendingPost
    if not pending or not pending.row or not pending.row.posting then
        return
    end

    self:RecordTransition("auction-created-received", {
        attemptID = pending.attemptID, rowID = pending.rowID, auctionID = auctionID,
    })

    local row = pending.row
    local posting = row.posting
    local toPost = PositiveQuantity(row.evaluation and row.evaluation.toPost)
    posting.postedCount = PositiveQuantity(posting.postedCount) + PositiveQuantity(pending.quantity)
    if posting.postedCount > toPost then
        posting.postedCount = toPost
    end
    posting.remainingToPost = math.max(0, toPost - posting.postedCount)
    posting.pending = false
    self.pendingPost = nil

    if posting.remainingToPost > 0 then
        row.evaluation.status = "Ready"
        row.evaluation.note = string.format("%d of %d posted.", posting.postedCount, toPost)
    else
        row.evaluation.status = "Posted"
        row.evaluation.shouldPost = false
        row.evaluation.note = "Posted"
    end

    ApplyEvaluationAliases(row)
    row.status = row.evaluation.status
    row.note = row.evaluation.note
    row.notes = row.evaluation.note
    row.toPost = toPost

    if self.controller then
        self.controller.lastConfirmedRowID = row.rowID or row.itemKey or row.itemName
        local evalService = PocketCFO_AH:GetModule("PostingEvaluationPipeline", true)
        if evalService and evalService.SortRows then
            evalService:SortRows(self.controller.rows)
        end
        self.controller:NotifyQueueChanged("post-confirmed")
    end
    SessionLog("PostingController: post confirmed rowID=%s item=%s posted=%d remaining=%d",
        tostring(row.rowID), tostring(row.itemName), posting.postedCount, posting.remainingToPost)

    -- Record in AHListingService.
    -- Unverified in-game: AUCTION_HOUSE_AUCTION_CREATED is documented by Blizzard to fire
    -- with auctionID as the first argument, but this has not been confirmed in our testing.
    -- Session log in PostingLifecycleController:HandleAuctionCreated will show the value.
    -- If auctionID is nil here, RecordPostedAuction is skipped and no listing is created
    -- at post time. The listing will be discovered on the next OWNED_AUCTIONS_UPDATED scan
    -- via BackfillMissingOwnedAuctions, but will lack postedAt and durationHours.
    if auctionID then
        local ahListing = PocketCFO_AH:GetModule("AHListingService", true)
        if ahListing and ahListing.RecordPostedAuction then
            local ownerKey = PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.characterGUID or nil
            ahListing:RecordPostedAuction({
                auctionID     = auctionID,
                itemID        = row.candidate and row.candidate.itemID
                             or row.target and row.target.debugItemID,
                itemName      = row.itemName,
                itemLink      = row.itemLink or (row.candidate and row.candidate.itemLink),
                itemGUID      = pending.itemGUID,
                configKey     = ExpectedConfigKey(row),
                quantity      = pending.quantity,
                unitPrice     = pending.unitPrice,
                durationHours = pending.durationHours,
                ownerKey      = ownerKey,
                postedAt      = pending.requestedAt,
            })
        end
    end
end

-- Finalizes a post attempt as failed: clears pending state, marks the row Error,
-- sorts, and notifies so the UI unlocks Post Selected without requiring a refresh.
function PostingExecution:FinalizePostFailure(row, message)
    self:ClearPending()
    if row then
        self:SetRowPostError(row, message or "Error: Auction House rejected this post request.")
    end

    if self.controller then
        local evalService = PocketCFO_AH:GetModule("PostingEvaluationPipeline", true)
        if evalService and evalService.SortRows then
            evalService:SortRows(self.controller.rows)
        end
        self.controller:NotifyQueueChanged("post-failed")
    end
    SessionLog("PostingController: post failed rowID=%s item=%s postedCountUnchanged=%s",
        tostring(row and row.rowID), tostring(row and row.itemName), tostring(row and row.posting and row.posting.postedCount))
end

function PostingExecution:AUCTION_HOUSE_AUCTION_CREATED(_, auctionID)
    -- Unverified in-game: Blizzard documents auctionID as the first arg of this event.
    -- See also AHManager:OnAuctionCreated and PostingLifecycleController:HandleAuctionCreated,
    -- which share the same event and log the received auctionID value.
    self:ApplyPostConfirmation(auctionID)
end

-- First AUCTION_HOUSE_POST_ERROR for a given pending post triggers one automatic
-- repost of the same row. A second error for that same attempt finalizes it as failed.
function PostingExecution:AUCTION_HOUSE_POST_ERROR()
    local pending = self.pendingPost
    if not pending or not pending.row then
        return
    end

    self:RecordTransition("post-error-received", { attemptID = pending.attemptID, rowID = pending.rowID })

    local row = pending.row
    local retryCount = tonumber(pending.retryCount) or 0
    self:ClearPending()

    if retryCount < 1 then
        row.evaluation = row.evaluation or {}
        row.evaluation.note = "Internal auction error. Retrying once..."
        row.note = row.evaluation.note
        row.notes = row.evaluation.note
        if self.controller then
            self.controller:NotifyQueueChanged("post-retry")
        end
        SessionLog("PostingController: post error retrying rowID=%s item=%s", tostring(row.rowID), tostring(row.itemName))

        self:PostSelectedRow(row, retryCount + 1)
        return
    end

    self:FinalizePostFailure(row, "Internal auction error. Not posted.")
end

function PostingExecution:OnEnable()
    self.controller = PocketCFO_AH:GetModule("PostingController", true)
    self:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
    self:RegisterEvent("AUCTION_HOUSE_POST_ERROR")
end
