-- Hammerspoon config

-- ============================================
-- Voice Dictation: F13 to toggle recording
-- ============================================
local voiceRecording = false
local voiceProcessing = false
_G.micMonitorDictationActive = false
local HOME = os.getenv("HOME")
local dictationSound = hs.sound.getByFile(HOME .. "/.hammerspoon/sounds/DefaultRecognitionSound.aiff")
local voiceIndicator = nil

local function showDot()
    local screen = hs.screen.mainScreen()
    local frame = screen:fullFrame()
    voiceIndicator = hs.canvas.new({ x = frame.w - 28, y = frame.y + 12, w = 16, h = 16 })
    voiceIndicator:level(hs.canvas.windowLevels.overlay)
    voiceIndicator[1] = {
        type = "circle",
        fillColor = { red = 1, green = 0, blue = 0, alpha = 1 },
        strokeWidth = 0,
    }
    voiceIndicator:show()
end

local function hideDot()
    if voiceIndicator then voiceIndicator:delete(); voiceIndicator = nil end
end

local voiceTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
    if e:getKeyCode() ~= 105 then return false end
    if voiceProcessing then return true end

    if not voiceRecording then
        voiceRecording = true
        _G.micMonitorDictationActive = true
        if dictationSound then dictationSound:stop(); dictationSound:play() end
        showDot()
        hs.task.new("/bin/bash", nil, {HOME .. "/.local/bin/voice-start.sh"}):start()
    else
        voiceRecording = false
        _G.micMonitorDictationActive = false
        voiceProcessing = true
        hideDot()
        if dictationSound then dictationSound:stop(); dictationSound:play() end
        hs.alert.show("Transcribing...", 2)
        hs.task.new("/bin/bash", function(exitCode, stdOut, stdErr)
            voiceProcessing = false
            if exitCode == 0 and stdOut and #stdOut > 0 then
                local tink = hs.sound.getByName("Tink")
                if tink then tink:play() end
                hs.alert.show("Copied to clipboard", 1.5)
            else
                hs.alert.show((stdErr and #stdErr > 0) and stdErr or "No speech detected", 2)
            end
        end, {HOME .. "/.local/bin/voice-stop.sh"}):start()
    end
    return true
end)
voiceTap:start()

-- F18 → Copy (⌘C)
hs.hotkey.bind({}, "F18", function()
    hs.eventtap.keyStroke({"cmd"}, "c", 0)
end)

-- F19 → Paste without style (⌥⇧⌘V)
hs.hotkey.bind({}, "F19", function()
    hs.eventtap.keyStroke({"cmd", "shift", "alt"}, "v", 0)
end)

-- ⌥⌘ + NUMPAD 0 → Restart Taskbar
hs.hotkey.bind({ "alt", "cmd" }, "pad0", function()
    local appPath = "/Applications/Taskbar.app"
    hs.execute([[/usr/bin/pkill -x "Taskbar" >/dev/null 2>&1]])
    hs.execute([[/usr/bin/pkill -f "/Applications/Taskbar\.app/" >/dev/null 2>&1]])
    hs.timer.doAfter(1, function()
        hs.execute(string.format([[/usr/bin/open "%s" >/dev/null 2>&1]], appPath))
    end)
end)

-- Remap ⇧⌘V to ⌥⇧⌘V (Paste without style)
local remapShiftCmdV = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local flags = event:getFlags()
    local keyCode = event:getKeyCode()
    if keyCode == hs.keycodes.map["v"] and flags.cmd and flags.shift and not flags.alt and not flags.ctrl then
        hs.eventtap.keyStroke({ "cmd", "shift", "alt" }, "v", 0)
        return true
    end
    return false
end)
remapShiftCmdV:start()

-- ============================================
-- Monitor Input Switching via DDC (m1ddc)
-- ============================================
local m1ddc = "/opt/homebrew/bin/m1ddc"

local monitors = {
    g27 = {
        name = "G27",
        uuid = "C8F0D4ED-3C53-41B0-AEED-58C787AA305A",
        readMap = { [15] = "DP1", [110] = "DP1", [19] = "DP2" },
        writeMap = { DP1 = 15, DP2 = 19 },
        toggle = { DP1 = "DP2", DP2 = "DP1" },
    },
    s27 = {
        name = "S27",
        remote = true,  -- DisplayLink: DDC not supported, switch via Windows PC
        remoteHost = "192.168.1.104",
        remotePort = 9867,
        toggle = { HDMI = "DP", DP = "HDMI" },
    },
    u32 = {
        name = "U32",
        uuid = "37CF39EE-C7A8-4CC4-8C31-31A18DA16CEA",
        readMap = { [17] = "HDMI", [25] = "TB4" },
        writeMap = { HDMI = 17, TB4 = 25 },
        toggle = { HDMI = "TB4", TB4 = "HDMI" },
        blindToggle = true,  -- DDC reads are broken on this monitor; track state instead
        defaultInput = "TB4",  -- Mac is connected via TB4
    },
}

