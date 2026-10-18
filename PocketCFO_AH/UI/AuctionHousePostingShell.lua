-- PocketCFO_AH/UI/AuctionHousePostingShell.lua
-- Owns the Pocket CFO Blizzard Auction House tab and internal AH workflow UI.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local ADDON_NAME, _ = ...
local PocketCFO_AH = _G.PocketCFO_AH
local PocketCFO = _G.PocketCFO

local AHPostingUI = PocketCFO_AH:NewModule("AHPostingUI", "AceEvent-3.0")

local POCKETCFO_TAB_ID = "PocketCFO_AH"

local CONTENT_FRAME_NAMES = {
    "BuyFrame",
    "SellFrame",
    "AuctionsFrame",
    "CommoditiesSellFrame",
    "ItemSellFrame",
}

local AUCTIONATOR_FRAME_NAMES = {
    "AuctionatorShoppingFrame",
    "AuctionatorSellingFrame",
    "AuctionatorCancellingFrame",
    "AuctionatorConfigFrame",
}

local BLIZZARD_TAB_KEYS = {
    "BuyTab",
    "SellTab",
    "AuctionsTab",
}

local RECIPE_LIST_VISIBLE_ROWS = 12
local RECIPE_LIST_ROW_HEIGHT = 22
local NONCRAFTED_LIST_VISIBLE_ROWS = 12
local NONCRAFTED_LIST_ROW_HEIGHT = 22
local IGNORE_LIST_VISIBLE_ROWS = 12
local IGNORE_LIST_ROW_HEIGHT = 22
local OWNER_FILTER_ALL = "__all"

local PAGE_ORDER = {
    { key = "dashboard", title = "Dashboard", short = "Dashboard", frameKey = "DashboardPage" },
    { key = "post", title = "Post Auctions", short = "Post Auctions", frameKey = "PostAuctionsPage" },
    { key = "cancel", title = "Cancel Auctions", short = "Cancel Auctions", frameKey = "CancelAuctionsPage" },
    { key = "profiles", title = "Posting Profiles", short = "Posting Profiles", frameKey = "ProfilesPage" },
    { key = "recipes", title = "Recipe Rules", short = "Recipe Rules", frameKey = "RecipeRulesPage" },
    { key = "noncrafted", title = "Item Rules", short = "Item Rules", frameKey = "NonCraftedRulesPage" },
    { key = "ignore", title = "Ignore List", short = "Ignore List", frameKey = "IgnoreListPage" },
}

local PAGE_BY_KEY = {}
for _, page in ipairs(PAGE_ORDER) do
    PAGE_BY_KEY[page.key] = page
end

local PAGE_TAB_WIDTHS = {
    dashboard = 82,
    post = 100,
    cancel = 116,
    profiles = 124,
    recipes = 94,
    noncrafted = 88,
    ignore = 88,
}

local PAGE_DESCRIPTIONS = {
    recipes = "Review and manage posting profiles and custom rules assigned to crafted items. For detailed recipe configuration, use the profession recipe window.",
    noncrafted = "Configure auction posting rules for non-crafted items such as gathered materials, world drops, transmog, and other sellable inventory.",
}

local TAB_CREATION_RETRY_LIMIT = 20

local function SessionLog(msg, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. tostring(msg))
end

local function GetAuctionHouseFrame()
    return _G.AuctionHouseFrame
end

local function GetLibAHTab()
    if LibStub then
        return LibStub("LibAHTab-1-0", true)
    end
    return nil
end

local function SafeLoad(name)
    local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(name))
        or (IsAddOnLoaded and IsAddOnLoaded(name))
    if loaded then
        return true
    end

    local loadFn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if not loadFn then
        return false
    end

    local ok = loadFn(name)
    return ok and true or false
end

local function IsFrameInTree(frame, root)
    while frame do
        if frame == root then
            return true
        end
        frame = frame.GetParent and frame:GetParent() or nil
    end
    return false
end

local function GlobalDB()
    return PocketCFO_AH.db and PocketCFO_AH.db.global or {}
end

local function OwnerKey()
    return PocketCFO
        and PocketCFO.db
        and PocketCFO.db.char
        and PocketCFO.db.char.characterGUID
        or nil
end

local function OwnerName()
    if UnitFullName then
        local name, realm = UnitFullName("player")
        if name and realm and realm ~= "" then
            return name .. "-" .. realm
        end
        return name
    end
    if UnitName then
        return UnitName("player")
    end
    return nil
end

local function PostingSettings()
    local db = GlobalDB()
    db.postingSettings = db.postingSettings or {}
    db.postingSettings.ui = db.postingSettings.ui or {}
    return db.postingSettings
end

local function SelectedOwnerFilter(settingKey)
    local settings = PostingSettings()
    local currentOwner = OwnerKey()
    local selected = settings.ui[settingKey]
    if selected == nil or selected == "" then
        selected = currentOwner
        settings.ui[settingKey] = selected
    end
    return selected
end

local function SetSelectedOwnerFilter(settingKey, value)
    PostingSettings().ui[settingKey] = value or OwnerKey()
end

local function OwnerMatchesFilter(row, filterValue)
    if filterValue == OWNER_FILTER_ALL then
        return true
    end
    return tostring(row and row.owner or "") == tostring(filterValue or "")
end

