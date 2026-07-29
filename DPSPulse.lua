local ADDON_NAME = ...

local DPSPulse = {}
_G.DPSPulse = DPSPulse

local defaults = {
    point = "CENTER",
    relativePoint = "CENTER",
    x = 0,
    y = -140,
    scale = 1,
    windowSeconds = 10,
    locked = false,
    visible = true,
}

local function now()
    if GetTimePreciseSec then
        return GetTimePreciseSec()
    end
    return GetTime()
end

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue
    end
    if value > maxValue then
        return maxValue
    end
    return value
end

local function round(value)
    return math.floor(value + 0.5)
end

-- Linear interpolation between two colors at t in [0,1].
local function lerp(a, b, t)
    return a + (b - a) * t
end

-- Returns r,g,b for a heat gradient based on intensity in [0,1]:
-- 0.00 blue -> 0.33 green -> 0.66 yellow -> 1.00 red.
local function gradientColor(intensity)
    if intensity ~= intensity then -- NaN guard
        intensity = 0
    end
    if intensity < 0 then intensity = 0 end
    if intensity > 1 then intensity = 1 end

    -- Stops: {t, r, g, b}
    local stops = {
        { 0.00, 0.25, 0.55, 1.00 }, -- blue
        { 0.33, 0.20, 0.95, 0.40 }, -- green (matches legacy line color)
        { 0.66, 1.00, 0.90, 0.20 }, -- yellow
        { 1.00, 1.00, 0.25, 0.20 }, -- red
    }

    for i = 1, #stops - 1 do
        local s1 = stops[i]
        local s2 = stops[i + 1]
        if intensity <= s2[1] then
            local span = s2[1] - s1[1]
            local t = span > 0 and (intensity - s1[1]) / span or 0
            return lerp(s1[2], s2[2], t), lerp(s1[3], s2[3], t), lerp(s1[4], s2[4], t)
        end
    end

    local last = stops[#stops]
    return last[2], last[3], last[4]
end

local function shallowCopy(src)
    local out = {}
    for key, value in pairs(src) do
        out[key] = value
    end
    return out
end

local function chat(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99DPSPulse|r " .. msg)
    end
end

DPSPulse.state = {
    initialized = false,
    playerGUID = nil,
    petGUID = nil,
    inCombat = false,
    fightStart = 0,
    clearAt = nil,
    buckets = {},
    history = {},
    peakDPS = 0,
    sampleAccumulator = 0,
    renderAccumulator = 0,
    logTimeOffset = nil,
}

DPSPulse.config = {
    bucketStep = 0.2,
    sampleInterval = 0.1,
    renderInterval = 0.08,
    clearDelay = 3,
}

DPSPulse.ui = {
    frame = nil,
    graph = nil,
    dpsText = nil,
    peakText = nil,
    maxLabel = nil,
    segments = {},
    supportsRotation = true,
}

local damageEvents = {
    SWING_DAMAGE = true,
    SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
    RANGE_DAMAGE = true,
    DAMAGE_SHIELD = true,
    DAMAGE_SPLIT = true,
    ENVIRONMENTAL_DAMAGE = true,
}

function DPSPulse:GetWindowSeconds()
    return clamp(tonumber(DPSPulseDB.windowSeconds) or defaults.windowSeconds, 2, 60)
end

function DPSPulse:GetHistorySeconds()
    local windowSeconds = self:GetWindowSeconds()
    return clamp(windowSeconds * 2, 10, 60)
end

function DPSPulse:EnsureDB()
    if type(DPSPulseDB) ~= "table" then
        DPSPulseDB = shallowCopy(defaults)
        return
    end

    for key, value in pairs(defaults) do
        if DPSPulseDB[key] == nil then
            DPSPulseDB[key] = value
        end
    end

    DPSPulseDB.windowSeconds = self:GetWindowSeconds()
    DPSPulseDB.scale = clamp(tonumber(DPSPulseDB.scale) or defaults.scale, 0.5, 2)
    DPSPulseDB.visible = DPSPulseDB.visible ~= false
    DPSPulseDB.locked = DPSPulseDB.locked == true
end

function DPSPulse:ResetFightData()
    self.state.buckets = {}
    self.state.history = {}
    self.state.peakDPS = 0
    self.state.fightStart = now()
    self.state.logTimeOffset = nil
end

function DPSPulse:StartFight()
    self.state.inCombat = true
    self.state.clearAt = nil
    self:ResetFightData()
end

function DPSPulse:EndFight()
    self.state.inCombat = false
    self.state.clearAt = now() + self.config.clearDelay
end

function DPSPulse:NormalizeEventTime(eventTimestamp)
    local eventTime = tonumber(eventTimestamp)
    if not eventTime then
        return now()
    end

    if not self.state.logTimeOffset then
        self.state.logTimeOffset = now() - eventTime
    end

    return eventTime + self.state.logTimeOffset
end

function DPSPulse:TrackDamage(eventTime, amount)
    if not amount or amount <= 0 then
        return
    end

    local step = self.config.bucketStep
    local bucketTime = math.floor(eventTime / step) * step
    local buckets = self.state.buckets
    local count = #buckets

    if count > 0 and buckets[count].t == bucketTime then
        buckets[count].dmg = buckets[count].dmg + amount
    else
        buckets[count + 1] = { t = bucketTime, dmg = amount }
    end

    local oldest = eventTime - (self:GetHistorySeconds() + 8)
    local trimIndex = 1
    while trimIndex <= #buckets and buckets[trimIndex].t < oldest do
        trimIndex = trimIndex + 1
    end

    if trimIndex > 1 then
        local newBuckets = {}
        local newIndex = 1
        for i = trimIndex, #buckets do
            newBuckets[newIndex] = buckets[i]
            newIndex = newIndex + 1
        end
        self.state.buckets = newBuckets
    end
end

function DPSPulse:ComputeRollingDPS(currentTime)
    local buckets = self.state.buckets
    if #buckets == 0 then
        return 0
    end

    local windowSeconds = self:GetWindowSeconds()
    local elapsed = currentTime - (self.state.fightStart or currentTime)
    local divisor = clamp(elapsed, self.config.bucketStep, windowSeconds)
    local lowerBound = currentTime - windowSeconds
    local sum = 0

    for i = #buckets, 1, -1 do
        local bucket = buckets[i]
        if bucket.t < lowerBound then
            break
        end
        sum = sum + bucket.dmg
    end

    if divisor <= 0 then
        return 0
    end

    return sum / divisor
end

function DPSPulse:Sample()
    local currentTime = now()

    if (not self.state.inCombat) and self.state.clearAt and currentTime >= self.state.clearAt then
        self.state.clearAt = nil
        self:ResetFightData()
        return
    end

    local currentDPS = self:ComputeRollingDPS(currentTime)

    local history = self.state.history
    history[#history + 1] = { t = currentTime, dps = currentDPS }

    if currentDPS > self.state.peakDPS then
        self.state.peakDPS = currentDPS
    end

    local historySeconds = self:GetHistorySeconds()
    local oldest = currentTime - historySeconds
    local trimIndex = 1
    while trimIndex <= #history and history[trimIndex].t < oldest do
        trimIndex = trimIndex + 1
    end

    if trimIndex > 1 then
        local newHistory = {}
        local newIndex = 1
        for i = trimIndex, #history do
            newHistory[newIndex] = history[i]
            newIndex = newIndex + 1
        end
        self.state.history = newHistory
    end

end

function DPSPulse:ClearSegments()
    local segments = self.ui.segments
    for i = 1, #segments do
        segments[i]:Hide()
    end
end

function DPSPulse:RenderGraph()
    if not self.ui.graph then
        return
    end

    local graph = self.ui.graph
    local graphWidth = graph:GetWidth()
    local graphHeight = graph:GetHeight()
    local history = self.state.history

    if #history < 2 then
        self:ClearSegments()
        if self.ui.maxLabel then
            self.ui.maxLabel:SetText("Max: 0")
        end
        return
    end

    local currentTime = now()
    local historySeconds = self:GetHistorySeconds()
    local minTime = currentTime - historySeconds

    local points = {}
    local maxDPS = 0

    for i = 1, #history do
        local point = history[i]
        if point.t >= minTime then
            points[#points + 1] = point
            if point.dps > maxDPS then
                maxDPS = point.dps
            end
        end
    end

    if #points < 2 then
        self:ClearSegments()
        if self.ui.maxLabel then
            self.ui.maxLabel:SetText("Max: 0")
        end
        return
    end

    maxDPS = math.max(50, round(maxDPS * 1.15))
    if self.ui.maxLabel then
        self.ui.maxLabel:SetText("Max: " .. tostring(round(maxDPS)))
    end

    local segments = self.ui.segments
    local segmentIndex = 1

    for i = 2, #points do
        local p1 = points[i - 1]
        local p2 = points[i]

        local x1 = ((p1.t - minTime) / historySeconds) * graphWidth
        local y1 = (clamp(p1.dps / maxDPS, 0, 1)) * graphHeight
        local x2 = ((p2.t - minTime) / historySeconds) * graphWidth
        local y2 = (clamp(p2.dps / maxDPS, 0, 1)) * graphHeight

        local dx = x2 - x1
        local dy = y2 - y1
        local dist = math.sqrt(dx * dx + dy * dy)

        local segment = segments[segmentIndex]
        if not segment then
            break
        end

        if dist < 0.01 then
            segment:Hide()
        else
            -- Color this segment on a heat gradient based on its DPS relative to the
            -- current visible max. Use the average of the two endpoints so the line
            -- transitions smoothly from segment to segment.
            local intensity = 0
            if maxDPS > 0 then
                intensity = clamp(((p1.dps + p2.dps) * 0.5) / maxDPS, 0, 1)
            end
            local r, g, b = gradientColor(intensity)
            segment:SetColorTexture(r, g, b, 1)

            segment:ClearAllPoints()
            if self.ui.supportsRotation and segment.SetRotation then
                segment:SetPoint("CENTER", graph, "BOTTOMLEFT", (x1 + x2) * 0.5, (y1 + y2) * 0.5)
                segment:SetSize(dist, 2)
                segment:SetRotation(math.atan2(dy, dx))
            else
                segment:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", math.min(x1, x2), y2)
                segment:SetSize(math.max(1, math.abs(dx)), 2)
            end
            segment:Show()
        end

        segmentIndex = segmentIndex + 1
    end

    for i = segmentIndex, #segments do
        segments[i]:Hide()
    end
end

function DPSPulse:UpdateTexts()
    if not self.ui.dpsText then
        return
    end

    local currentDPS = self:ComputeRollingDPS(now())
    self.ui.dpsText:SetText(string.format("%d DPS", round(currentDPS)))

    if self.ui.peakText then
        self.ui.peakText:SetText(string.format("Peak %d", round(self.state.peakDPS)))
    end
end

function DPSPulse:ApplyPosition()
    if not self.ui.frame then
        return
    end

    self.ui.frame:ClearAllPoints()
    self.ui.frame:SetPoint(
        DPSPulseDB.point or defaults.point,
        UIParent,
        DPSPulseDB.relativePoint or defaults.relativePoint,
        DPSPulseDB.x or defaults.x,
        DPSPulseDB.y or defaults.y
    )
end

function DPSPulse:SavePosition()
    if not self.ui.frame then
        return
    end

    local point, _, relativePoint, x, y = self.ui.frame:GetPoint(1)
    DPSPulseDB.point = point
    DPSPulseDB.relativePoint = relativePoint
    DPSPulseDB.x = round(x or 0)
    DPSPulseDB.y = round(y or 0)
end

function DPSPulse:SetVisible(visible)
    DPSPulseDB.visible = visible == true
    if self.ui.frame then
        if DPSPulseDB.visible then
            self.ui.frame:Show()
        else
            self.ui.frame:Hide()
        end
    end
end

function DPSPulse:CreateUI()
    if self.ui.frame then
        return
    end

    local frame = CreateFrame("Frame", "DPSPulseFrame", UIParent)
    frame:SetSize(320, 170)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScale(DPSPulseDB.scale)

    frame:SetScript("OnDragStart", function(selfFrame)
        if not DPSPulseDB.locked then
            selfFrame:StartMoving()
        end
    end)

    frame:SetScript("OnDragStop", function(selfFrame)
        selfFrame:StopMovingOrSizing()
        DPSPulse:SavePosition()
    end)

    frame:SetScript("OnUpdate", function(_, elapsed)
        if (not DPSPulse.state.inCombat) and (not DPSPulse.state.clearAt) then
            return
        end

        DPSPulse.state.sampleAccumulator = DPSPulse.state.sampleAccumulator + elapsed
        DPSPulse.state.renderAccumulator = DPSPulse.state.renderAccumulator + elapsed

        while DPSPulse.state.sampleAccumulator >= DPSPulse.config.sampleInterval do
            DPSPulse.state.sampleAccumulator = DPSPulse.state.sampleAccumulator - DPSPulse.config.sampleInterval
            DPSPulse:Sample()
        end

        if DPSPulse.state.renderAccumulator >= DPSPulse.config.renderInterval then
            DPSPulse.state.renderAccumulator = 0
            DPSPulse:UpdateTexts()
            DPSPulse:RenderGraph()
        end
    end)

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(frame)
    bg:SetColorTexture(0, 0, 0, 0.55)

    local header = frame:CreateTexture(nil, "ARTWORK")
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    header:SetHeight(24)
    header:SetColorTexture(0.08, 0.08, 0.08, 0.8)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -6)
    title:SetText("DPSPulse")

    local lockStatus = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lockStatus:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -8)
    frame.lockStatus = lockStatus

    local dpsText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    dpsText:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -30)
    dpsText:SetText("0 DPS")

    local peakText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    peakText:SetPoint("TOPLEFT", dpsText, "BOTTOMLEFT", 0, -4)
    peakText:SetText("Peak 0")

    local graph = CreateFrame("Frame", nil, frame)
    graph:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -70)
    graph:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)

    local graphBg = graph:CreateTexture(nil, "BACKGROUND")
    graphBg:SetAllPoints(graph)
    graphBg:SetColorTexture(0.02, 0.02, 0.02, 0.75)

    local axisX = graph:CreateTexture(nil, "ARTWORK")
    axisX:SetColorTexture(0.5, 0.5, 0.5, 0.35)
    axisX:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", 0, 0)
    axisX:SetPoint("BOTTOMRIGHT", graph, "BOTTOMRIGHT", 0, 0)
    axisX:SetHeight(1)

    local axisY = graph:CreateTexture(nil, "ARTWORK")
    axisY:SetColorTexture(0.5, 0.5, 0.5, 0.35)
    axisY:SetPoint("BOTTOMLEFT", graph, "BOTTOMLEFT", 0, 0)
    axisY:SetPoint("TOPLEFT", graph, "TOPLEFT", 0, 0)
    axisY:SetWidth(1)

    local maxLabel = graph:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    maxLabel:SetPoint("TOPRIGHT", graph, "TOPRIGHT", -2, -2)
    maxLabel:SetText("Max: 0")

    local supportsRotation = true
    local segmentCount = 160
    local segments = {}
    for i = 1, segmentCount do
        local segment = graph:CreateTexture(nil, "OVERLAY")
        segment:SetColorTexture(0.2, 0.95, 0.4, 1)
        segment:SetSize(1, 2)
        segment:Hide()

        if supportsRotation and not segment.SetRotation then
            supportsRotation = false
        end

        segments[i] = segment
    end

    self.ui.frame = frame
    self.ui.graph = graph
    self.ui.dpsText = dpsText
    self.ui.peakText = peakText
    self.ui.maxLabel = maxLabel
    self.ui.segments = segments
    self.ui.supportsRotation = supportsRotation

    self:ApplyPosition()
    self:SetVisible(DPSPulseDB.visible)
    self:UpdateLockStatus()
