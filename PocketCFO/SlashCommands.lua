-- PocketCFO/SlashCommands.lua
-- /mcg command dispatch. Delegates to the shared Diagnostics command
-- registry (Infrastructure/Diagnostics.lua) so any command registered
-- there (including "debug") is reachable from both /mcg and /mcgd without
-- duplicate registration or duplicate state.

local ADDON_NAME, _ = ...
local PocketCFO = _G.PocketCFO

local function GetDiagnostics()
    return PocketCFO and PocketCFO.Diagnostics
end

local function ToggleDebug()
    PocketCFO:SetDebugEnabled(not PocketCFO.debugEnabled)
    PocketCFO:Print(PocketCFO.debugEnabled and "Debug mode ON" or "Debug mode OFF")
end

local function ShowUsage()
    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.ShowDump and diagnostics.BuildHelpText then
        diagnostics:ShowDump("PocketCFO Commands", diagnostics:BuildHelpText())
        return
    end
    PocketCFO:Print("Unknown command. Try /mcgd help.")
end

local function HandleSlashCommand(msg)
    local raw = strtrim(msg or "")
    local cmd, rest = raw:match("^(%S*)%s*(.-)$")
    cmd = cmd and cmd:lower() or ""

    local diagnostics = GetDiagnostics()
    if cmd ~= "" and diagnostics and diagnostics.ExecuteCommand then
        local ok, err = diagnostics:ExecuteCommand(cmd, rest)
        if ok then
            return
        end
    end

    ShowUsage()
end

SLASH_MCG1 = "/mcg"
SlashCmdList["MCG"] = HandleSlashCommand

-- ---------------------------------------------------------------------------
-- /pcfo and /pocketcfo - player-facing commands.
-- Only runs commands registered with playerFacing = true. With no argument it
-- opens settings. /mcg and /mcgd stay as the dev/diagnostic commands.
-- ---------------------------------------------------------------------------

local function ShowPlayerHelp()
    PocketCFO:Print("Pocket CFO commands:")
    PocketCFO:Print("  /pcfo - open settings")
    local diagnostics = GetDiagnostics()
    if not diagnostics or not diagnostics.GetRegisteredCommands then
        return
    end
    for _, command in ipairs(diagnostics:GetRegisteredCommands()) do
        local metadata = command.metadata or {}
        if metadata.playerFacing and command.name ~= "settings" then
            PocketCFO:Print("  /pcfo %s - %s", command.name, tostring(metadata.description or ""))
        end
    end
end

local function HandlePlayerSlashCommand(msg)
    local raw = strtrim(msg or "")
    local cmd, rest = raw:match("^(%S*)%s*(.-)$")
    cmd = cmd and cmd:lower() or ""
    if cmd == "" then
        cmd = "settings"
    end
    if cmd == "help" then
        ShowPlayerHelp()
        return
    end

    local diagnostics = GetDiagnostics()
    if diagnostics and diagnostics.GetRegisteredCommands and diagnostics.ExecuteCommand then
        for _, command in ipairs(diagnostics:GetRegisteredCommands()) do
            if command.name == cmd and command.metadata and command.metadata.playerFacing then
                diagnostics:ExecuteCommand(cmd, rest)
                return
            end
        end
    end

    PocketCFO:Print("Unknown command. Type /pcfo help.")
end

SLASH_POCKETCFO1 = "/pcfo"
SLASH_POCKETCFO2 = "/pocketcfo"
SlashCmdList["POCKETCFO"] = HandlePlayerSlashCommand

local diagnostics = GetDiagnostics()
if diagnostics and diagnostics.RegisterCommand then
    diagnostics:RegisterCommand("debug", {
        name = "debug",
        description = "Toggle debug output and session-log capture.",
        usage = "/mcg debug",
        category = "General",
    }, ToggleDebug)
end
