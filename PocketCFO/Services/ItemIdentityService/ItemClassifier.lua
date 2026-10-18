-- PocketCFO/Services/ItemIdentityService/ItemClassifier.lua
-- Classifies normalized item facts into PocketCFO identity categories.

local PocketCFO = _G.PocketCFO

local ItemClassifier = {}

local ITEM_CLASS_CONSUMABLE = 0
local ITEM_CLASS_CONTAINER = 1
local ITEM_CLASS_WEAPON = 2
local ITEM_CLASS_GEM = 3
local ITEM_CLASS_ARMOR = 4
local ITEM_CLASS_REAGENT = 5
local ITEM_CLASS_TRADESKILL = 7
local ITEM_CLASS_ITEM_ENHANCEMENT = 8
local ITEM_CLASS_RECIPE = 9
local ITEM_CLASS_MISCELLANEOUS = 15
local ITEM_CLASS_PROFESSION = 19

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

function ItemClassifier:Classify(identity)
    local classID = NumberOrNil(identity and (identity.itemClassID or identity.classID))
    local equipLoc = identity and (identity.equipLoc or identity.inventoryType or identity.itemEquipLoc)

    if equipLoc == "INVTYPE_PROFESSION_TOOL" then
        return "professionTool"
    end
    if equipLoc == "INVTYPE_PROFESSION_GEAR" then
        return "professionAccessory"
    end
    if classID == ITEM_CLASS_WEAPON or classID == ITEM_CLASS_ARMOR then
        return "craftedGear"
    end
    if classID == ITEM_CLASS_CONTAINER then
        return "bag"
    end
    if classID == ITEM_CLASS_CONSUMABLE then
        return "consumable"
    end
    if classID == ITEM_CLASS_RECIPE then
        return "recipe"
    end
    if classID == ITEM_CLASS_REAGENT or classID == ITEM_CLASS_TRADESKILL then
        return "reagent"
    end
    if classID == ITEM_CLASS_ITEM_ENHANCEMENT then
        return "itemEnhancement"
    end
    if classID == ITEM_CLASS_GEM then
        return "gem"
    end
    if classID == ITEM_CLASS_PROFESSION then
        return "professionItem"
    end
    if classID == ITEM_CLASS_MISCELLANEOUS then
        return "miscellaneous"
    end
    return "item"
end

if PocketCFO then
    PocketCFO.ItemClassifier = ItemClassifier
end

_G.PocketCFO_ItemClassifier = ItemClassifier
