-- PocketCFO_PnL/UI/GoldPerHourTab.lua
-- Gold per Hour tab of the Gold window (2026-10-31; moved here from its own
-- window, which is now the small tracker window, UI/GoldPerHourWindow.lua).
--   Period buttons (Today / 7 Days / 30 Days / All) and the toon filter,
--     shared with the Income / Spending / Orders tabs.
--   Now / Last: this character's session or run in progress (or the last one):
--     time, value, gold per hour. Updates every second while the tab is open.
--   Buttons: Start session (asks for a name, pre-filled with the last one),
--     Stop (ends what is tracked now; Ctrl-click throws a session away),
--     Pause / Resume, Tracker (shows / hides the tracker window). Stop /
--     Pause / Resume go through core ActivityControl.
--   Best use of your time: activities ranked by gold per hour: activity,
--     character, runs / time, rate. Click a row for its detail:
--       Grand Beasts: loot parts and lures used;
--       gathering: By profession (only for a character with 2+ gathering
--         professions; one with nothing gathered shows "none"), By zone;
--       runs (gathering, fishing, Grand Beasts) and custom sessions: the 10
--         most recent, each with its date and start time, its own time and
--         its own gold per hour;
--       sessions: Items / Gold; Dungeons / Raids / Delves: one line per instance.
--     Right-click a custom session row to rename it; Ctrl-click a session row
--     (or an instance) to delete its saved sessions (both confirm first).
--   Which automatic activities show is set on the Pocket CFO settings page.
-- Data: PocketCFO_PnL.GoldPerHourReport.

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL
local GoldWindow = PocketCFO_PnL:GetModule("GoldWindow")

local ROW_HEIGHT = 16
local COL_LABEL = 130
local COL_NAME = 90
local COL_COUNT = 92

local Y_NOW_TITLE = -28
local Y_NOW_VALUES = -44
local Y_BUTTONS = -62
local Y_RANK = -92
local Y_RANK_ROWS = -32   -- inside the rank pane

local function UI()
    return GoldWindow.ui
end

local function Report()
    return PocketCFO_PnL.GoldPerHourReport
end

local function Sessions()
    return PocketCFO:GetModule("ActivitySessions", true)
end

local function Control()
    return PocketCFO.ActivityControl
end

local function Tracker()
    return PocketCFO_PnL:GetModule("GoldPerHourWindow", true)
end

-- Losses show in red with a "-" (2026-10-28). Two biggest coins (2026-11-05).
local function FormatMoney(copper)
    copper = _G.PocketCFO:RoundMoney(copper)
    local negative = copper < 0
    if negative then
        copper = -copper
    end
    local text
    if GetMoneyString then
        text = GetMoneyString(copper, true)
    else
        text = _G.PocketCFO:FormatMoney(copper)
    end
    if negative then
        return "|cffff6060-" .. text .. "|r"
    end
    return text
end

local function FormatRate(copper)
    if not copper then
        return "|cff888888-|r"
    end
    if copper < 0 then
        return "|cffff6060-" .. FormatMoney(-copper) .. "/hr|r"
    end
    return FormatMoney(copper) .. "/hr"
end

GoldWindow.FormatGoldPerHourMoney = FormatMoney
GoldWindow.FormatGoldPerHourRate = FormatRate

-- ---------------------------------------------------------------------------
-- Popups: start, rename, delete
-- ---------------------------------------------------------------------------

local START_POPUP = "MCGCFO_START_SESSION"
local RENAME_POPUP = "MCGCFO_RENAME_SESSION"

local function PopupEditBox(popup)
    return (popup.GetEditBox and popup:GetEditBox()) or popup.editBox or popup.EditBox
end

local function StartFromPopup(popup)
    local editBox = PopupEditBox(popup)
    local sessions = Sessions()
    if sessions and editBox then
        sessions:Start(editBox:GetText())
    end
end

