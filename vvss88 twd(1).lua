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

local MacroFolder = "UnifiedMacro"

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
    selectedDifficulty = "Easy",
    selectedSpeed = "1",
    lastReplayTime = 0,
    lastSpeedTime = 0,
    lastVoteTime = 0,
}

getgenv().UnifiedMacroState = State

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

function State:IndexOfTower(uniqueId)
    return table.find(self.placedTowerIds, uniqueId)
end

function State:ResolveTowerId(towerIndex)
    return self.placedTowerIds[towerIndex]
end

function State:ResetMatchTracking()
    table.clear(self.placedTowerIds)
    self.ignoredMatchEndedAt = workspace:GetAttribute("MatchEndedAt")
end

function State:RefreshMatchOrigin()
    local matchStartedAt = workspace:GetAttribute("MatchStartedAt")
    if typeof(matchStartedAt) == "number" and matchStartedAt ~= self.previousMatchStartedAt then
        self.previousMatchStartedAt = matchStartedAt
        self.ignoredMatchEndedAt = workspace:GetAttribute("MatchEndedAt")
        table.clear(self.placedTowerIds)
        self.lastWaveSeen = 0
        self.waveStartClock = 0
    end
    local gameStarted = GameConfig:FindFirstChild("GameStarted")
    if gameStarted and gameStarted.Value then
        self.fallbackClockOrigin = self:GetClockOrigin()
    end
end

local UnifiedMacroApi = {}

local function FindTowerIdByPosition(position)
    if not position then return nil end
    for _, towerConfig in ipairs(SharedTowerData:GetChildren()) do
        if towerConfig:GetAttribute("Owner") == LocalPlayer.Name then
            local cf = towerConfig:GetAttribute("CFrame")
            if cf and (cf.Position - position).Magnitude < 3 then
                return towerConfig.Name
            end
        end
    end
    return nil
end
function UnifiedMacroApi:Loadout(towerNames) self.loadout = towerNames end
function UnifiedMacroApi:Map(mapName, difficultyName) self.mapName = mapName; self.difficultyName = difficultyName end

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
    local lastReadyAt = 0
    while State.running and os.clock() < deadline do
        if State:GetWave() >= 1 and not State:IsMatchOver() then return true end
        if State:IsReadyVoting() and os.clock() - lastReadyAt > 3 then
            lastReadyAt = os.clock()
            pcall(function() RemoteEvents.ReadyUp:FireServer() end)
        end
        RunService.Heartbeat:Wait()
    end
    return false
end

function UnifiedMacroApi:AutoReplay()
    if not State.autoReplay then return end
    
    if State.lastReplayTime and os.clock() - State.lastReplayTime < 15 then
        return
    end
    State.lastReplayTime = os.clock()

    PushLog("准备自动重开...")

    task.spawn(function()
        local timeout = os.clock() + 30
        local foundReplay = false
        local vim = game:GetService("VirtualInputManager")
        local cam = workspace.CurrentCamera

        while State.running and os.clock() < timeout do
            pcall(function()
                local coreGui = LocalPlayer.PlayerGui:FindFirstChild("CoreGui")
                local searchRoot = coreGui or LocalPlayer.PlayerGui
                local resultsFrame = coreGui and coreGui:FindFirstChild("ResultsFrame", true)
                if resultsFrame then searchRoot = resultsFrame end

                for _, obj in ipairs(searchRoot:GetDescendants()) do
                    if obj:IsA("TextButton") and obj.Visible then
                        local text = string.lower(obj.Text or "")
                        if text:find("replay") or text:find("再玩") or text:find("重新") or text:find("play again") then
                            for _, conn in ipairs(getconnections(obj.Activated)) do
                                pcall(function() conn.Function() end)
                            end
                            pcall(function() obj:Click() end)
                            
                            PushLog("已找到并点击重开按钮: " .. tostring(obj.Text))
                            foundReplay = true
                            break
                        end
                    end
                end
            end)

            if foundReplay then break end

            pcall(function()
                if vim and cam then
                    local centerX = cam.ViewportSize.X / 2
                    local centerY = cam.ViewportSize.Y / 2
                    vim:SendMouseButtonEvent(centerX, centerY, 0, true, game, 1)
                    task.wait(0.05)
                    vim:SendMouseButtonEvent(centerX, centerY, 0, false, game, 1)
                end
            end)

            task.wait(0.5)
        end

        if not foundReplay and State.running then
            PushLog("未能找到UI按钮，发送底层 Rejoin 请求")
            for attempt = 1, 3 do
                if not State.running then return end
                local ok = pcall(function() RemoteEvents.ResultsAction:FireServer("Rejoin") end)
                if ok then break end
                task.wait(0.5)
            end
        end
    end)