-- Per-monitor lock
local monitorLocks = {}      -- name → true if locked
local monitorWatchdogs = {}  -- name → hs.timer (watchdog for stuck operations)
local COOLDOWN_SEC = 0.5     -- debounce cooldown after lock release
local WATCHDOG_SEC = 5       -- max time before force-unlocking (read + write)
local lastSwitchTime = {}    -- name → hs.timer.secondsSinceEpoch() of last unlock

local function acquireLock(mon)
    local name = mon.name
    if monitorLocks[name] then
        print("[monitor] " .. name .. ": REJECTED (locked)")
        hs.alert.show(name .. ": busy (locked)", 0.8)
        return false
    end
    -- Debounce: reject if last switch was too recent
    if lastSwitchTime[name] and (hs.timer.secondsSinceEpoch() - lastSwitchTime[name]) < COOLDOWN_SEC then
        print("[monitor] " .. name .. ": REJECTED (cooldown)")
        hs.alert.show(name .. ": cooldown", 0.8)
        return false
    end
    print("[monitor] " .. name .. ": lock acquired")
    monitorLocks[name] = true
    -- Watchdog: force-unlock after timeout so a stuck operation can't permanently lock
    monitorWatchdogs[name] = hs.timer.doAfter(WATCHDOG_SEC, function()
        if monitorLocks[name] then
            monitorLocks[name] = false
            lastSwitchTime[name] = hs.timer.secondsSinceEpoch()
            monitorWatchdogs[name] = nil
            hs.alert.show(name .. ": watchdog unlock (m1ddc hung?)", 1.5)
        end
    end)
    return true
end

local function releaseLock(mon)
    local name = mon.name
    monitorLocks[name] = false
    lastSwitchTime[name] = hs.timer.secondsSinceEpoch()
    if monitorWatchdogs[name] then
        monitorWatchdogs[name]:stop()
        monitorWatchdogs[name] = nil
    end
end

-- Remote input switching (via HTTP to Windows PC)
-- Uses /toggle endpoint — Windows reads the current input and toggles it
local REMOTE_TIMEOUT_SEC = 2
local function remoteSwitch(mon)
    local url = string.format("http://%s:%d/toggle?monitor=%s",
        mon.remoteHost, mon.remotePort, mon.name)
    print("[monitor] " .. mon.name .. ": remote toggle request")
    local responded = false
    hs.http.asyncGet(url, nil, function(status, body)
        if responded then return end
        responded = true
        if status == 200 and body then
            hs.alert.show(mon.name .. ": " .. body, 1)
        elseif status == 200 then
            hs.alert.show(mon.name .. ": toggled", 1)
        else
            hs.alert.show(mon.name .. " remote failed (HTTP " .. tostring(status) .. ")", 1.5)
        end
        releaseLock(mon)
    end)
    hs.timer.doAfter(REMOTE_TIMEOUT_SEC, function()
        if responded then return end
        responded = true
        print("[monitor] " .. mon.name .. ": remote timeout")
        hs.alert.show(mon.name .. ": PC unreachable", 1.5)
        releaseLock(mon)
    end)
end

-- Tracked state for monitors with blindToggle enabled (DDC reads broken)
local blindState = {}

-- Parse m1ddc DDC output: try high byte, low byte, then raw value
local function parseDDCInput(mon, rawVal)
    if not rawVal then return nil end
    -- Try high byte (m1ddc combined format: current * 256 + max)
    local hi = math.floor(rawVal / 256)
    if hi > 0 and mon.readMap[hi] then return mon.readMap[hi], hi end
    -- Try low byte (some monitors pack differently)
    local lo = rawVal % 256
    if lo > 0 and mon.readMap[lo] then return mon.readMap[lo], lo end
    -- Try raw value directly (single-value format)
    if mon.readMap[rawVal] then return mon.readMap[rawVal], rawVal end
    return nil, nil
end

-- DDC write: switch monitor to target input
local function ddcWrite(mon, currentInput, targetInput)
    local writeValue = mon.writeMap[targetInput]
    print("[monitor] " .. mon.name .. ": switching " .. currentInput .. " → " .. targetInput .. " (DDC " .. tostring(writeValue) .. ")")
    local writeTask = hs.task.new(m1ddc, function(wExitCode)
        if wExitCode == 0 then
            hs.alert.show(mon.name .. ": " .. currentInput .. " → " .. targetInput, 1)
            -- Update blind state tracker
            blindState[mon.name] = targetInput
        else
            hs.alert.show(mon.name .. ": write failed", 1.5)
        end
        releaseLock(mon)
    end, {"display", "uuid=" .. mon.uuid, "set", "input", tostring(writeValue)})
    if writeTask then
        writeTask:start()
    else
        hs.alert.show(mon.name .. ": m1ddc not found", 1.5)
        releaseLock(mon)
    end
end

-- DDC toggle with retry: read current input (up to DDC_MAX_RETRIES), then write the opposite
local DDC_MAX_RETRIES = 5

