-- PocketCFO/Services/ItemIdentityService/ItemIdentityService.lua
-- Canonical shared item identity service. This service is callable in Phase 1
-- but existing workflow consumers are not migrated to it yet.

local PocketCFO = _G.PocketCFO

local ItemIdentityService = {}

ItemIdentityService.baseFactsByItemID = ItemIdentityService.baseFactsByItemID or {}
ItemIdentityService.variantFactsByItemLink = ItemIdentityService.variantFactsByItemLink or {}
ItemIdentityService.requestedItemData = ItemIdentityService.requestedItemData or {}
ItemIdentityService.metadataRetryByItemKey = ItemIdentityService.metadataRetryByItemKey or {}
ItemIdentityService.identityDiagnostics = ItemIdentityService.identityDiagnostics or {}

local function GetAdapters()
    return PocketCFO and PocketCFO.ItemIdentityAdapters or _G.PocketCFO_ItemIdentityAdapters
end

local function GetClassifier()
    return PocketCFO and PocketCFO.ItemClassifier or _G.PocketCFO_ItemClassifier
end

local function GetCommodityResolver()
    return PocketCFO and PocketCFO.ItemCommodityResolver or _G.PocketCFO_ItemCommodityResolver
end

local function GetVariantResolver()
    return PocketCFO and PocketCFO.ItemVariantResolver or _G.PocketCFO_ItemVariantResolver
end

local function GetAuctionPathResolver()
    return PocketCFO and PocketCFO.ItemAuctionPathResolver or _G.PocketCFO_ItemAuctionPathResolver
end

local function GetConfigKeyBuilder()
    return PocketCFO and PocketCFO.ItemIdentityConfigKeyBuilder or _G.PocketCFO_ItemIdentityConfigKeyBuilder
end

