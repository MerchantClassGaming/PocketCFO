-- PocketCFO_Crafting/Crafting/CraftQueueController.lua
-- Profession window lifecycle and Inventory Manager orchestration.
-- Owns event registration, show/hide, click-to-load, and highlight tracking.
-- Asks QueueGeneration for rows and passes them to InventoryManagerWindow.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local CraftQueueController = PocketCFO_Crafting:NewModule("CraftQueueController", "AceEvent-3.0")

local INVENTORY_REFRESH_DEBOUNCE_SECONDS = 0.30
local PRICING_REFRESH_DEBOUNCE_SECONDS   = 0.50

-- MVP first-open Analysis loading behavior (see BeginAnalysisInitialLoad).
local ANALYSIS_INITIAL_LOAD_DELAY_SECONDS  = 2.0
local ANALYSIS_INITIAL_RETRY_DELAY_SECONDS = 1.0

-- Current profession/character context, updated on each trade skill show/update
local currentProfID   = nil
local currentCharGUID = nil

-- Debounces PCFO_PRICING_UPDATED (PocketCFO_Valuation's PricingCache can fire
-- this once per row during a SearchRefresh/FullScan batch) into a single
-- re-evaluation, so Prospecting Analysis reflects a newly-resolved price
-- without needing an unrelated recipe reselect to trigger it.
local pricingRefreshPending = false

local function GetWindow()
    return PocketCFO_Crafting:GetModule("InventoryManagerWindow", true)
end

local function GetQueueGeneration()
    return PocketCFO_Crafting:GetModule("QueueGeneration", true)
end

local function GetProfessionContextService()
    return PocketCFO_Crafting:GetModule("ProfessionContextService", true)
end

local function GetAnalysisController()
    return PocketCFO_Crafting:GetModule("ProcessingAnalysisController", true)
end

local function GetCraftAnalysisController()
    return PocketCFO_Crafting:GetModule("CraftAnalysisController", true)
end

local function GetRecipeAnalysisController()
    return PocketCFO_Crafting:GetModule("RecipeAnalysisController", true)
end

local function GetCraftAnalysisEligibilityPolicy()
    return PocketCFO and PocketCFO.CraftAnalysisEligibilityPolicy or _G.PocketCFO_CraftAnalysisEligibilityPolicy
end

local function GetDisplayModelBuilder()
    return PocketCFO_Crafting:GetModule("ProcessingAnalysisDisplayModelBuilder", true)
end

local function GetProfessionRegistry()
    return PocketCFO and PocketCFO.ProfessionRegistry or _G.PocketCFO_ProfessionRegistry
end

local function GetInventoryStateService()
    return PocketCFO and PocketCFO.InventoryStateService or _G.InventoryStateService
end

local function GetProfileKeyService()
    return PocketCFO and PocketCFO.OperationProfileKeyService or _G.PocketCFO_OperationProfileKeyService
end

-- Beta feature toggles (PocketCFO/Infrastructure/BetaFeatures.lua). Both
-- default off: with Inventory Manager off, Analysis is the only view; with
-- Auction House off, the Posting Rules/Profiles windows stay closed.
local function GetBetaFeatures()
    return PocketCFO and PocketCFO.GetModule and PocketCFO:GetModule("BetaFeatures", true)
end

local function IsInventoryBetaEnabled()
    local beta = GetBetaFeatures()
    return beta ~= nil and beta:IsInventoryManagerEnabled() == true
end

local function IsAuctionHouseBetaEnabled()
    local beta = GetBetaFeatures()
    return beta ~= nil and beta:IsAuctionHouseEnabled() == true
end

local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

local function TraceProcessingAnalysisUI(event, fmt, ...)
    local trace = _G.MCG_DiagnosticProcessingAnalysisUITrace
    if type(trace) ~= "table" then
        trace = { seq = 0, limit = 100, events = {} }
        _G.MCG_DiagnosticProcessingAnalysisUITrace = trace
    end
    trace.seq = (tonumber(trace.seq) or 0) + 1
    trace.limit = tonumber(trace.limit) or 100
    trace.events = type(trace.events) == "table" and trace.events or {}

    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    trace.events[#trace.events + 1] = {
        seq = trace.seq,
        time = date and date("%H:%M:%S") or tostring(GetTime and GetTime() or ""),
        event = tostring(event or "event"),
        message = msg,
    }
    while #trace.events > trace.limit do
        table.remove(trace.events, 1)
    end
end

-- Mining and Herbalism have nothing to show yet, so the window stays hidden
-- for them. Skinning shows it for Lure Analysis (Brian, 2026-10-16).
local SKINNING_PROFESSION_ID = 393 -- ProfessionRegistry

local function IsHiddenGatheringProfessionContext(context)
    local registry = GetProfessionRegistry()
    if not registry or not registry.IsGatheringProfession then
        return false
    end
    local professionID = context and context.professionID
    local professionName = context and context.professionName
    if not registry:IsGatheringProfession(professionID, professionName) then
        return false
    end
    if professionID == SKINNING_PROFESSION_ID
        or (type(professionName) == "string" and professionName:lower() == "skinning") then
        return false
    end
    return true
end

-- Gathering entries in a profession book (e.g. Skinning Details' Void-
-- Tempered Leather) can't be crafted, so they get no analysis.
-- isGatheringRecipe confirmed in-game 2026-10-16 (/mcgd gatherstats).
local function IsGatheringRecipe(recipeID)
    if not recipeID or not C_TradeSkillUI or type(C_TradeSkillUI.GetRecipeInfo) ~= "function" then
        return false
    end
    local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
    return ok and type(info) == "table" and info.isGatheringRecipe == true
end

local function DebugTime()
    return debugprofilestop and debugprofilestop() or (GetTime and GetTime() * 1000) or 0
end

local function LogTiming(label, startedAt, extra)
    if not PocketCFO or not PocketCFO.Debug then return end
    local elapsed = DebugTime() - (startedAt or DebugTime())
    if extra and extra ~= "" then
        PocketCFO:Debug("%s elapsed=%.1fms %s", label, elapsed, extra)
    else
        PocketCFO:Debug("%s elapsed=%.1fms", label, elapsed)
    end
end

local function ScanBagsOnOpen()
    local ownerKey = PocketCFO.db.char and PocketCFO.db.char.characterGUID
    local inventoryStateService = GetInventoryStateService()
    if inventoryStateService and ownerKey then
        local usable, reason = inventoryStateService:IsSnapshotUsable("bags", ownerKey)
        if usable then
            PocketCFO:Debug("CraftQueueController open -> bag scan skipped snapshot=usable")
            return
        end
        local scanner = PocketCFO:GetModule("BagScanner")
        if scanner and scanner.ScanBags then
            PocketCFO:Debug("CraftQueueController open -> ScanBags reason=craft-window-open-stale unusable=%s", tostring(reason))
            scanner:ScanBags({ reason = "craft-window-open-stale" })
        end
        return
    end
    -- Fallback: service or ownerKey unavailable, scan unconditionally.
    local scanner = PocketCFO:GetModule("BagScanner")
    if scanner and scanner.ScanBags then
        PocketCFO:Debug("CraftQueueController open -> ScanBags reason=craft-window-open")
        scanner:ScanBags({ reason = "craft-window-open" })
    end
end

-- ---------------------------------------------------------------------------
-- Processing Analysis mode switching
-- ---------------------------------------------------------------------------

-- True if any row in an Operation Summary result still needs a price - the
-- same "needsPrice" classification ProcessingAnalysisDisplayModelBuilder
-- already assigns rows, read back here (not recomputed) to decide whether
-- BeginAnalysisInitialLoad's one bounded retry is worth scheduling.
local function AnalysisResultHasUnresolvedPricing(result)
    local rows = result and result.rows
    if type(rows) ~= "table" then
        return false
    end
    local builder = GetDisplayModelBuilder()
    local needsPriceReason = (builder and builder.VALUE_UNAVAILABLE_NEEDS_PRICE) or "needsPrice"
    for _, row in ipairs(rows) do
        if row.valueUnavailableReason == needsPriceReason then
            return true
        end
    end
    return false
end

-- Stable per-row identity for preserving the selected analysis detail row
-- across any refresh (reagent allocation change, TRADE_SKILL_LIST_UPDATE,
-- pricing update, craft-completion outcome update, Top/All Results toggle).
-- Deliberately NOT summary.operationProfileKey - that key is per-RECIPE, so
-- every gem candidate row in a grouped Crushing result shares the same one,
-- making it ambiguous once more than one row per family exists (this was
-- the root cause of the analysis selection jumping to the first row on
-- reagent change - see OnLiveProcessingInputChanged). configKey-or-
-- item:itemID is the same canonical per-item identity formula
-- OperationOutcomeService:ResolveStatisticalProfileKey already uses, reused
-- here rather than re-derived.
local function GetAnalysisRowIdentity(row)
    if type(row) ~= "table" then return nil end
    if row.configKey then return row.configKey end
    if row.itemID then return "item:" .. tostring(row.itemID) end
    return nil
end

local function FindAnalysisRowByIdentity(rows, identity)
    if not identity or type(rows) ~= "table" then return nil end
    for _, row in ipairs(rows) do
        if GetAnalysisRowIdentity(row) == identity then
            return row
        end
    end
    return nil
