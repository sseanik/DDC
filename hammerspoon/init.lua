-- Hammerspoon config

-- ============================================
-- Voice Dictation: F13 to toggle recording
-- ============================================
local voiceRecording = false
local voiceProcessing = false
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
        if dictationSound then dictationSound:stop(); dictationSound:play() end
        showDot()
        hs.task.new("/bin/bash", nil, {HOME .. "/.local/bin/voice-start.sh"}):start()
    else
        voiceRecording = false
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
    hs.timer.doAfter(0.15, function()
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
        macInput = "DP1",
    },
    s27 = {
        name = "S27",
        remote = true,  -- DisplayLink: DDC not supported, switch via Windows PC
        remoteHost = "192.168.1.104",
        remotePort = 9867,
        macInput = "HDMI",
        toggle = { HDMI = "DP", DP = "HDMI" },
    },
    u32 = {
        name = "U32",
        uuid = "37CF39EE-C7A8-4CC4-8C31-31A18DA16CEA",
        readMap = { [41] = "HDMI", [25] = "TB4" },
        writeMap = { HDMI = 17, TB4 = 25 },
        toggle = { HDMI = "TB4", TB4 = "HDMI" },
        macInput = "HDMI",
    },
}

-- Per-monitor lock and state tracking
local monitorLocks = {}      -- name → true if locked
local monitorWatchdogs = {}  -- name → hs.timer (watchdog for stuck operations)
local lastKnownInput = {}    -- name → last successful input label
local COOLDOWN_SEC = 2       -- debounce cooldown after lock release
local WATCHDOG_SEC = 5       -- max time before force-unlocking
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

-- Resolve target input: use provided currentInput if valid, else last-known, else macInput
local function resolveToggle(mon, currentInput)
    if currentInput and mon.toggle[currentInput] then
        return currentInput, mon.toggle[currentInput]
    end
    local remembered = lastKnownInput[mon.name]
    if remembered and mon.toggle[remembered] then
        return remembered .. "?", mon.toggle[remembered]
    end
    return mon.macInput .. "*", mon.toggle[mon.macInput]
end

-- DDC write via m1ddc
local function ddcWrite(mon, fromLabel, toLabel)
    local writeValue = mon.writeMap[toLabel]
    print("[monitor] " .. mon.name .. ": writing input=" .. tostring(writeValue) .. " (" .. fromLabel .. " → " .. toLabel .. ")")
    hs.task.new(m1ddc, function(exitCode)
        print("[monitor] " .. mon.name .. ": m1ddc write exit=" .. tostring(exitCode))
        if exitCode == 0 then
            lastKnownInput[mon.name] = toLabel
            hs.alert.show(mon.name .. ": " .. fromLabel .. " → " .. toLabel, 1)
        else
            hs.alert.show(mon.name .. " switch failed (" .. fromLabel .. " → " .. toLabel .. ")", 1.5)
        end
        releaseLock(mon)
    end, {"display", "uuid=" .. mon.uuid, "set", "input", tostring(writeValue)}):start()
end

-- Remote input switching (via HTTP to Windows PC)
local function remoteSwitch(mon)
    local fromLabel, toLabel = resolveToggle(mon, lastKnownInput[mon.name])
    local url = string.format("http://%s:%d/switch?monitor=%s&to=%s",
        mon.remoteHost, mon.remotePort, mon.name, toLabel)
    print("[monitor] " .. mon.name .. ": remote request " .. fromLabel .. " → " .. toLabel)
    hs.http.asyncGet(url, nil, function(status, body)
        if status == 200 then
            lastKnownInput[mon.name] = toLabel
            hs.alert.show(mon.name .. ": " .. fromLabel .. " → " .. toLabel, 1)
        else
            hs.alert.show(mon.name .. " remote failed (HTTP " .. tostring(status) .. ")", 1.5)
        end
        releaseLock(mon)
    end)
end

-- BetterDisplay input switching (for DisplayLink displays)
local function betterDisplaySwitch(mon)
    local fromLabel, toLabel = resolveToggle(mon, lastKnownInput[mon.name])
    local writeValue = mon.writeMap[toLabel]
    local url = string.format(
        "http://localhost:55777/set?namelike=%s&ddc=%d&vcp=inputSelect",
        mon.bdName, writeValue
    )
    hs.http.asyncGet(url, nil, function(status)
        if status == 200 then
            lastKnownInput[mon.name] = toLabel
            hs.alert.show(mon.name .. ": " .. fromLabel .. " → " .. toLabel, 1)
        else
            hs.alert.show(mon.name .. " BD failed (HTTP " .. tostring(status) .. ")", 1.5)
        end
        releaseLock(mon)
    end)
end

-- DDC read-then-toggle via m1ddc
local function ddcToggle(mon)
    hs.task.new(m1ddc, function(exitCode, stdOut)
        local currentInput = nil
        if exitCode == 0 and stdOut then
            local rawValue = tonumber(stdOut:match("%d+"))
            if rawValue then rawValue = rawValue % 256 end
            if rawValue and mon.readMap[rawValue] then
                currentInput = mon.readMap[rawValue]
            end
        end
        local fromLabel, toLabel = resolveToggle(mon, currentInput)
        ddcWrite(mon, fromLabel, toLabel)
    end, {"display", "uuid=" .. mon.uuid, "get", "input"}):start()
end

local function toggleMonitorInput(mon)
    if not acquireLock(mon) then return end

    if mon.remote then
        remoteSwitch(mon)
    elseif mon.useBetterDisplay then
        betterDisplaySwitch(mon)
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

-- Watchdog: restart monitorTap if it stops (can happen after sleep/display changes)
hs.timer.doEvery(30, function()
    if not monitorTap:isEnabled() then
        print("[monitor] eventtap died — restarting")
        monitorTap:start()
    end
end)

hs.alert.show("Ready", 1)
