#requires -Version 5.1
# Evaluation only. The production backend is not switched by this test.
$ErrorActionPreference = 'Stop'
$mode = & (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
$output = if ($mode -eq 'WindowsSandbox') { 'C:\TestResults' } else { Join-Path $env:RUNNER_TEMP 'ICloudIntegrationResults' }
$null = [IO.Directory]::CreateDirectory($output)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KnownFolderEvaluation {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    public static extern int SHSetKnownFolderPath(ref Guid id, uint flags, IntPtr token, string path);
    [DllImport("shell32.dll")]
    public static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
}
'@
$keys = @('Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders','Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders')
function Snapshot-Key($Path) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path)
    try {
        if (-not $key) { return [pscustomobject]@{ Path=$Path; Exists=$false; Values=@() } }
        $values = @($key.GetValueNames() | Sort-Object | ForEach-Object {
            [pscustomobject]@{ Name=$_; Kind=$key.GetValueKind($_).ToString(); Data=$key.GetValue($_,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
        })
        [pscustomobject]@{ Path=$Path; Exists=$true; Values=$values }
    } finally { if ($key) { $key.Dispose() } }
}
function Read-ApiPath([guid]$Id, [uint32]$Flags=0) {
    $ptr = [IntPtr]::Zero
    try {
        $result = [KnownFolderEvaluation]::SHGetKnownFolderPath([ref]$Id,$Flags,[IntPtr]::Zero,[ref]$ptr)
        if ($result -ne 0) { throw "SHGetKnownFolderPath failed: $result" }
        [Runtime.InteropServices.Marshal]::PtrToStringUni($ptr)
    } finally { if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeCoTaskMem($ptr) } }
}
$before = @($keys | ForEach-Object { Snapshot-Key $_ })
$beforeJson = $before | ConvertTo-Json -Depth 8 -Compress
$id = [guid]'FDD39AD0-238F-46AF-ADB4-6C85480369C7'
$originalPath = Read-ApiPath $id
$windowsDefault = Read-ApiPath $id 0x4600
$aliasName = '{F42EE2D3-909F-4907-8871-4C22FC0BF756}'
$target = Join-Path $env:TEMP ('ICloudApi-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($originalPath)
$null = [IO.Directory]::CreateDirectory($target)
$sourceFile = Join-Path $originalPath ('api-source-' + [guid]::NewGuid().ToString('N') + '.txt')
[IO.File]::WriteAllText($sourceFile,'Do not move this source file')
$failure = $null
$restoreErrors = @()
$changedNames = @()
try {
    # Evaluate the important case where a local Documents alias already exists.
    $aliasKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($keys[0],$true)
    try { $aliasKey.SetValue($aliasName,$originalPath,[Microsoft.Win32.RegistryValueKind]::ExpandString) } finally { $aliasKey.Dispose() }
    $apiBefore = @($keys | ForEach-Object { Snapshot-Key $_ })
    $result = [KnownFolderEvaluation]::SHSetKnownFolderPath([ref]$id,0,[IntPtr]::Zero,$target)
    if ($result -ne 0) { throw "SHSetKnownFolderPath failed: $result" }
    if ((Read-ApiPath $id) -ine $target) { throw 'API destination did not resolve.' }
    if ((Read-ApiPath $id 0x4600) -ine $windowsDefault) { throw 'Windows default-path query followed current redirection.' }
    if (-not (Test-Path -LiteralPath $sourceFile) -or (Test-Path -LiteralPath (Join-Path $target ([IO.Path]::GetFileName($sourceFile))))) { throw 'Unexpected file migration.' }
    $after = @($keys | ForEach-Object { Snapshot-Key $_ })
    for ($i=0;$i -lt $before.Count;$i++) {
        $names = @(@($apiBefore[$i].Values.Name) + @($after[$i].Values.Name) | Select-Object -Unique)
        foreach ($name in $names) {
            $old = @($apiBefore[$i].Values | Where-Object { $_.Name -ceq $name }) | ConvertTo-Json -Depth 5 -Compress
            $new = @($after[$i].Values | Where-Object { $_.Name -ceq $name }) | ConvertTo-Json -Depth 5 -Compress
            if ($old -cne $new) { $changedNames += $before[$i].Path + '\' + $name }
        }
    }
    $aliasAfter = @($after[0].Values | Where-Object { $_.Name -ceq $aliasName })
    $aliasFollowsApi = $aliasAfter.Count -eq 1 -and [Environment]::ExpandEnvironmentVariables($aliasAfter[0].Data) -ieq $target
} catch { $failure = $_ | Out-String } finally {
    try { $null = [KnownFolderEvaluation]::SHSetKnownFolderPath([ref]$id,0,[IntPtr]::Zero,$originalPath) } catch { $restoreErrors += $_.Exception.Message }
    foreach ($snapshot in $before) {
        $key = $null
        try {
            if (-not $snapshot.Exists) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($snapshot.Path,$false); continue }
            $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($snapshot.Path)
            foreach ($name in $key.GetValueNames()) { if ($snapshot.Values.Name -notcontains $name) { $key.DeleteValue($name,$false) } }
            foreach ($value in $snapshot.Values) { $key.SetValue($value.Name,$value.Data,[Enum]::Parse([Microsoft.Win32.RegistryValueKind],$value.Kind)) }
        } catch { $restoreErrors += $_.Exception.Message } finally { if ($key) { $key.Dispose() } }
    }
    $restored = @($keys | ForEach-Object { Snapshot-Key $_ }) | ConvertTo-Json -Depth 8 -Compress
    $exactRestore = $restored -ceq $beforeJson
    [pscustomobject]@{ Success=($null -eq $failure -and $restoreErrors.Count -eq 0 -and $exactRestore); ApiCanonicalPathVerified=($null -eq $failure); DefaultPathIndependentOfRedirection=($null -eq $failure); LocalAliasFollowsApi=$aliasFollowsApi; SourceFileRetained=(Test-Path -LiteralPath $sourceFile); ChangedRegistryValues=$changedNames; ExactRestore=$exactRestore; Errors=@(@($failure)+$restoreErrors | Where-Object {$_}); OS=[Environment]::OSVersion.VersionString; PowerShell=$PSVersionTable.PSVersion.ToString() } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output 'known-folder-api.json') -Encoding UTF8
}
if ($failure -or $restoreErrors.Count -or -not $exactRestore) { throw 'Known Folder API evaluation failed; inspect known-folder-api.json.' }
Write-Host 'Known Folder API evaluation passed: path changed, source retained, original registry snapshots restored.'
