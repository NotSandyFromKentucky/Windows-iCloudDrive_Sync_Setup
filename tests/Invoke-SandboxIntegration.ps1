#requires -Version 5.1
# Launched only by the isolated Windows Sandbox configuration.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$marker = Get-Content -LiteralPath 'C:\TestInput\sandbox-marker.json' -Raw | ConvertFrom-Json
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($env:USERNAME -ne 'WDAGUtilityAccount' -or $sid -eq $marker.HostSid -or $env:COMPUTERNAME -eq $marker.HostComputer) {
    throw 'This integration test is restricted to the disposable Windows Sandbox guest.'
}
$output = 'C:\TestResults'
$project = 'C:\SandboxProject'
$null = [IO.Directory]::CreateDirectory($project)
Copy-Item -LiteralPath 'C:\TestInput\Set-ICloudFolders.ps1','C:\TestInput\ICloudFolders.psm1' -Destination $project
$script:checks = @()
$script:backupPath = $null
$script:failure = $null
$script:restored = $false
function Check([bool]$Condition, [string]$Name) {
    $script:checks += [pscustomobject]@{ Name=$Name; Passed=$Condition }
    if (-not $Condition) { throw "Failed: $Name" }
}
function Snapshot {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders')
    try {
        @($key.GetValueNames() | Sort-Object | ForEach-Object {
            [pscustomobject]@{ Name=$_; Kind=$key.GetValueKind($_).ToString(); Data=$key.GetValue($_,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
        }) | ConvertTo-Json -Depth 6 -Compress
    } finally { $key.Dispose() }
}
function Run-Cli([string]$Name, [string[]]$Options) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $project 'Set-ICloudFolders.ps1') @Options *> (Join-Path $output ($Name + '.log'))
    Check ($LASTEXITCODE -eq 0) $Name
}
try {
    $module = Import-Module (Join-Path $project 'ICloudFolders.psm1') -Force -PassThru
    $map = & $module { Get-FolderMap -IncludeMusic }
    $before = Snapshot
    # Make initially configured guest destinations available for restore.
    foreach ($name in $map.Keys) {
        $value = & $module { param($Name) Read-FolderValue $Name } $name
        if ($value.Exists) {
            $path = [Environment]::ExpandEnvironmentVariables($value.Data)
            $null = [IO.Directory]::CreateDirectory($path)
        }
    }
    $oldDocs = & $module { (Read-FolderValue 'Personal').Data }
    $sentinel = Join-Path ([Environment]::ExpandEnvironmentVariables($oldDocs)) 'integration-original.txt'
    [IO.File]::WriteAllText($sentinel, 'source must remain unchanged')
    $root = 'C:\ICloudIntegration !'
    $null = [IO.Directory]::CreateDirectory($root)
    $recovery = Join-Path $env:LOCALAPPDATA 'ICloudFolderSettler\Recovery'
    Run-Cli 'preview' @('-ICloudRoot',$root,'-IncludeMusic')
    Check ((Snapshot) -ceq $before -and -not (Test-Path -LiteralPath $recovery) -and @(Get-ChildItem -LiteralPath $root -Force).Count -eq 0) 'preview has no mutations'
    Run-Cli 'whatif' @('-ICloudRoot',$root,'-IncludeMusic','-Apply','-WhatIf','-AllowExistingContent','-VerifiedSyncRoot')
    Check ((Snapshot) -ceq $before -and -not (Test-Path -LiteralPath $recovery)) 'WhatIf has no registry or recovery writes'
    Run-Cli 'apply' @('-ICloudRoot',$root,'-IncludeMusic','-Apply','-AllowExistingContent','-VerifiedSyncRoot')
    $script:backupPath = @(Get-ChildItem -LiteralPath $recovery -Recurse -Filter before.json)[0].FullName
    foreach ($name in $map.Keys) {
        $value = & $module { param($Name) Read-FolderValue $Name } $name
        Check ($value.Kind -eq 'ExpandString' -and $value.Data -ceq (Join-Path $root $map[$name])) "real registry write: $name"
    }
    Check ([IO.File]::ReadAllText($sentinel) -ceq 'source must remain unchanged') 'original source file retained'
    $applied = Snapshot
    Run-Cli 'repeat-apply' @('-ICloudRoot',$root,'-IncludeMusic','-Apply','-AllowExistingContent','-VerifiedSyncRoot')
    Check ((Snapshot) -ceq $applied) 'second apply is stable'
    # A fresh process avoids .NET known-folder caching in this test process.
    $actualDocs = & powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('MyDocuments')"
    Check ($actualDocs -ceq (Join-Path $root 'Documents')) 'fresh-process Documents API resolves redirected path'
    Run-Cli 'restore-preview' @('-RestoreBackup',$script:backupPath)
    Check ((Snapshot) -ceq $applied) 'restore preview leaves settings unchanged'
    Run-Cli 'restore' @('-RestoreBackup',$script:backupPath,'-Apply')
    Check ((Snapshot) -ceq $before) 'restore exactly matches complete original registry snapshot'
    $script:restored = $true
    # Inject a one-time error after two REAL writes, then use production rollback.
    & $module {
        $script:OriginalWrite = (Get-Item Function:Write-FolderValue).ScriptBlock
        $script:IntegrationWriteCount = 0
        function script:Write-FolderValue {
            param($Value)
            $script:IntegrationWriteCount++
            if ($script:IntegrationWriteCount -eq 3) { throw 'Sandbox injected write failure' }
            & $script:OriginalWrite $Value
        }
    }
    $caught = $null
    try {
        Invoke-ICloudFolders -ICloudRoot $root -IncludeMusic -Apply -AllowExistingContent -VerifiedSyncRoot *> (Join-Path $output 'rollback.log')
    } catch { $caught = $_.Exception.Message }
    Check ($caught -like '*Sandbox injected write failure*Original settings retained/restored*') 'partial real-write failure triggers successful rollback'
    Check ((Snapshot) -ceq $before) 'real rollback exactly matches original registry snapshot'
    Check ([IO.File]::ReadAllText($sentinel) -ceq 'source must remain unchanged') 'source file survives apply, restore and rollback'
} catch {
    $script:failure = $_ | Out-String
} finally {
    # Restore on an unexpected failure too. Sandbox is discarded afterwards.
    if ($script:failure -and $script:backupPath -and -not $script:restored) {
        try { Run-Cli 'emergency-restore' @('-RestoreBackup',$script:backupPath,'-Apply') } catch { $script:failure += ($_ | Out-String) }
    }
    [pscustomobject]@{
        Success=($null -eq $script:failure); Checks=$script:checks; Error=$script:failure
        GuestUser=$env:USERNAME; GuestComputer=$env:COMPUTERNAME; TimeUtc=[DateTime]::UtcNow.ToString('o')
        Limits='Synthetic guest root; no iCloud installation, cloud sync or sign-out/sign-in verification.'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
}
