-- PocketCFO_AH/Posting/UI/PostingProfileEditorUI.lua
-- Right-side posting profile form used by PostingProfileManagerUI.

local PocketCFO_AH = _G.PocketCFO_AH

local PostingProfileEditorUI = PocketCFO_AH:NewModule("PostingProfileEditorUI")

local DURATION_OPTIONS = { 12, 24, 48 }

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
    label:SetWidth(width or 120)
    label:SetJustifyH("LEFT")
    label:SetText(text or "")
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
    button:SetSize(width or 86, 22)
    button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function SetDropdownText(dropdown, text)
    if UIDropDownMenu_SetText then
        UIDropDownMenu_SetText(dropdown, text or "")
    end
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

local function CreateDurationDropdown(parent, x, y, selectedDuration)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    UIDropDownMenu_SetWidth(dropdown, 86)
    dropdown.selectedValue = FormatDurationValue(selectedDuration)
    UIDropDownMenu_Initialize(dropdown, function()
        for _, duration in ipairs(DURATION_OPTIONS) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = tostring(duration) .. "h"
            info.func = function()
                dropdown.selectedValue = duration
                SetDropdownText(dropdown, tostring(duration) .. "h")
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    SetDropdownText(dropdown, tostring(dropdown.selectedValue) .. "h")
    return dropdown
end

function PostingProfileEditorUI:Create(parentFrame, options)
    local editor = {
        parent = parentFrame,
        options = options or {},
    }
    setmetatable(editor, { __index = self })
    editor:Render()
    return editor
end

function PostingProfileEditorUI:GetProfiles()
    if self.options.getProfiles then
        return self.options.getProfiles() or {}
    end
    return {}
end

function PostingProfileEditorUI:GetProfile(selectedKey)
    if selectedKey and self.options.getProfile then
        return self.options.getProfile(selectedKey)
    end
    return nil
end

function PostingProfileEditorUI:SetError(errorText)
    if self.options.setError then
        self.options.setError(errorText)
    end
    if self.errorLabel then
        self.errorLabel:SetText(errorText or "")
    end
end

function PostingProfileEditorUI:RenderInputs(selectedKey)
    local inputs = {}
    local parent = self.parent
    local profile = self:GetProfile(selectedKey)
    local x = self.options.editorX or 282
    local y = self.options.rowY or -52

    AddChild(parent, CreateLabel(parent, "Profile Name", x, y, 220))
    inputs.name = AddChild(parent, CreateInput(parent, x, y - 14, 248))
    y = y - 46

    AddChild(parent, CreateLabel(parent, "Target Posted #", x, y, 120))
    inputs.targetPosted = AddChild(parent, CreateInput(parent, x, y - 14, 94))
    AddChild(parent, CreateLabel(parent, "Duration", x + 150, y, 100))
    inputs.duration = AddChild(parent, CreateDurationDropdown(parent, x + 140, y - 16, profile and profile.duration or 12))
    y = y - 46

    AddChild(parent, CreateLabel(parent, "Minimum Price", x, y, 120))
    inputs.minPrice = AddChild(parent, CreateInput(parent, x, y - 14, 120))
    AddChild(parent, CreateLabel(parent, "Max Price", x + 150, y, 100))
    inputs.maxPrice = AddChild(parent, CreateInput(parent, x + 150, y - 14, 120))

    if profile then
        inputs.name:SetText(profile.name ~= nil and tostring(profile.name) or "")
        inputs.targetPosted:SetText(profile.targetPosted ~= nil and tostring(profile.targetPosted) or "")
        inputs.minPrice:SetText(FormatCopperString(profile.minPrice))
        inputs.maxPrice:SetText(FormatCopperString(profile.maxPrice))
    end

    self.inputs = inputs
    return inputs
end

function PostingProfileEditorUI:Validate(inputs, selectedKey)
    local values = {}
    values.name = Trim(inputs.name and inputs.name:GetText())
    if values.name == "" then
        return nil, "Name is required."
    end

    local normalizedName = values.name:lower()
    for _, row in ipairs(self:GetProfiles()) do
        local rowKey = row.profileID or row.profileKey
        local rowName = Trim(row.name):lower()
        if rowName == normalizedName and rowKey ~= selectedKey then
            return nil, "Name must be unique."
        end
    end

    values.targetPosted = ParseWholeNumber(inputs.targetPosted and inputs.targetPosted:GetText())
    if not values.targetPosted or values.targetPosted <= 0 then
        return nil, "Target Posted # must be a whole number greater than 0."
    end

    local duration = FormatDurationValue(inputs.duration and inputs.duration.selectedValue or 12)
    if not IsDurationValid(duration) then
        return nil, "Duration must be 12h, 24h, or 48h."
    end
    values.duration = duration

    for _, field in ipairs({ "minPrice", "maxPrice" }) do
        local text = Trim(inputs[field] and inputs[field]:GetText())
        if text ~= "" then
            local copper = ParseGoldString(text)
            if copper == nil then
                local labels = {
                    minPrice = "Minimum Price",
                    maxPrice = "Max Price",
                }
                return nil, labels[field] .. " must use a valid gold format, such as 140g25s10c."
            end
            values[field] = copper
        end
    end

    return values, nil
end

function PostingProfileEditorUI:Render()
    local parent = self.parent
    local options = self.options
    local selectedKey = options.selectedKey
    local x = options.editorX or 282
    local buttonY = options.buttonY or -238
    local errorY = options.errorY or -212

    AddChild(parent, CreateLabel(parent, selectedKey and ("Editing: " .. tostring(selectedKey)) or "New profile", x, -28, 240, "GameFontNormalSmall"))
    local inputs = self:RenderInputs(selectedKey)
    self.errorLabel = AddChild(parent, CreateLabel(parent, options.errorText or "", x, errorY, 330, "GameFontRedSmall"))

    AddChild(parent, CreateButton(parent, "Save", x, buttonY, 86, function()
        local profile, errorText = self:Validate(inputs, selectedKey)
        if errorText then
            self:SetError(errorText)
            return
        end
        if options.onSave then
            options.onSave(profile)
        end
    end))

    local deleteButton = AddChild(parent, CreateButton(parent, "Delete", x + 96, buttonY, 74, function()
        self:SetError(nil)
        if options.onDelete then
            options.onDelete()
        end
    end))
    if not selectedKey then
        deleteButton:Disable()
    end
end
