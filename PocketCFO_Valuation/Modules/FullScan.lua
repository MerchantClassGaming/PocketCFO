-- PocketCFO_Valuation/Modules/FullScan.lua
-- Manual replicate-scan pricing coordinator. Does not store auction rows.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local FullScan = PocketCFO_Valuation:NewModule("FullScan", "AceEvent-3.0")

local PROCESS_CHUNK_SIZE = 200
local FINALIZE_CHUNK_SIZE = 100
local YIELD_SECONDS = 0.01
local WAIT_TIMEOUT_SECONDS = 60
local FULL_SCAN_COOLDOWN_SECONDS = 15 * 60
local EXPECTED_SCAN_SECONDS = 2 * 60

local SCAN_EVENTS = {
    "REPLICATE_ITEM_LIST_UPDATE",
    "AUCTION_HOUSE_CLOSED",
}

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function Clock()
    if GetTime then
        return GetTime()
    end
    return Now()
end

local function PackCall(fn, ...)
    if type(fn) ~= "function" then
        return false, { "unavailable" }
    end

    local returns = { pcall(fn, ...) }
    local ok = table.remove(returns, 1)
    if not ok then
        return false, returns
    end
    return true, returns
end

local function PackPCall(fn, ...)
    if type(fn) ~= "function" then
        return false, { "unavailable" }
    end

    local returns = { pcall(fn, ...) }
    local ok = table.remove(returns, 1)
    return ok == true, returns
end

local function GetItemIDFromLink(itemLink)
    if not itemLink then
        return nil
    end
    if GetItemInfoFromHyperlink then
        local ok, itemID = pcall(GetItemInfoFromHyperlink, itemLink)
        if ok and itemID then
            return tonumber(itemID)
        end
    end
    return tonumber(tostring(itemLink):match("item:(%d+)"))
end

local function GetReplicateInfo(index)
    local ok, returns = PackCall(C_AuctionHouse and C_AuctionHouse.GetReplicateItemInfo, index)
    if not ok then
        return nil
    end
    if type(returns[1]) == "table" then
        return returns[1]
    end

    return {
        itemName = returns[1],
        quantity = returns[3],
        itemRarity = returns[4],
        itemLevel = returns[6],
        minBid = returns[8],
        minIncrement = returns[9],
        buyoutPrice = returns[10],
        bidAmount = returns[11],
        owner = returns[13],
        saleStatus = returns[15],
        itemID = returns[17],
        hasAllInfo = returns[18],
    }
end

local function GetReplicateLink(index)
    local ok, returns = PackCall(C_AuctionHouse and C_AuctionHouse.GetReplicateItemLink, index)
    if ok then
        return returns[1]
    end
    return nil
end

local function GetQuantity(row)
    local quantity = tonumber(row and (row.quantity or row.count or row.stackSize or row.totalQuantity)) or 1
    if quantity < 1 then
        return 0
    end
    return math.floor(quantity)
end

local function GetBuyout(row)
    return tonumber(row and (row.buyoutAmount or row.buyoutPrice or row.buyout or row.price or row.minPrice))
end

local function BuildIdentity(row, itemLink)
    local identity = PocketCFO_Valuation:GetModule("PricingIdentity", true)
    if not identity then
        return nil
    end

    if itemLink then
        return identity:BuildFromItemLink(itemLink)
    end

    local itemID = tonumber(row and (row.itemID or row.itemId or row.id)) or GetItemIDFromLink(itemLink)
    if itemID then
        return identity:BuildFromItemID(itemID)
    end
    return nil
end

local function AddObservation(buckets, identity, row)
    if not identity or not identity.marketKey then
        return false, false
    end

    local buyout = GetBuyout(row)
    local quantity = GetQuantity(row)
    if not buyout or buyout <= 0 or quantity <= 0 then
        return false, false
    end

    local marketKey = identity.marketKey
    local bucket = buckets[marketKey]
    local created = false
    if not bucket then
        bucket = {
            identity = identity,
            observations = {},
            isStackable = identity.isStackable == true,
        }
        buckets[marketKey] = bucket
        created = true
    end

    if bucket.isStackable then
        bucket.observations[#bucket.observations + 1] = {
            quantity = quantity,
            unitPrice = buyout / quantity,
        }
    else
        bucket.observations[#bucket.observations + 1] = {
            quantity = 1,
            buyout = buyout,
            buyoutAmount = buyout,
        }
    end

    return true, created
end

