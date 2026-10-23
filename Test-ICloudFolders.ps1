#requires -Version 5.1
[CmdletBinding()]
param([string]$ICloudRoot = "$env:USERPROFILE\iCloudDrive", [switch]$IncludeMusic, [switch]$Json, [hashtable]$FolderPaths=@{})
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'ICloudFolders.psm1') -Force
    $report = Test-ICloudFolderSetup -ICloudRoot $ICloudRoot -IncludeMusic:$IncludeMusic -FolderPaths $FolderPaths
    if ($Json) { $report | ConvertTo-Json -Depth 8 } else {
        Write-Host "iCloud folder check: $($report.Root)"
        Write-Host "Root exists: $($report.RootExists); registered for this account: $($report.RootRegistered)"
        $report.RegistryValues | Select-Object Folder, Current, Matches, DirectoryExists | Format-Table -AutoSize -Wrap
        Write-Host 'Windows folder resolution:'
        $report.ResolvedFolders | Select-Object Folder, Current, Matches | Format-Table -AutoSize -Wrap
        foreach ($message in $report.Errors) { Write-Warning $message }
        Write-Host $report.CloudSync
        if ($report.Healthy) { Write-Host 'Folder configuration checks passed.' } else { Write-Host 'Some checks need attention. Review missing roots, mismatches or unavailable paths above.' }
    }
    if ($report.Healthy) { exit 0 } else { exit 2 }
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
