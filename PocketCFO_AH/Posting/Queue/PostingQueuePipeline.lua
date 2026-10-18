-- PocketCFO_AH/Posting/Queue/PostingQueuePipeline.lua
-- Queue-generation pipeline only. This gathers inventory candidates, associates
-- them with posting rules, and emits normalized rows for PostingController.

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingQueuePipeline = PocketCFO_AH:NewModule("PostingQueuePipeline")

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function GetOwnerKey()
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.char
        and PocketCFO.db.char.characterGUID
        or nil
end

local function GetInventoryStateService()
    return PocketCFO and PocketCFO.InventoryStateService or _G.InventoryStateService
end

local function GetItemIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function GetPostingRuleRepository()
    return PocketCFO_AH:GetModule("PostingRuleRepository", true)
end

local function GetPostingRuleResolver()
    return PocketCFO_AH:GetModule("PostingRuleResolver", true)
end

local function GetPostingEligibilityService()
    return PocketCFO_AH:GetModule("PostingEligibilityService", true)
end

local function GetEligibilityDiagnostics()
    return PocketCFO_AH:GetModule("PostQueueEligibilityDiagnostics", true)
end

local function Quantity(row)
    return tonumber(row and (row.quantity or row.bagQuantity or row.count or row.stackCount)) or 0
end

local function PositiveQuantity(row)
    local quantity = Quantity(row)
    if quantity > 0 then
        return quantity
    end
    return 0
end

local function CopyIdentityRow(row, identity)
    identity = identity or {}
    return {
        ownerKey = row.ownerKey,
        location = row.location,
        configKey = identity.configKey or row.configKey,
        identity = identity,
        itemID = tonumber(identity.itemID or row.itemID),
        itemName = identity.itemName or row.itemName,
        itemQuality = identity.itemQuality or row.itemQuality,
        craftingQuality = identity.craftingQuality or row.craftingQuality,
        qualityTier = identity.qualityTier or row.qualityTier,
        rarityQuality = identity.rarityQuality or identity.quality or row.rarityQuality,
        ilvl = identity.effectiveIlvl or identity.effectiveItemLevel or row.ilvl,
        itemLevel = identity.effectiveItemLevel or identity.effectiveIlvl or row.itemLevel or row.ilvl,
        itemLink = identity.itemLink or row.itemLink,
        itemClassID = identity.itemClassID or row.itemClassID,
        itemSubClassID = identity.itemSubClassID or row.itemSubClassID,
        equipLoc = identity.equipLoc or identity.inventoryType or row.equipLoc or row.inventoryType,
        statFingerprint = identity.statFingerprint or row.statFingerprint or row.statKey or row.statTarget,
        itemStats = identity.itemStats or row.itemStats,
        isCommodity = identity.isCommodity == true or row.isCommodity == true,
        isStackable = identity.isStackable == true or row.isStackable == true,
        isBound = row.isBound == true,
        quantity = 0,
        bagQuantity = 0,
        sourceSlots = 0,
        sourceBagID = row.bagID or row.sourceBagID or row.bag or row.containerID,
        sourceSlotID = row.slotID or row.sourceSlotID or row.slot,
    }
end

local function ResolveInventoryIdentity(row)
    if type(row) ~= "table" then
        return nil, "missingRow"
    end

    local identityService = GetItemIdentityService()
    if not identityService then
        return nil, "identityServiceUnavailable"
    end

    local identity
    if identityService.FromSnapshotRow then
        identity = identityService:FromSnapshotRow(row)
    elseif identityService.Identify then
        identity = identityService:Identify(row)
    end

    if identity and identity.configKey then
        return identity, nil
    end
    return identity, identity and identity.unresolvedReason or "configKeyUnavailable"
end

local function GetCandidateRows(ownerKey, options)
    if options and options.bagRows then
        return options.bagRows, "override", {
            rawRows = #(options.bagRows or {}),
        }
    end

    local inventory = GetInventoryStateService()
    if inventory and inventory.GetLocationSnapshot then
        local rows = inventory:GetLocationSnapshot(ownerKey, "bags") or {}
        return rows, "inventory-state", {
            rawRows = #rows,
        }
    end

    return {}, "inventory-state-unavailable", {
        rawRows = 0,
        error = "InventoryStateServiceUnavailable",
    }
end