local function ddcReadWithRetry(mon, attempt)
    if attempt > DDC_MAX_RETRIES then
        print("[monitor] " .. mon.name .. ": all " .. DDC_MAX_RETRIES .. " DDC reads failed")
        hs.alert.show(mon.name .. ": DDC read failed (retries exhausted)", 1.5)
        releaseLock(mon)
        return
    end
    local readTask = hs.task.new(m1ddc, function(exitCode, stdOut)
        if exitCode == 0 and stdOut then
            local rawVal = tonumber(stdOut:match("%d+"))
            local currentInput, val = parseDDCInput(mon, rawVal)
            if currentInput then
                print("[monitor] " .. mon.name .. ": DDC raw=" .. tostring(rawVal) .. " → input " .. tostring(val) .. " (" .. currentInput .. ") [attempt " .. attempt .. "]")
                local targetInput = mon.toggle[currentInput]
                ddcWrite(mon, currentInput, targetInput)
                return
            else
                print("[monitor] " .. mon.name .. ": unknown DDC value raw=" .. tostring(rawVal) .. " [attempt " .. attempt .. "/" .. DDC_MAX_RETRIES .. "]")
            end
        else
            print("[monitor] " .. mon.name .. ": DDC read failed exit=" .. tostring(exitCode) .. " [attempt " .. attempt .. "/" .. DDC_MAX_RETRIES .. "]")
        end
        -- Retry after a short delay
        hs.timer.doAfter(0.1, function()
            ddcReadWithRetry(mon, attempt + 1)
        end)
    end, {"display", "uuid=" .. mon.uuid, "get", "input"})
    if readTask then
        readTask:start()
    else
        hs.alert.show(mon.name .. ": m1ddc not found", 1.5)
        releaseLock(mon)
    end
end

-- DDC toggle: read current input, then write the opposite
local function ddcToggle(mon)
    -- Blind toggle for monitors with broken DDC reads
    if mon.blindToggle then
        local currentInput = blindState[mon.name] or mon.defaultInput
        local targetInput = mon.toggle[currentInput]
        print("[monitor] " .. mon.name .. ": blind toggle " .. currentInput .. " → " .. targetInput)
        ddcWrite(mon, currentInput, targetInput)
        return
    end
    ddcReadWithRetry(mon, 1)
end

local function toggleMonitorInput(mon)
    if not acquireLock(mon) then return end

    if mon.remote then
        remoteSwitch(mon)
    else
        ddcToggle(mon)
    end
end

-- Cmd+Alt+Numpad → Monitor input switching (eventtap, since hs.hotkey.bind is unreliable with numpad)
local monitorTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
    local code = e:getKeyCode()
    if code ~= 83 and code ~= 84 and code ~= 85 then return false end
    local flags = e:getFlags()
    if not (flags.cmd and flags.alt) then return false end
    local monName = ({[83]="g27", [84]="s27", [85]="u32"})[code]
    print("[monitor] keypress: numpad" .. (code - 82) .. " → " .. monName)
    toggleMonitorInput(monitors[monName])
    return true
end)
monitorTap:start()

-- All eventtaps that need watchdog protection
local allTaps = { monitorTap, voiceTap, remapShiftCmdV }

-- Force-restart all eventtaps (stop + start) to recover from stale CGEventTaps
local function restartAllTaps(reason)
    print("[eventtap] restarting all taps (" .. reason .. ")")
    for _, tap in ipairs(allTaps) do
        tap:stop()
        tap:start()
    end
end

-- Watchdog: force-restart eventtaps periodically (isEnabled() can't detect stale CGEventTaps)
hs.timer.doEvery(120, function()
    restartAllTaps("periodic")
end)

-- Screen config changes (e.g. DDC input switch causes display to disappear/reappear)
local screenWatcher = hs.screen.watcher.new(function()
    print("[eventtap] screen configuration changed — scheduling tap restart")
    -- Delay to let macOS finish reconfiguring displays
    hs.timer.doAfter(2, function()
        restartAllTaps("screen change")
    end)
end)
screenWatcher:start()

-- Sleep/wake: clear stale locks and restart eventtaps
local sleepWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake then
        print("[monitor] system wake — resetting state")
        for _, mon in pairs(monitors) do
            monitorLocks[mon.name] = false
            if monitorWatchdogs[mon.name] then
                monitorWatchdogs[mon.name]:stop()
                monitorWatchdogs[mon.name] = nil
            end
            lastSwitchTime[mon.name] = nil
        end
        -- Restart eventtaps after a short delay (system needs time to stabilize)
        -- Must stop+start unconditionally — isEnabled() can't detect stale CGEventTaps
        hs.timer.doAfter(2, function()
            restartAllTaps("wake")
        end)
        -- Re-apply DDC brightness/contrast/color settings (they reset after sleep)
        hs.timer.doAfter(3, function()
            print("[monitor] re-syncing DDC settings after wake")
            hs.task.new("/bin/bash", function(exitCode)
                if exitCode == 0 then
                    print("[monitor] sync-monitors.sh completed successfully")
                else
                    print("[monitor] sync-monitors.sh failed (exit " .. tostring(exitCode) .. ")")
                end
            end, {"/Users/sean.smith/bin/sync-monitors.sh"}):start()
        end)
    end
end)
sleepWatcher:start()

package.loaded["mic_monitor"] = nil
micMonitor = require("mic_monitor")

hs.alert.show("Ready", 1)
