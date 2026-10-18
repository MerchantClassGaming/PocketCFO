-- PocketCFO/Infrastructure/Diagnostics.lua
-- Shared diagnostic infrastructure: command registry, generated help text,
-- copyable dump windows, safe value formatting, and package passthroughs.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

if not PocketCFO or type(PocketCFO.NewModule) ~= "function" then
    return
end

local Diagnostics = PocketCFO:NewModule("Diagnostics")
PocketCFO.Diagnostics = Diagnostics

local dumpFrame = nil
local commandRegistry = {}
local lastDump = nil
local diagnosticPackageProviders = {}
local diagnosticPackageOrder = {}

local COMMAND_METADATA_FIELDS = {
    "name",
    "description",
    "usage",
    "category",
    "destructive",
    "temporary",
    "releaseExcluded",
    "playerFacing",
}

local function CopyDiagnosticMetadata(metadata)
    if type(metadata) ~= "table" then
        return {}
    end

    local copy = {}
    for key, value in pairs(metadata) do
        copy[key] = value
    end
    return copy
end

local function CopyCommandMetadata(metadata)
    local copy = {}
    if type(metadata) == "table" then
        for _, key in ipairs(COMMAND_METADATA_FIELDS) do
            copy[key] = metadata[key]
        end
    end
    return copy
end

local function NormalizeCommandName(commandName)
    if type(commandName) ~= "string" then
        return nil
    end

    commandName = strtrim(commandName)
    if commandName == "" then
        return nil
    end

    return commandName:lower()
end

local function GetTimestamp()
    if PocketCFO and PocketCFO.GetServerNow then
        return PocketCFO:GetServerNow()
    end
    if GetServerTime then
        return GetServerTime()
    end
    return time()
end

local function GetGlobalDB()
    if PocketCFO and PocketCFO.db and PocketCFO.db.global then
        return PocketCFO.db.global
    end
    return nil
end

local function GetDiagnosticsDB()
    local db = GetGlobalDB()
    if not db then
        return nil
    end

    db.diagnostics = db.diagnostics or {}
    if type(db.diagnosticLastDump) == "table" and not db.diagnostics.lastDump then
        db.diagnostics.lastDump = db.diagnosticLastDump
    end
    db.diagnosticLastDump = nil
    return db.diagnostics
end

local function PersistLastDump()
    local db = GetDiagnosticsDB()
    if db then
        db.lastDump = lastDump or false
    end
end

local function RestoreLastDump()
    local db = GetDiagnosticsDB()
    if db and type(db.lastDump) == "table" then
        lastDump = {
            title = tostring(db.lastDump.title or "Diagnostic Dump"),
            body = tostring(db.lastDump.body or ""),
            timestamp = tonumber(db.lastDump.timestamp) or GetTimestamp(),
        }
    end
end

