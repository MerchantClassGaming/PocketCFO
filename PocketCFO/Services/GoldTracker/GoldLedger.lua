-- PocketCFO/Services/GoldTracker/GoldLedger.lua
-- Gold Sources, step 1: record every change in a character's gold and tag it
-- with what was happening at the time. Categories always add up to the real
-- change in gold; anything not recognized lands in "other".
-- Design: project doc claude/Gold_Sources_Design.md
--
-- Storage: the Item Ledger (2026-10-30, see "Storage" below): one gold entry
-- per change with category, profession, item detail (name + quantity for AH
-- and vendor sales, purchases, training, deposits) and the earned time.
-- (Until 2026-10-30: goldLedger.days[dayKey][characterGUID][category][professionKey].)
-- AH and vendor sales are credited to a profession by item (see ProfessionForItem).
-- AH sales are dated to the day they sold (mail is held 30 days from the
-- sale), not the day the gold was collected.
-- dayKey is the local date "YYYY-MM-DD". professionKey is the base profession
-- skill line ID as a string (e.g. "171") or "none".
--
-- How tagging works: PLAYER_MONEY changes are held for FLUSH_DELAY seconds so
-- related events can claim them regardless of which event arrives first.
--   1. A claim with a matching exact amount wins (quest reward, vendor sale,
--      warband deposit/withdraw).
--   2. Gold gained with the mailbox open is matched against the waiting list of
--      mail seen holding gold (see the Mailbox section).
--   3. Then a claim with no amount whose direction matches (order completed,
--      loot-money message, container opened from your bags, gold mailed to
--      your own character).
--   3b. Gold gained within MAIL_MATCH_AFTER_CLOSE of a mailbox visit is also
--      matched against the waiting list (mail gold can arrive late).
--   4. Then a window rule: gold IN only by merchant or trade (the only ways
--      gold goes up there); gold OUT by trainer, flight master, merchant
--      (repair mode first), AH, mail, trade, bank / barber / transmog, guild bank.
--   5. Otherwise "other" (shown as Unknown) and logged in goldLedger.unknownLog
--      (/mcg goldunknown) so each gap can be found and given a real rule.
-- Rule: a category is only assigned for a specific reason, never as a guess.
--
-- Sends AceEvent message "MCG_GOLD_LEDGER_UPDATED" after each batch is saved.
-- Storage (2026-10-30, claude/Ledger_Rebuild_Checklist.md item 8): every
-- recorded change is written into the Item Ledger as kind "gold" (category,
-- profession, item detail, sale date); the Income and Spending views read it
-- from there. The old goldLedger.days history is moved into the ledger once
-- (MoveDaysToItemLedger) and deleted when the totals match. goldLedger keeps
-- only its matching state: mail waiting list, mail log, unknown log.
-- Container gold: claimed from LootReader's MCG_CONTAINER_CLICK (one
-- container detector); the bag hook here is only for vendor sales.
--
-- Spending detail (2026-10-27, Flavor: Both). Claims made at the moment of the
-- action, so the gold drop that follows is tagged with what was bought:
--   - BuyMerchantItem / BuybackItem: vendor purchases, item + quantity.
--   - RepairAllItems: repair cost read before the click (cached on merchant
--     open/update and durability change). Single-item repairs: merchant open +
--     InRepairMode() at the gold change.
--   - BuyTrainerService: training, service name as the item.
--   - C_AuctionHouse.PlaceBid / ConfirmCommoditiesPurchase: AH purchases.
--   - C_AuctionHouse.PostItem / PostCommodity: AH deposits.
--   - Flight paths, bank slots, barber, transmog, guild bank: window rules.
--   Claims marked "loose" carry an expected amount but also match by
--   direction, so a rounding difference never loses the item detail.
--   All Theoretical until seen in-game; each claim writes a session log line.
--
-- Theoretical until seen in-game (verify via the session log with /mcg debug on):
--   - hooksecurefunc on C_CraftingOrders.FulfillOrder fires on order completion
--     and C_CraftingOrders.GetClaimedOrder() still returns the order then.
--   - QUEST_TURNED_IN payload (questID, xpReward, moneyReward).
--   - PLAYER_MONEY and ACCOUNT_MONEY for one warband transfer arrive within
--     FLUSH_DELAY of each other.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local GoldLedger = PocketCFO:NewModule("GoldLedger", "AceEvent-3.0")

-- "You loot X" (CHAT_MSG_MONEY) arrives after PLAYER_MONEY: ~1.0s on the
-- Forever beta (event capture 2026-10-20) and 0.93s on retail (event capture
-- 2026-10-27), so a 0.5s wait filed looted coin as Unknown. Both flavors wait
-- 2s (retail changed from 0.5 on 2026-10-27).
local FLUSH_DELAY = 2
local CLAIM_TTL = 5
local ORDER_CLAIM_TTL = 10
local WINDOW_GRACE = 2
local AH_MAIL_DAYS = 30

-- Enum.CraftingOrderType: Public = 0, Guild = 1, Personal = 2, Npc = 3
local ORDER_CATEGORY = {
    [0] = "order_public",
    [1] = "order_guild",
    [2] = "order_personal",
    [3] = "order_patron",
}

-- Window rules, used only when no claim matches. Gold coming IN is credited by
-- window only where that window is the only way gold can go up (selling to a
-- vendor, a trade). Anything else coming in is "other" (shown as Unknown).
-- Spending (not displayed yet) still uses every window.
local INCOME_WINDOW_CATEGORY = {
    { window = "merchant", category = "vendor" },
    { window = "trade",    category = "trade" },
}
-- Order matters: the first open window wins. Repair mode at a merchant is
-- checked before these (see Classify).
local SPEND_WINDOW_CATEGORY = {
    { window = "trainer",   category = "training" },
    { window = "taxi",      category = "flight" },
    { window = "merchant",  category = "vendor" },
    -- AH spending no hook explained counts as a purchase and is logged to
    -- /mcg goldunknown (2026-11-01). "auction" is AH sales only.
    { window = "auction",   category = "auction_buy" },
    { window = "mail",      category = "mail" },
    { window = "trade",     category = "trade" },
    { window = "guildbank", category = "guild_bank" },
    { window = "bank",      category = "services" },
    { window = "barber",    category = "services" },
    { window = "transmog",  category = "services" },
}
local TRACKED_WINDOWS = { "merchant", "trade", "auction", "mail", "bank",
    "trainer", "taxi", "guildbank", "barber", "transmog" }

local WINDOW_EVENTS = {
    MERCHANT_SHOW       = { "merchant", true },
    MERCHANT_CLOSED     = { "merchant", false },
    TRADE_SHOW          = { "trade", true },
    TRADE_CLOSED        = { "trade", false },
    AUCTION_HOUSE_SHOW  = { "auction", true },
    AUCTION_HOUSE_CLOSED = { "auction", false },
    MAIL_SHOW           = { "mail", true },
    MAIL_CLOSED         = { "mail", false },
    BANKFRAME_OPENED    = { "bank", true },
    BANKFRAME_CLOSED    = { "bank", false },
}

-- Window events added for spending (2026-10-27). Registered inside pcall: an
-- event a flavor doesn't have must not stop the rest from registering.
local OPTIONAL_WINDOW_EVENTS = {
    TRAINER_SHOW          = { "trainer", true },
    TRAINER_CLOSED        = { "trainer", false },
    TAXIMAP_OPENED        = { "taxi", true },
    TAXIMAP_CLOSED        = { "taxi", false },
    GUILDBANKFRAME_OPENED = { "guildbank", true },
    GUILDBANKFRAME_CLOSED = { "guildbank", false },
    BARBER_SHOP_OPEN      = { "barber", true },
    BARBER_SHOP_CLOSE     = { "barber", false },
    TRANSMOGRIFY_OPEN     = { "transmog", true },
    TRANSMOGRIFY_CLOSE    = { "transmog", false },
}

local LOOSE_CLAIM_TTL = 5
local AH_BUY_CLAIM_TTL = 10

-- Interaction types (PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE arg1).
-- MailInfo = 17 confirmed in-game 2026-10-19. Merchant / Auctioneer / Banker
-- are read from Enum.PlayerInteractionType (Theoretical until seen).
local INTERACTION_WINDOWS = {}
do
    local types = Enum and Enum.PlayerInteractionType or {}
    INTERACTION_WINDOWS[types.MailInfo or 17] = "mail"
    if types.Merchant then INTERACTION_WINDOWS[types.Merchant] = "merchant" end
    if types.Auctioneer then INTERACTION_WINDOWS[types.Auctioneer] = "auction" end
    if types.Banker then INTERACTION_WINDOWS[types.Banker] = "bank" end
    if types.AccountBanker then INTERACTION_WINDOWS[types.AccountBanker] = "bank" end
    -- Spending windows (2026-10-27). Read by name only; a type a flavor
    -- doesn't have is simply absent. Theoretical until seen.
    if types.Trainer then INTERACTION_WINDOWS[types.Trainer] = "trainer" end
    if types.TaxiNode then INTERACTION_WINDOWS[types.TaxiNode] = "taxi" end
    if types.GuildBanker then INTERACTION_WINDOWS[types.GuildBanker] = "guildbank" end
    if types.Barber then INTERACTION_WINDOWS[types.Barber] = "barber" end
    if types.Transmogrifier then INTERACTION_WINDOWS[types.Transmogrifier] = "transmog" end