end

-- Temporary diagnostics for the "toggle doesn't change rendered rows"
-- investigation. Formats "familyKey=count,familyKey=count,..." (ungrouped
-- rows count under "(ungrouped)") so the session log shows per-family
-- counts, not just a total. Remove once the toggle is confirmed working
-- in-game across both Top and All Results states.
local function DescribeFamilyCounts(rows)
    local counts, order = {}, {}
    for _, row in ipairs(rows or {}) do
        local key = row.outputFamilyKey or "(ungrouped)"
        if not counts[key] then
            counts[key] = 0
            order[#order + 1] = key
        end
        counts[key] = counts[key] + 1
    end
    local parts = {}
    for _, key in ipairs(order) do
        parts[#parts + 1] = string.format("%s=%d", tostring(key), counts[key])
    end
    return #parts > 0 and table.concat(parts, ",") or "(none)"
end

-- Applies the current Top Results/All Results display limit to an already-
-- evaluated analysis result, without touching economics/outcome data. Pure
-- presentation filtering: result.rows is the FULL ranked set
-- ProcessingRecommendationPolicy/ProcessingAnalysisController already
-- produced (see ProcessingRecommendationPolicy.RecommendTopNInputsPerOutputFamily),
-- so toggling never re-evaluates anything - it only changes how many of
-- those already-ranked rows this pass keeps per family. Builds a shallow
-- copy so result (== self.lastAnalysisResult) is never mutated - the full
-- ranked set must stay intact and reusable for the next toggle.
local function BuildLimitedAnalysisResult(result, showAllResults)
    if type(result) ~= "table" or not result.supportsResultsLimit then
        SessionLog("CraftQueueController:BuildLimitedAnalysisResult: DIAG skipped reason=%s",
            type(result) ~= "table" and "resultNotTable" or "supportsResultsLimitFalse")
        TraceProcessingAnalysisUI("BuildLimitedAnalysisResult",
            "skipped reason=%s", type(result) ~= "table" and "resultNotTable" or "supportsResultsLimitFalse")
        return result
    end
    local builder = GetDisplayModelBuilder()
    if not builder or not builder.LimitRowsPerFamily then
        SessionLog("CraftQueueController:BuildLimitedAnalysisResult: DIAG skipped reason=builderUnavailable builder=%s hasLimitFn=%s",
            tostring(builder ~= nil), tostring(builder and builder.LimitRowsPerFamily ~= nil))
        TraceProcessingAnalysisUI("BuildLimitedAnalysisResult",
            "skipped reason=builderUnavailable builder=%s hasLimitFn=%s",
            tostring(builder ~= nil), tostring(builder and builder.LimitRowsPerFamily ~= nil))
        return result
    end

    local limitPerFamily = nil
    if not showAllResults then
        limitPerFamily = builder.TOP_N_PER_FAMILY
    end
    SessionLog("CraftQueueController:BuildLimitedAnalysisResult: DIAG showAllResults=%s limitPerFamily=%s fullRows=%d fullPerFamily=%s",
        tostring(showAllResults), tostring(limitPerFamily), #(result.rows or {}), DescribeFamilyCounts(result.rows))
    TraceProcessingAnalysisUI("BuildLimitedAnalysisResult",
        "showAllResults=%s limitPerFamily=%s fullRows=%d fullPerFamily=%s",
        tostring(showAllResults), tostring(limitPerFamily), #(result.rows or {}), DescribeFamilyCounts(result.rows))

    local limitedRows = builder:LimitRowsPerFamily(result.rows, limitPerFamily)

    SessionLog("CraftQueueController:BuildLimitedAnalysisResult: DIAG limitedRows=%d limitedPerFamily=%s",
        #limitedRows, DescribeFamilyCounts(limitedRows))
    TraceProcessingAnalysisUI("BuildLimitedAnalysisResult",
        "limitedRows=%d limitedPerFamily=%s", #limitedRows, DescribeFamilyCounts(limitedRows))

    local limitedResult = {}
    for k, v in pairs(result) do
        limitedResult[k] = v
    end
    limitedResult.rows = limitedRows
    return limitedResult
end

-- MVP first-open loading behavior: the first time Analysis mode becomes
-- active for a processing recipe in a crafting-window session, item/pricing
-- data (GetItemInfo, PricingIdentity market keys) commonly hasn't resolved
-- yet, so an immediate evaluation renders rows as "needs pricing data" that
-- would often clear up moments later on their own. Rather than chase that
-- timing further, show a brief loading placeholder, then re-evaluate for
-- real - with one bounded retry if pricing is still unresolved after that.
--
-- Runs once per crafting-window session (self.analysisInitialLoadDone is
-- reset in OnTradeSkillClose). self.analysisLoadToken guards against a
-- timer scheduled in one session firing after OnTradeSkillClose has already
-- reset state for a new session (e.g. the window was closed and reopened
-- while a timer was pending).
function CraftQueueController:BeginAnalysisInitialLoad()
    self.analysisInitialLoadInProgress = true
    self.analysisInitialRetryDone = false

    local token = {}
    self.analysisLoadToken = token

    C_Timer.After(ANALYSIS_INITIAL_LOAD_DELAY_SECONDS, function()
        if self.analysisLoadToken ~= token then return end
        self.analysisInitialLoadInProgress = false
        self.analysisInitialLoadDone = true

        self:RefreshAnalysisAvailability()
        self:DoRender("analysis-initial-load")

        if not self.analysisInitialRetryDone and AnalysisResultHasUnresolvedPricing(self.lastAnalysisResult) then
            C_Timer.After(ANALYSIS_INITIAL_RETRY_DELAY_SECONDS, function()
                if self.analysisLoadToken ~= token then return end
                self.analysisInitialRetryDone = true
                self:RefreshAnalysisAvailability()
                self:DoRender("analysis-initial-retry")
            end)
        end
    end)
end

-- Re-evaluates Processing Analysis applicability for the currently selected
-- recipe and updates analysisAvailable/viewMode accordingly. This is the
-- only place that decides Inventory vs Analysis mode - InventoryManagerWindow
-- just renders whichever mode it is told to show.
--
-- Default-view rules:
--   0. Inventory Manager beta OFF: Analysis is the only view. Recipes with
--      no analysis show the "no analysis" message (see DoRender) and the
--      Inventory/Analysis toggle is hidden.
--   1. opts.forceInventory lands on Inventory (no longer passed on profession
--      window open - the window now opens on Analysis when available).
--   2. A recipe with no analysis forces Inventory and hides the toggle.
--   3. A *newly selected* recipe with analysis (recipeID changed since the
--      last evaluation) lands on the user's last manually toggled view
--      (self.preferredViewMode), defaulting to Analysis.
--   4. Re-evaluating the *same* recipe (e.g. a price/inventory refresh, or
--      TRADE_SKILL_LIST_UPDATE firing without an actual recipe change)
--      leaves viewMode/detail state exactly as the user last set it via the
--      manual toggle - this is what makes rule 4 ("respect manual toggle")
--      hold across incidental re-evaluations.
function CraftQueueController:RefreshAnalysisAvailability(opts)
    opts = opts or {}

    -- Requirement: analysisAvailable is a cheap registry-only check (is the
    -- selected recipeID a registered Processing Operation, OR a recipeID
    -- enabled by CraftAnalysisEligibilityPolicy?). Full evaluation
    -- (EvaluateCurrentRecipe, which reads the live schematic/economics) is
    -- never consulted to decide whether the Analysis view/toggle exists -
    -- it only decides what content that view shows once it's already up.
    local contextService = GetProfessionContextService()
    local recipeID        = contextService and contextService:GetCurrentRecipeID()
    local profileKeyService = GetProfileKeyService()
    local operationType   = (profileKeyService and recipeID) and profileKeyService:GetOperationType(recipeID) or nil
    local isProcessing     = profileKeyService ~= nil and operationType == profileKeyService.OPERATION_TYPE_PROCESSING

    local eligibilityPolicy = GetCraftAnalysisEligibilityPolicy()
    local isCraftAnalysisEligible = not isProcessing and recipeID ~= nil
        and eligibilityPolicy ~= nil and eligibilityPolicy.IsEnabled ~= nil
        and eligibilityPolicy:IsEnabled(recipeID) == true

    -- Every other ordinary recipe gets live Recipe Analysis (Order
    -- Analysis-style, read from the crafting form) - the default. Recipes in
    -- CraftAnalysisEligibilityPolicy keep the history-based Craft Analysis.
    -- Gathering entries (Skinning Details) show the "no analysis" message,
    -- never the Inventory Manager, even with the Inventory beta on (Brian).
    self.isGatheringRecipe = recipeID ~= nil and IsGatheringRecipe(recipeID) or nil
    local isLiveRecipe = not isProcessing and not isCraftAnalysisEligible and recipeID ~= nil
        and not self.isGatheringRecipe

    self.analysisAvailable = isProcessing == true or isCraftAnalysisEligible == true or isLiveRecipe == true
    -- Remembers which controller produced self.lastAnalysisResult, so
    -- DoRender's detail-view lookup (BuildDetailViewModel) and any future
    -- caller can route to the same controller without re-deriving eligibility.
    self.analysisMode = isProcessing and "processing"
        or (isCraftAnalysisEligible and "craftAnalysis")
        or (isLiveRecipe and "liveRecipe")
        or nil

    local result
    if isProcessing then
        local analysisController = GetAnalysisController()
        result = analysisController and analysisController:EvaluateCurrentRecipe()
            or { applicable = false, reason = "analysisControllerUnavailable", rows = {}, recipeID = recipeID }
    elseif isCraftAnalysisEligible then
        local craftAnalysisController = GetCraftAnalysisController()
        result = craftAnalysisController and craftAnalysisController:EvaluateCurrentRecipe()
            or { applicable = false, reason = "craftAnalysisControllerUnavailable", rows = {}, recipeID = recipeID }
    elseif isLiveRecipe then
        local recipeAnalysisController = GetRecipeAnalysisController()
        result = recipeAnalysisController and recipeAnalysisController:EvaluateCurrentRecipe()
            or { applicable = false, reason = "recipeAnalysisControllerUnavailable", rows = {}, recipeID = recipeID }
    else
        result = { applicable = false, reason = "notAProcessingOperation", rows = {}, recipeID = recipeID }
    end
    self.lastAnalysisResult = result

    local recipeChanged = (recipeID ~= self.lastEvaluatedRecipeID)
    self.lastEvaluatedRecipeID = recipeID

    SessionLog("AnalysisAvailability: recipeID=%s isProcessing=%s operationType=%s reason=%s analysisAvailable=%s recipeChanged=%s viewMode(before)=%s forceInventory=%s",
        tostring(recipeID),
        tostring(isProcessing),
        tostring(operationType),
        tostring(result.reason),
        tostring(self.analysisAvailable),
        tostring(recipeChanged),
        tostring(self.viewMode),
        tostring(opts.forceInventory))

    local inventoryEnabled = IsInventoryBetaEnabled()
    if not inventoryEnabled or self.isGatheringRecipe then
        if recipeChanged or self.viewMode ~= "analysis" then
            self.viewMode = "analysis"
            self.showingAnalysisDetail = false
            self.analysisDetailRow = nil
            if recipeChanged then
                self.analysisShowAllResults = nil
            end
        end
    elseif opts.forceInventory or not self.analysisAvailable then
        self.viewMode = "inventory"
        self.showingAnalysisDetail = false
        self.analysisDetailRow = nil
    elseif recipeChanged then
        -- Sticky view: a new recipe lands on whichever view the user last
        -- picked with the Inventory/Analysis toggle (default Analysis).
        -- Only onToggleViewMode writes preferredViewMode, so a recipe with
        -- no analysis (forced Inventory above) never overwrites the choice.
        -- In-memory only: survives profession window close/reopen, resets
        -- on /reload or login.
        self.viewMode = self.preferredViewMode or "analysis"
        self.showingAnalysisDetail = false
        self.analysisDetailRow = nil
        -- Selected recipe changed to a different analysis context - Top
        -- Results/All Results is presentation state scoped to "the recipe
        -- currently being analyzed", not a sticky global preference.
        self.analysisShowAllResults = nil
    end

    local window = GetWindow()
    SessionLog("AnalysisAvailability: viewMode(after)=%s window=%s",
        tostring(self.viewMode), tostring(window ~= nil))
    if window then
        window:SetAnalysisToggleVisible(self.analysisAvailable and inventoryEnabled)
        if self.analysisAvailable then
            window:SetAnalysisToggleMode(self.viewMode)
        end
    end
    self:UpdateAnalysisResultsToggleUI()

    -- A real evaluation just ran and self.lastAnalysisResult reflects
    -- whatever is currently in PricingCache, so any pending "a price arrived
    -- while Analysis wasn't visible" flag is resolved regardless of which
    -- caller (recipe change, trade-skill update, manual toggle, or the
    -- pricing-updated listener) triggered this refresh.
    self.analysisPricingDirty = false

    -- First entry into Analysis mode for a processing recipe this session -
    -- whether via auto-select on recipe change or a manual toggle - starts
    -- the MVP loading sequence instead of rendering this call's evaluation
    -- immediately. Guarded so re-entrant refreshes (pricing updates, trade
    -- skill list updates, the loading sequence's own re-evaluation) never
    -- start a second timer.
    if self.viewMode == "analysis" and self.analysisAvailable
        and not self.analysisInitialLoadDone
        and not self.analysisInitialLoadInProgress then
        self:BeginAnalysisInitialLoad()
    end
end

-- Shows/hides and relabels the Top Results/All Results toggle button.
-- Visible only while actually looking at an Analysis result whose policy
-- supports a Top N per-family limit (currently Crushing only, via
-- result.supportsResultsLimit) - hidden for Inventory mode and for every
-- other processing type, INCLUDING processing types that group rows into
-- sections without limiting them (Milling's Low/High-Quality Herbs - see
-- result.hasOutputFamilies, which only controls section rendering). Called
-- after every RefreshAnalysisAvailability run and from the view-mode/results
-- toggles themselves, so the button's visibility and label always match
-- current state without a separate render pass.
function CraftQueueController:UpdateAnalysisResultsToggleUI()
    local window = GetWindow()
    if not window then return end

    local visible = self.analysisAvailable == true
        and self.viewMode == "analysis"
        and self.lastAnalysisResult ~= nil
        and self.lastAnalysisResult.supportsResultsLimit == true

    window:SetAnalysisResultsToggleVisible(visible)
    if visible then
        window:SetAnalysisResultsToggleMode(self.analysisShowAllResults == true)
    end
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

function CraftQueueController:DoRender(reason)
    local startedAt = DebugTime()
    local window = GetWindow()

    -- Temporary diagnostic for the "a later queued render overwrites the
    -- Show All render" investigation - fires on EVERY DoRender call
    -- regardless of mode/reason, so the session log shows the full
    -- chronological sequence of render attempts (and which
    -- analysisShowAllResults value each one used) around a toggle click.
    SessionLog("CraftQueueController:DoRender: DIAG ENTRY reason=%s viewMode=%s analysisAvailable=%s analysisShowAllResults=%s hasLastResult=%s lastResultRows=%s lastResultHasFamilies=%s",
        tostring(reason or "unspecified"), tostring(self.viewMode), tostring(self.analysisAvailable),
        tostring(self.analysisShowAllResults), tostring(self.lastAnalysisResult ~= nil),
        tostring(self.lastAnalysisResult and #(self.lastAnalysisResult.rows or {})),
        tostring(self.lastAnalysisResult and self.lastAnalysisResult.hasOutputFamilies))
    TraceProcessingAnalysisUI("DoRender.entry",
        "reason=%s viewMode=%s analysisAvailable=%s analysisShowAllResults=%s hasLastResult=%s lastResultRows=%s lastResultHasFamilies=%s",
        tostring(reason or "unspecified"), tostring(self.viewMode), tostring(self.analysisAvailable),
        tostring(self.analysisShowAllResults), tostring(self.lastAnalysisResult ~= nil),
        tostring(self.lastAnalysisResult and #(self.lastAnalysisResult.rows or {})),
        tostring(self.lastAnalysisResult and self.lastAnalysisResult.hasOutputFamilies))

    if not window or not window:IsShown() then return end

    -- Re-sync the Inventory/Analysis toggle on every render. Needed because
    -- InventoryManagerWindow:DeactivateMode (leaving the Orders page) shows
    -- the toggle unconditionally before calling back into DoRender - without
    -- this it would reappear with the Inventory Manager beta off.
    window:SetAnalysisToggleVisible(self.analysisAvailable == true and IsInventoryBetaEnabled())

    if self.viewMode == "analysis" and self.analysisAvailable then
        -- MVP first-open loading: while BeginAnalysisInitialLoad's timer is
        -- pending, show the loading placeholder instead of whatever
        -- (possibly incomplete) self.lastAnalysisResult this call would
        -- otherwise render - regardless of which caller triggered DoRender.
        if self.analysisInitialLoadInProgress then
            window:RenderAnalysisLoading(self.lastAnalysisResult)
            LogTiming("CraftQueueController:DoRender", startedAt, string.format(
                "mode=analysisLoading reason=%s", tostring(reason or "unspecified")
            ))
            return
        end

        -- Live Recipe Analysis is a single breakdown, not a row list - no
        -- detail view, no Top/All results.
        if self.analysisMode == "liveRecipe" and self.lastAnalysisResult then
            window:RenderRecipeAnalysis(self.lastAnalysisResult)
            self:ScheduleRecipeNameRefresh(self.lastAnalysisResult)
            LogTiming("CraftQueueController:DoRender", startedAt, string.format(
                "mode=liveRecipe reason=%s", tostring(reason or "unspecified")
            ))
            return
        end

        if self.lastAnalysisResult then
            self:ScheduleAnalysisItemDataRefresh(self.lastAnalysisResult)
            if self.showingAnalysisDetail and self.analysisDetailRow then
                local analysisController = (self.analysisMode == "craftAnalysis")
                    and GetCraftAnalysisController() or GetAnalysisController()
                local detail = analysisController and analysisController:BuildDetailViewModel(self.analysisDetailRow)
                if detail then
                    window:RenderAnalysisDetail(detail, self.lastAnalysisResult)
                    LogTiming("CraftQueueController:DoRender", startedAt, string.format(
                        "mode=analysisDetail reason=%s", tostring(reason or "unspecified")
                    ))
                    return
                end
                -- Detail model couldn't be built (e.g. row went stale) - fall
                -- back to the list rather than showing a blank detail pane.
                self.showingAnalysisDetail = false
                self.analysisDetailRow = nil
            end

            -- BuildLimitedAnalysisResult only slices the already-ranked
            -- rows self.lastAnalysisResult already carries (see
            -- ProcessingRecommendationPolicy.RecommendTopNInputsPerOutputFamily) -
            -- never re-evaluates economics/outcome data, so toggling
            -- Top/All Results here is instantaneous.
            local resultToRender = BuildLimitedAnalysisResult(self.lastAnalysisResult, self.analysisShowAllResults)

            -- DIAG: the EXACT object/counts about to cross into
            -- InventoryManagerWindow:RenderAnalysis - if this doesn't match
            -- what BuildLimitedAnalysisResult logged a moment ago, the
            -- divergence is between those two lines (it isn't - nothing
            -- mutates resultToRender in between - but logging both closes
            -- the loop empirically instead of by inspection).
            SessionLog("CraftQueueController:DoRender: DIAG pre-RenderAnalysis reason=%s analysisShowAllResults=%s totalRows=%d perFamily=%s sameTableAsLastResult=%s",
                tostring(reason or "unspecified"), tostring(self.analysisShowAllResults),
                #(resultToRender.rows or {}), DescribeFamilyCounts(resultToRender.rows),
                tostring(resultToRender == self.lastAnalysisResult))
            TraceProcessingAnalysisUI("DoRender.pre-RenderAnalysis",
                "reason=%s analysisShowAllResults=%s totalRows=%d perFamily=%s sameTableAsLastResult=%s",
                tostring(reason or "unspecified"), tostring(self.analysisShowAllResults),
                #(resultToRender.rows or {}), DescribeFamilyCounts(resultToRender.rows),
                tostring(resultToRender == self.lastAnalysisResult))

            window:RenderAnalysis(resultToRender)
            LogTiming("CraftQueueController:DoRender", startedAt, string.format(
                "mode=analysis reason=%s rows=%d",
                tostring(reason or "unspecified"),
                #(resultToRender.rows or {})
            ))
            return
        end
    end

    -- Inventory Manager beta OFF (or a gathering entry): never fall through
    -- to the inventory list. Reached when the selected recipe has no analysis.
    if not IsInventoryBetaEnabled() or self.isGatheringRecipe then
        window:RenderAnalysisUnavailable()
        LogTiming("CraftQueueController:DoRender", startedAt, string.format(
            "mode=analysisUnavailable reason=%s", tostring(reason or "unspecified")
        ))
        return
    end

    local charGUID = currentCharGUID or (PocketCFO.db.char and PocketCFO.db.char.characterGUID)
    if not charGUID then return end

    local queueGen = GetQueueGeneration()
    if not queueGen then return end

    local filterState    = window:GetFilterState()
    local categoryGroups = queueGen:GenerateRows(
        charGUID, currentProfID,
        filterState.showZeroDeficit, filterState.currentExpFilter
    )
    window:Render(categoryGroups, self.highlightedConfigID, charGUID)
    LogTiming("CraftQueueController:DoRender", startedAt, string.format(
        "mode=full reason=%s groups=%d",
        tostring(reason or "unspecified"),
        #categoryGroups
    ))
end

function CraftQueueController:DoInventoryRender()
    local startedAt = DebugTime()
    local window = GetWindow()
    if not window or not window:IsShown() then return end
    if self.viewMode == "analysis" then
        -- Analysis rows are not inventory-driven; an inventory snapshot
        -- update has nothing to refresh while Analysis mode is showing.
        return
    end

    local charGUID = currentCharGUID or (PocketCFO.db.char and PocketCFO.db.char.characterGUID)
    if not charGUID then return end

    local queueGen = GetQueueGeneration()
    if not queueGen then return end

    local filterState = window:GetFilterState()
    local categoryGroups, cacheMiss = nil, nil
    if queueGen.GenerateInventoryRows then
        categoryGroups, cacheMiss = queueGen:GenerateInventoryRows(
            charGUID, currentProfID,
            filterState.showZeroDeficit, filterState.currentExpFilter
        )
    end

    if not categoryGroups then
        LogTiming("CraftQueueController:DoRender", startedAt, "mode=inventory fallback=full cacheMiss=" .. tostring(cacheMiss))
        self:DoRender("inventory-cache-miss")
        return
    end

    window:Render(categoryGroups, self.highlightedConfigID, charGUID)
    LogTiming("CraftQueueController:DoRender", startedAt, string.format(
        "mode=inventory groups=%d",
        #categoryGroups
    ))
end

-- ---------------------------------------------------------------------------
-- Highlight tracking
-- ---------------------------------------------------------------------------

local ShouldRefreshHighlight

local function GetVisibleSchematicForm()
    local craftingPage = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local sf = craftingPage and craftingPage.SchematicForm
    if not sf then return nil end
    if sf.IsShown and not sf:IsShown() then return nil end
    return sf
end

local function RefreshHighlightedConfigFromCurrentWindow(shouldScroll)
    local startedAt = DebugTime()

    -- Lightweight cache: skip CaptureCurrentDraft + FindMatchingSavedConfig when recipe unchanged.
    -- Invalidated by OnTradeSkillClose, OnConfigChanged, and OnTradeSkillUpdate.
    -- GetSchematicRecipeID is defined later in this file, so inline the equivalent here.
    local sf = GetVisibleSchematicForm()
    local _tx = sf and sf.GetTransaction and sf:GetTransaction()
    local recipeID = _tx and _tx.GetRecipeID and _tx:GetRecipeID()
    local configID
    if recipeID and CraftQueueController.lastHighlightDraftKey == recipeID then
        configID = CraftQueueController.lastHighlightConfigID
    else
        local capture = PocketCFO_Crafting:GetModule("RecipeStateCapture", true)
        local store = PocketCFO_Crafting:GetModule("RecipeConfigStore", true)
        configID = nil
        if capture and store and capture.CaptureCurrentDraft and store.FindMatchingSavedConfig then
            local config = capture:CaptureCurrentDraft()
            if config then
                configID = store:FindMatchingSavedConfig(config, PocketCFO.db.char and PocketCFO.db.char.characterGUID)
            end
        end
        CraftQueueController.lastHighlightDraftKey = recipeID
        CraftQueueController.lastHighlightConfigID = configID
    end

    local window = GetWindow()
    if not window then return end

    if CraftQueueController.highlightedConfigID == configID then
        if shouldScroll and configID then
            window:ScrollHighlightedRowIntoView()
        end
        LogTiming("RefreshHighlightedConfigFromCurrentWindow", startedAt, "changed=false")
        return
    end

    CraftQueueController.highlightedConfigID = configID
    if window:IsShown() then
        if shouldScroll and configID then
            window:SetScrollHighlightAfterRender(configID)
        end
        CraftQueueController:DoRender("highlight-change")
    end
    LogTiming("RefreshHighlightedConfigFromCurrentWindow", startedAt, "changed=true")
end

local refreshHighlightPending = false

local function QueueHighlightRefreshNextTick()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, function()
            CraftQueueController:QueueHighlightRefreshFromCurrentWindow(true)
        end)
    else
        CraftQueueController:QueueHighlightRefreshFromCurrentWindow(true)
    end
end

local function RefreshCurrentRecipeMatchDeferred()
    if refreshHighlightPending then return end
    refreshHighlightPending = true
    local function RunRefresh()
        refreshHighlightPending = false
        if ShouldRefreshHighlight() then
            QueueHighlightRefreshNextTick()
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(0, RunRefresh)
    else
        RunRefresh()
    end
end

function ShouldRefreshHighlight()
    local window = GetWindow()
    return window
        and window:IsShown()
        and ProfessionsFrame
        and ProfessionsFrame:IsShown()
end

function CraftQueueController:QueueHighlightRefreshFromCurrentWindow(shouldScrollToHighlight)
    if self.highlightRefreshPending then
        self.highlightRefreshShouldScroll = self.highlightRefreshShouldScroll or shouldScrollToHighlight
        return
    end
    if not ShouldRefreshHighlight() then
        self.highlightRefreshShouldScroll = nil
        return
    end

    self.highlightRefreshShouldScroll = shouldScrollToHighlight
    self.highlightRefreshPending      = true
    local function RunRefresh()
        self.highlightRefreshPending  = false
        local shouldScroll            = self.highlightRefreshShouldScroll
        self.highlightRefreshShouldScroll = nil
        if ShouldRefreshHighlight() then
            RefreshHighlightedConfigFromCurrentWindow(shouldScroll)
        end
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(0, RunRefresh)
    else
        RunRefresh()
    end
end

-- ---------------------------------------------------------------------------
-- Live processing-input analysis refresh (salvage-style selected reagent,
-- e.g. Crushing's gem slot - see ProcessingAnalysisController's "selected
-- reagent slot read live" candidate source)
-- ---------------------------------------------------------------------------
-- Analysis candidates for Crushing/Recycling are read live from the
-- SchematicForm on every EvaluateRecipe call (CraftEventCapture:
-- GetLiveProcessingInputs) - but nothing previously told CraftQueueController
-- *when* to re-run that evaluation after the player changes the selected
-- gem within an already-open recipe. TRADE_SKILL_LIST_UPDATE, pricing
-- updates, and PCFO_VIEWED_RECIPE_CHANGED (a different recipe being
-- selected) don't fire for that. Blizzard's SchematicForm exposes
-- AllocationsModified (CallbackRegistryMixin - confirmed via /mcgd dump of
-- the live form: RegisterCallback/Event.AllocationsModified/TriggerEvent
-- all present) for exactly this: it's the same event the manual salvage
-- picker itself triggers on every allocation change (see
-- "PocketCFO Docs/Processing_Reagent_Load_Lessons_Learned.md").

local analysisInputRefreshPending = false

-- ~0.1s coalescing debounce, not a retry/poll cycle - Blizzard can fire
-- AllocationsModified more than once for a single player action (old
-- allocation clearing, then the new one landing), so one coalesced
-- re-evaluation avoids evaluating candidates/economics twice per swap.
local ANALYSIS_INPUT_REFRESH_DEBOUNCE_SECONDS = 0.1

local function QueueAnalysisInputRefresh()
    if analysisInputRefreshPending then return end
    analysisInputRefreshPending = true
    C_Timer.After(ANALYSIS_INPUT_REFRESH_DEBOUNCE_SECONDS, function()
        analysisInputRefreshPending = false
        CraftQueueController:OnLiveProcessingInputChanged()
    end)
end

-- Reuses the exact same refresh/render entry point onToggleViewMode already
-- calls when switching back into Analysis - no second analysis
-- implementation. Never reuses a stale detail row across an input change:
-- if the row the player was drilled into no longer matches any row in the
-- freshly re-evaluated result (e.g. they swapped from Gem A to Gem B),
-- falls back to the list instead of showing Gem A's data under Gem B's
-- selection.
function CraftQueueController:OnLiveProcessingInputChanged()
    if not self.analysisAvailable or self.viewMode ~= "analysis" then
        return
    end
    local window = GetWindow()
    if not window or not window:IsShown() then
        return
    end

    -- Identity-based (configKey-or-item:itemID), not profile-key-based:
    -- operationProfileKey is shared by every row for this recipe, so it
    -- can't distinguish which specific gem's detail was being viewed once a
    -- family has more than one row - reusing it here previously caused the
    -- selection to jump to whichever row happened to be first after a
    -- reagent (stone/gem) change.
    local previousIdentity = GetAnalysisRowIdentity(self.analysisDetailRow)

    SessionLog("CraftQueueController: live processing input changed, forcing analysis refresh previousIdentity=%s",
        tostring(previousIdentity))

    self:RefreshAnalysisAvailability()

    if self.showingAnalysisDetail then
        local refreshedRow = FindAnalysisRowByIdentity(
            self.lastAnalysisResult and self.lastAnalysisResult.rows, previousIdentity)
        if refreshedRow then
            self.analysisDetailRow = refreshedRow
        else
            self.showingAnalysisDetail = false
            self.analysisDetailRow = nil
        end
    end

    self:DoRender("live-processing-input-changed")
end

-- Live Recipe Analysis rows whose item name was a client cache miss
-- (RecipeAnalysisDisplayModelBuilder's namePending): re-render once the
-- name loads instead of leaving "Unknown reagent". Same Item:ContinueOnItemLoad
-- approach as PocketCFO_Orders' OrdersCompanionController. One pending load
-- per itemID; the refresh goes through the existing debounced input refresh.
function CraftQueueController:ScheduleRecipeNameRefresh(result)
    local itemIDs = type(result) == "table" and result.pendingItemIDs or nil
    if type(itemIDs) ~= "table" or #itemIDs == 0 then return end
    if not Item or type(Item.CreateFromItemID) ~= "function" then return end

    self.pendingRecipeNameLoads = self.pendingRecipeNameLoads or {}
    for _, itemID in ipairs(itemIDs) do
        if not self.pendingRecipeNameLoads[itemID] then
            self.pendingRecipeNameLoads[itemID] = true
            local ok, item = pcall(Item.CreateFromItemID, Item, itemID)
            if ok and item and item.ContinueOnItemLoad then
                item:ContinueOnItemLoad(function()
                    self.pendingRecipeNameLoads[itemID] = nil
                    QueueAnalysisInputRefresh()
                end)
            else
                self.pendingRecipeNameLoads[itemID] = nil
            end
        end
    end
end

-- First-open fix for Prospecting (and every processing analysis): right
-- after a reload the game hasn't sent item details for the ores/gems yet,
-- so pricing can't tell which AH price to use and those rows show "needs
-- price". BeginAnalysisInitialLoad only waits ~3s, and nothing re-ran the
-- analysis when the details arrived later (only an AH scan did), which is
-- why leaving and coming back fixed it.
-- Watches each unpriced item whose details aren't loaded yet; when one
-- loads, re-runs through the same debounced path an AH price update uses
-- (OnPricingUpdated - also handles "analysis not showing right now").
-- Items whose details are already loaded and still have no price genuinely
-- have none, so they are never watched - this cannot loop. One watch per
-- itemID.
function CraftQueueController:ScheduleAnalysisItemDataRefresh(result)
    local rows = type(result) == "table" and result.rows or nil
    if type(rows) ~= "table" or not GetItemInfo then return end
    if not Item or type(Item.CreateFromItemID) ~= "function" then return end

    local builder = GetDisplayModelBuilder()
    local needsPriceReason = (builder and builder.VALUE_UNAVAILABLE_NEEDS_PRICE) or "needsPrice"
    self.pendingAnalysisItemLoads = self.pendingAnalysisItemLoads or {}

    local function Watch(itemID)
        itemID = tonumber(itemID)
        if not itemID or self.pendingAnalysisItemLoads[itemID] then return end
        local okInfo, name = pcall(GetItemInfo, itemID)
        if okInfo and name then return end

        self.pendingAnalysisItemLoads[itemID] = true
        local ok, item = pcall(Item.CreateFromItemID, Item, itemID)
        if ok and item and item.ContinueOnItemLoad then
            item:ContinueOnItemLoad(function()
                self.pendingAnalysisItemLoads[itemID] = nil
                SessionLog("CraftQueueController: item data loaded itemID=%s, re-running analysis", tostring(itemID))
                self:OnPricingUpdated(nil, nil, itemID, "itemDataLoaded")
            end)
        else
            self.pendingAnalysisItemLoads[itemID] = nil
        end
    end

    for _, row in ipairs(rows) do
        if row.valueUnavailableReason == needsPriceReason then
            Watch(row.itemID)
            local missing = type(row.summary) == "table" and row.summary.missingValues or nil
            for _, missingValue in ipairs(type(missing) == "table" and missing or {}) do
                Watch(type(missingValue) == "table" and missingValue.itemID or nil)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Schematic form hook installation (highlight tracking on reagent changes)
-- ---------------------------------------------------------------------------

local function HookQualityDialogButton(button)
    if not button or not button.HookScript or button.__mcgCFOQualityDialogHooked then
        return
    end
    button:HookScript("OnClick", function()
        RefreshCurrentRecipeMatchDeferred()
    end)
    button.__mcgCFOQualityDialogHooked = true
end

local function IsQualityDialogContainer(frame)
    if not frame then return false end
    local debugName, name = nil, nil
    if frame.GetDebugName then
        local ok, result = pcall(frame.GetDebugName, frame)
        if ok then debugName = result end
    end
    if frame.GetName then
        local ok, result = pcall(frame.GetName, frame)
        if ok then name = result end
    end
    local label = tostring(debugName or name or frame)
    return label:find("QualityDialog%.Container", 1, false) ~= nil
        or label:find("QualityDialog.Container",  1, true)  ~= nil
end

local function InstallQualityDialogHighlightHooks()
    local qd = ProfessionsFrame
        and ProfessionsFrame.CraftingPage
        and ProfessionsFrame.CraftingPage.SchematicForm
        and ProfessionsFrame.CraftingPage.SchematicForm.QualityDialog
    if not qd then return end

    HookQualityDialogButton(qd.AcceptButton)

    if qd.HookScript and not qd.__mcgCFOQualityDialogOnShowHooked then
        qd:HookScript("OnShow", function()
            InstallQualityDialogHighlightHooks()
        end)
        qd.__mcgCFOQualityDialogOnShowHooked = true
    end

    if qd.GetChildren then
        for _, child in ipairs({ qd:GetChildren() }) do
            if IsQualityDialogContainer(child) and child.Button then
                HookQualityDialogButton(child.Button)
            end
        end
    end
end

local function InstallConcentrationHighlightHook(sf)
    local button = sf
        and sf.Details
        and sf.Details.CraftingChoicesContainer
        and sf.Details.CraftingChoicesContainer.ConcentrateContainer
        and sf.Details.CraftingChoicesContainer.ConcentrateContainer.ConcentrateToggleButton

    if button and button.HookScript and not button.__mcgCFOConcentrationRefreshHooked then
        button:HookScript("OnClick", function()
            QueueHighlightRefreshNextTick()
            -- Concentration changes the predicted output quality (and so
            -- Live Recipe Analysis' output value) without changing any
            -- allocation, so AllocationsModified does not cover it.
            QueueAnalysisInputRefresh()
        end)
        button.__mcgCFOConcentrationRefreshHooked = true
    end
end

local function InstallBestQualityHighlightHook(sf)
    local checkbox = sf and sf.AllocateBestQualityCheckbox
    if checkbox and checkbox.HookScript and not checkbox.__mcgCFOBestQualityRefreshHooked then
        checkbox:HookScript("OnClick", function()
            QueueHighlightRefreshNextTick()
            -- Swapping to/from best-quality mats must re-run Live Recipe
            -- Analysis; AllocationsModified alone did not refresh it in-game.
            QueueAnalysisInputRefresh()
        end)
        checkbox.__mcgCFOBestQualityRefreshHooked = true
    end
end

-- Fires for every reagent allocation change on the form, including the
-- salvage-style selected-gem slot Crushing/Recycling read live for
-- Analysis - see the "Live processing-input analysis refresh" section
-- above. Installed once per SchematicForm instance (a singleton Blizzard
-- reuses across recipe selections), same guard pattern as the highlight
-- hooks above.
local function InstallAllocationsModifiedRefreshHook(sf)
    if not sf or not sf.RegisterCallback or not sf.Event or not sf.Event.AllocationsModified then
        return
    end
    if sf.__mcgCFOAllocationsModifiedRefreshHooked then
        return
    end
    sf:RegisterCallback(sf.Event.AllocationsModified, function()
        QueueAnalysisInputRefresh()
    end, CraftQueueController)
    sf.__mcgCFOAllocationsModifiedRefreshHooked = true
end

local function InstallSchematicFormHighlightHooks()
    if not hooksecurefunc then return end
    -- Hooking reusable reagent slot methods and parent mouse scripts can corrupt
    -- Blizzard's crafting hit-test state across recipe changes. Reagent commits are
    -- detected through QualityDialog AcceptButton and Container*.Button paths instead.
    local sf = GetVisibleSchematicForm()
    InstallQualityDialogHighlightHooks()
    InstallConcentrationHighlightHook(sf)
    InstallBestQualityHighlightHook(sf)
    InstallAllocationsModifiedRefreshHook(sf)
end

-- ---------------------------------------------------------------------------
-- Visible schematic details refresh (called after inventory changes while
-- the crafting window is open, to reload the config for the visible recipe)
-- ---------------------------------------------------------------------------

local function GetSchematicRecipeID(sf)
    if not sf or not sf.GetTransaction then return nil end
    local transaction = sf:GetTransaction()
    if not transaction or not transaction.GetRecipeID then return nil end
    return transaction:GetRecipeID()
end

local function FindConfigForRecipe(recipeID)
    if not recipeID then return nil end
    local charGUID = currentCharGUID or (PocketCFO.db.char and PocketCFO.db.char.characterGUID)
    local store = PocketCFO_Crafting:GetModule("RecipeConfigStore", true)
    local configs = store and store.GetConfigurations
        and store:GetConfigurations(charGUID, currentProfID)
        or {}
    for configID, config in pairs(configs) do
        if config
        and config.recipeID == recipeID
        and (not charGUID    or config.characterGUID == charGUID)
        and (not currentProfID or config.professionID == currentProfID) then
            return config.configID or configID, config
        end
    end
    return nil
end

local function RefreshVisibleSchematicDetails(allowRestore)
    local startedAt = DebugTime()
    local sf = GetVisibleSchematicForm()
    if not sf then return end

    local recipeID = GetSchematicRecipeID(sf)
    local configID = FindConfigForRecipe(recipeID)

    if configID and allowRestore then
        local targetEvaluator = PocketCFO_Crafting:GetModule("InventoryTargetEvaluator", true)
        local result   = targetEvaluator and targetEvaluator.CalculateOne and targetEvaluator:CalculateOne(configID)
        local quantity = result and result.deficit and result.deficit > 0 and result.deficit or 1
        PocketCFO_Crafting:GetModule("RecipeStateRestore"):LoadConfigIntoCraftingWindow(configID, quantity)
        LogTiming("RefreshVisibleSchematicDetails", startedAt, "restore=true configID=" .. tostring(configID))
        return
    end

    if configID and sf.UpdateAllSlots then
        pcall(function() sf:UpdateAllSlots() end)
    end
    LogTiming("RefreshVisibleSchematicDetails", startedAt, string.format(
        "restore=false matchedConfig=%s",
        tostring(configID ~= nil)
    ))
end

-- ---------------------------------------------------------------------------
-- Module lifecycle
-- ---------------------------------------------------------------------------

function CraftQueueController:OnEnable()
    local window = GetWindow()
    if window then
        window:Build({
            onRerender = function()
                self:DoRender("window-filter")
            end,
            onLoadConfig = function(configID, quantity)
                PocketCFO_Crafting:GetModule("RecipeStateRestore"):LoadConfigIntoCraftingWindow(configID, quantity)
                self.pendingCraftConfigID = configID
                PocketCFO:Debug("CraftQueueController: loaded configID=%s quantity=%d", configID, quantity)
            end,
            onDeleteConfig = function(configID, itemName)
                MCGCFO_ShowDeleteDialog(configID, itemName)
            end,
            onPostingRulesToggle = function()
                local rulesWindow = PocketCFO_Crafting:GetModule("RecipePostingRulesWindow", true)
                local win = GetWindow()
                if rulesWindow and rulesWindow.Toggle then
                    rulesWindow:Toggle(win and win:GetFrame())
                    if win then win:UpdatePostingRulesButton() end
                end
            end,
            onPostingProfilesToggle = function()
                local profilesWindow = PocketCFO_Crafting:GetModule("PostingProfilesWindow", true)
                local win = GetWindow()
                if profilesWindow and profilesWindow.Toggle then
                    profilesWindow:Toggle(win and win:GetFrame())
                    if win then win:UpdatePostingProfilesButton() end
                end
            end,
            onToggleViewMode = function()
                if not self.analysisAvailable then return end
                self.viewMode = (self.viewMode == "analysis") and "inventory" or "analysis"
                self.preferredViewMode = self.viewMode
                self.showingAnalysisDetail = false
                self.analysisDetailRow = nil
                local win = GetWindow()
                if win then win:SetAnalysisToggleMode(self.viewMode) end

                if self.viewMode == "analysis" then
                    -- Never repaint the old self.lastAnalysisResult on entry -
                    -- re-evaluate so a price that arrived while Inventory was
                    -- showing (see OnPricingUpdated's analysisPricingDirty)
                    -- is picked up immediately, not just when it happened to
                    -- arrive while Analysis was already active.
                    SessionLog("CraftQueueController: toggle -> analysis, forcing refresh reason=view-mode-toggle dirty=%s",
                        tostring(self.analysisPricingDirty))
                    self:RefreshAnalysisAvailability()
                end

                -- RefreshAnalysisAvailability already does this when the
                -- analysis branch above runs; also needed on the
                -- analysis->inventory leg, which doesn't call it, so the
                -- results-toggle button hides immediately.
                self:UpdateAnalysisResultsToggleUI()
                self:DoRender("view-mode-toggle")
            end,
            onSelectAnalysisRow = function(row)
                if not self.analysisAvailable or not row then return end
                self.showingAnalysisDetail = true
                self.analysisDetailRow = row
                self:DoRender("analysis-row-selected")
            end,
            onAnalysisDetailBack = function()
                self.showingAnalysisDetail = false
                self.analysisDetailRow = nil
                self:DoRender("analysis-detail-back")
            end,
            onToggleAnalysisResults = function()
                local beforeState = self.analysisShowAllResults == true
                SessionLog("CraftQueueController:onToggleAnalysisResults: DIAG clicked analysisAvailable=%s viewMode=%s hasLastResult=%s hasOutputFamilies=%s before=%s",
                    tostring(self.analysisAvailable), tostring(self.viewMode),
                    tostring(self.lastAnalysisResult ~= nil),
                    tostring(self.lastAnalysisResult and self.lastAnalysisResult.hasOutputFamilies),
                    tostring(beforeState))
                TraceProcessingAnalysisUI("onToggleAnalysisResults.entry",
                    "analysisAvailable=%s viewMode=%s hasLastResult=%s hasOutputFamilies=%s before=%s",
                    tostring(self.analysisAvailable), tostring(self.viewMode),
                    tostring(self.lastAnalysisResult ~= nil),
                    tostring(self.lastAnalysisResult and self.lastAnalysisResult.hasOutputFamilies),
                    tostring(beforeState))

                if not self.analysisAvailable or self.viewMode ~= "analysis" then return end
                if not self.lastAnalysisResult or not self.lastAnalysisResult.supportsResultsLimit then return end

                -- Pure presentation toggle - flips which slice of the
                -- already-ranked rows to show. Never calls EvaluateRecipe or
                -- any economics/outcome service (see BuildLimitedAnalysisResult).
                self.analysisShowAllResults = not self.analysisShowAllResults
                SessionLog("CraftQueueController:onToggleAnalysisResults: DIAG after=%s", tostring(self.analysisShowAllResults))
                TraceProcessingAnalysisUI("onToggleAnalysisResults.after",
                    "analysisShowAllResults=%s", tostring(self.analysisShowAllResults))

                if self.showingAnalysisDetail and self.analysisDetailRow then
                    local identity = GetAnalysisRowIdentity(self.analysisDetailRow)
                    local limitedResult = BuildLimitedAnalysisResult(self.lastAnalysisResult, self.analysisShowAllResults)
                    if not FindAnalysisRowByIdentity(limitedResult.rows, identity) then
                        -- Row dropped out of the now-visible slice (e.g.
                        -- switched to Top Results and this row ranked #4+) -
                        -- return to the grouped list rather than leaving a
                        -- stale detail-row reference.
                        self.showingAnalysisDetail = false
                        self.analysisDetailRow = nil
                    end
                end

                self:UpdateAnalysisResultsToggleUI()
                self:DoRender("analysis-results-toggle")
            end,
        })
    end

    self:RegisterEvent("TRADE_SKILL_CLOSE",      "OnTradeSkillClose")
    self:RegisterEvent("TRADE_SKILL_LIST_UPDATE", "OnTradeSkillUpdate")

    self:RegisterMessage("MCGCFO_CONFIG_SAVED",                       "OnConfigChanged")
    self:RegisterMessage("MCGCFO_CONFIG_UPDATED",                     "OnConfigChanged")
    self:RegisterMessage("MCGCFO_CONFIG_DELETED",                     "OnConfigChanged")
    self:RegisterMessage("MCGCFO_INVENTORY_SNAPSHOT_UPDATED",         "OnInventorySnapshotUpdated")
    self:RegisterMessage("MCGCFO_POSTING_RULES_WINDOW_CHANGED",       "OnPostingRulesWindowChanged")
    self:RegisterMessage("MCGCFO_POSTING_PROFILES_WINDOW_CHANGED",    "OnPostingProfilesWindowChanged")
    self:RegisterMessage("PCFO_CONFIG_LOADED_INTO_CRAFTING_WINDOW",   "OnConfigLoadedIntoCraftingWindow")
    self:RegisterMessage("PCFO_VIEWED_RECIPE_CHANGED",                "OnViewedRecipeChanged")
    self:RegisterMessage("PCFO_PRICING_UPDATED",                      "OnPricingUpdated")
    self:RegisterMessage("PCFO_OPERATION_OUTCOME_UPDATED",            "OnOperationOutcomeUpdated")
    self:RegisterMessage("PCFO_SETTINGS_CHANGED",                     "OnSettingsChanged")
end

-- A beta toggle flipped in the settings panel. Applies immediately, no
-- /reload: closes the posting windows when Auction House beta turns off, and
-- re-runs the view-mode rules so the Inventory/Analysis toggle and current
-- view match the Inventory Manager beta flag.
function CraftQueueController:OnSettingsChanged()
    if not IsAuctionHouseBetaEnabled() then
        local rulesWindow = PocketCFO_Crafting:GetModule("RecipePostingRulesWindow", true)
        if rulesWindow and rulesWindow.IsOpen and rulesWindow:IsOpen() and rulesWindow.CloseForTradeSkillClose then
            rulesWindow:CloseForTradeSkillClose()
        end
        local profilesWindow = PocketCFO_Crafting:GetModule("PostingProfilesWindow", true)
        if profilesWindow and profilesWindow.IsOpen and profilesWindow:IsOpen() and profilesWindow.CloseForTradeSkillClose then
            profilesWindow:CloseForTradeSkillClose()
        end
    end

    local window = GetWindow()
    if not window or not window:IsShown() then return end
    self:RefreshAnalysisAvailability()
    self:DoRender("settings-changed")
    window:UpdatePostingRulesButton()
    window:UpdatePostingProfilesButton()
end

-- PocketCFO_Valuation's PricingCache broadcasts this whenever a market key
-- gets a price (from AH search-result browsing or a full scan) - the only
-- way Prospecting Analysis previously found out about a newly-resolved price
-- was an unrelated recipe reselect happening to re-run RefreshAnalysisAvailability.
-- Only matters in Analysis mode; Inventory mode doesn't display prices.
--
-- When Analysis isn't the currently visible view, the update is not dropped
-- outright - self.analysisPricingDirty is set so the next switch into
-- Analysis (onToggleViewMode) knows to force a fresh evaluation instead of
-- repainting the stale self.lastAnalysisResult. RefreshAnalysisAvailability
-- clears the flag itself whenever it actually runs.
function CraftQueueController:OnPricingUpdated(_, marketKey, itemID, source)
    SessionLog("CraftQueueController: PCFO_PRICING_UPDATED received marketKey=%s itemID=%s source=%s viewMode=%s",
        tostring(marketKey), tostring(itemID), tostring(source), tostring(self.viewMode))

    if pricingRefreshPending then return end
    pricingRefreshPending = true

    C_Timer.After(PRICING_REFRESH_DEBOUNCE_SECONDS, function()
        pricingRefreshPending = false

        local window = GetWindow()
        local analysisActive = self.analysisAvailable
            and self.viewMode == "analysis"
            and window ~= nil and window:IsShown()

        if not analysisActive then
            self.analysisPricingDirty = true
            SessionLog("CraftQueueController: pricing-updated deferred reason=analysis-not-active analysisAvailable=%s viewMode=%s windowShown=%s",
                tostring(self.analysisAvailable), tostring(self.viewMode), tostring(window ~= nil and window:IsShown()))
            return
        end

        SessionLog("CraftQueueController: rerender triggered reason=pricing-updated")
        self:RefreshAnalysisAvailability()
        self:DoRender("pricing-updated")
    end)
end

-- A completed craft changed the underlying statistical data (a new/updated
-- Statistical Profile in OperationOutcomeService) - this must re-run
-- EvaluateRecipe (candidate discovery + economics), not just rerender
-- self.lastAnalysisResult. This is intentionally different from the Show
-- All/Show Top toggle (onToggleAnalysisResults), which must never
-- re-evaluate. Refreshes whenever the update is for the recipe currently
-- being analyzed in Analysis mode - list or detail - so a newly-crafted
-- gem/ore appears without reselecting the recipe or reopening the window.
--
-- Matched by recipeID (update.recipeID, already carried on the message),
-- NOT by rebuilding/comparing the full operationProfileKey. "Evaluate all
-- inputs" processing types (Prospecting, Milling) use
-- PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT, so their operationProfileKey
-- embeds one specific ore's configKey - but their Analysis view shows every
-- registered ore for the recipe at once, so there is no single "currently
-- selected ore" to rebuild that key from (profileKeyService:BuildKey(recipeID)
-- with no primary input option always returns unresolved for that mode).
-- recipeID is the granularity self.lastEvaluatedRecipeID already tracks and
-- the view is actually scoped to, for every processing type.
function CraftQueueController:OnOperationOutcomeUpdated(_, update)
    local updatedRecipeID = type(update) == "table" and update.recipeID or nil
    local currentRecipeID = self.lastEvaluatedRecipeID

    SessionLog("CraftQueueController: PCFO_OPERATION_OUTCOME_UPDATED received profileKey=%s recipeID=%s currentRecipeID=%s viewMode=%s showingDetail=%s",
        tostring(type(update) == "table" and update.operationProfileKey),
        tostring(updatedRecipeID),
        tostring(currentRecipeID),
        tostring(self.viewMode),
        tostring(self.showingAnalysisDetail))

    local window = GetWindow()
    if not updatedRecipeID
    or updatedRecipeID ~= currentRecipeID
    or not self.analysisAvailable
    or self.viewMode ~= "analysis"
    or not window
    or not window:IsShown() then
        return
    end

    -- self.analysisShowAllResults is NOT touched by RefreshAnalysisAvailability
    -- unless the selected recipeID changed (it hasn't here - same recipe,
    -- new observation), so the current Show All/Show Top state survives
    -- this refresh untouched.
    self:RefreshAnalysisAvailability()

    if self.showingAnalysisDetail and self.analysisDetailRow then
        -- Identity-based (configKey-or-item:itemID), not profile-key-based:
        -- operationProfileKey is shared by every row in this recipe, so it
        -- can't distinguish which specific gem's detail was being viewed
        -- once a family has more than one row.
        local previousIdentity = GetAnalysisRowIdentity(self.analysisDetailRow)
        local refreshedRow = FindAnalysisRowByIdentity(
            self.lastAnalysisResult and self.lastAnalysisResult.rows, previousIdentity)
        if refreshedRow then
            self.analysisDetailRow = refreshedRow
        else
            self.showingAnalysisDetail = false
            self.analysisDetailRow = nil
        end
    end

    self:DoRender("operation-outcome-updated")
end

function CraftQueueController:QueueInventoryRefresh()
    if self.inventoryRefreshPending or self.inventoryRefreshRunning then return end
    self.inventoryRefreshPending = true

    C_Timer.After(INVENTORY_REFRESH_DEBOUNCE_SECONDS, function()
        self.inventoryRefreshPending = false
        local window = GetWindow()
        if window and window:IsShown() then
            self.inventoryRefreshRunning = true
            self:DoInventoryRender()
            RefreshVisibleSchematicDetails(false)
            window:RefreshActiveTooltip()
            self.inventoryRefreshRunning = false
        end
    end)
end

function CraftQueueController:OnTradeSkillShow()
    local contextService = GetProfessionContextService()
    local context   = contextService and contextService:GetCurrentProfessionContext() or {}
    currentProfID   = context.professionID
    currentCharGUID = PocketCFO.db.char and PocketCFO.db.char.characterGUID

    local window = GetWindow()
    if not window then return end

    if IsHiddenGatheringProfessionContext(context) then
        window:Hide()
        return
    end

    window:ResetExpFilter()

    local wasShown = window:IsShown()
    if not wasShown then
        window:Position()
    end
    window:Show()

    if not wasShown then
        ScanBagsOnOpen()
    end

    InstallSchematicFormHighlightHooks()
    -- Idempotent retry: PocketCFO_Crafting:InstallSelectRecipeHook() is also
    -- attempted once at addon OnEnable, but if CraftingPage wasn't ready yet
    -- at that point it silently no-ops with no retry. Without this hook,
    -- PCFO_VIEWED_RECIPE_CHANGED never fires on recipe selection, so
    -- RefreshAnalysisAvailability never re-runs after the initial forced
    -- Inventory view - the toggle would never appear. Guarded by
    -- __pcfoSelectRecipeHooked, so this is a no-op once installed.
    if PocketCFO_Crafting.InstallSelectRecipeHook then
        PocketCFO_Crafting:InstallSelectRecipeHook()
    end

    -- Resolve highlight inline before the first render to avoid a second full render.
    -- Also seeds the highlight cache (Fix 4) so subsequent calls get a cache hit.
    do
        local capture = PocketCFO_Crafting:GetModule("RecipeStateCapture", true)
        local store   = PocketCFO_Crafting:GetModule("RecipeConfigStore", true)
        local resolvedID = nil
        if capture and store and capture.CaptureCurrentDraft and store.FindMatchingSavedConfig then
            local draft = capture:CaptureCurrentDraft()
            if draft then
                resolvedID = store:FindMatchingSavedConfig(draft, currentCharGUID)
            end
        end
        self.highlightedConfigID   = resolvedID
        local sf2 = GetVisibleSchematicForm()
        local tx2 = sf2 and sf2.GetTransaction and sf2:GetTransaction()
        self.lastHighlightDraftKey = tx2 and tx2.GetRecipeID and tx2:GetRecipeID()
        self.lastHighlightConfigID = resolvedID
    end
    -- The profession window opens on Analysis whenever the selected recipe
    -- has one (recipeChanged is always true here - OnTradeSkillClose clears
    -- lastEvaluatedRecipeID). Without analysis it opens on Inventory if the
    -- Inventory Manager beta is on, otherwise on the "no analysis" message.
    self:RefreshAnalysisAvailability()
    self:DoRender("trade-skill-show")

    local rulesWindow = PocketCFO_Crafting:GetModule("RecipePostingRulesWindow", true)
    if IsAuctionHouseBetaEnabled() and rulesWindow and rulesWindow.ShouldAutoOpen and rulesWindow:ShouldAutoOpen() then
        rulesWindow:Show(window:GetFrame())
    end
    window:UpdatePostingRulesButton()
    window:UpdatePostingProfilesButton()
end

function CraftQueueController:OnTradeSkillClose()
    local window = GetWindow()
    if window then window:Hide() end

    local rulesWindow = PocketCFO_Crafting:GetModule("RecipePostingRulesWindow", true)
    if rulesWindow and rulesWindow.CloseForTradeSkillClose then
        rulesWindow:CloseForTradeSkillClose()
    end
    local profilesWindow = PocketCFO_Crafting:GetModule("PostingProfilesWindow", true)
    if profilesWindow and profilesWindow.CloseForTradeSkillClose then
        profilesWindow:CloseForTradeSkillClose()
    end

    currentProfID              = nil
    self.pendingCraftConfigID  = nil
    self.inFlightCraftMode     = nil
    self.highlightedConfigID   = nil
    self.lastHighlightDraftKey = nil
    self.lastHighlightConfigID = nil
    self.analysisAvailable     = nil
    self.isGatheringRecipe     = nil
    self.viewMode              = "inventory"
    self.lastAnalysisResult    = nil
    self.lastEvaluatedRecipeID = nil
    self.showingAnalysisDetail = false
    self.analysisDetailRow     = nil
    self.analysisPricingDirty  = nil
    -- Profession window closing ends this analysis context entirely - Top
    -- Results/All Results resets so the next window-open session starts
    -- back at the default.
    self.analysisShowAllResults = nil
    -- New crafting-window session: the MVP loading sequence should run
    -- again the next time Analysis mode opens. analysisLoadToken = nil
    -- invalidates any BeginAnalysisInitialLoad timer still pending from the
    -- session that just closed, so it can't stomp on the new session's state.
    self.analysisInitialLoadDone       = nil
    self.analysisInitialLoadInProgress = nil
    self.analysisInitialRetryDone      = nil
    self.analysisLoadToken             = nil
    if window then window:ClearState() end
end

function CraftQueueController:OnTradeSkillUpdate()
    if self.renderPending then return end
    self.renderPending = true
    C_Timer.After(0.2, function()
        self.renderPending = false
        self.lastHighlightDraftKey = nil
        local contextService = GetProfessionContextService()
        local context = contextService and contextService:GetCurrentProfessionContext() or {}
        currentProfID = context.professionID
        local window = GetWindow()
        if IsHiddenGatheringProfessionContext(context) then
            if window then window:Hide() end
            return
        end
        InstallSchematicFormHighlightHooks()
        self:RefreshAnalysisAvailability()
        self:DoRender("trade-skill-update")
        RefreshHighlightedConfigFromCurrentWindow()
    end)
end

function CraftQueueController:OnConfigChanged()
    self.lastHighlightDraftKey = nil
    local window = GetWindow()
    if window and window:IsShown() then
        self:DoRender("config-changed")
        RefreshHighlightedConfigFromCurrentWindow()
    end
end

function CraftQueueController:OnConfigLoadedIntoCraftingWindow(message, configID)
    self.highlightedConfigID = configID
    local window = GetWindow()
    if window and window:IsShown() then
        self:DoRender("config-loaded")
    end
end

function CraftQueueController:OnViewedRecipeChanged(message, recipeID, source)
    SessionLog("OnViewedRecipeChanged: recipeID=%s source=%s", tostring(recipeID), tostring(source))
    InstallSchematicFormHighlightHooks()
    self:RefreshAnalysisAvailability()

    local window = GetWindow()
    if window and window:IsShown() then
        self:DoRender("viewed-recipe-changed")
    end

    self:QueueHighlightRefreshFromCurrentWindow(true)
end

function CraftQueueController:OnPostingRulesWindowChanged()
    local window = GetWindow()
    if window then window:UpdatePostingRulesButton() end
end

function CraftQueueController:OnPostingProfilesWindowChanged()
    local window = GetWindow()
    if window then window:UpdatePostingProfilesButton() end
end

function CraftQueueController:OnInventorySnapshotUpdated()
    self:QueueInventoryRefresh()
end

-- ---------------------------------------------------------------------------
-- Public API (slash commands, external callers)
-- ---------------------------------------------------------------------------

function CraftQueueController:Show()
    local contextService = GetProfessionContextService()
    local context = contextService and contextService:GetCurrentProfessionContext() or {}
    local window  = GetWindow()
    if not window then return end

    if IsHiddenGatheringProfessionContext(context) then
        window:Hide()
        return
    end

    currentProfID   = context.professionID
    currentCharGUID = PocketCFO.db.char and PocketCFO.db.char.characterGUID

    if not window:IsShown() then
        window:Position()
    end
    window:Show()
    InstallSchematicFormHighlightHooks()
    ScanBagsOnOpen()

    -- Inline highlight resolution before render (Fix 2) + seed cache (Fix 4).
    do
        local charGUID2 = currentCharGUID or (PocketCFO.db.char and PocketCFO.db.char.characterGUID)
        local capture = PocketCFO_Crafting:GetModule("RecipeStateCapture", true)
        local store   = PocketCFO_Crafting:GetModule("RecipeConfigStore", true)
        local resolvedID = nil
        if capture and store and capture.CaptureCurrentDraft and store.FindMatchingSavedConfig then
            local draft = capture:CaptureCurrentDraft()
            if draft then
                resolvedID = store:FindMatchingSavedConfig(draft, charGUID2)
            end
        end
        self.highlightedConfigID   = resolvedID
        local sf2 = GetVisibleSchematicForm()
        local tx2 = sf2 and sf2.GetTransaction and sf2:GetTransaction()
        self.lastHighlightDraftKey = tx2 and tx2.GetRecipeID and tx2:GetRecipeID()
        self.lastHighlightConfigID = resolvedID
    end
    self:DoRender("show")

    local rulesWindow = PocketCFO_Crafting:GetModule("RecipePostingRulesWindow", true)
    if IsAuctionHouseBetaEnabled() and rulesWindow and rulesWindow.ShouldAutoOpen and rulesWindow:ShouldAutoOpen() then
        rulesWindow:Show(window:GetFrame())
    end
    window:UpdatePostingRulesButton()
    window:UpdatePostingProfilesButton()
end

function CraftQueueController:Refresh()
    self:DoRender("manual-refresh")
end

function CraftQueueController:ScrollHighlightedRowIntoView()
    local window = GetWindow()
    if window then window:ScrollHighlightedRowIntoView() end
end
