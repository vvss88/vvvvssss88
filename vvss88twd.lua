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

local SCAN_INTERVAL = 0.25

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

local function RoundTime(t)
    t = t or 0
    return math.floor(t * 100 + 0.5) / 100
end

local function RoundCoord(value)
    return math.floor(value * 1000 + 0.5) / 1000
end

-- 同一条时间线上的动作排序：时间优先；同一时间先卖后放，避免塔位被占满
local ACTION_SORT_PRIORITY = { Sell = 1, Place = 2, Upgrade = 3, SetTarget = 4 }

local function SortMacroActions(actions)
    if type(actions) ~= "table" then return end
    local order = {}
    for index, action in ipairs(actions) do
        order[action] = index
    end
    table.sort(actions, function(a, b)
        local timeA = tonumber(a.time)
        local timeB = tonumber(b.time)
        if timeA and timeB and timeA ~= timeB then
            return timeA < timeB
        end
        local priorityA = ACTION_SORT_PRIORITY[a.action] or 9
        local priorityB = ACTION_SORT_PRIORITY[b.action] or 9
        if priorityA ~= priorityB then
            return priorityA < priorityB
        end
        return (order[a] or 0) < (order[b] or 0)
    end)
end

local function CreatePlaybackReport(macroLabel)
    return {
        macroLabel = tostring(macroLabel or "未命名"),
        startedAt = DateTime.now():FormatLocalTime("YYYY-MM-DD HH:mm:ss", "zh-cn"),
        map = tostring(workspace:GetAttribute("Map") or "未知"),
        difficulty = tostring(workspace:GetAttribute("Difficulty") or "未知"),
        total = 0,
        succeeded = 0,
        lines = {},
    }
end

local function AddPlaybackReportEntry(report, index, action, actualTime, elapsed, ok, detail)
    report.total = report.total + 1
    if ok then report.succeeded = report.succeeded + 1 end
    table.insert(report.lines, string.format(
        "%3d  %-9s 计划%7.2fs 实际%7.2fs 耗时%6.2fs  %s  %s",
        index,
        tostring(action.action or "?"),
        tonumber(action.time) or 0,
        actualTime,
        elapsed,
        ok and "成功" or "失败",
        tostring(detail or "")
    ))
end

local function SavePlaybackReport(report)
    local safeName = Recorder:SanitizeName(report.macroLabel or "宏")
    local stamp = DateTime.now():FormatLocalTime("YYYYMMDD_HHmmss", "zh-cn")
    local path = string.format("%s/report_%s_%s.txt", MacroFolder, safeName, stamp)
    local header = {
        "# 回放报告",
        "宏文件: " .. report.macroLabel,
        "开始时间: " .. report.startedAt,
        "地图/难度: " .. report.map .. " / " .. report.difficulty,
        string.format("动作: 共 %d 条, 成功 %d, 失败 %d", report.total, report.succeeded, report.total - report.succeeded),
        "",
    }
    local content = table.concat(header, "\n") .. "\n" .. table.concat(report.lines, "\n")
    local ok, writeError = pcall(writefile, path, content)
    if not ok then
        PushLog("回放报告写入失败: " .. tostring(writeError))
        return nil
    end
    return path
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

function UnifiedMacroApi:Start()
    State.running = true
    State:ResetMatchTracking()
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

local MONEY_HINTS = { "money", "gold", "cash", "coins", "insufficient", "not enough", "fund" }
local FAILURE_HINTS = {
    "money", "gold", "cash", "coins", "insufficient", "not enough", "fund",
    "fail", "invalid", "error", "denied", "cooldown", "limit", "occupied", "blocked",
    "失败", "不足", "不能",
}

local function ContainsAnyHint(text, hints)
    text = tostring(text or ""):lower()
    if text == "" then return false end
    for _, hint in ipairs(hints) do
        if text:find(hint, 1, true) then return true end
    end
    return false
end

local function LooksLikeMoneyError(message)
    return ContainsAnyHint(message, MONEY_HINTS)
end

-- 服务端返回的"塔 ID"和"失败提示"都是字符串，这里按常见错误词 + 空格/长度粗判
local function LooksLikeFailureMessage(value)
    if typeof(value) ~= "string" then return true end
    if value:find("%s") then return true end
    if #value > 64 then return true end
    return ContainsAnyHint(value, FAILURE_HINTS)
