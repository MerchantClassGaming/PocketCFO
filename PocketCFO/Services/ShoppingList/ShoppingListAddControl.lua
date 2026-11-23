-- PocketCFO/Services/ShoppingList/ShoppingListAddControl.lua
-- The "Add to list" control every analysis uses (design:
-- claude/Shopping_List_Design.md, step 4). Flavor: Both.
-- One implementation for recipe analysis (with a Make box), order analysis
-- and Crate analysis, so they all behave the same.
--
--   local control = PocketCFO.ShoppingList:CreateAddControl(parent, {
--       quantityBox = true,          -- "Make [ 1 ] Add to list"
--       buttonText = "Add to list",
--       buttonWidth = 86,
--   })
--   control:SetItems(items, source, resetKey)
--     items = { { itemID = n, qty = per-make amount }, ... }
--     resetKey: the Make box goes back to 1 when it changes (another recipe)
--   control.frame  -- position and show/hide it like any frame
--
-- Click: every item x the Make number (fractions round up) goes to
-- ShoppingList:Add. The button reads "Added" for 2s, or "You have it all"
-- when what you own already covers everything.

local PocketCFO = _G.PocketCFO
local ShoppingList = PocketCFO and PocketCFO.ShoppingList

local FEEDBACK_SECONDS = 2
local MAX_MAKE = 9999

local Control = {}
Control.__index = Control

function Control:GetMakeCount()
    if not self.box then
        return 1
    end
    local value = math.floor(tonumber(self.box:GetText()) or 1)
    if value < 1 then
        value = 1
    elseif value > MAX_MAKE then
        value = MAX_MAKE
    end
    return value
end

function Control:SetItems(items, source, resetKey)
    self.items = type(items) == "table" and items or {}
    self.source = source
    if self.box and resetKey ~= self.resetKey then
        self.box:SetText("1")
        self.box:ClearFocus()
    end
    self.resetKey = resetKey
    self.button:SetEnabled(#self.items > 0)
end

function Control:ShowFeedback(text)
    self.button:SetText(text)
    self.feedbackToken = (self.feedbackToken or 0) + 1
    local token = self.feedbackToken
    if C_Timer and C_Timer.After then
        C_Timer.After(FEEDBACK_SECONDS, function()
            if self.feedbackToken == token then
                self.button:SetText(self.buttonText)
            end
        end)
    end
end

function Control:Add()
    local list = PocketCFO and PocketCFO.ShoppingList
    if not list or not self.items or #self.items == 0 then
        return
    end
    local makes = self:GetMakeCount()
    if self.box then
        self.box:SetText(tostring(makes))
        self.box:ClearFocus()
    end
    local added = 0
    for _, item in ipairs(self.items) do
        local qty = math.ceil((tonumber(item.qty) or 0) * makes - 0.000001)
        if item.itemID and qty > 0 then
            local result = list:Add(item.itemID, qty, self.source)
            added = added + (result and result.toBuy or 0)
        end
    end
    self:ShowFeedback(added > 0 and "Added" or "You have it all")
end

-- Builds the control inside `parent`. Returns the control table.
function ShoppingList:CreateAddControl(parent, options)
    options = type(options) == "table" and options or {}
    local control = setmetatable({}, Control)
    control.buttonText = options.buttonText or "Add to list"

    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(20)
    control.frame = frame

    local button = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    button:SetSize(options.buttonWidth or 86, 20)
    button:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
    button:SetText(control.buttonText)
    local fontString = button.GetFontString and button:GetFontString()
    if fontString and GameFontNormalSmall then
        fontString:SetFontObject(GameFontNormalSmall)
    end
    button:SetScript("OnClick", function()
        control:Add()
    end)
    control.button = button

    local width = button:GetWidth()
    if options.quantityBox then
        local box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
        box:SetSize(36, 18)
        box:SetPoint("RIGHT", button, "LEFT", -6, 0)
        box:SetAutoFocus(false)
        box:SetNumeric(true)
        box:SetMaxLetters(4)
        box:SetJustifyH("CENTER")
        box:SetFontObject("GameFontHighlightSmall")
        box:SetText("1")
        box:SetScript("OnEnterPressed", function(editBox)
            editBox:ClearFocus()
        end)
        box:SetScript("OnEscapePressed", function(editBox)
            editBox:ClearFocus()
        end)
        control.box = box

        local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        label:SetPoint("RIGHT", box, "LEFT", -6, 0)
        label:SetText("Make")
        control.label = label
        width = width + 6 + 36 + 6 + 30
    end
    frame:SetWidth(width)
    control.items = {}
    return control
end
