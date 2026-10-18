-- PocketCFO/Scanners/BankScanner.lua
-- Snapshot-focused bank session scanner.
-- Scanner observes bags + character bank + warbank and writes current-state
-- snapshot rows only. Identity is resolved through ItemIdentityService;
-- scanners do not own identity or filtering logic.

local ADDON_NAME, ns = ...
local PocketCFO = _G.PocketCFO

local BankScanner = PocketCFO:NewModule("BankScanner", "AceEvent-3.0")

local DEBOUNCE_SECONDS = 0.40

local LOCATION_BAGS = "bags"
local LOCATION_BANK = "bank"
local LOCATION_WARBANK = "warbank"

local function Debug(fmt, ...)
    if PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug(fmt, ...)
    end
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

local function GetCharacterOwnerKey()
    if UnitGUID then
        return UnitGUID("player")
    end
    return nil
end

local function GetWarbandOwnerKey()
    return "WARBAND"
end

local function AddUnique(list, seen, value)
    if value == nil or seen[value] then return end
    seen[value] = true
    list[#list + 1] = value
end

local function SafeNumSlots(containerID)
    if not C_Container or not C_Container.GetContainerNumSlots then
        return 0
    end

    local ok, slots = pcall(C_Container.GetContainerNumSlots, containerID)
    if ok and slots then
        return slots
    end

    return 0
end

local function SafeItemInfo(containerID, slot)
    if not C_Container or not C_Container.GetContainerItemInfo then
        return nil
    end

    local ok, info = pcall(C_Container.GetContainerItemInfo, containerID, slot)
    if ok then
        return info
    end

    return nil
end

local function SafeItemGUIDFromLocation(containerID, slot)
    if not ItemLocation or not ItemLocation.CreateFromBagAndSlot or not C_Item or not C_Item.GetItemGUID then
        return nil
    end

    local ok, itemLocation = pcall(function()
        return ItemLocation:CreateFromBagAndSlot(containerID, slot)
    end)
    if not ok or not itemLocation then
        return nil
    end

    if itemLocation.IsValid then
        local validOk, valid = pcall(function()
            return itemLocation:IsValid()
        end)
        if validOk and not valid then
            return nil
        end
    end

    local guidOk, itemGUID = pcall(C_Item.GetItemGUID, itemLocation)
    if guidOk and itemGUID and itemGUID ~= "" then
        return itemGUID
    end

    return nil
end

local function GetObservedItemGUID(info, containerID, slot)
    local itemGUID = info and info.itemGUID
    if itemGUID and itemGUID ~= "" then
        return itemGUID, "direct"
    end

    itemGUID = SafeItemGUIDFromLocation(containerID, slot)
    if itemGUID and itemGUID ~= "" then
        return itemGUID, "itemLocation"
    end

    return nil, nil
end

local function GetItemIdentityService()
    return PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
end

local function ResolveBagSlotIdentity(containerID, slot)
    local identityService = GetItemIdentityService()
    if not identityService then
        return nil, "identityServiceUnavailable"
    end

    if type(identityService.FromBagSlot) == "function" then
        local identity = identityService:FromBagSlot(containerID, slot)
        if identity and identity.configKey then
            return identity
        end
        return identity, identity and identity.unresolvedReason or "configKeyUnavailable"
    end

    if type(identityService.Identify) == "function" then
        local identity = identityService:Identify({
            evidenceType = "bagSlot",
            containerID  = containerID,
            bag          = containerID,
            slot         = slot,
        })
        if identity and identity.configKey then
            return identity
        end
        return identity, identity and identity.unresolvedReason or "configKeyUnavailable"
    end

    return nil, "bagSlotIdentityResolverUnavailable"
end

local function GetSlotBoundState(containerID, slot)
    local classifier = PocketCFO and PocketCFO.SoulboundClassifier or _G.PocketCFO_SoulboundClassifier
    if not classifier or type(classifier.BagSlotHasBoundTooltip) ~= "function" then
        return false
    end
    return classifier:BagSlotHasBoundTooltip(containerID, slot)
end

local function GetBankContainers()
    local containers, seen = {}, {}

    AddUnique(containers, seen, -1)
    AddUnique(containers, seen, -3)
    AddUnique(containers, seen, 6)
    AddUnique(containers, seen, 7)
    AddUnique(containers, seen, 8)
    AddUnique(containers, seen, 9)
    AddUnique(containers, seen, 10)
    AddUnique(containers, seen, 11)

    if Enum and Enum.BagIndex then
        AddUnique(containers, seen, Enum.BagIndex.Bank)
        AddUnique(containers, seen, Enum.BagIndex.Reagentbank)
        AddUnique(containers, seen, Enum.BagIndex.ReagentBank)
    end

    return containers
end

local function GetWarbankContainers()
    local containers, seen = {}, {}

    AddUnique(containers, seen, 12)
    AddUnique(containers, seen, 13)
    AddUnique(containers, seen, 14)
    AddUnique(containers, seen, 15)
    AddUnique(containers, seen, 16)

    if Enum and Enum.BagIndex then
        AddUnique(containers, seen, Enum.BagIndex.AccountBankTab_1)
        AddUnique(containers, seen, Enum.BagIndex.AccountBankTab_2)
        AddUnique(containers, seen, Enum.BagIndex.AccountBankTab_3)
        AddUnique(containers, seen, Enum.BagIndex.AccountBankTab_4)
        AddUnique(containers, seen, Enum.BagIndex.AccountBankTab_5)
    end

    return containers
end

local function ObserveContainers(location, ownerKey, containers)
    local aggregatedRows = {}
    local rows = {}
    local readableContainers = 0
    local totalSlots = 0
    local timestamp = PocketCFO:Now()
    local annotatedBoundCount = 0
    local annotatedBoundDetails = {}
    local unresolvedIdentitySlots = 0

    for _, containerID in ipairs(containers or {}) do
        local slots = SafeNumSlots(containerID)

        if slots > 0 then
            readableContainers = readableContainers + 1
            totalSlots = totalSlots + slots
        end

        for slot = 1, slots do
            local info = SafeItemInfo(containerID, slot)

            if info and info.itemID and info.itemID ~= 0 then
                local quantity = tonumber(info.stackCount) or 1

                if quantity > 0 then
                    local itemGUID, itemGUIDSource = GetObservedItemGUID(info, containerID, slot)
                    local identity, identityErr = ResolveBagSlotIdentity(containerID, slot)
                    local configKey = identity and identity.configKey

                    if not configKey then
                        unresolvedIdentitySlots = unresolvedIdentitySlots + 1
                        Debug("BankScanner: skipped unresolved identity location=%s container=%s slot=%s itemID=%s reason=%s",
                            tostring(location), tostring(containerID), tostring(slot),
                            tostring(info.itemID), tostring(identityErr))
                    else
                        if not aggregatedRows[configKey] then
                            local row = {
                                ownerKey        = ownerKey,
                                location        = location,
                                configKey       = configKey,
                                itemID          = tonumber(identity.itemID) or tonumber(info.itemID),
                                itemName        = identity.itemName or info.itemName,
                                itemQuality     = identity.itemQuality,
                                craftingQuality = identity.craftingQuality,
                                rarityQuality   = identity.rarityQuality or identity.quality,
                                ilvl            = identity.effectiveIlvl or identity.effectiveItemLevel,
                                itemLink        = identity.itemLink or info.hyperlink,
                                itemGUID        = itemGUID,
                                itemGUIDSource  = itemGUIDSource,
                                statFingerprint = identity.statFingerprint,
                                itemStats       = identity.itemStats,
                                matchingPath    = identity.matchingPath,
                                auctionPath     = identity.auctionPath,
                                classification  = identity.classification,
                                variantType     = identity.variantType,
                                quantity        = 0,
                                timestamp       = timestamp,
                                source          = "BankScanner",
                            }
                            aggregatedRows[configKey] = row
                            rows[#rows + 1] = row
                        else
                            local existing = aggregatedRows[configKey]
                            existing.itemName  = existing.itemName  or identity.itemName or info.itemName
                            existing.itemLink  = existing.itemLink  or identity.itemLink or info.hyperlink
                            existing.itemGUID  = existing.itemGUID  or itemGUID
                            existing.itemStats = existing.itemStats or identity.itemStats
                        end

                        aggregatedRows[configKey].quantity = (aggregatedRows[configKey].quantity or 0) + quantity

                        -- Annotate bind-state while slot context is available.
                        -- Conservative: if any slot for this configKey is bound, the whole row is marked bound.
                        -- InventoryFilterService uses isBound to exclude bound items from posting workflows.
                        if not aggregatedRows[configKey].isBound then
                            if GetSlotBoundState(containerID, slot) then
                                aggregatedRows[configKey].isBound = true
                                annotatedBoundCount = annotatedBoundCount + 1
                                annotatedBoundDetails[#annotatedBoundDetails + 1] = {
                                    itemID      = tonumber(identity.itemID) or tonumber(info.itemID),
                                    itemName    = identity.itemName or info.itemName,
                                    location    = location,
                                    containerID = containerID,
                                    slot        = slot,
                                }
                                SessionLog("BankScanner: annotated bound item itemName=%s itemID=%s location=%s container=%s slot=%s",
                                    tostring(identity.itemName or info.itemName),
                                    tostring(identity.itemID or info.itemID),
                                    tostring(location), tostring(containerID), tostring(slot))
                            end
                        end
                    end
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        if (a.itemName or "") ~= (b.itemName or "") then
            return (a.itemName or "") < (b.itemName or "")
        end
        if (a.itemID or 0) ~= (b.itemID or 0) then
            return (a.itemID or 0) < (b.itemID or 0)
        end
        return tostring(a.configKey or "") < tostring(b.configKey or "")
    end)

    return {
        location                = location,
        ownerKey                = ownerKey,
        readable                = readableContainers > 0,
        readableContainers      = readableContainers,
        totalSlots              = totalSlots,
        rows                    = rows,
        annotatedBoundCount     = annotatedBoundCount,
        annotatedBoundDetails   = annotatedBoundDetails,
        unresolvedIdentitySlots = unresolvedIdentitySlots,
        timestamp               = timestamp,
    }
end

local function LogObservationSummary(observation)
    local location = observation and observation.location or "unknown"
    local rows = observation and observation.rows or {}
    local totalRows = #rows
    local annotatedBoundCount = tonumber(observation and observation.annotatedBoundCount) or 0
    local unresolvedIdentitySlots = tonumber(observation and observation.unresolvedIdentitySlots) or 0

    SessionLog(
        "BankScanner: bank-session summary location=%s totalRows=%d annotatedBoundCount=%d unresolvedIdentitySlots=%d",
        tostring(location),
        totalRows,
        annotatedBoundCount,
        unresolvedIdentitySlots
    )
end

local function GetStoredSnapshotRowCount(ownerKey, location)
    local inventoryStateService = PocketCFO and (PocketCFO.InventoryStateService or _G.InventoryStateService)
    local snapshot = inventoryStateService
        and inventoryStateService.GetLocationSnapshot
        and inventoryStateService:GetLocationSnapshot(ownerKey, location)
        or nil

    if type(snapshot) ~= "table" then
        return 0, false
    end

    return #snapshot, true
end

function BankScanner:ScanOpenBankSession(reason)
    if not self.bankOpen then
        SessionLog("BankScanner: grouped scan skipped reason=%s bankOpen=false locations=bags,bank,warbank",
            tostring(reason))
        return
    end

    local characterOwnerKey = GetCharacterOwnerKey()
    if not characterOwnerKey then
        Debug("BankScanner: bank session scan skipped; no character owner key")
        return
    end

    local warbandOwnerKey = GetWarbandOwnerKey()

    Debug("BankScanner: Bank session scan started reason=%s", tostring(reason))
    SessionLog("Scan trigger: %s locations=bags,bank,warbank", tostring(reason or "bank-session"))

    local bagScanner = PocketCFO:GetModule("BagScanner", true)
    local bagObservation
    if bagScanner and bagScanner.ObserveBags then
        bagObservation = bagScanner:ObserveBags("bankSession")
    else
        Debug("BankScanner: bag observation skipped; BagScanner:ObserveBags missing")
        bagObservation = {
            location              = LOCATION_BAGS,
            ownerKey              = characterOwnerKey,
            readable              = false,
            readableContainers    = 0,
            totalSlots            = 0,
            rows                  = {},
            annotatedBoundCount   = 0,
            unresolvedIdentitySlots = 0,
        }
    end

    local bankObservation    = ObserveContainers(LOCATION_BANK,    characterOwnerKey, GetBankContainers())
    local warbankObservation = ObserveContainers(LOCATION_WARBANK, warbandOwnerKey,   GetWarbankContainers())

    LogObservationSummary(bagObservation)
    LogObservationSummary(bankObservation)
    LogObservationSummary(warbankObservation)

    local inventoryStateService = PocketCFO.InventoryStateService or _G.InventoryStateService
    if inventoryStateService and inventoryStateService.ReplaceSnapshot then
        inventoryStateService:ReplaceSnapshot(characterOwnerKey, LOCATION_BAGS, bagObservation.rows or {})
        inventoryStateService:ReplaceSnapshot(characterOwnerKey, LOCATION_BANK, bankObservation.rows or {})
        local attemptedWarbankRows = #(warbankObservation.rows or {})
        local storedWarbankRows = inventoryStateService:ReplaceSnapshot(warbandOwnerKey, LOCATION_WARBANK, warbankObservation.rows or {})
        local directWarbankRows, directWarbankExists = GetStoredSnapshotRowCount(warbandOwnerKey, LOCATION_WARBANK)

        SessionLog("BankScanner: warbank post-write verify owner=%s location=%s observedRows=%d attemptedRows=%d returnedRows=%d storedRows=%d storedPathExists=%s",
            tostring(warbandOwnerKey),
            LOCATION_WARBANK,
            #(warbankObservation.rows or {}),
            attemptedWarbankRows,
            #(storedWarbankRows or {}),
            directWarbankRows,
            tostring(directWarbankExists))
    end

    Debug(
        "BankScanner: Bank session scan complete: bags=%d bank=%d warbank=%d",
        #(bagObservation.rows or {}),
        #(bankObservation.rows or {}),
        #(warbankObservation.rows or {})
    )

    SessionLog("BankScanner: inventory state updated bags=%d bank=%d warbank=%d annotatedBoundCount=%d unresolvedIdentitySlots=%d reason=%s",
        #(bagObservation.rows or {}),
        #(bankObservation.rows or {}),
        #(warbankObservation.rows or {}),
        (tonumber(bagObservation.annotatedBoundCount) or 0)
            + (tonumber(bankObservation.annotatedBoundCount) or 0)
            + (tonumber(warbankObservation.annotatedBoundCount) or 0),
        (tonumber(bagObservation.unresolvedIdentitySlots) or 0)
            + (tonumber(bankObservation.unresolvedIdentitySlots) or 0)
            + (tonumber(warbankObservation.unresolvedIdentitySlots) or 0),
        tostring(reason))
end

function BankScanner:QueueBankSessionScan(reason)
    if not self.bankOpen then
        return
    end

    if self.pendingTimer then
        self.pendingTimer:Cancel()
        self.pendingTimer = nil
    end

    self.pendingTimer = C_Timer.NewTimer(DEBOUNCE_SECONDS, function()
        self.pendingTimer = nil
        self:ScanOpenBankSession(reason)
    end)
end

function BankScanner:OnBankOpened()
    self.bankOpen = true
    self:QueueBankSessionScan("bank-opened")
end

function BankScanner:OnBankClosed()
    self.bankOpen = false

    if self.pendingTimer then
        self.pendingTimer:Cancel()
        self.pendingTimer = nil
    end

    SessionLog("BankScanner: bank close; grouped close scan not scheduled locations=bags,bank,warbank")
end

function BankScanner:OnBankChanged()
    self:QueueBankSessionScan("bank-changed")
end

function BankScanner:OnBagChanged()
    self:QueueBankSessionScan("bag-changed-during-bank-session")
end

function BankScanner:OnWarbankOpened()
    self.bankOpen = true
    self:QueueBankSessionScan("warbank-opened")
end

function BankScanner:OnWarbankClosed()
    self.bankOpen = false

    if self.pendingTimer then
        self.pendingTimer:Cancel()
        self.pendingTimer = nil
    end

    SessionLog("BankScanner: warbank close; grouped close scan not scheduled locations=bags,bank,warbank")
end

function BankScanner:OnWarbankChanged()
    self:QueueBankSessionScan("warbank-changed")
end

function BankScanner:OnEnable()
    self.bankOpen = false
    self.pendingTimer = nil

    self:RegisterEvent("BANKFRAME_OPENED",    "OnBankOpened")
    self:RegisterEvent("BANKFRAME_CLOSED",    "OnBankClosed")
    self:RegisterEvent("BAG_UPDATE_DELAYED",  "OnBagChanged")

    pcall(function()
        self:RegisterEvent("ACCOUNT_BANK_PANEL_OPENED",  "OnWarbankOpened")
    end)

    pcall(function()
        self:RegisterEvent("ACCOUNT_BANK_PANEL_CLOSED",  "OnWarbankClosed")
    end)

    pcall(function()
        self:RegisterEvent("ACCOUNT_BANK_TABS_UPDATED",  "OnWarbankChanged")
    end)

    pcall(function()
        self:RegisterEvent("ACCOUNT_BANK_TAB_UPDATED",   "OnWarbankChanged")
    end)

    pcall(function()
        self:RegisterEvent("ACCOUNT_BANK_UPDATE",        "OnWarbankChanged")
    end)

    Debug("BankScanner: enabled")
end

-- Compatibility wrappers: observe only, no reconciliation.
function BankScanner:ScanCharacterBank()
    local ownerKey = GetCharacterOwnerKey()
    if not ownerKey then return nil end
    return ObserveContainers(LOCATION_BANK, ownerKey, GetBankContainers())
end

function BankScanner:ScanWarbandBank()
    return ObserveContainers(LOCATION_WARBANK, GetWarbandOwnerKey(), GetWarbankContainers())
end
