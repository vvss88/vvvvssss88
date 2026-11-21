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

-- 缓存 GameConfig 里的 Wave / BaseHealth 引用，热路径不再反复 FindFirstChild
local WaveValueRef = GameConfig:FindFirstChild("Wave")
local BaseHealthValueRef = GameConfig:FindFirstChild("BaseHealth")
local function GetWaveRef()
    if not WaveValueRef then WaveValueRef = GameConfig:FindFirstChild("Wave") end
    return WaveValueRef
end
local function GetBaseHealthRef()
    if not BaseHealthValueRef then BaseHealthValueRef = GameConfig:FindFirstChild("BaseHealth") end
    return BaseHealthValueRef
end

local MacroFolder = "TWD_Macros"

if not isfolder(MacroFolder) then
    makefolder(MacroFolder)
end

local ConfigFile = MacroFolder .. "/twd_config.json"

-- 扫描间隔同时决定录制精度：同一轮扫到的多座塔原来共用一个时间戳，
-- 于是存下来的间隔永远是 0.25s 的整数倍（还可能是 0），这本身就是特征
local SCAN_INTERVAL = 0.12
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
    matchEndedAt = workspace:GetAttribute("MatchEndedAt"),
    ignoredMatchEndedAt = nil,
    fallbackClockOrigin = workspace:GetServerTimeNow(),
    previousMatchStartedAt = workspace:GetAttribute("MatchStartedAt"),
    autoStartedThisMatch = false,
    playbackActive = false,
    playbackGen = 0,
    upgradeRetryWindow = 6,
    autoPickupEnabled = false,
    antiMacroEnabled = false,
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

local function RoundTime(t)
    t = t or 0
    return math.floor(t * 100 + 0.5) / 100
end

-- ==========================================
-- 拟人化抖动（Humanize）
-- 原始回放命中目标时间后会在同一帧直接发请求，间隔恒等于录制值，
-- 服务端统计「相邻两次 RequestPlacement 的时间差」就能分辨人/宏。
-- 下面给每次请求加随机间隔 + 长尾犹豫，并把固定节拍改成随机节拍。
-- ==========================================
local Humanize = {
    gapMin = 0.09,          -- 两次放塔的最小间隔
    gapMax = 0.34,          -- 常规间隔上限
    hesitationChance = 0.07, -- 偶尔"手停一下"的概率
    hesitationMin = 0.35,
    hesitationMax = 1.15,
}

local lastPlaceAt = 0

-- 用平方把随机数压向短间隔：真人绝大多数操作很快、偶尔卡顿，
-- 严格的均匀分布本身就是个指纹
local function SkewedGap(minGap, maxGap)
    local t = math.random()
    return minGap + (maxGap - minGap) * t * t
end

function Humanize:Breathe()
    local gap = SkewedGap(self.gapMin, self.gapMax)
    if math.random() < self.hesitationChance then
        gap = gap + SkewedGap(self.hesitationMin, self.hesitationMax)
    end
    local waitFor = (lastPlaceAt + gap) - os.clock()
    if waitFor > 0 then
        task.wait(waitFor)
    end
    lastPlaceAt = os.clock()
end

-- 到达目标时间后再补 20~120ms 反应延迟，5% 概率多犹豫 150~450ms
local function ReactionDelay()
    local d = 0.02 + math.random() * 0.10
    if math.random() < 0.05 then
        d = d + 0.15 + math.random() * 0.30
    end
    return d
end

function State:GetWave()
    local waveValue = GetWaveRef()
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
    local matchEndedAt = self.matchEndedAt
    if typeof(matchEndedAt) == "number" and matchEndedAt ~= self.ignoredMatchEndedAt then
        return true
    end
    local baseHealth = GetBaseHealthRef()
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
    self.matchEndedAt = workspace:GetAttribute("MatchEndedAt")
    self.ignoredMatchEndedAt = self.matchEndedAt
end

function State:RefreshMatchOrigin()
    local matchStartedAt = workspace:GetAttribute("MatchStartedAt")
    -- 每轮扫描只读一次 MatchEndedAt，缓存供 IsMatchOver 复用，省掉重复 GetAttribute
    self.matchEndedAt = workspace:GetAttribute("MatchEndedAt")
    local changed = false
    if typeof(matchStartedAt) == "number" and matchStartedAt ~= self.previousMatchStartedAt then
        self.previousMatchStartedAt = matchStartedAt
        self.ignoredMatchEndedAt = self.matchEndedAt
        self.autoStartedThisMatch = false
        changed = true
    end
    return changed
end
local UnifiedMacroApi = {}
UnifiedMacroApi.deferred = {}
UnifiedMacroApi.pendingUpgrade = {}
UnifiedMacroApi.lateCount = 0
UnifiedMacroApi.maxLate = 0
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
    -- 上一轮的补放占位符已经没用了，不清会一直累积
    self.deferred = {}
    self.startTime = State:GetClock()
end

function UnifiedMacroApi:StopAll()
    State.running = false
    State.playbackGen = (State.playbackGen or 0) + 1
    State.macroRunning = false
end