end

local function FindOwnedTowerNear(position, towerName)
    for _, towerConfig in ipairs(SharedTowerData:GetChildren()) do
        if towerConfig:GetAttribute("Owner") == LocalPlayer.Name
            and towerConfig:GetAttribute("TowerName") == towerName then
            local towerCFrame = towerConfig:GetAttribute("CFrame")
            if typeof(towerCFrame) == "CFrame"
                and (towerCFrame.Position - position).Magnitude <= 1.5 then
                return towerConfig.Name
            end
        end
    end
    return nil
end

-- 放置刚发出去时本地可能还没复制到，等一小会儿再判断"塔不存在"
local function WaitForTowerConfig(uniqueId, timeout)
    local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
    if towerConfig then return towerConfig end

    local deadline = tick() + (timeout or 3)
    while State.running and not State:IsMatchOver() and tick() < deadline do
        task.wait(0.1)
        towerConfig = SharedTowerData:FindFirstChild(uniqueId)
        if towerConfig then return towerConfig end
    end
    return nil
end

function UnifiedMacroApi:Place(towerName, position, rotation, targetTime, targetWave)
    if not self:WaitForTime(targetTime, targetWave) then return nil end

    -- 整个重试共用同一个 requestId：服务端若按它去重，重试就不会重复放塔
    local requestId = HttpService:GenerateGUID(false)
    local baselineId = FindOwnedTowerNear(position, towerName)
    local maxRetries = 3
    local lastFailure = nil

    for attempt = 1, maxRetries do
        if not State.running then return nil end

        local success, result = pcall(function()
            return RemoteFunctions.RequestPlacement:InvokeServer(
                towerName, position, rotation or 0, requestId, workspace:GetServerTimeNow()
            )
        end)

        if success and not LooksLikeFailureMessage(result) then
            -- 服务端已受理。先等本地同步；等不到也按成功处理，绝不再放一次
            local uniqueId = result
            local confirmed = false
            local deadline = tick() + 1
            repeat
                if SharedTowerData:FindFirstChild(uniqueId) then
                    confirmed = true
                    break
                end
                local nearId = FindOwnedTowerNear(position, towerName)
                if nearId and nearId ~= baselineId then
                    uniqueId = nearId
                    confirmed = true
                    break
                end
                task.wait(0.05)
            until tick() > deadline

            State:RegisterTower(uniqueId)
            if confirmed then
                if attempt > 1 then
                    PushLog("放置成功(重试" .. attempt .. "次): " .. tostring(towerName))
                end
            else
                PushLog("放置已受理, 本地同步较慢, 按成功处理: " .. tostring(towerName))
            end
            return uniqueId
        end

        lastFailure = result
        if not success then
            PushLog("放置调用出错: " .. tostring(result))
        end

        if attempt == maxRetries then
            PushLog("放置彻底失败(已重试3次): " .. tostring(towerName) .. " (" .. tostring(lastFailure) .. ")")
        else
            local waitTime = 1.5
            if LooksLikeMoneyError(lastFailure) then
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
    if not WaitForTowerConfig(uniqueId, 3) then
        PushLog("升级失败: 塔已不存在 " .. tostring(towerOrId))
        return false
    end

    local maxRetries = 5
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
            PushLog("升级彻底失败(已重试" .. maxRetries .. "次): 塔 " .. tostring(towerOrId) .. " (" .. tostring(failureMessage or upgraded) .. ")")
        else
            local msg = tostring(failureMessage or upgraded):lower()
            local waitTime = 1.5
            if msg:find("money") or msg:find("gold") or msg:find("insufficient") then
                waitTime = 3
            end
            PushLog("升级失败, 等待" .. waitTime .. "秒重试 (" .. attempt .. "/" .. maxRetries .. "): 塔 " .. tostring(towerOrId))
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
    if not WaitForTowerConfig(uniqueId, 3) then
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
    local towerConfig = WaitForTowerConfig(uniqueId, 3)
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