local function NonEmpty(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return tostring(value)
end

local function NewUnresolved(source, reason)
    return {
        source = source or "unknown",
        evidenceType = source or "unknown",
        unresolved = true,
        unresolvedReason = reason or "identityUnresolved",
    }
end

local function DebugLog(msg, ...)
    if not PocketCFO or not PocketCFO.Debug then return end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:Debug("[ItemIdentityService] " .. tostring(msg))
end

function ItemIdentityService:GetResolutionCaches()
    self.baseFactsByItemID = self.baseFactsByItemID or {}
    self.variantFactsByItemLink = self.variantFactsByItemLink or {}
    self.requestedItemData = self.requestedItemData or {}
    self.metadataRetryByItemKey = self.metadataRetryByItemKey or {}
    self.identityDiagnostics = self.identityDiagnostics or {}
    return {
        baseFactsByItemID = self.baseFactsByItemID,
        variantFactsByItemLink = self.variantFactsByItemLink,
        requestedItemData = self.requestedItemData,
        metadataRetryByItemKey = self.metadataRetryByItemKey,
        diagnostics = self.identityDiagnostics,
    }
end

function ItemIdentityService:RecordResolutionDiagnostic(counter, detail)
    if type(counter) ~= "string" or counter == "" then return end
    local caches = self:GetResolutionCaches()
    local diagnostics = caches.diagnostics
    diagnostics[counter] = (diagnostics[counter] or 0) + 1
    DebugLog("%s%s", counter, detail and (" " .. tostring(detail)) or "")
end

local function Finalize(identity)
    if type(identity) ~= "table" then
        return NewUnresolved("unknown", "identityAdapterReturnedNil")
    end

    if not tonumber(identity.itemID) then
        identity.unresolved = true
        identity.unresolvedReason = identity.unresolvedReason or "missingItemID"
        ItemIdentityService:RecordResolutionDiagnostic("identity.unresolved", "reason=" .. tostring(identity.unresolvedReason))
        return identity
    end

    local classifier = GetClassifier()
    local commodityResolver = GetCommodityResolver()
    local variantResolver = GetVariantResolver()
    local auctionPathResolver = GetAuctionPathResolver()
    local configKeyBuilder = GetConfigKeyBuilder()

    identity.source = identity.source or identity.evidenceType or "unknown"
    identity.evidenceType = identity.evidenceType or identity.source
    identity.effectiveIlvl = tonumber(identity.effectiveIlvl or identity.effectiveItemLevel or identity.itemLevel or identity.ilvl)
    identity.effectiveItemLevel = identity.effectiveIlvl
    local rawStat = NonEmpty(identity.statFingerprint or identity.statTarget or identity.statKey)
    local adapters = GetAdapters()
    if rawStat and adapters and adapters.NormalizeVariantStatFingerprint then
        local filteredStat = adapters:NormalizeVariantStatFingerprint(rawStat)
        if filteredStat ~= rawStat then
            identity.droppedStatFingerprint = identity.droppedStatFingerprint or rawStat
        end
        identity.statFingerprint = filteredStat
    else
        identity.statFingerprint = rawStat
    end

    if classifier and classifier.Classify then
        identity.classification = identity.classification or classifier:Classify(identity)
    else
        identity.classification = identity.classification or "item"
    end
    if not NonEmpty(identity.classification) then
        identity.unresolved = true
        identity.unresolvedReason = identity.unresolvedReason or "classificationUnavailable"
    end

    if commodityResolver and commodityResolver.Apply then
        commodityResolver:Apply(identity)
    else
        identity.isCommodity = identity.isCommodity == true
        identity.commoditySource = identity.commoditySource or "default"
        identity.commodityReason = identity.commodityReason or "unknownDefaultItem"
    end

    if variantResolver and variantResolver.NormalizeIdentity then
        variantResolver:NormalizeIdentity(identity)
    end

    if variantResolver and variantResolver.Resolve then
        identity.variantType = identity.variantType or variantResolver:Resolve(identity)
        identity.matchingPath = identity.matchingPath or variantResolver:MatchingPath(identity)
    else
        identity.variantType = identity.variantType or "none"
        identity.matchingPath = identity.matchingPath or "itemID"
    end
    if not NonEmpty(identity.matchingPath) then
        identity.unresolved = true
        identity.unresolvedReason = identity.unresolvedReason or "matchingPathUnavailable"
    end

    if auctionPathResolver and auctionPathResolver.Resolve then
        identity.auctionPath = auctionPathResolver:Resolve(identity)
    else
        identity.auctionPath = identity.isCommodity == true and "commodity" or "item"
    end
    if not NonEmpty(identity.auctionPath) then
        identity.unresolved = true
        identity.unresolvedReason = identity.unresolvedReason or "auctionPathUnavailable"
    end

    if configKeyBuilder and configKeyBuilder.Build then
        local configKey, reason = configKeyBuilder:Build(identity)
        identity.configKey = identity.configKey or configKey
        if not identity.configKey then
            identity.unresolved = true
            identity.unresolvedReason = reason or "configKeyUnavailable"
        end
    end

    if identity.unresolved == true
        and identity.unresolvedReason == "itemDataPending"
        and identity.configKey
        and identity.matchingPath
        and identity.auctionPath
        and identity.classification
    then
        identity.unresolved = nil
        identity.unresolvedReason = nil
    end

    if identity.unresolved then
        ItemIdentityService:RecordResolutionDiagnostic("identity.unresolved", string.format(
            "reason=%s itemID=%s source=%s",
            tostring(identity.unresolvedReason),
            tostring(identity.itemID),
            tostring(identity.source)
        ))
    else
        ItemIdentityService:RecordResolutionDiagnostic("identity.resolved", string.format(
            "itemID=%s path=%s source=%s",
            tostring(identity.itemID),
            tostring(identity.matchingPath),
            tostring(identity.source)
        ))
    end

    identity.unresolved = identity.unresolved == true or nil
    return identity
end

function ItemIdentityService:Identify(evidence)
    local adapters = GetAdapters()
    if not adapters or type(adapters.FromEvidence) ~= "function" then
        return NewUnresolved("unknown", "identityAdaptersUnavailable")
    end

    local identity, reason = adapters:FromEvidence(evidence)
    if not identity then
        return NewUnresolved(type(evidence) == "table" and (evidence.evidenceType or evidence.source or evidence.type) or "unknown", reason)
    end
    return Finalize(identity)
end

function ItemIdentityService:Resolve(evidence)
    return self:Identify(evidence)
end

function ItemIdentityService:FromItem(row, source)
    return self:Identify({
        evidenceType = source or "item",
        row = row,
    })
end

function ItemIdentityService:FromItemID(itemID)
    local adapters = GetAdapters()
    local identity, reason = adapters and adapters:FromItemID(itemID)
    return identity and Finalize(identity) or NewUnresolved("itemID", reason or "identityAdaptersUnavailable")
end

function ItemIdentityService:BuildFromItemID(itemID)
    return self:FromItemID(itemID)
end

function ItemIdentityService:FromItemLink(itemLink)
    local adapters = GetAdapters()
    local identity, reason = adapters and adapters:FromItemLink(itemLink)
    return identity and Finalize(identity) or NewUnresolved("itemLink", reason or "identityAdaptersUnavailable")
end

function ItemIdentityService:BuildFromItemLink(itemLink)
    return self:FromItemLink(itemLink)
end

function ItemIdentityService:FromBagSlot(bag, slot)
    local adapters = GetAdapters()
    local identity, reason = adapters and adapters:FromBagSlot(bag, slot)
    return identity and Finalize(identity) or NewUnresolved("bagSlot", reason or "identityAdaptersUnavailable")
end

function ItemIdentityService:FromRecipeOutput(recipeID, options)
    local adapters = GetAdapters()
    local identity, reason = adapters and adapters:FromRecipeOutput(recipeID, options)
    return identity and Finalize(identity) or NewUnresolved("recipeOutput", reason or "identityAdaptersUnavailable")
end

function ItemIdentityService:BuildRecipeOutputIdentity(recipeID, options)
    options = type(options) == "table" and options or {}
    local adapters = GetAdapters()
    if adapters and adapters.ResolveRecipeTargetIlvl then
        local targetIlvl, targetItemID, resolutionDiag = adapters:ResolveRecipeTargetIlvl(
            options.recipeInfo,
            options.currentRecipeInfo,
            options.schematicInfo,
            options.operationInfo,
            options.expansionID
        )
        options.itemLevel = options.itemLevel or targetIlvl
        options.ilvl = options.ilvl or targetIlvl
        options.itemID = options.itemID or targetItemID
        options.outputItemID = options.outputItemID or targetItemID
            or options.schematicInfo and options.schematicInfo.outputItemID
            or options.recipeInfo and options.recipeInfo.outputItemID
        options.targetIlvl = targetIlvl
        options.targetItemID = targetItemID
        options.targetIlvlResolution = resolutionDiag
    end
    -- The schematic form's hyperlink is the predicted output item (with bonus IDs
    -- baked in), the same kind of reference bag/AH identity resolution uses to read
    -- real item stats. Propagating it here lets classification/variant resolution
    -- discover intrinsic armor/tool stats without depending on a selected missive.
    options.itemLink = options.itemLink or options.outputItemLink
        or (options.currentRecipeInfo and options.currentRecipeInfo.hyperlink)
        or (options.recipeInfo and options.recipeInfo.hyperlink)

    if adapters and adapters.GetMissiveStatFingerprint then
        options.statFingerprint = options.statFingerprint or adapters:GetMissiveStatFingerprint(options.optionalSlots)
        options.statTarget = options.statTarget or options.statFingerprint
    end
    local identity = self:FromRecipeOutput(recipeID, options)
    return identity, {
        targetIlvl = options.targetIlvl,
        targetItemID = options.targetItemID,
        statFingerprint = options.statFingerprint,
        targetIlvlResolution = options.targetIlvlResolution,
    }
