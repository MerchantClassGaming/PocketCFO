-- PocketCFO/Services/ItemIdentityService/SoulboundClassifier.lua
-- Tooltip-based bind-state and soulbound finished-good classification.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local PocketCFO = _G.PocketCFO

local SoulboundClassifier = {}

local function NormalizeTooltipText(value)
    return string.lower(tostring(value or "")):gsub("^%s+", ""):gsub("%s+$", "")
end

local SOULBOUND_TOOLTIP_TEXT = NormalizeTooltipText(_G.ITEM_SOULBOUND or "Soulbound")
local BIND_ON_PICKUP_TOOLTIP_TEXT = NormalizeTooltipText(_G.ITEM_BIND_ON_PICKUP or "Binds when picked up")

local function GetItemClassConstants()
    local itemClass = _G.Enum and _G.Enum.ItemClass or nil
    return {
        weapon = (itemClass and itemClass.Weapon) or _G.LE_ITEM_CLASS_WEAPON or 2,
        armor = (itemClass and itemClass.Armor) or _G.LE_ITEM_CLASS_ARMOR or 4,
        profession = (itemClass and itemClass.Profession) or 19,
    }
end

local function GetTooltipLinesFromTooltipInfo(bag, slot)
    if not _G.C_TooltipInfo then
        return nil
    end

    local tooltipData = nil
    if bag ~= nil and slot ~= nil and C_TooltipInfo.GetBagItem then
        local ok, data = pcall(C_TooltipInfo.GetBagItem, bag, slot)
        if ok then
            tooltipData = data
        end
    end

    if not tooltipData or type(tooltipData.lines) ~= "table" then
        return nil
    end

    local lines = {}
    for _, line in ipairs(tooltipData.lines) do
        local text = line and (line.leftText or line.rightText)
        if text and text ~= "" then
            lines[#lines + 1] = text
        end
    end
    return lines
end

local function GetSoulboundScanTooltip()
    if SoulboundClassifier.soulboundScanTooltip then
        return SoulboundClassifier.soulboundScanTooltip
    end

    if not _G.CreateFrame or not _G.UIParent then
        return nil
    end

    local tooltip = CreateFrame("GameTooltip", "PocketCFOSoulboundScanTooltip", UIParent, "GameTooltipTemplate")
    tooltip:SetOwner(UIParent, "ANCHOR_NONE")
    SoulboundClassifier.soulboundScanTooltip = tooltip
    return tooltip
end

local function GetTooltipLinesFromHiddenTooltip(bag, slot)
    local tooltip = GetSoulboundScanTooltip()
    if not tooltip then
        return nil
    end

    tooltip:ClearLines()
    local ok = false
    if bag ~= nil and slot ~= nil and tooltip.SetBagItem then
        ok = pcall(tooltip.SetBagItem, tooltip, bag, slot)
    end

    if not ok then
        tooltip:ClearLines()
        return nil
    end

    local lines = {}
    local tooltipName = tooltip:GetName()
    for i = 1, tooltip:NumLines() do
        local left = _G[tooltipName .. "TextLeft" .. i]
        local right = _G[tooltipName .. "TextRight" .. i]
        local leftText = left and left.GetText and left:GetText()
        local rightText = right and right.GetText and right:GetText()
        if leftText and leftText ~= "" then
            lines[#lines + 1] = leftText
        end
        if rightText and rightText ~= "" then
            lines[#lines + 1] = rightText
        end
    end
    tooltip:ClearLines()
    return lines
end

function SoulboundClassifier:GetTooltipLinesForBagSlot(bag, slot)
    return GetTooltipLinesFromTooltipInfo(bag, slot) or GetTooltipLinesFromHiddenTooltip(bag, slot) or {}
end

function SoulboundClassifier:TooltipTextIsBound(text)
    text = NormalizeTooltipText(text)
    if text == "" then
        return false
    end

    return text == SOULBOUND_TOOLTIP_TEXT
        or text == BIND_ON_PICKUP_TOOLTIP_TEXT
        or text:find("binds when picked up", 1, true) ~= nil
        or text:find("bind on pickup", 1, true) ~= nil
        or text:find("warbound", 1, true) ~= nil
        or text:find("warband", 1, true) ~= nil
end

function SoulboundClassifier:BagSlotHasBoundTooltip(bag, slot)
    if bag == nil or slot == nil then
        return false
    end

    for _, text in ipairs(self:GetTooltipLinesForBagSlot(bag, slot)) do
        if self:TooltipTextIsBound(text) then
            return true
        end
    end
    return false
end

function SoulboundClassifier:BagSlotHasSoulboundTooltip(bag, slot)
    if bag == nil or slot == nil then
        return false
    end

    for _, text in ipairs(self:GetTooltipLinesForBagSlot(bag, slot)) do
        if NormalizeTooltipText(text) == SOULBOUND_TOOLTIP_TEXT then
            return true
        end
    end
    return false
end

local function NormalizeLower(value)
    if not value then
        return ""
    end
    return string.lower(tostring(value))
end

local function IsProfessionEquipLoc(equipLoc)
    return equipLoc == "INVTYPE_PROFESSION_TOOL"
        or equipLoc == "INVTYPE_PROFESSION_GEAR"
end

function SoulboundClassifier:IsFinishedGoodClass(itemLink, itemID, itemInfo)
    local itemName, _, _, _, _, itemType, itemSubType, maxStack, itemEquipLoc, _, _, classID, subclassID, _, _, _, isCraftingReagent

    if type(itemInfo) == "table" then
        itemName = itemInfo.itemName or itemInfo.name
        itemType = itemInfo.itemType or itemInfo.type
        itemSubType = itemInfo.itemSubType or itemInfo.subType
        maxStack = itemInfo.maxStack or itemInfo.itemStackCount
        itemEquipLoc = itemInfo.itemEquipLoc or itemInfo.equipLoc
        classID = itemInfo.classID or itemInfo.itemClassID
        subclassID = itemInfo.subclassID or itemInfo.itemSubClassID
        isCraftingReagent = itemInfo.isCraftingReagent
    end

    if _G.GetItemInfo and (itemLink or itemID) then
        local infoName, _, _, _, _, infoType, infoSubType, infoMaxStack, infoEquipLoc, _, _, infoClassID, infoSubclassID, _, _, _, infoIsCraftingReagent =
            GetItemInfo(itemLink or itemID)
        itemName = infoName or itemName
        itemType = infoType or itemType
        itemSubType = infoSubType or itemSubType
        maxStack = infoMaxStack or maxStack
        itemEquipLoc = infoEquipLoc or itemEquipLoc
        classID = infoClassID or classID
        subclassID = infoSubclassID or subclassID
        if infoIsCraftingReagent ~= nil then
            isCraftingReagent = infoIsCraftingReagent
        end
    end

    classID = tonumber(classID)
    subclassID = tonumber(subclassID)
    maxStack = tonumber(maxStack) or 1

    if isCraftingReagent == true then
        return false
    end

    if IsProfessionEquipLoc(itemEquipLoc) then
        return true
    end

    local class = GetItemClassConstants()
    if classID == class.weapon then
        return true
    end

    if classID == class.armor then
        return itemEquipLoc ~= nil and itemEquipLoc ~= "" and maxStack <= 1
    end

    if classID == class.profession then
        local subTypeText = NormalizeLower(itemSubType)
        if IsProfessionEquipLoc(itemEquipLoc)
        or subTypeText:find("tool", 1, true)
        or subTypeText:find("accessor", 1, true)
        or subTypeText:find("equipment", 1, true) then
            return true
        end
    end

    return false
end

function SoulboundClassifier:IsSoulboundFinishedGood(itemLink, bag, slot, itemLocation, itemInfo)
    local itemID = itemInfo and itemInfo.itemID or nil
    if not itemID and itemLink then
        if _G.GetItemInfoFromHyperlink then
            local ok, parsedID = pcall(GetItemInfoFromHyperlink, itemLink)
            if ok then
                itemID = tonumber(parsedID)
            end
        end
        itemID = itemID or tonumber(tostring(itemLink):match("item:(%d+)"))
    end

    if not self:IsFinishedGoodClass(itemLink, itemID, itemInfo) then
        return false
    end

    return self:BagSlotHasSoulboundTooltip(bag, slot)
end

if PocketCFO then
    PocketCFO.SoulboundClassifier = SoulboundClassifier
end

_G.PocketCFO_SoulboundClassifier = SoulboundClassifier
