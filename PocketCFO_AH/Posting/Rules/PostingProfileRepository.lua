-- PocketCFO_AH/Posting/Rules/PostingProfileRepository.lua
-- Posting profile persistence, retrieval, normalization, and lifecycle helpers.

local ADDON_NAME, _ = ...
local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local PostingProfileRepository = PocketCFO_AH:NewModule("PostingProfileRepository")

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function CopyTableShallow(source)
    local copy = {}
    for key, value in pairs(source or {}) do
        copy[key] = value
    end
    return copy
end

local function Copper(value)
    value = tonumber(value)
    if not value or value < 0 then
        return nil
    end
    return math.floor(value + 0.5)
end

local function Decimal(value)
    value = tonumber(value)
    if not value then
        return nil
    end
    return value
end

local function CurrentOwnerKey()
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.char
        and PocketCFO.db.char.characterGUID
        or nil
end

local function CurrentOwnerName()
    if UnitFullName then
        local name, realm = UnitFullName("player")
        if name and realm and realm ~= "" then
            return name .. "-" .. realm
        end
        return name
    end
    if UnitName then
        return UnitName("player")
    end
    return nil
end

function PostingProfileRepository:GetProfilesDB()
    local db = PocketCFO_AH.db and PocketCFO_AH.db.global
    if not db then
        return {}
    end
    db.postingProfiles = db.postingProfiles or {}
    return db.postingProfiles
end

function PostingProfileRepository:GetSettingsDB()
    local db = PocketCFO_AH.db and PocketCFO_AH.db.global
    if not db then
        return {}
    end
    db.postingSettings = db.postingSettings or {}
    return db.postingSettings
end

function PostingProfileRepository:NormalizeProfile(profile, profileKey)
    if type(profile) ~= "table" then
        return nil
    end

    local normalized = CopyTableShallow(profile)
    normalized.profileID = normalized.profileID or normalized.profileKey or profileKey
    normalized.profileKey = normalized.profileKey or normalized.profileID
    normalized.owner = normalized.owner or CurrentOwnerKey()
    normalized.ownerName = normalized.ownerName or CurrentOwnerName()

    for _, field in ipairs({ "minPrice", "normalPrice", "maxPrice", "undercutAmount", "fallbackPrice", "minProfitGold" }) do
        if normalized[field] ~= nil then
            normalized[field] = Copper(normalized[field]) or 0
        end
    end

    if normalized.minProfitPct ~= nil then
        normalized.minProfitPct = Decimal(normalized.minProfitPct)
    end
    if normalized.targetPosted ~= nil then
        normalized.targetPosted = math.max(0, math.floor(tonumber(normalized.targetPosted) or 0))
    end

    return normalized
end

function PostingProfileRepository:EnsureSettings()
    local settings = self:GetSettingsDB()
    settings.ui = settings.ui or {}
end

function PostingProfileRepository:GetProfile(profileKey)
    if profileKey == nil or profileKey == "" then
        return nil
    end

    local profile = self:GetProfilesDB()[tostring(profileKey)]
    if type(profile) ~= "table" then
        return nil
    end

    return self:NormalizeProfile(profile, tostring(profileKey))
end

function PostingProfileRepository:SaveProfile(profileKey, profile)
    if profileKey == nil or profileKey == "" or type(profile) ~= "table" then
        return nil, "invalidProfile"
    end

    profileKey = tostring(profileKey)
    local existing = self:GetProfilesDB()[profileKey]
    profile.profileID = profile.profileID or profileKey
    profile.profileKey = profile.profileKey or profileKey
    profile.owner = (type(existing) == "table" and existing.owner) or profile.owner or CurrentOwnerKey()
    profile.ownerName = (type(existing) == "table" and existing.ownerName) or profile.ownerName or CurrentOwnerName()
    self:GetProfilesDB()[profileKey] = profile
    return self:GetProfile(profileKey)
end

function PostingProfileRepository:DeleteProfile(profileKey)
    if profileKey == nil or profileKey == "" then
        return nil, "missingProfileKey"
    end

    self:GetProfilesDB()[tostring(profileKey)] = nil
    return true
end

function PostingProfileRepository:GetDebugRows()
    self:EnsureSettings()
    local rows = {}
    for profileKey, profile in pairs(self:GetProfilesDB()) do
        rows[#rows + 1] = self:NormalizeProfile(profile, profileKey)
    end
    table.sort(rows, function(a, b)
        return tostring(a.profileID or "") < tostring(b.profileID or "")
    end)
    return rows
end

function PostingProfileRepository:OnInitialize()
    self:EnsureSettings()
    SessionLog("PostingProfileRepository OnInitialize profiles=%d", #(self:GetDebugRows() or {}))
end
