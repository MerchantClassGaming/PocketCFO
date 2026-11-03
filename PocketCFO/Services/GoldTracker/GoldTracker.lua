-- PocketCFO/Services/GoldTracker/GoldTracker.lua
-- Current gold per character and the warband bank (data only).
-- The Gold window (Balances + Income tabs) lives in PocketCFO_PnL
-- (UI/GoldWindow.lua); /mcg gold loads that addon and opens it.
--
-- Storage: PocketCFO_DB.global.gold
--   characters[characterGUID] = { name, realm, classFile, copper, updatedAt }
--   warband = { copper, updatedAt } | false
--   hidden[characterGUID] = true   (unchecked in the Gold window's character
--                                   list; all data is still captured)
-- Removing a character drops it from characters (and hidden). Its history is
-- kept, but the Gold window only shows characters in this list, so it
-- disappears until that character logs in again and is saved here.
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
    globalDB.gold.hidden = globalDB.gold.hidden or {}
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
        hidden = goldDB.hidden,
    }
end

-- Hidden characters: left out of every Gold window view. Capture continues.
function GoldTracker:IsHidden(guid)
    local goldDB = GoldDB()
    return goldDB ~= nil and guid ~= nil and goldDB.hidden[guid] == true
end

function GoldTracker:SetHidden(guid, hidden)
    local goldDB = GoldDB()
    if not goldDB or not guid then
        return
    end
    goldDB.hidden[guid] = hidden and true or nil
    self:SendMessage("MCG_GOLD_BALANCES_CHANGED")
end

-- Is this character on the Gold window's list and checked?
function GoldTracker:IsShown(guid)
    local goldDB = GoldDB()
    return goldDB ~= nil and guid ~= nil and goldDB.characters[guid] ~= nil
        and not goldDB.hidden[guid]
end

-- Takes a character off the list until it logs in again. The character you
-- are playing can't be removed (it would be saved again right away).
-- Returns true if removed.
function GoldTracker:RemoveCharacter(guid)
    local goldDB = GoldDB()
    if not goldDB or not guid or guid == (UnitGUID and UnitGUID("player")) then
        return false
    end
    goldDB.characters[guid] = nil
    goldDB.hidden[guid] = nil
    self:SendMessage("MCG_GOLD_BALANCES_CHANGED")
    return true
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
    -- pcall: warband gold may not exist on every client (WoW Forever - Theoretical).
    pcall(function()
        self:RegisterEvent("ACCOUNT_MONEY", "OnMoneyChanged")
    end)
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
