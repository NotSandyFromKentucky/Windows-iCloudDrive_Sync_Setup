@echo off
setlocal DisableDelayedExpansion
powershell.exe -NoProfile -File "%~dp0Set-ICloudFolders.ps1" %*
exit /b %errorlevel%
