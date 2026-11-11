local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

-- ================= 终极防卡死保护机制 =================
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
-- ========================================================

local MacroFolder = "UnifiedMacro"
local ConfigFile = MacroFolder .. "/Config.json"

if not isfolder(MacroFolder) then
    makefolder(MacroFolder)
end

local previousState = getgenv().UnifiedMacroState
if previousState then
    previousState.running = false
end

-- 全局状态
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
    lastSpeedTime = 0,
    lastVoteTime = 0,
    lastLobbyTime = 0,
    lastRejoinTime = 0,
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

-- ================= 配置保存与读取 =================
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
-- ==================================================

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

    PushLog("准备自动重开...")

    task.spawn(function()
        local timeout = os.clock() + 30
        local vim = game:GetService("VirtualInputManager")
        local cam = workspace.CurrentCamera
        while State.running and os.clock() < timeout do
            pcall(function()
                local searchAreas = { game:GetService("CoreGui"), LocalPlayer.PlayerGui }
                for _, root in ipairs(searchAreas) do
                    for _, obj in ipairs(root:GetDescendants()) do
                        if (obj:IsA("TextButton") or obj:IsA("ImageButton")) then
                            local text = string.lower(obj.Text or "")
                            if text:find("rejoin") or text:find("replay") or text:find("再玩") then
                                for _, conn in ipairs(getconnections(obj.Activated)) do pcall(function() conn.Function() end) end
                                pcall(function() obj:Click() end)
                                return
                            end
                        end
                    end
                end
            end)
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
        if State.running then
            pcall(function() RemoteEvents.ResultsAction:FireServer("Rejoin") end)
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
    local success, upgraded = pcall(function()
        return RemoteFunctions.RequestTowerUpgrade:InvokeServer(uniqueId)
    end)
    if success and upgraded == true then return true end
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

function UnifiedMacroApi:Loop(body)
    State.macroRunning = true
    while State.running do
        if State:GetWave() < 1 then
            if not self:WaitForNextMatch() then break end
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

function Recorder:RecordTargetting(towerIndex, targetMode) end
function Recorder:RecordReady() end
function Recorder:RecordSpeed(speedValue) end
function Recorder:RecordVote(difficulty) end

function Recorder:SanitizeName(macroName) 
    return (tostring(macroName):gsub("[\\/:*?\"<>|]", "_")) 
end

function Recorder:Start(macroName)
    self.macroName = self:SanitizeName(macroName)
    self.lines = {}
    self.towerNames = {}
    self.recording = true
    self.lastRecordedWave = 0
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
        string.format("api:Vote(%q, 0, 0)", State.selectedDifficulty),
        string.format("api:Speed(%q, 0, 0)", State.selectedSpeed),
        "",
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
            PushLog("录制中: 已记录进入第 " .. currentW .. " 波")
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
        SaveConfig()
        PushLog("已选择速度: " .. tostring(selection))
    end,
})

