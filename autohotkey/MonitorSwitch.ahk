; SYNC: This file must be kept in sync with the Windows startup copy at:
;   C:\Users\Sean\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\MonitorSwitch.ahk
; When editing, update BOTH locations.
#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent

; ============ CONFIG ============
; VCP 0x60 values: 0x0F = DP1, 0x10 = DP2, 0x11 = HDMI1, 0x12 = HDMI2
; Run scan mode (Ctrl+Alt+F12) to discover/verify input codes
Monitors := [
    {name: "G2724D",   win: 0x0F, mac: 0x13},  ; Dell G2724D:   DP1 (0x0F) ↔ DP2 (0x13)
    {name: "S2721DGF", win: 0x0F, mac: 0x11},  ; Dell S2721DGF: DP  (0x0F) ↔ HDMI1 (0x11)
    {name: "U3225QE",  win: 0x19, mac: 0x11},   ; Dell U3225QE:  TB4 (0x19) ↔ HDMI1 (0x11)
]

; ============ HOTKEYS ============
^!Numpad1:: ToggleMonitor(1)
^!Numpad2:: ToggleMonitor(2)
^!Numpad3:: ToggleMonitor(3)
^!F12::     ScanMonitors()
^!F11::     CacheMonitorHandles()  ; Manual re-cache if monitors change

; ============ HANDLE CACHE ============
; Cache physical monitor handles at startup so hotkeys skip re-enumeration.
; Maps monitor config name → {hPhys: handle}
; Handles are NOT destroyed — kept alive for fast repeated access.
; Press Ctrl+Alt+F11 to re-cache if monitors are plugged/unplugged.

global HandleCache := Map()

CacheMonitorHandles() {
    global HandleCache, Monitors
    ; Destroy any previously cached handles
    for name, entry in HandleCache
        DllCall("dxva2\DestroyPhysicalMonitor", "Ptr", entry.hPhys, "Int")
    HandleCache := Map()

    EnumPhysicalMonitors(CacheCallback, false)  ; false = don't destroy handles

    cached := []
    for name, _ in HandleCache
        cached.Push(name)
    if cached.Length
        ShowTip("Cached " cached.Length " monitor(s): " ArrayJoin(cached, ", "))
    else
        ShowTip("No monitors found to cache!")
}

CacheCallback(hMon, hPhys, desc) {
    global HandleCache, Monitors
    for cfg in Monitors {
        if InStr(desc, cfg.name) && !HandleCache.Has(cfg.name) {
            HandleCache[cfg.name] := {hPhys: hPhys}
            return
        }
    }
}

ArrayJoin(arr, sep) {
    s := ""
    for i, v in arr
        s .= (i > 1 ? sep : "") . v
    return s
}

; ============ CORE ============

ToggleMonitor(index) {
    global Monitors, HandleCache
    cfg := Monitors[index]

    ; Fast path: use cached handle
    if HandleCache.Has(cfg.name) {
        hPhys := HandleCache[cfg.name].hPhys
        current := VCPGet(hPhys, 0x60)
        if current != -1 {
            target := (current = cfg.win) ? cfg.mac : cfg.win
            direction := (current = cfg.win) ? "→ Mac" : "→ Windows"
            if VCPSet(hPhys, 0x60, target) {
                ShowTip(cfg.name " " direction)
            } else {
                ShowTip(cfg.name ": set failed, re-caching...")
                CacheMonitorHandles()
            }
            return
        }
        ; Read failed — handle may be stale, fall through to re-cache
        ShowTip(cfg.name ": stale handle, re-caching...")
        CacheMonitorHandles()
        ; Retry once with fresh handle
        if HandleCache.Has(cfg.name) {
            hPhys := HandleCache[cfg.name].hPhys
            current := VCPGet(hPhys, 0x60)
            if current != -1 {
                target := (current = cfg.win) ? cfg.mac : cfg.win
                direction := (current = cfg.win) ? "→ Mac" : "→ Windows"
                if VCPSet(hPhys, 0x60, target)
                    ShowTip(cfg.name " " direction)
                else
                    ShowTip(cfg.name ": failed to set input")
            } else {
                ShowTip(cfg.name ": failed to read input")
            }
        } else {
            ShowTip("Monitor not found: " cfg.name)
        }
        return
    }

    ; No cache entry — try to cache and retry
    CacheMonitorHandles()
    if HandleCache.Has(cfg.name) {
        ToggleMonitor(index)  ; Retry with cache
    } else {
        ShowTip("Monitor not found: " cfg.name)
    }
}

