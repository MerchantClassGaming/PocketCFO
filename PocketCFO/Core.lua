-- PocketCFO/Core.lua
-- Core addon registration and lifecycle bootstrap.
-- All debug output uses [MCG] prefix. No product name in chat output.

local ADDON_NAME = ...

local PocketCFO = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME,
    "AceEvent-3.0"
)
_G.PocketCFO = PocketCFO

local function GenerateUUID()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return string.gsub(template, "[xy]", function(c)
        local v = (c == "x")
            and math.random(0, 15)
            or math.random(8, 11)
        return string.format("%x", v)
    end)
end

local function GetDiagnostics()
    return PocketCFO.Diagnostics
end

local function GetSettings()
    return PocketCFO.Settings or _G.PocketCFO_Settings
end

local function GetInventoryStateService()
    return PocketCFO.InventoryStateService or _G.InventoryStateService
end

local function GetContainerOutcomeService()
    return PocketCFO.ContainerOutcomeService or _G.PocketCFO_ContainerOutcomeService
end

function PocketCFO:NewUUID()
    return GenerateUUID()
end

function PocketCFO:Now()
    return time()
end

function PocketCFO:GetServerNow()
    if GetServerTime then
        local serverTime = GetServerTime()
        if serverTime then
            return serverTime
        end
    end
    return self:Now()
end

function PocketCFO:GetCharacterGUID()
    return UnitGUID("player")
end

PocketCFO.debugEnabled = false
PocketCFO.sessionLog = PocketCFO.sessionLog or {}

function PocketCFO:RegisterDiagnosticPackageProvider(...)
    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.RegisterDiagnosticPackageProvider then
        return diagnostics:RegisterDiagnosticPackageProvider(...)
    end
    return false, "diagnosticsUnavailable"
end

function PocketCFO:GetDiagnosticPackage(...)
    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.GetDiagnosticPackage then
        return diagnostics:GetDiagnosticPackage(...)
    end
    return nil, "packageProviderUnavailable"
end

function PocketCFO:ListDiagnosticPackages(...)
    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.ListDiagnosticPackages then
        return diagnostics:ListDiagnosticPackages(...)
    end
    return {}
end

function PocketCFO:AppendSessionLog(...)
    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.AppendSessionLog then
        return diagnostics:AppendSessionLog(...)
    end
end

function PocketCFO:ClearSessionLog(...)
    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.ClearSessionLog then
        return diagnostics:ClearSessionLog(...)
    end
    self.sessionLog = {}
end

function PocketCFO:GetSessionLogLines(...)
    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.GetSessionLogLines then
        return diagnostics:GetSessionLogLines(...)
    end

    local copy = {}
    for _, line in ipairs(self.sessionLog or {}) do
        copy[#copy + 1] = tostring(line)
    end
    return copy
end

function PocketCFO:SetDebugEnabled(...)
    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.SetDebugEnabled then
        return diagnostics:SetDebugEnabled(...)
    end
    local enabled = ...
    self.debugEnabled = enabled and true or false
end

function PocketCFO:Debug(...)
    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.Debug then
        return diagnostics:Debug(...)
    end
end

function PocketCFO:Print(msg, ...)
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[MCG]|r " .. tostring(msg))
end

function PocketCFO:OnInitialize()
    local settings = GetSettings()
    local dbDefaults = settings and settings.GetDBDefaults and settings:GetDBDefaults() or {}
    self.db = LibStub("AceDB-3.0"):New("PocketCFO_DB", dbDefaults, true)
    self.db.global = self.db.global or {}
    self.db.char = self.db.char or {}
    self.currentSessionID = self.currentSessionID or self:NewUUID()

    if settings and settings.NormalizeDatabase then
        settings:NormalizeDatabase(self.db)
    end

    local inventorySummary = nil
    local inventoryStateService = GetInventoryStateService()
    if inventoryStateService and inventoryStateService.InitializeDatabase then
        inventorySummary = inventoryStateService:InitializeDatabase(self.db.global)
    end

    local containerOutcomeService = GetContainerOutcomeService()
    if containerOutcomeService and containerOutcomeService.InitializeDatabase then
        containerOutcomeService:InitializeDatabase(self.db.global)
    end

    if not self.db.char.characterGUID then
        self.db.char.characterGUID = self:GetCharacterGUID()
    end

    self:AppendSessionLog(string.format(
        "[MCG] inventory state initialized legacyOwners=%d legacyRows=%d migratedOwners=%d migratedRows=%d",
        tonumber(inventorySummary and inventorySummary.snapshotOwners) or 0,
        tonumber(inventorySummary and inventorySummary.snapshotRows) or 0,
        tonumber(inventorySummary and inventorySummary.migratedOwners) or 0,
        tonumber(inventorySummary and inventorySummary.migratedRows) or 0
    ))
    self:Debug("Initialized. CharGUID: %s", self.db.char.characterGUID)
end

function PocketCFO:OnEnable()
    self:Debug("Enabled.")
end

function PocketCFO:OnDisable()
    self:Debug("Disabled.")
end