if StaticPopupDialogs then
    StaticPopupDialogs[START_POPUP] = {
        text = "Name this session",
        button1 = "Start",
        button2 = CANCEL or "Cancel",
        hasEditBox = true,
        maxLetters = 40,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        OnShow = function(self)
            local editBox = PopupEditBox(self)
            local sessions = Sessions()
            local recent = sessions and sessions:GetRecentNames() or {}
            if editBox then
                editBox:SetText(recent[1] or "")
                editBox:HighlightText()
                editBox:SetFocus()
            end
        end,
        OnAccept = function(self)
            StartFromPopup(self)
        end,
        EditBoxOnEnterPressed = function(self)
            local popup = self:GetParent()
            StartFromPopup(popup)
            popup:Hide()
        end,
        EditBoxOnEscapePressed = function(self)
            self:GetParent():Hide()
        end,
    }

    StaticPopupDialogs[RENAME_POPUP] = {
        text = "Rename %s",
        button1 = "Rename",
        button2 = CANCEL or "Cancel",
        hasEditBox = true,
        maxLetters = 40,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        OnShow = function(self, data)
            local editBox = PopupEditBox(self)
            if editBox and data then
                editBox:SetText(data.oldName or "")
                editBox:HighlightText()
                editBox:SetFocus()
            end
        end,
        OnAccept = function(self, data)
            local editBox = PopupEditBox(self)
            if editBox and data then
                GoldWindow:FinishRename(data, editBox:GetText())
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local popup = self:GetParent()
            local data = popup and popup.data
            if data then
                GoldWindow:FinishRename(data, self:GetText())
            end
            popup:Hide()
        end,
        EditBoxOnEscapePressed = function(self)
            self:GetParent():Hide()
        end,
    }
end

-- Start session popup (also used by the tracker window).
function GoldWindow:PromptStartSession()
    if StaticPopup_Show then
        StaticPopup_Show(START_POPUP)
    end
end

-- Stop what is tracked now. Ctrl-click on a session throws it away (confirm).
function GoldWindow:StopTracking()
    local sessions = Sessions()
    local current = sessions and sessions:GetCurrent()
    if current and IsControlKeyDown() then
        StaticPopup_ShowGenericConfirmation(
            string.format("Throw away the %s session?\nIt won't be saved.", tostring(current.name)),
            function()
                sessions:Discard()
            end)
        return
    end
    local control = Control()
    if control then
        control:Stop()
    end
end

function GoldWindow:StartRename(guid, oldName)
    if guid and oldName and StaticPopup_Show then
        StaticPopup_Show(RENAME_POPUP, oldName, nil, { guid = guid, oldName = oldName })
    end
end

-- Renames all of that character's sessions with that name. An existing name
-- combines the two, after a confirmation.
function GoldWindow:FinishRename(data, newName)
    local sessions = Sessions()
    newName = tostring(newName or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not sessions or newName == "" or newName == data.oldName then
        return
    end
    local existing = sessions:CountSessions(data.guid, { name = newName })
    if existing > 0 then
        StaticPopup_ShowGenericConfirmation(
            string.format("Rename \"%s\" to \"%s\"?\nThis combines it with your %d \"%s\" %s.",
                data.oldName, newName, existing, newName, existing == 1 and "session" or "sessions"),
            function()
                sessions:RenameSessions(data.guid, data.oldName, newName)
            end)
    else
        sessions:RenameSessions(data.guid, data.oldName, newName)
    end
end

-- Ctrl-click a session row: delete that character's saved sessions with that
-- name, after a confirmation. A running session is not touched.
function GoldWindow:ConfirmDeleteSessions(guid, filter, label, characterText)
    local sessions = Sessions()
    if not sessions or not filter then
        return
    end
    local count = sessions:CountSessions(guid, filter)
    if count == 0 then
        PocketCFO:Print("Nothing saved to delete yet. Stop the session first to delete it.")
        return
    end
    StaticPopup_ShowGenericConfirmation(
        string.format("Delete all %d %s %s on %s?\nThis can't be undone.", count, tostring(label),
            count == 1 and "session" or "sessions", tostring(characterText or "?")),
        function()
            sessions:DeleteSessions(guid, filter)
        end)
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function CreateButton(parent, width, text, onClick, tooltipFn)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 20)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    button:SetMotionScriptsWhileDisabled(true)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        tooltipFn(GameTooltip)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    return button
end

