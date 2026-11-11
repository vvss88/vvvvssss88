local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Remotes = ReplicatedStorage:FindFirstChild("Remotes") or ReplicatedStorage:WaitForChild("Remotes", 10)
local RemoteFunctions = Remotes and (Remotes:FindFirstChild("Functions") or Remotes:WaitForChild("Functions", 10))
local RemoteEvents = Remotes and (Remotes:FindFirstChild("Events") or Remotes:WaitForChild("Events", 10))
local SharedTowerData = ReplicatedStorage:FindFirstChild("SharedTowerData") or ReplicatedStorage:WaitForChild("SharedTowerData", 10)

local GameConfig = workspace:FindFirstChild("GameConfig") or workspace:WaitForChild("GameConfig", 10)
if not GameConfig then
    GameConfig = ReplicatedStorage:FindFirstChild("GameConfig") or ReplicatedStorage:WaitForChild("GameConfig", 10)
end

if not Remotes or not RemoteFunctions or not RemoteEvents or not SharedTowerData or not GameConfig then
    warn("致命错误：游戏文件未加载完整，请重新加入游戏或等几秒后再注入！")
    return 
end

if getgenv().MacroHeartbeatConnection then
    pcall(function() getgenv().MacroHeartbeatConnection:Disconnect() end)
    getgenv().MacroHeartbeatConnection = nil
end

local MacroFolder = "UnifiedMacro"
local ConfigFile = MacroFolder .. "/Config.json"

if not isfolder(MacroFolder) then
    makefolder(MacroFolder)
end

local previousState = getgenv().UnifiedMacroState
if previousState then
    previousState.running = false
end

local State = {
    running = true,
    loopEnabled = true,
    autoSkipVote = true, 
    autoReplay = true,
    macroRunning = false,
    selectedMacroName = nil,
    recordName = "未命名",
    placedTowerIds = {},
    ignoredMatchEndedAt = nil,
    fallbackClockOrigin = workspace:GetServerTimeNow(),
    previousMatchStartedAt = nil,
    lastWaveSeen = 0,
    waveStartClock = 0,
    
    autoPlayEnabled = false,
    selectedDifficulty = "EASY",  
    selectedSpeed = "1",
    lastReplayTime = 0,
    lastLobbyTime = 0,
    
    isManualStop = false,
    isReadySent = false,
    wasGameStarted = false,
    stopGeneration = 0,
    
    -- P0: 添加大厅序列标记
    lobbySequenceFired = false,
    
    lastVotedDiff = nil,
    lastSentSpeed = nil,
    nextLobbyActionTime = 0,
}

getgenv().UnifiedMacroState = State

local LogParagraph = nil
local logHistory = {}
local lastLogTime = 0

local function PushLog(message, force)
    if not force and os.clock() - lastLogTime < 3 then return end
    lastLogTime = os.clock()
    local timestamp = DateTime.now():FormatLocalTime("HH:mm:ss", "zh-cn")
    table.insert(logHistory, 1, timestamp .. "  " .. tostring(message))
    while #logHistory > 14 do
        table.remove(logHistory)
    end
    if LogParagraph then
        LogParagraph:Set({ Title = "最近日志", Content = table.concat(logHistory, "\n") })
    end
end

local function SaveConfig()
    local data = {
        difficulty = State.selectedDifficulty,
        speed = State.selectedSpeed,
        selectedSave = State.selectedMacroName,
        autoFarm = State.autoPlayEnabled,
        autoSkipVote = State.autoSkipVote,
        autoReplay = State.autoReplay
    }
    pcall(function()
        writefile(ConfigFile, HttpService:JSONEncode(data))
    end)
end

local function LoadConfig()
    if isfile(ConfigFile) then
        local success, data = pcall(function()
            return HttpService:JSONDecode(readfile(ConfigFile))
        end)
        if success and data then
            State.selectedDifficulty = data.difficulty or "EASY"
            State.selectedSpeed = data.speed or "1"
            State.selectedMacroName = data.selectedSave
            State.autoPlayEnabled = data.autoFarm == true
            State.autoSkipVote = data.autoSkipVote ~= false
            State.autoReplay = data.autoReplay ~= false
            return true
        end
    end
    return false
