-- PocketCFO/Infrastructure/MinimapButton.lua
-- Minimap button (LibDataBroker-1.1 + LibDBIcon-1.0, bundled in Libs).
--   Hover:       current run (or last run) for this character + today's gathering
--   Left-click:  toggle the Gold window on the last tab used (2026-10-31;
--                Gold per Hour the first time) (PocketCFO_PnL)
--   Right-click: toggle the tracker window (PocketCFO_PnL)
-- Button position / hidden state: PocketCFO_DB.global.minimap (LibDBIcon's table).
-- The existing Addon Compartment entry (BetaFeatures.lua) is unchanged.
-- Theoretical: LibDBIcon on WoW Forever (library supports Classic clients).

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local MinimapButton = PocketCFO:NewModule("MinimapButton")

local BUTTON_NAME = "PocketCFO"
-- Custom PocketCFO icon (2026-10-31): 64x64 32-bit TGA with transparency,
-- made from Brian's Icon.png (circle cut out, checkerboard background removed).
local ICON = "Interface\\AddOns\\PocketCFO\\Media\\PocketCFO_Icon.tga"

-- Two biggest coins (core PocketCFO:RoundMoney, 2026-11-05).
local function FormatMoney(copper)
    copper = PocketCFO:RoundMoney(copper)
    if GetMoneyString then
        return GetMoneyString(copper, true)
    end
    return PocketCFO:FormatMoney(copper)
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return string.format("%dh %02dm", hours, minutes)
    end
    return string.format("%dm", minutes)
end

-- Today's gathering value, all characters (value at loot time, unpriced
-- items at today's price).
local function TodayGathered()
    local capture = PocketCFO:GetModule("GatheringCapture", true)
    local runs = PocketCFO:GetModule("ActivityRuns", true)
    if not capture or not runs then
        return 0
    end
    local day = capture:GetDays()[date("%Y-%m-%d")] or {}
    local total = 0
    for _, professions in pairs(day) do
        for professionKey, row in pairs(professions) do
            -- Lumber: captured, not shown until it has a value.
            if not capture:IsHiddenProfession(professionKey) then
                total = total + (runs:ValueItems(row.items))
            end
        end
    end
    return total
end

local function AddRunLines(tooltip)
    local runs = PocketCFO:GetModule("ActivityRuns", true)
    if not runs then
        return
    end
    local run = runs:GetCurrentRun()
    local label = "Gathering now"
    if not run then
        run = runs:GetLastRun()
        label = "Last run"
    end
    if not run then
        tooltip:AddLine("Gather something and your gold per hour shows up here.", 0.7, 0.7, 0.7, true)
        return
    end
    local stats = runs:GetRunStats(run)
    local title = ((label == "Last run") and "Last run: " or "Now: ")
        .. runs:GetActivityLabel(UnitGUID("player"), stats.activity)
    if stats.activity ~= "beasts" and stats.zone and stats.zone ~= "?" then
        title = title .. " - " .. stats.zone
    end
    tooltip:AddLine(title, 1, 0.82, 0)
    tooltip:AddDoubleLine("Time", FormatDuration(stats.seconds), 0.8, 0.8, 0.8, 1, 1, 1)
    tooltip:AddDoubleLine("Value", FormatMoney(stats.copper), 0.8, 0.8, 0.8, 1, 1, 1)
    tooltip:AddDoubleLine("Per hour", stats.perHour and FormatMoney(stats.perHour) or "-", 0.8, 0.8, 0.8, 1, 1, 1)
end

function MinimapButton:OnEnable()
    local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
    local icon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not ldb or not icon or not PocketCFO.db then
        return
    end

    local dataObject = ldb:NewDataObject(BUTTON_NAME, {
        type = "launcher",
        text = "PocketCFO",
        icon = ICON,
        OnClick = function(_, mouseButton)
            if mouseButton == "RightButton" then
                local runs = PocketCFO:GetModule("ActivityRuns", true)
                if runs then
                    runs:ToggleWindow()
                end
            else
                local tracker = PocketCFO:GetModule("GoldTracker", true)
                if tracker then
                    tracker:OpenWindow()
                end
            end
        end,
        OnTooltipShow = function(tooltip)
            if not tooltip or not tooltip.AddLine then
                return
            end
            tooltip:AddLine("PocketCFO")
            AddRunLines(tooltip)
            tooltip:AddLine(" ")
            tooltip:AddDoubleLine("Gathered today (all toons)", FormatMoney(TodayGathered()),
                0.8, 0.8, 0.8, 1, 1, 1)
            tooltip:AddLine(" ")
            tooltip:AddLine("Left-click: Gold window", 0.6, 0.6, 0.6)
            tooltip:AddLine("Right-click: Tracker", 0.6, 0.6, 0.6)
        end,
    })
    if not dataObject then
        return
    end

    PocketCFO.db.global.minimap = PocketCFO.db.global.minimap or { hide = false }
    if not icon:IsRegistered(BUTTON_NAME) then
        icon:Register(BUTTON_NAME, dataObject, PocketCFO.db.global.minimap)
    end

    -- Fit our round icon to LibDBIcon's dark background circle (2026-11-05).
    -- LibDBIcon 55 sizes the icon smaller than the background (built for
    -- square Blizzard icons): Classic/Forever 17x17 at (7,-6) on a 20x20 at
    -- (7,-5) leaves a gap right and bottom; retail 18x18 centered on 24x24
    -- leaves an even ring. Match the background on each flavor.
    -- Library left unedited (shared lib; another addon may load a newer copy).
    local button = icon.GetMinimapButton and icon:GetMinimapButton(BUTTON_NAME)
    if button and button.icon then
        button.icon:ClearAllPoints()
        if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
            button.icon:SetSize(24, 24)
            button.icon:SetPoint("CENTER", button, "CENTER")
        else
            button.icon:SetSize(20, 20)
            -- -6 not -5: at -5 the border covered the icon's top edge (Brian, in-game).
            button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)
        end
    end
end