local function BuildOwnerFilterOptions(rows)
    local options = {}
    local seen = {}
    local currentOwner = OwnerKey()
    local currentName = OwnerName()

    if currentOwner then
        options[#options + 1] = {
            value = currentOwner,
            label = currentName or "Current Character",
        }
        seen[tostring(currentOwner)] = true
    end

    options[#options + 1] = { value = OWNER_FILTER_ALL, label = "All" }

    for _, row in ipairs(rows or {}) do
        local owner = row and row.owner
        if owner and owner ~= "" and not seen[tostring(owner)] then
            options[#options + 1] = {
                value = owner,
                label = tostring(row.ownerName or owner),
            }
            seen[tostring(owner)] = true
        end
    end

    return options
end

local function GetProfilesModule()
    return PocketCFO_AH:GetModule("PostingProfileRepository", true)
end

local function GetPostingController()
    return PocketCFO_AH:GetModule("PostingController", true)
end

local function GetPostingUIModule()
    return PocketCFO_AH:GetModule("PostingUI", true)
end

local function GetCancelAuctionsUIModule()
    return PocketCFO_AH:GetModule("CancelAuctionsUI", true)
end

local function GetMatcherModule()
    return PocketCFO_AH:GetModule("CompetitionMatcher", true)
end

local function GetSnapshotsModule()
    return PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("Snapshots", true) or nil
end

local function GetBagRows()
    local snapshots = GetSnapshotsModule()
    if snapshots and snapshots.GetLocationSnapshot then
        return snapshots:GetLocationSnapshot(OwnerKey(), "bags") or {}
    end
    return {}
end

local function RefreshBagSnapshot()
    local scanner = PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("BagScanner", true)
    if scanner and scanner.ScanBags then
        scanner:ScanBags({ reason = "ah-posting-ui", mode = "normal" })
    end
end

local function BuildItemKey(row)
    local matcher = GetMatcherModule()
    if matcher and matcher.BuildKey then
        return matcher:BuildKey(row)
    end
    return row and row.itemID and tostring(row.itemID) or nil
end

local function GetItemIdentityAdapter()
    return PocketCFO and PocketCFO.ItemIdentityAdapter or _G.ItemIdentityAdapter
end

local function BuildRuleIdentityKey(rule, sourceKey, row)
    local adapter = GetItemIdentityAdapter()
    if adapter and adapter.FromRule then
        local ok, identity = pcall(adapter.FromRule, adapter, rule, sourceKey, row)
        if ok and type(identity) == "table" then
            local key = BuildItemKey(identity)
            if key then
                return key
            end
        end
    end

    if row then
        local key = BuildItemKey(row)
        if key then
            return key
        end
    end

    if type(rule) == "table" and rule.itemKey then
        return tostring(rule.itemKey)
    end
    return sourceKey and tostring(sourceKey) or nil
end

local function RemoveDuplicateNonCraftedRules(rules, keptKey, row, profileKey)
    if type(rules) ~= "table" or not keptKey then
        return 0
    end

    local targetKey = BuildRuleIdentityKey(nil, keptKey, row)
    if not targetKey then
        return 0
    end

    local removed = 0
    local keptKeyText = tostring(keptKey)
    for existingKey, existingRule in pairs(rules) do
        if tostring(existingKey) ~= keptKeyText and type(existingRule) == "table" then
            local existingIdentityKey = BuildRuleIdentityKey(existingRule, existingKey)
            if existingIdentityKey == targetKey then
                SessionLog("Item Rules: removed duplicate item rule itemName=%s itemID=%s removedKey=%s keptKey=%s oldProfile=%s newProfile=%s",
                    tostring((row and row.itemName) or existingRule.itemName),
                    tostring((row and row.itemID) or existingRule.itemID),
                    tostring(existingKey),
                    keptKeyText,
                    tostring(existingRule.profileKey or existingRule.profileID),
                    tostring(profileKey))
                rules[existingKey] = nil
                removed = removed + 1
            end
        end
    end
    return removed
end

local function ItemIgnoreDB()
    local db = GlobalDB()
    db.itemRuleIgnoreList = db.itemRuleIgnoreList or {}
    return db.itemRuleIgnoreList
end

local function IsItemIgnored(itemKey, itemID)
    local ignores = ItemIgnoreDB()
    if itemKey and ignores[tostring(itemKey)] then
        return true
    end
    if itemID then
        if ignores[tostring(itemID)] then
            return true
        end
        for _, row in pairs(ignores) do
            if type(row) == "table" and tonumber(row.itemID) == tonumber(itemID) then
                return true
            end
        end
    end
    return false
end

local function AddIgnoredItem(itemKey, row)
    if not itemKey or itemKey == "" then
        return nil, "missingItemKey"
    end
    local ignores = ItemIgnoreDB()
    ignores[tostring(itemKey)] = {
        itemKey = tostring(itemKey),
        itemID = tonumber(row and row.itemID),
        itemName = row and row.itemName,
        itemLink = row and row.itemLink,
        craftingQuality = row and (row.craftingQuality or row.itemQuality),
        itemLevel = row and (row.itemLevel or row.ilvl),
        statFingerprint = row and row.statFingerprint,
        owner = OwnerKey(),
        ownerName = OwnerName(),
        ignoredAt = GetServerTime and GetServerTime() or time(),
    }
    return ignores[tostring(itemKey)]
end

local function RemoveIgnoredItem(itemKey)
    if not itemKey or itemKey == "" then
        return false
    end
    ItemIgnoreDB()[tostring(itemKey)] = nil
    return true
end

local function GetLiveBagContainers()
    local containers = { BACKPACK_CONTAINER or 0 }
    for containerID = 1, (tonumber(NUM_BAG_SLOTS) or 4) do
        containers[#containers + 1] = containerID
    end
    containers[#containers + 1] = 5
    return containers
end

local function GetItemLinkFromLocation(itemLocation)
    if not itemLocation or not C_Item or not C_Item.GetItemLink then
        return nil
    end
    if itemLocation.IsValid and not itemLocation:IsValid() then
        return nil
    end
    local ok, itemLink = pcall(C_Item.GetItemLink, itemLocation)
    if ok then
        return itemLink
    end
    return nil
end

local function GetItemGUIDFromLocation(itemLocation)
    if not itemLocation or not C_Item or not C_Item.GetItemGUID then
        return nil
    end
    if itemLocation.IsValid and not itemLocation:IsValid() then
        return nil
    end
    local ok, itemGUID = pcall(C_Item.GetItemGUID, itemLocation)
    if ok and itemGUID and itemGUID ~= "" then
        return itemGUID
    end
    return nil
end

local function GetItemStatsFingerprint(itemLink)
    if not itemLink or not C_Item or not C_Item.GetItemStats then
        return nil, nil
    end

    local ok, stats = pcall(C_Item.GetItemStats, itemLink)
    if not ok or not stats then
        return nil, nil
    end

    local keys = {}
    for statKey in pairs(stats) do
        keys[#keys + 1] = statKey
    end
    if #keys == 0 then
        return stats, nil
    end
    table.sort(keys)
    return stats, table.concat(keys, "|")
end

local function GetLiveGameplayQualityTier(itemLink, itemID, itemLocation)
    local identityService = PocketCFO and (PocketCFO.ItemIdentityService or _G.ItemIdentityService) or _G.ItemIdentityService
    if not identityService then return nil end
    local identity
    if itemLocation then
        identity = identityService:Identify({
            evidenceType = "item",
            itemLocation = itemLocation,
            itemLink = itemLink,
            itemID = itemID,
        })
    elseif itemLink then
        identity = identityService:FromItemLink(itemLink)
    elseif itemID then
        identity = identityService:FromItemID(itemID)
    end
    local quality = identity and (identity.craftingQuality or identity.itemQuality)
    return quality ~= nil and tonumber(quality) or nil
end

local function RuleLabel(rule)
    if type(rule) ~= "table" then
        return "none"
    end
    local mode = tostring(rule.mode or "none")
    if mode == "profile" then
        return "profile:" .. tostring(rule.profileKey or rule.profileID or "")
    elseif mode == "custom" then
        return "custom"
    end
    return "none"
end

local function ProfileDisplayName(profileKey)
    local profiles = GetProfilesModule()
    local profile = profiles and profiles:GetProfile(profileKey)
    return profile and tostring(profile.name or profile.profileID or profile.profileKey or profileKey) or tostring(profileKey or "")
end

local function RuleSummary(rule)
    if type(rule) ~= "table" then
        return "None"
    end

    local mode = tostring(rule.mode or "none")
    if mode == "profile" then
        return ProfileDisplayName(rule.profileKey or rule.profileID or rule.profile)
    elseif mode == "custom" then
        return "Custom"
    end
    return "None"
end

local function GetRecipeConfig(recipeID)
    local crafting = _G.PocketCFO_Crafting
    local configs = crafting and crafting.db and crafting.db.global and crafting.db.global.recipeConfigurations
    recipeID = tonumber(recipeID)
    if not recipeID or type(configs) ~= "table" then
        return nil
    end

    for _, config in pairs(configs) do
        if tonumber(config and config.recipeID) == recipeID then
            return config
        end
    end
    return nil
end

local function GetRecipeOutputInfo(recipeID)
    recipeID = tonumber(recipeID)
    if not recipeID then
        return {}
    end

    local output = {}
    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeOutputItemData then
        local ok, outputData = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
        if ok and type(outputData) == "table" then
            output.itemID = tonumber(outputData.itemID)
            output.quantity = tonumber(outputData.quantity)
        end
    end

    if C_TradeSkillUI and C_TradeSkillUI.GetRecipeInfo then
        local ok, recipeInfo = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
        if ok and type(recipeInfo) == "table" then
            output.recipeName = recipeInfo.name
            output.itemLevel = tonumber(recipeInfo.itemLevel)
        end
    end

    if output.itemID and GetItemInfo then
        local itemName, itemLink, _, ilvl = GetItemInfo(output.itemID)
        output.itemName = itemName
        output.itemLink = itemLink
        output.itemLevel = tonumber(ilvl) or output.itemLevel
    end
    return output
end

-- Determines the matchingPath for a recipe rule at save time.
-- Checks for optional reagent slots (reagentType == 0 = missive/stat-selection slots).
-- Theoretical: GetRecipeSchematic reagentType detection follows the same pattern as
-- CraftEventCapture.lua; not independently verified for missive-eligibility detection.
local function ComputeRecipeMatchingPath(recipeID, config, output)
    if recipeID and C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic then
        local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if ok and type(schematic) == "table" and type(schematic.reagentSlotSchematics) == "table" then
            for _, slot in ipairs(schematic.reagentSlotSchematics) do
                if slot.reagentType == 0 then
                    return "itemID_ilvl_stat"
                end
            end
        end
    end

    local outputItemID = tonumber(output and output.itemID)
        or tonumber(config and config.targetItemID)
    if outputItemID and GetItemInfoInstant then
        local ok, _, _, _, _, itemClassID = pcall(GetItemInfoInstant, outputItemID)
        if ok and tonumber(itemClassID) then
            local classID = tonumber(itemClassID)
            -- 2=Weapon, 4=Armor, 19=Profession (includes tools, gear, and cooking tools)
            if classID == 2 or classID == 4 or classID == 19 then
                return "itemID_ilvl"
            end
        end
    end

    return "itemID"
end

local function ApplyRecipeOutputIdentity(rule, recipeID)
    if type(rule) ~= "table" then
        return rule
    end

    recipeID = tonumber(recipeID or rule.recipeID)
    if not recipeID then
        return rule
    end

    local config = GetRecipeConfig(recipeID)
    local output = GetRecipeOutputInfo(recipeID)
    local itemID = tonumber(rule.itemID or rule.outputItemID or rule.targetItemID)
        or tonumber(config and config.targetItemID)
        or tonumber(output and output.itemID)
    local itemName = rule.itemName or rule.outputItemName or rule.targetItemName
        or config and (config.outputItemName or config.targetItemName or config.itemName)
        or output and output.itemName
    local itemLink = rule.itemLink or rule.outputItemLink or output and output.itemLink
    local itemLevel = tonumber(rule.itemLevel or rule.ilvl)
        or tonumber(config and (config.targetIlvl or config.itemLevel or config.ilvl))
        or tonumber(output and output.itemLevel)
    local quality = tonumber(rule.craftingQuality or rule.qualityTier or rule.itemQuality or rule.quality)
        or tonumber(config and (config.targetQuality or config.craftingQuality or config.itemQuality))
        or tonumber(output and (output.craftingQuality or output.itemQuality or output.quality))

    if itemID then
        rule.itemID = rule.itemID or itemID
        rule.outputItemID = rule.outputItemID or itemID
        rule.targetItemID = rule.targetItemID or itemID
    end
    if itemName and itemName ~= "" then
        rule.itemName = rule.itemName or itemName
        rule.outputItemName = rule.outputItemName or itemName
        rule.targetItemName = rule.targetItemName or itemName
    end
    if itemLink and itemLink ~= "" then
        rule.itemLink = rule.itemLink or itemLink
        rule.outputItemLink = rule.outputItemLink or itemLink
    end
    if itemLevel then
        rule.itemLevel = rule.itemLevel or itemLevel
        rule.ilvl = rule.ilvl or itemLevel
    end
    if quality and quality > 0 then
        rule.craftingQuality = rule.craftingQuality or quality
        rule.itemQuality = rule.itemQuality or quality
        rule.qualityTier = rule.qualityTier or quality
    end

    if not rule.itemKey and itemID then
        local key = BuildItemKey({
            itemID = itemID,
            itemName = itemName,
            itemLink = itemLink,
            craftingQuality = quality,
            itemQuality = quality,
            qualityTier = quality,
            itemLevel = itemLevel,
            ilvl = itemLevel,
        })
        if key then
            rule.itemKey = key
        end
    end

    if not rule.matchingPath then
        rule.matchingPath = ComputeRecipeMatchingPath(recipeID, config, output)
    end

    return rule
end

local function GetPostingEligibilityService()
    return PocketCFO_AH:GetModule("PostingEligibilityService", true)
end

local function IsBagSlotAHPostable(containerID, slot, itemID)
    local svc = GetPostingEligibilityService()
    if svc then
        return svc:IsBagSlotAHPostable(containerID, slot, itemID)
    end
    return true
end

local function GetLiveBagPostableLookup()
    local lookup = {
        itemIDs = {},
        keys = {},
        inspected = false,
    }
    if not C_Container or not C_Container.GetContainerNumSlots or not C_Container.GetContainerItemInfo then
        return lookup
    end

    local maxBag = tonumber(_G.NUM_BAG_SLOTS) or 4
    for containerID = 0, maxBag do
        local okSlots, numSlots = pcall(C_Container.GetContainerNumSlots, containerID)
        if okSlots and numSlots and numSlots > 0 then
            lookup.inspected = true
            for slot = 1, numSlots do
                local okInfo, info = pcall(C_Container.GetContainerItemInfo, containerID, slot)
                local itemID = okInfo and info and tonumber(info.itemID) or nil
                if itemID and IsBagSlotAHPostable(containerID, slot, itemID) then
                    lookup.itemIDs[itemID] = true
                    local itemName, itemLink, _, ilvl = GetItemInfo(info.hyperlink or itemID)
                    local key = BuildItemKey({
                        itemID = itemID,
                        itemName = itemName or info.itemName,
                        itemLink = info.hyperlink or itemLink,
                        craftingQuality = info.quality,
                        itemQuality = info.quality,
                        itemLevel = ilvl,
                        ilvl = ilvl,
                    })
                    if key then
                        lookup.keys[key] = true
                    end
                end
            end
        end
    end
    return lookup
end

local function IsKnownRecipeOutputItem(itemID, itemName)
    itemID = tonumber(itemID)
    if not itemID and not itemName then
        return false
    end

    local core = _G.PocketCFO
    local registry = core and core.GetModule and core:GetModule("RecipeRegistry", true)
    if registry and registry.IsRecipeOutputItem then
        return registry:IsRecipeOutputItem(itemID, itemName)
    end

    return false
end

local function ItemVariantSuffix(row)
    local quality = row and (row.craftingQuality or row.itemQuality or row.quality)
    quality = tonumber(quality)
    if quality and quality > 0 then
        return " Q" .. tostring(quality)
    end
    return ""
end

local function ItemDisplayName(row)
    if type(row) ~= "table" then
        return ""
    end
    local name = row.itemName
    if (not name or name == "") and row.itemID then
        name = "Item " .. tostring(row.itemID)
    end
    return tostring(name or "") .. ItemVariantSuffix(row)
end

local function RecipeVariantSuffix(rule, config, output)
    local quality = rule and (rule.craftingQuality or rule.itemQuality or rule.quality)
        or config and (config.targetQuality or config.craftingQuality or config.itemQuality)
        or output and output.craftingQuality
    local ilvl = rule and (rule.itemLevel or rule.ilvl)
        or config and (config.targetIlvl or config.itemLevel or config.ilvl)
        or output and output.itemLevel
    local stat = rule and (rule.statTarget or rule.statFingerprint)
        or config and (config.statTarget or config.statFingerprint)

    if quality ~= nil then
        return " Q" .. tostring(quality)
    elseif ilvl ~= nil then
        return " ilvl " .. tostring(ilvl)
    elseif stat ~= nil and tostring(stat) ~= "" then
        return " " .. tostring(stat)
    end
    return ""
end

local function RecipeDisplayName(recipeID, rule, includeVariant)
    local config = GetRecipeConfig(recipeID)
    local output = GetRecipeOutputInfo(recipeID)
    local itemID = tonumber(rule and (rule.itemID or rule.outputItemID or rule.targetItemID))
        or tonumber(config and config.targetItemID)
        or tonumber(output and output.itemID)
    local name = rule and (rule.itemName or rule.outputItemName or rule.targetItemName)
        or config and (config.outputItemName or config.targetItemName or config.itemName)

    if not name and itemID and GetItemInfo then
        name = GetItemInfo(itemID)
    end
    name = name or output.itemName or output.recipeName or config and (config.recipeName or config.name)
    if name and name ~= "" then
        return tostring(name) .. (includeVariant and RecipeVariantSuffix(rule, config, output) or "")
    end
    return "Recipe " .. tostring(recipeID)
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

local function ClearChildren(frame)
    if not frame.children then
        return
    end
    for _, child in ipairs(frame.children) do
        child:Hide()
        child:SetParent(nil)
    end
    frame.children = {}
end

local function AddChild(frame, child)
    frame.children = frame.children or {}
    frame.children[#frame.children + 1] = child
    return child
end

local function GetVisibleListRows(listBox, maxRows, rowHeight, topInset, bottomInset)
    local height = listBox and listBox.GetHeight and listBox:GetHeight() or 0
    if height <= 0 then
        return maxRows
    end

    local available = height - (topInset or 0) - (bottomInset or 0)
    if available <= 0 then
        return 1
    end
    return math.max(1, math.min(maxRows, math.floor(available / rowHeight)))
end

local function CreateListEmptyLabel(listBox, text, topInset)
    local label = listBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    label:SetPoint("TOPLEFT", listBox, "TOPLEFT", 8, -(topInset or 8))
    label:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -8, 8)
    label:SetJustifyH("CENTER")
    label:SetJustifyV("MIDDLE")
    label:SetText(text or "")
    return label
end

function AHPostingUI:SetPocketCFOTabSelected(selected)
    if not self.tabButton then
        return
    end
    if self.tabButton.SetChecked then
        self.tabButton:SetChecked(selected and true or false)
    end
    if selected then
        if PanelTemplates_SelectTab then
            pcall(PanelTemplates_SelectTab, self.tabButton)
        end
    else
        if PanelTemplates_DeselectTab then
            pcall(PanelTemplates_DeselectTab, self.tabButton)
        end
    end
end

function AHPostingUI:ClearKnownAHSelectedTabs()
    local frame = GetAuctionHouseFrame()
    if frame and frame.Tabs and PanelTemplates_DeselectTab then
        for _, tab in ipairs(frame.Tabs) do
            if tab and tab ~= self.tabButton then
                pcall(PanelTemplates_DeselectTab, tab)
            end
        end
    end

    if frame and PanelTemplates_DeselectTab then
        for _, key in ipairs(BLIZZARD_TAB_KEYS) do
            local tab = frame[key]
            if tab and tab ~= self.tabButton then
                pcall(PanelTemplates_DeselectTab, tab)
            end
        end
    end

    local lib = GetLibAHTab()
    local tabs = lib and lib.internalState and lib.internalState.Tabs
    if tabs and PanelTemplates_DeselectTab then
        for _, tab in ipairs(tabs) do
            if tab and tab ~= self.tabButton then
                pcall(PanelTemplates_DeselectTab, tab)
            end
        end
    end
end

function AHPostingUI:HideContentFrame(frame)
    if not frame or frame == self.content then
        return
    end
    if self.content and IsFrameInTree(frame, self.content) then
        return
    end
    if frame.Hide and frame.IsShown and frame:IsShown() then
        frame:Hide()
    end
end

function AHPostingUI:HideOtherAHContent()
    local frame = GetAuctionHouseFrame()
    if not frame then
        return
    end
    if frame.SetDisplayMode then
        pcall(frame.SetDisplayMode, frame, {})
        frame.displayMode = nil
    end
    for _, key in ipairs(CONTENT_FRAME_NAMES) do
        self:HideContentFrame(frame[key] or _G["AuctionHouseFrame" .. key])
    end
    for _, name in ipairs(AUCTIONATOR_FRAME_NAMES) do
        self:HideContentFrame(_G[name])
    end
end

function AHPostingUI:MaybeHideForOtherTab(button)
    if not self.active or button == self.tabButton then
        return
    end
    if self.content and button and button.IsDescendantOf and button:IsDescendantOf(self.content) then
        return
    end
    self:HidePocketCFOContent()
end

function AHPostingUI:HookOtherButton(button)
    if not button or button == self.tabButton or self.hookedButtons[button] then
        return
    end
    if self.content and button.IsDescendantOf and button:IsDescendantOf(self.content) then
        return
    end
    if button.HookScript then
        self.hookedButtons[button] = true
        button:HookScript("OnClick", function(clicked)
            self:MaybeHideForOtherTab(clicked)
        end)
    end
end

function AHPostingUI:HookAuctionHouseButtons(root)
    if not root or not root.GetChildren then
        return
    end
    for _, child in ipairs({ root:GetChildren() }) do
        if child ~= self.content and child.GetObjectType and child:GetObjectType() == "Button" then
            self:HookOtherButton(child)
        end
        if child ~= self.content and child.GetChildren then
            self:HookAuctionHouseButtons(child)
        end
    end
end

function AHPostingUI:HookAuctionatorFrames()
    self.hookedAuctionatorFrames = self.hookedAuctionatorFrames or {}
    for _, name in ipairs(AUCTIONATOR_FRAME_NAMES) do
        local frame = _G[name]
        if frame and frame.HookScript and not self.hookedAuctionatorFrames[frame] then
            self.hookedAuctionatorFrames[frame] = true
            frame:HookScript("OnShow", function()
                self:HidePocketCFOContent()
            end)
        end
    end
end

function AHPostingUI:EnsureAuctionHouseTab()
    local frame = GetAuctionHouseFrame()
    if not frame then
        return nil
    end

    if self.tabButton and self.content then
        self:SetPocketCFOTabSelected(self.active)
        self:HookAuctionHouseButtons(frame)
        self:HookAuctionatorFrames()
        return self.content
    end

    self.hookedButtons = self.hookedButtons or {}

    local content = CreateFrame("Frame", "PocketCFOAHAuctionHouseContent", frame, "BackdropTemplate")
    content:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -64)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 38)
    content:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    content:SetBackdropColor(0.02, 0.02, 0.02, 0.96)
    content:Hide()
    self.content = content

    local lib = GetLibAHTab()
    if lib and not lib:DoesIDExist(POCKETCFO_TAB_ID) then
        lib:CreateTab(POCKETCFO_TAB_ID, content, "Pocket CFO", "Pocket CFO")
        self.tabButton = lib:GetButton(POCKETCFO_TAB_ID)
        if self.tabButton then
            self.tabButton:HookScript("OnClick", function()
                self:ShowPocketCFOContent()
            end)
        end
    elseif lib and lib:DoesIDExist(POCKETCFO_TAB_ID) then
        self.tabButton = lib:GetButton(POCKETCFO_TAB_ID)
        if self.tabButton and self.tabButton.HookScript and not self.libTabHooked then
            self.libTabHooked = true
            self.tabButton:HookScript("OnClick", function()
                self:ShowPocketCFOContent()
            end)
        end
    else
        local tab = CreateFrame("Button", "PocketCFOAHAuctionHouseTab", frame, "PanelTabButtonTemplate")
        tab:SetSize(132, 34)
        tab:SetHitRectInsets(0, 0, 0, 0)
        tab:SetText("Pocket CFO")
        if tab.Text then
            tab.Text:ClearAllPoints()
            tab.Text:SetPoint("CENTER", tab, "CENTER", 0, -2)
        end
        tab:SetScript("OnClick", function()
            self:ShowPocketCFOContent()
        end)

        local anchor = frame.AuctionsTab or frame.SellTab or frame.BuyTab
        if anchor then
            tab:SetPoint("LEFT", anchor, "RIGHT", 12, 0)
        elseif frame.Tabs and frame.Tabs[#frame.Tabs] then
            tab:SetPoint("LEFT", frame.Tabs[#frame.Tabs], "RIGHT", 12, 0)
        else
            tab:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 260, 2)
        end
        self.tabButton = tab
    end

    self:SetPocketCFOTabSelected(false)
    self:HookAuctionHouseButtons(frame)
    self:HookAuctionatorFrames()
    self:EnsureShell()
    return content
end

function AHPostingUI:ScheduleEnsureAuctionHouseTab(reason)
    if self:EnsureAuctionHouseTab() then
        self.tabCreationAttempts = 0
        SessionLog("AHPostingUI tab ensured reason=%s", tostring(reason or "direct"))
        return true
    end

    self.tabCreationAttempts = (tonumber(self.tabCreationAttempts) or 0) + 1
    if self.tabCreationAttempts > TAB_CREATION_RETRY_LIMIT then
        SessionLog("AHPostingUI tab ensure failed reason=%s attempts=%d auctionHouseFrame=%s",
            tostring(reason or "unknown"), tonumber(self.tabCreationAttempts) or 0, tostring(GetAuctionHouseFrame() ~= nil))
        return false
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0.1, function()
            self:ScheduleEnsureAuctionHouseTab(reason or "retry")
        end)
    end
    return false
end

function AHPostingUI:RefreshPostAuctionsOnOpen(reason)
    if not AuctionHouseFrame or not AuctionHouseFrame.IsShown or not AuctionHouseFrame:IsShown() then
        return
    end

    local postingUI = GetPostingUIModule()
    if postingUI and postingUI.RefreshFromAuctionHouseOpen then
        postingUI:RefreshFromAuctionHouseOpen()
        SessionLog("AHPostingUI refreshed Post Auctions on AH open reason=%s source=PostingUI",
            tostring(reason or "unknown"))
        return
    end

    RefreshBagSnapshot()
    local controller = GetPostingController()
    if controller and controller.Refresh then
        controller:Refresh()
        SessionLog("AHPostingUI refreshed Post Auctions on AH open reason=%s source=controller",
            tostring(reason or "unknown"))
    else
        SessionLog("AHPostingUI Post Auctions open refresh skipped reason=controller-unavailable")
    end
end

function AHPostingUI:SchedulePostAuctionsOpenRefresh(reason)
    self.postAuctionsOpenRefreshToken = (tonumber(self.postAuctionsOpenRefreshToken) or 0) + 1
    local token = self.postAuctionsOpenRefreshToken
    local function run()
        if token == self.postAuctionsOpenRefreshToken then
            self.postAuctionsOpenRefreshToken = nil
            self:RefreshPostAuctionsOnOpen(reason)
        end
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0, run)
        C_Timer.After(0.5, run)
    else
        run()
    end
end

function AHPostingUI:EnsureShell()
    local content = self.content or self:EnsureAuctionHouseTab()
    if not content then
        return nil
    end
    if self.mainFrame and self.mainFrame:GetParent() == content then
        return self.mainFrame
    end

    local main = CreateFrame("Frame", "PocketCFOAHMainFrame", content)
    main:SetAllPoints(content)

    local header = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    header:SetPoint("TOPLEFT", main, "TOPLEFT", 16, -14)
    header:SetJustifyH("LEFT")
    header:SetText("Post Auctions")
    main.HeaderLabel = header

    local description = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    description:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    description:SetWidth(700)
    description:SetJustifyH("LEFT")
    if description.SetWordWrap then
        description:SetWordWrap(true)
    end
    description:SetText("")
    description:Hide()
    main.HeaderDescriptionLabel = description

    local panel = CreateFrame("Frame", "PocketCFOAHActiveContentPanel", main)
    panel:SetPoint("TOPLEFT", main, "TOPLEFT", 12, -44)
    panel:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -12, 42)
    main.ActiveContentPanel = panel

    main.InternalTabs = {}
    local tabX = 12
    for _, page in ipairs(PAGE_ORDER) do
        local tabWidth = PAGE_TAB_WIDTHS[page.key] or 98
        local tabStep = tabWidth + 6
        local tab = CreateButton(main, page.short, tabX, 30, tabWidth, function()
            self:SelectPage(page.key)
        end)
        tab:ClearAllPoints()
        tab:SetPoint("BOTTOMLEFT", main, "BOTTOMLEFT", tabX, 10)
        main.InternalTabs[page.key] = tab
        tabX = tabX + tabStep

        local pageFrame = CreateFrame("Frame", "PocketCFOAH" .. page.frameKey, panel)
        pageFrame:SetAllPoints(panel)
        pageFrame:Hide()
        main[page.frameKey] = pageFrame
    end

    self.mainFrame = main
    self.pagesRendered = {}
    self:ApplyBetaPageVisibility()
    SessionLog("AHPostingUI EnsureShell created pages=lazy")
    return main
end

-- Auction House beta toggle (PocketCFO/Infrastructure/BetaFeatures.lua).
-- With it off, only the Dashboard (pricing/scan) page is reachable, so the
-- whole page-tab row is hidden - a lone Dashboard tab would just be clutter.
local function IsAuctionHouseBetaEnabled()
    local beta = PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("BetaFeatures", true)
    return beta ~= nil and beta:IsAuctionHouseEnabled() == true
end

function AHPostingUI:IsPageAllowed(pageKey)
    return pageKey == "dashboard" or IsAuctionHouseBetaEnabled()
end

function AHPostingUI:ApplyBetaPageVisibility()
    local main = self.mainFrame
    if not main or not main.InternalTabs then
        return
    end
    local showTabs = IsAuctionHouseBetaEnabled()
    for _, tab in pairs(main.InternalTabs) do
        tab:SetShown(showTabs)
    end
end

function AHPostingUI:OnSettingsChanged()
    self:ApplyBetaPageVisibility()
    if self.currentPage and not self:IsPageAllowed(self.currentPage) and self.mainFrame and self.mainFrame:IsShown() then
        self:SelectPage("dashboard")
    end
end

function AHPostingUI:GetValuationPricingModule()
    if not SafeLoad("PocketCFO_Valuation") then
        return nil
    end
    local valuation = _G.PocketCFO_Valuation
    return valuation and valuation.GetModule and valuation:GetModule("AHTab", true) or nil
end

function AHPostingUI:EmbedPricingSection()
    local main = self.mainFrame
    if not main or not main.DashboardPage or not self.pricingMount then
        return
    end
    local pricing = self:GetValuationPricingModule()
    if pricing and pricing.EmbedPricingSection then
        pricing:EmbedPricingSection(self.pricingMount)
    else
        if not self.pricingUnavailableText then
            self.pricingUnavailableText = self.pricingMount:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            self.pricingUnavailableText:SetPoint("TOPLEFT", self.pricingMount, "TOPLEFT", 0, 0)
            self.pricingUnavailableText:SetText("Pricing module unavailable.")
        end
    end
end

function AHPostingUI:RenderAllPages()
    local main = self.mainFrame
    if not main then
        return
    end
    if not self.pagesRendered.dashboard then
        self:RenderDashboard(main.DashboardPage)
        self.pagesRendered.dashboard = true
    end
    if not self.pagesRendered.profiles then
        self:RenderProfiles(main.ProfilesPage)
        self.pagesRendered.profiles = true
    end
    if not self.pagesRendered.cancel then
        self:RenderCancelAuctions(main.CancelAuctionsPage)
        self.pagesRendered.cancel = true
    end
    if not self.pagesRendered.recipes then
        self:RenderRecipes(main.RecipeRulesPage)
        self.pagesRendered.recipes = true
    end
    if not self.pagesRendered.noncrafted then
        self:RenderNonCrafted(main.NonCraftedRulesPage)
        self.pagesRendered.noncrafted = true
    end
    if not self.pagesRendered.ignore then
        self:RenderIgnoreList(main.IgnoreListPage)
        self.pagesRendered.ignore = true
    end
end

function AHPostingUI:RefreshPage(pageKey)
    local main = self.mainFrame
    if not main then
        return
    end
    local page = PAGE_BY_KEY[pageKey]
    local frame = page and main[page.frameKey]
    if not frame then
        return
    end
    local isFirstRender = not (self.pagesRendered and self.pagesRendered[pageKey])
    ClearChildren(frame)
    if pageKey == "dashboard" then
        self:RenderDashboard(frame)
    elseif pageKey == "profiles" then
        self:RenderProfiles(frame)
    elseif pageKey == "recipes" then
        self:RenderRecipes(frame)
    elseif pageKey == "noncrafted" then
        self:RenderNonCrafted(frame)
    elseif pageKey == "ignore" then
        self:RenderIgnoreList(frame)
    elseif pageKey == "post" then
        self:RenderPostAuctions(frame)
    elseif pageKey == "cancel" then
        self:RenderCancelAuctions(frame)
    end
    if isFirstRender then
        SessionLog("AHPostingUI lazy render page=%s", tostring(pageKey))
    end
    self.pagesRendered[pageKey] = true
end

function AHPostingUI:RefreshPostAuctionsPage()
    self:RefreshPage("post")
end

function AHPostingUI:RefreshSelectedPage(pageKey)
    if pageKey == "post" then
        local postingUI = GetPostingUIModule()
        if postingUI and postingUI.RefreshQueue then
            postingUI:RefreshQueue("post-page-activated")
        end
    elseif pageKey == "cancel" then
        local cancelUI = GetCancelAuctionsUIModule()
        if cancelUI and cancelUI.RefreshQueue then
            cancelUI:RefreshQueue("cancel-page-activated")
        end
    elseif pageKey == "dashboard" then
        self:EmbedPricingSection()
    else
        self:RefreshPage(pageKey)
    end
end

function AHPostingUI:SelectPage(pageKey)
    local main = self:EnsureShell()
    local page = PAGE_BY_KEY[pageKey] or PAGE_BY_KEY.post
    if page and not self:IsPageAllowed(page.key) then
        page = PAGE_BY_KEY.dashboard
    end
    if not main or not page then
        return
    end

    if page.key ~= "post" then
        local controller = GetPostingController()
        if controller and controller.InvalidateEvaluation then
            controller:InvalidateEvaluation("page-left")
        end
    end

    self.currentPage = page.key
    main.HeaderLabel:SetText(page.title)
    local description = PAGE_DESCRIPTIONS[page.key]
    if main.HeaderDescriptionLabel then
        main.HeaderDescriptionLabel:SetText(description or "")
        if description then
            main.HeaderDescriptionLabel:Show()
        else
            main.HeaderDescriptionLabel:Hide()
        end
    end
    if main.ActiveContentPanel then
        main.ActiveContentPanel:ClearAllPoints()
        main.ActiveContentPanel:SetPoint("TOPLEFT", main, "TOPLEFT", 12, description and -62 or -44)
        main.ActiveContentPanel:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -12, 42)
    end

    for _, candidate in ipairs(PAGE_ORDER) do
        local frame = main[candidate.frameKey]
        if frame then
            if candidate.key == page.key then
                frame:Show()
            else
                frame:Hide()
            end
        end

        local tab = main.InternalTabs[candidate.key]
        if tab then
            if candidate.key == page.key then
                tab:Disable()
                if tab.Left and tab.Middle and tab.Right then
                    tab.Left:SetVertexColor(1, 0.82, 0)
                    tab.Middle:SetVertexColor(1, 0.82, 0)
                    tab.Right:SetVertexColor(1, 0.82, 0)
                end
            else
                tab:Enable()
                if tab.Left and tab.Middle and tab.Right then
                    tab.Left:SetVertexColor(1, 1, 1)
                    tab.Middle:SetVertexColor(1, 1, 1)
                    tab.Right:SetVertexColor(1, 1, 1)
                end
            end
        end
    end
    if page.key == "dashboard" then
        self:EmbedPricingSection()
    end
    if self.pagesRendered and not self.pagesRendered[page.key] then
        self:RefreshPage(page.key)
    elseif self.pagesRendered and self.pagesRendered[page.key] then
        self:RefreshSelectedPage(page.key)
    end
