#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Snapshot)
$ErrorActionPreference='Stop'

if(-not $env:ICLOUD_TEST_DESKTOP){
    & (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{Snapshot=$Snapshot} -TimeoutSeconds 600
    return
}

$isolation=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
if($isolation -notin @('GitHubHosted','WindowsSandbox')){throw 'Cloud Files provider integration requires a disposable Windows environment.'}

$snapshotPath=[IO.Path]::GetFullPath($Snapshot)
$manifest=Join-Path $snapshotPath 'Cargo.toml'
if(-not (Test-Path -LiteralPath $manifest -PathType Leaf)){throw 'The immutable backend snapshot is missing Cargo.toml.'}
$cargo=(Get-Command cargo -CommandType Application -ErrorAction Stop).Source
$oldTarget=$env:CARGO_TARGET_DIR
try{
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
        $stdout.Result | Out-Host
        $stderr.Result | Out-Host
        if($process.ExitCode -ne 0){throw 'The guarded Cloud Files hydration probe failed.'}
    }finally{$process.Dispose()}
}finally{
    $env:CARGO_TARGET_DIR=$oldTarget
}