end

function DPSPulse:UpdateLockStatus()
    if not self.ui.frame or not self.ui.frame.lockStatus then
        return
    end

    if DPSPulseDB.locked then
        self.ui.frame.lockStatus:SetText("Locked")
    else
        self.ui.frame.lockStatus:SetText("Unlocked")
    end
end

function DPSPulse:ParseDamageAmount(subEvent, ...)
    if subEvent == "SWING_DAMAGE" then
        return tonumber((...))
    end

    if subEvent == "ENVIRONMENTAL_DAMAGE" then
        local _, amount = ...
        return tonumber(amount)
    end

    if subEvent == "SPELL_DAMAGE" or subEvent == "SPELL_PERIODIC_DAMAGE" or subEvent == "RANGE_DAMAGE" or subEvent == "DAMAGE_SHIELD" or subEvent == "DAMAGE_SPLIT" then
        local _, _, _, amount = ...
        return tonumber(amount)
    end

    return nil
end

function DPSPulse:HandleCombatLogEvent(...)
    local timestamp
    local subEvent
    local sourceGUID
    local arg12
    local arg13
    local arg14
    local arg15

    if CombatLogGetCurrentEventInfo then
        timestamp, subEvent, _, sourceGUID, _, _, _, _, _, _, _, arg12, arg13, arg14, arg15 = CombatLogGetCurrentEventInfo()
    else
        timestamp, subEvent, _, sourceGUID, _, _, _, _, _, _, _, arg12, arg13, arg14, arg15 = ...
    end

    if not timestamp or not subEvent or not sourceGUID then
        return
    end

    if not damageEvents[subEvent] then
        return
    end

    local isPlayer = sourceGUID == self.state.playerGUID
    local isPet = self.state.petGUID and sourceGUID == self.state.petGUID
    if not isPlayer and not isPet then
        return
    end

    local amount = self:ParseDamageAmount(subEvent, arg12, arg13, arg14, arg15)

    if amount and amount > 0 then
        self:TrackDamage(self:NormalizeEventTime(timestamp), amount)
    end
