Option Explicit

Dim shell, fileSystem, scriptDirectory, powerShellPath, trayScriptPath
Dim commandLine, exitCode

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
powerShellPath = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
trayScriptPath = fileSystem.BuildPath(scriptDirectory, "start-tray.ps1")
commandLine = Quote(powerShellPath) & " -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File " & Quote(trayScriptPath)

On Error Resume Next
exitCode = shell.Run(commandLine, 0, True)
If Err.Number <> 0 Then
    WScript.Quit 1
End If
On Error GoTo 0

WScript.Quit exitCode

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function
