-- PocketCFO_AH/Posting/UI/PostingProfileManagerUI.lua
-- Full reusable posting profile management panel.

local PocketCFO_AH = _G.PocketCFO_AH

local PostingProfileManagerUI = PocketCFO_AH:NewModule("PostingProfileManagerUI")

local LIST_VISIBLE_ROWS = 12
local LIST_ROW_HEIGHT = 22

local function AddChild(parent, child)
    parent.children = parent.children or {}
    parent.children[#parent.children + 1] = child
    return child
end

local function CreateLabel(parent, text, x, y, width, font)
    local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    label:SetWidth(width or 120)
    label:SetJustifyH("LEFT")
    label:SetText(text or "")
    return label
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

local function CreateOwnerFilterDropdown(parent, x, y, selectedValue, options, onSelect)
    local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    UIDropDownMenu_SetWidth(dropdown, 126)
    UIDropDownMenu_Initialize(dropdown, function()
        for _, option in ipairs(options or {}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = tostring(option.label or option.value or "")
            info.func = function()
                if onSelect then
                    onSelect(option.value)
                end
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    local label = ""
    for _, option in ipairs(options or {}) do
        if tostring(option.value) == tostring(selectedValue) then
            label = tostring(option.label or option.value or "")
            break
        end
    end
    SetDropdownText(dropdown, label)
    return dropdown
end

local function GetVisibleListRows(listBox)
    local height = listBox and listBox.GetHeight and listBox:GetHeight() or 0
    if height <= 0 then
        return LIST_VISIBLE_ROWS
    end

    local available = height - 8
    if available <= 0 then
        return 1
    end
    return math.max(1, math.min(LIST_VISIBLE_ROWS, math.floor(available / LIST_ROW_HEIGHT)))
end

local function CreateListEmptyLabel(listBox, text)
    local label = listBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    label:SetPoint("TOPLEFT", listBox, "TOPLEFT", 8, -8)
    label:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -8, 8)
    label:SetJustifyH("CENTER")
    label:SetJustifyV("MIDDLE")
    label:SetText(text or "")
    return label
end

local function CreateListRow(parent, x, y, width, height)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(width, height)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    row:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.Text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.Text:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.Text:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.Text:SetJustifyH("LEFT")
    row.Text:SetText("")
    return row
end

local function ProfileKeyFromName(name, profilesDB)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then
        return nil
    end
    local key = name:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if key == "" then
        key = "profile"
    end

    local candidate = key
    local index = 2
    while profilesDB and profilesDB[candidate] do
        candidate = key .. "_" .. tostring(index)
        index = index + 1
    end
    return candidate
end

function PostingProfileManagerUI:Create(parentFrame, options)
    local manager = {
        parent = parentFrame,
        options = options or {},
        selectedKey = options and options.selectedKey or nil,
    }
    setmetatable(manager, { __index = self })
    manager:Render()
    return manager
end

function PostingProfileManagerUI:GetProfiles()
    if self.options.getProfiles then
        local rows = self.options.getProfiles() or {}
        if self.options.filterProfiles then
            return self.options.filterProfiles(rows) or rows
        end
        return rows
    end
    return {}
end

function PostingProfileManagerUI:GetProfile(profileKey)
    if profileKey and self.options.getProfile then
        return self.options.getProfile(profileKey)
    end
    return nil
end

function PostingProfileManagerUI:GetProfilesDB()
    if self.options.getProfilesDB then
        return self.options.getProfilesDB() or {}
    end
    return {}
end

function PostingProfileManagerUI:SetSelectedKey(profileKey)
    self.selectedKey = profileKey
    if self.options.onSelect then
        self.options.onSelect(profileKey)
    end
end

function PostingProfileManagerUI:SetError(errorText)
    self.errorText = errorText
    if self.options.onError then
        self.options.onError(errorText)
    end
end

function PostingProfileManagerUI:NotifyChanged()
    if self.options.onChanged then
        self.options.onChanged()
    end
end

function PostingProfileManagerUI:RefreshListRows()
    local list = self.profileList
    if not list then
        return
    end

    local rows = list.rows or {}
    local offset = FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(list.scrollFrame) or 0
    local visibleRows = GetVisibleListRows(list.listBox)
    if FauxScrollFrame_Update then
        FauxScrollFrame_Update(list.scrollFrame, #rows, visibleRows, LIST_ROW_HEIGHT)
    end

    for index, button in ipairs(list.buttons or {}) do
        if index > visibleRows then
            button:Hide()
        else
            local row = rows[offset + index]
            if row then
                local key = row.profileID or row.profileKey
                button.profileKey = key
                button.Text:SetText(tostring(row.name or key or ""))
                button:Enable()
                button:Show()
                if key == self.selectedKey then
                    button:SetBackdropColor(0.18, 0.24, 0.34, 0.95)
                else
                    button:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
                end
            else
                button.profileKey = nil
                button.Text:SetText("")
                button:Disable()
                button:SetBackdropColor(0.04, 0.04, 0.04, 0.45)
                button:Show()
            end
        end
    end
end

function PostingProfileManagerUI:RenderList()
    local parent = self.parent
    local rows = self:GetProfiles()
    local filterOptions = self.options.getOwnerFilterOptions and self.options.getOwnerFilterOptions() or nil
    local selectedFilter = self.options.getOwnerFilter and self.options.getOwnerFilter() or nil
    local listBoxWidth = self.options.listBoxWidth or 250
    local listRowWidth = self.options.listRowWidth or 222

    AddChild(parent, CreateLabel(parent, "Existing Profiles", 10, -12, 180, "GameFontNormal"))
    AddChild(parent, CreateButton(parent, "New", 10 + listBoxWidth - 64, -14, 64, function()
        self:SetSelectedKey(nil)
        self:SetError(nil)
        self:NotifyChanged()
    end))
    if filterOptions and #filterOptions > 0 then
        AddChild(parent, CreateOwnerFilterDropdown(parent, 128, self.options.filterY or -16, selectedFilter, filterOptions, function(value)
            if self.options.setOwnerFilter then
                self.options.setOwnerFilter(value)
            end
            self:SetSelectedKey(nil)
            self:SetError(nil)
            self:NotifyChanged()
        end))
    end
    local listBox = AddChild(parent, CreateFrame("Frame", nil, parent, "BackdropTemplate"))
    listBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -36)
    listBox:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", 10 + listBoxWidth, 16)
    listBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listBox:SetBackdropColor(0.025, 0.025, 0.025, 0.9)
    listBox:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.85)

    local buttons = {}
    for index = 1, LIST_VISIBLE_ROWS do
        local button = AddChild(parent, CreateListRow(listBox, 4, -4 - ((index - 1) * LIST_ROW_HEIGHT), listRowWidth, LIST_ROW_HEIGHT - 2))
        button:SetScript("OnClick", function(clicked)
            self:SetSelectedKey(clicked.profileKey)
            self:SetError(nil)
            self:NotifyChanged()
        end)
        buttons[index] = button
    end

    local scrollFrame = AddChild(parent, CreateFrame("ScrollFrame", nil, listBox, "FauxScrollFrameTemplate"))
    scrollFrame:SetPoint("TOPLEFT", listBox, "TOPLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -26, 4)
    scrollFrame:SetScript("OnVerticalScroll", function(frame, offset)
        if FauxScrollFrame_OnVerticalScroll then
            FauxScrollFrame_OnVerticalScroll(frame, offset, LIST_ROW_HEIGHT, function()
                self:RefreshListRows()
            end)
        end
    end)

    self.profileList = {
        rows = rows,
        buttons = buttons,
        scrollFrame = scrollFrame,
        listBox = listBox,
    }
    self:RefreshListRows()

    if #rows == 0 then
        AddChild(parent, CreateListEmptyLabel(listBox, "No posting profiles."))
    end
end

function PostingProfileManagerUI:RenderEditor()
    local editorModule = PocketCFO_AH:GetModule("PostingProfileEditorUI", true)
    if not editorModule or not editorModule.Create then
        AddChild(self.parent, CreateLabel(self.parent, "Posting profile editor unavailable.", 282, -28, 320, "GameFontRedSmall"))
        return
    end

    editorModule:Create(self.parent, {
        selectedKey = self.selectedKey,
        editorX = self.options.editorX,
        errorText = self.errorText or self.options.errorText,
        getProfiles = function()
            if self.options.getProfiles then
                return self.options.getProfiles() or {}
            end
            return self:GetProfiles()
        end,
        getProfile = function(profileKey)
            return self:GetProfile(profileKey)
        end,
        setError = function(errorText)
            self:SetError(errorText)
        end,
        onDelete = function()
            if self.selectedKey and self.options.onDelete then
                self.options.onDelete(self.selectedKey)
                self:SetSelectedKey(nil)
                self:SetError(nil)
                self:NotifyChanged()
            end
        end,
        onSave = function(profile)
            local key = self.selectedKey
            if not key then
                key = ProfileKeyFromName(profile.name, self:GetProfilesDB())
            end
            if key and self.options.onSave then
                self.options.onSave(key, profile)
                self:SetSelectedKey(key)
                self:SetError(nil)
                self:NotifyChanged()
            end
        end,
    })
end

function PostingProfileManagerUI:Render()
    self:RenderList()
    self:RenderEditor()
end
