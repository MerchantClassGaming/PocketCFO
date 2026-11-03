-- PocketCFO_PnL/UI/GoldPerHourWindow.lua
-- The tracker window (2026-10-31; was the full Gold per Hour window, whose
-- ranking moved to the Gold window's Gold per Hour tab): a small window with
-- just what this character is doing right now.
--   Line 1: what is tracked (session or run) or the last one, PAUSED when paused.
--   Line 2: time, value, gold per hour. Updates every second while open.
--   Buttons: Stop (Ctrl-click throws a session away), Pause / Resume (core
--   ActivityControl), and an open button for the Gold window.
-- Opened from the Gold per Hour tab's Tracker button or the minimap button
-- (right-click), and by itself when tracking starts if "Show the tracker
-- when tracking starts" is on (core ActivityControl). When tracking ends it
-- keeps showing the result until closed, unless "Close the tracker when
-- tracking ends" is on. Shown / position are remembered (core ActivityRuns
-- ui state) and it comes back after /reload if it was left open.
-- Data: PocketCFO_PnL.GoldPerHourReport:BuildNow.

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL

local GoldPerHourWindow = PocketCFO_PnL:NewModule("GoldPerHourWindow", "AceEvent-3.0")

local WIDTH = 270
local INNER = WIDTH - 24
local UPDATE_SECONDS = 1

local function Report()
    return PocketCFO_PnL.GoldPerHourReport
end

local function Runs()
    return PocketCFO:GetModule("ActivityRuns", true)
end

local function Control()
    return PocketCFO.ActivityControl
end

local function GoldWindow()
    return PocketCFO_PnL:GetModule("GoldWindow", true)
end

local function UIState()
    local runs = Runs()
    return runs and runs:GetUIState() or {}
end

local function CreateText(parent, template, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    text:SetWordWrap(false)
    return text
end

-- ---------------------------------------------------------------------------
-- Shared clock (2026-10-31): one timer redraws both the tracker and the Gold
-- per Hour tab's top lines on the same tick, so their times always match
-- (two separate timers drifted a second apart). Each draw returns at once
-- when its window isn't shown.
-- ---------------------------------------------------------------------------

local clock = CreateFrame("Frame")
clock.elapsed = 0
clock:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.elapsed < UPDATE_SECONDS then
        return
    end
    self.elapsed = 0
    GoldPerHourWindow:Draw()
    local window = PocketCFO_PnL:GetModule("GoldWindow", true)
    if window and window.DrawGoldPerHourNow then
        window:DrawGoldPerHourNow()
    end
end)

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

