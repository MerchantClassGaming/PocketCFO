-- PocketCFO/Services/LootReader/LootReader.lua
-- One reader for every loot window (design: claude/Loot_Reader_Design.md,
-- agreed with Brian 2026-10-30). Reads each window once, using the rules the
-- existing readers confirmed in-game, and sends one record per finished
-- window. Reports facts only; it never decides what counts. Each consumer
-- keeps its own rules.
--
-- Step 1 (2026-10-30): built with its diagnostic only. Nothing reads from it
-- yet. GatheringCapture, BeastSkinCapture, DisenchantCapture and
-- ContainerOutcomeService still read the loot window themselves and move over
-- one at a time later.
--
-- Rules shared by every current reader (confirmed in-game, see their headers):
--   - LOOT_READY / LOOT_OPENED: re-read the window (area loot and fishing
--     fill in across events). The first LOOT_SLOT_CLEARED stops re-reading,
--     so a half-looted read never replaces a full one. LOOT_CLOSED finishes.
--   - GetLootSlotInfo r3 = quantity received, r4 = currencyID, r5 = quality.
--     GetLootSourceInfo = (guid, qty) pairs, one per source; the source qty
--     is the base amount (received - base = Finesse / Perception bonus).
--   - GUID type = first segment (Creature, Vehicle, GameObject, Item);
--     field 6 = npcID / object ID.
--   - The player cast that opened the window: UNIT_SPELLCAST_SUCCEEDED within
--     CAST_TO_LOOT_SECONDS (observed 0.0-0.1s). A cast is attached to the
--     first window after it only.
-- Container use: C_Container.UseContainerItem hook (same hook GoldLedger and
-- ContainerOutcomeService use, confirmed 2026-10-26), attached when the item
-- has loot, no merchant is open and it was within CONTAINER_TO_LOOT_SECONDS.
-- Secret values: UNIT_SPELLCAST_SENT arg2 (target name) has come back secret
-- in combat (/mcgd loot, 2026-10-26). Every value read here that could be
-- secret is dropped (stored as nil, flagged) rather than kept.
--
-- Messages (AceEvent):
--   MCG_LOOT_WINDOW (record) at LOOT_CLOSED. record = {
--     id, openedAt, closedAt (time()), seconds, firstEvent, reads, locked,
--     fishing (IsFishingLoot at first read), merchantOpen,
--     cast = { spellID, secondsBefore, target, castSeconds } | nil,
--     containerUse = { itemID, link, secondsBefore } | nil,
--     sourceTypes = { [type] = true }, objectID (first GameObject source),
--     context = "fishing" | "disenchant" | "gathering" | "container" | "kill" | "other",
--     slots = { { slot, slotType, itemID, link, name, quantity, quality, currencyID,
--                 sources = { { guid, type, id, qty, link } } } },   -- Item sources:
--                 -- id/link resolved from the GUID while the window is open
--     secretSeen }
--   MCG_LOOT_LINE (line) for each of the player's receive chat lines, parsed
--   by LootMessages: { itemID, link, quantity, kind ("looted" / "received"),
--   at, windowOpen }.
--   MCG_CONTAINER_OPENING (opening), see "Container openings" below.
--   MCG_CONTAINER_CLICK ({ itemID, link, name }) on every container click
--   (item has loot, no merchant open), before the opening is confirmed.
--   MCG_CURRENCY_CHANGE (change) for every currency gain or loss (2026-10-30,
--   Brian: order Moxie, currency farming per hour): { currencyID, name,
--   change, total, gainSource, lostSource, changeFrom ("event" / "total"),
--   at, raw }.
-- Consumers must not modify any of these tables.
--
-- Item Ledger writes (2026-10-30, claude/Item_Ledger_Design.md build step 1):
-- this reader is the only writer of items and currencies coming in (and
-- currency spends). Each thing is written once:
--   - Loot windows: every item slot (slotType 1), at LOOT_CLOSED, category
--     from the context (gathering, fishing, looted = kill, disenchant, other,
--     container), src = the slot's first source ID (node object ID, mob npcID,
--     disenchanted itemID). "Looted" chat lines are never written (every one
--     matched a window slot in-game 2026-10-30). Currency and gold slots are
--     left to the currency event and GoldLedger. Activity counted per window
--     (per corpse for kills).
--   - Container openings: everything attached (lines, windows, currencies) is
--     written as category container, src = container itemID, at the finish,
--     with the openings counted. Ambiguous or not-opened records: each
--     attached thing is written on its own with its own context instead.
--   - "You receive" lines and currency gains not attached to a container:
--     written when they arrive, category from what was happening (ContextFor):
--     a craft result in the last CRAFT_CONTEXT_SECONDS = craft (items: not
--     written here since 2026-11-05, the craft capture writes them through
--     ItemLedger:WriteCraft; currencies still are); an item taken
--     from the mail = transfer (your own character, or an AH cancel / expire
--     / returned mail), auction_buy (AH invoice "buyer"), order_patron
--     (patron reward mail, by subject) or mail (AH purchases
--     arrive by mail, never straight to bags: Brian 2026-10-30, so the AH
--     window itself is not a context); merchant open = vendor; trade open =
--     trade (transfer with
--     your own character); a quest turned in within QUEST_CONTEXT_SECONDS
--     before, or QUEST_LOOKBACK_SECONDS after (world quests) = quest; mailbox
--     open = mail; otherwise received. Currencies keep the
--     game's gain / lost code as src. Spends are written as out, same
--     context, fallback "spent".
--   - Quest items (item class Quest) are never written: they have no value
--     (Brian 2026-10-30; e.g. Lightwood Splinters, put in your bags by a
--     world quest). Theoretical: every such item has the Quest class.
--   Theoretical until /mcg lootreader confirms it: TakeInboxItem /
--   AutoLootMailItem hooks run before the mail is gone (header still
--   readable); trades produce "received" lines; TRADE_SKILL_ITEM_CRAFTED_RESULT
--   arrives before the processing output line.
--   Records carry ledgerIDs (window, opening) once written.
--
-- Currencies (Theoretical until /mcg lootreader confirms it in-game):
--   CURRENCY_DISPLAY_UPDATE args = currencyID, quantity (new total),
--   quantityChange, quantityGainSource, quantityLostSource. Every argument is
--   kept raw on the record. When quantityChange is missing, the change is
--   worked out from the last total this session (changeFrom = "total"); the
--   first event for a currency then has no change and isn't sent.
--   "You receive currency" chat lines (CHAT_MSG_CURRENCY) are only logged by
--   the diagnostic, next to the events, to compare the two. Not sent.
--
-- Container openings (2026-10-30, Brian; replaces the chat-line container tag
-- from earlier the same day). The capture in ContainerOutcomeService had three
-- faults, seen in-game on the payout bags: repeat clicks on one bag counted as
-- extra openings; any "received" line within 10s (order rewards, other bags)
-- counted as contents; and two bags clicked close together could swap lines.
-- Rules here:
--   - A click (UseContainerItem hook; item has loot; no merchant) joins the
--     open record for that container item, or starts one. The hook runs
--     before the bag is used up (the item is still in the slot; confirmed by
--     /mcg containerlog 2026-10-30), so its stack count is the "before" count.
--   - Openings are counted from the slots, not the clicks: at the end, each
--     clicked slot's drop in that item's count (gone = 0), capped at the
--     clicks on it. Repeat clicks and refused opens (bags full) don't drop the
--     count, so they don't count. Theoretical until tested.
--   - Contents: "received" lines within CONTAINER_LINE_SECONDS of the latest
--     click (seen 0.0-0.2s for payout bags), and loot windows that open within
--     that time (their Item sources should resolve to the container).
--   - Two different containers clicked within CONTAINER_LINE_SECONDS of each
--     other, or a line that could belong to either: both records are marked
--     ambiguous (consumers skip them; nothing is guessed).
--   - Split by expansion (2026-10-31, Brian): records marked ambiguous by each
--     other form a burst, finished together when the last one finishes. The
--     burst is split when every container has a different expansion (item
--     info return 15; in-game 2026-10-31: Mycobloom 10 = War Within,
--     Void-Tempered Leather 11 = Midnight) and every item matches exactly one
--     of them; and nothing else is mixed in (no loot window, no currency, no
--     gold gained). Each record then counts as a normal opening with its own
--     items. Otherwise every record stays ambiguous. Aimed at War Within and
--     Midnight payout bags opened together. Theoretical: a container item's
--     own expansion matches the expansion of its contents.
--   - Currencies (2026-10-30, Brian: same rules as items): a currency GAIN
--     (CURRENCY_DISPLAY_UPDATE, change > 0) within CONTAINER_LINE_SECONDS of
--     the latest click is part of the contents; one that could belong to two
--     records marks both ambiguous. Spends never attach. Not filtered by gain
--     source (seen 9 for the Aqir Research Satchel, one container only).
--     Theoretical: container currency always arrives within that second.
--   - A record is finished CONTAINER_FINISH_SECONDS after its latest click and
--     sent as MCG_CONTAINER_OPENING = { itemID, link, opens, clicks, at,
--     lines = { { itemID, link, quantity, gap } }, windows = { window record },
--     currencies = { { currencyID, name, quantity, gainSource, gap } },
--     copper, ambiguous, reason }.
--   - copper (2026-10-30, container migration): the rise in the player's gold
--     from the first click to the finish, on records that are not ambiguous
--     and had an opening. Other gold landing in those seconds (looted coin, a
--     sale) would be counted too; accepted, same as the old capture.
--     Theoretical: a gold-only container's gold arrives within
--     CONTAINER_FINISH_SECONDS. Records with no confirmed opening are not sent
--     (they are kept in the diagnostic with the reason).
-- Income: GoldLedger files container gold as looted gold on its own; copper
-- here is only for the container's average contents.
--
-- Context label (facts always win; see the design doc):
--   fishing     IsFishingLoot() true
--   disenchant  cast 13262
--   gathering   cast is a known gathering spell (same list as GatheringCapture
--               today; Gathering reads it from here once it migrates)
--   container   a container use is attached and no Creature / GameObject /
--               Vehicle source
--   kill        a Creature or Vehicle source
--   other       anything else (chests, quest objects, unknown casts)
--
-- Diagnostic: /mcg lootreader [on|off|show|clear]. Off by default; while on,
-- the last LOG_LIMIT windows, loot chat lines, container openings, currency
-- changes and currency chat lines are kept in PocketCFO_DB.global.lootReaderLog
-- (survives /reload).
--
-- Flavor: Both (PocketCFO.toc and PocketCFO_Camelot.toc). Every API call is
-- pcall-wrapped. Theoretical on Forever: everything above until tested there.
-- A plain event frame is used for game events (CraftSim's bundled AceEvent
-- can shift callback arguments); AceEvent is used for messages only.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local LootReader = PocketCFO:NewModule("LootReader", "AceEvent-3.0")
PocketCFO.LootReader = LootReader