end

function AHPostingUI:RenderDashboard(parent)
    AddChild(parent, CreateLabel(parent, "Pricing", 16, -12, 200, "GameFontNormal"))
    local mount = CreateFrame("Frame", nil, parent)
    mount:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -40)
    mount:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -16, 16)
    AddChild(parent, mount)
    self.pricingMount = mount
    self:EmbedPricingSection()
end

function AHPostingUI:RenderProfiles(parent)
    local selectedKey = self.selectedProfileKey
    local profiles = GetProfilesModule()
    local allRows = profiles and profiles:GetDebugRows() or {}
    local selectedFilter = SelectedOwnerFilter("profileOwnerFilter")

    local managerModule = PocketCFO_AH:GetModule("PostingProfileManagerUI", true)
    if not managerModule or not managerModule.Create then
        AddChild(parent, CreateLabel(parent, "Posting profile manager unavailable.", 10, -12, 320, "GameFontRedSmall"))
        return
    end

    managerModule:Create(parent, {
        selectedKey = selectedKey,
        editorX = 414,
        listBoxWidth = 374,
        listRowWidth = 346,
        filterY = 2,
        errorText = self.profileErrorText,
        getProfiles = function()
            return allRows
        end,
        filterProfiles = function(rows)
            local filtered = {}
            for _, row in ipairs(rows or {}) do
                if OwnerMatchesFilter(row, selectedFilter) then
                    filtered[#filtered + 1] = row
                end
            end
            return filtered
        end,
        getOwnerFilter = function()
            return SelectedOwnerFilter("profileOwnerFilter")
        end,
        setOwnerFilter = function(value)
            SetSelectedOwnerFilter("profileOwnerFilter", value)
        end,
        getOwnerFilterOptions = function()
            return BuildOwnerFilterOptions(allRows)
        end,
        getProfile = function(profileKey)
            return profiles and profiles:GetProfile(profileKey) or nil
        end,
        getProfilesDB = function()
            GlobalDB().postingProfiles = GlobalDB().postingProfiles or {}
            return GlobalDB().postingProfiles
        end,
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
                local existing = profiles:GetProfile(profileKey)
                profile.owner = existing and existing.owner or profile.owner or OwnerKey()
                profile.ownerName = existing and existing.ownerName or profile.ownerName or OwnerName()
                profiles:SaveProfile(profileKey, profile)
            end
        end,
        onError = function(errorText)
            self.profileErrorText = errorText
        end,
        onChanged = function()
            self:RefreshPage("profiles")
            self:RefreshPage("noncrafted")
            self:RefreshPage("recipes")
        end,
    })
end

function AHPostingUI:RenderRuleEditor(parent, rootName, selectedKey, selectedRow, onSave, onDelete, options)
    options = options or {}
    local db = GlobalDB()
    db[rootName] = db[rootName] or {}
    local rule = selectedKey and db[rootName][selectedKey] or nil
    local editorModule = PocketCFO_AH:GetModule("PostingRuleEditor", true)
    if not editorModule or not editorModule.Create then
        AddChild(parent, CreateLabel(parent, "Posting rule editor unavailable.", options.editorX or 360, options.topY or -62, 260, "GameFontRedSmall"))
        return
    end

    return editorModule:Create(parent, {
        owner = self,
        selectedKey = selectedKey,
        selectedRow = selectedRow,
        rule = rule,
        ruleLabel = options.ruleLabel,
        editorX = options.editorX,
        controlX = options.controlX,
        topY = options.topY,
        fieldY = options.fieldY,
        buttonY = options.buttonY,
        errorY = options.errorY,
        dropdownOffsetX = options.dropdownOffsetX,
        secondColumnOffset = options.secondColumnOffset,
        showProfileFields = options.showProfileFields,
        errorKey = options.errorKey,
        onModeChanged = function(value)
            if selectedKey then
                db[rootName][selectedKey] = db[rootName][selectedKey] or {}
                db[rootName][selectedKey].mode = value
                db[rootName][selectedKey].owner = db[rootName][selectedKey].owner or OwnerKey()
                db[rootName][selectedKey].ownerName = db[rootName][selectedKey].ownerName or OwnerName()
            end
        end,
        onProfileChanged = function(value)
            if selectedKey then
                db[rootName][selectedKey] = db[rootName][selectedKey] or {}
                db[rootName][selectedKey].mode = "profile"
                db[rootName][selectedKey].profileKey = value
                db[rootName][selectedKey].profileID = value
                db[rootName][selectedKey].owner = db[rootName][selectedKey].owner or OwnerKey()
                db[rootName][selectedKey].ownerName = db[rootName][selectedKey].ownerName or OwnerName()
            end
        end,
        onSave = onSave,
        onDelete = onDelete,
    })
end

local function GetLiveNonCraftedBagRows()
    local rows = {}
    local byKey = {}
    local counts = {
        totalLiveItemSlots = 0,
        skippedNotSellable = 0,
        skippedRecipeOutput = 0,
        skippedIgnored = 0,
        skippedNoKey = 0,
        includedCandidates = 0,
    }

    if not C_Container or not C_Container.GetContainerNumSlots or not C_Container.GetContainerItemInfo then
        SessionLog("Item Rules live candidates unavailable reason=C_Container-missing")
        return rows
    end

    for _, containerID in ipairs(GetLiveBagContainers()) do
        local okSlots, numSlots = pcall(C_Container.GetContainerNumSlots, containerID)
        if okSlots and numSlots and numSlots > 0 then
            for slot = 1, numSlots do
                local okInfo, info = pcall(C_Container.GetContainerItemInfo, containerID, slot)
                local itemID = okInfo and info and tonumber(info.itemID) or nil
                if itemID and itemID > 0 then
                    counts.totalLiveItemSlots = counts.totalLiveItemSlots + 1
                    if not IsBagSlotAHPostable(containerID, slot, itemID) then
                        counts.skippedNotSellable = counts.skippedNotSellable + 1
                    else
                        local itemLocation = ItemLocation and ItemLocation.CreateFromBagAndSlot
                            and ItemLocation:CreateFromBagAndSlot(containerID, slot) or nil
                        local itemLink = info.hyperlink or GetItemLinkFromLocation(itemLocation)
                        local itemName, itemInfoLink, rarityQuality, ilvl = GetItemInfo(itemLink or itemID)
                        itemLink = itemLink or itemInfoLink
                        itemName = itemName or info.itemName
                        if IsKnownRecipeOutputItem(itemID, itemName) then
                            counts.skippedRecipeOutput = counts.skippedRecipeOutput + 1
                        else
                            local quality = GetLiveGameplayQualityTier(itemLink, itemID, itemLocation)
                            local itemStats, statFingerprint = GetItemStatsFingerprint(itemLink)
                            local quantity = tonumber(info.stackCount) or 1
                            local row = {
                                ownerKey = OwnerKey(),
                                location = "bags",
                                itemID = itemID,
                                itemName = itemName,
                                itemLink = itemLink,
                                itemGUID = GetItemGUIDFromLocation(itemLocation),
                                itemQuality = quality,
                                craftingQuality = quality,
                                rarityQuality = rarityQuality,
                                ilvl = tonumber(ilvl) or nil,
                                itemLevel = tonumber(ilvl) or nil,
                                statFingerprint = statFingerprint,
                                itemStats = itemStats,
                                quantity = quantity,
                            }

                            local itemKey = BuildItemKey(row)
                            if not itemKey then
                                counts.skippedNoKey = counts.skippedNoKey + 1
                            elseif IsItemIgnored(itemKey, itemID) then
                                counts.skippedIgnored = counts.skippedIgnored + 1
                            elseif byKey[itemKey] then
                                byKey[itemKey].row.quantity = (tonumber(byKey[itemKey].row.quantity) or 0) + quantity
                                byKey[itemKey].quantity = byKey[itemKey].row.quantity
                                byKey[itemKey].row.itemName = byKey[itemKey].row.itemName or itemName
                                byKey[itemKey].itemName = byKey[itemKey].itemName or itemName
                                byKey[itemKey].displayName = ItemDisplayName(byKey[itemKey].row)
                            else
                                local entry = {
                                    key = itemKey,
                                    row = row,
                                    itemID = itemID,
                                    itemName = itemName,
                                    displayName = ItemDisplayName(row),
                                    quantity = quantity,
                                    ruleText = RuleSummary((GlobalDB().nonCraftedPostingRules or {})[itemKey]),
                                }
                                byKey[itemKey] = entry
                                rows[#rows + 1] = entry
                            end
                        end
                    end
                end
            end
        end
    end

    counts.includedCandidates = #rows
    SessionLog("Item Rules live candidates totalSlots=%d skippedNotSellable=%d skippedRecipeOutput=%d skippedIgnored=%d skippedNoKey=%d included=%d",
        counts.totalLiveItemSlots,
        counts.skippedNotSellable,
        counts.skippedRecipeOutput,
        counts.skippedIgnored,
        counts.skippedNoKey,
        counts.includedCandidates)

    table.sort(rows, function(a, b)
        local aName = tostring(a.displayName or a.itemName or "")
        local bName = tostring(b.displayName or b.itemName or "")
        if aName == bName then
            return tostring(a.key) < tostring(b.key)
        end
        return aName < bName
    end)
    return rows
end

function AHPostingUI:GetNonCraftedRows()
    return GetLiveNonCraftedBagRows()
end

function AHPostingUI:CreateNonCraftedListRow(parent, x, y, width, height)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(width, height)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    row:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.ItemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ItemText:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.ItemText:SetWidth(210)
    row.ItemText:SetJustifyH("LEFT")

    row.QtyText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.QtyText:SetPoint("LEFT", row, "LEFT", 224, 0)
    row.QtyText:SetWidth(34)
    row.QtyText:SetJustifyH("RIGHT")

    row.RuleText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.RuleText:SetPoint("LEFT", row, "LEFT", 268, 0)
    row.RuleText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.RuleText:SetJustifyH("LEFT")
    return row
end

function AHPostingUI:RefreshNonCraftedListRows()
    local list = self.nonCraftedList
    if not list then
        return
    end

    local rows = list.rows or {}
    local offset = FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(list.scrollFrame) or 0
    local visibleRows = GetVisibleListRows(list.listBox, NONCRAFTED_LIST_VISIBLE_ROWS, NONCRAFTED_LIST_ROW_HEIGHT, 24, 4)
    if FauxScrollFrame_Update then
        FauxScrollFrame_Update(list.scrollFrame, #rows, visibleRows, NONCRAFTED_LIST_ROW_HEIGHT)
    end

    for index, button in ipairs(list.buttons or {}) do
        if index > visibleRows then
            button:Hide()
        else
            local row = rows[offset + index]
            if row then
                button.itemKey = row.key
                button.itemRow = row.row
                button.ItemText:SetText(tostring(row.displayName or ItemDisplayName(row.row)))
                button.QtyText:SetText(tostring(row.quantity or 0))
                button.RuleText:SetText(tostring(row.ruleText or "None"))
                button:Enable()
                button:Show()
                if tostring(row.key) == tostring(self.selectedNonCraftedKey) then
                    button:SetBackdropColor(0.18, 0.24, 0.34, 0.95)
                else
                    button:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
                end
            else
                button.itemKey = nil
                button.itemRow = nil
                button.ItemText:SetText("")
                button.QtyText:SetText("")
                button.RuleText:SetText("")
                button:Disable()
                button:SetBackdropColor(0.04, 0.04, 0.04, 0.45)
                button:Show()
            end
        end
    end
end

function AHPostingUI:RenderNonCraftedList(parent, rows)
    AddChild(parent, CreateLabel(parent, "Non-Crafted Items in Bags", 10, -12, 220, "GameFontNormal"))

    local listBox = AddChild(parent, CreateFrame("Frame", nil, parent, "BackdropTemplate"))
    listBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -36)
    listBox:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", 384, 16)
    listBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listBox:SetBackdropColor(0.025, 0.025, 0.025, 0.9)
    listBox:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.85)

    AddChild(parent, CreateLabel(listBox, "Item", 8, -6, 210, "GameFontDisableSmall"))
    AddChild(parent, CreateLabel(listBox, "Qty", 224, -6, 34, "GameFontDisableSmall"))
    AddChild(parent, CreateLabel(listBox, "Rule", 268, -6, 92, "GameFontDisableSmall"))

    local buttons = {}
    for index = 1, NONCRAFTED_LIST_VISIBLE_ROWS do
        local button = AddChild(parent, self:CreateNonCraftedListRow(listBox, 4, -24 - ((index - 1) * NONCRAFTED_LIST_ROW_HEIGHT), 346, NONCRAFTED_LIST_ROW_HEIGHT - 2))
        button:SetScript("OnClick", function(clicked)
            local itemKey = clicked.itemKey
            local row = clicked.itemRow
            if itemKey and row then
                local rules = GlobalDB().nonCraftedPostingRules or {}
                GlobalDB().nonCraftedPostingRules = rules
                rules[itemKey] = rules[itemKey] or {
                    mode = "none",
                    itemID = tonumber(row.itemID),
                    itemKey = itemKey,
                    itemName = row.itemName,
                    craftingQuality = row.craftingQuality or row.itemQuality,
                    itemLevel = row.itemLevel or row.ilvl,
                    statFingerprint = row.statFingerprint,
                }
                self.selectedNonCraftedKey = itemKey
                self.selectedNonCraftedRow = row
                self.nonCraftedRuleErrorText = nil
                self:RefreshPage("noncrafted")
            end
        end)
        buttons[index] = button
    end

    local scrollFrame = AddChild(parent, CreateFrame("ScrollFrame", nil, listBox, "FauxScrollFrameTemplate"))
    scrollFrame:SetPoint("TOPLEFT", listBox, "TOPLEFT", 0, -24)
    scrollFrame:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -26, 4)
    scrollFrame:SetScript("OnVerticalScroll", function(frame, offset)
        if FauxScrollFrame_OnVerticalScroll then
            FauxScrollFrame_OnVerticalScroll(frame, offset, NONCRAFTED_LIST_ROW_HEIGHT, function()
                self:RefreshNonCraftedListRows()
            end)
        end
    end)

    self.nonCraftedList = {
        rows = rows or {},
        buttons = buttons,
        scrollFrame = scrollFrame,
        listBox = listBox,
    }
    self:RefreshNonCraftedListRows()
