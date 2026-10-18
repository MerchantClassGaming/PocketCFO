-- PocketCFO_Crafting/UI/PostingRules/RecipePostingRulesWindow.lua
-- Recipe-book posting rule editor window. UI only; identity and rule storage are delegated.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local RecipePostingRulesWindow = PocketCFO_Crafting:NewModule("RecipePostingRulesWindow", "AceEvent-3.0")

local FRAME_WIDTH = 350
local FRAME_HEIGHT = 400
local FRAME_PADDING = 10
local COLOR_BG = { r = 0.05, g = 0.05, b = 0.08, a = 0.92 }

-- Must match PostingRuleEditor's default save-confirm key (PostingRuleEditor:GetSaveConfirmKey()).
-- Cleared on every fresh load so a "Rule Saved" banner from a previously
-- viewed recipe can never bleed into the next one.
local EDITOR_SAVE_CONFIRM_KEY = "__postingRuleEditorSaveConfirmToken"

local frame
local content
local editorHost

local function AddChild(parent, child)
    parent.children = parent.children or {}
    parent.children[#parent.children + 1] = child
    return child
end

local function ClearChildren(parent)
    for _, child in ipairs(parent.children or {}) do
        if child.Hide then child:Hide() end
        if child.SetParent then child:SetParent(nil) end
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
    label:SetWidth(width or 300)
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

local function SettingsDB()
    local db = PocketCFO_Crafting.db and PocketCFO_Crafting.db.global
    if not db then
        return {}
    end
    db.postingRulesWindow = db.postingRulesWindow or {}
    if db.postingRulesWindow.open == nil then
        db.postingRulesWindow.open = false
    end
    return db.postingRulesWindow
end

local function SafeMethod(object, methodName, ...)
    if not object or type(object[methodName]) ~= "function" then
        return nil
    end
    local ok, result = pcall(object[methodName], object, ...)
    if ok then
        return result
    end
    return nil
end

local function GetCurrentRecipeID()
    local contextService = PocketCFO_Crafting:GetModule("ProfessionContextService", true)
    if contextService and contextService.GetCurrentRecipeID then
        return contextService:GetCurrentRecipeID()
    end
    local sf = ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm
    local transaction = sf and sf.GetTransaction and sf:GetTransaction()
    return transaction and transaction.GetRecipeID and transaction:GetRecipeID() or nil
end

local function GetSchematicForm()
    return ProfessionsFrame and ProfessionsFrame.CraftingPage and ProfessionsFrame.CraftingPage.SchematicForm or nil
end

local function GetRuleStore()
    local ah = SafeLoadAH()
    return ah and ah.GetModule and ah:GetModule("PostingRuleRepository", true) or nil
end

local function GetEditorModule()
    local ah = SafeLoadAH()
    return ah and ah.GetModule and ah:GetModule("PostingRuleEditor", true) or nil
end

local function GetRecipeInfo(recipeID, sf)
    return SafeMethod(sf, "GetRecipeInfo")
        or (C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo and C_TradeSkillUI.GetRecipeInfo(recipeID) or nil)
end

local function GetSchematic(recipeID)
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
        local ok, schematicInfo = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if ok then
            return schematicInfo
        end
    end
    return nil
end

function RecipePostingRulesWindow:ResolveCurrentOutput()
    local recipeID = tonumber(GetCurrentRecipeID())
    if not recipeID or not C_TradeSkillUI then
        return nil, "Select a recipe to manage its posting rule."
    end

    local sf = GetSchematicForm()
    local recipeInfo = GetRecipeInfo(recipeID, sf)
    local schematicInfo = GetSchematic(recipeID)
    local optionResolver = PocketCFO_Crafting:GetModule("RecipeOptionResolver", true)
    local optionEvidence = optionResolver and optionResolver:Resolve(recipeID, sf, schematicInfo) or {}

    local capture = PocketCFO_Crafting:GetModule("RecipeStateCapture", true)
    local config = capture and capture.CaptureCurrentDraft and capture:CaptureCurrentDraft() or nil
    local identity = config and config.outputIdentity or nil
    if not identity or identity.unresolved then
        return nil, "Current recipe output identity is unavailable."
    end

    local selectedVariant = optionEvidence.selectedMissiveOption
    local statLabel = optionEvidence.selectedMissiveStatLabel
    if not selectedVariant and self.selectedVariantManual then
        selectedVariant = self.selectedVariant
    end
    if selectedVariant and selectedVariant.statTarget then
        statLabel = selectedVariant.label
    end

    local key = identity.configKey or config.configKey or identity.itemKey
    return {
        key = tostring(key or recipeID),
        legacyKey = tostring(recipeID),
        recipeID = recipeID,
        recipeName = recipeInfo and recipeInfo.name or identity.itemName or ("Recipe " .. recipeID),
        identity = identity,
        variants = optionEvidence.missiveOptions or {},
        selectedVariant = selectedVariant,
        hasSelectableVariants = #(optionEvidence.missiveOptions or {}) > 0,
        needsVariant = false,
        statLabel = statLabel,
        optionEvidence = optionEvidence,
    }
end

function RecipePostingRulesWindow:ResolveCurrentRecipePostingTarget()
    return self:ResolveCurrentOutput()
end

function RecipePostingRulesWindow:ClearRenderedPostingRule()
    if content then
        ClearChildren(content)
    end
    editorHost = nil
    self.currentEditor = nil
    self.currentResolvedTarget = nil
    self.currentRule = nil
    self.currentRuleStorageKey = nil
    self.currentTargetSignature = nil
    self.currentRuleKey = nil
end

function RecipePostingRulesWindow:DrawCurrentRecipePostingRule()
    if not frame or not frame:IsShown() then
        return
    end

    self:ClearRenderedPostingRule()

    if not SafeLoadAH() then
        AddChild(content, CreateLabel(content, "PocketCFO AH could not be loaded.", 8, -10, 310, "GameFontRedSmall"))
        return
    end

    local editorModule = GetEditorModule()
    if not editorModule then
        AddChild(content, CreateLabel(content, "PostingRuleEditor is unavailable.", 8, -10, 310, "GameFontRedSmall"))
        return
    end

    local ruleStore = GetRuleStore()
    if not ruleStore then
        AddChild(content, CreateLabel(content, "PostingRuleRepository is unavailable.", 8, -10, 310, "GameFontRedSmall"))
        return
    end

    local resolved, errorText = self:ResolveCurrentOutput()
    if not resolved then
        AddChild(content, CreateLabel(content, errorText, 8, -10, 310))
        return
    end

    local rule, storageKey = ruleStore:GetRecipeRule(resolved)
    resolved.storageKey = storageKey
    rule = rule or {}
    local editorEnabled = not resolved.needsVariant
    self.currentResolvedTarget = resolved
    self.currentRule = rule
    self.currentRuleStorageKey = storageKey

    AddChild(content, CreateLabel(content, resolved.recipeName, 8, -8, 310, "GameFontNormal"))
    AddChild(content, CreateLabel(content, resolved.identity.itemName or "Unknown output", 8, -26, 310, "GameFontHighlightSmall"))

    local detail = {}
    local ilvl = resolved.identity.effectiveItemLevel or resolved.identity.effectiveIlvl or resolved.identity.itemLevel or resolved.identity.ilvl
    if ilvl then
        detail[#detail + 1] = "ilvl " .. tostring(ilvl)
    end
    if resolved.identity.craftingQuality then
        detail[#detail + 1] = "Q" .. tostring(resolved.identity.craftingQuality)
    end
    AddChild(content, CreateLabel(content, table.concat(detail, "  "), 8, -44, 310, "GameFontDisableSmall"))

    local hasOutputVariant = resolved.statLabel ~= nil and tostring(resolved.statLabel) ~= ""
    if hasOutputVariant then
        AddChild(content, CreateLabel(content, "Output Variant: " .. tostring(resolved.statLabel), 8, -66, 310))
    end

    editorHost = AddChild(content, CreateFrame("Frame", nil, content))
    editorHost:SetPoint("TOPLEFT", content, "TOPLEFT", 0, hasOutputVariant and -88 or -58)
    editorHost:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)

    self.currentEditor = editorModule:Create(editorHost, {
        owner = self,
        selectedKey = editorEnabled and resolved.key or nil,
        selectedRow = resolved.identity,
        rule = rule,
        ruleLabel = "Rule",
        editorX = 8,
        controlX = 8,
        topY = -8,
        fieldY = -62,
        buttonY = -196,
        errorY = -228,
        dropdownOffsetX = -10,
        secondColumnOffset = 135,
        showProfileFields = true,
        enabled = editorEnabled,
        errorKey = "editorError",
        onModeChanged = function(value)
            ruleStore:SaveRecipeRule(resolved, value, rule.profileKey or rule.profileID, rule.custom)
            self.editorError = nil
            self:LoadCurrentRecipePostingRule()
        end,
        onProfileChanged = function(value)
            ruleStore:SaveRecipeRule(resolved, "profile", value, nil)
            self.editorError = nil
            self:LoadCurrentRecipePostingRule()
        end,
        onSave = function(_, mode, profileKey, values)
            ruleStore:SaveRecipeRule(resolved, mode, profileKey, values)
        end,
        onDelete = function()
            ruleStore:DeleteRecipeRule(resolved)
        end,
    })
end

function RecipePostingRulesWindow:Render()
    self:LoadCurrentRecipePostingRule()
end

-- Canonical entry point for loading and displaying the posting rule for the
-- current recipe. Both "Show Posting Rules" and recipe-change events must
-- call this exact function so there is only one rule-loading path. Every
-- caller gets the same full lifecycle: stale per-instance UI state from
-- whatever recipe was previously displayed is reset here, once, so no
-- caller can forget to clear it and leave it to leak into the next draw.
function RecipePostingRulesWindow:LoadCurrentRecipePostingRule()
    if not frame or not frame:IsShown() then
        return
    end

    self.selectedVariant = nil
    self.selectedVariantManual = false
    self.editorError = nil
    self[EDITOR_SAVE_CONFIRM_KEY] = nil
    self:ClearRenderedPostingRule()

    -- Defer to next tick so LoadAddOn("PocketCFO_AH") inside SafeLoadAH
    -- doesn't block the crafting window open/refresh path.
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if RecipePostingRulesWindow:IsOpen() then
                RecipePostingRulesWindow:DrawCurrentRecipePostingRule()
            end
        end)
    else
        self:DrawCurrentRecipePostingRule()
    end
end

local function BuildFrame()
    if frame then
        return
    end

    frame = CreateFrame("Frame", "MCGCFORecipePostingRulesFrame", UIParent, "BackdropTemplate")
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
            PocketCFO.db.char.recipePostingRulesPosition = { x = x, y = y }
        end
    end)
    frame:SetClampedToScreen(true)
    frame:Hide()

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -8)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
    title:SetJustifyH("LEFT")
    title:SetText("Recipe Posting Rules")

    local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
    closeBtn:SetScript("OnClick", function()
        RecipePostingRulesWindow:Hide()
    end)

    content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", FRAME_PADDING, -34)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -FRAME_PADDING, FRAME_PADDING)