-- Settings from matching ValuationRules "market" rules for this market,
-- or nil when none match (then pricing is unchanged from before rules).
local function GetMarketOptions(bucket)
    local rules = PocketCFO_Valuation:GetModule("ValuationRules", true)
    if not rules or not bucket then
        return nil
    end
    local ok, params, ruleIDs = pcall(rules.GetMarketParams, rules, bucket.identity)
    if not ok or not params then
        return nil
    end
    return { market = params, marketRuleIDs = ruleIDs }
end

local function BuildPricingRow(bucket, value, depthUsed, diagnostics)
    local identity = bucket and bucket.identity or {}
    return {
        itemID = identity.itemID,
        itemName = identity.itemName,
        qualityTier = identity.qualityTier,
        itemLevel = identity.itemLevel,
        statFingerprint = identity.statFingerprint,
        depthUsed = depthUsed,
        valuationDiagnostics = diagnostics,
        value = value,
        freshness = "fresh",
        timestamp = Now(),
        source = "full-scan",
    }
end

function FullScan:ResetStatus()
    self:ClearRuntimeState()
    self.status = {
        state = "idle",
        running = false,
        rowsProcessed = 0,
        rowsTotal = 0,
        marketsBuilt = 0,
        marketsTotal = 0,
        marketsPriced = 0,
        startedAt = nil,
        startedClock = nil,
        completedAt = nil,
        completedClock = nil,
        totalElapsedSeconds = nil,
        lastError = nil,
        rejectReason = nil,
        waitingStartedAt = nil,
        waitingStartedClock = nil,
        timeoutSeconds = WAIT_TIMEOUT_SECONDS,
        expectedSeconds = EXPECTED_SCAN_SECONDS,
        cooldownSeconds = FULL_SCAN_COOLDOWN_SECONDS,
        cooldownUntil = nil,
        cooldownRemaining = nil,
        lastEventAt = nil,
        lastEventName = nil,
        replicateItemsExists = C_AuctionHouse and type(C_AuctionHouse.ReplicateItems) == "function" or false,
        replicateCallOk = nil,
        replicateCallReturned = false,
        replicateReturn1 = nil,
        replicateReturn2 = nil,
        replicateReturns = nil,
        getNumReplicateItemsExists = C_AuctionHouse and type(C_AuctionHouse.GetNumReplicateItems) == "function" or false,
        numReplicateItemsImmediately = nil,
        numReplicateItemsImmediateOk = nil,
        eventLog = {},
    }
    self.buckets = nil
    self.nextIndex = nil
    self.deferredIndexes = nil
    self.finalizeKeys = nil
    self.finalizeIndex = nil
    self.identityMemo = nil
    self.scanToken = nil
end

function FullScan:RegisterScanEvents()
    if not self.scanFrame then return end
    for _, eventName in ipairs(SCAN_EVENTS) do
        self.scanFrame:RegisterEvent(eventName)
    end
end

function FullScan:UnregisterScanEvents()
    if not self.scanFrame then return end
    for _, eventName in ipairs(SCAN_EVENTS) do
        self.scanFrame:UnregisterEvent(eventName)
    end
end

function FullScan:CancelWaitTimeout()
    if self.waitTimeoutTimer and self.waitTimeoutTimer.Cancel then
        self.waitTimeoutTimer:Cancel()
    end
    self.waitTimeoutTimer = nil
end

function FullScan:ClearRuntimeState()
    self:CancelWaitTimeout()
    self.buckets = nil
    self.nextIndex = nil
    self.deferredIndexes = nil
    self.finalizeKeys = nil
    self.finalizeIndex = nil
    self.identityMemo = nil
    self.scanToken = nil
end

function FullScan:GetReplicateRowCount()
    local ok, returns = PackCall(C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems)
    if not ok then
        return nil, returns and returns[1]
    end
    return tonumber(returns and returns[1]) or 0
end

function FullScan:PassiveReplicateProbe()
    local rowCount = 0
    if C_AuctionHouse and type(C_AuctionHouse.GetNumReplicateItems) == "function" then
        local ok, returns = PackCall(C_AuctionHouse.GetNumReplicateItems)
        rowCount = ok and tonumber(returns and returns[1]) or 0
    end
    local running = self.status and self.status.running == true
    PocketCFO:Debug("FullScan:PassiveProbe REPLICATE_ITEM_LIST_UPDATE t=%d rows=%d scanRunning=%s",
        GetServerTime(), rowCount, tostring(running))