end

function AHPostingUI:RenderNonCrafted(parent)
    AddChild(parent, CreateButton(parent, "Refresh Bags", 210, -8, 100, function()
        RefreshBagSnapshot()
        self:RefreshPage("noncrafted")
    end))

    local rows = self:GetNonCraftedRows()
    self:RenderNonCraftedList(parent, rows)
    if #rows == 0 then
        AddChild(parent, CreateListEmptyLabel(self.nonCraftedList.listBox, "No non-crafted AH-postable bag items found.", 24))
    end

    local selectedLabel = ""
    for _, row in ipairs(rows) do
        if tostring(row.key) == tostring(self.selectedNonCraftedKey) then
            selectedLabel = tostring(row.displayName or ItemDisplayName(row.row))
            self.selectedNonCraftedRow = row.row
            break
        end
    end
    if selectedLabel == "" and self.selectedNonCraftedKey then
        local rule = (GlobalDB().nonCraftedPostingRules or {})[self.selectedNonCraftedKey]
        selectedLabel = rule and ItemDisplayName(rule) or tostring(self.selectedNonCraftedKey)
    end

    local ignoreButton = AddChild(parent, CreateButton(parent, "Ignore Item", 414, -36, 100, function()
        if self.selectedNonCraftedKey then
            AddIgnoredItem(self.selectedNonCraftedKey, self.selectedNonCraftedRow or (GlobalDB().nonCraftedPostingRules or {})[self.selectedNonCraftedKey])
            GlobalDB().nonCraftedPostingRules[self.selectedNonCraftedKey] = nil
            self.selectedNonCraftedKey = nil
            self.selectedNonCraftedRow = nil
            self.nonCraftedRuleErrorText = nil
            self:RefreshPage("noncrafted")
            self:RefreshPage("ignore")
        end
    end))
    if not self.selectedNonCraftedKey then
        ignoreButton:Disable()
    end
    AddChild(parent, CreateLabel(parent, "Selected Item: " .. selectedLabel, 414, -62, 300, "GameFontNormalSmall"))
    self:RenderRuleEditor(parent, "nonCraftedPostingRules", self.selectedNonCraftedKey, self.selectedNonCraftedRow,
        function(key, mode, profileKey, custom, row)
            local rules = GlobalDB().nonCraftedPostingRules
            RemoveDuplicateNonCraftedRules(rules, key, row, profileKey)
            rules[key] = rules[key] or {}
            rules[key].mode = mode
            rules[key].profileKey = profileKey
            rules[key].profileID = profileKey
            rules[key].custom = custom
            if row then
                rules[key].itemID = tonumber(row.itemID)
                rules[key].itemName = row.itemName
                rules[key].itemKey = key
                rules[key].craftingQuality = row.craftingQuality or row.itemQuality
                rules[key].itemLevel = row.itemLevel or row.ilvl
                rules[key].statFingerprint = row.statFingerprint
            end
        end,
        function(key)
            GlobalDB().nonCraftedPostingRules[key] = nil
            self.selectedNonCraftedKey = nil
        end,
        {
            editorX = 414,
            controlX = 414,
            topY = -88,
            fieldY = -150,
            buttonY = -274,
            errorY = -258,
            dropdownOffsetX = -16,
            secondColumnOffset = 150,
            useProfileFieldLayout = true,
            showProfileFields = true,
            validateCustom = true,
            errorKey = "nonCraftedRuleErrorText",
            ruleLabel = "Rule",
            useRuleLabels = true,
            useProfileDisplayName = true,
        })
