-- PocketCFO_AH/Services/AuctionLookup/AuctionLookupService.lua
-- Live Auction House lookup and normalization service.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local AuctionLookupService = {}
local callbacksByID = {}
local callbacksByName = {}
local pendingNameByItemKey = {}
local pendingLookupKeyByItemID = {}
local pendingLookupContext = {}
local pendingBrowseLookups = {}

local frame = CreateFrame and CreateFrame("Frame") or nil

local function DebugEnabled()
    local settings = PocketCFO_AH
        and PocketCFO_AH.db
        and PocketCFO_AH.db.global
        and PocketCFO_AH.db.global.postingSettings
        or nil
    return settings
        and settings.debug
        and settings.debug.captureCompetitionRows == true
end

local function SessionLog(msg, ...)
    if not DebugEnabled() then
        return
    end
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function SafeCall(callback, value, meta)
    if type(callback) == "function" then
        callback(value, meta)
    end
end

local function ShallowCopyTable(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function ItemKeyDebugString(itemKey)
    if type(itemKey) ~= "table" then
        return tostring(itemKey)
    end
    return string.format("{itemID=%s,itemLevel=%s,itemSuffix=%s,battlePetSpeciesID=%s}",
        tostring(itemKey.itemID),
        tostring(itemKey.itemLevel),
        tostring(itemKey.itemSuffix),
        tostring(itemKey.battlePetSpeciesID))
end

local function BuildSorts()
    if _G.Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
        return {
            {
                sortOrder = Enum.AuctionHouseSortOrder.Price,
                reverseSort = false,
            },
        }
    end
    return {}
end

local function NormalizeName(value)
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    value = value:gsub("%s+", " ")
    return value
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

local function IsPositiveCommodityStatus(status)
    if status == true then
        return true
    end
    if type(status) == "table" then
        return IsPositiveCommodityStatus(status.isCommodity or status.commodity or status.status)
    end
    if type(status) == "number" then
        local commodityStatus = _G.Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity
        if commodityStatus ~= nil then
            return status == commodityStatus
        end
        return false
    end
    if type(status) == "string" then
        status = status:lower()
        return status == "commodity" or status == "itemcommodity" or status == "item_commodity"
    end
    return false
end

local function ExtractItemLink(row)
    if type(row) ~= "table" then
        return nil
    end
    return row.itemLink or row.hyperlink or row.link
end

local function ExtractItemKey(row)
    if type(row) ~= "table" then
        return nil
    end
    if type(row.itemKey) == "table" then
        return row.itemKey
    end
    if type(row.key) == "table" then
        return row.key
    end
    if type(row.itemKeyInfo) == "table" and type(row.itemKeyInfo.itemKey) == "table" then
        return row.itemKeyInfo.itemKey
    end
    return nil
end

local function ExtractItemID(row, itemLink)
    if type(row) ~= "table" then
        return nil
    end
    if row.itemID or row.itemId then
        return tonumber(row.itemID or row.itemId)
    end
    local itemKey = ExtractItemKey(row)
    if itemKey and itemKey.itemID then
        return tonumber(itemKey.itemID)
    end
    return GetItemIDFromLink(itemLink or ExtractItemLink(row))
end

local function ExtractItemName(row, itemID, itemLink)
    if type(row) ~= "table" then
        return nil
    end
    if row.itemName or row.name then
        return row.itemName or row.name
    end
    if itemLink and GetItemInfo then
        local itemName = GetItemInfo(itemLink)
        if itemName then
            return itemName
        end
    end
    if itemID and GetItemInfo then
        local itemName = GetItemInfo(itemID)
        if itemName then
            return itemName
        end
    end
    if row.itemKey and C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
        local ok, itemKeyInfo = pcall(C_AuctionHouse.GetItemKeyInfo, row.itemKey)
        if ok and type(itemKeyInfo) == "table" then
            return itemKeyInfo.itemName
        end
    end
    return nil
end

local function ExtractBrowseItemKey(row)
    if type(row) ~= "table" then
        return nil
    end
    if type(row.itemKey) == "table" then
        return row.itemKey
    end
    if type(row.key) == "table" then
        return row.key
    end
    if type(row.itemKeyInfo) == "table" and type(row.itemKeyInfo.itemKey) == "table" then
        return row.itemKeyInfo.itemKey
    end
    return nil
end

local function ExtractBrowseName(row)
    if type(row) ~= "table" then
        return nil
    end
    if row.name or row.itemName then
        return row.name or row.itemName
    end
    local itemKey = ExtractBrowseItemKey(row)
    if itemKey and C_AuctionHouse and C_AuctionHouse.GetItemKeyInfo then
        local ok, itemKeyInfo = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
        if ok and type(itemKeyInfo) == "table" then
            return itemKeyInfo.itemName
        end
    end
    return nil
end

local function GetItemStatsAndFingerprint(itemLink)
    if not itemLink or not C_Item or not C_Item.GetItemStats then
        return nil
    end

    local ok, stats = pcall(C_Item.GetItemStats, itemLink)
    if not ok or type(stats) ~= "table" then
        return nil
    end

    local keys = {}
    for statKey in pairs(stats) do
        keys[#keys + 1] = statKey
    end
    if #keys == 0 then
        return nil
    end

    table.sort(keys)
    return table.concat(keys, "|")
end

local function GetCraftingQuality(itemLink, itemID)
    if C_TradeSkillUI then
        if itemLink and type(C_TradeSkillUI.GetItemCraftedQualityByItemInfo) == "function" then
            local ok, quality = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, itemLink)
            if ok and tonumber(quality) then
                return tonumber(quality)
            end
        end
        if itemID and type(C_TradeSkillUI.GetItemCraftedQualityByItemInfo) == "function" then
            local ok, quality = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, itemID)
            if ok and tonumber(quality) then
                return tonumber(quality)
            end
        end
    end
    return nil
end

local function GetItemInfoFields(itemID, itemLink)
    local itemName, resolvedLink, itemQuality, ilvl, equipLoc, itemClassID, itemSubClassID
    if itemLink and GetItemInfo then
        itemName, resolvedLink, itemQuality, ilvl, _, _, _, _, equipLoc, _, _, itemClassID, itemSubClassID = GetItemInfo(itemLink)
    end
    if not itemName and itemID and GetItemInfo then
        itemName, resolvedLink, itemQuality, ilvl, _, _, _, _, equipLoc, _, _, itemClassID, itemSubClassID = GetItemInfo(itemID)
    end
    return itemName, resolvedLink or itemLink, itemQuality, tonumber(ilvl) or nil, equipLoc, tonumber(itemClassID), tonumber(itemSubClassID)
