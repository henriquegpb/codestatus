' Starts CodeStatus without opening a console window.
'
' This is the shortcut for normal use and for starting with Windows: the app
' lives in the tray, so a terminal window open for the whole session would serve
' no purpose.

Dim shell, fso, folder
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
folder = fso.GetParentFolderName(WScript.ScriptFullName)

' See the comment in scripts/start.cmd: if this variable leaks in from the
' parent process, electron.exe runs as plain Node and the app never starts.
'
' Removed, not emptied: Electron only checks whether the variable exists, so
' leaving it set to an empty string has exactly the same effect as leaving it 1.
On Error Resume Next
shell.Environment("PROCESS").Remove("ELECTRON_RUN_AS_NODE")
On Error Goto 0

shell.CurrentDirectory = folder
' 0 = hidden window, False = do not wait for it to finish
shell.Run """" & folder & "\node_modules\electron\dist\electron.exe"" """ & folder & """", 0, False
