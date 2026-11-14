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

local MacroFolder = "TWD_Macros"

if not isfolder(MacroFolder) then
    makefolder(MacroFolder)
end

local ConfigFile = MacroFolder .. "/twd_config.json"

local previousState = getgenv().UnifiedMacroState
if previousState then
    previousState.running = false
end

-- [优化] 清理旧 Heartbeat，避免重载脚本后重复监控
if getgenv().UnifiedMacroHeartbeat then
    pcall(function()
        getgenv().UnifiedMacroHeartbeat:Disconnect()
    end)
end

local State = {
    running = true,
    loopEnabled = true,
    autoSkipVote = false,
    autoRejoinEnabled = false, -- [新增] 自动重连开关状态
    macroRunning = false,
    selectedMacroName = nil,
    recordName = "未命名",
    placedTowerIds = {},
    -- [优化] uniqueId -> 索引，O(1) 查找
    towerIndex = {},
    ignoredMatchEndedAt = nil,
    fallbackClockOrigin = workspace:GetServerTimeNow(),
    previousMatchStartedAt = nil,
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

-- [优化] 录制时间保留两位小数，避免同秒动作被挤压
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
    while State.running do
        if State:IsMatchOver() then return false end
        if State:GetWave() >= (targetWave or 0) and State:GetClock() >= (targetTime or 0) then
            return true
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

function UnifiedMacroApi:Place(towerName, position, rotation, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end

    local requestId = HttpService:GenerateGUID(false)
    local requestTime = workspace:GetServerTimeNow()
    local maxRetries = 3

    for attempt = 1, maxRetries do
        if not State.running then return false end

        local success, result, failureMessage = pcall(function()
            return RemoteFunctions.RequestPlacement:InvokeServer(
                towerName, position, rotation or 0, requestId, requestTime
            )
        end)

        if success and typeof(result) == "string" then
            State:RegisterTower(result)
            if attempt > 1 then
                PushLog("放置成功(重试" .. attempt .. "次): " .. tostring(towerName))
            end
            return true
        end

        if attempt == maxRetries then
            PushLog("放置彻底失败(已重试3次): " .. tostring(towerName) .. " (" .. tostring(failureMessage or result) .. ")")
        else
            PushLog("放置失败, 等待1.5秒重试 (" .. attempt .. "/3): " .. tostring(towerName))
            task.wait(1.5)
        end
    end

    return false
end

function UnifiedMacroApi:Upgrade(towerIndex, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = State:ResolveTowerId(towerIndex)
    if not uniqueId then
        PushLog("升级失败: 找不到第 " .. tostring(towerIndex) .. " 座塔")
        return false
    end

    local maxRetries = 3
    for attempt = 1, maxRetries do
        if not State.running then return false end

        local success, upgraded, failureMessage = pcall(function()
            return RemoteFunctions.RequestTowerUpgrade:InvokeServer(uniqueId)
        end)

        if success and upgraded then
            if attempt > 1 then
                PushLog("升级成功(重试" .. attempt .. "次): 第 " .. tostring(towerIndex) .. " 座塔")
            end
            return true
        end

        if attempt == maxRetries then
            PushLog("升级彻底失败(已重试3次): 第 " .. tostring(towerIndex) .. " 座塔 (" .. tostring(failureMessage or upgraded) .. ")")
        else
            PushLog("升级失败, 等待1.5秒重试 (" .. attempt .. "/3): 第 " .. tostring(towerIndex) .. " 座塔")
            task.wait(1.5)
        end
    end
    return false
end
function UnifiedMacroApi:Sell(towerIndex, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = State:ResolveTowerId(towerIndex)
    if not uniqueId then
        PushLog("出售失败: 找不到第 " .. tostring(towerIndex) .. " 座塔")
        return false
    end
    local success, failureMessage = pcall(function()
        return RemoteFunctions.RequestTowerSell:InvokeServer(uniqueId)
    end)
    if success and (failureMessage == nil or failureMessage == true) then return true end
    PushLog("出售失败: " .. tostring(failureMessage))
    return false
end

function UnifiedMacroApi:SetTarget(towerIndex, targetMode, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = State:ResolveTowerId(towerIndex)
    if not uniqueId then
        PushLog("切换优先级失败: 找不到第 " .. tostring(towerIndex) .. " 座塔")
        return false
    end
    local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
    if not towerConfig then return false end
    if towerConfig:GetAttribute("Targetting") == targetMode then return true end

    for _ = 1, 6 do
        pcall(function() RemoteFunctions.RequestTargettingChange:InvokeServer(uniqueId) end)
        local deadline = tick() + 0.5
        repeat
            RunService.Heartbeat:Wait()
        until towerConfig:GetAttribute("Targetting") == targetMode or tick() > deadline

        if towerConfig:GetAttribute("Targetting") == targetMode then return true end
    end
    PushLog("切换优先级失败: " .. tostring(targetMode))
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
function Recorder:RecordPlacement(uniqueId, towerName, towerCFrame)
    if not towerName or typeof(towerCFrame) ~= "CFrame" then return false end
    local customName = self:GetCustomName(uniqueId, towerName)
    local position = towerCFrame.Position
    local _, yaw, _ = towerCFrame:ToOrientation()
    local quarterTurn = math.round(math.deg(yaw) / 90) * 90
    quarterTurn = quarterTurn % 360
    if quarterTurn > 180 then quarterTurn = quarterTurn - 360 end

    table.insert(self.actions, {
        action = "Place", name = customName, towerName = towerName,
        pos = { x = tonumber(string.format("%.3f", position.X)), y = tonumber(string.format("%.3f", position.Y)), z = tonumber(string.format("%.3f", position.Z)) },
        rot = quarterTurn, time = RoundTime(State:GetClock()), wave = State:GetWave()
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

function Recorder:RecordReady() table.insert(self.actions, { action = "Ready", time = RoundTime(State:GetClock()), wave = State:GetWave() }) end
function Recorder:RecordSpeed(speedValue) table.insert(self.actions, { action = "Speed", speedValue = speedValue, time = RoundTime(State:GetClock()), wave = State:GetWave() }) end
function Recorder:RecordVote(difficultyName) table.insert(self.actions, { action = "Vote", difficultyName = tostring(difficultyName), time = RoundTime(State:GetClock()), wave = State:GetWave() }) end

function Recorder:RecordWave(wave)
    if not wave or wave < 1 then return end
    table.insert(self.actions, { action = "WaitWave", wave = wave, time = RoundTime(State:GetClock()) })
end

function Recorder:SanitizeName(macroName) return (tostring(macroName):gsub("[\\/:*?\"<>|]", "_")) end

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
    return true
end

function Recorder:Stop()
    if not self.recording then return nil end
    self.recording = false
    local currentWave = State:GetWave()
    if currentWave > (self.lastRecordedWave or 0) then self:RecordWave(currentWave); self.lastRecordedWave = currentWave end

    local saveData = { map = self.mapName or "未知", difficulty = self.difficultyName or "未知", loadout = self.towerNames, actions = self.actions }
    local path = MacroFolder .. "/" .. self.macroName .. ".json"
    local success, jsonString = pcall(function() return HttpService:JSONEncode(saveData) end)
    if not success then PushLog("JSON生成失败: " .. tostring(jsonString)); return nil end

    local writeSuccess, writeError = pcall(function() writefile(path, jsonString) end)
    if not writeSuccess then PushLog("保存失败: " .. tostring(writeError)); return nil end
    PushLog("录制完成(JSON): " .. path .. " (" .. #self.actions .. " 条动作)")
    return path
end

local function ListMacroFiles()
    local macroFiles = {}
    local success, files = pcall(function() return listfiles(MacroFolder) end)
    if not success or not files then return macroFiles end
    for _, path in ipairs(files) do
        if path:sub(-4) == ".txt" or path:sub(-5) == ".json" then
            local fileName = path:match("([^\\/]+)$") or path
            table.insert(macroFiles, fileName)
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
    local now = State:GetClock()

    for uniqueId, tower in pairs(snapshot) do
        local previousTower = previousSnapshot[uniqueId]
        if not previousTower then
            State:RegisterTower(uniqueId)
            if self:IsRecordingActive() then
                local success = Recorder:RecordPlacement(uniqueId, tower.towerName, tower.cframe)
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
            else self.knownTowers[uniqueId] = tower end
        else
            if tower.level > previousTower.level then
                local step = 0
                for _ = previousTower.level + 1, tower.level do if self:IsRecordingActive() then Recorder:RecordUpgrade(uniqueId, now + step * 0.1) end; step = step + 1 end
            end
            if tower.targetting and tower.targetting ~= previousTower.targetting then
                if self:IsRecordingActive() then Recorder:RecordTargetting(uniqueId, tower.targetting, now) end
            end
            self.knownTowers[uniqueId] = tower
        end
    end

    for uniqueId, oldTower in pairs(previousSnapshot) do
        if not snapshot[uniqueId] then if matchActive and self:IsRecordingActive() then Recorder:RecordSell(uniqueId, now) end end
    end
end

function TowerTracker:ScanEnvironment()
    local currentWave = State:GetWave()
    if currentWave > (Recorder.lastRecordedWave or 0) then
        if self:IsRecordingActive() then for w = (Recorder.lastRecordedWave or 0) + 1, currentWave do Recorder:RecordWave(w) end end
        Recorder.lastRecordedWave = currentWave
    end

    local readyVotes = tonumber(workspace:GetAttribute("ReadyVotes")) or 0
    if self.readyVotes == nil then self.readyVotes = readyVotes
    elseif readyVotes ~= self.readyVotes then
        if readyVotes > self.readyVotes and State:IsReadyVoting() and self:IsRecordingActive() then Recorder:RecordReady() end
        self.readyVotes = readyVotes
    end

    local gameSpeed = tonumber(workspace:GetAttribute("GameSpeed")) or 1
    if self.gameSpeed == nil then self.gameSpeed = gameSpeed
    elseif gameSpeed ~= self.gameSpeed then
        if self:IsRecordingActive() then Recorder:RecordSpeed(gameSpeed) end
        self.gameSpeed = gameSpeed
    end

    local difficulty = workspace:GetAttribute("Difficulty")
    if self.difficulty == nil then self.difficulty = difficulty
    elseif difficulty ~= self.difficulty then
        if self:IsRecordingActive() and typeof(difficulty) == "string" then Recorder:RecordVote(difficulty) end
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
    State.autoStartedThisMatch = true
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
                        if api:Place(act.towerName, pos, act.rot, act.time, act.wave) then playbackMap[act.name] = #State.placedTowerIds else failedTargets[act.name] = true end
                    elseif act.action == "Upgrade" then
                        local realIdx = playbackMap[act.target]
                        if realIdx then api:Upgrade(realIdx, act.time, act.wave) elseif failedTargets[act.target] then PushLog("跳过升级: 前置放置失败 " .. tostring(act.target)) end
                    elseif act.action == "Sell" then
                        local realIdx = playbackMap[act.target]
                        if realIdx then api:Sell(realIdx, act.time, act.wave) elseif failedTargets[act.target] then PushLog("跳过出售: 前置放置失败 " .. tostring(act.target)) end
                    elseif act.action == "SetTarget" then
                        local realIdx = playbackMap[act.target]
                        if realIdx then api:SetTarget(realIdx, act.targetMode, act.time, act.wave) elseif failedTargets[act.target] then PushLog("跳过切换优先级: 前置放置失败 " .. tostring(act.target)) end
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
LogParagraph = LogTab:CreateParagraph({ Title = "最近日志", Content = "暂无日志" })
RefreshMacroList()

local skipVoteHandled = false
local function AutoAgreeSkipVote()
    if not State.autoSkipVote then return end
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui"); if not playerGui then return end
    local coreGui = playerGui:FindFirstChild("CoreGui"); if not coreGui then return end
    local skipFrame = coreGui:FindFirstChild("SkipWaveFrame"); if not skipFrame or not skipFrame.Visible then skipVoteHandled = false; return end
    if skipVoteHandled then return end
    local agreeButton = skipFrame:FindFirstChild("Agree"); if not agreeButton or not agreeButton.Visible or not getconnections then return end
    local connections = getconnections(agreeButton.Activated); if not connections or #connections == 0 then return end
    skipVoteHandled = true
    for _, connection in ipairs(connections) do pcall(function() connection.Function() end) end
end

-- 🔄 自动重连模块 (完全静默，无任何日志输出)
local RejoinConfig = { delayBeforeRejoin = 5, cooldown = 15, maxRetries = 3, retryDelay = 8, pollInterval = 0.5 }
local lastTriggerTime = 0
local isRejoining = false
local scriptStartTime = tick()

local function doRejoin()
    if isRejoining then return end
    if os.clock() - lastTriggerTime < RejoinConfig.cooldown then return end
    isRejoining = true; lastTriggerTime = os.clock()
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
    if monitorAccumulator < 0.25 then return end
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
                else recordStatusLabel:Set("录制状态: 自动保存失败") end
                PushLog("检测到新局，已自动停止录制并保存，请重新开始录制")
            end
            TowerTracker:Reset(); State:ClearTowers()
        end
        TowerTracker:ScanEnvironment(); TowerTracker:ScanTowers(); AutoAgreeSkipVote()

        if State:GetWave() >= 1 and not State.macroRunning and not State.autoStartedThisMatch and State.loopEnabled and State.selectedMacroName and State.selectedMacroName ~= "暂无宏文件" then
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

PushLog("脚本已加载，共检测到 " .. #ListMacroFiles() .. " 个宏文件（无任何 hook）")