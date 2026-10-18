-- PocketCFO/Scanners/MailboxScanner.lua
-- Observes mailbox contents and writes current-state mail snapshots.
-- Does not interpret AH meaning, filter items, or own reconciliation.
-- AH interpretation belongs to AHMailboxReconciler.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local MailboxScanner = PocketCFO:NewModule("MailboxScanner", "AceEvent-3.0")

local debounceTimer = nil

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function GetInboxAttachmentLink(mailIndex, attachmentIndex)
    if GetInboxItemLink then
        local ok, itemLink = pcall(GetInboxItemLink, mailIndex, attachmentIndex)
        if ok and itemLink then
            return itemLink
        end
    end
    return nil
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

local function GetInboxInvoice(mailIndex)
    if not GetInboxInvoiceInfo then
        return nil
    end
    local ok, invoiceType, itemName, playerName, bid, buyout, deposit, consignment, moneyDelay, etaHour, etaMin, count, commerceAuction =
        pcall(GetInboxInvoiceInfo, mailIndex)
    if not ok then
        return nil
    end
    return {
        invoiceType     = invoiceType,
        itemName        = itemName,
        playerName      = playerName,
        bid             = bid,
        buyout          = buyout,
        deposit         = deposit,
        consignment     = consignment,
        moneyDelay      = moneyDelay,
        etaHour         = etaHour,
        etaMin          = etaMin,
        count           = count,
        commerceAuction = commerceAuction,
    }
end