ScanMonitors() {
    output := "=== Monitor Scan ===`n`n"
    EnumPhysicalMonitors(ScanCallback.Bind(&output))

    if output = "=== Monitor Scan ===`n`n"
        output .= "No monitors found.`n"

    g := Gui("+AlwaysOnTop", "Monitor Scan Results")
    g.SetFont("s10", "Consolas")
    g.Add("Edit", "w600 h300 ReadOnly", output)
    g.Add("Button", "Default w80", "OK").OnEvent("Click", (*) => g.Destroy())
    g.Show()
}

ScanCallback(&output, hMon, hPhys, desc) {
    current := VCPGet(hPhys, 0x60)
    inputStr := (current >= 0) ? Format("0x{:02X}", current) : "ERR"
    output .= Format("Desc: {}  |  Input(0x60): {}`n", desc, inputStr)
}


; ============ DDC/CI ============

VCPGet(hPhysMon, code) {
    r := DllCall("dxva2\GetVCPFeatureAndVCPFeatureReply"
        , "Ptr", hPhysMon
        , "UChar", code
        , "Ptr", 0
        , "UInt*", &currentValue := 0
        , "UInt*", &maxValue := 0
        , "Int")
    ; Dell monitors duplicate the value byte into both SH and SL of the DDC response,
    ; so the DWORD reads as e.g. 0x0F0F instead of 0x0F. The real value is the low byte.
    return r ? (currentValue & 0xFF) : -1
}

VCPSet(hPhysMon, code, value) {
    return DllCall("dxva2\SetVCPFeature"
        , "Ptr", hPhysMon
        , "UChar", code
        , "UInt", value
        , "Int")
}

; ============ ENUMERATION ============

