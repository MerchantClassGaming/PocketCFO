-- PocketCFO_Crafting/Crafting/ProcessingAnalysisController.lua
-- Crafting-owned Processing Analysis evaluator.
--
-- For a Processing Operation recipe, enumerates the recipe's valid primary
-- inputs, builds an Operation Summary for each candidate via Core's
-- OperationEconomicsService, applies the processing type's recommendation
-- policy, and returns ready-to-render display rows.
--
-- Candidate source depends on the policy:
--   EvaluateAllInputs (Prospecting, Milling) - "show every valid input"
--     policies must not depend on whatever the player currently has
--     selected in the Blizzard reagent slot. Candidates come from Core's
--     ProcessingOperationRegistry:GetKnownPrimaryInputs (curated, verified
--     data), never the live schematic. An empty registry list is honest
--     content ("no inputs registered yet"), not an evaluation failure.
--   RecommendTopNPerOutputFamily (Crushing) - "compare every known observed
--     gem" also must not depend on the currently selected reagent slot (that
--     dependency previously caused a 20-30s render delay tied to Blizzard's
--     salvage-slot detection). Candidates come from every Statistical
--     Profile already stored in OperationOutcomeService for this recipe's
--     operation profile key (see GetObservedStatisticalProfileCandidates) -
--     never the live SchematicForm/transaction.
--   Everything else (Recycling) - the selected reagent slot is still read
--     live, since that policy uses the current selection as cost evidence
--     by design (see ProcessingOperationRegistry inputRoles).
--
-- This is the single reusable evaluator. Different processing behaviors are
-- policies (ProcessingRecommendationPolicy), never a different evaluator
-- architecture.
--
-- Driven by CraftQueueController's PCFO_VIEWED_RECIPE_CHANGED handler (see
-- PocketCFO_Crafting/Init.lua and Crafting/CraftQueueController.lua), which
-- owns the Inventory/Analysis view-mode state and calls EvaluateCurrentRecipe
-- on every recipe selection.
--
-- Only recipeIDs curated into Core's ProcessingOperationRegistry resolve as
-- Processing Operations; everything else resolves as a Crafting Operation
-- and returns applicable=false, reason="notAProcessingOperation". That is
-- the correct, honest state for an unregistered recipe - not a bug here.

-- Patch compat: Blizzard removed the global item APIs; route to C_Item.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local ADDON_NAME, _ = ...
local PocketCFO          = _G.PocketCFO
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local ProcessingAnalysisController = PocketCFO_Crafting:NewModule("ProcessingAnalysisController")

local function SessionLog(fmt, ...)
    if not PocketCFO or not PocketCFO.AppendSessionLog then return end
    local msg = tostring(fmt or "")
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end
    PocketCFO:AppendSessionLog("[MCG] " .. msg)
end

local function GetProfessionContextService()
    return PocketCFO_Crafting:GetModule("ProfessionContextService", true)
end

local function GetAnalysisRegistry()
    return PocketCFO_Crafting:GetModule("ProcessingAnalysisRegistry", true)
end

local function GetRecommendationPolicy()
    return PocketCFO_Crafting:GetModule("ProcessingRecommendationPolicy", true)
end

local function GetDisplayModelBuilder()
    return PocketCFO_Crafting:GetModule("ProcessingAnalysisDisplayModelBuilder", true)
end

local function GetProcessingOperationRegistry()
    return PocketCFO and PocketCFO.ProcessingOperationRegistry or _G.PocketCFO_ProcessingOperationRegistry
end

local function GetProfileKeyService()
    return PocketCFO and PocketCFO.OperationProfileKeyService or _G.PocketCFO_OperationProfileKeyService
end

local function GetEconomicsService()
    return PocketCFO and PocketCFO.OperationEconomicsService or _G.PocketCFO_OperationEconomicsService
end

local function GetOutcomeService()
    return PocketCFO and PocketCFO.OperationOutcomeService or _G.PocketCFO_OperationOutcomeService
end

local function GetItemIdentityService()
    return PocketCFO and PocketCFO.ItemIdentityService or _G.ItemIdentityService
end

local function GetIdentityAdapters()
    return PocketCFO and PocketCFO.ItemIdentityAdapters or _G.PocketCFO_ItemIdentityAdapters
end

