@echo off
set SCRIPT_DIR=%~dp0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%uninstall.ps1" -Purge
set EXIT_CODE=%ERRORLEVEL%
if not "%EXIT_CODE%"=="0" echo Uninstall failed or is incomplete. Review the error above.
pause
exit /b %EXIT_CODE%