; Calls fn(hMonitor, hPhysicalMonitor, description) for each physical monitor.
; If destroyHandles is true (default), handles are cleaned up after the callback.
; Pass false when caching handles for reuse.
EnumPhysicalMonitors(fn, destroyHandles := true) {
    ; Collect hMonitor handles first (can't nest callbacks easily)
    hMonitors := []
    enumCb := CallbackCreate(CollectMonitors.Bind(hMonitors), "Fast", 4)
    DllCall("user32\EnumDisplayMonitors", "Ptr", 0, "Ptr", 0, "Ptr", enumCb, "Ptr", 0, "Int")
    CallbackFree(enumCb)

    for hMon in hMonitors {
        numPhys := Buffer(4, 0)
        if !DllCall("dxva2\GetNumberOfPhysicalMonitorsFromHMONITOR", "Ptr", hMon, "Ptr", numPhys, "Int")
            continue
        count := NumGet(numPhys, 0, "UInt")
        if count = 0
            continue

        ; PHYSICAL_MONITOR: 8 bytes handle + 128 WCHARs (256 bytes) = 264 bytes each (x64, no padding needed)
        structSize := 8 + 128 * 2
        physArr := Buffer(count * structSize, 0)
        if !DllCall("dxva2\GetPhysicalMonitorsFromHMONITOR", "Ptr", hMon, "UInt", count, "Ptr", physArr, "Int")
            continue

        Loop count {
            offset := (A_Index - 1) * structSize
            hPhys := NumGet(physArr, offset, "Ptr")
            desc := StrGet(physArr.Ptr + offset + 8, 128, "UTF-16")
            fn(hMon, hPhys, desc)
            if destroyHandles
                DllCall("dxva2\DestroyPhysicalMonitor", "Ptr", hPhys, "Int")
        }
    }
}

CollectMonitors(hMonitors, hMonitor, hDC, pRect, lParam) {
    hMonitors.Push(hMonitor)
    return 1
}

; ============ HTTP SERVER (for remote switching from Mac) ============

HttpPort := 9867

; Monitor name mapping: Mac name → {AHK config index, input name → VCP value}
RemoteMap := Map(
    "S27", {index: 2, inputs: Map("DP", 0x0F, "HDMI", 0x11)},
    "G27", {index: 1, inputs: Map("DP1", 0x0F, "DP2", 0x13)},
    "U32", {index: 3, inputs: Map("TB4", 0x19, "HDMI", 0x11)},
)

StartHttpServer() {
    global HttpSocket, HttpPort
    HttpSocket := Socket()
    HttpSocket.SetReuseAddr()
    if !HttpSocket.Bind(HttpPort) {
        ShowTip("HTTP server failed to bind port " HttpPort)
        return
    }
    if !HttpSocket.Listen() {
        ShowTip("HTTP server failed to listen")
        return
    }
    SetTimer(HttpAccept, 250)
}

HttpAccept() {
    global HttpSocket
    client := HttpSocket.Accept()
    if !client
        return
    client.SetRecvTimeout(2000)
    ; Read request (small buffer is fine for our simple GET requests)
    data := client.Recv(1024)
    if !data {
        client.Close()
        return
    }

    ; Parse GET /toggle?monitor=S27 (reads current input, toggles it)
    ; Parse GET /switch?monitor=S27&to=DP (sets specific input)
    if RegExMatch(data, "GET /toggle\?monitor=(\w+)", &m) {
        monName := m[1]
        result := RemoteToggle(monName, &body)
        status := result ? "200 OK" : "400 Bad Request"
        if !result
            body := "FAIL"
    } else if RegExMatch(data, "GET /switch\?monitor=(\w+)&to=(\w+)", &m) {
        monName := m[1]
        targetInput := m[2]
        result := RemoteSwitch(monName, targetInput)
        status := result ? "200 OK" : "400 Bad Request"
        body := result ? "OK" : "FAIL"
    } else {
        status := "404 Not Found"
        body := "Not Found"
    }

    response := "HTTP/1.1 " status "`r`nContent-Length: " StrLen(body) "`r`nConnection: close`r`n`r`n" body
    client.Send(response)
    client.Close()
}

RemoteToggle(monName, &body) {
    global RemoteMap, Monitors, HandleCache
    if !RemoteMap.Has(monName)
        return false
    rm := RemoteMap[monName]
    cfg := Monitors[rm.index]

    if !HandleCache.Has(cfg.name)
        CacheMonitorHandles()
    if !HandleCache.Has(cfg.name) {
        body := "FAIL: monitor not found in cache"
        return false
    }

    hPhys := HandleCache[cfg.name].hPhys
    current := VCPGet(hPhys, 0x60)
    if current = -1 {
        CacheMonitorHandles()
        if !HandleCache.Has(cfg.name) {
            body := "FAIL: monitor lost after re-cache"
            return false
        }
        hPhys := HandleCache[cfg.name].hPhys
        current := VCPGet(hPhys, 0x60)
        if current = -1 {
            body := "FAIL: DDC read failed (got -1)"
            return false
        }
    }
    target := (current = cfg.win) ? cfg.mac : cfg.win
    direction := (current = cfg.win) ? "→ Mac" : "→ Windows"
    if VCPSet(hPhys, 0x60, target) {
        body := direction
        ShowTip(cfg.name " " direction " (remote) [read=0x" Format("{:02X}", current) " target=0x" Format("{:02X}", target) "]")
        return true
    }
    body := "FAIL: DDC write failed [read=0x" Format("{:02X}", current) " target=0x" Format("{:02X}", target) "]"
    return false
}

RemoteSwitch(monName, targetInput) {
    global RemoteMap, Monitors, HandleCache
    if !RemoteMap.Has(monName)
        return false
    rm := RemoteMap[monName]
    if !rm.inputs.Has(targetInput)
        return false
    targetValue := rm.inputs[targetInput]
    cfg := Monitors[rm.index]

    if !HandleCache.Has(cfg.name)
        CacheMonitorHandles()
    if !HandleCache.Has(cfg.name)
        return false

    hPhys := HandleCache[cfg.name].hPhys
    if VCPSet(hPhys, 0x60, targetValue) {
        direction := (targetValue = cfg.mac) ? "→ Mac (remote)" : "→ Windows (remote)"
        ShowTip(cfg.name " " direction)
        return true
    }
    ; Retry with fresh handle
    CacheMonitorHandles()
    if !HandleCache.Has(cfg.name)
        return false
    hPhys := HandleCache[cfg.name].hPhys
    if VCPSet(hPhys, 0x60, targetValue) {
        direction := (targetValue = cfg.mac) ? "→ Mac (remote)" : "→ Windows (remote)"
        ShowTip(cfg.name " " direction)
        return true
    }
    return false
}

; ============ SOCKET CLASS (minimal TCP wrapper) ============

class Socket {
    __New(sock := 0) {
        static wsaStarted := false
        if !wsaStarted {
            wsaData := Buffer(408, 0)
            DllCall("ws2_32\WSAStartup", "UShort", 0x0202, "Ptr", wsaData)
            wsaStarted := true
        }
        this.sock := sock ? sock : DllCall("ws2_32\socket", "Int", 2, "Int", 1, "Int", 6, "Ptr")
    }

    SetReuseAddr() {
        optval := Buffer(4, 0)
        NumPut("UInt", 1, optval, 0)
        DllCall("ws2_32\setsockopt", "Ptr", this.sock, "Int", 0xFFFF, "Int", 0x0004, "Ptr", optval, "Int", 4, "Int")
    }

    SetRecvTimeout(ms) {
        tv := Buffer(4, 0)
        NumPut("UInt", ms, tv, 0)
        DllCall("ws2_32\setsockopt", "Ptr", this.sock, "Int", 0xFFFF, "Int", 0x1006, "Ptr", tv, "Int", 4, "Int")
    }

    Bind(port) {
        addr := Buffer(16, 0)
        NumPut("UShort", 2, addr, 0)           ; AF_INET
        NumPut("UShort", this._htons(port), addr, 2)
        NumPut("UInt", 0, addr, 4)              ; INADDR_ANY
        return DllCall("ws2_32\bind", "Ptr", this.sock, "Ptr", addr, "Int", 16, "Int") = 0
    }

    Listen() {
        return DllCall("ws2_32\listen", "Ptr", this.sock, "Int", 5, "Int") = 0
    }

    Accept() {
        ; Non-blocking check
        readSet := Buffer(A_PtrSize + 8, 0)
        NumPut("UInt", 1, readSet, 0)
        NumPut("Ptr", this.sock, readSet, A_PtrSize)
        timeout := Buffer(8, 0)  ; 0 seconds = poll
        r := DllCall("ws2_32\select", "Int", 0, "Ptr", readSet, "Ptr", 0, "Ptr", 0, "Ptr", timeout, "Int")
        if r <= 0
            return false
        newSock := DllCall("ws2_32\accept", "Ptr", this.sock, "Ptr", 0, "Ptr", 0, "Ptr")
        return (newSock = -1) ? false : Socket(newSock)
    }

    Recv(maxLen) {
        buf := Buffer(maxLen, 0)
        n := DllCall("ws2_32\recv", "Ptr", this.sock, "Ptr", buf, "Int", maxLen, "Int", 0, "Int")
        return (n > 0) ? StrGet(buf, n, "UTF-8") : ""
    }

    Send(str) {
        buf := Buffer(StrPut(str, "UTF-8") - 1)
        StrPut(str, buf, "UTF-8")
        DllCall("ws2_32\send", "Ptr", this.sock, "Ptr", buf, "Int", buf.Size, "Int", 0, "Int")
    }

    Close() {
        DllCall("ws2_32\closesocket", "Ptr", this.sock)
    }

    _htons(val) {
        return ((val & 0xFF) << 8) | ((val >> 8) & 0xFF)
    }
}

CacheMonitorHandles()
StartHttpServer()

; ============ UTILITY ============

ShowTip(msg) {
    ToolTip(msg)
    SetTimer(() => ToolTip(), -2000)
}