function UnifiedMacroApi:WaitForTime(targetTime, targetWave)
    local startWait = os.clock()
    local hasTime = (targetTime or 0) > 0
    local hasWave = (targetWave or 0) > 0
    -- 波次属性刷新比时钟慢一点，纯等波次会把动作压住好几秒，给 1.5 秒宽容
    local WAVE_GRACE = 1.5
    while State.running do
        if State:IsMatchOver() then return false end
        local clock = State:GetClock()
        local clockOk = not hasTime or clock >= targetTime
        local waveOk = not hasWave or State:GetWave() >= targetWave
        if clockOk and waveOk then
            if hasTime and clock - targetTime > 0.35 then
                self.lateCount = (self.lateCount or 0) + 1
                self.maxLate = math.max(self.maxLate or 0, clock - targetTime)
                if not self.lastLateLog or os.clock() - self.lastLateLog > 3 then
                    self.lastLateLog = os.clock()
                    PushLog(string.format("动作迟到 %.2fs (目标 %.2fs / 实际 %.2fs)", clock - targetTime, targetTime, clock))
                end
            end
            return true
        end
        if hasTime and hasWave and clockOk and clock - targetTime > WAVE_GRACE then return true end
        if hasTime and clock >= targetTime + 10 then
            PushLog(string.format("动作严重迟到(10s+)，仍继续: time=%s", tostring(targetTime)))
            return true
        end
        if os.clock() - startWait > 300 then
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
function UnifiedMacroApi:NewDeferred(key)
    local token = "__pending_" .. tostring(key) .. "_" .. tostring(math.floor(os.clock() * 1000))
    self.deferred[token] = { id = nil, failed = false }
    return token
end

-- token 可能已经是真实 ID，也可能是等待补放的占位符
function UnifiedMacroApi:AwaitDeferred(token, timeout)
    local entry = self.deferred[token]
    if not entry then return token, false end
    local deadline = os.clock() + (timeout or 1)
    while State.running and not entry.id and not entry.failed and os.clock() < deadline do
        RunService.Heartbeat:Wait()
    end
    return entry.id, entry.failed
end

