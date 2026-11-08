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

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

-- Blizzard's own bind flags for the slot, no tooltip text involved
-- (2026-11-07: Potent Healing Potion, Latent Arcana (Warband) and Dark
-- Particle (BoP) got past the tooltip check). Returns bound, and the two
-- raw answers for the session log. Theoretical: whether either flag is
-- true for Warband-bound items, not only soulbound ones.
local function BagSlotBindFlags(containerID, slot, info, location)
    local infoBound = info and info.isBound == true or false
    local itemIsBound = nil
    if location and C_Item and type(C_Item.IsBound) == "function" then
        local ok, bound = pcall(C_Item.IsBound, location)
        if ok then
            itemIsBound = bound == true
        end
    end
    return infoBound or itemIsBound == true, infoBound, itemIsBound
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

-- Returns postable, and when false a reason: "noItem" | "noSlot" | "bound"
-- | "ahRefused" (C_AuctionHouse.IsSellItemValid said no). The reason is for
-- diagnostics only (Brian, 2026-11-06: smart list sometimes drops every
-- finished good; the session log now says which check refused them).
function PostingEligibilityService:IsBagSlotAHPostable(containerID, slot, itemID)
    if not itemID then
        return false, "noItem"
    end
    if not containerID or not slot then
        return false, "noSlot"
    end
    local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(containerID, slot) or nil
    local location = ItemLocation and ItemLocation.CreateFromBagAndSlot
        and ItemLocation:CreateFromBagAndSlot(containerID, slot) or nil

    local flagBound, infoBound, itemIsBound = BagSlotBindFlags(containerID, slot, info, location)
    if flagBound then
        return false, "bound"
    end
    if BagSlotHasBoundTooltip(containerID, slot) then
        return false, "bound"
    end

    if location and C_AuctionHouse and type(C_AuctionHouse.IsSellItemValid) == "function" then
        local ok, valid = pcall(C_AuctionHouse.IsSellItemValid, location, false)
        if ok then
            if valid == true then
                return true
            end

            -- Stackable override: the AH said no, but no bind check fired.
            -- Kept for commodities IsSellItemValid has refused before.
            if IsLikelyCommodityItem(info and info.hyperlink, itemID, info) then
                -- Diagnostics only (2026-11-07): every item that gets in only
                -- through this override, with what each check said, so a
                -- bound item that still leaks shows which check missed it.
                SessionLog("PostingEligibility: stackable override item=%s itemID=%s bag=%s slot=%s tooltipBound=false infoIsBound=%s C_Item.IsBound=%s IsSellItemValid=%s",
                    tostring(info and (info.itemName or info.hyperlink) or itemID), tostring(itemID),
                    tostring(containerID), tostring(slot),
                    tostring(infoBound), tostring(itemIsBound), tostring(valid))
                return true
            end
            return false, "ahRefused"
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
