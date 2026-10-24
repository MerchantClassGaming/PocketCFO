-- PocketCFO/Services/GoldTracker/GoldLedger.lua
-- Gold Sources, step 1: record every change in a character's gold and tag it
-- with what was happening at the time. Categories always add up to the real
-- change in gold; anything not recognized lands in "other".
-- Design: project doc claude/Gold_Sources_Design.md
--
-- Storage: PocketCFO_DB.global.goldLedger.days[dayKey][characterGUID][category][professionKey]
--   = { income = copper, spend = copper, count = n,
--       items = { [itemName] = { copper, quantity } } }   -- items: AH and vendor sales
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
--      gold goes up there); gold OUT by merchant, trade, AH or mail.
--   5. Otherwise "other" (shown as Unknown) and logged in goldLedger.unknownLog
--      (/mcg goldunknown) so each gap can be found and given a real rule.
-- Rule: a category is only assigned for a specific reason, never as a guess.
--
-- Sends AceEvent message "MCG_GOLD_LEDGER_UPDATED" after each batch is saved.
-- The Income view in PocketCFO_PnL reads GetDays().
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

-- Forever: "You loot X" (CHAT_MSG_MONEY) arrived ~1.0s after PLAYER_MONEY on
-- the beta (event capture 2026-10-20), so 0.5s filed looted gold as Unknown.
-- Retail keeps 0.5. PocketCFO.flavor is set by Flavor_Forever.lua (Forever TOC only).
local FLUSH_DELAY = (PocketCFO.flavor == "forever") and 2 or 0.5
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
local SPEND_WINDOW_CATEGORY = {
    { window = "merchant", category = "vendor" },
    { window = "trade",    category = "trade" },
    { window = "auction",  category = "auction" },
    { window = "mail",     category = "mail" },
}
local TRACKED_WINDOWS = { "merchant", "trade", "auction", "mail", "bank" }

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
    globalDB.goldLedger.days = globalDB.goldLedger.days or {}
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

-- True when the name matches one of this account's characters known to GoldTracker.
local function IsOwnCharacter(name)
    local bare = StripRealm(name)
    local goldDB = PocketCFO.db and PocketCFO.db.global and PocketCFO.db.global.gold
    if not bare or not goldDB or not goldDB.characters then
        return false
    end
    bare = string.lower(bare)
    for _, entry in pairs(goldDB.characters) do
        if entry.name and string.lower(tostring(entry.name)) == bare then
            return true
        end
    end
    return false
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
function GoldLedger:AddClaim(claim)
    claim.expiresAt = GetTime() + (claim.ttl or CLAIM_TTL)
    self.claims[#self.claims + 1] = claim
    if not claim.atMailbox and claim.category ~= "loot_quest" then
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
        if claim.amount == nil and claim.direction == direction then
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
-- row.items[name] = { copper, quantity }. Income only.
function GoldLedger:Record(delta, category, professionKey, reason, timestamp, item)
    local ledger = LedgerDB()
    local guid = UnitGUID and UnitGUID("player")
    if not ledger or not guid or delta == 0 then
        return
    end
    professionKey = professionKey or "none"
    local dayKey = DayKey(timestamp)

    local day = ledger.days[dayKey] or {}
    ledger.days[dayKey] = day
    local character = day[guid] or {}
    day[guid] = character
    local byCategory = character[category] or {}
    character[category] = byCategory
    local row = byCategory[professionKey] or { income = 0, spend = 0, count = 0 }
    byCategory[professionKey] = row

    if delta > 0 then
        row.income = row.income + delta
    else
        row.spend = row.spend + (-delta)
    end
    row.count = row.count + 1

    local itemText = ""
    if item and item.name and delta > 0 then
        row.items = row.items or {}
        local detail = row.items[item.name] or { copper = 0, quantity = 0 }
        row.items[item.name] = detail
        detail.copper = detail.copper + delta
        detail.quantity = detail.quantity + (tonumber(item.quantity) or 1)
        itemText = string.format(" item=%s x%d", tostring(item.name), tonumber(item.quantity) or 1)
    end

    SessionLog("%s category=%s profession=%s day=%s reason=%s%s",
        FormatCopper(delta), category, professionKey, dayKey, tostring(reason), itemText)
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
            end
            self:Record(entry.delta, category, professionKey, reason, timestamp or entry.timestamp, item)
        end
        changed = true
    end
    if changed then
        self:SendMessage("MCG_GOLD_LEDGER_UPDATED")
    end
end

-- Read-only view for display code (PocketCFO_PnL). Callers must not modify it.
-- days[dayKey][characterGUID][category][professionKey] = { income, spend, count }
function GoldLedger:GetDays()
    local ledger = LedgerDB()
    return ledger and ledger.days or {}
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
    if window == "mail" then
        SessionLog("mailbox %s source=%s", isOpen and "opened" or "closed", tostring(source))
        if isOpen then
            self:NoteInbox("open")
        end
    end
end

function GoldLedger:OnWindowEvent(event)
    local mapping = WINDOW_EVENTS[event]
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
        category = "loot_quest",
        direction = 1,
        reason = "loot-money",
        ttl = LOOT_CLAIM_TTL,
    })
end

function GoldLedger:OnQuestTurnedIn(_, questID, xpReward, moneyReward)
    moneyReward = tonumber(moneyReward)
    if moneyReward and moneyReward > 0 then
        self:AddClaim({
            category = "loot_quest",
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
    return { name = itemName, quantity = quantity or 1 }
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
    elseif info.hasLoot then
        self:ClaimContainerOpen(info)
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
        item = itemName and { name = itemName, quantity = quantity } or nil,
        reason = "vendor:sell profession-by=" .. tostring(how),
    })
