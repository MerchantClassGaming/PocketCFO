-- PocketCFO_PnL/Services/IncomeReport.lua
-- Builds the Income and Spending view models from the Item Ledger's gold rows
-- (kind "gold", written by GoldLedger; 2026-10-30, was GoldLedger:GetDays).
-- Build(periodKey, characterGUID, mode): mode "spend" reads gold going out;
-- anything else gold coming in. Item detail = rows with an item name (src).
-- Transfers between your own characters are never counted either way.
-- "other" (gold changes we could not classify) is shown as "Everything else"
-- so the total matches the gold actually gained.
-- Auction House sales (income only, 2026-10-31, Brian: not profession-first,
-- PocketCFO is for anyone selling anything): grouped by what the item is,
-- then a second level, then the items:
--   Gear (weapons, armor, profession tools, bags): Crafted: <profession>, Looted, Flipped
--   Crafting materials: one row per material type in the game's own list
--     (Herbs, Ore & metal, Leather, Cloth, Fish & meat, Enchanting,
--     Jewelcrafting, Inscription, Parts, Elemental, ...), else Other
--   Consumables: Crafted: <profession>, Other, Flipped
--   Item enhancements: Gems, Enchants (made by Enchanting), Other, Flipped
--   Recipes / Other: the items (and Flipped)
--   Collectibles: Pets, Mounts, Toys, Flipped
-- Item type comes from GetItemInfo(itemID saved on the sale, else the name).
-- Theoretical: name lookups only answer for items in the client's cache;
-- an item the client doesn't know goes to Other. Crafted = a recipe one of
-- your characters knows makes it (the profession GoldLedger credited).
-- Flipped (non-stackable items only, decided 2026-10-31): sold after the same
-- item (by name) was bought on the AH by any of your characters, unit for
-- unit, oldest first, purchases up to the sale day. Stackables are never
-- flipped until crafts record the mats they use (a mat bought for crafting
-- would make gathered mats look flipped).

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL

local IncomeReport = {}
PocketCFO_PnL.IncomeReport = IncomeReport

local MAX_CHART_BARS = 30
local SECONDS_PER_DAY = 86400

IncomeReport.PERIODS = {
    { key = "today", label = "Today",   days = 1 },
    { key = "7",     label = "7 Days",  days = 7 },
    { key = "30",    label = "30 Days", days = 30 },
    { key = "all",   label = "All",     days = nil },
}
IncomeReport.DEFAULT_PERIOD = "7"

local CATEGORY_LABELS = {
    order_patron   = "Patron Orders",
    order_personal = "Personal Orders",
    order_public   = "Public Orders",
    order_guild    = "Guild Orders",
    order_unknown  = "Crafting Orders",
    auction        = "Auction House",
    vendor         = "Vendor",
    trade          = "Trade",
    mail           = "Mail",
    -- Split 2026-10-27 (gold is never called "loot" on its own); older
    -- combined rows were moved over 2026-10-31.
    looted         = "Looted Gold",
    quest          = "Quest Rewards",
    -- Spending categories (2026-10-27)
    repair          = "Repairs",
    training        = "Training",
    flight          = "Flight Paths",
    auction_buy     = "AH Purchases",
    auction_deposit = "AH Deposits",
    services        = "Bank, Barber & Transmog",
    guild_bank      = "Guild Bank",
    other          = "Unknown",
}

local EXCLUDED_CATEGORIES = {
    transfer = true,
}

-- Personal spending (2026-11-02): categories "personal:<original>" (core
-- GoldLedger) are left out of every total, row and bar, and listed on their
-- own in model.personal. Returns the original category, or nil.
local function PersonalOriginal(category)
    local goldLedger = PocketCFO:GetModule("GoldLedger", true)
    return goldLedger and goldLedger.PersonalOriginal and goldLedger:PersonalOriginal(category) or nil
end

-- ---------------------------------------------------------------------------
-- Dates (noon anchors so daylight saving changes never skip or repeat a day)
-- ---------------------------------------------------------------------------

local function NoonOf(year, month, day)
    return time({ year = year, month = month, day = day, hour = 12 })
end

local function TodayNoon()
    local t = date("*t")
    return NoonOf(t.year, t.month, t.day)
end