local CAST_TO_LOOT_SECONDS = 3
local CONTAINER_TO_LOOT_SECONDS = 10
local CONTAINER_LINE_SECONDS = 1     -- payout bag contents arrived 0.0-0.2s after the click
local CONTAINER_FINISH_SECONDS = 2
local MAX_CAST_SECONDS = 10
local LOG_LIMIT = 300  -- raised from 50 for testing (2026-10-30): a crushing run filled 50 lines
local DISENCHANT_SPELL_ID = 13262

-- The one gathering spell list (2026-10-30: moved here from GatheringCapture,
-- which reads it as LootReader.GATHER_SPELLS). spellID -> { profession =
-- base profession skill line as a string, source = "node" (GameObject) or
-- "corpse" (Creature / Vehicle), hidden = captured but not shown }.
-- Confirmed in-game: 471009, 471013 (2026-10-23); 195125 (2026-10-16);
-- 32606, 32605 (2026-10-26, again 2026-10-30); 1239682 (2026-10-26).
local GATHER_SPELLS = {
    [471009] = { profession = "182", source = "node" },   -- Herb Gathering
    [471013] = { profession = "186", source = "node" },   -- Midnight Mining
    [195125] = { profession = "393", source = "corpse" }, -- Skinning
    [32606]  = { profession = "186", source = "corpse" }, -- Mining (creatures)
    [32605]  = { profession = "182", source = "corpse" }, -- Herb Gathering (creatures)
    [1239682] = { profession = "lumber", source = "node", hidden = true }, -- Woodchopping (housing lumber)
}
-- WoW Forever gathering spells (Forever-only, gated). Each rank
-- (Apprentice / Journeyman / Expert / Artisan) casts with its own spell ID,
-- so every rank is listed. Confirmed in-game 2026-11-05 from /mcg gatherlog:
-- 2575 Mining on Copper Vein (GameObject source), 8613 Skinning, and 8617
-- Skinning once the character reached Journeyman (skins were ignored until
-- this was added). The other rank IDs are the classic-client values:
-- Theoretical for Forever until seen. Herb Gathering ranks are Theoretical
-- too; an unknown ID lands in the miss log (/mcg gatherlog).
if PocketCFO.flavor == "forever" then
    -- Mining: Apprentice, Journeyman, Expert, Artisan
    GATHER_SPELLS[2575]  = { profession = "186", source = "node" }
    GATHER_SPELLS[2576]  = { profession = "186", source = "node" }
    GATHER_SPELLS[3564]  = { profession = "186", source = "node" }
    GATHER_SPELLS[10248] = { profession = "186", source = "node" }
    -- Skinning: Apprentice, Journeyman, Expert, Artisan
    GATHER_SPELLS[8613]  = { profession = "393", source = "corpse" }
    GATHER_SPELLS[8617]  = { profession = "393", source = "corpse" }
    GATHER_SPELLS[8618]  = { profession = "393", source = "corpse" }
    GATHER_SPELLS[10768] = { profession = "393", source = "corpse" }
    -- Herb Gathering: Apprentice, Journeyman, Expert, Artisan
    GATHER_SPELLS[2366]  = { profession = "182", source = "node" }
    GATHER_SPELLS[2368]  = { profession = "182", source = "node" }
    GATHER_SPELLS[3570]  = { profession = "182", source = "node" }
    GATHER_SPELLS[11993] = { profession = "182", source = "node" }
end
LootReader.GATHER_SPELLS = GATHER_SPELLS

-- Fished-up chests (moved here from GatheringCapture 2026-10-30, the one
-- rule): a known chest object opened within FISHING_CHEST_SECONDS of a
-- fishing catch is a fishing window. Confirmed in-game 2026-10-26: a chest
-- spawns at the player's feet, is opened with Opening, and IsFishingLoot() is
-- false for it, so it is recognized by its GameObject ID. New chest IDs show
-- up in GatheringCapture's miss log (/mcg gatherlog) to be added here.
local FISHING_CHESTS = {
    [540505] = true, -- Patient Treasure (Matatodos, 2026-10-26)
}
LootReader.FISHING_CHESTS = FISHING_CHESTS
local FISHING_CHEST_SECONDS = 300
local lastFishingAt = nil   -- GetTime() of the last fishing window

local eventFrame = CreateFrame("Frame")

-- Session state (not saved).
local lastSent = nil      -- { spellID, at, target }
local castStart = nil     -- { spellID, at }
local lastCast = nil      -- { spellID, at, target, castSeconds } waiting for a window
local lastUse = nil       -- { itemID, link, hasLoot, merchant, at }
local currencyTotals = {} -- [currencyID] = last total seen this session
local openings = {}       -- container opening records not finished yet
local current = nil       -- window being read
local nextID = 0

