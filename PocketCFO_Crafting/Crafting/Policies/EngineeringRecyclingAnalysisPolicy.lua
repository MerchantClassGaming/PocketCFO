-- PocketCFO_Crafting/Crafting/Policies/EngineeringRecyclingAnalysisPolicy.lua
-- Midnight Engineering Recycling analysis metadata. Family membership comes
-- from observed produced output identities, not from selected input rarity or
-- a curated input->output table.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local EngineeringRecyclingAnalysisPolicy = PocketCFO_Crafting:NewModule("EngineeringRecyclingAnalysisPolicy")
PocketCFO_Crafting.EngineeringRecyclingAnalysisPolicy = EngineeringRecyclingAnalysisPolicy

EngineeringRecyclingAnalysisPolicy.PROCESSING_TYPE = "engineeringRecycling"
EngineeringRecyclingAnalysisPolicy.TITLE = "Recycling Analysis"
EngineeringRecyclingAnalysisPolicy.analysisInfoTooltip = {
    title = "Midnight Recycling output quality",
    text = "PocketCFO expects Midnight Recycling output quality to match the selected input quality. Mismatched or unresolved-quality results are excluded from recycling statistics.",
}

EngineeringRecyclingAnalysisPolicy.FAMILY_EVERCORE = "evercore"
EngineeringRecyclingAnalysisPolicy.FAMILY_AETHERLUME = "aetherlume"

local FAMILY_BY_TOKEN = {
    evercore = {
        key = EngineeringRecyclingAnalysisPolicy.FAMILY_EVERCORE,
        label = "Evercore",
        order = 1,
    },
    aetherlume = {
        key = EngineeringRecyclingAnalysisPolicy.FAMILY_AETHERLUME,
        label = "Aetherlume",
        order = 2,
    },
}

local ORDER_BY_FAMILY_KEY = {
    [EngineeringRecyclingAnalysisPolicy.FAMILY_EVERCORE] = 1,
    [EngineeringRecyclingAnalysisPolicy.FAMILY_AETHERLUME] = 2,
}

local function CloneRow(row)
    local copy = {}
    for k, v in pairs(row or {}) do
        copy[k] = v
    end
    return copy
end

local function ResolveFamilyFromOutputName(itemName)
    itemName = itemName and tostring(itemName):lower() or ""
    if itemName:find("evercore", 1, true) then
        return FAMILY_BY_TOKEN.evercore
    end
    if itemName:find("aetherlume", 1, true) then
        return FAMILY_BY_TOKEN.aetherlume
    end
    return nil
end

--- Expands one evaluated exact-input profile row into one display/ranking row
-- per observed output family. A profile that genuinely produces both known
-- families appears in both family sections with the same economics summary;
-- exact output ConfigKeys and quality-specific valuations remain inside the
-- shared OperationEconomicsService summary.
function EngineeringRecyclingAnalysisPolicy:AssignOutputFamilies(row)
    local summary = row and row.summary
    local rows = {}
    local seen = {}

    local outputRows = type(summary and summary.outputValueRows) == "table"
        and summary.outputValueRows or {}
    if #outputRows == 0
    and type(row and row.sourceProfileView) == "table"
    and type(row.sourceProfileView.expectedProducedOutputsPerRun) == "table" then
        outputRows = row.sourceProfileView.expectedProducedOutputsPerRun
    end

    for _, outputRow in ipairs(outputRows) do
        local family = ResolveFamilyFromOutputName(outputRow.itemName)
        if family and not seen[family.key] then
            local familyRow = CloneRow(row)
            familyRow.outputFamilyKey = family.key
            familyRow.outputFamilyLabel = family.label
            rows[#rows + 1] = familyRow
            seen[family.key] = true
        end
    end

    return rows
end

function EngineeringRecyclingAnalysisPolicy:SortDisplayRows(rows)
    if type(rows) ~= "table" then
        return
    end
    table.sort(rows, function(a, b)
        local orderA = ORDER_BY_FAMILY_KEY[a.outputFamilyKey] or math.huge
        local orderB = ORDER_BY_FAMILY_KEY[b.outputFamilyKey] or math.huge
        if orderA ~= orderB then
            return orderA < orderB
        end
        local netA = a.expectedPerCraft
        local netB = b.expectedPerCraft
        if netA ~= nil and netB ~= nil and netA ~= netB then
            return netA > netB
        end
        if netA ~= nil and netB == nil then return true end
        if netA == nil and netB ~= nil then return false end
        return tostring(a.itemLabel or "") < tostring(b.itemLabel or "")
    end)
end

function EngineeringRecyclingAnalysisPolicy:OnEnable()
end

function EngineeringRecyclingAnalysisPolicy:OnDisable()
end