end

function ItemIdentityService:FromAuctionRow(row)
    local adapters = GetAdapters()
    local identity, reason = adapters and adapters:FromAuctionRow(row)
    return identity and Finalize(identity) or NewUnresolved("auctionRow", reason or "identityAdaptersUnavailable")
end

function ItemIdentityService:FromOwnedAuctionRow(row)
    local adapters = GetAdapters()
    local identity, reason = adapters and adapters:FromOwnedAuctionRow(row)
    return identity and Finalize(identity) or NewUnresolved("ownedAuctionRow", reason or "identityAdaptersUnavailable")
end

function ItemIdentityService:FromSnapshotRow(row)
    local adapters = GetAdapters()
    local identity, reason = adapters and adapters:FromSnapshotRow(row)
    return identity and Finalize(identity) or NewUnresolved("snapshotRow", reason or "identityAdaptersUnavailable")
end

function ItemIdentityService:BuildConfigKey(identity)
    identity = Finalize(identity)
    return identity and identity.configKey, identity and identity.unresolvedReason
end

function ItemIdentityService:Matches(leftIdentity, rightIdentity)
    if type(leftIdentity) ~= "table" or type(rightIdentity) ~= "table" then
        return false, "missingIdentity"
    end
    if not leftIdentity.configKey then
        leftIdentity = Finalize(leftIdentity)
    end
    if not rightIdentity.configKey then
        rightIdentity = Finalize(rightIdentity)
    end
    return NonEmpty(leftIdentity.configKey) ~= nil
        and NonEmpty(leftIdentity.configKey) == NonEmpty(rightIdentity.configKey),
        "configKeyEquality"
end

function ItemIdentityService:ResolveConfigKey(configKey)
    return nil, "configKeyReverseLookupUnsupported"
end

if PocketCFO then
    PocketCFO.ItemIdentityService = ItemIdentityService
end

_G.ItemIdentityService = ItemIdentityService
