#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Preview', 'Apply', 'Copy', 'Reset', 'Check')]
    [string]$Operation,
    [string]$ICloudRoot = "$env:USERPROFILE\iCloudDrive",
    [switch]$IncludeMusic,
    [switch]$VerifiedSyncRoot,
    [switch]$AllowExistingContent,
    [string]$RestoreBackup,
    [hashtable]$FolderPaths = @{}
)
$ErrorActionPreference = 'Stop'
try {
    $scriptRoot = $PSScriptRoot
    # Import modules based on operation needs
    if ($Operation -in @('Preview', 'Apply', 'Reset')) {
        Import-Module (Join-Path $scriptRoot 'ICloudFolders.psm1') -Force
    }
    if ($Operation -eq 'Copy') {
        Import-Module (Join-Path $scriptRoot 'ICloudFolderCopy.psm1') -Force
    }
    if ($Operation -eq 'Check') {
        Import-Module (Join-Path $scriptRoot 'ICloudFolders.psm1') -Force
    }
    # Route to the appropriate operation
    switch ($Operation) {
        'Preview' {
            $options = @{
                ICloudRoot = $ICloudRoot
                FolderPaths = $FolderPaths
            }
            if ($PSBoundParameters.ContainsKey('IncludeMusic')) { $options.IncludeMusic = $IncludeMusic }
            if ($PSBoundParameters.ContainsKey('VerifiedSyncRoot')) { $options.VerifiedSyncRoot = $VerifiedSyncRoot }
            if ($PSBoundParameters.ContainsKey('AllowExistingContent')) { $options.AllowExistingContent = $AllowExistingContent }
            Invoke-ICloudFolders @options
            exit 0
        }
        'Apply' {
            $options = @{
                ICloudRoot = $ICloudRoot
                Apply = $true
                FolderPaths = $FolderPaths
            }
            if ($PSBoundParameters.ContainsKey('IncludeMusic')) { $options.IncludeMusic = $IncludeMusic }
            if ($PSBoundParameters.ContainsKey('VerifiedSyncRoot')) { $options.VerifiedSyncRoot = $VerifiedSyncRoot }
            if ($PSBoundParameters.ContainsKey('AllowExistingContent')) { $options.AllowExistingContent = $AllowExistingContent }
            if ($WhatIfPreference) { $options.WhatIf = $true }
            if ($PSBoundParameters.ContainsKey('Confirm')) { $options.Confirm = [bool]$PSBoundParameters['Confirm'] }
            Invoke-ICloudFolders @options
            exit 0
        }
        'Copy' {
            $options = @{
                ICloudRoot = $ICloudRoot
                Apply = $true
                FolderPaths = $FolderPaths
            }
            if ($PSBoundParameters.ContainsKey('IncludeMusic')) { $options.IncludeMusic = $IncludeMusic }
            if ($PSBoundParameters.ContainsKey('VerifiedSyncRoot')) { $options.VerifiedSyncRoot = $VerifiedSyncRoot }
            if ($WhatIfPreference) { $options.WhatIf = $true }
            if ($PSBoundParameters.ContainsKey('Confirm')) { $options.Confirm = [bool]$PSBoundParameters.Confirm }
            Invoke-ICloudFolderCopy @options
            exit 0
        }
        'Reset' {
            $options = @{
                ResetToDefaults = $true
                Apply = $true
            }
            if ($WhatIfPreference) { $options.WhatIf = $true }
            if ($PSBoundParameters.ContainsKey('Confirm')) { $options.Confirm = [bool]$PSBoundParameters['Confirm'] }
            Invoke-ICloudFolders @options
            exit 0
        }
        'Check' {
            $options = @{
                ICloudRoot = $ICloudRoot
                FolderPaths = $FolderPaths
            }
            if ($PSBoundParameters.ContainsKey('IncludeMusic')) { $options.IncludeMusic = $IncludeMusic }
            $report = Test-ICloudFolderSetup @options
            Write-Host "iCloud folder check: $($report.Root)"
            Write-Host "Root exists: $($report.RootExists); registered for this account: $($report.RootRegistered)"
            $report.RegistryValues | Select-Object Folder, Current, Matches, DirectoryExists | Format-Table -AutoSize -Wrap
            Write-Host 'Windows folder resolution:'
            $report.ResolvedFolders | Select-Object Folder, Current, Matches | Format-Table -AutoSize -Wrap
            foreach ($message in $report.Errors) { Write-Warning $message }
            Write-Host $report.CloudSync
            if ($report.Healthy) { Write-Host 'Folder configuration checks passed.' } else { Write-Host 'Some checks need attention. Review missing roots, mismatches or unavailable paths above.' }
            if ($report.Healthy) { exit 0 } else { exit 2 }
        }
    }
} catch [OperationCanceledException] {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 3
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
