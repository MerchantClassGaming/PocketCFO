-- PocketCFO/Services/CostToMakeStore/CostToMakeStore.lua
-- Remembers what each crafted item is made from so its Cost to Make can be
-- worked out anywhere, at today's prices (design: claude/AH_Smart_Posting_Design.md).
--
-- Why: Cost to Make (RecipeEconomicsService) only exists while a recipe is
-- open in the profession window; at the Auction House there is no crafting
-- form to read, on any character. So every time recipe analysis resolves a
-- recipe, its mat list is saved here (account-wide). Readers re-price the
-- mats with today's values, so the answer is today's Cost to Make, not the
-- number from the last time the recipe was opened.
--
-- Saved per output configKey (PocketCFO.db.global.costToMake):
--   id   = output itemID
--   mats = { { id = itemID, ck = configKey, q = quantity per craft }, ... }
--   rf   = costToMake / totalCost (expected Resourcefulness savings; 1 = none)
--   ipc  = expected items per craft (base + multicraft)
--   t    = when saved (server time)
-- Not saved when a slot has no reagent chosen or a mat had no price (the
-- saved cost would be wrong). Bound mats with no price count as free, the
-- same as recipe analysis.
--
-- Readers: PocketCFO_AH smart posting (floor and ceiling).
-- Flavor: Both.

local PocketCFO = _G.PocketCFO

local CostToMakeStore = {}

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function DB()
    local db = PocketCFO and PocketCFO.db and PocketCFO.db.global
    if not db then
        return nil
    end
    db.costToMake = db.costToMake or {}
    return db.costToMake
end

local function NumberOrNil(value)
    value = tonumber(value)
    return value
end

local function AddMats(mats, rows)
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        local itemID = tonumber(row.itemID)
        local quantity = NumberOrNil(row.quantity) or 0
        -- Currencies (no itemID) have no AH price; recipe analysis leaves
        -- them out of cost too.
        if itemID and quantity > 0 and not (row.unvalued and row.bound) then
            mats[#mats + 1] = { id = itemID, ck = row.configKey, q = quantity }
        end
    end
end

-- Called by RecipeEconomicsService after a recipe resolves. Never throws.
function CostToMakeStore:Record(observation, economics)
    local ok, err = pcall(function()
        if type(observation) ~= "table" or type(economics) ~= "table" then
            return
        end
        if economics.hasUnchosenSlots or economics.hasOtherUnpricedMats then
            return
        end
        local configKey = observation.outputConfigKey or economics.outputConfigKey
        local itemID = tonumber(observation.outputItemID or economics.outputItemID)
        local totalCost = NumberOrNil(economics.totalCost)
        local costToMake = NumberOrNil(economics.costToMake)
        local itemsPerCraft = NumberOrNil(economics.expectedItemsPerCraft)
        if not configKey or not itemID or not totalCost or totalCost <= 0
            or not costToMake or not itemsPerCraft or itemsPerCraft <= 0 then
            return
        end

        local mats = {}
        AddMats(mats, economics.materialRows)
        AddMats(mats, economics.finishingReagentRows)
        AddMats(mats, economics.vellumRows)
        if #mats == 0 then
            return
        end

        local db = DB()
        if not db then
            return
        end
        db[tostring(configKey)] = {
            id = itemID,
            mats = mats,
            rf = math.max(0, math.min(1, costToMake / totalCost)),
            ipc = itemsPerCraft,
            t = Now(),
        }
    end)
    if not ok and PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug("CostToMakeStore: record failed err=%s", tostring(err))
    end
end

-- The saved recipe for an item: exact configKey first, else the cheapest
-- saved version of the same itemID (e.g. a different quality was last
-- opened). Returns record, matchedBy ("configKey" | "itemID") or nil.
function CostToMakeStore:Find(configKey, itemID)
    local db = DB()
    if not db then
        return nil
    end
    if configKey and db[tostring(configKey)] then
        return db[tostring(configKey)], "configKey"
    end
    itemID = tonumber(itemID)
    if not itemID then
        return nil
    end
    local found
    for _, record in pairs(db) do
        if type(record) == "table" and tonumber(record.id) == itemID then
            found = found or {}
            found[#found + 1] = record
        end
    end
    if not found then
        return nil
    end
    return found, "itemID"
end

-- Today's Cost to Make per item, using priceFn(itemID, configKey) -> copper
-- per unit or nil. Returns copper or nil (no saved recipe, or a mat has no
-- price today).
local function PriceRecord(record, priceFn)
    local total = 0
    for _, mat in ipairs(record.mats or {}) do
        local unit = priceFn(mat.id, mat.ck)
        if not unit then
            return nil
        end
        total = total + unit * (tonumber(mat.q) or 0)
    end
    local ipc = tonumber(record.ipc) or 1
    if ipc <= 0 then
        return nil
    end
    return math.floor(total * (tonumber(record.rf) or 1) / ipc + 0.5)
end

function CostToMakeStore:GetCostToday(configKey, itemID, priceFn)
    if type(priceFn) ~= "function" then
        return nil
    end
    local found, matchedBy = self:Find(configKey, itemID)
    if not found then
        return nil
    end
    if matchedBy == "configKey" then
        return PriceRecord(found, priceFn), matchedBy
    end
    local lowest
    for _, record in ipairs(found) do
        local cost = PriceRecord(record, priceFn)
        if cost and (not lowest or cost < lowest) then
            lowest = cost
        end
    end
    return lowest, matchedBy
end

if PocketCFO then
    PocketCFO.CostToMakeStore = CostToMakeStore
end
_G.PocketCFO_CostToMakeStore = CostToMakeStore
