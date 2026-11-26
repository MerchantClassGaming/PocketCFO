-- PocketCFO_AH/UI/AnalysisTab.lua
-- Forever only for now (loaded by PocketCFO_AH_Camelot.toc; the shell shows
-- the page only when PocketCFO.flavor == "forever").
--
-- The Analysis tab (claude/Analysis_Tab_Design.md, 2026-11-24): analysis
-- buttons in a narrow left column, the selected analysis on the right, one
-- status line on top. Clicking a button only opens that analysis; its own
-- Analyze button calls AnalysisTab:Run(key).
--
-- Every analysis gets its prices the same way (Brian, 2026-11-24): a full
-- AH scan, or the last one if it was less than 15 minutes ago (the game
-- allows one every 15 minutes). The scan saves the listings each analysis
-- asked for (FullScan:AddListingKeeper); then the analysis does its math.
--
-- An analysis registers once:
--   AnalysisTab:Register({
--       key = "crates", buttonText = "Crate analysis",
--       Build = function(entry, content) ... end,     -- draw its controls once
--       OnScanning = function(entry) ... end,          -- hide old results
--       IsReady = function(entry) return true end,     -- optional: data loaded?
--       OnPrices = function(entry, info) ... end,      -- info = { fresh = bool } or { failed = text }
--   })

local PocketCFO_AH = _G.PocketCFO_AH
local AnalysisTab = PocketCFO_AH:NewModule("AnalysisTab")

local LEFT_WIDTH = 130
local BUTTON_HEIGHT = 24
local GAP = 14
local POLL_SECONDS = 0.5

AnalysisTab.entries = {}
AnalysisTab.order = {}

local function SafeLoad(name)
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(name))
        or (IsAddOnLoaded and IsAddOnLoaded(name))
    if loaded then
        return true
    end
    local loadFn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if not loadFn then
        return false
    end
    local ok, result = pcall(loadFn, name)
    return ok and result and true or false
end

local function FullScanModule()
    SafeLoad("PocketCFO_Valuation")
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule("FullScan", true) or nil
end

function AnalysisTab:Register(entry)
    if type(entry) ~= "table" or not entry.key or self.entries[entry.key] then
        return
    end
    self.entries[entry.key] = entry
    self.order[#self.order + 1] = entry
end

function AnalysisTab:HasEntries()
    return #self.order > 0
end

local function CreateText(parent, font)
    local text = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    text:SetJustifyH("LEFT")
    return text
end

-- Builds the page once inside `parent` (the shell's Analysis page frame).
function AnalysisTab:Render(parent)
    if not parent or not CreateFrame then
        return nil
    end
    local frame = self.frame
    if not frame then
        frame = CreateFrame("Frame", "PocketCFOAnalysisTabFrame", parent)
        self.frame = frame

        local left = CreateFrame("Frame", nil, frame)
        left:SetPoint("TOPLEFT", frame, "TOPLEFT", 4, -8)
        left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 8)
        left:SetWidth(LEFT_WIDTH)
        self.left = left

        local right = CreateFrame("Frame", nil, frame)
        right:SetPoint("TOPLEFT", left, "TOPRIGHT", GAP, 0)
        right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 8)
        self.right = right

        local status = CreateText(right, "GameFontHighlightSmall")
        status:SetPoint("TOPLEFT", right, "TOPLEFT", 0, 0)
        status:SetPoint("RIGHT", right, "RIGHT", 0, 0)
        status:SetHeight(14)
        self.status = status

        self.buttons = {}
        for index, entry in ipairs(self.order) do
            local button = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
            button:SetSize(LEFT_WIDTH, BUTTON_HEIGHT)
            button:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -(index - 1) * (BUTTON_HEIGHT + 6))
            button:SetText(entry.buttonText or entry.key)
            button:SetScript("OnClick", function()
                self:Select(entry.key)
            end)
            self.buttons[entry.key] = button

            local content = CreateFrame("Frame", nil, right)
            content:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -6)
            content:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)
            content:Hide()
            entry.content = content
            if type(entry.Build) == "function" then
                entry:Build(content)
            end
        end

        local hint = CreateText(right, "GameFontHighlightSmall")
        hint:SetPoint("TOPLEFT", status, "BOTTOMLEFT", 0, -6)
        hint:SetPoint("RIGHT", right, "RIGHT", 0, 0)
        hint:SetText("Pick an analysis on the left.")
        self.hint = hint
    end
    frame:SetParent(parent)
    frame:ClearAllPoints()
    frame:SetAllPoints(parent)
    frame:Show()
    if self.selected then
        self:Select(self.selected)
    end
    return frame
end

function AnalysisTab:Select(key)
    if not self.entries[key] or not self.frame then
        return
    end
    self.selected = key
    if self.hint then
        self.hint:Hide()
    end
    for entryKey, entry in pairs(self.entries) do
        if entry.content then
            entry.content:SetShown(entryKey == key)
        end
        local button = self.buttons and self.buttons[entryKey]
        if button then
            if entryKey == key then
                button:LockHighlight()
            else
                button:UnlockHighlight()
            end
        end
    end
