-- PocketCFO/Services/ItemLedger/ItemLedger.lua
-- One history of everything coming in and going out (design:
-- claude/Item_Ledger_Design.md, agreed with Brian 2026-10-30).
--
-- Step 1 (2026-10-30): the ledger itself, written by LootReader (items and
-- currencies coming in, currency spends). No feature reads it yet. Gold joins
-- at step 2 (GoldLedger becomes a writer); items going out join later.
-- Going out step 1 (2026-11-05): crafts (WriteCraft) - mats out, returns and
-- output in. Other exits: claude/Going_Out_Design.md.
--
-- Rules:
--   - One ledger, several readers, one writer per fact. Readers decide the
--     category; the ledger only stores and adds up.
--   - Facts only. Feature details (disenchant skill / gear, gathering buffs)
--     stay with the feature, linked by entry id.
--   - Value at the time: each entry is announced (MCG_ITEM_LEDGER_ENTRY) and
--     PocketCFO_Valuation (loaded at login by AddonLoader) prices it in the
--     same moment through SetValue. Entries written before Valuation was
--     ready this session are kept in a session list it prices when it starts.
--     An item with no price stays unpriced (never zero).
--
-- Storage: PocketCFO_DB.global.itemLedger = {
--   version = 1, nextID,
--   characters = { [index] = { guid, name, realm } },
--   detail = { entry, ... },                 -- oldest first, last DETAIL_DAYS
--   days   = { ["YYYY-MM-DD"] = { rows = { [key] = row }, activity = { [key] = row } } },
--   months = { ["YYYY-MM"]    = { rows = {...}, activity = {...} } },
--   housekeptOn = "YYYY-MM-DD",
--   holdings = { [key] = { qty, value } },  -- book value record (see Book value)
-- }
-- Item entries also carry hk (book value key) and bop (bound on pickup) on
-- the way in, and bv / bvq (book value copper / units) on the way out.
-- entry = { id, at, day, c, dir, cat, src, prof, kind, iid, link, qty, units, base, val, x }
--   dir "in" / "out"; cat = shared category (CATEGORIES); src = the ID behind
--   it where one exists (node object ID, mob npcID, container itemID,
--   disenchanted itemID, currency gain / lost code); kind "item" / "currency"
--   or "gold"; iid = itemID or currencyID; link for items; base =
--   source quantity for gathering (bonus = qty - base); val = unit value in
--   copper at the time (nil = unpriced); x = small extra facts (cast spell).
--   prof = base profession key ("182", "fishing", ...) where known.
--   Gold (2026-10-30, written by GoldLedger): kind "gold", qty = copper,
--   val = 1, src = the item sold / bought (by name, GoldLedger's detail)
--   with units = how many; at = when it was earned (AH sales: the sale day).
-- row (day / month) = { c, dir, cat, src, prof, kind, iid, qty, n, units, value, vq }
--   value = copper of priced entries, vq = quantity that was priced.
-- activity row = { c, cat, src, prof, n }: how many times it happened
--   (windows, nodes, kills, container openings).
--
-- Flavor: Both. Theoretical on Forever until tested there.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local ItemLedger = PocketCFO:NewModule("ItemLedger", "AceEvent-3.0")
PocketCFO.ItemLedger = ItemLedger

local DETAIL_DAYS = 30
local DAY_ROW_MONTHS = 13
local SECONDS_PER_DAY = 86400

-- Shared category list (Item_Ledger_Design.md decision 5): the same names as
-- GoldLedger so gold and items for one activity carry one label. GoldLedger
-- adopts this list at step 2. Labels are for diagnostics only.
ItemLedger.CATEGORIES = {
    gathering = "Gathering",
    fishing = "Fishing",
    looted = "Looted (kills)",
    disenchant = "Disenchanting",
    container = "Containers",
    other = "Other loot",
    craft = "Crafting",
    vendor = "Vendor",
    auction_buy = "Auction House purchases",
    mail = "Mail",
    trade = "Trade",
    quest = "Quests",
    transfer = "Moved between your characters",
    received = "Received (reason unknown)",
    spent = "Spent (reason unknown)",
    used = "Used up (food, potions, lures, knowledge)",
    -- Gold categories (GoldLedger; written from step 2).
    order_patron = "Patron orders",
    order_personal = "Personal orders",
    order_public = "Public orders",
    order_guild = "Guild orders",
    auction = "Auction House sales",
    auction_deposit = "Auction House deposits",
    repair = "Repairs",
    training = "Training",
    flight = "Flights",
    guild_bank = "Guild bank",
    services = "Services",
}

local sessionUnpriced = {}   -- entries written before Valuation was listening
local charIndexByGUID = nil  -- built from characters on first use

-- ---------------------------------------------------------------------------
-- Book value (Going Out step 2, 2026-11-05; claude/Going_Out_Design.md
-- "Book value"). Account-wide record of what held items were worth when they
-- came in, so an item going out leaves at the value it came in at (not
-- today's price, which would make every sale net about zero). Kept because
-- ledger detail is only DETAIL_DAYS long.
--   ledger.holdings[key] = { qty, value }   -- value = copper for qty units
--   key = "i:<itemID>" for stackables (average, project rule: average for
--   mats); "g:<configKey>" for non-stackable items (ItemIdentityService
--   identity incl. item level and stat fingerprint, so stat versions stay
--   apart; no identity = not tracked).
-- In (not transfer): priced units add qty and value when the price arrives
-- (SetValue); BoP items (bound on pickup, Brian 2026-11-05: no gold value)
-- add qty with value 0 at write. Unpriced units never enter the record.
-- Out (not transfer): takes book value at the record's average for as many
-- units as it holds; stored on the entry as bv (copper) for bvq units. Units
-- with no record (acquired before tracking, unpriced) leave at their value
-- at that moment (readers use val): no gain, no loss.
-- Transfers between your own characters don't touch it (account-wide).
-- Theoretical: GetItemInfo / GetDetailedItemLevelInfo answer at write time;
-- when the item isn't cached the stackable key / not-BoP is assumed.
-- Cost (what you paid) is added with the P&L work.
-- ---------------------------------------------------------------------------
local GetItemInfoAPI = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local BIND_ON_ACQUIRE = (Enum and Enum.ItemBind and Enum.ItemBind.OnAcquire) or 1

local function Holdings(ledger)
    ledger.holdings = ledger.holdings or {}
    return ledger.holdings
end

-- key, isBoP for an item entry.
local function HoldingKey(iid, link)
    iid = tonumber(iid)
    if not iid then
        return nil, false
    end
    local ref = (type(link) == "string" and link) or iid
    local maxStack, bindType
    if GetItemInfoAPI then
        local ok, _, _, _, _, _, _, _, stack, _, _, _, _, _, bind = pcall(GetItemInfoAPI, ref)
        if ok then
            maxStack, bindType = tonumber(stack), tonumber(bind)
        end
    end
    local isBoP = bindType == BIND_ON_ACQUIRE
    if maxStack == 1 then
        -- Gear: the same item identity Valuation prices by (configKey, which
        -- carries item level and stat fingerprint; project rule: never
        -- itemID alone). Fix 2026-11-05: keying by itemID + item level merged
        -- stat versions (in-game: a haste binding at 799g and versatility
        -- ones at 77g in one bucket, so a disenchant took the 799g book
        -- value). No identity = not tracked (leaves at its value then).
        local service = PocketCFO.ItemIdentityService
        if type(link) ~= "string" or not service or not service.FromItemLink then
            return nil, isBoP
        end
        local ok, identity = pcall(service.FromItemLink, service, link)
        if ok and type(identity) == "table" and not identity.unresolved and identity.configKey then
            return "g:" .. tostring(identity.configKey), isBoP
        end
        return nil, isBoP
    end
    return "i:" .. iid, isBoP
end

-- ---------------------------------------------------------------------------
-- Cost (2026-11-05, Brian: "any profit calculation has to come from the cost
-- of acquisition, not the value when it was acquired"). Kept next to value in
-- the same record: row.cost = copper for row.qty units; entry.cost = the
-- in entry's acquisition cost / the out entry's cost of what left.
--   Free (looted, gathered, fished, containers, quests, order rewards, mail,
--   trade, received): 0.
--   Bought (vendor, auction_buy): the gold paid, matched by item name to
--   GoldLedger's purchase gold-out entry (src = name, units), either order.
--   Crafted / disenchant mats: assigned by their writer (AllocateCost): the
--   cost of what went in, split by value.
--   Until a cost is known (purchase not matched yet, assigned later) the
--   entry counts at its value (provisional), replaced when the cost arrives.
-- Out entries take book cost like book value; units with no record cost
-- their value at that moment (no gain, no loss).
-- Day rows keep row.cost too (copper), for the P&L.
-- ---------------------------------------------------------------------------
local FREE_COST = {
    gathering = true, fishing = true, looted = true, container = true, other = true,
    quest = true, received = true, mail = true, trade = true,
    order_patron = true, order_personal = true, order_public = true, order_guild = true,
}
local PURCHASE = { vendor = true, auction_buy = true }
local VENDOR_MATCH_SECONDS = 60          -- vendor: gold and item arrive together
local PURCHASE_KEEP_SECONDS = 30 * 86400 -- AH: the item comes by mail, maybe days later
local recentPurchaseIns = {}             -- unmatched bought items this session

local AddRowCost  -- (ledger, entry, delta) defined after the row helpers

local function HoldingRow(ledger, key)
    local holdings = Holdings(ledger)
    local row = holdings[key]
    if not row then
        row = { qty = 0, value = 0, cost = 0 }
        holdings[key] = row
    end
    row.cost = row.cost or 0
    return row
end

-- Called from Write for item entries (not transfers), before the entry is
-- announced (so out entries carry bv / cost when readers see them).
local function ApplyHoldings(ledger, entry, fields)
    if entry.kind ~= "item" or entry.cat == "transfer" then
        return
    end
    local key, isBoP = HoldingKey(entry.iid, entry.link)
    if entry.dir == "in" then
        if fields.cost ~= nil then
            entry.cost = tonumber(fields.cost)
        elseif FREE_COST[entry.cat] and not fields.costPending then
            entry.cost = 0
        else
            entry.costPending = true
        end
        if not key then
            return
        end
        entry.hk = key
        if isBoP then
            entry.bop = true
            local row = HoldingRow(ledger, key)
            row.qty = row.qty + entry.qty
            entry.provCost = entry.cost or 0
            row.cost = row.cost + entry.provCost
            entry.inHoldings = true
        end
        return
    end
    local holdings = Holdings(ledger)
    local row = key and holdings[key]
    if not row or (row.qty or 0) <= 0 then
        return
    end
    local take = math.min(entry.qty, row.qty)
    local unitValue = (row.value or 0) / row.qty
    local unitCost = (row.cost or 0) / row.qty
    entry.bv = math.floor(unitValue * take + 0.5)
    entry.bvq = take
    entry.cost = math.floor(unitCost * take + 0.5)
    row.qty = row.qty - take
    row.value = math.max(0, (row.value or 0) - unitValue * take)
    row.cost = math.max(0, (row.cost or 0) - unitCost * take)
    if row.qty <= 0 then
        holdings[key] = nil
    end
end

-- Called from SetValue. A priced item in adds its units, value and cost
-- (provisional = its value while the cost is pending). An out entry's units
-- with no record cost their value now.
local function AddPricedHolding(ledger, entry)
    if entry.kind ~= "item" or entry.cat == "transfer" then
        return
    end
    local val = tonumber(entry.val) or 0
    if entry.dir == "out" then
        local unbased = entry.qty - (tonumber(entry.bvq) or 0)
        if unbased > 0 then
            local extra = val * unbased
            entry.cost = (entry.cost or 0) + extra
            AddRowCost(ledger, entry, extra)
        end
        return
    end
    if entry.bop or not entry.hk or entry.inHoldings then
        return
    end
    local row = HoldingRow(ledger, entry.hk)
    row.qty = row.qty + entry.qty
    row.value = row.value + val * entry.qty
    entry.provCost = entry.cost or (val * entry.qty)
    row.cost = row.cost + entry.provCost
    entry.inHoldings = true
end

-- Sets an in entry's acquisition cost (replaces the provisional one).
local function AssignCost(ledger, entry, cost)
    cost = math.max(0, math.floor((tonumber(cost) or 0) + 0.5))
    entry.costPending = nil
    local before = entry.cost or 0
    entry.cost = cost
    AddRowCost(ledger, entry, cost - before)
    if entry.inHoldings and entry.hk then
        local row = Holdings(ledger)[entry.hk]
        if row then
            row.cost = math.max(0, (row.cost or 0) + cost - (entry.provCost or 0))
        end
        entry.provCost = cost
    end
end

local function ItemNameOf(iid, link)
    if not GetItemInfoAPI then
        return nil
    end
    local ok, name = pcall(GetItemInfoAPI, link or iid)
    return ok and type(name) == "string" and name or nil
end

-- Purchases: a bought item and the gold paid for it, matched by name.
local function PendingBuys(ledger)
    ledger.pendingBuys = ledger.pendingBuys or {}
    return ledger.pendingBuys
end

local function MatchBoughtItem(ledger, entry)
    local name = ItemNameOf(entry.iid, entry.link)
    if not name then
        return
    end
    entry.buyName = name
    local buys = PendingBuys(ledger)
    local need = entry.qty - (entry.matchedQty or 0)
    local i = 1
    while i <= #buys and need > 0 do
        local buy = buys[i]
        if buy.cat == entry.cat and buy.name == name and buy.c == entry.c and (buy.units or 0) > 0 then
            local take = math.min(need, buy.units)
            local copper = buy.copper * take / buy.units
            entry.matchedQty = (entry.matchedQty or 0) + take
            entry.matchedCost = (entry.matchedCost or 0) + copper
            buy.units = buy.units - take
            buy.copper = buy.copper - copper
            need = need - take
            if buy.units <= 0 then
                table.remove(buys, i)
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    if (entry.matchedQty or 0) >= entry.qty then
        AssignCost(ledger, entry, entry.matchedCost)
    else
        recentPurchaseIns[#recentPurchaseIns + 1] = entry
    end
end

local function MatchPurchaseGold(ledger, entry)
    local name, units = entry.src, tonumber(entry.units) or 1
    if type(name) ~= "string" or units <= 0 then
        return
    end
    local copper = entry.qty
    local now = time()
    local i = 1
    while i <= #recentPurchaseIns and units > 0 do
        local item = recentPurchaseIns[i]
        if (now - (item.at or 0)) > VENDOR_MATCH_SECONDS and item.cat == "vendor" then
            table.remove(recentPurchaseIns, i)
        elseif item.cat == entry.cat and item.buyName == name and item.c == entry.c then
            local need = item.qty - (item.matchedQty or 0)
            local take = math.min(need, units)
            local part = copper * take / units
            item.matchedQty = (item.matchedQty or 0) + take
            item.matchedCost = (item.matchedCost or 0) + part
            units, copper = units - take, copper - part
            if item.matchedQty >= item.qty then
                AssignCost(ledger, item, item.matchedCost)
                table.remove(recentPurchaseIns, i)
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    if units > 0 then
        local buys = PendingBuys(ledger)
        buys[#buys + 1] = { cat = entry.cat, name = name, units = units, copper = copper, at = now, c = entry.c }
        -- Keep the list short: old vendor buys never get an item now.
        local j = 1
        while j <= #buys do
            local age = now - (buys[j].at or now)
            if (buys[j].cat == "vendor" and age > VENDOR_MATCH_SECONDS) or age > PURCHASE_KEEP_SECONDS then
                table.remove(buys, j)
            else
                j = j + 1
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local function DB()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    local ledger = globalDB.itemLedger
    if not ledger then
        ledger = { version = 1, nextID = 1, characters = {}, detail = {}, days = {}, months = {} }
        globalDB.itemLedger = ledger
    end
    ledger.characters = ledger.characters or {}
    ledger.detail = ledger.detail or {}
    ledger.days = ledger.days or {}
    ledger.months = ledger.months or {}
    ledger.nextID = ledger.nextID or 1
    return ledger
end

local function DayKey(at)
    return date("%Y-%m-%d", at or time())
end

local function CharacterIndex(ledger, guid, name, realm)
    local isPlayer = guid == nil
    guid = guid or (UnitGUID and UnitGUID("player"))
    if not guid then
        return nil
    end
    if not charIndexByGUID then
        charIndexByGUID = {}
        for index, character in ipairs(ledger.characters) do
            charIndexByGUID[character.guid] = index
        end
    end
    local index = charIndexByGUID[guid]
    if not index then
        ledger.characters[#ledger.characters + 1] = {
            guid = guid,
            name = name or (isPlayer and UnitName and UnitName("player")) or nil,
            realm = realm or (isPlayer and GetRealmName and GetRealmName()) or nil,
        }
        index = #ledger.characters
        charIndexByGUID[guid] = index
    end
    return index
end

-- Profession is appended only when present, so rows written before it
-- existed keep their keys.
local function RowKey(c, dir, cat, src, kind, iid, prof)
    local key = table.concat({ tostring(c), dir, cat, tostring(src or ""), kind, tostring(iid or "") }, "|")
    if prof then
        key = key .. "|" .. tostring(prof)
    end
    return key
end

local function EntryKey(e)
    return RowKey(e.c, e.dir, e.cat, e.src, e.kind, e.iid, e.prof)
end

local function ActivityKey(c, cat, src, prof)
    local key = table.concat({ tostring(c), cat, tostring(src or "") }, "|")
    if prof then
        key = key .. "|" .. tostring(prof)
    end
    return key
end

local function Bucket(store, key)
    local bucket = store[key]
    if not bucket then
        bucket = { rows = {}, activity = {} }
        store[key] = bucket
    end
    bucket.rows = bucket.rows or {}
    bucket.activity = bucket.activity or {}
    return bucket
end

local function AddToRow(rows, key, source, qty, n, value, vq, units)
    local row = rows[key]
    if not row then
        row = { c = source.c, dir = source.dir, cat = source.cat, src = source.src, prof = source.prof,
            kind = source.kind, iid = source.iid, qty = 0, n = 0, value = 0, vq = 0 }
        rows[key] = row
    end
    row.qty = row.qty + (qty or 0)
    row.n = row.n + (n or 0)
    row.value = row.value + (value or 0)
    row.vq = row.vq + (vq or 0)
    if units and units ~= 0 then
        row.units = (row.units or 0) + units
    end
    return row
end

-- Cost on an entry's day row (copper; the P&L reads it).
AddRowCost = function(ledger, entry, delta)
    delta = tonumber(delta) or 0
    if delta == 0 or not entry.day then
        return
    end
    local bucket = ledger.days[entry.day]
    local row = bucket and bucket.rows[EntryKey(entry)]
    if row then
        row.cost = (row.cost or 0) + delta
    end
end

-- Entry by id: detail is in id order (appended), so binary search.
local function FindEntry(ledger, id)
    local list = ledger.detail
    local low, high = 1, #list
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local entry = list[mid]
        if entry.id == id then
            return entry
        elseif entry.id < id then
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Writing (readers only)
-- ---------------------------------------------------------------------------

--- Writes one entry and adds it to its day's row. Returns the entry id.
-- @param fields { dir = "in"|"out", cat, src, prof, kind = "item"|"currency"|"gold",
--   iid, link, qty, units, base, x, at (default now), characterGUID }
function ItemLedger:Write(fields)
    local ledger = DB()
    if not ledger or type(fields) ~= "table" then
        return nil
    end
    local qty = tonumber(fields.qty)
    if not qty or qty <= 0 or not fields.cat or not fields.kind then
        return nil
    end
    local at = tonumber(fields.at) or time()
    local entry = {
        id = ledger.nextID,
        at = at,
        day = DayKey(at),
        c = CharacterIndex(ledger, fields.characterGUID),
        dir = fields.dir or "in",
        cat = fields.cat,
        src = fields.src,
        prof = fields.prof,
        kind = fields.kind,
        iid = tonumber(fields.iid),
        link = fields.link,
        qty = qty,
        units = tonumber(fields.units),
        base = tonumber(fields.base),
        x = fields.x,
    }
    -- Gold is its own value (1 copper = 1 copper).
    if entry.kind == "gold" then
        entry.val = 1
    end
    ledger.nextID = ledger.nextID + 1
    ApplyHoldings(ledger, entry, fields)
    ledger.detail[#ledger.detail + 1] = entry
    local bucket = Bucket(ledger.days, entry.day)
    AddToRow(bucket.rows, EntryKey(entry), entry, qty, 1, entry.val and qty or 0, entry.val and qty or 0, entry.units)
    if entry.cost and entry.cost ~= 0 then
        AddRowCost(ledger, entry, entry.cost)
    end

    self:SendMessage("MCG_ITEM_LEDGER_ENTRY", entry)
    -- Kept for Valuation only while it isn't listening yet (pricingReady is
    -- set by PocketCFO_Valuation's LedgerPricing when it starts).
    if entry.val == nil and not self.pricingReady then
        sessionUnpriced[#sessionUnpriced + 1] = entry
    end
    -- Purchases (cost): bought item <-> gold paid, matched by name.
    if entry.kind == "item" and entry.dir == "in" and PURCHASE[entry.cat] and entry.costPending then
        MatchBoughtItem(ledger, entry)
    elseif entry.kind == "gold" and entry.dir == "out" and PURCHASE[entry.cat] then
        MatchPurchaseGold(ledger, entry)
    end
    return entry.id, entry
end

--- Writes one craft (Going Out step 1, 2026-11-05; claude/Going_Out_Design.md):
-- mats used as out, resourcefulness returns and the output as in. All
-- category craft, src = recipeID, prof = base profession key, linked by
-- x.craft (the id of the craft's first entry). Writers: PocketCFO_Crafting's
-- CraftCompletionDispatcher (normal crafts and processing) and PocketCFO_Orders'
-- OrdersLedger (order crafts: your own mats only, no output, since the item
-- goes to the customer). LootReader no longer writes items in craft context.
-- craft = { recipeID, prof, used = rows, returned = rows, output = rows,
--   order = true|nil }; row = { itemID, quantity, itemLink }.
-- When no mats could be read, returns and output carry x.noMats so sessions
-- don't count the craft as pure profit (detail only; day rows don't keep x).
-- Returns the craft id, or nil when nothing was written.
function ItemLedger:WriteCraft(craft)
    local ledger = DB()
    if not ledger or type(craft) ~= "table" then
        return nil
    end
    local craftID = ledger.nextID
    local src = tonumber(craft.recipeID)
    local prof = craft.prof ~= nil and tostring(craft.prof) or nil
    local written = 0
    local function WriteRows(rows, dir, flags, costFor)
        local entries = {}
        for _, row in ipairs(type(rows) == "table" and rows or {}) do
            local iid = tonumber(row and row.itemID)
            local qty = tonumber(row and row.quantity) or 0
            if iid and qty > 0 then
                local x = { craft = craftID }
                for key, value in pairs(flags) do
                    x[key] = value
                end
                local fields = { dir = dir, cat = "craft", src = src, prof = prof, kind = "item",
                    iid = iid, link = row.itemLink, qty = qty, x = x }
                if dir == "in" then
                    local cost = costFor and costFor(iid, qty)
                    if cost then
                        fields.cost = cost
                    else
                        fields.costPending = true
                    end
                end
                local id, entry = self:Write(fields)
                if id then
                    entries[#entries + 1] = entry
                end
            end
        end
        written = written + #entries
        return entries
    end
    -- Mats out first: each takes its book value and cost (priced as written).
    local usedEntries = WriteRows(craft.used, "out", { order = craft.order or nil })
    local noMats = #usedEntries == 0 or nil
    local usedCost, unitCost = 0, {}
    for _, entry in ipairs(usedEntries) do
        local cost = tonumber(entry.cost) or 0
        usedCost = usedCost + cost
        local per = unitCost[entry.iid] or { qty = 0, cost = 0 }
        unitCost[entry.iid] = per
        per.qty = per.qty + entry.qty
        per.cost = per.cost + cost
    end
    -- Resourcefulness returns come back at the mats' own cost per unit.
    local returnsCost = 0
    WriteRows(craft.returned, "in", { returned = true, order = craft.order or nil, noMats = noMats },
        function(iid, qty)
            local per = unitCost[iid]
            local cost = (per and per.qty > 0) and (per.cost / per.qty * qty) or 0
            returnsCost = returnsCost + cost
            return cost
        end)
    -- Output: what the mats cost, less the returns, split by value.
    local outputEntries = WriteRows(craft.output, "in", { output = true, noMats = noMats })
    self:AllocateCost(outputEntries, math.max(0, usedCost - returnsCost))
    if written == 0 then
        return nil
    end
    return craftID
end

--- Splits a total cost (copper) across in entries by value (val x qty);
-- by quantity when none is priced. For crafts and disenchant mats.
function ItemLedger:AllocateCost(entries, total)
    local ledger = DB()
    if not ledger or type(entries) ~= "table" or #entries == 0 then
        return
    end
    total = tonumber(total) or 0
    local weights, sum = {}, 0
    for i, entry in ipairs(entries) do
        weights[i] = (tonumber(entry.val) or 0) * (tonumber(entry.qty) or 0)
        sum = sum + weights[i]
    end
    if sum <= 0 then
        sum = 0
        for i, entry in ipairs(entries) do
            weights[i] = tonumber(entry.qty) or 0
            sum = sum + weights[i]
        end
    end
    for i, entry in ipairs(entries) do
        if entry.dir == "in" then
            AssignCost(ledger, entry, sum > 0 and (total * weights[i] / sum) or 0)
        end
    end
end

--- Counts one occurrence of an activity (a gathering window, a kill, a
-- container opening) so "per node / per opening" averages need no detail.
function ItemLedger:CountActivity(cat, src, count, characterGUID, prof)
    local ledger = DB()
    count = tonumber(count) or 1
    if not ledger or not cat or count <= 0 then
        return
    end
    local c = CharacterIndex(ledger, characterGUID)
    local bucket = Bucket(ledger.days, DayKey())
    local key = ActivityKey(c, cat, src, prof)
    local row = bucket.activity[key]
    if not row then
        row = { c = c, cat = cat, src = src, prof = prof, n = 0 }
        bucket.activity[key] = row
    end
    row.n = row.n + count
end

--- Sets an entry's unit value (copper) once. Called by PocketCFO_Valuation.
-- Later calls for the same entry are ignored (value stays "at the time").
function ItemLedger:SetValue(id, unitValue)
    local ledger = DB()
    unitValue = tonumber(unitValue)
    if not ledger or not unitValue or unitValue < 0 then
        return false
    end
    local entry = type(id) == "table" and id or FindEntry(ledger, tonumber(id))
    if not entry or entry.val ~= nil then
        return false
    end
    entry.val = unitValue
    AddPricedHolding(ledger, entry)
    local bucket = ledger.days[entry.day]
    local row = bucket and bucket.rows[EntryKey(entry)]
    if row then
        row.value = row.value + unitValue * entry.qty
        row.vq = row.vq + entry.qty
    end
    return true
end

--- Adds history straight into a day's rows (no detail entry). For one-time
-- moves of older data into the ledger (GoldLedger day history, 2026-10-30).
-- @param fields { characterGUID, name, realm, dir, cat, src, prof, kind, iid,
--   qty, n, value, valuedQty, units }
function ItemLedger:AddHistoryRow(dayKey, fields)
    local ledger = DB()
    local qty = tonumber(fields and fields.qty)
    if not ledger or type(dayKey) ~= "string" or not qty or qty == 0 or not fields.cat or not fields.kind then
        return false
    end
    local c = CharacterIndex(ledger, fields.characterGUID, fields.name, fields.realm)
    local source = { c = c, dir = fields.dir or "in", cat = fields.cat, src = fields.src, prof = fields.prof,
        kind = fields.kind, iid = tonumber(fields.iid) }
    local bucket = Bucket(ledger.days, dayKey)
    AddToRow(bucket.rows, EntryKey(source), source, qty, tonumber(fields.n) or 0, tonumber(fields.value) or 0,
        tonumber(fields.valuedQty) or 0, tonumber(fields.units))
    ledger.housekeptOn = nil   -- old days roll into months at the next login
    return true
end

--- Adds an activity count straight into a day (one-time history moves).
function ItemLedger:AddHistoryActivity(dayKey, fields)
    local ledger = DB()
    local n = tonumber(fields and fields.n)
    if not ledger or type(dayKey) ~= "string" or not n or n <= 0 or not fields.cat then
        return false
    end
    local c = CharacterIndex(ledger, fields.characterGUID, fields.name, fields.realm)
    local bucket = Bucket(ledger.days, dayKey)
    local key = ActivityKey(c, fields.cat, fields.src, fields.prof)
    local row = bucket.activity[key]
    if not row then
        row = { c = c, cat = fields.cat, src = fields.src, prof = fields.prof, n = 0 }
        bucket.activity[key] = row
    end
    row.n = row.n + n
    ledger.housekeptOn = nil
    return true
end

--- Re-tags rows and entries from one category to another (one-time merges,
-- 2026-11-01). dir / kind limit it ("out", "gold"); nil matches any. Day and
-- month rows are re-keyed and added into any row that already has the new
-- key. Activity rows are left alone: they are keyed without dir, so one row
-- can hold both sides. Returns quantity moved, rows moved, entries moved.
function ItemLedger:MoveCategory(fromCat, toCat, dir, kind)
    local ledger = DB()
    if not ledger or not fromCat or not toCat or fromCat == toCat then
        return 0, 0, 0
    end
    local function Matches(row)
        return row.cat == fromCat and (dir == nil or row.dir == dir) and (kind == nil or row.kind == kind)
    end
    local movedQty, movedRows, movedEntries = 0, 0, 0
    for _, store in ipairs({ ledger.days, ledger.months }) do
        for _, bucket in pairs(store) do
            local rows = bucket.rows or {}
            local keys = {}
            for key, row in pairs(rows) do
                if Matches(row) then
                    keys[#keys + 1] = key
                end
            end
            for _, key in ipairs(keys) do
                local row = rows[key]
                rows[key] = nil
                local source = { c = row.c, dir = row.dir, cat = toCat, src = row.src, prof = row.prof,
                    kind = row.kind, iid = row.iid }
                AddToRow(rows, EntryKey(source), source, row.qty, row.n, row.value, row.vq, row.units)
                movedQty = movedQty + (tonumber(row.qty) or 0)
                movedRows = movedRows + 1
            end
        end
    end
    for _, entry in ipairs(ledger.detail) do
        if Matches(entry) then
            entry.cat = toCat
            movedEntries = movedEntries + 1
        end
    end
    return movedQty, movedRows, movedEntries
end

--- Removes day / month rows and activity rows of one category (and src when
-- given). One-time history moves only: clears rows a feature's old store
-- already holds, so the move doesn't count them twice. Returns rows removed.
function ItemLedger:RemoveRows(cat, src)
    local ledger = DB()
    if not ledger or not cat then
        return 0
    end
    local removed = 0
    for _, store in ipairs({ ledger.days, ledger.months }) do
        for _, bucket in pairs(store) do
            for key, row in pairs(bucket.rows or {}) do
                if row.cat == cat and (src == nil or row.src == src) then
                    bucket.rows[key] = nil
                    removed = removed + 1
                end
            end
            for key, row in pairs(bucket.activity or {}) do
                if row.cat == cat and (src == nil or row.src == src) then
                    bucket.activity[key] = nil
                    removed = removed + 1
                end
            end
        end
    end
    return removed
end

--- Entries written this session that still have no value (for Valuation to
-- price when it starts). Clears the list.
function ItemLedger:TakeSessionUnpriced()
    local list = {}
    for _, entry in ipairs(sessionUnpriced) do
        if entry.val == nil then
            list[#list + 1] = entry
        end
    end
    sessionUnpriced = {}
    return list
end

--- True when the name is one of this account's characters known to
-- GoldTracker (same data GoldLedger reads; GoldLedger keeps its own copy of
-- this check until step 2).
function ItemLedger:IsOwnCharacter(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    local bare = string.lower((string.match(name, "^([^%-]+)")) or name)
    local goldDB = PocketCFO.db and PocketCFO.db.global and PocketCFO.db.global.gold
    for _, character in pairs(goldDB and goldDB.characters or {}) do
        if character.name and string.lower(tostring(character.name)) == bare then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Housekeeping: detail older than DETAIL_DAYS goes; day rows older than
-- DAY_ROW_MONTHS months roll into month rows. Once per day, at login.
-- ---------------------------------------------------------------------------

local function MonthCutoff(now)
    local t = date("*t", now)
    t.month = t.month - DAY_ROW_MONTHS
    while t.month <= 0 do
        t.month = t.month + 12
        t.year = t.year - 1
    end
    return string.format("%04d-%02d-01", t.year, t.month)
end

function ItemLedger:Housekeep(now)
    local ledger = DB()
    if not ledger then
        return
    end
    now = now or time()
    local today = DayKey(now)
    if ledger.housekeptOn == today then
        return
    end

    local oldest = now - DETAIL_DAYS * SECONDS_PER_DAY
    local keep, dropped = {}, 0
    for _, entry in ipairs(ledger.detail) do
        if (entry.at or 0) >= oldest then
            keep[#keep + 1] = entry
        else
            dropped = dropped + 1
        end
    end
    ledger.detail = keep

    local cutoff = MonthCutoff(now)
    local rolled = 0
    for dayKey, bucket in pairs(ledger.days) do
        if dayKey < cutoff then
            local month = Bucket(ledger.months, string.sub(dayKey, 1, 7))
            for key, row in pairs(bucket.rows or {}) do
                local target = AddToRow(month.rows, key, row, row.qty, row.n, row.value, row.vq)
                if row.cost then
                    target.cost = (target.cost or 0) + row.cost
                end
            end
            for key, row in pairs(bucket.activity or {}) do
                local target = month.activity[key]
                if not target then
                    target = { c = row.c, cat = row.cat, src = row.src, prof = row.prof, n = 0 }
                    month.activity[key] = target
                end
                target.n = target.n + (row.n or 0)
            end
            ledger.days[dayKey] = nil
            rolled = rolled + 1
        end
    end

    ledger.housekeptOn = today
    if (dropped > 0 or rolled > 0) and PocketCFO.AppendSessionLog then
        PocketCFO:AppendSessionLog(string.format(
            "[MCG] ItemLedger: housekeeping dropped %d old entries, rolled %d days into months", dropped, rolled))
    end
end

function ItemLedger:OnEnable()
    pcall(self.Housekeep, self)
end

-- ---------------------------------------------------------------------------
-- Reading (features)
-- ---------------------------------------------------------------------------

local function CharacterFilter(ledger, filter)
    if filter.characterGUID then
        for index, character in ipairs(ledger.characters) do
            if character.guid == filter.characterGUID then
                return index
            end
        end
        return -1   -- unknown character: matches nothing
    end
    return nil
end

local function RowMatches(row, filter, c)
    return (c == nil or row.c == c)
        and (filter.dir == nil or row.dir == filter.dir)
        and (filter.cat == nil or row.cat == filter.cat)
        and (filter.src == nil or row.src == filter.src)
        and (filter.prof == nil or row.prof == filter.prof)
        and (filter.kind == nil or row.kind == filter.kind)
        and (filter.iid == nil or row.iid == filter.iid)
end

-- Calls fn(bucket) for every day and month bucket inside [from, to] (date
-- strings "YYYY-MM-DD"; either may be nil). A month bucket counts when its
-- month overlaps the range (month rows have no days).
local function EachBucket(ledger, filter, fn)
    local from, to = filter.from, filter.to
    for dayKey, bucket in pairs(ledger.days) do
        if (not from or dayKey >= from) and (not to or dayKey <= to) then
            fn(bucket, dayKey)
        end
    end
    local fromMonth = from and string.sub(from, 1, 7)
    local toMonth = to and string.sub(to, 1, 7)
    for monthKey, bucket in pairs(ledger.months) do
        if (not fromMonth or monthKey >= fromMonth) and (not toMonth or monthKey <= toMonth) then
            fn(bucket, monthKey)
        end
    end
end

--- Re-tags matching rows and entries to another category (2026-11-02,
-- Brian: marking spending personal and back). Filter: cat (required), dir,
-- kind, src, from, to ("YYYY-MM-DD"), characterGUIDs ({ [guid] = true }; nil
-- = every character). Day / month rows in the range are re-keyed and added
-- into any row that already has the new key; detail entries in the range are
-- re-tagged too. Amounts never change. Returns quantity, rows, entries moved.
function ItemLedger:MoveRows(filter, toCat)
    local ledger = DB()
    if not ledger or type(filter) ~= "table" or not filter.cat or not toCat or filter.cat == toCat then
        return 0, 0, 0
    end
    local chars = nil
    if type(filter.characterGUIDs) == "table" then
        chars = {}
        for index, character in ipairs(ledger.characters) do
            if filter.characterGUIDs[character.guid] then
                chars[index] = true
            end
        end
    end
    local function Matches(row)
        return row.cat == filter.cat and (filter.dir == nil or row.dir == filter.dir)
            and (filter.kind == nil or row.kind == filter.kind)
            and (filter.src == nil or row.src == filter.src)
            and (chars == nil or chars[row.c] == true)
    end
    local movedQty, movedRows, movedEntries = 0, 0, 0
    EachBucket(ledger, filter, function(bucket)
        local rows = bucket.rows or {}
        local keys = {}
        for key, row in pairs(rows) do
            if Matches(row) then
                keys[#keys + 1] = key
            end
        end
        for _, key in ipairs(keys) do
            local row = rows[key]
            rows[key] = nil
            local source = { c = row.c, dir = row.dir, cat = toCat, src = row.src, prof = row.prof,
                kind = row.kind, iid = row.iid }
            AddToRow(rows, EntryKey(source), source, row.qty, row.n, row.value, row.vq, row.units)
            movedQty = movedQty + (tonumber(row.qty) or 0)
            movedRows = movedRows + 1
        end
    end)
    for _, entry in ipairs(ledger.detail) do
        if Matches(entry) and (not filter.from or entry.day >= filter.from) and (not filter.to or entry.day <= filter.to) then
            entry.cat = toCat
            movedEntries = movedEntries + 1
        end
    end
    return movedQty, movedRows, movedEntries
end

--- Totals from day and month rows. Filter: from, to ("YYYY-MM-DD"),
-- characterGUID, dir, cat, src, prof, kind, iid. Returns { qty, n, value, valuedQty }.
function ItemLedger:GetTotals(filter)
    filter = filter or {}
    local result = { qty = 0, n = 0, value = 0, valuedQty = 0 }
    local ledger = DB()
    if not ledger then
        return result
    end
    local c = CharacterFilter(ledger, filter)
    EachBucket(ledger, filter, function(bucket)
        for _, row in pairs(bucket.rows) do
            if RowMatches(row, filter, c) then
                result.qty = result.qty + row.qty
                result.n = result.n + row.n
                result.value = result.value + row.value
                result.valuedQty = result.valuedQty + row.vq
            end
        end
    end)
    return result
end

--- Matching day / month rows themselves (for breakdowns by item or category).
function ItemLedger:GetRows(filter)
    filter = filter or {}
    local list = {}
    local ledger = DB()
    if not ledger then
        return list
    end
    local c = CharacterFilter(ledger, filter)
    EachBucket(ledger, filter, function(bucket, period)
        for _, row in pairs(bucket.rows) do
            if RowMatches(row, filter, c) then
                list[#list + 1] = { period = period, row = row }
            end
        end
    end)
    return list
end

--- How many times an activity happened. Filter: from, to, characterGUID, cat, src, prof.
function ItemLedger:GetActivityCount(filter)
    filter = filter or {}
    local ledger = DB()
    local total = 0
    if not ledger then
        return total
    end
    local c = CharacterFilter(ledger, filter)
    EachBucket(ledger, filter, function(bucket)
        for _, row in pairs(bucket.activity) do
            if (c == nil or row.c == c) and (filter.cat == nil or row.cat == filter.cat)
                and (filter.src == nil or row.src == filter.src) and (filter.prof == nil or row.prof == filter.prof) then
                total = total + (row.n or 0)
            end
        end
    end)
    return total
end

--- Activity rows themselves (to list what has activity). Filter: from, to,
-- characterGUID, cat, src.
function ItemLedger:GetActivityRows(filter)
    filter = filter or {}
    local list = {}
    local ledger = DB()
    if not ledger then
        return list
    end
    local c = CharacterFilter(ledger, filter)
    EachBucket(ledger, filter, function(bucket, period)
        for _, row in pairs(bucket.activity) do
            if (c == nil or row.c == c) and (filter.cat == nil or row.cat == filter.cat)
                and (filter.src == nil or row.src == filter.src) and (filter.prof == nil or row.prof == filter.prof) then
                list[#list + 1] = { period = period, row = row }
            end
        end
    end)
    return list
end

--- Detail entries (last DETAIL_DAYS days only). Filter: since, untilTime
-- (timestamps), characterGUID, dir, cat, src, kind, iid. Oldest first.
function ItemLedger:GetEntries(filter)
    filter = filter or {}
    local list = {}
    local ledger = DB()
    if not ledger then
        return list
    end
    local c = CharacterFilter(ledger, filter)
    for _, entry in ipairs(ledger.detail) do
        if (not filter.since or entry.at >= filter.since) and (not filter.untilTime or entry.at <= filter.untilTime)
            and RowMatches(entry, filter, c) then
            list[#list + 1] = entry
        end
    end
    return list
end

function ItemLedger:GetEntry(id)
    local ledger = DB()
    return ledger and FindEntry(ledger, tonumber(id)) or nil
end

function ItemLedger:GetCharacter(index)
    local ledger = DB()
    return ledger and ledger.characters[index] or nil
end

-- ---------------------------------------------------------------------------
-- Diagnostic: /mcg ledger [today|size|recent [n]|item <id>|category <name>]
-- ---------------------------------------------------------------------------

local function FormatCopper(copper)
    copper = math.floor(tonumber(copper) or 0)
    return string.format("%dg%02ds%02dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local function ThingName(kind, iid, link, src)
    if kind == "gold" then
        return "gold" .. (src and (" (" .. tostring(src) .. ")") or "")
    end
    if kind == "currency" then
        if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, iid)
            if ok and type(info) == "table" and info.name then
                return info.name .. " (currency " .. tostring(iid) .. ")"
            end
        end
        return "currency " .. tostring(iid)
    end
    if link then
        return link
    end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local ok, name = pcall(getInfo, iid)
    return (ok and name) or ("item " .. tostring(iid))
end

local function CharacterName(ledger, c)
    local character = ledger.characters[c]
    return character and tostring(character.name) or ("char " .. tostring(c))
end

function ItemLedger:BuildSizeReport()
    local ledger = DB() or { detail = {}, days = {}, months = {}, characters = {} }
    local dayRows, dayActivity, days = 0, 0, 0
    for _, bucket in pairs(ledger.days) do
        days = days + 1
        for _ in pairs(bucket.rows or {}) do dayRows = dayRows + 1 end
        for _ in pairs(bucket.activity or {}) do dayActivity = dayActivity + 1 end
    end
    local monthRows, months = 0, 0
    for _, bucket in pairs(ledger.months) do
        months = months + 1
        for _ in pairs(bucket.rows or {}) do monthRows = monthRows + 1 end
    end
    -- Rough bytes as written to SavedVariables (Theoretical estimate).
    local bytes = #ledger.detail * 160 + (dayRows + monthRows) * 110 + dayActivity * 50
    return {
        string.format("Entries (last %d days): %d   next id: %s", DETAIL_DAYS, #ledger.detail, tostring(ledger.nextID)),
        string.format("Day rows: %d over %d days (+%d activity rows)", dayRows, days, dayActivity),
        string.format("Month rows: %d over %d months", monthRows, months),
        string.format("Characters: %d   Estimated size: %.1f KB", #ledger.characters, bytes / 1024),
    }
end

function ItemLedger:BuildReport(arg)
    local ledger = DB()
    if not ledger then
        return "Saved data not ready yet."
    end
    arg = strtrim(tostring(arg or "")):lower()
    local command, rest = arg:match("^(%S*)%s*(.-)$")
    local lines = {}

    if command == "size" then
        lines = self:BuildSizeReport()
    elseif command == "recent" then
        local count = tonumber(rest) or 40
        lines[#lines + 1] = "=== Recent entries (newest first) ==="
        for index = #ledger.detail, math.max(1, #ledger.detail - count + 1), -1 do
            local e = ledger.detail[index]
            -- cost / book value (debug, 2026-11-05): cost = total copper
            -- (in: acquisition cost, "pending" until known; out: cost of what
            -- left); book = book value taken by an out entry.
            local costText = ""
            if e.kind == "item" then
                if e.cost ~= nil then
                    costText = "  cost=" .. FormatCopper(e.cost)
                elseif e.costPending then
                    costText = "  cost=pending"
                end
                if e.bv ~= nil then
                    costText = costText .. string.format("  book=%s (%d)", FormatCopper(e.bv), tonumber(e.bvq) or 0)
                end
            end
            lines[#lines + 1] = string.format("  #%d  %s  %s  %s %-12s src=%s  %s x%d%s  value=%s%s%s",
                e.id, date("%m-%d %H:%M:%S", e.at), CharacterName(ledger, e.c), e.dir, e.cat, tostring(e.src),
                ThingName(e.kind, e.iid, e.link, e.src), e.qty, e.base and ("  base=" .. e.base) or "",
                e.val and (FormatCopper(e.val) .. " each") or "unpriced", costText,
                e.x and e.x.spell and ("  spell=" .. tostring(e.x.spell)) or "")
        end
    elseif command == "item" or command == "category" then
        local filter = { from = DayKey(time() - DETAIL_DAYS * SECONDS_PER_DAY) }
        if command == "item" then
            filter.iid = tonumber(rest)
        else
            filter.cat = rest
        end
        lines[#lines + 1] = string.format("=== %s %s, last %d days (by day) ===", command, rest, DETAIL_DAYS)
        local found = self:GetRows(filter)
        table.sort(found, function(a, b) return a.period > b.period end)
        for _, item in ipairs(found) do
            local row = item.row
            lines[#lines + 1] = string.format("  %s  %s  %s %-12s src=%s  %s  qty=%d  n=%d  value=%s (priced %d)",
                item.period, CharacterName(ledger, row.c), row.dir, row.cat, tostring(row.src),
                ThingName(row.kind, row.iid, nil, row.src), row.qty, row.n, FormatCopper(row.value), row.vq)
        end
    else
        local today = DayKey()
        lines[#lines + 1] = "=== Today " .. today .. " (by category) ==="
        local bucket = ledger.days[today]
        local byCat, order = {}, {}
        for _, row in pairs(bucket and bucket.rows or {}) do
            local key = row.dir .. " " .. row.cat
            if not byCat[key] then
                byCat[key] = { rows = {}, value = 0 }
                order[#order + 1] = key
            end
            byCat[key].rows[#byCat[key].rows + 1] = row
            byCat[key].value = byCat[key].value + row.value
        end
        table.sort(order)
        for _, key in ipairs(order) do
            lines[#lines + 1] = string.format("  %s  (priced value %s)", key, FormatCopper(byCat[key].value))
            for _, row in ipairs(byCat[key].rows) do
                lines[#lines + 1] = string.format("      %s  %s x%d  src=%s  value=%s (priced %d)",
                    CharacterName(ledger, row.c), ThingName(row.kind, row.iid, nil, row.src), row.qty, tostring(row.src),
                    FormatCopper(row.value), row.vq)
            end
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "=== Activity today ==="
        for _, row in pairs(bucket and bucket.activity or {}) do
            lines[#lines + 1] = string.format("  %s  %s src=%s  x%d", CharacterName(ledger, row.c), row.cat,
                tostring(row.src), row.n)
        end
        lines[#lines + 1] = ""
        for _, line in ipairs(self:BuildSizeReport()) do
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines, "\n")
end

local diagnostics = PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("ledger", {
        name = "ledger",
        description = "Item ledger: today (default), size, recent [n], item <itemID>, category <name>.",
        usage = "/mcg ledger [today|size|recent [n]|item <itemID>|category <name>]",
        category = "General",
    }, function(rest)
        diagnostics:ShowDump("Item Ledger", ItemLedger:BuildReport(rest))
    end)
end