function UnifiedMacroApi:ExecuteAction(action, playbackMap, failedTargets, soldTargets)
    local actionType = action.action

    if actionType == "Place" then
        if not action.pos or not action.towerName then
            return false, "缺少放置数据"
        end
        local alias = action.name or action.towerName
        local position = Vector3.new(action.pos.x, action.pos.y, action.pos.z)
        local uniqueId = self:Place(action.towerName, position, action.rot, action.time, action.wave)
        if not uniqueId then
            failedTargets[alias] = true
            return false, "放置失败"
        end
        playbackMap[alias] = uniqueId
        local recordedLevel = tonumber(action.level)
        if recordedLevel and recordedLevel > 1 then
            local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
            if towerConfig and tonumber(towerConfig:GetAttribute("Level")) ~= recordedLevel then
                PushLog(string.format("警告: %s 初始等级 %s != 录制 %s",
                    tostring(alias), tostring(towerConfig:GetAttribute("Level")), tostring(action.level)))
            end
        end
        return true, string.format("%s -> %s", tostring(alias), tostring(uniqueId))

    elseif actionType == "Upgrade" then
        local uniqueId = playbackMap[action.target]
        if not uniqueId then
            if failedTargets[action.target] then return true, "跳过(放置失败)" end
            if soldTargets[action.target] then return true, "跳过(已出售)" end
            return false, "找不到目标 " .. tostring(action.target)
        end
        local ok = self:Upgrade(uniqueId, action.time, action.wave)
        return ok, tostring(action.target)

    elseif actionType == "Sell" then
        local uniqueId = playbackMap[action.target]
        if not uniqueId then
            return true, "跳过(没有对应塔)"
        end
        local ok = self:Sell(uniqueId, action.time, action.wave)
        if ok or not SharedTowerData:FindFirstChild(uniqueId) then
            -- 卖成功或塔已经不在：清掉映射，后面的动作直接跳过
            playbackMap[action.target] = nil
            soldTargets[action.target] = true
        end
        return ok, tostring(action.target)

    elseif actionType == "SetTarget" then
        local uniqueId = playbackMap[action.target]
        if not uniqueId then
            if failedTargets[action.target] then return true, "跳过(放置失败)" end
            if soldTargets[action.target] then return true, "跳过(已出售)" end
            return false, "找不到目标 " .. tostring(action.target)
        end
        local ok = self:SetTarget(uniqueId, action.targetMode, action.time, action.wave)
        return ok, tostring(action.target) .. " -> " .. tostring(action.targetMode)

    elseif actionType == "WaitWave" then
        local reached = self:WaitWave(action.wave, 0, action.wave)
        return reached ~= false, "波次 " .. tostring(action.wave)

    elseif actionType == "Ready" then
        return self:Ready(action.time, action.wave), "准备"

    elseif actionType == "Speed" then
        return self:Speed(action.speedValue, action.time, action.wave), "速度 " .. tostring(action.speedValue)

    elseif actionType == "Vote" then
        return self:Vote(action.difficultyName, action.time, action.wave), "难度 " .. tostring(action.difficultyName)
    end

    return false, "未知动作 " .. tostring(actionType)
end

function UnifiedMacroApi:PlayOnce(data, macroLabel)
    self:Start()

    local report = CreatePlaybackReport(macroLabel)
    local playbackMap = {}
    local failedTargets = {}
    local soldTargets = {}

    for index, action in ipairs(data.actions or {}) do
        if not State.running then break end

        local startedAt = State:GetClock()
        local callOk, resultOk, resultDetail = pcall(function()
            return self:ExecuteAction(action, playbackMap, failedTargets, soldTargets)
        end)

        local ok = callOk and resultOk == true
        local detail = callOk and resultDetail or ("执行出错: " .. tostring(resultOk))
        local elapsed = math.max(0, State:GetClock() - startedAt)

        AddPlaybackReportEntry(report, index, action, startedAt, elapsed, ok, detail)
        if not ok and action.action ~= "WaitWave" then
            PushLog(string.format("动作 #%d %s 失败: %s", index, tostring(action.action), tostring(detail)))
        end
    end

    local reportPath = SavePlaybackReport(report)
    PushLog(string.format("本局回放 %d/%d 成功%s", report.succeeded, report.total,
        reportPath and ("，报告: " .. reportPath) or ""))
    return report
end