end

-- Opening a container from your bags (cache, trove, reward bag): gold that
-- arrives within CONTAINER_CLAIM_TTL is credited to Loot & Quests with the
-- container's name as the item. Seen 2026-10-23: an Overflowing Silvermoon
-- Trove and an Apex chest paid gold with no loot-money claim, so it went to
-- Unknown. Theoretical: info.hasLoot is true for these containers and the
-- slot still holds the item when this post-hook runs.
function GoldLedger:ClaimContainerOpen(info)
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    local itemName = (getInfo(info.hyperlink)) or info.itemName
    SessionLog("container opened: %s", tostring(itemName))
    self:AddClaim({
        category = "loot_quest",
        direction = 1,
        item = itemName and { name = itemName, quantity = 1 } or nil,
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

function GoldLedger:OnEnable()
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
    self:OnEnteringWorld()
end

-- ---------------------------------------------------------------------------
-- Diagnostics: /mcg goldsources [days]
-- ---------------------------------------------------------------------------

function GoldLedger:BuildReport(days)
    days = math.max(1, math.floor(tonumber(days) or 7))
    local ledger = LedgerDB()
    local goldDB = PocketCFO.db and PocketCFO.db.global and PocketCFO.db.global.gold
    local characters = goldDB and goldDB.characters or {}
    local lines = {}
    if not ledger then
        return "No gold ledger data."
    end
    local registry = PocketCFO.ProfessionRegistry
    local now = time()
    for offset = 0, days - 1 do
        local dayKey = DayKey(now - offset * 86400)
        local day = ledger.days[dayKey]
        if day then
            lines[#lines + 1] = dayKey
            for guid, byCategory in pairs(day) do
                local who = characters[guid] and characters[guid].name or guid
                for category, byProfession in pairs(byCategory) do
                    for professionKey, row in pairs(byProfession) do
                        local config = registry and registry.GetProfessionConfig
                            and registry:GetProfessionConfig(tonumber(professionKey))
                        lines[#lines + 1] = string.format("  %s  %s  %s  in=%s  out=%s  n=%d",
                            tostring(who), category, config and config.name or professionKey,
                            FormatCopper(row.income), FormatCopper(-row.spend), row.count or 0)
                    end
                end
            end
        end
    end
    if #lines == 0 then
        return string.format("No gold ledger data in the last %d day(s).", days)
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

-- ---------------------------------------------------------------------------
-- ONE-TIME FIX (2026-10-23): /mcg containerfix
-- Matatodos container opens on 2026-10-23 went to Unknown before containers
-- were recognized. Moves each one still in Unknown (matched by its exact
-- amount in the Unknown log) to Loot & Quests with the container name.
-- Safe to run more than once. No window needed. Delete after it has been run.
-- ---------------------------------------------------------------------------
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("containerfix", {
        name = "containerfix",
        description = "One-time: move 2026-10-23 Matatodos container opens from Unknown to Loot & Quests.",
        usage = "/mcg containerfix",
        category = "General",
    }, function()
        local ok, err = pcall(function()
            local DAY = "2026-10-23"
            local OPENS = {
                { copper = 20437618, name = "Overflowing Silvermoon Trove" },
                { copper = 19583515, name = "Apex Chest" },
                { copper = 10675723, name = "Aqir Research Satchel" },
            }
            local ledger = LedgerDB()
            local characters = PocketCFO.db.global.gold and PocketCFO.db.global.gold.characters or {}
            local guid
            for characterGUID, entry in pairs(characters) do
                if entry.name == "Matatodos" then
                    guid = characterGUID
                end
            end
            local character = guid and ledger and ledger.days[DAY] and ledger.days[DAY][guid]
            if not character then
                PocketCFO:Print("containerfix: no data for Matatodos on %s, nothing changed.", DAY)
                return
            end
            local moved = 0
            for _, open in ipairs(OPENS) do
                local logIndex
                for index, entry in ipairs(ledger.unknownLog or {}) do
                    if entry.character == "Matatodos" and entry.copper == open.copper then
                        logIndex = index
                        break
                    end
                end
                local unknownRow = character.other and character.other.none
                if logIndex and unknownRow and (unknownRow.income or 0) >= open.copper then
                    table.remove(ledger.unknownLog, logIndex)
                    unknownRow.income = unknownRow.income - open.copper
                    unknownRow.count = math.max(0, (unknownRow.count or 0) - 1)
                    if unknownRow.income == 0 and (unknownRow.spend or 0) == 0 then
                        character.other.none = nil
                        if next(character.other) == nil then
                            character.other = nil
                        end
                    end
                    character.loot_quest = character.loot_quest or {}
                    local row = character.loot_quest.none or { income = 0, spend = 0, count = 0 }
                    character.loot_quest.none = row
                    row.items = row.items or {}
                    row.income = row.income + open.copper
                    row.count = row.count + 1
                    local detail = row.items[open.name] or { copper = 0, quantity = 0 }
                    row.items[open.name] = detail
                    detail.copper = detail.copper + open.copper
                    detail.quantity = detail.quantity + 1
                    moved = moved + 1
                    PocketCFO:Print("containerfix: %s %s -> Loot & Quests", open.name, FormatCopper(open.copper))
                end
            end
            PocketCFO:Print("containerfix: moved %d of %d.", moved, #OPENS)
            GoldLedger:SendMessage("MCG_GOLD_LEDGER_UPDATED")
        end)
        if not ok then
            PocketCFO:Print("containerfix error: " .. tostring(err))
        end
    end)
end
