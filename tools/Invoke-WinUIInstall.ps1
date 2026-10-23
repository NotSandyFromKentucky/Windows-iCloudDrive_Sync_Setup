#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param([switch]$DesktopShortcut)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'ICloudFolderSetup.Install.psm1') -Force
$options=@{
    Source=(Split-Path $PSScriptRoot -Parent)
    InstallRoot=(Join-Path $env:LOCALAPPDATA 'Programs\ICloudFolderSettler')
    ProgramsDirectory=([Environment]::GetFolderPath('Programs'))
    RequireNative=$true
}
if($DesktopShortcut){$options.DesktopDirectory=[Environment]::GetFolderPath('DesktopDirectory')}
if($WhatIfPreference){$options.WhatIf=$true}
$installed=Install-SetupFiles @options
if($installed){Write-Output ('Installed application: '+$installed.Directory);Write-Output 'Open iCloud folder setup from your Start menu. Folder locations have not changed.'}