-- Resolves a dedicated per-processing-type policy module by naming
-- convention: "prospecting" -> "ProspectingAnalysisPolicy". Silent lookup -
-- processing types with no dedicated policy module (e.g. crushing, which
-- still runs entirely on the generic Registry+RecommendationPolicy path)
-- simply get nil back here and fall through to the registry's label.
local function GetDedicatedPolicyModule(processingType)
    if not processingType or processingType == "" then
        return nil
    end
    local moduleName = processingType:sub(1, 1):upper() .. processingType:sub(2) .. "AnalysisPolicy"
    return PocketCFO_Crafting:GetModule(moduleName, true)
end

local function NewResult(applicable, reason, extra)
    local result = {
        applicable = applicable == true,
        reason = reason,
        rows = {},
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            result[k] = v
        end
    end
    return result
end

local function GetCraftEventCapture()
    return PocketCFO_Crafting:GetModule("CraftEventCapture", true)
end

-- Finds the input flagged statisticalProfile/selectedCostInput in the
-- registry's inputRoles - the "current selection" role Crushing/Recycling
-- read live (see ProcessingOperationRegistry inputRoles), as opposed to the
-- fixedCatalyst role (e.g. Crushing's Duskshrouded Stone), which is never a
-- candidate to compare.
local function FindSelectedInput(inputs)
    for _, input in ipairs(type(inputs) == "table" and inputs or {}) do
        if type(input) == "table" and (input.statisticalProfile == true or input.selectedCostInput == true) then
            return input
        end
    end
    return nil
end

-- Resolves the single currently-selected primary input for "selected
-- reagent slot read live" policies (Crushing, Recycling). These operations
-- are salvage-style: Blizzard does not enumerate a static candidate list in
-- C_TradeSkillUI.GetRecipeSchematic's reagentSlotSchematics[].reagents (the
-- same reason Prospecting could not rely on it either - see
-- "PocketCFO Docs/Processing_Reagent_Load_Lessons_Learned.md"). The only
-- reliable source of "what's selected right now" is CraftEventCapture's
-- live transaction/slot-frame read, already proven correct by real captured
-- craft completions - reused here rather than re-deriving a second,
-- possibly-divergent reading of the same live UI state.
local function GetPrimaryInputCandidates(recipeID)
    local capture = GetCraftEventCapture()
    if not capture or not capture.GetLiveProcessingInputs then
        return {}, "captureUnavailable"
    end

    local inputs, reason = capture:GetLiveProcessingInputs(recipeID, "ProcessingAnalysis")
    local selected = FindSelectedInput(inputs)
    if not selected or not selected.itemID then
        return {}, reason or "noSelectedInput"
    end

    return { { itemID = selected.itemID, name = selected.itemName, itemLink = selected.itemLink } }, nil
end

-- Candidate source for policies that compare every known OBSERVED
-- Statistical Profile rather than the live-selected reagent (Crushing).
-- Never touches C_TradeSkillUI, the SchematicForm, or its transaction - it
-- reads directly from OperationOutcomeService's already-built Statistical
-- Profile views for this recipe's operation profile key, so Analysis
-- renders immediately from stored data with no dependency on a currently-
-- selected gem (or on one being selected at all). Uses the canonical
-- stored statisticalProfileKey/configKey/itemID already carried on each
-- profile view - never reconstructs or parses a configKey here.
-- Returns candidates shaped like GetPrimaryInputCandidates' ({ itemID, name,
-- itemLink }) plus a statisticalProfileView field BuildEvaluatedRow uses to
-- price directly via OperationEconomicsService:SummarizeStatisticalProfile,
-- skipping the live-selection profile-key lookup entirely for this source.
local function GetObservedStatisticalProfileCandidates(recipeID)
    local profileKeyService = GetProfileKeyService()
    local keyResult = profileKeyService and profileKeyService:BuildKey(recipeID)
    if not keyResult or keyResult.unresolved then
        return {}, "operationProfileKeyUnresolved"
    end

    local outcomeService = GetOutcomeService()
    local aggregate = outcomeService and outcomeService.GetAggregate
        and outcomeService:GetAggregate(keyResult.profileKey)
    if not aggregate or not aggregate.hasStatisticalProfileSplit then
        return {}, "noStatisticalProfilesObserved"
    end

    local candidates = {}
    for _, profileView in ipairs(aggregate.statisticalProfiles or {}) do
        if profileView.itemID then
            candidates[#candidates + 1] = {
                itemID = profileView.itemID,
                name = profileView.itemName,
                configKey = profileView.configKey,
                statisticalProfileView = profileView,
            }
        end
    end

    if #candidates == 0 then
        return {}, "noStatisticalProfilesObserved"
    end
    return candidates, nil