local function GetDumpFrame()
    if dumpFrame then
        return dumpFrame
    end

    dumpFrame = CreateFrame("Frame", "PocketCFODiagnosticsDumpFrame", UIParent, "BackdropTemplate")
    dumpFrame:SetSize(760, 520)
    dumpFrame:SetPoint("CENTER")
    dumpFrame:SetFrameStrata("FULLSCREEN_DIALOG")
    dumpFrame:SetFrameLevel(100)
    dumpFrame:SetToplevel(true)
    dumpFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    dumpFrame:SetBackdropColor(0, 0, 0, 0.95)
    dumpFrame:SetBackdropBorderColor(0.6, 0.6, 0.2, 1)
    dumpFrame:SetMovable(true)
    dumpFrame:EnableMouse(true)
    dumpFrame:RegisterForDrag("LeftButton")
    dumpFrame:SetScript("OnDragStart", dumpFrame.StartMoving)
    dumpFrame:SetScript("OnDragStop", dumpFrame.StopMovingOrSizing)
    dumpFrame:SetClampedToScreen(true)

    table.insert(UISpecialFrames, dumpFrame:GetName())

    local title = dumpFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", dumpFrame, "TOPLEFT", 8, -8)
    title:SetPoint("RIGHT", dumpFrame, "RIGHT", -32, 0)
    title:SetJustifyH("LEFT")
    title:SetTextColor(1, 0.8, 0.2)
    dumpFrame.title = title

    local closeBtn = CreateFrame("Button", nil, dumpFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", dumpFrame, "TOPRIGHT", -2, -2)
    closeBtn:SetScript("OnClick", function()
        dumpFrame:Hide()
    end)

    local scrollFrame = CreateFrame("ScrollFrame", nil, dumpFrame, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", dumpFrame, "TOPLEFT", 6, -28)
    scrollFrame:SetPoint("BOTTOMRIGHT", dumpFrame, "BOTTOMRIGHT", -26, 6)

    local editBox = CreateFrame("EditBox", "PocketCFODiagnosticsDumpEditBox", scrollFrame)
    editBox:SetMultiLine(true)
    editBox:SetFontObject(ChatFontNormal)
    editBox:SetWidth(700)
    editBox:SetAutoFocus(false)
    editBox:EnableMouse(true)
    editBox:EnableKeyboard(true)
    editBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        dumpFrame:Hide()
    end)
    scrollFrame:SetScrollChild(editBox)

    dumpFrame.editBox = editBox
    dumpFrame:SetScript("OnHide", function(self)
        if self.editBox then
            self.editBox:ClearFocus()
        end
    end)

    return dumpFrame
end

local function BodyToString(body)
    if type(body) == "table" then
        return table.concat(body, "\n")
    end
    return tostring(body or "")
end

local function ShowDumpBody(title, body)
    local f = GetDumpFrame()
    f.title:SetText(string.format("[MCG] %s - Ctrl+A, Ctrl+C to copy", tostring(title or "Diagnostic Dump")))
    f.editBox:SetText(BodyToString(body))
    f.editBox:SetFocus()
    f.editBox:HighlightText()
    f:Show()
    if f.Raise then
        f:Raise()
    end
end

local function SortKeys(a, b)
    local typeA = type(a)
    local typeB = type(b)
    if typeA ~= typeB then
        return typeA < typeB
    end
    return tostring(a) < tostring(b)
end

local function FormatScalar(value)
    local valueType = type(value)
    if value == nil then
        return "nil"
    elseif valueType == "string" then
        return string.format("%q", value)
    elseif valueType == "number" or valueType == "boolean" then
        return tostring(value)
    end
    return "<" .. valueType .. ":" .. tostring(value) .. ">"
end

local function FormatValue(value, options, depth, seen)
    local valueType = type(value)
    if valueType ~= "table" then
        return FormatScalar(value)
    end

    options = options or {}
    depth = depth or 0
    seen = seen or {}

    local maxDepth = tonumber(options.maxDepth) or 4
    local maxEntries = tonumber(options.maxEntries) or 200
    local indentText = options.indent or "  "
    local indent = string.rep(indentText, depth)
    local childIndent = string.rep(indentText, depth + 1)

    if seen[value] then
        return "<cycle>"
    end
    if depth >= maxDepth then
        return "<max-depth:" .. tostring(value) .. ">"
    end

    seen[value] = true

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, SortKeys)

    if #keys == 0 then
        seen[value] = nil
        return "{}"
    end

    local lines = { "{" }
    local shown = 0
    for _, key in ipairs(keys) do
        shown = shown + 1
        if shown > maxEntries then
            lines[#lines + 1] = childIndent .. "... <truncated>"
            break
        end

        lines[#lines + 1] = string.format(
            "%s[%s] = %s",
            childIndent,
            FormatScalar(key),
            FormatValue(value[key], options, depth + 1, seen)
        )
    end

    lines[#lines + 1] = indent .. "}"
    seen[value] = nil
    return table.concat(lines, "\n")
end

function Diagnostics:OnInitialize()
    RestoreLastDump()
    PocketCFO.sessionLog = PocketCFO.sessionLog or {}
    PocketCFO.debugEnabled = PocketCFO.debugEnabled and true or false
end

function Diagnostics:RegisterCommand(commandName, metadata, handler)
    local normalizedName = NormalizeCommandName(commandName)
    if not normalizedName then
        return false, "invalidCommandName"
    end
    if type(handler) ~= "function" then
        return false, "invalidHandler"
    end

    local metadataCopy = CopyCommandMetadata(metadata)
    metadataCopy.name = metadataCopy.name or normalizedName
    metadataCopy.category = metadataCopy.category or "General"

    commandRegistry[normalizedName] = {
        name = normalizedName,
        metadata = metadataCopy,
        handler = handler,
    }

    return true
end

function Diagnostics:UnregisterCommand(commandName)
    local normalizedName = NormalizeCommandName(commandName)
    if not normalizedName then
        return false, "invalidCommandName"
    end

    commandRegistry[normalizedName] = nil
    return true
end

function Diagnostics:GetRegisteredCommands()
    local commands = {}
    for commandName, entry in pairs(commandRegistry) do
        local metadata = CopyCommandMetadata(entry.metadata)
        metadata.name = metadata.name or commandName
        commands[#commands + 1] = {
            name = commandName,
            metadata = metadata,
            handler = entry.handler,
        }
    end

    table.sort(commands, function(a, b)
        local categoryA = tostring(a.metadata.category or "General")
        local categoryB = tostring(b.metadata.category or "General")
        if categoryA ~= categoryB then
            return categoryA < categoryB
        end
        return tostring(a.name) < tostring(b.name)
    end)

    return commands
end

function Diagnostics:ExecuteCommand(commandName, ...)
    local normalizedName = NormalizeCommandName(commandName)
    if not normalizedName then
        return false, "invalidCommandName"
    end

    local entry = commandRegistry[normalizedName]
    if not entry then
        return false, "commandNotRegistered"
    end
    if type(entry.handler) ~= "function" then
        return false, "invalidHandler"
    end

    local function PackReturns(...)
        return { n = select("#", ...), ... }
    end

    local results = PackReturns(pcall(entry.handler, ...))
    if not results[1] then
        return false, tostring(results[2] or "commandFailed")
    end

    return true, unpack(results, 2, results.n)
end

function Diagnostics:BuildHelpText()
    local commands = self:GetRegisteredCommands()
    local lines = { "=== PocketCFO Diagnostic Commands ===" }

    if #commands == 0 then
        lines[#lines + 1] = "(no commands registered)"
        return table.concat(lines, "\n")
    end

    local currentCategory = nil
    for _, command in ipairs(commands) do
        local metadata = command.metadata or {}
        local category = tostring(metadata.category or "General")
        if category ~= currentCategory then
            lines[#lines + 1] = ""
            lines[#lines + 1] = category
            currentCategory = category
        end

        local markers = {}
        if metadata.destructive then
            markers[#markers + 1] = "DESTRUCTIVE"
        end
        if metadata.temporary then
            markers[#markers + 1] = "TEMP"
        end
        if metadata.releaseExcluded then
            markers[#markers + 1] = "RELEASE-EXCLUDED"
        end

        local label = metadata.usage or metadata.name or command.name
        if #markers > 0 then
            label = label .. " [" .. table.concat(markers, ", ") .. "]"
        end

        local description = metadata.description
        if description and description ~= "" then
            lines[#lines + 1] = "  " .. tostring(label) .. " - " .. tostring(description)
        else
            lines[#lines + 1] = "  " .. tostring(label)
        end
    end

    return table.concat(lines, "\n")
end

function Diagnostics:ShowDump(title, body)
    lastDump = {
        title = tostring(title or "Diagnostic Dump"),
        body = BodyToString(body),
        timestamp = GetTimestamp(),
    }
    PersistLastDump()
    ShowDumpBody(lastDump.title, lastDump.body)
    return true
end

function Diagnostics:AppendDump(title, body)
    local appendTitle = tostring(title or "Diagnostic Dump")
    local appendBody = BodyToString(body)

    if not lastDump then
        RestoreLastDump()
    end

    if lastDump and lastDump.body and lastDump.body ~= "" then
        appendBody = table.concat({
            lastDump.body,
            "",
            "=== " .. appendTitle .. " ===",
            appendBody,
        }, "\n")
    end

    return self:ShowDump(appendTitle, appendBody)
end

function Diagnostics:ShowLastDump()
    if not lastDump then
        RestoreLastDump()
    end
    if not lastDump then
        return false, "noLastDump"
    end

    ShowDumpBody(lastDump.title, lastDump.body)
    return true
end

function Diagnostics:ClearLastDump()
    lastDump = nil
    PersistLastDump()
    if dumpFrame and dumpFrame.editBox then
        dumpFrame.editBox:SetText("")
    end
    return true
end

function Diagnostics:FormatTable(value, options)
    return FormatValue(value, options or {})
end

function Diagnostics:RegisterDiagnosticPackageProvider(packageKey, providerFn, metadata)
    if type(packageKey) ~= "string" or packageKey == "" then
        return false, "invalidPackageKey"
    end
    if type(providerFn) ~= "function" then
        return false, "invalidProvider"
    end

    if diagnosticPackageProviders[packageKey] == nil then
        diagnosticPackageOrder[#diagnosticPackageOrder + 1] = packageKey
        table.sort(diagnosticPackageOrder)
    end

    diagnosticPackageProviders[packageKey] = {
        provider = providerFn,
        metadata = CopyDiagnosticMetadata(metadata),
    }
    return true
end

function Diagnostics:GetDiagnosticPackage(packageKey, context)
    local entry = diagnosticPackageProviders[packageKey]
    if not entry or type(entry.provider) ~= "function" then
        return nil, "packageProviderUnavailable"
    end

    local ok, packageOrError = pcall(entry.provider, context)
    if not ok then
        return nil, tostring(packageOrError or "packageProviderFailed")
    end
    return packageOrError
end

function Diagnostics:ListDiagnosticPackages()
    local packages = {}
    for _, packageKey in ipairs(diagnosticPackageOrder) do
        local entry = diagnosticPackageProviders[packageKey]
        if entry then
            packages[#packages + 1] = {
                packageKey = packageKey,
                metadata = CopyDiagnosticMetadata(entry.metadata),
            }
        end
    end
    return packages
end

function Diagnostics:AppendSessionLog(line)
    if not PocketCFO.debugEnabled and not PocketCFO.traceEnabled then
        return
    end

    local buffer = PocketCFO.sessionLog
    if not buffer then
        buffer = {}
        PocketCFO.sessionLog = buffer
    end

    local stamp = date("%H:%M:%S")
    table.insert(buffer, string.format("[%s] %s", tostring(stamp), tostring(line)))
end

function Diagnostics:ClearSessionLog()
    PocketCFO.sessionLog = {}
end

function Diagnostics:GetSessionLogLines()
    local copy = {}
    for _, line in ipairs(PocketCFO.sessionLog or {}) do
        copy[#copy + 1] = tostring(line)
    end
    return copy
end

function Diagnostics:SetDebugEnabled(enabled)
    PocketCFO.debugEnabled = enabled and true or false
end

function Diagnostics:Debug(msg, ...)
    msg = tostring(msg)
    if not PocketCFO.debugEnabled then
        return
    end
    if select("#", ...) > 0 then
        msg = string.format(msg, ...)
    end

    -- Debug output goes to the session log only (/mcgd session). It used to also
    -- print every line to chat, which flooded the chat window and made it unusable.
    self:AppendSessionLog("[MCG] " .. tostring(msg))
end