-- What's happening, for the ledger category of "received" lines and
-- currencies (see header). Memory only.
local CRAFT_CONTEXT_SECONDS = 1.5
local QUEST_CONTEXT_SECONDS = 3
-- World quest rewards arrive a moment BEFORE QUEST_TURNED_IN (in-game
-- 2026-10-30: Voidlight Marl at 15:29:57, the quest's renown at 15:29:58), so
-- a gain that would be "received" waits this long for a quest before writing.
local QUEST_LOOKBACK_SECONDS = 2
local MAIL_TAKE_SECONDS = 3
local windowOpen = {}     -- merchant / auction / mail / trade
local lastMailTake = nil  -- { at, sender, subject, invoiceType, returned }
local lastQuestAt = nil
local lastCraftAt = nil
local tradePartner = nil

local WINDOW_EVENTS = {
    MERCHANT_SHOW = { "merchant", true }, MERCHANT_CLOSED = { "merchant", false },
    AUCTION_HOUSE_SHOW = { "auction", true }, AUCTION_HOUSE_CLOSED = { "auction", false },
    MAIL_SHOW = { "mail", true }, MAIL_CLOSED = { "mail", false },
    TRADE_SHOW = { "trade", true }, TRADE_CLOSED = { "trade", false },
}
-- PLAYER_INTERACTION_MANAGER_FRAME_SHOW / HIDE types (same table as
-- GoldLedger; MailInfo 17 confirmed there 2026-10-19: closing the mailbox
-- fires FRAME_HIDE 17 and never MAIL_CLOSED).
local INTERACTION_WINDOWS = {}
do
    local types = Enum and Enum.PlayerInteractionType or {}
    INTERACTION_WINDOWS[types.MailInfo or 17] = "mail"
    if types.Merchant then INTERACTION_WINDOWS[types.Merchant] = "merchant" end
    if types.Auctioneer then INTERACTION_WINDOWS[types.Auctioneer] = "auction" end
    if types.TradePartner then INTERACTION_WINDOWS[types.TradePartner] = "trade" end
end

local WINDOW_CATEGORY = {
    gathering = "gathering", fishing = "fishing", kill = "looted",
    disenchant = "disenchant", container = "container", other = "other",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function IsSecret(value)
    return type(issecretvalue) == "function" and issecretvalue(value) == true
end

-- Value safe to keep, or nil. Second return true when it was secret.
local function Plain(value)
    if IsSecret(value) then
        return nil, true
    end
    return value, false
end

local function ItemIDFromLink(link)
    if type(link) ~= "string" then
        return nil
    end
    return tonumber(link:match("item:(%d+)"))
end

local function GUIDParts(guid)
    if type(guid) ~= "string" then
        return nil, nil
    end
    local ok, guidType, _, _, _, _, id = pcall(strsplit, "-", guid)
    if not ok then
        return nil, nil
    end
    if guidType == "Creature" or guidType == "Vehicle" or guidType == "GameObject" then
        return guidType, tonumber(id)
    end
    return guidType, nil
end

local function MerchantOpen()
    return MerchantFrame ~= nil and MerchantFrame.IsShown ~= nil and MerchantFrame:IsShown() == true
end

local function FishingLoot()
    if type(IsFishingLoot) ~= "function" then
        return false
    end
    local ok, fishing = pcall(IsFishingLoot)
    return ok and fishing == true
end

local function LogDB()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return nil
    end
    local log = globalDB.lootReaderLog or {}
    globalDB.lootReaderLog = log
    log.windows = log.windows or {}
    log.lines = log.lines or {}
    log.currency = log.currency or {}
    log.openings = log.openings or {}
    log.currencyLines = log.currencyLines or {}
    return log
end

local function Keep(list, entry)
    list[#list + 1] = entry
    while #list > LOG_LIMIT do
        table.remove(list, 1)
    end
end

-- ---------------------------------------------------------------------------
-- Item Ledger (see header)
-- ---------------------------------------------------------------------------

local function Ledger()
    return PocketCFO.ItemLedger
end

local function SubjectStarts(subject, globalName, fallback)
    subject = tostring(subject or "")
    local format = _G[globalName]
    local prefix = type(format) == "string" and string.match(format, "^(.-)%%") or nil
    if prefix and prefix ~= "" then
        return string.sub(subject, 1, #prefix) == prefix
    end
    return fallback ~= nil and string.find(subject, fallback, 1, true) == 1
end

-- Category for an item taken from the mail.
local function MailCategory(take)
    local ledger = Ledger()
    if take.returned then
        return "transfer", "mail_returned"
    end
    if take.invoiceType == "buyer" then
        return "auction_buy", nil
    end
    -- Patron order reward mail: sender Artisans Consortium, subject "Patron
    -- Crafting Order Commission" (War Within order, Brian's screenshot
    -- 2026-10-30). Theoretical for Midnight orders and for non-English clients.
    if string.find(tostring(take.subject or ""), "Patron Crafting Order", 1, true) then
        return "order_patron", nil
    end
    if SubjectStarts(take.subject, "AUCTION_REMOVED_MAIL_SUBJECT", "Auction cancelled")
        or SubjectStarts(take.subject, "AUCTION_EXPIRED_MAIL_SUBJECT", "Auction expired") then
        return "transfer", "auction_return"
    end
    if ledger and ledger:IsOwnCharacter(take.sender) then
        return "transfer", "mail"
    end
    return "mail", nil
end

-- { cat, src, label } for something arriving now with no loot window.
local function ContextFor(now)
    if lastCraftAt and (now - lastCraftAt) <= CRAFT_CONTEXT_SECONDS then
        return "craft", nil
    end
    if windowOpen.mail and lastMailTake and (now - lastMailTake.at) <= MAIL_TAKE_SECONDS then
        return MailCategory(lastMailTake)
    end
    if windowOpen.merchant or MerchantOpen() then
        return "vendor", nil
    end
    if windowOpen.trade then
        local ledger = Ledger()
        if ledger and ledger:IsOwnCharacter(tradePartner) then
            return "transfer", "trade"
        end
        return "trade", nil
    end
    if lastQuestAt and (now - lastQuestAt) <= QUEST_CONTEXT_SECONDS then
        return "quest", nil
    end
    if windowOpen.mail then
        return "mail", nil
    end
    return "received", nil
end

local QUEST_ITEM_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Questitem) or 12

local function IsQuestItem(itemID)
    local getInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
    if not getInstant or not itemID then
        return false
    end
    local ok, _, _, _, _, _, classID = pcall(getInstant, itemID)
    return ok and classID == QUEST_ITEM_CLASS
end

local function SafeWrite(fields)
    local ledger = Ledger()
    if not ledger then
        return nil
    end
    if fields.kind == "item" and IsQuestItem(fields.iid) then
        return nil
    end
    local ok, id = pcall(ledger.Write, ledger, fields)
    return ok and id or nil
end

local function SafeCount(cat, src, count, prof)
    local ledger = Ledger()
    if ledger then
        pcall(ledger.CountActivity, ledger, cat, src, count, nil, prof)
    end
end

-- A "received" line or currency change waiting to be written: { kind, iid,
-- link, qty, dir, cat, src, written, attached }. Written once (written flag),
-- either on its own or as container contents.
local function WritePending(pending, cat, src)
    if pending.written then
        return nil
    end
    pending.written = true
    local id = SafeWrite({
        dir = pending.dir or "in",
        cat = cat or pending.cat,
        src = src or pending.src,
        kind = pending.kind,
        iid = pending.iid,
        link = pending.link,
        qty = pending.qty,
    })
    pending.ledgerID = id
    return id
end

-- A gain with no context ("received") waits QUEST_LOOKBACK_SECONDS: if a quest
-- is turned in meanwhile it is written as quest (see QUEST_LOOKBACK_SECONDS).
-- Everything else is written now. Gains still waiting are lost on /reload.
local function WriteGain(pending)
    if pending.cat ~= "received" or not (C_Timer and C_Timer.After) then
        return WritePending(pending)
    end
    local heldAt = GetTime()
    C_Timer.After(QUEST_LOOKBACK_SECONDS, function()
        -- Craft output whose line arrived just BEFORE the craft result event
        -- (in-game 2026-11-05: a prospect's Dusk-Shrouded Stone line came
        -- first and was written as received on top of the craft capture's
        -- entry). A craft result within CRAFT_CONTEXT_SECONDS either side of
        -- the line means it's craft output: written by the craft capture.
        if pending.kind == "item" and lastCraftAt and lastCraftAt >= heldAt - CRAFT_CONTEXT_SECONDS then
            return
        end
        if lastQuestAt and lastQuestAt >= heldAt then
            pending.cat = "quest"
        end
        WritePending(pending)
    end)
    return nil
end

-- First source ID of a slot (node object ID, mob npcID, Item source itemID).
local function SlotSource(slot)
    local first = slot.sources and slot.sources[1]
    return first and first.id or nil
end

-- Writes a loot window's item slots. cat / src override the window's own
-- (container contents); otherwise from its context. Returns entry ids.
local function WriteWindowItems(window, cat, src, countActivity)
    local ids = {}
    cat = cat or WINDOW_CATEGORY[window.context] or "other"
    local extra = window.cast and { spell = window.cast.spellID } or nil
    -- Profession (2026-10-30): from the gathering spell; fishing is "fishing".
    local prof = nil
    if cat == "fishing" then
        prof = "fishing"
    elseif cat == "gathering" and window.cast and GATHER_SPELLS[window.cast.spellID] then
        prof = GATHER_SPELLS[window.cast.spellID].profession
    end
    local activity, corpses = nil, {}
    for _, slot in ipairs(window.slots or {}) do
        local quantity = tonumber(slot.quantity) or 0
        if slot.slotType == 1 and slot.itemID and quantity > 0 then
            local base = 0
            for _, source in ipairs(slot.sources or {}) do
                base = base + (tonumber(source.qty) or 0)
                if source.type == "Creature" or source.type == "Vehicle" then
                    corpses[source.guid] = source.id
                end
            end
            local slotSrc = src
            if not slotSrc and window.context == "container" then
                slotSrc = window.containerUse and window.containerUse.itemID
            end
            slotSrc = slotSrc or SlotSource(slot)
            activity = activity or slotSrc
            local id = SafeWrite({
                dir = "in", cat = cat, src = slotSrc, kind = "item", iid = slot.itemID, link = slot.link,
                qty = quantity, base = (cat == "gathering" or cat == "fishing") and base > 0 and base or nil,
                x = extra, prof = prof,
            })
            if id then
                ids[#ids + 1] = id
            end
        end
    end
    -- Disenchant (Going Out step 2, 2026-11-05): the item destroyed is the
    -- window's Item source (id and link resolved while the window was open,
    -- confirmed 2026-10-25). Written once as disenchant out, src = its itemID,
    -- with the mats, so one window = one writer. Book value is taken by the
    -- Item Ledger. Flavor: Both (Theoretical on Forever).
    if cat == "disenchant" and #ids > 0 then
        local destroyed
        for _, slot in ipairs(window.slots or {}) do
            for _, source in ipairs(slot.sources or {}) do
                if source.type == "Item" and source.id then
                    destroyed = source
                    break
                end
            end
            if destroyed then
                break
            end
        end
        if destroyed then
            local matIDs = { unpack(ids) }
            local id = SafeWrite({
                dir = "out", cat = "disenchant", src = destroyed.id, kind = "item", iid = destroyed.id,
                link = destroyed.link, qty = 1, x = extra,
            })
            if id then
                ids[#ids + 1] = id
                -- Cost: the mats cost what the destroyed item cost, split by
                -- value (ItemLedger:AllocateCost, 2026-11-05).
                local ledger = Ledger()
                local out = ledger and ledger.GetEntry and ledger:GetEntry(id)
                if out and ledger.AllocateCost then
                    local mats = {}
                    for _, matID in ipairs(matIDs) do
                        local entry = ledger:GetEntry(matID)
                        if entry then
                            mats[#mats + 1] = entry
                        end
                    end
                    pcall(ledger.AllocateCost, ledger, mats, tonumber(out.cost) or 0)
                end
            end
        end
    end
    if countActivity and #ids > 0 then
        if cat == "looted" then
            for _, npcID in pairs(corpses) do
                SafeCount(cat, npcID, 1)
            end
        else
            SafeCount(cat, activity, 1, prof)
        end
    end
    return ids
end

local function OnMailTake(mailIndex)
    if not GetInboxHeaderInfo then
        return
    end
    local ok, _, _, sender, subject, _, _, _, _, _, wasReturned = pcall(GetInboxHeaderInfo, mailIndex)
    if not ok then
        return
    end
    local take = { at = GetTime(), sender = (Plain(sender)), subject = (Plain(subject)),
        returned = wasReturned and true or false }
    if GetInboxInvoiceInfo then
        local okInvoice, invoiceType = pcall(GetInboxInvoiceInfo, mailIndex)
        take.invoiceType = okInvoice and invoiceType or nil
    end
    lastMailTake = take
end

local function SetWindow(window, isOpen)
    windowOpen[window] = isOpen and true or nil
    if window == "trade" then
        tradePartner = nil
        if isOpen and UnitName then
            local ok, name = pcall(UnitName, "NPC")
            tradePartner = ok and (Plain(name)) or nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

local function ReadSlots(window)
    local slots = {}
    local okCount, numItems = pcall(GetNumLootItems)
    numItems = okCount and tonumber(numItems) or 0
    local sourceTypes = {}
    local objectID = nil
    for slot = 1, numItems do
        local entry = { slot = slot, sources = {} }
        local okType, slotType = pcall(GetLootSlotType, slot)
        entry.slotType = okType and tonumber(slotType) or nil
        local okLink, link = pcall(GetLootSlotLink, slot)
        local secret
        link, secret = Plain(okLink and link or nil)
        window.secretSeen = window.secretSeen or secret
        entry.link = type(link) == "string" and link or nil
        entry.itemID = ItemIDFromLink(entry.link)
        local okInfo, _, name, quantity, currencyID, quality = pcall(GetLootSlotInfo, slot)
        if okInfo then
            name, secret = Plain(name)
            window.secretSeen = window.secretSeen or secret
            quantity, secret = Plain(quantity)
            window.secretSeen = window.secretSeen or secret
            entry.name = type(name) == "string" and name or nil
            entry.quantity = tonumber(quantity)
            entry.currencyID = tonumber(currencyID)
            entry.quality = tonumber(quality)
        end
        local sources = { pcall(GetLootSourceInfo, slot) }
        if sources[1] then
            for i = 2, #sources, 2 do
                local guid, qty = sources[i], sources[i + 1]
                guid, secret = Plain(guid)
                window.secretSeen = window.secretSeen or secret
                qty = Plain(qty)
                if guid then
                    local guidType, id = GUIDParts(guid)
                    local sourceLink = nil
                    -- Item sources (disenchant, containers): resolve while the
                    -- window is open (confirmed for disenchant 2026-10-25).
                    if guidType == "Item" and C_Item then
                        if type(C_Item.GetItemIDByGUID) == "function" then
                            local okID, itemID = pcall(C_Item.GetItemIDByGUID, guid)
                            id = okID and tonumber((Plain(itemID))) or nil
                        end
                        if type(C_Item.GetItemLinkByGUID) == "function" then
                            local okLink2, resolved = pcall(C_Item.GetItemLinkByGUID, guid)
                            resolved = okLink2 and Plain(resolved) or nil
                            sourceLink = type(resolved) == "string" and resolved or nil
                        end
                        id = id or ItemIDFromLink(sourceLink)
                    end
                    entry.sources[#entry.sources + 1] = { guid = guid, type = guidType, id = id, qty = tonumber(qty),
                        link = sourceLink }
                    if guidType then
                        sourceTypes[guidType] = true
                    end
                    if guidType == "GameObject" and not objectID then
                        objectID = id
                    end
                end
            end
        end
        slots[#slots + 1] = entry
    end
    window.slots = slots
    window.sourceTypes = sourceTypes
    window.objectID = objectID
    window.reads = (window.reads or 0) + 1
end

local function Classify(window)
    local types = window.sourceTypes or {}
    local castID = window.cast and window.cast.spellID
    if window.fishing then
        return "fishing"
    elseif window.objectID and FISHING_CHESTS[window.objectID] and lastFishingAt
        and (GetTime() - lastFishingAt) <= FISHING_CHEST_SECONDS then
        window.fishingChest = true
        return "fishing"
    elseif castID == DISENCHANT_SPELL_ID then
        return "disenchant"
    elseif castID and GATHER_SPELLS[castID] then
        return "gathering"
    elseif window.containerUse and not (types.Creature or types.GameObject or types.Vehicle) then
        return "container"
    elseif types.Creature or types.Vehicle then
        return "kill"
    end
    return "other"
end

local function OpenWindow(event)
    local now = GetTime()
    nextID = nextID + 1
    local window = {
        id = nextID,
        openedAt = time(),
        openedClock = now,
        firstEvent = event,
        fishing = FishingLoot(),
        merchantOpen = MerchantOpen(),
        slots = {},
        sourceTypes = {},
        reads = 0,
    }
    if lastCast and (now - lastCast.at) <= CAST_TO_LOOT_SECONDS then
        window.cast = {
            spellID = lastCast.spellID,
            secondsBefore = now - lastCast.at,
            target = lastCast.target,
            castSeconds = lastCast.castSeconds,
        }
        lastCast = nil
    end
    if lastUse and lastUse.hasLoot and not lastUse.merchant and (now - lastUse.at) <= CONTAINER_TO_LOOT_SECONDS then
        window.containerUse = { itemID = lastUse.itemID, link = lastUse.link, secondsBefore = now - lastUse.at }
        lastUse = nil
    end
    return window
end

-- The window being read right now (nil when none), for consumers that must
-- tie something arriving mid-window to it (GatheringCapture proc toasts,
-- 2026-10-30). Read-only. Has id, fishing, cast, objectID (after the first
-- read); context is only set at close.
function LootReader:GetOpenWindow()
    return current
end

local function CloseWindow()
    local window = current
    current = nil
    if not window then
        return
    end
    window.closedAt = time()
    window.seconds = GetTime() - window.openedClock
    local openedClock = window.openedClock
    window.openedClock = nil
    window.context = Classify(window)
    if window.fishing then
        lastFishingAt = GetTime()
    end
    local attached = 0
    if window.sourceTypes and window.sourceTypes.Item then
        attached = LootReader:AttachWindowToOpening(window, openedClock) or 0
    end
    -- Item Ledger: a window that belongs to a container opening is written
    -- with the opening; any other window is written now.
    if attached == 0 then
        window.ledgerIDs = WriteWindowItems(window, nil, nil, true)
    end
    LootReader:SendMessage("MCG_LOOT_WINDOW", window)
    local log = LogDB()
    if log and log.enabled then
        Keep(log.windows, window)
    end
end

-- ---------------------------------------------------------------------------
-- Chat lines and container uses
-- ---------------------------------------------------------------------------

local function OnLootLine(text)
    local parser = PocketCFO.LootMessages
    if not parser or IsSecret(text) then
        return
    end
    local itemID, link, quantity, kind = parser:Parse(text)
    if not itemID then
        return
    end
    local line = { itemID = itemID, link = link, quantity = quantity, kind = kind, at = time(),
        windowOpen = current ~= nil }
    if kind == "received" then
        -- Item Ledger: written now in its context, or with the container
        -- opening it belongs to (see header).
        local cat, src = ContextFor(GetTime())
        line.ctx = cat
        local pending = { kind = "item", iid = itemID, link = link, qty = tonumber(quantity) or 1,
            dir = "in", cat = cat, src = src }
        if cat == "craft" then
            -- Going Out step 1 (2026-11-05): craft facts (output, returns,
            -- mats used) are written by the craft capture (ItemLedger:WriteCraft),
            -- one writer per fact. A line in craft context is only logged.
            line.ctx = "craft (written by craft capture)"
        elseif (LootReader:AttachLineToOpening(line, pending) or 0) == 0 then
            WriteGain(pending)
        else
            line.ctx = "container (else " .. cat .. ")"
        end
    end
    LootReader:SendMessage("MCG_LOOT_LINE", line)
    local log = LogDB()
    if log and log.enabled then
        Keep(log.lines, line)
    end
end

local function CurrencyName(currencyID)
    if C_CurrencyInfo and type(C_CurrencyInfo.GetCurrencyInfo) == "function" then
        local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
        if ok and type(info) == "table" and type(info.name) == "string" and not IsSecret(info.name) then
            return info.name
        end
    end
    return nil
end

local function OnCurrencyUpdate(...)
    local args = { n = select("#", ...), ... }
    local raw = {}
    for i = 1, args.n do
        local value, secret = Plain(args[i])
        raw[#raw + 1] = "arg" .. i .. "=" .. (secret and "<secret>" or tostring(value))
    end
    local currencyID = tonumber((Plain(args[1])))
    if not currencyID then
        return
    end
    local total = tonumber((Plain(args[2])))
    local change = tonumber((Plain(args[3])))
    local changeFrom = "event"
    if not change and total and currencyTotals[currencyID] then
        change = total - currencyTotals[currencyID]
        changeFrom = "total"
    end
    if total then
        currencyTotals[currencyID] = total
    end
    if not change or change == 0 then
        return
    end
    local entry = {
        currencyID = currencyID,
        name = CurrencyName(currencyID),
        change = change,
        total = total,
        gainSource = tonumber((Plain(args[4]))),
        lostSource = tonumber((Plain(args[5]))),
        changeFrom = changeFrom,
        at = time(),
        raw = table.concat(raw, " "),
    }
    -- Item Ledger: gains go with a container opening or are written now in
    -- their context; spends are written as out (see header).
    local cat, src = ContextFor(GetTime())
    entry.ctx = cat
    local pending = { kind = "currency", iid = currencyID, qty = math.abs(change),
        dir = change > 0 and "in" or "out", cat = cat, src = src }
    if change > 0 then
        pending.src = src or entry.gainSource
        if (LootReader:AttachCurrencyToOpening(entry, pending) or 0) == 0 then
            WriteGain(pending)
        end
    else
        pending.cat = (cat == "received") and "spent" or cat
        pending.src = src or entry.lostSource
        WritePending(pending)
    end
    LootReader:SendMessage("MCG_CURRENCY_CHANGE", entry)
    local log = LogDB()
    if log and log.enabled then
        Keep(log.currency, entry)
    end
end

local function OnCurrencyLine(text)
    local log = LogDB()
    if not log or not log.enabled or type(text) ~= "string" or IsSecret(text) then
        return
    end
    Keep(log.currencyLines, { at = time(), text = text })
end

local function OnUseContainerItem(bag, slot)
    if not C_Container or type(C_Container.GetContainerItemInfo) ~= "function" then
        return
    end
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if not ok or type(info) ~= "table" then
        return
    end
    lastUse = {
        itemID = tonumber(info.itemID),
        link = info.hyperlink,
        hasLoot = info.hasLoot and true or false,
        merchant = MerchantOpen(),
        at = GetTime(),
    }
    if lastUse.hasLoot and not lastUse.merchant and lastUse.itemID then
        LootReader:NoteContainerClick(bag, slot, lastUse.itemID, lastUse.link, tonumber(info.stackCount) or 1)
        -- One container detector (2026-10-30): GoldLedger claims container
        -- gold from this instead of its own hook.
        LootReader:SendMessage("MCG_CONTAINER_CLICK", { itemID = lastUse.itemID, link = lastUse.link,
            name = info.itemName })
    end
end

-- ---------------------------------------------------------------------------
-- Container openings (see header)
-- ---------------------------------------------------------------------------

local function OpenRecordFor(itemID)
    for _, record in ipairs(openings) do
        if record.itemID == itemID then
            return record
        end
    end
    return nil
end

local function SlotCount(bag, slot, itemID)
    if not C_Container or type(C_Container.GetContainerItemInfo) ~= "function" then
        return nil
    end
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if not ok then
        return nil
    end
    if type(info) ~= "table" or tonumber(info.itemID) ~= itemID then
        return 0
    end
    return tonumber(info.stackCount) or 1
end

-- Records that marked each other ambiguous share one burst table (see header).
local function JoinBurst(a, b)
    local burst = a.burst or b.burst
    if not burst then
        burst = { records = {} }
    end
    for _, record in ipairs({ a, b }) do
        local old = record.burst
        if old and old ~= burst then
            for _, member in ipairs(old.records) do
                member.burst = burst
                burst.records[#burst.records + 1] = member
            end
        elseif not old then
            record.burst = burst
            burst.records[#burst.records + 1] = record
        end
    end
end

-- Expansion number of an item (item info return 15), nil when unknown.
local function ItemExpansion(itemID)
    local getInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
    if not getInfo or not itemID then
        return nil
    end
    local results = { pcall(getInfo, itemID) }
    if not results[1] then
        return nil
    end
    return tonumber(results[16])
end

function LootReader:NoteContainerClick(bag, slot, itemID, link, stackCount)
    local now = GetTime()
    local record = OpenRecordFor(itemID)
    if not record then
        record = { itemID = itemID, link = link, at = time(), firstAt = now, lastAt = now, clicks = 0,
            slots = {}, lines = {}, windows = {}, currencies = {}, moneyBefore = GetMoney and GetMoney() or nil }
        openings[#openings + 1] = record
    end
    -- Another container clicked close in time: contents can't be told apart.
    for _, other in ipairs(openings) do
        if other ~= record and (now - other.lastAt) <= CONTAINER_LINE_SECONDS then
            other.ambiguous = true
            record.ambiguous = true
            JoinBurst(record, other)
        end
    end
    local key = tostring(bag) .. ":" .. tostring(slot)
    local slotEntry = record.slots[key]
    if not slotEntry then
        slotEntry = { bag = bag, slot = slot, before = stackCount, clicks = 0 }
        record.slots[key] = slotEntry
    end
    slotEntry.clicks = slotEntry.clicks + 1
    record.clicks = record.clicks + 1
    record.lastAt = now
    local token = {}
    record.token = token
    if C_Timer and C_Timer.After then
        C_Timer.After(CONTAINER_FINISH_SECONDS, function()
            if record.token == token then
                LootReader:FinishOpening(record)
            end
        end)
    end
end

-- Candidate records for something that arrived now: clicked within
-- CONTAINER_LINE_SECONDS.
local function Candidates(at)
    local list = {}
    for _, record in ipairs(openings) do
        local gap = at - record.lastAt
        if gap >= 0 and gap <= CONTAINER_LINE_SECONDS then
            list[#list + 1] = record
        end
    end
    return list
end

-- Item Ledger: things waiting on a record are kept in record.pendings (memory
-- only; removed before the record is sent or logged). Returns how many
-- records it was attached to.
local function AddPending(record, pending)
    if pending then
        record.pendings = record.pendings or {}
        record.pendings[#record.pendings + 1] = pending
    end
end

function LootReader:AttachLineToOpening(line, pending)
    local now = GetTime()
    local list = Candidates(now)
    for _, record in ipairs(list) do
        record.lines[#record.lines + 1] = { itemID = line.itemID, link = line.link, quantity = line.quantity,
            gap = now - record.lastAt }
        AddPending(record, pending)
        if #list > 1 then
            record.ambiguous = true
            JoinBurst(record, list[1])
        end
    end
    return #list
end

-- A currency gain that arrived now (same rules as AttachLineToOpening).
function LootReader:AttachCurrencyToOpening(entry, pending)
    local now = GetTime()
    local list = Candidates(now)
    for _, record in ipairs(list) do
        record.currencies = record.currencies or {}
        record.currencies[#record.currencies + 1] = { currencyID = entry.currencyID, name = entry.name,
            quantity = entry.change, gainSource = entry.gainSource, gap = now - record.lastAt }
        AddPending(record, pending)
        if #list > 1 then
            record.ambiguous = true
            JoinBurst(record, list[1])
        end
    end
    return #list
end

function LootReader:AttachWindowToOpening(window, openedClock)
    local list = Candidates(openedClock or GetTime())
    for _, record in ipairs(list) do
        record.windows[#record.windows + 1] = window
        if #list > 1 then
            record.ambiguous = true
            JoinBurst(record, list[1])
        end
    end
    return #list
end

-- Item Ledger write for a finished opening (see header). A counted opening:
-- everything as container contents. Ambiguous / not opened: each thing on
-- its own, in its own context.
local function WriteOpening(record)
    local ids = {}
    local asContainer = (record.opens or 0) > 0 and not record.ambiguous
    for _, pending in ipairs(record.pendings or {}) do
        local id
        if asContainer then
            id = WritePending(pending, "container", record.itemID)
        else
            id = WritePending(pending)
        end
        if id then
            ids[#ids + 1] = id
        end
    end
    for _, window in ipairs(record.windows or {}) do
        if not window.ledgerWritten then
            window.ledgerWritten = true
            local written
            local types = window.sourceTypes or {}
            local fromWorld = window.fishing or types.Creature or types.GameObject or types.Vehicle
            if asContainer and not fromWorld then
                written = WriteWindowItems(window, "container", record.itemID, false)
            else
                written = WriteWindowItems(window, nil, nil, true)
            end
            window.ledgerIDs = written
            for _, id in ipairs(written) do
                ids[#ids + 1] = id
            end
        end
    end
    if asContainer then
        SafeCount("container", record.itemID, record.opens)
    end
    record.ledgerIDs = ids
end

function LootReader:FinishOpening(record)
    for index, open in ipairs(openings) do
        if open == record then
            table.remove(openings, index)
            break
        end
    end
    local opens = 0
    for _, slotEntry in pairs(record.slots) do
        local after = SlotCount(slotEntry.bag, slotEntry.slot, record.itemID)
        slotEntry.after = after
        if after then
            opens = opens + math.min(slotEntry.clicks, math.max(0, slotEntry.before - after))
        end
    end
    record.opens = opens
    if opens > 0 and not record.ambiguous and record.moneyBefore and GetMoney then
        local gained = GetMoney() - record.moneyBefore
        if gained > 0 then
            record.copper = gained
        end
    end
    -- A burst finishes together: wait until its last record is done here.
    local burst = record.burst
    if burst then
        record.burstDone = true
        for _, member in ipairs(burst.records) do
            if not member.burstDone then
                return
            end
        end
        self:SplitBurst(burst)
        for _, member in ipairs(burst.records) do
            member.burst = nil
            member.burstReason = burst.reason
            self:CompleteOpening(member)
        end
        return
    end
    self:CompleteOpening(record)
end

-- Split a burst by expansion when every item can be placed (see header);
-- otherwise leave every record ambiguous.
function LootReader:SplitBurst(burst)
    local byExpansion = {}
    local moneyBefore = nil
    for _, record in ipairs(burst.records) do
        if #record.windows > 0 or #(record.currencies or {}) > 0 then
            burst.reason = "not split: a loot window or currency was mixed in"
            return false
        end
        local expansion = ItemExpansion(record.itemID)
        if not expansion or byExpansion[expansion] then
            burst.reason = "not split: containers share an expansion (or it is unknown)"
            return false
        end
        byExpansion[expansion] = record
        if record.moneyBefore and (not moneyBefore or record.moneyBefore < moneyBefore) then
            moneyBefore = record.moneyBefore
        end
    end
    if moneyBefore and GetMoney and GetMoney() > moneyBefore then
        burst.reason = "not split: gold arrived during the burst"
        return false
    end
    -- Every item once (the same pending can sit on several records).
    local pendings, seen = {}, {}
    for _, record in ipairs(burst.records) do
        for _, pending in ipairs(record.pendings or {}) do
            if not seen[pending] then
                seen[pending] = true
                pendings[#pendings + 1] = pending
            end
        end
    end
    local owners = {}
    for index, pending in ipairs(pendings) do
        local owner = pending.kind == "item" and byExpansion[ItemExpansion(pending.iid) or -1] or nil
        if not owner then
            burst.reason = "not split: an item matches none of the containers' expansions"
            return false
        end
        owners[index] = owner
    end
    for _, record in ipairs(burst.records) do
        record.pendings, record.lines = {}, {}
        record.ambiguous = nil
        record.split = true
    end
    for index, pending in ipairs(pendings) do
        local owner = owners[index]
        owner.pendings[#owner.pendings + 1] = pending
        owner.lines[#owner.lines + 1] = { itemID = pending.iid, link = pending.link, quantity = pending.qty }
    end
    return true
end

function LootReader:CompleteOpening(record)
    local opens = record.opens or 0
    record.lastAt, record.firstAt, record.token, record.moneyBefore, record.burstDone = nil, nil, nil, nil, nil
    if opens == 0 then
        record.reason = "not opened: the container never left its slot"
    elseif record.ambiguous then
        record.reason = "ambiguous: another container was opened at the same time"
            .. (record.burstReason and (" (" .. record.burstReason .. ")") or "")
    elseif record.split and #record.lines > 0 then
        record.reason = "split by expansion from a burst"
    elseif #record.lines == 0 and #record.windows == 0 and #(record.currencies or {}) == 0 then
        record.reason = "no contents seen"
    end
    record.burstReason = nil
    WriteOpening(record)
    record.pendings = nil
    if opens > 0 then
        self:SendMessage("MCG_CONTAINER_OPENING", record)
    end
    local log = LogDB()
    if log and log.enabled then
        Keep(log.openings, record)
    end
end

-- ---------------------------------------------------------------------------
-- Consumed (Going Out, 2026-11-05): an item used up (food, drink, potion,
-- lure, knowledge item) is written as "used" out, 1 per use, so sessions take
-- its value off (Brian: consumables used in a session are part of the
-- activity). Confirmed in-game 2026-11-05 (/mcgd events, a drink and a food):
-- UNIT_SPELLCAST_SUCCEEDED (player, spell S), then SPELL_UPDATE_COOLDOWN with
-- arg1 = S and arg5 = the item's ID, and ITEM_COUNT_CHANGED for that item,
-- all within half a second (either order). All three within USE_SECONDS =
-- one used. A hearthstone gets a cooldown but no count change: not used.
-- Skipped: containers being opened (counted by their opening), crafts (mats
-- written by the craft capture).
-- Theoretical: one use = 1 item; the same signals on Forever.
-- ---------------------------------------------------------------------------
local USE_SECONDS = 2
local spellSucceeded = {}   -- spellID -> GetTime()
local useCooldown = {}      -- itemID -> { at, spellID }
local countChanged = {}     -- itemID -> GetTime()

local function TryConsume(itemID)
    local cooldown, changedAt = useCooldown[itemID], countChanged[itemID]
    local now = GetTime()
    if not cooldown or not changedAt or (now - cooldown.at) > USE_SECONDS or (now - changedAt) > USE_SECONDS then
        return
    end
    useCooldown[itemID], countChanged[itemID] = nil, nil
    if lastCraftAt and (now - lastCraftAt) <= CRAFT_CONTEXT_SECONDS then
        return
    end
    if lastUse and lastUse.itemID == itemID and lastUse.hasLoot and (now - (lastUse.at or 0)) <= USE_SECONDS then
        return
    end
    local link
    if C_Item and type(C_Item.GetItemInfo) == "function" then
        local ok, _, itemLink = pcall(C_Item.GetItemInfo, itemID)
        link = ok and type(itemLink) == "string" and itemLink or nil
    end
    SafeWrite({ dir = "out", cat = "used", src = cooldown.spellID, kind = "item", iid = itemID, link = link, qty = 1 })
end

local function OnSpellCooldown(...)
    local spellID = tonumber((Plain((select(1, ...)))))
    local itemID = tonumber((Plain((select(5, ...)))))
    if not spellID or not itemID then
        return
    end
    local castAt = spellSucceeded[spellID]
    if not castAt or (GetTime() - castAt) > USE_SECONDS then
        return
    end
    useCooldown[itemID] = { at = GetTime(), spellID = spellID }
    TryConsume(itemID)
end

local function OnItemCountChanged(itemID)
    itemID = tonumber((Plain(itemID)))
    if not itemID then
        return
    end
    countChanged[itemID] = GetTime()
    TryConsume(itemID)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "LOOT_READY" or event == "LOOT_OPENED" then
        if not current then
            current = OpenWindow(event)
        end
        if not current.locked then
            ReadSlots(current)
        end
    elseif event == "LOOT_SLOT_CLEARED" then
        if current then
            current.locked = true
        end
    elseif event == "LOOT_CLOSED" then
        CloseWindow()
    elseif event == "CHAT_MSG_LOOT" then
        OnLootLine((...))
    elseif event == "CURRENCY_DISPLAY_UPDATE" then
        OnCurrencyUpdate(...)
    elseif event == "CHAT_MSG_CURRENCY" then
        OnCurrencyLine((...))
    elseif WINDOW_EVENTS[event] then
        SetWindow(WINDOW_EVENTS[event][1], WINDOW_EVENTS[event][2])
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local window = INTERACTION_WINDOWS[tonumber((...))]
        if window then
            SetWindow(window, event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
        end
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        OnSpellCooldown(...)
    elseif event == "ITEM_COUNT_CHANGED" then
        OnItemCountChanged((...))
    elseif event == "QUEST_TURNED_IN" then
        lastQuestAt = GetTime()
    elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        lastCraftAt = GetTime()
    elseif event == "UNIT_SPELLCAST_SENT" then
        local unit, target, _, spellID = ...
        if unit == "player" and spellID then
            lastSent = { spellID = spellID, at = GetTime(), target = (Plain(target)) }
        end
    elseif event == "UNIT_SPELLCAST_START" then
        local unit, _, spellID = ...
        if unit == "player" and spellID then
            castStart = { spellID = spellID, at = GetTime() }
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and spellID then
            local now = GetTime()
            local cast = { spellID = spellID, at = now }
            if castStart and castStart.spellID == spellID and (now - castStart.at) <= MAX_CAST_SECONDS then
                cast.castSeconds = now - castStart.at
            end
            if lastSent and lastSent.spellID == spellID and (now - lastSent.at) <= MAX_CAST_SECONDS then
                cast.target = lastSent.target
            end
            castStart, lastSent = nil, nil
            lastCast = cast
            spellSucceeded[spellID] = now
        end
    end
end)

function LootReader:OnEnable()
    eventFrame:RegisterEvent("LOOT_READY")
    eventFrame:RegisterEvent("LOOT_OPENED")
    eventFrame:RegisterEvent("LOOT_SLOT_CLEARED")
    eventFrame:RegisterEvent("LOOT_CLOSED")
    eventFrame:RegisterEvent("CHAT_MSG_LOOT")
    pcall(eventFrame.RegisterEvent, eventFrame, "CURRENCY_DISPLAY_UPDATE")
    pcall(eventFrame.RegisterEvent, eventFrame, "CHAT_MSG_CURRENCY")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
    eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    if not self.hooked and hooksecurefunc and C_Container and type(C_Container.UseContainerItem) == "function" then
        hooksecurefunc(C_Container, "UseContainerItem", OnUseContainerItem)
        self.hooked = true
    end
    -- Item Ledger context (2026-10-30). Optional events in pcall: one a
    -- flavor doesn't have must not stop the rest.
    for event in pairs(WINDOW_EVENTS) do
        pcall(eventFrame.RegisterEvent, eventFrame, event)
    end
    pcall(eventFrame.RegisterEvent, eventFrame, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
    pcall(eventFrame.RegisterEvent, eventFrame, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
    pcall(eventFrame.RegisterEvent, eventFrame, "QUEST_TURNED_IN")
    pcall(eventFrame.RegisterEvent, eventFrame, "TRADE_SKILL_ITEM_CRAFTED_RESULT")
    pcall(eventFrame.RegisterEvent, eventFrame, "SPELL_UPDATE_COOLDOWN")
    pcall(eventFrame.RegisterEvent, eventFrame, "ITEM_COUNT_CHANGED")
    if not self.mailHooked and hooksecurefunc then
        if type(_G.TakeInboxItem) == "function" then
            hooksecurefunc("TakeInboxItem", OnMailTake)
        end
        if type(_G.AutoLootMailItem) == "function" then
            hooksecurefunc("AutoLootMailItem", OnMailTake)
        end
        self.mailHooked = true
    end
end

-- ---------------------------------------------------------------------------
-- Diagnostic: /mcg lootreader [on|off|show|clear]
-- ---------------------------------------------------------------------------

local function SpellName(spellID)
    if C_Spell and type(C_Spell.GetSpellName) == "function" then
        local ok, name = pcall(C_Spell.GetSpellName, spellID)
        if ok and type(name) == "string" then
            return name
        end
    end
    return "?"
end

local function TypeList(set)
    local list = {}
    for name in pairs(set or {}) do
        list[#list + 1] = name
    end
    table.sort(list)
    return #list > 0 and table.concat(list, ",") or "none"
end

function LootReader:BuildReport()
    local log = LogDB() or { windows = {}, lines = {} }
    local lines = {
        string.format("Loot reader capture: %s  (windows: %d, chat lines: %d, openings: %d, currency changes: %d, last %d of each)",
            log.enabled and "ON" or "OFF", #log.windows, #log.lines, #(log.openings or {}), #(log.currency or {}), LOG_LIMIT),
        "",
        "=== Windows (newest first) ===",
    }
    for index = #log.windows, 1, -1 do
        local w = log.windows[index]
        lines[#lines + 1] = string.format("#%s  %s  context=%s  open=%.2fs  reads=%s  locked=%s  fishing=%s  merchant=%s%s",
            tostring(w.id), date("%m-%d %H:%M:%S", w.openedAt or 0), tostring(w.context), tonumber(w.seconds) or 0,
            tostring(w.reads), tostring(w.locked and true or false), tostring(w.fishing), tostring(w.merchantOpen),
            w.secretSeen and "  SECRET VALUE SEEN" or "")
        if w.cast then
            lines[#lines + 1] = string.format("    cast: %s (%s)  %.2fs before  castTime=%s  target=%s",
                tostring(w.cast.spellID), SpellName(w.cast.spellID), tonumber(w.cast.secondsBefore) or 0,
                w.cast.castSeconds and string.format("%.2fs", w.cast.castSeconds) or "-", tostring(w.cast.target))
        else
            lines[#lines + 1] = "    cast: none within 3s"
        end
        if w.containerUse then
            lines[#lines + 1] = string.format("    container use: %s (%s)  %.2fs before",
                tostring(w.containerUse.link), tostring(w.containerUse.itemID), tonumber(w.containerUse.secondsBefore) or 0)
        end
        lines[#lines + 1] = string.format("    source types: %s%s", TypeList(w.sourceTypes),
            w.objectID and ("  objectID=" .. tostring(w.objectID)) or "")
        for _, s in ipairs(w.slots or {}) do
            lines[#lines + 1] = string.format("    slot %d  type=%s  %s  qty=%s  quality=%s%s",
                s.slot or 0, tostring(s.slotType), tostring(s.link or s.name), tostring(s.quantity), tostring(s.quality),
                s.currencyID and ("  currencyID=" .. s.currencyID) or "")
            local base = 0
            for _, src in ipairs(s.sources or {}) do
                base = base + (tonumber(src.qty) or 0)
                lines[#lines + 1] = string.format("        source %s  id=%s  qty=%s  %s%s",
                    tostring(src.type), tostring(src.id), tostring(src.qty), tostring(src.guid),
                    src.link and ("  " .. src.link) or "")
            end
            if #(s.sources or {}) > 0 and tonumber(s.quantity) and tonumber(s.quantity) ~= base then
                lines[#lines + 1] = string.format("        received %d vs sources %d (bonus %d)",
                    tonumber(s.quantity), base, tonumber(s.quantity) - base)
            end
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== Chat lines (newest first) ==="
    for index = #log.lines, 1, -1 do
        local l = log.lines[index]
        lines[#lines + 1] = string.format("  %s  %-8s  %s x%s%s%s", date("%H:%M:%S", l.at or 0), tostring(l.kind),
            tostring(l.link), tostring(l.quantity), l.windowOpen and "  (loot window open)" or "",
            l.ctx and ("  ledger=" .. l.ctx) or "")
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== Container openings (newest first) ==="
    for index = #(log.openings or {}), 1, -1 do
        local o = log.openings[index]
        lines[#lines + 1] = string.format("  %s  %s (%s)  opened=%s  clicks=%s%s%s%s", date("%H:%M:%S", o.at or 0),
            tostring(o.link), tostring(o.itemID), tostring(o.opens), tostring(o.clicks),
            o.copper and string.format("  gold=%dg%02ds%02dc", math.floor(o.copper / 10000),
                math.floor(o.copper / 100) % 100, o.copper % 100) or "",
            o.ambiguous and "  AMBIGUOUS" or "", o.reason and ("  [" .. o.reason .. "]") or "")
        for _, slotEntry in pairs(o.slots or {}) do
            lines[#lines + 1] = string.format("      bag %s slot %s: count %s -> %s, clicks %s", tostring(slotEntry.bag),
                tostring(slotEntry.slot), tostring(slotEntry.before), tostring(slotEntry.after), tostring(slotEntry.clicks))
        end
        for _, l in ipairs(o.lines or {}) do
            lines[#lines + 1] = string.format("      line  %s x%s  %.2fs after click", tostring(l.link),
                tostring(l.quantity), tonumber(l.gap) or 0)
        end
        for _, c in ipairs(o.currencies or {}) do
            lines[#lines + 1] = string.format("      currency  %s (%s) +%s  gainSource=%s  %.2fs after click",
                tostring(c.name), tostring(c.currencyID), tostring(c.quantity), tostring(c.gainSource),
                tonumber(c.gap) or 0)
        end
        for _, w in ipairs(o.windows or {}) do
            lines[#lines + 1] = string.format("      window #%s (%d slots)", tostring(w.id), #(w.slots or {}))
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== Currency changes (newest first) ==="
    for index = #(log.currency or {}), 1, -1 do
        local c = log.currency[index]
        lines[#lines + 1] = string.format("  %s  %s (%s)  %s%d  total=%s  gainSource=%s  lostSource=%s  from=%s%s",
            date("%H:%M:%S", c.at or 0), tostring(c.name), tostring(c.currencyID), (c.change or 0) > 0 and "+" or "",
            c.change or 0, tostring(c.total), tostring(c.gainSource), tostring(c.lostSource), tostring(c.changeFrom),
            c.ctx and ("  ledger=" .. c.ctx) or "")
        lines[#lines + 1] = "      raw: " .. tostring(c.raw)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== Currency chat lines (newest first, for comparison) ==="
    for index = #(log.currencyLines or {}), 1, -1 do
        local l = log.currencyLines[index]
        lines[#lines + 1] = string.format("  %s  %s", date("%H:%M:%S", l.at or 0), tostring(l.text))
    end
    return table.concat(lines, "\n")
end

local diagnostics = PocketCFO.Diagnostics
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("lootreader", {
        name = "lootreader",
        description = "Loot reader capture: on, off, show (default), clear.",
        usage = "/mcg lootreader [on|off|show|clear]",
        category = "General",
    }, function(rest)
        local arg = strtrim(tostring(rest or "")):lower()
        local log = LogDB()
        if not log then
            PocketCFO:Print("lootreader: saved data not ready yet.")
            return
        end
        if arg == "on" then
            log.enabled = true
            PocketCFO:Print("Loot reader capture ON. /mcg lootreader to view.")
        elseif arg == "off" then
            log.enabled = false
            PocketCFO:Print("Loot reader capture OFF. Records kept.")
        elseif arg == "clear" then
            log.windows, log.lines, log.currency, log.currencyLines, log.openings = {}, {}, {}, {}, {}
            PocketCFO:Print("Loot reader records cleared.")
        else
            diagnostics:ShowDump("Loot Reader", LootReader:BuildReport())
        end
    end)
end