end

local MAIL_MATCH_AFTER_CLOSE = 300  -- seconds after a mailbox visit that late mail gold still matches
local MAIL_WAIT_DAYS = 31           -- waiting mail older than this is dropped (mail is gone by then)
local MAIL_SUBSET_CAP = 12          -- free-form combination search covers the newest N waiting mails
local MAIL_LOG_SIZE = 100
local LOOT_CLAIM_TTL = 3
local CONTAINER_CLAIM_TTL = 10
local UNKNOWN_LOG_SIZE = 50

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function SessionLog(msg, ...)
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] GoldLedger: " .. tostring(msg))
end

local function LedgerDB()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    globalDB.goldLedger = globalDB.goldLedger or {}
    return globalDB.goldLedger
end

local function DayKey(timestamp)
    return date("%Y-%m-%d", timestamp or time())
end

local function FormatCopper(copper)
    copper = tonumber(copper) or 0
    local sign = copper < 0 and "-" or "+"
    copper = math.abs(math.floor(copper))
    return string.format("%s%dg%02ds%02dc", sign,
        math.floor(copper / 10000), math.floor((copper % 10000) / 100), copper % 100)
end

local function StripRealm(name)
    if not name then
        return nil
    end
    return (string.match(tostring(name), "^([^%-]+)")) or tostring(name)
end

-- True when the name is one of this account's characters (the one check,
-- in ItemLedger since 2026-10-30).
local function IsOwnCharacter(name)
    local itemLedger = PocketCFO.ItemLedger
    return itemLedger ~= nil and itemLedger:IsOwnCharacter(name) or false
end

-- Gathered mats by trade goods subclass -> gathering profession.
-- Theoretical: subclass numbers (Leather 6, Metal & Stone 7, Herb 9) are taken
-- from Enum.ItemTradeGoodsSubclass when present; literals are the fallback.
local TRADEGOODS_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Tradegoods) or 7
local GATHERING_BY_SUBCLASS = {}
do
    local sub = Enum and Enum.ItemTradeGoodsSubclass or {}
    GATHERING_BY_SUBCLASS[sub.Leather or 6] = "393"       -- Skinning
    GATHERING_BY_SUBCLASS[sub.MetalAndStone or 7] = "186" -- Mining
    GATHERING_BY_SUBCLASS[sub.Herb or 9] = "182"          -- Herbalism
end

-- Profession credited for an item: the profession of a recipe that makes it
-- (RecipeRegistry, account-wide), else the gathering profession for raw mats,
-- else nil ("none"). Name-only lookups (AH sales) depend on the item being in
-- the client's item cache for the gathering check (Theoretical).
local function ProfessionForItem(itemID, itemName)
    local recipeRegistry = PocketCFO:GetModule("RecipeRegistry", true)
    if recipeRegistry and recipeRegistry.GetRecipeIDsForOutput then
        local ok, recipeIDs = pcall(recipeRegistry.GetRecipeIDsForOutput, recipeRegistry, itemID, itemName)
        if ok and type(recipeIDs) == "table" then
            for _, recipeID in ipairs(recipeIDs) do
                local record = recipeRegistry:GetRecipeRecord(recipeID)
                local professionID = record and tonumber(record.professionID)
                if professionID and PocketCFO.ProfessionRegistry
                    and PocketCFO.ProfessionRegistry:IsSupportedProfessionID(professionID) then
                    return tostring(professionID), "recipe"
                end
            end
        end
    end

    local getInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    local lookup = itemID or itemName
    if getInstant and lookup then
        local ok, _, _, _, _, _, classID, subclassID = pcall(getInstant, lookup)
        if ok and classID == TRADEGOODS_CLASS and GATHERING_BY_SUBCLASS[subclassID] then
            return GATHERING_BY_SUBCLASS[subclassID], "gathered"
        end
    end
    return nil, "none"
end

local function BaseProfessionKey()
    if C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo then
        local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
        if ok and type(info) == "table" and info.professionID then
            return tostring(info.professionID)
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

GoldLedger.lastMoney = nil
GoldLedger.lastAccountMoney = nil
GoldLedger.pending = {}
GoldLedger.claims = {}
GoldLedger.windowOpen = {}
GoldLedger.windowClosedAt = {}
GoldLedger.flushScheduled = false
GoldLedger.mailSeq = 0      -- order in which waiting mails were noted (inbox order)

function GoldLedger:IsWindowActive(window, now)
    if self.windowOpen[window] then
        return true
    end
    local closedAt = self.windowClosedAt[window]
    return closedAt ~= nil and (now - closedAt) <= WINDOW_GRACE
end

function GoldLedger:SnapshotWindows()
    local now = GetTime()
    local active = {}
    for _, window in ipairs(TRACKED_WINDOWS) do
        if self:IsWindowActive(window, now) then
            active[window] = true
        end
    end
    return active
end

-- claim = { category, profession, amount (exact signed copper or nil),
--           direction (1 / -1, used when amount is nil), reason, expiresAt }
-- Evidence of another gold source (order, quest, vendor sale, warband) means
-- you are not at the mailbox. Claims made AT the mailbox (mail to your own
-- character) and loot messages do not close it.
-- Theoretical: whether taking mail gold also fires CHAT_MSG_MONEY; loot is
-- excluded until confirmed so it can never end a real mailbox session.
-- Loot-money, container and quest claims never end a mailbox session.
local KEEPS_MAILBOX_OPEN = { looted = true, quest = true }

