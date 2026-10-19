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
--   2. Gold gained while the mailbox is open is matched against the inbox
--      (see the Mailbox section).
--   3. Then a claim with no amount whose direction matches (order completed,
--      loot-money message, gold mailed to your own character).
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

local FLUSH_DELAY = 0.5
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

local MAIL_HOLD_TIMEOUT = 20
local LOOT_CLAIM_TTL = 3
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
GoldLedger.mailSeen = nil   -- last inbox read (by signature) while the mailbox is open
GoldLedger.mailHeld = {}    -- gold gained at the mailbox, waiting to be matched
GoldLedger.mailGone = {}    -- mails whose gold left the inbox, waiting to be matched

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
-- category "mail_hold" = gold gained at the open mailbox; matched against the
-- inbox instead (see the Mailbox section).
function GoldLedger:Classify(entry)
    -- Exact-amount evidence first, then the open mailbox, then direction-only
    -- evidence (loot message, order completed, mail to own character).
    local claim = self:TakeClaim(entry.delta, true)
    if not claim and entry.delta > 0 and entry.mailOpen then
        return "mail_hold"
    end
    claim = claim or self:TakeClaim(entry.delta)
    if claim then
        return claim.category, claim.profession, claim.reason, claim.timestamp, claim.item
    end
    local rules = entry.delta > 0 and INCOME_WINDOW_CATEGORY or SPEND_WINDOW_CATEGORY
    for _, windowEntry in ipairs(rules) do
        if entry.windows[windowEntry.window] then
            return windowEntry.category, nil, "window:" .. windowEntry.window
        end
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
    local recorded, held = 0, 0
    for _, entry in ipairs(pending) do
        local category, professionKey, reason, timestamp, item = self:Classify(entry)
        if category == "mail_hold" and self.windowOpen.mail then
            entry.heldAt = GetTime()
            self.mailHeld[#self.mailHeld + 1] = entry
            held = held + 1
            SessionLog("holding %s for mailbox matching", FormatCopper(entry.delta))
            C_Timer.After(MAIL_HOLD_TIMEOUT + 0.5, function()
                GoldLedger:ReleaseStaleHeld()
            end)
        else
            if category == "mail_hold" then
                -- Mailbox closed before this batch was processed.
                category, reason = "other", "mail:closed-before-match"
            end
            if category == "other" then
                self:LogUnknown(entry.delta, reason, entry.windows, entry.timestamp)
            end
            self:Record(entry.delta, category, professionKey, reason, timestamp or entry.timestamp, item)
            recorded = recorded + 1
        end
    end
    if recorded > 0 then
        self:SendMessage("MCG_GOLD_LEDGER_UPDATED")
    end
    if held > 0 then
        self:SettleMail(false)
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
        if isOpen then
            SessionLog("mailbox opened source=%s", tostring(source))
            self.mailSeen = nil
            self.mailHeld = {}
            self.mailGone = {}
            self:OnMailInbox()
        else
            SessionLog("mailbox closed source=%s", tostring(source))
            self:SettleMail(true)
            self.mailSeen = nil
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

-- Another gold source just proved you are not at the mailbox: close the
-- mailbox session (held gold is matched or released to Unknown).
function GoldLedger:LeaveMailbox(reason)
    if self.windowOpen.mail then
        self:SetWindow("mail", false, reason)
    end
end

-- Held mailbox gold that stays unmatched for MAIL_HOLD_TIMEOUT seconds is
-- released to Unknown so a missed mailbox close can never swallow gold.
function GoldLedger:ReleaseStaleHeld()
    local now = GetTime()
    local kept, released = {}, 0
    for _, entry in ipairs(self.mailHeld) do
        if now - (entry.heldAt or now) >= MAIL_HOLD_TIMEOUT then
            local reason = "mail:timeout-unmatched"
            self:LogUnknown(entry.delta, reason, entry.windows, entry.timestamp)
            self:Record(entry.delta, "other", nil, reason, entry.timestamp)
            released = released + 1
        else
            kept[#kept + 1] = entry
        end
    end
    self.mailHeld = kept
    if released > 0 then
        SessionLog("released %d held mailbox gold change(s) after %ds", released, MAIL_HOLD_TIMEOUT)
        self:SendMessage("MCG_GOLD_LEDGER_UPDATED")
    end
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
-- Mailbox: match gold taken from mail against what left the inbox
-- ---------------------------------------------------------------------------
-- Gold that arrives while the mailbox is open is held, not recorded. Each
-- inbox read compares the mails holding gold now with the previous read; mails
-- whose gold is gone are collected. Whenever the held gold and the gold of the
-- gone mails add up exactly, each gone mail is recorded on its own (category,
-- sale date, item, profession). Works no matter how the game groups the gold
-- (Open All, Postal, TSM). When the mailbox closes, any gold still unmatched
-- is recorded as Mail.
-- Theoretical: a mail whose gold was taken drops out of the inbox read (AH
-- sale mails are deleted; mails with items remain with 0 gold).

-- Describes one inbox mail that holds gold. Field order of
-- GetInboxInvoiceInfo matches MailboxScanner (confirmed in use there).
function GoldLedger:DescribeMail(mailIndex, sender, subject, money, daysLeft)
    local invoiceType, invoiceItemName, invoiceCount
    if GetInboxInvoiceInfo then
        local ok, iType, iName, _, _, _, _, _, _, _, _, iCount = pcall(GetInboxInvoiceInfo, mailIndex)
        if ok then
            invoiceType, invoiceItemName, invoiceCount = iType, iName, iCount
        end
    end

    local mail = {
        signature = table.concat({ tostring(sender), tostring(subject), tostring(money) }, "|"),
        money = money,
    }
    local isAuctionSale = invoiceType == "seller" or invoiceType == "seller_temp_invoice"
        or (sender ~= nil and _G.AUCTION_HOUSE ~= nil and tostring(sender) == tostring(_G.AUCTION_HOUSE))

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

-- Mails currently holding gold, grouped by signature (sender|subject|money)
-- in inbox order. Identical mails (same bag sold at the same price) are
-- interchangeable, so they are counted rather than told apart.
function GoldLedger:ReadInbox()
    local bySignature = {}
    if not GetInboxNumItems or not GetInboxHeaderInfo then
        return bySignature
    end
    local count = tonumber((GetInboxNumItems())) or 0
    for mailIndex = 1, count do
        local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(mailIndex)
        money = tonumber(money)
        if money and money > 0 then
            local mail = self:DescribeMail(mailIndex, sender, subject, money, daysLeft)
            local list = bySignature[mail.signature] or {}
            bySignature[mail.signature] = list
            list[#list + 1] = mail
        end
    end
    return bySignature
end

function GoldLedger:OnMailInbox()
    if not self.windowOpen.mail then
        return
    end
    local current = self:ReadInbox()
    if self.mailSeen then
        for signature, seenList in pairs(self.mailSeen) do
            local remaining = current[signature] and #current[signature] or 0
            for index = remaining + 1, #seenList do
                self.mailGone[#self.mailGone + 1] = seenList[index]
            end
        end
    end
    self.mailSeen = current
    self:SettleMail(false)
end

function GoldLedger:SettleMail(force)
    local heldTotal, goneTotal = 0, 0
    for _, entry in ipairs(self.mailHeld) do
        heldTotal = heldTotal + entry.delta
    end
    for _, mail in ipairs(self.mailGone) do
        goneTotal = goneTotal + mail.money
    end

    if heldTotal > 0 and heldTotal == goneTotal then
        for _, mail in ipairs(self.mailGone) do
            self:Record(mail.money, mail.category, mail.profession, mail.reason, mail.timestamp, mail.item)
        end
        SessionLog("mail settled mails=%d gold=%s", #self.mailGone, FormatCopper(goneTotal))
        self.mailHeld = {}
        self.mailGone = {}
        self:SendMessage("MCG_GOLD_LEDGER_UPDATED")
        return
    end

    if force then
        for _, entry in ipairs(self.mailHeld) do
            local reason = string.format("mail:unmatched goneMails=%d goneGold=%s", #self.mailGone, FormatCopper(goneTotal))
            self:LogUnknown(entry.delta, reason, entry.windows, entry.timestamp)
            self:Record(entry.delta, "other", nil, reason, entry.timestamp)
        end
        if #self.mailHeld > 0 or #self.mailGone > 0 then
            SessionLog("mailbox closed unmatched held=%s goneMails=%d goneGold=%s",
                FormatCopper(heldTotal), #self.mailGone, FormatCopper(goneTotal))
        end
        if #self.mailHeld > 0 then
            self:SendMessage("MCG_GOLD_LEDGER_UPDATED")
        end
        self.mailHeld = {}
        self.mailGone = {}
    end
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
    if not self.windowOpen.merchant or not C_Container or not C_Container.GetContainerItemInfo then
        return
    end
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if not ok or type(info) ~= "table" or not info.hyperlink or info.hasNoValue then
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
