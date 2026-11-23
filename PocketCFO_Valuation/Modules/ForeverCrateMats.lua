-- PocketCFO_Valuation/Modules/ForeverCrateMats.lua
-- Forever only (loaded by PocketCFO_Valuation_Camelot.toc).
--
-- Every mat a Waylaid Crate can ask for (all 30 crates, 96 mats; list from
-- method.gg, matches both in-game captures of 2026-11-17). The tooltip reads
-- the bundle names off the crate (Tooltip.lua, ReadCrateBundles) and turns
-- each name into an itemID with C_Item.GetItemIDForItemInfo, which only
-- works for items the client has loaded (confirmed 2026-11-17: Wool Cloth
-- resolved, Bronze Tube returned 0). Loading these items when this addon
-- enables makes the lookup work for mats the player has never seen, in any
-- client language. Theoretical until checked in-game: that a requested load
-- is enough for GetItemIDForItemInfo (check: /mcgd crate verify).
--
-- Names are English and only used by /mcgd crate verify to catch a wrong
-- itemID; the tooltip never reads them.
-- IDs are the vanilla item IDs. Confirmed in-game: 2592, 4306, 2319.
-- Seen on outof.games item links: 8172, 15994, 13464, 4304, 6037, 7911,
-- 13465, 11175. Others: Theoretical until /mcgd crate verify passes.

local PocketCFO_Valuation = _G.PocketCFO_Valuation
local CrateMats = PocketCFO_Valuation:NewModule("ForeverCrateMats")

CrateMats.MATS = {
    -- Ore
    [2770] = "Copper Ore", [2771] = "Tin Ore", [2775] = "Silver Ore", [2772] = "Iron Ore",
    [2776] = "Gold Ore", [3858] = "Mithril Ore", [7911] = "Truesilver Ore", [10620] = "Thorium Ore",
    [11370] = "Dark Iron Ore",
    -- Ingots
    [2840] = "Copper Bar", [3576] = "Tin Bar", [2841] = "Bronze Bar", [2842] = "Silver Bar",
    [3575] = "Iron Bar", [3860] = "Mithril Bar", [3859] = "Steel Bar", [3577] = "Gold Bar",
    [11371] = "Dark Iron Bar", [6037] = "Truesilver Bar", [12359] = "Thorium Bar",
    -- Herbs
    [2447] = "Peacebloom", [765] = "Silverleaf", [2449] = "Earthroot", [785] = "Mageroyal",
    [2450] = "Briarthorn", [3820] = "Stranglekelp", [2453] = "Bruiseweed", [3355] = "Wild Steelbloom",
    [3369] = "Grave Moss", [3356] = "Kingsblood", [3357] = "Liferoot", [3818] = "Fadeleaf",
    [3821] = "Goldthorn", [3358] = "Khadgar's Whisker", [3819] = "Wintersbite", [4625] = "Firebloom",
    [8831] = "Purple Lotus", [8836] = "Arthas' Tears", [13464] = "Golden Sansam", [8838] = "Sungrass",
    [8839] = "Blindweed", [8845] = "Ghost Mushroom", [8846] = "Gromsblood", [13463] = "Dreamfoil",
    [13465] = "Mountain Silversage", [13466] = "Plaguebloom", [13467] = "Icecap",
    -- Parts
    [4359] = "Handful of Copper Bolts", [4361] = "Copper Tube", [4363] = "Copper Modulator",
    [4371] = "Bronze Tube", [4375] = "Whirring Bronze Gizmo", [4382] = "Bronze Framework",
    [10558] = "Gold Power Core", [4387] = "Iron Strut", [10559] = "Mithril Tube",
    [10560] = "Unstable Trigger", [10561] = "Mithril Casing", [15994] = "Thorium Widget",
    [18631] = "Truesilver Transformer", [16000] = "Thorium Tube",
    -- Textiles
    [2589] = "Linen Cloth", [2318] = "Light Leather", [2592] = "Wool Cloth", [4306] = "Silk Cloth",
    [2319] = "Medium Leather", [4338] = "Mageweave Cloth", [4234] = "Heavy Leather",
    [14047] = "Runecloth", [4304] = "Thick Leather", [8170] = "Rugged Leather",
    -- Fabrics
    [4231] = "Cured Light Hide", [2996] = "Bolt of Linen Cloth", [2997] = "Bolt of Woolen Cloth",
    [4305] = "Bolt of Silk Cloth", [4233] = "Cured Medium Hide", [4339] = "Bolt of Mageweave",
    [4236] = "Cured Heavy Hide", [14048] = "Bolt of Runecloth", [8172] = "Cured Thick Hide",
    -- Curiosities
    [10940] = "Strange Dust", [10939] = "Greater Magic Essence", [10978] = "Small Glimmering Shard",
    [11084] = "Large Glimmering Shard", [11083] = "Soul Dust", [11082] = "Greater Astral Essence",
    [11138] = "Small Glowing Shard", [11139] = "Large Glowing Shard", [11137] = "Vision Dust",
    [11135] = "Greater Mystic Essence", [11177] = "Small Radiant Shard", [11178] = "Large Radiant Shard",
    [11176] = "Dream Dust", [11175] = "Greater Nether Essence", [14343] = "Small Brilliant Shard",
    [14344] = "Large Brilliant Shard",
}

