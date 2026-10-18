-- PocketCFO_AH/Posting/Components/PostingRuleEditor.lua
-- Reusable posting rule field editor.

local PocketCFO_AH = _G.PocketCFO_AH

local PostingRuleEditor = PocketCFO_AH:NewModule("PostingRuleEditor")

local MODES = { "none", "profile", "custom" }

local function AddChild(parent, child)
    parent.children = parent.children or {}
    parent.children[#parent.children + 1] = child
    return child
end

local function Trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function CreateLabel(parent, text, x, y, width, font)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetWidth(width or 100)
    label:SetJustifyH("LEFT")
    label:SetText(text)
    return label
end

local function CreateInput(parent, x, y, width)
    local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    input:SetSize(width or 90, 20)
    input:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    input:SetAutoFocus(false)
    input:SetFontObject("GameFontHighlightSmall")
    return input
end

local function CreateButton(parent, text, x, y, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width or 96, 22)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function FormatCopperString(value)
    value = tonumber(value)
    if not value or value < 0 then
        return ""
    end

    value = math.floor(value + 0.5)
    local gold = math.floor(value / 10000)
    local silver = math.floor((value % 10000) / 100)
    local copper = value % 100
    local text = ""

    if gold > 0 then
        text = text .. tostring(gold) .. "g"
    end
    if silver > 0 then
        text = text .. tostring(silver) .. "s"
    end
    if copper > 0 or text == "" then
        text = text .. tostring(copper) .. "c"
    end
    return text
end

local function ParseWholeNumber(value)
    value = Trim(value)
    if value == "" or not value:match("^%d+$") then
        return nil
    end
    return tonumber(value)
end

local function ParseGoldString(value)
    value = Trim(value):lower():gsub("%s+", "")
    if value == "" then
        return nil, "empty"
    end
    if value:match("^%d+$") then
        return (tonumber(value) or 0) * 10000
    end

    local amounts = { g = 0, s = 0, c = 0 }
    local seen = {}
    local order = { g = 1, s = 2, c = 3 }
    local lastOrder = 0
    local position = 1

    while position <= #value do
        local amountText, unit, nextPosition = value:match("^(%d+)([gsc])()", position)
        if not amountText or not unit then
            return nil, "invalid"
        end
        if seen[unit] or order[unit] <= lastOrder then
            return nil, "invalid"
        end
        seen[unit] = true
        amounts[unit] = tonumber(amountText) or 0
        lastOrder = order[unit]
        position = nextPosition
    end

    if amounts.s > 99 or amounts.c > 99 then
        return nil, "invalid"
    end

    return (amounts.g * 10000) + (amounts.s * 100) + amounts.c
end

local function FormatDurationValue(value)
    value = tostring(value or ""):lower():gsub("%s+", ""):gsub("h$", "")
    local duration = tonumber(value) or 12
    if duration ~= 12 and duration ~= 24 and duration ~= 48 then
        duration = 12
    end
    return duration
end

local function IsDurationValid(value)
    value = tonumber(value)
    return value == 12 or value == 24 or value == 48
end

local function PreserveLegacyMinProfitValues(existing, values)
    if type(existing) == "table" and type(values) == "table" then
        if existing.minProfitPct ~= nil and values.minProfitPct == nil then
            values.minProfitPct = existing.minProfitPct
        end
        if existing.minProfitGold ~= nil and values.minProfitGold == nil then
            values.minProfitGold = existing.minProfitGold
        end
    end
    return values
end

local function FormatRuleModeLabel(mode)
    mode = tostring(mode or "none")
    if mode == "profile" then
        return "Profile"
    elseif mode == "custom" then
        return "Custom"
    end
    return "None"
end

local function GetProfilesModule()
    return PocketCFO_AH:GetModule("PostingProfileRepository", true)
end

local function ProfileDisplayName(profileKey)
    local profiles = GetProfilesModule()
    local profile = profiles and profiles:GetProfile(profileKey)
    return profile and tostring(profile.name or profile.profileID or profile.profileKey or profileKey) or tostring(profileKey or "")
end

local function SetDropdownText(dropdown, text)
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(dropdown, text or "")
    end
end

local function CreateDurationDropdown(parent, x, y, selectedDuration)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    dropdown.selectedValue = FormatDurationValue(selectedDuration)
    UIDropDownMenu_SetWidth(dropdown, 72)
    UIDropDownMenu_Initialize(dropdown, function()
        for _, duration in ipairs({ 12, 24, 48 }) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = tostring(duration) .. "h"
            info.func = function()
                dropdown.selectedValue = duration
                SetDropdownText(dropdown, info.text)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    SetDropdownText(dropdown, tostring(dropdown.selectedValue) .. "h")
    return dropdown
end

local function CreateModeDropdown(parent, x, y, selectedMode, onSelect)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    UIDropDownMenu_SetWidth(dropdown, 86)
    UIDropDownMenu_Initialize(dropdown, function()
        for _, mode in ipairs(MODES) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = FormatRuleModeLabel(mode)
            info.func = function()
                onSelect(mode)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    SetDropdownText(dropdown, FormatRuleModeLabel(selectedMode))
    return dropdown
end

local function CreateProfileDropdown(parent, x, y, selectedProfile, onSelect)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    UIDropDownMenu_SetWidth(dropdown, 130)
    UIDropDownMenu_Initialize(dropdown, function()
        local rows = GetProfilesModule() and GetProfilesModule():GetDebugRows() or {}
        for _, profile in ipairs(rows) do
            local key = profile.profileID or profile.profileKey
            local info = UIDropDownMenu_CreateInfo()
            info.text = tostring(profile.name or key)
            info.func = function()
                onSelect(key)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    SetDropdownText(dropdown, selectedProfile and ProfileDisplayName(selectedProfile) or "")
    return dropdown
end

local function SetRuleFieldText(input, fieldKey, values)
    if not input then
        return
    end
    local value = values and values[fieldKey]
    if fieldKey == "minPrice" or fieldKey == "maxPrice" then
        input:SetText(value ~= nil and FormatCopperString(value) or "")
    else
        input:SetText(value ~= nil and tostring(value) or "")
    end
end

local function DisableRuleInput(input)
    if not input then
        return
    end
    if input.ClearFocus then
        input:ClearFocus()
    end
    if input.SetEnabled then
        input:SetEnabled(false)
    elseif input.Disable then
        input:Disable()
    end
    if input.SetTextColor then
        input:SetTextColor(0.62, 0.62, 0.62)
    end
end

local function RenderRuleValueFields(parent, x, y, values, readOnly)
    local inputs = {}

    AddChild(parent, CreateLabel(parent, "Max to Post", x, y, 100))
    inputs.targetPosted = AddChild(parent, CreateInput(parent, x, y - 14, 94))
    SetRuleFieldText(inputs.targetPosted, "targetPosted", values)

    AddChild(parent, CreateLabel(parent, "Duration", x + 150, y, 100))
    if readOnly then
        inputs.durationText = AddChild(parent, CreateInput(parent, x + 150, y - 14, 94))
        inputs.durationText:SetText(tostring(FormatDurationValue(values and values.duration or 12)) .. "h")
    else
        inputs.duration = AddChild(parent, CreateDurationDropdown(parent, x + 140, y - 16, values and values.duration or 12))
    end
    y = y - 52

    AddChild(parent, CreateLabel(parent, "Min Price", x, y, 100))
    inputs.minPrice = AddChild(parent, CreateInput(parent, x, y - 14, 120))
    SetRuleFieldText(inputs.minPrice, "minPrice", values)

    AddChild(parent, CreateLabel(parent, "Max Price", x + 150, y, 100))
    inputs.maxPrice = AddChild(parent, CreateInput(parent, x + 150, y - 14, 120))
    SetRuleFieldText(inputs.maxPrice, "maxPrice", values)

    if readOnly then
        DisableRuleInput(inputs.targetPosted)
        DisableRuleInput(inputs.durationText)
        DisableRuleInput(inputs.minPrice)
        DisableRuleInput(inputs.maxPrice)
    end

    return inputs
end

local function ValidateCustomRuleForm(inputs)
    local values = {}

    values.targetPosted = ParseWholeNumber(inputs.targetPosted and inputs.targetPosted:GetText())
    if not values.targetPosted or values.targetPosted <= 0 then
        return nil, "Max to Post must be a whole number greater than 0."
    end

    local duration = inputs.duration and inputs.duration.selectedValue or 12
    duration = FormatDurationValue(duration)
    if not IsDurationValid(duration) then
        return nil, "Duration must be 12h, 24h, or 48h."
    end
    values.duration = duration

    for _, field in ipairs({ "minPrice", "maxPrice" }) do
        local text = Trim(inputs[field] and inputs[field]:GetText())
        if text ~= "" then
            local copper = ParseGoldString(text)
            if copper == nil then
                local label = field == "minPrice" and "Min Price" or "Max Price"
                return nil, label .. " must use a valid gold format, such as 140g25s10c."
            end
            values[field] = copper
        end
    end

    return values, nil
end

function PostingRuleEditor:Create(parentFrame, options)
    local editor = {
        module = self,
        parent = parentFrame,
        options = options or {},
        enabled = not (options and options.enabled == false),
    }
    setmetatable(editor, { __index = self })
    editor:Render()
    return editor
end

function PostingRuleEditor:SetRuleTarget(ruleTarget)
    self.ruleTarget = ruleTarget
end

function PostingRuleEditor:LoadRule(rule)
    self.rule = rule
end

function PostingRuleEditor:SetOnSave(callback)
    self.onSave = callback
end

function PostingRuleEditor:SetOnClear(callback)
    self.onClear = callback
end

function PostingRuleEditor:SetOnDelete(callback)
    self.onDelete = callback
end

function PostingRuleEditor:SetEnabled(enabled)
    self.enabled = enabled and true or false
    self:ApplyEnabled()
end

function PostingRuleEditor:GetValues()
    if self.mode == "custom" and self.customInputs then
        return ValidateCustomRuleForm(self.customInputs)
    end
    return {}, nil
end

function PostingRuleEditor:SetError(errorText)
    if self.options.errorKey and self.options.owner then
        self.options.owner[self.options.errorKey] = errorText
    end
    if self.errorLabel then
        self.errorLabel:SetText(errorText or "")
    end
end

function PostingRuleEditor:GetSaveConfirmKey()
    return self.options.saveConfirmKey or "__postingRuleEditorSaveConfirmToken"
end

function PostingRuleEditor:SetSaveConfirmationVisible(visible)
    if self.saveConfirmLabel then
        self.saveConfirmLabel:SetText(visible and "Rule Saved" or "")
        if visible then
            self.saveConfirmLabel:Show()
        else
            self.saveConfirmLabel:Hide()
        end
    end
end

function PostingRuleEditor:ShowSaveConfirmation()
    local owner = self.options.owner
    local key = self:GetSaveConfirmKey()
    local token = tostring(GetTime and GetTime() or time()) .. ":" .. tostring(math.random and math.random() or 0)

    if owner then
        owner[key] = token
    else
        self[key] = token
    end

    self:SetSaveConfirmationVisible(true)

    if C_Timer and C_Timer.After then
        C_Timer.After(2.5, function()
            local current = owner and owner[key] or self[key]
            if current ~= token then
                return
            end
            if owner then
                owner[key] = nil
            else
                self[key] = nil
            end
            self:SetSaveConfirmationVisible(false)
            self:RefreshParent()
        end)
    end
end

function PostingRuleEditor:RefreshParent()
    if self.options.owner and self.options.owner.RefreshPage then
        self.options.owner:RefreshPage(self.options.owner.currentPage)
        self.options.owner:RefreshPage("post")
    end
end

function PostingRuleEditor:SetControlEnabled(control, enabled)
    if not control then
        return
    end
    if enabled then
        if control.Enable then
            control:Enable()
        elseif control.SetEnabled then
            control:SetEnabled(true)
        end
        if control.SetTextColor and control.GetObjectType and control:GetObjectType() == "EditBox" then
            control:SetTextColor(1, 1, 1)
        end
    else
        if control.ClearFocus then
            control:ClearFocus()
        end
        if control.Disable then
            control:Disable()
        elseif control.SetEnabled then
            control:SetEnabled(false)
        end
        if control.SetTextColor and control.GetObjectType and control:GetObjectType() == "EditBox" then
            control:SetTextColor(0.62, 0.62, 0.62)
        end
    end
end

function PostingRuleEditor:SetDropdownEnabled(dropdown, enabled)
    if not dropdown then
        return
    end
    if enabled then
        if UIDropDownMenu_EnableDropDown then
            UIDropDownMenu_EnableDropDown(dropdown)
        end
    elseif UIDropDownMenu_DisableDropDown then
        UIDropDownMenu_DisableDropDown(dropdown)
    end
end

function PostingRuleEditor:ApplyEnabled()
    local enabled = self.enabled ~= false
    self:SetDropdownEnabled(self.modeDropdown, enabled)
    self:SetDropdownEnabled(self.profileDropdown, enabled)
    self:SetDropdownEnabled(self.durationDropdown, enabled)
    self:SetControlEnabled(self.saveButton, enabled)
    self:SetControlEnabled(self.deleteButton, enabled)

    for _, input in pairs(self.customInputs or {}) do
        self:SetControlEnabled(input, enabled)
    end
end

function PostingRuleEditor:Render()
    local options = self.options
    local owner = options.owner
    local parent = self.parent
    local rule = options.rule or {}
    local selectedKey = options.selectedKey
    local mode = tostring(rule and rule.mode or "none")
    local profileKey = rule and (rule.profileKey or rule.profileID) or nil
    local custom = rule and rule.custom or {}
    local editorX = options.editorX or 360
    local controlX = options.controlX or editorX
    local topY = options.topY or -62
    local fieldY = options.fieldY or -116
    local buttonY = options.buttonY or -220
    local errorY = options.errorY or -262
    local dropdownOffsetX = options.dropdownOffsetX or -10
    local secondColumnOffset = options.secondColumnOffset or 140

    self.mode = mode
    self.rule = rule

    AddChild(parent, CreateLabel(parent, options.ruleLabel or "Rule", controlX, topY, 80))
    self.modeDropdown = AddChild(parent, CreateModeDropdown(parent, controlX + dropdownOffsetX, topY - 16, mode, function(value)
        if self.enabled == false then
            return
        end
        if options.onModeChanged then
            options.onModeChanged(value)
        end
        if owner and options.errorKey then
            owner[options.errorKey] = nil
        end
        if owner and owner.RefreshPage then
            owner:RefreshPage(owner.currentPage)
        end
    end))

    if mode == "profile" then
        AddChild(parent, CreateLabel(parent, "Profile", controlX + secondColumnOffset, topY, 120))
        self.profileDropdown = AddChild(parent, CreateProfileDropdown(parent, controlX + secondColumnOffset + dropdownOffsetX, topY - 16, profileKey, function(value)
            if self.enabled == false then
                return
            end
            if options.onProfileChanged then
                options.onProfileChanged(value)
            end
            if owner and options.errorKey then
                owner[options.errorKey] = nil
            end
            if owner and owner.RefreshPage then
                owner:RefreshPage(owner.currentPage)
            end
        end))
        if options.showProfileFields then
            local profile = GetProfilesModule() and GetProfilesModule():GetProfile(profileKey)
            RenderRuleValueFields(parent, editorX, fieldY, profile or {}, true)
        end
    elseif mode == "custom" then
        self.customInputs = RenderRuleValueFields(parent, editorX, fieldY, custom or {}, false)
        self.durationDropdown = self.customInputs and self.customInputs.duration
    end

    if options.errorKey and owner then
        self.errorLabel = AddChild(parent, CreateLabel(parent, owner[options.errorKey] or "", editorX, errorY, 360, "GameFontRedSmall"))
    end

    self.saveConfirmLabel = AddChild(parent, CreateLabel(parent, "", editorX, buttonY - 24, 120, "GameFontGreenSmall"))
    local saveConfirmKey = self:GetSaveConfirmKey()
    self:SetSaveConfirmationVisible((owner and owner[saveConfirmKey]) or self[saveConfirmKey])

    self.saveButton = AddChild(parent, CreateButton(parent, "Save Rule", editorX, buttonY, 92, function()
        if self.enabled == false or not selectedKey then
            return
        end

        local values = custom
        if mode == "custom" and self.customInputs then
            local parsed, errorText = ValidateCustomRuleForm(self.customInputs)
            if errorText then
                self:SetError(errorText)
                return
            end
            values = PreserveLegacyMinProfitValues(rule and rule.custom, parsed)
        end

        local onSave = options.onSave or self.onSave
        if onSave then
            onSave(selectedKey, mode, profileKey, values, options.selectedRow)
        end
        self:SetError(nil)
        self:ShowSaveConfirmation()
        self:RefreshParent()
    end))

    self.deleteButton = AddChild(parent, CreateButton(parent, "Delete Rule", editorX + 100, buttonY, 92, function()
        if self.enabled == false or not selectedKey then
            return
        end
        local onDelete = options.onDelete or self.onDelete or self.onClear
        if onDelete then
            onDelete(selectedKey)
        end
        self:SetError(nil)
        self:RefreshParent()
    end))

    self:ApplyEnabled()
end
