-- PocketCFO/Reconciliation/AHMailboxReconciler.lua
-- Mailbox-driven AH outcome reconciliation.
-- Owns outcome determination only; identity, listing lifecycle, and inventory
-- adjustment state are delegated to shared services.
--
-- ProcessMailboxObservations receives raw mailbox observations from MailboxScanner,
-- detects AH sold/returned evidence, and orchestrates reconciliation. Resolve
-- performs the matching and inventory submission given a built evidence list.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local AHMailboxReconciler = PocketCFO:NewModule("AHMailboxReconciler")

local function Now()
    return PocketCFO and PocketCFO.Now and PocketCFO:Now() or time()
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

local function GetIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function GetInventoryStateService()
    return PocketCFO and (PocketCFO.InventoryStateService or _G.InventoryStateService) or _G.InventoryStateService
end

local function GetAHListingService()
    return PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("AuctionListingStateService", true)
end

local function Quantity(row)
    if type(row) ~= "table" then
        return 0
    end
    return tonumber(row.quantity) or tonumber(row.count) or tonumber(row.stackCount) or 1
end

local function NameKey(name)
    if not name or tostring(name) == "" then
        return nil
    end
    return string.lower(tostring(name))
end

local function CopyRow(row)
    if type(row) ~= "table" then
        return nil
    end
    local copy = {}
    for key, value in pairs(row) do
        copy[key] = value
    end
    return copy
end

local function EvidenceIsReturned(evidence)
    return evidence and (
        evidence.type == "returned"
        or evidence.type == "canceled"
        or evidence.type == "cancelled"
        or evidence.type == "expired"
    )
end

local function EvidenceIsSold(evidence)
    return evidence and evidence.type == "sold"
end

local function ReturnedOutcome(evidence)
    if not evidence then
        return "returned"
    end
    if evidence.type == "expired" then
        return "expired"
    end
    if evidence.type == "canceled" or evidence.type == "cancelled" then
        return "cancelled"
    end
    local subject = string.lower(tostring(evidence.subject or evidence.mailSubject or ""))
    if subject:find("expired", 1, true) then
        return "expired"
    end
    if subject:find("cancel", 1, true) or subject:find("removed", 1, true) then
        return "cancelled"
    end
    return "returned"
end

local function GetOwnerKey(mailEvidence)
    for _, evidence in ipairs(mailEvidence or {}) do
        if evidence and evidence.ownerKey and evidence.ownerKey ~= "" then
            return evidence.ownerKey
        end
    end
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.char
        and PocketCFO.db.char.characterGUID
        or nil
end

