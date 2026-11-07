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
        -- Smart AH view (SmartPricing.lua): floor/ceiling details for the
        -- evaluator's smart branch and the row Notes.
        smart = rule and rule.smart == true or nil,
        bounds = rule and rule.bounds or nil,
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
            item = PocketCFO_AH.ItemDisplayName(candidate),
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
    -- Smart view: starting price shown on skipped rows; a fresh evaluation
    -- clears any in-place overrides.
    row.evaluation.suggestedPrice = result and result.suggestedPrice or nil
    row.evaluation.suggestedQuantity = result and result.suggestedQuantity or nil
    -- Smart view: a price we picked ourselves; "Check the price" group.
    row.evaluation.check = result and result.check == true or nil
    -- Smart view: the AH search didn't finish; re-checked once (RetryLoadingPrices).
    row.evaluation.searchIncomplete = result and result.searchIncomplete == true or nil
    row.overrides = nil
    row.smartEvaluation = nil
    row.posting.postedCount = 0
    row.posting.remainingToPost = row.evaluation.toPost
    row.posting.pending = false
    ApplyEvaluationAliases(row)
end

function PostingController:MarketSettingsForRow(row)
    local rule = row and row.resolvedRule
    if rule and rule.smart then
        -- Smart view: real market value, so listings far below it are
        -- treated as bait, not competition.
        return {
            marketValue = rule.bounds and rule.bounds.marketValue or nil,
            protectionPct = GetProtectionPct(),
        }
    end
    return {
        marketValue = GetMarketValue(row),
        protectionPct = GetProtectionPct(),
    }
end

-- ---------------------------------------------------------------------------
-- Smart view: in-place overrides (this post only, never saved) and Keep.
-- ---------------------------------------------------------------------------

local function FormatGold(copper)
    copper = tonumber(copper)
    if not copper then
        return ""
    end
    -- Two biggest coins (core PocketCFO:FormatMoney, 2026-11-05).
    return PocketCFO:FormatMoney(copper)
end

