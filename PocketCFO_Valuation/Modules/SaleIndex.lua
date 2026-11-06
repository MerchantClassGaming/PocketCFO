-- PocketCFO_Valuation/Modules/SaleIndex.lua
-- Our own most recent AH sale of each item, as one quick lookup
-- (2026-11-04, value confidence and smart posting). A sale is real evidence
-- of what a buyer paid; a listing isn't.
--
-- Built in one pass and kept for REBUILD_SECONDS, so tooltips and the posting
-- list never search the sale records item by item. Sources (both core,
-- account-wide):
--   1. PocketCFO.db.global.ahListings, status "sold": exact item version
--      (configKey), unit price, sale time. 30-day retention. Theoretical how
--      reliably rows reach "sold".
--   2. Item Ledger gold income, category "auction" (13 months, by itemID,
--      not stat version): the latest day/month's average per unit, grossed
--      up for the 5% AH cut (income is what reached the mailbox).
-- Flavor: Both.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local SaleIndex = PocketCFO_Valuation:NewModule("SaleIndex")

local REBUILD_SECONDS = 5 * 60
local AH_CUT = 0.05

local function Now()
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

-- "YYYY-MM-DD" or "YYYY-MM" -> server time at the start of it (approximate).
local function PeriodTime(period)
    local y, m, d = tostring(period or ""):match("^(%d+)%-(%d+)%-?(%d*)$")
    if not y or type(time) ~= "function" then
        return nil
    end
    return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) or 1, hour = 12 })
end

function SaleIndex:Rebuild()
    local byConfigKey, byItemID = {}, {}
    local PocketCFO = _G.PocketCFO
    local listings = PocketCFO and PocketCFO.db and PocketCFO.db.global and PocketCFO.db.global.ahListings
    for _, row in pairs(type(listings) == "table" and listings or {}) do
        if type(row) == "table" and row.status == "sold" and row.configKey then
            local price = tonumber(row.unitPrice or row.postedPrice or row.buyout)
            local at = tonumber(row.closedAt) or 0
            local existing = byConfigKey[row.configKey]
            if price and price > 0 and (not existing or at > existing.at) then
                byConfigKey[row.configKey] = { price = price, at = at, source = "listing" }
            end
        end
    end

    local ledger = PocketCFO and PocketCFO.ItemLedger
    if ledger and type(ledger.GetRows) == "function" then
        local ok, rows = pcall(ledger.GetRows, ledger, { kind = "gold", dir = "in", cat = "auction" })
        local latest = {}
        for _, item in ipairs(ok and type(rows) == "table" and rows or {}) do
            local row, period = item.row, item.period
            local itemID = row and tonumber(row.iid)
            local units = tonumber(row and row.units) or 0
            if itemID and period and units > 0 then
                local entry = latest[itemID]
                if not entry or period > entry.period then
                    entry = { period = period, copper = 0, units = 0 }
                    latest[itemID] = entry
                end
                if period == entry.period then
                    entry.copper = entry.copper + (tonumber(row.qty) or 0)
                    entry.units = entry.units + units
                end
            end
        end
        for itemID, entry in pairs(latest) do
            if entry.units > 0 and entry.copper > 0 then
                byItemID[itemID] = {
                    price = entry.copper / entry.units / (1 - AH_CUT),
                    at = PeriodTime(entry.period) or 0,
                    source = "income",
                }
            end
        end
    end

    self.byConfigKey, self.byItemID, self.builtAt = byConfigKey, byItemID, Now()
end

-- Returns price (copper per unit), at (server time, approximate for income),
-- source ("listing" | "income"), or nil. Exact version first.
function SaleIndex:GetLastSale(configKey, itemID)
    if not self.builtAt or Now() - self.builtAt > REBUILD_SECONDS then
        local ok = pcall(self.Rebuild, self)
        if not ok then
            self.byConfigKey, self.byItemID, self.builtAt = {}, {}, Now()
        end
    end
    local sale = configKey and self.byConfigKey[configKey]
    if not sale then
        sale = tonumber(itemID) and self.byItemID[tonumber(itemID)]
    end
    if not sale then
        return nil
    end
    return sale.price, sale.at, sale.source
end
