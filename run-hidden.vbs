' run-hidden.vbs <script.ps1> [arguments...]
'
' Launches one of this folder's PowerShell scripts with no console window at
' all. powershell.exe -WindowStyle Hidden is not enough: the console is still
' created and painted for a frame, so shortcuts and log-on tasks flash a black
' box. WScript.Shell.Run with window style 0 never creates one.
'
' Paths are resolved relative to this file, so the shortcut that calls it does
' not care where the project lives.

Option Explicit

Dim sh, fso, dir, cmd, i

If WScript.Arguments.Count = 0 Then WScript.Quit 1

Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & _
      dir & "\" & WScript.Arguments(0) & """"

For i = 1 To WScript.Arguments.Count - 1
    cmd = cmd & " " & WScript.Arguments(i)
Next

sh.CurrentDirectory = dir
sh.Run cmd, 0, False
