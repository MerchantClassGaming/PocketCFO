-- PocketCFO_Crafting/Statistics/CraftStatLog.lua
-- Records aggregate proc stats for craft attempts.
-- Called by PocketCFO_Crafting/Crafting/CraftEventCapture.lua; does not register craft events.
-- Writes to PocketCFO.db.global.craftStatLog[craftKey].

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local CraftStatLog = PocketCFO_Crafting:NewModule("CraftStatLog")

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

local function SumResourcesReturned(resourcesReturned)
    if not resourcesReturned then return 0 end
    local total = 0
    for _, entry in ipairs(resourcesReturned) do
        total = total + (entry.quantity or 0)
    end
    return total
end

local function AddResourcesReturnedByItem(target, resourcesReturned)
    if not resourcesReturned then return end
    for _, entry in ipairs(resourcesReturned) do
        local reagent = entry.reagent
        local itemID = reagent and reagent.itemID
        local quantity = entry.quantity or 0
        if itemID and quantity > 0 then
            local key = tostring(itemID)
            target[key] = (target[key] or 0) + quantity
        end
    end
end

local function GetOutputItemID(result)
    if result.hyperlink and GetItemInfoFromHyperlink then
        local itemID = GetItemInfoFromHyperlink(result.hyperlink)
        if itemID then return itemID end
    end
    return result.itemID
end

local function RoundToNearest(value, increment)
    if value == nil then return nil end
    value = tonumber(value)
    if value == nil then return nil end
    increment = increment or 1
    return math.floor((value / increment) + 0.5) * increment
end

local function NormalizeCraftStats(skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct)
    return RoundToNearest(skillAtCraft, 1),
        RoundToNearest(resourcefulnessPct, 0.1),
        RoundToNearest(multicraftPct, 0.1),
        RoundToNearest(ingenuityPct, 0.1)
end

local function KeyPart(value, fmt)
    if value == nil then return "nil" end
    if fmt then return string.format(fmt, value) end
    return tostring(value)
end

local function BuildCraftKey(characterGUID, recipeID, outputItemID, outputCraftQuality, skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct)
    return KeyPart(characterGUID)
        .. ":" .. KeyPart(recipeID)
        .. ":" .. tostring(outputItemID or "nil")
        .. ":" .. tostring(outputCraftQuality or "nil")
        .. ":" .. KeyPart(skillAtCraft, "%.0f")
        .. ":" .. KeyPart(resourcefulnessPct, "%.1f")
        .. ":" .. KeyPart(multicraftPct, "%.1f")
        .. ":" .. KeyPart(ingenuityPct, "%.1f")
end

local function GetCharacterInfo()
    local guid = UnitGUID and UnitGUID("player") or nil
    if not guid and PocketCFO and PocketCFO.db and PocketCFO.db.char then
        guid = PocketCFO.db.char.characterGUID
    end

    local name = UnitName and UnitName("player") or nil
    local realm = GetRealmName and GetRealmName() or nil
    local displayName = nil

    if name and realm and realm ~= "" then
        displayName = name .. "-" .. realm
    elseif name and name ~= "" then
        displayName = name
    else
        displayName = guid
    end

    return guid, name, realm, displayName
end

local function GetTotalRequiredMats(recipeID)
    if not recipeID or not C_TradeSkillUI or not C_TradeSkillUI.GetRecipeSchematic then
        return 0
    end

    local schematic = C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
    local totalRequiredMats = 0
    if schematic and schematic.reagentSlotSchematics then
        for _, slot in ipairs(schematic.reagentSlotSchematics) do
            if slot.reagentType == 1 then
                totalRequiredMats = totalRequiredMats + (slot.quantityRequired or 0)
            end
        end
    end
    return totalRequiredMats
end

