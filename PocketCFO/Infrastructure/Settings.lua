-- PocketCFO/Infrastructure/Settings.lua
-- SavedVariables defaults and database normalization.

local PocketCFO = _G.PocketCFO

local Settings = {}

local DB_DEFAULTS = {
    global = {
        inventorySnapshots = {},
        observedInventory  = {},
        pendingAHSnapshotReductions = {},
        pendingAHMailboxEvidence = {},
        mailboxResolutionEvidenceScans = {},

        lifecycleLedger = {},
        missingLedger   = {},

        settings = {},

        -- Gold tracker (Services/GoldTracker): last known gold per character
        -- (keyed by character GUID) and the warband bank balance.
        gold = {
            characters = {},
            warband = false,
        },

        craftStatLog = {},

        recipeRegistry = {
            outputsByItemID = {},
            outputsByName = {},
            recipesByID = {},
            refreshByProfession = {},
        },

        lastWarbandBankScan = 0,

        diagnostics = {
            lastDump = false,
        },
    },
    char = {
        characterGUID = false,
        lastBagScan = 0,
        lastMailboxScan = 0,
        lastAHScan = 0,
        lastBankScan = 0,
        craftQueuePosition = false,
        initialScanComplete = {
            bags = false,
            ah = false,
            bank = false,
            warbandBank = false,
            mailbox = false,
        },
    },
}

function Settings:GetDBDefaults()
    return DB_DEFAULTS
end

function Settings:NormalizeDatabase(db)
    if not db then
        return nil
    end

    db.global = db.global or {}
    db.char = db.char or {}

    local globalDB = db.global
    globalDB.settings = globalDB.settings or {}
    globalDB.gold = globalDB.gold or {}
    globalDB.gold.characters = globalDB.gold.characters or {}
    globalDB.craftStatLog = globalDB.craftStatLog or {}
    globalDB.lifecycleLedger = globalDB.lifecycleLedger or {}
    globalDB.missingLedger = globalDB.missingLedger or {}
    globalDB.diagnostics = globalDB.diagnostics or {}
    if type(globalDB.diagnosticLastDump) == "table" and not globalDB.diagnostics.lastDump then
        globalDB.diagnostics.lastDump = globalDB.diagnosticLastDump
    end
    globalDB.diagnosticLastDump = nil

    globalDB.recipeRegistry = globalDB.recipeRegistry or {}
    globalDB.recipeRegistry.outputsByItemID = globalDB.recipeRegistry.outputsByItemID or {}
    globalDB.recipeRegistry.outputsByName = globalDB.recipeRegistry.outputsByName or {}
    globalDB.recipeRegistry.recipesByID = globalDB.recipeRegistry.recipesByID or {}
    globalDB.recipeRegistry.refreshByProfession = globalDB.recipeRegistry.refreshByProfession or {}

    db.char.initialScanComplete = db.char.initialScanComplete or {}
    db.char.initialScanComplete.bags = db.char.initialScanComplete.bags or false
    db.char.initialScanComplete.ah = db.char.initialScanComplete.ah or false
    db.char.initialScanComplete.bank = db.char.initialScanComplete.bank or false
    db.char.initialScanComplete.warbandBank = db.char.initialScanComplete.warbandBank or false
    db.char.initialScanComplete.mailbox = db.char.initialScanComplete.mailbox or false

    return db
end

if PocketCFO then
    PocketCFO.Settings = Settings
end

_G.PocketCFO_Settings = Settings
