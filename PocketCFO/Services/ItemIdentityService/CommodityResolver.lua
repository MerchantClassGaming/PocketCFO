-- PocketCFO/Services/ItemIdentityService/CommodityResolver.lua
-- Owns canonical PocketCFO/AH commodity determination for item identities.

local PocketCFO = _G.PocketCFO

local CommodityResolver = {}

local ITEM_CLASS_CONSUMABLE = 0
local ITEM_CLASS_CONTAINER = 1
local ITEM_CLASS_WEAPON = 2
local ITEM_CLASS_GEM = 3
local ITEM_CLASS_ARMOR = 4
local ITEM_CLASS_REAGENT = 5
local ITEM_CLASS_TRADESKILL = 7
local ITEM_CLASS_ITEM_ENHANCEMENT = 8
local ITEM_CLASS_PROFESSION = 19
local ITEM_CLASS_ITEM_ENHANCEMENT_HOUSING = 20

local HOUSING_SUBCLASS_DYE = 1

local TRADEGOODS_SUBCLASS_CLOTH = 5
local TRADEGOODS_SUBCLASS_METAL_AND_STONE = 7
local TRADEGOODS_SUBCLASS_HERB = 9
local TRADEGOODS_SUBCLASS_ENCHANTING = 12
local TRADEGOODS_SUBCLASS_INSCRIPTION = 16

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

local function BooleanOrNil(value)
    if value == true or value == "true" then
        return true
    end
    if value == false or value == "false" then
        return false
    end
    return nil
end

local function Lower(value)
    if value == nil then
        return nil
    end
    return tostring(value):lower()
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return false, nil
    end
    return pcall(fn, ...)
end

local function CommodityStatusToBoolean(status)
    if status == true then
        return true
    end
    if status == false then
        return false
    end
    if type(status) == "table" then
        local keys = { "isCommodity", "commodity", "status", "commodityStatus" }
        for _, key in ipairs(keys) do
            if status[key] ~= nil then
                local value = CommodityStatusToBoolean(status[key])
                if value ~= nil then
                    return value
                end
            end
        end
        return nil
    end
    if type(status) == "number" and Enum and Enum.ItemCommodityStatus and Enum.ItemCommodityStatus.Commodity ~= nil then
        return status == Enum.ItemCommodityStatus.Commodity
    end
    if type(status) == "string" then
        status = status:lower()
        if status == "commodity" or status == "itemcommodity" or status == "item_commodity" then
            return true
        end
        if status == "item" or status == "noncommodity" or status == "non_commodity" then
            return false
        end
    end
    return nil
end

local function ResolveFromItemLocation(identity)
    local itemLocation = identity and identity.itemLocation
    if not itemLocation or not C_AuctionHouse or type(C_AuctionHouse.GetItemCommodityStatus) ~= "function" then
        return nil
    end

    local ok, status = SafeCall(C_AuctionHouse.GetItemCommodityStatus, itemLocation)
    if not ok then
        return nil
    end

    local isCommodity = CommodityStatusToBoolean(status)
    if isCommodity ~= nil then
        return isCommodity, "itemLocation", "GetItemCommodityStatus"
    end
    return nil
end

local function ResolveFromAuctionEvidence(identity)
    local raw = identity and identity.raw
    local rawIsCommodity = type(raw) == "table" and BooleanOrNil(raw.isCommodity) or nil
    if rawIsCommodity ~= nil then
        if rawIsCommodity then
            return true, "auctionEvidence", "commodityAuctionRow"
        end
        return false, "auctionEvidence", "itemAuctionRow"
    end

    local explicitIsCommodity = BooleanOrNil(identity and identity.isCommodity)
    if explicitIsCommodity ~= nil and identity and tostring(identity.evidenceType or identity.source or ""):lower():find("auction", 1, true) then
        if explicitIsCommodity then
            return true, "auctionEvidence", "commodityAuctionRow"
        end
        return false, "auctionEvidence", "itemAuctionRow"
    end

    local path = Lower(type(raw) == "table" and (raw.auctionPath or raw.path or raw.marketPath) or nil)
    if path == "commodity" then
        return true, "auctionEvidence", "commodityAuctionRow"
    end
    if path == "item" then
        return false, "auctionEvidence", "itemAuctionRow"
    end

    local rawCommodity = type(raw) == "table" and BooleanOrNil(raw.commodity) or nil
    if rawCommodity == true then
        return true, "auctionEvidence", "commodityAuctionRow"
    end

    return nil
end

local function NameMatches(itemName, patterns)
    itemName = Lower(itemName)
    if not itemName then
        return false
    end
    for _, pattern in ipairs(patterns) do
        if itemName:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

