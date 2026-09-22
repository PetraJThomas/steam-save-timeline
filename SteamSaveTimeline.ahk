#Requires AutoHotkey v2.0
#SingleInstance Force
;
; SteamSaveTimeline.ahk -- passive boot hook for the Steam save timeline.
;
; Starts steam_save_watcher.ps1 hidden at log on and keeps a tray icon so the
; Steam Save Timeline Browser is one click away. The PowerShell scripts do all the work
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
;     /out SteamSaveTimeline.exe /icon SteamSaveTimeline.ico ^
;     /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
;
; /icon is what gives the EXE its own icon in Explorer and the taskbar.
; TraySetIcon below only changes the tray icon at runtime, so without /icon the
; compiled file still carries the stock AutoHotkey icon.
;
; Keep the exe BESIDE the .ps1 files -- it finds them through A_ScriptDir. To
; start it at log on, put a shortcut to it in shell:startup; steam_save_setup.ps1
; offers to do exactly that.

Persistent

SCRIPTS  := A_ScriptDir
WATCHER  := SCRIPTS "\steam_save_watcher.ps1"
BROWSER  := SCRIPTS "\steam_save_restore_gui.ps1"
SETUP    := SCRIPTS "\steam_save_setup.ps1"
STARTUP_LNK := A_Startup "\Steam Save Timeline.lnk"
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
    A_TrayMenu.Add("Open Steam Save Timeline Browser", (*) => RunPS(BROWSER, true))
    A_TrayMenu.Add("Snapshot everything now", (*) => SnapshotNow())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Restart capture", (*) => RestartWatcher())
    A_TrayMenu.Add("Start with Windows", (*) => ToggleStartup())
    A_TrayMenu.Add("Setup...", (*) => RunPS(SETUP, true))
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit", (*) => ExitApp())
    A_TrayMenu.Default := "Open Steam Save Timeline Browser"
    ; Windows' own "previous versions" icon. Not the cloud nearby (that is the
    ; OneDrive glyph, and this tool offers OneDrive as a destination) and not
    ; the sync arrows nearby (an overlay badge: 22% fill, so it shrinks to a
    ; dot). AutoHotkey numbers icons from 1 and ExtractIconEx from 0, so this is
    ; 143 here and 142 in steam_save_theme.ps1. Same picture.
    try TraySetIcon(A_WinDir "\System32\imageres.dll", 143)
    A_IconTip := "Steam Save Timeline - capturing"
    if FileExist(STARTUP_LNK)
        A_TrayMenu.Check("Start with Windows")
}

; Reachable without opening the setup window, because "make this keep happening"
; is the one setting anyone changes after the first run. A_ScriptFullPath is the
; exe once compiled, so the shortcut points at the right thing either way.
ToggleStartup() {
    global STARTUP_LNK
    if FileExist(STARTUP_LNK) {
        try FileDelete(STARTUP_LNK)
        A_TrayMenu.Uncheck("Start with Windows")
        TrayTip("Will not start with Windows", "Steam Save Timeline")
    } else {
        try {
            FileCreateShortcut(A_ScriptFullPath, STARTUP_LNK, A_ScriptDir, ,
                               "Capture Steam Cloud saves into a git timeline")
            A_TrayMenu.Check("Start with Windows")
            TrayTip("Will start with Windows", "Steam Save Timeline")
        } catch as e {
            MsgBox("Could not write the startup shortcut:`n" e.Message, "Steam Save Timeline", "Icon!")
        }
    }
}

; ---------------------------------------------------------------- actions

; Hidden by default: the browser and the setup window are their own feedback, so
; a console alongside them is just a black box flashing up for no reason. Only
; the one-shot sweep is shown, because its console IS the feedback.
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
