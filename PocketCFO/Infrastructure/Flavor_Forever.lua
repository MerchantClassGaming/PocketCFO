-- PocketCFO/Infrastructure/Flavor_Forever.lua
-- Loaded only by the WoW Forever TOC, right after Core.lua. Retail never loads
-- this file, so PocketCFO.flavor stays nil there and every check reads as retail.
--
-- The flavor comes from which TOC loaded, not from WOW_PROJECT_ID: Forever beta
-- builds reported 1 and later 18, so the project ID is not reliable yet.

local PocketCFO = _G.PocketCFO

PocketCFO.flavor = "forever"