local function AddReportEntry(report, key, entry)
    report[key] = report[key] or {}
    report[key][#report[key] + 1] = entry
end

local function ResolveIdentity(evidence, source)
    local identityService = GetIdentityService()
    if not identityService then
        return nil, nil, "identityServiceUnavailable"
    end

    local identity
    if source == "ownedAuctionRow" and identityService.FromOwnedAuctionRow then
        identity = identityService:FromOwnedAuctionRow(evidence)
    elseif source == "snapshotRow" and identityService.FromSnapshotRow then
        identity = identityService:FromSnapshotRow(evidence)
    elseif identityService.Resolve then
        local lookup = CopyRow(evidence) or {}
        lookup.evidenceType = source or lookup.evidenceType or lookup.type or "auctionRow"
        identity = identityService:Resolve(lookup)
    elseif identityService.Identify then
        identity = identityService:Identify(evidence)
    end

    local configKey = identity and not identity.unresolved and identity.configKey or nil
    if not configKey and evidence and evidence.configKey and evidence.configKey ~= "" then
        configKey = evidence.configKey
    end
    return identity, configKey, (identity and identity.unresolvedReason) or (configKey and nil or "configKeyUnavailable")
end

local function BuildEvidenceEntry(evidence, index)
    if type(evidence) ~= "table" then
        return nil
    end
    local identity, configKey, unresolvedReason = ResolveIdentity(evidence, "mailboxEvidence")
    return {
        index = index,
        evidence = evidence,
        identity = identity,
        configKey = configKey,
        nameKey = NameKey(evidence.itemName or (identity and identity.itemName)),
        quantity = Quantity(evidence),
        type = evidence.type,
        outcome = EvidenceIsSold(evidence) and "sold" or (EvidenceIsReturned(evidence) and ReturnedOutcome(evidence) or "unresolved"),
        unresolvedReason = unresolvedReason,
    }
end

local function NormalizeListing(row, index)
    if type(row) ~= "table" then
        return nil
    end
    local identity, configKey, unresolvedReason = ResolveIdentity(row, "ownedAuctionRow")
    local mailboxResolution = row.mailboxResolution or "unresolved"
    local quantity = Quantity(row)
    return {
        index = index,
        row = row,
        identity = identity,
        configKey = configKey,
        nameKey = NameKey(row.itemName or row.name or (identity and identity.itemName)),
        quantity = quantity,
        remaining = mailboxResolution == "unresolved" and quantity or 0,
        auctionID = row.auctionID,
        mailboxResolution = mailboxResolution,
        unresolvedReason = unresolvedReason,
    }
end

local MAILBOX_RESOLUTION_FROM_OUTCOME = {
    sold      = "sold",
    expired   = "expired",
    returned  = "canceled",
    canceled  = "canceled",
    cancelled = "canceled",
}

local function GetUnresolvedListings(ownerKey)
    local service = GetAHListingService()
    if service and service.GetUnresolvedListings then
        return service:GetUnresolvedListings({ ownerKey = ownerKey }) or {}
    end
    if service and service.GetActiveOwnedListings then
        SessionLog("AHMailboxReconciler: GetUnresolvedListings unavailable, using active-only fallback")
        return service:GetActiveOwnedListings({ ownerKey = ownerKey }) or {}
    end
    SessionLog("AHMailboxReconciler: AuctionListingStateService listing query unavailable")
    return {}
end

local function IndexListings(listings)
    local byConfigKey = {}
    local byName = {}
    for _, listing in ipairs(listings or {}) do
        if listing.configKey then
            byConfigKey[listing.configKey] = byConfigKey[listing.configKey] or {}
            byConfigKey[listing.configKey][#byConfigKey[listing.configKey] + 1] = listing
        end
        if listing.nameKey then
            byName[listing.nameKey] = byName[listing.nameKey] or {}
            byName[listing.nameKey][#byName[listing.nameKey] + 1] = listing
        end
    end
    return byConfigKey, byName
end

-- nameGroupEvidenceTotal: pre-computed map of nameKey → total evidence quantity for
-- no-configKey evidence. Enables full-group resolution when evidence accounts for all
-- unresolved listings under the same name, even across multiple evidence entries.
local function NameFallbackIsSafe(entry, listings, nameGroupEvidenceTotal)
    if not entry or entry.configKey or not listings or #listings == 0 then
        return false, "name-fallback-not-applicable"
    end

    local firstConfigKey = nil
    local totalRemaining = 0
    local activeRows = 0
    local missingConfigKey = false
    for _, listing in ipairs(listings) do
        local remaining = tonumber(listing.remaining) or 0
        if remaining > 0 then
            activeRows = activeRows + 1
            totalRemaining = totalRemaining + remaining
            if listing.configKey then
                firstConfigKey = firstConfigKey or listing.configKey
                if firstConfigKey ~= listing.configKey then
                    firstConfigKey = false
                end
            else
                missingConfigKey = true
            end
        end
    end

    if activeRows == 0 then
        return false, "name-fallback-no-active-quantity"
    end
    if missingConfigKey then
        return false, "listing-configKey-unavailable"
    end
    if activeRows == 1 then
        return true
    end
    if firstConfigKey then
        return true
    end
    if tonumber(entry.quantity) == totalRemaining then
        return true
    end
    -- Full group coverage: total evidence for this name accounts for all unresolved listings.
    -- Allows resolving all variants when exact configKey is unknown but totals match.
    local groupTotal = nameGroupEvidenceTotal and nameGroupEvidenceTotal[entry.nameKey]
    if groupTotal and tonumber(groupTotal) == totalRemaining then
        return true
    end
    return false, "ambiguous-name-fallback"
end

local function AddUnresolvedEvidence(state, entry, reason, quantity)
    local evidence = entry and entry.evidence
    if type(evidence) ~= "table" then
        return
    end

    local row = CopyRow(evidence) or {}
    row.ownerKey = row.ownerKey or state.ownerKey
    row.quantity = tonumber(quantity) or entry.quantity or Quantity(evidence)
    row.configKey = entry.configKey
    row.identityUnresolvedReason = entry.unresolvedReason
    row.reason = reason
    row.timestamp = row.timestamp or Now()
    state.unresolvedEvidence[#state.unresolvedEvidence + 1] = row
end

local function AddOutcome(state, listing, entry, quantity, reason, fallback)
    quantity = math.min(tonumber(quantity) or 0, tonumber(listing and listing.remaining) or 0)
    if not listing or quantity <= 0 then
        return 0
    end

    listing.remaining = listing.remaining - quantity
    local evidence = entry and entry.evidence or {}
    local outcome = entry and entry.outcome or "unresolved"
    local row = listing.row or {}
    local result = {
        outcome = outcome,
        ownerKey = state.ownerKey,
        auctionID = listing.auctionID,
        configKey = listing.configKey or entry and entry.configKey,
        quantity = quantity,
        itemID = row.itemID or evidence.itemID or listing.identity and listing.identity.itemID,
        itemName = row.itemName or row.name or evidence.itemName or listing.identity and listing.identity.itemName,
        itemLink = row.itemLink or evidence.itemLink or listing.identity and listing.identity.itemLink,
        mailIndex = evidence.mailIndex,
        attachmentIndex = evidence.attachmentIndex,
        evidenceKey = evidence.evidenceKey,
        evidenceType = evidence.type,
        reason = reason,
        matchedBy = fallback and "nameFallback" or "configKey",
        timestamp = Now(),
    }

    state.results[#state.results + 1] = result
    state.ahRemovals[#state.ahRemovals + 1] = {
        rowIndex = listing.index,
        row = row,
        quantity = quantity,
        reason = reason,
        outcome = outcome,
        evidenceType = evidence.type,
        mailIndex = evidence.mailIndex,
        evidenceKey = evidence.evidenceKey,
        evidenceKeys = evidence.evidenceKey and { evidence.evidenceKey } or {},
        snapshotKey = row.snapshotKey,
        auctionID = listing.auctionID,
        configKey = result.configKey,
        itemName = result.itemName,
        itemID = result.itemID,
    }

    if outcome == "returned" or outcome == "expired" or outcome == "cancelled" then
        local mailAdd = CopyRow(evidence) or {}
        mailAdd.quantity = quantity
        mailAdd.location = "mail"
        mailAdd.configKey = result.configKey
        mailAdd.outcome = outcome
        mailAdd.timestamp = Now()
        state.mailAdds[#state.mailAdds + 1] = mailAdd
    end

    if evidence.evidenceKey then
        state.resolvedEvidenceKeys[evidence.evidenceKey] = true
        if outcome == "sold" then
            state.soldResolvedEvidenceKeys[evidence.evidenceKey] = true
        end
    end

    AddReportEntry(state.report, "results", result)
    return quantity
end

local function ResolveAgainstListings(state, entry, listings, reason, fallback)
    local remaining = tonumber(entry and entry.quantity) or 0
    for _, listing in ipairs(listings or {}) do
        if remaining <= 0 then
            break
        end
        if (tonumber(listing.remaining) or 0) > 0 then
            local applied = AddOutcome(state, listing, entry, remaining, reason, fallback)
            remaining = remaining - applied
        end
    end
    return (entry.quantity or 0) - remaining, remaining
end

local function ResolveEntry(state, entry, byConfigKey, byName)
    if not entry or entry.quantity <= 0 then
        return
    end
    if not EvidenceIsSold(entry.evidence) and not EvidenceIsReturned(entry.evidence) then
        AddUnresolvedEvidence(state, entry, "unsupported-mailbox-evidence-type", entry.quantity)
        return
    end

    local matches = entry.configKey and byConfigKey[entry.configKey] or nil
    local resolved, remaining = ResolveAgainstListings(state, entry, matches, "configKey-match", false)

    if remaining <= 0 then
        return
    end

    if not entry.configKey and entry.nameKey then
        local fallbackMatches = byName[entry.nameKey]
        local safeFallback, fallbackReason = NameFallbackIsSafe(entry, fallbackMatches, state.nameGroupEvidenceTotal)
        if safeFallback then
            local fallbackResolved
            fallbackResolved, remaining = ResolveAgainstListings(state, entry, fallbackMatches, "identity-unresolved-name-fallback", true)
            resolved = resolved + fallbackResolved
        elseif fallbackMatches and #fallbackMatches > 0 then
            AddReportEntry(state.report, "ambiguousSkippedMatches", {
                itemName = entry.evidence and entry.evidence.itemName,
                quantity = entry.quantity,
                reason = fallbackReason,
            })
        end
    end

    if resolved > 0 then
        AddReportEntry(state.report, "partialMatches", {
            itemName = entry.evidence and entry.evidence.itemName,
            configKey = entry.configKey,
            quantity = resolved,
            unresolvedQuantity = remaining,
            reason = "listing-quantity-shortfall",
        })
    end

    if remaining > 0 then
        local reason = entry.configKey and "no-active-listing-for-configKey" or "identity-unresolved-no-name-fallback-match"
        local unresolved = {
            itemName = entry.evidence and entry.evidence.itemName,
            itemID = entry.evidence and entry.evidence.itemID,
            configKey = entry.configKey,
            quantity = remaining,
            outcome = entry.outcome,
            mailIndex = entry.evidence and entry.evidence.mailIndex,
            reason = reason,
        }
        state.unresolved[#state.unresolved + 1] = unresolved
        AddReportEntry(state.report, "unresolvedGroups", unresolved)
        AddUnresolvedEvidence(state, entry, reason, remaining)
    end
end

local function NotifyListingService(results)
    local service = GetAHListingService()
    if not service then
        return 0
    end

    local notified = 0
    for _, result in ipairs(results or {}) do
        if result.auctionID then
            local mailboxResolution = MAILBOX_RESOLUTION_FROM_OUTCOME[tostring(result.outcome or "")]
            if mailboxResolution and service.MarkMailboxResolved then
                local mailboxEvidence = {
                    source       = "mailbox_reconciler",
                    evidenceType = result.evidenceType,
                    evidenceKey  = result.evidenceKey,
                    mailIndex    = result.mailIndex,
                }
                local _, resolveErr = service:MarkMailboxResolved(result.auctionID, mailboxResolution, mailboxEvidence)
                if resolveErr and resolveErr ~= "alreadyResolved" then
                    SessionLog("AHMailboxReconciler: MarkMailboxResolved issue auctionID=%s resolution=%s err=%s",
                        tostring(result.auctionID), tostring(mailboxResolution), tostring(resolveErr))
                end
            end

            local evidence = CopyRow(result) or {}
            evidence.source = "ah_mailbox_reconciliation"
            evidence.reason = result.outcome
            local closed
            if service.RecordAuctionEnded then
                closed = service:RecordAuctionEnded(result.auctionID, result.outcome, evidence)
            elseif service.CloseAuction then
                closed = service:CloseAuction(result.auctionID, result.outcome == "cancelled" and "canceled" or "closed", evidence)
            end
            if closed then
                notified = notified + 1
            end
        end
    end
    return notified
end

local function SubmitInventoryResults(ownerKey, results, unresolvedEvidence)
    local service = GetInventoryStateService()
    if not service then
        return nil, "inventoryStateServiceUnavailable"
    end
    if service.ApplyAHMailboxReconciliationResults then
        return service:ApplyAHMailboxReconciliationResults(ownerKey, results, {
            source = "ah-mailbox-reconciler",
            unresolvedEvidence = unresolvedEvidence,
        })
    end
    return nil, "applyAHMailboxReconciliationResultsUnavailable"
end

-- AH mail detection and evidence tracking (moved from MailboxScanner).
-- These helpers interpret AH meaning from raw mailbox observations.

local function SameItemName(left, right)
    if not left or not right then
        return false
    end
    return string.lower(tostring(left)) == string.lower(tostring(right))
end

local function IsAuctionHouseSender(sender)
    return sender ~= nil
        and _G.AUCTION_HOUSE ~= nil
        and tostring(sender) == tostring(_G.AUCTION_HOUSE)
end

local function SubjectMatchesGlobalFormat(subject, globalString)
    if not subject or not globalString or globalString == "" then
        return false
    end
    local prefix = tostring(globalString):match("^(.-)%%")
    if not prefix or prefix == "" then
        return false
    end
    return string.sub(tostring(subject), 1, string.len(prefix)) == prefix
end

local function IsSoldAuctionInvoice(invoice)
    return invoice
        and (invoice.invoiceType == "seller" or invoice.invoiceType == "seller_temp_invoice")
end

local function ParseSoldAuctionSubject(subject)
    local text = tostring(subject or "")
    local itemName, quantity = text:match("^Auction successful:%s*(.-)%s*%((%d+)%)%s*$")
    if itemName and itemName ~= "" then
        return itemName, tonumber(quantity) or 1
    end
    itemName = text:match("^Auction successful:%s*(.-)%s*$")
    if itemName and itemName ~= "" then
        return itemName, 1
    end
    return nil, nil
end

local function IsReturnedAuctionMail(sender, subject, wasReturned, hasItem)
    if not hasItem then
        return false
    end
    if SubjectMatchesGlobalFormat(subject, _G.AUCTION_EXPIRED_MAIL_SUBJECT)
    or SubjectMatchesGlobalFormat(subject, _G.AUCTION_REMOVED_MAIL_SUBJECT) then
        return true
    end
    local subjectText = string.lower(tostring(subject or ""))
    if subjectText:find("auction expired", 1, true)
    or subjectText:find("auction cancelled", 1, true)
    or subjectText:find("auction canceled", 1, true) then
        return true
    end
    return wasReturned and IsAuctionHouseSender(sender)
end

local function BuildDepreciationKey(kind, mailIndex, attachmentIndex, header, evidence, invoice)
    return table.concat({
        tostring(kind or ""),
        tostring(mailIndex or 0),
        tostring(attachmentIndex or 0),
        tostring(header and header.sender or ""),
        tostring(header and header.subject or ""),
        tostring(invoice and invoice.invoiceType or ""),
        tostring(evidence and evidence.itemID or ""),
        tostring(evidence and evidence.itemName or ""),
        tostring(evidence and evidence.quantity or ""),
        tostring(invoice and invoice.bid or ""),
        tostring(invoice and invoice.buyout or ""),
        tostring(invoice and invoice.deposit or ""),
        tostring(invoice and invoice.consignment or ""),
        tostring(invoice and invoice.moneyDelay or ""),
    }, "|")
end

local function MarkedDepreciationApplied(reconciler, key)
    reconciler.ahMailboxDepreciations = reconciler.ahMailboxDepreciations or {}
    return reconciler.ahMailboxDepreciations[key] == true
end

local function MarkDepreciationApplied(reconciler, key)
    reconciler.ahMailboxDepreciations = reconciler.ahMailboxDepreciations or {}
    reconciler.ahMailboxDepreciations[key] = true
end

local function EvidenceAlreadyApplied(reconciler, evidence)
    return evidence and evidence.evidenceKey and MarkedDepreciationApplied(reconciler, evidence.evidenceKey)
end

local function MarkEvidenceApplied(reconciler, evidence)
    if evidence and evidence.evidenceKey then
        MarkDepreciationApplied(reconciler, evidence.evidenceKey)
    end
end

local function IncrementSkipReason(stats, reason)
    if not stats then return end
    reason = reason or "unknown"
    stats.skippedMailCount = (stats.skippedMailCount or 0) + 1
    stats.skippedMailReasons = stats.skippedMailReasons or {}
    stats.skippedMailReasons[reason] = (stats.skippedMailReasons[reason] or 0) + 1
    return true
end

local function ReconciliationResolvedEvidence(result, evidence)
    if not result or not evidence then
        return false
    end
    if evidence.type == "sold" then
        return result.soldResolvedEvidenceKeys and result.soldResolvedEvidenceKeys[evidence.evidenceKey] == true
    end
    if result.resolvedEvidenceKeys and result.resolvedEvidenceKeys[evidence.evidenceKey] == true then
        return true
    end
    for _, mailAdd in ipairs(result.mailAdds or {}) do
        if tonumber(mailAdd.mailIndex) == tonumber(evidence.mailIndex)
        and tonumber(mailAdd.itemID) == tonumber(evidence.itemID)
        and SameItemName(mailAdd.itemName, evidence.itemName) then
            return true
        end
    end
    return false
end

local function StampMailboxResolutionEvidence(ownerKey, mailEvidence)
    local inventoryStateService = GetInventoryStateService()
    if not inventoryStateService or not inventoryStateService.MarkMailboxResolutionEvidenceScan then
        return nil
    end
    local metadata = inventoryStateService:MarkMailboxResolutionEvidenceScan(ownerKey, Now())
    if type(metadata) ~= "table" then
        return nil
    end
    for _, evidence in ipairs(mailEvidence or {}) do
        if type(evidence) == "table" then
            evidence.mailboxScanSessionID = metadata.sessionID
            evidence.mailboxScanTimestamp = metadata.scanTimestamp
        end
    end
    return metadata
end

-- Returns a map of configKey → total quantity from the current AH observation snapshot.
-- Used to cap returned-item AH adjustments so we never subtract more than what the
-- stale snapshot contains.
local function BuildAHSnapshotQtyMap(ownerKey)
    local service = GetInventoryStateService()
    if not service or not service.GetLocationSnapshot then
        return {}
    end
    local rows = service:GetLocationSnapshot(ownerKey, "ah") or {}
    local qtyMap = {}
    for _, row in ipairs(rows) do
        local ck = row.configKey
        local qty = tonumber(row.quantity) or 0
        if ck and ck ~= "" and qty > 0 then
            qtyMap[ck] = (qtyMap[ck] or 0) + qty
        end
    end
    return qtyMap
end

-- Applies AH offset adjustments (-quantity) for returned AH mail attachments that
-- carry a known configKey from MailboxScanner identity resolution. Does not require
-- AuctionListingStateService lookup or variant inference.
--
-- Deduplication: evidenceKey tracked in ahMailboxDepreciations (owned by this
-- reconciler, not InventoryStateService). Repeated mailbox opens skip already-applied
-- evidence.
--
-- Cap: cumulative subtraction per configKey is capped by the current AH observation
-- snapshot quantity. This protects against applying more than the stale snapshot holds.
function AHMailboxReconciler:ResolveReturnedInventory(ownerKey, returnedEvidence)
    local service = GetInventoryStateService()
    if not service then
        SessionLog("AHMailboxReconciler:ResolveReturnedInventory skipped reason=inventoryStateServiceUnavailable owner=%s", tostring(ownerKey))
        return { adjustmentCount = 0, skippedDuplicate = 0, skippedCap = 0 }
    end

    local ahQtyMap = BuildAHSnapshotQtyMap(ownerKey)
    local remaining = {}
    for ck, qty in pairs(ahQtyMap) do
        remaining[ck] = qty
    end

    local results = {}
    local skippedDuplicate = 0
    local skippedCap = 0

    for _, evidence in ipairs(returnedEvidence or {}) do
        local ck = evidence and evidence.configKey
        if not ck or ck == "" then
            -- No configKey: cannot safely produce an adjustment.
        elseif EvidenceAlreadyApplied(self, evidence) then
            skippedDuplicate = skippedDuplicate + 1
            SessionLog("AHMailboxReconciler: returned direct skipped reason=duplicate configKey=%s evidenceKey=%s",
                tostring(ck), tostring(evidence.evidenceKey))
        else
            local cap = remaining[ck] or 0
            local qty = math.min(tonumber(evidence.quantity) or 0, cap)
            if qty > 0 then
                remaining[ck] = cap - qty
                results[#results + 1] = {
                    outcome     = ReturnedOutcome(evidence),
                    configKey   = ck,
                    quantity    = qty,
                    evidenceKey = evidence.evidenceKey,
                    ownerKey    = ownerKey,
                    itemID      = evidence.itemID,
                    itemName    = evidence.itemName,
                    itemLink    = evidence.itemLink,
                    reason      = "returned-direct",
                    matchedBy   = "directConfigKey",
                }
            else
                skippedCap = skippedCap + 1
                SessionLog("AHMailboxReconciler: returned direct capped configKey=%s snapshotQty=%d requestedQty=%d evidenceKey=%s",
                    tostring(ck), cap, tonumber(evidence.quantity) or 0, tostring(evidence.evidenceKey))
            end
            -- Mark applied even when capped so repeated mailbox opens do not retry.
            MarkEvidenceApplied(self, evidence)
        end
    end

    local submission, submitErr
    if #results > 0 and service.ApplyAHMailboxReconciliationResults then
        submission, submitErr = service:ApplyAHMailboxReconciliationResults(ownerKey, results, {
            source = "ah-mailbox-reconciler-returned-direct",
        })
    end

    local adjustmentCount = tonumber(submission and submission.adjustmentCount) or 0
    SessionLog("AHMailboxReconciler: returned direct inventory owner=%s candidates=%d results=%d adjustments=%d skippedDuplicate=%d skippedCap=%d submitError=%s",
        tostring(ownerKey), #(returnedEvidence or {}), #results, adjustmentCount,
        skippedDuplicate, skippedCap, tostring(submitErr))

    return {
        adjustmentCount  = adjustmentCount,
        results          = results,
        skippedDuplicate = skippedDuplicate,
        skippedCap       = skippedCap,
        submitError      = submitErr,
    }
end

function AHMailboxReconciler.Resolve(selfOrEvidence, maybeEvidence)
    local mailEvidence = maybeEvidence or selfOrEvidence
    mailEvidence = mailEvidence or {}
    local scanStats = mailEvidence.scanStats or {}
    local ownerKey = GetOwnerKey(mailEvidence)

    -- Pre-pass: sum evidence quantities by name key for variant group resolution.
    -- Only counts evidence without a configKey (sold invoices, generic returns).
    -- Used by NameFallbackIsSafe to resolve all variants when totals match.
    local nameGroupEvidenceTotal = {}
    for _, evidence in ipairs(mailEvidence) do
        if type(evidence) == "table" then
            local evNameKey = NameKey(evidence.itemName)
            local hasConfigKey = evidence.configKey ~= nil and evidence.configKey ~= ""
            if evNameKey and not hasConfigKey
            and (EvidenceIsSold(evidence) or EvidenceIsReturned(evidence)) then
                local qty = tonumber(evidence.quantity) or tonumber(evidence.count) or 1
                nameGroupEvidenceTotal[evNameKey] = (nameGroupEvidenceTotal[evNameKey] or 0) + qty
            end
        end
    end

    local rawListings = ownerKey and GetUnresolvedListings(ownerKey) or {}
    local listings = {}
    for index, row in ipairs(rawListings or {}) do
        local listing = NormalizeListing(row, index)
        if listing and listing.quantity > 0 then
            listings[#listings + 1] = listing
        end
    end

    local byConfigKey, byName = IndexListings(listings)
    local state = {
        ownerKey = ownerKey,
        listings = listings,
        nameGroupEvidenceTotal = nameGroupEvidenceTotal,
        ahWasEmpty = #listings == 0,
        results = {},
        ahRemovals = {},
        mailAdds = {},
        unresolved = {},
        unresolvedEvidence = {},
        resolvedEvidenceKeys = {},
        soldResolvedEvidenceKeys = {},
        report = {
            timestamp = Now(),
            ownerKey = ownerKey,
            inboxTotal = tonumber(scanStats.inboxTotal) or 0,
            inboxVisible = tonumber(scanStats.inboxVisible) or 0,
            rawMailScanned = tonumber(scanStats.rawMailScanned) or 0,
            evidenceProcessed = #mailEvidence,
            soldEvidenceCount = tonumber(scanStats.soldEvidenceCount) or 0,
            returnedEvidenceCount = tonumber(scanStats.returnedEvidenceCount) or 0,
            skippedMailCount = tonumber(scanStats.skippedMailCount) or 0,
            skippedMailReasons = scanStats.skippedMailReasons or {},
            activeListingCount = #listings,
            ahWasEmpty = #listings == 0,
            results = {},
            partialMatches = {},
            ambiguousSkippedMatches = {},
            unresolvedGroups = {},
            unresolvedEvidence = {},
            ahRemovals = {},
            mailAdds = {},
        },
    }

    for index, evidence in ipairs(mailEvidence or {}) do
        local entry = BuildEvidenceEntry(evidence, index)
        if entry then
            ResolveEntry(state, entry, byConfigKey, byName)
        end
    end

    table.sort(state.ahRemovals, function(a, b)
        return (tonumber(a.rowIndex) or 0) < (tonumber(b.rowIndex) or 0)
    end)

    for _, removal in ipairs(state.ahRemovals) do
        state.report.ahRemovals[#state.report.ahRemovals + 1] = {
            rowIndex = removal.rowIndex,
            snapshotKey = removal.snapshotKey,
            auctionID = removal.auctionID,
            configKey = removal.configKey,
            itemName = removal.itemName,
            itemID = removal.itemID,
            quantity = removal.quantity,
            outcome = removal.outcome,
            reason = removal.reason,
            evidenceType = removal.evidenceType,
            mailIndex = removal.mailIndex,
            evidenceKey = removal.evidenceKey,
            evidenceKeys = removal.evidenceKeys,
        }
    end
    for _, mailAdd in ipairs(state.mailAdds) do
        state.report.mailAdds[#state.report.mailAdds + 1] = {
            itemName = mailAdd.itemName,
            itemID = mailAdd.itemID,
            configKey = mailAdd.configKey,
            quantity = Quantity(mailAdd),
            outcome = mailAdd.outcome,
            mailIndex = mailAdd.mailIndex,
        }
    end
    for _, evidence in ipairs(state.unresolvedEvidence) do
        state.report.unresolvedEvidence[#state.report.unresolvedEvidence + 1] = evidence
    end

    -- All resolved outcomes go to listing service for lifecycle tracking.
    -- Inventory submission is sold-only: returned/cancelled/expired inventory is
    -- handled by ResolveReturnedInventory, which runs before Resolve in
    -- ProcessMailboxObservations and does not require a listing match.
    local soldResults = {}
    for _, r in ipairs(state.results) do
        if r.outcome == "sold" then
            soldResults[#soldResults + 1] = r
        end
    end
    state.listingClosures = NotifyListingService(state.results)
    local submitted, submitErr = SubmitInventoryResults(ownerKey, soldResults, state.unresolvedEvidence)
    state.inventorySubmission = submitted
    state.inventorySubmissionError = submitErr
    state.report.listingClosures = state.listingClosures
    state.report.inventorySubmission = submitted
    state.report.inventorySubmissionError = submitErr

    local exactMatchCount = 0
    local cohortMatchCount = 0
    for _, r in ipairs(state.results) do
        if r.matchedBy == "configKey" then
            exactMatchCount = exactMatchCount + 1
        else
            cohortMatchCount = cohortMatchCount + 1
        end
    end
    local nameGroupCount = 0
    for _ in pairs(nameGroupEvidenceTotal) do
        nameGroupCount = nameGroupCount + 1
    end
    local ambiguousCount = #(state.report.ambiguousSkippedMatches or {})

    state.report.exactMatchCount = exactMatchCount
    state.report.cohortMatchCount = cohortMatchCount
    state.report.nameGroupCount = nameGroupCount
    state.report.ambiguousCount = ambiguousCount

    PocketCFO.lastAHMailboxReconciliationReport = state.report
    SessionLog("AHMailboxReconciler: pass summary owner=%s evidence=%d[sold=%d returned=%d] unresolvedListings=%d nameGroups=%d exactMatches=%d cohortMatches=%d ambiguous=%d resolved=%d adjustments=%d unresolved=%d unresolvedEvidence=%d",
        tostring(ownerKey),
        #mailEvidence, tonumber(scanStats.soldEvidenceCount) or 0, tonumber(scanStats.returnedEvidenceCount) or 0,
        #listings,
        nameGroupCount,
        exactMatchCount,
        cohortMatchCount,
        ambiguousCount,
        #state.results,
        tonumber(submitted and submitted.adjustmentCount) or 0,
        #state.unresolved,
        #state.unresolvedEvidence)

    return {
        results = state.results,
        ahRemovals = state.ahRemovals,
        mailAdds = state.mailAdds,
        unresolved = state.unresolved,
        unresolvedEvidence = state.unresolvedEvidence,
        resolvedEvidenceKeys = state.resolvedEvidenceKeys,
        soldResolvedEvidenceKeys = state.soldResolvedEvidenceKeys,
        listingClosures = state.listingClosures,
        inventorySubmission = state.inventorySubmission,
        inventorySubmissionError = state.inventorySubmissionError,
        report = state.report,
    }
end

-- Returns true only when it is safe to apply direct AH-return inventory adjustments.
-- Defers if AuctionListingStateService is unavailable, ownerKey is missing, or any
-- listing for this owner could still plausibly be active.
local function AssistedReturnIsAllowed(ownerKey)
    if not ownerKey then
        SessionLog("AHMailboxReconciler: assisted return deferred reason=ownerKey-unavailable")
        return false
    end
    local service = GetAHListingService()
    if not service or type(service.CanAnyListingStillBeActive) ~= "function" then
        SessionLog("AHMailboxReconciler: assisted return deferred reason=AuctionListingStateService-unavailable owner=%s", tostring(ownerKey))
        return false
    end
    if service:CanAnyListingStillBeActive(ownerKey) then
        SessionLog("AHMailboxReconciler: AH listings may still be active; assisted mailbox reconciliation deferred owner=%s", tostring(ownerKey))
        return false
    end
    SessionLog("AHMailboxReconciler: no listings plausibly active; assisted return reconciliation allowed owner=%s", tostring(ownerKey))
    return true
end

-- ProcessMailboxObservations receives raw mailbox observations from MailboxScanner,
-- detects AH sold/returned evidence, and drives reconciliation. Owns all AH
-- mail interpretation that previously lived in MailboxScanner.
function AHMailboxReconciler:ProcessMailboxObservations(ownerKey, mailObservations, scanStats)
    local mailEvidence = {}
    local stats = {
        inboxVisible          = scanStats and scanStats.inboxVisible or 0,
        inboxTotal            = scanStats and scanStats.inboxTotal or 0,
        rawMailScanned        = scanStats and scanStats.rawMailScanned or 0,
        soldEvidenceCount     = 0,
        returnedEvidenceCount = 0,
        skippedMailCount      = 0,
        skippedMailReasons    = {},
    }

    for _, obs in ipairs(mailObservations or {}) do
        local evidenceCountBefore = #mailEvidence
        local skipRecorded
        local invoice = obs.invoice

        local subjectSoldItemName, subjectSoldQuantity = ParseSoldAuctionSubject(obs.subject)
        local soldAuctionMail = IsSoldAuctionInvoice(invoice)
            or (subjectSoldItemName ~= nil and IsAuctionHouseSender(obs.sender))
        local returnedAuctionMail = IsReturnedAuctionMail(obs.sender, obs.subject, obs.wasReturned, obs.hasItem)

        if soldAuctionMail then
            local soldItemName = invoice and invoice.itemName or subjectSoldItemName
            local soldQuantity = tonumber(invoice and invoice.count) or tonumber(subjectSoldQuantity) or 1
            local soldEvidence = {
                type      = "sold",
                ownerKey  = ownerKey,
                location  = "ah",
                itemName  = soldItemName,
                quantity  = soldQuantity,
                money     = obs.money,
                mailIndex = obs.mailIndex,
                subject   = obs.subject,
                sender    = obs.sender,
            }
            soldEvidence.evidenceKey = BuildDepreciationKey("sold", obs.mailIndex, 0, obs, soldEvidence, invoice)

            SessionLog("AHMailboxReconciler: sold AH mail detected mailIndex=%d itemName=%s quantity=%d invoiceType=%s money=%s delayed=%s",
                obs.mailIndex, tostring(soldItemName), soldQuantity,
                tostring(invoice and invoice.invoiceType), tostring(obs.money),
                tostring(invoice and invoice.moneyDelay))

            if not soldItemName or soldItemName == "" then
                skipRecorded = IncrementSkipReason(stats, "sold-missing-itemName")
                SessionLog("AHMailboxReconciler: sold AH evidence skipped mailIndex=%d reason=missing-itemName subject=%s invoiceType=%s",
                    obs.mailIndex, tostring(obs.subject), tostring(invoice and invoice.invoiceType))
            else
                if EvidenceAlreadyApplied(self, soldEvidence) then
                    skipRecorded = IncrementSkipReason(stats, "sold-already-applied")
                    SessionLog("AHMailboxReconciler: sold AH evidence skipped owner=%s itemName=%s quantity=%d reason=already-applied-this-session",
                        tostring(ownerKey), tostring(soldEvidence.itemName), soldQuantity)
                else
                    mailEvidence[#mailEvidence + 1] = soldEvidence
                    stats.soldEvidenceCount = stats.soldEvidenceCount + 1
                end
            end
        end

        if returnedAuctionMail then
            SessionLog("AHMailboxReconciler: returned AH mail detected mailIndex=%d sender=%s subject=%s attachments=%d",
                obs.mailIndex, tostring(obs.sender), tostring(obs.subject), #(obs.attachments or {}))

            for _, att in ipairs(obs.attachments or {}) do
                local returnedEvidence = {
                    type            = "returned",
                    ownerKey        = ownerKey,
                    location        = "ah",
                    itemID          = att.itemID,
                    itemName        = att.itemName,
                    itemLink        = att.itemLink,
                    quantity        = att.quantity,
                    configKey       = att.configKey,
                    quality         = att.identity and (att.identity.craftingQuality or att.identity.itemQuality) or nil,
                    mailIndex       = obs.mailIndex,
                    attachmentIndex = att.attachmentIndex,
                    subject         = obs.subject,
                    sender          = obs.sender,
                }
                returnedEvidence.evidenceKey = BuildDepreciationKey("returned", obs.mailIndex, att.attachmentIndex, obs, returnedEvidence, invoice)

                if EvidenceAlreadyApplied(self, returnedEvidence) then
                    skipRecorded = IncrementSkipReason(stats, "returned-already-applied")
                    SessionLog("AHMailboxReconciler: returned AH evidence skipped owner=%s itemID=%s itemName=%s quantity=%d reason=already-applied-this-session",
                        tostring(ownerKey), tostring(att.itemID), tostring(att.itemName), att.quantity)
                else
                    mailEvidence[#mailEvidence + 1] = returnedEvidence
                    stats.returnedEvidenceCount = stats.returnedEvidenceCount + 1
                end
            end
        end

        if #mailEvidence == evidenceCountBefore and not skipRecorded then
            if soldAuctionMail then
                IncrementSkipReason(stats, "sold-no-evidence")
            elseif returnedAuctionMail then
                IncrementSkipReason(stats, "returned-no-evidence")
            elseif IsAuctionHouseSender(obs.sender) then
                IncrementSkipReason(stats, "ah-mail-unclassified")
            else
                IncrementSkipReason(stats, "non-ah-mail")
            end
        end
    end

    mailEvidence.scanStats = stats

    if #mailEvidence == 0 then
        SessionLog("AHMailboxReconciler: no AH evidence in mailbox owner=%s; skipping reconciliation", tostring(ownerKey))
        return nil
    end

    StampMailboxResolutionEvidence(ownerKey, mailEvidence)

    -- Direct returned-item inventory path: applies AH offset adjustments for returned
    -- attachments with a known configKey, without requiring a listing match.
    local returnedWithKey = {}
    for _, ev in ipairs(mailEvidence) do
        if EvidenceIsReturned(ev) and ev.configKey and ev.configKey ~= "" then
            returnedWithKey[#returnedWithKey + 1] = ev
        end
    end
    local returnedInventoryResult = nil
    if #returnedWithKey > 0 and AssistedReturnIsAllowed(ownerKey) then
        returnedInventoryResult = self:ResolveReturnedInventory(ownerKey, returnedWithKey)
    end

    local result = self:Resolve(mailEvidence)
    local inventoryStateService = GetInventoryStateService()
    local results = result and result.results or {}
    local submission = result and result.inventorySubmission

    SessionLog("AHMailboxReconciler: reconciliation complete owner=%s evidence=%d results=%d returnedInventory=%d soldInventory=%d unresolved=%d listingClosures=%d submitError=%s",
        tostring(ownerKey), #mailEvidence, #results,
        tonumber(returnedInventoryResult and returnedInventoryResult.adjustmentCount) or 0,
        tonumber(submission and submission.adjustmentCount) or 0,
        #(result and result.unresolvedEvidence or {}),
        tonumber(result and result.listingClosures) or 0,
        tostring(result and result.inventorySubmissionError))

    if inventoryStateService and inventoryStateService.GetPendingAHReductions
    and inventoryStateService.StorePendingAHMailboxEvidence
    and inventoryStateService.ResolvePendingAHMailboxEvidence then
        local pendingRows = inventoryStateService:GetPendingAHReductions(ownerKey)
        if type(pendingRows) == "table" and next(pendingRows) ~= nil then
            for _, evidence in ipairs(mailEvidence) do
                if evidence and (evidence.type == "sold" or evidence.type == "returned")
                and ReconciliationResolvedEvidence(result, evidence)
                and #results == 0 then
                    inventoryStateService:StorePendingAHMailboxEvidence(ownerKey, evidence,
                        tostring(evidence.type) .. "-mail-no-active-ah-match", "mailbox-scan")
                end
            end
        end
        inventoryStateService:ResolvePendingAHMailboxEvidence(ownerKey, "mailbox-scan")
    end

    -- Returned evidence was already marked in ResolveReturnedInventory.
    -- Only mark sold evidence that resolved through the listing match path.
    for _, evidence in ipairs(mailEvidence) do
        if not EvidenceIsReturned(evidence) and ReconciliationResolvedEvidence(result, evidence) then
            MarkEvidenceApplied(self, evidence)
        end
    end

    return result
end
