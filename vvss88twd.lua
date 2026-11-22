local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RemoteFunctions = Remotes:WaitForChild("Functions")
local RemoteEvents = Remotes:WaitForChild("Events")
local GameConfig = workspace:WaitForChild("GameConfig")
local SharedTowerData = ReplicatedStorage:WaitForChild("SharedTowerData")
local RequestTowerAbility = RemoteFunctions:WaitForChild("RequestTowerAbility", 10)

local MacroFolder = "TWD_Macros"

if not isfolder(MacroFolder) then
    makefolder(MacroFolder)
end

local ConfigFile = MacroFolder .. "/twd_config.json"

local SCAN_INTERVAL = 0.25
local SCAN_HALF = SCAN_INTERVAL / 2

local previousState = getgenv().UnifiedMacroState
if previousState then
    previousState.running = false
end

if getgenv().UnifiedMacroHeartbeat then
    pcall(function()
        getgenv().UnifiedMacroHeartbeat:Disconnect()
    end)
end

local State = {
    running = true,
    loopEnabled = true,
    autoSkipVote = false,
    autoRejoinEnabled = false,
    macroRunning = false,
    manualStartInProgress = false,
    selectedMacroName = nil,
    recordName = "未命名",
    placedTowerIds = {},
    towerIndex = {},
    ignoredMatchEndedAt = nil,
    fallbackClockOrigin = workspace:GetServerTimeNow(),
    previousMatchStartedAt = workspace:GetAttribute("MatchStartedAt"),
    autoStartedThisMatch = false,
}

getgenv().UnifiedMacroState = State

local Recorder
local TowerTracker

local LogParagraph = nil
local logHistory = {}

local function PushLog(message)
    local timestamp = DateTime.now():FormatLocalTime("HH:mm:ss", "zh-cn")
    table.insert(logHistory, 1, timestamp .. "  " .. tostring(message))

    while #logHistory > 14 do
        table.remove(logHistory)
    end

    if LogParagraph then
        LogParagraph:Set({ Title = "最近日志", Content = table.concat(logHistory, "\n") })
    end
end

-- ===== 技能支持：塔 -> 技能名 映射（录制或手动使用技能后自动记住）=====
local AbilityMapFile = MacroFolder .. "/twd_ability_map.json"
local AbilityByTower = {}

local function SaveAbilityMap()
    local ok, json = pcall(function() return HttpService:JSONEncode(AbilityByTower) end)
    if ok then pcall(writefile, AbilityMapFile, json) end
end

local function LoadAbilityMap()
    local ok, content = pcall(readfile, AbilityMapFile)
    if not ok or not content then return end
    local ok2, data = pcall(function() return HttpService:JSONDecode(content) end)
    if ok2 and type(data) == "table" then
        for k, v in pairs(data) do
            if type(k) == "string" and type(v) == "string" then AbilityByTower[k] = v end
        end
    end
end

local function LearnAbility(uniqueId, abilityName)
    if not uniqueId or not abilityName then return end
    local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
    local towerName = towerConfig and towerConfig:GetAttribute("TowerName")
    if not towerName then return end
    abilityName = tostring(abilityName)
    if AbilityByTower[towerName] == abilityName then return end
    AbilityByTower[towerName] = abilityName
    SaveAbilityMap()
    PushLog("记住技能: " .. tostring(towerName) .. " -> " .. abilityName)
end

LoadAbilityMap()

local function RoundTime(t)
    t = t or 0
    return math.floor(t * 100 + 0.5) / 100
end

function State:GetWave()
    local waveValue = GameConfig:FindFirstChild("Wave")
    if waveValue then
        return waveValue.Value
    end
    return 0
end

function State:GetClockOrigin()
    local matchStartedAt = workspace:GetAttribute("MatchStartedAt")
    if typeof(matchStartedAt) == "number" then
        return matchStartedAt
    end
    return self.fallbackClockOrigin
end

function State:GetClock()
    return math.max(workspace:GetServerTimeNow() - self:GetClockOrigin(), 0)
end

function State:IsMatchOver()
    local matchEndedAt = workspace:GetAttribute("MatchEndedAt")
    if typeof(matchEndedAt) == "number" and matchEndedAt ~= self.ignoredMatchEndedAt then
        return true
    end
    local baseHealth = GameConfig:FindFirstChild("BaseHealth")
    if baseHealth and baseHealth.Value <= 0 then
        return true
    end
    return false
end

function State:IsReadyVoting()
    return workspace:GetAttribute("ReadyVoting") == true
end

function State:RegisterTower(uniqueId)
    if typeof(uniqueId) ~= "string" then return end
    if self.towerIndex[uniqueId] then return end
    table.insert(self.placedTowerIds, uniqueId)
    self.towerIndex[uniqueId] = #self.placedTowerIds
end

function State:IndexOfTower(uniqueId)
    return self.towerIndex[uniqueId]
end

function State:ResolveTowerId(towerIndex)
    return self.placedTowerIds[towerIndex]
end

function State:ClearTowers()
    table.clear(self.placedTowerIds)
    table.clear(self.towerIndex)
end

function State:ResetMatchTracking()
    self:ClearTowers()
    self.ignoredMatchEndedAt = workspace:GetAttribute("MatchEndedAt")
end

function State:RefreshMatchOrigin()
    local matchStartedAt = workspace:GetAttribute("MatchStartedAt")
    local changed = false
    if typeof(matchStartedAt) == "number" and matchStartedAt ~= self.previousMatchStartedAt then
        self.previousMatchStartedAt = matchStartedAt
        self.ignoredMatchEndedAt = workspace:GetAttribute("MatchEndedAt")
        self.autoStartedThisMatch = false
        changed = true
    end
    return changed
end
local UnifiedMacroApi = {}
getgenv().UnifiedMacroApi = UnifiedMacroApi

function UnifiedMacroApi:Loadout(towerNames)
    self.loadout = towerNames
end

function UnifiedMacroApi:Map(mapName, difficultyName)
    self.mapName = mapName
    self.difficultyName = difficultyName
end

function UnifiedMacroApi:Start()
    State.running = true
    State:ResetMatchTracking()
    self.startTime = State:GetClock()
end

function UnifiedMacroApi:StopAll()
    State.running = false
    State.macroRunning = false
end

function UnifiedMacroApi:WaitForTime(targetTime, targetWave)
    local startWait = os.time()
    local hasTime = (targetTime or 0) > 0
    local hasWave = (targetWave or 0) > 0
    while State.running do
        if State:IsMatchOver() then return false end
        local clockOk = not hasTime or State:GetClock() >= targetTime
        local waveOk = not hasWave or State:GetWave() >= targetWave
        if clockOk and waveOk then return true end
        if hasTime and State:GetClock() >= targetTime + 10 then return true end
        if os.time() - startWait > 300 then
            PushLog(string.format("WaitForTime 超时: time=%s wave=%s", tostring(targetTime), tostring(targetWave)))
            return false
        end
        RunService.Heartbeat:Wait()
    end
    return false
end

function UnifiedMacroApi:WaitForMatchEnd()
    while State.running and not State:IsMatchOver() do
        RunService.Heartbeat:Wait()
    end
end

function UnifiedMacroApi:WaitForNextMatch()
    local deadline = os.time() + 1800
    local lastReadyAt = 0
    while State.running and os.time() < deadline do
        if State:GetWave() >= 1 and not State:IsMatchOver() then return true end
        if State:IsReadyVoting() and os.time() - lastReadyAt > 3 then
            lastReadyAt = os.time()
            pcall(function() RemoteEvents.ReadyUp:FireServer() end)
        end
        RunService.Heartbeat:Wait()
    end
    return false
