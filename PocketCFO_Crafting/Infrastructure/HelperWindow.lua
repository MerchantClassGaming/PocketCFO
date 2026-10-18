-- PocketCFO_Crafting/Infrastructure/HelperWindow.lua
-- Small shared behavior for profession-side PocketCFO helper windows.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local HelperWindow = {}
PocketCFO_Crafting.HelperWindow = HelperWindow

local BASE_FRAME_LEVEL = 100
local HELPER_LEVEL_OFFSET = 5

local registeredFrames = {}

local function GetBaseFrameLevel()
    local uiParent = _G.UIParent
    if uiParent and uiParent.GetFrameLevel then
        local level = tonumber(uiParent:GetFrameLevel())
        if level then
            return level
        end
    end
    return BASE_FRAME_LEVEL
end

local function RegisterFrame(frame)
    for _, registered in ipairs(registeredFrames) do
        if registered == frame then
            return
        end
    end
    registeredFrames[#registeredFrames + 1] = frame
end

local function GetFrameIndex(frame)
    for index, registered in ipairs(registeredFrames) do
        if registered == frame then
            return index
        end
    end
    return #registeredFrames + 1
end

local function SetMouseEnabled(frame, enabled)
    if frame and frame.EnableMouse then
        frame:EnableMouse(enabled == true)
    end
end

local function MarkHelperConfigured(frame)
    if frame.__pcfoHelperWindowConfigured then
        return
    end

    frame.__pcfoHelperWindowConfigured = true
    if frame.HookScript then
        frame:HookScript("OnShow", function(self)
            SetMouseEnabled(self, true)
        end)
        frame:HookScript("OnHide", function(self)
            SetMouseEnabled(self, false)
        end)
    end
end

function HelperWindow:Configure(frame)
    if not frame then
        return
    end

    frame:SetParent(UIParent)
    frame:SetFrameStrata("MEDIUM")
    if frame.SetToplevel then
        frame:SetToplevel(false)
    end
    SetMouseEnabled(frame, frame.IsShown and frame:IsShown())
    if frame.HookScript then
        frame:HookScript("OnMouseDown", function(self)
            HelperWindow:Raise(self)
        end)
    end

    RegisterFrame(frame)
    MarkHelperConfigured(frame)
end

function HelperWindow:Raise(frame)
    if not frame then
        return
    end
    if frame.IsShown and not frame:IsShown() then
        SetMouseEnabled(frame, false)
        return
    end

    SetMouseEnabled(frame, true)
    if frame.SetFrameStrata then
        frame:SetFrameStrata("MEDIUM")
    end
    if frame.SetFrameLevel then
        frame:SetFrameLevel(GetBaseFrameLevel() + HELPER_LEVEL_OFFSET + GetFrameIndex(frame))
    end
    if frame.Raise then
        frame:Raise()
    end
end

function HelperWindow:ShowOrRaise(frame)
    if not frame then
        return
    end

    frame:Show()
    self:Raise(frame)
end

function HelperWindow:Hide(frame)
    if not frame then
        return
    end

    frame:Hide()
    SetMouseEnabled(frame, false)
end
