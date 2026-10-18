-- PocketCFO_AH/Posting/Components/PostingController.lua
-- Builds posting queue rows and evaluates them one at a time.
-- Identity classification is read from queue candidates. No identity logic lives here.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingController = PocketCFO_AH:NewModule("PostingController", "AceEvent-3.0")

local DEFAULT_PROTECTION_PCT = 50
local INITIAL_EVALUATION_DELAY_SECONDS = 1.25
local PENDING_COMPETITION_STATUS = "Pending evaluation"
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

local function PositiveNumber(value)
    value = tonumber(value)
    if value and value > 0 then
        return value
    end
    return nil
end

local function Copper(value)
    value = tonumber(value)
    if value and value >= 0 then
        return math.floor(value + 0.5)
    end
    return nil
end

local function RuleMaxToPost(rule)
    return PositiveQuantity(rule and (rule.maxToPost or rule.targetPosted))
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

local function RuleSummary(rule)
    if type(rule) ~= "table" then
        return ""
    end
    if rule.mode == "profile" then
        return tostring(rule.profileKey or rule.profileID or "Profile")
    end
    if rule.mode == "custom" then
        return "Custom"
    end
    return tostring(rule.mode or "")
end

local function FormatStatFingerprint(statFingerprint)
    if statFingerprint == nil or tostring(statFingerprint) == "" then
        return nil
    end

    local labels = {}
    for rawPart in string.gmatch(tostring(statFingerprint), "([^|]+)") do
        local part = rawPart
        part = part:gsub("^ITEM_MOD_", "")
        part = part:gsub("_SHORT$", "")
        part = part:gsub("_STAT$", "")
        part = part:gsub("_", " "):lower()
        part = part:gsub("(%a)([%w']*)", function(first, rest)
            return first:upper() .. rest
        end)
        if part ~= "" then
            labels[#labels + 1] = part
        end
    end

    if #labels == 0 then
        return nil
    end
    return table.concat(labels, " / ")
end

-- Returns the matchingPath set on the candidate's effective rule, if any.
local function CandidateMatchingPath(candidate)
    return (candidate and candidate.effectiveRule and candidate.effectiveRule.matchingPath)
        or (candidate and candidate.rule and candidate.rule.matchingPath)
        or (candidate and candidate.target and candidate.target.matchingPath)
        or candidate and candidate.matchingPath
end

-- Display name includes the stat label suffix only when the rule's matching path
-- requires stat-variant differentiation.
local function GetPostingDisplayName(candidate)
    local name = candidate and candidate.itemName
    if (not name or name == "") and candidate and candidate.itemID then
        name = "Item " .. tostring(candidate.itemID)
    end
    name = tostring(name or "")

    local matchingPath = CandidateMatchingPath(candidate)
    local showStatVariant = tostring(matchingPath or "") == "itemID_ilvl_stat"
    if not showStatVariant then
        return name
    end

    local statLabel = FormatStatFingerprint(candidate and candidate.statFingerprint)
    if statLabel and name:find(" - " .. statLabel, 1, true) == nil then
        return name .. " - " .. statLabel
    end
    return name
end

-- Builds the posting target descriptor from a queue candidate.
-- isCommodity and identity fields (itemClassID, equipLoc, effectiveItemLevel,
-- statFingerprint) are read directly from the candidate; PostingQueuePipeline already
-- ran the identity adapter and commodity detection before producing candidates.
-- The matching-path shape (stat variant vs non-variant vs commodity) is derived
-- from the rule's matchingPath, which was set during rule resolution.
local function BuildTargetFromCandidate(candidate)
    if type(candidate) ~= "table" then
        return {
            postAPI = "PostItem",
            classificationSource = "missing-candidate",
        }
    end

    local isCommodity = candidate.isCommodity == true
    local postAPI = isCommodity and "PostCommodity" or "PostItem"
    local classificationSource = isCommodity and "candidate.isCommodity" or "default-item-auction"

    local savedMatchingPath = (candidate.effectiveRule and candidate.effectiveRule.matchingPath)
        or (candidate.rule and candidate.rule.matchingPath)

    -- "itemID_ilvl_stat" is the only matching path that requires per-stat variant matching.
    local usesStatVariant = tostring(savedMatchingPath or "") == "itemID_ilvl_stat"

    local itemID = tonumber(candidate.itemID)
    local effectiveItemLevel = PositiveNumber(
        candidate.effectiveItemLevel or candidate.itemLevel or candidate.ilvl)
    local statFingerprint = candidate.statFingerprint
    if statFingerprint ~= nil and tostring(statFingerprint) == "" then
        statFingerprint = nil
    end

    local target = {
        itemID = itemID,
        targetItemID = itemID,
        debugItemID = itemID,
        configKey = candidate.configKey or candidate.identity and candidate.identity.configKey,
        identity = candidate.identity,
        itemName = candidate.itemName,
        itemLink = candidate.itemLink,
        itemClassID = candidate.itemClassID,
        itemSubClassID = candidate.itemSubClassID,
        equipLoc = candidate.equipLoc,
        effectiveItemLevel = effectiveItemLevel,
        statFingerprint = statFingerprint,
        targetQuality = PositiveNumber(
            candidate.craftingQuality or candidate.itemQuality or candidate.qualityTier),
        targetIlvl = effectiveItemLevel,
        statTarget = statFingerprint,
        postAPI = postAPI,
        classificationSource = classificationSource,
        matchPath = "nameSearch",
        matchingPath = savedMatchingPath,
        useItemIDMatching = true,
    }

    if isCommodity then
        target.targetQuality = nil
        target.targetIlvl = nil
        target.statTarget = nil
        target.statFingerprint = nil
        target.ignoreCandidateStatFingerprint = true
        target.requireVariantIdentity = false
        target.meaningfulVariant = false
        target.competitionEvaluation = "commodity-lowest"
    elseif usesStatVariant then
        target.ignoreCandidateStatFingerprint = false
        target.requireVariantIdentity = true
        target.meaningfulVariant = true
        target.competitionEvaluation = "variant-lowest-identical"
    else
        target.statTarget = nil
        target.statFingerprint = nil
        target.ignoreCandidateStatFingerprint = true
        target.requireVariantIdentity = false
        target.meaningfulVariant = false
        target.competitionEvaluation = "nonvariant-bait-protected"
    end

    return target
end

local function BuildResolvedRule(rule)
    return {
        maxToPost = RuleMaxToPost(rule),
        minPrice = Copper(rule and rule.minPrice) or 0,
        maxPrice = Copper(rule and rule.maxPrice),
        duration = NormalizeDuration(rule and rule.duration, GetGlobalDuration()),
    }
end

local function GetMarketValue(row)
    return nil
end

local function GetProtectionPct()
    local settings = PocketCFO_AH
        and PocketCFO_AH.db
        and PocketCFO_AH.db.global
        and PocketCFO_AH.db.global.postingSettings
        or nil
    local priceProtection = settings and settings.priceProtection or nil
    if priceProtection and priceProtection.enabled == false then
        return nil
    end
    local pct = priceProtection and tonumber(priceProtection.ignoreBelowMarketPct) or nil
    if not pct or pct <= 0 then
        return DEFAULT_PROTECTION_PCT
    end
    if pct <= 1 then
        return pct * 100
    end
    return pct
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

function PostingController:SetQueueChangedCallback(callback)
    self.queueChangedCallback = type(callback) == "function" and callback or nil
end

function PostingController:NotifyQueueChanged(reason)
    if self.queueChangedCallback then
        self.queueChangedCallback(self.rows or {}, reason)
    end
end

function PostingController:GetRows()
    return self.rows or {}
end

function PostingController:IsEvaluationInProgress()
    if self.evaluating == true then
        return true
    end

    for _, row in ipairs(self.rows or {}) do
        local status = row and row.evaluation and row.evaluation.status or row and row.status
        if status == "Evaluating"
        or status == "Pending evaluation"
        or status == "Refreshing owned auctions..." then
            return true
        end
    end
    return false
end

function PostingController:IsPostingInProgress()
    local exec = PocketCFO_AH:GetModule("PostingExecution", true)
    return exec and exec.IsPostingInProgress and exec:IsPostingInProgress() == true or false
end

function PostingController:GetMatchDebugReports()
    local reports = {}
    for _, row in ipairs(self.rows or {}) do
        if row.matchDebug then
            reports[#reports + 1] = row.matchDebug
        end
    end
    return reports
end

function PostingController:BuildInitialQueue()
    local queue = PocketCFO_AH:GetModule("PostingQueuePipeline", true)
    local candidates = queue and queue:BuildCandidates({ ownerKey = OwnerKey() }) or {}
    local rows = {}
    local ownerKey = OwnerKey()
    local ownerName = PlayerOwnerName()

    for index, candidate in ipairs(candidates or {}) do
        local rule = candidate.effectiveRule or candidate.rule or {}
        local inBags = PositiveQuantity(candidate.bagQuantity or candidate.quantity)
        local resolvedRule = BuildResolvedRule(rule)
        local target = BuildTargetFromCandidate(candidate)

        rows[#rows + 1] = {
            rowID = tostring(index) .. ":" .. tostring(candidate.itemKey or candidate.itemID or candidate.itemName or ""),
            ruleID = tostring(rule.ruleKey or rule.sourceKey or candidate.recipeID or candidate.itemKey or ""),
            ruleType = candidate.sourceType == "recipe" and "recipe" or "item",
            configKey = candidate.configKey or candidate.identity and candidate.identity.configKey,
            identity = candidate.identity,
            itemName = candidate.itemName,
            itemLink = candidate.itemLink,
            itemKey = candidate.itemKey,
            item = GetPostingDisplayName(candidate),
            inBags = inBags,
            have = inBags,
            isStackable = candidate.isStackable == true,
            ownerKey = ownerKey,
            owner = ownerName,
            candidate = candidate,
            target = target,
            postAPI = target.postAPI,
            matchPath = target.matchPath,
            classificationSource = target.classificationSource,
            resolvedRule = resolvedRule,
            postingRules = RuleSummary(rule),
            duration = resolvedRule.duration,
            evaluation = {
                status = PENDING_COMPETITION_STATUS,
                note = PENDING_COMPETITION_STATUS,
                shouldPost = false,
                price = nil,
                toPost = 0,
                lowestAuction = nil,
                ownedLowestQuantity = 0,
                ownedNextBuyCoverage = 0,
            },
            posting = {
                postedCount = 0,
                remainingToPost = 0,
                pending = false,
            },
            status = PENDING_COMPETITION_STATUS,
            notes = PENDING_COMPETITION_STATUS,
            note = PENDING_COMPETITION_STATUS,
            toPost = 0,
            postingPrice = nil,
            price = nil,
            selectable = false,
        }
    end

    self.rows = rows
    self.evaluating = false
    SessionLog("PostingController: candidates built rows=%d", #rows)
    return rows
end

function PostingController:ApplyEvaluation(row, result)
    row.canonicalEvaluation = result
    row.evaluation.shouldPost = result and result.shouldPost == true or false
    row.evaluation.price = result and result.price or nil
    row.evaluation.toPost = PositiveQuantity(result and result.toPost)
    row.evaluation.status = result and result.status or "Skipped"
    row.evaluation.note = result and result.note or "Skipped: evaluation did not return a decision."
    row.evaluation.lowestAuction = result and result.lowestAuction or nil
    row.evaluation.ownedLowestQuantity = PositiveQuantity(result and result.ownedLowestQuantity)
    row.evaluation.ownedNextBuyCoverage = PositiveQuantity(result and result.ownedNextBuyCoverage)
    row.evaluation.canonical = result
    row.evaluation.decisionCode = result and result.decisionCode or nil
    row.evaluation.rawAuctionCount = result and result.rawAuctionCount or nil
    row.evaluation.matchedCompetitorCount = result and result.matchedCompetitors and #result.matchedCompetitors or nil
    row.evaluation.rejectedAuctionCount = result and result.rejectedAuctions and #result.rejectedAuctions or nil
    row.evaluation.lowestMatchingPrice = result and result.lowestMatchingPrice or nil
    row.evaluation.ownedCoverage = result and result.ownedCoverage or nil
    row.evaluation.remainingToPost = result and result.remainingToPost or nil
    row.posting.postedCount = 0
    row.posting.remainingToPost = row.evaluation.toPost
    row.posting.pending = false
    ApplyEvaluationAliases(row)
end

function PostingController:MarketSettingsForRow(row)
    return {
        marketValue = GetMarketValue(row),
        protectionPct = GetProtectionPct(),
    }
end

function PostingController:EvaluateRow(index, generation)
    local evalService = PocketCFO_AH:GetModule("PostingEvaluationPipeline", true)
    if not evalService then
        return
    end
    evalService:EvaluateRow(self, generation)
end

function PostingController:StartEvaluation()
    self.generation = (tonumber(self.generation) or 0) + 1
    self.evaluating = true
    for _, row in ipairs(self.rows or {}) do
        if row.evaluation and row.evaluation.status == PENDING_COMPETITION_STATUS then
            row.evaluation.status = "Evaluating"
            row.evaluation.note = nil
            row.status = "Evaluating"
            row.notes = nil
            row.note = nil
        end
    end
    self:NotifyQueueChanged("evaluation-started")
    self:EvaluateRow(nil, self.generation)
end

function PostingController:ScheduleEvaluationAfterDelay(reason, generation)
    local gen = generation or self.generation
    SessionLog("PostingController: evaluation delayed %.2fs generation=%s rows=%d reason=%s",
        INITIAL_EVALUATION_DELAY_SECONDS, tostring(gen), #(self.rows or {}), tostring(reason or "unknown"))
    C_Timer.After(INITIAL_EVALUATION_DELAY_SECONDS, function()
        if self.generation == gen then
            SessionLog("PostingController: delayed evaluation started generation=%s rows=%d",
                tostring(gen), #(self.rows or {}))
            self:StartEvaluation()
        else
            SessionLog("PostingController: delayed evaluation skipped staleGeneration=%s currentGeneration=%s",
                tostring(gen), tostring(self.generation))
        end
    end)
end

function PostingController:MarkOwnedAuctionRefreshPending()
    for _, row in ipairs(self.rows or {}) do
        if row.evaluation then
            row.evaluation.status = "Refreshing owned auctions..."
            row.evaluation.note = "Refreshing owned auctions..."
            row.status = "Refreshing owned auctions..."
            row.notes = "Refreshing owned auctions..."
            row.note = "Refreshing owned auctions..."
        end
    end
    self:NotifyQueueChanged("owned-auctions-refreshing")
end

function PostingController:StartAfterOwnedAuctionRefresh(reason, generation)
    local ahManager = PocketCFO_AH:GetModule("AHManager", true)
    if not ahManager or not ahManager.RequestOwnedAuctionsRefresh then
        SessionLog("PostingController: owned auction refresh skipped reason=%s error=manager-unavailable; continuing with last known snapshot",
            tostring(reason or "unknown"))
        self:ScheduleEvaluationAfterDelay(reason, generation)
        return
    end

    self:MarkOwnedAuctionRefreshPending()
    ahManager:RequestOwnedAuctionsRefresh("post-auctions-refresh", function(ok, observation, err)
        if self.generation ~= generation then
            SessionLog("PostingController: owned auction refresh callback skipped staleGeneration=%s currentGeneration=%s",
                tostring(generation), tostring(self.generation))
            return
        end
        if ok then
            SessionLog("PostingController: owned auction refresh ready generation=%s rows=%d snapshotWritten=%s snapshotWriteReason=%s",
                tostring(generation), #(self.rows or {}),
                tostring(observation and observation.snapshotWritten),
                tostring(observation and observation.snapshotWriteReason))
        else
            SessionLog("PostingController: owned auction refresh unavailable generation=%s err=%s; continuing with last known snapshot",
                tostring(generation), tostring(err or "unknown"))
        end
        for _, row in ipairs(self.rows or {}) do
            if row.evaluation and row.evaluation.status == "Refreshing owned auctions..." then
                row.evaluation.status = PENDING_COMPETITION_STATUS
                row.evaluation.note = PENDING_COMPETITION_STATUS
                row.status = PENDING_COMPETITION_STATUS
                row.notes = PENDING_COMPETITION_STATUS
                row.note = PENDING_COMPETITION_STATUS
            end
        end
        self:NotifyQueueChanged("owned-auctions-refreshed")
        self:ScheduleEvaluationAfterDelay(reason, generation)
    end, OWNED_AUCTION_REFRESH_TIMEOUT_SECONDS)
end

function PostingController:InvalidateEvaluation(reason)
    self.generation = (tonumber(self.generation) or 0) + 1
    self.evaluating = false
    SessionLog("PostingController: evaluation invalidated generation=%s reason=%s",
        tostring(self.generation), tostring(reason or "unknown"))
end

function PostingController:PrepareQueueSilent(reason)
    self:BuildInitialQueue()
    self.queuePrepared = true
    SessionLog("PostingController: silent prep done reason=%s rows=%d",
        tostring(reason or "unknown"), #(self.rows or {}))
end

function PostingController:OpenPostAuctions(reason)
    if not self.queuePrepared then
        self:BuildInitialQueue()
    end
    self.queuePrepared = false
    self:NotifyQueueChanged("built")
    self.generation = (tonumber(self.generation) or 0) + 1
    local gen = self.generation
    if reason == "refresh" then
        self:StartAfterOwnedAuctionRefresh(reason, gen)
    else
        self:ScheduleEvaluationAfterDelay(reason, gen)
    end
    return self.rows
end

-- Hard workflow reset: unlocks posting after a stuck/interrupted state (e.g. an internal
-- auction error that left pendingPost set without a confirmation or failure event firing).
-- This only clears lifecycle state - it does not touch inventory, pricing, or evaluation logic.
function PostingController:ResetPostingWorkflowState(reason)
    self:InvalidateEvaluation(reason or "workflow-reset")

    for _, row in ipairs(self.rows or {}) do
        if row.posting then
            row.posting.pending = false
        end
        if row.evaluation and row.evaluation.status == "Posting" then
            row.evaluation.status = PENDING_COMPETITION_STATUS
            row.evaluation.note = PENDING_COMPETITION_STATUS
            row.status = PENDING_COMPETITION_STATUS
            row.notes = PENDING_COMPETITION_STATUS
            row.note = PENDING_COMPETITION_STATUS
        end
    end

    local exec = PocketCFO_AH:GetModule("PostingExecution", true)
    if exec and exec.ResetPendingPost then
        exec:ResetPendingPost(reason)
    elseif exec and exec.ClearPending then
        exec:ClearPending()
    end

    self.queuePrepared = false
    SessionLog("PostingController: posting workflow reset reason=%s rows=%d",
        tostring(reason or "unknown"), #(self.rows or {}))
end

function PostingController:Refresh()
    self:ResetPostingWorkflowState("refresh")
    return self:OpenPostAuctions("refresh")
end

function PostingController:CanPostRow(row)
    if type(row) ~= "table" or type(row.evaluation) ~= "table" or type(row.posting) ~= "table" then
        return false
    end

    return self:IsEvaluationInProgress() ~= true
        and self:IsPostingInProgress() ~= true
        and row.evaluation.status == "Ready"
        and row.evaluation.shouldPost == true
        and PositiveQuantity(row.evaluation.toPost) > PositiveQuantity(row.posting.postedCount)
        and row.posting.pending ~= true
end

-- Re-builds the target descriptor from a candidate at evaluation time.
-- Called by PostingEvaluationPipeline after the item cache has had time to warm.
-- candidate.isCommodity is the authoritative commodity determination set by
-- PostingQueuePipeline (through ItemIdentityService commodity resolution),
-- so no additional classification is needed here.
function PostingController:ReclassifyTarget(candidate)
    return BuildTargetFromCandidate(candidate)
end

function PostingController:PostSelectedRow(row)
    local exec = PocketCFO_AH:GetModule("PostingExecution", true)
    if not exec then
        return false, "executionServiceUnavailable"
    end
    return exec:PostSelectedRow(row)
end

-- Manual recovery entry point: PostingUI -> here -> PostingExecution. Only releases the
-- active posting attempt (PostingExecution owns the actual reset). Does not refresh,
-- rebuild, rescan, or reevaluate the queue.
function PostingController:UnstickPendingPost(reason)
    local exec = PocketCFO_AH:GetModule("PostingExecution", true)
    if not exec or not exec.UnstickPendingPost then
        return false, "executionServiceUnavailable"
    end
    return exec:UnstickPendingPost(reason or "manual-unstick")
end

-- Read-only, best-effort snapshot for the stuck-post diagnostic capture. Merges
-- controller-level state with PostingExecution's own snapshot (which in turn includes
-- PostingEventCapture correlation and recent transitions).
function PostingController:BuildDiagnosticSnapshot(selectedIndex)
    local exec = PocketCFO_AH:GetModule("PostingExecution", true)
    local selectedRow = selectedIndex and self.rows and self.rows[selectedIndex] or nil
    return {
        evaluating         = self:IsEvaluationInProgress(),
        postingInProgress  = self:IsPostingInProgress(),
        generation         = self.generation,
        queuePrepared      = self.queuePrepared,
        rowCount           = #(self.rows or {}),
        selectedRowID      = selectedRow and (selectedRow.rowID or selectedRow.itemKey or selectedRow.itemName) or nil,
        selectedRowCanPost = selectedRow ~= nil and self:CanPostRow(selectedRow) or false,
        execution          = exec and exec.BuildDiagnosticSnapshot and exec:BuildDiagnosticSnapshot() or nil,
    }
end
