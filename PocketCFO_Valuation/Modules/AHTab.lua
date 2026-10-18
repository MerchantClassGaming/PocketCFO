-- PocketCFO_Valuation/Modules/AHTab.lua
-- Embeddable Auction House pricing controls.
--
-- PocketCFO_AH owns the Blizzard Auction House tab and page shell. This module
-- only contributes the pricing scan button/status used by the AH Dashboard.

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local AHTab = PocketCFO_Valuation:NewModule("AHTab")

local function Print(message)
    local PocketCFO = _G.PocketCFO
    if PocketCFO and PocketCFO.Print then
        PocketCFO:Print(message)
    elseif DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(message)
    end
end

local function IsStatusRunning(status)
    return status and status.running == true
end

local function FormatList(values)
    if type(values) ~= "table" then
        return tostring(values)
    end

    local parts = {}
    for index = 1, #values do
        parts[#parts + 1] = tostring(values[index])
    end
    if #parts == 0 then
        return "{}"
    end
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.ceil(tonumber(seconds) or 0))
    local minutes = math.floor(seconds / 60)
    local remainder = seconds % 60
    return string.format("%02d:%02d", minutes, remainder)
end

local function GetPhaseLabel(status)
    local state = status and status.state or "unknown"
    if state == "requesting" or state == "waiting" then
        return "Phase 1 of 4: Waiting for Blizzard AH data"
    elseif state == "processing" then
        return "Phase 2 of 4: Reading Auction House rows"
    elseif state == "building" then
        return "Phase 3 of 4: Building pricing buckets"
    elseif state == "finalizing" then
        return "Phase 4 of 4: Calculating prices"
    end
    return nil
end

local function GetStatusLabel(status)
    local state = status and status.state or "unknown"
    if state == "idle" then
        return "Idle"
    elseif state == "complete" then
        return "Complete"
    elseif state == "failed" then
        return "Failed"
    elseif state == "cooldown" then
        return "Full scan available in " .. FormatDuration(status and status.cooldownRemaining or 0)
    end
    return GetPhaseLabel(status) or tostring(state)
end