function GoldLedger:AddClaim(claim)
    claim.expiresAt = GetTime() + (claim.ttl or CLAIM_TTL)
    self.claims[#self.claims + 1] = claim
    if not claim.atMailbox and not KEEPS_MAILBOX_OPEN[claim.category] then
        self:LeaveMailbox("evidence:" .. tostring(claim.category))
    end
end

function GoldLedger:PruneClaims(now)
    local kept = {}
    for _, claim in ipairs(self.claims) do
        if claim.expiresAt >= now then
            kept[#kept + 1] = claim
        end
    end
    self.claims = kept
end

-- exactOnly: only claims with a matching exact amount.
function GoldLedger:TakeClaim(delta, exactOnly)
    for index, claim in ipairs(self.claims) do
        if claim.amount ~= nil and claim.amount == delta then
            table.remove(self.claims, index)
            return claim
        end
    end
    if exactOnly then
        return nil
    end
    local direction = delta > 0 and 1 or -1
    for index, claim in ipairs(self.claims) do
        if (claim.amount == nil or claim.loose) and claim.direction == direction then
            table.remove(self.claims, index)
            return claim
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

-- item (optional) = { name, quantity }: per-item detail kept on the row as
-- row.items[name] (income) or row.spendItems[name] (spending) = { copper, quantity }.
function GoldLedger:Record(delta, category, professionKey, reason, timestamp, item)
    local guid = UnitGUID and UnitGUID("player")
    if not guid or delta == 0 then
        return
    end
    professionKey = professionKey or "none"
    local itemLedger = PocketCFO.ItemLedger
    if itemLedger then
        itemLedger:Write({
            dir = delta > 0 and "in" or "out",
            cat = category,
            prof = professionKey ~= "none" and professionKey or nil,
            kind = "gold",
            qty = math.abs(delta),
            src = item and item.name or nil,
            iid = item and tonumber(item.itemID) or nil,   -- container gold: the container (2026-10-30)
            units = item and (tonumber(item.quantity) or 1) or nil,
            at = timestamp,
        })
        -- Going Out (2026-11-05): a vendor sale whose claim matched (exact
        -- sell price x stack, read at the sell click) also writes the item
        -- leaving. Same moment, one writer. No match = no item out.
        -- Both item-out writes are pcall-wrapped (2026-11-06) so a failure
        -- there can never stop the gold record above or the rest of Record.
        if category == "vendor" and delta > 0 and item and item.saleItemID then
            pcall(itemLedger.Write, itemLedger, {
                dir = "out",
                cat = "vendor",
                prof = professionKey ~= "none" and professionKey or nil,
                kind = "item",
                iid = item.saleItemID,
                link = item.saleLink,
                qty = tonumber(item.quantity) or 1,
                src = item.saleItemID,
                at = timestamp,
            })
        end
        -- AH sale (2026-11-05): the sold item leaves as auction out, at the
        -- sale time. If AHMailboxReconciler resolved this sale (same name,
        -- same copper) to one listing, its link is used, so gear leaves at
        -- its own book value and stackables at the right quality. Otherwise:
        -- name -> itemID via ResolveItemID, quantity from the invoice /
        -- subject (1 for gear, api-findings), no link (gear goes out
        -- unpriced). Name not resolved and no resolved sale = no item out.
        if category == "auction" and delta > 0 and item then
            local sale = self:ResolvedSale(item.name, delta)   -- pcall-wrapped inside
            local itemID = (sale and tonumber(sale.itemID)) or tonumber(item.itemID)
            if itemID then
                pcall(itemLedger.Write, itemLedger, {
                    dir = "out",
                    cat = "auction",
                    prof = professionKey ~= "none" and professionKey or nil,
                    kind = "item",
                    iid = itemID,
                    link = sale and sale.itemLink or nil,
                    qty = (sale and tonumber(sale.quantity)) or tonumber(item.quantity) or 1,
                    src = itemID,
                    at = timestamp,
                })
            end
        end
    end

    local itemText = ""
    if item and item.name then
        itemText = string.format(" item=%s x%d", tostring(item.name), tonumber(item.quantity) or 1)
    end
    SessionLog("%s category=%s profession=%s day=%s reason=%s%s",
        FormatCopper(delta), category, professionKey, DayKey(timestamp), tostring(reason), itemText)
end

-- One-time move of the old day history into the Item Ledger (2026-10-30).
-- Every day x character x category x profession row goes in as gold rows:
-- one per item sold / bought (by name, with quantity) and one for the rest.
-- The old history is deleted only when the ledger's gold totals rose by
-- exactly the amounts moved; otherwise it is kept and the mismatch logged.
local MOVE_FLAG = "goldDaysToItemLedger1"

function GoldLedger:MoveDaysToItemLedger()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    local itemLedger = PocketCFO.ItemLedger
    local goldLedger = globalDB and globalDB.goldLedger
    if not goldLedger or not itemLedger or type(goldLedger.days) ~= "table" then
        return
    end
    globalDB.migrations = globalDB.migrations or {}
    if globalDB.migrations[MOVE_FLAG] then
        return
    end
    globalDB.migrations[MOVE_FLAG] = time()
    local characters = globalDB.gold and globalDB.gold.characters or {}
    local before = { ["in"] = itemLedger:GetTotals({ kind = "gold", dir = "in" }).qty,
        out = itemLedger:GetTotals({ kind = "gold", dir = "out" }).qty }
    local moved = { ["in"] = 0, out = 0 }
    local rows = 0
    for dayKey, day in pairs(goldLedger.days) do
        for guid, categories in pairs(day) do
            local character = characters[guid]
            for category, professions in pairs(categories) do
                for professionKey, row in pairs(professions) do
                    local count = tonumber(row.count) or 0
                    for _, side in ipairs({ { "in", row.income, row.items }, { "out", row.spend, row.spendItems } }) do
                        local dir, amount, items = side[1], tonumber(side[2]) or 0, side[3]
                        if amount > 0 then
                            moved[dir] = moved[dir] + amount
                            local base = { characterGUID = guid, name = character and character.name or nil,
                                realm = character and character.realm or nil, dir = dir, cat = category,
                                prof = professionKey ~= "none" and professionKey or nil, kind = "gold" }
                            local itemCopper = 0
                            for itemName, detail in pairs(type(items) == "table" and items or {}) do
                                local copper = tonumber(detail.copper) or 0
                                if copper > 0 then
                                    local fields = {}
                                    for k, v in pairs(base) do fields[k] = v end
                                    fields.src, fields.qty, fields.value, fields.valuedQty = itemName, copper, copper, copper
                                    fields.units = tonumber(detail.quantity)
                                    itemLedger:AddHistoryRow(dayKey, fields)
                                    itemCopper = itemCopper + copper
                                    rows = rows + 1
                                end
                            end
                            local rest = amount - itemCopper
                            if rest > 0 then
                                local fields = {}
                                for k, v in pairs(base) do fields[k] = v end
                                fields.qty, fields.value, fields.valuedQty, fields.n = rest, rest, rest, count
                                count = 0
                                itemLedger:AddHistoryRow(dayKey, fields)
                                rows = rows + 1
                            end
                        end
                    end
                end
            end
        end
    end
    local after = { ["in"] = itemLedger:GetTotals({ kind = "gold", dir = "in" }).qty,
        out = itemLedger:GetTotals({ kind = "gold", dir = "out" }).qty }
    if after["in"] - before["in"] == moved["in"] and after.out - before.out == moved.out then
        goldLedger.days = nil
        PocketCFO:AppendSessionLog(string.format(
            "[MCG] GoldLedger: moved gold history into the Item Ledger (%d rows, in %d, out %d); old history removed",
            rows, moved["in"], moved.out))
    else
        PocketCFO:AppendSessionLog(string.format(
            "[MCG] GoldLedger: gold history move MISMATCH (in moved %d ledger +%d, out moved %d ledger +%d); old history kept",
            moved["in"], after["in"] - before["in"], moved.out, after.out - before.out))
    end
end

-- One-time merge (2026-11-01, Brian): AH spending from before the buy and
-- deposit hooks (2026-10-27) was filed as "auction" by the window rule and
-- showed as a second "Auction House" row on the Spending tab. It moves into
-- "auction_buy". Deposits from that time can't be told apart and go with it.
-- Result (OK or MISMATCH) goes to the session log.
local MERGE_AH_SPEND_FLAG = "ahSpendIntoPurchases1"

function GoldLedger:MergeAuctionSpending()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    local itemLedger = PocketCFO.ItemLedger
    if not globalDB or not itemLedger or type(itemLedger.MoveCategory) ~= "function" then
        return
    end
    globalDB.migrations = globalDB.migrations or {}
    if globalDB.migrations[MERGE_AH_SPEND_FLAG] then
        return
    end
    globalDB.migrations[MERGE_AH_SPEND_FLAG] = time()
    local function Spent(cat)
        return itemLedger:GetTotals({ kind = "gold", dir = "out", cat = cat }).qty
    end
    local spentBefore, buyBefore = Spent(nil), Spent("auction_buy")
    local moved, rows, entries = itemLedger:MoveCategory("auction", "auction_buy", "out", "gold")
    local spentAfter, buyAfter, left = Spent(nil), Spent("auction_buy"), Spent("auction")
    if spentAfter == spentBefore and buyAfter - buyBefore == moved and left == 0 then
        PocketCFO:AppendSessionLog(string.format(
            "[MCG] GoldLedger: merged AH spending into AH Purchases (%d rows, %d entries, %d copper)",
            rows, entries, moved))
    else
        PocketCFO:AppendSessionLog(string.format(
            "[MCG] GoldLedger: AH spending merge MISMATCH (spent %d -> %d, purchases +%d, moved %d, left %d)",
            spentBefore, spentAfter, buyAfter - buyBefore, moved, left))
    end
end

-- ---------------------------------------------------------------------------
-- Personal spending (2026-11-02, Brian): spending the player marks as
-- personal (a mount, a toy) is left out of the business numbers. Its category
-- becomes "personal:<original>" (e.g. "personal:vendor"), so marking it back
-- restores the original category. The gold amount never changes.
-- Flavor: Both.
-- ---------------------------------------------------------------------------

GoldLedger.PERSONAL_PREFIX = "personal:"

--- Original category of a personal category, or nil when it isn't personal.
function GoldLedger:PersonalOriginal(category)
    if type(category) ~= "string" then
        return nil
    end
    local prefix = GoldLedger.PERSONAL_PREFIX
    if string.sub(category, 1, #prefix) == prefix then
        return string.sub(category, #prefix + 1)
    end
    return nil
end

--- Marks spending on one item personal (isPersonal true) or back to business.
-- category = the category it is in now ("vendor", or "personal:vendor" to
-- move back). from / to = "YYYY-MM-DD" (nil = no limit); characterGUIDs =
-- { [guid] = true } (nil = every character). Returns copper moved.
function GoldLedger:SetPersonal(itemName, category, from, to, characterGUIDs, isPersonal)
    local itemLedger = PocketCFO.ItemLedger
    if not itemLedger or type(itemLedger.MoveRows) ~= "function" or not itemName or not category then
        return 0
    end
    local toCat
    if isPersonal then
        if self:PersonalOriginal(category) then
            return 0
        end
        toCat = GoldLedger.PERSONAL_PREFIX .. category
    else
        toCat = self:PersonalOriginal(category)
        if not toCat then
            return 0
        end
    end
    local moved, rows, entries = itemLedger:MoveRows({
        cat = category, dir = "out", kind = "gold", src = itemName,
        from = from, to = to, characterGUIDs = characterGUIDs,
    }, toCat)
    SessionLog("%s %s -> %s (%s, %d rows, %d entries, range %s..%s)",
        isPersonal and "personal:" or "business:", tostring(itemName), toCat, FormatCopper(moved),
        rows, entries, tostring(from or "start"), tostring(to or "now"))
    self:SendMessage("MCG_GOLD_LEDGER_UPDATED")
    return moved
end

-- Returns category, professionKey, reason, timestamp override, item.
-- category "mail_matched" = the gold was matched to waiting mail and those mails
-- were already recorded by MatchWaitingMail.
function GoldLedger:Classify(entry)
    -- Exact-amount evidence first, then waiting mail when at the mailbox, then
    -- direction-only evidence, then waiting mail after a recent mailbox visit.
    local claim = self:TakeClaim(entry.delta, true)
    if not claim and entry.delta > 0 and entry.mailOpen and self:MatchWaitingMail(entry.delta, true) then
        return "mail_matched"
    end
    claim = claim or self:TakeClaim(entry.delta)
    if claim then
        return claim.category, claim.profession, claim.reason, claim.timestamp, claim.item
    end
    if entry.delta > 0 and entry.mailRecent and self:MatchWaitingMail(entry.delta, false) then
        return "mail_matched"
    end
    if entry.delta < 0 and entry.repairMode and entry.windows.merchant then
        return "repair", nil, "window:merchant repair-mode"
    end
    local rules = entry.delta > 0 and INCOME_WINDOW_CATEGORY or SPEND_WINDOW_CATEGORY
    for _, windowEntry in ipairs(rules) do
        if entry.windows[windowEntry.window] then
            return windowEntry.category, nil, "window:" .. windowEntry.window
        end
    end
    if entry.delta > 0 and (entry.mailOpen or entry.mailRecent) then
        return "other", nil, string.format("mail:no-waiting-match waiting=%d", self:WaitingCount())
    end
    return "other", nil, "unrecognized"
end

-- Unknown log: the last UNKNOWN_LOG_SIZE gold changes that could not be traced,
-- with what was going on at the time. /mcg goldunknown lists them.
function GoldLedger:LogUnknown(delta, reason, windows, timestamp)
    local ledger = LedgerDB()
    if not ledger then
        return
    end
    ledger.unknownLog = ledger.unknownLog or {}
    local open = {}
    for window in pairs(windows or {}) do
        open[#open + 1] = window
    end
    table.sort(open)
    table.insert(ledger.unknownLog, 1, {
        at = timestamp or time(),
        character = UnitName and UnitName("player") or "?",
        copper = delta,
        reason = reason,
        windows = table.concat(open, ","),
    })
    while #ledger.unknownLog > UNKNOWN_LOG_SIZE do
        table.remove(ledger.unknownLog)
    end
end

function GoldLedger:Flush()
    self.flushScheduled = false
    local now = GetTime()
    self:PruneClaims(now)
    local pending = self.pending
    self.pending = {}
    local changed = false
    for _, entry in ipairs(pending) do
        local category, professionKey, reason, timestamp, item = self:Classify(entry)
        if category ~= "mail_matched" then
            if category == "other" then
                self:LogUnknown(entry.delta, reason, entry.windows, entry.timestamp)
                if entry.delta > 0 and (entry.mailOpen or entry.mailRecent) then
                    self:MailLog("miss", entry.delta, reason)
                end
            elseif reason == "window:auction" then
                -- Fell through to the AH window rule: recorded as a purchase
                -- with no item, logged so the gap can be traced (2026-11-01).
                self:LogUnknown(entry.delta, reason, entry.windows, entry.timestamp)
            end
            self:Record(entry.delta, category, professionKey, reason, timestamp or entry.timestamp, item)
        end
        changed = true
    end
    if changed then
        self:SendMessage("MCG_GOLD_LEDGER_UPDATED")
    end
end

function GoldLedger:ScheduleFlush()
    if self.flushScheduled then
        return
    end
    self.flushScheduled = true
    C_Timer.After(FLUSH_DELAY, function()
        GoldLedger:Flush()
    end)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function GoldLedger:OnPlayerMoney()
    local money = GetMoney and GetMoney()
    if not money then
        return
    end
    if self.lastMoney == nil then
        self.lastMoney = money
        return
    end
    local delta = money - self.lastMoney
    self.lastMoney = money
    if delta == 0 then
        return
    end
    self.pending[#self.pending + 1] = {
        delta = delta,
        timestamp = time(),
        windows = self:SnapshotWindows(),
        mailOpen = self.windowOpen.mail and true or false,
        mailRecent = self:WasMailboxRecent(),
        repairMode = delta < 0 and type(InRepairMode) == "function" and InRepairMode() or false,
    }
    self:ScheduleFlush()
end

function GoldLedger:ReadAccountMoney()
    if not C_Bank or type(C_Bank.FetchDepositedMoney) ~= "function"
        or not Enum or not Enum.BankType or not Enum.BankType.Account then
        return nil
    end
    local ok, copper = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
    return ok and tonumber(copper) or nil
end

-- A warband deposit raises the warband by exactly what the character lost
-- (and a withdrawal the reverse), so claim the opposite amount as a transfer.
function GoldLedger:OnAccountMoney()
    local accountMoney = self:ReadAccountMoney()
    if not accountMoney then
        return
    end
    if self.lastAccountMoney ~= nil then
        local accountDelta = accountMoney - self.lastAccountMoney
        if accountDelta ~= 0 then
            self:AddClaim({
                category = "transfer",
                amount = -accountDelta,
                reason = "warband",
            })
        end
    end
    self.lastAccountMoney = accountMoney
end

-- Single place window state changes. Ignores repeats (the legacy event and the
-- interaction event can both report the same open/close).
function GoldLedger:SetWindow(window, isOpen, source)
    local wasOpen = self.windowOpen[window] and true or false
    if wasOpen == (isOpen and true or false) then
        return
    end
    self.windowOpen[window] = isOpen or nil
    if not isOpen then
        self.windowClosedAt[window] = GetTime()
    end
    if window == "merchant" and isOpen then
        self:CacheRepairCost()
    end
    if window ~= "mail" then
        SessionLog("window %s %s source=%s", window, isOpen and "opened" or "closed", tostring(source))
    end
    if window == "mail" then
        SessionLog("mailbox %s source=%s", isOpen and "opened" or "closed", tostring(source))
        if isOpen then
            self:NoteInbox("open")
        end
    end
end

function GoldLedger:OnWindowEvent(event)
    local mapping = WINDOW_EVENTS[event] or OPTIONAL_WINDOW_EVENTS[event]
    if mapping then
        self:SetWindow(mapping[1], mapping[2], event)
    end
end

-- PLAYER_INTERACTION_MANAGER_FRAME_SHOW/HIDE (arg = interaction type).
-- Confirmed in-game 2026-10-19: closing the mailbox (X or Escape) fires
-- FRAME_HIDE with type 17 and never fires MAIL_CLOSED.
function GoldLedger:OnInteraction(event, interactionType)
    local window = INTERACTION_WINDOWS[tonumber(interactionType)]
    if window then
        self:SetWindow(window, event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", event .. ":" .. tostring(interactionType))
    end
end

-- Another gold source just proved you are not at the mailbox: treat the
-- mailbox as closed (late mail gold still matches for MAIL_MATCH_AFTER_CLOSE).
function GoldLedger:LeaveMailbox(reason)
    if self.windowOpen.mail then
        self:SetWindow("mail", false, reason)
    end
end

function GoldLedger:WasMailboxRecent()
    if self.windowOpen.mail then
        return true
    end
    local closedAt = self.windowClosedAt.mail
    return closedAt ~= nil and (GetTime() - closedAt) <= MAIL_MATCH_AFTER_CLOSE
end

-- The game's "You loot X" money message arrives with looted gold, so it is
-- the evidence for Loot (replaces the old loot-window flag, which could stick).
-- Theoretical: CHAT_MSG_MONEY fires for every money loot, auto-loot included.
function GoldLedger:OnLootMoney()
    self:AddClaim({
        category = "looted",
        direction = 1,
        reason = "loot-money",
        ttl = LOOT_CLAIM_TTL,
    })
end

function GoldLedger:OnQuestTurnedIn(_, questID, xpReward, moneyReward)
    moneyReward = tonumber(moneyReward)
    if moneyReward and moneyReward > 0 then
        self:AddClaim({
            category = "quest",
            amount = moneyReward,
            reason = "quest:" .. tostring(questID),
        })
    end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Mailbox: waiting list of mail seen holding gold
-- ---------------------------------------------------------------------------
-- Every time the inbox is read (mailbox open, inbox update), each fully loaded
-- mail holding gold goes on this character's waiting list with its details
-- (category, sale date, item, profession). Nothing is recorded yet.
-- When gold arrives (mailbox open, or up to MAIL_MATCH_AFTER_CLOSE after a
-- visit) it is matched against the list, exactly to the copper:
--   1. one waiting mail,
--   2. a run of mails that sat next to each other in the inbox (Open All takes
--      mail in order, so grouped gold is neighbours),
--   3. any combination of the newest MAIL_SUBSET_CAP waiting mails.
-- Matched mails are recorded and leave the list. Unmatched gold goes to
-- Unknown. Mail that never pays (noted twice, never collected) just waits and
-- is dropped after MAIL_WAIT_DAYS: it can never inflate income.
-- Why not match against the inbox directly: mail gold arrives late, grouped,
-- or after the mailbox closes, and half-loaded mails were misread (2026-10-19
-- to 10-21). The list removes all of that timing.
-- Saved per character in goldLedger.mailWaiting[characterGUID]; every note,
-- match and miss is also saved in goldLedger.mailLog (/mcg goldmaillog).
-- Theoretical: a mail is fully loaded once sender and subject are present and
-- the subject is not the "Retrieving data" placeholder.

local function RetrievingText()
    return _G.RETRIEVING_DATA or "Retrieving data"
end

-- "Auction successful: %s" without the item part (localized global when present).
local function IsAuctionSoldSubject(subject)
    subject = tostring(subject or "")
    local format = _G.AUCTION_SOLD_MAIL_SUBJECT
    if format and format ~= "" then
        local prefix = string.match(format, "^(.-)%%")
        if prefix and prefix ~= "" and string.sub(subject, 1, #prefix) == prefix then
            return true
        end
    end
    return string.find(subject, "^Auction successful:") ~= nil
end

-- Describes one inbox mail that holds gold. Field order of
-- GetInboxInvoiceInfo matches MailboxScanner (confirmed in use there).
function GoldLedger:DescribeMail(mailIndex, sender, subject, money, daysLeft)
    local mail = { money = money }
    mail.loaded = sender ~= nil and sender ~= "" and subject ~= nil and subject ~= ""
        and subject ~= RetrievingText()

    local invoiceType, invoiceItemName, invoiceCount
    if GetInboxInvoiceInfo then
        local ok, iType, iName, _, _, _, _, _, _, _, _, iCount = pcall(GetInboxInvoiceInfo, mailIndex)
        if ok then
            invoiceType, invoiceItemName, invoiceCount = iType, iName, iCount
        end
    end

    -- Arrival time from days left (mail is kept AH_MAIL_DAYS). Bucketed to 10
    -- minutes for the identity key so small drift between reads still matches.
    daysLeft = tonumber(daysLeft)
    local arrival = daysLeft and (time() - math.floor((AH_MAIL_DAYS - daysLeft) * 86400)) or nil
    mail.key = table.concat({ tostring(sender), tostring(subject), tostring(money),
        tostring(arrival and math.floor(arrival / 600) or "?") }, "|")

    local isAuctionSale = invoiceType == "seller" or invoiceType == "seller_temp_invoice"
        or (sender ~= nil and _G.AUCTION_HOUSE ~= nil and tostring(sender) == tostring(_G.AUCTION_HOUSE))
        or IsAuctionSoldSubject(subject)

    if isAuctionSale then
        mail.category = "auction"
        mail.timestamp, mail.reason = self:SaleTimestamp(daysLeft)
        mail.item = self:SaleItem(invoiceItemName, invoiceCount, subject)
        if mail.item then
            local professionKey, how = ProfessionForItem(nil, mail.item.name)
            mail.profession = professionKey
            mail.reason = mail.reason .. " profession-by=" .. tostring(how)
        end
    elseif IsOwnCharacter(sender) then
        mail.category, mail.reason = "transfer", "mail:own-character"
    else
        mail.category, mail.reason = "mail", "mail:" .. tostring(sender)
    end
    return mail
end

-- Mails currently holding gold, in inbox order.
function GoldLedger:ReadInbox()
    local mails = {}
    if not GetInboxNumItems or not GetInboxHeaderInfo then
        return mails
    end
    local count = tonumber((GetInboxNumItems())) or 0
    for mailIndex = 1, count do
        local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(mailIndex)
        money = tonumber(money)
        if money and money > 0 then
            mails[#mails + 1] = self:DescribeMail(mailIndex, sender, subject, money, daysLeft)
        end
    end
    return mails
end

function GoldLedger:WaitingList()
    local ledger = LedgerDB()
    local guid = UnitGUID and UnitGUID("player")
    if not ledger or not guid then
        return {}
    end
    ledger.mailWaiting = ledger.mailWaiting or {}
    ledger.mailWaiting[guid] = ledger.mailWaiting[guid] or {}
    return ledger.mailWaiting[guid]
end

function GoldLedger:WaitingCount()
    return #self:WaitingList()
end

-- Saved log of waiting-list activity (/mcg goldmaillog), newest first.
function GoldLedger:MailLog(kind, copper, detail)
    local ledger = LedgerDB()
    if not ledger then
        return
    end
    ledger.mailLog = ledger.mailLog or {}
    table.insert(ledger.mailLog, 1, {
        at = time(),
        character = UnitName and UnitName("player") or "?",
        kind = kind,
        copper = copper,
        detail = detail,
    })
    while #ledger.mailLog > MAIL_LOG_SIZE do
        table.remove(ledger.mailLog)
    end
    SessionLog("mail %s %s %s", kind, FormatCopper(copper or 0), tostring(detail))
end

local function MailLabel(mail)
    local itemName = mail.item and mail.item.name
    return string.format("%s%s", tostring(mail.category), itemName and (" " .. itemName) or "")
end

-- Adds newly seen mail to the waiting list and fills in details on waiting
-- mail that was incomplete. Identical mails are counted, not merged.
function GoldLedger:NoteInbox(source)
    local list = self:WaitingList()
    local cutoff = time() - MAIL_WAIT_DAYS * 86400
    for index = #list, 1, -1 do
        if (list[index].notedAt or 0) < cutoff then
            self:MailLog("expired", list[index].money, MailLabel(list[index]))
            table.remove(list, index)
        end
    end

    local waitingByKey = {}
    for _, waiting in ipairs(list) do
        waitingByKey[waiting.key] = waitingByKey[waiting.key] or {}
        table.insert(waitingByKey[waiting.key], waiting)
    end

    local seenByKey, skipped = {}, 0
    for _, mail in ipairs(self:ReadInbox()) do
        if not mail.loaded then
            skipped = skipped + 1
        else
            seenByKey[mail.key] = (seenByKey[mail.key] or 0) + 1
            local existing = waitingByKey[mail.key] and waitingByKey[mail.key][seenByKey[mail.key]]
            if existing then
                if not existing.item and mail.item then
                    existing.item, existing.profession, existing.reason = mail.item, mail.profession, mail.reason
                    self:MailLog("upgraded", existing.money, MailLabel(existing))
                end
            else
                self.mailSeq = self.mailSeq + 1
                mail.seq = self.mailSeq
                mail.notedAt = time()
                mail.loaded = nil
                list[#list + 1] = mail
                self:MailLog("noted", mail.money, MailLabel(mail) .. " via " .. tostring(source))
            end
        end
    end
    if skipped > 0 then
        SessionLog("mail inbox read skipped %d mail(s) still loading", skipped)
    end
end

function GoldLedger:OnMailInbox()
    if self.windowOpen.mail then
        self:NoteInbox("update")
    end
end

-- Finds waiting mail whose gold adds up exactly to amount. Returns a list.
local function FindMailMatch(list, amount)
    local sorted = {}
    for _, mail in ipairs(list) do
        sorted[#sorted + 1] = mail
    end
    table.sort(sorted, function(a, b) return (a.seq or 0) < (b.seq or 0) end)

    -- 1. One mail.
    for _, mail in ipairs(sorted) do
        if mail.money == amount then
            return { mail }
        end
    end

    -- 2. A run of neighbours in inbox order.
    for first = 1, #sorted do
        local sum = 0
        for last = first, #sorted do
            sum = sum + sorted[last].money
            if sum == amount then
                local run = {}
                for index = first, last do
                    run[#run + 1] = sorted[index]
                end
                return run
            elseif sum > amount then
                break
            end
        end
    end

    -- 3. Any combination of the newest MAIL_SUBSET_CAP mails.
    local candidates = {}
    for index = #sorted, math.max(1, #sorted - MAIL_SUBSET_CAP + 1), -1 do
        candidates[#candidates + 1] = sorted[index]
    end
    local chosen = {}
    local function Search(index, remaining)
        if remaining == 0 then
            return true
        end
        if remaining < 0 or index > #candidates then
            return false
        end
        chosen[#chosen + 1] = candidates[index]
        if Search(index + 1, remaining - candidates[index].money) then
            return true
        end
        chosen[#chosen] = nil
        return Search(index + 1, remaining)
    end
    if Search(1, amount) then
        return chosen
    end
    return nil
end

-- Records the waiting mail matched by amount. With refresh, re-reads the open
-- inbox once first if nothing matches (mail that loaded late).
function GoldLedger:MatchWaitingMail(amount, refresh)
    local list = self:WaitingList()
    local matched = FindMailMatch(list, amount)
    if not matched and refresh and self.windowOpen.mail then
        self:NoteInbox("retry")
        matched = FindMailMatch(list, amount)
    end
    if not matched then
        return false
    end
    for _, mail in ipairs(matched) do
        for index = #list, 1, -1 do
            if list[index] == mail then
                table.remove(list, index)
                break
            end
        end
        self:Record(mail.money, mail.category, mail.profession, mail.reason, mail.timestamp, mail.item)
    end
    self:MailLog("match", amount, string.format("%d mail(s), %d still waiting", #matched, #list))
    return true
end

-- The listing AHMailboxReconciler matched to this AH sale (item name + mail
-- money), taken so it is used once. nil = not resolved (2026-11-05).
function GoldLedger:ResolvedSale(itemName, money)
    local reconciler = PocketCFO:GetModule("AHMailboxReconciler", true)
    if not itemName or not reconciler or not reconciler.TakeResolvedSale then
        return nil
    end
    local ok, sale = pcall(reconciler.TakeResolvedSale, reconciler, itemName, money)
    return ok and sale or nil
end

-- AH sale mail is held for AH_MAIL_DAYS from the moment of the sale, so the
-- sale happened (AH_MAIL_DAYS - daysLeft) days before now.
-- Returns timestamp (nil = use collection time), reason text.
function GoldLedger:SaleTimestamp(daysLeft)
    daysLeft = tonumber(daysLeft)
    if not daysLeft then
        return nil, "mail:ah-sale daysLeft=?"
    end
    local elapsedDays = AH_MAIL_DAYS - daysLeft
    if elapsedDays < 0 then
        elapsedDays = 0
    end
    local timestamp = time() - math.floor(elapsedDays * 86400)
    return timestamp, string.format("mail:ah-sale daysLeft=%.2f", daysLeft)
end

-- Item name and quantity from the invoice; falls back to the English
-- "Auction successful: Name (N)" subject, as AHMailboxReconciler does.
function GoldLedger:SaleItem(itemName, count, subject)
    local quantity = tonumber(count)
    if not itemName or itemName == "" then
        local text = tostring(subject or "")
        local name, qty = text:match("^Auction successful:%s*(.-)%s*%((%d+)%)%s*$")
        if not name then
            name = text:match("^Auction successful:%s*(.-)%s*$")
        end
        itemName = name
        quantity = quantity or tonumber(qty)
    end
    if not itemName or itemName == "" then
        return nil
    end
    -- Item ID saved on the row (iid) so the Income tab can group the sale by
    -- item type (2026-10-31; ResolveItemID).
    return { name = itemName, quantity = quantity or 1, itemID = self:ResolveItemID(itemName) }
end

-- ---------------------------------------------------------------------------
-- Item ID by name (2026-10-31). AH sale mail gives only the item's name, and
-- the game only answers name lookups for items it has loaded recently
-- (/mcg ahgroups showed 63 of 80 sold items unknown by name). Tried in order:
--   1. IDs already found (goldLedger.itemIDs[name], saved for good)
--   2. GetItemInfo(name), then GetItemInfoInstant(name) (answered for more)
--   3. RecipeRegistry: a recipe one of your characters knows that makes it
--   4. Item Ledger: an item that came into your bags with that name (names
--      the game doesn't have loaded yet are requested for next time)
-- Returns the itemID or nil.
-- ---------------------------------------------------------------------------
local ledgerNames = nil      -- [name] = itemID, from Item Ledger item rows (this session)
local ledgerNamesAt = 0
local LEDGER_NAMES_SECONDS = 60

local function LinkItemID(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function LedgerNameIndex()
    local now = GetTime and GetTime() or 0
    if ledgerNames and (now - ledgerNamesAt) < LEDGER_NAMES_SECONDS then
        return ledgerNames
    end
    ledgerNames, ledgerNamesAt = {}, now
    local itemLedger = PocketCFO.ItemLedger
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not itemLedger or not getInfo then
        return ledgerNames
    end
    local seen = {}
    for _, found in ipairs(itemLedger:GetRows({ kind = "item" })) do
        local itemID = tonumber(found.row.iid)
        if itemID and not seen[itemID] then
            seen[itemID] = true
            local ok, name = pcall(getInfo, itemID)
            if ok and name then
                ledgerNames[name] = ledgerNames[name] or itemID
            elseif C_Item and C_Item.RequestLoadItemDataByID then
                pcall(C_Item.RequestLoadItemDataByID, itemID)
            end
        end
    end
    return ledgerNames
end

function GoldLedger:ResolveItemID(itemName)
    if not itemName or itemName == "" then
        return nil
    end
    local db = LedgerDB()
    if db then
        db.itemIDs = db.itemIDs or {}
        if db.itemIDs[itemName] then
            return db.itemIDs[itemName]
        end
    end
    local itemID
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if getInfo then
        local ok, _, link = pcall(getInfo, itemName)
        itemID = ok and LinkItemID(link) or nil
    end
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not itemID and getInstant then
        local ok, instantID = pcall(getInstant, itemName)
        itemID = ok and tonumber(instantID) or nil
    end
    local recipeRegistry = PocketCFO:GetModule("RecipeRegistry", true)
    if not itemID and recipeRegistry and recipeRegistry.GetRecipeIDsForOutput then
        local ok, recipeIDs = pcall(recipeRegistry.GetRecipeIDsForOutput, recipeRegistry, nil, itemName)
        for _, recipeID in ipairs(ok and type(recipeIDs) == "table" and recipeIDs or {}) do
            local record = recipeRegistry:GetRecipeRecord(recipeID)
            itemID = record and tonumber(record.outputItemID) or nil
            if itemID then
                break
            end
        end
    end
    if not itemID then
        itemID = LedgerNameIndex()[itemName]
    end
    if itemID and db then
        db.itemIDs[itemName] = itemID
    end
    return itemID
end

-- Selling to a vendor: read the item at the sell click (post-hook of
-- C_Container.UseContainerItem while a merchant is open) and claim the exact
-- vendor price x stack size.
-- Theoretical: the slot still holds the item when the post-hook runs, and one
-- sale produces one PLAYER_MONEY of exactly that amount. If not, the sale still
-- lands in Vendor by the open-window rule, just without item or profession.
function GoldLedger:OnUseContainerItem(bag, slot)
    if not C_Container or not C_Container.GetContainerItemInfo then
        return
    end
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if not ok or type(info) ~= "table" or not info.hyperlink then
        if not self.windowOpen.merchant then
            SessionLog("bag item use: slot already empty or unreadable bag=%s slot=%s", tostring(bag), tostring(slot))
        end
        return
    end
    if self.windowOpen.merchant then
        self:ClaimVendorSale(info)
    end
end

function GoldLedger:ClaimVendorSale(info)
    if info.hasNoValue then
        return
    end
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local itemName, _, _, _, _, _, _, _, _, _, sellPrice = getInfo(info.hyperlink)
    sellPrice = tonumber(sellPrice)
    local quantity = tonumber(info.stackCount) or 1
    if not sellPrice or sellPrice <= 0 then
        return
    end
    itemName = itemName or info.itemName
    local professionKey, how = ProfessionForItem(info.itemID, itemName)
    self:AddClaim({
        category = "vendor",
        amount = sellPrice * quantity,
        profession = professionKey,
        -- saleItemID / saleLink (2026-11-05): the item leaves as vendor out
        -- when this claim matches (Record).
        item = itemName and { name = itemName, quantity = quantity,
            saleItemID = tonumber(info.itemID), saleLink = info.hyperlink } or nil,
        reason = "vendor:sell profession-by=" .. tostring(how),
    })
end

-- Opening a container from your bags (cache, trove, reward bag): gold that
-- arrives within CONTAINER_CLAIM_TTL is credited to Looted Gold with the
-- container's name as the item. Seen 2026-10-23: an Overflowing Silvermoon
-- Trove and an Apex chest paid gold with no loot-money claim, so it went to
-- Unknown. Since 2026-10-30 the click comes from LootReader
-- (MCG_CONTAINER_CLICK: item has loot, no merchant open).
function GoldLedger:ClaimContainerOpen(click)
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local itemName = (click.link and getInfo(click.link)) or click.name
    SessionLog("container opened: %s", tostring(itemName))
    self:AddClaim({
        category = "looted",
        direction = 1,
        item = itemName and { name = itemName, quantity = 1, itemID = tonumber(click.itemID) } or nil,
        reason = "container:" .. tostring(itemName),
        ttl = CONTAINER_CLAIM_TTL,
    })
end

function GoldLedger:OnSendMail(recipient)
    if IsOwnCharacter(recipient) then
        self:AddClaim({
            category = "transfer",
            direction = -1,
            reason = "send-mail:own-character",
            atMailbox = true,
        })
    end
end

function GoldLedger:OnFulfillOrder(orderID, _, professionEnum)
    local orderType
    if C_CraftingOrders and C_CraftingOrders.GetClaimedOrder then
        local ok, order = pcall(C_CraftingOrders.GetClaimedOrder)
        if ok and type(order) == "table" then
            orderType = tonumber(order.orderType)
        end
    end

    local professionKey
    local registry = PocketCFO.ProfessionRegistry
    if professionEnum and registry and registry.GetProfessionIDFromEnum then
        local professionID = registry:GetProfessionIDFromEnum(professionEnum)
        professionKey = professionID and tostring(professionID) or nil
    end
    professionKey = professionKey or BaseProfessionKey()

    local category = ORDER_CATEGORY[orderType] or "order_unknown"
    SessionLog("order fulfill orderID=%s orderType=%s profession=%s",
        tostring(orderID), tostring(orderType), tostring(professionKey))
    self:AddClaim({
        category = category,
        profession = professionKey,
        direction = 1,
        reason = "order:" .. tostring(orderID),
        ttl = ORDER_CLAIM_TTL,
    })
end

-- ---------------------------------------------------------------------------
-- Spending claims (2026-10-27). Flavor: Both. All Theoretical until seen.
-- ---------------------------------------------------------------------------

local function ItemNameOf(linkOrID)
    if not linkOrID then
        return nil
    end
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local ok, name = pcall(getInfo, linkOrID)
    return ok and name or nil
end

-- Merchant item: name, link, price, stackCount. C_MerchantFrame.GetItemInfo
-- (table) when present, else the global GetMerchantItemInfo.
local function MerchantItem(index)
    local name, price, stackCount
    if C_MerchantFrame and type(C_MerchantFrame.GetItemInfo) == "function" then
        local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
        if ok and type(info) == "table" then
            name, price, stackCount = info.name, info.price, info.stackCount
        end
    end
    if not name and type(GetMerchantItemInfo) == "function" then
        local ok, n, _, p, s = pcall(GetMerchantItemInfo, index)
        if ok then
            name, price, stackCount = n, p, s
        end
    end
    local link
    if type(GetMerchantItemLink) == "function" then
        local ok, l = pcall(GetMerchantItemLink, index)
        link = ok and l or nil
    end
    return ItemNameOf(link) or name, tonumber(price), tonumber(stackCount) or 1
end

function GoldLedger:OnBuyMerchantItem(index, quantity)
    local name, price, stackCount = MerchantItem(index)
    quantity = tonumber(quantity) or stackCount
    if not price or price <= 0 then
        SessionLog("vendor buy: no gold price index=%s (currency item?)", tostring(index))
        return
    end
    local amount = math.floor(price * quantity / math.max(1, stackCount) + 0.5)
    SessionLog("vendor buy claim %s x%d expected=%s", tostring(name), quantity, FormatCopper(-amount))
    self:AddClaim({
        category = "vendor",
        amount = -amount,
        loose = true,
        direction = -1,
        item = name and { name = name, quantity = quantity } or nil,
        reason = "vendor:buy",
        ttl = LOOSE_CLAIM_TTL,
    })
end

function GoldLedger:OnBuybackItem(index)
    if type(GetBuybackItemInfo) ~= "function" then
        return
    end
    local ok, name, _, price, quantity = pcall(GetBuybackItemInfo, index)
    price = ok and tonumber(price) or nil
    if not price or price <= 0 then
        return
    end
    SessionLog("vendor buyback claim %s x%s expected=%s", tostring(name), tostring(quantity), FormatCopper(-price))
    self:AddClaim({
        category = "vendor",
        amount = -price,
        loose = true,
        direction = -1,
        item = name and { name = name, quantity = tonumber(quantity) or 1 } or nil,
        reason = "vendor:buyback",
        ttl = LOOSE_CLAIM_TTL,
    })
end

-- Repair All: the cost is gone once the repair is done, so it is cached while
-- the merchant is open (merchant show/update, durability change).
function GoldLedger:CacheRepairCost()
    if not self.windowOpen.merchant or type(GetRepairAllCost) ~= "function" then
        return
    end
    local ok, cost, canRepair = pcall(GetRepairAllCost)
    if ok then
        self.repairAllCost = canRepair and tonumber(cost) or 0
    end
end

function GoldLedger:OnRepairAllItems(guildBankRepair)
    if guildBankRepair then
        SessionLog("repair all: paid by guild bank, not counted")
        return
    end
    local cost = tonumber(self.repairAllCost) or 0
    SessionLog("repair all claim expected=%s", FormatCopper(-cost))
    self:AddClaim({
        category = "repair",
        amount = cost > 0 and -cost or nil,
        loose = true,
        direction = -1,
        reason = "repair:all",
        ttl = LOOSE_CLAIM_TTL,
    })
    self.repairAllCost = 0
end

function GoldLedger:OnBuyTrainerService(index)
    local name, cost
    if type(GetTrainerServiceInfo) == "function" then
        local ok, n = pcall(GetTrainerServiceInfo, index)
        name = ok and n or nil
    end
    if type(GetTrainerServiceCost) == "function" then
        local ok, c = pcall(GetTrainerServiceCost, index)
        cost = ok and tonumber(c) or nil
    end
    SessionLog("trainer claim %s expected=%s", tostring(name), cost and FormatCopper(-cost) or "?")
    self:AddClaim({
        category = "training",
        amount = (cost and cost > 0) and -cost or nil,
        loose = true,
        direction = -1,
        item = name and { name = name, quantity = 1 } or nil,
        reason = "trainer:" .. tostring(name),
        ttl = LOOSE_CLAIM_TTL,
    })
end

-- AH purchases. Item auctions: PlaceBid(auctionID, bidAmount) charges the bid
-- at once; the item is the one last searched (ITEM_SEARCH_RESULTS_UPDATED).
-- Commodities: the total comes from COMMODITY_PRICE_UPDATED after
-- StartCommoditiesPurchase, charged at ConfirmCommoditiesPurchase.
function GoldLedger:OnItemSearchResults(_, itemKey)
    self.lastSearchItemKey = itemKey
end

function GoldLedger:OnCommodityPriceUpdated(_, unitPrice, totalPrice)
    self.commodityQuote = self.commodityQuote or {}
    self.commodityQuote.total = tonumber(totalPrice)
end

function GoldLedger:OnStartCommoditiesPurchase(itemID, quantity)
    self.commodityQuote = { itemID = itemID, quantity = tonumber(quantity) }
end

function GoldLedger:OnConfirmCommoditiesPurchase(itemID, quantity)
    local quote = self.commodityQuote or {}
    local total = quote.itemID == itemID and tonumber(quote.total) or nil
    quantity = tonumber(quantity) or quote.quantity or 1
    local name = ItemNameOf(itemID)
    SessionLog("AH commodity buy claim %s x%d expected=%s", tostring(name), quantity, total and FormatCopper(-total) or "?")
    self:AddClaim({
        category = "auction_buy",
        amount = total and -total or nil,
        loose = true,
        direction = -1,
        item = name and { name = name, quantity = quantity } or nil,
        reason = "ah:buy-commodity",
        ttl = AH_BUY_CLAIM_TTL,
    })
    self.commodityQuote = nil
end

function GoldLedger:OnPlaceBid(auctionID, bidAmount)
    bidAmount = tonumber(bidAmount)
    local name
    local itemKey = self.lastSearchItemKey
    if itemKey and C_AuctionHouse and type(C_AuctionHouse.GetItemKeyInfo) == "function" then
        local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
        name = ok and type(info) == "table" and info.itemName or nil
    end
    SessionLog("AH bid/buyout claim %s auctionID=%s expected=%s", tostring(name), tostring(auctionID),
        bidAmount and FormatCopper(-bidAmount) or "?")
    self:AddClaim({
        category = "auction_buy",
        amount = bidAmount and -bidAmount or nil,
        loose = true,
        direction = -1,
        item = name and { name = name, quantity = 1 } or nil,
        reason = "ah:bid",
        ttl = AH_BUY_CLAIM_TTL,
    })
end

-- AH deposits. The item may already be gone from the bag when the post-hook
-- runs, so the name is best effort.
function GoldLedger:OnPostAuction(kind, itemLocation, quantity)
    local name
    if itemLocation and C_Item and type(C_Item.GetItemName) == "function" then
        local ok, n = pcall(C_Item.GetItemName, itemLocation)
        name = ok and n or nil
    end
    SessionLog("AH deposit claim (%s) %s x%s", kind, tostring(name), tostring(quantity))
    self:AddClaim({
        category = "auction_deposit",
        direction = -1,
        item = name and { name = name, quantity = tonumber(quantity) or 1 } or nil,
        reason = "ah:post-" .. kind,
        ttl = LOOSE_CLAIM_TTL,
    })
end

function GoldLedger:OnRepairCostEvent()
    self:CacheRepairCost()
end

local function HookGlobal(name, fn)
    if type(_G[name]) == "function" then
        hooksecurefunc(name, fn)
    end
end

local function HookTable(tbl, name, fn)
    if tbl and type(tbl[name]) == "function" then
        hooksecurefunc(tbl, name, fn)
    end
end

function GoldLedger:InstallSpendingHooks()
    HookGlobal("BuyMerchantItem", function(index, quantity) GoldLedger:OnBuyMerchantItem(index, quantity) end)
    HookGlobal("BuybackItem", function(index) GoldLedger:OnBuybackItem(index) end)
    HookGlobal("RepairAllItems", function(guildBankRepair) GoldLedger:OnRepairAllItems(guildBankRepair) end)
    HookGlobal("BuyTrainerService", function(index) GoldLedger:OnBuyTrainerService(index) end)
    local ah = C_AuctionHouse
    HookTable(ah, "PlaceBid", function(auctionID, bidAmount) GoldLedger:OnPlaceBid(auctionID, bidAmount) end)
    HookTable(ah, "StartCommoditiesPurchase", function(itemID, quantity) GoldLedger:OnStartCommoditiesPurchase(itemID, quantity) end)
    HookTable(ah, "ConfirmCommoditiesPurchase", function(itemID, quantity) GoldLedger:OnConfirmCommoditiesPurchase(itemID, quantity) end)
    HookTable(ah, "PostItem", function(item, _, quantity) GoldLedger:OnPostAuction("item", item, quantity) end)
    HookTable(ah, "PostCommodity", function(item, _, quantity) GoldLedger:OnPostAuction("commodity", item, quantity) end)
end

function GoldLedger:RegisterOptionalEvent(event, method)
    local ok = pcall(self.RegisterEvent, self, event, method)
    if not ok then
        SessionLog("event not available on this client: %s", event)
    end
end

function GoldLedger:InstallHooks()
    if self.hooksInstalled then
        return
    end
    self.hooksInstalled = true
    if type(_G.SendMail) == "function" then
        hooksecurefunc("SendMail", function(recipient) GoldLedger:OnSendMail(recipient) end)
    end
    if C_Container and type(C_Container.UseContainerItem) == "function" then
        hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot) GoldLedger:OnUseContainerItem(bag, slot) end)
    end
    if C_CraftingOrders and type(C_CraftingOrders.FulfillOrder) == "function" then
        hooksecurefunc(C_CraftingOrders, "FulfillOrder", function(...) GoldLedger:OnFulfillOrder(...) end)
    end
    self:InstallSpendingHooks()
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function GoldLedger:OnEnteringWorld()
    -- A loading screen closes every window.
    self:LeaveMailbox("loading-screen")
    self.windowOpen = {}
    self.lastMoney = GetMoney and GetMoney() or self.lastMoney
    self.lastAccountMoney = self:ReadAccountMoney() or self.lastAccountMoney
end

local messenger = LibStub and LibStub("AceEvent-3.0", true) and LibStub("AceEvent-3.0"):Embed({}) or nil
if messenger then
    messenger:RegisterMessage("MCG_CONTAINER_CLICK", function(_, click)
        if type(click) == "table" then
            GoldLedger:ClaimContainerOpen(click)
        end
    end)
end

function GoldLedger:OnEnable()
    pcall(self.MoveDaysToItemLedger, self)
    pcall(self.MergeAuctionSpending, self)   -- after the history move (2026-11-01)
    self:InstallHooks()
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnEnteringWorld")
    self:RegisterEvent("PLAYER_MONEY", "OnPlayerMoney")
    self:RegisterEvent("ACCOUNT_MONEY", "OnAccountMoney")
    self:RegisterEvent("QUEST_TURNED_IN", "OnQuestTurnedIn")
    self:RegisterEvent("MAIL_INBOX_UPDATE", "OnMailInbox")
    self:RegisterEvent("CHAT_MSG_MONEY", "OnLootMoney")
    for event in pairs(WINDOW_EVENTS) do
        self:RegisterEvent(event, "OnWindowEvent")
    end
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "OnInteraction")
    self:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "OnInteraction")
    -- Spending (2026-10-27): optional events, pcall-registered.
    for event in pairs(OPTIONAL_WINDOW_EVENTS) do
        self:RegisterOptionalEvent(event, "OnWindowEvent")
    end
    self:RegisterOptionalEvent("MERCHANT_UPDATE", "OnRepairCostEvent")
    self:RegisterOptionalEvent("UPDATE_INVENTORY_DURABILITY", "OnRepairCostEvent")
    self:RegisterOptionalEvent("COMMODITY_PRICE_UPDATED", "OnCommodityPriceUpdated")
    self:RegisterOptionalEvent("ITEM_SEARCH_RESULTS_UPDATED", "OnItemSearchResults")
    self:OnEnteringWorld()
end

-- ---------------------------------------------------------------------------
-- Diagnostics: /mcg goldsources [days]
-- ---------------------------------------------------------------------------

function GoldLedger:BuildReport(days)
    days = math.max(1, math.floor(tonumber(days) or 7))
    local itemLedger = PocketCFO.ItemLedger
    if not itemLedger then
        return "No ledger."
    end
    local registry = PocketCFO.ProfessionRegistry
    local from = DayKey(time() - (days - 1) * 86400)
    local found = itemLedger:GetRows({ kind = "gold", from = from })
    table.sort(found, function(a, b)
        if a.period ~= b.period then
            return a.period > b.period
        end
        return (a.row.cat or "") < (b.row.cat or "")
    end)
    local lines = {}
    local lastPeriod = nil
    for _, item in ipairs(found) do
        local row = item.row
        if item.period ~= lastPeriod then
            lines[#lines + 1] = item.period
            lastPeriod = item.period
        end
        local character = itemLedger:GetCharacter(row.c)
        local config = registry and registry.GetProfessionConfig and row.prof
            and registry:GetProfessionConfig(tonumber(row.prof))
        lines[#lines + 1] = string.format("  %s  %s  %s  %s %s  n=%d%s",
            tostring(character and character.name or row.c), row.cat, config and config.name or tostring(row.prof or "none"),
            row.dir, FormatCopper(row.dir == "in" and row.qty or -row.qty), row.n or 0,
            row.src and string.format("  item=%s x%d", tostring(row.src), row.units or 0) or "")
    end
    if #lines == 0 then
        return string.format("No gold recorded in the last %d day(s).", days)
    end
    return table.concat(lines, "\n")
end

local diagnostics = PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("goldsources", {
        name = "goldsources",
        description = "Dump gold sources by day, character, category and profession.",
        usage = "/mcg goldsources [days]",
        category = "General",
    }, function(rest)
        diagnostics:ShowDump("Gold Sources", GoldLedger:BuildReport(rest))
    end)
end

-- ---------------------------------------------------------------------------
-- Diagnostics: /mcg ahgroups - why each Auction House sale lands in its
-- Income group (2026-10-31; report lives in PocketCFO_PnL, loaded here).
-- ---------------------------------------------------------------------------
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("ahgroups", {
        name = "ahgroups",
        description = "List every item sold on the Auction House and why it is in its Income group.",
        usage = "/mcg ahgroups",
        category = "General",
    }, function()
        local loader = PocketCFO:GetModule("AddonLoader", true)
        local pnl = loader and loader:SafeLoad("PocketCFO_PnL") and _G.PocketCFO_PnL
        local report = pnl and pnl.IncomeReport
        if not report or not report.BuildAuctionGroupsReport then
            PocketCFO:Print("Could not load the Income report.")
            return
        end
        diagnostics:ShowDump("AH Groups", report:BuildAuctionGroupsReport())
    end)
end

-- ---------------------------------------------------------------------------
-- Diagnostics: /mcg goldunknown - recent gold changes that could not be traced
-- ---------------------------------------------------------------------------
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("goldunknown", {
        name = "goldunknown",
        description = "List the most recent gold changes that could not be traced to a source.",
        usage = "/mcg goldunknown",
        category = "General",
    }, function()
        local ledger = LedgerDB()
        local log = ledger and ledger.unknownLog or {}
        local lines = {}
        for _, entry in ipairs(log) do
            lines[#lines + 1] = string.format("%s  %s  %s  windows=%s  reason=%s",
                date("%Y-%m-%d %H:%M:%S", entry.at or 0), tostring(entry.character),
                FormatCopper(entry.copper), entry.windows ~= "" and entry.windows or "none",
                tostring(entry.reason))
        end
        if #lines == 0 then
            lines[1] = "No untraced gold recorded."
        end
        diagnostics:ShowDump("Unknown Gold", table.concat(lines, "\n"))
    end)
end

-- ---------------------------------------------------------------------------
-- Diagnostics: /mcg goldmaillog - mail waiting for its gold, and recent
-- waiting-list activity (saved, so it works with debug off)
-- ---------------------------------------------------------------------------
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("goldmaillog", {
        name = "goldmaillog",
        description = "Show mail waiting for its gold and recent mail matching activity.",
        usage = "/mcg goldmaillog",
        category = "General",
    }, function()
        local ledger = LedgerDB()
        local characters = PocketCFO.db.global.gold and PocketCFO.db.global.gold.characters or {}
        local lines = { "=== Mail waiting for its gold ===" }
        for guid, list in pairs(ledger and ledger.mailWaiting or {}) do
            for _, mail in ipairs(list) do
                lines[#lines + 1] = string.format("  %s  %s  %s  %s  noted %s",
                    tostring(characters[guid] and characters[guid].name or guid), FormatCopper(mail.money),
                    tostring(mail.category), mail.item and mail.item.name or "-",
                    date("%m-%d %H:%M", mail.notedAt or 0))
            end
        end
        if #lines == 1 then
            lines[#lines + 1] = "  (none)"
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "=== Recent activity (newest first) ==="
        for _, entry in ipairs(ledger and ledger.mailLog or {}) do
            lines[#lines + 1] = string.format("  %s  %s  %-8s %s  %s",
                date("%m-%d %H:%M:%S", entry.at or 0), tostring(entry.character), tostring(entry.kind),
                FormatCopper(entry.copper or 0), tostring(entry.detail))
        end
        diagnostics:ShowDump("Gold Mail Log", table.concat(lines, "\n"))
    end)
end
