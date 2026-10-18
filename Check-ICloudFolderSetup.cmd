@echo off
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-ICloudFolders.ps1"
set "checkExit=%errorlevel%"
echo.
pause
exit /b %checkExit%
