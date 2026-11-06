-- PocketCFO/Services/ActivityControl/ActivityControl.lua
-- Stop / Pause / Resume for what Gold per Hour is tracking right now, used by
-- the Gold per Hour tab and the tracker window (PocketCFO_PnL). Agreed with
-- Brian 2026-10-31.
--
-- The target is the character's session if one is running (custom or
-- dungeon / raid / delve), otherwise its gathering run (ActivityRuns).
-- Automatic runs keep recording under a session as before; Stop / Pause
-- act on the session then.
--   Stop:   files it now (Ctrl-click Stop on a session still throws it away,
--           in the UI). The next loot starts a new run / instance session.
--   Pause:  clock stops, nothing auto-ends (see ActivityRuns / ActivitySessions).
--   Resume: clock restarts.
-- While paused, the first thing that would count is held and the player is
-- asked once "Resume?" (Hold): Resume counts everything held; Stay paused
-- drops it and isn't asked again until the next pause. All automatic safety
-- ends stay in place (a pause over 30 minutes is filed where it was paused).
--
-- Tracker settings (PocketCFO_DB.global.settings.goldPerHour):
--   trackerAutoShow  - show the tracker window when tracking starts (default off)
--   trackerAutoClose - close the tracker window when tracking ends (default off;
--                      the tracker otherwise keeps the final result until closed)
-- Auto-show happens once per run / session, so closing the tracker mid-run
-- keeps it closed.
--
-- Logging off (2026-10-31): an intentional logout / exit ends this
-- character's session and gathering run, saved at that moment; a disconnect
-- doesn't (see ActivitySessions). Intent = Logout() or Quit() was called, or
-- the logout countdown started (PLAYER_CAMPING / PLAYER_QUITING); moving
-- cancels it (LOGOUT_CANCEL). PLAYER_LOGOUT then ends things only if the
-- intent is set, so /reload and disconnects are untouched.
-- Theoretical: a disconnect never calls Logout() / Quit(); Alt-F4 counts as a
-- disconnect (the 30-minute abandoned-session safety covers it).
--
-- "Still gathering?" (agreed with Brian 2026-11-05): when the gathering run
-- has gone GAP_CAP_SECONDS without loot (rule: ActivityRuns
-- NeedsStillGatheringPrompt), ask once per gap. Held while in combat, shown
-- as soon as combat ends. Only when no session is running (automatic
-- gathering runs only). Still gathering -> ActivityRuns:KeepGathering;
-- I'm done -> the run is filed ending at its last loot. Closed (no answer
-- needed) when loot comes in or the run ends on its own.
--
-- Messages: MCG_ACTIVITY_PAUSE_CHANGED (pause state changed).
-- Flavor: Both.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local ActivityControl = PocketCFO:NewModule("ActivityControl", "AceEvent-3.0")
PocketCFO.ActivityControl = ActivityControl

local POPUP = "MCGCFO_RESUME_PAUSED"
local STILL_POPUP = "MCGCFO_STILL_GATHERING"
local STILL_CHECK_SECONDS = 2

local pending = {}        -- { { kind = "run" | "session", fn } } held while paused (not saved)
local loggingOut = false  -- an intentional logout / exit is under way
local autoShownFor = nil  -- key of the run / session the tracker was auto-shown for
local stillAskedFor = nil -- "startedAt:lastLootAt" of the gap already asked about (not saved)

local function Runs()
    return PocketCFO:GetModule("ActivityRuns", true)
end

local function Sessions()
    return PocketCFO:GetModule("ActivitySessions", true)
end

local function PlayerGUID()
    return UnitGUID and UnitGUID("player") or nil
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local function SettingsTable()
    local globalDB = PocketCFO.db and PocketCFO.db.global
    if not globalDB then
        return {}
    end
    globalDB.settings = globalDB.settings or {}
    globalDB.settings.goldPerHour = globalDB.settings.goldPerHour or {}
    return globalDB.settings.goldPerHour
end

function ActivityControl:GetSetting(key)
    return SettingsTable()[key] == true
end

function ActivityControl:SetSetting(key, enabled)
    SettingsTable()[key] = enabled and true or nil
end

-- ---------------------------------------------------------------------------
-- Target
-- ---------------------------------------------------------------------------

-- "session", session | "run", run | nil
function ActivityControl:GetTarget()
    local sessions = Sessions()
    local session = sessions and sessions:GetCurrent()
    if session then
        return "session", session
    end
    local runs = Runs()
    local run = runs and runs:GetCurrentRun()
    if run then
        return "run", run
    end
    return nil
end

function ActivityControl:IsTracking()
    return (self:GetTarget()) ~= nil
end

function ActivityControl:IsPaused()
    local _, target = self:GetTarget()
    return target ~= nil and target.pausedAt ~= nil
end