end

function AHPostingUI:GetIgnoredItemRows()
    local rows = {}
    for itemKey, row in pairs(ItemIgnoreDB()) do
        local copy = {}
        if type(row) == "table" then
            for key, value in pairs(row) do
                copy[key] = value
            end
        end
        copy.itemKey = copy.itemKey or itemKey
        copy.key = tostring(itemKey)
        copy.displayName = ItemDisplayName(copy)
        rows[#rows + 1] = copy
    end
    table.sort(rows, function(a, b)
        local aName = tostring(a.displayName or a.itemName or "")
        local bName = tostring(b.displayName or b.itemName or "")
        if aName == bName then
            return tostring(a.key) < tostring(b.key)
        end
        return aName < bName
    end)
    return rows
end

function AHPostingUI:CreateIgnoredItemListRow(parent, x, y, width, height)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(width, height)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    row:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.ItemText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.ItemText:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.ItemText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.ItemText:SetJustifyH("LEFT")
    return row
end

function AHPostingUI:RefreshIgnoreListRows()
    local list = self.ignoreList
    if not list then
        return
    end

    local rows = list.rows or {}
    local offset = FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(list.scrollFrame) or 0
    local visibleRows = GetVisibleListRows(list.listBox, IGNORE_LIST_VISIBLE_ROWS, IGNORE_LIST_ROW_HEIGHT, 4, 4)
    if FauxScrollFrame_Update then
        FauxScrollFrame_Update(list.scrollFrame, #rows, visibleRows, IGNORE_LIST_ROW_HEIGHT)
    end

    for index, button in ipairs(list.buttons or {}) do
        if index > visibleRows then
            button:Hide()
        else
            local row = rows[offset + index]
            if row then
                button.itemKey = row.key
                button.itemRow = row
                button.ItemText:SetText(tostring(row.displayName or row.itemName or row.key or ""))
                button:Enable()
                button:Show()
                if tostring(row.key) == tostring(self.selectedIgnoreKey) then
                    button:SetBackdropColor(0.18, 0.24, 0.34, 0.95)
                else
                    button:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
                end
            else
                button.itemKey = nil
                button.itemRow = nil
                button.ItemText:SetText("")
                button:Disable()
                button:SetBackdropColor(0.04, 0.04, 0.04, 0.45)
                button:Show()
            end
        end
    end
end

function AHPostingUI:RenderIgnoreList(parent)
    local rows = self:GetIgnoredItemRows()

    AddChild(parent, CreateLabel(parent, "Ignored Items", 10, -12, 190, "GameFontNormal"))
    local listBox = AddChild(parent, CreateFrame("Frame", nil, parent, "BackdropTemplate"))
    listBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -36)
    listBox:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", 384, 16)
    listBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listBox:SetBackdropColor(0.025, 0.025, 0.025, 0.9)
    listBox:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.85)

    local buttons = {}
    for index = 1, IGNORE_LIST_VISIBLE_ROWS do
        local button = AddChild(parent, self:CreateIgnoredItemListRow(listBox, 4, -4 - ((index - 1) * IGNORE_LIST_ROW_HEIGHT), 346, IGNORE_LIST_ROW_HEIGHT - 2))
        button:SetScript("OnClick", function(clicked)
            self.selectedIgnoreKey = clicked.itemKey
            self.selectedIgnoreRow = clicked.itemRow
            self:RefreshPage("ignore")
        end)
        buttons[index] = button
    end

    local scrollFrame = AddChild(parent, CreateFrame("ScrollFrame", nil, listBox, "FauxScrollFrameTemplate"))
    scrollFrame:SetPoint("TOPLEFT", listBox, "TOPLEFT", 0, -4)
    scrollFrame:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -26, 4)
    scrollFrame:SetScript("OnVerticalScroll", function(frame, offset)
        if FauxScrollFrame_OnVerticalScroll then
            FauxScrollFrame_OnVerticalScroll(frame, offset, IGNORE_LIST_ROW_HEIGHT, function()
                self:RefreshIgnoreListRows()
            end)
        end
    end)

    self.ignoreList = {
        rows = rows,
        buttons = buttons,
        scrollFrame = scrollFrame,
        listBox = listBox,
    }
    self:RefreshIgnoreListRows()

    local selected = nil
    for _, row in ipairs(rows) do
        if tostring(row.key) == tostring(self.selectedIgnoreKey) then
            selected = row
            break
        end
    end
    if not selected then
        self.selectedIgnoreKey = nil
        self.selectedIgnoreRow = nil
    end

    AddChild(parent, CreateLabel(parent, "Selected Item: " .. tostring(selected and (selected.displayName or selected.itemName) or ""), 414, -36, 300, "GameFontNormalSmall"))
    AddChild(parent, CreateLabel(parent, "Item ID: " .. tostring(selected and selected.itemID or ""), 414, -62, 220, "GameFontHighlightSmall"))
    AddChild(parent, CreateLabel(parent, "Item Key: " .. tostring(selected and selected.key or ""), 414, -84, 320, "GameFontHighlightSmall"))

    local removeButton = AddChild(parent, CreateButton(parent, "Remove from Ignore List", 414, -122, 170, function()
        if self.selectedIgnoreKey then
            RemoveIgnoredItem(self.selectedIgnoreKey)
            self.selectedIgnoreKey = nil
            self.selectedIgnoreRow = nil
            self:RefreshPage("ignore")
            self:RefreshPage("noncrafted")
        end
    end))
    if not selected then
        removeButton:Disable()
    end

    if #rows == 0 then
        AddChild(parent, CreateListEmptyLabel(listBox, "No ignored items.", 4))
    end
