local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
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
    autoSkipVote = false,
    macroRunning = false,
    selectedMacroName = nil,
    recordName = "未命名",
    placedTowerIds = {},
    internalCallCount = 0,
    ignoredMatchEndedAt = nil,
    fallbackClockOrigin = workspace:GetServerTimeNow(),
    previousMatchStartedAt = nil,
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

function State:RegisterTower(uniqueId)
    if typeof(uniqueId) ~= "string" then
        return
    end

    if table.find(self.placedTowerIds, uniqueId) then
        return
    end

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
    end

    local gameStarted = GameConfig:FindFirstChild("GameStarted")

    if gameStarted and gameStarted.Value then
        self.fallbackClockOrigin = self:GetClockOrigin()
    end
end

function State:IsReadyVoting()
    return workspace:GetAttribute("ReadyVoting") == true
end

local UnifiedMacroApi = {}

local function RunInternal(callback)
    State.internalCallCount = State.internalCallCount + 1

    local packed = table.pack(pcall(callback))

    State.internalCallCount = State.internalCallCount - 1

    return table.unpack(packed, 1, packed.n)
end

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
        if State:IsMatchOver() then
            return false
        end

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
    local deadline = os.clock() + 300
    local lastReadyAt = 0

    while State.running and os.clock() < deadline do
        if State:GetWave() >= 1 and not State:IsMatchOver() then
            return true
        end

        if State:IsReadyVoting() and os.clock() - lastReadyAt > 3 then
            lastReadyAt = os.clock()

            RunInternal(function()
                RemoteEvents.ReadyUp:FireServer()
            end)
        end

        RunService.Heartbeat:Wait()
    end

    return false
end

