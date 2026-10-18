-- PocketCFO_Crafting/UI/PostingProfiles/PostingProfilesWindow.lua
-- Standalone posting profile manager window opened from Inventory Manager.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local PostingProfilesWindow = PocketCFO_Crafting:NewModule("PostingProfilesWindow", "AceEvent-3.0")

local FRAME_WIDTH = 650
local FRAME_HEIGHT = 400
local FRAME_PADDING = 10
local COLOR_BG = { r = 0.05, g = 0.05, b = 0.08, a = 0.92 }

local frame
local content

local function AddChild(parent, child)
    parent.children = parent.children or {}
    parent.children[#parent.children + 1] = child
    return child
end

local function ClearChildren(parent)
    for _, child in ipairs(parent.children or {}) do
        if child.Hide then
            child:Hide()
        end
        if child.SetParent then
            child:SetParent(nil)
        end
    end
    for _, child in ipairs({ parent:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    parent.children = {}
end

local function CreateLabel(parent, text, x, y, width, font)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetWidth(width or 320)
    label:SetJustifyH("LEFT")
    label:SetText(text or "")
    return label
end

local function SafeLoadAH()
    if _G.PocketCFO_AH then
        return _G.PocketCFO_AH
    end

    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("PocketCFO_AH"))
        or (IsAddOnLoaded and IsAddOnLoaded("PocketCFO_AH"))
    if not loaded then
        local loadFn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if loadFn then
            pcall(loadFn, "PocketCFO_AH")
        end
    end
    return _G.PocketCFO_AH
end

local function GetProfilesModule()
    local ah = SafeLoadAH()
    return ah and ah.GetModule and ah:GetModule("PostingProfileRepository", true) or nil
end

local function GetProfilesDB()
    local profiles = GetProfilesModule()
    if profiles and profiles.GetProfilesDB then
        return profiles:GetProfilesDB()
    end
    return {}
end

local function BuildFrame()
    if frame then
        return
    end

    frame = CreateFrame("Frame", "MCGCFOPostingProfilesFrame", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    if PocketCFO_Crafting.HelperWindow then
        PocketCFO_Crafting.HelperWindow:Configure(frame)
    else
        frame:SetFrameStrata("HIGH")
    end
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(COLOR_BG.r, COLOR_BG.g, COLOR_BG.b, COLOR_BG.a)
    frame:SetBackdropBorderColor(0.4, 0.35, 0.25, 0.9)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local x = self:GetLeft()
        local y = self:GetTop()
        if x and y and PocketCFO and PocketCFO.db and PocketCFO.db.char then
            PocketCFO.db.char.postingProfilesWindowPosition = { x = x, y = y }
        end
    end)
    frame:SetClampedToScreen(true)
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
    title:SetJustifyH("LEFT")
    title:SetText("PocketCFO Posting Profiles")

    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
    closeBtn:SetScript("OnClick", function()
        PostingProfilesWindow:Hide()
    end)

    content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", FRAME_PADDING, -34)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -FRAME_PADDING, FRAME_PADDING)
end

function PostingProfilesWindow:Position(anchorFrame)
    if not frame then
        return
    end

    local saved = PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.postingProfilesWindowPosition
    frame:ClearAllPoints()
    if saved and saved.x and saved.y then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved.x, saved.y)
    elseif anchorFrame then
        frame:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", 364, -24)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 360, 0)
    end
end

function PostingProfilesWindow:Render()
    if not frame or not frame:IsShown() then
        return
    end

    ClearChildren(content)

    local ah = SafeLoadAH()
    if not ah then
        AddChild(content, CreateLabel(content, "PocketCFO AH could not be loaded.", 10, -12, 360, "GameFontRedSmall"))
        return
    end

    local managerModule = ah:GetModule("PostingProfileManagerUI", true)
    if not managerModule or not managerModule.Create then
        AddChild(content, CreateLabel(content, "PocketCFO_AH module 'PostingProfileManagerUI' is unavailable.", 10, -12, 360, "GameFontRedSmall"))
        return
    end

    local profiles = GetProfilesModule()
    if not profiles then
        AddChild(content, CreateLabel(content, "PocketCFO_AH module 'PostingProfileRepository' is unavailable.", 10, -12, 360, "GameFontRedSmall"))
        return
    end

    managerModule:Create(content, {
        selectedKey = self.selectedProfileKey,
        errorText = self.profileErrorText,
        getProfiles = function()
            return profiles and profiles:GetDebugRows() or {}
        end,
        getProfile = function(profileKey)
            return profiles and profiles:GetProfile(profileKey) or nil
        end,
        getProfilesDB = GetProfilesDB,
        onSelect = function(profileKey)
            self.selectedProfileKey = profileKey
        end,
        onDelete = function(profileKey)
            if profiles then
                profiles:DeleteProfile(profileKey)
            end
        end,
        onSave = function(profileKey, profile)
            if profiles then
                profiles:SaveProfile(profileKey, profile)
            end
        end,
        onError = function(errorText)
            self.profileErrorText = errorText
        end,
        onChanged = function()
            self:Render()
        end,
    })
end

function PostingProfilesWindow:Show(anchorFrame)
    BuildFrame()
    if not frame:IsShown() then
        self:Position(anchorFrame)
    end
    if PocketCFO_Crafting.HelperWindow then
        PocketCFO_Crafting.HelperWindow:ShowOrRaise(frame)
    else
        frame:Show()
    end
    self:Render()
    self:SendMessage("MCGCFO_POSTING_PROFILES_WINDOW_CHANGED", true)
end

function PostingProfilesWindow:Hide()
    if frame then
        frame:Hide()
    end
    self:SendMessage("MCGCFO_POSTING_PROFILES_WINDOW_CHANGED", false)
end

function PostingProfilesWindow:CloseForTradeSkillClose()
    if frame then
        frame:Hide()
    end
    self:SendMessage("MCGCFO_POSTING_PROFILES_WINDOW_CHANGED", false)
end

function PostingProfilesWindow:Toggle(anchorFrame)
    BuildFrame()
    if frame:IsShown() then
        self:Hide()
    else
        self:Show(anchorFrame)
    end
end

function PostingProfilesWindow:IsOpen()
    return frame and frame:IsShown() == true
end

function PostingProfilesWindow:OnEnable()
    BuildFrame()
end