Recorder = {
    recording = false,
    macroName = "未命名",
    actions = {},
    towerNames = {},
    nameCounters = {},
    idToName = {},
    lastRecordedWave = 0,
    sequence = 0,
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

function Recorder:PushAction(action)
    self.sequence = (self.sequence or 0) + 1
    action.seq = self.sequence
    if action.wave == nil then
        action.wave = State:GetWave()
    end
    action.time = RoundTime(action.time or State:GetClock())
    table.insert(self.actions, action)
    return action
end

function Recorder:RecordPlacement(uniqueId, towerName, towerCFrame, towerLevel, targetTime)
    if not towerName or typeof(towerCFrame) ~= "CFrame" then return false end
    local customName = self:GetCustomName(uniqueId, towerName)
    local position = towerCFrame.Position
    local _, yaw, _ = towerCFrame:ToOrientation()
    local quarterTurn = math.round(math.deg(yaw) / 90) * 90
    quarterTurn = quarterTurn % 360
    if quarterTurn > 180 then quarterTurn = quarterTurn - 360 end

    self:PushAction({
        action = "Place", name = customName, towerName = towerName,
        pos = { x = RoundCoord(position.X), y = RoundCoord(position.Y), z = RoundCoord(position.Z) },
        rot = quarterTurn,
        level = towerLevel or 1,
        time = targetTime or State:GetClock(),
    })

    if not table.find(self.towerNames, towerName) then
        table.insert(self.towerNames, towerName)
    end
    return true
end

function Recorder:RecordUpgrade(uniqueId, targetTime)
    local customName = self.idToName[uniqueId]
    if not customName then
        PushLog("录制升级丢失: 未找到别名 " .. tostring(uniqueId))
        return false
    end
    self:PushAction({
        action = "Upgrade", target = customName,
        time = targetTime or State:GetClock(),
    })
    return true
end

function Recorder:RecordSell(uniqueId, targetTime)
    local customName = self.idToName[uniqueId]
    if not customName then return false end
    self:PushAction({ action = "Sell", target = customName, time = targetTime or State:GetClock() })
    return true
end

function Recorder:RecordTargetting(uniqueId, targetMode, targetTime)
    local customName = self.idToName[uniqueId]
    if not customName or not targetMode then
        PushLog("录制切目标丢失: " .. tostring(uniqueId) .. " / " .. tostring(targetMode))
        return false
    end
    self:PushAction({
        action = "SetTarget", target = customName, targetMode = tostring(targetMode),
        time = targetTime or State:GetClock(),
    })
    return true
end

function Recorder:RecordReady(targetTime)
    self:PushAction({ action = "Ready", time = targetTime or State:GetClock() })
end

function Recorder:RecordSpeed(speedValue, targetTime)
    self:PushAction({ action = "Speed", speedValue = speedValue, time = targetTime or State:GetClock() })
end

function Recorder:RecordVote(difficultyName, targetTime)
    self:PushAction({ action = "Vote", difficultyName = tostring(difficultyName), time = targetTime or State:GetClock() })
end

function Recorder:RecordWave(wave, targetTime)
    if not wave or wave < 1 then return end
    self:PushAction({ action = "WaitWave", wave = wave, time = targetTime or State:GetClock() })
end

function Recorder:SanitizeName(macroName) return (tostring(macroName):gsub("[\\/:*?\"<>|]", "_")) end

function Recorder:Start(macroName)
    if State.macroRunning then PushLog("回放进行中，请先停止回放再开始录制"); return false end
    self.macroName = self:SanitizeName(macroName)
    self.actions = {}; self.towerNames = {}; self.nameCounters = {}; self.idToName = {}
    self.recording = true; self.lastRecordedWave = 0; self.sequence = 0
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
    if currentWave > (self.lastRecordedWave or 0) then
        self:RecordWave(currentWave)
    end

    SortMacroActions(self.actions)

    local saveData = {
        version = 1,
        createdAt = os.time(),
        map = self.mapName or "未知",
        difficulty = self.difficultyName or "未知",
        waveCount = tonumber(workspace:GetAttribute("WaveCount")) or 0,
        loadout = self.towerNames,
        actions = self.actions,
    }
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
        local fileName = path:match("([^\\/]+)$") or path
        -- 回放报告也是 .txt，别让它们混进宏列表
        if fileName:sub(1, 7) ~= "report_" then
            if fileName:sub(-4) == ".txt" or fileName:sub(-5) == ".json" then
                table.insert(macroFiles, fileName)
            end
        end
    end
    table.sort(macroFiles)
    return macroFiles
end

TowerTracker = {
    towerConnections = {},
    watchedTowers = {},
    lostTowers = {},
    globalConnections = {},
    readyVotes = nil,
    gameSpeed = nil,
    difficulty = nil,
}

local TOWER_ATTRIBUTES = { "Owner", "TowerName", "CFrame", "Level", "Targetting" }

function TowerTracker:IsRecordingActive() return Recorder.recording and not State.macroRunning end

function TowerTracker:DisconnectTowerSignals(uniqueId)
    local connections = self.towerConnections[uniqueId]
    if not connections then return end
    for _, connection in ipairs(connections) do
        pcall(function() connection:Disconnect() end)
    end
    self.towerConnections[uniqueId] = nil
end

-- 属性变化时只处理这一座塔：时间取事件发生的那一刻，不再靠 0.25 秒轮询猜
function TowerTracker:RefreshTower(uniqueId)
    local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
    if not towerConfig then return end

    local owner = towerConfig:GetAttribute("Owner")
    local towerName = towerConfig:GetAttribute("TowerName")
    local towerCFrame = towerConfig:GetAttribute("CFrame")
    local level = tonumber(towerConfig:GetAttribute("Level")) or 0
    local targetting = towerConfig:GetAttribute("Targetting")
    local previous = self.watchedTowers[uniqueId]
    local now = math.max(0, State:GetClock())

    if not previous then
        if owner ~= LocalPlayer.Name then return end
        if typeof(towerName) ~= "string" or typeof(towerCFrame) ~= "CFrame" then return end

        State:RegisterTower(uniqueId)
        if self:IsRecordingActive() and not Recorder:RecordPlacement(uniqueId, towerName, towerCFrame, math.max(level, 1), now) then
            return -- 基础数据还没齐，等下一次属性同步
        end

        self.watchedTowers[uniqueId] = {
            towerName = towerName,
            level = level,
            targetting = targetting,
        }
        self.lostTowers[uniqueId] = nil

        if self:IsRecordingActive() then
            local step = 0
            for _ = 2, math.max(level, 1) do
                Recorder:RecordUpgrade(uniqueId, now + step * 0.1)
                step = step + 1
            end
            if targetting then Recorder:RecordTargetting(uniqueId, targetting, now + step * 0.1) end
        end
        return
    end

    -- 归属变了（卖塔 / 复制清空），按"消失"走一次复核
    if owner ~= LocalPlayer.Name then
        self:HandleTowerLost(uniqueId)
        return
    end

    local previousLevel = math.max(previous.level or 0, 1)
    if level > previousLevel then
        if self:IsRecordingActive() then
            local step = 0
            for _ = previousLevel + 1, level do
                Recorder:RecordUpgrade(uniqueId, now + step * 0.1)
                step = step + 1
            end
        end
        previous.level = level
    elseif level > 0 then
        previous.level = level
    end

    if targetting ~= nil and targetting ~= previous.targetting then
        if self:IsRecordingActive() then Recorder:RecordTargetting(uniqueId, targetting, now) end
        previous.targetting = targetting
    end
end

function TowerTracker:WatchTower(towerConfig)
    if not towerConfig or typeof(towerConfig) ~= "Instance" then return end
    local uniqueId = towerConfig.Name
    if self.towerConnections[uniqueId] then return end
    self.lostTowers[uniqueId] = nil

    local tracker = self
    local connections = {}
    local function onChange()
        pcall(function() tracker:RefreshTower(uniqueId) end)
    end

    for _, attributeName in ipairs(TOWER_ATTRIBUTES) do
        local ok, signal = pcall(function()
            return towerConfig:GetAttributeChangedSignal(attributeName)
        end)
        if ok and signal then
            connections[#connections + 1] = signal:Connect(onChange)
        end
    end

    self.towerConnections[uniqueId] = connections
    pcall(function() tracker:RefreshTower(uniqueId) end)
end

function TowerTracker:WatchAllTowers()
    for _, towerConfig in ipairs(SharedTowerData:GetChildren()) do
        self:WatchTower(towerConfig)
    end
end

function TowerTracker:HandleTowerLost(uniqueId)
    if self.lostTowers[uniqueId] then return end
    if not self.watchedTowers[uniqueId] then
        self:DisconnectTowerSignals(uniqueId)
        return
    end
    self.lostTowers[uniqueId] = true
    self:DisconnectTowerSignals(uniqueId)

    local removedAt = math.max(0, State:GetClock() - 0.05)
    local matchStartedAt = workspace:GetAttribute("MatchStartedAt")
    local wasRecording = self:IsRecordingActive()

    -- 等 0.35 秒复核：复制抖动时塔会回来，不能当成卖塔
    task.delay(0.35, function()
        local towerConfig = SharedTowerData:FindFirstChild(uniqueId)
        if towerConfig and towerConfig:GetAttribute("Owner") == LocalPlayer.Name then
            self.lostTowers[uniqueId] = nil
            self:WatchTower(towerConfig)
            return
        end

        self.lostTowers[uniqueId] = nil
        -- Reset 之后这个塔已经被重新接管或清掉，不再补记卖塔
        if not self.watchedTowers[uniqueId] then return end
        self.watchedTowers[uniqueId] = nil
        if not wasRecording or not Recorder.recording or State.macroRunning then return end
        if workspace:GetAttribute("MatchStartedAt") ~= matchStartedAt then return end
        if State:IsMatchOver() then return end
        Recorder:RecordSell(uniqueId, removedAt)
    end)
end

function TowerTracker:HandleTowerRemoved(towerConfig)
    if not towerConfig then return end
    self:HandleTowerLost(towerConfig.Name)
end

function TowerTracker:OnWaveChanged()
    local currentWave = State:GetWave()
    if currentWave <= (Recorder.lastRecordedWave or 0) then return end

    local now = math.max(0, State:GetClock())
    if self:IsRecordingActive() then
        for wave = (Recorder.lastRecordedWave or 0) + 1, currentWave do
            Recorder:RecordWave(wave, now)
        end
    end
    Recorder.lastRecordedWave = currentWave
end

function TowerTracker:OnReadyVotesChanged()
    local readyVotes = tonumber(workspace:GetAttribute("ReadyVotes")) or 0
    local previous = self.readyVotes
    self.readyVotes = readyVotes
    if previous == nil or readyVotes <= previous then return end
    if State:IsReadyVoting() and self:IsRecordingActive() then
        Recorder:RecordReady(math.max(0, State:GetClock()))
    end
end

function TowerTracker:OnGameSpeedChanged()
    local gameSpeed = tonumber(workspace:GetAttribute("GameSpeed")) or 1
    local previous = self.gameSpeed
    self.gameSpeed = gameSpeed
    if previous == nil or gameSpeed == previous then return end
    if self:IsRecordingActive() then
        Recorder:RecordSpeed(gameSpeed, math.max(0, State:GetClock()))
    end
end

function TowerTracker:OnDifficultyChanged()
    local difficulty = workspace:GetAttribute("Difficulty")
    local previous = self.difficulty
    self.difficulty = difficulty
    if previous == nil or difficulty == previous then return end
    if typeof(difficulty) == "string" and self:IsRecordingActive() then
        Recorder:RecordVote(difficulty, math.max(0, State:GetClock()))
    end
end

function TowerTracker:Reset()
    local uniqueIds = {}
    for uniqueId in pairs(self.towerConnections) do
        table.insert(uniqueIds, uniqueId)
    end
    for _, uniqueId in ipairs(uniqueIds) do
        self:DisconnectTowerSignals(uniqueId)
    end

    self.towerConnections = {}
    self.watchedTowers = {}
    self.lostTowers = {}
    self.readyVotes = tonumber(workspace:GetAttribute("ReadyVotes")) or 0
    self.gameSpeed = tonumber(workspace:GetAttribute("GameSpeed")) or 1
    self.difficulty = workspace:GetAttribute("Difficulty")
    if Recorder then Recorder.lastRecordedWave = 0 end

    -- 重新接管当前场上的塔；录制开始时相当于把现有塔补记一遍
    self:WatchAllTowers()
end

function TowerTracker:Shutdown()
    local uniqueIds = {}
    for uniqueId in pairs(self.towerConnections) do
        table.insert(uniqueIds, uniqueId)
    end
    for _, uniqueId in ipairs(uniqueIds) do
        self:DisconnectTowerSignals(uniqueId)
    end
    self.towerConnections = {}
    self.watchedTowers = {}
    self.lostTowers = {}

    for _, connection in ipairs(self.globalConnections or {}) do
        pcall(function() connection:Disconnect() end)
    end
    self.globalConnections = {}

    if self.waveConnection then
        pcall(function() self.waveConnection:Disconnect() end)
        self.waveConnection = nil
    end
    self.waveValue = nil
end

function TowerTracker:WatchWaveValue()
    local waveValue = GameConfig:FindFirstChild("Wave")
    if not waveValue then return end
    if self.waveValue == waveValue and self.waveConnection then return end

    if self.waveConnection then
        pcall(function() self.waveConnection:Disconnect() end)
        self.waveConnection = nil
    end

    self.waveValue = waveValue
    self.waveConnection = waveValue:GetPropertyChangedSignal("Value"):Connect(function()
        pcall(function() self:OnWaveChanged() end)
    end)
end

function TowerTracker:StartWatching()
    local previousTracker = getgenv().TWD_TowerTracker
    if type(previousTracker) == "table" and previousTracker ~= self and previousTracker.Shutdown then
        pcall(function() previousTracker:Shutdown() end)
    end
    getgenv().TWD_TowerTracker = self

    self.readyVotes = tonumber(workspace:GetAttribute("ReadyVotes")) or 0
    self.gameSpeed = tonumber(workspace:GetAttribute("GameSpeed")) or 1
    self.difficulty = workspace:GetAttribute("Difficulty")

    local function addConnection(signal, callback)
        self.globalConnections[#self.globalConnections + 1] = signal:Connect(callback)
    end

    addConnection(SharedTowerData.ChildAdded, function(child)
        pcall(function() self:WatchTower(child) end)
    end)
    addConnection(SharedTowerData.ChildRemoved, function(child)
        pcall(function() self:HandleTowerRemoved(child) end)
    end)
    self:WatchWaveValue()
    addConnection(GameConfig.ChildAdded, function(child)
        if child.Name == "Wave" then
            pcall(function() self:WatchWaveValue() end)
        end
    end)
    addConnection(workspace:GetAttributeChangedSignal("ReadyVotes"), function()
        pcall(function() self:OnReadyVotesChanged() end)
    end)
    addConnection(workspace:GetAttributeChangedSignal("GameSpeed"), function()
        pcall(function() self:OnGameSpeedChanged() end)
    end)
    addConnection(workspace:GetAttributeChangedSignal("Difficulty"), function()
        pcall(function() self:OnDifficultyChanged() end)
    end)

    self:WatchAllTowers()
end

TowerTracker:StartWatching()

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
        if not decodeSuccess or type(data) ~= "table" then
            PushLog("解析 JSON 失败: " .. tostring(data))
            return
        end
        if type(data.actions) ~= "table" then
            PushLog("宏文件里没有 actions 列表")
            return
        end
        SortMacroActions(data.actions)
        if tonumber(data.version) and tonumber(data.version) > 1 then
            PushLog("宏版本高于脚本，可能不兼容: " .. tostring(data.version))
        end

        task.spawn(function()
            local api = getgenv().UnifiedMacroApi
            State.macroRunning = true
            if data.loadout and #data.loadout > 0 then PushLog("宏 loadout: " .. table.concat(data.loadout, ", ")) end
            if data.map then PushLog("宏地图: " .. tostring(data.map) .. " / " .. tostring(data.difficulty or "?")) end

            local runOk, runError = pcall(function()
                while State.running do
                    api:PlayOnce(data, State.selectedMacroName)
                    if not State.loopEnabled then break end
                    api:WaitForMatchEnd()
                    if not State.running then break end
                    task.wait(2)
                    if not api:WaitForNextMatch() then break end
                    task.wait(1)
                end
            end)
            if not runOk then PushLog("回放出错: " .. tostring(runError)) end
            State.macroRunning = false
        end)
        PushLog("开始播放 (JSON): " .. State.selectedMacroName)
    else
        PushLog("TXT 宏为旧格式，仅作兼容保留，建议重新录制为 JSON")
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
        AutoAgreeSkipVote()

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

PushLog("脚本已加载，共检测到 " .. #ListMacroFiles() .. " 个宏文件（无任何 hook）")