#requires -Version 5.1
param([switch]$ResetToDefaults)
$ErrorActionPreference = 'Stop'
$setupExit = 0
try {
    Import-Module (Join-Path $PSScriptRoot 'ICloudFolders.psm1') -Force
    $options = @{}
    if ($ResetToDefaults) { $options.ResetToDefaults = $true }
    $confirmation = if ($ResetToDefaults) { 'RESET' } else { 'APPLY' }
    if ($ResetToDefaults) {
        Write-Host 'Reset all managed folders to local Windows defaults (including Music).'
        Write-Host 'Existing cloud files remain in their current locations and will not appear in the new local folders unless you copy them separately.'
    } else { Write-Host 'iCloud folder setup' }
    Write-Host 'Review the destinations below. Existing files will stay where they are.'
    Invoke-ICloudFolders @options
    Write-Host ''
    $answer = Read-Host "Type $confirmation to use these locations and leave existing files where they are, or press Enter to cancel"
    if ($answer -ceq $confirmation) {
        if ($ResetToDefaults) { $options.AllowExistingContent = $true }
        Invoke-ICloudFolders @options -Apply
    } else {
        Write-Host 'Cancelled. No settings changed.'
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    Write-Host 'Setup did not complete. Review the error above.'
    $setupExit = 1
}
exit $setupExit