-- Identity of the current run / session (for auto-show once per thing).
local function TargetKey(kind, target)
    if not target then
        return nil
    end
    return tostring(kind) .. ":" .. tostring(target.startedAt or "?")
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function ActivityControl:Stop()
    local kind = self:GetTarget()
    pending = {}
    if StaticPopup_Hide then
        StaticPopup_Hide(POPUP)
    end
    if kind == "session" then
        Sessions():Stop()
    elseif kind == "run" then
        Runs():StopRun(PlayerGUID())
    end
    self:SendMessage("MCG_ACTIVITY_PAUSE_CHANGED")
end

function ActivityControl:Pause()
    local kind = self:GetTarget()
    local changed = false
    if kind == "session" then
        changed = Sessions():Pause()
    elseif kind == "run" then
        changed = Runs():PauseRun(PlayerGUID())
    end
    if changed then
        self:SendMessage("MCG_ACTIVITY_PAUSE_CHANGED")
    end
end

-- Resumes and replays anything held while paused (in the order it came in).
local function ResumeKind(kind)
    if kind == "session" then
        Sessions():Resume()
    elseif kind == "run" then
        Runs():ResumeRun(PlayerGUID())
    end
end

-- The kinds to act on: the target plus anything held (a run paused before a
-- session started is still paused under it).
local function KindsToAnswer(self)
    local kinds = {}
    local kind = self:GetTarget()
    if kind then
        kinds[kind] = true
    end
    for _, entry in ipairs(pending) do
        kinds[entry.kind] = true
    end
    return kinds
end

function ActivityControl:Resume()
    for kind in pairs(KindsToAnswer(self)) do
        ResumeKind(kind)
    end
    if StaticPopup_Hide then
        StaticPopup_Hide(POPUP)
    end
    local held = pending
    pending = {}
    for _, entry in ipairs(held) do
        local ok, err = pcall(entry.fn)
        if not ok then
            PocketCFO:AppendSessionLog("[MCG] ActivityControl: replay failed " .. tostring(err))
        end
    end
    self:SendMessage("MCG_ACTIVITY_PAUSE_CHANGED")
end

function ActivityControl:TogglePause()
    if self:IsPaused() then
        self:Resume()
    else
        self:Pause()
    end
end

-- "Stay paused": drop what was held and don't ask again this pause.
function ActivityControl:StayPaused()
    for kind in pairs(KindsToAnswer(self)) do
        local target
        if kind == "session" then
            target = Sessions():GetCurrent()
        else
            target = Runs():GetCurrentRuns()[PlayerGUID() or ""]
        end
        if target and target.pausedAt then
            target.pauseDeclined = true
        end
    end
    pending = {}
    self:SendMessage("MCG_ACTIVITY_PAUSE_CHANGED")
end