local function OverrideNote(row)
    local overrides = row.overrides or {}
    local parts = {}
    if overrides.price then parts[#parts + 1] = "price" end
    if overrides.quantity then parts[#parts + 1] = "quantity" end
    if overrides.duration then parts[#parts + 1] = "duration" end
    if #parts == 0 then
        return nil
    end
    local note = "Your " .. table.concat(parts, " and ") .. "."
    local floor = row.resolvedRule and row.resolvedRule.bounds and row.resolvedRule.bounds.floor
    local price = tonumber(row.evaluation and row.evaluation.price)
    if overrides.price and floor and price and price < floor then
        local source = row.resolvedRule.bounds.floorSource
        if source == "disenchant" then
            note = note .. " Below disenchant value (" .. FormatGold(floor) .. ")."
        elseif source == "vendor" then
            note = note .. " Below vendor price."
        else
            note = note .. " Below what it costs to make (" .. FormatGold(floor) .. ")."
        end
    end
    return note
end

-- field = "price" (copper) | "quantity" | "duration" (12/24/48). value nil =
-- put the smart value back. Returns true when the row changed.
function PostingController:ApplyOverride(row, field, value)
    if type(row) ~= "table" or type(row.evaluation) ~= "table" then
        return false
    end
    if row.posting and row.posting.pending == true then
        return false
    end
    row.overrides = row.overrides or {}
    row.smartEvaluation = row.smartEvaluation or {
        price = row.evaluation.price,
        toPost = row.evaluation.toPost,
        status = row.evaluation.status,
        note = row.evaluation.note,
        shouldPost = row.evaluation.shouldPost,
        duration = row.resolvedRule and row.resolvedRule.duration,
    }
    local smartEval = row.smartEvaluation
    local inBags = PositiveQuantity(row.inBags)

    if field == "price" then
        local copper = Copper(value)
        -- Whole silver: PostItem drops prices with copper left over.
        copper = copper and math.floor(copper / 100 + 0.5) * 100 or nil
        if copper and copper > 0 then
            row.evaluation.price = copper
            row.overrides.price = true
        else
            row.evaluation.price = smartEval.price
            row.overrides.price = nil
        end
    elseif field == "quantity" then
        local quantity = math.floor(tonumber(value) or 0)
        if value ~= nil and quantity > 0 then
            -- Post Now is what's left to post: already-posted copies of this
            -- row (1 of 2 for gear) count on top of it.
            local alreadyPosted = PositiveQuantity(row.posting and row.posting.postedCount)
            row.evaluation.toPost = math.min(alreadyPosted + quantity, inBags)
            row.overrides.quantity = true
        else
            row.evaluation.toPost = smartEval.toPost
            row.overrides.quantity = nil
        end
    elseif field == "duration" then
        local duration = value and NormalizeDuration(value, 12) or smartEval.duration
        row.resolvedRule.duration = duration
        row.duration = duration
        row.overrides.duration = (value ~= nil and duration ~= smartEval.duration) or nil
    else
        return false
    end

    local hasPrice = tonumber(row.evaluation.price) ~= nil and tonumber(row.evaluation.price) > 0
    if row.overrides.price or row.overrides.quantity then
        -- An override un-skips a row once it has a price and a Post Now.
        -- Post Now is the one shown on the row: the starting Post Now, never
        -- a made-up quantity. Post Now 0 stays put (Brian, 2026-11-06).
        if hasPrice and PositiveQuantity(row.evaluation.toPost) <= 0 then
            row.evaluation.toPost = PositiveQuantity(row.evaluation.suggestedQuantity)
        end
        if hasPrice and PositiveQuantity(row.evaluation.toPost) > 0 then
            row.evaluation.status = "Ready"
            row.evaluation.shouldPost = true
            row.userSkipped = nil
        else
            row.evaluation.status = smartEval.status
            row.evaluation.shouldPost = smartEval.shouldPost
        end
    else
        row.evaluation.status = smartEval.status
        row.evaluation.shouldPost = smartEval.shouldPost
        row.evaluation.toPost = smartEval.toPost
    end

    if not hasPrice and (row.overrides.quantity) then
        row.evaluation.note = "Type a price to post."
    elseif hasPrice and row.overrides.price and PositiveQuantity(row.evaluation.toPost) <= 0 then
        row.evaluation.note = (OverrideNote(row) or "Your price.") .. " Type in Post Now to post."
    else
        row.evaluation.note = OverrideNote(row) or smartEval.note
    end
    if row.overrides.duration and not (row.overrides.price or row.overrides.quantity) then
        row.evaluation.note = smartEval.note .. " Your duration."
    end

    row.posting.remainingToPost = math.max(0, PositiveQuantity(row.evaluation.toPost) - PositiveQuantity(row.posting.postedCount))
    ApplyEvaluationAliases(row)
    -- A row that changed status moves to its group (e.g. a typed price puts
    -- it in Ready to post) instead of splitting the group it was in (Brian,
    -- 2026-11-06). Stable sort: it lands at the bottom of its new group.
    local evalService = PocketCFO_AH:GetModule("PostingEvaluationPipeline", true)
    if evalService and evalService.SortRows then
        evalService:SortRows(self.rows)
    end
    self:NotifyQueueChanged("override")
    return true
end

-- Skip (smart view): not now, but next time. The row moves to the bottom as
-- Skipped; nothing is saved, so the next Refresh or AH visit offers it again.
-- Typing a price on it un-skips it like any skipped row (Brian, 2026-11-04).
function PostingController:SkipRow(row)
    if type(row) ~= "table" or type(row.evaluation) ~= "table" then
        return false
    end
    if row.posting and row.posting.pending == true then
        return false
    end
    row.overrides = nil
    row.smartEvaluation = nil
    row.evaluation.status = "Skipped"
    row.evaluation.shouldPost = false
    row.evaluation.toPost = 0
    row.evaluation.note = "Skipped by you."
    if PositiveQuantity(row.evaluation.suggestedQuantity) <= 0 then
        local stackSize = PositiveQuantity(row.resolvedRule and row.resolvedRule.bounds
            and row.resolvedRule.bounds.stackSize)
        row.evaluation.suggestedQuantity = math.min(PositiveQuantity(row.inBags), stackSize > 0 and stackSize or 1)
    end
    row.userSkipped = true
    if row.posting then
        row.posting.remainingToPost = 0
    end
    ApplyEvaluationAliases(row)
    local moved = {}
    for _, other in ipairs(self.rows or {}) do
        if other ~= row then
            moved[#moved + 1] = other
        end
    end
    moved[#moved + 1] = row
    self.rows = moved
    -- Skipped sits above Posted in Probably not.
    local evalService = PocketCFO_AH:GetModule("PostingEvaluationPipeline", true)
    if evalService and evalService.SortRows then
        evalService:SortRows(self.rows)
    end
    SessionLog("PostingController: skipped by player item=%s", tostring(row.itemName))
    self:NotifyQueueChanged("skip")
    return true
end

-- Usually Post (smart view): saved per item for the whole account (Brian,
-- 2026-11-04). value nil/0 = back to the default. Rows that are Ready or
-- Listed with no edits re-figure Post Now right away: Usually Post minus ours
-- already selling next. Other rows just get the new starting Post Now.
function PostingController:SetUsuallyPost(row, value)
    local smart = PocketCFO_AH:GetModule("SmartPricing", true)
    if not smart or type(row) ~= "table" or type(row.evaluation) ~= "table" then
        return false
    end
    if row.posting and row.posting.pending == true then
        return false
    end
    local candidate = row.candidate or {}
    local itemKey = row.configKey or candidate.configKey or tostring(candidate.itemID or "")
    if itemKey == "" then
        return false
    end
    smart:SetUsuallyPost(itemKey, value)
    local saved = smart:GetUsuallyPost(itemKey)
    local bounds = row.resolvedRule and row.resolvedRule.bounds
    if bounds then
        bounds.usuallyPost = saved
    end
    local usual = saved or smart:DefaultUsuallyPost(bounds and bounds.stackSize)
    local evaluation = row.evaluation
    local inBags = PositiveQuantity(row.inBags)
    local status = evaluation.status
    local untouched = not (row.overrides and (row.overrides.price or row.overrides.quantity))
        and PositiveQuantity(row.posting and row.posting.postedCount) == 0
    local price = tonumber(evaluation.price) or tonumber(evaluation.suggestedPrice)

    if untouched and (status == "Ready" or status == "Listed") and price and price > 0 then
        local coverage = PositiveQuantity(evaluation.ownedCoverage)
        local postNow = math.min(inBags, math.max(0, usual - coverage))
        evaluation.price = price
        if postNow > 0 then
            evaluation.status = "Ready"
            evaluation.shouldPost = true
            evaluation.toPost = postNow
            if status == "Listed" then
                evaluation.note = "Matched your price. " .. tostring(coverage) .. " of yours already up."
            end
        else
            evaluation.status = "Listed"
            evaluation.shouldPost = false
            evaluation.toPost = 0
            evaluation.suggestedPrice = price
            evaluation.note = "Yours sells next (" .. FormatGold(price) .. "). Type in Post Now to add more."
        end
        -- New starting point for "put the smart value back".
        row.smartEvaluation = nil
        if row.posting then
            row.posting.remainingToPost = evaluation.toPost
        end
    else
        evaluation.suggestedQuantity = math.min(inBags, usual)
    end
    ApplyEvaluationAliases(row)
    local evalService = PocketCFO_AH:GetModule("PostingEvaluationPipeline", true)
    if evalService and evalService.SortRows then
        evalService:SortRows(self.rows)
    end
    SessionLog("PostingController: usually post item=%s key=%s value=%s", tostring(row.itemName), tostring(itemKey), tostring(saved))
    self:NotifyQueueChanged("usually-post")
    return true
end

-- Adds the row's item to this character's Keep list (keep all) and drops
-- every row for it from the current list.
function PostingController:KeepRow(row)
    local smart = PocketCFO_AH:GetModule("SmartPricing", true)
    if not smart or type(row) ~= "table" then
        return false
    end
    if row.posting and row.posting.pending == true then
        return false
    end
    local candidate = row.candidate or {}
    local itemKey = row.configKey or candidate.configKey or tostring(candidate.itemID or "")
    if itemKey == "" then
        return false
    end
    smart:AddKeep(itemKey, {
        itemID = candidate.itemID,
        itemName = candidate.itemName or row.itemName,
        itemLink = candidate.itemLink or row.itemLink,
        configKey = itemKey,
    })
    local kept = {}
    for _, other in ipairs(self.rows or {}) do
        local otherKey = other.configKey or (other.candidate and other.candidate.configKey)
        if otherKey ~= itemKey then
            kept[#kept + 1] = other
        end
    end
    self.rows = kept
    SessionLog("PostingController: kept item=%s key=%s", tostring(row.itemName), tostring(itemKey))
    self:NotifyQueueChanged("keep")
    return true
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

-- Smart view (Brian, 2026-11-06): before building the list, wait for mat
-- data still loading (SmartPricing:PrewarmMats), at most PREWARM_MAX_SECONDS,
-- so Cost to Make estimates work on the first pass. "Preparing possible
-- auctions..." stays up meanwhile. One wait per open (prewarmDone).
local PREWARM_MAX_SECONDS = 5
local PREWARM_POLL_SECONDS = 0.25

function PostingController:OpenPostAuctions(reason)
    if not self.queuePrepared and not self.prewarmDone and C_Timer and C_Timer.After then
        local smart = PocketCFO_AH:GetModule("SmartPricing", true)
        local okWait, waiting = false, false
        if smart and smart.PrewarmMats and smart:IsSmartView() then
            okWait, waiting = pcall(smart.PrewarmMats, smart)
        end
        if okWait and waiting then
            self.prewarmDone = true
            local started = GetTime and GetTime() or 0
            SessionLog("PostingController: waiting for mat data before building the list reason=%s", tostring(reason))
            local function Poll()
                if not (_G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown()) then
                    self.prewarmDone = nil
                    return
                end
                local now = GetTime and GetTime() or started
                local okLoading, loading = pcall(smart.IsPrewarming, smart)
                if okLoading and loading and now - started < PREWARM_MAX_SECONDS then
                    C_Timer.After(PREWARM_POLL_SECONDS, Poll)
                    return
                end
                SessionLog("PostingController: mat data wait done after %.1fs (still loading=%s)",
                    now - started, tostring(okLoading and loading))
                self:OpenPostAuctions(reason)
            end
            C_Timer.After(PREWARM_POLL_SECONDS, Poll)
            return self.rows
        end
    end
    self.prewarmDone = nil
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

-- Smart view (Brian, 2026-11-06): after /reload the client hasn't loaded
-- mats yet, so the first pass can't estimate Cost to Make ("Loading
-- prices..."); SmartPricing asked for the item data. A moment later, re-check
-- ONLY those rows (new bounds, re-evaluated), not the whole list. Each row is
-- re-checked at most once per list build (row.loadingRetried), so it can
-- never loop: a mat that still hasn't loaded leaves the row on
-- "Loading prices..." until the player clicks Refresh. Never while the
-- player has typed anything, while posting, or with the AH closed.
-- (First version refreshed the whole list on a 30s timer and looped on
-- bags whose pass took longer than 30s.)
local LOADING_RETRY_DELAY = 1.5

local function HasOverrides(rows)
    for _, row in ipairs(rows or {}) do
        if row.overrides and next(row.overrides) ~= nil then
            return true
        end
    end
    return false
end

local function LoadingRows(rows)
    local list = {}
    for _, row in ipairs(rows or {}) do
        local bounds = row.resolvedRule and row.resolvedRule.bounds
        local loading = bounds and bounds.pricesLoading and not row.loadingRetried
        -- Same one-time re-check for a row whose AH search didn't finish.
        local searchFailed = row.evaluation and row.evaluation.searchIncomplete and not row.searchRetried
        if (loading or searchFailed) and row.candidate then
            list[#list + 1] = row
        end
    end
    return list
end

function PostingController:RetryLoadingPrices()
    if #LoadingRows(self.rows) == 0 or not (C_Timer and C_Timer.After) then
        return
    end
    local generation = self.generation
    C_Timer.After(LOADING_RETRY_DELAY, function()
        if self.generation ~= generation then
            return
        end
        if not (_G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown()) then
            return
        end
        if self:IsEvaluationInProgress() or self:IsPostingInProgress() or HasOverrides(self.rows) then
            return
        end
        local smart = PocketCFO_AH:GetModule("SmartPricing", true)
        if not smart then
            return
        end
        local rows = LoadingRows(self.rows)
        if #rows == 0 then
            return
        end
        for _, row in ipairs(rows) do
            row.loadingRetried = true
            if row.evaluation and row.evaluation.searchIncomplete then
                row.searchRetried = true
            end
            local bounds = smart:GetBounds(row.candidate)
            row.resolvedRule.bounds = bounds
            row.resolvedRule.minPrice = tonumber(bounds.floor) or 0
            row.resolvedRule.maxPrice = tonumber(bounds.ceiling)
            row.evaluation.status = "Evaluating"
            row.evaluation.note = nil
            row.status = "Evaluating"
            row.notes = nil
            row.note = nil
        end
        SessionLog("PostingController: re-checking %d row(s) (mat prices loading or AH search unfinished)", #rows)
        self.generation = (tonumber(self.generation) or 0) + 1
        self.evaluating = true
        self:NotifyQueueChanged("evaluation-started")
        self:EvaluateRow(nil, self.generation)
    end)
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
