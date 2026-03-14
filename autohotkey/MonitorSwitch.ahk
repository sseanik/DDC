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
    {name: "S2721DGF", win: 0x0F, mac: 0x12},  ; Dell S2721DGF: DP  (0x0F) ↔ HDMI2 (0x12)
    {name: "U3225QE",  win: 0x19, mac: 0x11},   ; Dell U3225QE:  TB4 (0x19) ↔ HDMI1 (0x11)
]

; ============ HOTKEYS ============
^!Numpad1:: ToggleMonitor(1)
^!Numpad2:: ToggleMonitor(2)
^!Numpad3:: ToggleMonitor(3)
^!F12::     ScanMonitors()

; ============ CORE ============

ToggleMonitor(index) {
    global Monitors
    cfg := Monitors[index]
    found := false
    EnumPhysicalMonitors(ToggleCallback.Bind(cfg, &found))
    if !found
        ShowTip("Monitor not found: " cfg.name)
}

ToggleCallback(cfg, &found, hMon, hPhys, desc) {
    if found || !InStr(desc, cfg.name)
        return
    found := true
    current := VCPGet(hPhys, 0x60)
    if current = -1 {
        ShowTip(cfg.name ": failed to read input")
        return
    }
    target := (current = cfg.win) ? cfg.mac : cfg.win
    direction := (current = cfg.win) ? "→ Mac" : "→ Windows"
    if VCPSet(hPhys, 0x60, target)
        ShowTip(cfg.name " " direction)
    else
        ShowTip(cfg.name ": failed to set input")
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
; Handles all allocation and cleanup.
EnumPhysicalMonitors(fn) {
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
            DllCall("dxva2\DestroyPhysicalMonitor", "Ptr", hPhys, "Int")
        }
    }
}

CollectMonitors(hMonitors, hMonitor, hDC, pRect, lParam) {
    hMonitors.Push(hMonitor)
    return 1
}

; ============ UTILITY ============

ShowTip(msg) {
    ToolTip(msg)
    SetTimer(() => ToolTip(), -2000)
}
