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

-- Mail waiting list helpers, defined further down (2026-11-09).
local StampMailAge, ClaimInboxMail, AddUnclaimedWaiting, UpdateMailStore

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

-- Sale price of a sold mail (2026-11-05): money - deposit + AH cut
-- (api-findings formula). nil when the invoice parts are missing.
local function SalePrice(evidence)
    local money = tonumber(evidence and evidence.money)
    local deposit = tonumber(evidence and evidence.deposit)
    local cut = tonumber(evidence and evidence.consignment)
    if not money or not deposit or not cut then
        return nil
    end
    return money - deposit + cut
end

-- Mail identity (2026-11-09, AH_Mail_Matching_Design Change B):
-- * Evidence with an item link is resolved again from the link on every pass
--   (never from a stored configKey), so a key built while the item wasn't
--   loaded yet (ilvl:0) corrects itself on the next pass.
-- * An item-level key is trusted only when it came from the item's own link
--   and has a real level. Sold mail has no link: for gear its name-only key
--   can't say which variant sold, so it's dropped and price, name and
--   elimination rules decide. Stackables keep their name-derived key.
local function TrustedConfigKey(evidence, configKey)
    if not configKey or configKey == "" then
        return nil
    end
    local isItemLevelKey = configKey:find("|ilvl:", 1, true) ~= nil
    if not isItemLevelKey then
        return configKey
    end
    if not evidence.itemLink or configKey:find("|ilvl:0", 1, true) then
        return nil
    end
    return configKey
end

