-- PocketCFO_AH/Services/SalesWatch/SalesWatch.lua
-- Sales Watch (an item watch): search one item every INTERVAL seconds for
-- DURATION seconds and compare each ladder with the one before.
-- Design: project doc claude/Sales_Watch_Design.md. Flavor: Both.
--
-- What it reports (Brian, 2026-11-16: state what we can see, call out the
-- rest, never overpromise "sold"):
--   You sold        your own units at a price went down and you didn't cancel
--                   (numOwnerItems / containsOwnerItem; cancel hook). Confirmed.
--   Sold (likely)   commodities: other sellers' units that left a price with
--                   nothing cheaper still listed afterwards. A buyer can only
--                   buy the cheapest units (a big purchase walks up the prices
--                   as each empties), so these were reachable; their sellers
--                   weren't undercut and can't see their place in a tied price,
--                   so they had no reason to pull. Gear: the cheapest auction.
--   Canceled or     commodities: units that left a price while something
--   expired         cheaper was still listed. No buyer could reach them (Brian,
--                   2026-11-16: you can't buy above the cheapest, even by
--                   misclick). Gear: any other auction gone (buyers pick any
--                   auction, so bought, canceled or expired).
--   New listed      other sellers' units that showed up.
-- Counts are minimums: a posting and a sale at the same price between two
-- refreshes cancel out, and a fresh cheaper posting bought within seconds is
-- never seen.
--
-- Confirmed 2026-11-16 (retail): commodity rows are one per price with
-- auctionID, timeLeftSeconds, owners, totalNumberOfOwners, numOwnerItems,
-- containsOwnerItem, containsAccountItem. numOwnerItems tracked Brian's ink
-- sales exactly (582 -> 576, each drop matching the price's total). 3s
-- searches: 0 missed, 0 throttle waits. timeLeftSeconds = longest time left
-- at that price (Brian's 12h ink sat under a 48h listing's timer). owners
-- list holds at most 5 names (count said 8); your own show as "player".
-- THEORETICAL: buyers at a tied price get the newest auctions first (LIFO):
-- Brian's last-posted ink sold first; at 6.00g copper the longest-time-left
-- (newest 48h) auctions left first. Gear fields (containsOwnerItem, timeLeft).
-- Gear is counted per version (name + item level + stats), see VersionOf.

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local SalesWatch = PocketCFO_AH:NewModule("SalesWatch")

SalesWatch.DURATION = 180          -- seconds of watching
SalesWatch.EXTEND = 180            -- "Watch 3 more minutes"
SalesWatch.MAX_TOTAL = 600         -- cap on watching per watch (10 min)
SalesWatch.INTERVAL = 3            -- seconds between searches (10s ran clean, 2026-11-16)
SalesWatch.RESPONSE_TIMEOUT = 8    -- seconds to wait for one search answer
SalesWatch.MAX_SAVED = 200         -- watches kept in saved data (summary)
SalesWatch.MAX_SAVED_FULL = 5      -- of those, the newest keep every refresh (diagnostic)
SalesWatch.MAX_SAVED_LADDER_ROWS = 100
SalesWatch.CHEAP_LEVELS_SAVED = 5  -- per refresh, row detail for the cheapest prices

local function SessionLog(msg, ...)
    if not PocketCFO or PocketCFO.debugEnabled ~= true or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] SalesWatch: " .. tostring(msg))
end

local function Now()
    return GetTime and GetTime() or 0
end

local function SavedDB()
    local db = PocketCFO_AH.db and PocketCFO_AH.db.global
    if not db then
        return nil
    end
    db.salesWatches = db.salesWatches or {}
    return db.salesWatches
end

local function IsEquipment(equipLoc)
    return equipLoc ~= nil and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
        and equipLoc ~= "INVTYPE_NON_EQUIP"
end

