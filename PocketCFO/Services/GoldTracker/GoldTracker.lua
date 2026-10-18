-- PocketCFO/Services/GoldTracker/GoldTracker.lua
-- Current gold per character and the warband bank (data only).
-- The Gold window (Balances + Income tabs) lives in PocketCFO_PnL
-- (UI/GoldWindow.lua); /mcg gold loads that addon and opens it.
--
-- Storage: PocketCFO_DB.global.gold
--   characters[characterGUID] = { name, realm, classFile, copper, updatedAt }
--   warband = { copper, updatedAt } | false
-- A character's balance is saved on login and whenever it changes;
-- characters not logged in recently keep their last known amount.
--
-- Warband bank gold: C_Bank.FetchDepositedMoney(Enum.BankType.Account) +
-- ACCOUNT_MONEY - confirmed in Blizzard 12.1.0 source (MoneyFrame.lua
-- MoneyTypeInfo["ACCOUNT"], BankFrame.lua). Theoretical: whether it returns
-- the balance away from a bank; the last known value is kept either way.
--
-- Sends AceEvent message "MCG_GOLD_BALANCES_CHANGED" after every save.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local GoldTracker = PocketCFO:NewModule("GoldTracker", "AceEvent-3.0")

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------

local function GoldDB()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    globalDB.gold = globalDB.gold or {}
    globalDB.gold.characters = globalDB.gold.characters or {}
    return globalDB.gold
end

local function Now()
    return (GetServerTime and GetServerTime()) or time()
end

function GoldTracker:SaveCharacterGold()
    local goldDB = GoldDB()
    local guid = UnitGUID and UnitGUID("player")
    if not goldDB or not guid or not GetMoney then
        return
    end
    local _, classFile = UnitClass("player")
    goldDB.characters[guid] = {
        name = UnitName("player"),
        realm = GetRealmName and GetRealmName() or nil,
        classFile = classFile,
        copper = GetMoney() or 0,
        updatedAt = Now(),
    }
end

function GoldTracker:SaveWarbandGold()
    local goldDB = GoldDB()
    if not goldDB or not C_Bank or type(C_Bank.FetchDepositedMoney) ~= "function"
        or not Enum or not Enum.BankType or not Enum.BankType.Account then
        return
    end
    local ok, copper = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
    copper = ok and tonumber(copper) or nil
    if copper then
        goldDB.warband = { copper = copper, updatedAt = Now() }
    end
end

function GoldTracker:Refresh()
    self:SaveCharacterGold()
    self:SaveWarbandGold()
end

function GoldTracker:OnMoneyChanged()
    self:Refresh()
    self:SendMessage("MCG_GOLD_BALANCES_CHANGED")
end

-- Read-only view for display code (PocketCFO_PnL). Callers must not modify it.
function GoldTracker:GetBalances()
    local goldDB = GoldDB()
    if not goldDB then
        return { characters = {} }
    end
    return {
        characters = goldDB.characters,
        warband = goldDB.warband or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Window (lives in PocketCFO_PnL)
-- ---------------------------------------------------------------------------

function GoldTracker:OpenWindow(tab)
    self:Refresh()
    local loader = PocketCFO:GetModule("AddonLoader", true)
    if not loader or not loader:SafeLoad("PocketCFO_PnL") then
        PocketCFO:Print("Could not load the gold window.")
        return
    end
    local pnl = _G.PocketCFO_PnL
    local window = pnl and pnl:GetModule("GoldWindow", true)
    if window then
        window:Toggle(tab)
    end
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function GoldTracker:OnEnable()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnMoneyChanged")
    self:RegisterEvent("PLAYER_MONEY", "OnMoneyChanged")
    self:RegisterEvent("ACCOUNT_MONEY", "OnMoneyChanged")
    -- No PLAYER_LOGOUT save: every logged-out character was being stored as
    -- 0 (Brian, 2026-10-12), so GetMoney() evidently returns 0 by logout.
    -- PLAYER_MONEY already saves every change while logged in.
    self:OnMoneyChanged()
end

local diagnostics = PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("gold", {
        name = "gold",
        description = "Show your gold: balances per character and where your income came from.",
        usage = "/mcg gold",
        category = "General",
        playerFacing = true,
    }, function()
        GoldTracker:OpenWindow("balances")
    end)
end
