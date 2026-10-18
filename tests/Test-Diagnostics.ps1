#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $repo ('.test-diagnostics-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($fixture)
$module = Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force -PassThru
function Assert($Condition, $Message) { if (-not $Condition) { throw $Message } }
try {
    & $module {
        param($Root)
        $script:DiagnosticRoot = $Root
        $script:DiagnosticMismatch = $false
        $script:DiagnosticRegistered = $true
        function script:Get-RegisteredICloudRoots { if ($script:DiagnosticRegistered) { $script:DiagnosticRoot } }
        function script:Read-FolderValue {
            param($Name)
            $map = Get-FolderMap -IncludeMusic
            $path = Join-Path $script:DiagnosticRoot $map[$Name]
            if ($script:DiagnosticMismatch -and $Name -eq 'My Pictures') { $path = Join-Path $script:DiagnosticRoot 'old-pictures' }
            [pscustomobject]@{ Name=$Name; Exists=$true; Kind='ExpandString'; Data=$path }
        }
        function script:Write-FolderValue { throw 'Diagnostics attempted a registry write.' }
        function script:Get-ResolvedFolderPath { param($Folder) Join-Path $script:DiagnosticRoot $Folder }
    } $fixture
    $map = & $module { Get-FolderMap -IncludeMusic }
    foreach ($folder in @($map.Values | Select-Object -Unique)) { $null = [IO.Directory]::CreateDirectory((Join-Path $fixture $folder)) }
    $before = @(Get-ChildItem -LiteralPath $fixture -Recurse -Force | Select-Object -ExpandProperty FullName) -join "`n"
    $report = Test-ICloudFolderSetup -ICloudRoot $fixture
    Assert ($report.Healthy -and $report.RegistryValues.Count -eq 11 -and $report.ResolvedFolders.Count -eq 6) 'Healthy default configuration was not recognized.'
    Assert (@($report.RegistryValues | Where-Object { $_.Folder -match '^\{' }).Count -eq 0) 'Friendly labels contain raw GUIDs.'
    Assert ($report.CloudSync -like '*Not verified*') 'Diagnostics overclaimed sync verification.'
    Write-Host 'PASS: healthy configuration, friendly labels, explicit sync limitation'
    & $module { $script:DiagnosticMismatch = $true }
    $report = Test-ICloudFolderSetup -ICloudRoot $fixture
    Assert (-not $report.Healthy -and @($report.RegistryValues | Where-Object { -not $_.Matches }).Count -eq 1) 'Registry mismatch was missed.'
    Write-Host 'PASS: mismatched mapping is reported'
    & $module { $script:DiagnosticMismatch = $false; $script:DiagnosticRegistered = $false }
    Assert (-not (Test-ICloudFolderSetup -ICloudRoot $fixture).Healthy) 'Missing root registration was missed.'
    Write-Host 'PASS: unavailable registration is reported'
    & $module { $script:DiagnosticRegistered = $true; function script:Get-ResolvedFolderPath { param($Folder) throw 'Injected resolution failure' } }
    $report = Test-ICloudFolderSetup -ICloudRoot $fixture -IncludeMusic
    Assert (-not $report.Healthy -and $report.Errors.Count -eq 7 -and $report.RegistryValues.Count -eq 13) 'Resolution failures or optional Music were missed.'
    Write-Host 'PASS: resolution failures are reported; Music is optional'
    $after = @(Get-ChildItem -LiteralPath $fixture -Recurse -Force | Select-Object -ExpandProperty FullName) -join "`n"
    Assert ($before -ceq $after) 'Diagnostic check changed filesystem contents.'
    Write-Host 'PASS: diagnostics create no files or directories'
    Write-Host '5 diagnostic checks passed.'
} finally {
    Remove-Module $module -Force
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($repo).TrimEnd('\') + '\.test-diagnostics-', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