local function ItemStatsKeyList(itemStats)
    if type(itemStats) ~= "table" then
        return "none"
    end
    local keys = {}
    for statKey in pairs(itemStats) do
        keys[#keys + 1] = tostring(statKey)
    end
    if #keys == 0 then
        return "none"
    end
    table.sort(keys)
    return table.concat(keys, "|")
end

local function GetInboxCounts()
    if not GetInboxNumItems then
        return 0, 0
    end
    local visible, total = GetInboxNumItems()
    visible = tonumber(visible) or 0
    total = tonumber(total) or visible
    return visible, total
end

local function ResolveAttachmentIdentity(itemLink, itemID)
    local identityService = PocketCFO.ItemIdentityService or _G.ItemIdentityService
    if not identityService then
        return nil, "identityServiceUnavailable"
    end
    if itemLink and identityService.FromItemLink then
        return identityService:FromItemLink(itemLink)
    end
    if itemID and identityService.FromItemID then
        return identityService:FromItemID(itemID)
    end
    return nil, "noLookupAvailable"
end

function MailboxScanner:WriteMailSnapshot(count)
    local characterGUID = PocketCFO.db.char.characterGUID
    if not characterGUID then
        return
    end

    local inventoryByConfigKey = {}
    local rows = {}
    local mailObservations = {}
    local timestamp = PocketCFO:Now()
    local inboxVisible, inboxTotal = GetInboxCounts()
    count = count or math.max(inboxVisible or 0, inboxTotal or 0)

    local scanStats = {
        inboxVisible   = inboxVisible,
        inboxTotal     = inboxTotal,
        rawMailScanned = 0,
    }

    for i = 1, count do
        local _, _, sender, subject, money, cod, daysLeft, hasItem, _, wasReturned = GetInboxHeaderInfo(i)
        scanStats.rawMailScanned = scanStats.rawMailScanned + 1

        local invoice = GetInboxInvoice(i)
        local attachments = {}

        if hasItem then
            for j = 1, ATTACHMENTS_MAX_RECEIVE do
                local name, itemIDFromAPI, texture, itemCount, rarityQuality = GetInboxItem(i, j)
                local quantity = tonumber(itemCount) or 0

                if (name or itemIDFromAPI) and quantity > 0 then
                    local itemLink = GetInboxAttachmentLink(i, j)
                    local itemID = GetItemIDFromLink(itemLink) or tonumber(itemIDFromAPI)

                    local identity, identityReason
                    if itemLink or itemID then
                        identity, identityReason = ResolveAttachmentIdentity(itemLink, itemID)
                    end

                    if identity then
                        SessionLog(
                            "MailboxScanner DIAG: ResolveAttachmentIdentity mailIndex=%d attachmentIndex=%d itemName=%s itemID=%s itemLinkPresent=%s unresolved=%s matchingPath=%s configKey=%s statFingerprint=%s itemStatsKeys=%s classification=%s variantType=%s",
                            i, j, tostring(name), tostring(itemID), tostring(itemLink ~= nil),
                            tostring(identity.unresolved), tostring(identity.matchingPath), tostring(identity.configKey),
                            tostring(identity.statFingerprint), ItemStatsKeyList(identity.itemStats),
                            tostring(identity.classification), tostring(identity.variantType)
                        )
                    else
                        SessionLog(
                            "MailboxScanner DIAG: ResolveAttachmentIdentity mailIndex=%d attachmentIndex=%d itemName=%s itemID=%s itemLinkPresent=%s identity=nil identityReason=%s",
                            i, j, tostring(name), tostring(itemID), tostring(itemLink ~= nil), tostring(identityReason)
                        )
                    end

                    local configKey = identity and not identity.unresolved and identity.configKey or nil
                    local itemName = name or (identity and identity.itemName)

                    local attachmentObs = {
                        mailIndex       = i,
                        attachmentIndex = j,
                        itemID          = itemID,
                        itemName        = itemName,
                        itemLink        = itemLink,
                        quantity        = quantity,
                        configKey       = configKey,
                        identity        = identity,
                        identityReason  = identityReason,
                        rarityQuality   = rarityQuality,
                    }
                    attachments[#attachments + 1] = attachmentObs

                    if itemID and itemID > 0 then
                        if configKey then
                            if inventoryByConfigKey[configKey] then
                                inventoryByConfigKey[configKey].quantity =
                                    inventoryByConfigKey[configKey].quantity + quantity
                            else
                                local row = {
                                    ownerKey        = characterGUID,
                                    location        = "mail",
                                    itemID          = tonumber(identity.itemID) or itemID,
                                    itemName        = identity.itemName or itemName,
                                    quantity        = quantity,
                                    itemLink        = identity.itemLink or itemLink,
                                    configKey       = configKey,
                                    isStackable     = identity.isStackable,
                                    itemQuality     = identity.itemQuality,
                                    craftingQuality = identity.craftingQuality,
                                    rarityQuality   = identity.rarityQuality or identity.quality or rarityQuality,
                                    ilvl            = identity.effectiveIlvl or identity.effectiveItemLevel or identity.itemLevel,
                                    statFingerprint = identity.statFingerprint,
                                    itemStats       = identity.itemStats,
                                    matchingPath    = identity.matchingPath,
                                    auctionPath     = identity.auctionPath,
                                    classification  = identity.classification,
                                    variantType     = identity.variantType,
                                    timestamp       = timestamp,
                                    source          = "MailboxScanner",
                                }

                                SessionLog(
                                    "MailboxScanner DIAG: row-before-add itemID=%s itemName=%s configKey=%s matchingPath=%s statFingerprint=%s itemStatsKeys=%s",
                                    tostring(row.itemID), tostring(row.itemName), tostring(row.configKey),
                                    tostring(row.matchingPath), tostring(row.statFingerprint), ItemStatsKeyList(row.itemStats)
                                )

                                inventoryByConfigKey[configKey] = row
                                rows[#rows + 1] = row
                            end
                        else
                            -- Identity unresolved: add as individual row without aggregation
                            rows[#rows + 1] = {
                                ownerKey      = characterGUID,
                                location      = "mail",
                                itemID        = itemID,
                                itemName      = itemName,
                                quantity      = quantity,
                                itemLink      = itemLink,
                                isStackable   = false,
                                rarityQuality = rarityQuality,
                                timestamp     = timestamp,
                                source        = "MailboxScanner",
                            }
                            SessionLog("MailboxScanner: attachment identity unresolved mailIndex=%d attachment=%d itemID=%s reason=%s",
                                i, j, tostring(itemID), tostring(identityReason))
                        end
                    else
                        SessionLog("MailboxScanner: skipped mailIndex=%d attachment=%d itemName=%s reason=missing-itemID",
                            i, j, tostring(name))
                    end
                elseif name or itemIDFromAPI then
                    SessionLog("MailboxScanner: skipped mailIndex=%d attachment=%d itemName=%s rawItemID=%s rawTexture=%s rawCount=%s normalizedQuantity=%d reason=missing-quantity",
                        i, j, tostring(name), tostring(itemIDFromAPI), tostring(texture), tostring(itemCount), quantity)
                end
            end
        end

        mailObservations[#mailObservations + 1] = {
            mailIndex   = i,
            sender      = sender,
            subject     = subject,
            money       = money,
            COD         = cod,
            daysLeft    = daysLeft,
            hasItem     = hasItem,
            wasReturned = wasReturned,
            invoice     = invoice,
            attachments = attachments,
        }
    end

    local inventoryStateService = PocketCFO.InventoryStateService or _G.InventoryStateService
    if inventoryStateService and inventoryStateService.ReplaceSnapshot then
        inventoryStateService:ReplaceSnapshot(characterGUID, "mail", rows)
    end

    local reconciler = PocketCFO:GetModule("AHMailboxReconciler", true)
    if reconciler and reconciler.ProcessMailboxObservations then
        reconciler:ProcessMailboxObservations(characterGUID, mailObservations, scanStats)
    end

    SessionLog("MailboxScanner: snapshot rows=%d mails=%d", #rows, count)
    PocketCFO:Debug("MailboxScanner:WriteMailSnapshot rows=%d mails=%d", #rows, count)
    return rows
end

function MailboxScanner:ScanInbox(reason)
    local characterGUID = PocketCFO.db.char.characterGUID
    if not characterGUID then return end

    SessionLog("Scan trigger: %s locations=mail", tostring(reason or "mailbox"))
    local inboxVisible, inboxTotal = GetInboxCounts()
    local scanCount = math.max(inboxVisible or 0, inboxTotal or 0)
    local rows = self:WriteMailSnapshot(scanCount) or {}
    PocketCFO.db.char.initialScanComplete.mailbox = true
    PocketCFO.db.char.lastMailboxScan = PocketCFO:Now()
    self:SendMessage("MCGCFO_MAILBOX_SCAN_COMPLETE")

    PocketCFO:Debug("MailboxScanner:ScanInbox complete reason=%s snapshotRows=%d mails=%d",
        tostring(reason or "mailbox"), #rows, scanCount)
end

function MailboxScanner:OnMailShow()
    C_Timer.After(0.1, function()
        self:ScanInbox("mailbox-open")
    end)
end

function MailboxScanner:OnMailInboxUpdate()
    if debounceTimer then
        debounceTimer:Cancel()
        debounceTimer = nil
    end
    local scanner = self
    debounceTimer = C_Timer.NewTimer(0.6, function()
        debounceTimer = nil
        scanner:ScanInbox("mail-inbox-update-debounced")
    end)
end

function MailboxScanner:OnMailClosed()
    if debounceTimer then
        debounceTimer:Cancel()
        debounceTimer = nil
    end
    SessionLog("MailboxScanner: mailbox close; cancelled pending debounce if any")
end

function MailboxScanner:OnEnable()
    self:RegisterEvent("MAIL_SHOW", "OnMailShow")
    self:RegisterEvent("MAIL_INBOX_UPDATE", "OnMailInboxUpdate")
    self:RegisterEvent("MAIL_CLOSED", "OnMailClosed")
end
