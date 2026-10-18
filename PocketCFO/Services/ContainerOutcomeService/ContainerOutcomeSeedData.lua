-- PocketCFO/Services/ContainerOutcomeService/ContainerOutcomeSeedData.lua
-- Published seed aggregate for container-open outcomes. Immutable at runtime -
-- local observations layer on top of this in SavedVariables, never copied in.
--
-- Source: MCG_DataLogger's live "Bag Opens Aggregate Debug" aggregate
-- (WTF SavedVariables, /mcgdl bagopens), parsed directly rather than hand-typed.
--
-- Two self-referential rows (a container listing itself as its own loot output)
-- were excluded as capture artifacts - see PocketCFO_Orders MVP completion report
-- for the evidence (227713 self-rate ~9.5pct vs 246585 self-rate ~0.26pct, and
-- MCG_DataLoggers diff algorithm cannot attribute loot to a specific container
-- within a batched BAG_UPDATE_DELAYED window).

local PocketCFO = _G.PocketCFO

local SEED_VERSION = 1

local SEED_CONTAINERS = {
    [260534] = {
        bagName = "Alchemist Surplus",
        openCount = 7,
        outputs = {
            { itemID = 236780, quality = 0, quantity = 34 }, -- Nocturnal Lotus
            { itemID = 236777, quality = 2, quantity = 121 }, -- Argentleaf
            { itemID = 251285, quality = 0, quantity = 12 }, -- Petrified Root
            { itemID = 236775, quality = 2, quantity = 119 }, -- Azeroot
            { itemID = 236771, quality = 2, quantity = 119 }, -- Sanguithorn
            { itemID = 236767, quality = 2, quantity = 245 }, -- Tranquility Bloom
            { itemID = 236779, quality = 2, quantity = 116 }, -- Mana Lily
        },
    },
    [246585] = {
        bagName = "Consortium Payout (Midnight)",
        openCount = 777,
        outputs = {
            { itemID = 236777, quality = 2, quantity = 54 }, -- Argentleaf
            { itemID = 236776, quality = 1, quantity = 85 }, -- Argentleaf
            { itemID = 238512, quality = 2, quantity = 163 }, -- Void-Tempered Leather
            { itemID = 236778, quality = 1, quantity = 88 }, -- Mana Lily
            { itemID = 236774, quality = 1, quantity = 84 }, -- Azeroot
            { itemID = 237359, quality = 1, quantity = 782 }, -- Refulgent Copper Ore
            { itemID = 260630, quality = 0, quantity = 240 }, -- Ingenious Identifier
            { itemID = 236779, quality = 2, quantity = 45 }, -- Mana Lily
            { itemID = 245767, quality = 2, quantity = 4 }, -- Soul Cipher
            { itemID = 246447, quality = 0, quantity = 2 }, -- Apprentice's Scribbles
            { itemID = 259085, quality = 0, quantity = 2 }, -- Void-Touched Augment Rune
            -- excluded self-referential capture artifact: itemID=246585 quality=0 quantity=2 ("Artisan's Consortium Payout")
            { itemID = 238523, quality = 0, quantity = 102 }, -- Carving Canine
            { itemID = 210814, quality = 0, quantity = 30 }, -- Artisan's Acuity
            { itemID = 238522, quality = 0, quantity = 130 }, -- Peerless Plumage
            { itemID = 246335, quality = 0, quantity = 2 }, -- Glimmer of Midnight Tailoring Knowledge
            { itemID = 238514, quality = 2, quantity = 248 }, -- Void-Tempered Scales
            { itemID = 246449, quality = 0, quantity = 1 }, -- Mentor's Helpful Handiwork
            { itemID = 237364, quality = 1, quantity = 122 }, -- Brilliant Silver Ore
            { itemID = 236770, quality = 1, quantity = 85 }, -- Sanguithorn
            { itemID = 236775, quality = 2, quantity = 34 }, -- Azeroot
            { itemID = 221790, quality = 5, quantity = 1 }, -- Bismuth Fisherfriend
            { itemID = 238520, quality = 1, quantity = 1 }, -- Void-Tempered Plating
            { itemID = 237365, quality = 2, quantity = 65 }, -- Brilliant Silver Ore
            { itemID = 238525, quality = 0, quantity = 104 }, -- Fantastic Fur
            { itemID = 237366, quality = 0, quantity = 15 }, -- Dazzling Thorium
            { itemID = 238511, quality = 1, quantity = 400 }, -- Void-Tempered Leather
            { itemID = 236780, quality = 0, quantity = 10 }, -- Nocturnal Lotus
            { itemID = 238513, quality = 1, quantity = 338 }, -- Void-Tempered Scales
            { itemID = 236771, quality = 2, quantity = 37 }, -- Sanguithorn
            { itemID = 238519, quality = 2, quantity = 2 }, -- Void-Tempered Hide
            { itemID = 236761, quality = 1, quantity = 428 }, -- Tranquility Bloom
            { itemID = 247719, quality = 0, quantity = 253 }, -- Multicraft Matrix
            { itemID = 237362, quality = 1, quantity = 118 }, -- Umbral Tin Ore
            { itemID = 238518, quality = 1, quantity = 3 }, -- Void-Tempered Hide
            { itemID = 222573, quality = 5, quantity = 1 }, -- Lightweight Scribe's Quill
            { itemID = 251285, quality = 0, quantity = 249 }, -- Petrified Root
            { itemID = 237361, quality = 2, quantity = 328 }, -- Refulgent Copper Ore
            { itemID = 247725, quality = 0, quantity = 254 }, -- Resourceful Rebar
            { itemID = 237363, quality = 2, quantity = 60 }, -- Umbral Tin Ore
            { itemID = 236767, quality = 2, quantity = 288 }, -- Tranquility Bloom
        },
    },
    [227713] = {
        bagName = "Consortium Payout (TWW)",
        openCount = 42,
        outputs = {
            { itemID = 210796, quality = 1, quantity = 11 }, -- Mycobloom
            { itemID = 218339, quality = 0, quantity = 2 }, -- Burning Cinderbee Setae
            { itemID = 218337, quality = 0, quantity = 8 }, -- Honed Bone Shards
            { itemID = 219150, quality = 0, quantity = 43 }, -- Pile of Rusted Scrap
            -- excluded self-referential capture artifact: itemID=227713 quality=0 quantity=4 ("Artisan's Consortium Payout")
            { itemID = 210805, quality = 1, quantity = 12 }, -- Blessing Blossom
            { itemID = 228724, quality = 0, quantity = 1 }, -- Flicker of Alchemy Knowledge
            { itemID = 210935, quality = 3, quantity = 5 }, -- Aqirite
            { itemID = 212665, quality = 2, quantity = 11 }, -- Stormcharged Leather
            { itemID = 210797, quality = 2, quantity = 10 }, -- Mycobloom
            { itemID = 210809, quality = 2, quantity = 4 }, -- Arathor's Spear
            { itemID = 212669, quality = 3, quantity = 6 }, -- Gloom Chitin
            { itemID = 225670, quality = 0, quantity = 1 }, -- Apprentice's Crafting License
            { itemID = 228737, quality = 0, quantity = 2 }, -- Glimmer of Leatherworking Knowledge
            { itemID = 210938, quality = 3, quantity = 5 }, -- Ironclaw Ore
            { itemID = 218336, quality = 0, quantity = 7 }, -- Kaheti Swarm Chitin
            { itemID = 210933, quality = 1, quantity = 7 }, -- Aqirite
            { itemID = 210806, quality = 2, quantity = 5 }, -- Blessing Blossom
            { itemID = 210808, quality = 1, quantity = 4 }, -- Arathor's Spear
            { itemID = 210799, quality = 1, quantity = 2 }, -- Luredrop
            { itemID = 210936, quality = 1, quantity = 17 }, -- Ironclaw Ore
            { itemID = 228739, quality = 0, quantity = 1 }, -- Glimmer of Tailoring Knowledge
            { itemID = 210814, quality = 0, quantity = 220 }, -- Artisan's Acuity
            { itemID = 212674, quality = 1, quantity = 1 }, -- Sunless Carapace
            { itemID = 210802, quality = 1, quantity = 3 }, -- Orbinid
            { itemID = 210931, quality = 2, quantity = 11 }, -- Bismuth
            { itemID = 212670, quality = 1, quantity = 1 }, -- Thunderous Hide
            { itemID = 212664, quality = 1, quantity = 27 }, -- Stormcharged Leather
            { itemID = 210803, quality = 2, quantity = 5 }, -- Orbinid
            { itemID = 210939, quality = 0, quantity = 1 }, -- Null Stone
            { itemID = 210930, quality = 1, quantity = 28 }, -- Bismuth
        },
    },
    [260537] = {
        bagName = "Enchanter Surplus",
        openCount = 4,
        outputs = {
            { itemID = 243606, quality = 2, quantity = 22 }, -- Dawn Crystal
            { itemID = 243603, quality = 2, quantity = 96 }, -- Radiant Shard
            { itemID = 243600, quality = 2, quantity = 237 }, -- Eversinging Dust
            { itemID = 251285, quality = 0, quantity = 11 }, -- Petrified Root
        },
    },
    [260538] = {
        bagName = "Engineer Surplus",
        openCount = 10,
        outputs = {
            { itemID = 237365, quality = 2, quantity = 269 }, -- Brilliant Silver Ore
            { itemID = 251285, quality = 0, quantity = 19 }, -- Petrified Root
            { itemID = 237366, quality = 0, quantity = 84 }, -- Dazzling Thorium
            { itemID = 237363, quality = 2, quantity = 234 }, -- Umbral Tin Ore
            { itemID = 237361, quality = 2, quantity = 451 }, -- Refulgent Copper Ore
        },
    },
    [260539] = {
        bagName = "Herbalist Surplus",
        openCount = 1,
        outputs = {
            { itemID = 236780, quality = 0, quantity = 5 }, -- Nocturnal Lotus
            { itemID = 236777, quality = 2, quantity = 18 }, -- Argentleaf
            { itemID = 251285, quality = 0, quantity = 3 }, -- Petrified Root
            { itemID = 236775, quality = 2, quantity = 19 }, -- Azeroot
            { itemID = 236771, quality = 2, quantity = 15 }, -- Sanguithorn
            { itemID = 236767, quality = 2, quantity = 30 }, -- Tranquility Bloom
            { itemID = 236779, quality = 2, quantity = 16 }, -- Mana Lily
        },
    },
    [260541] = {
        bagName = "Jewelcrafter Surplus",
        openCount = 7,
        outputs = {
            { itemID = 237365, quality = 2, quantity = 181 }, -- Brilliant Silver Ore
            { itemID = 251285, quality = 0, quantity = 15 }, -- Petrified Root
            { itemID = 237366, quality = 0, quantity = 58 }, -- Dazzling Thorium
            { itemID = 237363, quality = 2, quantity = 164 }, -- Umbral Tin Ore
            { itemID = 237361, quality = 2, quantity = 315 }, -- Refulgent Copper Ore
        },
    },
    [260542] = {
        bagName = "Leatherworker Surplus",
        openCount = 3,
        outputs = {
            { itemID = 238519, quality = 2, quantity = 15 }, -- Void-Tempered Hide
            { itemID = 238523, quality = 0, quantity = 18 }, -- Carving Canine
            { itemID = 256625, quality = 0, quantity = 1 }, -- Pattern: Hexwoven Strand
            { itemID = 238522, quality = 0, quantity = 15 }, -- Peerless Plumage
            { itemID = 251285, quality = 0, quantity = 3 }, -- Petrified Root
            { itemID = 238514, quality = 2, quantity = 104 }, -- Void-Tempered Scales
            { itemID = 238521, quality = 2, quantity = 9 }, -- Void-Tempered Plating
            { itemID = 238512, quality = 2, quantity = 101 }, -- Void-Tempered Leather
            { itemID = 238525, quality = 0, quantity = 14 }, -- Fantastic Fur
        },
    },
    [260545] = {
        bagName = "Master Tailor's Surplus Reagents",
        openCount = 10,
        outputs = {
            { itemID = 239202, quality = 2, quantity = 18 }, -- Sunfire Silk Bolt
            { itemID = 251285, quality = 0, quantity = 25 }, -- Petrified Root
            { itemID = 237016, quality = 2, quantity = 98 }, -- Sunfire Silk
            { itemID = 237017, quality = 2, quantity = 94 }, -- Arcanoweave
            { itemID = 239200, quality = 2, quantity = 17 }, -- Arcanoweave Bolt
            { itemID = 236965, quality = 2, quantity = 211 }, -- Bright Linen
        },
    },
    [260543] = {
        bagName = "Miner Surplus",
        openCount = 1,
        outputs = {
            { itemID = 237365, quality = 2, quantity = 28 }, -- Brilliant Silver Ore
            { itemID = 251285, quality = 0, quantity = 3 }, -- Petrified Root
            { itemID = 237366, quality = 0, quantity = 8 }, -- Dazzling Thorium
            { itemID = 237363, quality = 2, quantity = 20 }, -- Umbral Tin Ore
            { itemID = 237361, quality = 2, quantity = 41 }, -- Refulgent Copper Ore
        },
    },
    [260540] = {
        bagName = "Scribe Surplus",
        openCount = 7,
        outputs = {
            { itemID = 236780, quality = 0, quantity = 24 }, -- Nocturnal Lotus
            { itemID = 236777, quality = 2, quantity = 104 }, -- Argentleaf
            { itemID = 251285, quality = 0, quantity = 14 }, -- Petrified Root
            { itemID = 236775, quality = 2, quantity = 102 }, -- Azeroot
            { itemID = 236771, quality = 2, quantity = 112 }, -- Sanguithorn
            { itemID = 236767, quality = 2, quantity = 207 }, -- Tranquility Bloom
            { itemID = 236779, quality = 2, quantity = 107 }, -- Mana Lily
        },
    },
    [260544] = {
        bagName = "Skinner Surplus",
        openCount = 1,
        outputs = {
            { itemID = 238514, quality = 2, quantity = 30 }, -- Void-Tempered Scales
            { itemID = 238522, quality = 0, quantity = 5 }, -- Peerless Plumage
            { itemID = 238523, quality = 0, quantity = 5 }, -- Carving Canine
            { itemID = 251285, quality = 0, quantity = 3 }, -- Petrified Root
        },
    },
    [260536] = {
        bagName = "Smith Surplus",
        openCount = 6,
        outputs = {
            { itemID = 237365, quality = 2, quantity = 141 }, -- Brilliant Silver Ore
            { itemID = 251285, quality = 0, quantity = 11 }, -- Petrified Root
            { itemID = 237366, quality = 0, quantity = 41 }, -- Dazzling Thorium
            { itemID = 237363, quality = 2, quantity = 140 }, -- Umbral Tin Ore
            { itemID = 237361, quality = 2, quantity = 268 }, -- Refulgent Copper Ore
        },
    },
}

local ContainerOutcomeSeedData = {
    seedVersion = SEED_VERSION,
    containers = SEED_CONTAINERS,
}

if PocketCFO then
    PocketCFO.ContainerOutcomeSeedData = ContainerOutcomeSeedData
end

_G.PocketCFO_ContainerOutcomeSeedData = ContainerOutcomeSeedData
