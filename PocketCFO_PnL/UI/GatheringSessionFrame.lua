-- PocketCFO_PnL/UI/GatheringSessionFrame.lua
-- Small movable frame shown while a gathering session runs: time, value
-- gathered and gold per hour, with a Stop button. Session state is owned by
-- core GatheringCapture; this frame only displays it.
-- Gold per hour shows "-" for the first minute so it never flashes a silly
-- number off one node.

local PocketCFO = _G.PocketCFO
local PocketCFO_PnL = _G.PocketCFO_PnL

local GatheringSessionFrame = PocketCFO_PnL:NewModule("GatheringSessionFrame", "AceEvent-3.0")

local WIDTH = 210
local HEIGHT = 96
local UPDATE_SECONDS = 1

local function Capture()
    return PocketCFO:GetModule("GatheringCapture", true)
end

local function FormatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper >= 10000 then
        copper = math.floor(copper / 10000) * 10000
    end
    if GetMoneyString then
        return GetMoneyString(copper, true)
    end
    return tostring(math.floor(copper / 10000)) .. "g"
end

local function CreateText(parent, template, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    text:SetWordWrap(false)
    return text
end

function GatheringSessionFrame:Build()
    if self.frame then
        return
    end
    local frame = CreateFrame("Frame", "MCGCFOGatheringSessionFrame", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    frame:SetFrameStrata("MEDIUM")
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0.05, 0.05, 0.07, 0.9)
    frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 1)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
            local capture = Capture()
            if capture then
                capture:SetFramePosition(left, top)
            end
        end
    end)

    local capture = Capture()
    local pos = capture and capture:GetFramePosition()
    if pos and pos.left and pos.top then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.left, pos.top)
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end

    frame.title = CreateText(frame, "GameFontNormal")
    frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -8)
    frame.title:SetText("Gathering")

    frame.time = CreateText(frame, "GameFontHighlightSmall", "RIGHT")
    frame.time:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -10)

    local labels = { "Value", "Per hour" }
    frame.values = {}
    for index, labelText in ipairs(labels) do
        local y = -28 - (index - 1) * 16
        local label = CreateText(frame, "GameFontDisableSmall")
        label:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, y)
        label:SetText(labelText)
        local value = CreateText(frame, "GameFontHighlightSmall", "RIGHT")
        value:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, y)
        value:SetWidth(WIDTH - 80)
        frame.values[index] = value
    end

    frame.stop = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.stop:SetSize(WIDTH - 20, 20)
    frame.stop:SetPoint("BOTTOM", frame, "BOTTOM", 0, 8)
    frame.stop:SetText("Stop Session")
    frame.stop:SetScript("OnClick", function()
        local captureModule = Capture()
        if captureModule then
            captureModule:ToggleSession()
        end
    end)

    frame.elapsed = 0
    frame:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed >= UPDATE_SECONDS then
            self.elapsed = 0
            GatheringSessionFrame:Draw()
        end
    end)
    frame:Hide()
    self.frame = frame

    self:RegisterMessage("MCG_GATHERING_UPDATED", "Draw")
    self:RegisterMessage("MCG_GATHERING_SESSION_CHANGED", "Refresh")
end

-- Shows the frame while a session runs, hides it otherwise.
function GatheringSessionFrame:Refresh()
    self:Build()
    local capture = Capture()
    if capture and capture:GetActiveSession() then
        self:Draw()
        self.frame:Show()
    else
        self.frame:Hide()
    end
end

function GatheringSessionFrame:Draw()
    if not self.frame then
        return
    end
    local capture = Capture()
    local session = capture and capture:GetActiveSession()
    if not session then
        self.frame:Hide()
        return
    end
    local report = PocketCFO_PnL.GatheringReport
    local stats = report:SessionStats(session, time())
    self.frame.time:SetText(report:FormatDuration(stats.seconds))
    self.frame.values[1]:SetText(FormatMoney(stats.copper))
    self.frame.values[2]:SetText(stats.perHour and FormatMoney(stats.perHour) or "-")
end
