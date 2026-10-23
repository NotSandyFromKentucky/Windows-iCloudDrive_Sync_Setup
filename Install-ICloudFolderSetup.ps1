#requires -Version 5.1
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'Start-ICloudFolderSetup.ps1') -InitialMode Install
exit $LASTEXITCODE
