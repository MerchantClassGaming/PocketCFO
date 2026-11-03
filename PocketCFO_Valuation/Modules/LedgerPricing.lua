-- PocketCFO_Valuation/Modules/LedgerPricing.lua
-- Prices Item Ledger entries at the moment they're written ("value at the
-- time", claude/Item_Ledger_Design.md decision 3, Brian 2026-10-30).
--
-- Core's ItemLedger announces each entry (MCG_ITEM_LEDGER_ENTRY); this module
-- prices it with ValuationService (same value the tooltip shows) and writes
-- the unit value back with ItemLedger:SetValue. Tier 2 calls into core, core
-- never calls Tier 2 (CLAUDE.md). This addon is loaded at login by core's
-- AddonLoader, so almost every entry is priced as it arrives; entries written
-- before it was ready this session are priced when it starts.
-- Items with no price stay unpriced (never zero). Currencies are priced only
-- where a currency rule exists (none yet).
--
-- Flavor: Both.

local PocketCFO_Valuation = _G.PocketCFO_Valuation
local LedgerPricing = PocketCFO_Valuation:NewModule("LedgerPricing")

local messenger = LibStub and LibStub("AceEvent-3.0", true) and LibStub("AceEvent-3.0"):Embed({}) or nil

local function UnitValue(entry)
    local valuationService = PocketCFO_Valuation:GetModule("ValuationService", true)
    if not valuationService or type(entry) ~= "table" or not entry.iid then
        return nil
    end
    local ok, result
    if entry.kind == "item" then
        ok, result = pcall(valuationService.GetItemValue, valuationService, { itemID = entry.iid, itemLink = entry.link })
    elseif entry.kind == "currency" then
        ok, result = pcall(valuationService.GetCurrencyValue, valuationService, entry.iid)
    else
        return nil
    end
    if ok and type(result) == "table" and not result.unresolved then
        return tonumber(result.valuePerUnit or result.value)
    end
    -- Gray (poor) items: their vendor price, same rule as ActivityRuns
    -- (2026-10-30, so ledger values match the Gathering tab's).
    if entry.kind == "item" then
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local okInfo, name, _, rarity, _, _, _, _, _, _, _, sellPrice = pcall(getInfo, entry.link or entry.iid)
        if okInfo and name and tonumber(rarity) == 0 and tonumber(sellPrice) and sellPrice > 0 then
            return tonumber(sellPrice)
        end
    end
    return nil
end

function LedgerPricing:Price(entry)
    local ledger = _G.PocketCFO and _G.PocketCFO.ItemLedger
    if not ledger or type(entry) ~= "table" or entry.val ~= nil then
        return
    end
    local value = UnitValue(entry)
    if value then
        ledger:SetValue(entry, value)
    end
end

function LedgerPricing:OnEnable()
    if messenger and not self.listening then
        messenger:RegisterMessage("MCG_ITEM_LEDGER_ENTRY", function(_, entry)
            LedgerPricing:Price(entry)
        end)
        self.listening = true
    end
    local ledger = _G.PocketCFO and _G.PocketCFO.ItemLedger
    if ledger and ledger.TakeSessionUnpriced then
        ledger.pricingReady = true
        for _, entry in ipairs(ledger:TakeSessionUnpriced()) do
            self:Price(entry)
        end
    end
end
