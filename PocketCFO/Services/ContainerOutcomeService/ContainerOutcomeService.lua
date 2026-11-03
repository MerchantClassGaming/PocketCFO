-- PocketCFO/Services/ContainerOutcomeService/ContainerOutcomeService.lua
-- Answers exactly one question: "Based on the published seed observations plus
-- this user's local observations, what contents are expected from opening this
-- container once?" Also records newly observed local container openings.
-- Does not value contents - see PocketCFO_Valuation's custom container
-- valuation strategies for that.
--
-- Published seed aggregate (ContainerOutcomeSeedData.lua) is immutable code.
-- Local observations come from the Item Ledger (2026-10-30, claude/
-- Ledger_Rebuild_Checklist.md item 9b): container rows (category container,
-- src = container itemID) for items and currencies, container activity for
-- openings, and GoldLedger's container gold (gold, category looted, iid =
-- container itemID). Kept in a memory-only summary per container (cleared
-- when a matching ledger entry arrives) so tooltips never search the ledger.
-- The old store, PocketCFO_DB.global.containerOutcomeObservations, is moved
-- into the ledger once (InitializeDatabase) and removed. Its gold-per-opening
-- history is not moved (Brian 2026-10-30: that gold is already in the gold
-- history as looted gold; moving it would count it twice), so gold per
-- opening rebuilds from new openings.
--
-- Local opening capture: every container opened from the bags is recorded -
-- any container in the game, not a list - keyed by the container's itemID /
-- config key, never its name. Since 2026-10-30 the openings come from core
-- LootReader (MCG_CONTAINER_OPENING); see "Openings from the loot reader"
-- below. Each recorded opening sends MCG_CONTAINER_OPENED (containerItemID) so
-- valuation values a new container at once.
-- One-time reset (2026-10-30): local history of the two Artisan's Consortium
-- Payout bags is not moved where the reset hasn't run yet (polluted by the
-- old capture); see InitializeDatabase. Other containers' history is kept.
--
-- Live seed (2026-10-31, Brian): ContainerOutcomeSeedLive.lua
-- (PocketCFO_ContainerSeedLive) is generated on every commit from the
-- developer's loot reader openings (MCG_Diagnostic ContainerSeedExport + git
-- hook) and adds openings, items, gold and currencies on top of the published
-- seed. Ignored when MCG_Diagnostic is enabled (the developer's own install:
-- those openings are already local, so they would count twice).

local PocketCFO = _G.PocketCFO

local ContainerOutcomeService = {}

ContainerOutcomeService.configKeyCache = ContainerOutcomeService.configKeyCache or {}

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function GetSeedData()
    return (PocketCFO and PocketCFO.ContainerOutcomeSeedData) or _G.PocketCFO_ContainerOutcomeSeedData
end

