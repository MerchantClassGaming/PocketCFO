-- PocketCFO/Services/ItemIdentityService/ItemEvidenceExtractor.lua
-- Shared item metadata extraction for identity diagnostics and resolution.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local GetDetailedItemLevelInfo = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo

local PocketCFO = _G.PocketCFO

local ItemEvidenceExtractor = {}

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

local function PositiveNumber(value)
    local number = tonumber(value)
    if number and number > 0 then
        return number
    end
    return nil
end

local function NonEmpty(value)
    if value == nil or tostring(value) == "" then
        return nil
    end
    return value
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return false, nil
    end
    return pcall(fn, ...)
end

local function ResolveItemIDFromLink(itemLink)
    if not itemLink then
        return nil
    end
    if C_Item and type(C_Item.GetItemInfoInstant) == "function" then
        local ok, itemID = SafeCall(C_Item.GetItemInfoInstant, itemLink)
        itemID = ok and NumberOrNil(itemID) or nil
        if itemID then
            return itemID
        end
    end
    if GetItemInfoInstant then
        local ok, itemID = SafeCall(GetItemInfoInstant, itemLink)
        itemID = ok and NumberOrNil(itemID) or nil
        if itemID then
            return itemID
        end
    end
    if GetItemInfoFromHyperlink then
        local ok, itemID = SafeCall(GetItemInfoFromHyperlink, itemLink)
        itemID = ok and NumberOrNil(itemID) or nil
        if itemID then
            return itemID
        end
    end
    return NumberOrNil(tostring(itemLink):match("item:(%d+)"))
end

local function CreateBagItemLocation(bag, slot)
    if not bag or not slot or not ItemLocation or type(ItemLocation.CreateFromBagAndSlot) ~= "function" then
        return nil
    end
    local ok, location = SafeCall(ItemLocation.CreateFromBagAndSlot, ItemLocation, bag, slot)
    if ok then
        return location
    end
    return nil
end

local function GetCraftingQuality(itemLink, itemID)
    if not C_TradeSkillUI then
        return nil
    end

    local refs = {
        { ref = itemLink },
        { ref = itemID },
    }
    local apis = {
        "GetItemCraftedQualityByItemInfo",
        "GetItemReagentQualityByItemInfo",
    }
    for _, itemRef in ipairs(refs) do
        if itemRef.ref ~= nil then
            for _, apiName in ipairs(apis) do
                local api = C_TradeSkillUI[apiName]
                if type(api) == "function" then
                    local ok, quality = SafeCall(api, itemRef.ref)
                    quality = ok and PositiveNumber(quality) or nil
                    if quality then
                        return quality
                    end
                end
            end
        end
    end
    return nil
end

function ItemEvidenceExtractor:Extract(input)
    input = type(input) == "table" and input or { itemID = input }

    local bag = NumberOrNil(input.bag or input.containerID)
    local slot = NumberOrNil(input.slot)
    local itemLocation = input.itemLocation or CreateBagItemLocation(bag, slot)
    local itemLink = NonEmpty(input.itemLink or input.link or input.hyperlink or input.itemString)
    local itemID = NumberOrNil(input.itemID or input.itemId or input.id)

    if not itemLink and C_Container and C_Container.GetContainerItemLink and bag and slot then
        local ok, link = SafeCall(C_Container.GetContainerItemLink, bag, slot)
        itemLink = ok and NonEmpty(link) or itemLink
    end
    if not itemLink and itemLocation and C_Item and type(C_Item.GetItemLink) == "function" then
        local ok, link = SafeCall(C_Item.GetItemLink, itemLocation)
        itemLink = ok and NonEmpty(link) or itemLink
    end
    if not itemID and itemLink then
        itemID = ResolveItemIDFromLink(itemLink)
    end

    local itemName, resolvedLink, rarityQuality, itemLevel, maxStack, equipLoc, itemClassID, itemSubClassID
    local itemRef = itemLink or itemID
    if itemRef and GetItemInfo then
        local ok
        ok, itemName, resolvedLink, rarityQuality, itemLevel, _, _, _, maxStack, equipLoc, _, _, itemClassID, itemSubClassID = SafeCall(GetItemInfo, itemRef)
        if not ok then
            itemName, resolvedLink, rarityQuality, itemLevel, maxStack, equipLoc, itemClassID, itemSubClassID = nil
        end
    end
    if itemRef and not itemName and C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok
        ok, itemName, resolvedLink, rarityQuality, itemLevel, _, _, _, maxStack, equipLoc, _, _, itemClassID, itemSubClassID = SafeCall(C_Item.GetItemInfo, itemRef)
        if not ok then
            itemName, resolvedLink, rarityQuality, itemLevel, maxStack, equipLoc, itemClassID, itemSubClassID = nil
        end
    end

    local instantID, instantEquipLoc, instantClassID, instantSubClassID
    if itemRef and GetItemInfoInstant then
        local ok
        ok, instantID, _, _, instantEquipLoc, _, instantClassID, instantSubClassID = SafeCall(GetItemInfoInstant, itemRef)
        if not ok then
            instantID, instantEquipLoc, instantClassID, instantSubClassID = nil
        end
    end
    if itemRef and C_Item and type(C_Item.GetItemInfoInstant) == "function" and (not instantID or not instantClassID) then
        local ok
        ok, instantID, _, _, instantEquipLoc, _, instantClassID, instantSubClassID = SafeCall(C_Item.GetItemInfoInstant, itemRef)
        if not ok then
            instantID, instantEquipLoc, instantClassID, instantSubClassID = nil
        end
    end

    if not itemID then
        itemID = NumberOrNil(instantID)
    end
    itemLink = itemLink or NonEmpty(resolvedLink)

    local detailedIlvl
    if itemRef and C_Item and type(C_Item.GetDetailedItemLevelInfo) == "function" then
        local ok, value = SafeCall(C_Item.GetDetailedItemLevelInfo, itemRef)
        detailedIlvl = ok and PositiveNumber(value) or nil
    end
    if not detailedIlvl and itemRef and GetDetailedItemLevelInfo then
        local ok, value = SafeCall(GetDetailedItemLevelInfo, itemRef)
        detailedIlvl = ok and PositiveNumber(value) or nil
    end

    local finalMaxStack = NumberOrNil(maxStack)
    local isStackable = nil
    if finalMaxStack then
        isStackable = finalMaxStack > 1
    end
    local craftingQuality = GetCraftingQuality(itemLink, itemID)

    return {
        itemID = itemID,
        itemLink = itemLink,
        itemName = NonEmpty(itemName),
        quality = NumberOrNil(rarityQuality),
        rarityQuality = NumberOrNil(rarityQuality),
        effectiveIlvl = detailedIlvl or NumberOrNil(itemLevel),
        effectiveItemLevel = detailedIlvl or NumberOrNil(itemLevel),
        itemClassID = NumberOrNil(itemClassID or instantClassID),
        classID = NumberOrNil(itemClassID or instantClassID),
        itemSubClassID = NumberOrNil(itemSubClassID or instantSubClassID),
        subClassID = NumberOrNil(itemSubClassID or instantSubClassID),
        equipLoc = NonEmpty(equipLoc or instantEquipLoc),
        inventoryType = NonEmpty(instantEquipLoc or equipLoc),
        craftingQuality = craftingQuality,
        itemQuality = craftingQuality,
        maxStack = finalMaxStack,
        isStackable = isStackable,
        itemLocation = itemLocation,
    }
end

if PocketCFO then
    PocketCFO.ItemEvidenceExtractor = ItemEvidenceExtractor
end

_G.PocketCFO_ItemEvidenceExtractor = ItemEvidenceExtractor