end

function State:GetWave()
    local waveValue = GameConfig:FindFirstChild("Wave")
    if waveValue then return waveValue.Value end
    return 0
end

function State:GetClockOrigin()
    local matchStartedAt = workspace:GetAttribute("MatchStartedAt")
    if typeof(matchStartedAt) == "number" then return matchStartedAt end
    return self.fallbackClockOrigin
end

function State:GetClock()
    return math.max(workspace:GetServerTimeNow() - self:GetClockOrigin(), 0)
end

function State:GetWaveClock()
    local waveStartedAt = workspace:GetAttribute("WaveStartedAt")
    if typeof(waveStartedAt) == "number" then
        return math.max(workspace:GetServerTimeNow() - waveStartedAt, 0)
    end
    return math.max(self:GetClock() - self.waveStartClock, 0)
end

function State:IsMatchOver()
    local matchEndedAt = workspace:GetAttribute("MatchEndedAt")
    if typeof(matchEndedAt) == "number" and matchEndedAt ~= self.ignoredMatchEndedAt then
        return true
    end
    local baseHealth = GameConfig:FindFirstChild("BaseHealth")
    if baseHealth and baseHealth.Value <= 0 then return true end
    return false
end

function State:IsReadyVoting()
    return workspace:GetAttribute("ReadyVoting") == true
end

function State:RegisterTower(uniqueId)
    if typeof(uniqueId) ~= "string" then return end
    if table.find(self.placedTowerIds, uniqueId) then return end
    table.insert(self.placedTowerIds, uniqueId)
end

function State:IndexOfTower(uniqueId) return table.find(self.placedTowerIds, uniqueId) end
function State:ResolveTowerId(towerIndex) return self.placedTowerIds[towerIndex] end

-- P0: ResetMatchTracking 补齐重置
function State:ResetMatchTracking()
    table.clear(self.placedTowerIds)
    self.ignoredMatchEndedAt = workspace:GetAttribute("MatchEndedAt")
    self.wasGameStarted = false
    self.lobbySequenceFired = false 
    self.isReadySent = false
    self.lastVotedDiff = nil 
    self.lastSentSpeed = nil
end

function State:RefreshMatchOrigin()
    local matchStartedAt = workspace:GetAttribute("MatchStartedAt")
    if typeof(matchStartedAt) == "number" and matchStartedAt ~= self.previousMatchStartedAt then
        self.previousMatchStartedAt = matchStartedAt
        self.ignoredMatchEndedAt = workspace:GetAttribute("MatchEndedAt")
        table.clear(self.placedTowerIds)
        self.lastWaveSeen = 0
        self.waveStartClock = 0
        self.isReadySent = false
        self.fallbackClockOrigin = matchStartedAt
    end

    local gameStarted = GameConfig:FindFirstChild("GameStarted")
    if gameStarted then
        local isStarted = gameStarted.Value
        if isStarted and not self.wasGameStarted then
            if typeof(matchStartedAt) ~= "number" then
                self.fallbackClockOrigin = workspace:GetServerTimeNow()
            end
        end
        self.wasGameStarted = isStarted
    end
end

local UnifiedMacroApi = {}

local function FindTowerIdByPosition(position)
    if not position then return nil end
    local closestId = nil
    local minDistance = 2.0
    
    for _, towerConfig in ipairs(SharedTowerData:GetChildren()) do
        if towerConfig:GetAttribute("Owner") == LocalPlayer.Name then
            local cf = towerConfig:GetAttribute("CFrame")
            if cf then
                local dist = (cf.Position - position).Magnitude
                if dist < minDistance then
                    minDistance = dist
                    closestId = towerConfig.Name
                end
            end
        end
    end
    return closestId
end
local function GetServerDifficultyName(diff)
    if diff == "EASY" then return "Easy"
    elseif diff == "MEDIUM" then return "Medium"
    elseif diff == "HARD" then return "Hard"
    elseif diff == "NIGHTMARE" then return "Nightmare"
    end
    return "Easy"
end

