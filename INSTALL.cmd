@echo off
set SCRIPT_DIR=%~dp0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install.ps1" -PreSleepSeconds 10 -MaxProbeIntervalSeconds 60 -LogRetentionDays 5
set EXIT_CODE=%ERRORLEVEL%
if not "%EXIT_CODE%"=="0" echo Installation failed. Review the error above.
pause
exit /b %EXIT_CODE%
