-- PocketCFO_Valuation/Modules/VendorPriceDefaults.lua
-- Bundled default vendor-price registry. Immutable code-only seed data,
-- never written to and never copied into SavedVariables.
--
-- Converted directly from the approved /mcgd vendorprices export (52 rows,
-- captured 2026-07-12, all gold-only observations). Values are the exact
-- unitPrice/purchasePrice/purchaseQuantity the export produced - no
-- rounding, no recalculation.
--
-- This table is consulted by VendorPriceService only as a fallback when no
-- player observation exists for an itemID. A player observation always
-- overrides the matching default row (see VendorPriceService:GetPrice).

local ADDON_NAME, _ = ...
local PocketCFO_Valuation = _G.PocketCFO_Valuation

local VendorPriceDefaults = {
    [2324] = { unitPrice = 24, purchasePrice = 24, purchaseQuantity = 1 }, -- Bleach
    [2325] = { unitPrice = 950, purchasePrice = 950, purchaseQuantity = 1 }, -- Black Dye
    [2604] = { unitPrice = 48, purchasePrice = 48, purchaseQuantity = 1 }, -- Red Dye
    [2605] = { unitPrice = 95, purchasePrice = 95, purchaseQuantity = 1 }, -- Green Dye
    [2901] = { unitPrice = 117, purchasePrice = 117, purchaseQuantity = 1 }, -- Mining Pick
    [4340] = { unitPrice = 333, purchasePrice = 333, purchaseQuantity = 1 }, -- Gray Dye
    [4341] = { unitPrice = 475, purchasePrice = 475, purchaseQuantity = 1 }, -- Yellow Dye
    [4342] = { unitPrice = 2375, purchasePrice = 2375, purchaseQuantity = 1 }, -- Purple Dye
    [5956] = { unitPrice = 1, purchasePrice = 1, purchaseQuantity = 1 }, -- Blacksmith Hammer
    [6219] = { unitPrice = 900, purchasePrice = 900, purchaseQuantity = 1 }, -- Arclight Spanner
    [6260] = { unitPrice = 48, purchasePrice = 48, purchaseQuantity = 1 }, -- Blue Dye
    [6261] = { unitPrice = 950, purchasePrice = 950, purchaseQuantity = 1 }, -- Orange Dye
    [7005] = { unitPrice = 118, purchasePrice = 118, purchaseQuantity = 1 }, -- Skinning Knife
    [10290] = { unitPrice = 2375, purchasePrice = 2375, purchaseQuantity = 1 }, -- Pink Dye
    [10498] = { unitPrice = 13300, purchasePrice = 13300, purchaseQuantity = 1 }, -- Gyromatic Micro-Adjustor
    [20815] = { unitPrice = 760, purchasePrice = 760, purchaseQuantity = 1 }, -- Jeweler's Toolset
    [38682] = { unitPrice = 950, purchasePrice = 950, purchaseQuantity = 1 }, -- Enchanting Vellum
    [39489] = { unitPrice = 4750, purchasePrice = 4750, purchaseQuantity = 1 }, -- Scribe's Satchel
    [39505] = { unitPrice = 713, purchasePrice = 713, purchaseQuantity = 1 }, -- Virtuoso Inking Set
    [85663] = { unitPrice = 151, purchasePrice = 151, purchaseQuantity = 1 }, -- Herbalist's Spade
    [210828] = { unitPrice = 118750, purchasePrice = 118750, purchaseQuantity = 1 }, -- Dilution Solution
    [211806] = { unitPrice = 26125, purchasePrice = 26125, purchaseQuantity = 1 }, -- Gilded Vial
    [212498] = { unitPrice = 9500, purchasePrice = 9500, purchaseQuantity = 1 }, -- Ambivalent Amber
    [213398] = { unitPrice = 4750, purchasePrice = 4750, purchaseQuantity = 1 }, -- Handful of Pebbles
    [213399] = { unitPrice = 4750, purchasePrice = 4750, purchaseQuantity = 1 }, -- Glittering Glass
    [219150] = { unitPrice = 47500, purchasePrice = 47500, purchaseQuantity = 1 }, -- Pile of Rusted Scrap
    [224764] = { unitPrice = 665, purchasePrice = 665, purchaseQuantity = 1 }, -- Mosswool Thread
    [226202] = { unitPrice = 2850, purchasePrice = 2850, purchaseQuantity = 1 }, -- Echoing Flux
    [226204] = { unitPrice = 2000, purchasePrice = 2000, purchaseQuantity = 1 }, -- Fresh Parchment
    [226205] = { unitPrice = 91, purchasePrice = 91, purchaseQuantity = 1 }, -- Distilled Algari Freshwater
    [227208] = { unitPrice = 47500, purchasePrice = 47500, purchaseQuantity = 1 }, -- Bismuth Rod
    [228414] = { unitPrice = 38000, purchasePrice = 38000, purchaseQuantity = 1 }, -- Frayed Wiring
    [228930] = { unitPrice = 1758, purchasePrice = 1758, purchaseQuantity = 1 }, -- Adorning Ribbon
    [228956] = { unitPrice = 95000, purchasePrice = 95000, purchaseQuantity = 1 }, -- Junk Bucket
    [240991] = { unitPrice = 27500, purchasePrice = 27500, purchaseQuantity = 1 }, -- Sunglass Vial
    [243060] = { unitPrice = 3000, purchasePrice = 3000, purchaseQuantity = 1 }, -- Luminant Flux
    [244174] = { unitPrice = 100000, purchasePrice = 100000, purchaseQuantity = 1 }, -- Refulgent Copper Rod
    [245881] = { unitPrice = 2105, purchasePrice = 2105, purchaseQuantity = 1 }, -- Lexicologist's Vellum
    [245882] = { unitPrice = 3595, purchasePrice = 3595, purchaseQuantity = 1 }, -- Thalassian Songwater
    [247811] = { unitPrice = 125000, purchasePrice = 125000, purchaseQuantity = 1 }, -- Oil of Heartwood
    [251665] = { unitPrice = 700, purchasePrice = 700, purchaseQuantity = 1 }, -- Silverleaf Thread
    [251691] = { unitPrice = 700, purchasePrice = 700, purchaseQuantity = 1 }, -- Embroidery Floss
    [253302] = { unitPrice = 2105, purchasePrice = 2105, purchaseQuantity = 1 }, -- Malleable Wireframe
    [253303] = { unitPrice = 2105, purchasePrice = 2105, purchaseQuantity = 1 }, -- Pile of Junk
    [263997] = { unitPrice = 50000, purchasePrice = 50000, purchaseQuantity = 1 }, -- Midnight Alchemist's Shop Sign
    [263998] = { unitPrice = 50000, purchasePrice = 50000, purchaseQuantity = 1 }, -- Midnight Blacksmith's Shop Sign
    [264000] = { unitPrice = 50000, purchasePrice = 50000, purchaseQuantity = 1 }, -- Midnight Enchanter's Shop Sign
    [264001] = { unitPrice = 50000, purchasePrice = 50000, purchaseQuantity = 1 }, -- Midnight Engineer's Shop Sign
    [264004] = { unitPrice = 50000, purchasePrice = 50000, purchaseQuantity = 1 }, -- Midnight Scribe's Shop Sign
    [264006] = { unitPrice = 50000, purchasePrice = 50000, purchaseQuantity = 1 }, -- Midnight Leatherworker's Shop Sign
    [264173] = { unitPrice = 50000, purchasePrice = 50000, purchaseQuantity = 1 }, -- Midnight Skinner's Shop Sign
    [264174] = { unitPrice = 50000, purchasePrice = 50000, purchaseQuantity = 1 }, -- Midnight Tailor's Shop Sign
}

if PocketCFO_Valuation then
    PocketCFO_Valuation.VendorPriceDefaults = VendorPriceDefaults
end