-- Called by ActivityRuns / ActivitySessions with something that would count
-- on a paused run / session. Asks once; holds everything until answered.
function ActivityControl:Hold(kind, fn)
    pending[#pending + 1] = { kind = kind, fn = fn }
    if #pending == 1 and StaticPopup_Show then
        StaticPopup_Show(POPUP)
    end
end

if StaticPopupDialogs then
    StaticPopupDialogs[POPUP] = {
        text = "Gold per hour is paused.\nResume and count what you just got?",
        button1 = "Resume",
        button2 = "Stay paused",
        timeout = 0,
        whileDead = true,
        hideOnEscape = false,
        OnAccept = function()
            ActivityControl:Resume()
        end,
        OnCancel = function()
            ActivityControl:StayPaused()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- "Still gathering?" prompt
-- ---------------------------------------------------------------------------

local function GapKey(run)
    return tostring(run.startedAt or "?") .. ":" .. tostring(run.lastLootAt or "?")
end

local function InCombat()
    return UnitAffectingCombat and UnitAffectingCombat("player") and true or false
end

-- The run the prompt is about: the character's gathering run, only when no
-- session is running. nil otherwise.
local function PromptRun()
    local sessions = Sessions()
    if sessions and sessions:GetCurrent() then
        return nil
    end
    local runs = Runs()
    return runs and runs:GetCurrentRun() or nil
end

local function HideStillPopup()
    if StaticPopup_Visible and StaticPopup_Visible(STILL_POPUP) and StaticPopup_Hide then
        StaticPopup_Hide(STILL_POPUP)
    end
end

-- Runs every STILL_CHECK_SECONDS and on leaving combat.
function ActivityControl:CheckStillGathering()
    local run = PromptRun()
    local runs = Runs()
    if not run or not runs then
        stillAskedFor = nil
        HideStillPopup()
        return
    end
    -- Loot came in or the gap was answered: the open prompt is stale.
    if stillAskedFor and stillAskedFor ~= GapKey(run) then
        stillAskedFor = nil
        HideStillPopup()
    end
    if stillAskedFor or InCombat() or not runs:NeedsStillGatheringPrompt(run) then
        return
    end
    stillAskedFor = GapKey(run)
    if StaticPopup_Show then
        StaticPopup_Show(STILL_POPUP)
    end
end

-- The prompt's run, if it is still the gap that was asked about.
local function AnsweredRun()
    local run = PromptRun()
    if run and stillAskedFor and stillAskedFor == GapKey(run) then
        return run
    end
    return nil
end

function ActivityControl:AnswerStillGathering()
    if AnsweredRun() then
        Runs():KeepGathering(PlayerGUID())
    end
end

function ActivityControl:AnswerDoneGathering()
    if AnsweredRun() then
        stillAskedFor = nil
        Runs():StopRun(PlayerGUID())
        self:SendMessage("MCG_ACTIVITY_PAUSE_CHANGED")
    end
end

if StaticPopupDialogs then
    StaticPopupDialogs[STILL_POPUP] = {
        text = "You haven't gathered anything in 3 minutes. Still at it?\n\n"
            .. "|cffffd100Still gathering:|r the time spent looking counts.\n"
            .. "|cffffd100I'm done:|r your run is saved, ending at your last gather.",
        button1 = "Still gathering",
        button2 = "I'm done",
        timeout = 0,
        whileDead = true,
        hideOnEscape = false,
        OnAccept = function()
            ActivityControl:AnswerStillGathering()
        end,
        OnCancel = function()
            ActivityControl:AnswerDoneGathering()
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Tracker auto-show (the tracker window lives in PocketCFO_PnL)
-- ---------------------------------------------------------------------------

local function Tracker(load)
    if load then
        local loader = PocketCFO:GetModule("AddonLoader", true)
        if not loader or not loader:SafeLoad("PocketCFO_PnL") then
            return nil
        end
    end
    local pnl = _G.PocketCFO_PnL
    return pnl and pnl.GetModule and pnl:GetModule("GoldPerHourWindow", true) or nil
end

function ActivityControl:OnTrackingChanged()
    if not self:GetSetting("trackerAutoShow") then
        return
    end
    local kind, target = self:GetTarget()
    local key = TargetKey(kind, target)
    if not key or key == autoShownFor then
        return
    end
    autoShownFor = key
    local tracker = Tracker(true)
    if tracker and not tracker:IsShown() then
        tracker:Show()
    end
end

-- ---------------------------------------------------------------------------
-- Logout
-- ---------------------------------------------------------------------------

local function NoteLogoutIntent()
    loggingOut = true
end

function ActivityControl:OnPlayerLogout()
    if not loggingOut then
        return
    end
    local sessions = Sessions()
    if sessions and sessions.EndForLogout then
        sessions:EndForLogout()
    end
    local runs = Runs()
    if runs and runs.StopRun then
        runs:StopRun(PlayerGUID())
    end
    PocketCFO:AppendSessionLog("[MCG] ActivityControl: logged out, session and run ended")
end

-- Game events on a plain frame (CraftSim's bundled AceEvent can shift
-- callback arguments; same pattern as ActivitySessions).
local logoutFrame = CreateFrame("Frame")
logoutFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        ActivityControl:CheckStillGathering()
    elseif event == "LOGOUT_CANCEL" then
        loggingOut = false
    elseif event == "PLAYER_LOGOUT" then
        ActivityControl:OnPlayerLogout()
    else
        NoteLogoutIntent()
    end
end)

function ActivityControl:OnEnable()
    for _, event in ipairs({ "PLAYER_CAMPING", "PLAYER_QUITING", "LOGOUT_CANCEL", "PLAYER_LOGOUT",
                             "PLAYER_REGEN_ENABLED" }) do
        pcall(logoutFrame.RegisterEvent, logoutFrame, event)
    end
    if hooksecurefunc then
        for _, name in ipairs({ "Logout", "Quit" }) do
            if type(_G[name]) == "function" then
                hooksecurefunc(name, NoteLogoutIntent)
            end
        end
    end
    self:RegisterMessage("MCG_ACTIVITY_RUNS_UPDATED", "OnTrackingChanged")
    self:RegisterMessage("MCG_SESSIONS_FILED", "OnTrackingChanged")
    self:RegisterMessage("MCG_SESSIONS_UPDATED", "OnTrackingChanged")
    -- "Still gathering?" prompt: closes when the run is filed or loot lands.
    self:RegisterMessage("MCG_ACTIVITY_RUNS_FILED", "CheckStillGathering")
    self:RegisterMessage("MCG_ACTIVITY_RUNS_UPDATED", "CheckStillGathering")
    if C_Timer and C_Timer.NewTicker then
        self.stillTicker = C_Timer.NewTicker(STILL_CHECK_SECONDS, function()
            ActivityControl:CheckStillGathering()
        end)
    end
end