end

function UnifiedMacroApi:WaitWave(wave, targetTime, targetWave)
    return self:WaitForTime(targetTime or 0, targetWave or wave)
end

function UnifiedMacroApi:ResolveId(towerOrId)
    if type(towerOrId) == "string" then
        return towerOrId
    end
    return State:ResolveTowerId(towerOrId)
end
function UnifiedMacroApi:Place(towerName, position, rotation, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return nil end

    local maxRetries = 3
    for attempt = 1, maxRetries do
        if not State.running then return nil end

        local requestId = HttpService:GenerateGUID(false)
        local requestTime = workspace:GetServerTimeNow()

        local success, result = pcall(function()
            return RemoteFunctions.RequestPlacement:InvokeServer(
                towerName, position, rotation or 0, requestId, requestTime
            )
        end)

        if success and typeof(result) == "string" then
            local valid = false
            local deadline = tick() + 1
            repeat
                if SharedTowerData:FindFirstChild(result) then valid = true break end
                RunService.Heartbeat:Wait()
            until tick() > deadline

            if not valid then
                task.wait(0.5)
                if SharedTowerData:FindFirstChild(result) then valid = true end
            end

            if valid then
                State:RegisterTower(result)
                if attempt > 1 then
                    PushLog("放置成功(重试" .. attempt .. "次): " .. tostring(towerName))
                end
                return result
            else
                PushLog("放置返回无效ID或同步超时: " .. tostring(result))
            end
        end

        if attempt == maxRetries then
            PushLog("放置彻底失败(已重试3次): " .. tostring(towerName) .. " (" .. tostring(result) .. ")")
        else
            local msg = tostring(result):lower()
            local waitTime = 1.5
            if msg:find("money") or msg:find("gold") or msg:find("insufficient") then
                waitTime = 3
            end
            PushLog("放置失败, 等待" .. waitTime .. "秒重试 (" .. attempt .. "/3): " .. tostring(towerName))
            task.wait(waitTime)
        end
    end

    return nil
end
function UnifiedMacroApi:Upgrade(towerOrId, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = self:ResolveId(towerOrId)
    if not uniqueId then
        PushLog("升级失败: 找不到塔 " .. tostring(towerOrId))
        return false
    end

    local maxRetries = 3
    for attempt = 1, maxRetries do
        if not State.running then return false end

        if not SharedTowerData:FindFirstChild(uniqueId) then
            PushLog("升级失败: 塔已不存在 " .. tostring(towerOrId))
            return false
        end

        local success, upgraded, failureMessage = pcall(function()
            return RemoteFunctions.RequestTowerUpgrade:InvokeServer(uniqueId)
        end)

        if success and upgraded then
            if attempt > 1 then
                PushLog("升级成功(重试" .. attempt .. "次): 塔 " .. tostring(towerOrId))
            end
            return true
        end

        if attempt == maxRetries then
            PushLog("升级彻底失败(已重试3次): 塔 " .. tostring(towerOrId) .. " (" .. tostring(failureMessage or upgraded) .. ")")
        else
            local msg = tostring(failureMessage or upgraded):lower()
            local waitTime = 1.5
            if msg:find("money") or msg:find("gold") or msg:find("insufficient") then
                waitTime = 3
            end
            PushLog("升级失败, 等待" .. waitTime .. "秒重试 (" .. attempt .. "/3): 塔 " .. tostring(towerOrId))
            task.wait(waitTime)
        end
    end
    return false
end

function UnifiedMacroApi:Sell(towerOrId, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = self:ResolveId(towerOrId)
    if not uniqueId then
        PushLog("出售失败: 找不到塔 " .. tostring(towerOrId))
        return false
    end
    if not SharedTowerData:FindFirstChild(uniqueId) then
        PushLog("出售失败: 塔已不存在 " .. tostring(towerOrId))
        return false
    end
    local success, failureMessage = pcall(function()
        return RemoteFunctions.RequestTowerSell:InvokeServer(uniqueId)
    end)
    if success and (failureMessage == nil or failureMessage == true) then return true end
    PushLog("出售失败: " .. tostring(failureMessage))
    return false
end
function UnifiedMacroApi:SetTarget(towerOrId, targetMode, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = self:ResolveId(towerOrId)
    if not uniqueId then
        PushLog("切换优先级失败: 找不到塔 " .. tostring(towerOrId))
        return false
    end
    local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
    if not towerConfig then
        PushLog("切换优先级失败: 塔已不存在 " .. tostring(towerOrId))
        return false
    end
    if towerConfig:GetAttribute("Targetting") == targetMode then return true end

    for _ = 1, 12 do
        pcall(function() RemoteFunctions.RequestTargettingChange:InvokeServer(uniqueId) end)
        local deadline = tick() + 0.25
        repeat
            RunService.Heartbeat:Wait()
        until towerConfig:GetAttribute("Targetting") == targetMode or tick() > deadline

        if towerConfig:GetAttribute("Targetting") == targetMode then return true end
    end
    PushLog("切换优先级失败: " .. tostring(targetMode))
    return false
end

function UnifiedMacroApi:Skill(towerOrId, abilityName, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = self:ResolveId(towerOrId)
    if not uniqueId then
        PushLog("技能失败: 找不到塔 " .. tostring(towerOrId))
        return false
    end
    if not abilityName or abilityName == "" then
        PushLog("技能失败: 缺少技能名")
        return false
    end
    if not RequestTowerAbility then
        PushLog("技能失败: 找不到 RequestTowerAbility")
        return false
    end
    local ok, result = pcall(function() return RequestTowerAbility:InvokeServer(uniqueId, abilityName) end)
    if ok then
        LearnAbility(uniqueId, abilityName)
        return true
    end
    PushLog("技能失败: " .. tostring(result))
    return false
end

function UnifiedMacroApi:Ready(targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    return pcall(function() RemoteEvents.ReadyUp:FireServer() end)
end

function UnifiedMacroApi:Skip(targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    State.autoSkipVote = true
    return true
end

function UnifiedMacroApi:Speed(speedValue, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    return pcall(function() RemoteEvents.SpeedToggle:FireServer(speedValue) end)
end

function UnifiedMacroApi:Vote(difficultyName, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    return pcall(function() RemoteEvents.CastDifficultyVote:FireServer(difficultyName) end)
end

function UnifiedMacroApi:Rejoin()
    pcall(function() RemoteEvents.ResultsAction:FireServer("Rejoin") end)
end

function UnifiedMacroApi:Loop(body)
    State.macroRunning = true
    while State.running do
        self:Start()
        local success, runtimeError = pcall(body)
        if not success then PushLog("宏执行出错: " .. tostring(runtimeError)) end
        if not State.loopEnabled then break end
        self:WaitForMatchEnd()
        if not State.running then break end
        task.wait(2)
        if not self:WaitForNextMatch() then break end
        task.wait(1)
    end
    State.macroRunning = false
end
     Recorder = {
    recording = false,
    macroName = "未命名",
    actions = {},
    towerNames = {},
    nameCounters = {},
    idToName = {},
    lastRecordedWave = 0,
    mapName = nil,
    difficultyName = nil,
}

function Recorder:GetCustomName(uniqueId, towerName)
    if self.idToName[uniqueId] then
        return self.idToName[uniqueId]
    end

    self.nameCounters[towerName] = (self.nameCounters[towerName] or 0) + 1
    local customName = string.format("%s_%d", towerName, self.nameCounters[towerName])
    self.idToName[uniqueId] = customName
    return customName
end

function Recorder:RecordPlacement(uniqueId, towerName, towerCFrame, towerLevel, targetTime)
    if not towerName or typeof(towerCFrame) ~= "CFrame" then return false end
    local customName = self:GetCustomName(uniqueId, towerName)
    local position = towerCFrame.Position
    local _, yaw, _ = towerCFrame:ToOrientation()
    local quarterTurn = math.round(math.deg(yaw) / 90) * 90
    quarterTurn = quarterTurn % 360
    if quarterTurn > 180 then quarterTurn = quarterTurn - 360 end

    table.insert(self.actions, {
        action = "Place", name = customName, towerName = towerName,
        pos = { x = position.X, y = position.Y, z = position.Z },
        rot = quarterTurn, rotRaw = math.deg(yaw),
        level = towerLevel or 1,
        time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave()
    })

    if not table.find(self.towerNames, towerName) then
        table.insert(self.towerNames, towerName)
    end
    return true
end

function Recorder:RecordUpgrade(uniqueId, targetTime)
    local customName = self.idToName[uniqueId]
    if not customName then PushLog("录制升级丢失: 未找到别名 " .. tostring(uniqueId)); return false end
    table.insert(self.actions, { action = "Upgrade", target = customName, time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave() })
    return true
end

function Recorder:RecordSell(uniqueId, targetTime)
    local customName = self.idToName[uniqueId]
    if not customName then return false end
    table.insert(self.actions, { action = "Sell", target = customName, time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave() })
    return true
end

function Recorder:RecordTargetting(uniqueId, targetMode, targetTime)
    local customName = self.idToName[uniqueId]
    if not customName or not targetMode then PushLog("录制切目标丢失: " .. tostring(uniqueId) .. " / " .. tostring(targetMode)); return false end
    table.insert(self.actions, { action = "SetTarget", target = customName, targetMode = tostring(targetMode), time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave() })
    return true
end
function Recorder:RecordSkill(uniqueId, abilityName, targetTime)
    if not uniqueId or not abilityName then return false end
    LearnAbility(uniqueId, abilityName)
    local customName = self.idToName[uniqueId]
    if not customName then
        local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
        local towerName = towerConfig and towerConfig:GetAttribute("TowerName")
        PushLog("技能未录制: 塔 " .. tostring(towerName or uniqueId) .. " 不是本次录制放置的")
        return false
    end
    table.insert(self.actions, {
        action = "Skill", target = customName, ability = tostring(abilityName),
        time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave(),
    })
    PushLog("录制技能: " .. customName .. " / " .. tostring(abilityName))
    return true
end

function Recorder:RecordReady(targetTime)
    table.insert(self.actions, { action = "Ready", time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave() })
end

function Recorder:RecordSpeed(speedValue, targetTime)
    table.insert(self.actions, { action = "Speed", speedValue = speedValue, time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave() })
end

function Recorder:RecordVote(difficultyName, targetTime)
    table.insert(self.actions, { action = "Vote", difficultyName = tostring(difficultyName), time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave() })
end

function Recorder:RecordWave(wave, targetTime)
    if not wave or wave < 1 then return end
    table.insert(self.actions, { action = "WaitWave", wave = wave, time = RoundTime(targetTime or State:GetClock()) })
end

function Recorder:SanitizeName(macroName) return (tostring(macroName):gsub("[\\/:*?\"<>|]", "_")) end

-- ===== 技能捕获：抓 RequestTowerAbility:InvokeServer(塔uuid, 技能名) =====
-- 常驻开启：手动按一次技能就会记住，不需要先开「自动使用技能」
local previousCapture = getgenv().TwdSkillCaptureHook
if previousCapture then
    pcall(function()
        setreadonly(previousCapture.mt, false)
        previousCapture.mt.__namecall = previousCapture.old
        setreadonly(previousCapture.mt, true)
    end)
    getgenv().TwdSkillCaptureHook = nil
end

local SkillCapture = { active = false }

function SkillCapture:Start()
    if self.active then return end
    if not getrawmetatable or not setreadonly then return end
    local ok, err = pcall(function()
        local mt = getrawmetatable(game)
        if not mt then error("无 metatable") end
        local old = mt.__namecall
        if not old then error("无 __namecall") end
        local function handler(selfObj, ...)
            if getnamecallmethod() == "InvokeServer" then
                local okName, name = pcall(function() return selfObj.Name end)
                if okName and name == "RequestTowerAbility" and not State.macroRunning then
                    local args = { ... }
                    pcall(function()
                        local isOurs = false
                        if checkcaller then isOurs = checkcaller() end
                        if isOurs then return end
                        if Recorder.recording then
                            Recorder:RecordSkill(args[1], args[2])
                        else
                            LearnAbility(args[1], args[2])
                        end
                    end)
                end
            end
            return old(selfObj, ...)
        end
        setreadonly(mt, false)
        if newcclosure then
            mt.__namecall = newcclosure(handler)
        else
            mt.__namecall = handler
        end
        setreadonly(mt, true)
        self.mt = mt
        self.oldNamecall = old
        getgenv().TwdSkillCaptureHook = { mt = mt, old = old }
    end)
    self.active = ok and true or false
    if not self.active then PushLog("技能捕获未启用: " .. tostring(err)) end
end

function SkillCapture:Stop()
    if not self.active or not self.mt then
        self.active = false
        return
    end
    pcall(function()
        setreadonly(self.mt, false)
        self.mt.__namecall = self.oldNamecall
        setreadonly(self.mt, true)
    end)
    self.active = false
    self.mt = nil
    self.oldNamecall = nil
    getgenv().TwdSkillCaptureHook = nil
end

local function RefreshSkillCapture()
    SkillCapture:Start()
end

RefreshSkillCapture()

function Recorder:Start(macroName)
    if State.macroRunning then PushLog("回放进行中，请先停止回放再开始录制"); return false end
    self.macroName = self:SanitizeName(macroName)
    self.actions = {}; self.towerNames = {}; self.nameCounters = {}; self.idToName = {}
    self.recording = true; self.lastRecordedWave = 0
    self.mapName = tostring(workspace:GetAttribute("Map") or "未知")
    self.difficultyName = tostring(workspace:GetAttribute("Difficulty") or "未知")

    State:ClearTowers()
    if TowerTracker then TowerTracker:Reset() end

    local initSpeed = tonumber(workspace:GetAttribute("GameSpeed")) or 1
    self:RecordSpeed(initSpeed)
    if TowerTracker then TowerTracker.gameSpeed = initSpeed end
    PushLog("开始录制: " .. self.macroName)
    RefreshSkillCapture()
    return true
end

function Recorder:Stop()
    if not self.recording then return nil end
    self.recording = false
    RefreshSkillCapture()
    local currentWave = State:GetWave()
    if currentWave > (self.lastRecordedWave or 0) then
        self:RecordWave(currentWave)
    end

    local saveData = { map = self.mapName or "未知", difficulty = self.difficultyName or "未知", loadout = self.towerNames, actions = self.actions }
    local path = MacroFolder .. "/" .. self.macroName .. ".json"
    local success, jsonString = pcall(function() return HttpService:JSONEncode(saveData) end)
    if not success then PushLog("JSON生成失败: " .. tostring(jsonString)); return nil end

    local writeSuccess, writeError = pcall(function() writefile(path, jsonString) end)
    if not writeSuccess then PushLog("保存失败: " .. tostring(writeError)); return nil end
    PushLog("录制完成(JSON): " .. path .. " (" .. #self.actions .. " 条动作)")
    return path
end

local ConfigFileNames = {
    ["twd_config.json"] = true,
    ["twd_autovote_config.json"] = true,
    ["twd_aux_config.json"] = true,
    ["twd_ability_map.json"] = true,
}

local function ListMacroFiles()
    local macroFiles = {}
    local success, files = pcall(function() return listfiles(MacroFolder) end)
    if not success or not files then return macroFiles end
    for _, path in ipairs(files) do
        if path:sub(-4) == ".txt" or path:sub(-5) == ".json" then
            local fileName = path:match("([^\\/]+)$") or path
            if not ConfigFileNames[fileName:lower()] then
                table.insert(macroFiles, fileName)
            end
        end
    end
    table.sort(macroFiles)
    return macroFiles
end

TowerTracker = { knownTowers = {}, readyVotes = nil, gameSpeed = nil, difficulty = nil, failedPlacementLog = {} }

function TowerTracker:BuildSnapshot()
    local snapshot = {}
    for _, towerConfig in ipairs(SharedTowerData:GetChildren()) do
        if towerConfig:GetAttribute("Owner") == LocalPlayer.Name then
            snapshot[towerConfig.Name] = {
                towerName = towerConfig:GetAttribute("TowerName"),
                level = towerConfig:GetAttribute("Level") or 0,
                targetting = towerConfig:GetAttribute("Targetting"),
                cframe = towerConfig:GetAttribute("CFrame"),
            }
        end
    end
    return snapshot
end

function TowerTracker:IsRecordingActive() return Recorder.recording and not State.macroRunning end

function TowerTracker:ScanTowers()
    local snapshot = self:BuildSnapshot()
    local previousSnapshot = self.knownTowers
    self.knownTowers = {}
    local matchActive = not State:IsMatchOver()
    local now = math.max(0, State:GetClock() - SCAN_HALF)

    for uniqueId, tower in pairs(snapshot) do
        local previousTower = previousSnapshot[uniqueId]
        if not previousTower then
            State:RegisterTower(uniqueId)
            if self:IsRecordingActive() then
                local success = Recorder:RecordPlacement(uniqueId, tower.towerName, tower.cframe, tower.level, now)
                if success then
                    self.failedPlacementLog[uniqueId] = nil
                    local currentLevel = math.max(tower.level or 0, 1)
                    local step = 0
                    for lvl = 2, currentLevel do Recorder:RecordUpgrade(uniqueId, now + step * 0.1); step = step + 1 end
                    if tower.targetting then Recorder:RecordTargetting(uniqueId, tower.targetting, now + step * 0.1) end
                    self.knownTowers[uniqueId] = tower
                else
                    local lastLog = self.failedPlacementLog[uniqueId]
                    if not lastLog or now - lastLog > 2 then self.failedPlacementLog[uniqueId] = now; PushLog("塔放置数据未就绪，下一轮重试...") end
                end
            else
                self.knownTowers[uniqueId] = tower
            end
        else
            if tower.level > previousTower.level then
                local step = 0
                for _ = previousTower.level + 1, tower.level do
                    if self:IsRecordingActive() then Recorder:RecordUpgrade(uniqueId, now + step * 0.1) end
                    step = step + 1
                end
            end
            if tower.targetting and tower.targetting ~= previousTower.targetting then
                if self:IsRecordingActive() then Recorder:RecordTargetting(uniqueId, tower.targetting, now) end
            end
            self.knownTowers[uniqueId] = tower
        end
    end

    for uniqueId, oldTower in pairs(previousSnapshot) do
        if not snapshot[uniqueId] then
            if matchActive and self:IsRecordingActive() then Recorder:RecordSell(uniqueId, now) end
        end
    end
end
function TowerTracker:ScanEnvironment()
    local now = math.max(0, State:GetClock() - SCAN_HALF)
    local currentWave = State:GetWave()
    if currentWave > (Recorder.lastRecordedWave or 0) then
        if self:IsRecordingActive() then
            for w = (Recorder.lastRecordedWave or 0) + 1, currentWave do Recorder:RecordWave(w, now) end
        end
        Recorder.lastRecordedWave = currentWave
    end

    local readyVotes = tonumber(workspace:GetAttribute("ReadyVotes")) or 0
    if self.readyVotes == nil then self.readyVotes = readyVotes
    elseif readyVotes ~= self.readyVotes then
        if readyVotes > self.readyVotes and State:IsReadyVoting() and self:IsRecordingActive() then Recorder:RecordReady(now) end
        self.readyVotes = readyVotes
    end

    local gameSpeed = tonumber(workspace:GetAttribute("GameSpeed")) or 1
    if self.gameSpeed == nil then self.gameSpeed = gameSpeed
    elseif gameSpeed ~= self.gameSpeed then
        if self:IsRecordingActive() then Recorder:RecordSpeed(gameSpeed, now) end
        self.gameSpeed = gameSpeed
    end

    local difficulty = workspace:GetAttribute("Difficulty")
    if self.difficulty == nil then self.difficulty = difficulty
    elseif difficulty ~= self.difficulty then
        if self:IsRecordingActive() and typeof(difficulty) == "string" then Recorder:RecordVote(difficulty, now) end
        self.difficulty = difficulty
    end
end

function TowerTracker:Reset()
    self.knownTowers = {}; self.readyVotes = nil; self.gameSpeed = nil; self.difficulty = nil; self.failedPlacementLog = {}
    if Recorder then Recorder.lastRecordedWave = 0 end
end

local function LoadConfig()
    local success, content = pcall(readfile, ConfigFile)
    if success and content then
        local decodeSuccess, data = pcall(HttpService.JSONDecode, HttpService, content)
        if decodeSuccess and data then return data end
    end
    return {}
end

local function SaveConfig()
    local data = { selectedMacroName = State.selectedMacroName, loopEnabled = State.loopEnabled, autoSkipVote = State.autoSkipVote, autoRejoinEnabled = State.autoRejoinEnabled, recordName = State.recordName }
    local success, jsonStr = pcall(HttpService.JSONEncode, HttpService, data)
    if success then pcall(writefile, ConfigFile, jsonStr) end
end

local SavedConfig = LoadConfig()
if SavedConfig.loopEnabled ~= nil then State.loopEnabled = SavedConfig.loopEnabled end
if SavedConfig.autoSkipVote ~= nil then State.autoSkipVote = SavedConfig.autoSkipVote end
if SavedConfig.autoRejoinEnabled ~= nil then State.autoRejoinEnabled = SavedConfig.autoRejoinEnabled end
if SavedConfig.recordName then State.recordName = SavedConfig.recordName end
if SavedConfig.selectedMacroName then State.selectedMacroName = SavedConfig.selectedMacroName end
local hiddenGui = gethui and gethui() or game:GetService("CoreGui")
local existingMenu = hiddenGui:FindFirstChild("Rayfield")
if existingMenu then existingMenu:Destroy() end

local rayfieldSource
local rayfieldOk = pcall(function() rayfieldSource = game:HttpGet("https://sirius.menu/rayfield") end)
if not rayfieldOk or not rayfieldSource then error("Rayfield 加载失败，请检查网络或执行器 HttpGet 权限") end

local Rayfield = loadstring(rayfieldSource)()
local Window = Rayfield:CreateWindow({
    Name = "vvss88", LoadingTitle = "vvss88", LoadingSubtitle = "录制与回放",
    ConfigurationSaving = { Enabled = false }, KeySystem = false,
})

local PlayTab = Window:CreateTab("宏播放", nil)
local RecordTab = Window:CreateTab("录制", nil)
local LogTab = Window:CreateTab("日志", nil)

local statusLabel = PlayTab:CreateLabel("状态: 初始化中")
PlayTab:CreateSection("宏文件")

local macroDropdown
macroDropdown = PlayTab:CreateDropdown({
    Name = "选择宏", Options = { "暂无宏文件" }, CurrentOption = { State.selectedMacroName or "暂无宏文件" }, MultipleOptions = false,
    Callback = function(option)
        local selection = option
        if type(option) == "table" then selection = option[1] end
        State.selectedMacroName = selection
        PushLog("已选择宏: " .. tostring(selection))
        SaveConfig()
    end,
})

local function RefreshMacroList()
    local macroFiles = ListMacroFiles()
    if #macroFiles == 0 then macroFiles = { "暂无宏文件" } end
    macroDropdown:Refresh(macroFiles)

    if State.selectedMacroName and table.find(macroFiles, State.selectedMacroName) then
        macroDropdown:Set({ State.selectedMacroName })
    elseif #macroFiles > 0 then
        State.selectedMacroName = macroFiles[1]
        macroDropdown:Set({ macroFiles[1] })
    end
end

PlayTab:CreateButton({ Name = "刷新宏列表", Callback = function() RefreshMacroList(); PushLog("宏列表已刷新") end })
PlayTab:CreateSection("播放控制")

local function StartMacroPlayback()
    if State.manualStartInProgress then return end
    State.manualStartInProgress = true
    task.delay(1, function() State.manualStartInProgress = false end)
    State.autoStartedThisMatch = true

    if Recorder.recording then
        local savedPath = Recorder:Stop()
        if savedPath then
            PushLog("播放前已自动停止录制并保存: " .. savedPath)
            RefreshMacroList()
            local fileName = savedPath:match("([^\\/]+)$")
            if fileName then State.selectedMacroName = fileName; macroDropdown:Set({ fileName }); SaveConfig() end
        end
        task.wait(0.3)
    end

    if not State.selectedMacroName or State.selectedMacroName == "暂无宏文件" then PushLog("未选择宏文件"); return end
    local path = MacroFolder .. "/" .. State.selectedMacroName
    local readSuccess, source = pcall(function() return readfile(path) end)
    if not readSuccess or not source then PushLog("读取失败: " .. tostring(source)); return end
    if State.macroRunning then UnifiedMacroApi:StopAll(); task.wait(0.5) end
    State.running = true
    if not State:IsMatchOver() and State:GetWave() >= 1 and not State:IsReadyVoting() then PushLog("警告: 当前对局已开始，回放时间点可能已过期") end
        if State.selectedMacroName:sub(-5) == ".json" then
        local decodeSuccess, data = pcall(function() return HttpService:JSONDecode(source) end)
        if not decodeSuccess or not data then PushLog("解析 JSON 失败"); return end

        task.spawn(function()
            local api = getgenv().UnifiedMacroApi
            State.macroRunning = true
            if data.loadout and #data.loadout > 0 then PushLog("宏 loadout: " .. table.concat(data.loadout, ", ")) end
            if data.map then PushLog("宏地图: " .. tostring(data.map) .. " / " .. tostring(data.difficulty or "?")) end

            while State.running do
                api:Loadout(data.loadout or {})
                api:Map(data.map or "未知", data.difficulty or "未知")
                api:Start()

                local playbackMap = {}
                local failedTargets = {}

                for _, act in ipairs(data.actions or {}) do
                    if not State.running then break end
                    if act.action == "Place" then
                        local pos = Vector3.new(act.pos.x, act.pos.y, act.pos.z)
                        local uid = api:Place(act.towerName, pos, act.rot, act.time, act.wave)
                        if uid then
                            playbackMap[act.name] = uid
                            if act.level and act.level > 1 then
                                local t = SharedTowerData:FindFirstChild(uid)
                                if t and tonumber(t:GetAttribute("Level")) ~= act.level then
                                    PushLog(string.format("警告: %s 初始等级 %s != 录制 %s", act.name, tostring(t:GetAttribute("Level")), tostring(act.level)))
                                end
                            end
                        else
                            failedTargets[act.name] = true
                        end
                    elseif act.action == "Upgrade" then
                        local uid = playbackMap[act.target]
                        if uid then api:Upgrade(uid, act.time, act.wave) elseif failedTargets[act.target] then PushLog("跳过升级: 前置放置失败 " .. tostring(act.target)) end
                    elseif act.action == "Sell" then
                        local uid = playbackMap[act.target]
                        if uid then api:Sell(uid, act.time, act.wave) elseif failedTargets[act.target] then PushLog("跳过出售: 前置放置失败 " .. tostring(act.target)) end
                    elseif act.action == "SetTarget" then
                        local uid = playbackMap[act.target]
                        if uid then api:SetTarget(uid, act.targetMode, act.time, act.wave) elseif failedTargets[act.target] then PushLog("跳过切换优先级: 前置放置失败 " .. tostring(act.target)) end
                    elseif act.action == "Skill" then
                        local uid = playbackMap[act.target]
                        if uid then api:Skill(uid, act.ability, act.time, act.wave) elseif failedTargets[act.target] then PushLog("跳过技能: 前置放置失败 " .. tostring(act.target)) end
                    elseif act.action == "WaitWave" then api:WaitWave(act.wave, 0, act.wave)
                    elseif act.action == "Ready" then api:Ready(act.time, act.wave)
                    elseif act.action == "Speed" then api:Speed(act.speedValue, act.time, act.wave)
                    elseif act.action == "Vote" then api:Vote(act.difficultyName, act.time, act.wave) end
                end

                if not State.loopEnabled then break end
                api:WaitForMatchEnd()
                if not State.running then break end
                task.wait(2)
                if not api:WaitForNextMatch() then break end
                task.wait(1)
            end
            State.macroRunning = false
        end)
        PushLog("开始播放 (JSON): " .. State.selectedMacroName)
    else
        local chunk, compileError = loadstring(source)
        if not chunk then PushLog("编译失败: " .. tostring(compileError)); return end
        task.spawn(function() local success, runtimeError = pcall(chunk); if not success then PushLog("运行出错: " .. tostring(runtimeError)) end end)
        PushLog("开始播放 (TXT): " .. State.selectedMacroName)
    end
end

PlayTab:CreateButton({ Name = "播放选中的宏", Callback = StartMacroPlayback })
PlayTab:CreateButton({ Name = "停止播放", Callback = function() State.running = false; State.macroRunning = false; PushLog("已请求停止播放") end })

PlayTab:CreateToggle({ Name = "循环执行", CurrentValue = State.loopEnabled, Flag = "LoopEnabled", Callback = function(value) State.loopEnabled = value; PushLog("循环执行: " .. (value and "开" or "关")); SaveConfig() end })
PlayTab:CreateToggle({ Name = "自动同意跳波投票", CurrentValue = State.autoSkipVote, Flag = "AutoSkipVote", Callback = function(value) State.autoSkipVote = value; PushLog("自动同意跳波: " .. (value and "开" or "关")); SaveConfig() end })
PlayTab:CreateToggle({ Name = "自动重连 (防卡结算)", CurrentValue = State.autoRejoinEnabled, Flag = "AutoRejoinEnabled", Callback = function(value) State.autoRejoinEnabled = value; PushLog("自动重连: " .. (value and "开" or "关")); SaveConfig() end })

do
    local VoteConfig = { enabled = false, targetDifficulty = "Nightmare", validModes = { "Easy", "Medium", "Hard", "Nightmare" } }
    local VoteConfigFile = MacroFolder .. "/twd_autovote_config.json"

    local function isValidMode(mode) for _, m in ipairs(VoteConfig.validModes) do if m == mode then return true end end return false end
    local function LoadVoteConfig()
        local ok, content = pcall(readfile, VoteConfigFile)
        if not ok or not content then return end
        local decodeOk, data = pcall(function() return HttpService:JSONDecode(content) end)
        if not decodeOk or type(data) ~= "table" then return end
        if type(data.enabled) == "boolean" then VoteConfig.enabled = data.enabled end
        if type(data.targetDifficulty) == "string" and isValidMode(data.targetDifficulty) then VoteConfig.targetDifficulty = data.targetDifficulty end
    end

    local function SaveVoteConfig()
        local data = { enabled = VoteConfig.enabled, targetDifficulty = VoteConfig.targetDifficulty }
        local ok, json = pcall(function() return HttpService:JSONEncode(data) end)
        if ok then pcall(writefile, VoteConfigFile, json) end
    end
    LoadVoteConfig()

    local VoteRemote = RemoteEvents:WaitForChild("CastDifficultyVote")
    local ReadyRemote = RemoteEvents:WaitForChild("ReadyUp")
    local function voteOnce() if not isValidMode(VoteConfig.targetDifficulty) then return end; pcall(function() VoteRemote:FireServer(VoteConfig.targetDifficulty) end) end
    local function readyUp() pcall(function() ReadyRemote:FireServer() end) end
    local isRunning = false

    local function RunAutoVoteOnce()
        if isRunning then return end
        isRunning = true
        task.spawn(function()
            if not VoteConfig.enabled then isRunning = false; return end
            task.wait(5); if not VoteConfig.enabled then isRunning = false; return end
            voteOnce(); task.wait(1); if not VoteConfig.enabled then isRunning = false; return end
            voteOnce(); task.wait(15); if not VoteConfig.enabled then isRunning = false; return end
            readyUp(); isRunning = false
        end)
    end

    PlayTab:CreateSection("自动投票")
    PlayTab:CreateDropdown({ Name = "目标难度", Options = VoteConfig.validModes, CurrentOption = { VoteConfig.targetDifficulty }, MultipleOptions = false, Callback = function(option) local sel = option; if type(option) == "table" then sel = option[1] end; VoteConfig.targetDifficulty = sel; SaveVoteConfig() end })
    PlayTab:CreateToggle({ Name = "自动投票 (单次)", CurrentValue = VoteConfig.enabled, Callback = function(value) VoteConfig.enabled = value; SaveVoteConfig(); if value then RunAutoVoteOnce() end end })
    if VoteConfig.enabled then RunAutoVoteOnce() end
end
RecordTab:CreateSection("录制设置")
local recordNameLabel = RecordTab:CreateLabel("当前宏名称: " .. State.recordName)
local recordStatusLabel = RecordTab:CreateLabel("录制状态: 未开始")
RecordTab:CreateInput({ Name = "宏名称", CurrentValue = State.recordName, PlaceholderText = "输入宏名称后回车", RemoveTextAfterFocusLost = false, Callback = function(text) if text and text ~= "" then State.recordName = text; recordNameLabel:Set("当前宏名称: " .. text); SaveConfig() end end })
RecordTab:CreateButton({ Name = "开始录制", Callback = function() if Recorder:Start(State.recordName or "未命名") then recordStatusLabel:Set("录制状态: 录制中 (" .. Recorder.macroName .. ")") else recordStatusLabel:Set("录制状态: 启动失败") end end })
RecordTab:CreateButton({ Name = "停止录制并保存", Callback = function() local savedPath = Recorder:Stop(); if savedPath then recordStatusLabel:Set("录制状态: 已保存 " .. savedPath); RefreshMacroList(); local fileName = savedPath:match("([^\\/]+)$"); if fileName then State.selectedMacroName = fileName; macroDropdown:Set({ fileName }); SaveConfig() end else recordStatusLabel:Set("录制状态: 保存失败或未在录制") end end })

LogTab:CreateSection("日志")
LogParagraph = LogTab:CreateParagraph({ Title = "最近日志", Content = #logHistory > 0 and table.concat(logHistory, "\n") or "暂无日志" })
RefreshMacroList()

local skipVoteHandled = false
local function AutoAgreeSkipVote()
    if not State.autoSkipVote then return end
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui"); if not playerGui then return end
    local coreGui = playerGui:FindFirstChild("CoreGui"); if not coreGui then return end
    local skipFrame = coreGui:FindFirstChild("SkipWaveFrame"); if not skipFrame or not skipFrame.Visible then skipVoteHandled = false; return end
    if skipVoteHandled then return end
    local agreeButton = skipFrame:FindFirstChild("Agree"); if not agreeButton or not agreeButton.Visible then return end
    skipVoteHandled = true
    if getconnections then
        local connections = getconnections(agreeButton.Activated)
        if connections and #connections > 0 then
            for _, connection in ipairs(connections) do pcall(function() connection.Function() end) end
            return
        end
    end
    if firesignal then pcall(firesignal, agreeButton.Activated) end
end

local RejoinConfig = { delayBeforeRejoin = 5, cooldown = 15, maxRetries = 3, retryDelay = 8, pollInterval = 0.5 }
local lastTriggerTime = 0
local isRejoining = false
local scriptStartTime = tick()

local function doRejoin()
    if isRejoining then return end
    if os.time() - lastTriggerTime < RejoinConfig.cooldown then return end
    isRejoining = true; lastTriggerTime = os.time()
    task.wait(RejoinConfig.delayBeforeRejoin)
    for attempt = 1, RejoinConfig.maxRetries do
        pcall(function() RemoteEvents.ResultsAction:FireServer("Shown") end)
        task.wait(0.2)
        pcall(function() RemoteEvents.ResultsAction:FireServer("Rejoin") end)
        task.wait(RejoinConfig.retryDelay)
    end
    isRejoining = false
end

task.spawn(function()
    local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
    local LoadingGui = PlayerGui:WaitForChild("Loading", 10)
    if not LoadingGui then return end
    while true do
        task.wait(RejoinConfig.pollInterval)
        if tick() - scriptStartTime < 30 then continue end
        if State.autoRejoinEnabled and not isRejoining then
            local endSeq = LoadingGui:FindFirstChild("EndSequence")
            local endSeqContent = LoadingGui:FindFirstChild("EndSequenceContent")
            if (endSeq and endSeq.Visible) or (endSeqContent and endSeqContent.Visible) then doRejoin() end
        end
    end
end)

local monitorAccumulator = 0
getgenv().UnifiedMacroHeartbeat = RunService.Heartbeat:Connect(function(deltaTime)
    monitorAccumulator = monitorAccumulator + deltaTime
    if monitorAccumulator < SCAN_INTERVAL then return end
    monitorAccumulator = 0
    pcall(function()
        if State:RefreshMatchOrigin() then
            if Recorder.recording then
                local savedPath = Recorder:Stop()
                if savedPath then
                    recordStatusLabel:Set("录制状态: 已自动保存 " .. savedPath)
                    RefreshMacroList()
                    local fileName = savedPath:match("([^\\/]+)$")
                    if fileName then State.selectedMacroName = fileName; macroDropdown:Set({ fileName }); SaveConfig() end
                else
                    recordStatusLabel:Set("录制状态: 自动保存失败")
                end
                PushLog("检测到新局，已自动停止录制并保存，请重新开始录制")
            end
            TowerTracker:Reset(); State:ClearTowers()
        end
        TowerTracker:ScanEnvironment(); TowerTracker:ScanTowers(); AutoAgreeSkipVote()

        if State:GetWave() >= 1 and not State.macroRunning and not State.autoStartedThisMatch and not State.manualStartInProgress and State.loopEnabled and State.selectedMacroName and State.selectedMacroName ~= "暂无宏文件" then
            State.autoStartedThisMatch = true
            task.spawn(function() task.wait(1); if State:GetWave() >= 1 and not State.macroRunning then StartMacroPlayback() end end)
        end

        local phaseText = "大厅"
        if State:IsMatchOver() then phaseText = "结算中"
        elseif State:GetWave() >= 1 then phaseText = "战斗中"
        elseif State:IsReadyVoting() then phaseText = "准备阶段" end
        local totalWaveCount = tonumber(workspace:GetAttribute("WaveCount")) or 0

        statusLabel:Set(string.format("状态: %s | 波次: %d/%d | 计时: %ds | 塔: %d | 录制: %s | 播放: %s", phaseText, State:GetWave(), totalWaveCount, math.floor(State:GetClock()), #State.placedTowerIds, Recorder.recording and "开" or "关", State.macroRunning and "运行中" or "空闲"))
    end)
end)

PushLog("脚本已加载，共检测到 " .. #ListMacroFiles() .. " 个宏文件（录制时临时挂钩 RequestTowerAbility 以捕获技能）")


-- ==========================================
-- 附加功能：反反宏 / 自动拾取（都带开关，逻辑取自原脚本）
-- ==========================================
local AuxTab = Window:CreateTab("辅助功能", nil)

local Aux = { antiAntiMacro = true, autoPickup = false, autoAbility = false, abilityInterval = 2 }  -- 默认开启：执行即生效，不用再手动点开关
getgenv().TwdAuxState = Aux

local AuxConfigFile = MacroFolder .. "/twd_aux_config.json"

local function LoadAuxConfig()
    local ok, content = pcall(readfile, AuxConfigFile)
    if not ok or not content then return end
    local decodeOk, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not decodeOk or type(data) ~= "table" then return end
    if type(data.antiAntiMacro) == "boolean" then Aux.antiAntiMacro = data.antiAntiMacro end
    if type(data.autoPickup) == "boolean" then Aux.autoPickup = data.autoPickup end
    if type(data.autoAbility) == "boolean" then Aux.autoAbility = data.autoAbility end
    if tonumber(data.abilityInterval) then Aux.abilityInterval = math.clamp(tonumber(data.abilityInterval), 1, 15) end
end

local function SaveAuxConfig()
    local data = { antiAntiMacro = Aux.antiAntiMacro, autoPickup = Aux.autoPickup, autoAbility = Aux.autoAbility, abilityInterval = Aux.abilityInterval }
    local ok, json = pcall(function() return HttpService:JSONEncode(data) end)
    if ok then pcall(writefile, AuxConfigFile, json) end
end

LoadAuxConfig()

-- ==========================================
-- 1. 反反宏轮询版（修复点击报错版）
-- ==========================================
AuxTab:CreateSection("反反宏")

local antiStatusLabel = AuxTab:CreateLabel("反反宏: " .. (Aux.antiAntiMacro and "开启" or "关闭"))

-- 修复版点击函数：只用执行器底层方法，并且区分「真的触发成功」和「pcall 把报错吞了」
local function ClickButton(btn)
    if not btn then return false end

    -- 方案1：getconnections 直接调用连接回调（.Function 最通用，Synapse/Fluxus/Solara 都吃）
    if getconnections then
        local ok, conns = pcall(getconnections, btn.Activated)
        if ok and conns and #conns > 0 then
            local fired = 0
            for _, c in ipairs(conns) do
                local ok2 = pcall(function() c.Function() end)
                if not ok2 and c.Fire then
                    ok2 = pcall(function() c:Fire() end)
                end
                if ok2 then fired = fired + 1 end
            end
            if fired > 0 then return true end
        end
    end

    -- 方案2：使用 firesignal
    if firesignal then
        local ok = pcall(firesignal, btn.Activated)
        if ok then return true end
    end

    -- 方案3：如果都不行，尝试点击 MouseButton1Click
    if firesignal then
        local ok = pcall(firesignal, btn.MouseButton1Click)
        if ok then return true end
    end

    return false
end

AuxTab:CreateToggle({
    Name = "启用反反宏",
    CurrentValue = Aux.antiAntiMacro,
    Callback = function(value)
        Aux.antiAntiMacro = value
        antiStatusLabel:Set("反反宏: " .. (value and "开启" or "关闭"))
        PushLog("反反宏: " .. (value and "开启" or "关闭"))
        SaveAuxConfig()
    end,
})

-- 作答延迟：看到目标数字后随机等 5~10 秒再点，别秒答
local ANSWER_DELAY_MIN = 5
local ANSWER_DELAY_MAX = 10

task.spawn(function()
    local pending = nil -- 当前这题的等待状态：{ num, sig, deadline, done }
    while getgenv().TwdAuxState == Aux do
        task.wait(0.5)
        if not Aux.antiAntiMacro then pending = nil; continue end

        local gui = LocalPlayer:FindFirstChild("PlayerGui")
            and LocalPlayer.PlayerGui:FindFirstChild("AntiMacro")
        if not gui then continue end
        if gui:IsA("ScreenGui") and not gui.Enabled then continue end

        -- ---------- 先扫描：答题面板是否存在 ----------
        local hasQuizPanel = false
        local targetNum = nil
        local optionBtns = {}
        local optionSig = ""

        for _, obj in ipairs(gui:GetDescendants()) do
            -- 目标数字：TextSize == 36 的 TextLabel
            -- 只认可见的：答题面板隐藏后实例往往还在，不加 Visible 会卡在分支 A，永远不点 banner
            if obj:IsA("TextLabel") and obj.TextSize == 36 and obj.Visible then
                hasQuizPanel = true
                if tonumber(obj.Text) then
                    targetNum = obj.Text
                end
            end
            -- 选项按钮：内部带数字 TextLabel 的 TextButton
            if obj:IsA("TextButton") then
                local lbl = obj:FindFirstChildOfClass("TextLabel")
                if lbl and tonumber(lbl.Text) then
                    table.insert(optionBtns, { button = obj, value = lbl.Text })
                    optionSig = optionSig .. lbl.Text .. ","
                end
            end
        end

        -- ---------- 分支 A：有答题面板 → 只答题，绝不碰 banner ----------
        if hasQuizPanel then
            if targetNum then
                local sig = targetNum .. "|" .. optionSig

                -- 新题 / 数字变了 / 已经答完又刷出新题 → 重新起 5~10 秒随机等待
                if not pending or pending.num ~= targetNum or (pending.done and pending.sig ~= sig) then
                    local delay = ANSWER_DELAY_MIN + math.random() * (ANSWER_DELAY_MAX - ANSWER_DELAY_MIN)
                    pending = { num = targetNum, sig = sig, deadline = tick() + delay, done = false }
                    PushLog(string.format("[反反宏] 看到目标=%s，%.1f 秒后作答", targetNum, delay))
                end

                -- 时间到 + 选项已加载 → 才点；选项没出来就继续等，不会空点
                if not pending.done and tick() >= pending.deadline and #optionBtns > 0 then
                    for _, item in ipairs(optionBtns) do
                        if item.value == targetNum then
                            PushLog("[反反宏] 匹配成功 目标=" .. targetNum .. "，尝试点击...")
                            local success = ClickButton(item.button)
                            if success then
                                pending.done = true
                                pending.sig = sig
                                PushLog("  -> 点击指令已发送")
                            elseif not pending.failLogged then
                                pending.failLogged = true
                                PushLog("  -> 点击失败，执行器不支持底层触发（持续重试）")
                            end
                            task.wait(2)   -- 等原脚本发 Answer + 服务器回包
                            break
                        end
                    end
                end
            end

        -- ---------- 分支 B：没有答题面板 → 才处理 PausedBanner ----------
        else
            pending = nil -- 面板消失，下一题重新计时
            local banner = gui:FindFirstChild("PausedBanner")
            if banner and banner.Visible then
                local btn = banner:FindFirstChildOfClass("TextButton")
                if btn then
                    PushLog("[反反宏] 点击 PausedBanner")
                    ClickButton(btn)
                    task.wait(1)
                end
            end
        end
    end
end)

-- ==========================================
-- 2. 自动使用技能（按塔记住的技能名定时触发）
-- ==========================================
AuxTab:CreateSection("自动使用技能")

local abilityStatusLabel = AuxTab:CreateLabel("自动使用技能: " .. (Aux.autoAbility and "开启" or "关闭"))

AuxTab:CreateToggle({
    Name = "启用自动使用技能",
    CurrentValue = Aux.autoAbility,
    Callback = function(value)
        Aux.autoAbility = value
        abilityStatusLabel:Set("自动使用技能: " .. (value and "开启" or "关闭"))
        PushLog("自动使用技能: " .. (value and "开启" or "关闭"))
        SaveAuxConfig()
        RefreshSkillCapture()
        if value and next(AbilityByTower) == nil then
            PushLog("还没有技能数据: 先手动按一次某座塔的技能，会自动记住")
        end
    end,
})

pcall(function()
    AuxTab:CreateSlider({
        Name = "技能使用间隔(秒)",
        Range = { 1, 15 },
        Increment = 1,
        CurrentValue = Aux.abilityInterval,
        Callback = function(value)
            Aux.abilityInterval = value
            SaveAuxConfig()
        end,
    })
end)

if Aux.autoAbility then
    task.defer(RefreshSkillCapture)
end

-- ==========================================
-- 3. 自动拾取（全物品版）
-- ==========================================
AuxTab:CreateSection("自动拾取")

local pickupStatusLabel = AuxTab:CreateLabel("自动拾取: " .. (Aux.autoPickup and "开启" or "关闭"))

-- ================= 配置区 =================
local teleportDelay = 0.6 -- 必须大于 0.5 秒，因为源码要求停留 0.5 秒才会自动发包
-- ==========================================

-- 掉落物文件夹由客户端生成，换图会重建，所以每轮重新取一次（原脚本只在启动时取一次）
local itemDropsFolder

local function getNearestDrop()
    local nearestDrop = nil
    local shortestDist = math.huge
    local char = LocalPlayer.Character

    if not char or not char:FindFirstChild("HumanoidRootPart") then return nil end
    local myPos = char.HumanoidRootPart.Position

    -- 遍历客户端生成的 ItemDrops 文件夹
    for _, drop in ipairs(itemDropsFolder:GetChildren()) do
        if drop:IsA("Model") or drop:IsA("BasePart") then
            local dropPos
            if drop:IsA("BasePart") then
                dropPos = drop.Position
            elseif drop:IsA("Model") then
                local success, pivot = pcall(function() return drop:GetPivot() end)
                if success then dropPos = pivot.Position end
            end

            if dropPos then
                local dist = (dropPos - myPos).Magnitude
                -- 找最近的物品
                if dist < shortestDist then
                    shortestDist = dist
                    nearestDrop = { instance = drop, position = dropPos, name = drop.Name }
                end
            end
        end
    end
    return nearestDrop
end

AuxTab:CreateToggle({
    Name = "启用自动拾取",
    CurrentValue = Aux.autoPickup,
    Callback = function(value)
        Aux.autoPickup = value
        pickupStatusLabel:Set("自动拾取: " .. (value and "开启" or "关闭"))
        PushLog("自动拾取: " .. (value and "开启" or "关闭"))
        SaveAuxConfig()
    end,
})

-- 启动独立线程执行主循环
task.spawn(function()
    while getgenv().TwdAuxState == Aux do
        task.wait(0.1) -- 基础循环间隔，防止卡死
        if not Aux.autoPickup then continue end

        itemDropsFolder = workspace:FindFirstChild("ItemDrops")
        if not itemDropsFolder then continue end

        local char = LocalPlayer.Character
        if not char or not char:FindFirstChild("HumanoidRootPart") then
            continue
        end

        local nearest = getNearestDrop()
        if nearest then
            local hrp = char.HumanoidRootPart
            local myPos = hrp.Position
            local dist = (nearest.position - myPos).Magnitude

            -- 如果距离大于 5 格，直接瞬移过去
            if dist > 5 then
                -- 瞬移到物品中心偏上 2.5 格，防止卡在模型里
                hrp.CFrame = CFrame.new(nearest.position + Vector3.new(0, 2.5, 0))
            end

            -- 核心：停在这里等待 0.6 秒
            -- 这期间，游戏自带的反编译脚本 ItemDrops_CLIENT 会自动检测到你在附近，并向服务器发送 Pickup 包。
            task.wait(teleportDelay)
        end
    end
end)

-- 自动使用技能主循环：对每座自己的塔，按记住的技能名定时 InvokeServer
task.spawn(function()
    local lastUse = {}
    while getgenv().TwdAuxState == Aux do
        task.wait(0.25)
        if not Aux.autoAbility or not RequestTowerAbility then continue end
        if State:GetWave() < 1 or State:IsMatchOver() then continue end
        local interval = tonumber(Aux.abilityInterval) or 2
        local now = tick()
        for _, towerConfig in ipairs(SharedTowerData:GetChildren()) do
            if towerConfig:GetAttribute("Owner") == LocalPlayer.Name then
                local towerName = towerConfig:GetAttribute("TowerName")
                local abilityName = towerName and AbilityByTower[towerName]
                if abilityName then
                    local uniqueId = towerConfig.Name
                    if now - (lastUse[uniqueId] or 0) >= interval then
                        lastUse[uniqueId] = now
                        pcall(function() RequestTowerAbility:InvokeServer(uniqueId, abilityName) end)
                    end
                end
            end
        end
        for uniqueId in pairs(lastUse) do
            if not SharedTowerData:FindFirstChild(uniqueId) then lastUse[uniqueId] = nil end
        end
    end
end)

PushLog("附加功能已加载（反反宏 / 自动拾取 / 自动使用技能，均在「辅助功能」页开关）")