local function BuildScanStatusText(status)
    status = status or {}
    local state = status.state or "unknown"
    local lines = {}

    if state == "idle" or state == "cooldown" then
        lines[#lines + 1] = "State: " .. GetStatusLabel(status)
        if status.rejectReason then
            lines[#lines + 1] = tostring(status.rejectReason)
        end
        return table.concat(lines, "\n")
    end

    if state == "complete" then
        lines[#lines + 1] = "Complete"
        lines[#lines + 1] = "Rows Analyzed: " .. tostring(status.rowsProcessed or status.rowsTotal or 0)
        lines[#lines + 1] = "Markets Priced: " .. tostring(status.marketsPriced or 0)
        lines[#lines + 1] = "Total Time: " .. FormatDuration(status.totalElapsedSeconds or status.elapsedSeconds or 0)
        return table.concat(lines, "\n")
    end

    if state == "failed" then
        lines[#lines + 1] = "Failed"
        lines[#lines + 1] = tostring(status.lastError or status.rejectReason or "Full scan failed")
        lines[#lines + 1] = "Elapsed: " .. FormatDuration(status.totalElapsedSeconds or status.elapsedSeconds or 0)
        lines[#lines + 1] = "ReplicateItems: exists=" .. tostring(status.replicateItemsExists)
            .. " ok=" .. tostring(status.replicateCallOk)
            .. " returns=" .. FormatList(status.replicateReturns)
        lines[#lines + 1] = "GetNumReplicateItems: exists=" .. tostring(status.getNumReplicateItemsExists)
            .. " immediate=" .. tostring(status.numReplicateItemsImmediately)
        lines[#lines + 1] = "Last event=" .. tostring(status.lastEventName or "none")
            .. "  Timeout=" .. tostring(status.timeoutSeconds or "?") .. "s"
        return table.concat(lines, "\n")
    end

    lines[#lines + 1] = "PocketCFO Full Market Scan"
    lines[#lines + 1] = "This scan analyzes the entire Auction House and builds pricing data for crafting valuation."
    lines[#lines + 1] = "Expected Time: About 2 minutes"
    lines[#lines + 1] = ""
    lines[#lines + 1] = GetPhaseLabel(status) or ("State: " .. GetStatusLabel(status))
    lines[#lines + 1] = "Elapsed: " .. FormatDuration(status.elapsedSeconds or 0)

    if state == "requesting" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Sending the full scan request to Blizzard."
    elseif state == "waiting" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Blizzard has accepted the scan request."
        lines[#lines + 1] = "Waiting for the Auction House to provide the market dataset."
    elseif state == "processing" then
        if tonumber(status.rowsTotal) and tonumber(status.rowsTotal) > 0 then
            lines[#lines + 1] = "Rows Read: " .. tostring(status.rowsProcessed or 0) .. " / " .. tostring(status.rowsTotal or 0)
        end
    elseif state == "building" then
        lines[#lines + 1] = "Markets Built: " .. tostring(status.marketsBuilt or 0)
    elseif state == "finalizing" then
        if tonumber(status.marketsTotal) and tonumber(status.marketsTotal) > 0 then
            lines[#lines + 1] = "Markets Priced: " .. tostring(status.marketsPriced or 0) .. " / " .. tostring(status.marketsTotal or 0)
        else
            lines[#lines + 1] = "Markets Priced: " .. tostring(status.marketsPriced or 0)
        end
    end

    return table.concat(lines, "\n")
end

function AHTab:RefreshStatus()
    if not self.statusText then
        return
    end

    local status = PocketCFO_Valuation:GetFullScanStatus()
    local running = IsStatusRunning(status)
    self.statusText:SetText(BuildScanStatusText(status))

    if self.scanButton then
        if running then
            self.scanButton:Disable()
        else
            self.scanButton:Enable()
        end
    end

    return status
end

function AHTab:StopStatusRefresh()
    if self.statusTicker and self.statusTicker.Cancel then
        self.statusTicker:Cancel()
    end
    self.statusTicker = nil
end

function AHTab:StartStatusRefreshIfRunning()
    local status = PocketCFO_Valuation:GetFullScanStatus()
    if not IsStatusRunning(status) then
        self:StopStatusRefresh()
        return
    end
    if self.statusTicker then
        return
    end

    if C_Timer and C_Timer.NewTicker then
        self.statusTicker = C_Timer.NewTicker(0.2, function()
            if not self.pricingFrame or not self.pricingFrame:IsShown() then
                self:StopStatusRefresh()
                return
            end

            local refreshed = self:RefreshStatus()
            if not IsStatusRunning(refreshed) then
                self:StopStatusRefresh()
            end
        end)
    end
end

function AHTab:StartScan()
    local PocketCFO = _G.PocketCFO
    if PocketCFO and PocketCFO.Debug then
        PocketCFO:Debug("AHTab:StartScan called")
    end
    if self.statusText then
        self.statusText:SetText(BuildScanStatusText({
            state = "requesting",
            running = true,
            elapsedSeconds = 0,
        }))
    end
    local ok, reason = PocketCFO_Valuation:StartFullScan()
    if ok then
        Print("PocketCFO pricing scan started.")
    else
        Print(reason or "PocketCFO pricing scan could not start.")
    end
    self:RefreshStatus()
    self:StartStatusRefreshIfRunning()
end

function AHTab:EmbedPricingSection(parent)
    if not parent or not CreateFrame then
        return nil, "missingParent"
    end

    local frame = self.pricingFrame
    if not frame then
        frame = CreateFrame("Frame", "PocketCFOValuationPricingSection", parent)
        self.pricingFrame = frame

        local scanButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        scanButton:SetSize(130, 24)
        scanButton:SetText("Scan Prices")
        scanButton:SetScript("OnClick", function()
            self:StartScan()
        end)
        self.scanButton = scanButton

        local statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        statusText:SetJustifyH("LEFT")
        statusText:SetJustifyV("TOP")
        statusText:SetText("State: Idle")
        if statusText.SetWordWrap then
            statusText:SetWordWrap(true)
        end
        self.statusText = statusText

        frame:SetScript("OnShow", function()
            frame.elapsed = 0
            self:RefreshStatus()
            self:StartStatusRefreshIfRunning()
        end)
        frame:SetScript("OnHide", function()
            self:StopStatusRefresh()
        end)
        frame:SetScript("OnUpdate", function(_, elapsed)
            frame.elapsed = (frame.elapsed or 0) + (elapsed or 0)
            local status = PocketCFO_Valuation:GetFullScanStatus()
            local interval = IsStatusRunning(status) and 0.2 or 0.5
            if frame.elapsed >= interval then
                frame.elapsed = 0
                status = self:RefreshStatus()
                if IsStatusRunning(status) then
                    self:StartStatusRefreshIfRunning()
                end
            end
        end)
    end

    frame:SetParent(parent)
    frame:ClearAllPoints()
    frame:SetAllPoints(parent)
    frame:SetFrameLevel(parent:GetFrameLevel() + 1)

    self.scanButton:ClearAllPoints()
    self.scanButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)

    self.statusText:ClearAllPoints()
    self.statusText:SetPoint("TOPLEFT", self.scanButton, "BOTTOMLEFT", 0, -14)
    self.statusText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

    frame:Show()
    self:RefreshStatus()
    self:StartStatusRefreshIfRunning()
    return frame
end

function AHTab:OnEnable()
end

function AHTab:OnDisable()
    self:StopStatusRefresh()
end