end

local function NormalizeAuctionRow(row, isCommodity, forcedItemID)
    if type(row) ~= "table" then
        return nil
    end

    local itemLink = ExtractItemLink(row)
    local itemKey = ExtractItemKey(row)
    local itemID = forcedItemID or ExtractItemID(row, itemLink)
    local infoName, resolvedLink, itemQuality, ilvl, equipLoc, itemClassID, itemSubClassID = GetItemInfoFields(itemID, itemLink)
    itemLink = itemLink or resolvedLink

    local itemName = ExtractItemName(row, itemID, itemLink) or infoName
    if not itemName and not itemID then
        return nil
    end

    local quantity = tonumber(row.quantity or row.stackSize or row.count or row.numItems)
    local buyoutAmount = tonumber(row.buyoutAmount or row.buyout or row.buyoutPrice or row.totalPrice)
    local explicitUnitPrice = tonumber(row.unitPrice or row.pricePerUnit)
    local unitPrice = explicitUnitPrice
    if isCommodity == true and (not unitPrice or unitPrice <= 0) and buyoutAmount and buyoutAmount > 0 and quantity and quantity > 0 then
        unitPrice = math.floor((buyoutAmount / quantity) + 0.5)
    end
    local price = isCommodity == true and unitPrice or buyoutAmount

    return {
        auctionID = row.auctionID or row.auctionId or row.listingID or row.listingId,
        itemID = itemID,
        itemName = itemName,
        itemLink = itemLink,
        itemClassID = itemClassID,
        itemSubClassID = itemSubClassID,
        equipLoc = equipLoc,
        quantity = quantity,
        unitPrice = unitPrice,
        price = price,
        buyoutAmount = buyoutAmount,
        ilvl = tonumber(row.ilvl or row.itemLevel or itemKey and itemKey.itemLevel) or ilvl,
        effectiveItemLevel = tonumber(row.effectiveItemLevel or row.ilvl or row.itemLevel or itemKey and itemKey.itemLevel) or ilvl,
        craftingQuality = row.craftingQuality or row.qualityTier or GetCraftingQuality(itemLink, itemID),
        itemQuality = row.rarityQuality or itemQuality,
        statFingerprint = row.statFingerprint or row.statKey or row.statTarget or GetItemStatsAndFingerprint(itemLink),
        owner = row.owner or row.ownerFullName or row.seller,
        timeLeft = row.timeLeft or row.durationLeft or row.duration,
        isCommodity = isCommodity,
        rawRow = row,
    }
end