function UnifiedMacroApi:Place(towerName, position, rotation, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return nil end
    if not State.running then return nil end

    -- 抖一下再发包：反应延迟 + 与上一次放塔的最小随机间隔
    task.wait(ReactionDelay())
    if not State.running then return nil end
    Humanize:Breathe()
    if not State.running then return nil end

    local success, result = pcall(function()
        return RemoteFunctions.RequestPlacement:InvokeServer(
            towerName, position, rotation or 0, HttpService:GenerateGUID(false), workspace:GetServerTimeNow()
        )
    end)

    if success and typeof(result) == "string" then
        State:RegisterTower(result)
        return result
    end

    -- 失败不再原地死等（原来 3 次 × 1.5~3 秒会把整条时间线拖垮），挂到后台补放
    local token = self:NewDeferred(towerName)
    local entry = self.deferred[token]
    PushLog("放置失败, 后台补放: " .. tostring(towerName) .. " (" .. tostring(result) .. ")")
    task.spawn(function()
        for attempt = 1, 3 do
            task.wait(0.45 + math.random() * 0.7)
            if not State.running then entry.failed = true; return end
            if entry.id then return end
            local ok, res = pcall(function()
                return RemoteFunctions.RequestPlacement:InvokeServer(
                    towerName, position, rotation or 0, HttpService:GenerateGUID(false), workspace:GetServerTimeNow()
                )
            end)
            if ok and typeof(res) == "string" then
                entry.id = res
                State:RegisterTower(res)
                PushLog("补放成功(第" .. attempt .. "次): " .. tostring(towerName))
                return
            end
        end
        entry.failed = true
        PushLog("补放最终失败: " .. tostring(towerName))
    end)
    return token
end
function UnifiedMacroApi:GetTowerLevel(uniqueId)
    local tower = SharedTowerData:FindFirstChild(uniqueId)
    if not tower then return nil end
    return tonumber(tower:GetAttribute("Level"))
end

-- 升级失败绝大多数是「这一刻钱不够」。录制里有目标等级时，挂一个后台补升级：
-- 每 0.9 秒检查一次等级，没到就补按一次，达到目标或超窗就退出。
-- 之所以先查等级再按，是为了避免补按把塔顶到比录制更高的等级（白烧钱）。
function UnifiedMacroApi:ScheduleUpgradeRetry(uniqueId, targetLevel, key)
    local window = tonumber(State.upgradeRetryWindow) or 6
    if window <= 0 then return end
    if not State.running then return end

    -- 同一座塔只留一个补升级任务；后续失败的升级把目标等级抬高即可
    local pending = self.pendingUpgrade[uniqueId]
    if pending then
        if targetLevel > pending.target then
            pending.target = targetLevel
            pending.deadline = math.max(pending.deadline or 0, os.clock() + 2)
            PushLog(string.format("补升级目标提高到 %d 级: %s", targetLevel, tostring(key)))
        end
        return
    end

    local gen = State.playbackGen
    local entry = { target = targetLevel, deadline = os.clock() + window }
    self.pendingUpgrade[uniqueId] = entry
    PushLog(string.format("升级未达成, 后台补升级(%ds): %s → %d 级", window, tostring(key), targetLevel))

    task.spawn(function()
        local presses = 0
        while State.running and State.playbackGen == gen and os.clock() < entry.deadline do
            task.wait(0.7 + math.random() * 0.5)
            if not State.running or State.playbackGen ~= gen then break end
            local tower = SharedTowerData:FindFirstChild(uniqueId)
            if not tower then
                PushLog("补升级中止: 塔已不存在 " .. tostring(key))
                break
            end
            local level = tonumber(tower:GetAttribute("Level"))
            if level and level >= entry.target then
                PushLog(string.format("补升级到位: %s (%d 级, 补按 %d 次)", tostring(key), level, presses))
                break
            end
            if presses >= 8 then
                PushLog("补升级放弃(次数上限): " .. tostring(key))
                break
            end
            local ok, result = pcall(function()
                return RemoteFunctions.RequestTowerUpgrade:InvokeServer(uniqueId)
            end)
            if ok and result then presses = presses + 1 end
        end
        if self.pendingUpgrade[uniqueId] == entry then self.pendingUpgrade[uniqueId] = nil end
    end)
end

function UnifiedMacroApi:Upgrade(towerOrId, targetTime, targetWave, targetLevel)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = self:ResolveId(towerOrId)
    if not uniqueId then
        PushLog("升级失败: 找不到塔 " .. tostring(towerOrId))
        return false
    end

    -- 放置现在是立即返回的，塔可能还没复制过来，先等一小会
    local appearDeadline = os.clock() + 1.2
    while State.running and not SharedTowerData:FindFirstChild(uniqueId) and os.clock() < appearDeadline do
        RunService.Heartbeat:Wait()
    end
    if not SharedTowerData:FindFirstChild(uniqueId) then
        PushLog("升级失败: 塔已不存在 " .. tostring(towerOrId))
        return false
    end

    targetLevel = tonumber(targetLevel)

    -- 连升 4 级时原来正好每 100ms 按一次，间隔恒定同样是特征，这里也抖一下
    task.wait(ReactionDelay() * 0.7)
    if not State.running then return false end
    Humanize:Breathe()
    if not State.running then return false end

    local maxRetries = 2
    for attempt = 1, maxRetries do
        if not State.running then return false end

        local tower = SharedTowerData:FindFirstChild(uniqueId)
        if not tower then
            PushLog("升级失败: 塔已不存在 " .. tostring(towerOrId))
            return false
        end

        -- 已有目标等级时先看当前等级：已经到位就不再重复按（幂等，省一次钱）
        local level = tonumber(tower:GetAttribute("Level"))
        if targetLevel and level and level >= targetLevel then
            if attempt > 1 then PushLog("升级已到位(重试" .. attempt .. "次): 塔 " .. tostring(towerOrId)) end
            return true
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
            PushLog("升级失败(重试" .. maxRetries .. "次): 塔 " .. tostring(towerOrId) .. " (" .. tostring(failureMessage or upgraded) .. ")")
        else
            -- 原来是 1.5~3 秒死等，经济不够也一样白等，改成 0.28~0.48 秒随机快重试
            task.wait(0.28 + math.random() * 0.2)
        end
    end

    if targetLevel then
        self:ScheduleUpgradeRetry(uniqueId, targetLevel, towerOrId)
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
    local appearDeadline = os.clock() + 1.2
    while State.running and not SharedTowerData:FindFirstChild(uniqueId) and os.clock() < appearDeadline do
        RunService.Heartbeat:Wait()
    end
    if not SharedTowerData:FindFirstChild(uniqueId) then
        PushLog("出售失败: 塔已不存在 " .. tostring(towerOrId))
        return false
    end
    for attempt = 1, 2 do
        local success, failureMessage = pcall(function()
            return RemoteFunctions.RequestTowerSell:InvokeServer(uniqueId)
        end)
        if success and (failureMessage == nil or failureMessage == true) then return true end
        if attempt == 2 then
            PushLog("出售失败: " .. tostring(failureMessage))
        else
            task.wait(0.25)
        end
    end
    return false
end
function UnifiedMacroApi:SetTarget(towerOrId, targetMode, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return false end
    local uniqueId = self:ResolveId(towerOrId)
    if not uniqueId then
        PushLog("切换优先级失败: 找不到塔 " .. tostring(towerOrId))
        return false
    end
    local appearDeadline = os.clock() + 1.2
    while State.running and not SharedTowerData:FindFirstChild(uniqueId) and os.clock() < appearDeadline do
        RunService.Heartbeat:Wait()
    end
    local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
    if not towerConfig then
        PushLog("切换优先级失败: 塔已不存在 " .. tostring(towerOrId))
        return false
    end
    if towerConfig:GetAttribute("Targetting") == targetMode then return true end

    for _ = 1, 8 do
        pcall(function() RemoteFunctions.RequestTargettingChange:InvokeServer(uniqueId) end)
        local deadline = tick() + 0.12
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
    startWave = 0,
    startClock = 0,
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
        level = math.max(tonumber(towerLevel) or 1, 1),
        time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave()
    })

    if not table.find(self.towerNames, towerName) then
        table.insert(self.towerNames, towerName)
    end
    return true
end

function Recorder:RecordUpgrade(uniqueId, targetTime, targetLevel)
    local customName = self.idToName[uniqueId]
    if not customName then PushLog("录制升级丢失: 未找到别名 " .. tostring(uniqueId)); return false end
    table.insert(self.actions, {
        action = "Upgrade", target = customName,
        level = tonumber(targetLevel),
        time = RoundTime(targetTime or State:GetClock()), wave = State:GetWave()
    })
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

function Recorder:Start(macroName)
    if State.playbackActive then PushLog("回放还没完全停下，请稍等再开始录制"); return false end
    if State.macroRunning then PushLog("回放进行中，请先停止回放再开始录制"); return false end
    -- 重复点「开始录制」时不再静默清空，先把上一段保存掉
    if self.recording then
        local prevPath = self:Stop()
        if prevPath then PushLog("已有录制在进行，已先保存上一段: " .. prevPath) end
    end

    self.macroName = self:SanitizeName(macroName)
    self.actions = {}; self.towerNames = {}; self.nameCounters = {}; self.idToName = {}
    self.mapName = tostring(workspace:GetAttribute("Map") or "未知")
    self.difficultyName = tostring(workspace:GetAttribute("Difficulty") or "未知")
    self.startWave = State:GetWave()
    self.startClock = State:GetClock()
    self.recording = true

    State:ClearTowers()
    if TowerTracker then TowerTracker:Reset(self.startWave) end

    local initSpeed = tonumber(workspace:GetAttribute("GameSpeed")) or 1
    self:RecordSpeed(initSpeed)
    if TowerTracker then TowerTracker.gameSpeed = initSpeed end

    if State:IsMatchOver() then
        PushLog("提示: 当前不在对局中，建议开赛后再开始录制")
    elseif self.startWave > 1 then
        PushLog("提示: 从第 " .. self.startWave .. " 波开始录制，之前的塔不会被记录")
    end
    PushLog("开始录制: " .. self.macroName)
    return true
