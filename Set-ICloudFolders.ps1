#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ICloudRoot = "$env:USERPROFILE\iCloudDrive",
    [switch]$Apply,
    [switch]$VerifiedSyncRoot,
    [switch]$IncludeMusic,
    [switch]$AllowExistingContent,
    [string]$RestoreBackup
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'ICloudFolders.psm1') -Force
    $options = @{
        ICloudRoot = $ICloudRoot; Apply = $Apply; VerifiedSyncRoot = $VerifiedSyncRoot
        IncludeMusic = $IncludeMusic; AllowExistingContent = $AllowExistingContent
    }
    if ($RestoreBackup) { $options.RestoreBackup = $RestoreBackup }
    if ($WhatIfPreference) { $options.WhatIf = $true }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $options.Confirm = [bool]$PSBoundParameters['Confirm'] }
    Invoke-ICloudFolders @options
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