local function BuildSorts()
    if _G.Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price then
        return { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
    end
    return {}
end

local function RawKeys(row)
    local keys = {}
    for key, value in pairs(row or {}) do
        local shown = type(value) == "table" and "{table}" or tostring(value)
        keys[#keys + 1] = tostring(key) .. "=" .. shown
    end
    table.sort(keys)
    return table.concat(keys, ", ")
end

---------------------------------------------------------------------------
-- Snapshots
---------------------------------------------------------------------------

-- Commodity: ladder[price] = { qty, own, minTimeLeft }
local function ReadCommoditySnapshot(itemID)
    local snap = { mode = "commodity", ladder = {}, rows = 0, full = true }
    local okCount, count = pcall(C_AuctionHouse.GetNumCommoditySearchResults, itemID)
    count = okCount and tonumber(count) or 0
    snap.rows = count
    for index = 1, count do
        local ok, row = pcall(C_AuctionHouse.GetCommoditySearchResultInfo, itemID, index)
        if ok and type(row) == "table" then
            if index == 1 then
                snap.rawKeys = RawKeys(row)
            end
            local price = tonumber(row.unitPrice)
            local qty = tonumber(row.quantity) or 0
            if price and qty > 0 then
                local own = tonumber(row.numOwnerItems)
                if own == nil then
                    own = row.containsOwnerItem == true and qty or 0
                end
                own = math.min(math.max(own, 0), qty)
                local entry = snap.ladder[price]
                if not entry then
                    entry = { qty = 0, own = 0, rows = 0, ids = {}, owners = {} }
                    snap.ladder[price] = entry
                end
                entry.qty = entry.qty + qty
                entry.own = entry.own + own
                entry.rows = entry.rows + 1
                entry.ids[#entry.ids + 1] = tostring(row.auctionID)
                entry.ownerCount = (entry.ownerCount or 0) + (tonumber(row.totalNumberOfOwners) or 0)
                if type(row.owners) == "table" then
                    for _, name in ipairs(row.owners) do
                        entry.owners[#entry.owners + 1] = tostring(name)
                    end
                end
                local tls = tonumber(row.timeLeftSeconds)
                if tls and (entry.minTimeLeft == nil or tls < entry.minTimeLeft) then
                    entry.minTimeLeft = tls
                end
                if tls and (entry.maxTimeLeft == nil or tls > entry.maxTimeLeft) then
                    entry.maxTimeLeft = tls
                end
            end
        end
    end
    if type(C_AuctionHouse.HasFullCommoditySearchResults) == "function" then
        local okFull, full = pcall(C_AuctionHouse.HasFullCommoditySearchResults, itemID)
        snap.full = okFull and full ~= false
    end
    return snap
end

-- Gear versions (Brian, 2026-11-16): one gear search returns every version
-- of the item (retail: crafted qualities; Forever: random suffixes such as
-- "of the Monkey", confirmed on Infantry Leggings, 43 auctions / 19 variants).
-- Buyers shop one version, so "cheapest" only means something inside a
-- version. Version = the name in the auction's link (carries the suffix)
-- plus item level (GetItemInfo(link) gives the real item level, confirmed;
-- crafted qualities differ by item level). Quality is read only for the label.
local function LinkName(link)
    local name = tostring(link or ""):match("|h%[(.-)%]|h")
    if not name then
        return nil
    end
    name = name:gsub("|A.-|a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return (name:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- THEORETICAL on AH auction links: crafted quality API (used the same way in
-- AuctionLookupService), with the quality icon in the link name as fallback.
local function LinkQuality(link)
    if C_TradeSkillUI and type(C_TradeSkillUI.GetItemCraftedQualityByItemInfo) == "function" then
        local ok, quality = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, link)
        if ok and tonumber(quality) then
            return tonumber(quality)
        end
    end
    local tier = tostring(link or ""):match("Quality%-[%w%-]-Tier(%d)")
    return tonumber(tier)
end

local function LinkItemLevel(link)
    local _, _, _, ilvl = GetItemInfo(link)
    if tonumber(ilvl) then
        return tonumber(ilvl)
    end
    local detailed = (C_Item and C_Item.GetDetailedItemLevelInfo) or _G.GetDetailedItemLevelInfo
    if detailed then
        local ok, value = pcall(detailed, link)
        if ok and tonumber(value) then
            return tonumber(value)
        end
    end
    return nil
end

-- Stats on the auction's item (Brian, 2026-11-16: Sin'dorei Snippers at one
-- item level come with different profession stats, and a buyer shops one
-- combination). Uses core's identity helpers, the same stat fingerprint the
-- item identity key uses (C_Item.GetItemStats). Returns the key form
-- ("MULTICRAFT+RESOURCEFULNESS"), a player label ("Multicraft + Resourcefulness",
-- secondary and profession stats only), and whether stats were read.
local function LinkStats(link)
    if not (C_Item and type(C_Item.GetItemStats) == "function") then
        return nil, nil, false
    end
    local ok, stats = pcall(C_Item.GetItemStats, link)
    if not ok or type(stats) ~= "table" then
        return nil, nil, false
    end
    local keys = {}
    for statKey in pairs(stats) do
        keys[#keys + 1] = tostring(statKey)
    end
    table.sort(keys)
    if #keys == 0 then
        return nil, nil, true
    end
    local joined = table.concat(keys, "|")
    local adapters = PocketCFO and PocketCFO.ItemIdentityAdapters
    local fingerprint = adapters and adapters.NormalizeVariantStatFingerprint
        and adapters:NormalizeVariantStatFingerprint(joined) or joined
    local label
    local variant = adapters and adapters.LegacyVariantStatFingerprint and adapters:LegacyVariantStatFingerprint(joined)
    if variant then
        local names = {}
        for statName in variant:gmatch("[^|]+") do
            local shown = _G[statName]
            if type(shown) ~= "string" or shown == "" then
                shown = statName:gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""):gsub("_", " "):lower()
            end
            names[#names + 1] = shown
        end
        label = table.concat(names, " + ")
    end
    return fingerprint, label, true
end

local function VersionOf(run, link)
    if not link then
        return { key = "?" }
    end
    run.versionCache = run.versionCache or {}
    local cached = run.versionCache[link]
    if cached then
        return cached
    end
    local name = LinkName(link) or "?"
    local ilvl = LinkItemLevel(link)
    local base = run.item and run.item.baseName
    local suffix
    if base and name ~= base then
        if name:sub(1, #base) == base then
            suffix = name:sub(#base + 1):gsub("^%s+", "")
        else
            suffix = name
        end
        if suffix == "" then suffix = nil end
    end
    local stats, statLabel, statsRead = LinkStats(link)
    local version = {
        key = name .. "|" .. tostring(ilvl or "?") .. "|" .. tostring(stats or ""),
        suffix = suffix,
        quality = LinkQuality(link),
        ilvl = ilvl,
        stats = stats,
        statLabel = statLabel,
    }
    -- Only keep it once the item level and stats are known (cold item cache).
    if ilvl and statsRead then
        run.versionCache[link] = version
    end
    return version
end

-- Gear and other non-stacking items: auctions[auctionID] = { price, qty, link, timeLeft, own, version }
local function ReadItemSnapshot(itemKey, run)
    local snap = { mode = "item", auctions = {}, rows = 0, full = true }
    local okCount, count = pcall(C_AuctionHouse.GetNumItemSearchResults, itemKey)
    count = okCount and tonumber(count) or 0
    snap.rows = count
    for index = 1, count do
        local ok, row = pcall(C_AuctionHouse.GetItemSearchResultInfo, itemKey, index)
        if ok and type(row) == "table" then
            if index == 1 then
                snap.rawKeys = RawKeys(row)
            end
            local id = row.auctionID
            if id then
                snap.auctions[id] = {
                    price = tonumber(row.buyoutAmount),
                    qty = tonumber(row.quantity) or 1,
                    link = row.itemLink,
                    timeLeft = row.timeLeft,
                    own = row.containsOwnerItem == true or row.containsAccountItem == true,
                }
                local version = VersionOf(run, row.itemLink)
                snap.auctions[id].version = version.key
                snap.versionInfo = snap.versionInfo or {}
                snap.versionInfo[version.key] = version
            end
        end
    end
    if type(C_AuctionHouse.HasFullItemSearchResults) == "function" then
        local okFull, full = pcall(C_AuctionHouse.HasFullItemSearchResults, itemKey)
        snap.full = okFull and full ~= false
    end
    return snap
end

-- Lowest price, total units, own units and highest price seen (others only for lowest/total).
local function Summarize(snap)
    local lowest, lowestAll, highest, total, own = nil, nil, nil, 0, 0
    local hashParts = {}
    if snap.mode == "commodity" then
        local prices = {}
        for price in pairs(snap.ladder) do
            prices[#prices + 1] = price
        end
        table.sort(prices)
        for _, price in ipairs(prices) do
            local entry = snap.ladder[price]
            local others = math.max(0, entry.qty - entry.own)
            own = own + entry.own
            total = total + others
            if others > 0 and not lowest then
                lowest = price
            end
            if entry.qty > 0 and not lowestAll then
                lowestAll = price
            end
            highest = price
            hashParts[#hashParts + 1] = price .. "x" .. entry.qty
        end
        snap.sortedPrices = prices
        -- Row detail for the cheapest levels (data capture for hidden churn).
        snap.cheap = {}
        for i = 1, math.min(SalesWatch.CHEAP_LEVELS_SAVED, #prices) do
            local entry = snap.ladder[prices[i]]
            -- Full seller list (Brian's ink test, 2026-11-16: do names track
            -- who posted / cancelled / reposted?). mine = numOwnerItems.
            snap.cheap[i] = string.format("%.0f qty=%d mine=%d rows=%d id=%s tl=%s..%s owners=%d[%s]",
                prices[i], entry.qty, entry.own, entry.rows, table.concat(entry.ids, "/"),
                tostring(entry.minTimeLeft), tostring(entry.maxTimeLeft), entry.ownerCount or 0,
                table.concat(entry.owners, ","))
        end
    else
        local ids = {}
        snap.versionLowest, snap.versionListed = {}, {}
        for id, auction in pairs(snap.auctions) do
            ids[#ids + 1] = id
            local v = auction.version or "?"
            snap.versionListed[v] = (snap.versionListed[v] or 0) + auction.qty
            if auction.price and (not snap.versionLowest[v] or auction.price < snap.versionLowest[v]) then
                snap.versionLowest[v] = auction.price
            end
            if auction.own then
                own = own + auction.qty
            else
                total = total + auction.qty
                if auction.price and (not lowest or auction.price < lowest) then
                    lowest = auction.price
                end
            end
            if auction.price and (not lowestAll or auction.price < lowestAll) then
                lowestAll = auction.price
            end
            if auction.price and (not highest or auction.price > highest) then
                highest = auction.price
            end
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
            hashParts[#hashParts + 1] = tostring(id)
        end
    end
    snap.lowest = lowest
    snap.lowestAll = lowestAll
    snap.highest = highest
    snap.total = total
    snap.own = own
    snap.hash = #hashParts > 0 and (#hashParts .. ":" .. tostring(string.len(table.concat(hashParts, ","))) .. ":"
        .. table.concat(hashParts, ","):sub(1, 40)) or "empty"
end

---------------------------------------------------------------------------
-- Comparing two snapshots
---------------------------------------------------------------------------

local function NewStep()
    return { soldMine = 0, soldCheap = 0, leftHigher = 0, newListed = 0 }
end

-- When either search came back partial, only compare prices both covered.
local function PriceCap(prev, cur)
    if prev.full and cur.full then
        return nil
    end
    return math.min(prev.highest or 0, cur.highest or 0)
end

-- Did you cancel one of your own auctions around this step? Then a drop in
-- your own count is not counted as a sale.
local function OwnCancelInStep(run, prev, cur)
    local at = run.ownCancelAt
    return at ~= nil and at >= (run.startedAt + (prev.t or 0)) - 5 and at <= (run.startedAt + (cur.t or 0)) + 5
end

-- Units leaving price p were reachable by a buyer when nothing cheaper is
-- listed afterwards (every cheaper price emptied, no new cheaper listing).
local function NothingCheaperNow(cur, price, lowestOverride)
    local lowest = lowestOverride or cur.lowestAll
    return lowest == nil or lowest >= price
end

-- Commodity: the ID shown for a price looks like its OLDEST auction (it
-- stays while newer auctions join; when the oldest leaves it moves to the
-- next oldest: Oily Blackmouth 1.87s, 101958803 -> 101959207, Forever
-- 2026-11-16). Theoretical. So a changed ID alone only means the oldest
-- auction left. The price emptied and was posted again only when the new ID
-- is newer than every ID in the previous refresh (created during the step,
-- so everything older at that price is gone): Silverleaf 25c.
local function HighestId(snap)
    local highest = 0
    for _, entry in pairs(snap.ladder) do
        for _, id in ipairs(entry.ids or {}) do
            local n = tonumber(id)
            if n and n > highest then
                highest = n
            end
        end
    end
    return highest
end

local function WasRefilled(before, after, prevHighestId)
    if not before or not after or #before.ids == 0 or #after.ids == 0 then
        return false
    end
    for _, b in ipairs(after.ids) do
        local n = tonumber(b)
        if not n or n <= prevHighestId then
            return false
        end
    end
    return true
end

-- Gear: only the cheapest auction of its version counts as likely sold, with
-- nothing cheaper of that version listed afterwards. Anything else gone is
-- canceled or expired (Brian, 2026-11-16: buying a pricier copy of the same
-- version on purpose is rare).
local function IsUncutCheapest(prev, cur, auction)
    local v = auction.version or "?"
    local before = prev.versionLowest and prev.versionLowest[v]
    local after = cur.versionLowest and cur.versionLowest[v]
    return before ~= nil and auction.price == before and (after == nil or after >= auction.price)
end

local function VersionStep(step, v)
    step.versions = step.versions or {}
    local entry = step.versions[v]
    if not entry then
        entry = NewStep()
        step.versions[v] = entry
    end
    return entry
end

local function DiffCommodity(run, prev, cur)
    local step = NewStep()
    local cap = PriceCap(prev, cur)

    local seen, prices = {}, {}
    for price in pairs(prev.ladder) do
        if not cap or price <= cap then seen[price] = true end
    end
    for price in pairs(cur.ladder) do
        if not cap or price <= cap then seen[price] = true end
    end
    for price in pairs(seen) do
        prices[#prices + 1] = price
    end

    local function Get(snap, price)
        local entry = snap.ladder[price]
        if not entry then
            return 0, 0
        end
        return math.max(0, entry.qty - entry.own), entry.own
    end

    -- Cheapest price that was listed before the step and still is (never
    -- emptied). Only those block buyers from the prices above them. A
    -- refilled price was empty at some point; a brand-new cheaper price was
    -- most likely posted right after a buy (Brian, 2026-11-16: Oily
    -- Blackmouth, 1,000 bought bottom up while 13 went up at a new 1.80s;
    -- sellers who cancel to reprice were undercut by a price already listed).
    local prevHighestId = HighestId(prev)
    local refilled, lowestKept = {}, nil
    for price, entry in pairs(cur.ladder) do
        if entry.qty > 0 then
            local before = prev.ladder[price]
            if WasRefilled(before, entry, prevHighestId) then
                refilled[price] = true
            elseif before and before.qty > 0 and (not lowestKept or price < lowestKept) then
                lowestKept = price
            end
        end
    end

    local mineBefore, mineAfter = 0, 0
    for _, price in ipairs(prices) do
        local othersBefore, ownBefore = Get(prev, price)
        local othersAfter, ownAfter = Get(cur, price)
        mineBefore = mineBefore + ownBefore
        mineAfter = mineAfter + ownAfter
        local gone, added = 0, 0
        if refilled[price] then
            gone, added = othersBefore, othersAfter
        elseif othersBefore > othersAfter then
            gone = othersBefore - othersAfter
        else
            added = othersAfter - othersBefore
        end
        if gone > 0 then
            -- No old price left at all: nothing blocks.
            if NothingCheaperNow(cur, price, lowestKept or math.huge) then
                step.soldCheap = step.soldCheap + gone
            else
                step.leftHigher = step.leftHigher + gone
            end
        end
        step.newListed = step.newListed + added
    end
    if mineAfter < mineBefore and not OwnCancelInStep(run, prev, cur) then
        step.soldMine = mineBefore - mineAfter
    end
    return step
end

local function DiffItems(run, prev, cur)
    local step = NewStep()
    local cap = PriceCap(prev, cur)
    local function InScope(auction)
        return not cap or not auction.price or auction.price <= cap
    end
    local cancelled = OwnCancelInStep(run, prev, cur)

    local function Add(key, auction)
        step[key] = step[key] + auction.qty
        local entry = VersionStep(step, auction.version or "?")
        entry[key] = entry[key] + auction.qty
    end
    for id, auction in pairs(prev.auctions) do
        if not cur.auctions[id] and InScope(auction) then
            if auction.own then
                if not cancelled then
                    Add("soldMine", auction)
                end
            elseif auction.price and IsUncutCheapest(prev, cur, auction) then
                Add("soldCheap", auction)
            else
                Add("leftHigher", auction)
            end
        end
    end
    for id, auction in pairs(cur.auctions) do
        if not prev.auctions[id] and not auction.own and InScope(auction) then
            Add("newListed", auction)
        end
    end
    return step
end

---------------------------------------------------------------------------
-- Run control
---------------------------------------------------------------------------

function SalesWatch:IsRunning()
    return self.run ~= nil and self.run.status == "running"
end

function SalesWatch:GetRun()
    return self.run
end

function SalesWatch:SetListener(fn)
    self.listener = fn
end

function SalesWatch:Notify()
    if type(self.listener) == "function" then
        local ok, err = pcall(self.listener, self.run)
        if not ok then
            SessionLog("listener error %s", tostring(err))
        end
    end
end

function SalesWatch:StartTicker()
    if self.ticker then
        self.ticker:Cancel()
    end
    self.ticker = C_Timer.NewTicker(1, function()
        self:OnTick()
    end)
    self:OnTick()
end

-- item = { itemID, itemName, itemLink, icon, equipLoc | isEquipment }
function SalesWatch:Start(item)
    if self:IsRunning() then
        return false, "A watch is already running."
    end
    if type(item) ~= "table" or not tonumber(item.itemID) then
        return false, "Pick an item first."
    end
    if not C_AuctionHouse or type(C_AuctionHouse.SendSearchQuery) ~= "function" then
        return false, "The Auction House isn't available."
    end
    if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
        return false, "Open the Auction House first."
    end

    local itemID = tonumber(item.itemID)
    local now = Now()
    self.run = {
        item = {
            itemID = itemID,
            itemName = item.itemName,
            itemLink = item.itemLink,
            icon = item.icon,
            isEquipment = item.isEquipment == true or IsEquipment(item.equipLoc),
            -- Base name (no suffix) from the item ID, to split off suffixes.
            baseName = (GetItemInfo and GetItemInfo(itemID)) or item.itemName,
        },
        status = "running",
        startedAt = now,
        startedTime = time and time() or 0,
        interval = self.INTERVAL,
        planned = self.DURATION,     -- seconds of watching asked for (extends add to it)
        watchedBefore = 0,           -- seconds watched in finished segments
        segmentStart = now,
        segmentEnd = now + self.DURATION,
        segments = 1,
        baselineNext = true,         -- next refresh starts a new comparison chain
        snapshots = {},
        steps = {},
        totals = NewStep(),
        versions = {},               -- gear only: per version, see TrackVersions
        sent = 0,
        missed = 0,
        throttleWaits = 0,
        nextSendAt = 0,
    }
    SessionLog("start itemID=%s name=%s equipment=%s", tostring(itemID), tostring(item.itemName),
        tostring(self.run.item.isEquipment))
    self:StartTicker()
    return true
end

-- Seconds actually spent watching (gaps between segments left out).
function SalesWatch:WatchedSeconds(run)
    run = run or self.run
    if not run then
        return 0
    end
    local watched = run.watchedBefore or 0
    if run.status == "running" then
        watched = watched + math.max(0, math.min(Now(), run.segmentEnd) - run.segmentStart)
    end
    return watched
end

-- How much "Watch 3 more minutes" would add for this item (0 = can't).
function SalesWatch:ExtendAmount(item)
    local run = self.run
    if not run or #run.snapshots == 0 then
        return 0
    end
    if item and tonumber(item.itemID) ~= run.item.itemID then
        return 0
    end
    local planned = run.status == "running" and run.planned or (run.watchedBefore or 0)
    return math.max(0, math.min(self.EXTEND, self.MAX_TOTAL - planned))
end

-- Running: adds to the end. Finished / stopped: continues the same watch;
-- the first refresh after the gap is a new starting point (no comparison
-- across the gap). Totals carry over.
function SalesWatch:Extend(item)
    local add = self:ExtendAmount(item)
    if add <= 0 then
        return false, "That's the 10 minute limit for one watch."
    end
    local run = self.run
    if run.status == "running" then
        run.segmentEnd = run.segmentEnd + add
        run.planned = run.planned + add
        run.finalSent = nil
        self:Notify()
        return true
    end
    if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
        return false, "Open the Auction House first."
    end
    local now = Now()
    run.status = "running"
    run.stopReason = nil
    run.finishedAt = nil
    run.planned = (run.watchedBefore or 0) + add
    run.segmentStart = now
    run.segmentEnd = now + add
    run.segments = (run.segments or 1) + 1
    run.finalSent = nil
    run.baselineNext = true
    run.pending = nil
    run.nextSendAt = 0
    SessionLog("extend +%ds (segment %d)", add, run.segments)
    self:StartTicker()
    return true
end

function SalesWatch:Stop(reason)
    if not self:IsRunning() then
        return
    end
    self:Finish("stopped", reason or "stopped")
end

function SalesWatch:Finish(status, reason)
    local run = self.run
    if not run then
        return
    end
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
    local now = Now()
    if run.status == "running" then
        run.watchedBefore = (run.watchedBefore or 0) + math.max(0, math.min(now, run.segmentEnd) - run.segmentStart)
    end
    if status ~= "done" then
        run.planned = run.watchedBefore
    end
    run.status = status
    run.stopReason = reason
    run.pending = nil
    run.finishedAt = now
    SessionLog("finish status=%s reason=%s snapshots=%d sent=%d missed=%d", tostring(status), tostring(reason),
        #run.snapshots, run.sent, run.missed)
    self:Save(run)
    self:Notify()
end

function SalesWatch:SendSearch()
    local run = self.run
    if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
        run.throttleWaits = run.throttleWaits + 1
        return
    end
    local itemID = run.item.itemID
    local ok
    if run.item.isEquipment and type(C_AuctionHouse.SendSellSearchQuery) == "function" then
        local key = C_AuctionHouse.MakeItemKey and C_AuctionHouse.MakeItemKey(itemID) or { itemID = itemID }
        key.itemLevel = 0
        key.itemSuffix = key.itemSuffix or 0
        key.battlePetSpeciesID = key.battlePetSpeciesID or 0
        ok = pcall(C_AuctionHouse.SendSellSearchQuery, key, BuildSorts(), true)
    else
        -- Plain key with no itemLevel: confirmed to trigger
        -- COMMODITY_SEARCH_RESULTS_UPDATED for commodities (api-findings).
        local key = { itemID = itemID, battlePetSpeciesID = 0, itemSuffix = 0 }
        ok = pcall(C_AuctionHouse.SendSearchQuery, key, {}, false)
    end
    local now = Now()
    run.sent = run.sent + 1
    run.nextSendAt = now + run.interval
    if ok then
        run.pending = { sentAt = now }
    else
        run.missed = run.missed + 1
        SessionLog("search call failed itemID=%s", tostring(itemID))
    end
end

function SalesWatch:OnTick()
    local run = self.run
    if not run or run.status ~= "running" then
        return
    end
    if not AuctionHouseFrame or not AuctionHouseFrame:IsShown() then
        self:Finish("stopped", "ah-closed")
        return
    end
    local now = Now()

    if run.pending and now - run.pending.sentAt > self.RESPONSE_TIMEOUT then
        run.missed = run.missed + 1
        SessionLog("no answer within %ds (search %d)", self.RESPONSE_TIMEOUT, run.sent)
        run.pending = nil
    end

    if now >= run.segmentEnd then
        -- One last refresh when the clock hits zero so the results cover the
        -- whole watch (Brian, 2026-11-16: ended at 2:57 without it).
        if run.pending then
            return
        end
        if not run.finalSent then
            run.finalSent = true
            self:SendSearch()
            if run.pending then
                return
            end
        end
        self:Finish("done", "done")
        return
    end

    if not run.pending and now >= run.nextSendAt then
        self:SendSearch()
    end
    self:Notify()
end

function SalesWatch:Capture(snap)
    local run = self.run
    run.pending = nil
    if run.mode and run.mode ~= snap.mode then
        return
    end
    run.mode = snap.mode
    snap.t = Now() - run.startedAt
    Summarize(snap)
    self:TrackVersions(run, snap)

    local index = #run.snapshots + 1
    run.snapshots[index] = snap
    local isBaseline = run.baselineNext == true
    run.baselineNext = false

    local prev = run.snapshots[index - 1]
    if isBaseline or not prev then
        -- New starting point (first refresh, or first after a gap): nothing
        -- to compare; units already listed count as old.
        snap.baseline = true
        SessionLog("refresh %d t=%.1f baseline mode=%s rows=%d full=%s lowest=%s total=%d own=%d", index, snap.t,
            snap.mode, snap.rows, tostring(snap.full), tostring(snap.lowest), snap.total, snap.own)
        self:Notify()
        return
    end

    snap.changed = prev.hash ~= snap.hash
    local step = snap.mode == "commodity" and DiffCommodity(run, prev, snap) or DiffItems(run, prev, snap)
    step.t = snap.t
    step.dt = snap.t - prev.t
    run.steps[#run.steps + 1] = step
    for key, value in pairs(step) do
        if key ~= "t" and key ~= "dt" and type(value) == "number" then
            run.totals[key] = (run.totals[key] or 0) + value
        end
    end
    for v, counts in pairs(step.versions or {}) do
        local entry = run.versions[v]
        if entry then
            for key, value in pairs(counts) do
                entry[key] = (entry[key] or 0) + value
            end
        end
    end
    SessionLog("refresh %d t=%.1f rows=%d full=%s lowest=%s total=%d own=%d changed=%s mine=%d cheap=%d higher=%d new=%d",
        index, snap.t, snap.rows, tostring(snap.full), tostring(snap.lowest), snap.total, snap.own,
        tostring(snap.changed), step.soldMine, step.soldCheap, step.leftHigher, step.newListed)
    self:Notify()
end

function SalesWatch:OnCommodityResults(itemID)
    local run = self.run
    if not run or run.status ~= "running" or not run.pending then
        return
    end
    if tonumber(itemID) ~= run.item.itemID then
        return
    end
    self:Capture(ReadCommoditySnapshot(run.item.itemID))
end

function SalesWatch:OnItemResults(itemKey)
    local run = self.run
    if not run or run.status ~= "running" or not run.pending then
        return
    end
    if type(itemKey) ~= "table" or tonumber(itemKey.itemID) ~= run.item.itemID then
        return
    end
    self:Capture(ReadItemSnapshot(itemKey, run))
end

-- Gear: listed count and cheapest price per version, first seen and now.
function SalesWatch:TrackVersions(run, snap)
    if snap.mode ~= "item" then
        return
    end
    run.versions = run.versions or {}
    for v, info in pairs(snap.versionInfo or {}) do
        local entry = run.versions[v]
        if not entry then
            entry = NewStep()
            entry.suffix, entry.quality, entry.ilvl = info.suffix, info.quality, info.ilvl
            entry.stats, entry.statLabel = info.stats, info.statLabel
            entry.firstListed = snap.versionListed[v] or 0
            entry.firstLowest = snap.versionLowest[v]
            run.versions[v] = entry
        end
    end
    for v, entry in pairs(run.versions) do
        entry.lastListed = snap.versionListed and snap.versionListed[v] or 0
        entry.lastLowest = snap.versionLowest and snap.versionLowest[v] or nil
    end
end

-- Player-facing name of a version: suffix, then quality; item level only
-- when nothing else tells versions apart; then the secondary / profession
-- stats when the name has no suffix (a suffix already names the stats).
function SalesWatch:VersionLabel(run, entry)
    local parts = {}
    if entry.suffix then
        parts[#parts + 1] = entry.suffix
    end
    if entry.quality then
        parts[#parts + 1] = "Quality " .. entry.quality
    elseif entry.ilvl and self:CountItemLevels(run) > 1 then
        parts[#parts + 1] = "Item level " .. entry.ilvl
    end
    if not entry.suffix and entry.statLabel then
        parts[#parts + 1] = entry.statLabel
    end
    if #parts == 0 then
        return (run.item and run.item.baseName) or "This item"
    end
    return table.concat(parts, ", ")
end

function SalesWatch:CountItemLevels(run)
    local seen, count = {}, 0
    for _, entry in pairs(run and run.versions or {}) do
        if entry.ilvl and not seen[entry.ilvl] then
            seen[entry.ilvl] = true
            count = count + 1
        end
    end
    return count
end

-- Gear: versions where something happened (most sold first), the number of
-- versions with no change, and the total number of versions seen.
function SalesWatch:GetVersionRows(run)
    run = run or self.run
    local active, quiet, total = {}, 0, 0
    for _, entry in pairs(run and run.versions or {}) do
        total = total + 1
        local sold = (entry.soldMine or 0) + (entry.soldCheap or 0)
        if sold + (entry.leftHigher or 0) + (entry.newListed or 0) > 0 then
            active[#active + 1] = { entry = entry, sold = sold, label = self:VersionLabel(run, entry) }
        else
            quiet = quiet + 1
        end
    end
    table.sort(active, function(a, b)
        if a.sold ~= b.sold then
            return a.sold > b.sold
        end
        if (a.entry.leftHigher or 0) ~= (b.entry.leftHigher or 0) then
            return (a.entry.leftHigher or 0) > (b.entry.leftHigher or 0)
        end
        return a.label < b.label
    end)
    return active, quiet, total
end

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------

-- Seconds covered by comparisons (gaps between segments left out).
function SalesWatch:ObservedSeconds(run)
    run = run or self.run
    local total = 0
    for _, step in ipairs(run and run.steps or {}) do
        total = total + (step.dt or 0)
    end
    return total
end

function SalesWatch:SoldCount(run)
    run = run or self.run
    return run and (run.totals.soldMine + run.totals.soldCheap) or 0
end

-- Saved for later analysis only; not shown (one bulk buy x20 misleads).
function SalesWatch:PerHour(run)
    local seconds = self:ObservedSeconds(run)
    if seconds <= 0 then
        return nil
    end
    return math.floor(self:SoldCount(run) / seconds * 3600 + 0.5)
end

local function SaveLadder(snap)
    local out = {}
    if snap.mode == "commodity" then
        for i, price in ipairs(snap.sortedPrices or {}) do
            if i > SalesWatch.MAX_SAVED_LADDER_ROWS then
                break
            end
            local entry = snap.ladder[price]
            out[#out + 1] = string.format("%.0f:%d:%d", price, entry.qty, entry.own)
        end
    else
        for id, auction in pairs(snap.auctions) do
            out[#out + 1] = string.format("%s:%s:%d:%s:%s:%s", tostring(id), tostring(auction.price), auction.qty,
                tostring(auction.timeLeft), auction.own and "own" or "", tostring(auction.version))
        end
        table.sort(out)
        while #out > SalesWatch.MAX_SAVED_LADDER_ROWS do
            table.remove(out)
        end
    end
    return out
end

function SalesWatch:Save(run)
    local saved = SavedDB()
    if not saved or #run.snapshots == 0 then
        return
    end
    local first, last = run.snapshots[1], run.snapshots[#run.snapshots]
    local record = {
        itemID = run.item.itemID,
        itemName = run.item.itemName,
        itemLink = run.item.itemLink,
        mode = run.mode,
        flavor = PocketCFO and PocketCFO.flavor or "retail",
        startedAt = run.startedTime,
        status = run.status,
        stopReason = run.stopReason,
        interval = run.interval,
        duration = run.planned,
        observedSeconds = self:ObservedSeconds(run),
        sent = run.sent,
        missed = run.missed,
        throttleWaits = run.throttleWaits,
        totals = run.totals,
        versions = run.mode == "item" and run.versions or nil,
        perHour = self:PerHour(run),
        watchedSeconds = run.watchedBefore,
        segments = run.segments,
        startLowest = first.lowest,
        endLowest = last.lowest,
        startTotal = first.total,
        endTotal = last.total,
        rawKeys = first.rawKeys,
        steps = run.steps,
        snapshots = {},
    }
    for i, snap in ipairs(run.snapshots) do
        record.snapshots[i] = {
            t = snap.t,
            rows = snap.rows,
            full = snap.full,
            lowest = snap.lowest,
            total = snap.total,
            own = snap.own,
            hash = snap.hash,
            changed = snap.changed,
            baseline = snap.baseline,
            cheap = snap.cheap,
            ladder = (i == 1 or i == #run.snapshots or i == 2) and SaveLadder(snap) or nil,
        }
    end
    -- An extended watch replaces its own earlier saved record.
    local replaced = false
    if run.savedRecord then
        for i, existing in ipairs(saved) do
            if existing == run.savedRecord then
                saved[i] = record
                replaced = true
                break
            end
        end
    end
    if not replaced then
        saved[#saved + 1] = record
    end
    run.savedRecord = record
    while #saved > self.MAX_SAVED do
        table.remove(saved, 1)
    end
    -- Older watches keep only their summary (Brian, 2026-11-16): item, time,
    -- totals, cheapest and listed start/end, and the gear versions that had
    -- activity. The refresh-by-refresh detail is what makes a watch large
    -- and is only used by /mcgd saleswatch.
    for i = 1, #saved - self.MAX_SAVED_FULL do
        self:TrimToSummary(saved[i])
    end
end

function SalesWatch:TrimToSummary(record)
    if type(record) ~= "table" or record.summaryOnly then
        return
    end
    record.steps = nil
    record.snapshots = nil
    record.rawKeys = nil
    if type(record.versions) == "table" then
        local kept = {}
        for key, v in pairs(record.versions) do
            local moved = (v.soldMine or 0) + (v.soldCheap or 0) + (v.leftHigher or 0) + (v.newListed or 0)
            if moved > 0 then
                kept[key] = v
            end
        end
        record.versions = next(kept) and kept or nil
    end
    record.summaryOnly = true
end

function SalesWatch:GetSavedWatches()
    return SavedDB() or {}
end

---------------------------------------------------------------------------
-- Events (plain frame: CraftSim's bundled AceEvent can shift handler args)
---------------------------------------------------------------------------

function SalesWatch:OnEnable()
    if self.eventFrame then
        return
    end
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
    frame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
    frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
            self:OnCommodityResults(...)
        elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
            self:OnItemResults(...)
        elseif event == "AUCTION_HOUSE_CLOSED" then
            self:Stop("ah-closed")
        end
    end)
    self.eventFrame = frame

    -- Your own cancels (Blizzard UI, TSM, Auctionator all go through this),
    -- so a drop in your own count right after one isn't counted as a sale.
    if C_AuctionHouse and type(C_AuctionHouse.CancelAuction) == "function" and hooksecurefunc then
        hooksecurefunc(C_AuctionHouse, "CancelAuction", function()
            if self.run and self.run.status == "running" then
                self.run.ownCancelAt = Now()
            end
        end)
    end
end