end

function Recorder:Discard()
    if not self.recording then return false end
    self.recording = false
    local count = #self.actions
    self.actions = {}
    self.lastRecordedWave = 0
    PushLog("已放弃本次录制，丢弃 " .. count .. " 条动作")
    return true
end

local function NextAvailablePath(baseName)
    if not isfile then return MacroFolder .. "/" .. baseName .. ".json", baseName end
    local function taken(name)
        local hit = false
        pcall(function() hit = isfile(MacroFolder .. "/" .. name .. ".json") end)
        return hit
    end
    if not taken(baseName) then return MacroFolder .. "/" .. baseName .. ".json", baseName end
    for i = 2, 99 do
        local candidate = baseName .. "_" .. i
        if not taken(candidate) then return MacroFolder .. "/" .. candidate .. ".json", candidate end
    end
    -- 99 个重名之后不再回退到原文件名（那会静默覆盖已有录制），改用时间戳继续找
    local stamp = tostring(os.time())
    local candidate = baseName .. "_" .. stamp
    while taken(candidate) do
        candidate = baseName .. "_" .. stamp .. "_" .. tostring(math.random(1000, 9999))
    end
    return MacroFolder .. "/" .. candidate .. ".json", candidate
end

function Recorder:Stop()
    if not self.recording then return nil end
    self.recording = false

    local currentWave = State:GetWave()
    if currentWave > (self.lastRecordedWave or 0) then
        self:RecordWave(currentWave)
    end

    if #self.actions == 0 then
        PushLog("录制结束但没有任何动作，未生成文件")
        return nil
    end

    -- 不做时间归零：存开赛后的绝对时间，回放直接和服务器时钟对齐。
    -- （老版本就是这么工作的，归零会让第一波的动作变成 time=0 而被波次卡住）
    local offset = 0

    -- 按时间稳定排序：同一次扫描里补写的未来时间戳会把顺序打乱
    local indexed = {}
    for index, act in ipairs(self.actions) do
        indexed[index] = { index = index, act = act }
    end
    table.sort(indexed, function(a, b)
        local ta, tb = a.act.time or 0, b.act.time or 0
        if ta == tb then return a.index < b.index end
        return ta < tb
    end)
    local sortedActions = {}
    for index, item in ipairs(indexed) do sortedActions[index] = item.act end
    self.actions = sortedActions

    local nowMap = tostring(workspace:GetAttribute("Map") or "未知")
    if nowMap ~= (self.mapName or "未知") then
        PushLog("注意: 录制中地图从 " .. tostring(self.mapName) .. " 变成了 " .. nowMap)
    end

    local saveData = {
        schema = 2,
        map = self.mapName or "未知",
        difficulty = self.difficultyName or "未知",
        recordedStartWave = self.startWave or 0,
        recordedStartClock = RoundTime(self.startClock or 0),
        timeOffset = RoundTime(offset),
        loadout = self.towerNames,
        actions = self.actions,
    }

    local path, finalName = NextAvailablePath(self.macroName)
    if finalName ~= self.macroName then
        PushLog("同名文件已存在，改存为: " .. finalName)
        self.macroName = finalName
    end

    local success, jsonString = pcall(function() return HttpService:JSONEncode(saveData) end)
    if not success then PushLog("JSON生成失败: " .. tostring(jsonString)); return nil end

    local writeSuccess, writeError = pcall(function() writefile(path, jsonString) end)
    if not writeSuccess then PushLog("保存失败: " .. tostring(writeError)); return nil end
    PushLog(string.format("录制完成(JSON): %s (%d 条动作)", path, #self.actions))
    return path
end
-- 这两个是本脚本自己的配置文件，之前被当成宏列出来，还会被自动选中播放
local CONFIG_FILE_NAMES = { ["twd_config.json"] = true, ["twd_autovote_config.json"] = true }

local function ListMacroFiles()
    local macroFiles = {}
    local success, files = pcall(function() return listfiles(MacroFolder) end)
    if not success or not files then return macroFiles end
    for _, path in ipairs(files) do
        if path:sub(-4) == ".txt" or path:sub(-5) == ".json" then
            local fileName = path:match("([^\\/]+)$") or path
            if not CONFIG_FILE_NAMES[fileName] then
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
    -- 同一轮扫到的多座塔不能共用一个时间戳，否则存档里会出现 0 间隔的连放
    local newTowerCount = 0

    for uniqueId, tower in pairs(snapshot) do
        local previousTower = previousSnapshot[uniqueId]
        if not previousTower then
            State:RegisterTower(uniqueId)
            if self:IsRecordingActive() then
                local placeTime = now + newTowerCount * (0.06 + math.random() * 0.09)
                local success = Recorder:RecordPlacement(uniqueId, tower.towerName, tower.cframe, tower.level, placeTime)
                if success then
                    newTowerCount = newTowerCount + 1
                    self.failedPlacementLog[uniqueId] = nil
                    local currentLevel = math.max(tower.level or 0, 1)
                    local step = 0
                    for lvl = 2, currentLevel do Recorder:RecordUpgrade(uniqueId, placeTime + step * 0.1, lvl); step = step + 1 end
                    if tower.targetting then Recorder:RecordTargetting(uniqueId, tower.targetting, placeTime + step * 0.1) end
                    self.knownTowers[uniqueId] = tower
                else
                    local lastLog = self.failedPlacementLog[uniqueId]
                    if not lastLog or now - lastLog > 2 then self.failedPlacementLog[uniqueId] = now; PushLog("塔放置数据未就绪，下一轮重试...") end
                end
            else
                self.knownTowers[uniqueId] = tower
            end
        else
            if (tower.level or 0) > (previousTower.level or 0) then
                local step = 0
                -- 从 2 级起算：塔刚放下就是 1 级，属性短暂为 0 时不会多按一次
                for lvl = math.max(2, (previousTower.level or 0) + 1), tower.level do
                    if self:IsRecordingActive() then Recorder:RecordUpgrade(uniqueId, now + step * 0.1, lvl) end
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

function TowerTracker:Reset(baseWave)
    self.knownTowers = {}; self.readyVotes = nil; self.gameSpeed = nil; self.difficulty = nil; self.failedPlacementLog = {}
    -- 从 startWave 起算，避免中途开录时把前面所有波次一次性补成 WaitWave
    if Recorder then Recorder.lastRecordedWave = baseWave or 0 end
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
    local data = { selectedMacroName = State.selectedMacroName, loopEnabled = State.loopEnabled, autoSkipVote = State.autoSkipVote, autoRejoinEnabled = State.autoRejoinEnabled, recordName = State.recordName, upgradeRetryWindow = State.upgradeRetryWindow, autoPickupEnabled = State.autoPickupEnabled, antiMacroEnabled = State.antiMacroEnabled }
    local success, jsonStr = pcall(HttpService.JSONEncode, HttpService, data)
    if success then pcall(writefile, ConfigFile, jsonStr) end
end

local SavedConfig = LoadConfig()
if SavedConfig.loopEnabled ~= nil then State.loopEnabled = SavedConfig.loopEnabled end
if SavedConfig.autoSkipVote ~= nil then State.autoSkipVote = SavedConfig.autoSkipVote end
if SavedConfig.autoRejoinEnabled ~= nil then State.autoRejoinEnabled = SavedConfig.autoRejoinEnabled end
if SavedConfig.autoPickupEnabled ~= nil then State.autoPickupEnabled = SavedConfig.autoPickupEnabled end
if SavedConfig.antiMacroEnabled ~= nil then State.antiMacroEnabled = SavedConfig.antiMacroEnabled end
if SavedConfig.recordName then State.recordName = SavedConfig.recordName end
if SavedConfig.selectedMacroName then State.selectedMacroName = SavedConfig.selectedMacroName end
if tonumber(SavedConfig.upgradeRetryWindow) then
    State.upgradeRetryWindow = math.max(0, math.min(12, tonumber(SavedConfig.upgradeRetryWindow)))
end
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

    local selected = State.selectedMacroName
    -- 选中的宏还在：保持原选择，不要被列表顺序带着走
    if selected and table.find(macroFiles, selected) then
        macroDropdown:Set({ selected })
        return
    end
    -- 还没有有效选择（首次使用 / 之前就是占位符）：默认选第一个
    if (not selected or selected == "暂无宏文件") and macroFiles[1] ~= "暂无宏文件" then
        State.selectedMacroName = macroFiles[1]
        macroDropdown:Set({ macroFiles[1] })
        return
    end
    if selected and selected ~= "暂无宏文件" then
        PushLog("找不到已选的宏: " .. tostring(selected) .. "，请重新选择")
    end
end

PlayTab:CreateButton({ Name = "刷新宏列表", Callback = function() RefreshMacroList(); PushLog("宏列表已刷新") end })
PlayTab:CreateSection("播放控制")

local function StartMacroPlayback()
    if State.manualStartInProgress then return end
    State.manualStartInProgress = true
    task.delay(1, function() State.manualStartInProgress = false end)

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
        if not decodeSuccess or type(data) ~= "table" then PushLog("解析 JSON 失败"); return end
        -- 配置文件或空文件也会以 .json 存在，别把它当宏播，否则回放状态会一直挂着
        if type(data.actions) ~= "table" or #data.actions == 0 then
            PushLog("不是有效的宏文件（没有动作数据）: " .. tostring(State.selectedMacroName))
            return
        end

        if data.map and data.map ~= "未知" then
            local currentMap = tostring(workspace:GetAttribute("Map") or "未知")
            if currentMap ~= data.map then
                PushLog("警告: 宏录制于地图 " .. tostring(data.map) .. "，当前是 " .. currentMap .. "，回放可能不可用")
            end
        end
        if (tonumber(data.recordedStartWave) or 0) > 1 then
            PushLog("警告: 该宏从第 " .. data.recordedStartWave .. " 波开始录制，前面阶段缺失")
        end
        if data.schema == nil then
            PushLog("提示: 旧版宏文件按原绝对时间回放")
        end
        -- 兼容之前那版“把时间归零”录的宏：把偏移加回去，恢复成绝对时间
        local timeShift = tonumber(data.timeOffset) or 0
        if timeShift > 0.01 then
            for _, act in ipairs(data.actions) do
                if type(act.time) == "number" then act.time = act.time + timeShift end
            end
            PushLog(string.format("检测到归零过的旧宏，时间整体加回 %.2fs 再回放", timeShift))
        end

        State.playbackGen = (State.playbackGen or 0) + 1
        local myGen = State.playbackGen
        State.playbackActive = true
        State.autoStartedThisMatch = true
        task.spawn(function()
            -- 整个回放体包在 pcall 里：动作数据异常时也要复位状态，不能卡在“回放中”
            local ok, runtimeError = pcall(function()
                local api = getgenv().UnifiedMacroApi
                State.macroRunning = true
                if type(data.loadout) == "table" and #data.loadout > 0 then PushLog("宏 loadout: " .. table.concat(data.loadout, ", ")) end
                if data.map then PushLog("宏地图: " .. tostring(data.map) .. " / " .. tostring(data.difficulty or "?")) end

                while State.running and State.playbackGen == myGen do
                    api:Loadout(data.loadout or {})
                    api:Map(data.map or "未知", data.difficulty or "未知")
                    api:Start()
                    api.lateCount = 0; api.maxLate = 0
                    api.pendingUpgrade = {}

                    local firstTime = (data.actions and data.actions[1] and data.actions[1].time) or 0
                    local startClock = State:GetClock()
                    if startClock > firstTime + 1.2 then
                        PushLog(string.format("回放起点偏晚: 当前 %.1fs / 首个动作 %.1fs, 落后 %.1fs", startClock, firstTime, startClock - firstTime))
                    end

                    local playbackMap = {}
                    local failedTargets = {}

                    local lastFireAt = 0
                    for _, act in ipairs(data.actions or {}) do
                        if not State.running or State.playbackGen ~= myGen then break end
                        -- 追赶时也不在同一帧连发，给服务器与资金结算留一点间隔
                        if (act.time or 0) > 0 and State:GetClock() - act.time > 1 then
                            if os.clock() - lastFireAt < 0.04 then task.wait(0.04) end
                        end
                        lastFireAt = os.clock()
                        if act.action == "Place" then
                            -- 旧宏或手改文件可能缺坐标/别名，跳过这一条，别让整个回放线程崩掉
                            if type(act.pos) ~= "table" or type(act.towerName) ~= "string" or not act.name then
                                PushLog("跳过放置: 动作数据不完整")
                            else
                                local pos = Vector3.new(tonumber(act.pos.x) or 0, tonumber(act.pos.y) or 0, tonumber(act.pos.z) or 0)
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
                            end
                        elseif act.action == "Upgrade" then
                            local ref = playbackMap[act.target]
                            if ref then
                                local uid, dfail = api:AwaitDeferred(ref, 1.0)
                                if uid then api:Upgrade(uid, act.time, act.wave, act.level) else PushLog("跳过升级: 塔未就绪 " .. tostring(act.target) .. (dfail and "(补放失败)" or "")) end
                            elseif failedTargets[act.target] then PushLog("跳过升级: 前置放置失败 " .. tostring(act.target)) end
                        elseif act.action == "Sell" then
                            local ref = playbackMap[act.target]
                            if ref then
                                local uid, dfail = api:AwaitDeferred(ref, 1.0)
                                if uid then api:Sell(uid, act.time, act.wave) else PushLog("跳过出售: 塔未就绪 " .. tostring(act.target) .. (dfail and "(补放失败)" or "")) end
                            elseif failedTargets[act.target] then PushLog("跳过出售: 前置放置失败 " .. tostring(act.target)) end
                        elseif act.action == "SetTarget" then
                            local ref = playbackMap[act.target]
                            if ref then
                                local uid, dfail = api:AwaitDeferred(ref, 1.0)
                                if uid then api:SetTarget(uid, act.targetMode, act.time, act.wave) else PushLog("跳过切换优先级: 塔未就绪 " .. tostring(act.target) .. (dfail and "(补放失败)" or "")) end
                            elseif failedTargets[act.target] then PushLog("跳过切换优先级: 前置放置失败 " .. tostring(act.target)) end
                        elseif act.action == "WaitWave" then api:WaitWave(act.wave, 0, act.wave)
                        elseif act.action == "Ready" then api:Ready(act.time, act.wave)
                        elseif act.action == "Speed" then api:Speed(act.speedValue, act.time, act.wave)
                        elseif act.action == "Vote" then api:Vote(act.difficultyName, act.time, act.wave) end
                    end

                    if not State.loopEnabled then break end
                    api:WaitForMatchEnd()
                    if not State.running or State.playbackGen ~= myGen then break end
                    task.wait(2)
                    if not api:WaitForNextMatch() then break end
                    task.wait(1)
                end
            end)
            -- 正常结束或中途报错都在这里复位，避免一直卡在“回放运行中”
            if State.playbackGen == myGen then
                State.playbackActive = false
                State.macroRunning = false
            end
            if not ok then PushLog("回放异常终止: " .. tostring(runtimeError)) end
        end)
        PushLog("开始播放 (JSON): " .. State.selectedMacroName)
    else
        local chunk, compileError = loadstring(source)
        if not chunk then PushLog("编译失败: " .. tostring(compileError)); return end
        State.autoStartedThisMatch = true
        task.spawn(function() local success, runtimeError = pcall(chunk); if not success then PushLog("运行出错: " .. tostring(runtimeError)) end end)
        PushLog("开始播放 (TXT): " .. State.selectedMacroName .. " —— 注意: TXT 宏无法中途停止，建议改用 JSON 录制")
    end
end

PlayTab:CreateButton({ Name = "播放选中的宏", Callback = StartMacroPlayback })
PlayTab:CreateButton({ Name = "停止播放", Callback = function()
    State.running = false
    State.playbackGen = (State.playbackGen or 0) + 1
    local stopGen = State.playbackGen
    PushLog("已请求停止播放（等当前动作收尾）")
    task.delay(3, function()
        if State.playbackActive and State.playbackGen == stopGen then
            State.playbackActive = false
            State.macroRunning = false
            PushLog("停止超时，已强制清理回放状态")
        end
    end)
end })

PlayTab:CreateToggle({ Name = "循环执行", CurrentValue = State.loopEnabled, Flag = "LoopEnabled", Callback = function(value) State.loopEnabled = value; PushLog("循环执行: " .. (value and "开" or "关")); SaveConfig() end })
PlayTab:CreateToggle({ Name = "自动同意跳波投票", CurrentValue = State.autoSkipVote, Flag = "AutoSkipVote", Callback = function(value) State.autoSkipVote = value; PushLog("自动同意跳波: " .. (value and "开" or "关")); SaveConfig() end })
PlayTab:CreateToggle({ Name = "自动重连 (防卡结算)", CurrentValue = State.autoRejoinEnabled, Flag = "AutoRejoinEnabled", Callback = function(value) State.autoRejoinEnabled = value; PushLog("自动重连: " .. (value and "开" or "关")); SaveConfig() end })

do
    local sliderOk = pcall(function()
        PlayTab:CreateSlider({
            Name = "升级补升窗口", Range = { 0, 12 }, Increment = 1, Suffix = " 秒",
            CurrentValue = State.upgradeRetryWindow or 6,
            Callback = function(value)
                State.upgradeRetryWindow = tonumber(value) or 6
                SaveConfig()
            end,
        })
    end)
    if not sliderOk then PushLog("滑块创建失败，升级补升窗口固定为 6 秒") end
end

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

-- ==========================================
-- 辅助功能：自动拾取 + 自动反宏（开关控制）
-- ==========================================
do
    local AssistTab = Window:CreateTab("辅助功能", nil)

    -- ---------- 自动拾取 ----------
    local teleportDelay = 0.6 -- 必须大于 0.5 秒，因为源码要求停留 0.5 秒才会自动发包

    task.spawn(function()
        -- 等待客户端生成掉落物文件夹
        local itemDropsFolder = workspace:WaitForChild("ItemDrops")

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

        while true do
            task.wait(0.1) -- 基础循环间隔，防止卡死
            if not State.autoPickupEnabled then continue end

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

                -- 核心：停在这里等待 0.6 秒，游戏自带 ItemDrops_CLIENT 会自动发包
                task.wait(teleportDelay)
            end
        end
    end)

    -- ---------- 自动反宏 ----------
    task.spawn(function()
        local AntiMacro = RemoteEvents:WaitForChild("AntiMacro")

        local function ClickButton(btn)
            if not btn then return false end
            -- 方案1：使用 getconnections 触发底层回调（最稳）
            if getconnections then
                local ok, conns = pcall(getconnections, btn.Activated)
                if ok and conns and #conns > 0 then
                    for _, c in ipairs(conns) do
                        pcall(function() c:Fire() end)
                    end
                    return true
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

        while task.wait(0.5) do
            if not State.antiMacroEnabled then continue end
            local gui = LocalPlayer:FindFirstChild("PlayerGui")
                and LocalPlayer.PlayerGui:FindFirstChild("AntiMacro")
            if not gui then continue end

            -- ---------- 先扫描：答题面板是否存在 ----------
            local hasQuizPanel = false
            local targetNum = nil
            local optionBtns = {}

            for _, obj in ipairs(gui:GetDescendants()) do
                -- 目标数字：TextSize == 36 的 TextLabel
                if obj:IsA("TextLabel") and obj.TextSize == 36 then
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
                    end
                end
            end

            -- ---------- 分支 A：有答题面板 → 只答题，绝不碰 banner ----------
            if hasQuizPanel then
                if targetNum and #optionBtns > 0 then
                    for _, item in ipairs(optionBtns) do
                        if item.value == targetNum then
                            print("[轮询] 匹配成功 目标=" .. targetNum .. "，尝试点击...")
                            local success = ClickButton(item.button)
                            if success then
                                print("  -> 点击指令已发送")
                            else
                                print("  -> 点击失败，执行器不支持底层触发")
                            end
                            task.wait(2)   -- 等原脚本发 Answer + 服务器回包
                            break
                        end
                    end
                end
            -- ---------- 分支 B：没有答题面板 → 才处理 PausedBanner ----------
            else
                local banner = gui:FindFirstChild("PausedBanner")
                if banner and banner.Visible then
                    local btn = banner:FindFirstChildOfClass("TextButton")
                    if btn then
                        print("[轮询] 点击 PausedBanner")
                        ClickButton(btn)
                        task.wait(1)
                    end
                end
            end
        end
    end)

    -- ---------- 开关 ----------
    AssistTab:CreateSection("辅助功能")
    AssistTab:CreateToggle({ Name = "自动拾取", CurrentValue = State.autoPickupEnabled, Flag = "AutoPickup", Callback = function(value) State.autoPickupEnabled = value; PushLog("自动拾取: " .. (value and "开" or "关")); SaveConfig() end })
    AssistTab:CreateToggle({ Name = "自动反反宏", CurrentValue = State.antiMacroEnabled, Flag = "AntiMacro", Callback = function(value) State.antiMacroEnabled = value; PushLog("自动反反宏: " .. (value and "开" or "关")); SaveConfig() end })
end
RecordTab:CreateSection("录制设置")
local recordNameLabel = RecordTab:CreateLabel("当前宏名称: " .. State.recordName)
local recordStatusLabel = RecordTab:CreateLabel("录制状态: 未开始")
RecordTab:CreateInput({ Name = "宏名称", CurrentValue = State.recordName, PlaceholderText = "输入宏名称后回车", RemoveTextAfterFocusLost = false, Callback = function(text) if text and text ~= "" then State.recordName = text; recordNameLabel:Set("当前宏名称: " .. text); SaveConfig() end end })
RecordTab:CreateButton({ Name = "开始录制", Callback = function() if Recorder:Start(State.recordName or "未命名") then recordStatusLabel:Set("录制状态: 录制中 (" .. Recorder.macroName .. ")") else recordStatusLabel:Set("录制状态: 启动失败") end end })
RecordTab:CreateButton({ Name = "停止录制并保存", Callback = function() local savedPath = Recorder:Stop(); if savedPath then recordStatusLabel:Set("录制状态: 已保存 " .. savedPath); RefreshMacroList(); local fileName = savedPath:match("([^\\/]+)$"); if fileName then State.selectedMacroName = fileName; macroDropdown:Set({ fileName }); SaveConfig() end else recordStatusLabel:Set("录制状态: 保存失败或未在录制") end end })
RecordTab:CreateButton({ Name = "放弃当前录制", Callback = function() if Recorder:Discard() then recordStatusLabel:Set("录制状态: 已放弃") else recordStatusLabel:Set("录制状态: 当前没有在录制") end end })

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

local prevMatchOver = State:IsMatchOver()

local function AutoSaveRecording(reason)
    if not Recorder.recording then return end
    local savedPath = Recorder:Stop()
    if savedPath then
        recordStatusLabel:Set("录制状态: " .. reason .. "，已保存 " .. savedPath)
        RefreshMacroList()
        local fileName = savedPath:match("([^\\/]+)$")
        if fileName then State.selectedMacroName = fileName; macroDropdown:Set({ fileName }); SaveConfig() end
        PushLog(reason .. "，已自动停止录制并保存: " .. savedPath)
    else
        recordStatusLabel:Set("录制状态: 自动保存失败")
    end
end

local monitorAccumulator = 0
local lastMonitorErrorAt = 0
getgenv().UnifiedMacroHeartbeat = RunService.Heartbeat:Connect(function(deltaTime)
    monitorAccumulator = monitorAccumulator + deltaTime
    if monitorAccumulator < SCAN_INTERVAL then return end
    monitorAccumulator = 0
    local monitorOk, monitorError = pcall(function()
        -- 对局结束就立刻收尾保存，不再等下一局开始（那样会把新局的波次写进旧录制）
        local matchOverNow = State:IsMatchOver()
        if matchOverNow and not prevMatchOver then
            AutoSaveRecording("对局结束")
        end
        prevMatchOver = matchOverNow

        if State:RefreshMatchOrigin() then
            if Recorder.recording then
                if #Recorder.actions <= 2 then
                    Recorder:Discard()
                    recordStatusLabel:Set("录制状态: 对局刚开始，请重新开始录制")
                    PushLog("检测到新局开始，已丢弃大厅阶段的空白录制")
                else
                    AutoSaveRecording("检测到新局")
                end
            end
            TowerTracker:Reset(); State:ClearTowers()
            prevMatchOver = State:IsMatchOver()
        end
        -- 塔扫描只在录制时需要，回放/挂机直接跳过，省掉每轮全量快照与 diff
        if Recorder.recording then
            TowerTracker:ScanEnvironment()
            TowerTracker:ScanTowers()
        end
        AutoAgreeSkipVote()

        if State:GetWave() >= 1 and not State.macroRunning and not State.autoStartedThisMatch and not State.manualStartInProgress and State.loopEnabled and State.selectedMacroName and State.selectedMacroName ~= "暂无宏文件" then
            State.autoStartedThisMatch = true
            task.spawn(function() task.wait(0.2); if State:GetWave() >= 1 and not State.macroRunning then StartMacroPlayback() end end)
        end

        local phaseText = "大厅"
        if State:IsMatchOver() then phaseText = "结算中"
        elseif State:GetWave() >= 1 then phaseText = "战斗中"
        elseif State:IsReadyVoting() then phaseText = "准备阶段" end
        local totalWaveCount = tonumber(workspace:GetAttribute("WaveCount")) or 0

        local apiRef = getgenv().UnifiedMacroApi
        local lateText = "无"
        if apiRef and (apiRef.lateCount or 0) > 0 then
            lateText = string.format("%d次/最大%.1fs", apiRef.lateCount, apiRef.maxLate or 0)
        end
        statusLabel:Set(string.format("状态: %s | 波次: %d/%d | 计时: %ds | 塔: %d | 录制: %s | 播放: %s | 迟到: %s", phaseText, State:GetWave(), totalWaveCount, math.floor(State:GetClock()), #State.placedTowerIds, Recorder.recording and "开" or "关", State.macroRunning and "运行中" or "空闲", lateText))
    end)
    if not monitorOk then
        -- 以前这里静默吞错，出问题完全看不出来；限流写进日志
        local nowClock = os.clock()
        if nowClock - lastMonitorErrorAt > 5 then
            lastMonitorErrorAt = nowClock
            pcall(PushLog, "监控出错: " .. tostring(monitorError))
        end
    end
end)

PushLog("脚本已加载，共检测到 " .. #ListMacroFiles() .. " 个宏文件（无任何 hook）")