local addonName = ...
local _, class = UnitClass("player")
if class ~= "DRUID" then return end

local frame = CreateFrame("Frame")
local db, timer, started
local applying, deferred, retryCount = false, false, 0
local lastAttempt, burstStart, burstCount = -100, -100, 0
local conflictReported = false
local lastStatus = "Waiting for talents."
local labels = { TANK = "Tank", DAMAGER = "DPS", HEALER = "Healer", NONE = "None" }

-- Stable spell IDs identify the talents on every client language. Names also
-- cover a future replacement spell ID, without depending on tree positions.
local rules = {
    { key = "hide", name = "Thick Hide", spellID = 16929 },
    { key = "bite", name = "Primal Bite", spellID = 407995 },
    { key = "shift", name = "Shifting Power", spellID = 1322605 },
    { key = "moonkin", name = "Moonkin Form", spellID = 24858 },
    { key = "growth", name = "Wild Growth", spellID = 408120 },
}

local function Safe(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
end

local function Print(message)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff70c0ffLakoAutoRole:|r " .. message)
    end
end

local function ActiveConfig()
    -- Forever's active spec group is authoritative, including dual spec.
    if C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup
        and C_SpecializationInfo.GetCombatConfigIDForSpecGroup then
        local group = Safe(C_SpecializationInfo.GetActiveSpecGroup)
        if not group then return nil end
        return Safe(C_SpecializationInfo.GetCombatConfigIDForSpecGroup, group)
    end
    return C_ClassTalents and Safe(C_ClassTalents.GetActiveConfigID)
end

local function SpellName(id)
    return C_Spell and Safe(C_Spell.GetSpellName, id)
end

local function ReadTalents()
    local configID = ActiveConfig()
    if not configID or not C_Traits then
        return nil, "Active talent data is not ready."
    end
    if C_Traits.ConfigHasStagedChanges then
        local staged = Safe(C_Traits.ConfigHasStagedChanges, configID)
        if staged == nil then return nil, "Talent data is not ready." end
        if staged then return nil, "Apply or discard your pending talent changes first." end
    end
    local config = Safe(C_Traits.GetConfigInfo, configID)
    if not config or not config.treeIDs or #config.treeIDs == 0 then
        return nil, "Talent trees are not ready."
    end

    local byID, byName, talents = {}, {}, {}
    for _, rule in ipairs(rules) do
        talents[rule.key] = 0
        byID[rule.spellID] = rule.key
        byName[rule.name] = rule.key
        local localized = SpellName(rule.spellID)
        if localized then byName[localized] = rule.key end
    end

    local nodeCount = 0
    for _, treeID in ipairs(config.treeIDs) do
        local nodes = Safe(C_Traits.GetTreeNodes, treeID)
        if not nodes or #nodes == 0 then return nil, "Talent nodes are not ready." end
        for _, nodeID in ipairs(nodes) do
            local node = Safe(C_Traits.GetNodeInfo, configID, nodeID)
            if not node or node.ID == 0 then return nil, "Talent nodes are not ready." end
            nodeCount = nodeCount + 1
            local active = node.activeEntry
            local rank = math.max(node.activeRank or 0, node.currentRank or 0,
                node.ranksPurchased or 0, active and active.rank or 0)
            if rank > 0 and node.subTreeActive ~= false then
                local entries = node.entryIDs or {}
                -- A choice node must only credit its selected entry.
                if active and active.entryID then
                    entries = { active.entryID }
                elseif #entries > 1 then
                    entries = node.entryIDsWithCommittedRanks or {}
                end
                for _, entryID in ipairs(entries) do
                    local entry = Safe(C_Traits.GetEntryInfo, configID, entryID)
                    if not entry then return nil, "Talent entries are not ready." end
                    if entry.definitionID then
                        local definition = Safe(C_Traits.GetDefinitionInfo, entry.definitionID)
                        if not definition then return nil, "Talent definitions are not ready." end
                        local key = byID[definition.spellID]
                            or byName[definition.overrideName]
                            or byName[SpellName(definition.spellID)]
                        if key then talents[key] = math.max(talents[key], rank) end
                    end
                end
            end
        end
    end
    if nodeCount == 0 then return nil, "Talent data is not ready." end
    -- Do not use a reading if the active spec changed during the scan.
    if ActiveConfig() ~= configID then return nil, "Talent specialization is changing." end
    return talents
end

local function ChooseRole(talents)
    -- Explicit priority for unusual hybrid builds, in the user's rule order.
    if talents.hide > 0 and talents.bite > 0 then
        return "TANK", "Thick Hide + Primal Bite"
    elseif talents.shift > 0 then
        return "DAMAGER", "Shifting Power"
    elseif talents.moonkin > 0 then
        return "DAMAGER", "Moonkin Form"
    elseif talents.growth > 0 then
        return "HEALER", "Wild Growth"
    end
end

local Update
local function Schedule(delay)
    if not started or not db.enabled then return end
    if timer then timer:Cancel() end
    timer = C_Timer.NewTimer(delay or 0.4, function()
        timer = nil
        Update()
    end)
end

local function Retry()
    if retryCount < 3 then
        retryCount = retryCount + 1
        Schedule(1.5)
    end
end

Update = function()
    if not db or not db.enabled then return end
    if InCombatLockdown() then
        deferred = true
        lastStatus = "Waiting for combat to end."
        return
    end
    deferred = false
    local talents, problem = ReadTalents()
    if not talents then
        lastStatus = problem
        Retry()
        return
    end
    local role, reason = ChooseRole(talents)
    if not role then
        lastStatus = "No matching talent rule; your role was left unchanged."
        return
    end
    if not IsInGroup() then
        lastStatus = "Detected " .. labels[role] .. " (" .. reason .. "); waiting for a group."
        return
    end
    if UnitGroupRolesAssigned("player") == role then
        retryCount = 0
        lastStatus = "Your group role is " .. labels[role] .. " (" .. reason .. ")."
        return
    end

    local now = GetTime()
    if now - burstStart >= 20 then
        burstStart, burstCount, conflictReported = now, 0, false
    end
    -- Role changes from another addon can trigger this event too. Throttle
    -- corrections and cap them so competing auto-role addons cannot loop.
    if burstCount >= 3 then
        lastStatus = "Repeated role changes detected; automatic corrections are paused briefly."
        if not conflictReported then
            conflictReported = true
            Print("Another setting may be changing your role. Check other auto-role addons if this continues.")
        end
        return
    end
    if now - lastAttempt < 2 then
        Schedule(2 - (now - lastAttempt) + 0.1)
        return
    end
    lastAttempt, burstCount = now, burstCount + 1
    applying = true
    local success = Safe(UnitSetRole, "player", role)
    applying = false
    if success == false or success == nil then
        lastStatus = "The game did not accept the role change; will retry."
        Retry()
        return
    end
    lastStatus = "Requested " .. labels[role] .. " (" .. reason .. ")."
    Schedule(0.6)
end

local function Status()
    Print("Automatic roles: " .. (db.enabled and "ON" or "OFF") .. ".")
    local talents, problem = ReadTalents()
    if talents then
        for _, rule in ipairs(rules) do
            Print(rule.name .. ": " .. talents[rule.key] .. " point(s)")
        end
        local role, reason = ChooseRole(talents)
        Print(role and ("Detected: " .. labels[role] .. " (" .. reason .. ").") or "No matching rule.")
    else
        Print(problem)
    end
    Print("Current group role: " .. (labels[UnitGroupRolesAssigned("player")] or "None") .. ".")
    Print(lastStatus)
end

SLASH_LAKOAUTOROLE1 = "/lar"
SLASH_LAKOAUTOROLE2 = "/lakoautorole"
SlashCmdList.LAKOAUTOROLE = function(message)
    if not db then return end
    local command = (message or ""):lower():match("^%s*(%S*)")
    if command == "off" then
        db.enabled = false
        if timer then timer:Cancel(); timer = nil end
        Print("Automatic roles OFF.")
    elseif command == "on" or command == "check" then
        if command == "on" then db.enabled = true end
        retryCount, burstCount, burstStart = 0, 0, -100
        if command == "on" then Print("Automatic roles ON.") end
        Schedule(0.1)
    elseif command == "" or command == "status" then
        Status()
    else
        Print("/lar status, /lar check, /lar on, /lar off")
    end
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        if type(LakoAutoRoleDB) ~= "table" then LakoAutoRoleDB = {} end
        db = LakoAutoRoleDB
        if db.enabled == nil then db.enabled = true end
        frame:UnregisterEvent("ADDON_LOADED")
        return
    end
    if event == "PLAYER_LOGIN" then started = true end
    if not started or not db or not db.enabled then return end
    if event == "PLAYER_SPECIALIZATION_CHANGED" and arg1 and arg1 ~= "player" then return end
    if event == "ROLE_CHANGED_INFORM" and applying then return end
    if event == "PLAYER_REGEN_ENABLED" and not deferred then return end
    retryCount = 0
    Schedule(event == "GROUP_JOINED" and 1 or 0.4)
end)

for _, event in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
    "PLAYER_TALENT_UPDATE", "PLAYER_SPECIALIZATION_CHANGED", "ACTIVE_TALENT_GROUP_CHANGED",
    "TRAIT_CONFIG_UPDATED", "TRAIT_CONFIG_CREATED", "TRAIT_CONFIG_LIST_UPDATED",
    "GROUP_JOINED", "GROUP_ROSTER_UPDATE", "ROLE_CHANGED_INFORM", "ROLE_POLL_BEGIN",
    "PLAYER_REGEN_ENABLED", "SPELLS_CHANGED",
}) do
    frame:RegisterEvent(event)
end