end

function RecipePostingRulesWindow:Position(anchorFrame)
    if not frame then
        return
    end

    local saved = PocketCFO and PocketCFO.db and PocketCFO.db.char and PocketCFO.db.char.recipePostingRulesPosition
    frame:ClearAllPoints()
    if saved and saved.x and saved.y then
        frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved.x, saved.y)
    elseif anchorFrame then
        frame:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", 4, 0)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 360, 0)
    end
end

function RecipePostingRulesWindow:Show(anchorFrame)
    BuildFrame()
    SettingsDB().open = true
    if not frame:IsShown() then
        self:Position(anchorFrame)
    end
    if PocketCFO_Crafting.HelperWindow then
        PocketCFO_Crafting.HelperWindow:ShowOrRaise(frame)
    else
        frame:Show()
    end
    self:LoadCurrentRecipePostingRule()
    self:SendMessage("MCGCFO_POSTING_RULES_WINDOW_CHANGED", true)
end

function RecipePostingRulesWindow:Hide()
    SettingsDB().open = false
    self.selectedVariant = nil
    self.selectedVariantManual = false
    -- Bounds how long a config-restore-in-progress guard can possibly persist:
    -- even if PCFO_CONFIG_LOADED_INTO_CRAFTING_WINDOW never arrives for some
    -- aborted restore, closing/reopening the window always clears it.
    self.configRestoreInProgress = false
    if frame then
        frame:Hide()
    end
    self:SendMessage("MCGCFO_POSTING_RULES_WINDOW_CHANGED", false)