local function AggregatePostingRows(rows)
    local byConfigKey = {}
    local ordered = {}
    local unresolvedRows = 0
    local rawRows = #(rows or {})

    for _, row in ipairs(rows or {}) do
        if type(row) == "table" then
            local identity, err = ResolveInventoryIdentity(row)
            local configKey = identity and identity.configKey
            if not configKey then
                unresolvedRows = unresolvedRows + 1
                SessionLog("PostingQueuePipeline: skipped unresolved inventory row item=%s itemID=%s reason=%s",
                    tostring(row.itemName), tostring(row.itemID), tostring(err))
            else
                local aggregate = byConfigKey[configKey]
                if not aggregate then
                    aggregate = CopyIdentityRow(row, identity)
                    aggregate.aggregationKey = configKey
                    byConfigKey[configKey] = aggregate
                    ordered[#ordered + 1] = aggregate
                else
                    aggregate.itemName = aggregate.itemName or identity.itemName or row.itemName
                    aggregate.itemLink = aggregate.itemLink or identity.itemLink or row.itemLink
                    aggregate.itemClassID = aggregate.itemClassID or identity.itemClassID or row.itemClassID
                    aggregate.itemSubClassID = aggregate.itemSubClassID or identity.itemSubClassID or row.itemSubClassID
                    aggregate.equipLoc = aggregate.equipLoc or identity.equipLoc or identity.inventoryType or row.equipLoc or row.inventoryType
                    aggregate.itemQuality = aggregate.itemQuality or identity.itemQuality or row.itemQuality
                    aggregate.craftingQuality = aggregate.craftingQuality or identity.craftingQuality or row.craftingQuality
                    aggregate.qualityTier = aggregate.qualityTier or identity.qualityTier or row.qualityTier
                    aggregate.rarityQuality = aggregate.rarityQuality or identity.rarityQuality or identity.quality or row.rarityQuality
                    aggregate.ilvl = aggregate.ilvl or identity.effectiveIlvl or identity.effectiveItemLevel or row.ilvl
                    aggregate.itemLevel = aggregate.itemLevel or identity.effectiveItemLevel or identity.effectiveIlvl or row.itemLevel or row.ilvl
                    aggregate.statFingerprint = aggregate.statFingerprint or identity.statFingerprint or row.statFingerprint or row.statKey or row.statTarget
                    aggregate.itemStats = aggregate.itemStats or identity.itemStats or row.itemStats
                    aggregate.isCommodity = aggregate.isCommodity == true or identity.isCommodity == true or row.isCommodity == true
                    aggregate.isStackable = aggregate.isStackable == true or identity.isStackable == true or row.isStackable == true
                    aggregate.isBound = aggregate.isBound == true or row.isBound == true
                end

                local quantity = PositiveQuantity(row)
                aggregate.quantity = (tonumber(aggregate.quantity) or 0) + quantity
                aggregate.bagQuantity = aggregate.quantity
                aggregate.sourceSlots = (tonumber(aggregate.sourceSlots) or 0) + 1
            end
        end
    end

    local commodityRows = 0
    for _, row in ipairs(ordered) do
        if row.isCommodity == true then
            commodityRows = commodityRows + 1
        end
    end

    return ordered, {
        rawRows = rawRows,
        aggregatedRows = #ordered,
        commodityRows = commodityRows,
        unresolvedRows = unresolvedRows,
    }
end

local function ResolveRuleIdentity(sourceType, sourceKey, rawRule, effectiveRule)
    local identityService = GetItemIdentityService()
    if not identityService then
        return nil, "identityServiceUnavailable"
    end

    local evidence = {}
    for key, value in pairs(rawRule or {}) do
        evidence[key] = value
    end
    for key, value in pairs(effectiveRule or {}) do
        if evidence[key] == nil then
            evidence[key] = value
        end
    end

    -- sourceType/sourceKey are metadata for logging only; ItemIdentityService dispatches
    -- on evidence.evidenceType (or evidence.source/evidence.type), so it must be set here.
    evidence.sourceType = sourceType
    evidence.sourceKey = sourceKey
    evidence.recipeID = tonumber(evidence.recipeID or (sourceType == "recipe" and sourceKey)) or evidence.recipeID

    if sourceType == "recipe" then
        evidence.evidenceType = evidence.evidenceType or evidence.source or evidence.type or "recipeOutput"
    elseif sourceType == "noncrafted" then
        evidence.evidenceType = evidence.evidenceType or evidence.source or evidence.type or "item"
    end

    local identity
    if sourceType == "recipe" and identityService.FromRecipeOutput then
        identity = identityService:FromRecipeOutput(evidence.recipeID, evidence)
    elseif identityService.Identify then
        identity = identityService:Identify(evidence)
    end

    if identity and identity.configKey then
        return identity, nil
    end
    return identity, identity and identity.unresolvedReason or "configKeyUnavailable"
end

local function RuleMatchesRow(row, ruleIdentity)
    local identityService = GetItemIdentityService()
    if not identityService or not identityService.Matches then
        return false, {
            rejectReason = "identityMatchingUnavailable",
            rowIdentity = row and row.identity,
            ruleIdentity = ruleIdentity,
        }
    end

    local matches, reason = identityService:Matches(ruleIdentity, row and row.identity)
    return matches == true, {
        ruleIdentity = ruleIdentity,
        rowIdentity = row and row.identity,
        matchResult = {
            matches = matches == true,
            reason = reason,
            matchingPath = ruleIdentity and ruleIdentity.matchingPath,
        },
        rejectReason = matches == true and nil or reason or "notMatched",
    }
end

function PostingQueuePipeline:GetSellableStatus(row)
    if not row or not row.itemID then
        return false, "missingItemID"
    end

    if row.isBound == true then
        return false, "boundItemExcluded"
    end

    local bagID = row.bagID or row.sourceBagID or row.bag or row.containerID
    local slotID = row.slotID or row.sourceSlotID or row.slot
    if not bagID or not slotID then
        return true, "queueEligibilityNoBagSlotContextFallback"
    end

    local svc = GetPostingEligibilityService()
    if svc and svc.IsBagSlotQueueEligible then
        local eligible = svc:IsBagSlotQueueEligible(bagID, slotID, row.itemID)
        return eligible == true, eligible == true and "queueEligible" or "queueEligibilityServiceRejected"
    end
    return true, "queueEligibilityServiceUnavailableFallback"
end

function PostingQueuePipeline:IsSellable(row)
    local sellable = self:GetSellableStatus(row)
    return sellable == true
end

function PostingQueuePipeline:BuildCandidate(row, sourceType, sourceKey, effectiveRule)
    local identity = row and row.identity
    local configKey = row and row.configKey or identity and identity.configKey
    local candidate = {
        itemKey = configKey or tostring(row and row.itemID or sourceKey),
        recipeID = sourceType == "recipe" and tonumber(sourceKey) or nil,
        configKey = configKey,
        identity = identity,
        itemID = tonumber(row and row.itemID),
        itemName = row and row.itemName,
        itemLink = row and row.itemLink,
        itemClassID = row and row.itemClassID,
        itemSubClassID = row and row.itemSubClassID,
        equipLoc = row and row.equipLoc,
        quantity = tonumber(row and row.quantity) or 0,
        bagQuantity = tonumber(row and row.quantity) or 0,
        craftingQuality = row and (row.craftingQuality or row.itemQuality),
        itemLevel = row and (row.itemLevel or row.ilvl),
        effectiveItemLevel = row and (row.itemLevel or row.ilvl),
        statFingerprint = row and row.statFingerprint,
        isCommodity = row and row.isCommodity == true,
        isStackable = row and row.isStackable == true,
        sourceType = sourceType,
        sourceKey = sourceKey,
        rule = effectiveRule,
        effectiveRule = effectiveRule,
    }
    candidate.competitionKey = candidate.configKey or candidate.itemKey
    return candidate
end

local function CandidateDedupeKey(candidate, row)
    return tostring(candidate and (candidate.configKey or candidate.itemKey)
        or row and row.aggregationKey
        or row and row.configKey
        or row and row.itemID
        or "")
end

function PostingQueuePipeline:BuildCandidates(options)
    options = options or {}
    local ownerKey = options.ownerKey or GetOwnerKey()
    local rawBagRows, rowSource, sourceReport = GetCandidateRows(ownerKey, options)
    local bagRows, aggregationReport = AggregatePostingRows(rawBagRows)
    local repository = GetPostingRuleRepository()
    local resolver = GetPostingRuleResolver()
    local diagnostics = GetEligibilityDiagnostics()
    local candidates = {}
    local candidateByKey = {}
    local skipped = {
        unconfigured = 0,
        ignored = 0,
        unsellable = 0,
        duplicateRecipe = 0,
        nonCraftedControlledByRecipe = 0,
        duplicateNonCrafted = 0,
        unresolvedRuleIdentity = 0,
    }

    if diagnostics and diagnostics.BeginRun then
        diagnostics:BeginRun({
            ownerKey = ownerKey,
            source = rowSource,
            bagRowsScanned = #(bagRows or {}),
            rawRowsScanned = #(rawBagRows or {}),
        })
        if diagnostics.EnsureRows then
            diagnostics:EnsureRows(bagRows)
        end
    end

    if not resolver then
        if diagnostics and diagnostics.CompleteRun then
            diagnostics:CompleteRun({ error = "PostingRuleResolverUnavailable" })
        end
        return candidates, { ownerKey = ownerKey, skipped = skipped, error = "PostingRuleResolverUnavailable" }
    end

    if not repository then
        if diagnostics and diagnostics.CompleteRun then
            diagnostics:CompleteRun({ error = "PostingRuleRepositoryUnavailable" })
        end
        return candidates, { ownerKey = ownerKey, skipped = skipped, error = "PostingRuleRepositoryUnavailable" }
    end

    local function AddCandidate(candidate, row)
        local key = CandidateDedupeKey(candidate, row)
        local existing = candidateByKey[key]
        if not existing then
            candidateByKey[key] = candidate
            candidates[#candidates + 1] = candidate
            if diagnostics and diagnostics.RecordCandidateCreated then
                diagnostics:RecordCandidateCreated(row, candidate, true, "matchedRuleCreatedCandidate")
            end
            return true
        end

        if candidate.sourceType == "recipe" and existing.sourceType ~= "recipe" then
            for index, queued in ipairs(candidates) do
                if queued == existing then
                    candidates[index] = candidate
                    break
                end
            end
            candidateByKey[key] = candidate
            if diagnostics and diagnostics.RecordCandidateCreated then
                diagnostics:RecordCandidateCreated(row, candidate, true, "matchedRecipeReplacedNonCraftedCandidate")
            end
            SessionLog("PostingQueuePipeline: recipe candidate replaced noncrafted duplicate item=%s itemID=%s key=%s recipeID=%s itemRule=%s",
                tostring(candidate.itemName), tostring(candidate.itemID), tostring(key), tostring(candidate.recipeID), tostring(existing.sourceKey))
            return true
        end

        if candidate.sourceType == "recipe" then
            skipped.duplicateRecipe = skipped.duplicateRecipe + 1
            if diagnostics and diagnostics.RecordCandidateCreated then
                diagnostics:RecordCandidateCreated(row, candidate, false, "duplicateRecipeCandidate")
            end
            SessionLog("PostingQueuePipeline: skipped duplicate recipe candidate item=%s itemID=%s key=%s existingRecipeID=%s skippedRecipeID=%s",
                tostring(candidate.itemName), tostring(candidate.itemID), tostring(key), tostring(existing.recipeID), tostring(candidate.recipeID))
            return false
        end

        if existing.sourceType == "recipe" then
            skipped.nonCraftedControlledByRecipe = skipped.nonCraftedControlledByRecipe + 1
            if diagnostics and diagnostics.RecordCandidateCreated then
                diagnostics:RecordCandidateCreated(row, candidate, false, "nonCraftedControlledByRecipe")
            end
            SessionLog("PostingQueuePipeline WARNING: skipped noncrafted rule controlled by recipe item=%s itemID=%s key=%s itemRule=%s recipeID=%s",
                tostring(candidate.itemName), tostring(candidate.itemID), tostring(key), tostring(candidate.sourceKey), tostring(existing.recipeID))
            return false
        end

        skipped.duplicateNonCrafted = skipped.duplicateNonCrafted + 1
        if diagnostics and diagnostics.RecordCandidateCreated then
            diagnostics:RecordCandidateCreated(row, candidate, false, "duplicateNonCraftedCandidate")
        end
        SessionLog("PostingQueuePipeline: skipped duplicate noncrafted candidate item=%s itemID=%s key=%s existingRule=%s skippedRule=%s",
            tostring(candidate.itemName), tostring(candidate.itemID), tostring(key), tostring(existing.sourceKey), tostring(candidate.sourceKey))
        return false
    end

    local function EvaluateRuleAgainstRows(sourceType, sourceKey, rawRule, effectiveRule)
        local ruleIdentity, identityErr = ResolveRuleIdentity(sourceType, sourceKey, rawRule, effectiveRule)
        if not ruleIdentity or not ruleIdentity.configKey then
            skipped.unresolvedRuleIdentity = skipped.unresolvedRuleIdentity + 1
            SessionLog("PostingQueuePipeline: skipped rule with unresolved identity sourceType=%s sourceKey=%s evidenceType=%s itemID=%s hasItemLink=%s configKey=%s reason=%s",
                tostring(sourceType), tostring(sourceKey),
                tostring(ruleIdentity and ruleIdentity.evidenceType),
                tostring(ruleIdentity and ruleIdentity.itemID),
                tostring(ruleIdentity and ruleIdentity.itemLink ~= nil),
                tostring(ruleIdentity and ruleIdentity.configKey),
                tostring(identityErr))
            return
        end

        for _, row in ipairs(bagRows or {}) do
            local queueEligible, sellableReason = self:GetSellableStatus(row)
            local matched, matchInfo = false, { rejectReason = sellableReason, ruleIdentity = ruleIdentity, rowIdentity = row.identity }
            if queueEligible then
                matched, matchInfo = RuleMatchesRow(row, ruleIdentity)
            end
            if diagnostics and diagnostics.RecordRuleCheck then
                diagnostics:RecordRuleCheck(row, {
                    ruleKey = tostring(sourceKey),
                    recipeID = sourceType == "recipe" and tonumber(sourceKey) or nil,
                    sellable = queueEligible,
                    sellableReason = sellableReason,
                    ruleIdentity = matchInfo and matchInfo.ruleIdentity,
                    rowIdentity = matchInfo and matchInfo.rowIdentity,
                    matchResult = matchInfo and matchInfo.matchResult,
                    ruleMatchingPath = effectiveRule and effectiveRule.matchingPath,
                    rejectReason = queueEligible and matchInfo and matchInfo.rejectReason or sellableReason,
                })
            end
            if queueEligible and matched then
                AddCandidate(self:BuildCandidate(row, sourceType, sourceKey, effectiveRule), row)
            elseif not queueEligible then
                skipped.unsellable = skipped.unsellable + 1
            end
        end
    end

    for ruleKey, rawRule in pairs(repository:GetRecipeRulesDB()) do
        local effective = resolver:GetEffectiveRecipeRule(ruleKey)
        local recipeID = tonumber(rawRule and rawRule.recipeID) or tonumber(ruleKey) or ruleKey
        if effective then
            EvaluateRuleAgainstRows("recipe", recipeID, rawRule, effective)
        else
            skipped.ignored = skipped.ignored + 1
        end
    end

    for itemKey, rawRule in pairs(resolver:GetNonCraftedRulesDB()) do
        local effective = resolver:GetEffectiveNonCraftedRule(itemKey)
        if effective then
            EvaluateRuleAgainstRows("noncrafted", itemKey, rawRule, effective)
        else
            skipped.ignored = skipped.ignored + 1
        end
    end

    self.lastCandidates = candidates
    SessionLog("PostingQueuePipeline: candidates built owner=%s source=%s rawRows=%d aggregatedRows=%d commodityRows=%d candidates=%d ignoredRules=%d duplicateRecipe=%d nonCraftedControlledByRecipe=%d duplicateNonCrafted=%d unresolvedRuleIdentity=%d",
        tostring(ownerKey), tostring(rowSource),
        tonumber(aggregationReport and aggregationReport.rawRows) or 0,
        tonumber(aggregationReport and aggregationReport.aggregatedRows) or 0,
        tonumber(aggregationReport and aggregationReport.commodityRows) or 0,
        #candidates, skipped.ignored,
        skipped.duplicateRecipe,
        skipped.nonCraftedControlledByRecipe,
        skipped.duplicateNonCrafted,
        skipped.unresolvedRuleIdentity)

    if diagnostics and diagnostics.SetSkipped then
        diagnostics:SetSkipped(skipped)
    end
    if diagnostics and diagnostics.CompleteRun then
        diagnostics:CompleteRun({
            ownerKey = ownerKey,
            bagRows = #(bagRows or {}),
            rawRows = aggregationReport and aggregationReport.rawRows or #(rawBagRows or {}),
            aggregatedRows = aggregationReport and aggregationReport.aggregatedRows or #(bagRows or {}),
            commodityRows = aggregationReport and aggregationReport.commodityRows or nil,
            unresolvedRows = aggregationReport and aggregationReport.unresolvedRows or nil,
            source = rowSource,
            liveRows = sourceReport and sourceReport.liveRows or nil,
            liveError = sourceReport and sourceReport.liveError or sourceReport and sourceReport.error or nil,
            skipped = skipped,
            candidates = #candidates,
        })
    end

    return candidates, {
        ownerKey = ownerKey,
        bagRows = #(bagRows or {}),
        rawRows = aggregationReport and aggregationReport.rawRows or #(rawBagRows or {}),
        aggregatedRows = aggregationReport and aggregationReport.aggregatedRows or #(bagRows or {}),
        commodityRows = aggregationReport and aggregationReport.commodityRows or nil,
        unresolvedRows = aggregationReport and aggregationReport.unresolvedRows or nil,
        source = rowSource,
        liveRows = sourceReport and sourceReport.liveRows or nil,
        liveError = sourceReport and sourceReport.liveError or sourceReport and sourceReport.error or nil,
        skipped = skipped,
    }
end