end

-- Candidate source for Top-N family policies whose operation profile key is
-- already split by primary input (Midnight Engineering Recycling). Reads all
-- observed Operation Profiles for the recipe and evaluates each profile's
-- synthesized/default Statistical Profile, so analysis rows are one per exact
-- observed input profile without touching Blizzard's current reagent picker.
local function GetObservedOperationProfileCandidates(recipeID)
    local outcomeService = GetOutcomeService()
    if not outcomeService or not outcomeService.ListAggregates then
        return {}, "outcomeServiceUnavailable"
    end

    local aggregates = outcomeService:ListAggregates({ recipeID = recipeID })
    local candidates = {}

    for _, aggregate in ipairs(type(aggregates) == "table" and aggregates or {}) do
        -- Skip aggregates recorded before this recipeID was registered as a
        -- Processing Operation (operationType == "crafting"/profileKeyMode
        -- == "recipeOnly" from OperationProfileKeyService's unregistered-
        -- recipe fallback). Such a row predates role-aware capture entirely
        -- - its consumedInputs never went through the registry's inputRoles,
        -- so its "first consumed item" can be the fixed catalyst rather than
        -- the real primary input (e.g. a stale Alchemy Recycling row whose
        -- only consumed reagent on file is Oil of Heartwood). This is a
        -- structural staleness check, not a per-processingType rule: any
        -- currently-valid processing observation (Crushing, both Recycling
        -- types, Prospecting, Milling) is always recorded with
        -- operationType == "processing", so no real data is ever excluded.
        if aggregate.operationType == "processing" then
            local profileView = aggregate.latestStatisticalProfile
                or (type(aggregate.statisticalProfiles) == "table" and aggregate.statisticalProfiles[1])
            local primaryInput = type(aggregate.latestSelectedInputEvidence) == "table"
                and aggregate.latestSelectedInputEvidence[1] or nil

            if profileView then
                local consumed = type(profileView.expectedConsumedInputsPerRun) == "table"
                    and profileView.expectedConsumedInputsPerRun[1] or nil
                local itemID = primaryInput and primaryInput.itemID or consumed and consumed.itemID
                if itemID then
                    candidates[#candidates + 1] = {
                        itemID = itemID,
                        name = (primaryInput and primaryInput.itemName) or (consumed and consumed.itemName),
                        itemLink = primaryInput and primaryInput.itemLink,
                        configKey = (primaryInput and primaryInput.configKey) or (consumed and consumed.configKey),
                        quality = primaryInput and primaryInput.craftingQuality,
                        statisticalProfileView = profileView,
                    }
                end
            end
        end
    end

    if #candidates == 0 then
        return {}, "noObservedOperationProfiles"
    end
    return candidates, nil
end