function GoldWindow:BuildGoldPerHourPane()
    local pane = self.frame.gphPane
    local ui = UI()
    local inner = ui.INNER_WIDTH
    self:BuildFilterControls(pane, "MCGCFOGoldWindowGPHCharacterDropdown")
    self.gphExpanded = {}

    pane.nowTitle = ui.CreateText(pane, "GameFontNormalSmall")
    pane.nowTitle:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_NOW_TITLE)
    pane.nowTitle:SetWidth(inner)
    pane.nowTime = ui.CreateText(pane, "GameFontHighlightSmall")
    pane.nowTime:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_NOW_VALUES)
    pane.nowTime:SetWidth(70)
    pane.nowValue = ui.CreateText(pane, "GameFontHighlightSmall", "RIGHT")
    pane.nowValue:SetPoint("TOPLEFT", pane, "TOPLEFT", 70, Y_NOW_VALUES)
    pane.nowValue:SetWidth(100)
    pane.nowRate = ui.CreateText(pane, "GameFontHighlight", "RIGHT")
    pane.nowRate:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, Y_NOW_VALUES + 1)
    pane.nowRate:SetWidth(inner - 180)
    pane.nowEmpty = ui.CreateText(pane, "GameFontDisableSmall")
    pane.nowEmpty:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_NOW_VALUES)
    pane.nowEmpty:SetWidth(inner)
    pane.nowEmpty:SetText("Gather something or start a session and your gold per hour shows up here.")

    pane.startButton = CreateButton(pane, 100, "Start session", function()
        GoldWindow:PromptStartSession()
    end, function(tooltip)
        tooltip:AddLine("Start a session")
        tooltip:AddLine("Track the gold from anything you do until you stop it. Gathering, dungeons, raids and delves are tracked on their own.", 1, 1, 1, true)
    end)
    pane.startButton:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_BUTTONS)

    pane.stopButton = CreateButton(pane, 64, "Stop", function()
        GoldWindow:StopTracking()
    end, function(tooltip)
        tooltip:AddLine("Stop")
        tooltip:AddLine("End what you are tracking now and save it. The next thing you gather starts a new run.", 1, 1, 1, true)
        local sessions = Sessions()
        if sessions and sessions:GetCurrent() then
            tooltip:AddLine("Ctrl-click to throw this session away without saving.", 1, 1, 1, true)
        end
    end)
    pane.stopButton:SetPoint("LEFT", pane.startButton, "RIGHT", 4, 0)

    pane.pauseButton = CreateButton(pane, 72, "Pause", function()
        local control = Control()
        if control then
            control:TogglePause()
        end
    end, function(tooltip)
        local control = Control()
        if control and control:IsPaused() then
            tooltip:AddLine("Resume")
            tooltip:AddLine("Start the clock again.", 1, 1, 1, true)
        else
            tooltip:AddLine("Pause")
            tooltip:AddLine("Stop the clock. Nothing ends on its own while paused. If you loot something while paused, you'll be asked whether to resume.", 1, 1, 1, true)
        end
    end)
    pane.pauseButton:SetPoint("LEFT", pane.stopButton, "RIGHT", 4, 0)

    pane.trackerButton = CreateButton(pane, 92, "Tracker", function()
        local tracker = Tracker()
        if tracker then
            tracker:Toggle()
        end
    end, function(tooltip)
        tooltip:AddLine("Tracker")
        tooltip:AddLine("A small window with just what you're doing right now.", 1, 1, 1, true)
    end)
    pane.trackerButton:SetPoint("LEFT", pane.pauseButton, "RIGHT", 4, 0)

    -- Best use of your time
    pane.rank = CreateFrame("Frame", nil, pane)
    pane.rank:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, Y_RANK)
    pane.rank:SetSize(inner, 10)
    local rank = pane.rank
    rank.header = ui.CreateText(rank, "GameFontNormalSmall")
    rank.header:SetPoint("TOPLEFT", rank, "TOPLEFT", 0, 0)
    rank.header:SetText("Best use of your time")
    rank.caption = ui.CreateText(rank, "GameFontDisableSmall")
    rank.caption:SetPoint("TOPLEFT", rank, "TOPLEFT", 0, -14)
    rank.empty = ui.CreateText(rank, "GameFontDisableSmall")
    rank.empty:SetWordWrap(true)
    rank.empty:SetWidth(inner)
    rank.empty:SetText("Gather, fish or start a session on any character and it shows up here.")
    rank.rows = {}

    -- The top lines update every second from the tracker window's shared
    -- clock (UI/GoldPerHourWindow.lua), so the tab and the tracker always
    -- show the same time (2026-10-31: two separate timers were a second apart).

    -- Loot only redraws the top lines; the ranking is rebuilt when the tab
    -- opens, a row is expanded, or a run / session is filed (rebuilding it on
    -- every loot lagged each skin, 2026-10-26).
    self:RegisterMessage("MCG_ACTIVITY_RUNS_UPDATED", "OnGoldPerHourLive")
    self:RegisterMessage("MCG_SESSIONS_UPDATED", "OnGoldPerHourLive")
    self:RegisterMessage("MCG_ACTIVITY_PAUSE_CHANGED", "OnGoldPerHourLive")
    self:RegisterMessage("MCG_ACTIVITY_RUNS_FILED", "OnGoldPerHourFiled")
    self:RegisterMessage("MCG_SESSIONS_FILED", "OnGoldPerHourFiled")