function GoldPerHourWindow:Build()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "MCGCFOGoldPerHourWindow", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, 96)
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.07, 0.92)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
            local ui = UIState()
            ui.left, ui.top = left, top
        end
    end)

    local ui = UIState()
    if ui.left and ui.top then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", ui.left, ui.top)
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -140)
    end

    local title = CreateText(frame, "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -10)
    title:SetText("Gold per Hour")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function()
        GoldPerHourWindow:Hide()
    end)

    -- Open the Gold window on the Gold per Hour tab.
    frame.open = CreateFrame("Button", nil, frame)
    frame.open:SetSize(18, 18)
    frame.open:SetPoint("RIGHT", close, "LEFT", -2, 0)
    frame.open:SetNormalTexture("Interface\\Icons\\INV_Misc_Coin_01")
    frame.open:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    frame.open:SetScript("OnClick", function()
        local window = GoldWindow()
        if window then
            window:Toggle("gph")
        end
    end)
    frame.open:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Gold window")
        GameTooltip:AddLine("See every activity ranked by gold per hour.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame.open:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    frame.nowTitle = CreateText(frame, "GameFontNormalSmall")
    frame.nowTitle:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -30)
    frame.nowTitle:SetWidth(INNER)
    frame.nowTime = CreateText(frame, "GameFontHighlightSmall")
    frame.nowTime:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -46)
    frame.nowTime:SetWidth(60)
    frame.nowValue = CreateText(frame, "GameFontHighlightSmall", "RIGHT")
    frame.nowValue:SetPoint("TOPLEFT", frame, "TOPLEFT", 12 + 60, -46)
    frame.nowValue:SetWidth(80)
    frame.nowRate = CreateText(frame, "GameFontHighlight", "RIGHT")
    frame.nowRate:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -45)
    frame.nowRate:SetWidth(INNER - 144)
    frame.nowEmpty = CreateText(frame, "GameFontDisableSmall")
    frame.nowEmpty:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -46)
    frame.nowEmpty:SetWidth(INNER)
    frame.nowEmpty:SetText("Gather something or start a session.")

    local function Button(width, text, onClick, tooltipFn)
        local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
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

    frame.stopButton = Button(64, "Stop", function()
        local window = GoldWindow()
        if window and window.StopTracking then
            window:StopTracking()
        end
    end, function(tooltip)
        tooltip:AddLine("Stop")
        tooltip:AddLine("End what you are tracking now and save it. The next thing you gather starts a new run.", 1, 1, 1, true)
        local sessions = PocketCFO:GetModule("ActivitySessions", true)
        if sessions and sessions:GetCurrent() then
            tooltip:AddLine("Ctrl-click to throw this session away without saving.", 1, 1, 1, true)
        end
    end)
    frame.stopButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -64)

    frame.pauseButton = Button(72, "Pause", function()
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
    frame.pauseButton:SetPoint("LEFT", frame.stopButton, "RIGHT", 4, 0)

    frame:Hide()
    self.frame = frame

    self:RegisterMessage("MCG_ACTIVITY_RUNS_UPDATED", "Draw")
    self:RegisterMessage("MCG_SESSIONS_UPDATED", "Draw")
    self:RegisterMessage("MCG_ACTIVITY_PAUSE_CHANGED", "Draw")
    self:RegisterMessage("MCG_ACTIVITY_RUNS_FILED", "OnFiled")
    self:RegisterMessage("MCG_SESSIONS_FILED", "OnFiled")
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

function GoldPerHourWindow:Draw()
    local frame = self.frame
    if not frame or not frame:IsShown() then
        return
    end
    local control = Control()
    local tracking = control and control:IsTracking() or false
    local paused = control and control:IsPaused() or false
    frame.stopButton:SetEnabled(tracking)
    frame.pauseButton:SetEnabled(tracking)
    frame.pauseButton:SetText(paused and "Resume" or "Pause")

    local window = GoldWindow()
    local formatMoney = window and window.FormatGoldPerHourMoney
    local formatRate = window and window.FormatGoldPerHourRate
    local now = Report():BuildNow()
    if not now or not formatMoney then
        frame.nowTitle:SetText("Nothing tracked yet")
        frame.nowTime:Hide()
        frame.nowValue:Hide()
        frame.nowRate:Hide()
        frame.nowEmpty:Show()
        return
    end
    frame.nowEmpty:Hide()
    frame.nowTitle:SetText(now.title .. (now.paused and "  |cffff9900PAUSED|r" or ""))
    frame.nowTime:SetText(Report():FormatDuration(now.seconds))
    frame.nowValue:SetText(formatMoney(now.copper))
    frame.nowRate:SetText(formatRate(now.perHour))
    frame.nowTime:Show()
    frame.nowValue:Show()
    frame.nowRate:Show()
end

-- A run or session was filed: close if tracking ended and the setting says so.
function GoldPerHourWindow:OnFiled()
    local control = Control()
    if self:IsShown() and control and control:GetSetting("trackerAutoClose") and not control:IsTracking() then
        self:Hide()
        return
    end
    self:Draw()
end

-- ---------------------------------------------------------------------------
-- Show / hide
-- ---------------------------------------------------------------------------

function GoldPerHourWindow:IsShown()
    return self.frame ~= nil and self.frame:IsShown()
end

function GoldPerHourWindow:Show()
    self:Build()
    UIState().shown = true
    self.frame:Show()
    self:Draw()
end

function GoldPerHourWindow:Hide()
    UIState().shown = nil
    if self.frame then
        self.frame:Hide()
    end
end

function GoldPerHourWindow:Toggle()
    if self:IsShown() then
        self:Hide()
    else
        self:Show()
    end
end