local function ResolveFromFallback(identity)
    local classID = NumberOrNil(identity and (identity.itemClassID or identity.classID))
    local subClassID = NumberOrNil(identity and (identity.itemSubClassID or identity.subClassID or identity.subclassID))
    local equipLoc = identity and (identity.equipLoc or identity.inventoryType or identity.itemEquipLoc)
    local classification = identity and identity.classification
    local maxStack = NumberOrNil(identity and identity.maxStack)
    local isStackable = BooleanOrNil(identity and identity.isStackable)

    if classID == ITEM_CLASS_ITEM_ENHANCEMENT_HOUSING and subClassID == HOUSING_SUBCLASS_DYE then
        return true, "fallback", "housingDyeCommodity"
    end

    if equipLoc == "INVTYPE_PROFESSION_TOOL" then
        return false, "fallbackClassification", "professionTool"
    end
    if equipLoc == "INVTYPE_PROFESSION_GEAR" then
        return false, "fallbackClassification", "professionAccessory"
    end
    if classID == ITEM_CLASS_ARMOR then
        return false, "fallbackClassification", "armor"
    end
    if classID == ITEM_CLASS_WEAPON then
        return false, "fallbackClassification", "weapon"
    end
    if classID == ITEM_CLASS_PROFESSION then
        return false, "fallbackClassification", "professionItem"
    end
    if classID == ITEM_CLASS_CONTAINER then
        return false, "fallbackClassification", "container"
    end
    if (isStackable == false or maxStack == 1) and tostring(identity and (identity.evidenceType or identity.source or "")):lower():find("auction", 1, true) then
        return false, "fallbackClassification", "knownNonStackableItemAuction"
    end

    if classification == "reagent" or classID == ITEM_CLASS_REAGENT then
        return true, "fallbackClassification", "reagent"
    end
    if classID == ITEM_CLASS_TRADESKILL then
        if subClassID == TRADEGOODS_SUBCLASS_METAL_AND_STONE then
            return true, "fallbackClassification", "ore"
        end
        if subClassID == TRADEGOODS_SUBCLASS_HERB then
            return true, "fallbackClassification", "herb"
        end
        if subClassID == TRADEGOODS_SUBCLASS_CLOTH then
            return true, "fallbackClassification", "cloth"
        end
        if subClassID == TRADEGOODS_SUBCLASS_ENCHANTING then
            return true, "fallbackClassification", "enchantingMaterial"
        end
        if subClassID == TRADEGOODS_SUBCLASS_INSCRIPTION then
            return true, "fallbackClassification", "pigment"
        end
        return true, "fallbackClassification", "tradeGood"
    end
    if classID == ITEM_CLASS_GEM or classification == "gem" then
        return true, "fallbackClassification", "gem"
    end
    if classID == ITEM_CLASS_ITEM_ENHANCEMENT or classification == "itemEnhancement" then
        return true, "fallbackClassification", "itemEnhancement"
    end
    if classID == ITEM_CLASS_CONSUMABLE and (isStackable == true or (maxStack and maxStack > 1)) then
        if NameMatches(identity and identity.itemName, { "phial", "potion", "flask" }) then
            return true, "fallbackClassification", "stackableConsumable"
        end
        return true, "fallbackClassification", "stackableConsumable"
    end
    -- Any other stackable item is an AH commodity (e.g. Ancient Mogu Key, stack 20,
    -- class not covered above). Gear, tools, bags and known non-stackables have
    -- already returned false before this point.
    if isStackable == true or (maxStack and maxStack > 1) then
        return true, "fallbackClassification", "stackableItem"
    end

    return nil
end

function CommodityResolver:Resolve(identity)
    if type(identity) ~= "table" then
        return false, "default", "unknownDefaultItem"
    end

    local isCommodity, source, reason = ResolveFromItemLocation(identity)
    if isCommodity ~= nil then
        return isCommodity, source, reason
    end

    isCommodity, source, reason = ResolveFromAuctionEvidence(identity)
    if isCommodity ~= nil then
        return isCommodity, source, reason
    end

    isCommodity, source, reason = ResolveFromFallback(identity)
    if isCommodity ~= nil then
        return isCommodity, source, reason
    end

    return false, "default", "unknownDefaultItem"
end

function CommodityResolver:Apply(identity)
    local isCommodity, source, reason = self:Resolve(identity)
    identity.isCommodity = isCommodity == true
    identity.commoditySource = source
    identity.commodityReason = reason
    return identity
end

if PocketCFO then
    PocketCFO.ItemCommodityResolver = CommodityResolver
end

_G.PocketCFO_ItemCommodityResolver = CommodityResolver
