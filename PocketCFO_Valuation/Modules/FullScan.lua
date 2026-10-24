-- PocketCFO_Valuation/Modules/FullScan.lua
-- Manual replicate-scan pricing coordinator. Does not store auction rows.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local FullScan = PocketCFO_Valuation:NewModule("FullScan", "AceEvent-3.0")

-- Rows read per frame only when debugprofilestop is unavailable; normally
-- each frame works until CHUNK_BUDGET_MS is spent, so slower machines do
-- fewer rows per frame instead of stuttering.
local PROCESS_CHUNK_SIZE = 200
local CHUNK_BUDGET_MS = 8
local FINALIZE_CHUNK_SIZE = 100
local YIELD_SECONDS = 0.01
-- Blizzard takes 30-90+ seconds to send replicate data (api-findings), longer
-- on big Auction Houses.
local WAIT_TIMEOUT_SECONDS = 180
-- Phase 3: rows that weren't ready in phase 2 (hasAllInfo == false) wait
-- for the game to fill them in. Confirmed in-game 2026-10-24: a row's
-- readiness is per row, not per item (rows stay not ready after GetItemInfo
-- works, and reading them early gives a nil link), and it doesn't last:
-- not-ready rows went 186k -> 318k -> 350k over ~5 minutes of idling.
-- Theoretical: the game only keeps a limited set of item data, so asking
-- for everything at once pushes rows out before they're read. So rows are
-- worked through a small set of items at a time (like the original code's
-- 200-row retry, which got the most markets), read the moment they're
-- ready. An item not ready within WAIT_ITEM_SECONDS goes to the back of the
-- queue; after WAIT_ITEM_MAX_TRIES it is skipped. WAIT_STALL_SECONDS with no
-- row read, or WAIT_MAX_SECONDS overall, ends phase 3 (rest skipped).
local WAIT_WINDOW_ITEMS = 200
local WAIT_ITEM_SECONDS = 10
local WAIT_ITEM_MAX_TRIES = 3
local WAIT_REREQUEST_SECONDS = 1
local WAIT_STALL_SECONDS = 30
local WAIT_MAX_SECONDS = 360
local WAIT_LOG_SECONDS = 1
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

-- Returns a function to call after each row; it returns true once this
-- frame's work budget is spent.
local function NewFrameBudget()
    local startMs = debugprofilestop and debugprofilestop() or nil
    local count = 0
    return function()
        count = count + 1
        if startMs then
            return (debugprofilestop() - startMs) >= CHUNK_BUDGET_MS
        end
        return count >= PROCESS_CHUNK_SIZE
    end
end

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local function IsItemInfoLoaded(itemID)
    if not itemID or not GetItemInfo then
        return false
    end
    local ok, name = pcall(GetItemInfo, itemID)
    return ok and name ~= nil
end

-- false only when the game says the item doesn't exist (Blizzard sometimes
-- returns replicate rows for such items; they never load).
local function ItemExists(itemID)
    if not itemID then
        return false
    end
    if C_Item and type(C_Item.DoesItemExistByID) == "function" then
        local ok, exists = pcall(C_Item.DoesItemExistByID, itemID)
        if ok and exists == false then
            return false
        end
    end
    return true
end

local function RequestItemLoad(itemID)
    if itemID and C_Item and type(C_Item.RequestLoadItemDataByID) == "function" then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
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
    self.finalizeKeys = nil
    self.finalizeIndex = nil
    self.identityMemo = nil
    self.scanToken = nil
    self.timing = nil
    self:ClearPending()
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
    -- The event can fire dozens of times a second with the same count; log
    -- only when the count changes (2026-10-24).
    if rowCount == self.lastProbeRowCount then
        return
    end
    self.lastProbeRowCount = rowCount
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