end

function AHPostingUI:GetRecipeRows()
    local rows = {}
    local rules = GlobalDB().recipePostingRules or {}
    local labelCounts = {}
    for recipeID, rule in pairs(rules) do
        local label = RecipeDisplayName(recipeID, rule, false)
        labelCounts[label] = (labelCounts[label] or 0) + 1
        rows[#rows + 1] = {
            recipeID = recipeID,
            key = recipeID,
            baseLabel = label,
            ruleText = RuleSummary(rule),
            rule = rule,
            owner = rule and rule.owner,
            ownerName = rule and rule.ownerName,
        }
    end
    for _, row in ipairs(rows) do
        row.label = row.baseLabel
        if labelCounts[row.baseLabel] and labelCounts[row.baseLabel] > 1 then
            row.label = RecipeDisplayName(row.recipeID, row.rule, true)
        end
    end
    table.sort(rows, function(a, b)
        local aLabel = tostring(a.label or "")
        local bLabel = tostring(b.label or "")
        if aLabel == bLabel then
            return tostring(a.recipeID) < tostring(b.recipeID)
        end
        return aLabel < bLabel
    end)
    return rows
end

function AHPostingUI:GetFilteredRecipeRows(rows)
    local selectedFilter = SelectedOwnerFilter("recipeOwnerFilter")
    local filtered = {}
    for _, row in ipairs(rows or {}) do
        if OwnerMatchesFilter(row, selectedFilter) then
            filtered[#filtered + 1] = row
        end
    end
    return filtered
end

function AHPostingUI:CreateRecipeListRow(parent, x, y, width, height)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetSize(width, height)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    row:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

    row.RecipeText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.RecipeText:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.RecipeText:SetWidth(216)
    row.RecipeText:SetJustifyH("LEFT")

    row.RuleText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.RuleText:SetPoint("LEFT", row, "LEFT", 232, 0)
    row.RuleText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.RuleText:SetJustifyH("LEFT")
    return row
end

function AHPostingUI:RefreshRecipeListRows()
    local list = self.recipeList
    if not list then
        return
    end

    local rows = list.rows or {}
    local offset = FauxScrollFrame_GetOffset and FauxScrollFrame_GetOffset(list.scrollFrame) or 0
    local visibleRows = GetVisibleListRows(list.listBox, RECIPE_LIST_VISIBLE_ROWS, RECIPE_LIST_ROW_HEIGHT, 24, 4)
    if FauxScrollFrame_Update then
        FauxScrollFrame_Update(list.scrollFrame, #rows, visibleRows, RECIPE_LIST_ROW_HEIGHT)
    end

    for index, button in ipairs(list.buttons or {}) do
        if index > visibleRows then
            button:Hide()
        else
            local row = rows[offset + index]
            if row then
                button.recipeKey = row.key
                button.recipeID = row.recipeID
                button.RecipeText:SetText(tostring(row.label or ""))
                button.RuleText:SetText(tostring(row.ruleText or ""))
                button:Enable()
                button:Show()
                if tostring(row.key) == tostring(self.selectedRecipeKey) then
                    button:SetBackdropColor(0.18, 0.24, 0.34, 0.95)
                else
                    button:SetBackdropColor(0.06, 0.06, 0.06, 0.82)
                end
            else
                button.recipeKey = nil
                button.recipeID = nil
                button.RecipeText:SetText("")
                button.RuleText:SetText("")
                button:Disable()
                button:SetBackdropColor(0.04, 0.04, 0.04, 0.45)
                button:Show()
            end
        end
    end
end

function AHPostingUI:RenderRecipeList(parent, rows)
    AddChild(parent, CreateLabel(parent, "Recipe Rules", 10, -12, 180, "GameFontNormal"))
    AddChild(parent, CreateOwnerFilterDropdown(parent, 122, 2, SelectedOwnerFilter("recipeOwnerFilter"), BuildOwnerFilterOptions(self.allRecipeRows or rows), function(value)
        SetSelectedOwnerFilter("recipeOwnerFilter", value)
        self.selectedRecipeKey = nil
        self.recipeRuleErrorText = nil
        self:RefreshPage("recipes")
    end))

    local listBox = AddChild(parent, CreateFrame("Frame", nil, parent, "BackdropTemplate"))
    listBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -36)
    listBox:SetPoint("BOTTOMRIGHT", parent, "BOTTOMLEFT", 384, 16)
    listBox:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    listBox:SetBackdropColor(0.025, 0.025, 0.025, 0.9)
    listBox:SetBackdropBorderColor(0.45, 0.45, 0.45, 0.85)

    AddChild(parent, CreateLabel(listBox, "Recipe", 8, -6, 210, "GameFontDisableSmall"))
    AddChild(parent, CreateLabel(listBox, "Rule", 232, -6, 120, "GameFontDisableSmall"))

    local buttons = {}
    for index = 1, RECIPE_LIST_VISIBLE_ROWS do
        local button = AddChild(parent, self:CreateRecipeListRow(listBox, 4, -24 - ((index - 1) * RECIPE_LIST_ROW_HEIGHT), 346, RECIPE_LIST_ROW_HEIGHT - 2))
        button:SetScript("OnClick", function(clicked)
            local rules = GlobalDB().recipePostingRules
            rules[clicked.recipeKey] = rules[clicked.recipeKey] or {
                mode = "none",
                recipeID = tonumber(clicked.recipeID),
                owner = OwnerKey(),
                ownerName = OwnerName(),
            }
            ApplyRecipeOutputIdentity(rules[clicked.recipeKey], clicked.recipeID)
            self.selectedRecipeKey = clicked.recipeKey
            self.recipeRuleErrorText = nil
            self:RefreshPage("recipes")
        end)
        buttons[index] = button
    end

    local scrollFrame = AddChild(parent, CreateFrame("ScrollFrame", nil, listBox, "FauxScrollFrameTemplate"))
    scrollFrame:SetPoint("TOPLEFT", listBox, "TOPLEFT", 0, -24)
    scrollFrame:SetPoint("BOTTOMRIGHT", listBox, "BOTTOMRIGHT", -26, 4)
    scrollFrame:SetScript("OnVerticalScroll", function(frame, offset)
        if FauxScrollFrame_OnVerticalScroll then
            FauxScrollFrame_OnVerticalScroll(frame, offset, RECIPE_LIST_ROW_HEIGHT, function()
                self:RefreshRecipeListRows()
            end)
        end
    end)

    self.recipeList = {
        rows = rows or {},
        buttons = buttons,
        scrollFrame = scrollFrame,
        listBox = listBox,
    }
    self:RefreshRecipeListRows()
end

function AHPostingUI:RenderRecipes(parent)
    local allRows = self:GetRecipeRows()
    self.allRecipeRows = allRows
    local rows = self:GetFilteredRecipeRows(allRows)
    self:RenderRecipeList(parent, rows)
    if #rows == 0 then
        AddChild(parent, CreateListEmptyLabel(self.recipeList.listBox, "No configured recipe rules.", 24))
    end

    local selectedRule = self.selectedRecipeKey and (GlobalDB().recipePostingRules or {})[self.selectedRecipeKey] or nil
    if selectedRule then
        ApplyRecipeOutputIdentity(selectedRule, selectedRule.recipeID or self.selectedRecipeKey)
    end
    local selectedLabel = ""
    for _, row in ipairs(rows) do
        if tostring(row.key) == tostring(self.selectedRecipeKey) then
            selectedLabel = tostring(row.label or "")
            break
        end
    end
    if selectedLabel == "" and self.selectedRecipeKey then
        selectedLabel = RecipeDisplayName(self.selectedRecipeKey, selectedRule, false)
    end
    AddChild(parent, CreateLabel(parent, "Selected: " .. selectedLabel, 414, -36, 250, "GameFontNormalSmall"))
    self:RenderRuleEditor(parent, "recipePostingRules", self.selectedRecipeKey, nil,
        function(key, mode, profileKey, custom)
            local rules = GlobalDB().recipePostingRules
            local existing = rules[key]
            rules[key] = rules[key] or {}
            rules[key].mode = mode
            rules[key].recipeID = tonumber(rules[key].recipeID) or tonumber(key)
            rules[key].profileKey = profileKey
            rules[key].profileID = profileKey
            rules[key].custom = custom
            rules[key].owner = existing and existing.owner or rules[key].owner or OwnerKey()
            rules[key].ownerName = existing and existing.ownerName or rules[key].ownerName or OwnerName()
            ApplyRecipeOutputIdentity(rules[key], rules[key].recipeID or key)
        end,
        function(key)
            GlobalDB().recipePostingRules[key] = nil
            self.selectedRecipeKey = nil
        end,
        {
            editorX = 414,
            controlX = 414,
            topY = -62,
            fieldY = -124,
            buttonY = -248,
            errorY = -232,
            dropdownOffsetX = -16,
            secondColumnOffset = 150,
            useProfileFieldLayout = true,
            showProfileFields = true,
            validateCustom = true,
            errorKey = "recipeRuleErrorText",
            ruleLabel = "Rule",
            useRuleLabels = true,
            useProfileDisplayName = true,
        })
end

function AHPostingUI:RenderPostAuctions(parent)
    local postingUI = GetPostingUIModule()
    if postingUI and postingUI.Render then
        postingUI:Render(parent)
        return
    end

    AddChild(parent, CreateLabel(parent, "Posting UI unavailable.", 14, -16, 360, "GameFontDisableSmall"))
end

function AHPostingUI:RenderCancelAuctions(parent)
    local cancelUI = GetCancelAuctionsUIModule()
    if cancelUI and cancelUI.Render then
        cancelUI:Render(parent)
        return
    end

    AddChild(parent, CreateLabel(parent, "Cancel Auctions UI unavailable.", 14, -16, 360, "GameFontDisableSmall"))
end

-- First-run guidance: until one full price scan has finished, a small
-- callout under the Pocket CFO AH tab points the player to it. Parented to
-- the tab so it hides with the Auction House. Hidden for the rest of the
-- session once the tab is clicked (the Scan Prices button is on the page
-- that opens). Missing Valuation addon is treated as "scanned".
function AHPostingUI:UpdateScanCallout()
    local tab = self.tabButton
    local valuation = _G.PocketCFO_Valuation
    local needsScan = tab and not self.scanCalloutDismissed
        and valuation and valuation.HasCompletedPriceScan
        and not valuation:HasCompletedPriceScan()

    if not needsScan then
        if self.scanCallout then
            self.scanCallout:Hide()
        end
        return
    end

    if not self.scanCallout then
        local callout = CreateFrame("Frame", nil, tab, "BackdropTemplate")
        callout:SetFrameStrata("DIALOG")
        callout:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        callout:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
        callout:SetBackdropBorderColor(1.00, 0.82, 0.00, 1)

        local text = callout:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("CENTER", callout, "CENTER", 0, 0)
        text:SetText("Click here, then press Scan Prices")
        callout:SetSize(math.max(240, (text:GetStringWidth() or 0) + 24), 28)

        callout.text = text
        self.scanCallout = callout
    end

    self.scanCallout:ClearAllPoints()
    self.scanCallout:SetPoint("TOP", tab, "BOTTOM", 0, -4)
    self.scanCallout:Show()
end

function AHPostingUI:ShowPocketCFOContent()
    self:EnsureAuctionHouseTab()
    if not self.content then
        return
    end
    self.scanCalloutDismissed = true
    self:UpdateScanCallout()
    self.active = true
    self:ClearKnownAHSelectedTabs()
    self:SetPocketCFOTabSelected(true)
    self:HideOtherAHContent()
    self.content:Show()
    self:EnsureShell()
    self:SelectPage("dashboard")
end

AHPostingUI.ShowContent = AHPostingUI.ShowPocketCFOContent

function AHPostingUI:HidePocketCFOContent()
    self.active = false
    if self.content then
        self.content:Hide()
    end
    self:SetPocketCFOTabSelected(false)
end

function AHPostingUI:OnAuctionHouseShow()
    self:ScheduleEnsureAuctionHouseTab("auction-house-show")
    -- The tab can take a few 0.1s retries to exist; check after it settles.
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, function()
            self:UpdateScanCallout()
        end)
    else
        self:UpdateScanCallout()
    end
