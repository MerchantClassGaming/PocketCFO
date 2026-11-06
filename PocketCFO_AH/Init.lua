-- PocketCFO_AH/Init.lua
-- AH addon initialization. Registers as a standalone AceAddon.
-- Depends on PocketCFO core for shared utilities and inventory snapshots.

local ADDON_NAME = ...

local PocketCFO_AH = LibStub("AceAddon-3.0"):NewAddon(
    ADDON_NAME,
    "AceEvent-3.0"
)
_G.PocketCFO_AH = PocketCFO_AH

local DB_DEFAULTS = {
    global = {
        ahListings           = {},
        ahListingsByConfigKey = {},
        ahSales              = {},
        postingProfiles = {},
        recipePostingRules = {},
        nonCraftedPostingRules = {},
        itemRuleIgnoreList = {},
        postingSettings = {
            priceProtection = {
                enabled = true,
                ignoreBelowMarketPct = 0.50,
            },
            queue = {
                preserveLastQueue = false,
            },
            debug = {
                captureCompetitionRows = false,
            },
            ui = {},
        },
    },
}

local function SessionLog(msg, ...)
    local PocketCFO = _G.PocketCFO
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

-- The one item name used by every AH screen (Post, Cancel, Item Rules):
-- "Item Name Q3 - Crit / Haste". Q tag when the item has a crafting quality;
-- stats when it has a stat version, filtered by core IdentityAdapters
-- (primaries, stamina and armor dropped). Display only: never a lookup key.
local function ItemStatLabel(statFingerprint)
    if statFingerprint == nil or tostring(statFingerprint) == "" then
        return nil
    end
    local adapters = _G.PocketCFO and _G.PocketCFO.ItemIdentityAdapters
    if adapters and adapters.NormalizeVariantStatFingerprint then
        local ok, filtered = pcall(adapters.NormalizeVariantStatFingerprint, adapters, statFingerprint)
        if ok then
            statFingerprint = filtered
        end
    end
    if statFingerprint == nil or tostring(statFingerprint) == "" then
        return nil
    end

    local labels = {}
    for rawPart in string.gmatch(tostring(statFingerprint), "([^|]+)") do
        local part = rawPart
        part = part:gsub("^ITEM_MOD_", "")
        part = part:gsub("_SHORT$", "")
        part = part:gsub("_STAT$", "")
        -- "Haste Rating" -> "Haste" (Brian, 2026-11-04).
        part = part:gsub("_RATING$", "")
        part = part:gsub("_", " "):lower()
        part = part:gsub("(%a)([%w']*)", function(first, rest)
            return first:upper() .. rest
        end)
        if part ~= "" and not part:find("^Modified Crafting") then
            labels[#labels + 1] = part
        end
    end
    if #labels == 0 then
        return nil
    end
    return table.concat(labels, " / ")
end

function PocketCFO_AH.ItemDisplayName(row)
    if type(row) ~= "table" then
        return ""
    end
    local name = row.itemName or row.name
    if (not name or name == "") and row.itemID then
        name = "Item " .. tostring(row.itemID)
    end
    name = tostring(name or "")

    local quality = tonumber(row.craftingQuality or row.itemQuality or row.quality)
    if quality and quality > 0 then
        name = name .. " Q" .. tostring(quality)
    end

    local statLabel = ItemStatLabel(row.statFingerprint)
    if statLabel then
        name = name .. " - " .. statLabel
    end
    return name
end

local function CountTableEntries(value)
    if type(value) ~= "table" then
        return 0
    end

    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    return count
end

-- True when a rules table holds at least one rule. A value that is an empty
-- table (e.g. an empty per-owner bucket) doesn't count.
local function HasAnyRule(rules)
    if type(rules) ~= "table" then
        return false
    end
    for _, value in pairs(rules) do
        if type(value) ~= "table" or next(value) ~= nil then
            return true
        end
    end
    return false
end

local function IsCodexSeededConservativeProfile(profile)
    if type(profile) ~= "table" then
        return false
    end

    return tostring(profile.profileID or profile.profileKey or "") == "conservative"
        and tostring(profile.name or "") == "Conservative"
        and tonumber(profile.targetPosted) == 1
        and tonumber(profile.duration) == 12
        and tonumber(profile.minPrice) == 0
        and tonumber(profile.maxPrice) == 0
        and tonumber(profile.minProfitPct) == 0.25
        and tonumber(profile.minProfitGold) == 0
end

local function HasUserMeaningfulProfileFields(profile)
    if type(profile) ~= "table" then
        return false
    end

    for _, field in ipairs({ "name", "targetPosted", "minPrice", "maxPrice", "duration", "minProfitPct", "minProfitGold" }) do
        if profile[field] ~= nil and tostring(profile[field]) ~= "" then
            return true
        end
    end

    return false
end

local function IsEmptyConservativeProfile(profile)
    if type(profile) ~= "table" then
        return false
    end

    local isConservative = tostring(profile.profileID or "") == "conservative"
        or tostring(profile.profileKey or "") == "conservative"

    return isConservative and not HasUserMeaningfulProfileFields(profile)
end

local function CleanupPostingProfileRecords(profiles)
    local removed = 0
    local profileCount = CountTableEntries(profiles)

    for profileKey, profile in pairs(profiles or {}) do
        if IsEmptyConservativeProfile(profile)
        or (profileCount == 1 and IsCodexSeededConservativeProfile(profile)) then
            profiles[profileKey] = nil
            removed = removed + 1
        end
    end

    return removed
end

local function EnsurePostingSettings(globalDB)
    globalDB.postingSettings = globalDB.postingSettings or {}
    local settings = globalDB.postingSettings

    settings.priceProtection = settings.priceProtection or {}
    if settings.priceProtection.enabled == nil then
        settings.priceProtection.enabled = true
    end
    settings.priceProtection.ignoreBelowMarketPct = tonumber(settings.priceProtection.ignoreBelowMarketPct) or 0.50

    settings.queue = settings.queue or {}
    if settings.queue.preserveLastQueue == nil then
        settings.queue.preserveLastQueue = false
    end

    settings.debug = settings.debug or {}
    if settings.debug.captureCompetitionRows == nil then
        settings.debug.captureCompetitionRows = false
    end

    settings.ui = settings.ui or {}
end

local function CurrentOwnerKey()
    local PocketCFO = _G.PocketCFO
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

local function EnsureOwnerFields(rows, ownerKey, ownerName)
    if not ownerKey or type(rows) ~= "table" then
        return 0
    end

    local updated = 0
    for _, row in pairs(rows) do
        if type(row) == "table" and (row.owner == nil or row.owner == "") then
            row.owner = ownerKey
            row.ownerName = row.ownerName or ownerName
            updated = updated + 1
        end
    end
    return updated
end

function PocketCFO_AH:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("PocketCFO_AH_DB", DB_DEFAULTS, true)
    local globalDB = self.db.global
    globalDB.postingProfiles = globalDB.postingProfiles or {}
    local removedProfiles = CleanupPostingProfileRecords(globalDB.postingProfiles)
    if removedProfiles > 0 then
        SessionLog("PocketCFO_AH removed generated conservative posting profiles count=%d", removedProfiles)
    end
    globalDB.recipePostingRules = globalDB.recipePostingRules or {}
    globalDB.nonCraftedPostingRules = globalDB.nonCraftedPostingRules or {}
    globalDB.itemRuleIgnoreList = globalDB.itemRuleIgnoreList or {}
    EnsurePostingSettings(globalDB)
    local ownerKey = CurrentOwnerKey()
    local ownerName = CurrentOwnerName()
    local ownedProfiles = EnsureOwnerFields(globalDB.postingProfiles, ownerKey, ownerName)
    local ownedRecipeRules = EnsureOwnerFields(globalDB.recipePostingRules, ownerKey, ownerName)
    if ownedProfiles > 0 or ownedRecipeRules > 0 then
        SessionLog("PocketCFO_AH assigned missing posting owners profiles=%d recipeRules=%d owner=%s",
            ownedProfiles, ownedRecipeRules, tostring(ownerKey))
    end

    local PocketCFO = _G.PocketCFO

    -- One-time (Brian, 2026-11-06): players who already built posting rules
    -- get the Auction House Posting beta turned on; Smart Posting stays off.
    -- Runs after the seeded Conservative profile cleanup above, so only real
    -- rules count. Core BetaFeatures does nothing on Forever.
    local beta = PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("BetaFeatures", true)
    if beta and beta.ApplyExistingRulesCheck then
        local hasRules = HasAnyRule(globalDB.postingProfiles)
            or HasAnyRule(globalDB.recipePostingRules)
            or HasAnyRule(globalDB.nonCraftedPostingRules)
        beta:ApplyExistingRulesCheck(hasRules)
    end

    if PocketCFO then
        PocketCFO:Debug("PocketCFO_AH init loaded")
    end
    SessionLog("PocketCFO_AH init loaded")
end

function PocketCFO_AH:OnEnable()
    SessionLog("PocketCFO_AH OnEnable")

    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            local manager = self.GetModule and self:GetModule("AHManager", true)
            if manager and manager.StartAHOpenSessionIfAvailable then
                manager:StartAHOpenSessionIfAvailable("addon-enable-deferred")
            end
        end)
    end
end

function PocketCFO_AH:OnDisable()
end
