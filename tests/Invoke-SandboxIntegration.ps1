#requires -Version 5.1
# Real writes are restricted to disposable Sandbox/hosted-runner environments.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$mode = & (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
$output = if ($mode -eq 'WindowsSandbox') { 'C:\TestResults' } else { Join-Path $env:RUNNER_TEMP 'ICloudIntegrationResults' }
$project = if ($mode -eq 'WindowsSandbox') { 'C:\SandboxProject' } else { Join-Path $env:RUNNER_TEMP 'ICloudIntegrationProject' }
$source = if ($mode -eq 'WindowsSandbox') { 'C:\TestInput' } else { Split-Path $PSScriptRoot -Parent }
$null = [IO.Directory]::CreateDirectory($output)
$null = [IO.Directory]::CreateDirectory($project)
Copy-Item -LiteralPath (Join-Path $source 'Set-ICloudFolders.ps1'),(Join-Path $source 'ICloudFolders.psm1') -Destination $project
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
    $root = Join-Path $project 'ICloudIntegration !'
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
    & powershell.exe -NoProfile -Command "[IO.File]::WriteAllText([IO.Path]::Combine([Environment]::GetFolderPath('MyDocuments'),'application-save.txt'),'saved through the Windows Documents API')"
    Check ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $root 'Documents\application-save.txt'))) 'application-style save uses redirected Documents'
    $diagnostics = Test-ICloudFolderSetup -ICloudRoot $root -IncludeMusic
    Check (@($diagnostics.RegistryValues | Where-Object { -not $_.Matches }).Count -eq 0 -and @($diagnostics.ResolvedFolders | Where-Object { -not $_.Matches }).Count -eq 0) 'diagnostics agree with all guest registry and resolved paths'
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

    # Real filesystem denial, not a mocked probe failure.
    $deniedPath = Join-Path $root 'Pictures'
    $originalAcl = Get-Acl -LiteralPath $deniedPath
    try {
        $acl = Get-Acl -LiteralPath $deniedPath
        $rule = New-Object Security.AccessControl.FileSystemAccessRule([Security.Principal.WindowsIdentity]::GetCurrent().User,'Write','Deny')
        $null = $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $deniedPath -AclObject $acl
        $caught = $null
        try { Invoke-ICloudFolders -ICloudRoot $root -IncludeMusic -Apply -AllowExistingContent -VerifiedSyncRoot *> (Join-Path $output 'access-denied.log') } catch { $caught = $_.Exception.Message }
        Check ($null -ne $caught -and (Snapshot) -ceq $before) 'real destination access denial leaves registry unchanged'
    } finally { Set-Acl -LiteralPath $deniedPath -AclObject $originalAcl }

    # Terminate a separate process after its first real write; recover using its on-disk backup.
    $crashRoot = Join-Path $project 'crash-root'
    $null = [IO.Directory]::CreateDirectory($crashRoot)
    $ready = Join-Path $project 'crash-ready.txt'
    $crashScript = Join-Path $project 'crash-test.ps1'
    @'
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot 'ICloudFolders.psm1') -Force -PassThru
& $module {
    param($Ready)
    $script:OriginalCrashWrite=(Get-Item Function:Write-FolderValue).ScriptBlock
    $script:CrashReady=$Ready
    function script:Write-FolderValue {
        param($Value)
        & $script:OriginalCrashWrite $Value
        [IO.File]::WriteAllText($script:CrashReady,'first write completed')
        Start-Sleep -Seconds 600
    }
} (Join-Path $PSScriptRoot 'crash-ready.txt')
Invoke-ICloudFolders -ICloudRoot (Join-Path $PSScriptRoot 'crash-root') -IncludeMusic -Apply -AllowExistingContent -VerifiedSyncRoot
'@ | Set-Content -LiteralPath $crashScript -Encoding UTF8
    $priorBackups = @(Get-ChildItem -LiteralPath $recovery -Recurse -Filter before.json | Select-Object -ExpandProperty FullName)
    $child = Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$crashScript+'"') -WindowStyle Hidden -PassThru
    try {
        $deadline = (Get-Date).AddSeconds(30)
        while (-not (Test-Path -LiteralPath $ready) -and -not $child.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
        Check ((Test-Path -LiteralPath $ready) -and (Snapshot) -cne $before) 'interrupted process performed a real write before termination'
    } finally { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force; $child.WaitForExit() }; $child.Dispose() }
    $crashBackup = @(Get-ChildItem -LiteralPath $recovery -Recurse -Filter before.json | Where-Object { $priorBackups -notcontains $_.FullName })
    Check ($crashBackup.Count -eq 1) 'interrupted process left one recoverable backup'
    Run-Cli 'crash-restore' @('-RestoreBackup',$crashBackup[0].FullName,'-Apply')
    Check ((Snapshot) -ceq $before) 'manual recovery after process termination restores exact original settings'
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
if ($script:failure) { throw $script:failure }
