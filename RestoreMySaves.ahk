#Requires AutoHotkey v2.0
#SingleInstance Force
;
; RestoreMySaves.ahk -- the "my PC died" button.
;
; Compiled to "Restore my saves.exe" and shipped in the release zip. Extract
; the zip into the backup folder (the one your cloud drive synced down), then
; double-click this. It opens the setup window, which finds the backup sitting
; beside it and offers to restore everything.
;
; It is a separate program on purpose. The capture daemon is the one part that
; must never break, so restore logic does not go anywhere near it: this only
; launches the setup window, which already knows how to find and restore a
; backup, and setup is where a person can see what is about to happen and say
; yes to it.
;
; It also exists so nobody is ever told to "run a .ps1". Double-clicking a
; .ps1 opens Notepad, and right-click Run with PowerShell trips over execution
; policy. An exe just runs.
;
; Rebuild (AutoHotkey only needed to rebuild, not to run):
;   "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" /in RestoreMySaves.ahk ^
;     /out "Restore my saves.exe" /icon SteamSaveTimeline.ico ^
;     /base "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"

SETUP  := A_ScriptDir "\steam_save_setup.ps1"
BACKUP := A_ScriptDir "\steam-save-history.git"

if !FileExist(SETUP) {
    MsgBox("This needs to sit in the same folder as the Steam Save Timeline"
         . " scripts.`n`nExtract the whole release zip into your backup folder,"
         . " then run this again.",
           "Restore my saves", "Icon!")
    ExitApp
}

; Not fatal: setup is worth opening anyway, and it can point at a backup
; somewhere else. But if the expected one is missing, say so first rather than
; letting someone sit in front of a window wondering why nothing was found.
if !DirExist(BACKUP) {
    r := MsgBox("No backup found in this folder.`n`nExpected:`n" BACKUP
              . "`n`nOpen setup anyway?",
                "Restore my saves", "YesNo Icon?")
    if (r != "Yes")
        ExitApp
}

try {
    Run('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden'
      . ' -File "' SETUP '"', A_ScriptDir, "Hide")
} catch as e {
    MsgBox("Could not start setup:`n" e.Message, "Restore my saves", "Icon!")
}
ExitApp
