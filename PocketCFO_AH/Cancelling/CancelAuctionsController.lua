-- PocketCFO_AH/Cancelling/CancelAuctionsController.lua
-- Builds and evaluates the owned-auction cancel workflow. Cancels one auction per click.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local CancelAuctionsController = PocketCFO_AH:NewModule("CancelAuctionsController")

local OWNED_AUCTION_REFRESH_TIMEOUT_SECONDS = 2

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function OwnerKey()
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.char
        and PocketCFO.db.char.characterGUID
        or nil
end

local function PlayerOwnerName()
    if UnitFullName then
        local name, realm = UnitFullName("player")
        if name and realm and realm ~= "" then
            return name .. "-" .. realm
        end
        return name
    end
    if UnitName then
        return UnitName("player")
    end
    return nil
end

local function PositiveQuantity(value)
    value = math.floor(tonumber(value) or 0)
    if value > 0 then
        return value
    end
    return 0
end

local function GetItemIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function GetMarketLadderService()
    return PocketCFO_AH and PocketCFO_AH.MarketLadderService or _G.MarketLadderService
end

local function GetCancelEvaluation()
    return PocketCFO_AH and PocketCFO_AH.CancelEvaluation or _G.CancelEvaluation
end

local function GetInventoryStateService()
    return PocketCFO and (PocketCFO.InventoryStateService or _G.InventoryStateService) or _G.InventoryStateService
end

local function GetAHListingService()
    return PocketCFO_AH and PocketCFO_AH.GetModule and PocketCFO_AH:GetModule("AHListingService", true) or nil
end

local function BuildOwnedAuctionTarget(row)
    return {
        source = "ownedAuctionRow",
        evidenceType = "ownedAuctionRow",
        row = row,
    }
end

local function NowMs()
    if debugprofilestop then
        return debugprofilestop()
    end
    if GetTime then
        return GetTime() * 1000
    end
    return (time and time() or 0) * 1000
end

local function ElapsedMs(startMs)
    return math.floor((NowMs() - (tonumber(startMs) or NowMs())) + 0.5)
end

local function GetAuctionID(auction)
    if type(auction) ~= "table" then
        return nil
    end
    return auction.auctionID or auction.auctionId or auction.id or auction.listingID or auction.listingId
end

local function AuctionPrice(auction)
    if type(auction) ~= "table" then
        return nil
    end
    local normalizedPrice = tonumber(auction.price)
    if normalizedPrice and normalizedPrice > 0 then
        return normalizedPrice
    end
    local unitPrice = tonumber(auction.unitPrice or auction.pricePerUnit)
    if auction.isCommodity == true and unitPrice and unitPrice > 0 then
        return unitPrice
    end
    local buyout = tonumber(auction.buyoutAmount or auction.buyout or auction.buyoutPrice or auction.totalPrice)
    if buyout and buyout > 0 then
        if auction.isCommodity == true then
            local quantity = PositiveQuantity(auction.quantity or auction.count or auction.stackSize or auction.numItems)
            if quantity > 0 then
                return math.floor((buyout / quantity) + 0.5)
            end
        end
        return buyout
    end
    if unitPrice and unitPrice > 0 then
        return unitPrice
    end
    return nil
end

local function AuctionQuantity(auction)
    local quantity = PositiveQuantity(auction and (auction.quantity or auction.count or auction.stackSize or auction.numItems))
    if quantity > 0 then
        return quantity
    end
    return 1
end

local function DurationValue(auction)
    return auction and (auction.timeLeft or auction.durationLeft or auction.duration) or nil
end

local function ConfigKeyForOwnedAuction(auction)
    if auction and auction.configKey then
        return auction.configKey, auction.identity
    end
    local identityService = GetItemIdentityService()
    if not identityService or type(identityService.FromOwnedAuctionRow) ~= "function" then
        return nil, nil
    end
    local identity = identityService:FromOwnedAuctionRow(auction)
    if identity and not identity.unresolved and identity.configKey then
        auction.configKey = auction.configKey or identity.configKey
        auction.identity = auction.identity or identity
        auction.auctionPath = auction.auctionPath or identity.auctionPath
        auction.isCommodity = auction.isCommodity == true or identity.auctionPath == "commodity"
        return identity.configKey, identity
    end
    return nil, identity
end

local function RowGroupKey(configKey, auctionID, price, duration, state)
    return table.concat({
        tostring(configKey or ("auction:" .. tostring(auctionID or ""))),
        tostring(price or ""),
        tostring(duration or ""),
        tostring(state or "active"),
    }, "||")
end