end

function AHPostingUI:OnAuctionHouseClosed()
    local exec = PocketCFO_AH:GetModule("PostingExecution", true)
    if exec and exec.ClearPending then
        exec:ClearPending()
    end
    self:HidePocketCFOContent()
end

function AHPostingUI:OnInitialize()
    SessionLog("AHPostingUI OnInitialize")
end

function AHPostingUI:OnEnable()
    self:RegisterEvent("AUCTION_HOUSE_SHOW", "OnAuctionHouseShow")
    self:RegisterEvent("AUCTION_HOUSE_CLOSED", "OnAuctionHouseClosed")
    self:RegisterMessage("PCFO_SETTINGS_CHANGED", "OnSettingsChanged")
    if AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown() then
        self:ScheduleEnsureAuctionHouseTab("enable-ah-shown")
    elseif C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            if AuctionHouseFrame and AuctionHouseFrame.IsShown and AuctionHouseFrame:IsShown() then
                self:ScheduleEnsureAuctionHouseTab("enable-deferred")
            end
        end)
    end
    -- This addon loads on the first AUCTION_HOUSE_SHOW, after that event has
    -- already fired, so OnAuctionHouseShow misses the first open. No-op if
    -- the tab doesn't exist or a scan has already finished.
    if C_Timer and C_Timer.After then
        C_Timer.After(0.5, function()
            self:UpdateScanCallout()
        end)
    end
end