local function GetOperationStats(recipeID)
    if not recipeID or not C_TradeSkillUI or not C_TradeSkillUI.GetCraftingOperationInfo then
        return nil, nil, nil, nil
    end

    local opInfo = C_TradeSkillUI.GetCraftingOperationInfo(recipeID, {}, nil, false)
    if not opInfo then return nil, nil, nil, nil end

    local skillAtCraft = (opInfo.baseSkill or 0) + (opInfo.bonusSkill or 0)
    local resourcefulnessPct, multicraftPct, ingenuityPct = nil, nil, nil
    if opInfo.bonusStats then
        for _, stat in ipairs(opInfo.bonusStats) do
            if stat.bonusStatName == "Resourcefulness" then
                resourcefulnessPct = stat.ratingPct
            elseif stat.bonusStatName == "Multicraft" then
                multicraftPct = stat.ratingPct
            elseif stat.bonusStatName == "Ingenuity" then
                ingenuityPct = stat.ratingPct
            end
        end
    end

    return skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct
end

-- ---------------------------------------------------------------------------
-- Public API - called by CraftEventCapture / OperationObservationBuilder
-- ---------------------------------------------------------------------------

-- Exposes the existing skill/proc-rate extraction so OperationObservationBuilder
-- can reuse it instead of re-deriving crafting stats from C_TradeSkillUI itself.
function CraftStatLog:GetOperationStats(recipeID)
    return GetOperationStats(recipeID)
end

