#Requires AutoHotkey v2.0
#SingleInstance Force
;
; SteamSaveTimeline.ahk -- passive boot hook for the Steam save timeline.
;
; Starts steam_save_watcher.ps1 hidden at log on and keeps a tray icon so the
; timeline browser is one click away. The PowerShell scripts do all the work
; and are unchanged by this; nothing here is required to use them.
;
; IT BINDS NO HOTKEYS, deliberately. Hotkeys.exe is the single resident hotkey
; host on this machine, and two hosts competing for the same key would fight.
; If you want a hotkey for the browser, add a row to Hotkeys.ahk's BINDINGS
; table instead -- that is the one place hotkeys belong.
;
; Compiling means AutoHotkey does NOT have to be installed to run this: the exe
; bundles the v2 runtime. AHK is only needed to rebuild it. Stop the running exe
; first or the output file is locked:
;
;   "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in SteamSaveTimeline.ahk ^
;     /out SteamSaveTimeline.exe /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
;
; Keep the exe BESIDE the .ps1 files -- it finds them through A_ScriptDir. To
; start it at log on, put a shortcut to it in shell:startup; steam_save_setup.ps1
; offers to do exactly that.

Persistent

SCRIPTS  := A_ScriptDir
WATCHER  := SCRIPTS "\steam_save_watcher.ps1"
BROWSER  := SCRIPTS "\steam_save_restore_gui.ps1"
SETUP    := SCRIPTS "\steam_save_setup.ps1"
WatchPid := 0

if !FileExist(WATCHER) {
    MsgBox("Cannot find steam_save_watcher.ps1 next to this program.`n`n"
         . "Keep " A_ScriptName " in the same folder as the scripts.",
           "Steam Save Timeline", "Icon!")
    ExitApp
}

BuildTray()
StartWatcher()
OnExit(StopWatcher)
return

; ---------------------------------------------------------------- tray

BuildTray() {
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Open timeline browser", (*) => RunPS(BROWSER, false))
    A_TrayMenu.Add("Snapshot everything now", (*) => SnapshotNow())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Restart capture", (*) => RestartWatcher())
    A_TrayMenu.Add("Setup...", (*) => RunPS(SETUP, false))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_TrayMenu.Default := "Open timeline browser"
    A_IconTip := "Steam Save Timeline - capturing"
}

; ---------------------------------------------------------------- actions

; Hidden for the daemon, visible for anything the user asked for by hand --
; a manual action with no feedback looks broken.
RunPS(file, hidden := true, args := "") {
    global SCRIPTS
    if !FileExist(file) {
        MsgBox("Missing: " file, "Steam Save Timeline", "Icon!")
        return 0
    }
    cmd := 'powershell.exe -NoProfile -ExecutionPolicy Bypass'
         . (hidden ? ' -WindowStyle Hidden' : '')
         . ' -File "' file '"' (args ? " " args : "")
    try {
        Run(cmd, SCRIPTS, hidden ? "Hide" : "", &pid)
        return pid
    } catch as e {
        MsgBox("Could not start:`n" file "`n`n" e.Message, "Steam Save Timeline", "Icon!")
        return 0
    }
}

StartWatcher() {
    global WATCHER, WatchPid
    WatchPid := RunPS(WATCHER, true)
}

StopWatcher(*) {
    global WatchPid
    if WatchPid {
        try ProcessClose(WatchPid)
        WatchPid := 0
    }
}

RestartWatcher() {
    StopWatcher()
    Sleep 500
    StartWatcher()
    TrayTip("Capture restarted", "Steam Save Timeline")
}

; One-shot sweep, shown so the output is visible.
SnapshotNow() {
    global WATCHER
    RunPS(WATCHER, false, "-Once")
}
