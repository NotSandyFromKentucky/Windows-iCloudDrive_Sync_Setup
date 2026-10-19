@echo off
setlocal DisableDelayedExpansion
start "" powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Start-ICloudFolderSetup.ps1"