function CraftStatLog:LogCraft(result, recipeID)
    SessionLog("CraftStatLog: write attempted recipeID=%s", tostring(recipeID))

    if not result or type(result) ~= "table" then
        SessionLog("CraftStatLog: write skipped reason=result-not-table")
        return
    end
    if not PocketCFO or not PocketCFO.db or not PocketCFO.db.global then
        SessionLog("CraftStatLog: write skipped reason=core-db-unavailable recipeID=%s", tostring(recipeID))
        return
    end

    PocketCFO.db.global.craftStatLog = PocketCFO.db.global.craftStatLog or {}
    local store = PocketCFO.db.global.craftStatLog

    local outputItemID = GetOutputItemID(result)
    local outputCraftQuality = result.craftingQuality
    local characterGUID, characterName, characterRealm, characterDisplayName = GetCharacterInfo()
    local skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct = GetOperationStats(recipeID)
    skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct = NormalizeCraftStats(
        skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct)
    local craftKey = BuildCraftKey(characterGUID, recipeID, outputItemID, outputCraftQuality,
        skillAtCraft, resourcefulnessPct, multicraftPct, ingenuityPct)
    local now = GetServerTime and GetServerTime() or time()

    local totalQuantity = result.quantity or 1
    local multicraftExtra = result.multicraft or 0
    local baseQuantity = totalQuantity - multicraftExtra
    if baseQuantity < 0 then baseQuantity = 0 end

    local didMulticraft = multicraftExtra > 0
    local didResourcefulness = result.resourcesReturned ~= nil
    local didIngenuity = result.hasIngenuityProc == true
    local resourcesReturnedTotal = SumResourcesReturned(result.resourcesReturned)
    local ingenuityRefund = didIngenuity and (result.ingenuityRefund or 0) or 0
    local totalRequiredMats = GetTotalRequiredMats(recipeID)

    local row = store[craftKey]
    if not row then
        row = {
            craftKey = craftKey,
            recipeID = recipeID,
            outputItemID = outputItemID,
            outputCraftQuality = outputCraftQuality,
            firstSeenAt = now,
            lastSeenAt = now,
            craftCount = 0,
            baseQuantityTotal = 0,
            totalQuantityTotal = 0,
            multicraftProcCount = 0,
            multicraftExtraTotal = 0,
            resourcefulnessProcCount = 0,
            resourcesReturnedTotal = 0,
            resourcesReturnedByItemID = {},
            totalRequiredMats = 0,
            totalRequiredMatsTotal = 0,
            ingenuityProcCount = 0,
            concentrationSpentTotal = 0,
            ingenuityRefundTotal = 0,
            lastSkillAtCraft = nil,
            lastResourcefulnessPct = nil,
            lastMulticraftPct = nil,
            lastIngenuityPct = nil,
            lastHyperlink = nil,
            characterGUID = characterGUID,
            characterName = characterName,
            characterRealm = characterRealm,
            characterDisplayName = characterDisplayName,
        }
        store[craftKey] = row
    end

    row.recipeID = recipeID
    row.outputItemID = outputItemID
    row.outputCraftQuality = outputCraftQuality
    row.lastSeenAt = now
    row.craftCount = (row.craftCount or 0) + 1
    row.baseQuantityTotal = (row.baseQuantityTotal or 0) + baseQuantity
    row.totalQuantityTotal = (row.totalQuantityTotal or 0) + totalQuantity
    row.multicraftExtraTotal = (row.multicraftExtraTotal or 0) + multicraftExtra
    row.totalRequiredMats = (row.totalRequiredMats or 0) + totalRequiredMats
    row.totalRequiredMatsTotal = (row.totalRequiredMatsTotal or 0) + totalRequiredMats
    row.concentrationSpentTotal = (row.concentrationSpentTotal or 0) + (result.concentrationSpent or 0)
    row.lastSkillAtCraft = skillAtCraft
    row.lastResourcefulnessPct = resourcefulnessPct
    row.lastMulticraftPct = multicraftPct
    row.lastIngenuityPct = ingenuityPct
    row.lastHyperlink = result.hyperlink
    row.characterGUID = row.characterGUID or characterGUID
    row.characterName = row.characterName or characterName
    row.characterRealm = row.characterRealm or characterRealm
    row.characterDisplayName = row.characterDisplayName or characterDisplayName

    if didMulticraft then
        row.multicraftProcCount = (row.multicraftProcCount or 0) + 1
    end
    if didResourcefulness then
        row.resourcefulnessProcCount = (row.resourcefulnessProcCount or 0) + 1
        row.resourcesReturnedTotal = (row.resourcesReturnedTotal or 0) + resourcesReturnedTotal
        row.resourcesReturnedByItemID = row.resourcesReturnedByItemID or {}
        AddResourcesReturnedByItem(row.resourcesReturnedByItemID, result.resourcesReturned)
    end
    if didIngenuity then
        row.ingenuityProcCount = (row.ingenuityProcCount or 0) + 1
        row.ingenuityRefundTotal = (row.ingenuityRefundTotal or 0) + ingenuityRefund
    end

    SessionLog("CraftStatLog: wrote craftKey=%s character=%s recipeID=%s outputItemID=%s stats=skill:%s/rf:%s/mc:%s/ing:%s craftCount=%s",
        tostring(craftKey), tostring(characterDisplayName), tostring(recipeID), tostring(outputItemID),
        tostring(skillAtCraft), tostring(resourcefulnessPct), tostring(multicraftPct), tostring(ingenuityPct),
        tostring(row.craftCount))
end

-- ---------------------------------------------------------------------------
-- Debug UI
-- ---------------------------------------------------------------------------

local craftStatFrame = nil
local ALL_CHARACTERS = "__ALL__"
local RebuildCraftStatUI

local function SafePct(numerator, denominator)
    if not denominator or denominator == 0 then return 0 end
    return (numerator or 0) / denominator * 100
end

local function SafeRatio(numerator, denominator)
    if not denominator or denominator == 0 then return 0 end
    return (numerator or 0) / denominator
end

local function DisplayStat(value, suffix)
    if value == nil then return "--" end
    if suffix then return string.format("%.1f%s", value, suffix) end
    return tostring(value)
end

local function GetRecordCharacterDisplayName(record)
    return record.characterDisplayName
        or record.characterName
        or record.characterGUID
        or "(unknown)"
end

local function GetRecordItemText(record)
    if record.lastHyperlink then return record.lastHyperlink end
    if record.outputItemID and GetItemInfo then
        local itemName, itemLink = GetItemInfo(record.outputItemID)
        if itemLink then return itemLink end
        if itemName then return itemName end
    end
    if record.outputItemID then return "Item " .. tostring(record.outputItemID) end
    return "(unknown item)"