end

function RecipePostingRulesWindow:CloseForTradeSkillClose()
    self.selectedVariant = nil
    self.selectedVariantManual = false
    self.configRestoreInProgress = false
    if frame then
        frame:Hide()
    end
    self:SendMessage("MCGCFO_POSTING_RULES_WINDOW_CHANGED", false)
end

function RecipePostingRulesWindow:Toggle(anchorFrame)
    BuildFrame()
    if frame:IsShown() then
        self:Hide()
    else
        self:Show(anchorFrame)
    end
end

function RecipePostingRulesWindow:IsOpen()
    return frame and frame:IsShown() == true
end

function RecipePostingRulesWindow:ShouldAutoOpen()
    return SettingsDB().open == true
end

function RecipePostingRulesWindow:OnEnable()
    BuildFrame()
    -- PCFO_VIEWED_RECIPE_CHANGED is PocketCFO's high-level "recipe selection
    -- changed" signal. For an ordinary manual recipe-list click it fires once
    -- the selection is settled and is safe to reload from directly. Raw
    -- Blizzard trade skill events are not used here because they can fire
    -- before PocketCFO has finished restoring the selected recipe.
    --
    -- For an Inventory Manager config/row load, RecipeStateRestore sends
    -- PCFO_VIEWED_RECIPE_CHANGED on the very next tick after SelectRecipe,
    -- but optional/material slot restoration doesn't finish until ~0.1s
    -- later (see RecipeStateRestore:LoadConfigIntoCraftingWindow). Reading
    -- recipe state in that window produces an incomplete output identity, so
    -- PostingRuleRepository:GetRecipeRule(resolved) can't find the saved
    -- rule. PCFO_CONFIG_LOAD_STARTED_INTO_CRAFTING_WINDOW /
    -- PCFO_CONFIG_LOADED_INTO_CRAFTING_WINDOW bracket that restore window, so
    -- a reload triggered by PCFO_VIEWED_RECIPE_CHANGED while a config restore
    -- is in progress is deferred until PCFO_CONFIG_LOADED_INTO_CRAFTING_WINDOW
    -- fires instead.
    self:RegisterMessage("PCFO_VIEWED_RECIPE_CHANGED", "OnViewedRecipeChanged")
    self:RegisterMessage("PCFO_CONFIG_LOAD_STARTED_INTO_CRAFTING_WINDOW", "OnConfigRestoreStarted")
    self:RegisterMessage("PCFO_CONFIG_LOADED_INTO_CRAFTING_WINDOW", "OnConfigRestoreCompleted")
end

function RecipePostingRulesWindow:OnConfigRestoreStarted()
    self.configRestoreInProgress = true
end

function RecipePostingRulesWindow:OnConfigRestoreCompleted()
    self.configRestoreInProgress = false
    self:LoadCurrentRecipePostingRule()
end

function RecipePostingRulesWindow:OnViewedRecipeChanged()
    if self.configRestoreInProgress then
        -- A config/row load is restoring optional/material slots right now.
        -- PCFO_CONFIG_LOADED_INTO_CRAFTING_WINDOW will trigger the reload
        -- once that restore is actually complete.
        return
    end
    self:LoadCurrentRecipePostingRule()
end