local function ApplyRowTotals(row)
    local quantity = 0
    local auctionIDs = {}
    for _, auction in ipairs(row.auctions or {}) do
        quantity = quantity + AuctionQuantity(auction)
        local auctionID = GetAuctionID(auction)
        if auctionID ~= nil then
            auctionIDs[#auctionIDs + 1] = auctionID
        end
    end
    row.quantity = quantity
    row.quantityPosted = quantity
    row.auctionIDs = auctionIDs
    row.auctionID = auctionIDs[1]
end

local function RemoveRow(rows, target)
    for index, row in ipairs(rows or {}) do
        if row == target then
            table.remove(rows, index)
            return true
        end
    end
    return false
end

local function RowCanCancel(row)
    return row and row.status == "Undercut" and #(row.auctions or {}) > 0
end

local function SortRows(rows)
    local buckets = { {}, {}, {}, {}, {} }
    local function bucket(row)
        if row.status == "Undercut" then
            return 1
        elseif row.status == "Evaluating" or row.status == "Pending evaluation" or row.status == "Refreshing owned auctions..." then
            return 2
        elseif row.status == "Canceled" then
            return 3
        elseif row.status == "OK" then
            return 5
        end
        return 4
    end

    for _, row in ipairs(rows or {}) do
        buckets[bucket(row)][#buckets[bucket(row)] + 1] = row
    end

    local index = 1
    for bucketIndex = 1, #buckets do
        for _, row in ipairs(buckets[bucketIndex]) do
            rows[index] = row
            index = index + 1
        end
    end
    for removeIndex = index, #rows do
        rows[removeIndex] = nil
    end
end

local function FirstCancelableIndex(rows)
    for index, row in ipairs(rows or {}) do
        if RowCanCancel(row) then
            return index
        end
    end
    return nil
end

local function CountStatus(rows, status)
    local count = 0
    for _, row in ipairs(rows or {}) do
        if row and row.status == status then
            count = count + 1
        end
    end
    return count
end

local function AuctionItemID(auction)
    if type(auction) ~= "table" then
        return nil
    end
    if auction.itemID or auction.itemId then
        return tonumber(auction.itemID or auction.itemId)
    end
    if type(auction.itemKey) == "table" then
        return tonumber(auction.itemKey.itemID or auction.itemKey.itemId)
    end
    return nil
end

local function CopyArray(source)
    local copy = {}
    for index, value in ipairs(source or {}) do
        copy[index] = value
    end
    return copy
end

function CancelAuctionsController:SetRowsChangedCallback(callback)
    self.rowsChangedCallback = type(callback) == "function" and callback or nil
end

function CancelAuctionsController:NotifyRowsChanged(reason)
    if self.rowsChangedCallback then
        self.rowsChangedCallback(self.rows or {}, reason)
    end
end

function CancelAuctionsController:GetRows()
    return self.rows or {}
end

function CancelAuctionsController:IsEvaluationInProgress()
    if self.evaluating == true then
        return true
    end
    for _, row in ipairs(self.rows or {}) do
        if row.status == "Evaluating" or row.status == "Refreshing owned auctions..." then
            return true
        end
    end
    return false
end

function CancelAuctionsController:IsCancelInProgress()
    return self.cancelInProgress == true
end

function CancelAuctionsController:CanCancelRow(row)
    return self:IsEvaluationInProgress() ~= true
        and self:IsCancelInProgress() ~= true
        and RowCanCancel(row)
end

function CancelAuctionsController:BuildRowsFromOwnedAuctions(ownedRows)
    local ownerKey = OwnerKey()
    local ownerName = PlayerOwnerName()
    local groups = {}
    local orderedKeys = {}

    for _, auction in ipairs(ownedRows or {}) do
        if auction and ownerKey and ownerKey ~= "" and (auction.ownerKey == nil or tostring(auction.ownerKey) == tostring(ownerKey)) then
            local auctionID = GetAuctionID(auction)
            if auctionID ~= nil or auction.isCommodity == true then
                auction.isOwned = true
                auction.owned = true
                auction.ownerIsPlayer = true
                auction.ownerKey = auction.ownerKey or ownerKey
                auction.owner = auction.owner or ownerName

                local price = AuctionPrice(auction)
                local duration = DurationValue(auction)
                local configKey, identity = ConfigKeyForOwnedAuction(auction)
                local key = RowGroupKey(configKey, auctionID, price, duration, "active")
                if not groups[key] then
                    orderedKeys[#orderedKeys + 1] = key
                    groups[key] = {
                        rowID = "cancel:" .. tostring(#orderedKeys) .. ":" .. tostring(key),
                        groupKey = key,
                        configKey = configKey,
                        identity = identity,
                        auctionPath = identity and identity.auctionPath or auction.auctionPath,
                        itemName = auction.itemName or auction.name or ("Item " .. tostring(auction.itemID or "")),
                        item = auction.itemName or auction.name or ("Item " .. tostring(auction.itemID or "")),
                        itemID = auction.itemID,
                        itemLink = auction.itemLink,
                        itemQuality = auction.itemQuality or auction.craftingQuality or auction.qualityTier,
                        ilvl = auction.ilvl or auction.itemLevel,
                        itemClassID = auction.itemClassID,
                        itemSubClassID = auction.itemSubClassID,
                        equipLoc = auction.equipLoc,
                        statFingerprint = auction.statFingerprint,
                        isCommodity = auction.isCommodity == true or (identity and identity.auctionPath == "commodity"),
                        price = price,
                        duration = duration,
                        ownerKey = ownerKey,
                        owner = ownerName,
                        auctions = {},
                        status = "Evaluating",
                        note = "",
                        notes = "",
                        cancel = { pending = false },
                    }
                end
                groups[key].auctions[#groups[key].auctions + 1] = auction
            end
        end
    end

    local rows = {}
    for _, key in ipairs(orderedKeys) do
        local row = groups[key]
        ApplyRowTotals(row)
        rows[#rows + 1] = row
    end

    self.rows = rows
    self.evaluating = false
    self.rowsBuiltMs = NowMs()
    SessionLog("CancelAuctionsController: owned rows built raw=%d grouped=%d", #(ownedRows or {}), #rows)
    return rows
end

function CancelAuctionsController:SplitEvaluatedRow(row, okAuctions, undercutAuctions)
    if #okAuctions > 0 and #undercutAuctions > 0 then
        local okRow = {}
        for key, value in pairs(row) do
            if key ~= "auctions" and key ~= "auctionIDs" and key ~= "auctionID" and key ~= "cancel" then
                okRow[key] = value
            end
        end
        okRow.rowID = tostring(row.rowID) .. ":ok"
        okRow.auctions = okAuctions
        okRow.status = "OK"
        okRow.note = "Still next to buy auction."
        okRow.notes = okRow.note
        okRow.cancel = { pending = false }
        ApplyRowTotals(okRow)
        self.rows[#self.rows + 1] = okRow

        row.auctions = undercutAuctions
        ApplyRowTotals(row)
        return row
    end

    if #okAuctions > 0 then
        row.auctions = okAuctions
        ApplyRowTotals(row)
        return row
    end

    row.auctions = undercutAuctions
    ApplyRowTotals(row)
    return row
end

function CancelAuctionsController:ApplyEvaluation(row, evaluation)
    if not evaluation then
        row.status = "OK"
        row.note = "Cancel evaluation unavailable."
        row.notes = row.note
        return
    end

    row = self:SplitEvaluatedRow(row, evaluation.okAuctions or {}, evaluation.undercutAuctions or {})
    row.status = evaluation.status or "OK"
    row.note = evaluation.note or ""
    row.notes = row.note
    row.matchDebug = evaluation.matchDebug or {}
    row.cancelMatchedAuctions = evaluation.matchedAuctions
    row.cancelLadderResult = evaluation.ladderResult
end

function CancelAuctionsController:EvaluateNext(generation)
    if generation ~= self.generation then
        return
    end

    local row = nil
    for _, candidate in ipairs(self.rows or {}) do
        if candidate.status == "Evaluating" then
            row = candidate
            break
        end
    end

    if not row then
        self.evaluating = false
        SortRows(self.rows)
        self:NotifyRowsChanged("complete")
        SessionLog("CancelAuctionsController: evaluation complete rows=%d", #(self.rows or {}))
        return
    end

    local ladder = GetMarketLadderService()
    local evaluator = GetCancelEvaluation()
    if not ladder or type(ladder.BuildForTarget) ~= "function" or not evaluator or type(evaluator.Evaluate) ~= "function" then
        row.status = "OK"
        row.note = "Cancel evaluation unavailable."
        row.notes = row.note
        SortRows(self.rows)
        self:NotifyRowsChanged("row")
        self:EvaluateNext(generation)
        return
    end

    row.evaluationStartedMs = NowMs()
    SessionLog("CancelAuctionsController: row evaluation request rowID=%s item=%s rowsBuiltAgeMs=%d evaluationAgeMs=%d",
        tostring(row.rowID), tostring(row.itemName), ElapsedMs(self.rowsBuiltMs), ElapsedMs(self.evaluationStartedMs))
    row.candidate = row
    ladder:BuildForTarget(BuildOwnedAuctionTarget(row), function(ladderResult)
        if generation ~= self.generation then
            return
        end
        local lookupElapsedMs = ElapsedMs(row.evaluationStartedMs)
        local matchedAuctions = ladderResult and ladderResult.discoveryResult and ladderResult.discoveryResult.matchingAuctions or {}
        local evaluation = evaluator:Evaluate(row, {
            ladderResult = ladderResult,
            matchedAuctions = matchedAuctions,
        })
        self:ApplyEvaluation(row, evaluation)
        row.matchDebug = row.matchDebug or {}
        row.matchDebug.lookupMeta = ladderResult and ladderResult.discovery and ladderResult.discovery.query or nil
        row.matchDebug.matchAnalysis = ladderResult and ladderResult.discovery or nil
        SessionLog("CancelAuctionsController: row evaluation result rowID=%s item=%s rawAuctions=%d matched=%d lookupReason=%s elapsedMs=%d",
            tostring(row.rowID), tostring(row.itemName), #(ladderResult and ladderResult.discovery and ladderResult.discovery.candidates or {}),
            #(matchedAuctions or {}), tostring(ladderResult and ladderResult.discovery and ladderResult.discovery.query and ladderResult.discovery.query.zeroReason),
            lookupElapsedMs)
        SortRows(self.rows)
        self:NotifyRowsChanged("row")
        self:EvaluateNext(generation)
    end)
end

function CancelAuctionsController:StartEvaluation()
    self.generation = (tonumber(self.generation) or 0) + 1
    self.evaluating = true
    self.evaluationStartedMs = NowMs()
    SessionLog("CancelAuctionsController: evaluation started rows=%d rowsBuiltAgeMs=%d",
        #(self.rows or {}), ElapsedMs(self.rowsBuiltMs))
    for _, row in ipairs(self.rows or {}) do
        row.status = "Evaluating"
        row.note = ""
        row.notes = ""
    end
    SortRows(self.rows)
    self:NotifyRowsChanged("evaluation-started")
    self:EvaluateNext(self.generation)
end

function CancelAuctionsController:UseObservationRows(observation, reason)
    self:BuildRowsFromOwnedAuctions(observation and observation.rows or {})
    self:NotifyRowsChanged("built")
    SessionLog("CancelAuctionsController: owned rows ready source=%s rows=%d",
        tostring(reason or "unknown"), #(self.rows or {}))
    self:StartEvaluation()
end

function CancelAuctionsController:GetImmediateOwnedObservation()
    local ahManager = PocketCFO_AH:GetModule("AHManager", true)
    local existing = ahManager and ahManager.session and ahManager.session.ahObservation or nil
    if existing and existing.complete == true and type(existing.rows) == "table" then
        return existing, "existing-complete-observation"
    end

    local scanner = PocketCFO_AH:GetModule("OwnedAuctionsScanner", true)
    if not scanner or not scanner.OwnedAuctionResultsReady or not scanner.ScanOwnedAuctions then
        return nil
    end

    local ready = scanner:OwnedAuctionResultsReady()
    if ready ~= true then
        return nil
    end

    local ownedCount = scanner.GetOwnedAuctionCount and scanner:GetOwnedAuctionCount() or nil
    local ownedInfos = scanner.GetOwnedAuctionInfos and scanner:GetOwnedAuctionInfos() or nil
    if ownedCount == nil and type(ownedInfos) ~= "table" then
        return nil
    end
    if tonumber(ownedCount) == 0 and type(ownedInfos) == "table" and #ownedInfos == 0 then
        -- A reliable empty owned-auction result is valid and should render immediately.
    elseif tonumber(ownedCount or 0) <= 0 and type(ownedInfos) ~= "table" then
        return nil
    end

    local observation = scanner:ScanOwnedAuctions()
    if observation and observation.complete == true then
        if ahManager and ahManager.session then
            ahManager.session.ahObservation = observation
        end
        return observation, "scanner-ready-immediate"
    end
    return nil
end

function CancelAuctionsController:Refresh()
    self.generation = (tonumber(self.generation) or 0) + 1
    self.evaluating = true
    self.rows = {}
    self:NotifyRowsChanged("refreshing")

    local ahManager = PocketCFO_AH:GetModule("AHManager", true)
    if not ahManager or not ahManager.RequestOwnedAuctionsRefresh then
        self.evaluating = false
        self:BuildRowsFromOwnedAuctions({})
        self:NotifyRowsChanged("complete")
        return false, "managerUnavailable"
    end

    local generation = self.generation
    local immediateObservation, immediateReason = self:GetImmediateOwnedObservation()
    if immediateObservation then
        self:UseObservationRows(immediateObservation, immediateReason)
        return true
    end

    ahManager:RequestOwnedAuctionsRefresh("cancel-auctions-refresh", function(ok, observation, err)
        if generation ~= self.generation then
            return
        end
        if not ok then
            SessionLog("CancelAuctionsController: owned refresh unavailable err=%s; using observation rows if present", tostring(err))
        end
        self:UseObservationRows(observation, ok and "refresh-callback" or ("refresh-" .. tostring(err or "unavailable")))
    end, OWNED_AUCTION_REFRESH_TIMEOUT_SECONDS)
    return true
end

function CancelAuctionsController:OpenCancelAuctions(reason)
    SessionLog("CancelAuctionsController: open reason=%s", tostring(reason or "unknown"))
    return self:Refresh()
end

function CancelAuctionsController:TraceCancelEvaluationForItemID(itemID, callback)
    itemID = tonumber(itemID)
    local trace = {
        command = "canceltrace " .. tostring(itemID),
        itemID = itemID,
        ownerKey = OwnerKey(),
        owner = PlayerOwnerName(),
        startedMs = NowMs(),
        startedAt = date and date("%Y-%m-%d %H:%M:%S") or tostring(time and time() or ""),
        timings = {},
        ownedObservation = nil,
        rawBlizzardOwnedRowsMatchingItemID = {},
        rawOwnedRowsMatchingItemID = {},
        cancelRows = {},
        targetRows = {},
        evaluations = {},
    }
    trace.timings.commandStartedMs = trace.startedMs

    local function Finish(reason)
        trace.completedReason = reason
        trace.timings.completedMs = NowMs()
        trace.totalElapsedMs = ElapsedMs(trace.startedMs)
        if type(callback) == "function" then
            callback(trace)
        end
    end

    if not itemID then
        trace.error = "invalidItemID"
        Finish("invalidItemID")
        return false, "invalidItemID"
    end

    if C_AuctionHouse and type(C_AuctionHouse.GetOwnedAuctions) == "function" then
        local ok, rawAuctions = pcall(C_AuctionHouse.GetOwnedAuctions)
        if ok and type(rawAuctions) == "table" then
            for index, auction in ipairs(rawAuctions) do
                if AuctionItemID(auction) == itemID then
                    trace.rawBlizzardOwnedRowsMatchingItemID[#trace.rawBlizzardOwnedRowsMatchingItemID + 1] = {
                        index = index,
                        auction = auction,
                        auctionID = GetAuctionID(auction),
                        itemID = AuctionItemID(auction),
                        status = auction.status,
                        excludedReason = auction.status ~= nil and tonumber(auction.status) ~= 0 and "nonActiveStatus" or nil,
                    }
                end
            end
        else
            trace.rawBlizzardOwnedRowsError = ok and "non-table-result" or tostring(rawAuctions)
        end
    else
        trace.rawBlizzardOwnedRowsError = "C_AuctionHouse.GetOwnedAuctions unavailable"
    end

    local function ContinueWithObservation(observation, observationReason)
        trace.timings.ownedRowsAvailableMs = NowMs()
        trace.ownedObservation = observation
        trace.ownedObservationReason = observationReason
        local ownedRows = observation and observation.rows or {}
        for index, auction in ipairs(ownedRows or {}) do
            if AuctionItemID(auction) == itemID then
                trace.rawOwnedRowsMatchingItemID[#trace.rawOwnedRowsMatchingItemID + 1] = {
                    index = index,
                    auction = auction,
                    auctionID = GetAuctionID(auction),
                    includedByScanner = true,
                    excludedReason = nil,
                    ownerDecision = auction.ownerKey ~= nil and tostring(auction.ownerKey) == tostring(trace.ownerKey) or auction.ownerKey == nil,
                }
            end
        end

        local traceController = {
            rows = {},
            evaluating = false,
            generation = 0,
            rowsChangedCallback = nil,
        }
        setmetatable(traceController, { __index = self })
        traceController:BuildRowsFromOwnedAuctions(ownedRows)
        trace.cancelRows = traceController.rows or {}
        for _, row in ipairs(trace.cancelRows or {}) do
            if tonumber(row and row.itemID) == itemID then
                trace.targetRows[#trace.targetRows + 1] = row
            end
        end

        if #trace.targetRows == 0 then
            Finish("noMatchingCancelRows")
            return
        end

        local ladder = GetMarketLadderService()
        local evaluator = GetCancelEvaluation()
        if not ladder or type(ladder.BuildForTarget) ~= "function" or not evaluator or type(evaluator.Evaluate) ~= "function" then
            trace.error = "cancelEvaluationUnavailable"
            trace.ladderAvailable = ladder ~= nil
            trace.evaluatorAvailable = evaluator ~= nil
            Finish("cancelEvaluationUnavailable")
            return
        end

        local rowIndex = 1
        local function EvaluateNextTraceRow()
            local row = trace.targetRows[rowIndex]
            if not row then
                Finish("complete")
                return
            end

            local evaluation = {
                rowIndex = rowIndex,
                row = row,
                rowBefore = {
                    rowID = row.rowID,
                    groupKey = row.groupKey,
                    auctionIDs = CopyArray(row.auctionIDs),
                    quantity = row.quantity,
                    price = row.price,
                    duration = row.duration,
                    status = row.status,
                    note = row.note,
                },
            }
            trace.evaluations[#trace.evaluations + 1] = evaluation

            row.evaluationStartedMs = NowMs()
            row.candidate = row
            evaluation.target = {
                source = "ownedAuctionRow",
                configKey = row.configKey,
                identity = row.identity,
                auctionPath = row.auctionPath,
            }
            evaluation.timings = {
                ladderLookupStartedMs = NowMs(),
            }

            ladder:BuildForTarget(BuildOwnedAuctionTarget(row), function(ladderResult)
                evaluation.timings.ladderCallbackReceivedMs = NowMs()
                evaluation.ladderMeta = ladderResult
                evaluation.rawAuctions = ladderResult and ladderResult.discoveryResult and ladderResult.discoveryResult.candidates or {}
                evaluation.matchAnalysis = ladderResult and ladderResult.discovery or nil
                local matchedAuctions = ladderResult and ladderResult.discoveryResult and ladderResult.discoveryResult.matchingAuctions or {}
                evaluation.matchedAuctions = matchedAuctions or {}
                evaluation.ownedAuctionIDSetCount = ladderResult and ladderResult.ownershipCoverage and ladderResult.ownershipCoverage.ownedAuctionIDCount or nil

                evaluation.timings.positionServiceStartedMs = NowMs()
                evaluation.positionTrace = evaluator:BuildTrace(row, {
                    ladderResult = ladderResult,
                    matchedAuctions = matchedAuctions,
                })
                evaluation.timings.positionServiceCompletedMs = NowMs()

                local evalController = {
                    rows = { row },
                    evaluating = false,
                    generation = 0,
                    rowsChangedCallback = nil,
                }
                setmetatable(evalController, { __index = self })
                evalController:ApplyEvaluation(row, evaluator:Evaluate(row, {
                    ladderResult = ladderResult,
                    matchedAuctions = matchedAuctions,
                }))
                evaluation.controllerRowsAfter = evalController.rows or {}
                evaluation.finalRow = row
                evaluation.controllerMapping = {
                    serviceResults = evaluation.positionTrace and evaluation.positionTrace.auctionResults or {},
                    rowStatusAssigned = row.status,
                    rowNoteAssigned = row.note,
                    rowAuctionIDsAfter = CopyArray(row.auctionIDs),
                    finalCancelRecommendation = row.status == "Undercut",
                    rowCountAfter = #(evalController.rows or {}),
                    undercutRowsAfter = CountStatus(evalController.rows, "Undercut"),
                    okRowsAfter = CountStatus(evalController.rows, "OK"),
                }

                rowIndex = rowIndex + 1
                EvaluateNextTraceRow()
            end)
        end

        EvaluateNextTraceRow()
    end

    local immediateObservation, immediateReason = self:GetImmediateOwnedObservation()
    if immediateObservation then
        ContinueWithObservation(immediateObservation, immediateReason)
        return true
    end

    local ahManager = PocketCFO_AH:GetModule("AHManager", true)
    if not ahManager or not ahManager.RequestOwnedAuctionsRefresh then
        trace.error = "ownedAuctionRefreshUnavailable"
        Finish("ownedAuctionRefreshUnavailable")
        return false, "ownedAuctionRefreshUnavailable"
    end

    ahManager:RequestOwnedAuctionsRefresh("canceltrace", function(ok, observation, err)
        trace.ownedRefreshOK = ok == true
        trace.ownedRefreshError = err
        ContinueWithObservation(observation, ok and "refresh-callback" or ("refresh-" .. tostring(err or "unavailable")))
    end, OWNED_AUCTION_REFRESH_TIMEOUT_SECONDS)
    return true
end

-- Routes cancel inventory movement through InventoryStateService as an adjustment
-- (ah -quantity, mail +quantity). Best-known current-state only; the item does not
-- actually land in the mailbox until Blizzard processes the cancel server-side, but
-- this is the same evidence-first approach used for posts. The next authoritative
-- AH scan clears the AH-side adjustment; the next mailbox scan clears the mail-side one.
function CancelAuctionsController:ApplyCancelInventoryAdjustment(auctionID, hint)
    local listing = nil
    local ahListing = GetAHListingService()
    if ahListing and ahListing.GetListing then
        listing = ahListing:GetListing(auctionID)
    end

    local ownerKey = (hint and hint.ownerKey) or (listing and listing.ownerKey) or OwnerKey()
    local quantity = PositiveQuantity((hint and hint.quantity) or (listing and listing.quantity))

    if quantity <= 0 then
        SessionLog("CancelAuctionsController: cancel inventory adjustment skipped reason=missing-quantity auctionID=%s",
            tostring(auctionID))
        return false, "missingQuantity"
    end
    if not ownerKey or ownerKey == "" then
        SessionLog("CancelAuctionsController: cancel inventory adjustment skipped reason=missing-ownerKey auctionID=%s",
            tostring(auctionID))
        return false, "missingOwnerKey"
    end

    local inventoryState = GetInventoryStateService()
    if not inventoryState or not inventoryState.RecordAuctionCancelled then
        SessionLog("CancelAuctionsController: cancel inventory adjustment skipped reason=inventory-state-service-unavailable auctionID=%s",
            tostring(auctionID))
        return false, "inventoryStateServiceUnavailable"
    end

    local evidence = {
        configKey       = (hint and hint.configKey) or (listing and listing.configKey),
        itemID          = (hint and hint.itemID) or (listing and listing.itemID),
        itemName        = (hint and hint.itemName) or (listing and listing.itemName),
        itemLink        = (hint and hint.itemLink) or (listing and listing.itemLink),
        itemQuality     = (hint and hint.itemQuality) or (listing and listing.itemQuality),
        craftingQuality = (hint and hint.craftingQuality) or (listing and listing.craftingQuality),
        rarityQuality   = (hint and hint.rarityQuality) or (listing and listing.rarityQuality),
        ilvl            = (hint and hint.ilvl) or (listing and listing.ilvl),
        statFingerprint = (hint and hint.statFingerprint) or (listing and listing.statFingerprint),
        isStackable     = (hint and hint.isStackable) or (listing and listing.isStackable),
    }

    if not evidence.configKey and not evidence.itemLink and not evidence.itemID then
        SessionLog("CancelAuctionsController: cancel inventory adjustment identity missing auctionID=%s hintPresent=%s listingFound=%s",
            tostring(auctionID), tostring(hint ~= nil), tostring(listing ~= nil))
    end

    local adjustments, err = inventoryState:RecordAuctionCancelled(ownerKey, evidence, quantity, {
        reason    = "ah-cancel",
        itemID    = evidence.itemID,
        itemName  = evidence.itemName,
        itemLink  = evidence.itemLink,
        auctionID = auctionID,
    })

    if not adjustments then
        SessionLog("CancelAuctionsController: cancel inventory adjustment failed owner=%s auctionID=%s quantity=%d err=%s",
            tostring(ownerKey), tostring(auctionID), quantity, tostring(err))
        return false, err
    end

    SessionLog("CancelAuctionsController: cancel inventory adjustment written owner=%s auctionID=%s quantity=%d ahAdjustmentID=%s mailAdjustmentID=%s",
        tostring(ownerKey), tostring(auctionID), quantity,
        tostring(adjustments[1] and adjustments[1].adjustmentID), tostring(adjustments[2] and adjustments[2].adjustmentID))
    return true, nil
end

-- Fired by the CancelAuction hook for every cancel request, regardless of which
-- UI or addon issued it. This is the single place that marks listing lifecycle
-- and applies inventory movement for cancels, so a cancel issued through this
-- controller's own CancelSelectedRow (which also calls C_AuctionHouse.CancelAuction,
-- and is therefore observed by this same hook) is not double-processed.
function CancelAuctionsController:HandleCancelAuctionObserved(auctionID)
    if auctionID == nil then
        return
    end
    local key = tostring(auctionID)
    local hint = self.pendingCancelHints and self.pendingCancelHints[key]
    if self.pendingCancelHints then
        self.pendingCancelHints[key] = nil
    end

    SessionLog("CancelAuctionsController: CancelAuction observed auctionID=%s source=%s",
        tostring(auctionID), hint and "pocketcfo_ui" or "external")

    local ahListing = GetAHListingService()
    if ahListing and ahListing.MarkCancelled then
        ahListing:MarkCancelled(auctionID, { source = hint and "cancel_workflow" or "cancel_observed_external" })
    end

    self:ApplyCancelInventoryAdjustment(auctionID, hint)
end

function CancelAuctionsController:HookCancelMethod()
    if self.cancelHookInstalled or not C_AuctionHouse or not hooksecurefunc or not C_AuctionHouse.CancelAuction then
        return
    end
    hooksecurefunc(C_AuctionHouse, "CancelAuction", function(auctionID)
        self:HandleCancelAuctionObserved(auctionID)
    end)
    self.cancelHookInstalled = true
    SessionLog("CancelAuctionsController: CancelAuction hook installed")
end

function CancelAuctionsController:OnEnable()
    self:HookCancelMethod()
end

function CancelAuctionsController:CancelSelectedRow(row)
    if self.cancelInProgress == true then
        SessionLog("CancelAuctionsController: cancel ignored reason=cancel-in-progress rowID=%s",
            tostring(row and row.rowID))
        return false, "cancelInProgress"
    end
    if not self:CanCancelRow(row) then
        return false, "rowNotCancelable"
    end
    self.cancelInProgress = true
    self:NotifyRowsChanged("cancel-processing-started")

    local function FinishCancel(reason)
        self.cancelInProgress = false
        SessionLog("CancelAuctionsController: cancel processing finished reason=%s", tostring(reason))
    end

    if not C_AuctionHouse or type(C_AuctionHouse.CancelAuction) ~= "function" then
        row.note = "Cancel auction API unavailable."
        row.notes = row.note
        FinishCancel("cancel-api-unavailable")
        self:NotifyRowsChanged("cancel-failed")
        return false, "cancelApiUnavailable"
    end

    local auction = row.auctions and row.auctions[1] or nil
    local auctionID = GetAuctionID(auction)
    local canceledQuantity = AuctionQuantity(auction)
    local sourceAuctionCountBefore = #(row.auctions or {})
    local rowCountBefore = #(self.rows or {})
    SessionLog("CancelAuctionsController: cancel transition start rowID=%s auctionID=%s status=%s sourceAuctionsBefore=%d rowsBefore=%d undercutBefore=%d",
        tostring(row.rowID), tostring(auctionID), tostring(row.status),
        sourceAuctionCountBefore, rowCountBefore, CountStatus(self.rows, "Undercut"))
    if auctionID == nil then
        row.note = "Missing auction ID."
        row.notes = row.note
        FinishCancel("missing-auction-id")
        self:NotifyRowsChanged("cancel-failed")
        return false, "missingAuctionID"
    end

    -- Stash rich identity/quantity for HandleCancelAuctionObserved (fired by the
    -- CancelAuction hook below) so cancels made through this UI keep the precise
    -- identity already known here, instead of falling back to the listing lookup
    -- used for cancels observed from outside PocketCFO.
    self.pendingCancelHints = self.pendingCancelHints or {}
    self.pendingCancelHints[tostring(auctionID)] = {
        ownerKey        = row.ownerKey,
        configKey       = (auction and auction.configKey) or row.configKey,
        itemID          = (auction and auction.itemID) or row.itemID,
        itemName        = (auction and auction.itemName) or row.itemName,
        itemLink        = (auction and auction.itemLink) or row.itemLink,
        itemQuality     = (auction and auction.itemQuality) or row.itemQuality,
        craftingQuality = auction and auction.craftingQuality,
        rarityQuality   = auction and auction.rarityQuality,
        ilvl            = (auction and auction.ilvl) or row.ilvl,
        statFingerprint = (auction and auction.statFingerprint) or row.statFingerprint,
        isStackable     = (auction and (auction.isStackable or auction.isCommodity)) or row.isCommodity,
        quantity        = canceledQuantity,
    }

    local ok, err = pcall(C_AuctionHouse.CancelAuction, auctionID)
    if not ok then
        self.pendingCancelHints[tostring(auctionID)] = nil
        row.note = "Cancel request failed."
        row.notes = row.note
        SessionLog("CancelAuctionsController: cancel failed auctionID=%s err=%s", tostring(auctionID), tostring(err))
        FinishCancel("cancel-failed")
        self:NotifyRowsChanged("cancel-failed")
        return false, err or "cancelFailed"
    end

    -- Lifecycle marking and inventory movement both happen synchronously inside
    -- the pcall above, via the CancelAuction hook (HandleCancelAuctionObserved) -
    -- hooksecurefunc runs before pcall returns. This keeps a single adjustment
    -- path regardless of whether the cancel is issued by this UI or elsewhere.

    table.remove(row.auctions, 1)
    ApplyRowTotals(row)
    local sourceAuctionCountAfter = #(row.auctions or {})

    local canceledRow = {
        rowID = tostring(row.rowID) .. ":canceled:" .. tostring(auctionID),
        itemName = row.itemName,
        item = row.item,
        itemID = row.itemID,
        itemLink = row.itemLink,
        price = row.price,
        duration = row.duration,
        ownerKey = row.ownerKey,
        owner = row.owner,
        auctions = { auction },
        auctionIDs = { auctionID },
        auctionID = auctionID,
        quantity = canceledQuantity,
        quantityPosted = canceledQuantity,
        status = "Canceled",
        note = "Cancel requested.",
        notes = "Cancel requested.",
        cancel = { pending = false },
    }
    self.rows[#self.rows + 1] = canceledRow
    local canceledRowAdded = true

    local sourceRemoved = false
    if #(row.auctions or {}) == 0 then
        sourceRemoved = RemoveRow(self.rows, row)
    else
        local evaluator = GetCancelEvaluation()
        local remainingMatchedAuctions = evaluator and evaluator.WithoutAuctionID
            and evaluator:WithoutAuctionID(row.cancelMatchedAuctions, auctionID)
            or {}
        row.status = "Evaluating"
        row.note = ""
        row.notes = ""
        self:ApplyEvaluation(row, evaluator and evaluator:Evaluate(row, {
            matchedAuctions = remainingMatchedAuctions,
        }) or nil)
    end

    local rowCountBeforeSort = #(self.rows or {})
    SortRows(self.rows)
    local rowCountAfterSort = #(self.rows or {})
    local undercutAfter = CountStatus(self.rows, "Undercut")
    SessionLog("CancelAuctionsController: cancel transition applied rowID=%s auctionID=%s sourceAuctionsBefore=%d sourceAuctionsAfter=%d sourceRemoved=%s canceledRowAdded=%s rowsBefore=%d rowsBeforeSort=%d rowsAfterSort=%d undercutAfter=%d",
        tostring(row.rowID), tostring(auctionID), sourceAuctionCountBefore, sourceAuctionCountAfter,
        tostring(sourceRemoved), tostring(canceledRowAdded), rowCountBefore, rowCountBeforeSort,
        rowCountAfterSort, undercutAfter)

    -- A successful CancelAuction call only means the request was submitted, not that
    -- the AH has finished processing it server-side. Keep the lock held until a guarded
    -- completion window passes so the user cannot spam another cancel into the queue.
    local generation = self.generation
    self:NotifyRowsChanged("cancel-requested")
    SessionLog("CancelAuctionsController: cancel requested auctionID=%s item=%s remainingInRow=%d",
        tostring(auctionID), tostring(row.itemName), #(row.auctions or {}))

    C_Timer.After(0.8, function()
        if self.generation ~= generation then
            return
        end
        self.cancelInProgress = false
        SessionLog("CancelAuctionsController: cancel processing finished reason=cancel-processing-complete")
        self:NotifyRowsChanged("cancel-processing-complete")
    end)

    return true
end

function CancelAuctionsController:GetFirstCancelableIndex()
    return FirstCancelableIndex(self.rows)
end