function UnifiedMacroApi:Loadout(towerNames) self.loadout = towerNames end
function UnifiedMacroApi:Map(mapName, difficultyName) self.mapName = mapName; self.difficultyName = difficultyName end

function UnifiedMacroApi:Start()
    if State.isManualStop then return end
    State.running = true
    State:ResetMatchTracking()
    self.startTime = State:GetClock()
end

function UnifiedMacroApi:StopAll()
    State.running = false
    State.macroRunning = false
    State.isManualStop = true
    State.stopGeneration = State.stopGeneration + 1
end

function UnifiedMacroApi:WaitForTime(targetTime, targetWave)
    while State.running do
        if State:IsMatchOver() then return false end
        local wave = State:GetWave()
        local waveClock = State:GetWaveClock()
        if targetWave and targetWave > 0 then
            if wave > targetWave then return true end
            if wave == targetWave and waveClock >= (targetTime or 0) then return true end
        else
            if waveClock >= (targetTime or 0) then return true end
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
    local deadline = os.clock() + 300
    while State.running and os.clock() < deadline do
        if State:GetWave() >= 1 and not State:IsMatchOver() then return true end
        RunService.Heartbeat:Wait()
    end
    return false
end

function UnifiedMacroApi:AutoReplay()
    if not State.autoReplay then return end
    if State.lastReplayTime and os.clock() - State.lastReplayTime < 10 then return end
    State.lastReplayTime = os.clock()

    PushLog("准备自动重开 (领奖+发包)...", true)

    task.spawn(function()
        local vim = game:GetService("VirtualInputManager")
        local cam = workspace.CurrentCamera

        for i = 1, 10 do
            if not State.running then break end
            if not State:IsMatchOver() then break end
            pcall(function()
                if vim and cam then
                    local cx = cam.ViewportSize.X / 2
                    local cy = cam.ViewportSize.Y / 2
                    vim:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
                    task.wait(0.05)
                    vim:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
                end
            end)
            task.wait(0.5)
        end

        for attempt = 1, 3 do
            if not State.running then break end
            local ok = pcall(function() RemoteEvents.ResultsAction:FireServer("Rejoin") end)
            if ok then 
                PushLog("已发送底层 Rejoin 重开包", true)
                break 
            end
            task.wait(0.5)
        end
    end)
end

