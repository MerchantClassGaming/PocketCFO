-- PocketCFO_Orders/BagOpens.lua
-- Artisan's Consortium bag open tracking.
-- Consortium bag IDs 227713/246585 belong here (not in PocketCFO_Crafting).

local ADDON_NAME, _ = ...
local PocketCFO_Orders = _G.PocketCFO_Orders

local BagOpens = PocketCFO_Orders:NewModule("BagOpens", "AceEvent-3.0")

-- Artisan's Consortium payout bags.
local CONSORTIUM_BAG_IDS = {
    [227713] = "Artisan's Consortium Payout (TWW)",      -- THEORETICAL: item ID unverified
    [246585] = "Artisan's Consortium Payout (Midnight)", -- THEORETICAL: item ID unverified
}

local function ScanTrackedBagsInContainers()
    local found = {}
    local containers = { BACKPACK_CONTAINER }
    for i = 1, NUM_BAG_SLOTS do
        containers[#containers + 1] = i
    end
    containers[#containers + 1] = 5

    for _, containerID in ipairs(containers) do
        local numSlots = C_Container.GetContainerNumSlots(containerID)
        for slot = 1, (numSlots or 0) do
            local info = C_Container.GetContainerItemInfo(containerID, slot)
            if info and info.itemID and CONSORTIUM_BAG_IDS[info.itemID] then
                found[info.itemID] = (found[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end

    return found
end

local function ScanAllBagContents()
    local qtyMap = {}
    local containers = { BACKPACK_CONTAINER }
    for i = 1, NUM_BAG_SLOTS do
        containers[#containers + 1] = i
    end
    containers[#containers + 1] = 5

    for _, containerID in ipairs(containers) do
        local numSlots = C_Container.GetContainerNumSlots(containerID)
        for slot = 1, (numSlots or 0) do
            local info = C_Container.GetContainerItemInfo(containerID, slot)
            if info and info.itemID and info.itemID ~= 0 then
                qtyMap[info.itemID] = (qtyMap[info.itemID] or 0) + (info.stackCount or 1)
            end
        end
    end

    return qtyMap
end

local function BuildLootList(preQty, postQty)
    local loot = {}
    for itemID, currentQty in pairs(postQty) do
        local previousQty = preQty[itemID] or 0
        if currentQty > previousQty then
            loot[itemID] = currentQty - previousQty
        end
    end
    return loot
end

local function UpdateAggregatedBagOpens(loot)
    local aggregated = PocketCFO_Orders.db.global.bagOpensAggregated
    if not aggregated then
        aggregated = { bags = 0 }
        PocketCFO_Orders.db.global.bagOpensAggregated = aggregated
    end
    aggregated.bags = (aggregated.bags or 0) + 1
    for itemID, qty in pairs(loot) do
        aggregated[itemID] = (aggregated[itemID] or 0) + qty
    end
end

local function RefreshBagSnapshot(self)
    self.previousTrackedBagCounts = ScanTrackedBagsInContainers()
    self.previousBagContents = ScanAllBagContents()
end

function BagOpens:OnEnable()
    self:RegisterEvent("BAG_UPDATE_DELAYED", "OnBagUpdateDelayed")
    RefreshBagSnapshot(self)
end

function BagOpens:OnBagUpdateDelayed()
    PocketCFO:Debug("BagOpens:OnBagUpdateDelayed fired")
    local currentTracked = ScanTrackedBagsInContainers()
    local currentContents = ScanAllBagContents()
    local previousTracked = self.previousTrackedBagCounts or {}
    local previousContents = self.previousBagContents or {}

    for bagItemID, previousCount in pairs(previousTracked) do
        local currentCount = currentTracked[bagItemID] or 0
        if currentCount < previousCount then
            local bagName = CONSORTIUM_BAG_IDS[bagItemID] or "Unknown"
            local bagCount = previousCount - currentCount
            local loot = BuildLootList(previousContents, currentContents)
            UpdateAggregatedBagOpens(loot)
            PocketCFO:Debug("BagOpens: aggregated consortium bag open bagItemID=%s bagName=%s bagCount=%d loot=%d",
                tostring(bagItemID), tostring(bagName), bagCount, #loot)
        end
    end

    RefreshBagSnapshot(self)
end

function BagOpens:OnDisable()
    self:UnregisterAllEvents()
end