end

function GoldWindow:OnGoldPerHourLive()
    self:DrawGoldPerHourNow()
end

function GoldWindow:OnGoldPerHourFiled()
    if self.frame and self.frame:IsShown() and self.activeTab == "gph" then
        self:Render()
    end
end

function GoldWindow:GetGoldPerHourRow(index)
    local rank = self.frame.gphPane.rank
    local row = rank.rows[index]
    if row then
        return row
    end
    local ui = UI()
    local inner = ui.INNER_WIDTH
    row = CreateFrame("Button", nil, rank)
    row:SetSize(inner, ROW_HEIGHT)
    row.highlight = row:CreateTexture(nil, "HIGHLIGHT")
    row.highlight:SetAllPoints()
    row.highlight:SetColorTexture(1, 1, 1, 0.06)
    row.label = ui.CreateText(row, "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
    row.label:SetWidth(COL_LABEL)
    row.name = ui.CreateText(row, "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row, "LEFT", COL_LABEL + 4, 0)
    row.name:SetWidth(COL_NAME)
    row.count = ui.CreateText(row, "GameFontDisableSmall", "RIGHT")
    row.count:SetPoint("LEFT", row, "LEFT", COL_LABEL + 4 + COL_NAME + 4, 0)
    row.count:SetWidth(COL_COUNT)
    row.amount = ui.CreateText(row, "GameFontHighlightSmall", "RIGHT")
    row.amount:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.amount:SetWidth(inner - COL_LABEL - COL_NAME - COL_COUNT - 12)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            if self.renameName then
                GoldWindow:StartRename(self.sessionGuid, self.renameName)
            end
            return
        end
        if self.sessionGuid and self.deleteFilter and IsControlKeyDown() then
            GoldWindow:ConfirmDeleteSessions(self.sessionGuid, self.deleteFilter, self.deleteLabel,
                self.sessionCharacter)
            return
        end
        if self.expandKey then
            GoldWindow.gphExpanded[self.expandKey] = not GoldWindow.gphExpanded[self.expandKey] or nil
            GoldWindow:Render()
        end
    end)
    row:SetScript("OnEnter", function(self)
        if self.tooltipTitle then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(tostring(self.tooltipTitle))
            GameTooltip:AddLine(tostring(self.tooltipText or ""), 1, 1, 1, true)
            GameTooltip:Show()
        end
    end)
    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    rank.rows[index] = row
    return row
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

-- Top lines and button states (every second while the tab is open).
function GoldWindow:DrawGoldPerHourNow()
    if not self.frame or not self.frame:IsShown() or self.activeTab ~= "gph" then
        return
    end
    local pane = self.frame.gphPane
    local control = Control()
    local sessions = Sessions()
    local tracking = control and control:IsTracking() or false
    local paused = control and control:IsPaused() or false
    pane.startButton:SetEnabled(not (sessions and sessions:GetCurrent()))
    pane.stopButton:SetEnabled(tracking)
    pane.pauseButton:SetEnabled(tracking)
    pane.pauseButton:SetText(paused and "Resume" or "Pause")
    local tracker = Tracker()
    pane.trackerButton:SetText((tracker and tracker:IsShown()) and "Hide tracker" or "Tracker")

    local now = Report():BuildNow()
    if not now then
        pane.nowTitle:SetText("Nothing tracked on this character yet")
        pane.nowTime:Hide()
        pane.nowValue:Hide()
        pane.nowRate:Hide()
        pane.nowEmpty:Show()
        return
    end
    pane.nowEmpty:Hide()
    pane.nowTitle:SetText(now.title .. (now.paused and "  |cffff9900PAUSED|r" or ""))
    pane.nowTime:SetText(Report():FormatDuration(now.seconds))
    pane.nowValue:SetText(FormatMoney(now.copper))
    pane.nowRate:SetText(FormatRate(now.perHour))
    pane.nowTime:Show()
    pane.nowValue:Show()
    pane.nowRate:Show()
end

-- Items / Gold detail lines for a session row or instance (2026-10-27).
local function DetailAmount(detail)
    if not detail.perHour then
        return FormatRate(nil)
    elseif detail.copper < 0 then
        return "|cffff6060-" .. FormatMoney(-detail.perHour) .. "/hr|r"
    end
    return FormatRate(detail.perHour)
end

local function AddSessionDetails(lines, source, indent)
    local sections = { { title = "Items", list = source.items or {} }, { title = "Gold", list = source.gold or {} } }
    for _, section in ipairs(sections) do
        if #section.list > 0 then
            lines[#lines + 1] = { label = indent .. "|cff888888" .. section.title .. "|r", count = "", amount = "" }
            for _, detail in ipairs(section.list) do
                lines[#lines + 1] = { label = indent .. "  |cffbbbbbb" .. detail.label .. "|r", count = "",
                    amount = DetailAmount(detail) }
            end
        end
    end
    if (source.keptUnpriced or 0) > 0 then
        lines[#lines + 1] = { label = string.format("%s|cff888888%d items with no price yet|r", indent, source.keptUnpriced),
            count = "", amount = "" }
    end
end

-- The most recent runs / sessions of a row, one line each (2026-10-31).
local function AddRecent(lines, row, indent, report)
    if not row.recent or #row.recent == 0 then
        return
    end
    local title = row.isSession and "Recent sessions" or "Recent runs"
    lines[#lines + 1] = { label = indent .. "|cff888888" .. title .. "|r", count = "", amount = "" }
    for _, recent in ipairs(row.recent) do
        local label = recent.label .. (recent.active and " |cff33ff33(now)|r" or "")
        lines[#lines + 1] = {
            label = indent .. "  |cffbbbbbb" .. label .. "|r",
            count = report:FormatHours(recent.seconds),
            amount = recent.costUnpriced and "|cff888888no lure price|r" or FormatRate(recent.perHour),
        }
    end
end

function GoldWindow:RenderGoldPerHourRanking()
    local rank = self.frame.gphPane.rank
    local report = Report()
    local model = report:BuildRanking(self.periodKey, self.characterGUID)
    rank.caption:SetText(report:GetPeriodCaption(self.periodKey))
    local expanded = self.gphExpanded

    -- Build every line before drawing anything.
    local lines = {}
    local function AddCharacter(row, ranked)
        local isOpen = expanded[row.key]
        local unit = row.isSession and (row.runs == 1 and "session" or "sessions")
            or (row.runs == 1 and "run" or "runs")
        local tooltipText
        if row.isManual then
            tooltipText = "A session you started. Click for details. Right-click to rename. Ctrl-click to delete."
        elseif row.isSession then
            tooltipText = string.format("Tracked automatically in %s. Click for details. Ctrl-click to delete.",
                string.lower(tostring(row.label)))
        elseif row.activity == "fishing" then
            tooltipText = "Tracked automatically while you fish. Click for details."
        elseif row.activity == "beasts" then
            tooltipText = "Tracked automatically from Grand Beasts lures and skins. Click for details."
        else
            tooltipText = "Tracked automatically while you gather. Click for details."
        end
        lines[#lines + 1] = {
            expandKey = row.key,
            tooltipTitle = row.label,
            tooltipText = tooltipText,
            renameName = row.isManual and row.label or nil,
            sessionGuid = row.isSession and row.guid or nil,
            deleteFilter = row.isSession and row.deleteFilter or nil,
            deleteLabel = row.isSession and row.deleteLabel or nil,
            sessionCharacter = row.isSession and row.name or nil,
            label = (isOpen and "- " or "+ ") .. row.label,
            name = row.name,
            count = ranked and string.format("%d %s, %s", row.runs, unit,
                report:FormatHours(row.seconds)) or (report:FormatHours(row.seconds) .. " so far"),
            amount = ranked and (row.costUnpriced and "|cff888888no lure price|r" or FormatRate(row.perHour))
                or string.format("|cff888888needs %d min|r", math.floor((model.minSeconds or report.MIN_RANK_SECONDS) / 60)),
        }
        if not isOpen then
            return
        end
        if row.isSession and row.children then
            -- Dungeons / Raids / Delves: one line per instance, each expandable.
            for _, child in ipairs(row.children) do
                local childOpen = expanded[child.key]
                lines[#lines + 1] = {
                    expandKey = child.key,
                    tooltipTitle = child.label,
                    tooltipText = "Tracked automatically. Click for details. Ctrl-click to delete.",
                    sessionGuid = row.guid,
                    deleteFilter = child.deleteFilter,
                    deleteLabel = child.deleteLabel,
                    sessionCharacter = row.name,
                    label = "    " .. (childOpen and "- " or "+ ") .. child.label,
                    count = string.format("%d %s, %s", child.runs, child.runs == 1 and "session" or "sessions",
                        report:FormatHours(child.seconds)),
                    amount = FormatRate(child.perHour),
                }
                if childOpen then
                    AddSessionDetails(lines, child, "        ")
                end
            end
            return
        elseif row.isSession then
            AddSessionDetails(lines, row, "    ")
            AddRecent(lines, row, "    ", report)
            return
        end
        local isBeasts = row.activity == "beasts"
        if isBeasts or row.showProfessions then
            lines[#lines + 1] = { label = isBeasts and "    |cff888888Loot|r" or "    |cff888888By profession|r",
                count = "", amount = "" }
            for _, part in ipairs(row.parts) do
                local none = part.copper == 0 and (part.loots or 0) == 0
                lines[#lines + 1] = {
                    label = "      |cffbbbbbb" .. part.label .. "|r",
                    count = string.format("%d%%", math.floor(part.share * 100 + 0.5)),
                    amount = none and "|cff888888none|r" or FormatRate(part.perHour),
                }
            end
        end
        if isBeasts then
            lines[#lines + 1] = {
                label = "      |cffbbbbbbLures used|r",
                count = "",
                amount = row.costUnpriced and "|cff888888open skinning book|r"
                    or (row.costPerHour and ("|cffff6060-" .. FormatMoney(row.costPerHour) .. "/hr|r") or FormatRate(nil)),
            }
        else
            lines[#lines + 1] = { label = "    |cff888888By zone|r", count = "", amount = "" }
            for _, zone in ipairs(row.zones) do
                lines[#lines + 1] = {
                    label = "      |cffbbbbbb" .. tostring(zone.label) .. "|r",
                    count = report:FormatHours(zone.seconds),
                    amount = FormatRate(zone.perHour),
                }
            end
        end
        AddRecent(lines, row, "    ", report)
    end
    for _, row in ipairs(model.ranked) do
        AddCharacter(row, true)
    end
    for _, row in ipairs(model.unranked) do
        AddCharacter(row, false)
    end

    local y = Y_RANK_ROWS
    if #lines == 0 then
        rank.empty:ClearAllPoints()
        rank.empty:SetPoint("TOPLEFT", rank, "TOPLEFT", 0, y)
        rank.empty:Show()
        y = y - 18
    else
        rank.empty:Hide()
    end
    for index, line in ipairs(lines) do
        local row = self:GetGoldPerHourRow(index)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", rank, "TOPLEFT", 0, y)
        row.expandKey = line.expandKey
        row.sessionGuid = line.sessionGuid
        row.tooltipTitle = line.tooltipTitle
        row.tooltipText = line.tooltipText
        row.renameName = line.renameName
        row.deleteFilter = line.deleteFilter
        row.deleteLabel = line.deleteLabel
        row.sessionCharacter = line.sessionCharacter
        row.label:SetText(line.label)
        -- Detail lines have no character column: their label uses its width.
        row.label:SetWidth(line.name and COL_LABEL or (COL_LABEL + 4 + COL_NAME))
        row.name:SetText(line.name or "")
        row.count:SetText(line.count or "")
        row.amount:SetText(line.amount or "")
        row:Show()
        y = y - ROW_HEIGHT
    end
    for index = #lines + 1, #rank.rows do
        rank.rows[index]:Hide()
    end
    local height = -y
    rank:SetHeight(height)
    return height
end

function GoldWindow:RenderGoldPerHour()
    local pane = self.frame.gphPane
    self:UpdateFilterControls(pane, PocketCFO_PnL.IncomeReport:GetPeriod(self.periodKey).key)
    self:DrawGoldPerHourNow()
    local rankHeight = self:RenderGoldPerHourRanking()
    local height = -Y_RANK + rankHeight + 4
    pane:SetHeight(height)
    return height
end
