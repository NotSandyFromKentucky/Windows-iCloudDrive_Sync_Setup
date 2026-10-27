#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Snapshot,[switch]$NoHiddenDesktop)
$ErrorActionPreference='Stop'

if(-not $env:ICLOUD_TEST_DESKTOP -and -not $NoHiddenDesktop){
    & (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{Snapshot=$Snapshot} -TimeoutSeconds 600
    return
}

$isolation=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
if($NoHiddenDesktop){
    if($isolation -ne 'GitHubHosted'){throw 'NoHiddenDesktop provider integration is restricted to a GitHub-hosted runner.'}
    if($env:ICLOUD_TEST_DESKTOP){throw 'NoHiddenDesktop mode must run on the visible runner desktop.'}
}
if($isolation -notin @('GitHubHosted','WindowsSandbox')){throw 'Cloud Files provider integration requires a disposable Windows environment.'}

$snapshotPath=[IO.Path]::GetFullPath($Snapshot)
$manifest=Join-Path $snapshotPath 'Cargo.toml'
if(-not (Test-Path -LiteralPath $manifest -PathType Leaf)){throw 'The immutable backend snapshot is missing Cargo.toml.'}
$cargo=(Get-Command cargo -CommandType Application -ErrorAction Stop).Source
$oldTarget=$env:CARGO_TARGET_DIR
$oldMap=$env:ICLOUD_FOLDER_MAP_PATH
try{
    $env:ICLOUD_FOLDER_MAP_PATH=Join-Path $snapshotPath 'folder-map.json'
    if(-not (Test-Path -LiteralPath $env:ICLOUD_FOLDER_MAP_PATH -PathType Leaf)){throw 'The immutable backend snapshot is missing generated folder-map.json metadata.'}
    $env:CARGO_TARGET_DIR=Join-Path $snapshotPath 'target'
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$cargo
    $info.Arguments='test --locked --manifest-path "'+$manifest+'" --release --test cloud_files_hydration -- --ignored --test-threads=1'
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    if($null -eq $process){throw 'Cargo could not start the guarded Cloud Files hydration test.'}
    try{
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        if($process.ExitCode -ne 0){
            foreach($output in @($stdout.Result,$stderr.Result)){
                $safeOutput=[regex]::Replace($output,'(?i)(?:[a-z]:\\|\\\\)[^\r\n]*','[path details withheld]')
                $lines=@($safeOutput -split '\r?\n' | Where-Object {$_})
                if($lines.Count -gt 40){$lines=$lines[-40..-1]}
                foreach($line in $lines){Write-Output $line}
            }
            throw ('The guarded Cloud Files hydration probe failed (Cargo exit code '+$process.ExitCode+').')
        }
        Write-Output 'PASS: guarded Cloud Files hydration tests completed'
    }finally{$process.Dispose()}
}finally{
    $env:CARGO_TARGET_DIR=$oldTarget
    $env:ICLOUD_FOLDER_MAP_PATH=$oldMap
}