-- Every Waylaid Crate by itemID (Brian 2026-11-17: item IDs, not names, so
-- it works in any client language). tier = Favor tier; the white / green
-- doubling comes from the crate's own quality in game (Tooltip.lua).
-- Confirmed: 248685, 248688, 248707 (in-game captures); 248682-248684,
-- 248686, 248687, 248689, 248693, 248699, 248703, 248706 (wowhead);
-- 248702, 248705, 248708, 248711, 248712 (wclbox / foreverchanges).
-- inferred = true: fills a gap in the same numbering (gathered 248682-699:
-- per tier Herbs [Earthly, Flowering from Expert up], Ore, Textiles,
-- Curiosities; crafted 248702-713: per tier Fabrics, Ingots, Parts).
-- Theoretical until /mcgd crate verify shows the expected name.
CrateMats.CRATES = {
    [248682] = { tier = "Apprentice", name = "Waylaid Crate: Apprentice Herbs" },
    [248683] = { tier = "Apprentice", name = "Waylaid Crate: Apprentice Ore" },
    [248684] = { tier = "Apprentice", name = "Waylaid Crate: Apprentice Textiles" },
    [248685] = { tier = "Apprentice", name = "Waylaid Crate: Apprentice Curiosities" },
    [248686] = { tier = "Journeyman", name = "Waylaid Crate: Journeyman Herbs" },
    [248687] = { tier = "Journeyman", name = "Waylaid Crate: Journeyman Ore" },
    [248688] = { tier = "Journeyman", name = "Waylaid Crate: Journeyman Textiles" },
    [248689] = { tier = "Journeyman", name = "Waylaid Crate: Journeyman Curiosities" },
    [248690] = { tier = "Expert", name = "Waylaid Crate: Earthly Expert Herbs", inferred = true },
    [248691] = { tier = "Expert", name = "Waylaid Crate: Flowering Expert Herbs", inferred = true },
    [248692] = { tier = "Expert", name = "Waylaid Crate: Expert Ore", inferred = true },
    [248693] = { tier = "Expert", name = "Waylaid Crate: Expert Textiles" },
    [248694] = { tier = "Expert", name = "Waylaid Crate: Expert Curiosities", inferred = true },
    [248695] = { tier = "Artisan", name = "Waylaid Crate: Earthly Artisan Herbs", inferred = true },
    [248696] = { tier = "Artisan", name = "Waylaid Crate: Flowering Artisan Herbs", inferred = true },
    [248697] = { tier = "Artisan", name = "Waylaid Crate: Artisan Ore", inferred = true },
    [248698] = { tier = "Artisan", name = "Waylaid Crate: Artisan Textiles", inferred = true },
    [248699] = { tier = "Artisan", name = "Waylaid Crate: Artisan Curiosities" },
    [248702] = { tier = "Apprentice", name = "Waylaid Crate: Apprentice Fabrics" },
    [248703] = { tier = "Apprentice", name = "Waylaid Crate: Apprentice Ingots" },
    [248704] = { tier = "Apprentice", name = "Waylaid Crate: Apprentice Parts", inferred = true },
    [248705] = { tier = "Journeyman", name = "Waylaid Crate: Journeyman Fabrics" },
    [248706] = { tier = "Journeyman", name = "Waylaid Crate: Journeyman Ingots" },
    [248707] = { tier = "Journeyman", name = "Waylaid Crate: Journeyman Parts" },
    [248708] = { tier = "Expert", name = "Waylaid Crate: Expert Fabrics" },
    [248709] = { tier = "Expert", name = "Waylaid Crate: Expert Ingots", inferred = true },
    [248710] = { tier = "Expert", name = "Waylaid Crate: Expert Parts", inferred = true },
    [248711] = { tier = "Artisan", name = "Waylaid Crate: Artisan Fabrics" },
    [248712] = { tier = "Artisan", name = "Waylaid Crate: Artisan Ingots" },
    [248713] = { tier = "Artisan", name = "Waylaid Crate: Artisan Parts", inferred = true },
}

-- Asks the client to load every mat and crate. Async and cheap (126 requests, once per
-- load of this addon). Theoretical: C_Item.RequestLoadItemDataByID on
-- Forever; GetItemInfo(itemID) also starts a load when the item isn't
-- cached, so it is the fallback.
function CrateMats:RequestLoad()
    local request = C_Item and C_Item.RequestLoadItemDataByID
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    for _, list in ipairs({ self.MATS, self.CRATES }) do
        for itemID in pairs(list) do
            if request then
                pcall(request, itemID)
            elseif getInfo then
                pcall(getInfo, itemID)
            end
        end
    end
end

function CrateMats:OnEnable()
    self:RequestLoad()
end

-- Name -> itemID for crate mats. Confirmed 2026-11-17 (/mcgd crate verify):
-- all 96 IDs above give the expected name, but C_Item.GetItemIDForItemInfo
-- still returns 0 for 75 of them after the load (it resolved only the 21
-- the player holds), so the tooltip can't use it for these. Instead the
-- index is built from GetItemInfo(itemID) names: the game's own name in
-- the client's language, matching the crate text. An ID whose name isn't
-- loaded yet is tried again on the next lookup.
local nameIndex, missing = {}, nil

local function BuildIndex()
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local stillMissing = {}
    for itemID in pairs(missing or CrateMats.MATS) do
        local ok, name = pcall(getInfo, itemID)
        if ok and type(name) == "string" and name ~= "" then
            nameIndex[name:lower()] = itemID
        else
            stillMissing[itemID] = true
        end
    end
    missing = next(stillMissing) and stillMissing or false
end

function CrateMats:GetItemIDByName(name)
    if type(name) ~= "string" then
        return nil
    end
    if missing ~= false then
        BuildIndex()
    end
    return nameIndex[name:lower()]
end