function UnifiedMacroApi:Place(towerName, position, rotation, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    for i = 1, 3 do
        local requestId = HttpService:GenerateGUID(false)
        local success, result = pcall(function()
            return RemoteFunctions.RequestPlacement:InvokeServer(towerName, position, rotation or 0, requestId, workspace:GetServerTimeNow())
        end)
        if success and typeof(result) == "string" then
            State:RegisterTower(result)
            return true
        end
        if typeof(result) == "string" and result:find("Not enough cash") then
            task.wait(1)
        else
            break
        end
    end
    return false
end

function UnifiedMacroApi:Upgrade(positionOrIndex, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId
    if typeof(positionOrIndex) == "Vector3" then
        uniqueId = FindTowerIdByPosition(positionOrIndex)
    else
        uniqueId = State:ResolveTowerId(positionOrIndex)
    end
    if not uniqueId then return false end
    
    for attempt = 1, 3 do
        local success, upgraded, failureMsg = pcall(function()
            return RemoteFunctions.RequestTowerUpgrade:InvokeServer(uniqueId)
        end)
        
        if success then
            if upgraded == true then return true end
            if typeof(upgraded) == "string" then
                local lowerMsg = string.lower(upgraded)
                if lowerMsg:find("not enough") or lowerMsg:find("max level") then 
                    return false 
                end
            end
        end
        task.wait(0.5)
    end
    return false
end

function UnifiedMacroApi:Sell(positionOrIndex, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId
    if typeof(positionOrIndex) == "Vector3" then
        uniqueId = FindTowerIdByPosition(positionOrIndex)
    else
        uniqueId = State:ResolveTowerId(positionOrIndex)
    end
    if not uniqueId then return false end
    pcall(function() return RemoteFunctions.RequestTowerSell:InvokeServer(uniqueId) end)
    return true
end

function UnifiedMacroApi:SetTarget(towerIndex, targetMode, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = State:ResolveTowerId(towerIndex)
    if not uniqueId then return false end
    
    local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
    if not towerConfig then return false end
    
    if towerConfig:GetAttribute("Targetting") == targetMode then return true end

    for _ = 1, 6 do
        pcall(function() RemoteFunctions.RequestTargettingChange:InvokeServer(uniqueId) end)
        local deadline = os.clock() + 0.5
        repeat RunService.Heartbeat:Wait() until towerConfig:GetAttribute("Targetting") == targetMode or os.clock() > deadline
        if towerConfig:GetAttribute("Targetting") == targetMode then return true end
    end
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
    local numSpeed = tonumber(speedValue) or 1
    
    if State.lastSentSpeed == numSpeed then return true end
    State.lastSentSpeed = numSpeed
    
    return pcall(function() RemoteEvents.SpeedToggle:FireServer(numSpeed) end)
end

function UnifiedMacroApi:Vote(difficulty, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local serverDiff = GetServerDifficultyName(difficulty)
    
    if State.lastVotedDiff == serverDiff then return true end
    State.lastVotedDiff = serverDiff
    
    return pcall(function() RemoteEvents.CastDifficultyVote:FireServer(serverDiff) end)
end

function UnifiedMacroApi:Rejoin()
    pcall(function() RemoteEvents.ResultsAction:FireServer("Rejoin") end)
end

function UnifiedMacroApi:Loop(body)
    if State.isManualStop then return end
    State.macroRunning = true
    local myGen = State.stopGeneration
    while State.running and myGen == State.stopGeneration do
        if State:GetWave() < 1 then
            if not self:WaitForNextMatch() then break end
        end
        self:Start()
        local success, runtimeError = pcall(body)
        if not success then PushLog("宏执行出错: " .. tostring(runtimeError), true) end
        if not State.loopEnabled then break end
        self:WaitForMatchEnd()
        if not State.running or myGen ~= State.stopGeneration then break end
        self:AutoReplay()
        task.wait(2)
    end
    State.macroRunning = false
end

getgenv().UnifiedMacroApi = UnifiedMacroApi
local Recorder = {
    recording = false,
    macroName = "未命名",
    lines = {},
    towerNames = {},
    lastRecordedWave = 0,
}

function Recorder:RecordPlacement(tower, towerCFrame)
    if typeof(towerCFrame) ~= "CFrame" then return end
    local position = towerCFrame.Position
    local _, yaw, _ = towerCFrame:ToOrientation()
    local quarterTurn = math.round(math.deg(yaw) / 90) * 90
    quarterTurn = quarterTurn % 360
    if quarterTurn > 0 then quarterTurn = quarterTurn - 360 end
    table.insert(self.lines, string.format("\tapi:Place(%q, Vector3.new(%.3f, %.3f, %.3f), %d, %d, %d)", tower, position.X, position.Y, position.Z, quarterTurn, math.floor(State:GetWaveClock()), State:GetWave()))
    if not table.find(self.towerNames, tower) then
        table.insert(self.towerNames, tower)
    end
end

function Recorder:RecordUpgrade(towerIndex, position)
    if not towerIndex or not position then return end
    table.insert(self.lines, string.format("\tapi:Upgrade(Vector3.new(%.3f, %.3f, %.3f), %d, %d)", position.X, position.Y, position.Z, math.floor(State:GetWaveClock()), State:GetWave()))
end

function Recorder:RecordSell(towerIndex, position)
    if not towerIndex or not position then return end
    table.insert(self.lines, string.format("\tapi:Sell(Vector3.new(%.3f, %.3f, %.3f), %d, %d)", position.X, position.Y, position.Z, math.floor(State:GetWaveClock()), State:GetWave()))
end

function Recorder:RecordTargetting(towerIndex, targetMode) 
    if not towerIndex or not targetMode then return end
    table.insert(self.lines, string.format("\tapi:SetTarget(%d, %q, %d, %d)", towerIndex, targetMode, math.floor(State:GetWaveClock()), State:GetWave()))
end

function Recorder:RecordReady() table.insert(self.lines, string.format("\tapi:Ready(%d, %d)", math.floor(State:GetWaveClock()), State:GetWave())) end
function Recorder:RecordSpeed(speedValue) table.insert(self.lines, string.format("\tapi:Speed(%s, %d, %d)", tostring(speedValue), math.floor(State:GetWaveClock()), State:GetWave())) end
function Recorder:RecordVote(difficulty) table.insert(self.lines, string.format("\tapi:Vote(%q, %d, %d)", tostring(difficulty), math.floor(State:GetWaveClock()), State:GetWave())) end

function Recorder:SanitizeName(macroName) 
    return (tostring(macroName):gsub("[\\/:*?\"<>|]", "_")) 
end

function Recorder:Start(macroName)
    self.macroName = self:SanitizeName(macroName)
    self.lines = {}
    self.towerNames = {}
    self.recording = true
    self.lastRecordedWave = 0
    PushLog("开始录制: " .. self.macroName, true)
end

function Recorder:Stop()
    if not self.recording then return nil end
    self.recording = false
    local loadoutEntries = {}
    for _, towerName in ipairs(self.towerNames) do
        table.insert(loadoutEntries, string.format("%q", towerName))
    end
    local mapName = tostring(workspace:GetAttribute("Map") or "未知")
    local actualDiff = tostring(workspace:GetAttribute("Difficulty") or "未知")
    
    if actualDiff ~= "未知" and string.upper(actualDiff) ~= string.upper(State.selectedDifficulty) then
        PushLog("警告: 实际游戏难度(" .. actualDiff .. ") 与面板(" .. State.selectedDifficulty .. ")不一致!", true)
    end
    
    local outputLines = {
        "local api = getgenv().UnifiedMacroApi",
        "if not api then return end", "",
        "api:Loadout({" .. table.concat(loadoutEntries, ", ") .. "})",
        string.format("api:Map(%q, %q)", mapName, actualDiff), "",
        "api:Start()", "",
        "api:Loop(function()",
        string.format("\tapi:Vote(%q, 0, 0)", State.selectedDifficulty),
        string.format("\tapi:Speed(%s, 0, 0)", tostring(State.selectedSpeed)),
    }
    for _, line in ipairs(self.lines) do table.insert(outputLines, line) end
    table.insert(outputLines, "end)")
    
    local path = MacroFolder .. "/" .. self.macroName .. ".txt"
    writefile(path, table.concat(outputLines, "\n"))
    PushLog("录制完成: " .. path .. " (" .. #self.lines .. " 条动作)", true)
    return path
end

local TowerTracker = { knownTowers = {}, readyVotes = nil, gameSpeed = nil, difficulty = nil }

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
    for uniqueId, tower in pairs(snapshot) do
        local previousTower = self.knownTowers[uniqueId]
        if not previousTower then
            State:RegisterTower(uniqueId)
            if self:IsRecordingActive() then Recorder:RecordPlacement(tower.towerName, tower.cframe) end
        else
            if tower.level > previousTower.level then
                for _ = previousTower.level + 1, tower.level do
                    if self:IsRecordingActive() and tower.cframe then
                        Recorder:RecordUpgrade(State:IndexOfTower(uniqueId), tower.cframe.Position)
                    end
                end
            end
            if tower.targetting and tower.targetting ~= previousTower.targetting then
                if self:IsRecordingActive() then Recorder:RecordTargetting(State:IndexOfTower(uniqueId), tower.targetting) end
            end
        end
    end
    for uniqueId, oldTower in pairs(self.knownTowers) do
        if not snapshot[uniqueId] then
            if self:IsRecordingActive() and oldTower and oldTower.cframe then
                Recorder:RecordSell(State:IndexOfTower(uniqueId), oldTower.cframe.Position)
            end
        end
    end
    self.knownTowers = snapshot
end

function TowerTracker:ScanEnvironment()
    if Recorder.recording then
        local currentW = State:GetWave()
        if currentW > Recorder.lastRecordedWave then
            Recorder.lastRecordedWave = currentW
            table.insert(Recorder.lines, string.format("\t-- 进入第 %d 波", currentW))
        end
    end
end

function TowerTracker:Reset() self.knownTowers = {} end

local function ListMacroFiles()
    local macroFiles = {}
    for _, path in ipairs(listfiles(MacroFolder)) do
        if path:sub(-4) == ".txt" then
            local fileName = path:match("([^\\/]+)$") or path
            table.insert(macroFiles, fileName)
        end
    end
    table.sort(macroFiles)
    return macroFiles
end
local hiddenGui = gethui and gethui() or game:GetService("CoreGui")
local existingMenu = hiddenGui:FindFirstChild("Rayfield")

if existingMenu then
    existingMenu:Destroy()
end

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "vvss的twd宏",
    LoadingTitle = "vvss",
    LoadingSubtitle = "录制与回放",
    ConfigurationSaving = { Enabled = false },
    KeySystem = false,
})

local PlayTab = Window:CreateTab("宏播放", nil)
local RecordTab = Window:CreateTab("录制", nil)
local LogTab = Window:CreateTab("日志", nil)

local statusLabel = PlayTab:CreateLabel("状态: 初始化中")
PlayTab:CreateSection("局内预")

local macroDropdown = PlayTab:CreateDropdown({
    Name = "选择存档",
    Options = { "暂无存档" },
    CurrentOption = { "暂无存档" },
    MultipleOptions = false,
    Callback = function(option)
        local selection = option
        if type(option) == "table" then selection = option[1] end
        State.selectedMacroName = selection
        SaveConfig()
    end,
})

local diffDropdown = PlayTab:CreateDropdown({
    Name = "选择难度",
    Options = { "EASY", "MEDIUM", "HARD", "NIGHTMARE" }, 
    CurrentOption = { "EASY" },
    MultipleOptions = false,
    Callback = function(option)
        local selection = option
        if type(option) == "table" then selection = option[1] end
        State.selectedDifficulty = selection
        SaveConfig()
        PushLog("已选择难度: " .. tostring(selection), true)
    end,
})

local speedDropdown = PlayTab:CreateDropdown({
    Name = "选择速度",
    Options = { "1", "1.25", "1.5" }, 
    CurrentOption = { "1" },
    MultipleOptions = false,
    Callback = function(option)
        local selection = option
        if type(option) == "table" then selection = option[1] end
        State.selectedSpeed = selection
        SaveConfig()
        PushLog("已选择速度: " .. tostring(selection), true)
    end,
})

local autoFarmToggle = PlayTab:CreateToggle({
    Name = "👻 自动挂机",
    CurrentValue = false,
    Flag = "AutoPlay",
    Callback = function(value)
        State.autoPlayEnabled = value
        SaveConfig()
        PushLog("自动挂机: " .. (value and "开" or "关"), true)
        
        if value then
            State.isManualStop = false
            State.macroRunning = false
            State.stopGeneration = State.stopGeneration + 1 
            
            if not State.selectedMacroName or State.selectedMacroName == "暂无存档" then
                local files = ListMacroFiles()
                if #files > 0 then
                    State.selectedMacroName = files[1]
                    macroDropdown:Set({ files[1] })
                end
            end
            
            if State.selectedMacroName then
                local path = MacroFolder .. "/" .. State.selectedMacroName
                local source
                local success, err = pcall(function() source = readfile(path) end)
                if success and source then
                    local chunk
                    local cSuccess, cErr = pcall(function() chunk = loadstring(source) end)
                    if cSuccess and chunk then
                        State.running = true
                        task.spawn(function() pcall(chunk) end)
                        PushLog("自动挂机已启动", true)
                    end
                end
            end
        elseif not value then
            UnifiedMacroApi:StopAll()
            PushLog("自动挂机已关闭，停止播放", true)
        end
    end,
})

PlayTab:CreateButton({
    Name = "刷新存档列表",
    Callback = function()
        local macroFiles = ListMacroFiles()
        if #macroFiles == 0 then macroFiles = { "暂无存档" } end
        macroDropdown:Refresh(macroFiles)
    end,
})

PlayTab:CreateSection("其他控制")

PlayTab:CreateButton({
    Name = "手动播放选中的宏",
    Callback = function()
        if not State.selectedMacroName or State.selectedMacroName == "暂无存档" then
            local files = ListMacroFiles()
            if #files > 0 then State.selectedMacroName = files[1]; macroDropdown:Set({ files[1] }) else return end
        end
        State.isManualStop = false
        State.macroRunning = false
        State.stopGeneration = State.stopGeneration + 1
        
        local path = MacroFolder .. "/" .. State.selectedMacroName
        local source
        local success = pcall(function() source = readfile(path) end)
        if success and source then
            local chunk
            local cSuccess = pcall(function() chunk = loadstring(source) end)
            if cSuccess and chunk then
                State.running = true
                task.spawn(function() pcall(chunk) end)
            end
        end
    end,
})

PlayTab:CreateButton({
    Name = "停止播放",
    Callback = function()
        UnifiedMacroApi:StopAll()
        PushLog("已请求停止播放", true)
    end,
})

PlayTab:CreateToggle({
    Name = "自动同意跳波投票",
    CurrentValue = true,
    Flag = "AutoSkipVote",
    Callback = function(value)
        State.autoSkipVote = value
        SaveConfig()
    end,
})

PlayTab:CreateToggle({
    Name = "自动重开 (Replay)",
    CurrentValue = true,
    Flag = "AutoReplay",
    Callback = function(value)
        State.autoReplay = value
        SaveConfig()
    end,
})
RecordTab:CreateSection("录制设置")

local recordNameLabel = RecordTab:CreateLabel("当前宏名称: 未命名")
local recordStatusLabel = RecordTab:CreateLabel("录制状态: 未开始")

RecordTab:CreateInput({
    Name = "宏名称",
    CurrentValue = "",
    PlaceholderText = "输入宏名称后回车",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        if text and text ~= "" then
            State.recordName = text
            recordNameLabel:Set("当前宏名称: " .. text)
        end
    end,
})

RecordTab:CreateButton({
    Name = "开始录制",
    Callback = function()
        Recorder:Start(State.recordName or "未命名")
        recordStatusLabel:Set("录制状态: 录制中 (" .. Recorder.macroName .. ")")
    end,
})

RecordTab:CreateButton({
    Name = "停止录制并保存",
    Callback = function()
        local savedPath = Recorder:Stop()
        if savedPath then
            recordStatusLabel:Set("录制状态: 已保存 " .. savedPath)
            local macroFiles = ListMacroFiles()
            macroDropdown:Refresh(macroFiles)
            local fileName = savedPath:match("([^\\/]+)$")
            if fileName then
                State.selectedMacroName = fileName
                macroDropdown:Set({ fileName })
                SaveConfig()
            end
        end
    end,
})

LogTab:CreateSection("日志")
LogParagraph = LogTab:CreateParagraph({ Title = "最近日志", Content = "暂无日志" })

local initMacroFiles = ListMacroFiles()
if #initMacroFiles > 0 then
    macroDropdown:Refresh(initMacroFiles)
end

local hasConfig = LoadConfig()

diffDropdown:Set({ State.selectedDifficulty })
speedDropdown:Set({ State.selectedSpeed })
if State.selectedMacroName and table.find(initMacroFiles, State.selectedMacroName) then
    macroDropdown:Set({ State.selectedMacroName })
else
    if #initMacroFiles > 0 then
        State.selectedMacroName = initMacroFiles[1]
        macroDropdown:Set({ initMacroFiles[1] })
    end
end

if hasConfig then
    task.delay(1, function()
        if State.autoPlayEnabled then
            autoFarmToggle:Set(true)
            PushLog("读取历史配置，开关已自动开启", true)
        end
    end)
end

local vim = game:GetService("VirtualInputManager")
local lastSkipClickTime = 0

local function AutoAgreeSkipVote()
    if not State.autoSkipVote or os.clock() - lastSkipClickTime < 1 then return end
    
    local searchAreas = { game:GetService("CoreGui"), LocalPlayer.PlayerGui }
    for _, root in ipairs(searchAreas) do
        for _, obj in ipairs(root:GetDescendants()) do
            if obj:IsA("TextButton") or obj:IsA("ImageButton") then
                local text = string.lower(obj.Text or "")
                local name = string.lower(obj.Name or "")
                if name:find("agree") or name:find("yes") or text == "agree" or text == "yes" or text == "同意" then
                    lastSkipClickTime = os.clock()
                    task.spawn(function()
                        local pos = obj.AbsolutePosition
                        local size = obj.AbsoluteSize
                        if pos.X > 0 and pos.Y > 0 then
                            vim:SendMouseButtonEvent(pos.X + size.X/2, pos.Y + size.Y/2, 0, true, game, 1)
                            task.wait(0.05)
                            vim:SendMouseButtonEvent(pos.X + size.X/2, pos.Y + size.Y/2, 0, false, game, 1)
                            PushLog("已全屏扫描并点击跳波", true)
                        end
                    end)
                    return
                end
            end
        end
    end
end

local monitorAccumulator = 0

getgenv().MacroHeartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
    monitorAccumulator = monitorAccumulator + deltaTime
    if monitorAccumulator < 0.5 then return end
    monitorAccumulator = 0
    
    pcall(function()
        State:RefreshMatchOrigin()
        TowerTracker:ScanTowers()
        TowerTracker:ScanEnvironment()
        AutoAgreeSkipVote()

        local currentW = State:GetWave()
        
        -- P2: isInLobby 判定严格依靠波次 < 1
        local isInLobby = (currentW < 1)
        
        if currentW ~= State.lastWaveSeen then
            State.lastWaveSeen = currentW
            State.waveStartClock = State:GetClock()
        end

        if State.autoPlayEnabled then
            if State:IsMatchOver() then
                -- 结算交由 AutoReplay
            else
                if isInLobby and not State.lobbySequenceFired then
                    State.lobbySequenceFired = true
                    local myGen = State.stopGeneration -- P2: 获取当前协程代际
                    
                    task.spawn(function()
                        local serverDiff = GetServerDifficultyName(State.selectedDifficulty)
                        
                        task.wait(5)
                        if myGen ~= State.stopGeneration then return end
                        if not State.running then return end
                        
                        -- P1: 改回 2 次，间隔 3 秒
                        for i = 1, 2 do
                            if myGen ~= State.stopGeneration or not State.running then return end
                            pcall(function() RemoteEvents.CastDifficultyVote:FireServer(serverDiff) end)
                            task.wait(3)
                        end
                        State.lastVotedDiff = serverDiff
                        PushLog("大厅动作: 连发 2 次投票 [" .. serverDiff .. "]", true)
                        
                        -- P1: 准备包状态驱动，不死等 14 秒
                        local waitDeadline = os.clock() + 60 -- 防死循环最长等 60 秒
                        while os.clock() < waitDeadline do
                            if myGen ~= State.stopGeneration or not State.running then return end
                            
                            -- 只要游戏进入准备状态，立刻发包
                            if State:IsReadyVoting() then
                                pcall(function() RemoteEvents.ReadyUp:FireServer() end)
                                State.isReadySent = true
                                PushLog("大厅动作: 检测到准备阶段，已发送准备包", true)
                                break
                            end
                            task.wait(0.5)
                        end
                    end)
                end
                
                -- 局内调速逻辑
                if not isInLobby then
                    local numSpeed = tonumber(State.selectedSpeed) or 1
                    if State.lastSentSpeed ~= numSpeed then
                        pcall(function() RemoteEvents.SpeedToggle:FireServer(numSpeed) end)
                        State.lastSentSpeed = numSpeed
                        PushLog("游戏内调速: [" .. tostring(numSpeed) .. "]", true)
                    end
                end
            end
        end

        local phaseText = "大厅"
        if State:IsMatchOver() then phaseText = "结算中"
        elseif not isInLobby then phaseText = "战斗中"
        end
        
        local totalWaveCount = tonumber(workspace:GetAttribute("WaveCount")) or 0
        statusLabel:Set(string.format(
            "状态: %s | 波次: %d/%d | 计时: %ds | 塔: %d | 挂机: %s",
            phaseText, currentW, totalWaveCount, math.floor(State:GetClock()), #State.placedTowerIds,
            State.autoPlayEnabled and "开" or "关"
        ))
    end)
end)

PushLog("脚本已加载，P2 状态驱动高防版已启动。", true)