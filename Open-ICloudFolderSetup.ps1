#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$setupExit = 0
try {
    Import-Module (Join-Path $PSScriptRoot 'ICloudFolders.psm1') -Force
    Write-Host 'iCloud folder setup'
    Write-Host 'Review the destinations below. Existing files will stay where they are.'
    Invoke-ICloudFolders
    Write-Host ''
    $answer = Read-Host 'Type APPLY to use these folder locations, or press Enter to cancel'
    if ($answer -ceq 'APPLY') {
        Invoke-ICloudFolders -Apply
    } else {
        Write-Host 'Cancelled. No settings changed.'
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    Write-Host 'Setup did not complete. Review the error above.'
    $setupExit = 1
}
exit $setupExit