local function DayKeyAt(timestamp)
    return date("%Y-%m-%d", timestamp)
end

local function ParseDayKey(dayKey)
    local y, m, d = string.match(tostring(dayKey), "^(%d+)-(%d+)-(%d+)$")
    if not y then
        return nil
    end
    return NoonOf(tonumber(y), tonumber(m), tonumber(d))
end

local function DayKeysFor(days, ledgerDays)
    local today = TodayNoon()
    local count = days
    if not count then
        local earliest = today
        for dayKey in pairs(ledgerDays) do
            local noon = ParseDayKey(dayKey)
            if noon and noon < earliest then
                earliest = noon
            end
        end
        count = math.floor((today - earliest) / SECONDS_PER_DAY + 0.5) + 1
    end
    local keys = {}
    for offset = count - 1, 0, -1 do
        keys[#keys + 1] = DayKeyAt(today - offset * SECONDS_PER_DAY)
    end
    return keys
end

-- Shared with OrderReport: the day keys covered by a period ("all" starts at
-- the earliest day present in ledgerDays).
function IncomeReport:GetDayKeys(periodDays, ledgerDays)
    return DayKeysFor(periodDays, ledgerDays or {})
end

-- Shared with OrderReport and GoldPerHourReport: is this character's data in
-- the view? A picked toon shows only that toon; "All toons" shows only
-- characters on the Gold window's list that are checked (unchecked and
-- removed characters are left out; GoldTracker:IsShown).
function IncomeReport:IncludesCharacter(guid, characterGUID)
    if characterGUID then
        return guid == characterGUID
    end
    local tracker = PocketCFO:GetModule("GoldTracker", true)
    if not (tracker and tracker.IsShown) then
        return true
    end
    return tracker:IsShown(guid)
end

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------

function IncomeReport:GetCategoryLabel(category)
    return CATEGORY_LABELS[category] or tostring(category)
end

function IncomeReport:GetProfessionLabel(professionKey)
    if professionKey == nil or professionKey == "none" then
        return "No profession"
    end
    -- Gathering keys that are not in the profession registry.
    if professionKey == "fishing" then
        return "Fishing"
    end
    local registry = PocketCFO.ProfessionRegistry
    local config = registry and registry.GetProfessionConfig
        and registry:GetProfessionConfig(tonumber(professionKey))
    return config and config.name or tostring(professionKey)
end

-- ---------------------------------------------------------------------------
-- Model
-- ---------------------------------------------------------------------------

local function GetPeriod(periodKey)
    for _, period in ipairs(IncomeReport.PERIODS) do
        if period.key == periodKey then
            return period
        end
    end
    return IncomeReport.PERIODS[2]
end

function IncomeReport:GetPeriod(periodKey)
    return GetPeriod(periodKey)
end

