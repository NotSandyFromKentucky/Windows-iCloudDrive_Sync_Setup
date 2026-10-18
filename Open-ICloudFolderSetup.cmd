@echo off
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Open-ICloudFolderSetup.ps1"
set "setupExit=%errorlevel%"
echo.
pause
exit /b %setupExit%