local function BuildEvidenceEntry(evidence, index)
    if type(evidence) ~= "table" then
        return nil
    end
    local lookup = CopyRow(evidence) or {}
    if lookup.itemLink then
        lookup.configKey = nil
    end
    local identity, configKey, unresolvedReason = ResolveIdentity(lookup, "mailboxEvidence")
    if configKey and evidence.itemLink and configKey:find("|ilvl:0", 1, true) then
        unresolvedReason = unresolvedReason or "itemLevelPending"
    end
    configKey = TrustedConfigKey(evidence, configKey)
    -- Returned mail carries the item itself (2026-11-10): with a link but no
    -- trusted key yet (item not loaded), it waits for the next pass instead of
    -- matching by name (a Finesse knife cancel matched a Perception listing).
    local identityPending = EvidenceIsReturned(evidence) and evidence.itemLink and not configKey or nil
    return {
        index = index,
        evidence = evidence,
        identity = identity,
        configKey = configKey,
        -- The item's key under the pre-2026-11-10 identity rule: a listing
        -- posted before the update still carries it until its next owned-
        -- auctions scan (Item_Identity_Unification_Design.md 6.3).
        legacyConfigKey = configKey and identity and identity.legacyConfigKey or nil,
        identityPending = identityPending,
        nameKey = NameKey(evidence.itemName or (identity and identity.itemName)),
        quantity = Quantity(evidence),
        type = evidence.type,
        outcome = EvidenceIsSold(evidence) and "sold" or (EvidenceIsReturned(evidence) and ReturnedOutcome(evidence) or "unresolved"),
        unresolvedReason = unresolvedReason,
        salePrice = EvidenceIsSold(evidence) and SalePrice(evidence) or nil,
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
        -- Part of a commodity listing may already be settled by earlier mail.
        remaining = mailboxResolution == "unresolved"
            and math.max(0, quantity - (tonumber(row.settledQuantity) or 0)) or 0,
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
    row.legacyConfigKey = entry.legacyConfigKey
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

-- Price match (2026-11-05): open listings with this name whose posted price
-- equals the sale price (buyout, or unit price x quantity sold). Used only
-- when every match is the same variant (one configKey) and they cover the
-- whole sale, so it never splits a sale or guesses between variants.
local function PriceMatches(entry, listings)
    local price = tonumber(entry and entry.salePrice)
    local quantity = tonumber(entry and entry.quantity) or 1
    if not price or price <= 0 then
        return nil
    end
    local matches, configKey, total = {}, nil, 0
    for _, listing in ipairs(listings or {}) do
        local remaining = tonumber(listing.remaining) or 0
        if remaining > 0 and listing.configKey then
            local row = listing.row or {}
            local buyout = tonumber(row.buyout)
            local unitPrice = tonumber(row.unitPrice)
            if buyout == price or (unitPrice and unitPrice * quantity == price) then
                if configKey and configKey ~= listing.configKey then
                    return nil
                end
                configKey = listing.configKey
                matches[#matches + 1] = listing
                total = total + remaining
            end
        end
    end
    if #matches == 0 or total < quantity then
        return nil
    end
    return matches
end

-- Owned-scan elimination (2026-11-09): a listing seen active in a reliable
-- owned-auctions scan after this mail arrived can't be the auction the mail is
-- about (a sale happens about an hour before its mail arrives, per Brian; an
-- expiry or cancel at the moment its mail arrives). Only used when the mail's
-- arrival time is precise (fractional daysLeft: confirmed in-game 2026-11-09,
-- good to about a minute, hence the 2-minute margin).
local ELIMINATION_MARGIN_SECONDS = 120
-- A mail can't be about an auction posted after the mail arrived (margin kept
-- wider, it only ever widens the set of candidates).
local POSTED_AFTER_MARGIN_SECONDS = 600

-- Also (2026-11-09): a mail can't be about an auction posted after the mail
-- arrived, so an old waiting sale never claims a newer listing of the same item.
-- Latest possible arrival: the precise arrival time, else arrival + 1 day
-- (daysLeft precision Theoretical), else when the mail was first seen.
local function LatestPossibleArrival(evidence)
    local arrivalAt = tonumber(evidence and evidence.arrivalAt)
    if arrivalAt then
        return arrivalAt + (evidence.arrivalPrecise and POSTED_AFTER_MARGIN_SECONDS or 86400)
    end
    return tonumber(evidence and (evidence.firstSeenAt or evidence.storedAt))
end

local function EligibleListings(entry, listings)
    local evidence = entry and entry.evidence
    if not listings or not evidence then
        return listings
    end
    local preciseArrival = evidence.arrivalPrecise and tonumber(evidence.arrivalAt)
    local latestArrival = LatestPossibleArrival(evidence)
    if not preciseArrival and not latestArrival then
        return listings
    end
    local eligible, excluded = {}, 0
    for _, listing in ipairs(listings) do
        local row = listing.row or {}
        local seenActiveAt = tonumber(row.lastConfirmedAt)
        local postedAt = tonumber(row.postedAt)
        if latestArrival and postedAt and postedAt > latestArrival then
            excluded = excluded + 1
        elseif preciseArrival and row.status == "active" and seenActiveAt
        and seenActiveAt > preciseArrival + ELIMINATION_MARGIN_SECONDS then
            excluded = excluded + 1
        else
            eligible[#eligible + 1] = listing
        end
    end
    if excluded > 0 then
        entry.eliminatedListings = (entry.eliminatedListings or 0) + excluded
    end
    return eligible
end

local function ResolveEntry(state, entry, byConfigKey, byName)
    if not entry or entry.quantity <= 0 then
        return
    end
    if not EvidenceIsSold(entry.evidence) and not EvidenceIsReturned(entry.evidence) then
        AddUnresolvedEvidence(state, entry, "unsupported-mailbox-evidence-type", entry.quantity)
        return
    end

    local keyedListings = entry.configKey and (byConfigKey[entry.configKey]
        or (entry.legacyConfigKey and byConfigKey[entry.legacyConfigKey])) or nil
    local matches = keyedListings and EligibleListings(entry, keyedListings) or nil
    local resolved, remaining = ResolveAgainstListings(state, entry, matches, "configKey-match", false)

    if remaining <= 0 then
        return
    end

    if entry.identityPending then
        SessionLog("AHMailboxReconciler: returned mail waits, item not loaded yet item=%s reason=%s evidenceKey=%s",
            tostring(entry.evidence and entry.evidence.itemName), tostring(entry.unresolvedReason),
            tostring(entry.evidence and entry.evidence.evidenceKey))
        AddUnresolvedEvidence(state, entry, "returned-identity-pending", remaining)
        return
    end

    -- Price match before the name rules (2026-11-05). Only when nothing has
    -- been applied yet, so ResolveAgainstListings starts from the full sale.
    if resolved == 0 and not entry.configKey and entry.nameKey and EvidenceIsSold(entry.evidence) then
        local ok, priceMatches = pcall(PriceMatches, entry, EligibleListings(entry, byName[entry.nameKey]))
        if ok and priceMatches then
            resolved, remaining = ResolveAgainstListings(state, entry, priceMatches, "price-match", false)
            if remaining <= 0 then
                return
            end
        end
    end

    if not entry.configKey and entry.nameKey then
        local fallbackMatches = EligibleListings(entry, byName[entry.nameKey])
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
            legacyConfigKey = entry.legacyConfigKey,
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

-- Resolved sales for the Item Ledger (2026-11-05). When a sold mail resolves
-- to one variant, keep its link so GoldLedger can write the auction out with
-- it when the gold is collected (gear then leaves at its own book value).
-- Keyed by item name + mail money (exact copper). Kept in the saved DB so a
-- reload between opening the mailbox and collecting doesn't lose it; pruned
-- after 31 days (AH mail is held 30).
local RESOLVED_SALE_DAYS = 31

local function ResolvedSalesTable()
    local global = PocketCFO and PocketCFO.db and PocketCFO.db.global
    if not global then
        return nil
    end
    global.ahResolvedSales = global.ahResolvedSales or {}
    return global.ahResolvedSales
end

local function ResolvedSaleKey(name, money)
    local nameKey = NameKey(name)
    money = tonumber(money)
    if not nameKey or not money then
        return nil
    end
    return nameKey .. "|" .. tostring(money)
end

local function RememberResolvedSale(entry, results, firstIndex)
    local evidence = entry and entry.evidence
    if not evidence or not EvidenceIsSold(evidence) then
        return
    end
    local key = ResolvedSaleKey(evidence.itemName, evidence.money)
    local store = key and ResolvedSalesTable()
    if not store then
        return
    end
    local configKey, itemLink, itemID, quantity = nil, nil, nil, 0
    for index = firstIndex, #results do
        local result = results[index]
        if not result.configKey or not result.itemLink then
            return
        end
        if configKey and configKey ~= result.configKey then
            return
        end
        configKey = result.configKey
        itemLink = itemLink or result.itemLink
        itemID = itemID or tonumber(result.itemID)
        quantity = quantity + (tonumber(result.quantity) or 0)
    end
    if not configKey or quantity ~= (tonumber(entry.quantity) or 0) then
        return
    end

    local now = Now()
    local cutoff = now - RESOLVED_SALE_DAYS * 86400
    for saleKey, list in pairs(store) do
        for i = #list, 1, -1 do
            if (tonumber(list[i].at) or 0) < cutoff then
                table.remove(list, i)
            end
        end
        if #list == 0 then
            store[saleKey] = nil
        end
    end

    local list = store[key] or {}
    for _, sale in ipairs(list) do
        if evidence.evidenceKey and sale.evidenceKey == evidence.evidenceKey then
            return
        end
    end
    list[#list + 1] = {
        itemLink = itemLink,
        itemID = itemID,
        configKey = configKey,
        quantity = quantity,
        evidenceKey = evidence.evidenceKey,
        at = now,
    }
    store[key] = list
    SessionLog("AHMailboxReconciler: resolved sale kept item=%s money=%s configKey=%s qty=%d",
        tostring(evidence.itemName), tostring(evidence.money), tostring(configKey), quantity)
end

-- GoldLedger asks for (and takes) the resolved sale matching a collected AH
-- sale mail. Returns { itemLink, itemID, configKey, quantity } or nil.
function AHMailboxReconciler:TakeResolvedSale(name, money)
    local key = ResolvedSaleKey(name, money)
    local store = key and ResolvedSalesTable()
    local list = store and store[key]
    if not list or #list == 0 then
        return nil
    end
    local sale = table.remove(list, 1)
    if #list == 0 then
        store[key] = nil
    end
    return sale
end

local function NotifyListingService(results)
    local service = GetAHListingService()
    if not service then
        return 0
    end

    local notified = 0
    for _, result in ipairs(results or {}) do
        if result.auctionID and service.RecordMailboxOutcome then
            -- Settle by quantity (2026-11-09): a partial commodity sale no longer
            -- closes the whole listing.
            local evidence = CopyRow(result) or {}
            evidence.source = "ah_mailbox_reconciliation"
            evidence.reason = result.outcome
            local _, settleErr, fullySettled = service:RecordMailboxOutcome(result.auctionID, result.outcome, result.quantity, evidence)
            if settleErr and settleErr ~= "alreadyResolved" then
                SessionLog("AHMailboxReconciler: RecordMailboxOutcome issue auctionID=%s outcome=%s err=%s",
                    tostring(result.auctionID), tostring(result.outcome), tostring(settleErr))
            end
            if fullySettled then
                notified = notified + 1
            end
        elseif result.auctionID then
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

-- Unmatched mail now waits in the reconciler's own waiting list (2026-11-09),
-- so nothing is passed to InventoryStateService's old pending-evidence store.
local function SubmitInventoryResults(ownerKey, results)
    local service = GetInventoryStateService()
    if not service then
        return nil, "inventoryStateServiceUnavailable"
    end
    if service.ApplyAHMailboxReconciliationResults then
        return service:ApplyAHMailboxReconciliationResults(ownerKey, results, {
            source = "ah-mailbox-reconciler",
        })
    end
    return nil, "applyAHMailboxReconciliationResultsUnavailable"
end

-- ─── Mail waiting list and matched list (2026-11-09) ─────────────────────────
-- Design: claude/AH_Mail_Matching_Design.md, Change B.
-- PocketCFO_DB.global.ahMailWaiting[ownerKey][evidenceKey] = AH mail not matched
--   yet (sold or returned), retried every mailbox pass and after owned scans.
-- PocketCFO_DB.global.ahMailMatched[ownerKey][evidenceKey] = { contentKey,
--   arrivalAt, matchedAt }: mail already matched, never processed again.
-- A mail has no ID in the game API. Its contentKey is what the mail says (kind,
-- sender, subject, gold, item, quantity), without position, time, deposit or cut
-- (older saved sales have no deposit / cut); its arrival time (from daysLeft)
-- tells identical mails apart.
-- Both lists drop entries after 31 days (AH mail is kept 30).

local AH_MAIL_DAYS = 30
local MAIL_KEEP_DAYS = 31
local ARRIVAL_TOLERANCE_SECONDS = 600

function StampMailAge(evidence, daysLeft)
    daysLeft = tonumber(daysLeft)
    evidence.daysLeft = daysLeft
    evidence.mailQuantity = tonumber(evidence.quantity) or 1
    evidence.inInbox = true
    if daysLeft then
        evidence.arrivalAt = Now() - math.floor((AH_MAIL_DAYS - daysLeft) * 86400)
        -- Theoretical: whether daysLeft has sub-day precision. A whole number
        -- means it doesn't, so the arrival time can't be used for elimination.
        evidence.arrivalPrecise = daysLeft ~= math.floor(daysLeft)
    end
end

local function MailContentKey(ownerKey, evidence)
    return table.concat({
        tostring(evidence.type or ""),
        tostring(ownerKey or evidence.ownerKey or ""),
        tostring(evidence.sender or ""),
        tostring(evidence.subject or ""),
        tostring(evidence.money or ""),
        tostring(evidence.itemID or ""),
        tostring(NameKey(evidence.itemName) or ""),
        tostring(evidence.mailQuantity or evidence.quantity or ""),
    }, "|")
end

-- One-time move of InventoryStateService's old unmatched-evidence store into the
-- waiting list. The old store saved one copy per mailbox visit, so per mail the
-- number of real mails is the most copies seen in any single visit.
local function MigrateOldPendingEvidence(global, waitingRoot)
    global.migrations = global.migrations or {}
    if global.migrations.ahMailWaiting1 then
        return
    end
    global.migrations.ahMailWaiting1 = Now()
    local moved, dropped = 0, 0
    local sources = {}
    local serviceRoot = global.inventoryStateService
    if serviceRoot and type(serviceRoot.pendingAHMailboxEvidence) == "table" then
        sources[#sources + 1] = serviceRoot.pendingAHMailboxEvidence
    end
    if type(global.pendingAHMailboxEvidence) == "table" and global.pendingAHMailboxEvidence ~= (serviceRoot and serviceRoot.pendingAHMailboxEvidence) then
        sources[#sources + 1] = global.pendingAHMailboxEvidence
    end
    for _, source in ipairs(sources) do
        for ownerKey, rows in pairs(source) do
            if type(rows) == "table" then
                local groups = {}
                for _, row in pairs(rows) do
                    if type(row) == "table" and (row.type == "sold" or row.type == "returned") then
                        row.mailQuantity = row.mailQuantity or row.quantity
                        local contentKey = MailContentKey(ownerKey, row)
                        local group = groups[contentKey] or { perVisit = {}, sample = row, firstAt = nil }
                        local visit = tostring(row.mailboxScanSessionID or "?")
                        group.perVisit[visit] = (group.perVisit[visit] or 0) + 1
                        local at = tonumber(row.storedAt or row.timestamp)
                        if at and (not group.firstAt or at < group.firstAt) then
                            group.firstAt = at
                        end
                        groups[contentKey] = group
                        dropped = dropped + 1
                    end
                end
                waitingRoot[ownerKey] = waitingRoot[ownerKey] or {}
                for contentKey, group in pairs(groups) do
                    local copies = 0
                    for _, count in pairs(group.perVisit) do
                        copies = math.max(copies, count)
                    end
                    for n = 1, copies do
                        local row = CopyRow(group.sample)
                        row.evidenceKey = contentKey .. "@legacy#" .. n
                        row.contentKey = contentKey
                        row.ownerKey = ownerKey
                        row.arrivalAt = nil
                        row.arrivalPrecise = nil
                        row.inInbox = nil
                        row.mailboxScanSessionID = nil
                        row.mailboxScanTimestamp = nil
                        row.firstSeenAt = group.firstAt or Now()
                        row.legacy = true
                        waitingRoot[ownerKey][row.evidenceKey] = row
                        moved = moved + 1
                    end
                end
            end
        end
    end
    if serviceRoot then
        serviceRoot.pendingAHMailboxEvidence = {}
    end
    global.pendingAHMailboxEvidence = {}
    SessionLog("AHMailboxReconciler: old unmatched mail store moved to waiting list rows=%d (from %d saved copies)", moved, dropped)
end

local function MailStore(ownerKey)
    local global = PocketCFO and PocketCFO.db and PocketCFO.db.global
    if not global or not ownerKey or ownerKey == "" then
        return nil, nil
    end
    global.ahMailWaiting = global.ahMailWaiting or {}
    global.ahMailMatched = global.ahMailMatched or {}
    MigrateOldPendingEvidence(global, global.ahMailWaiting)
    global.ahMailWaiting[ownerKey] = global.ahMailWaiting[ownerKey] or {}
    global.ahMailMatched[ownerKey] = global.ahMailMatched[ownerKey] or {}
    return global.ahMailWaiting[ownerKey], global.ahMailMatched[ownerKey]
end

local function ArrivalsMatch(left, right)
    left, right = tonumber(left), tonumber(right)
    if not left or not right then
        return true
    end
    return math.abs(left - right) <= ARRIVAL_TOLERANCE_SECONDS
end

-- A legacy entry (moved over by MigrateOldPendingEvidence) stands for a mail
-- that was already in the inbox when the migration ran, so a mail that arrived
-- after that can't be it (2026-11-10: a Finesse knife cancel from today
-- claimed a Nov 6 legacy cancel entry). Unknown arrival: allowed, as before.
local function LegacyClaimAllowed(entry, arrivalAt)
    if not entry.legacy then
        return true
    end
    local global = PocketCFO and PocketCFO.db and PocketCFO.db.global
    local migratedAt = tonumber(global and global.migrations and global.migrations.ahMailWaiting1)
    arrivalAt = tonumber(arrivalAt)
    if not migratedAt or not arrivalAt then
        return true
    end
    return arrivalAt <= migratedAt
end

-- Finds the closest unclaimed entry with this contentKey whose arrival matches.
local function FindClaim(entries, contentKey, arrivalAt, claimed)
    local best, bestGap
    for key, entry in pairs(entries) do
        if not claimed[key] and type(entry) == "table" and entry.contentKey == contentKey
        and ArrivalsMatch(entry.arrivalAt, arrivalAt) and LegacyClaimAllowed(entry, arrivalAt) then
            local gap = (tonumber(entry.arrivalAt) and tonumber(arrivalAt)) and math.abs(entry.arrivalAt - arrivalAt) or math.huge
            if not best or gap < bestGap then
                best, bestGap = key, gap
            end
        end
    end
    return best
end

-- Already accounted for (2026-11-09): a mail that matches no open listing but
-- lines up with a listing already settled with the same outcome was matched
-- before (e.g. by the old code, before the waiting list existed). It moves to
-- the matched list instead of waiting 31 days.
-- * expired: the settled listing expired (posted + duration) within 15 minutes
--   of the mail's arrival.
-- * cancelled: the settled listing was cancelled (closedAt) within 15 minutes of
--   the mail's arrival.
-- * sold: the settled listing's posted price equals the sale price (needs the
--   invoice deposit / cut) and it was posted before the mail arrived.
-- Same item: the trusted configKey when known, else item ID, else name. Each
-- settled listing accounts for one mail only (remembered on the matched entry).
local ACCOUNTED_WINDOW_SECONDS = 900

local function SettledListings(ownerKey)
    local service = GetAHListingService()
    if service and service.GetSettledListings then
        return service:GetSettledListings({ ownerKey = ownerKey }) or {}
    end
    return {}
end

local function SameItem(row, listing)
    if row.configKey and row.configKey ~= "" then
        return listing.configKey == row.configKey
            or (row.legacyConfigKey ~= nil and listing.configKey == row.legacyConfigKey)
    end
    if row.itemID and listing.itemID then
        return tonumber(row.itemID) == tonumber(listing.itemID)
    end
    local left, right = NameKey(row.itemName), NameKey(listing.itemName or listing.name)
    return left ~= nil and left == right
end

local function AccountsFor(row, listing)
    local arrivalAt = tonumber(row.arrivalAt)
    local resolution = listing.mailboxResolution
    local postedAt = tonumber(listing.postedAt)
    if not SameItem(row, listing) then
        return false
    end
    if row.type == "sold" then
        local price = SalePrice(row)
        local buyout = tonumber(listing.buyout)
        local unitPrice = tonumber(listing.unitPrice)
        local quantity = tonumber(row.quantity) or 1
        return resolution == "sold" and price ~= nil
            and (buyout == price or (unitPrice ~= nil and unitPrice * quantity == price))
            and (not arrivalAt or not postedAt or postedAt <= arrivalAt)
    end
    if not arrivalAt or not row.arrivalPrecise then
        return false
    end
    local outcome = ReturnedOutcome(row)
    if outcome == "expired" and resolution == "expired" then
        local hours = tonumber(listing.durationHours)
        return postedAt ~= nil and hours ~= nil
            and math.abs(postedAt + hours * 3600 - arrivalAt) <= ACCOUNTED_WINDOW_SECONDS
    end
    if outcome == "cancelled" and resolution == "canceled" then
        local closedAt = tonumber(listing.closedAt)
        return closedAt ~= nil and math.abs(closedAt - arrivalAt) <= ACCOUNTED_WINDOW_SECONDS
    end
    return false
end

-- Removes already-accounted-for mail from result.unresolvedEvidence and records
-- result.accounted[evidenceKey] = auctionID. Only mail with nothing matched at all.
local function MarkAccountedFor(ownerKey, mailEvidence, result)
    if not result or not result.unresolvedEvidence or #result.unresolvedEvidence == 0 then
        return 0
    end
    local fullQuantity = {}
    for _, evidence in ipairs(mailEvidence or {}) do
        if evidence.evidenceKey then
            fullQuantity[evidence.evidenceKey] = tonumber(evidence.quantity) or 0
        end
    end
    local _, matched = MailStore(ownerKey)
    local used = {}
    for _, entry in pairs(matched or {}) do
        if type(entry) == "table" and entry.accountedAuctionID then
            used[tostring(entry.accountedAuctionID)] = true
        end
    end
    local settled = SettledListings(ownerKey)
    result.accounted = result.accounted or {}
    local kept, count = {}, 0
    for _, row in ipairs(result.unresolvedEvidence) do
        local key = row.evidenceKey
        local found
        if key and fullQuantity[key] and (tonumber(row.quantity) or 0) >= fullQuantity[key] then
            for _, listing in ipairs(settled) do
                local id = tostring(listing.auctionID or "")
                if id ~= "" and not used[id] and AccountsFor(row, listing) then
                    found = listing.auctionID
                    used[id] = true
                    break
                end
            end
        end
        if found then
            result.accounted[key] = found
            count = count + 1
        else
            kept[#kept + 1] = row
        end
    end
    result.unresolvedEvidence = kept
    return count
end

-- Splits inbox evidence into: already matched (dropped), already waiting (keeps
-- its stable key), new (gets a stable key). Returns the evidence to match.
function ClaimInboxMail(ownerKey, mailEvidence)
    local waiting, matched = MailStore(ownerKey)
    local stats = { inboxEvidence = #mailEvidence, alreadyMatched = 0, stillWaiting = 0, new = 0, claimedWaiting = {}, precise = 0 }
    for _, evidence in ipairs(mailEvidence) do
        if evidence.arrivalPrecise then
            stats.precise = stats.precise + 1
        end
        stats.sampleDaysLeft = stats.sampleDaysLeft or evidence.daysLeft
    end
    if not waiting then
        return mailEvidence, stats
    end
    local claimedMatched = {}
    local kept = {}
    for _, evidence in ipairs(mailEvidence) do
        local contentKey = MailContentKey(ownerKey, evidence)
        evidence.contentKey = contentKey
        local matchedKey = FindClaim(matched, contentKey, evidence.arrivalAt, claimedMatched)
        if matchedKey then
            claimedMatched[matchedKey] = true
            stats.alreadyMatched = stats.alreadyMatched + 1
        else
            local waitingKey = FindClaim(waiting, contentKey, evidence.arrivalAt, stats.claimedWaiting)
            if waitingKey then
                stats.claimedWaiting[waitingKey] = true
                local row = waiting[waitingKey]
                evidence.evidenceKey = waitingKey
                evidence.firstSeenAt = row.firstSeenAt
                -- A partly matched mail waits with only its unmatched quantity.
                evidence.quantity = tonumber(row.quantity) or evidence.quantity
                stats.stillWaiting = stats.stillWaiting + 1
            else
                local base = contentKey .. "@" .. tostring(evidence.arrivalAt and math.floor(evidence.arrivalAt / 60) or "?")
                local key, n = base, 1
                while waiting[key] or matched[key] do
                    n = n + 1
                    key = base .. "#" .. n
                end
                evidence.evidenceKey = key
                evidence.firstSeenAt = Now()
                stats.new = stats.new + 1
            end
            kept[#kept + 1] = evidence
        end
    end
    return kept, stats
end

-- Adds every waiting row not claimed by an inbox mail this pass (mail already
-- collected, or beyond the inbox's visible 50) to the evidence list.
function AddUnclaimedWaiting(ownerKey, mailEvidence, claimedWaiting)
    local waiting = MailStore(ownerKey)
    local added = 0
    for key, row in pairs(waiting or {}) do
        if type(row) == "table" and not claimedWaiting[key] then
            local evidence = CopyRow(row)
            evidence.evidenceKey = key
            evidence.inInbox = nil
            evidence.mailIndex = nil
            evidence.attachmentIndex = nil
            mailEvidence[#mailEvidence + 1] = evidence
            added = added + 1
        end
    end
    return added
end

-- After a pass: matched mail moves to the matched list; mail with quantity left
-- unmatched waits (with that quantity). Then both lists are trimmed.
function UpdateMailStore(ownerKey, mailEvidence, result, source)
    local waiting, matched = MailStore(ownerKey)
    if not waiting then
        return
    end
    local accountedCount = MarkAccountedFor(ownerKey, mailEvidence, result)
    local unmatchedQuantity = {}
    for _, row in ipairs(result and result.unresolvedEvidence or {}) do
        if row.evidenceKey then
            unmatchedQuantity[row.evidenceKey] = (unmatchedQuantity[row.evidenceKey] or 0) + (tonumber(row.quantity) or 0)
        end
    end
    local now = Now()
    local nowWaiting, nowMatched = 0, 0
    for _, evidence in ipairs(mailEvidence) do
        local key = evidence.evidenceKey
        if key then
            local left = unmatchedQuantity[key] or 0
            if left > 0 then
                local row = waiting[key] or {}
                for field, value in pairs(evidence) do
                    if field ~= "inInbox" and field ~= "mailIndex" and field ~= "attachmentIndex" then
                        row[field] = value
                    end
                end
                row.quantity = left
                row.ownerKey = ownerKey
                row.firstSeenAt = row.firstSeenAt or evidence.firstSeenAt or now
                row.lastTriedAt = now
                row.tries = (tonumber(row.tries) or 0) + 1
                waiting[key] = row
                nowWaiting = nowWaiting + 1
            else
                waiting[key] = nil
                matched[key] = {
                    contentKey = evidence.contentKey,
                    arrivalAt = evidence.arrivalAt,
                    matchedAt = now,
                    type = evidence.type,
                    accountedAuctionID = result and result.accounted and result.accounted[key] or nil,
                }
                nowMatched = nowMatched + 1
            end
        end
    end
    local cutoff = now - MAIL_KEEP_DAYS * 86400
    local trimmed = 0
    for key, row in pairs(waiting) do
        if type(row) ~= "table" or (tonumber(row.firstSeenAt) or 0) < cutoff then
            waiting[key] = nil
            trimmed = trimmed + 1
        end
    end
    for key, row in pairs(matched) do
        if type(row) ~= "table" or (tonumber(row.matchedAt) or 0) < cutoff then
            matched[key] = nil
            trimmed = trimmed + 1
        end
    end
    local waitingCount = 0
    for _ in pairs(waiting) do
        waitingCount = waitingCount + 1
    end
    SessionLog("AHMailboxReconciler: mail lists updated owner=%s source=%s matchedNow=%d (alreadyAccountedFor=%d) waitingNow=%d waitingTotal=%d trimmed=%d eliminated=%s",
        tostring(ownerKey), tostring(source), nowMatched, accountedCount, nowWaiting, waitingCount, trimmed,
        tostring(result and result.report and result.report.eliminatedListings or 0))
end

-- AH mail detection and evidence tracking (moved from MailboxScanner).
-- These helpers interpret AH meaning from raw mailbox observations.

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

    -- Build entries first (identity resolved per pass), then sum quantities by
    -- name for entries without a trusted configKey. Used by NameFallbackIsSafe to
    -- resolve all variants when totals match (elimination across the waiting list).
    local entries = {}
    local nameGroupEvidenceTotal = {}
    for index, evidence in ipairs(mailEvidence or {}) do
        local entry = BuildEvidenceEntry(evidence, index)
        if entry then
            entries[#entries + 1] = entry
            if entry.nameKey and not entry.configKey and not entry.identityPending
            and (EvidenceIsSold(evidence) or EvidenceIsReturned(evidence)) then
                nameGroupEvidenceTotal[entry.nameKey] = (nameGroupEvidenceTotal[entry.nameKey] or 0) + (entry.quantity or 0)
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

    -- Returned mail carries the exact item, so it settles its own listing first;
    -- a sale checked afterwards then sees that listing gone (2026-11-09).
    local ordered = {}
    for _, entry in ipairs(entries) do
        if EvidenceIsReturned(entry.evidence) then
            ordered[#ordered + 1] = entry
        end
    end
    for _, entry in ipairs(entries) do
        if not EvidenceIsReturned(entry.evidence) then
            ordered[#ordered + 1] = entry
        end
    end
    entries = ordered

    local eliminatedTotal = 0
    for _, entry in ipairs(entries) do
        local firstResult = #state.results + 1
        ResolveEntry(state, entry, byConfigKey, byName)
        eliminatedTotal = eliminatedTotal + (entry.eliminatedListings or 0)
        local ok, err = pcall(RememberResolvedSale, entry, state.results, firstResult)
        if not ok then
            SessionLog("AHMailboxReconciler: RememberResolvedSale error=%s", tostring(err))
        end
    end
    state.report.eliminatedListings = eliminatedTotal

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
    local submitted, submitErr = SubmitInventoryResults(ownerKey, soldResults)
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
                deposit   = invoice and invoice.deposit or nil,
                consignment = invoice and invoice.consignment or nil,
                mailIndex = obs.mailIndex,
                subject   = obs.subject,
                sender    = obs.sender,
            }
            StampMailAge(soldEvidence, obs.daysLeft)

            SessionLog("AHMailboxReconciler: sold AH mail detected mailIndex=%d itemName=%s quantity=%d invoiceType=%s money=%s delayed=%s",
                obs.mailIndex, tostring(soldItemName), soldQuantity,
                tostring(invoice and invoice.invoiceType), tostring(obs.money),
                tostring(invoice and invoice.moneyDelay))

            if not soldItemName or soldItemName == "" then
                skipRecorded = IncrementSkipReason(stats, "sold-missing-itemName")
                SessionLog("AHMailboxReconciler: sold AH evidence skipped mailIndex=%d reason=missing-itemName subject=%s invoiceType=%s",
                    obs.mailIndex, tostring(obs.subject), tostring(invoice and invoice.invoiceType))
            else
                mailEvidence[#mailEvidence + 1] = soldEvidence
                stats.soldEvidenceCount = stats.soldEvidenceCount + 1
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
                StampMailAge(returnedEvidence, obs.daysLeft)
                mailEvidence[#mailEvidence + 1] = returnedEvidence
                stats.returnedEvidenceCount = stats.returnedEvidenceCount + 1
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

    -- Waiting list (2026-11-09): skip mail already matched on an earlier visit,
    -- reuse the stable key of mail already waiting, then retry everything still
    -- waiting together with the new mail so elimination can work across visits.
    local inboxEvidence, claimStats = ClaimInboxMail(ownerKey, mailEvidence)
    mailEvidence = inboxEvidence
    local waitingAdded = AddUnclaimedWaiting(ownerKey, mailEvidence, claimStats.claimedWaiting)
    mailEvidence.scanStats = stats

    SessionLog("AHMailboxReconciler: mail claims owner=%s inbox=%d alreadyMatched=%d stillWaiting=%d new=%d waitingNotInInbox=%d preciseArrival=%d sampleDaysLeft=%s",
        tostring(ownerKey), claimStats.inboxEvidence, claimStats.alreadyMatched, claimStats.stillWaiting,
        claimStats.new, waitingAdded, claimStats.precise or 0, tostring(claimStats.sampleDaysLeft))

    if #mailEvidence == 0 then
        SessionLog("AHMailboxReconciler: no AH evidence to match owner=%s; skipping reconciliation", tostring(ownerKey))
        return nil
    end

    -- Direct returned-item inventory path: applies AH offset adjustments for returned
    -- attachments with a known configKey, without requiring a listing match.
    local returnedWithKey = {}
    for _, ev in ipairs(mailEvidence) do
        if EvidenceIsReturned(ev) and ev.inInbox and ev.configKey and ev.configKey ~= "" then
            returnedWithKey[#returnedWithKey + 1] = ev
        end
    end
    local returnedInventoryResult = nil
    if #returnedWithKey > 0 and AssistedReturnIsAllowed(ownerKey) then
        returnedInventoryResult = self:ResolveReturnedInventory(ownerKey, returnedWithKey)
    end

    local result = self:Resolve(mailEvidence)
    local results = result and result.results or {}
    local submission = result and result.inventorySubmission

    SessionLog("AHMailboxReconciler: reconciliation complete owner=%s evidence=%d results=%d returnedInventory=%d soldInventory=%d unresolved=%d listingClosures=%d submitError=%s",
        tostring(ownerKey), #mailEvidence, #results,
        tonumber(returnedInventoryResult and returnedInventoryResult.adjustmentCount) or 0,
        tonumber(submission and submission.adjustmentCount) or 0,
        #(result and result.unresolvedEvidence or {}),
        tonumber(result and result.listingClosures) or 0,
        tostring(result and result.inventorySubmissionError))

    UpdateMailStore(ownerKey, mailEvidence, result, "mailbox")

    return result
end

-- Retries the waiting list without the mailbox open (2026-11-09). Called after
-- a reliable owned-auctions scan: listings it just closed or saw still active
-- can settle held mail by elimination.
function AHMailboxReconciler:RetryWaitingMail(ownerKey, reason)
    if not ownerKey or ownerKey == "" then
        return nil
    end
    local candidates = {}
    AddUnclaimedWaiting(ownerKey, candidates, {})
    if #candidates == 0 then
        return nil
    end
    candidates.scanStats = {}
    local result = self:Resolve(candidates)
    UpdateMailStore(ownerKey, candidates, result, reason or "retry")
    return result
end
