-- PocketCFO_PnL/Services/OrderReport.lua
-- Builds the Orders tab model from PocketCFO_Orders' OrdersLedger daily totals.
-- Loads PocketCFO_Orders on demand (it owns the data).

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL

local OrderReport = {}
PocketCFO_PnL.OrderReport = OrderReport

local ORDER_TYPE_LABELS = {
    patron   = "Patron Orders",
    personal = "Personal Orders",
    public   = "Public Orders",
    guild    = "Guild Orders",
    unknown  = "Other Orders",
}

local PART_FIELDS = { "orders", "goldPaid", "rewards", "resourcefulness", "mats", "earned" }

local function NewTotals()
    local totals = {}
    for _, field in ipairs(PART_FIELDS) do
        totals[field] = 0
    end
    return totals
end

local function AddInto(totals, row)
    for _, field in ipairs(PART_FIELDS) do
        totals[field] = totals[field] + (tonumber(row[field]) or 0)
    end
end

local function GetOrdersLedger()
    local loader = PocketCFO:GetModule("AddonLoader", true)
    if loader then
        loader:SafeLoad("PocketCFO_Orders")
    end
    local orders = _G.PocketCFO_Orders
    return orders and orders.GetModule and orders:GetModule("OrdersLedger", true)
end

-- Returns:
-- { available, period, totals = {orders, goldPaid, rewards, resourcefulness, mats, earned},
--   professions = { { key, label, totals, types = { { key, label, totals } } } } }
-- hiddenTypes (optional): { [typeKey] = true } order types to leave out.
function OrderReport:Build(periodKey, characterGUID, hiddenTypes)
    hiddenTypes = hiddenTypes or {}
    local incomeReport = PocketCFO_PnL.IncomeReport
    local period = incomeReport:GetPeriod(periodKey)
    local ledger = GetOrdersLedger()
    if not ledger then
        return { available = false, period = period, totals = NewTotals(), professions = {} }
    end
    local ledgerDays = ledger:GetDays() or {}

    local totals = NewTotals()
    local byProfession = {}

    for _, dayKey in ipairs(incomeReport:GetDayKeys(period.days, ledgerDays)) do
        local day = ledgerDays[dayKey]
        if day then
            for guid, professions in pairs(day) do
                if not characterGUID or guid == characterGUID then
                    for professionKey, types in pairs(professions) do
                        for typeKey, row in pairs(types) do
                            if not hiddenTypes[typeKey] then
                                local profession = byProfession[professionKey]
                                if not profession then
                                    profession = { key = professionKey, totals = NewTotals(), types = {} }
                                    byProfession[professionKey] = profession
                                end
                                AddInto(totals, row)
                                AddInto(profession.totals, row)
                                profession.types[typeKey] = profession.types[typeKey] or NewTotals()
                                AddInto(profession.types[typeKey], row)
                            end
                        end
                    end
                end
            end
        end
    end

    local list = {}
    for professionKey, profession in pairs(byProfession) do
        profession.label = incomeReport:GetProfessionLabel(professionKey)
        local types = {}
        for typeKey, typeTotals in pairs(profession.types) do
            types[#types + 1] = { key = typeKey, label = ORDER_TYPE_LABELS[typeKey] or typeKey, totals = typeTotals }
        end
        table.sort(types, function(a, b)
            if a.totals.earned ~= b.totals.earned then
                return a.totals.earned > b.totals.earned
            end
            return a.label < b.label
        end)
        profession.types = types
        list[#list + 1] = profession
    end
    table.sort(list, function(a, b)
        if a.totals.earned ~= b.totals.earned then
            return a.totals.earned > b.totals.earned
        end
        return a.label < b.label
    end)

    return { available = true, period = period, totals = totals, professions = list }
end