PlayTab:CreateToggle({
    Name = "👻 自动挂机",
    CurrentValue = false,
    Flag = "AutoPlay",
    Callback = function(value)
        State.autoPlayEnabled = value
        SaveConfig()
        PushLog("自动挂机: " .. (value and "开" or "关"))
        
        if value then
            if not State.macroRunning then
                if not State.selectedMacroName or State.selectedMacroName == "暂无存档" then
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
        local path = MacroFolder .. "/" .. State.selectedMacroName
        local source = readfile(path)
        local chunk = loadstring(source)
        if chunk then
            State.running = true
            task.spawn(function() pcall(chunk) end)
        end
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

-- ================= 初始化读取配置 =================
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
-- ==================================================

local vim = game:GetService("VirtualInputManager")

-- 物理点击函数：获取中心点点击
local function PhysicalClick(obj)
    if not obj then return false end
    local success = false
    pcall(function()
        for _, conn in ipairs(getconnections(obj.Activated)) do conn.Function() end
        for _, conn in ipairs(getconnections(obj.MouseButton1Click)) do conn.Function() end
        
        local pos = obj.AbsolutePosition
        local size = obj.AbsoluteSize
        local cx = pos.X + (size.X / 2)
        local cy = pos.Y + (size.Y / 2)
        
        if cx > 0 and cy > 0 then
            vim:SendMouseButtonEvent(cx, cy, 0, true, game, 1)
            task.wait(0.05)
            vim:SendMouseButtonEvent(cx, cy, 0, false, game, 1)
            success = true
        end
    end)
    return success
end

-- 通用强效点击：根据文字找到真正的按钮并物理点击
local function ForceClickByText(targetWord)
    local searchAreas = { game:GetService("CoreGui"), LocalPlayer.PlayerGui }
    local targetKeyword = string.upper(targetWord)
    
    for _, root in ipairs(searchAreas) do
        for _, obj in ipairs(root:GetDescendants()) do
            local text = string.upper(obj.Text or "")
            local name = string.upper(obj.Name or "")
            
            if text:find(targetKeyword) or name:find(targetKeyword) then
                local clickTarget = obj
                -- 如果是文字，往上找按钮
                if obj:IsA("TextLabel") then
                    local parent = obj.Parent
                    while parent and parent ~= root do
                        if parent:IsA("TextButton") or parent:IsA("ImageButton") then
                            clickTarget = parent
                            break
                        end
                        parent = parent.Parent
                    end
                end
                if PhysicalClick(clickTarget) then
                    return true
                end
            end
        end
    end
    return false
end

-- 根据选中的难度（如 EASY），找到同一张卡片里的 VOTE 按钮
local function VoteSpecificDifficulty(diffName)
    local targetDiff = string.upper(diffName)
    local searchAreas = { game:GetService("CoreGui"), LocalPlayer.PlayerGui }
    
    for _, root in ipairs(searchAreas) do
        for _, obj in ipairs(root:GetDescendants()) do
            if obj:IsA("TextLabel") or obj:IsA("TextButton") then
                local text = string.upper(obj.Text or "")
                if text:find(targetDiff) then
                    local parent = obj.Parent
                    for depth = 1, 3 do
                        if parent and parent ~= root then
                            for _, child in ipairs(parent:GetDescendants()) do
                                if child:IsA("TextButton") or child:IsA("ImageButton") then
                                    local childText = string.upper(child.Text or "")
                                    local childName = string.upper(child.Name or "")
                                    if childText:find("VOTE") or childName:find("VOTE") then
                                        if PhysicalClick(child) then
                                            PushLog("已点击 " .. targetDiff .. " 的 VOTE 按钮")
                                            return true
                                        end
                                    end
                                end
                            end
                        end
                        parent = parent.Parent
                    end
                end
            end
        end
    end
    return false
end

local monitorAccumulator = 0
local lastSkipClickTime = 0

RunService.Heartbeat:Connect(function(deltaTime)
    monitorAccumulator = monitorAccumulator + deltaTime
    if monitorAccumulator < 0.5 then return end
    monitorAccumulator = 0
    
    pcall(function()
        State:RefreshMatchOrigin()
        TowerTracker:ScanTowers()
        TowerTracker:ScanEnvironment()
        
        -- 自动同意跳波
        if State.autoSkipVote and os.clock() - lastSkipClickTime > 1 then
            local clicked = ForceClickByText("agree") or ForceClickByText("yes") or ForceClickByText("同意")
            if clicked then
                lastSkipClickTime = os.clock()
                PushLog("已自动同意跳波")
            end
        end

        if State.autoPlayEnabled then
            -- 1. 结算重开
            if State:IsMatchOver() then
                if not State.lastRejoinTime or os.clock() - State.lastRejoinTime > 5 then
                    State.lastRejoinTime = os.clock()
                    SaveConfig() 
                    
                    local clicked = ForceClickByText("rejoin")
                    if clicked then
                        PushLog("已物理点击 Rejoin 按钮")
                    else
                        PushLog("未找到 Rejoin 按钮，发送底层 Rejoin 请求")
                        pcall(function() RemoteEvents.ResultsAction:FireServer("Rejoin") end)
                    end
                end
            
            -- 2. 大厅选图准备
            elseif State:GetWave() < 1 then
                if not State.lastLobbyTime or os.clock() - State.lastLobbyTime > 2 then
                    State.lastLobbyTime = os.clock()
                    
                    -- 强行发包投票
                    pcall(function() RemoteEvents.CastDifficultyVote:FireServer(State.selectedDifficulty) end)
                    
                    -- 精准点击对应难度的 VOTE 按钮
                    if not VoteSpecificDifficulty(State.selectedDifficulty) then
                        ForceClickByText("vote")
                    end
                    
                    -- ============ 核心升级：强行点击 READY ============
                    if ForceClickByText("ready") then
                        -- PushLog("已点击 READY 按钮") -- 为了防止日志刷屏，这里去掉了日志
                    end
                end
            end
        end

        local phaseText = "大厅"
        if State:IsMatchOver() then phaseText = "结算中"
        elseif State:GetWave() >= 1 then phaseText = "战斗中"
        end
        
        local totalWaveCount = tonumber(workspace:GetAttribute("WaveCount")) or 0
        statusLabel:Set(string.format(
            "状态: %s | 波次: %d/%d | 计时: %ds | 塔: %d | 挂机: %s",
            phaseText, State:GetWave(), totalWaveCount, math.floor(State:GetClock()), #State.placedTowerIds,
            State.autoPlayEnabled and "开" or "关"
        ))
    end)
end)

-- ================= 启动自动挂机 =================
task.defer(function()
    task.wait(1)
    if hasConfig and State.autoPlayEnabled then
        PushLog("检测到历史挂机配置，正在自动启动挂机...")
        if not State.macroRunning and State.selectedMacroName then
            local path = MacroFolder .. "/" .. State.selectedMacroName
            if isfile(path) then
                local source = readfile(path)
                local chunk = loadstring(source)
                if chunk then
                    State.running = true
                    task.spawn(function() pcall(chunk) end)
                    PushLog("自动挂机已恢复运行！")
                end
            end
        end
    end
end)

PushLog("脚本已加载，共检测到 " .. #ListMacroFiles() .. " 个宏文件")