end

function AnalysisTab:SetStatus(text)
    if self.status then
        self.status:SetText(text or "")
    end
end

function AnalysisTab:IsRunning()
    return self.ticker ~= nil
end

local function FormatClock(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Scan steps on the status line (Brian, 2026-11-24): the full scan's own
-- stages, so players see it moving instead of one "Scanning" line until it
-- suddenly finishes. Each step stays up at least STEP_MIN_SECONDS and the
-- line moves one step at a time, so a stage that takes half a second never
-- flashes; a step shown late (the scan already past it) shows 100%.
local STEP_MIN_SECONDS = 3
local STEP_TEXT = {
    "Step 1 of 4: Requesting Auction House data",
    "Step 2 of 4: Reading auctions",
    "Step 3 of 4: Reviewing crates and materials",
    "Step 4 of 4: Finalizing recommendations",
}
local STEP_BY_STATE = {
    requesting = 1,
    waiting = 1,
    processing = 2,
    building = 3,
    finalizing = 4,
}

local function Percent(done, total)
    done, total = tonumber(done) or 0, tonumber(total) or 0
    if total <= 0 then
        return nil
    end
    return math.min(100, math.floor(done / total * 100))
end

function AnalysisTab:StepText(status)
    local actual = STEP_BY_STATE[status.state] or 1
    local clock = GetTime and GetTime() or 0
    local shown = self.shownStep
    if not shown then
        shown = 1
        self.shownStep, self.shownSince = shown, clock
    end
    if actual > shown and clock - (self.shownSince or clock) >= STEP_MIN_SECONDS then
        shown = shown + 1
        self.shownStep, self.shownSince = shown, clock
    end

    local percent
    if shown < actual then
        percent = (shown == 2 or shown == 4) and 100 or nil
    elseif shown == 2 then
        percent = Percent(status.rowsProcessed, status.rowsTotal)
    elseif shown == 4 then
        percent = Percent(status.marketsPriced, status.marketsTotal)
    end
    return STEP_TEXT[shown] .. (percent and (" " .. percent .. "%") or "") .. "... "
        .. FormatClock(status.elapsedSeconds)
end

function AnalysisTab:StopTicker()
    if self.ticker then
        self.ticker:Cancel()
        self.ticker = nil
    end
end

-- An analysis can say it isn't ready yet (entry:IsReady(), e.g. Crate
-- analysis waiting for the game to load crate tooltips; Brian 2026-11-24:
-- a plan built from half-loaded data was wrong). The status stays on the
-- last step until it is, up to READY_WAIT_SECONDS; after that the results
-- go out with info.notReady = true.
local READY_WAIT_SECONDS = 10

function AnalysisTab:Deliver(entry, info)
    self:StopTicker()
    local function Send()
        self:StopTicker()
        if info.failed then
            self:SetStatus(info.failed)
        else
            self:SetStatus("")
        end
        if type(entry.OnPrices) == "function" then
            entry:OnPrices(info)
        end
    end
    if type(entry.IsReady) ~= "function" or entry:IsReady() then
        Send()
        return
    end
    local started = GetTime and GetTime() or 0
    self:SetStatus(STEP_TEXT[4] .. "...")
    self.ticker = C_Timer.NewTicker(POLL_SECONDS, function()
        if entry:IsReady() then
            Send()
        elseif (GetTime and GetTime() or 0) - started >= READY_WAIT_SECONDS then
            info.notReady = true
            Send()
        end
    end)
end

-- Full scan, or the last one if it was less than 15 minutes ago, then the
-- analysis does its math.
function AnalysisTab:Run(key)
    local entry = self.entries[key]
    if not entry or self:IsRunning() then
        return
    end
    local scan = FullScanModule()
    if not scan then
        self:Deliver(entry, { failed = "Pricing isn't available." })
        return
    end
    if type(entry.OnScanning) == "function" then
        entry:OnScanning()
    end

    local status = scan:GetStatus()
    if not status.running then
        if (scan:GetCooldownRemaining() or 0) > 0 then
            -- A scan in the last 15 minutes: use it.
            self:Deliver(entry, { fresh = false })
            return
        end
        local ok, reason = scan:StartFullScan()
        if not ok then
            self:Deliver(entry, { failed = reason or "The scan didn't start." })
            return
        end
    end

    -- A scan is running (ours, or one started from the Dashboard): wait,
    -- showing its step (StepText).
    self.shownStep, self.shownSince = nil, nil
    self:SetStatus(self:StepText(scan:GetStatus()))
    self.ticker = C_Timer.NewTicker(POLL_SECONDS, function()
        local now = scan:GetStatus()
        if now.running then
            self:SetStatus(self:StepText(now))
        elseif now.state == "complete" then
            self:Deliver(entry, { fresh = true })
        else
            self:Deliver(entry, { failed = now.lastError or "The scan didn't finish." })
        end
    end)
end