-- True on the developer's install (MCG_Diagnostic loaded or enabled; enabled
-- covers calls made before it has loaded).
local function IsDevInstall()
    local addOns = _G.C_AddOns
    local isLoaded = (addOns and addOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if isLoaded then
        local ok, loaded = pcall(isLoaded, "MCG_Diagnostic")
        if ok and loaded then
            return true
        end
    end
    local enableState = (addOns and addOns.GetAddOnEnableState) or _G.GetAddOnEnableState
    if enableState then
        local ok, state = pcall(enableState, "MCG_Diagnostic", UnitName and UnitName("player") or nil)
        if ok and (tonumber(state) or 0) > 0 then
            return true
        end
    end
    return false
end

-- { exportedAt, containers = { [itemID] = { openCount, goldOpenCount, outputs =
-- { [itemID] = qty }, copper, currencies = { [currencyID] = qty } } } }, or nil.
local function GetLiveSeed()
    local live = _G.PocketCFO_ContainerSeedLive
    if type(live) ~= "table" or type(live.containers) ~= "table" or IsDevInstall() then
        return nil
    end
    return live
end

local function NumberOrNil(value)
    local number = tonumber(value)
    if number then
        return number
    end
    return nil
end

-- Resolves and caches itemID -> configKey via ItemIdentityService. Cache is
-- keyed by itemID only (never persisted) - safe to retry every call since a
-- prior "itemDataPending" miss should resolve once Blizzard's item data cache
-- fills in.
local function ResolveConfigKey(itemID)
    itemID = NumberOrNil(itemID)
    if not itemID then
        return nil, "missingItemID"
    end

    local cache = ContainerOutcomeService.configKeyCache
    if cache[itemID] then
        return cache[itemID], nil
    end

    local identityService = GetItemIdentityService()
    if not identityService then
        return nil, "itemIdentityServiceUnavailable"
    end

    local ok, identity = pcall(function()
        return identityService:FromItemID(itemID)
    end)
    if not ok or type(identity) ~= "table" or not identity.configKey then
        local reason = ok and type(identity) == "table" and identity.unresolvedReason or "identityResolutionFailed"
        return nil, reason
    end

    cache[itemID] = identity.configKey
    return identity.configKey, nil
end

local function ResolveContainerItemID(containerReference)
    if type(containerReference) == "number" then
        return containerReference
    end
    if type(containerReference) == "table" then
        return NumberOrNil(containerReference.itemID or containerReference.containerItemID)
    end
    return nil
end

--- One-time move of the old local store into the Item Ledger - call once from
-- Core.lua:OnInitialize (ItemLedger is loaded before this file).
-- Payout bags whose local history the old capture polluted (2026-10-30): not
-- moved where that reset (flag containerPayoutReset1) hasn't run yet.
local PAYOUT_RESET_ITEM_IDS = { [246585] = true, [227713] = true }
local PAYOUT_RESET_FLAG = "containerPayoutReset1"
local MOVE_FLAG = "containerHistoryToItemLedger1"
local HISTORY_CHARACTER = "Account-History"   -- old container history was account-wide

-- Container itemID of an old store row: saved on the row since 2026-10-26,
-- read from the storage key ("...|id:260534|...") for older rows.
local function RowItemID(key, row)
    local itemID = type(row) == "table" and NumberOrNil(row.itemID) or nil
    if not itemID and type(key) == "string" then
        itemID = NumberOrNil(key:match("id:(%d+)") or key:match("^itemID:(%d+)"))
    end
    return itemID
end

function ContainerOutcomeService:InitializeDatabase(globalDB)
    if type(globalDB) ~= "table" then
        return
    end
    globalDB.migrations = globalDB.migrations or {}
    local old = globalDB.containerOutcomeObservations
    local itemLedger = PocketCFO and PocketCFO.ItemLedger
    if globalDB.migrations[MOVE_FLAG] or not itemLedger then
        return
    end
    globalDB.migrations[MOVE_FLAG] = time and time() or true
    local skipPayout = not globalDB.migrations[PAYOUT_RESET_FLAG]
    globalDB.migrations[PAYOUT_RESET_FLAG] = globalDB.migrations[PAYOUT_RESET_FLAG] or (time and time() or true)
    if type(old) ~= "table" or next(old) == nil then
        globalDB.containerOutcomeObservations = nil
        return
    end
    -- Rows the ledger already has for containers came from the same openings
    -- the old store holds (both were fed by the loot reader): clear them first.
    local cleared = itemLedger:RemoveRows("container")
    local today = date("%Y-%m-%d")
    local before = itemLedger:GetTotals({ cat = "container" }).qty
    local movedQty, movedOpens, beforeOpens = 0, 0, itemLedger:GetActivityCount({ cat = "container" })
    local skipped = 0
    for key, row in pairs(old) do
        local itemID = RowItemID(key, row)
        if itemID and skipPayout and PAYOUT_RESET_ITEM_IDS[itemID] then
            skipped = skipped + 1
        elseif itemID and type(row) == "table" then
            local dayKey = row.lastOpenedAt and date("%Y-%m-%d", row.lastOpenedAt) or today
            local base = { characterGUID = HISTORY_CHARACTER, name = "(before the ledger)", dir = "in",
                cat = "container", src = itemID }
            for _, output in pairs(row.outputTotals or {}) do
                local qty = NumberOrNil(output.quantity) or 0
                if qty > 0 and NumberOrNil(output.itemID) then
                    local fields = {}
                    for k, v in pairs(base) do fields[k] = v end
                    fields.kind, fields.iid, fields.qty = "item", NumberOrNil(output.itemID), qty
                    itemLedger:AddHistoryRow(dayKey, fields)
                    movedQty = movedQty + qty
                end
            end
            for currencyID, currency in pairs(row.currencyTotals or {}) do
                local qty = NumberOrNil(currency.quantity) or 0
                if qty > 0 then
                    local fields = {}
                    for k, v in pairs(base) do fields[k] = v end
                    fields.kind, fields.iid, fields.qty = "currency", NumberOrNil(currency.currencyID) or NumberOrNil(currencyID), qty
                    itemLedger:AddHistoryRow(dayKey, fields)
                    movedQty = movedQty + qty
                end
            end
            local opens = NumberOrNil(row.openCount) or 0
            if opens > 0 then
                itemLedger:AddHistoryActivity(dayKey, { characterGUID = HISTORY_CHARACTER, name = "(before the ledger)",
                    cat = "container", src = itemID, n = opens })
                movedOpens = movedOpens + opens
            end
        end
    end
    local after = itemLedger:GetTotals({ cat = "container" }).qty
    local afterOpens = itemLedger:GetActivityCount({ cat = "container" })
    local ok = (after - before == movedQty) and (afterOpens - beforeOpens == movedOpens)
    if ok then
        globalDB.containerOutcomeObservations = nil
    end
    if PocketCFO and PocketCFO.AppendSessionLog then
        PocketCFO:AppendSessionLog(string.format(
            "[MCG] ContainerOutcomeService: container history %s (items+currencies %d, openings %d, payout rows skipped %d, ledger rows cleared first %d)%s",
            ok and "moved into the Item Ledger" or "move MISMATCH", movedQty, movedOpens, skipped, cleared,
            ok and "; old store removed" or "; old store kept"))
    end
end

-- ─── Local totals from the Item Ledger (memory-only summary) ─────────────────
local localCache = {}   -- [containerItemID] = row-shaped totals (see LocalRow)

-- { openCount, liveOpenCount, outputTotals = { [itemID] = { itemID, quantity } },
--   copperTotal, currencyTotals = { [currencyID] = { currencyID, quantity } } } for one
-- container, from the ledger. nil when it has never been opened here.
local function LocalRow(containerItemID)
    local cached = localCache[containerItemID]
    if cached ~= nil then
        return cached or nil
    end
    local itemLedger = PocketCFO and PocketCFO.ItemLedger
    if not itemLedger then
        return nil
    end
    local row = { openCount = itemLedger:GetActivityCount({ cat = "container", src = containerItemID }),
        outputTotals = {}, currencyTotals = {} }
    for _, found in ipairs(itemLedger:GetRows({ cat = "container", src = containerItemID, dir = "in" })) do
        local r = found.row
        local bucket = r.kind == "currency" and row.currencyTotals or (r.kind == "item" and row.outputTotals) or nil
        if bucket and r.iid then
            local total = bucket[r.iid] or (r.kind == "currency" and { currencyID = r.iid, quantity = 0 }
                or { itemID = r.iid, quantity = 0 })
            bucket[r.iid] = total
            total.quantity = total.quantity + (tonumber(r.qty) or 0)
        end
    end
    -- Gold and currency averages use only openings the loot reader saw (since
    -- 2026-10-30): moved history openings (HISTORY_CHARACTER) have no gold and
    -- only partial currency, so they would dilute the average. Item averages
    -- keep every opening.
    local historyFilter = { cat = "container", src = containerItemID, characterGUID = HISTORY_CHARACTER }
    row.liveOpenCount = row.openCount - itemLedger:GetActivityCount(historyFilter)
    historyFilter.dir, historyFilter.kind = "in", "currency"
    for _, found in ipairs(itemLedger:GetRows(historyFilter)) do
        local total = found.row.iid and row.currencyTotals[found.row.iid]
        if total then
            total.quantity = total.quantity - (tonumber(found.row.qty) or 0)
            if total.quantity <= 0 then
                row.currencyTotals[found.row.iid] = nil
            end
        end
    end
    local copper = itemLedger:GetTotals({ kind = "gold", cat = "looted", dir = "in", iid = containerItemID }).qty
    row.copperTotal = copper > 0 and copper or nil
    if row.openCount <= 0 then
        localCache[containerItemID] = false
        return nil
    end
    localCache[containerItemID] = row
    return row
end

function ContainerOutcomeService:ClearLocalCache(containerItemID)
    if containerItemID then
        localCache[containerItemID] = nil
    else
        localCache = {}
    end
end

--- Returns the sorted list of seeded container itemIDs. Used by
-- PocketCFO_Valuation's central registration file so the 13 seeded
-- containers only need to be enumerated in one place (the seed data file).
function ContainerOutcomeService:GetSeedContainerItemIDs()
    local seed = GetSeedData()
    local ids, seen = {}, {}
    local live = GetLiveSeed()
    for _, source in ipairs({ seed and seed.containers, live and live.containers }) do
        if type(source) == "table" then
            for key in pairs(source) do
                local itemID = NumberOrNil(key)
                if itemID and not seen[itemID] then
                    seen[itemID] = true
                    ids[#ids + 1] = itemID
                end
            end
        end
    end
    table.sort(ids)
    return ids
end

--- Returns { resolved, containerConfigKey, seedVersion, seedOpenCount,
-- localOpenCount, effectiveOpenCount, expectedContents = {{configKey, itemID,
-- expectedQuantity}} } for one container. expectedQuantity is never rounded.
function ContainerOutcomeService:GetExpectedContents(containerReference)
    local containerItemID = ResolveContainerItemID(containerReference)
    if not containerItemID then
        return { resolved = false, unresolvedReason = "missingContainerItemID" }
    end

    local seed = GetSeedData()
    local seedContainer = seed and type(seed.containers) == "table" and seed.containers[containerItemID] or nil
    local containerConfigKey = ResolveConfigKey(containerItemID)

    local localRow = LocalRow(containerItemID)
    local liveSeed = GetLiveSeed()
    local liveSeedContainer = liveSeed and liveSeed.containers[containerItemID] or nil
    if type(liveSeedContainer) ~= "table" then
        liveSeedContainer = nil
    end

    local seedOpenCount = (seedContainer and NumberOrNil(seedContainer.openCount)) or 0
    local liveSeedOpenCount = (liveSeedContainer and NumberOrNil(liveSeedContainer.openCount)) or 0
    -- Live seed openings with gold / currency data (its history openings have none).
    local liveSeedGoldOpenCount = (liveSeedContainer and (NumberOrNil(liveSeedContainer.goldOpenCount)
        or NumberOrNil(liveSeedContainer.openCount))) or 0
    local localOpenCount = (localRow and NumberOrNil(localRow.openCount)) or 0
    local liveOpenCount = (localRow and NumberOrNil(localRow.liveOpenCount)) or 0
    local effectiveOpenCount = seedOpenCount + liveSeedOpenCount + localOpenCount
    -- Gold and currencies: loot reader openings only (live seed + local since 10-30).
    local goldOpenCount = liveSeedGoldOpenCount + liveOpenCount

    if effectiveOpenCount <= 0 then
        return {
            resolved = false,
            unresolvedReason = "noObservations",
            containerConfigKey = containerConfigKey,
        }
    end

    local totals = {}
    local order = {}

    local function AddTotal(itemID, quantity)
        quantity = NumberOrNil(quantity)
        if not quantity or quantity == 0 then
            return
        end
        itemID = NumberOrNil(itemID)
        if not itemID then
            return
        end
        local outputConfigKey = ResolveConfigKey(itemID)
        local key = outputConfigKey or ("itemID:" .. tostring(itemID))
        if not totals[key] then
            totals[key] = { itemID = itemID, configKey = outputConfigKey, quantity = 0 }
            order[#order + 1] = key
        end
        totals[key].quantity = totals[key].quantity + quantity
    end

    if seedContainer and type(seedContainer.outputs) == "table" then
        for _, row in ipairs(seedContainer.outputs) do
            AddTotal(row.itemID, row.quantity)
        end
    end

    if liveSeedContainer and type(liveSeedContainer.outputs) == "table" then
        for itemID, quantity in pairs(liveSeedContainer.outputs) do
            AddTotal(itemID, quantity)
        end
    end

    if localRow and type(localRow.outputTotals) == "table" then
        for _, row in pairs(localRow.outputTotals) do
            AddTotal(row.itemID, row.quantity)
        end
    end

    local expectedContents = {}
    for _, key in ipairs(order) do
        local total = totals[key]
        expectedContents[#expectedContents + 1] = {
            configKey = total.configKey,
            itemID = total.itemID,
            expectedQuantity = total.quantity / effectiveOpenCount,
        }
    end

    -- Gold per opening: openings the loot reader saw only (the seed and the
    -- moved history have no gold data).
    local expectedCopper = nil
    local copperTotal = ((localRow and NumberOrNil(localRow.copperTotal)) or 0)
        + ((liveSeedContainer and NumberOrNil(liveSeedContainer.copper)) or 0)
    if goldOpenCount > 0 and copperTotal > 0 then
        expectedCopper = copperTotal / goldOpenCount
    end

    -- Currencies per opening: loot reader openings only (live seed + local,
    -- see LocalRow). { { currencyID, name, expectedQuantity } }, never rounded.
    local expectedCurrencies = {}
    if goldOpenCount > 0 then
        local currencyTotals = {}
        if liveSeedContainer and type(liveSeedContainer.currencies) == "table" then
            for key, quantity in pairs(liveSeedContainer.currencies) do
                local currencyID = NumberOrNil(key)
                if currencyID then
                    currencyTotals[currencyID] = (currencyTotals[currencyID] or 0) + (NumberOrNil(quantity) or 0)
                end
            end
        end
        if localRow and type(localRow.currencyTotals) == "table" then
            for key, total in pairs(localRow.currencyTotals) do
                local currencyID = NumberOrNil(total.currencyID) or NumberOrNil(key)
                if currencyID then
                    currencyTotals[currencyID] = (currencyTotals[currencyID] or 0) + (NumberOrNil(total.quantity) or 0)
                end
            end
        end
        for currencyID, quantity in pairs(currencyTotals) do
            if quantity > 0 then
                expectedCurrencies[#expectedCurrencies + 1] = {
                    currencyID = currencyID,
                    expectedQuantity = quantity / goldOpenCount,
                }
            end
        end
    end

    return {
        resolved = true,
        expectedCopper = expectedCopper,
        expectedCurrencies = expectedCurrencies,
        containerConfigKey = containerConfigKey,
        seedVersion = seed and seed.seedVersion,
        seedOpenCount = seedOpenCount,
        liveSeedOpenCount = liveSeedOpenCount,
        localOpenCount = localOpenCount,
        effectiveOpenCount = effectiveOpenCount,
        expectedContents = expectedContents,
    }
end

--- Item IDs of every container with local openings (sorted), from the ledger.
function ContainerOutcomeService:GetObservedContainerItemIDs()
    local itemLedger = PocketCFO and PocketCFO.ItemLedger
    local seen, ids = {}, {}
    for _, found in ipairs(itemLedger and itemLedger:GetActivityRows({ cat = "container" }) or {}) do
        local itemID = NumberOrNil(found.row.src)
        if itemID and not seen[itemID] then
            seen[itemID] = true
            ids[#ids + 1] = itemID
        end
    end
    table.sort(ids)
    return ids
end

-- ─── Openings from the loot reader (2026-10-30) ─────────────────────────────
-- The capture that lived here (UseContainerItem hook, loot window and chat
-- line bursts) was replaced by core LootReader container openings
-- (claude/Container_Migration_Design.md). It counted repeat clicks as
-- openings, counted any "received" line within 10s as contents, mixed bags
-- clicked close together, and on some characters counted openings and
-- contents 2-3 times. LootReader counts openings from the bag slot and only
-- takes lines within 1s of the click.
-- Since 2026-10-30 the loot reader writes every opening into the Item Ledger
-- itself (LootReader WriteOpening): counted openings as category container,
-- ambiguous ones / ones with a world or fishing window on their own. This
-- module only reads those rows (LocalRow) and, per MCG_CONTAINER_OPENING,
-- notes the opening for /mcg containerlog, refreshes that container's summary
-- and sends MCG_CONTAINER_OPENED (containerItemID) for Valuation and
-- ActivityRuns when it counted.

local RECENT_OPEN_LIMIT = 20
local LOOT_SLOT_ITEM = 1

local recentOpens = {}   -- this session, newest first (/mcg containerlog)
local messenger = LibStub and LibStub("AceEvent-3.0", true) and LibStub("AceEvent-3.0"):Embed({}) or nil

local function NoteRecent(entry)
    table.insert(recentOpens, 1, entry)
    while #recentOpens > RECENT_OPEN_LIMIT do
        table.remove(recentOpens)
    end
end

-- Why an opening doesn't count toward averages (the ledger wrote its
-- contents on their own instead), or nil. Same rules as before 2026-10-30.
local function SkipReason(opening)
    if not NumberOrNil(opening.itemID) or (NumberOrNil(opening.opens) or 0) <= 0 then
        return "no opening"
    elseif opening.ambiguous then
        return "another container was opened at the same time"
    end
    for _, window in ipairs(opening.windows or {}) do
        local types = window.sourceTypes or {}
        if window.fishing or types.Creature or types.GameObject or types.Vehicle then
            return "a loot window from the world or fishing was attached"
        end
    end
    return nil
end

-- The ledger already wrote the opening (LootReader); this only notes it for
-- /mcg containerlog, refreshes that container's summary and tells Valuation.
function ContainerOutcomeService:OnLootReaderOpening(opening)
    if type(opening) ~= "table" then
        return
    end
    local itemID = NumberOrNil(opening.itemID)
    local entry = {
        at = time and time() or 0,
        itemID = itemID,
        link = opening.link,
        opens = NumberOrNil(opening.opens) or 0,
        clicks = opening.clicks,
        copper = NumberOrNil(opening.copper),
        items = 0,
        currencies = #(opening.currencies or {}),
    }
    for _, line in ipairs(opening.lines or {}) do
        entry.items = entry.items + (NumberOrNil(line.quantity) or 1)
    end
    for _, window in ipairs(opening.windows or {}) do
        for _, slot in ipairs(window.slots or {}) do
            if slot.slotType == LOOT_SLOT_ITEM then
                entry.items = entry.items + (NumberOrNil(slot.quantity) or 0)
            end
        end
    end
    entry.skipped = SkipReason(opening)
    entry.recorded = entry.skipped == nil
    if itemID then
        self:ClearLocalCache(itemID)
    end
    if entry.recorded and messenger then
        messenger:SendMessage("MCG_CONTAINER_OPENED", itemID)
    end
    NoteRecent(entry)
end

if messenger then
    messenger:RegisterMessage("MCG_CONTAINER_OPENING", function(_, opening)
        ContainerOutcomeService:OnLootReaderOpening(opening)
    end)
    -- Container rows or container gold changed: that container's summary is stale.
    messenger:RegisterMessage("MCG_ITEM_LEDGER_ENTRY", function(_, ledgerEntry)
        if type(ledgerEntry) ~= "table" then
            return
        end
        if ledgerEntry.cat == "container" and ledgerEntry.src then
            ContainerOutcomeService:ClearLocalCache(NumberOrNil(ledgerEntry.src))
        elseif ledgerEntry.kind == "gold" and ledgerEntry.iid then
            ContainerOutcomeService:ClearLocalCache(NumberOrNil(ledgerEntry.iid))
        end
    end)
end

-- /mcg containerlog: every container with local openings (averages per
-- opening) and this session's openings from the loot reader, including ones
-- skipped and why.
local function FormatCopper(copper)
    copper = math.floor(tonumber(copper) or 0)
    return string.format("%dg%02ds%02dc", math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100)
end

local diagnostics = PocketCFO and PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("containerlog", {
        name = "containerlog",
        description = "Show containers you have opened (average contents per opening) and this session's openings from the loot reader.",
        usage = "/mcg containerlog",
        category = "General",
    }, function()
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        local function Name(itemID)
            local ok, name = pcall(getInfo, itemID)
            return (ok and name) or ("item " .. tostring(itemID))
        end
        local lines = { "=== Containers opened (your openings, from the Item Ledger, average per opening) ===" }
        local any = false
        for _, itemID in ipairs(ContainerOutcomeService:GetObservedContainerItemIDs()) do
            local row = LocalRow(itemID)
            if row then
            any = true
            local opens = NumberOrNil(row.openCount) or 0
            local liveOpens = NumberOrNil(row.liveOpenCount) or 0
            lines[#lines + 1] = string.format("  %s  itemID=%s  opens=%d (since 10-30: %d)  gold/open=%s",
                Name(itemID), tostring(itemID), opens, liveOpens,
                FormatCopper(liveOpens > 0 and (NumberOrNil(row.copperTotal) or 0) / liveOpens or 0))
            for _, output in pairs(row.outputTotals or {}) do
                lines[#lines + 1] = string.format("      %s (%s)  total=%d  per open=%.2f",
                    Name(output.itemID), tostring(output.itemID), output.quantity or 0,
                    opens > 0 and (output.quantity or 0) / opens or 0)
            end
            for currencyID, currency in pairs(row.currencyTotals or {}) do
                lines[#lines + 1] = string.format("      currency %s  total=%d  per open=%.2f",
                    tostring(currency.currencyID or currencyID), currency.quantity or 0,
                    liveOpens > 0 and (currency.quantity or 0) / liveOpens or 0)
            end
            end
        end
        if not any then
            lines[#lines + 1] = "  (none yet)"
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "=== Openings this session, from the loot reader (newest first) ==="
        for _, entry in ipairs(recentOpens) do
            lines[#lines + 1] = string.format("  %s  %s (%s)  opened=%d  clicks=%s  items=%d  currencies=%d  gold=%s  %s",
                date("%H:%M:%S", entry.at or 0), tostring(entry.link), tostring(entry.itemID), entry.opens or 0,
                tostring(entry.clicks), entry.items or 0, entry.currencies or 0, FormatCopper(entry.copper or 0),
                entry.skipped and ("SKIPPED: " .. entry.skipped)
                    or (entry.recorded and "recorded" or ("NOT recorded: " .. tostring(entry.reason))))
        end
        if #recentOpens == 0 then
            lines[#lines + 1] = "  (none)"
        end
        diagnostics:ShowDump("Container Log", table.concat(lines, "\n"))
    end)
end

if PocketCFO then
    PocketCFO.ContainerOutcomeService = ContainerOutcomeService
end

_G.PocketCFO_ContainerOutcomeService = ContainerOutcomeService