local function GetItemSearchRows(itemKey)
    local rows = {}
    if not C_AuctionHouse or not C_AuctionHouse.GetNumItemSearchResults or not C_AuctionHouse.GetItemSearchResultInfo then
        return rows, 0, "item search result APIs unavailable"
    end

    local okCount, count = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
    if not okCount then
        return rows, 0, tostring(count)
    end

    count = tonumber(count) or 0
    for index = 1, count do
        local ok, row = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, index)
        if ok and row then
            rows[#rows + 1] = row
        end
    end
    return rows, count, nil
end

local function GetCommodityRows(itemID)
    local rows = {}
    if not itemID or not C_AuctionHouse or not C_AuctionHouse.GetNumCommoditySearchResults or not C_AuctionHouse.GetCommoditySearchResultInfo then
        return rows
    end

    local okCount, count = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
    if not okCount then
        return rows
    end

    for index = 1, tonumber(count) or 0 do
        local ok, row = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, index)
        if ok and row then
            rows[#rows + 1] = row
        end
    end
    return rows
end

local function NormalizeRows(rows, isCommodity, forcedItemID)
    local auctions = {}
    for _, row in ipairs(rows or {}) do
        local auction = NormalizeAuctionRow(row, isCommodity, forcedItemID)
        if auction then
            auctions[#auctions + 1] = auction
        end
    end
    return auctions
end

local function FinishNameLookup(itemName, auctions, meta)
    local callbacks = callbacksByName[itemName]
    callbacksByName[itemName] = nil
    pendingLookupContext[itemName] = nil
    pendingBrowseLookups[itemName] = nil
    if not callbacks then
        return
    end

    for _, callback in ipairs(callbacks) do
        SafeCall(callback, auctions or {}, meta)
    end
end

local function ItemKeyToken(itemKey)
    if type(itemKey) ~= "table" then
        return tostring(itemKey)
    end
    return table.concat({
        tostring(itemKey.itemID or ""),
        tostring(itemKey.itemLevel or ""),
        tostring(itemKey.itemSuffix or ""),
        tostring(itemKey.battlePetSpeciesID or ""),
    }, ":")
end

local function BuildItemKey(itemID)
    itemID = tonumber(itemID)
    if not itemID then
        return nil
    end
    if C_AuctionHouse and type(C_AuctionHouse.MakeItemKey) == "function" then
        local ok, itemKey = pcall(C_AuctionHouse.MakeItemKey, itemID, 0, 0, 0)
        if ok and type(itemKey) == "table" then
            return itemKey
        end
        ok, itemKey = pcall(C_AuctionHouse.MakeItemKey, itemID)
        if ok and type(itemKey) == "table" then
            return itemKey
        end
    end
    return { itemID = itemID, battlePetSpeciesID = 0, itemSuffix = 0 }
end

local function BuildDirectItemKey(row, candidate, itemID)
    itemID = tonumber(itemID)
    if not itemID then
        return nil
    end

    local itemKey = BuildItemKey(itemID)
    if type(itemKey) ~= "table" then
        itemKey = { itemID = itemID }
    end
    itemKey.itemID = itemID

    local sourceKey = ExtractItemKey(row)
    if type(sourceKey) ~= "table" or tonumber(sourceKey.itemID) ~= itemID then
        sourceKey = ExtractItemKey(candidate)
    end
    if type(sourceKey) == "table" and tonumber(sourceKey.itemID) == itemID then
        if sourceKey.battlePetSpeciesID ~= nil then
            itemKey.battlePetSpeciesID = sourceKey.battlePetSpeciesID
        end
        if sourceKey.itemSuffix ~= nil then
            itemKey.itemSuffix = sourceKey.itemSuffix
        end
    end

    itemKey.battlePetSpeciesID = itemKey.battlePetSpeciesID or 0
    itemKey.itemSuffix = itemKey.itemSuffix or 0
    return itemKey
end

local function IsEquipmentCandidate(row, candidate)
    local equipLoc = candidate and (candidate.equipLoc or candidate.inventoryType)
        or row and (row.equipLoc or row.inventoryType)
    if equipLoc ~= nil and tostring(equipLoc) ~= "" then
        return true
    end

    local itemRef = candidate and (candidate.itemLink or candidate.itemID)
        or row and (row.itemLink or row.itemID)
    if itemRef and GetItemInfo then
        local ok, _, _, _, _, _, _, _, _, resolvedEquipLoc = pcall(GetItemInfo, itemRef)
        if ok and resolvedEquipLoc and tostring(resolvedEquipLoc) ~= "" then
            return true
        end
    end
    return false
end

local function RegisterPendingItemLookup(lookupKey, itemKey)
    pendingNameByItemKey[itemKey] = lookupKey
    if itemKey and itemKey.itemID then
        pendingNameByItemKey[tostring(itemKey.itemID)] = lookupKey
        pendingLookupKeyByItemID[tostring(itemKey.itemID)] = lookupKey
    end
end

local function ClearPendingItemLookup(lookupKey, itemKey)
    pendingNameByItemKey[itemKey] = nil
    if itemKey and itemKey.itemID then
        local itemIDKey = tostring(itemKey.itemID)
        if pendingNameByItemKey[itemIDKey] == lookupKey then
            pendingNameByItemKey[itemIDKey] = nil
        end
        if pendingLookupKeyByItemID[itemIDKey] == lookupKey then
            pendingLookupKeyByItemID[itemIDKey] = nil
        end
    end
end

local function FinishItemLookupWithZero(lookupKey, itemKey, context, reason)
    ClearPendingItemLookup(lookupKey, itemKey)
    FinishNameLookup(lookupKey, {}, {
        path = "itemAuction",
        rawCount = 0,
        completed = context and context.completed == true or false,
        requestMade = context and context.requestMade == true or false,
        requestAPI = context and context.requestAPI,
        requestItemKey = context and ItemKeyDebugString(context.requestItemKey or itemKey),
        source = "C_AuctionHouse.GetItemSearchResultInfo",
        sourceRowsBeforeFiltering = context and context.sourceRowsBeforeFiltering or 0,
        zeroReason = reason or context and context.zeroReason or "item search returned zero rows",
        itemKeyInfoAvailable = context and context.itemKeyInfoAvailable == true or false,
        attempts = context and context.attempts or 0,
    })
end

local ProcessBrowseRowsForNameLookup

local function GetCurrentBrowseRows()
    if C_AuctionHouse and type(C_AuctionHouse.GetBrowseResults) == "function" then
        local ok, rows = pcall(C_AuctionHouse.GetBrowseResults)
        if ok and type(rows) == "table" then
            return rows
        end
    end
    return {}
end

local function ScheduleBrowseResultPolls(lookupKey)
    if not C_Timer or type(C_Timer.After) ~= "function" then
        return
    end
    for _, delay in ipairs({ 0.25, 0.75, 1.5, 3.0 }) do
        C_Timer.After(delay, function()
            if pendingBrowseLookups[lookupKey] and ProcessBrowseRowsForNameLookup then
                ProcessBrowseRowsForNameLookup(lookupKey, GetCurrentBrowseRows())
            end
        end)
    end
end

local function SnapshotPendingBrowseLookupKeys()
    local keys = {}
    local lookupKey = next(pendingBrowseLookups)
    while lookupKey ~= nil do
        keys[#keys + 1] = lookupKey
        lookupKey = next(pendingBrowseLookups, lookupKey)
    end
    return keys
end

local function RequestBrowseNameSearch(lookupKey)
    if not C_AuctionHouse or type(C_AuctionHouse.SendBrowseQuery) ~= "function" then
        return false
    end
    local context = pendingLookupContext[lookupKey] or {}
    pendingLookupContext[lookupKey] = context
    context.path = "nameSearch"
    context.nameGather = true
    context.requestMade = true
    context.requestAPI = "C_AuctionHouse.SendBrowseQuery"
    context.source = "C_AuctionHouse.GetBrowseResults -> detail result source by item key"
    context.zeroReason = "browse query requested; waiting for browse results"
    local query = {
        searchString = context.itemName or "",
        sorts = BuildSorts(),
        filters = {},
        itemClassFilters = {},
    }
    context.requestQuery = query
    local ok = pcall(C_AuctionHouse.SendBrowseQuery, query)
    if not ok then
        context.zeroReason = "browse query API call failed"
    end
    SessionLog("AuctionLookup: requesting item-auction browse name=%s ok=%s",
        tostring(context.itemName), tostring(ok))
    if ok then
        ScheduleBrowseResultPolls(lookupKey)
    end
    return ok and true or false
end

local RequestItemSearch
local RequestCommodityNameDetailSearch
local StartBrowseNameLookup

local function DirectLookupFallbackReason(meta)
    if type(meta) ~= "table" then
        return "direct itemID lookup returned no metadata"
    end
    if meta.requestMade ~= true then
        return meta.zeroReason or "direct itemID lookup request was not made"
    end
    if meta.completed ~= true then
        return meta.zeroReason or "direct itemID lookup did not complete"
    end
    if meta.sourceError then
        return "direct itemID lookup source read failed: " .. tostring(meta.sourceError)
    end
    if tonumber(meta.rawCount) and tonumber(meta.rawCount) > 0 then
        return nil
    end
    if meta.hasFullItemSearchResults == true then
        return nil
    end
    return meta.zeroReason or "direct itemID lookup returned zero rows without a clean completion signal"
end

local function QueueNextNameDetailSearch(lookupKey)
    local context = pendingLookupContext[lookupKey]
    if not context then
        return false
    end
    local queue = context.detailQueue or {}
    context.detailIndex = (tonumber(context.detailIndex) or 0) + 1
    local itemKey = queue[context.detailIndex]
    if not itemKey then
        FinishNameLookup(lookupKey, context.auctions or {}, {
            path = context.path or "nameSearch",
            rawCount = #(context.auctions or {}),
            completed = true,
            requestMade = context.requestMade == true,
            requestAPI = context.requestAPI,
            requestQuery = context.requestQuery,
            source = context.source,
            sourceRowsBeforeFiltering = tonumber(context.sourceRowsBeforeFiltering) or 0,
            browseRowsMatchedByName = tonumber(context.browseRowsMatchedByName) or 0,
            detailKeysQueued = #(context.detailQueue or {}),
            itemAuctionDetailKeysQueued = tonumber(context.itemAuctionDetailKeysQueued) or 0,
            commodityDetailKeysQueued = tonumber(context.commodityDetailKeysQueued) or 0,
            itemAuctionRowsCollected = tonumber(context.itemAuctionRowsCollected) or 0,
            commodityRowsCollected = tonumber(context.commodityRowsCollected) or 0,
            zeroReason = #(context.auctions or {}) == 0 and (context.zeroReason or "name browse/detail search returned zero item-auction rows") or nil,
            attempts = context.attempts,
            fallbackFromPath = context.fallbackFromPath,
            fallbackReason = context.fallbackReason,
        })
        return true
    end

    if type(itemKey) == "table" and itemKey.__detailSource == "commodity" then
        return RequestCommodityNameDetailSearch(lookupKey, itemKey.itemKey or itemKey)
    end

    RegisterPendingItemLookup(lookupKey, itemKey)
    return RequestItemSearch(lookupKey, itemKey, context.row, context.candidate)
end

local function FinishIDLookup(auctionID, auction)
    local callbacks = callbacksByID[tostring(auctionID)]
    callbacksByID[tostring(auctionID)] = nil
    if not callbacks then
        return
    end

    for _, callback in ipairs(callbacks) do
        SafeCall(callback, auction)
    end
end

local function FindAuctionInRows(auctionID, rows, isCommodity)
    local wanted = tostring(auctionID)
    for _, row in ipairs(rows or {}) do
        local rowAuctionID = row and (row.auctionID or row.auctionId or row.listingID or row.listingId)
        if rowAuctionID ~= nil and tostring(rowAuctionID) == wanted then
            return NormalizeAuctionRow(row, isCommodity)
        end
    end
    return nil
end

local function SearchCurrentResultsForAuction(auctionID)
    if C_AuctionHouse and C_AuctionHouse.GetBrowseResults then
        local ok, rows = pcall(C_AuctionHouse.GetBrowseResults)
        if ok then
            local auction = FindAuctionInRows(rows, auctionID, nil)
            if auction then
                return auction
            end
        end
    end

    if C_AuctionHouse and C_AuctionHouse.GetOwnedAuctions then
        local ok, rows = pcall(C_AuctionHouse.GetOwnedAuctions)
        if ok then
            local auction = FindAuctionInRows(rows, auctionID, nil)
            if auction then
                return auction
            end
        end
    end

    return nil
end

local function RequestNameSearch(itemName)
    if not C_AuctionHouse then
        return false
    end

    if C_AuctionHouse.SearchForItemKeys then
        local ok = pcall(C_AuctionHouse.SearchForItemKeys, itemName, {})
        if ok then
            return true
        end
    end

    return false
end

local function ScheduleNameLookupTimeout(itemName)
    if C_Timer and C_Timer.After then
        C_Timer.After(5.0, function()
            if callbacksByName[itemName] then
                local context = pendingLookupContext[itemName]
                if context and context.nameGather == true and pendingBrowseLookups[itemName] then
                    if ProcessBrowseRowsForNameLookup then
                        ProcessBrowseRowsForNameLookup(itemName, GetCurrentBrowseRows())
                    end
                    if callbacksByName[itemName] and context.detailQueueStarted == true then
                        context.timeoutPolls = (tonumber(context.timeoutPolls) or 0) + 1
                        context.zeroReason = "item detail searches still pending after browse name match"
                        if context.timeoutPolls < 3 then
                            ScheduleNameLookupTimeout(itemName)
                            return
                        end
                    end
                    if callbacksByName[itemName] and not context.detailQueueStarted then
                        context.timeoutPolls = (tonumber(context.timeoutPolls) or 0) + 1
                        context.zeroReason = "browse query still waiting for matching browse rows"
                        if context.timeoutPolls < 3 then
                            ScheduleBrowseResultPolls(itemName)
                            ScheduleNameLookupTimeout(itemName)
                            return
                        end
                    end
                end
                FinishNameLookup(itemName, {}, {
                    path = context and context.path or "nameSearch",
                    rawCount = 0,
                    completed = false,
                    requestMade = context and context.requestMade == true or false,
                    requestAPI = context and context.requestAPI,
                    requestItemKey = context and ItemKeyDebugString(context.requestItemKey),
                    source = context and context.source or "timeout",
                    sourceRowsBeforeFiltering = context and context.sourceRowsBeforeFiltering or 0,
                    zeroReason = context and context.zeroReason or "lookup timed out before result event",
                    itemKeyInfoAvailable = context and context.itemKeyInfoAvailable == true or false,
                    attempts = context and context.attempts or 0,
                    fallbackFromPath = context and context.fallbackFromPath,
                    fallbackReason = context and context.fallbackReason,
                })
            end
        end)
    end
end

RequestItemSearch = function(lookupKey, itemKey, row, candidate)
    if not C_AuctionHouse then
        return false
    end

    local context = pendingLookupContext[lookupKey] or {}
    pendingLookupContext[lookupKey] = context
    context.path = context.nameGather == true and "nameSearch"
        or context.path == "directItemID" and "directItemID"
        or "itemAuction"
    context.source = context.nameGather == true
        and "name browse -> C_AuctionHouse.GetItemSearchResultInfo"
        or context.path == "directItemID" and "direct itemID -> C_AuctionHouse.GetItemSearchResultInfo"
        or "C_AuctionHouse.GetItemSearchResultInfo"
    context.internalCandidateSource = context.nameGather == true and "itemAuction" or context.internalCandidateSource
    context.requestItemKey = itemKey
    context.itemKeyInfoAvailable = false
    context.attempts = (tonumber(context.attempts) or 0) + 1

    if C_AuctionHouse.GetItemKeyInfo then
        local okInfo, itemKeyInfo = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
        context.itemKeyInfoAvailable = okInfo and itemKeyInfo ~= nil
        if not context.itemKeyInfoAvailable then
            context.zeroReason = "item key info not cached; waiting before item-auction query"
            if C_Timer and C_Timer.After and context.attempts < 10 then
                C_Timer.After(0.25, function()
                    if callbacksByName[lookupKey] then
                        RequestItemSearch(lookupKey, itemKey, row, candidate)
                    end
                end)
                return true
            end
            return false
        end
    else
        context.itemKeyInfoAvailable = nil
    end

    local sorts = BuildSorts()
    local isEquipment = context.useSellSearch == true or IsEquipmentCandidate(row, candidate)
    context.useSellSearch = isEquipment
    local requestKey = ShallowCopyTable(itemKey)
    if isEquipment then
        requestKey.itemLevel = 0
    end
    context.requestItemKey = requestKey
    context.requestMade = true
    context.requestAPI = isEquipment and C_AuctionHouse.SendSellSearchQuery and "C_AuctionHouse.SendSellSearchQuery"
        or "C_AuctionHouse.SendSearchQuery"
    context.splitOwnedItems = true
    context.sorts = sorts

    local ok = false
    if isEquipment and C_AuctionHouse.SendSellSearchQuery then
        ok = pcall(C_AuctionHouse.SendSellSearchQuery, requestKey, sorts, true)
    elseif C_AuctionHouse.SendSearchQuery then
        ok = pcall(C_AuctionHouse.SendSearchQuery, requestKey, sorts, true)
    end
    if not ok and C_AuctionHouse.SendSearchQuery then
        context.requestAPI = "C_AuctionHouse.SendSearchQuery"
        ok = pcall(C_AuctionHouse.SendSearchQuery, requestKey, sorts, true)
    end
    if not ok then
        context.zeroReason = "item-auction search API call failed"
    end
    SessionLog("AuctionLookup: item request lookupKey=%s api=%s itemKey=%s itemKeyInfo=%s attempt=%d ok=%s",
        tostring(lookupKey), tostring(context.requestAPI), ItemKeyDebugString(requestKey), tostring(context.itemKeyInfoAvailable), context.attempts, tostring(ok))
    return ok and true or false
end

RequestCommodityNameDetailSearch = function(lookupKey, itemKey)
    if not C_AuctionHouse or not C_AuctionHouse.SendSearchQuery then
        return false
    end

    local itemID = tonumber(itemKey and itemKey.itemID)
    if not itemID then
        return false
    end

    local context = pendingLookupContext[lookupKey] or {}
    pendingLookupContext[lookupKey] = context
    context.path = "nameSearch"
    context.requestMade = true
    context.requestAPI = "C_AuctionHouse.SendSearchQuery"
    context.requestItemKey = itemKey
    context.source = "name browse -> C_AuctionHouse.GetCommoditySearchResultInfo"
    context.internalCandidateSource = "commodity"
    context.commodityDetailRequests = (tonumber(context.commodityDetailRequests) or 0) + 1
    context.zeroReason = "commodity detail search requested from name browse; waiting for commodity results"

    pendingNameByItemKey[tostring(itemID)] = lookupKey
    local ok = pcall(C_AuctionHouse.SendSearchQuery, itemKey, {}, false)
    if not ok then
        ok = pcall(C_AuctionHouse.SendSearchQuery, itemKey, {})
    end
    if not ok then
        context.zeroReason = "commodity detail search API call failed"
    end
    return ok and true or false
end

local function OnItemKeysReceived(itemKeyInfos)
    if type(itemKeyInfos) ~= "table" then
        return
    end

    for _, itemKeyInfo in ipairs(itemKeyInfos) do
        local itemName = itemKeyInfo and itemKeyInfo.itemName
        local itemKey = itemKeyInfo and itemKeyInfo.itemKey
        if itemName and callbacksByName[itemName] and itemKey then
            pendingNameByItemKey[itemKey] = itemName
            if itemKey.itemID then
                pendingNameByItemKey[tostring(itemKey.itemID)] = itemName
            end
            if not RequestItemSearch(itemName, itemKey) then
                SessionLog("AuctionLookup: item search unavailable itemName=%s itemID=%s",
                    tostring(itemName), tostring(itemKey.itemID))
                FinishNameLookup(itemName, {}, { path = "itemAuction", rawCount = 0 })
            end
        end
    end
end

local function OnItemSearchResultsUpdated(itemKey)
    local lookupKey = pendingNameByItemKey[itemKey] or pendingNameByItemKey[tostring(itemKey and itemKey.itemID)]
    if not lookupKey then
        return
    end

    ClearPendingItemLookup(lookupKey, itemKey)

    local context = pendingLookupContext[lookupKey] or {}
    context.completed = true
    context.resultItemKey = itemKey
    local rawRows, sourceRowCount, sourceErr = GetItemSearchRows(itemKey)
    context.sourceRowsBeforeFiltering = tonumber(sourceRowCount) or 0
    context.sourceError = sourceErr
    local auctions = NormalizeRows(rawRows, false)
    local rawCount = #auctions
    if rawCount == 0 then
        context.zeroReason = sourceErr
            and ("item search source read failed: " .. tostring(sourceErr))
            or "ITEM_SEARCH_RESULTS_UPDATED fired but GetNumItemSearchResults returned zero normalized rows"
        if C_AuctionHouse then
            if type(C_AuctionHouse.HasSearchResults) == "function" then
                local hasOk, has = pcall(C_AuctionHouse.HasSearchResults, itemKey)
                context.hasSearchResults = hasOk and has or nil
            end
            if type(C_AuctionHouse.HasFullItemSearchResults) == "function" then
                local fullOk, full = pcall(C_AuctionHouse.HasFullItemSearchResults, itemKey)
                context.hasFullItemSearchResults = fullOk and full or nil
            end
            if type(C_AuctionHouse.GetItemSearchResultsQuantity) == "function" then
                local qtyOk, qty = pcall(C_AuctionHouse.GetItemSearchResultsQuantity, itemKey)
                context.itemSearchResultsQuantity = qtyOk and qty or nil
            end
        end
        if (tonumber(context.attempts) or 0) < 3 then
            RegisterPendingItemLookup(lookupKey, context.requestItemKey or itemKey)
            RequestItemSearch(lookupKey, context.requestItemKey or itemKey)
            return
        end
    end

    if context.nameGather == true then
        context.auctions = context.auctions or {}
        context.itemAuctionRowsCollected = (tonumber(context.itemAuctionRowsCollected) or 0) + #(auctions or {})
        for _, auction in ipairs(auctions or {}) do
            if NormalizeName(auction.itemName) == NormalizeName(context.itemName) then
                context.auctions[#context.auctions + 1] = auction
            end
        end
        context.zeroReason = #context.auctions == 0 and "name browse found item keys but detail rows were empty or did not match normalized name" or nil
        QueueNextNameDetailSearch(lookupKey)
        return
    end

    SessionLog("AuctionLookup: item results key=%s itemID=%s rows=%d sourceRows=%d reason=%s",
        tostring(lookupKey), tostring(itemKey and itemKey.itemID), #auctions, tonumber(sourceRowCount) or 0, tostring(context.zeroReason))
    FinishNameLookup(lookupKey, auctions, {
        path = context.path or "itemAuction",
        rawCount = rawCount,
        completed = true,
        requestMade = context.requestMade == true,
        requestAPI = context.requestAPI,
        requestItemKey = ItemKeyDebugString(context.requestItemKey),
        resultItemKey = ItemKeyDebugString(itemKey),
        source = "C_AuctionHouse.GetItemSearchResultInfo",
        sourceRowsBeforeFiltering = tonumber(sourceRowCount) or 0,
        sourceError = sourceErr,
        zeroReason = rawCount == 0 and context.zeroReason or nil,
        itemKeyInfoAvailable = context.itemKeyInfoAvailable == true,
        attempts = context.attempts,
        hasSearchResults = context.hasSearchResults,
        hasFullItemSearchResults = context.hasFullItemSearchResults,
        itemSearchResultsQuantity = context.itemSearchResultsQuantity,
        internalCandidateSource = context.internalCandidateSource,
        fallbackFromPath = context.fallbackFromPath,
        fallbackReason = context.fallbackReason,
    })
end

local function IsCommodityItemKey(itemKey)
    if not itemKey or not C_AuctionHouse or type(C_AuctionHouse.GetItemCommodityStatus) ~= "function" then
        return false
    end
    local ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, itemKey)
    if ok and IsPositiveCommodityStatus(status) then
        return true
    end
    if itemKey.itemID then
        ok, status = pcall(C_AuctionHouse.GetItemCommodityStatus, itemKey.itemID)
        if ok and IsPositiveCommodityStatus(status) then
            return true
        end
    end
    return false
end

ProcessBrowseRowsForNameLookup = function(lookupKey, rows)
    local context = pendingLookupContext[lookupKey]
    if not context or context.nameGather ~= true or context.detailQueueStarted == true then
        return
    end

    context.sourceRowsBeforeFiltering = (tonumber(context.sourceRowsBeforeFiltering) or 0) + #(rows or {})
    context.detailQueue = context.detailQueue or {}
    context.detailKeySeen = context.detailKeySeen or {}
    local normalizedTargetName = NormalizeName(context.itemName)

    for _, row in ipairs(rows or {}) do
        local rowName = ExtractBrowseName(row)
        local itemKey = ExtractBrowseItemKey(row)
        if itemKey and NormalizeName(rowName) == normalizedTargetName then
            local token = ItemKeyToken(itemKey)
            if not context.detailKeySeen[token] then
                context.detailKeySeen[token] = true
                if IsCommodityItemKey(itemKey) then
                    -- For commodities, try to read cached results immediately rather than
                    -- queuing a detail search that may time out. The AH populates commodity
                    -- results when it opens, so they are often already in cache.
                    local commodityItemID = tonumber(itemKey and itemKey.itemID)
                    local cachedCount = 0
                    if commodityItemID and C_AuctionHouse and C_AuctionHouse.GetNumCommoditySearchResults then
                        local ok, count = pcall(C_AuctionHouse.GetNumCommoditySearchResults, commodityItemID)
                        cachedCount = ok and tonumber(count) or 0
                    end
                    if cachedCount > 0 then
                        -- Results already in cache - read them now and finish immediately
                        local commodityRows = GetCommodityRows(commodityItemID)
                        local auctions = NormalizeRows(commodityRows, true, commodityItemID)
                        context.auctions = context.auctions or {}
                        for _, auction in ipairs(auctions) do
                            context.auctions[#context.auctions + 1] = auction
                        end
                        context.commodityRowsCollected = (tonumber(context.commodityRowsCollected) or 0) + #auctions
                        context.detailKeySeen[token] = true
                    else
                        -- Not in cache yet - queue a detail search
                        context.detailQueue[#context.detailQueue + 1] = {
                            __detailSource = "commodity",
                            itemKey = itemKey,
                        }
                        context.commodityDetailKeysQueued = (tonumber(context.commodityDetailKeysQueued) or 0) + 1
                    end
                else
                    context.detailQueue[#context.detailQueue + 1] = itemKey
                    context.itemAuctionDetailKeysQueued = (tonumber(context.itemAuctionDetailKeysQueued) or 0) + 1
                end
                context.browseRowsMatchedByName = (tonumber(context.browseRowsMatchedByName) or 0) + 1
            end
        end
    end

    if #(context.auctions or {}) > 0 and #context.detailQueue == 0 then
        -- All matched items were commodities with cached results - finish immediately
        FinishNameLookup(lookupKey, context.auctions, {
            path = "nameSearch",
            rawCount = #context.auctions,
            completed = true,
            requestMade = context.requestMade == true,
            requestAPI = context.requestAPI,
            source = context.source,
            sourceRowsBeforeFiltering = tonumber(context.sourceRowsBeforeFiltering) or 0,
            browseRowsMatchedByName = tonumber(context.browseRowsMatchedByName) or 0,
            commodityRowsCollected = tonumber(context.commodityRowsCollected) or 0,
            fallbackFromPath = context.fallbackFromPath,
            fallbackReason = context.fallbackReason,
        })
    elseif #context.detailQueue > 0 then
        context.detailQueueStarted = true
        context.zeroReason = "browse matched names; waiting for item detail search results"
        QueueNextNameDetailSearch(lookupKey)
    elseif C_AuctionHouse and type(C_AuctionHouse.HasFullBrowseResults) == "function" then
        local okFull, full = pcall(C_AuctionHouse.HasFullBrowseResults)
        if okFull and full then
            FinishNameLookup(lookupKey, {}, {
                path = "itemAuction",
                rawCount = 0,
                completed = true,
                requestMade = context.requestMade == true,
                requestAPI = context.requestAPI,
                requestQuery = context.requestQuery,
                source = context.source,
                sourceRowsBeforeFiltering = tonumber(context.sourceRowsBeforeFiltering) or 0,
                browseRowsMatchedByName = tonumber(context.browseRowsMatchedByName) or 0,
                zeroReason = "browse search returned no rows with matching normalized item name",
                fallbackFromPath = context.fallbackFromPath,
                fallbackReason = context.fallbackReason,
            })
        end
    elseif C_AuctionHouse and type(C_AuctionHouse.RequestMoreBrowseResults) == "function" then
        context.moreBrowseRequests = (tonumber(context.moreBrowseRequests) or 0) + 1
        context.zeroReason = "browse search has not returned a matching normalized item name yet"
        if context.moreBrowseRequests <= 3 then
            pcall(C_AuctionHouse.RequestMoreBrowseResults)
        end
    end
end

local function OnBrowseResultsUpdated(...)
    local rows = nil
    if select("#", ...) > 0 and type((...)) == "table" then
        rows = ...
    elseif C_AuctionHouse and type(C_AuctionHouse.GetBrowseResults) == "function" then
        local ok, resultRows = pcall(C_AuctionHouse.GetBrowseResults)
        if ok then
            rows = resultRows
        end
    end

    for _, lookupKey in ipairs(SnapshotPendingBrowseLookupKeys()) do
        if pendingBrowseLookups[lookupKey] then
            ProcessBrowseRowsForNameLookup(lookupKey, rows or {})
        end
    end
end

local function OnCommoditySearchResultsUpdated(itemID)
    local itemName = pendingNameByItemKey[tostring(itemID)]
    if not itemName then
        return
    end

    pendingNameByItemKey[tostring(itemID)] = nil
    local auctions = NormalizeRows(GetCommodityRows(itemID), true, tonumber(itemID))
    SessionLog("AuctionLookup: commodity results key=%s itemID=%s rows=%d",
        tostring(itemName), tostring(itemID), #auctions)
    local context = pendingLookupContext[itemName] or {}
    if context.nameGather == true then
        context.auctions = context.auctions or {}
        for _, auction in ipairs(auctions or {}) do
            if NormalizeName(auction.itemName) == NormalizeName(context.itemName) then
                context.auctions[#context.auctions + 1] = auction
            end
        end
        context.commodityRowsCollected = (tonumber(context.commodityRowsCollected) or 0) + #auctions
        context.zeroReason = #context.auctions == 0 and "name browse found commodity key but commodity rows were empty or did not match normalized name" or nil
        QueueNextNameDetailSearch(itemName)
        return
    end

    FinishNameLookup(itemName, auctions, {
        path = context.path or "nameSearch",
        postAPI = context.postAPI,
        classificationSource = context.classificationSource,
        internalCandidateSource = context.internalCandidateSource or "commodity",
        rawCount = #auctions,
        completed = true,
        requestMade = context.requestMade == true,
        requestAPI = context.requestAPI,
        requestItemKey = ItemKeyDebugString(context.requestItemKey),
        source = context.source or "C_AuctionHouse.GetCommoditySearchResultInfo",
        sourceRowsBeforeFiltering = #auctions,
        zeroReason = #auctions == 0 and "commodity search returned zero rows" or nil,
    })
end

if frame then
    frame:RegisterEvent("AUCTION_HOUSE_NEW_RESULTS_RECEIVED")
    frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    frame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    frame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")
    frame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
    frame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "AUCTION_HOUSE_NEW_RESULTS_RECEIVED" then
            OnItemKeysReceived(...)
        elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
            OnBrowseResultsUpdated(...)
        elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
            for _, lookupKey in ipairs(SnapshotPendingBrowseLookupKeys()) do
                if pendingBrowseLookups[lookupKey] then
                    local context = pendingLookupContext[lookupKey]
                    FinishNameLookup(lookupKey, {}, {
                        path = "nameSearch",
                        rawCount = 0,
                        completed = true,
                        requestMade = context and context.requestMade == true,
                        requestAPI = context and context.requestAPI,
                        requestQuery = context and context.requestQuery,
                        source = context and context.source,
                        sourceRowsBeforeFiltering = context and context.sourceRowsBeforeFiltering or 0,
                        zeroReason = "browse query failed",
                        fallbackFromPath = context and context.fallbackFromPath,
                        fallbackReason = context and context.fallbackReason,
                    })
                end
            end
        elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
            OnItemSearchResultsUpdated(...)
        elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
            OnCommoditySearchResultsUpdated(...)
        end
    end)
end

function AuctionLookupService:GetAuctionByID(auctionID, callback)
    if auctionID == nil or callback == nil then
        SafeCall(callback, nil)
        return
    end

    local auction = SearchCurrentResultsForAuction(auctionID)
    if auction then
        SafeCall(callback, auction)
        return
    end

    callbacksByID[tostring(auctionID)] = callbacksByID[tostring(auctionID)] or {}
    callbacksByID[tostring(auctionID)][#callbacksByID[tostring(auctionID)] + 1] = callback
    FinishIDLookup(auctionID, nil)
end

function AuctionLookupService:GetAuctionsByName(itemName, callback)
    if type(itemName) ~= "string" or itemName == "" or callback == nil then
        SafeCall(callback, {})
        return
    end

    callbacksByName[itemName] = callbacksByName[itemName] or {}
    callbacksByName[itemName][#callbacksByName[itemName] + 1] = callback

    if not RequestNameSearch(itemName) then
        FinishNameLookup(itemName, {}, { path = "itemAuction", rawCount = 0 })
    else
        ScheduleNameLookupTimeout(itemName)
    end
end

StartBrowseNameLookup = function(row, candidate, itemID, itemName, normalizedName, callback, fallbackReason)
    if normalizedName ~= "" then
        local lookupKey = "name:" .. normalizedName
        callbacksByName[lookupKey] = callbacksByName[lookupKey] or {}
        callbacksByName[lookupKey][#callbacksByName[lookupKey] + 1] = callback
        pendingLookupContext[lookupKey] = {
            path = "nameSearch",
            itemID = itemID,
            itemName = itemName,
            normalizedName = normalizedName,
            row = row,
            candidate = candidate,
            source = "C_AuctionHouse.GetBrowseResults -> detail result source by item key",
            zeroReason = "name browse query not completed yet",
            attempts = 0,
            nameGather = true,
            auctions = {},
            fallbackFromPath = fallbackReason and "directItemID" or nil,
            fallbackReason = fallbackReason,
        }
        pendingBrowseLookups[lookupKey] = true
        SessionLog("AuctionLookup: browse fallback itemID=%s itemName=%s normalized=%s reason=%s",
            tostring(itemID), tostring(itemName), tostring(normalizedName), tostring(fallbackReason or "primary browse path"))
        if not RequestBrowseNameSearch(lookupKey) then
            FinishNameLookup(lookupKey, {}, {
                path = "nameSearch",
                rawCount = 0,
                completed = true,
                requestMade = false,
                requestAPI = "C_AuctionHouse.SendBrowseQuery",
                source = "C_AuctionHouse.GetBrowseResults",
                sourceRowsBeforeFiltering = 0,
                zeroReason = "item-auction name browse could not be requested",
                fallbackFromPath = fallbackReason and "directItemID" or nil,
                fallbackReason = fallbackReason,
            })
        else
            ScheduleNameLookupTimeout(lookupKey)
        end
        return true
    end

    SessionLog("AuctionLookup: requesting item-name search itemName=%s itemID=%s reason=%s",
        tostring(row.itemName or candidate and candidate.itemName), tostring(itemID), tostring(fallbackReason))
    AuctionLookupService:GetAuctionsByName(row.itemName or candidate and candidate.itemName, callback)
    return true
end

function AuctionLookupService:GetAuctionsForRow(row, callback)
    if type(row) ~= "table" or callback == nil then
        SafeCall(callback, {})
        return
    end

    local candidate = row.candidate or row
    local itemID = tonumber(candidate and (candidate.itemID or candidate.targetItemID))
        or tonumber(row.target and (row.target.targetItemID or row.target.debugItemID))
    local itemName = row.itemName or candidate and candidate.itemName
    local normalizedName = NormalizeName(itemName)

    -- Commodity fast path: query SendSearchQuery directly rather than browse,
    -- because browse rows for commodities often lack a usable name from GetItemKeyInfo
    -- synchronously, causing the name match in ProcessBrowseRowsForNameLookup to fail.
    local isCommodity = (candidate and candidate.isCommodity == true)
        or (row.target and row.target.postAPI == "PostCommodity")
    if isCommodity then
        local commodityItemID = tonumber(candidate and candidate.itemID)
            or tonumber(row.target and row.target.debugItemID)
        if commodityItemID and normalizedName ~= "" then
            local lookupKey = "name:" .. normalizedName
            callbacksByName[lookupKey] = callbacksByName[lookupKey] or {}
            callbacksByName[lookupKey][#callbacksByName[lookupKey] + 1] = callback
            pendingLookupContext[lookupKey] = {
                path = "commodity",
                itemID = commodityItemID,
                itemName = itemName,
                normalizedName = normalizedName,
                nameGather = false,
                requestMade = true,
                requestAPI = "C_AuctionHouse.SendSearchQuery",
            }
            pendingNameByItemKey[tostring(commodityItemID)] = lookupKey
            SessionLog("AuctionLookup: path=commodity itemID=%s itemName=%s normalized=%s",
                tostring(commodityItemID), tostring(itemName), tostring(normalizedName))
            -- Use a plain item key with no itemLevel. MakeItemKey returns itemLevel set to the
            -- item's base ilvl which may cause the wrong event to fire. The manual key with
            -- itemLevel=nil is confirmed to trigger COMMODITY_SEARCH_RESULTS_UPDATED correctly.
            local itemKey = { itemID = commodityItemID, battlePetSpeciesID = 0, itemSuffix = 0 }
            local ok = pcall(C_AuctionHouse.SendSearchQuery, itemKey, {}, false)
            if not ok then
                ok = pcall(C_AuctionHouse.SendSearchQuery, itemKey, {})
            end
            if not ok then
                pendingNameByItemKey[tostring(commodityItemID)] = nil
                FinishNameLookup(lookupKey, {}, {
                    path = "commodity",
                    rawCount = 0,
                    completed = false,
                    requestMade = true,
                    requestAPI = "C_AuctionHouse.SendSearchQuery",
                    zeroReason = "commodity SendSearchQuery failed",
                })
                return
            end
            ScheduleNameLookupTimeout(lookupKey)
            return
        end
    end

    if itemID then
        local directItemKey = BuildDirectItemKey(row, candidate, itemID)
        if directItemKey then
            local lookupKey = "direct:" .. tostring(itemID)
            callbacksByName[lookupKey] = callbacksByName[lookupKey] or {}
            callbacksByName[lookupKey][#callbacksByName[lookupKey] + 1] = function(auctions, meta)
                local fallbackReason = DirectLookupFallbackReason(meta)
                if fallbackReason and type(meta) == "table" and meta.requestMade == true and meta.completed ~= true then
                    -- The direct search was sent but the AH never answered before the timeout.
                    -- The browse fallback re-sends an equivalent search for the same item key,
                    -- so it would only wait out its own 15s timeout. Finish here instead.
                    SessionLog("AuctionLookup: path=direct timed out; browse fallback skipped itemID=%s itemName=%s reason=%s",
                        tostring(itemID), tostring(itemName), tostring(fallbackReason))
                    SafeCall(callback, auctions or {}, meta)
                    return
                end
                if fallbackReason then
                    SessionLog("AuctionLookup: path=browse fallback itemID=%s itemName=%s reason=%s",
                        tostring(itemID), tostring(itemName), tostring(fallbackReason))
                    StartBrowseNameLookup(row, candidate, itemID, itemName, normalizedName, callback, fallbackReason)
                    return
                end
                SessionLog("AuctionLookup: path=direct itemID=%s rows=%d completed=%s",
                    tostring(itemID), #(auctions or {}), tostring(meta and meta.completed))
                SafeCall(callback, auctions or {}, meta)
            end
            pendingLookupContext[lookupKey] = {
                path = "directItemID",
                itemID = itemID,
                itemName = itemName,
                normalizedName = normalizedName,
                row = row,
                candidate = candidate,
                source = "C_AuctionHouse.GetItemSearchResultInfo",
                zeroReason = "direct itemID lookup not completed yet",
                attempts = 0,
                nameGather = false,
                internalCandidateSource = "directItemID",
            }
            RegisterPendingItemLookup(lookupKey, directItemKey)
            SessionLog("AuctionLookup: path=direct itemID request itemID=%s itemName=%s key=%s",
                tostring(itemID), tostring(itemName), ItemKeyDebugString(directItemKey))
            if not RequestItemSearch(lookupKey, directItemKey, row, candidate) then
                ClearPendingItemLookup(lookupKey, directItemKey)
                callbacksByName[lookupKey] = nil
                pendingLookupContext[lookupKey] = nil
                StartBrowseNameLookup(row, candidate, itemID, itemName, normalizedName, callback, "direct itemID lookup could not be requested")
            else
                ScheduleNameLookupTimeout(lookupKey)
            end
            return
        end
    end

    StartBrowseNameLookup(row, candidate, itemID, itemName, normalizedName, callback, "itemID missing")
end

if PocketCFO_AH then
    PocketCFO_AH.AuctionLookupService = AuctionLookupService
end

_G.AuctionLookupService = AuctionLookupService
