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
--
-- Confidence filter (2026-11-07, Brian): local openings are filtered before
-- they count (last 11 months, 3 days per bag and per item, one-offs as a
-- group, a bag never contains itself, seedOnly seed containers); see LocalRow
-- and claude/Container_Confidence_Design.md. Flavor: Both.

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

-- Confidence filter (2026-11-07, Brian; claude/Container_Confidence_Design.md).
-- Mail items taken within a second of a bag click were counted as contents
-- (the Payout bag "could contain" itself, a fishing cap and gloves). Local
-- openings are read only from the last LOCAL_WINDOW_MONTHS of day rows (month
-- rows never: old openings age out, and last year's holiday bag contents
-- don't mix in). A bag's local openings count only once it was opened on
-- MIN_DAYS different days; an item (or currency) counts only once it was
-- seen on MIN_DAYS different days, or when the seed / live seed lists it for
-- that bag. Non-stackable outputs (one-offs) that miss the threshold on their
-- own count when the bag's one-offs together were seen on MIN_DAYS days. A
-- bag never contains itself; a seed container's excludedOutputs never count.
-- Unconfirmed items are left out (the ledger keeps them; /mcg containerlog
-- lists them); the opening count is not reduced.
local LOCAL_WINDOW_MONTHS = 11
local MIN_DAYS = 3

-- First day ("YYYY-MM-DD") of the local window.
local function WindowStart(now)
    local t = date("*t", now or time())
    t.month = t.month - LOCAL_WINDOW_MONTHS
    while t.month <= 0 do
        t.month = t.month + 12
        t.year = t.year - 1
    end
    return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
end

-- true / false, or nil while item data isn't loaded (GetItemInfo maxStack,
-- same read as PocketCFO_Valuation's container valuation).
local function IsStackableItem(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
    if not itemID or not getInfo then
        return nil
    end
    local ok, name, _, _, _, _, _, _, maxStack = pcall(getInfo, itemID)
    maxStack = ok and name and tonumber(maxStack) or nil
    if not maxStack then
        return nil
    end
    return maxStack > 1
end

-- Ledger character index of the moved history, or nil.
local function HistoryIndex(itemLedger)
    local index = 1
    while true do
        local character = itemLedger:GetCharacter(index)
        if not character then
            return nil
        end
        if character.guid == HISTORY_CHARACTER then
            return index
        end
        index = index + 1
    end
end

-- Seed container rows for a bag (published seed, live seed); either may be nil.
local function SeedRows(containerItemID)
    local seed = GetSeedData()
    local seedContainer = seed and type(seed.containers) == "table" and seed.containers[containerItemID] or nil
    local liveSeed = GetLiveSeed()
    local liveContainer = liveSeed and liveSeed.containers[containerItemID] or nil
    if type(liveContainer) ~= "table" then
        liveContainer = nil
    end
    return seedContainer, liveContainer
end

-- True when an output must never count for this bag (itself, or excluded by
-- the seed container's excludedOutputs = { [itemID] = true }).
local function IsExcludedOutput(containerItemID, itemID, seedContainer)
    itemID = NumberOrNil(itemID)
    if itemID == containerItemID then
        return true
    end
    local excluded = seedContainer and seedContainer.excludedOutputs
    return type(excluded) == "table" and itemID ~= nil and excluded[itemID] == true
end

-- { openCount, liveOpenCount, bagDays, bagConfirmed, outputTotals = { [itemID]
--   = { itemID, quantity, historyQuantity, days } }, copperTotal,
--   currencyTotals = { [currencyID] = { currencyID, quantity, days } },
--   unconfirmed = { { kind, iid, quantity, days, reason } }, itemDataPending }
-- for one container, from the ledger (last LOCAL_WINDOW_MONTHS only, filtered,
-- see above). nil when it has not been opened here in that time.
local function LocalRow(containerItemID)
    local cached = localCache[containerItemID]
    if cached ~= nil then
        return cached or nil
    end
    local itemLedger = PocketCFO and PocketCFO.ItemLedger
    if not itemLedger or not containerItemID then
        return nil
    end
    local from = WindowStart()
    local history = HistoryIndex(itemLedger)
    local seedContainer, liveContainer = SeedRows(containerItemID)

    local row = { openCount = 0, liveOpenCount = 0, bagDays = 0, outputTotals = {}, currencyTotals = {},
        unconfirmed = {} }
    local bagDaySet = {}
    for _, found in ipairs(itemLedger:GetActivityRows({ cat = "container", src = containerItemID, from = from })) do
        local n = tonumber(found.row.n) or 0
        if n > 0 then
            row.openCount = row.openCount + n
            -- Gold and currency averages use only openings the loot reader
            -- saw (since 2026-10-30): moved history openings have no gold and
            -- only partial currency. Item averages keep every opening.
            if history == nil or found.row.c ~= history then
                row.liveOpenCount = row.liveOpenCount + n
            end
            if not bagDaySet[found.period] then
                bagDaySet[found.period] = true
                row.bagDays = row.bagDays + 1
            end
        end
    end
    if row.openCount <= 0 then
        localCache[containerItemID] = false
        return nil
    end
    row.bagConfirmed = row.bagDays >= MIN_DAYS

    -- Every output seen, with the days it was seen on.
    local seen = {}   -- ["item:123"] = { kind, iid, quantity, historyQuantity, days, daySet }
    for _, found in ipairs(itemLedger:GetRows({ cat = "container", src = containerItemID, dir = "in", from = from })) do
        local r = found.row
        if (r.kind == "item" or r.kind == "currency") and r.iid then
            local key = r.kind .. ":" .. tostring(r.iid)
            local entry = seen[key]
            if not entry then
                entry = { kind = r.kind, iid = r.iid, quantity = 0, historyQuantity = 0, days = 0, daySet = {} }
                seen[key] = entry
            end
            local qty = tonumber(r.qty) or 0
            entry.quantity = entry.quantity + qty
            if history ~= nil and r.c == history then
                entry.historyQuantity = entry.historyQuantity + qty
            end
            if qty > 0 and not entry.daySet[found.period] then
                entry.daySet[found.period] = true
                entry.days = entry.days + 1
            end
        end
    end

    -- Outputs the seed or live seed already lists for this bag.
    local seedListed = {}
    if seedContainer and type(seedContainer.outputs) == "table" then
        for _, output in ipairs(seedContainer.outputs) do
            local itemID = NumberOrNil(output.itemID)
            if itemID then
                seedListed["item:" .. tostring(itemID)] = true
            end
        end
    end
    if liveContainer then
        for itemID in pairs(type(liveContainer.outputs) == "table" and liveContainer.outputs or {}) do
            seedListed["item:" .. tostring(NumberOrNil(itemID))] = true
        end
        for currencyID in pairs(type(liveContainer.currencies) == "table" and liveContainer.currencies or {}) do
            seedListed["currency:" .. tostring(NumberOrNil(currencyID))] = true
        end
    end

    -- Confirm each output; one-offs that miss on their own wait for the group.
    local confirmed, oneOffs, oneOffDays, oneOffDayCount = {}, {}, {}, 0
    for key, entry in pairs(seen) do
        if entry.kind == "item" and IsExcludedOutput(containerItemID, entry.iid, seedContainer) then
            entry.reason = (NumberOrNil(entry.iid) == containerItemID) and "the bag itself" or "excluded by the seed"
        elseif entry.days >= MIN_DAYS or seedListed[key] then
            confirmed[key] = true
        elseif entry.kind == "item" then
            local stackable = IsStackableItem(entry.iid)
            if stackable == false then
                oneOffs[#oneOffs + 1] = key
                for day in pairs(entry.daySet) do
                    if not oneOffDays[day] then
                        oneOffDays[day] = true
                        oneOffDayCount = oneOffDayCount + 1
                    end
                end
            elseif stackable == nil then
                row.itemDataPending = true
                entry.reason = "item data not loaded yet"
            end
        end
    end
    if oneOffDayCount >= MIN_DAYS then
        for _, key in ipairs(oneOffs) do
            confirmed[key] = true
        end
    end

    for key, entry in pairs(seen) do
        if confirmed[key] then
            if entry.kind == "item" then
                row.outputTotals[entry.iid] = { itemID = entry.iid, quantity = entry.quantity,
                    historyQuantity = entry.historyQuantity, days = entry.days }
            else
                -- History currency is partial: left out, like history openings.
                local quantity = entry.quantity - entry.historyQuantity
                if quantity > 0 then
                    row.currencyTotals[entry.iid] = { currencyID = entry.iid, quantity = quantity, days = entry.days }
                end
            end
        else
            row.unconfirmed[#row.unconfirmed + 1] = { kind = entry.kind, iid = entry.iid, quantity = entry.quantity,
                days = entry.days,
                reason = entry.reason or string.format("seen on %d of %d days", entry.days, MIN_DAYS) }
        end
    end

    local copper = itemLedger:GetTotals({ kind = "gold", cat = "looted", dir = "in", iid = containerItemID,
        from = from }).qty
    row.copperTotal = copper > 0 and copper or nil
    -- Not cached while item data is loading (one-offs can't be told apart yet).
    if not row.itemDataPending then
        localCache[containerItemID] = row
    end
    return row
end

--- Filtered local summary of one container (see LocalRow), or nil. Read by
-- MCG_Diagnostic's seed export so the live seed ships the same filtered data.
function ContainerOutcomeService:GetLocalSummary(containerItemID)
    return LocalRow(NumberOrNil(containerItemID))
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
    local localPending = localRow and localRow.itemDataPending or nil
    -- Confidence filter (see LocalRow): local openings count only once the
    -- bag was opened on MIN_DAYS days, and never for a seedOnly container on
    -- a player's install (the dev install's local openings are the live seed).
    local localHeldBack = nil
    if localRow and not localRow.bagConfirmed then
        localHeldBack = "notEnoughDays"
        localRow = nil
    elseif localRow and seedContainer and seedContainer.seedOnly and not IsDevInstall() then
        localHeldBack = "seedOnly"
        localRow = nil
    end
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
            unresolvedReason = localHeldBack or "noObservations",
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
        if not itemID or IsExcludedOutput(containerItemID, itemID, seedContainer) then
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
        -- Local one-offs couldn't be classified yet: don't cache this result.
        itemDataPending = (localRow ~= nil and localPending) or nil,
        -- Why local openings were left out ("notEnoughDays" / "seedOnly"), or nil.
        localHeldBack = localHeldBack,
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
    elseif opening.outside then
        return tostring(opening.outside) .. " at the same time"
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
        local lines = { string.format(
            "=== Containers opened (your openings, last %d months, average per opening; counts after %d days) ===",
            LOCAL_WINDOW_MONTHS, MIN_DAYS) }
        local any = false
        for _, itemID in ipairs(ContainerOutcomeService:GetObservedContainerItemIDs()) do
            local row = LocalRow(itemID)
            if row then
            any = true
            local opens = NumberOrNil(row.openCount) or 0
            local liveOpens = NumberOrNil(row.liveOpenCount) or 0
            local seedContainer = SeedRows(itemID)
            local status = row.bagConfirmed and "counted" or "NOT counted yet"
            if row.bagConfirmed and seedContainer and seedContainer.seedOnly then
                status = "seed only for players"
            end
            lines[#lines + 1] = string.format("  %s  itemID=%s  opens=%d (since 10-30: %d)  days=%d  %s  gold/open=%s",
                Name(itemID), tostring(itemID), opens, liveOpens, row.bagDays or 0, status,
                FormatCopper(liveOpens > 0 and (NumberOrNil(row.copperTotal) or 0) / liveOpens or 0))
            for _, output in pairs(row.outputTotals or {}) do
                lines[#lines + 1] = string.format("      %s (%s)  total=%d  per open=%.2f  days=%d",
                    Name(output.itemID), tostring(output.itemID), output.quantity or 0,
                    opens > 0 and (output.quantity or 0) / opens or 0, output.days or 0)
            end
            for currencyID, currency in pairs(row.currencyTotals or {}) do
                lines[#lines + 1] = string.format("      currency %s  total=%d  per open=%.2f  days=%d",
                    tostring(currency.currencyID or currencyID), currency.quantity or 0,
                    liveOpens > 0 and (currency.quantity or 0) / liveOpens or 0, currency.days or 0)
            end
            for _, left in ipairs(row.unconfirmed or {}) do
                lines[#lines + 1] = string.format("      LEFT OUT %s (%s)  total=%d  %s",
                    left.kind == "item" and Name(left.iid) or "currency", tostring(left.iid), left.quantity or 0,
                    tostring(left.reason))
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

    -- /mcg containerfix <bagID> <itemID> <category> (2026-11-07,
    -- claude/Container_Confidence_Design.md): moves an item that was wrongly
    -- counted as a bag's contents (e.g. taken from the mail during the click)
    -- to its real category in the Item Ledger, and clears the bag as its
    -- source. Openings are not touched. Every row of that item for that bag
    -- moves, so use it only for items the bag never gives.
    local FIX_CATEGORIES = { "mail", "transfer", "auction_buy", "order_patron", "trade", "quest", "received" }
    diagnostics:RegisterCommand("containerfix", {
        name = "containerfix",
        description = "Move an item wrongly counted as a bag's contents to its real category (mail, transfer, auction_buy, order_patron, trade, quest, received).",
        usage = "/mcg containerfix <bagItemID> <itemID> <category>",
        category = "General",
    }, function(rest)
        local bagID, itemID, category = tostring(rest or ""):match("^%s*(%d+)%s+(%d+)%s+(%S+)")
        bagID, itemID = NumberOrNil(bagID), NumberOrNil(itemID)
        local allowed = false
        for _, name in ipairs(FIX_CATEGORIES) do
            if name == category then
                allowed = true
            end
        end
        local itemLedger = PocketCFO and PocketCFO.ItemLedger
        local lines = {}
        if not bagID or not itemID or not allowed then
            lines[1] = "Usage: /mcg containerfix <bagItemID> <itemID> <category>"
            lines[2] = "Categories: " .. table.concat(FIX_CATEGORIES, ", ")
            lines[3] = "Item IDs: /mcg containerlog (LEFT OUT lines and per-item lines show them)."
        elseif not itemLedger or type(itemLedger.MoveRows) ~= "function" then
            lines[1] = "Item Ledger not loaded: nothing moved."
        else
            local qty, rows, entries = itemLedger:MoveRows({ cat = "container", src = bagID, iid = itemID,
                clearSrc = true }, category)
            ContainerOutcomeService:ClearLocalCache(bagID)
            if messenger then
                messenger:SendMessage("MCG_CONTAINER_OPENED", bagID)
            end
            lines[1] = string.format("Bag %d, item %d: moved quantity %d (%d day/month rows, %d entries) to %s.",
                bagID, itemID, qty or 0, rows or 0, entries or 0, category)
        end
        diagnostics:ShowDump("Container Fix", table.concat(lines, "\n"))
    end)
end

if PocketCFO then
    PocketCFO.ContainerOutcomeService = ContainerOutcomeService
end

_G.PocketCFO_ContainerOutcomeService = ContainerOutcomeService