function UnifiedMacroApi:Place(towerName, position, rotation, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then
        return false
    end

    local requestId = HttpService:GenerateGUID(false)
    local success, result, failureMessage = RunInternal(function()
        return RemoteFunctions.RequestPlacement:InvokeServer(towerName, position, rotation or 0, requestId, workspace:GetServerTimeNow())
    end)

    if success and typeof(result) == "string" then
        State:RegisterTower(result)
        return true
    end

    PushLog("放置失败: " .. tostring(towerName) .. " (" .. tostring(failureMessage or result) .. ")")

    return false
end

function UnifiedMacroApi:Upgrade(towerIndex, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then
        return false
    end

    local uniqueId = State:ResolveTowerId(towerIndex)

    if not uniqueId then
        PushLog("升级失败: 找不到第 " .. tostring(towerIndex) .. " 座塔")
        return false
    end

    local success, upgraded, failureMessage = RunInternal(function()
        return RemoteFunctions.RequestTowerUpgrade:InvokeServer(uniqueId)
    end)

    if success and upgraded then
        return true
    end

    PushLog("升级失败: " .. tostring(failureMessage or upgraded))

    return false
end

function UnifiedMacroApi:Sell(towerIndex, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then
        return false
    end

    local uniqueId = State:ResolveTowerId(towerIndex)

    if not uniqueId then
        PushLog("出售失败: 找不到第 " .. tostring(towerIndex) .. " 座塔")
        return false
    end

    local success, failureMessage = RunInternal(function()
        return RemoteFunctions.RequestTowerSell:InvokeServer(uniqueId)
    end)

    if success and (failureMessage == nil or failureMessage == true) then
        return true
    end

    PushLog("出售失败: " .. tostring(failureMessage))

    return false
end

function UnifiedMacroApi:SetTarget(towerIndex, targetMode, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then
        return false
    end

    local uniqueId = State:ResolveTowerId(towerIndex)

    if not uniqueId then
        PushLog("切换优先级失败: 找不到第 " .. tostring(towerIndex) .. " 座塔")
        return false
    end

    local towerData = SharedTowerData:FindFirstChild(uniqueId)

    if not towerData then
        return false
    end

    if towerData:GetAttribute("Targetting") == targetMode then
        return true
    end

    for _ = 1, 6 do
        RunInternal(function()
            return RemoteFunctions.RequestTargettingChange:InvokeServer(uniqueId)
        end)

        local deadline = os.clock() + 0.5

        repeat
            RunService.Heartbeat:Wait()
        until towerData:GetAttribute("Targetting") == targetMode or os.clock() > deadline

        if towerData:GetAttribute("Targetting") == targetMode then
            return true
        end
    end

    PushLog("切换优先级失败: " .. tostring(targetMode))

    return false
end

function UnifiedMacroApi:Ready(targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then
        return false
    end

    RunInternal(function()
        RemoteEvents.ReadyUp:FireServer()
    end)

    return true
end

function UnifiedMacroApi:Skip(targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then
        return false
    end

    State.autoSkipVote = true

    return true
end

function UnifiedMacroApi:Speed(speedValue, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then
        return false
    end

    RunInternal(function()
        RemoteEvents.SpeedToggle:FireServer(speedValue)
    end)

    return true
end

function UnifiedMacroApi:Vote(difficultyName, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then
        return false
    end

    RunInternal(function()
        RemoteEvents.CastDifficultyVote:FireServer(difficultyName)
    end)

    return true
end

function UnifiedMacroApi:Rejoin()
    RunInternal(function()
        RemoteEvents.ResultsAction:FireServer("Rejoin")
    end)
end

function UnifiedMacroApi:Loop(body)
    State.macroRunning = true

    while State.running do
        self:Start()

        local success, runtimeError = pcall(body)

        if not success then
            PushLog("宏执行出错: " .. tostring(runtimeError))
        end

        if not State.loopEnabled then
            break
        end

        self:WaitForMatchEnd()

        if not State.running then
            break
        end

        task.wait(2)

        if not self:WaitForNextMatch() then
            break
        end

        task.wait(1)
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

function Recorder:FormatVector(position)
    return string.format("Vector3.new(%.3f, %.3f, %.3f)", position.X, position.Y, position.Z)
end

function Recorder:RecordPlacement(towerName, position, rotation)
    if typeof(position) ~= "Vector3" then
        return
    end

    table.insert(self.lines, string.format(
        "\tapi:Place(%q, %s, %s, %d, %d)",
        towerName,
        self:FormatVector(position),
        tostring(rotation or 0),
        math.floor(State:GetClock()),
        State:GetWave()
    ))

    if not table.find(self.towerNames, towerName) then
        table.insert(self.towerNames, towerName)
    end
end

function Recorder:HandlePlacement(towerName, position, rotation, uniqueId)
    State:RegisterTower(uniqueId)

    if not self.recording then
        return
    end

    self:RecordPlacement(towerName, position, rotation)
end

function Recorder:HandleUpgrade(uniqueId)
    if not self.recording then
        return
    end

    local towerIndex = State:IndexOfTower(uniqueId)

    if not towerIndex then
        PushLog("录制升级失败: 找不到对应塔序号")
        return
    end

    table.insert(self.lines, string.format("\tapi:Upgrade(%d, %d, %d)", towerIndex, math.floor(State:GetClock()), State:GetWave()))
end

function Recorder:HandleSell(uniqueId)
    if not self.recording then
        return
    end

    local towerIndex = State:IndexOfTower(uniqueId)

    if not towerIndex then
        PushLog("录制出售失败: 找不到对应塔序号")
        return
    end

    table.insert(self.lines, string.format("\tapi:Sell(%d, %d, %d)", towerIndex, math.floor(State:GetClock()), State:GetWave()))
end

function Recorder:HandleTargettingChange(uniqueId)
    if not self.recording then
        return
    end

    local towerIndex = State:IndexOfTower(uniqueId)

    if not towerIndex then
        return
    end

    task.spawn(function()
        local towerData = SharedTowerData:FindFirstChild(uniqueId)

        if not towerData then
            return
        end

        local startingMode = towerData:GetAttribute("Targetting")
        local deadline = os.clock() + 1

        repeat
            RunService.Heartbeat:Wait()
        until towerData:GetAttribute("Targetting") ~= startingMode or os.clock() > deadline

        local currentMode = towerData:GetAttribute("Targetting")

        if currentMode and currentMode ~= startingMode and self.recording then
            table.insert(self.lines, string.format(
                "\tapi:SetTarget(%d, %q, %d, %d)",
                towerIndex,
                currentMode,
                math.floor(State:GetClock()),
                State:GetWave()
            ))
        end
    end)
end

function Recorder:HandleReady()
    if not self.recording then
        return
    end

    table.insert(self.lines, string.format("\tapi:Ready(%d, %d)", math.floor(State:GetClock()), State:GetWave()))
end

function Recorder:HandleSpeed(speedValue)
    if not self.recording then
        return
    end

    table.insert(self.lines, string.format("\tapi:Speed(%s, %d, %d)", tostring(speedValue), math.floor(State:GetClock()), State:GetWave()))
end

function Recorder:HandleVote(difficultyName)
    if not self.recording then
        return
    end

    table.insert(self.lines, string.format("\tapi:Vote(%q, %d, %d)", tostring(difficultyName), math.floor(State:GetClock()), State:GetWave()))
end

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
    if not self.recording then
        return nil
    end

    self.recording = false

    local loadoutEntries = {}

    for _, towerName in ipairs(self.towerNames) do
        table.insert(loadoutEntries, string.format("%q", towerName))
    end

    local mapName = tostring(workspace:GetAttribute("Map") or "未知")
    local difficultyName = tostring(workspace:GetAttribute("Difficulty") or "未知")

    local outputLines = {
        "local api = getgenv().UnifiedMacroApi",
        "if not api then return end",
        "",
        "api:Loadout({" .. table.concat(loadoutEntries, ", ") .. "})",
        string.format("api:Map(%q, %q)", mapName, difficultyName),
        "",
        "api:Start()",
        "",
        "api:Loop(function()",
    }

    for _, line in ipairs(self.lines) do
        table.insert(outputLines, line)
    end

    table.insert(outputLines, "end)")

    local path = MacroFolder .. "/" .. self.macroName .. ".txt"
    writefile(path, table.concat(outputLines, "\n"))
    PushLog("录制完成: " .. path .. " (" .. #self.lines .. " 条动作)")

    return path
end

local Runtime = {}

Runtime.IsInternalCall = function()
    return State.internalCallCount > 0
end

Runtime.HandleRemoteCall = function(calledRemote, invokedMethod, sourceArguments, result)
    if invokedMethod == "InvokeServer" then
        if calledRemote == RemoteFunctions.RequestPlacement then
            Recorder:HandlePlacement(sourceArguments[1], sourceArguments[2], sourceArguments[3], result)
        elseif calledRemote == RemoteFunctions.RequestTowerUpgrade then
            Recorder:HandleUpgrade(sourceArguments[1])
        elseif calledRemote == RemoteFunctions.RequestTowerSell then
            Recorder:HandleSell(sourceArguments[1])
        elseif calledRemote == RemoteFunctions.RequestTargettingChange then
            Recorder:HandleTargettingChange(sourceArguments[1])
        end
    elseif invokedMethod == "FireServer" then
        if calledRemote == RemoteEvents.ReadyUp then
            Recorder:HandleReady()
        elseif calledRemote == RemoteEvents.SpeedToggle then
            Recorder:HandleSpeed(sourceArguments[1])
        elseif calledRemote == RemoteEvents.CastDifficultyVote then
            Recorder:HandleVote(sourceArguments[1])
        end
    end
end

getgenv().UnifiedMacroRuntime = Runtime

if not getgenv().UnifiedMacroHookInstalled then
    local gameMetatable = getrawmetatable(game)
    local originalNamecall = gameMetatable.__namecall

    setreadonly(gameMetatable, false)
    gameMetatable.__namecall = newcclosure(function(self, ...)
        local runtime = getgenv().UnifiedMacroRuntime

        if not runtime or runtime.IsInternalCall() then
            return originalNamecall(self, ...)
        end

        local sourceArguments = table.pack(...)
        local result = originalNamecall(self, ...)

        pcall(runtime.HandleRemoteCall, self, getnamecallmethod(), sourceArguments, result)

        return result
    end)
    setreadonly(gameMetatable, true)

    getgenv().UnifiedMacroHookInstalled = true
end

local CoreGui = LocalPlayer.PlayerGui:WaitForChild("CoreGui", 30)
local SkipVoteFrame = CoreGui and CoreGui:FindFirstChild("SkipWaveFrame")

local function ShowSkipVoteFrame()
    if not SkipVoteFrame then
        return
    end

    TweenService:Create(
        SkipVoteFrame,
        TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        { GroupTransparency = 0 }
    ):Play()

    SkipVoteFrame.Visible = true
end

local function HideSkipVoteFrame()
    if not SkipVoteFrame then
        return
    end

    TweenService:Create(
        SkipVoteFrame,
        TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
        { GroupTransparency = 1 }
    ):Play()

    task.delay(0.5, function()
        if SkipVoteFrame then
            SkipVoteFrame.Visible = false
        end
    end)
end

local function UnifiedSkipVoteHandler()
    if State.autoSkipVote then
        return true
    end

    if not SkipVoteFrame then
        return false
    end

    local decision = nil
    local connections = {
        SkipVoteFrame.Agree.Activated:Connect(function()
            decision = true
        end),
        SkipVoteFrame.Decline.Activated:Connect(function()
            decision = false
        end),
    }

    ShowSkipVoteFrame()

    repeat
        task.wait()
    until decision ~= nil or not SkipVoteFrame.Visible

    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end

    if not decision then
        HideSkipVoteFrame()
    end

    return decision
end

RemoteFunctions.RequestSkipVote.OnClientInvoke = UnifiedSkipVoteHandler

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
    Name = "塔防统一宏",
    LoadingTitle = "塔防统一宏",
    LoadingSubtitle = "录制与回放",
    ConfigurationSaving = { Enabled = false },
    KeySystem = false,
})

local PlayTab = Window:CreateTab("宏播放", nil)
local RecordTab = Window:CreateTab("录制", nil)
local LogTab = Window:CreateTab("日志", nil)

local statusLabel = PlayTab:CreateLabel("状态: 初始化中")

PlayTab:CreateSection("宏文件")

local macroDropdown = PlayTab:CreateDropdown({
    Name = "选择宏",
    Options = { "暂无宏文件" },
    CurrentOption = { "暂无宏文件" },
    MultipleOptions = false,
    Callback = function(option)
        local selection = option

        if type(option) == "table" then
            selection = option[1]
        end

        State.selectedMacroName = selection
        PushLog("已选择宏: " .. tostring(selection))
    end,
})

local function RefreshMacroList()
    local macroFiles = ListMacroFiles()

    if #macroFiles == 0 then
        macroFiles = { "暂无宏文件" }
    end

    macroDropdown:Refresh(macroFiles)
end

PlayTab:CreateButton({
    Name = "刷新宏列表",
    Callback = function()
        RefreshMacroList()
        PushLog("宏列表已刷新")
    end,
})

PlayTab:CreateSection("播放控制")

PlayTab:CreateButton({
    Name = "播放选中的宏",
    Callback = function()
        if not State.selectedMacroName or State.selectedMacroName == "暂无宏文件" then
            PushLog("未选择宏文件")
            return
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

            if not success then
                PushLog("运行出错: " .. tostring(runtimeError))
            end
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
    CurrentValue = false,
    Flag = "AutoSkipVote",
    Callback = function(value)
        State.autoSkipVote = value
        PushLog("自动同意跳波: " .. (value and "开" or "关"))
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
            RefreshMacroList()
        else
            recordStatusLabel:Set("录制状态: 当前未在录制")
        end
    end,
})

LogTab:CreateSection("日志")
LogParagraph = LogTab:CreateParagraph({ Title = "最近日志", Content = "暂无日志" })

RefreshMacroList()

local monitorAccumulator = 0

RunService.Heartbeat:Connect(function(deltaTime)
    monitorAccumulator = monitorAccumulator + deltaTime

    if monitorAccumulator < 0.25 then
        return
    end

    monitorAccumulator = 0

    pcall(function()
        State:RefreshMatchOrigin()

        local phaseText = "大厅"

        if State:IsMatchOver() then
            phaseText = "结算中"
        elseif State:GetWave() >= 1 then
            phaseText = "战斗中"
        elseif workspace:GetAttribute("ReadyVoting") then
            phaseText = "准备阶段"
        end

        local totalWaveCount = tonumber(workspace:GetAttribute("WaveCount")) or 0

        statusLabel:Set(string.format(
            "状态: %s | 波次: %d/%d | 计时: %ds | 塔: %d | 录制: %s | 播放: %s",
            phaseText,
            State:GetWave(),
            totalWaveCount,
            math.floor(State:GetClock()),
            #State.placedTowerIds,
            Recorder.recording and "开" or "关",
            State.macroRunning and "运行中" or "空闲"
        ))
    end)
end)

PushLog("脚本已加载，共检测到 " .. #ListMacroFiles() .. " 个宏文件")
