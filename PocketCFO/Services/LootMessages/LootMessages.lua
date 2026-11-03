-- PocketCFO/Services/LootMessages/LootMessages.lua
-- Reads the game's own item receive chat lines (CHAT_MSG_LOOT) for the
-- player. One copy of the parser, shared by ContainerOutcomeService and
-- ActivitySessions (2026-10-27).
--
-- Patterns are built from the game's localized format strings, so this works
-- in any client language. Most specific ("x%d") forms are tried first.
--   kind "looted":   LOOT_ITEM_SELF / LOOT_ITEM_SELF_MULTIPLE
--                    ("You receive loot: [item]") - loot windows, roll wins,
--                    personal loot.
--   kind "received": LOOT_ITEM_PUSHED_SELF / LOOT_ITEM_PUSHED_SELF_MULTIPLE
--                    ("You receive item: [item]") - containers with no loot
--                    window (confirmed 2026-10-26), quest rewards, purchases.
-- Theoretical: on WoW Forever, items won on a group loot roll produce a
-- "looted" line.
--
-- Flavor: Both. No events, no state: callers register CHAT_MSG_LOOT themselves.

local PocketCFO = _G.PocketCFO

local LootMessages = {}
PocketCFO.LootMessages = LootMessages

local FORMATS = {
    { name = "LOOT_ITEM_PUSHED_SELF_MULTIPLE", kind = "received" },
    { name = "LOOT_ITEM_SELF_MULTIPLE",        kind = "looted" },
    { name = "LOOT_ITEM_PUSHED_SELF",          kind = "received" },
    { name = "LOOT_ITEM_SELF",                 kind = "looted" },
}

local function FormatToPattern(format)
    local pattern = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
    pattern = pattern:gsub("%%s", "(.+)"):gsub("%%d", "(%%d+)")
    return "^" .. pattern .. "$"
end

local patterns = nil
local function Patterns()
    if patterns then
        return patterns
    end
    patterns = {}
    for _, entry in ipairs(FORMATS) do
        local format = _G[entry.name]
        if type(format) == "string" then
            patterns[#patterns + 1] = { pattern = FormatToPattern(format), kind = entry.kind }
        end
    end
    return patterns
end

-- "You receive loot: [link]x2." -> itemID, link, quantity, kind
-- (nil when the line is not one of the player's receive lines).
function LootMessages:Parse(text)
    if type(text) ~= "string" then
        return nil
    end
    for _, entry in ipairs(Patterns()) do
        local link, quantity = text:match(entry.pattern)
        if link then
            local itemID = tonumber(link:match("item:(%d+)"))
            if itemID then
                return itemID, link, tonumber(quantity) or 1, entry.kind
            end
        end
    end
    return nil
end