end

local function GetRequiredMatsTotal(record)
    return record.totalRequiredMatsTotal or record.totalRequiredMats or 0
end

local function CollectRecords(selectedCharacter)
    if not PocketCFO or not PocketCFO.db or not PocketCFO.db.global then
        return {}, {}
    end

    local allRecords = PocketCFO.db.global.craftStatLog or {}
    local records = {}
    local seenCharacters = {}
    local characters = {}

    for _, record in pairs(allRecords) do
        if type(record) == "table" and record.craftKey then
            local characterDisplay = GetRecordCharacterDisplayName(record)
            if not seenCharacters[characterDisplay] then
                seenCharacters[characterDisplay] = true
                characters[#characters + 1] = characterDisplay
            end
            if selectedCharacter == ALL_CHARACTERS or selectedCharacter == nil or characterDisplay == selectedCharacter then
                records[#records + 1] = record
            end
        end
    end

    table.sort(characters, function(a, b) return tostring(a) < tostring(b) end)
    table.sort(records, function(a, b)
        return (a.lastSeenAt or 0) > (b.lastSeenAt or 0)
    end)

    return records, characters
end

local function RefreshCharacterDropdown(f, characters)
    if not f.characterDropdown or not UIDropDownMenu_SetText then return end

    local selected = f.selectedCharacter or ALL_CHARACTERS
    if selected ~= ALL_CHARACTERS then
        local found = false
        for _, character in ipairs(characters) do
            if character == selected then
                found = true
                break
            end
        end
        if not found then
            selected = ALL_CHARACTERS
            f.selectedCharacter = ALL_CHARACTERS
        end
    end

    UIDropDownMenu_SetText(f.characterDropdown, selected == ALL_CHARACTERS and "All Characters" or selected)
end

local function BuildCraftStatFrame()
    local f = CreateFrame("Frame", "MCG_CraftStatLogFrame", UIParent, "BackdropTemplate")
    f:SetSize(980, 700)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetFrameLevel(100)
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop",  f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile   = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets   = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
    f:SetBackdropBorderColor(0.6, 0.6, 0.2, 1)

    table.insert(UISpecialFrames, f:GetName())

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -8)
    title:SetText("CraftStatLog Debug Aggregates")
    title:SetTextColor(1, 0.8, 0.2)

    local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", f, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function() f:Hide() end)

    f.selectedCharacter = ALL_CHARACTERS
    f.characterDropdown = CreateFrame("Frame", "MCG_CraftStatLogCharacterDropdown", f, "UIDropDownMenuTemplate")
    f.characterDropdown:SetPoint("TOPLEFT", f, "TOPLEFT", -6, -26)
    UIDropDownMenu_SetWidth(f.characterDropdown, 220)
    UIDropDownMenu_SetText(f.characterDropdown, "All Characters")
    UIDropDownMenu_Initialize(f.characterDropdown, function(dropdown, level)
        local info = UIDropDownMenu_CreateInfo()
        info.text = "All Characters"
        info.value = ALL_CHARACTERS
        info.checked = f.selectedCharacter == ALL_CHARACTERS
        info.func = function()
            f.selectedCharacter = ALL_CHARACTERS
            RebuildCraftStatUI(f)
        end
        UIDropDownMenu_AddButton(info, level)

        local _, characters = CollectRecords(ALL_CHARACTERS)
        for _, character in ipairs(characters) do
            info = UIDropDownMenu_CreateInfo()
            info.text = character
            info.value = character
            info.checked = f.selectedCharacter == character
            info.func = function(self)
                f.selectedCharacter = self.value
                RebuildCraftStatUI(f)
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    f.summaryLine1 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.summaryLine1:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -64)
    f.summaryLine1:SetText("Crafts: 0")

    f.summaryLine2 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.summaryLine2:SetPoint("TOPLEFT", f.summaryLine1, "BOTTOMLEFT", 0, -4)
    f.summaryLine2:SetText("")

    f.summaryLine3 = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.summaryLine3:SetPoint("TOPLEFT", f.summaryLine2, "BOTTOMLEFT", 0, -4)
    f.summaryLine3:SetText("")

    f.divider = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.divider:SetPoint("TOPLEFT", f.summaryLine3, "BOTTOMLEFT", 0, -6)
    f.divider:SetText("--------------------------------------------------------------------------")
    f.divider:SetTextColor(0.35, 0.35, 0.35, 1)

    f.scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    f.scrollFrame:SetPoint("TOPLEFT",     f.divider,  "BOTTOMLEFT",  0,  -4)
    f.scrollFrame:SetPoint("BOTTOMRIGHT", f,          "BOTTOMRIGHT", -26, 6)
    f.content = nil

    f:Hide()
    return f
end

RebuildCraftStatUI = function(f)
    local records, characters = CollectRecords(f.selectedCharacter or ALL_CHARACTERS)
    RefreshCharacterDropdown(f, characters)

    local totalCrafts = 0
    local rfCount, mcCount, ingCount = 0, 0, 0
    local totalQuantity, baseQuantity = 0, 0
    local rfMatNumerator, rfMatDenominator = 0, 0

    for _, record in ipairs(records) do
        local craftCount = record.craftCount or 0
        totalCrafts = totalCrafts + craftCount
        rfCount = rfCount + (record.resourcefulnessProcCount or 0)
        mcCount = mcCount + (record.multicraftProcCount or 0)
        ingCount = ingCount + (record.ingenuityProcCount or 0)
        totalQuantity = totalQuantity + (record.totalQuantityTotal or 0)
        baseQuantity = baseQuantity + (record.baseQuantityTotal or 0)
        rfMatNumerator = rfMatNumerator + (record.resourcesReturnedTotal or 0)
        rfMatDenominator = rfMatDenominator + GetRequiredMatsTotal(record)
    end

    if totalCrafts > 0 then
        local rfRate   = SafePct(rfCount, totalCrafts)
        local mcRate   = SafePct(mcCount, totalCrafts)
        local ingRate  = SafePct(ingCount, totalCrafts)
        local avgYield = SafeRatio(totalQuantity, baseQuantity)
        local pctMatsReturned = SafePct(rfMatNumerator, rfMatDenominator)

        f.summaryLine1:SetText(string.format("Crafts: %d  |  Aggregate Rows: %d", totalCrafts, #records))
        f.summaryLine2:SetText(string.format(
            "Observed RF Proc: %.1f%%  |  Observed MC Proc: %.1f%%  |  Observed ING Proc: %.1f%%",
            rfRate, mcRate, ingRate))
        f.summaryLine3:SetText(string.format(
            "Average Yield: %.2fx  |  Actual Mats Returned: %.1f%%",
            avgYield, pctMatsReturned))
    else
        f.summaryLine1:SetText("Crafts: 0  |  Aggregate Rows: 0")
        f.summaryLine2:SetText("Resourcefulness: --  |  Multicraft: --  |  Ingenuity: --")
        f.summaryLine3:SetText("Avg Yield: --  |  Mats Returned: --")
    end

    if f.content then
        f.content:Hide()
        f.content:SetParent(nil)
    end
    local content = CreateFrame("Frame", nil, f.scrollFrame)
    f.scrollFrame:SetScrollChild(content)
    f.content = content

    local ROW_HEIGHT   = 104
    local displayCount = #records
    content:SetSize(920, math.max(520, displayCount * ROW_HEIGHT + 10))

    if displayCount == 0 then
        local empty = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        empty:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -4)
        empty:SetText("(no aggregate craft records)")
        empty:SetTextColor(0.6, 0.6, 0.6, 1)
        return
    end

    for i = 1, displayCount do
        local record  = records[i]
        local craftCount = record.craftCount or 0
        local rfProcRate = SafePct(record.resourcefulnessProcCount or 0, craftCount)
        local matsReturnedPct = SafePct(record.resourcesReturnedTotal or 0, GetRequiredMatsTotal(record))
        local mcProcRate = SafePct(record.multicraftProcCount or 0, craftCount)
        local avgBaseCraft = SafeRatio(record.baseQuantityTotal or 0, craftCount)
        local avgMcExtraPerProc = SafeRatio(record.multicraftExtraTotal or 0, record.multicraftProcCount or 0)
        local avgTotalWhenMcProcs = avgBaseCraft + avgMcExtraPerProc
        local ingProcRate = SafePct(record.ingenuityProcCount or 0, craftCount)
        local avgIngRefundPerProc = SafeRatio(record.ingenuityRefundTotal or 0, record.ingenuityProcCount or 0)

        local y = -(i - 1) * ROW_HEIGHT - 4
        local header = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
        header:SetWidth(890)
        header:SetJustifyH("LEFT")
        header:SetText(string.format("%s  |  RecipeID: %s  |  Quality: %s  |  Crafts: %s  |  Last: %s",
            GetRecordItemText(record),
            tostring(record.recipeID or "?"),
            tostring(record.outputCraftQuality or "-"),
            tostring(craftCount),
            date("%Y-%m-%d %H:%M", record.lastSeenAt or 0)))
        header:SetTextColor(1, 0.9, 0.55, 1)

        local profile = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        profile:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -5)
        profile:SetText(string.format("STAT PROFILE: Skill %s  |  RF %s  |  MC %s  |  ING %s  |  Character: %s",
            DisplayStat(record.lastSkillAtCraft),
            DisplayStat(record.lastResourcefulnessPct, "%%"),
            DisplayStat(record.lastMulticraftPct, "%%"),
            DisplayStat(record.lastIngenuityPct, "%%"),
            GetRecordCharacterDisplayName(record)))
        profile:SetTextColor(0.82, 0.88, 1, 1)

        local rf = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        rf:SetPoint("TOPLEFT", profile, "BOTTOMLEFT", 0, -5)
        rf:SetText(string.format("RESOURCEFULNESS RESULTS: observed proc %.1f%%  |  actual mats returned %.1f%%",
            rfProcRate, matsReturnedPct))
        rf:SetTextColor(0.82, 1, 0.82, 1)

        local mc = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        mc:SetPoint("TOPLEFT", rf, "BOTTOMLEFT", 0, -5)
        mc:SetText(string.format("MULTICRAFT RESULTS: observed proc %.1f%%  |  avg base %.2f  |  avg MC extra/proc %.2f  |  avg total when MC procs %.2f",
            mcProcRate, avgBaseCraft, avgMcExtraPerProc, avgTotalWhenMcProcs))
        mc:SetTextColor(0.8, 0.95, 1, 1)

        local ing = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        ing:SetPoint("TOPLEFT", mc, "BOTTOMLEFT", 0, -5)
        ing:SetText(string.format("INGENUITY RESULTS: observed proc %.1f%%  |  avg refund/proc %.2f",
            ingProcRate, avgIngRefundPerProc))
        ing:SetTextColor(1, 0.82, 1, 1)
    end
end

function CraftStatLog:ShowDebugUI()
    if not craftStatFrame then craftStatFrame = BuildCraftStatFrame() end
    if craftStatFrame:IsShown() then
        craftStatFrame:Hide()
        return
    end
    RebuildCraftStatUI(craftStatFrame)
    craftStatFrame:Show()
    if craftStatFrame.Raise then craftStatFrame:Raise() end
end

-- ---------------------------------------------------------------------------
-- Module lifecycle
-- ---------------------------------------------------------------------------

function CraftStatLog:OnEnable()
    SLASH_MCGCL1 = "/mcgcl"
    SlashCmdList["MCGCL"] = function()
        CraftStatLog:ShowDebugUI()
    end
end

function CraftStatLog:OnDisable()
end
