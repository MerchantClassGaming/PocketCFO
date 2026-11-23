-- PocketCFO/Services/ShoppingList/ShoppingList.lua
-- The shopping list store (design: claude/Shopping_List_Design.md).
-- Flavor: Both. Data and rules only; the window and the buy click are
-- ShoppingListWindow.lua. Any feature adds to it: PocketCFO.ShoppingList:Add(...).
--
-- Saved per character (PocketCFO.db.char.shoppingList):
--   lines[itemID] = {
--     toBuy   = what the list shows (still to buy),
--     covered = how much of what was asked for is already owned or bought,
--     order   = when the line was first added (display order),
--     sources = { [source] = true }  (who asked: "recipe", "order", "crate")
--   }
--
-- Rules (agreed with Brian 2026-11-19):
--   Add q: spare = owned now - covered (never below 0). The part spare covers
--          goes to covered, the rest to toBuy. What you own is read only here,
--          so taking the mail later never changes a line.
--   Purchase n confirmed: toBuy - n (never below 0), covered + n.
--   A line shows only while toBuy > 0. A line with nothing to buy stays,
--   hidden, so a later Add for the same item doesn't count the same stock
--   twice. Every line (hidden too) is wiped by Clear, or when a purchase
--   leaves nothing to buy (the shopping trip is done).
--
-- Owned = bags (live count) + bank + warband bank (latest stored snapshots).
-- Retail crafts from all three; on Forever the bank counts too (agreed
-- 2026-11-19), and GetLines reports how much of a line is in the bank there.
-- Counts come from InventoryStateService:GetItemPlaces (shared with the
-- item tooltip).

local PocketCFO = _G.PocketCFO

local ShoppingList = {}

local CHANGED_MESSAGE = "MCG_SHOPPING_LIST_CHANGED"

local function IsForever()
    return PocketCFO and PocketCFO.flavor == "forever"
end

local function Root()
    local char = PocketCFO and PocketCFO.db and PocketCFO.db.char
    if not char then
        return nil
    end
    local root = char.shoppingList
    if type(root) ~= "table" then
        root = { lines = {}, nextOrder = 1 }
        char.shoppingList = root
    end
    root.lines = root.lines or {}
    root.nextOrder = tonumber(root.nextOrder) or 1
    return root
end

local function Changed(reason)
    if PocketCFO and PocketCFO.SendMessage then
        PocketCFO:SendMessage(CHANGED_MESSAGE, reason)
    end
end

local function Log(fmt, ...)
    if PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug("ShoppingList: " .. fmt, ...)
    end
end

-- ---------------------------------------------------------------------------
-- What you own
-- ---------------------------------------------------------------------------

-- Returns total owned, then the parts: bags, bank, warband bank.
-- Same counts as the item tooltip "You have" line
-- (InventoryStateService:GetItemPlaces). Mail and AH are not counted here:
-- you can't fill an order from them.
function ShoppingList:GetOwned(itemID)
    itemID = tonumber(itemID)
    local service = PocketCFO and PocketCFO.InventoryStateService
    if not itemID or not service or not service.GetItemPlaces then
        return 0, 0, 0, 0
    end
    local places = service:GetItemPlaces(itemID)
    return places.bags + places.bank + places.warbank, places.bags, places.bank, places.warbank
end

-- ---------------------------------------------------------------------------
-- Changing the list
-- ---------------------------------------------------------------------------