end

function DPSPulse:HandleSlash(msg)
    local command = string.lower((msg or ""):match("^%s*(.-)%s*$") or "")

    if command == "" or command == "toggle" then
        self:SetVisible(not DPSPulseDB.visible)
        return
    end

    if command == "show" then
        self:SetVisible(true)
        return
    end

    if command == "hide" then
        self:SetVisible(false)
        return
    end

    if command == "reset" then
        self:ResetFightData()
        self:UpdateTexts()
        self:RenderGraph()
        chat("Current fight data reset.")
        return
    end

    if command == "lock" then
        DPSPulseDB.locked = true
        self:UpdateLockStatus()
        chat("Frame locked.")
        return
    end

    if command == "unlock" then
        DPSPulseDB.locked = false
        self:UpdateLockStatus()
        chat("Frame unlocked.")
        return
    end

    local windowValue = command:match("^window%s+([%d%.]+)$")
    if windowValue then
        local seconds = clamp(tonumber(windowValue) or defaults.windowSeconds, 2, 60)
        DPSPulseDB.windowSeconds = seconds
        chat("Rolling window set to " .. tostring(seconds) .. "s.")
        return
    end

    local scaleValue = command:match("^scale%s+([%d%.]+)$")
    if scaleValue then
        local scale = clamp(tonumber(scaleValue) or 1, 0.5, 2)
        DPSPulseDB.scale = scale
        if self.ui.frame then
            self.ui.frame:SetScale(scale)
        end
        chat("Scale set to " .. tostring(scale) .. ".")
        return
    end

    chat("Commands: show, hide, toggle, window <2-60>, scale <0.5-2>, lock, unlock, reset")
end

function DPSPulse:HandleEvent(event, ...)
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= ADDON_NAME then
            return
        end
        self:EnsureDB()
    elseif event == "PLAYER_LOGIN" then
        if self.state.initialized then
            return
        end

        self.state.initialized = true
        self.state.playerGUID = UnitGUID("player")
        self.state.petGUID = UnitGUID("pet")

        self:CreateUI()
        self:ResetFightData()

        SLASH_DPSPULSE1 = "/dpspulse"
        SlashCmdList.DPSPULSE = function(msg)
            self:HandleSlash(msg)
        end

        chat("Loaded. Type /dpspulse help for commands.")
    elseif event == "PLAYER_REGEN_DISABLED" then
        self:StartFight()
    elseif event == "PLAYER_REGEN_ENABLED" then
        self:EndFight()
    elseif event == "UNIT_PET" then
        local unit = ...
        if unit == "player" then
            self.state.petGUID = UnitGUID("pet")
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        self.state.playerGUID = UnitGUID("player")
        self.state.petGUID = UnitGUID("pet")
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        self:HandleCombatLogEvent(...)
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:RegisterEvent("UNIT_PET")
eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    DPSPulse:HandleEvent(event, ...)
end)
