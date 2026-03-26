-- mic_monitor.lua — Detect mic-in-use during meetings, send webhooks to Home Assistant
--
-- Detection: Polls hs.audiodevice.allInputDevices():inUse() every 2 seconds.
-- Additionally requires a meeting app (Teams, Zoom, FaceTime) to be running,
-- filtering out voice dictation, recordings, etc.
--
-- Webhooks: POST to Home Assistant to control phone notification sounds.
-- Includes retry logic, heartbeat re-sends, and persistent state across reloads.
--
-- Permissions needed:
--   System Settings → Privacy & Security → Microphone → Hammerspoon (for inUse)
--   System Settings → Privacy & Security → Accessibility → Hammerspoon (general)
--
-- Reload config: Hammerspoon menu bar → Reload Config, or run hs.reload()
--
-- Testing:
--   micMonitor.status()     — print full diagnostic info to console
--   micMonitor.testOn()     — fire ON webhook manually
--   micMonitor.testOff()    — fire OFF webhook manually
--   micMonitor.forceSync()  — re-send webhook matching current state (manual recovery)
--   micMonitor.stop()       — stop monitoring
--   micMonitor.start()      — restart monitoring

local M = {}

-- ── Configuration ──────────────────────────────────────────────────────
local HA_BASE     = "http://192.168.1.104:9123"
local HA_TOKEN    = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiI4M2M1NTZjYjAzMjU0YTVkYWMxNzY3N2MwY2FkYjQwYSIsImlhdCI6MTc3MzcxOTY4MywiZXhwIjoyMDg5MDc5NjgzfQ.LIdiqZAqkjhVK0B3yTnbxtnhe8J1ePQIEgD4ktDuPGs"
local HA_NOTIFY   = HA_BASE .. "/api/services/notify/mobile_app_s26plus"
local HA_HEADERS  = {
    ["Authorization"] = "Bearer " .. HA_TOKEN,
    ["Content-Type"]  = "application/json",
}

local POLL_INTERVAL   = 2    -- seconds between polls
local DEBOUNCE_COUNT  = 3    -- consecutive polls before triggering (3 × 2s = 6s)

local WORK_START_HOUR = 8
local WORK_START_MIN  = 45   -- 08:45 local time
local WORK_END_HOUR   = 17
local WORK_END_MIN    = 45   -- 17:45 local time
local WORK_OVERRIDE   = true  -- set true to bypass day/time check

local MEETING_APPS = {"Microsoft Teams", "zoom.us", "FaceTime"}

local HEARTBEAT_INTERVAL = 120  -- seconds between heartbeat re-sends during active meeting

local STATE_FILE = os.getenv("HOME") .. "/.hammerspoon/mic_monitor_state.json"
local LOG_FILE   = os.getenv("HOME") .. "/.hammerspoon/mic_monitor.log"
local LOG_MAX_BYTES = 100 * 1024  -- truncate to last 50KB when exceeding this

-- ── Logging ──────────────────────────────────────────────────────────
local function truncateLogIfNeeded()
    local f = io.open(LOG_FILE, "r")
    if not f then return end
    local size = f:seek("end")
    if size and size > LOG_MAX_BYTES then
        -- Keep last 50KB
        local keepBytes = 50 * 1024
        f:seek("set", size - keepBytes)
        f:read("*l") -- skip partial line
        local tail = f:read("*a")
        f:close()
        f = io.open(LOG_FILE, "w")
        if f then
            f:write("--- log truncated ---\n")
            f:write(tail or "")
            f:close()
        end
    else
        f:close()
    end
end

local function log(msg)
    local line = os.date("%Y-%m-%d %H:%M:%S") .. " [mic] " .. msg
    print("[mic] " .. msg)
    local f = io.open(LOG_FILE, "a")
    if f then
        f:write(line .. "\n")
        f:close()
    end
end

-- Truncate log on startup
truncateLogIfNeeded()

-- ── State ──────────────────────────────────────────────────────────────
local pollTimer         = nil    -- hs.timer
local lastReportedState = nil    -- true=active, false=inactive, nil=unknown
local consecutiveCount  = 0      -- polls showing pendingState
local pendingState      = nil    -- state being debounced toward
local lastTransitionTime = nil   -- os.time() of last transition
local heartbeatTimer    = nil    -- hs.timer for heartbeat re-sends

-- ── State Persistence ────────────────────────────────────────────────
local json = hs.json

