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
    & $cargo test --locked --manifest-path $manifest --release --test cloud_files_hydration -- --ignored --test-threads=1
    if($LASTEXITCODE -ne 0){throw 'The guarded Cloud Files hydration probe failed.'}
}finally{
    $env:CARGO_TARGET_DIR=$oldTarget
}