local function SortedList(map, labelFn)
    local list = {}
    for key, copper in pairs(map) do
        list[#list + 1] = { key = key, label = labelFn(key), copper = copper }
    end
    table.sort(list, function(a, b)
        if a.copper ~= b.copper then
            return a.copper > b.copper
        end
        return a.label < b.label
    end)
    return list
end

local function SortedItems(itemMap)
    local items = {}
    for itemName, entry in pairs(itemMap or {}) do
        items[#items + 1] = { label = itemName, copper = entry.copper, quantity = entry.quantity }
    end
    table.sort(items, function(a, b)
        if a.copper ~= b.copper then
            return a.copper > b.copper
        end
        return a.label < b.label
    end)
    return items
end

local function BuildChartBuckets(daily)
    local bucketSize = math.max(1, math.ceil(#daily / MAX_CHART_BARS))
    local buckets = {}
    local index = 1
    while index <= #daily do
        local bucket = { firstDay = daily[index].dayKey, copper = 0, byCategory = {} }
        local last = math.min(#daily, index + bucketSize - 1)
        for i = index, last do
            local day = daily[i]
            bucket.lastDay = day.dayKey
            bucket.copper = bucket.copper + day.copper
            for category, copper in pairs(day.byCategory) do
                bucket.byCategory[category] = (bucket.byCategory[category] or 0) + copper
            end
        end
        if bucket.firstDay == bucket.lastDay then
            bucket.label = bucket.firstDay
        else
            bucket.label = bucket.firstDay .. " to " .. bucket.lastDay
        end
        buckets[#buckets + 1] = bucket
        index = last + 1
    end
    return buckets
end

-- Returns:
-- { total, period, sources = { { key, label, copper, share, expandable,
--     showProfessions, professions = {...}, items = { { label, copper, quantity } } } },
--   chart = { { label, copper, byCategory } } }
-- Gold rows from the Item Ledger, grouped as days[dayKey][guid] = { rows },
-- plus every day with any gold either way (the "All" period starts at the
-- earliest one, as before). Month rows (older than 13 months) are filed on
-- the 1st of their month.
local function GoldDays(dir)
    local itemLedger = PocketCFO.ItemLedger
    local days, anyDays = {}, {}
    if not itemLedger then
        return days, anyDays, {}
    end
    local goldRows = itemLedger:GetRows({ kind = "gold" })
    for _, found in ipairs(goldRows) do
        local dayKey = #found.period == 7 and (found.period .. "-01") or found.period
        anyDays[dayKey] = true
        if found.row.dir == dir then
        local character = itemLedger:GetCharacter(found.row.c)
        local guid = character and character.guid or tostring(found.row.c)
        local day = days[dayKey] or {}
        days[dayKey] = day
        local list = day[guid] or {}
        day[guid] = list
        list[#list + 1] = found.row
        end
    end
    return days, anyDays, goldRows
end

-- ---------------------------------------------------------------------------
-- Auction House groups (2026-10-31)
-- ---------------------------------------------------------------------------

local ITEM_CLASS = Enum and Enum.ItemClass or {}
local CLASS = {
    consumable = ITEM_CLASS.Consumable or 0,
    container = ITEM_CLASS.Container or 1,
    weapon = ITEM_CLASS.Weapon or 2,
    gem = ITEM_CLASS.Gem or 3,
    armor = ITEM_CLASS.Armor or 4,
    reagent = ITEM_CLASS.Reagent or 5,
    tradegoods = ITEM_CLASS.Tradegoods or 7,
    enhancement = ITEM_CLASS.ItemEnhancement or 8,
    recipe = ITEM_CLASS.Recipe or 9,
    misc = ITEM_CLASS.Miscellaneous or 15,
    battlepet = ITEM_CLASS.Battlepet or 17,
    profession = ITEM_CLASS.Profession or 19,
}
-- Crafting material rows (2026-10-31, Brian: every material type gets its
-- own row): one per type in the game's own list (Enum.ItemTradeGoodsSubclass,
-- read from the client), named as below or from the game's type name.
-- A type not on the game's list goes to "Other".
local MATERIAL_LABELS = {
    Herb = "Herbs",
    MetalAndStone = "Ore & metal",
    Leather = "Leather",
    Cloth = "Cloth",
    Cooking = "Fish & meat",
    Enchanting = "Enchanting",
    Jewelcrafting = "Jewelcrafting",
    Inscription = "Inscription",
    Parts = "Parts",
    Elemental = "Elemental",
    Other = "Other",
    OptionalReagents = "Optional reagents",
    FinishingReagents = "Finishing reagents",
    Tradegoods = "Trade goods",
}
local MATERIAL_SUBS = {}
do
    local trade = Enum and Enum.ItemTradeGoodsSubclass
    if type(trade) == "table" then
        for name, value in pairs(trade) do
            if type(value) == "number" then
                -- "MetalAndStone" -> "Metal And Stone" when there's no label above.
                local label = MATERIAL_LABELS[name] or tostring(name):gsub("(%l)(%u)", "%1 %2")
                MATERIAL_SUBS[value] = { key = string.lower(tostring(name)), label = label }
            end
        end
    else
        -- No list from the client: the common types by number.
        MATERIAL_SUBS = {
            [1] = { key = "parts", label = "Parts" }, [4] = { key = "jewelcrafting", label = "Jewelcrafting" },
            [5] = { key = "cloth", label = "Cloth" }, [6] = { key = "leather", label = "Leather" },
            [7] = { key = "metalandstone", label = "Ore & metal" }, [8] = { key = "cooking", label = "Fish & meat" },
            [9] = { key = "herb", label = "Herbs" }, [10] = { key = "elemental", label = "Elemental" },
            [11] = { key = "other", label = "Other" }, [12] = { key = "enchanting", label = "Enchanting" },
            [16] = { key = "inscription", label = "Inscription" },
        }
    end
end
local MISC = Enum and Enum.ItemMiscellaneousSubclass or {}
local MISC_PET = MISC.CompanionPet or 2
local MISC_MOUNT = MISC.Mount or 5
local ENCHANTING_KEY = "333"

local GROUPS = {
    { key = "gear",         label = "Gear" },
    { key = "materials",    label = "Crafting materials" },
    { key = "consumables",  label = "Consumables" },
    { key = "enhancements", label = "Item enhancements" },
    { key = "recipes",      label = "Recipes" },
    { key = "collectibles", label = "Collectibles" },
    { key = "other",        label = "Other" },
}
local GROUP_LABELS = {}
for _, group in ipairs(GROUPS) do
    GROUP_LABELS[group.key] = group.label
end

local itemInfoCache = {}   -- [name] = { classID, subclassID, stack, itemID, partial }

local getItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local getItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

-- Item ID for a name with no saved ID: core GoldLedger:ResolveItemID (known
-- IDs, name lookups, your recipes, items that came into your bags).
local function ResolveItemID(name)
    local goldLedger = PocketCFO:GetModule("GoldLedger", true)
    return goldLedger and goldLedger.ResolveItemID and goldLedger:ResolveItemID(name) or nil
end

-- What the client knows about a sold / bought item, or nil.
-- Full info (GetItemInfo by ID or name) gives the stack size too; when only
-- GetItemInfoInstant by ID answers, the type is known but the stack size
-- isn't (partial: never counted as a flip, asked again next time).
local function ItemInfo(name, itemID)
    if not name then
        return nil
    end
    local cached = itemInfoCache[name]
    if cached and not cached.partial then
        return cached
    end
    itemID = itemID or (cached and cached.itemID) or ResolveItemID(name)
    local ok, itemName, link, _, _, _, _, _, stack, _, _, _, classID, subclassID
    if getItemInfo and itemID then
        ok, itemName, link, _, _, _, _, _, stack, _, _, _, classID, subclassID = pcall(getItemInfo, itemID)
    end
    if not (ok and itemName) and getItemInfo then
        ok, itemName, link, _, _, _, _, _, stack, _, _, _, classID, subclassID = pcall(getItemInfo, name)
    end
    if ok and itemName and classID then
        local info = {
            classID = classID,
            subclassID = subclassID,
            stack = tonumber(stack) or 1,
            itemID = itemID or (type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil),
        }
        itemInfoCache[name] = info
        return info
    end
    if not itemID then
        return nil
    end
    -- Ask the client to load it so the next look has full info (Theoretical).
    if C_Item and C_Item.RequestLoadItemDataByID then
        pcall(C_Item.RequestLoadItemDataByID, itemID)
    end
    if getItemInfoInstant then
        local okInstant, instantID, _, _, _, _, instantClass, instantSub = pcall(getItemInfoInstant, itemID)
        if okInstant and instantID and instantClass then
            local info = { classID = instantClass, subclassID = instantSub, stack = nil, itemID = itemID, partial = true }
            itemInfoCache[name] = info
            return info
        end
    end
    return nil
end

local function IsToy(itemID)
    if not itemID or not C_ToyBox or not C_ToyBox.GetToyInfo then
        return false
    end
    local ok, toyItemID = pcall(C_ToyBox.GetToyInfo, itemID)
    return ok and toyItemID ~= nil
end

-- Group of a sold item: groupKey, subKey, subLabel.
function IncomeReport:ClassifySale(name, itemID, professionKey, flipped)
    local info = ItemInfo(name, itemID)
    if not info then
        return "other", "items", nil
    end
    local classID, subclassID = info.classID, info.subclassID
    local group
    if classID == CLASS.weapon or classID == CLASS.armor or classID == CLASS.profession or classID == CLASS.container then
        group = "gear"
    elseif classID == CLASS.tradegoods or classID == CLASS.reagent then
        group = "materials"
    elseif classID == CLASS.consumable then
        group = "consumables"
    elseif classID == CLASS.gem or classID == CLASS.enhancement then
        group = "enhancements"
    elseif classID == CLASS.recipe then
        group = "recipes"
    elseif classID == CLASS.battlepet or (classID == CLASS.misc and (subclassID == MISC_PET or subclassID == MISC_MOUNT))
        or IsToy(info.itemID) then
        group = "collectibles"
    else
        group = "other"
    end
    if flipped then
        return group, "flipped", "Flipped"
    end
    local crafted = professionKey and professionKey ~= "none"
    if group == "gear" then
        if crafted then
            return group, "crafted:" .. professionKey, "Crafted: " .. self:GetProfessionLabel(professionKey)
        end
        return group, "looted", "Looted"
    elseif group == "materials" then
        local sub = classID == CLASS.tradegoods and MATERIAL_SUBS[subclassID] or nil
        if sub then
            return group, sub.key, sub.label
        end
        return group, "other", "Other"
    elseif group == "consumables" then
        if crafted then
            return group, "crafted:" .. professionKey, "Crafted: " .. self:GetProfessionLabel(professionKey)
        end
        return group, "other", "Other"
    elseif group == "enhancements" then
        if classID == CLASS.gem then
            return group, "gems", "Gems"
        elseif professionKey == ENCHANTING_KEY then
            return group, "enchants", "Enchants"
        end
        return group, "other", "Other"
    elseif group == "collectibles" then
        if classID == CLASS.battlepet or (classID == CLASS.misc and subclassID == MISC_PET) then
            return group, "pets", "Pets"
        elseif classID == CLASS.misc and subclassID == MISC_MOUNT then
            return group, "mounts", "Mounts"
        end
        return group, "toys", "Toys"
    end
    return group, "items", nil
end

local function RowDayKey(found)
    return #found.period == 7 and (found.period .. "-01") or found.period
end

-- Flipped share of every AH sale row (all time, all characters, so a sale is
-- matched against every earlier purchase only once): { [row] = fraction }.
function IncomeReport:FindFlips(goldRows)
    local purchases = {}   -- [name] = { { day, units } }
    local sales = {}
    for _, found in ipairs(goldRows) do
        local row = found.row
        if row.src and row.cat == "auction_buy" and row.dir == "out" then
            local list = purchases[row.src] or {}
            purchases[row.src] = list
            list[#list + 1] = { day = RowDayKey(found), units = tonumber(row.units) or 1 }
        elseif row.src and row.cat == "auction" and row.dir == "in" then
            sales[#sales + 1] = { day = RowDayKey(found), row = row }
        end
    end
    local flips = {}
    if next(purchases) == nil then
        return flips
    end
    table.sort(sales, function(a, b) return a.day < b.day end)
    local used = {}   -- [name] = units already matched
    for _, sale in ipairs(sales) do
        local name = sale.row.src
        local list = purchases[name]
        if list then
            local info = ItemInfo(name, sale.row.iid)
            if info and info.stack == 1 then
                local bought = 0
                for _, purchase in ipairs(list) do
                    if purchase.day <= sale.day then
                        bought = bought + purchase.units
                    end
                end
                local units = tonumber(sale.row.units) or 1
                local take = math.min(units, bought - (used[name] or 0))
                if take > 0 then
                    used[name] = (used[name] or 0) + take
                    flips[sale.row] = take / math.max(1, units)
                end
            end
        end
    end
    return flips
end

local function SortByCopper(list)
    table.sort(list, function(a, b)
        if a.copper ~= b.copper then
            return a.copper > b.copper
        end
        return tostring(a.label) < tostring(b.label)
    end)
end

-- Diagnostics (/mcg ahgroups, 2026-10-31): every item sold on the AH (all
-- time, all characters) with what the game says about it, three ways, and
-- the group it lands in. For finding why items end up in Other.
function IncomeReport:BuildAuctionGroupsReport()
    local itemLedger = PocketCFO.ItemLedger
    local lines = {}
    if not itemLedger then
        return "Item Ledger not loaded."
    end
    local byName = {}
    for _, found in ipairs(itemLedger:GetRows({ kind = "gold" })) do
        local row = found.row
        if row.cat == "auction" and row.dir == "in" then
            local name = row.src or "(no item name)"
            local entry = byName[name] or { sales = 0, copper = 0, iid = nil, prof = nil }
            byName[name] = entry
            entry.sales = entry.sales + 1
            entry.copper = entry.copper + (tonumber(row.qty) or 0)
            entry.iid = entry.iid or row.iid
            entry.prof = entry.prof or row.prof
        end
    end
    local names = {}
    for name in pairs(byName) do
        names[#names + 1] = name
    end
    table.sort(names)
    local function Info(lookup)
        if not lookup or not getItemInfo then
            return "-"
        end
        local ok, itemName, _, _, _, _, _, _, stack, _, _, _, classID, subclassID = pcall(getItemInfo, lookup)
        if not ok or not itemName then
            return "not known"
        end
        return string.format("class=%s sub=%s stack=%s", tostring(classID), tostring(subclassID), tostring(stack))
    end
    local function Instant(lookup)
        local getInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
        if not lookup or not getInstant then
            return "-"
        end
        local ok, itemID, _, _, _, _, classID, subclassID = pcall(getInstant, lookup)
        if not ok or not itemID then
            return "not known"
        end
        return string.format("id=%s class=%s sub=%s", tostring(itemID), tostring(classID), tostring(subclassID))
    end
    local inOther = 0
    for _, name in ipairs(names) do
        local entry = byName[name]
        itemInfoCache[name] = nil   -- ask the game fresh
        local group, sub = self:ClassifySale(name, entry.iid, entry.prof or "none", false)
        if group == "other" then
            inOther = inOther + 1
        end
        lines[#lines + 1] = string.format("%-34s -> %s / %s", name, group, tostring(sub))
        lines[#lines + 1] = string.format("    saved id=%s found id=%s prof=%s sales=%d", tostring(entry.iid),
            tostring(ResolveItemID(name)), tostring(entry.prof), entry.sales)
        lines[#lines + 1] = "    by saved id:  " .. Info(entry.iid)
        lines[#lines + 1] = "    by name:      " .. Info(name)
        lines[#lines + 1] = "    instant name: " .. Instant(name)
    end
    table.insert(lines, 1, string.format("%d items sold, %d in Other", #names, inOther))
    table.insert(lines, 2, string.format("Enum.ItemClass: Tradegoods=%s Profession=%s Gem=%s ItemEnhancement=%s",
        tostring(ITEM_CLASS.Tradegoods), tostring(ITEM_CLASS.Profession), tostring(ITEM_CLASS.Gem),
        tostring(ITEM_CLASS.ItemEnhancement)))
    table.insert(lines, 3, "")
    return table.concat(lines, "\n")
end

-- Builds source.groups for the Auction House source from its sale parts:
-- parts = { { name, units, copper, professionKey, iid, flipped } }.
function IncomeReport:BuildAuctionGroups(parts)
    local groups = {}
    for _, part in ipairs(parts) do
        local groupKey, subKey, subLabel = self:ClassifySale(part.name, part.iid, part.professionKey, part.flipped)
        local group = groups[groupKey]
        if not group then
            group = { key = groupKey, label = GROUP_LABELS[groupKey] or groupKey, copper = 0, subs = {} }
            groups[groupKey] = group
        end
        group.copper = group.copper + part.copper
        local sub = group.subs[subKey]
        if not sub then
            sub = { key = subKey, label = subLabel, copper = 0, itemMap = {} }
            group.subs[subKey] = sub
        end
        sub.copper = sub.copper + part.copper
        local entry = sub.itemMap[part.name] or { copper = 0, quantity = 0 }
        sub.itemMap[part.name] = entry
        entry.copper = entry.copper + part.copper
        entry.quantity = entry.quantity + part.units
    end
    local list = {}
    for _, group in pairs(groups) do
        local subs = {}
        for _, sub in pairs(group.subs) do
            sub.items = {}
            for itemName, entry in pairs(sub.itemMap) do
                sub.items[#sub.items + 1] = { label = itemName, copper = entry.copper, quantity = entry.quantity }
            end
            SortByCopper(sub.items)
            sub.itemMap = nil
            subs[#subs + 1] = sub
        end
        SortByCopper(subs)
        -- Only plain items (Recipes, Other): list them right under the group.
        if #subs == 1 and subs[1].key == "items" then
            group.items = subs[1].items
            group.subs = {}
        else
            -- Items with no second level of their own sit in an "Items" row.
            for _, sub in ipairs(subs) do
                sub.label = sub.label or "Items"
            end
            group.subs = subs
            group.items = {}
        end
        list[#list + 1] = group
    end
    SortByCopper(list)
    return list
end

function IncomeReport:Build(periodKey, characterGUID, mode)
    local period = GetPeriod(periodKey)
    local ledgerDays, anyDays, goldRows = GoldDays((mode == "spend") and "out" or "in")
    local isIncome = mode ~= "spend"
    local flips = isIncome and self:FindFlips(goldRows) or {}
    local auctionParts = {}

    local byCategory = {}
    local byCategoryProfession = {}
    local byCategoryItem = {}
    local unnamedSpend = {}   -- [category][professionKey] = { copper, quantity }
    local personalMap = {}    -- [category .. "|" .. item] = { name, category, copper, quantity }
    local personalTotal = 0
    local daily = {}
    local total = 0

    for _, dayKey in ipairs(DayKeysFor(period.days, anyDays)) do
        local dayEntry = { dayKey = dayKey, copper = 0, byCategory = {} }
        local day = ledgerDays[dayKey]
        if day then
            for guid, rows in pairs(day) do
                if self:IncludesCharacter(guid, characterGUID) then
                    for _, row in ipairs(rows) do
                        local category = row.cat
                        local copper = tonumber(row.qty) or 0
                        if PersonalOriginal(category) then
                            -- Personal spending: listed on its own, never counted.
                            if not isIncome and copper > 0 then
                                personalTotal = personalTotal + copper
                                local name = row.src or "Unknown item"
                                local key = category .. "|" .. name
                                local entry = personalMap[key]
                                if not entry then
                                    entry = { name = name, category = category, copper = 0, quantity = 0 }
                                    personalMap[key] = entry
                                end
                                entry.copper = entry.copper + copper
                                entry.quantity = entry.quantity + (tonumber(row.units) or 0)
                            end
                        elseif not EXCLUDED_CATEGORIES[category] and copper > 0 then
                            local professionKey = row.prof or "none"
                            total = total + copper
                            dayEntry.copper = dayEntry.copper + copper
                            dayEntry.byCategory[category] = (dayEntry.byCategory[category] or 0) + copper
                            byCategory[category] = (byCategory[category] or 0) + copper
                            local split = byCategoryProfession[category] or {}
                            byCategoryProfession[category] = split
                            split[professionKey] = (split[professionKey] or 0) + copper
                            if isIncome and category == "auction" and row.src then
                                local units = tonumber(row.units) or 0
                                local share = flips[row] or 0
                                local flippedCopper = math.floor(copper * share + 0.5)
                                local flippedUnits = math.floor(units * share + 0.5)
                                local base = { name = row.src, professionKey = professionKey, iid = row.iid }
                                if flippedCopper > 0 then
                                    auctionParts[#auctionParts + 1] = { name = base.name, professionKey = base.professionKey,
                                        iid = base.iid, copper = flippedCopper, units = flippedUnits, flipped = true }
                                end
                                if copper - flippedCopper > 0 then
                                    auctionParts[#auctionParts + 1] = { name = base.name, professionKey = base.professionKey,
                                        iid = base.iid, copper = copper - flippedCopper, units = units - flippedUnits }
                                end
                            elseif isIncome and category == "auction" then
                                -- Sale with no item name: listed under Other.
                                auctionParts[#auctionParts + 1] = { name = "Unknown item", copper = copper, units = 0 }
                            end
                            if row.src then
                                local byProfession = byCategoryItem[category] or {}
                                byCategoryItem[category] = byProfession
                                local items = byProfession[professionKey] or {}
                                byProfession[professionKey] = items
                                local entry = items[row.src] or { copper = 0, quantity = 0 }
                                items[row.src] = entry
                                entry.copper = entry.copper + copper
                                entry.quantity = entry.quantity + (tonumber(row.units) or 0)
                            elseif not isIncome then
                                -- Spending with no item (older history, or gold no
                                -- hook explained): held aside for "Unknown item".
                                -- No item count exists, so count the purchases
                                -- (one per gold charge), at least 1 (2026-11-01).
                                local byProfession = unnamedSpend[category] or {}
                                unnamedSpend[category] = byProfession
                                local entry = byProfession[professionKey] or { copper = 0, quantity = 0 }
                                byProfession[professionKey] = entry
                                entry.copper = entry.copper + copper
                                entry.quantity = entry.quantity + math.max(tonumber(row.n) or 0, 1)
                            end
                        end
                    end
                end
            end
        end
        daily[#daily + 1] = dayEntry
    end

    -- Spending: a category that lists named items also lists what has no name
    -- as "Unknown item", so the list adds up to the total. Categories with no
    -- named items at all (flights) stay unexpanded (2026-11-01).
    for category, byProfession in pairs(unnamedSpend) do
        local named = byCategoryItem[category]
        if named then
            for professionKey, unknown in pairs(byProfession) do
                local items = named[professionKey] or {}
                named[professionKey] = items
                items["Unknown item"] = { copper = unknown.copper, quantity = unknown.quantity }
            end
        end
    end

    local sources = SortedList(byCategory, function(key) return self:GetCategoryLabel(key) end)
    -- "Unknown" always sits at the bottom.
    for index, source in ipairs(sources) do
        if source.key == "other" then
            table.remove(sources, index)
            sources[#sources + 1] = source
            break
        end
    end
    for _, source in ipairs(sources) do
        source.share = total > 0 and (source.copper / total) or 0
        source.professions = SortedList(byCategoryProfession[source.key] or {},
            function(key) return self:GetProfessionLabel(key) end)
        local onlyNone = #source.professions == 1 and source.professions[1].key == "none"
        source.showProfessions = #source.professions > 0 and not onlyNone

        -- Items stay grouped under the profession they were credited to.
        local itemsByProfession = byCategoryItem[source.key] or {}
        local itemCount = 0
        for _, profession in ipairs(source.professions) do
            profession.items = SortedItems(itemsByProfession[profession.key])
            itemCount = itemCount + #profession.items
        end
        -- Single "No profession" source: its items list directly under the source.
        source.items = onlyNone and source.professions[1].items or {}

        source.expandable = source.showProfessions or itemCount > 0

        -- Auction House sales: grouped by what was sold (2026-10-31).
        if isIncome and source.key == "auction" then
            source.groups = self:BuildAuctionGroups(auctionParts)
            source.showProfessions = false
            source.items = {}
            source.expandable = #source.groups > 0
        end
    end

    local personalItems = {}
    for _, entry in pairs(personalMap) do
        personalItems[#personalItems + 1] = entry
    end
    table.sort(personalItems, function(a, b)
        if a.copper ~= b.copper then
            return a.copper > b.copper
        end
        return a.name < b.name
    end)

    return {
        mode = (mode == "spend") and "spend" or "income",
        period = period,
        total = total,
        sources = sources,
        chart = (#daily > 1) and BuildChartBuckets(daily) or nil,
        -- Spend mode only: { total, items = { { name, category, copper, quantity } } }.
        personal = { total = personalTotal, items = personalItems },
    }
end

--- Marks spending on one item personal or back to business, for what the
-- view shows: the period and the characters in view (2026-11-02).
-- category = the row's category now ("vendor", or "personal:vendor").
function IncomeReport:SetPersonal(itemName, category, periodKey, characterGUID, isPersonal)
    local goldLedger = PocketCFO:GetModule("GoldLedger", true)
    local itemLedger = PocketCFO.ItemLedger
    if not goldLedger or not goldLedger.SetPersonal or not itemLedger then
        return 0
    end
    local period = GetPeriod(periodKey)
    local from, to
    if period.days then
        local today = TodayNoon()
        from = DayKeyAt(today - (period.days - 1) * SECONDS_PER_DAY)
        to = DayKeyAt(today)
    end
    -- Characters in view (same rule as Build: picked toon, or checked toons).
    local characters = {}
    local index = 1
    local character = itemLedger:GetCharacter(index)
    while character do
        if character.guid and self:IncludesCharacter(character.guid, characterGUID) then
            characters[character.guid] = true
        end
        index = index + 1
        character = itemLedger:GetCharacter(index)
    end
    return goldLedger:SetPersonal(itemName, category, from, to, characters, isPersonal)
end
