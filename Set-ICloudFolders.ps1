#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ICloudRoot = "$env:USERPROFILE\iCloudDrive",
    [switch]$Apply,
    [switch]$VerifiedSyncRoot,
    [switch]$IncludeMusic,
    [switch]$AllowExistingContent,
    [string]$RestoreBackup,
    [switch]$ResetToDefaults
)
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'ICloudFolders.psm1') -Force
    $options = @{
        Apply = $Apply; AllowExistingContent = $AllowExistingContent
    }
    foreach ($name in @('ICloudRoot','VerifiedSyncRoot','IncludeMusic','ResetToDefaults')) {
        if ($PSBoundParameters.ContainsKey($name)) { $options[$name] = $PSBoundParameters[$name] }
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