-- Adds qty of itemID for one source ("recipe", "order", "crate", ...).
-- Returns { toBuy = added to the list, fromOwned = covered by what you own }
-- or nil if the arguments are bad. toBuy 0 means you already have it all.
-- options.exact (manual adds, Brian 2026-11-22): "I need to buy 20" means
-- buy 20; what you own is not taken off.
function ShoppingList:Add(itemID, qty, source, options)
    itemID = tonumber(itemID)
    qty = math.floor(tonumber(qty) or 0)
    local root = Root()
    if not root or not itemID or qty <= 0 then
        return nil
    end

    local line = root.lines[itemID]
    if not line then
        line = { toBuy = 0, covered = 0, order = root.nextOrder, sources = {} }
        root.nextOrder = root.nextOrder + 1
        root.lines[itemID] = line
    end

    local owned = self:GetOwned(itemID)
    local spare = math.max(0, owned - line.covered)
    local fromOwned = math.min(qty, spare)
    if type(options) == "table" and options.exact then
        fromOwned = 0
    end
    line.covered = line.covered + fromOwned
    line.toBuy = line.toBuy + (qty - fromOwned)
    if source then
        line.sources = line.sources or {}
        line.sources[tostring(source)] = true
    end

    Log("add itemID=%d qty=%d source=%s owned=%d spare=%d fromOwned=%d toBuy=%d covered=%d",
        itemID, qty, tostring(source), owned, spare, fromOwned, line.toBuy, line.covered)
    Changed("add")
    return { toBuy = qty - fromOwned, fromOwned = fromOwned }
end

local function AnythingToBuy(root)
    for _, line in pairs(root.lines) do
        if (tonumber(line.toBuy) or 0) > 0 then
            return true
        end
    end
    return false
end

-- A confirmed purchase (the AH side calls this on COMMODITY_PURCHASE_SUCCEEDED
-- with the item and quantity from the confirmed purchase). A buy for an item
-- not on the list is ignored.
function ShoppingList:RecordPurchase(itemID, qty)
    itemID = tonumber(itemID)
    qty = math.floor(tonumber(qty) or 0)
    local root = Root()
    if not root or not itemID or qty <= 0 then
        return
    end
    local line = root.lines[itemID]
    if not line then
        Log("purchase itemID=%d qty=%d not on the list", itemID, qty)
        return
    end
    line.toBuy = math.max(0, line.toBuy - qty)
    line.covered = line.covered + qty
    Log("purchase itemID=%d qty=%d toBuy=%d covered=%d", itemID, qty, line.toBuy, line.covered)

    if not AnythingToBuy(root) then
        root.lines = {}
        root.nextOrder = 1
        Log("nothing left to buy: list reset")
    end
    Changed("purchase")
end

-- Right-click remove (the window asks "Are you sure?" first).
function ShoppingList:Remove(itemID)
    itemID = tonumber(itemID)
    local root = Root()
    if not root or not itemID or not root.lines[itemID] then
        return
    end
    root.lines[itemID] = nil
    Log("remove itemID=%d", itemID)
    Changed("remove")
end

-- Clear button (the window asks "Are you sure?" first).
function ShoppingList:Clear()
    local root = Root()
    if not root then
        return
    end
    root.lines = {}
    root.nextOrder = 1
    Log("clear")
    Changed("clear")
end

-- ---------------------------------------------------------------------------
-- Reading the list
-- ---------------------------------------------------------------------------

-- Lines with something to buy, in the order they were added:
-- { itemID, toBuy, covered, sources, inBank }. inBank (Forever only) is how
-- much of what's covered sits in the bank (bags first), for "Buy 8, 12 in bank".
function ShoppingList:GetLines()
    local root = Root()
    local lines = {}
    if not root then
        return lines
    end
    for itemID, line in pairs(root.lines) do
        if (tonumber(line.toBuy) or 0) > 0 then
            local entry = {
                itemID = itemID,
                toBuy = line.toBuy,
                covered = line.covered,
                sources = line.sources,
                order = line.order or 0,
            }
            if IsForever() and line.covered > 0 then
                local _, bags, bank = self:GetOwned(itemID)
                local inBank = math.min(bank, math.max(0, line.covered - bags))
                if inBank > 0 then
                    entry.inBank = inBank
                end
            end
            lines[#lines + 1] = entry
        end
    end
    table.sort(lines, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.itemID < b.itemID
    end)
    return lines
end

-- Every stored line, hidden ones included (diagnostics).
function ShoppingList:GetAllLines()
    local root = Root()
    return root and root.lines or {}
end

ShoppingList.CHANGED_MESSAGE = CHANGED_MESSAGE

if PocketCFO then
    PocketCFO.ShoppingList = ShoppingList
end