end

function UnifiedMacroApi:Place(towerName, position, rotation, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    
    for i = 1, 3 do
        local requestId = HttpService:GenerateGUID(false)
        local success, result, failureMessage = pcall(function()
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

    PushLog("放置失败: " .. tostring(towerName) .. " (" .. tostring(failureMessage or result) .. ")")
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
    if not uniqueId then
        PushLog("升级失败: 找不到目标塔 (坐标/索引: " .. tostring(positionOrIndex) .. ")")
        return false
    end
    local success, upgraded, failureMessage = pcall(function()
        return RemoteFunctions.RequestTowerUpgrade:InvokeServer(uniqueId)
    end)
    if success then
        if upgraded == true then
            return true
        elseif type(upgraded) == "string" then
            if upgraded:find("Not Enough") or upgraded:find("Max Level") then return false end
        end
    end
    PushLog("升级失败: " .. tostring(failureMessage or upgraded))
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
    if not uniqueId then
        PushLog("出售失败: 找不到目标塔 (坐标/索引: " .. tostring(positionOrIndex) .. ")")
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
        local deadline = os.clock() + 0.5
        repeat RunService.Heartbeat:Wait() until towerConfig:GetAttribute("Targetting") == targetMode or os.clock() > deadline
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

function UnifiedMacroApi:Vote(difficulty, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    return pcall(function() RemoteEvents.CastDifficultyVote:FireServer(difficulty) end)
end

function UnifiedMacroApi:Rejoin()
    pcall(function() RemoteEvents.ResultsAction:FireServer("Rejoin") end)
end

-- 带有大厅安全锁的 Loop
function UnifiedMacroApi:Loop(body)
    State.macroRunning = true
    while State.running do
        if State:GetWave() < 1 then
            PushLog("已开启自动挂机，当前在大厅待命...")
            if not self:WaitForNextMatch() then 
                break 
            end
        end

        self:Start()
        local success, runtimeError = pcall(body)
        if not success then PushLog("宏执行出错: " .. tostring(runtimeError)) end
        if not State.loopEnabled then break end
        self:WaitForMatchEnd()
        if not State.running then break end
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
    PushLog("开始录制: " .. self.macroName)
end

function Recorder:Stop()
    if not self.recording then return nil end
    self.recording = false
    local loadoutEntries = {}
    for _, towerName in ipairs(self.towerNames) do
        table.insert(loadoutEntries, string.format("%q", towerName))
    end
    local mapName = tostring(workspace:GetAttribute("Map") or "未知")
    local difficultyName = tostring(workspace:GetAttribute("Difficulty") or "未知")
    local outputLines = {
        "local api = getgenv().UnifiedMacroApi",
        "if not api then return end", "",
        "api:Loadout({" .. table.concat(loadoutEntries, ", ") .. "})",
        string.format("api:Map(%q, %q)", mapName, difficultyName), "",
        "api:Start()", "",
        "api:Loop(function()",
    }
    for _, line in ipairs(self.lines) do table.insert(outputLines, line) end
    table.insert(outputLines, "end)")
    local path = MacroFolder .. "/" .. self.macroName .. ".txt"
    writefile(path, table.concat(outputLines, "\n"))
    PushLog("录制完成: " .. path .. " (" .. #self.lines .. " 条动作)")
    return path
end

local TowerTracker = {
    knownTowers = {},
    readyVotes = nil,
    gameSpeed = nil,
    difficulty = nil,
}

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
    local matchActive = not State:IsMatchOver()
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
            if matchActive and self:IsRecordingActive() and oldTower and oldTower.cframe then
                Recorder:RecordSell(State:IndexOfTower(uniqueId), oldTower.cframe.Position)
            end
        end
    end
    self.knownTowers = snapshot
end

function TowerTracker:ScanEnvironment()
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
        PushLog("已选择存档: " .. tostring(selection))
    end,
})

local diffDropdown = PlayTab:CreateDropdown({
    Name = "选择难度",
    Options = { "Easy", "Normal", "Hard", "Insane" }, 
    CurrentOption = { "Easy" },
    MultipleOptions = false,
    Callback = function(option)
        local selection = option
        if type(option) == "table" then selection = option[1] end
        State.selectedDifficulty = selection
        PushLog("已选择难度: " .. tostring(selection))
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
        PushLog("已选择速度: " .. tostring(selection))
    end,
})

PlayTab:CreateToggle({
    Name = "👻 自动挂机",
    CurrentValue = false,
    Flag = "AutoPlay",
    Callback = function(value)
        State.autoPlayEnabled = value
        PushLog("自动挂机: " .. (value and "开" or "关"))
        
        if value then
            if State:GetWave() < 1 then
                PushLog("你在大厅开启了自动挂机，进入对局后将自动接管！")
            end
            
            if not State.macroRunning then
                if not State.selectedMacroName or State.selectedMacroName == "暂无存档" or State.selectedMacroName == "暂无宏文件" then
                    local files = ListMacroFiles()
                    if #files > 0 then
                        State.selectedMacroName = files[1]
                        macroDropdown:Set({ files[1] })
                    end
                end
                
                if State.selectedMacroName then
                    local path = MacroFolder .. "/" .. State.selectedMacroName
                    local source = readfile(path)
                    local chunk = loadstring(source)
                    if chunk then
                        State.running = true
                        task.spawn(function() pcall(chunk) end)
                        PushLog("自动挂机已启动")
                    end
                end
            end
        elseif not value then
            State.running = false
            State.macroRunning = false
            PushLog("自动挂机已关闭，停止播放")
        end
    end,
})

PlayTab:CreateButton({
    Name = "刷新存档列表",
    Callback = function()
        local macroFiles = ListMacroFiles()
        if #macroFiles == 0 then macroFiles = { "暂无存档" } end
        macroDropdown:Refresh(macroFiles)
        PushLog("存档列表已刷新")
    end,
})

PlayTab:CreateSection("其他控制")

PlayTab:CreateButton({
    Name = "手动播放选中的宏",
    Callback = function()
        if not State.selectedMacroName or State.selectedMacroName == "暂无存档" then
            local files = ListMacroFiles()
            if #files > 0 then
                State.selectedMacroName = files[1]
                macroDropdown:Set({ files[1] })
                PushLog("未选择，自动播放第一个: " .. files[1])
            else
                PushLog("没有可用的宏文件")
                return
            end
        end
        local path = MacroFolder .. "/" .. State.selectedMacroName
        local source = readfile(path)
        local chunk, compileError = loadstring(source)
        if not chunk then
            PushLog("编译失败: " .. tostring(compileError))
            return
        end
        State.running = true
        task.spawn(function()
            local success, runtimeError = pcall(chunk)
            if not success then PushLog("运行出错: " .. tostring(runtimeError)) end
        end)
        PushLog("开始播放: " .. State.selectedMacroName)
    end,
})

PlayTab:CreateButton({
    Name = "停止播放",
    Callback = function()
        State.running = false
        State.macroRunning = false
        PushLog("已请求停止播放")
    end,
})

PlayTab:CreateToggle({
    Name = "循环执行",
    CurrentValue = true,
    Flag = "LoopEnabled",
    Callback = function(value)
        State.loopEnabled = value
        PushLog("循环执行: " .. (value and "开" or "关"))
    end,
})

PlayTab:CreateToggle({
    Name = "自动同意跳波投票",
    CurrentValue = true,
    Flag = "AutoSkipVote",
    Callback = function(value)
        State.autoSkipVote = value
        PushLog("自动同意跳波: " .. (value and "开" or "关"))
    end,
})

PlayTab:CreateToggle({
    Name = "自动重开 (Replay)",
    CurrentValue = true,
    Flag = "AutoReplay",
    Callback = function(value)
        State.autoReplay = value
        PushLog("自动重开: " .. (value and "开" or "关"))
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
            if #macroFiles == 0 then macroFiles = { "暂无存档" } end
            macroDropdown:Refresh(macroFiles)
            
            local fileName = savedPath:match("([^\\/]+)$")
            if fileName then
                State.selectedMacroName = fileName
                macroDropdown:Set({ fileName })
                PushLog("已自动选中宏: " .. fileName)
            end
        else
            recordStatusLabel:Set("录制状态: 当前未在录制")
        end
    end,
})

LogTab:CreateSection("日志")
LogParagraph = LogTab:CreateParagraph({ Title = "最近日志", Content = "暂无日志" })

local initMacroFiles = ListMacroFiles()
if #initMacroFiles > 0 then
    macroDropdown:Refresh(initMacroFiles)
    State.selectedMacroName = initMacroFiles[1]
    macroDropdown:Set({ initMacroFiles[1] })
end

local skipVoteHandled = false

local function AutoAgreeSkipVote()
    if not State.autoSkipVote then return end

    local coreGui = LocalPlayer.PlayerGui:FindFirstChild("CoreGui")
    local skipVoteFrame = coreGui and coreGui:FindFirstChild("SkipWaveFrame")
    
    if not skipVoteFrame or not skipVoteFrame.Visible then
        skipVoteHandled = false
        return
    end

    if skipVoteHandled then return end

    local agreeButton = skipVoteFrame:FindFirstChild("Agree") 
        or skipVoteFrame:FindFirstChild("AgreeButton") 
        or skipVoteFrame:FindFirstChild("Yes")
        
    if not agreeButton then
        for _, obj in ipairs(skipVoteFrame:GetDescendants()) do
            if obj:IsA("TextButton") and obj.Visible then
                local text = string.lower(obj.Text or "")
                if text:find("agree") or text:find("yes") or text:find("同意") or text:find("勾选") then
                    agreeButton = obj
                    break
                end
            end
        end
    end

    if agreeButton and agreeButton.Visible then
        skipVoteHandled = true
        for _, connection in ipairs(getconnections(agreeButton.Activated)) do
            pcall(function() connection.Function() end)
        end
        PushLog("已自动同意跳波")
    end
end

local monitorAccumulator = 0

RunService.Heartbeat:Connect(function(deltaTime)
    monitorAccumulator = monitorAccumulator + deltaTime
    if monitorAccumulator < 0.25 then return end
    monitorAccumulator = 0
    
    pcall(function()
        State:RefreshMatchOrigin()
        local currentWave = State:GetWave()
        if currentWave ~= State.lastWaveSeen then
            State.lastWaveSeen = currentWave
            State.waveStartClock = State:GetClock()
        end
        TowerTracker:ScanTowers()
        TowerTracker:ScanEnvironment()
        AutoAgreeSkipVote()

        if State.autoPlayEnabled then
            if State:IsReadyVoting() then
                if not State.lastVoteTime or os.clock() - State.lastVoteTime > 3 then
                    State.lastVoteTime = os.clock()
                    pcall(function()
                        RemoteEvents.CastDifficultyVote:FireServer(State.selectedDifficulty)
                    end)
                end
            end
            
            local currentSpeed = tonumber(workspace:GetAttribute("GameSpeed")) or 1
            local targetSpeed = tonumber(State.selectedSpeed) or 1
            
            if currentSpeed ~= targetSpeed then
                if not State.lastSpeedTime or os.clock() - State.lastSpeedTime > 2 then
                    State.lastSpeedTime = os.clock()
                    pcall(function()
                        RemoteEvents.SpeedToggle:FireServer(targetSpeed)
                    end)
                end
            end
        end

        local phaseText = "大厅"
        if State:IsMatchOver() then 
            phaseText = "结算中"
        elseif State:GetWave() >= 1 then 
            phaseText = "战斗中"
        elseif State:IsReadyVoting() then 
            phaseText = "准备阶段" 
        end
        
        local totalWaveCount = tonumber(workspace:GetAttribute("WaveCount")) or 0
        
        statusLabel:Set(string.format(
            "状态: %s | 波次: %d/%d | 计时: %ds | 波内: %ds | 塔: %d | 录制: %s | 播放: %s",
            phaseText, State:GetWave(), totalWaveCount, math.floor(State:GetClock()), math.floor(State:GetWaveClock()),
            #State.placedTowerIds, Recorder.recording and "开" or "关", State.macroRunning and "运行中" or "空闲"
        ))
    end)
end)

PushLog("脚本已加载，共检测到 " .. #ListMacroFiles() .. " 个宏文件（无任何 hook）")