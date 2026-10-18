-- PocketCFO/Services/ProfessionRegistry/ProfessionRegistry.lua
-- Core shared profession and expansion metadata.

local PocketCFO = _G.PocketCFO

local ProfessionRegistry = {}

ProfessionRegistry.EXPANSION_DRAGONFLIGHT = 10
ProfessionRegistry.EXPANSION_TWW          = 11
ProfessionRegistry.EXPANSION_MIDNIGHT     = 12

local EXPANSION_NAMES = {
    [10] = "Dragonflight",
    [11] = "The War Within",
    [12] = "Midnight",
}

ProfessionRegistry.PROFESSION_CONFIG = {
    [164] = { name = "Blacksmithing",  enum = 1,  category = "crafting",  supportsCraftingToolUI = true  },
    [165] = { name = "Leatherworking", enum = 2,  category = "crafting",  supportsCraftingToolUI = true  },
    [171] = { name = "Alchemy",        enum = 3,  category = "crafting",  supportsCraftingToolUI = true  },
    [182] = { name = "Herbalism",      enum = 4,  category = "gathering", supportsCraftingToolUI = false },
    [186] = { name = "Mining",         enum = 6,  category = "gathering", supportsCraftingToolUI = false },
    [197] = { name = "Tailoring",      enum = 7,  category = "crafting",  supportsCraftingToolUI = true  },
    [202] = { name = "Engineering",    enum = 8,  category = "crafting",  supportsCraftingToolUI = true  },
    [333] = { name = "Enchanting",     enum = 9,  category = "crafting",  supportsCraftingToolUI = true  },
    [393] = { name = "Skinning",       enum = 11, category = "gathering", supportsCraftingToolUI = false },
    [755] = { name = "Jewelcrafting",  enum = 12, category = "crafting",  supportsCraftingToolUI = true  },
    [773] = { name = "Inscription",    enum = 13, category = "crafting",  supportsCraftingToolUI = true  },
}

local CHILD_SKILL_LINE_TO_EXPANSION = {
    [164] = { [2822] = 10, [2872] = 11, [2907] = 12 },
    [165] = { [2830] = 10, [2880] = 11, [2915] = 12 },
    [171] = { [2823] = 10, [2871] = 11, [2906] = 12 },
    [182] = { [2832] = 10, [2877] = 11, [2912] = 12 },
    [186] = { [2833] = 10, [2881] = 11, [2916] = 12 },
    [197] = { [2831] = 10, [2883] = 11, [2918] = 12 },
    [202] = { [2827] = 10, [2875] = 11, [2910] = 12 },
    [333] = { [2825] = 10, [2874] = 11, [2909] = 12 },
    [393] = { [2834] = 10, [2882] = 11, [2917] = 12 },
    [755] = { [2829] = 10, [2879] = 11, [2914] = 12 },
    [773] = { [2828] = 10, [2878] = 11, [2913] = 12 },
}

local function NormalizeLower(value)
    if not value then
        return ""
    end
    return string.lower(tostring(value))
end

function ProfessionRegistry:GetExpansionName(expansionID)
    return EXPANSION_NAMES[expansionID] or ("Unknown (" .. tostring(expansionID) .. ")")
end

function ProfessionRegistry:GetExpansionIDFromChildSkillLineID(professionID, childSkillLineID)
    if not professionID or not childSkillLineID then
        return nil
    end
    local map = CHILD_SKILL_LINE_TO_EXPANSION[professionID]
    if not map then
        return nil
    end
    return map[childSkillLineID]
end

function ProfessionRegistry:GetChildSkillLineID(professionID, expansionID)
    if not professionID or not expansionID then
        return nil
    end
    local map = CHILD_SKILL_LINE_TO_EXPANSION[professionID]
    if not map then
        return nil
    end
    for childSkillLineID, expID in pairs(map) do
        if expID == expansionID then
            return childSkillLineID
        end
    end
    return nil
end

function ProfessionRegistry:GetProfessionConfig(professionID)
    if not professionID then
        return nil
    end
    return self.PROFESSION_CONFIG[professionID]
end

function ProfessionRegistry:IsSupportedProfessionID(professionID)
    return self:GetProfessionConfig(professionID) ~= nil
end

function ProfessionRegistry:IsCraftingProfession(professionID)
    local config = self:GetProfessionConfig(professionID)
    return config and config.category == "crafting" or false
end

function ProfessionRegistry:IsGatheringProfession(professionID, professionName)
    local config = self:GetProfessionConfig(professionID)
    if config then
        return config.category == "gathering"
    end

    local name = NormalizeLower(professionName)
    return name == "mining" or name == "skinning" or name == "herbalism"
end

function ProfessionRegistry:GetProfessionIDFromEnum(professionEnum)
    if not professionEnum then
        return nil
    end
    for professionID, config in pairs(self.PROFESSION_CONFIG) do
        if config.enum == professionEnum then
            return professionID
        end
    end
    return nil
end

if PocketCFO then
    PocketCFO.ProfessionRegistry = ProfessionRegistry
end

_G.PocketCFO_ProfessionRegistry = ProfessionRegistry