end

function FullScan:RegisterPassiveProbe()
    self:RegisterEvent("REPLICATE_ITEM_LIST_UPDATE", "PassiveReplicateProbe")
end

function FullScan:UnregisterPassiveProbe()
    self:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
end

function FullScan:RecordScanEvent(eventName)
    if not self.status then
        self:ResetStatus()
    end

    self.status.lastEventName = tostring(eventName or "unknown")
    self.status.lastEventAt = Now()
    self.status.eventLog = self.status.eventLog or {}
    self.status.eventLog[#self.status.eventLog + 1] = {
        eventName = self.status.lastEventName,
        eventAt = self.status.lastEventAt,
    }
end

function FullScan:Fail(message)
    if not self.status then
        self:ResetStatus()
    end
    self.status.running = false
    self.status.state = "failed"
    self.status.completedAt = Now()
    self.status.completedClock = Clock()
    if self.status.startedClock then
        self.status.totalElapsedSeconds = math.max(0, self.status.completedClock - self.status.startedClock)
    end
    self.status.lastError = tostring(message or "Full scan failed")
    self:ClearRuntimeState()
    self:UnregisterScanEvents()
    self:RegisterPassiveProbe()
    return false, self.status.lastError
end

function FullScan:ScheduleNext(methodName)
    local token = self.scanToken
    if C_Timer and C_Timer.After then
        C_Timer.After(YIELD_SECONDS, function()
            if self.status and self.status.running and self.scanToken == token then
                self[methodName](self)
            end
        end)
    else
        self[methodName](self)
    end
end