-- Curated + observed candidate source for "evaluate all inputs" policies
-- (Prospecting, Milling). Deliberately does not touch C_TradeSkillUI or the
-- live schematic form - the whole point is that these rows must render
-- without a selected reagent. Merges Core's curated GetKnownPrimaryInputs
-- with runtime-learned GetObservedPrimaryInputs (populated by
-- CraftCompletionDispatcher on successful processing completions),
-- deduplicated by configKey then itemID so the same ore never renders
-- twice. Returns candidates shaped like GetPrimaryInputCandidates' reagent
-- entries ({ itemID, name, itemLink }) so BuildEvaluatedRow can treat both
-- sources identically. itemLink (observed candidates only) is the real
-- hyperlink captured from the actual item instance consumed - preferred by
-- the analysis row's icon quality-tier overlay over a freshly rebuilt
-- itemID-only link.
local function GetRegisteredPrimaryInputCandidates(registry, recipeID)
    if not registry or not registry.GetKnownPrimaryInputs then
        return {}, "registryUnavailable"
    end

    local known = registry:GetKnownPrimaryInputs(recipeID)
    local observed = registry.GetObservedPrimaryInputs and registry:GetObservedPrimaryInputs(recipeID) or {}

    local candidates = {}
    local seenByConfigKey = {}
    local seenByItemID = {}

    local function AddCandidate(input)
        if not input or not input.itemID then return end
        local configKey = input.configKey
        if configKey and seenByConfigKey[configKey] then return end
        if seenByItemID[input.itemID] then return end
        if configKey then seenByConfigKey[configKey] = true end
        seenByItemID[input.itemID] = true
        candidates[#candidates + 1] = { itemID = input.itemID, name = input.name, itemLink = input.itemLink }
    end

    for _, input in ipairs(type(known) == "table" and known or {}) do
        AddCandidate(input)
    end
    for _, input in ipairs(type(observed) == "table" and observed or {}) do
        AddCandidate(input)
    end

    if #candidates == 0 then
        return {}, "noPrimaryInputsRegistered"
    end
    return candidates, nil
end

-- Resolves the crafting-quality tier (1, 2, 3, ...) for a reagent slot
-- choice, when the live schematic entry carries one. Exposed as a distinct
-- row.quality field - the UI renders it as its own badge (see
-- InventoryManagerWindow's quality badge) rather than merging it into the
-- item name, so same-named quality variants (e.g. Refulgent Copper Ore
-- Q1/Q2) still render as visually distinct rows. Theoretical: assumes the
-- live reagent entry from C_TradeSkillUI.GetRecipeSchematic carries a
-- resolvable quality via IdentityAdapters:GetReagentCraftingQuality - not
-- yet confirmed in-game against a real Midnight Prospecting recipe.
local function ResolveReagentCraftingQuality(reagent, itemID)
    local adapters = GetIdentityAdapters()
    if not adapters or not adapters.GetReagentCraftingQuality then
        return nil
    end
    local ok, quality = pcall(function()
        return adapters:GetReagentCraftingQuality(reagent, itemID)
    end)
    if ok and type(quality) == "number" and quality > 0 then
        return quality
    end
    return nil
end

-- @param recipeID number
-- @param reagent table candidate from one of the Get*Candidates functions -
--        { itemID, name, itemLink, configKey, statisticalProfileView }.
--        statisticalProfileView (only set by
--        GetObservedStatisticalProfileCandidates) is an already-resolved
--        OperationOutcomeService Statistical Profile view; when present,
--        economics are summarized directly from it
--        (SummarizeStatisticalProfile), skipping the recipeID -> definition
--        -> aggregate -> profile-key lookup the live-selection path needs.
-- @param outputFamilyResolver function|nil (qualityTier) -> familyKey, familyLabel,
--        supplied by the processing type's dedicated policy module (e.g.
--        CrushingAnalysisPolicy:ResolveOutputFamily) when it owns output
--        families. nil for processing types with no family grouping.
local function BuildEvaluatedRow(recipeID, reagent, economicsService, identityService, outputFamilyResolver, economicsOptions)
    economicsOptions = type(economicsOptions) == "table" and economicsOptions or {}
    local itemID = reagent and tonumber(reagent.itemID)
    if not itemID then
        return nil
    end

    local itemName = reagent.name or (GetItemInfo and GetItemInfo(itemID)) or ("item:" .. tostring(itemID))
    local quality = reagent.quality or ResolveReagentCraftingQuality(reagent, itemID)

    local configKey = reagent.configKey
    local identity = nil
    if not configKey and identityService and identityService.FromItemID then
        local ok, result = pcall(function() return identityService:FromItemID(itemID) end)
        if ok and type(result) == "table" and not result.unresolved then
            identity = result
            configKey = identity.configKey
        end
    end

    local summary
    if reagent.statisticalProfileView then
        -- Already-known Statistical Profile (observed-candidates source) -
        -- price it directly, never re-deriving/parsing its identity.
        -- Per-candidate copy: economicsOptions is shared across candidates.
        -- primaryInputItemID tells OperationEconomicsService this gem is the
        -- primary input, so a missing price is never counted as free.
        local profileOptions = {}
        for k, v in pairs(economicsOptions) do
            profileOptions[k] = v
        end
        profileOptions.primaryInputItemID = itemID
        summary = economicsService:SummarizeStatisticalProfile(reagent.statisticalProfileView, profileOptions)
        SessionLog("ProcessingAnalysisController:BuildEvaluatedRow: DIAG source=observedStatisticalProfile itemID=%s configKey=%s statisticalProfileKey=%s unresolved=%s unresolvedReason=%s currentInputCost=%s historicalOperationCost=%s expectedNet=%s observationCount=%s yieldStatus=%s",
            tostring(itemID), tostring(configKey), tostring(reagent.statisticalProfileView.statisticalProfileKey),
            tostring(summary.unresolved), tostring(summary.unresolvedReason), tostring(summary.currentInputCost),
            tostring(summary.historicalOperationCost),
            tostring(summary.expectedNet), tostring(summary.observationCount), tostring(summary.yieldStatus))
    else
        -- Resolves which Statistical Profile this candidate's economics
        -- should read from (e.g. a live-selected reagent). Uses
        -- OperationOutcomeService's canonical configKey-or-item:itemID
        -- identity formula rather than hand-building the key here - see
        -- OperationOutcomeService:ResolveStatisticalProfileKey.
        local outcomeService = GetOutcomeService()
        local statisticalProfileKey = outcomeService and outcomeService.ResolveStatisticalProfileKey
            and outcomeService:ResolveStatisticalProfileKey({ configKey = configKey, itemID = itemID })
            or nil

        local summarizeOptions = {}
        for k, v in pairs(economicsOptions) do
            summarizeOptions[k] = v
        end
        summarizeOptions.primaryInputIdentity = identity
        summarizeOptions.primaryInputConfigKey = configKey
        summarizeOptions.primaryInputItemID = itemID
        summarizeOptions.primaryInputItemName = itemName
        summarizeOptions.statisticalProfileKey = statisticalProfileKey

        summary = economicsService:SummarizeOperation(recipeID, summarizeOptions)

        SessionLog("ProcessingAnalysisController:BuildEvaluatedRow: DIAG source=liveSelectedInput itemID=%s configKey=%s statisticalProfileKey=%s unresolved=%s unresolvedReason=%s currentInputCost=%s historicalOperationCost=%s expectedNet=%s observationCount=%s yieldStatus=%s",
            tostring(itemID), tostring(configKey), tostring(statisticalProfileKey),
            tostring(summary.unresolved), tostring(summary.unresolvedReason), tostring(summary.currentInputCost),
            tostring(summary.historicalOperationCost),
            tostring(summary.expectedNet), tostring(summary.observationCount), tostring(summary.yieldStatus))
    end

    local outputFamilyKey, outputFamilyLabel
    if outputFamilyResolver then
        outputFamilyKey, outputFamilyLabel = outputFamilyResolver(quality)
    end

    return {
        itemID = itemID,
        configKey = configKey,
        itemName = itemName,
        itemLabel = itemName,
        quality = quality,
        -- Real hyperlink captured from the actual item instance consumed
        -- (live-selected candidates only; nil for curated/observed
        -- candidates) - preferred by the analysis row's icon quality-tier
        -- overlay over a freshly rebuilt itemID-only link.
        itemLink = reagent.itemLink,
        summary = summary,
        sourceProfileView = reagent.statisticalProfileView,
        outputFamilyKey = outputFamilyKey,
        outputFamilyLabel = outputFamilyLabel,
    }
end

--- Evaluates one recipeID for Processing Analysis applicability and, if
-- applicable, builds ready-to-render display rows.
-- @return table {
--   applicable, reason, processingType, policyName, label,
--   recipeID, professionID, rows = { display rows },
-- }
function ProcessingAnalysisController:EvaluateRecipe(recipeID, professionID)
    recipeID = tonumber(recipeID)
    if not recipeID then
        SessionLog("ProcessingAnalysisController:EvaluateRecipe: reason=missingRecipeID")
        return NewResult(false, "missingRecipeID")
    end

    local profileKeyService = GetProfileKeyService()
    if not profileKeyService then
        SessionLog("ProcessingAnalysisController:EvaluateRecipe: recipeID=%s reason=profileKeyServiceUnavailable", tostring(recipeID))
        return NewResult(false, "profileKeyServiceUnavailable", { recipeID = recipeID, professionID = professionID })
    end

    if profileKeyService:GetOperationType(recipeID) ~= profileKeyService.OPERATION_TYPE_PROCESSING then
        SessionLog("ProcessingAnalysisController:EvaluateRecipe: recipeID=%s reason=notAProcessingOperation", tostring(recipeID))
        return NewResult(false, "notAProcessingOperation", { recipeID = recipeID, professionID = professionID })
    end

    local registry = GetProcessingOperationRegistry()
    local registryEntry = registry and registry:GetEntry(recipeID)
    local processingType = registryEntry and registryEntry.processingType
    if not processingType then
        SessionLog("ProcessingAnalysisController:EvaluateRecipe: recipeID=%s reason=processingTypeUnknown registry=%s",
            tostring(recipeID), tostring(registry ~= nil))
        return NewResult(false, "processingTypeUnknown", { recipeID = recipeID, professionID = professionID })
    end

    local analysisRegistry = GetAnalysisRegistry()
    local analysisEntry = analysisRegistry and analysisRegistry:GetEntry(processingType)
    if not analysisEntry then
        SessionLog("ProcessingAnalysisController:EvaluateRecipe: recipeID=%s processingType=%s reason=processingTypeUnsupported",
            tostring(recipeID), tostring(processingType))
        return NewResult(false, "processingTypeUnsupported", {
            recipeID = recipeID, professionID = professionID, processingType = processingType,
        })
    end

    local economicsService = GetEconomicsService()
    if not economicsService then
        SessionLog("ProcessingAnalysisController:EvaluateRecipe: recipeID=%s processingType=%s reason=economicsServiceUnavailable",
            tostring(recipeID), tostring(processingType))
        return NewResult(false, "economicsServiceUnavailable", {
            recipeID = recipeID, professionID = professionID, processingType = processingType,
        })
    end

    do
        local keyResultForLog = profileKeyService:BuildKey(recipeID)
        SessionLog("ProcessingAnalysisController:EvaluateRecipe: DIAG recipeID=%s operationProfileKey=%s profileKeyMode=%s keyUnresolved=%s",
            tostring(recipeID), tostring(keyResultForLog and keyResultForLog.profileKey),
            tostring(keyResultForLog and keyResultForLog.profileKeyMode), tostring(keyResultForLog and keyResultForLog.unresolved))
    end

    local dedicatedPolicy = GetDedicatedPolicyModule(processingType)
    local label = (dedicatedPolicy and dedicatedPolicy.TITLE) or analysisEntry.label
    local analysisInfoTooltip = (dedicatedPolicy and dedicatedPolicy.analysisInfoTooltip)
        or analysisEntry.analysisInfoTooltip

    local policy = GetRecommendationPolicy()
    local usesRegisteredInputs = policy ~= nil and analysisEntry.policyName == policy.POLICY_EVALUATE_ALL_INPUTS
    -- Top-N family policies compare every known observed profile rather than
    -- reading the live salvage/recycling slot. recipeOnly split operations
    -- (Crushing) read stored Statistical Profiles under one Operation Profile;
    -- recipePlusPrimaryInput operations (Midnight Recycling) read the observed
    -- Operation Profiles for the recipe.
    local usesObservedStatisticalProfiles = policy ~= nil
        and analysisEntry.policyName == policy.POLICY_RECOMMEND_TOP_N_PER_OUTPUT_FAMILY
    local usesObservedOperationProfiles = analysisEntry.candidateSource == "observedOperationProfiles"

    local candidateSourceLabel, candidates, candidateReason
    if usesObservedOperationProfiles then
        candidateSourceLabel = "observedOperationProfiles"
        candidates, candidateReason = GetObservedOperationProfileCandidates(recipeID)
    elseif usesRegisteredInputs then
        candidateSourceLabel = "registry"
        candidates, candidateReason = GetRegisteredPrimaryInputCandidates(registry, recipeID)
    elseif usesObservedStatisticalProfiles then
        if registryEntry.profileKeyMode == registry.PROFILE_KEY_MODE_RECIPE_PLUS_PRIMARY_INPUT then
            candidateSourceLabel = "observedOperationProfiles"
            candidates, candidateReason = GetObservedOperationProfileCandidates(recipeID)
        else
            candidateSourceLabel = "observedStatisticalProfiles"
            candidates, candidateReason = GetObservedStatisticalProfileCandidates(recipeID)
        end
    else
        candidateSourceLabel = "liveSchematic"
        candidates, candidateReason = GetPrimaryInputCandidates(recipeID)
    end

    if #candidates == 0 then
        SessionLog("ProcessingAnalysisController:EvaluateRecipe: recipeID=%s processingType=%s source=%s reason=%s",
            tostring(recipeID), tostring(processingType), candidateSourceLabel, tostring(candidateReason))

        if usesRegisteredInputs then
            -- "Evaluate all inputs" policies never fall back to Inventory
            -- Manager for a missing input list - an empty registry is
            -- honest content ("nothing curated yet"), not an evaluation
            -- failure, so applicable stays true and the Analysis view stays
            -- up with an explanatory empty state.
            return {
                applicable = true,
                reason = candidateReason,
                processingType = processingType,
                policyName = analysisEntry.policyName,
                label = label,
                analysisInfoTooltip = analysisInfoTooltip,
                analysisMode = dedicatedPolicy and dedicatedPolicy.analysisMode,
                recipeID = recipeID,
                professionID = professionID,
                rows = {},
                emptyMessage = string.format("No %s inputs registered for this operation.", tostring(label or processingType):lower()),
            }
        end

        if usesObservedStatisticalProfiles or usesObservedOperationProfiles then
            -- No observed gem crafts yet is honest empty content, not an
            -- evaluation failure - "No processing analysis rows available"
            -- should read this way only when no Crushing statistical
            -- profiles exist at all.
            return {
                applicable = true,
                reason = candidateReason,
                processingType = processingType,
                policyName = analysisEntry.policyName,
                label = label,
                analysisInfoTooltip = analysisInfoTooltip,
                analysisMode = dedicatedPolicy and dedicatedPolicy.analysisMode,
                recipeID = recipeID,
                professionID = professionID,
                rows = {},
                emptyMessage = string.format("No %s crafts observed yet.", tostring(label or processingType):lower()),
            }
        end

        return NewResult(false, candidateReason or "noValidPrimaryInputs", {
            recipeID = recipeID, professionID = professionID,
            processingType = processingType, policyName = analysisEntry.policyName, label = label,
        })
    end

    for i, c in ipairs(candidates) do
        SessionLog("ProcessingAnalysisController:EvaluateRecipe: DIAG candidate[%d] itemID=%s name=%s itemLink=%s configKey=%s",
            i, tostring(c.itemID), tostring(c.name), tostring(c.itemLink), tostring(c.configKey))
    end

    -- Dedicated policy modules that own output families (e.g.
    -- CrushingAnalysisPolicy) expose ResolveOutputFamily(qualityTier); other
    -- processing types simply have no resolver, so outputFamilyKey stays
    -- nil and rows render as the original flat, ungrouped list.
    local outputFamilyResolver = nil
    if dedicatedPolicy and dedicatedPolicy.ResolveOutputFamily then
        outputFamilyResolver = function(qualityTier)
            return dedicatedPolicy:ResolveOutputFamily(qualityTier)
        end
    end

    local identityService = GetItemIdentityService()
    local economicsOptions = {
        outputValuationMode = registryEntry.outputValuationMode,
        unitAcquisitionOutputItemID = registryEntry.unitAcquisitionOutputItemID,
    }
    local evaluatedRows = {}
    for _, reagent in ipairs(candidates) do
        local row = BuildEvaluatedRow(recipeID, reagent, economicsService, identityService, outputFamilyResolver, economicsOptions)
        if row then
            local assignedRows = dedicatedPolicy and dedicatedPolicy.AssignOutputFamilies
                and dedicatedPolicy:AssignOutputFamilies(row) or nil
            if type(assignedRows) == "table" and #assignedRows > 0 then
                for _, assignedRow in ipairs(assignedRows) do
                    evaluatedRows[#evaluatedRows + 1] = assignedRow
                end
            else
                evaluatedRows[#evaluatedRows + 1] = row
            end
        end
    end

    SessionLog("ProcessingAnalysisController:EvaluateRecipe: DIAG evaluatedRows=%d (candidates=%d)", #evaluatedRows, #candidates)

    local survivingRows, policyError = {}, nil
    if policy then
        survivingRows, policyError = policy:Apply(analysisEntry.policyName, evaluatedRows)
    end

    SessionLog("ProcessingAnalysisController:EvaluateRecipe: DIAG policy=%s evaluatedRows=%d survivingRows=%d policyError=%s",
        tostring(analysisEntry.policyName), #evaluatedRows, #survivingRows, tostring(policyError))

    local displayBuilder = GetDisplayModelBuilder()
    local displayRows = displayBuilder and displayBuilder:BuildRows(survivingRows, {
        analysisMode = dedicatedPolicy and dedicatedPolicy.analysisMode,
        outputItemName = dedicatedPolicy and dedicatedPolicy.outputItemName,
    }) or {}

    SessionLog("ProcessingAnalysisController:EvaluateRecipe: DIAG final recipeID=%s displayRowCount=%d", tostring(recipeID), #displayRows)

    -- Sort by Expected / Craft descending. Rows with no resolvable value
    -- (missing price or no observed yield) sink to the bottom rather than
    -- being ranked as zero - they cannot be honestly compared to a priced
    -- row. Skipped for grouped rows (outputFamilyKey present): the policy
    -- already ranked within each family, and a global value sort here would
    -- interleave families and break the grouped section rendering.
    local hasOutputFamilies = false
    for _, row in ipairs(displayRows) do
        if row.outputFamilyKey then
            hasOutputFamilies = true
            break
        end
    end

    if dedicatedPolicy and dedicatedPolicy.SortDisplayRows then
        dedicatedPolicy:SortDisplayRows(displayRows)
    elseif not hasOutputFamilies then
        table.sort(displayRows, function(a, b)
            if a.expectedPerCraft == nil and b.expectedPerCraft == nil then return false end
            if a.expectedPerCraft == nil then return false end
            if b.expectedPerCraft == nil then return true end
            return a.expectedPerCraft > b.expectedPerCraft
        end)
    end

    -- True when any row shown is built from published starter data, so the
    -- window can say so once for the whole list.
    local hasSeedData = false
    for _, row in ipairs(displayRows) do
        if row.isSeedData then
            hasSeedData = true
            break
        end
    end

    SessionLog("ProcessingAnalysisController: evaluated recipeID=%s processingType=%s policy=%s source=%s candidates=%d surviving=%d groupedByFamily=%s hasSeedData=%s",
        tostring(recipeID), tostring(processingType), tostring(analysisEntry.policyName),
        candidateSourceLabel, #candidates, #survivingRows, tostring(hasOutputFamilies), tostring(hasSeedData))

    return {
        applicable = true,
        reason = policyError,
        processingType = processingType,
        policyName = analysisEntry.policyName,
        label = label,
        analysisInfoTooltip = analysisInfoTooltip,
        analysisMode = dedicatedPolicy and dedicatedPolicy.analysisMode,
        recipeID = recipeID,
        professionID = professionID,
        rows = displayRows,
        -- Purely a rendering signal: true when at least one row carries an
        -- outputFamilyKey, so InventoryManagerWindow:RenderAnalysis groups
        -- rows under section headers (Crushing's quality-tier families,
        -- Milling's Low/High-Quality Herbs). Does NOT by itself mean the
        -- Top Results/All Results limit applies - see supportsResultsLimit.
        hasOutputFamilies = hasOutputFamilies,
        -- Lets CraftQueueController decide whether the Top Results/All
        -- Results toggle applies to this result without re-deriving policy
        -- knowledge itself - true only for the RecommendTopNPerOutputFamily
        -- policy (Crushing). Milling also groups into sections
        -- (hasOutputFamilies=true) but always shows every row, so it must
        -- stay false here even though it groups.
        supportsResultsLimit = usesObservedStatisticalProfiles,
        hasSeedData = hasSeedData,
        seedDataNote = hasSeedData and displayBuilder and displayBuilder.GetSeedDataNote
            and displayBuilder:GetSeedDataNote() or nil,
    }
end

--- Builds the expanded detail-view model for a display row previously
-- returned by EvaluateRecipe/EvaluateCurrentRecipe's .rows. Delegates
-- entirely to the display builder - this controller does not touch
-- economics math itself.
function ProcessingAnalysisController:BuildDetailViewModel(displayRow)
    if type(displayRow) ~= "table" then
        return nil
    end
    local displayBuilder = GetDisplayModelBuilder()
    if not displayBuilder or not displayBuilder.BuildDetailRow then
        return nil
    end
    return displayBuilder:BuildDetailRow(displayRow.itemLabel, displayRow.summary, {
        itemID = displayRow.itemID,
        configKey = displayRow.configKey,
        analysisMode = displayRow.analysisMode,
        outputItemName = displayRow.outputItemName,
    })
end

--- Convenience wrapper that reads the currently selected recipe/profession
-- from ProfessionContextService.
function ProcessingAnalysisController:EvaluateCurrentRecipe()
    local contextService = GetProfessionContextService()
    local recipeID = contextService and contextService:GetCurrentRecipeID()
    local context = contextService and contextService:GetCurrentProfessionContext() or {}
    if not recipeID then
        SessionLog("ProcessingAnalysisController:EvaluateCurrentRecipe: reason=noRecipeSelected professionID=%s",
            tostring(context.professionID))
        return NewResult(false, "noRecipeSelected", { professionID = context.professionID })
    end
    return self:EvaluateRecipe(recipeID, context.professionID)
end

function ProcessingAnalysisController:OnEnable()
end

function ProcessingAnalysisController:OnDisable()
end
