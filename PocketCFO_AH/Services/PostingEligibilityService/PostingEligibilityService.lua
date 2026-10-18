-- PocketCFO_AH/Services/PostingEligibilityService/PostingEligibilityService.lua
-- Shared AH posting eligibility checks for bag slot items.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingEligibilityService = PocketCFO_AH:NewModule("PostingEligibilityService")

local function GetSoulboundClassifier()
    return PocketCFO and PocketCFO.SoulboundClassifier or _G.PocketCFO_SoulboundClassifier
end

local function BagSlotHasBoundTooltip(containerID, slot)
    local classifier = GetSoulboundClassifier()
    if classifier and classifier.BagSlotHasBoundTooltip then
        return classifier:BagSlotHasBoundTooltip(containerID, slot)
    end
    return false
end

local function IsLikelyCommodityItem(itemLink, itemID, itemInfo)
    local maxStack = itemInfo and tonumber(itemInfo.stackCount)
    local isCraftingReagent = nil
    if GetItemInfo and (itemLink or itemID) then
        local _, _, _, _, _, _, _, itemStackCount, _, _, _, _, _, _, _, _, reagentFlag = GetItemInfo(itemLink or itemID)
        maxStack = tonumber(itemStackCount) or maxStack
        isCraftingReagent = reagentFlag
    end
    return isCraftingReagent == true or (tonumber(maxStack) or 1) > 1
end

function PostingEligibilityService:IsBagSlotAHPostable(containerID, slot, itemID)
    if not itemID then
        return false
    end
    if not containerID or not slot then
        return false
    end
    if BagSlotHasBoundTooltip(containerID, slot) then
        return false
    end

    if ItemLocation and ItemLocation.CreateFromBagAndSlot
    and C_AuctionHouse and type(C_AuctionHouse.IsSellItemValid) == "function" then
        local location = ItemLocation:CreateFromBagAndSlot(containerID, slot)
        local ok, valid = pcall(C_AuctionHouse.IsSellItemValid, location, false)
        if ok then
            if valid == true then
                return true
            end

            local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(containerID, slot) or nil
            if IsLikelyCommodityItem(info and info.hyperlink, itemID, info) then
                return true
            end
            return false
        end
    end

    return true
end

function PostingEligibilityService:IsBagSlotQueueEligible(containerID, slot, itemID)
    if not itemID then
        return false
    end
    if not containerID or not slot then
        return false
    end
    if BagSlotHasBoundTooltip(containerID, slot) then
        return false
    end
    return true
end