function FullScan:StartFinalizing()
    self.status.state = "building"
    self.finalizeKeys = {}
    for marketKey in pairs(self.buckets or {}) do
        self.finalizeKeys[#self.finalizeKeys + 1] = marketKey
    end
    table.sort(self.finalizeKeys)
    self.status.marketsBuilt = #self.finalizeKeys
    self.status.marketsTotal = #self.finalizeKeys
    self.finalizeIndex = 1
    self:StartCalculatingPrices()
end

function FullScan:StartCalculatingPrices()
    if not self.status or not self.status.running then
        return
    end

    self.status.state = "finalizing"
    self:ProcessFinalizeChunk()
end

function FullScan:ProcessFinalizeChunk()
    if not self.status or not self.status.running then
        return
    end

    local cache = PocketCFO_Valuation:GetModule("PricingCache", true)
    local valuation = PocketCFO_Valuation:GetModule("PricingValuation", true)
    if not cache or not valuation then
        self:Fail("Pricing modules unavailable")
        return
    end

    local keys = self.finalizeKeys or {}
    local startIndex = self.finalizeIndex or 1
    local stopIndex = math.min(startIndex + FINALIZE_CHUNK_SIZE - 1, #keys)

    for index = startIndex, stopIndex do
        local marketKey = keys[index]
        local bucket = self.buckets and self.buckets[marketKey]
        local value, depthUsed, diagnostics
        if bucket and bucket.isStackable then
            value, depthUsed, diagnostics = valuation:CalculateStackableValue(bucket.observations, GetMarketOptions(bucket))
        elseif bucket then
            value, depthUsed = valuation:CalculateNonStackableValue(bucket.observations)
        end

        if value and cache:SetPricingRow(marketKey, BuildPricingRow(bucket, value, depthUsed, diagnostics)) then
            self.status.marketsPriced = (tonumber(self.status.marketsPriced) or 0) + 1
        end
    end

    self.finalizeIndex = stopIndex + 1
    if self.finalizeIndex <= #keys then
        self:ScheduleNext("ProcessFinalizeChunk")
        return
    end

    self.status.running = false
    self.status.state = "complete"
    self.status.completedAt = Now()
    self.status.completedClock = Clock()
    if self.status.startedClock then
        self.status.totalElapsedSeconds = math.max(0, self.status.completedClock - self.status.startedClock)
    end
    if PocketCFO_Valuation.db and PocketCFO_Valuation.db.global then
        PocketCFO_Valuation.db.global.timeOfLastReplicateScan = self.status.startedAt or self.status.completedAt
    end
    self.status.lastError = nil
    self.status.rejectReason = nil
    self:ClearRuntimeState()
    self:UnregisterScanEvents()
    self:RegisterPassiveProbe()

    -- Fresh prices and names: refresh which items are quality siblings
    -- (QualitySiblings.lua, used by the quality-sibling-cap rule).
    local siblings = PocketCFO_Valuation:GetModule("QualitySiblings", true)
    if siblings and siblings.Rebuild then
        siblings:Rebuild()
    end
end

function FullScan:ProcessChunk()
    if not self.status.running then
        return
    end

    local total = self.status.rowsTotal or 0
    if (self.nextIndex or 0) < total then
        self.status.state = "processing"
    else
        self.status.state = "building"
    end

    -- Process the next chunk of regular (0-based) indexes
    if (self.nextIndex or 0) < total then
        local startIndex = self.nextIndex or 0
        local stopIndex = math.min(startIndex + PROCESS_CHUNK_SIZE - 1, total - 1)
        for index = startIndex, stopIndex do
            local row = GetReplicateInfo(index)
            local hasAllInfo = row and row.hasAllInfo
            if hasAllInfo == false then
                local itemID = row and tonumber(row.itemID or row.itemId or row.id)
                if itemID and C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
                    C_Item.RequestLoadItemDataByID(itemID)
                end
                self.deferredIndexes[#self.deferredIndexes + 1] = index
            else
                local itemLink = GetReplicateLink(index)
                local memoKey = itemLink or ("itemID:" .. tostring(row and (row.itemID or row.itemId or row.id) or ""))
                local identity = self.identityMemo and self.identityMemo[memoKey]
                if identity == nil then
                    identity = BuildIdentity(row, itemLink) or false
                    if self.identityMemo and memoKey ~= "" then
                        self.identityMemo[memoKey] = identity
                    end
                end
                if identity == false then
                    identity = nil
                end
                local _, bucketCreated = AddObservation(self.buckets, identity, row)
                if bucketCreated then
                    self.status.marketsBuilt = (tonumber(self.status.marketsBuilt) or 0) + 1
                end
            end
            self.status.rowsProcessed = index + 1
        end
        self.nextIndex = stopIndex + 1
        if self.nextIndex >= total then
            self.status.state = "building"
        end
        self:ScheduleNext("ProcessChunk")
        return
    end

    -- All regular indexes done; retry deferred indexes
    if #(self.deferredIndexes or {}) == 0 then
        self:StartFinalizing()
        return
    end

    local retry = self.deferredIndexes
    self.deferredIndexes = {}
    local stopAt = math.min(#retry, PROCESS_CHUNK_SIZE)
    for i = 1, stopAt do
        local index = retry[i]
        local row = GetReplicateInfo(index)
        local hasAllInfo = row and row.hasAllInfo
        if hasAllInfo == false then
            local itemID = row and tonumber(row.itemID or row.itemId or row.id)
            if itemID and C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
                C_Item.RequestLoadItemDataByID(itemID)
            end
            self.deferredIndexes[#self.deferredIndexes + 1] = index
        else
            local itemLink = GetReplicateLink(index)
            local memoKey = itemLink or ("itemID:" .. tostring(row and (row.itemID or row.itemId or row.id) or ""))
            local identity = self.identityMemo and self.identityMemo[memoKey]
            if identity == nil then
                identity = BuildIdentity(row, itemLink) or false
                if self.identityMemo and memoKey ~= "" then
                    self.identityMemo[memoKey] = identity
                end
            end
            if identity == false then
                identity = nil
            end
            local _, bucketCreated = AddObservation(self.buckets, identity, row)
            if bucketCreated then
                self.status.marketsBuilt = (tonumber(self.status.marketsBuilt) or 0) + 1
            end
        end
    end
    -- Items beyond this chunk's capacity carry over to the next pass
    for i = stopAt + 1, #retry do
        self.deferredIndexes[#self.deferredIndexes + 1] = retry[i]
    end

    self:ScheduleNext("ProcessChunk")
end

function FullScan:StartProcessingReplicateRows(rowCount)
    if not self.status or not self.status.running then
        return
    end

    self.status.rowsTotal = tonumber(rowCount) or 0
    self.status.rowsProcessed = 0
    self.status.state = "processing"
    self:CancelWaitTimeout()
    self.nextIndex = 0
    self.deferredIndexes = {}
    if self.status.rowsTotal <= 0 then
        self:StartFinalizing()
        return
    end
    self:ProcessChunk()
end

function FullScan:StartWaitTimeout(token)
    if not self.status or not self.status.running or self.scanToken ~= token then
        return
    end

    self:CancelWaitTimeout()
    if C_Timer and C_Timer.NewTimer then
        self.waitTimeoutTimer = C_Timer.NewTimer(WAIT_TIMEOUT_SECONDS, function()
            if self.status and self.status.running and self.scanToken == token and not self.nextIndex then
                self:Fail("Timed out waiting for Auction House replicate update")
            end
        end)
    elseif C_Timer and C_Timer.After then
        C_Timer.After(WAIT_TIMEOUT_SECONDS, function()
            if self.status and self.status.running and self.scanToken == token and not self.nextIndex then
                self:Fail("Timed out waiting for Auction House replicate update")
            end
        end)
    end
end

function FullScan:StartWaitingForReplicateRows()
    if not self.status or not self.status.running then
        return
    end

    self.status.state = "waiting"
    self.status.waitingStartedAt = Now()
    self.status.waitingStartedClock = Clock()
    self.status.timeoutSeconds = WAIT_TIMEOUT_SECONDS
    self:StartWaitTimeout(self.scanToken)
end

function FullScan:RequestReplicateScan(token)
    if not self.status or not self.status.running or self.scanToken ~= token then
        return false
    end

    local replicateItems = C_AuctionHouse and C_AuctionHouse.ReplicateItems
    local getNumReplicateItems = C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems
    self.status.state = "requesting"
    self.status.cooldownUntil = nil
    self:CancelWaitTimeout()

    local ok, replicateReturns = PackPCall(replicateItems)
    local accepted = replicateReturns and replicateReturns[1]
    local reason = replicateReturns and replicateReturns[2]
    self.status.replicateCallOk = ok
    self.status.replicateCallReturned = true
    self.status.replicateReturn1 = accepted
    self.status.replicateReturn2 = reason
    self.status.replicateReturns = replicateReturns
    do
        local replicateRowsAtCall = 0
        if type(getNumReplicateItems) == "function" then
            local cntOk, cntReturns = PackCall(getNumReplicateItems)
            replicateRowsAtCall = cntOk and tonumber(cntReturns and cntReturns[1]) or 0
        end
        PocketCFO:Debug("FullScan:ReplicateItems called ok=" .. tostring(ok) .. " ret1=" .. tostring(accepted) .. " ret2=" .. tostring(reason) .. " rows=" .. tostring(replicateRowsAtCall))
    end
    if not ok then
        return self:Fail(accepted)
    end
    if accepted == false then
        return self:Fail(reason or "Auction House replicate scan was rejected")
    end

    local started = Now()
    self.status.startedAt = started
    self.status.startedClock = self.status.startedClock or Clock()
    self:StartWaitingForReplicateRows()
    return true
end

function FullScan:GetCooldownRemaining()
    local lastScan = PocketCFO_Valuation.db
        and PocketCFO_Valuation.db.global
        and tonumber(PocketCFO_Valuation.db.global.timeOfLastReplicateScan)
        or nil
    if not lastScan then
        return 0
    end
    return math.max(0, FULL_SCAN_COOLDOWN_SECONDS - (Now() - lastScan))
end

function FullScan:FormatCooldownRemaining(seconds)
    seconds = math.max(0, math.ceil(tonumber(seconds) or 0))
    local minutes = math.floor(seconds / 60)
    local remainder = seconds % 60
    return string.format("%02d:%02d", minutes, remainder)
end

function FullScan:StartFullScan()
    PocketCFO:Debug("FullScan:StartFullScan called")
    if not self.status then
        self:ResetStatus()
    end
    if self.status and self.status.running then
        self.status.rejectReason = "Scan already running."
        return false, self.status.rejectReason
    end

    local cooldownRemaining = self:GetCooldownRemaining()
    if cooldownRemaining > 0 then
        self:ClearRuntimeState()
        self:UnregisterScanEvents()
        self:RegisterPassiveProbe()
        self.status.running = false
        self.status.state = "cooldown"
        self.status.cooldownSeconds = FULL_SCAN_COOLDOWN_SECONDS
        self.status.cooldownRemaining = cooldownRemaining
        self.status.cooldownUntil = Now() + cooldownRemaining
        self.status.rejectReason = "Full scan available in " .. self:FormatCooldownRemaining(cooldownRemaining)
        return false, self.status.rejectReason
    end

    local replicateItems = C_AuctionHouse and C_AuctionHouse.ReplicateItems
    local getNumReplicateItems = C_AuctionHouse and C_AuctionHouse.GetNumReplicateItems
    if type(replicateItems) ~= "function" then
        self.status.rejectReason = "Auction House replicate scan API unavailable"
        self.status.state = "failed"
        self.status.replicateItemsExists = false
        self.status.getNumReplicateItemsExists = type(getNumReplicateItems) == "function"
        return false, self.status.rejectReason
    end

    self:ResetStatus()
    self.status.running = true
    self.status.state = "requesting"
    self.status.startedAt = Now()
    self.status.startedClock = Clock()
    self.status.replicateItemsExists = true
    self.status.getNumReplicateItemsExists = type(getNumReplicateItems) == "function"
    self.status.timeoutSeconds = WAIT_TIMEOUT_SECONDS
    self.status.cooldownSeconds = FULL_SCAN_COOLDOWN_SECONDS
    self.buckets = {}
    self.identityMemo = {}
    self.scanToken = {}

    self:UnregisterPassiveProbe()
    self:RegisterScanEvents()

    return self:RequestReplicateScan(self.scanToken)
end

function FullScan:OnScanFrameEvent(event)
    if event == "REPLICATE_ITEM_LIST_UPDATE" then
        if not self.status or not self.status.running then
            return
        end
        self:RecordScanEvent("REPLICATE_ITEM_LIST_UPDATE")
        if self.nextIndex then
            return
        end
        if self.scanFrame then
            self.scanFrame:UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
        end
        self:CancelWaitTimeout()
        local rowCount, err = self:GetReplicateRowCount()
        self.status.numReplicateItemsImmediateOk = rowCount ~= nil
        self.status.numReplicateItemsImmediately = rowCount
        if not rowCount then
            self:Fail(err or "Auction House replicate row count unavailable")
            return
        end
        self:StartProcessingReplicateRows(rowCount)
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if self.status and self.status.running then
            self:RecordScanEvent("AUCTION_HOUSE_CLOSED")
            self:Fail("Auction House closed before full scan completed")
        end
    end
end

function FullScan:GetStatus()
    local source = self.status or {}
    local cooldownRemaining = source.cooldownRemaining
    if source.state == "cooldown" and source.cooldownUntil then
        cooldownRemaining = math.max(0, (tonumber(source.cooldownUntil) or 0) - Now())
    end
    return {
        running = source.running == true,
        state = source.state or (source.running and "processing" or "idle"),
        rowsProcessed = tonumber(source.rowsProcessed) or 0,
        rowsTotal = tonumber(source.rowsTotal) or 0,
        marketsPriced = tonumber(source.marketsPriced) or 0,
        marketsBuilt = tonumber(source.marketsBuilt) or 0,
        marketsTotal = tonumber(source.marketsTotal) or 0,
        startedAt = source.startedAt,
        startedClock = source.startedClock,
        completedAt = source.completedAt,
        completedClock = source.completedClock,
        elapsedSeconds = source.startedClock and math.max(0, (source.completedClock or Clock()) - source.startedClock) or 0,
        totalElapsedSeconds = source.totalElapsedSeconds,
        lastError = source.lastError,
        rejectReason = source.rejectReason,
        error = source.lastError,
        waitingStartedAt = source.waitingStartedAt,
        lastEventName = source.lastEventName,
        lastEventAt = source.lastEventAt,
        replicateItemsExists = source.replicateItemsExists == true,
        replicateCallOk = source.replicateCallOk,
        replicateCallReturned = source.replicateCallReturned == true,
        replicateReturn1 = source.replicateReturn1,
        replicateReturn2 = source.replicateReturn2,
        replicateReturns = source.replicateReturns,
        getNumReplicateItemsExists = source.getNumReplicateItemsExists == true,
        numReplicateItemsImmediately = source.numReplicateItemsImmediately,
        numReplicateItemsImmediateOk = source.numReplicateItemsImmediateOk,
        timeoutSeconds = source.timeoutSeconds,
        expectedSeconds = source.expectedSeconds,
        cooldownSeconds = source.cooldownSeconds,
        cooldownUntil = source.cooldownUntil,
        cooldownRemaining = cooldownRemaining,
        eventLog = source.eventLog,
    }
end

function FullScan:OnEnable()
    self.scanFrame = CreateFrame("Frame")
    self.scanFrame:SetScript("OnEvent", function(_, event)
        self:OnScanFrameEvent(event)
    end)
    self:ResetStatus()
    self:RegisterPassiveProbe()
end

function FullScan:OnDisable()
    if self.status and self.status.running then
        self:Fail("Full scan interrupted: module disabled")
    end
end