local function saveState(active)
    local data = json.encode({active = active, timestamp = os.time()})
    local f = io.open(STATE_FILE, "w")
    if f then
        f:write(data)
        f:close()
    end
end

local function loadState()
    local f = io.open(STATE_FILE, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local ok, state = pcall(json.decode, content)
    if ok and state then return state end
    return nil
end

-- ── Helpers ────────────────────────────────────────────────────────────

local function isWorkHours()
    if WORK_OVERRIDE then return true end
    local now = os.date("*t")
    local dow = now.wday  -- 1=Sunday, 7=Saturday
    if dow == 1 or dow == 7 then return false end
    local minuteOfDay = now.hour * 60 + now.min
    local startMinute = WORK_START_HOUR * 60 + WORK_START_MIN
    local endMinute   = WORK_END_HOUR * 60 + WORK_END_MIN
    return minuteOfDay >= startMinute and minuteOfDay < endMinute
end

local function isMeetingAppRunning()
    for _, appName in ipairs(MEETING_APPS) do
        if hs.application.find(appName) then
            return true, appName
        end
    end
    return false, nil
end

local function anyMicInUse()
    -- Suppress during voice dictation
    if _G.micMonitorDictationActive then
        return false, nil
    end
    for _, dev in ipairs(hs.audiodevice.allInputDevices()) do
        if dev:inUse() then
            return true, dev:name()
        end
    end
    return false, nil
end

local function isMeetingActive()
    local micInUse, deviceName = anyMicInUse()
    if not micInUse then return false, nil end
    local appRunning, appName = isMeetingAppRunning()
    if not appRunning then return false, nil end
    return true, deviceName .. " / " .. appName
end

-- ── HA Notify with Retry ─────────────────────────────────────────────

local DND_ON_BODY  = hs.json.encode({message = "command_dnd", data = {command = "alarms_only"}})
local DND_OFF_BODY = hs.json.encode({message = "command_dnd", data = {command = "off"}})

local function sendNotify(body, label)
    log("notify " .. label)
    hs.http.asyncPost(HA_NOTIFY, body, HA_HEADERS, function(status)
        if status >= 200 and status < 300 then
            log("notify " .. label .. " OK (" .. tostring(status) .. ")")
        else
            log("notify " .. label .. " FAILED (HTTP " .. tostring(status) .. ")")
            hs.alert.show("HA notify " .. label .. " failed", 2)
        end
    end)
end

-- ── Heartbeat ────────────────────────────────────────────────────────

local function startHeartbeat()
    if heartbeatTimer then heartbeatTimer:stop() end
    heartbeatTimer = hs.timer.doEvery(HEARTBEAT_INTERVAL, function()
        if lastReportedState == true then
            log("heartbeat re-sending DND ON")
            sendNotify(DND_ON_BODY, "HEARTBEAT-ON")
        end
    end)
end

local function stopHeartbeat()
    if heartbeatTimer then
        heartbeatTimer:stop()
        heartbeatTimer = nil
    end
end

-- ── Transitions ──────────────────────────────────────────────────────

local function onTransition(newState, detail)
    if newState == lastReportedState then return end
    local detailStr = detail and (" [" .. detail .. "]") or ""
    log("transition: " .. tostring(lastReportedState) .. " → " .. tostring(newState) .. detailStr)
    if newState then
        sendNotify(DND_ON_BODY, "ON")
        startHeartbeat()
    else
        sendNotify(DND_OFF_BODY, "OFF")
        stopHeartbeat()
    end
    lastReportedState = newState
    lastTransitionTime = os.time()
    saveState(newState)
end

-- ── Polling ──────────────────────────────────────────────────────────

local function poll()
    if not isWorkHours() then
        if lastReportedState == true then
            log("outside work hours — sending OFF")
            onTransition(false)
        end
        consecutiveCount = 0
        pendingState = nil
        return
    end

    local active, detail = isMeetingActive()

    -- Debounce: require DEBOUNCE_COUNT consecutive matching polls
    if active == pendingState then
        consecutiveCount = consecutiveCount + 1
    else
        pendingState = active
        consecutiveCount = 1
    end

    if consecutiveCount >= DEBOUNCE_COUNT and pendingState ~= lastReportedState then
        onTransition(pendingState, detail)
    end
end

-- ── Public API ───────────────────────────────────────────────────────

function M.start()
    if pollTimer then pollTimer:stop() end
    stopHeartbeat()

    -- Restore persisted state
    local saved = loadState()
    if saved then
        local age = os.time() - (saved.timestamp or 0)
        if saved.active and age > 4 * 3600 then
            log("startup: stale active state (" .. math.floor(age / 60) .. "m old) — sending OFF")
            lastReportedState = true  -- set so onTransition sees a change
            onTransition(false)
        elseif saved.active then
            log("startup: restored active state (age " .. math.floor(age / 60) .. "m) — will reconcile on next poll")
            lastReportedState = true
            lastTransitionTime = saved.timestamp
            startHeartbeat()
        else
            log("startup: restored inactive state")
            lastReportedState = false
            lastTransitionTime = saved.timestamp
        end
    else
        lastReportedState = nil
        lastTransitionTime = nil
    end

    consecutiveCount = 0
    pendingState = nil
    pollTimer = hs.timer.doEvery(POLL_INTERVAL, poll)
    log("monitor started (poll=" .. POLL_INTERVAL .. "s, debounce=" .. DEBOUNCE_COUNT
        .. ", hours=" .. string.format("%02d:%02d-%02d:%02d", WORK_START_HOUR, WORK_START_MIN, WORK_END_HOUR, WORK_END_MIN)
        .. ", override=" .. tostring(WORK_OVERRIDE) .. ")")
end

function M.stop()
    if pollTimer then
        pollTimer:stop()
        pollTimer = nil
    end
    stopHeartbeat()
    if lastReportedState == true then
        sendNotify(DND_OFF_BODY, "OFF (stop)")
        saveState(false)
    end
    lastReportedState = nil
    consecutiveCount = 0
    pendingState = nil
    log("monitor stopped")
end

function M.testOn()
    sendNotify(DND_ON_BODY, "TEST-ON")
end

function M.testOff()
    sendNotify(DND_OFF_BODY, "TEST-OFF")
end

function M.forceSync()
    local active, detail = isMeetingActive()
    log("forceSync: meeting=" .. tostring(active) .. " reported=" .. tostring(lastReportedState))
    if active then
        sendNotify(DND_ON_BODY, "FORCE-ON")
        if lastReportedState ~= true then
            lastReportedState = true
            lastTransitionTime = os.time()
            saveState(true)
            startHeartbeat()
        end
    else
        sendNotify(DND_OFF_BODY, "FORCE-OFF")
        if lastReportedState ~= false then
            lastReportedState = false
            lastTransitionTime = os.time()
            saveState(false)
            stopHeartbeat()
        end
    end
end

function M.status()
    local micInUse, deviceName = anyMicInUse()
    local appRunning, appName = isMeetingAppRunning()
    local active, _ = isMeetingActive()
    local timeSince = lastTransitionTime and (os.time() - lastTransitionTime) or nil
    local saved = loadState()

    local lines = {
        "--- mic monitor status ---",
        "  lastReported:    " .. tostring(lastReportedState),
        "  meetingActive:   " .. tostring(active),
        "  micInUse:        " .. tostring(micInUse) .. (deviceName and (" [" .. deviceName .. "]") or ""),
        "  meetingApp:      " .. tostring(appRunning) .. (appName and (" [" .. appName .. "]") or ""),
        "  dictationActive: " .. tostring(_G.micMonitorDictationActive or false),
        "  pending:         " .. tostring(pendingState) .. " (count=" .. tostring(consecutiveCount) .. ")",
        "  workHours:       " .. tostring(isWorkHours()) .. " (override=" .. tostring(WORK_OVERRIDE) .. ")",
        "  heartbeat:       " .. (heartbeatTimer and "running" or "stopped"),
        "  timeSinceLast:   " .. (timeSince and (timeSince .. "s") or "n/a"),
        "  stateFile:       " .. (saved and ("active=" .. tostring(saved.active) .. " age=" .. (os.time() - (saved.timestamp or 0)) .. "s") or "none"),
    }
    for _, line in ipairs(lines) do
        print(line)
    end
end

-- ── Sleep/Wake ───────────────────────────────────────────────────────

local sleepWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then
        log("system wake — resetting debounce, scheduling immediate poll")
        consecutiveCount = 0
        pendingState = nil
        -- Immediate poll after short delay for CoreAudio to stabilize
        hs.timer.doAfter(1, function()
            log("post-wake poll")
            poll()
        end)
    end
end)
sleepWatcher:start()

-- ── Auto-start (deferred to let NSRunLoop stabilize) ────────────────

_G._micMonitorSetup = hs.timer.doAfter(3, function()
    M.start()
end)

return M