function FullScan:ScheduleNext(methodName, delaySeconds)
    local token = self.scanToken
    if C_Timer and C_Timer.After then
        C_Timer.After(delaySeconds or YIELD_SECONDS, function()
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

    local timing = self.timing or {}
    local doneClock = Clock()
    local function Span(a, b)
        return (a and b) and (b - a) or -1
    end
    PocketCFO:Debug("FullScan: summary rows=%d markets=%d priced=%d | phase1=%.1fs phase2=%.1fs phase3=%.1fs phase4=%.1fs total=%.1fs | waitedRows=%d waitedItems=%d skippedWaiting=%d missingItem=%d noMarketKey=%d",
        tonumber(self.status.rowsTotal) or 0, #keys, tonumber(self.status.marketsPriced) or 0,
        Span(timing.start, timing.phase1End), Span(timing.phase1End, timing.phase2End),
        Span(timing.phase2End, timing.phase3End), Span(timing.phase3End, doneClock), Span(timing.start, doneClock),
        timing.waitedRows or 0, timing.waitedItems or 0, timing.skippedWaiting or 0,
        timing.missingItem or 0, timing.noMarketKey or 0)

    self.status.running = false
    self.status.state = "complete"
    self.status.completedAt = Now()
    self.status.completedClock = Clock()
    if self.status.startedClock then
        self.status.totalElapsedSeconds = math.max(0, self.status.completedClock - self.status.startedClock)
    end
    cache:SetLastScanTime(self.status.startedAt or self.status.completedAt)
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

    -- Same for green/blue profession gear pairs (ProfessionGearPairs.lua,
    -- used by the tool-tier-cap rule). Not loaded on Forever.
    local gearPairs = PocketCFO_Valuation:GetModule("ProfessionGearPairs", true)
    if gearPairs and gearPairs.Rebuild then
        gearPairs:Rebuild()
    end
end

-- Reads one replicate row into its market bucket. Returns:
--   "ok"       read (or has no usable price, same as before)
--   "pending"  row not ready yet; second return is the itemID
--   "missing"  the game says the item doesn't exist; skipped
--   "unkeyed"  row ready but no market key could be built; skipped
function FullScan:ReadReplicateRow(index)
    local row = GetReplicateInfo(index)
    local itemID = row and tonumber(row.itemID or row.itemId or row.id)
    if row and row.hasAllInfo == false then
        if not ItemExists(itemID) then
            return "missing"
        end
        return "pending", itemID
    end

    local itemLink = GetReplicateLink(index)
    local memoKey = itemLink or ("itemID:" .. tostring(itemID or ""))
    local identity = self.identityMemo and self.identityMemo[memoKey]
    if identity == nil then
        identity = BuildIdentity(row, itemLink)
        if identity then
            if self.identityMemo then
                self.identityMemo[memoKey] = identity
            end
        elseif itemID and not IsItemInfoLoaded(itemID) then
            -- No key only because the item's details haven't arrived yet:
            -- wait for them instead of dropping the row.
            if not ItemExists(itemID) then
                return "missing"
            end
            return "pending", itemID
        else
            identity = false
            if self.identityMemo and memoKey ~= "" then
                self.identityMemo[memoKey] = false
            end
        end
    end
    if identity == false then
        self:NoteUnkeyed(itemID, itemLink)
        return "unkeyed"
    end

    local _, bucketCreated = AddObservation(self.buckets, identity, row)
    if bucketCreated then
        self.status.marketsBuilt = (tonumber(self.status.marketsBuilt) or 0) + 1
    end
    return "ok"
end

-- ─── Rows waiting to be ready (phase 3) ───────────────────────────────────

function FullScan:ClearPending()
    self.waitItems = nil
    self.waitOrder = nil
    self.waitCursor = nil
    self.waitWindow = nil
    self.waitWindowInfo = nil
    self.waitRowCount = nil
    self.waitStats = nil
    self.unkeyedSample = nil
    self.unkeyedSampleSeen = nil
end

function FullScan:InitPending()
    self:ClearPending()
    self.waitItems = {}       -- itemID -> { rows = { index, ... }, tries = n }
    self.waitOrder = {}       -- queue of itemIDs (requeued items go to the back)
    self.waitCursor = 1
    self.waitWindow = {}      -- itemIDs being worked on now
    self.waitWindowInfo = {}  -- itemID -> { enteredAt, lastRequest }
    self.waitRowCount = 0
    self.waitStats = {
        missingItem = 0, noMarketKey = 0, rowsAtStart = 0, itemsAtStart = 0,
        readSinceLog = 0, requeued = 0, gaveUpItems = 0, gaveUpRows = 0,
    }
    self.unkeyedSample = {}
    self.unkeyedSampleSeen = {}
end

-- Up to UNKEYED_SAMPLE_SIZE distinct items that got no market key, for the
-- debug log (to find out why).
local UNKEYED_SAMPLE_SIZE = 25
function FullScan:NoteUnkeyed(itemID, itemLink)
    local seen = self.unkeyedSampleSeen
    if not seen or #self.unkeyedSample >= UNKEYED_SAMPLE_SIZE then
        return
    end
    local key = itemID or itemLink or "?"
    if seen[key] then
        return
    end
    seen[key] = true
    self.unkeyedSample[#self.unkeyedSample + 1] = tostring(itemID) .. "=" .. tostring(itemLink)
end

function FullScan:AddWaiting(itemID, index)
    local entry = self.waitItems[itemID]
    if not entry then
        entry = { rows = {}, tries = 0 }
        self.waitItems[itemID] = entry
        self.waitOrder[#self.waitOrder + 1] = itemID
    end
    entry.rows[#entry.rows + 1] = index
    self.waitRowCount = self.waitRowCount + 1
end

-- Counts a finished row ("missing"/"unkeyed"/"ok"). Phase 2 only.
function FullScan:HandleRowResult(index, result, itemID)
    if result == "pending" then
        if itemID then
            self:AddWaiting(itemID, index)
            return
        end
        result = "missing"
    end
    if result == "missing" then
        self.waitStats.missingItem = self.waitStats.missingItem + 1
    elseif result == "unkeyed" then
        self.waitStats.noMarketKey = self.waitStats.noMarketKey + 1
    end
end

function FullScan:ProcessChunk()
    if not self.status.running then
        return
    end

    local spent = NewFrameBudget()
    local total = self.status.rowsTotal or 0

    -- Phase 2: the regular (0-based) indexes
    if (self.nextIndex or 0) < total then
        self.status.state = "processing"
        local index = self.nextIndex or 0
        while index < total do
            local result, itemID = self:ReadReplicateRow(index)
            self:HandleRowResult(index, result, itemID)
            index = index + 1
            self.status.rowsProcessed = index
            if spent() then
                break
            end
        end
        self.nextIndex = index
        if index >= total then
            self.status.state = "building"
            self.timing.phase2End = Clock()
        end
        self:ScheduleNext("ProcessChunk")
        return
    end

    self.status.state = "building"
    self:ProcessPendingRows(spent)
end

-- Re-reads one window item's waiting rows. Returns true when the item
-- leaves the window (all rows read, requeued, or given up).
function FullScan:CheckWaitingItem(itemID, now)
    local entry = self.waitItems[itemID]
    local info = self.waitWindowInfo[itemID]
    if not entry or not info then
        self.waitWindowInfo[itemID] = nil
        return true
    end

    local stats = self.waitStats
    local remaining = {}
    for _, index in ipairs(entry.rows) do
        local result = self:ReadReplicateRow(index)
        if result == "pending" then
            remaining[#remaining + 1] = index
        else
            if result == "missing" then
                stats.missingItem = stats.missingItem + 1
            elseif result == "unkeyed" then
                stats.noMarketKey = stats.noMarketKey + 1
            end
            self.waitRowCount = self.waitRowCount - 1
            stats.readSinceLog = stats.readSinceLog + 1
            self.waitLastProgressClock = now
        end
    end
    entry.rows = remaining

    if #remaining == 0 then
        self.waitItems[itemID] = nil
        self.waitWindowInfo[itemID] = nil
        return true
    end

    if (now - info.enteredAt) >= WAIT_ITEM_SECONDS then
        self.waitWindowInfo[itemID] = nil
        entry.tries = entry.tries + 1
        if entry.tries >= WAIT_ITEM_MAX_TRIES then
            stats.gaveUpItems = stats.gaveUpItems + 1
            stats.gaveUpRows = stats.gaveUpRows + #remaining
            self.waitRowCount = self.waitRowCount - #remaining
            self.waitItems[itemID] = nil
        else
            stats.requeued = stats.requeued + 1
            self.waitOrder[#self.waitOrder + 1] = itemID
        end
        return true
    end

    if (now - info.lastRequest) >= WAIT_REREQUEST_SECONDS then
        RequestItemLoad(itemID)
        info.lastRequest = now
    end
    return false
end

function FullScan:FinishPending(reason)
    local now = Clock()
    local stats = self.waitStats
    local timing = self.timing
    timing.phase3End = now
    timing.waitedRows = stats.rowsAtStart
    timing.waitedItems = stats.itemsAtStart
    timing.requeued = stats.requeued
    timing.skippedWaiting = stats.gaveUpRows + (self.waitRowCount or 0)
    timing.missingItem = stats.missingItem
    timing.noMarketKey = stats.noMarketKey
    PocketCFO:Debug("FullScan: phase 3 %s t=%.1fs requeued=%d gaveUpItems=%d gaveUpRows=%d leftWaiting=%d missingItem=%d noMarketKey=%d",
        reason, now - (self.waitStartedClock or now), stats.requeued, stats.gaveUpItems, stats.gaveUpRows,
        self.waitRowCount or 0, stats.missingItem, stats.noMarketKey)
    if self.unkeyedSample and #self.unkeyedSample > 0 then
        PocketCFO:Debug("FullScan: noMarketKey sample (itemID=link): %s", table.concat(self.unkeyedSample, " , "))
    end
    self.waitStartedClock = nil
    self.waitLastProgressClock = nil
    self.waitLastLogClock = nil
    self:ClearPending()
    self:StartFinalizing()
end

-- Phase 3: keep up to WAIT_WINDOW_ITEMS items in the window; check their
-- rows every frame (within the frame budget) and read each row as soon as
-- it's ready.
function FullScan:ProcessPendingRows(spent)
    local now = Clock()
    local stats = self.waitStats
    if not self.waitStartedClock then
        self.waitStartedClock = now
        self.waitLastProgressClock = now
        self.waitLastLogClock = now
        stats.rowsAtStart = self.waitRowCount
        stats.itemsAtStart = #self.waitOrder
        PocketCFO:Debug("FullScan: phase 3 waiting: %d rows across %d items (missingItem=%d noMarketKey=%d so far)",
            stats.rowsAtStart, stats.itemsAtStart, stats.missingItem, stats.noMarketKey)
    end

    -- Limits first, every frame.
    if self.waitRowCount <= 0 then
        self:FinishPending("done")
        return
    end
    if (now - self.waitStartedClock) >= WAIT_MAX_SECONDS then
        self:FinishPending("stopped (time limit)")
        return
    end
    if (now - self.waitLastProgressClock) >= WAIT_STALL_SECONDS then
        self:FinishPending("stopped (no progress)")
        return
    end

    -- Fill the window from the queue.
    local window = self.waitWindow
    while #window < WAIT_WINDOW_ITEMS and self.waitCursor <= #self.waitOrder do
        local itemID = self.waitOrder[self.waitCursor]
        self.waitCursor = self.waitCursor + 1
        if self.waitItems[itemID] and not self.waitWindowInfo[itemID] then
            window[#window + 1] = itemID
            self.waitWindowInfo[itemID] = { enteredAt = now, lastRequest = now }
            RequestItemLoad(itemID)
        end
    end

    -- Check window items, rotating so none starve when the budget runs out.
    local unvisited, visitedKept = {}, {}
    local budgetOut = false
    for _, itemID in ipairs(window) do
        if budgetOut then
            unvisited[#unvisited + 1] = itemID
        else
            if not self:CheckWaitingItem(itemID, now) then
                visitedKept[#visitedKept + 1] = itemID
            end
            budgetOut = spent()
        end
    end
    for _, itemID in ipairs(visitedKept) do
        unvisited[#unvisited + 1] = itemID
    end
    self.waitWindow = unvisited

    -- Timing, to tune the WAIT_* settings from real data.
    if (now - self.waitLastLogClock) >= WAIT_LOG_SECONDS then
        PocketCFO:Debug("FullScan: phase 3 t=%.1fs read=%d waitingRows=%d window=%d queued=%d requeued=%d gaveUpItems=%d",
            now - self.waitStartedClock, stats.readSinceLog, self.waitRowCount, #self.waitWindow,
            #self.waitOrder - self.waitCursor + 1, stats.requeued, stats.gaveUpItems)
        self.waitLastLogClock = now
        stats.readSinceLog = 0
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
    self.timing.phase1End = Clock()
    self:InitPending()
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
    local cache = PocketCFO_Valuation:GetModule("PricingCache", true)
    if cache and cache.SetLastRequestTime then
        cache:SetLastRequestTime(started)
    end
    self.status.startedAt = started
    self.status.startedClock = self.status.startedClock or Clock()
    self:StartWaitingForReplicateRows()
    return true
end

function FullScan:GetCooldownRemaining()
    -- Counts from the last request (finished or not), like Blizzard's own
    -- cooldown; falls back to the last finished scan for groups saved
    -- before request times were recorded.
    local cache = PocketCFO_Valuation:GetModule("PricingCache", true)
    local lastScan = cache and (cache:GetLastRequestTime() or cache:GetLastScanTime()) or nil
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
    self.timing = { start = Clock() }

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
