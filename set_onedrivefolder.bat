@echo off
setlocal enabledelayedexpansion

:: Check if iCloud Drive is installed
if not exist "%USERPROFILE%\iCloudDrive" (
    echo Error: iCloud Drive folder not found in %USERPROFILE%
    echo Please ensure that iCloud for Windows is installed and set up correctly.
    echo.
    pause
    exit /b 1
)

:: Define the base iCloudDrive path
set "iCloudDrivePath=%USERPROFILE%\iCloudDrive"
set "backupFile=%~dp0iCloudFoldersBackup.reg"

echo.
echo ================================
echo Setting up iCloud Drive Folders
echo ================================

:: Create backup of current registry settings
echo Creating registry backup...
reg export "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" "%backupFile%" /y
echo Registry backup created: %backupFile%

:: Create restore script
(
echo @echo off
echo reg import "%backupFile%"
echo echo Registry settings restored.
echo pause
) > "%~dp0RestoreRegistry.bat"
echo Restore script created: "%~dp0RestoreRegistry.bat"

:: Create the folders
echo Creating folders...
mkdir "%iCloudDrivePath%\Desktop" 2>nul
if errorlevel 1 (
    echo Folder "%iCloudDrivePath%\Desktop" already exists or could not be created.
) else (
    echo Created folder: "%iCloudDrivePath%\Desktop"
)

mkdir "%iCloudDrivePath%\Pictures" 2>nul
if errorlevel 1 (
    echo Folder "%iCloudDrivePath%\Pictures" already exists or could not be created.
) else (
    echo Created folder: "%iCloudDrivePath%\Pictures"
)

mkdir "%iCloudDrivePath%\Documents" 2>nul
if errorlevel 1 (
    echo Folder "%iCloudDrivePath%\Documents" already exists or could not be created.
) else (
    echo Created folder: "%iCloudDrivePath%\Documents"
)

mkdir "%iCloudDrivePath%\Videos" 2>nul
if errorlevel 1 (
    echo Folder "%iCloudDrivePath%\Videos" already exists or could not be created.
) else (
    echo Created folder: "%iCloudDrivePath%\Videos"
)

mkdir "%iCloudDrivePath%\Downloads" 2>nul
if errorlevel 1 (
    echo Folder "%iCloudDrivePath%\Downloads" already exists or could not be created.
) else (
    echo Created folder: "%iCloudDrivePath%\Downloads"
)

mkdir "%iCloudDrivePath%\Images" 2>nul
if errorlevel 1 (
    echo Folder "%iCloudDrivePath%\Images" already exists or could not be created.
) else (
    echo Created folder: "%iCloudDrivePath%\Images"
)

mkdir "%iCloudDrivePath%\Videos\Captures" 2>nul
if errorlevel 1 (
    echo Folder "%iCloudDrivePath%\Videos\Captures" already exists or could not be created.
) else (
    echo Created folder: "%iCloudDrivePath%\Videos\Captures"
)

echo.
echo All specified folders have been processed.

:: Set the registry keys
echo Setting registry keys...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "Desktop" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Desktop" /f
echo Set registry key for Desktop to: %USERPROFILE%\iCloudDrive\Desktop

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Pictures" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Pictures" /f
echo Set registry key for My Pictures to: %USERPROFILE%\iCloudDrive\Pictures

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "Personal" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Documents" /f
echo Set registry key for Personal (Documents) to: %USERPROFILE%\iCloudDrive\Documents

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "My Video" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Videos" /f
echo Set registry key for My Video to: %USERPROFILE%\iCloudDrive\Videos

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{374DE290-123F-4565-9164-39C4925E467B}" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Downloads" /f
echo Set registry key for Downloads to: %USERPROFILE%\iCloudDrive\Downloads

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{339719B5-8C47-4894-94C2-D8F77ADD44A6}" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Images" /f
echo Set registry key for Images to: %USERPROFILE%\iCloudDrive\Images

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{EDC0FE71-98D8-4F4A-B920-C8DC133CB165}" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Videos\Captures" /f
echo Set registry key for Videos (Captures) to: %USERPROFILE%\iCloudDrive\Videos\Captures

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{F42EE2D3-909F-4907-8871-4C22FC0BF756}" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Documents" /f
echo Set registry key for Documents to: %USERPROFILE%\iCloudDrive\Documents

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{0DDD015D-B06C-45D5-8C4C-F59713854639}" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Images" /f
echo Set registry key for Images (again) to: %USERPROFILE%\iCloudDrive\Images

reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{35286A68-3C57-41A1-BBB1-0EAE73D76C95}" /t REG_EXPAND_SZ /d "%%USERPROFILE%%\iCloudDrive\Videos" /f
echo Set registry key for Videos (again) to: %USERPROFILE%\iCloudDrive\Videos

echo.
echo All folders created and registry keys set successfully. Please restart your computer for changes to take effect.
echo To restore the original registry settings, run the RestoreRegistry.bat file.
echo.
pause

:: Script: iCloud Folders Redirector
:: Version: 1.2
:: Author: Sviatoslav
:: Description: Redirects Windows user folders to iCloud Drive and creates a backup of original settings
:: Compatibility: Windows 10/11
:: Requires: Administrator Privileges, iCloud for Windows installed
