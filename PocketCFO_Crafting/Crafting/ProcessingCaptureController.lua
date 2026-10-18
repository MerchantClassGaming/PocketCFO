-- PocketCFO_Crafting/Crafting/ProcessingCaptureController.lua
-- Scaffold only.
--
-- This will own the future in-game processing capture workflow: turn on
-- capture mode, log every completed processing-eligible recipe execution
-- with its selected primary input, turn capture off or log out, export the
-- results to curate ProcessingOperationRegistry / OperationDefinitionService
-- data (see PocketCFO_Processing_VCM_Architecture_v3.md "Processing Capture
-- Tool"). None of that is implemented yet.
--
-- This file exists so CraftCompletionDispatcher has a stable, inert
-- integration point now and does not need to change again once capture mode
-- is actually built.

local ADDON_NAME, _ = ...
local PocketCFO_Crafting = _G.PocketCFO_Crafting

local ProcessingCaptureController = PocketCFO_Crafting:NewModule("ProcessingCaptureController")

ProcessingCaptureController.captureModeActive = false

function ProcessingCaptureController:IsCaptureModeActive()
    return self.captureModeActive == true
end

-- Intentionally not implemented. CraftCompletionDispatcher calls this only
-- when IsCaptureModeActive() is true, which is never true yet.
function ProcessingCaptureController:RecordObservation(observation, context)
end

function ProcessingCaptureController:OnEnable()
end

function ProcessingCaptureController:OnDisable()
end
