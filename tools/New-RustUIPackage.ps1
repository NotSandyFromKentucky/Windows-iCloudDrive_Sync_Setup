#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$BuildInfo,[string]$BackendBuildInfo,[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$policy=Get-Content (Join-Path $repo 'build/ReleaseFiles.json') -Raw|ConvertFrom-Json
$build=Get-Content -LiteralPath $BuildInfo -Raw|ConvertFrom-Json
foreach($source in $policy.RustUI.SourceFiles){
    $relative=$source.Substring('ui/rust/'.Length)
    $entry=@($build.Sources|Where-Object Path -ceq $relative)
    if($entry.Count -ne 1 -or $entry[0].SHA256 -cne (Get-FileHash -LiteralPath (Join-Path $repo $source)).Hash){throw 'Rust build sources are stale. Build the current sources first.'}
}
if($build.FolderMapSourceSHA256 -cne (Get-FileHash -LiteralPath (Join-Path $repo 'ICloudFolders.psm1')).Hash -or $build.ExecutableSHA256 -cne (Get-FileHash -LiteralPath $build.WorkerPath).Hash){throw 'Rust executable or generated mapping is stale.'}
if(-not $BackendBuildInfo){$backendBuild=& (Join-Path $PSScriptRoot 'Build-NativeBackend.ps1');$BackendBuildInfo=Join-Path $backendBuild.Snapshot 'build-info.json'}
$backend=Get-Content -LiteralPath $BackendBuildInfo -Raw|ConvertFrom-Json
foreach($relative in @('Cargo.toml','Cargo.lock','src/main.rs')){
    $entry=@($backend.Sources|Where-Object Path -ceq $relative)
    if($entry.Count -ne 1 -or $entry[0].SHA256 -cne (Get-FileHash -LiteralPath (Join-Path $repo ('backend/'+$relative))).Hash){throw 'Rust backend build sources are stale.'}
}
if($backend.FolderMapSourceSHA256 -cne (Get-FileHash -LiteralPath (Join-Path $repo 'ICloudFolders.psm1')).Hash -or $backend.ExecutableSHA256 -cne (Get-FileHash -LiteralPath $backend.WorkerPath).Hash){throw 'Rust backend executable or generated mapping is stale.'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('ICloudRustPackage-'+[guid]::NewGuid().ToString('N'))}
$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
foreach($blocked in @($repo,(Join-Path $env:USERPROFILE 'iCloudDrive'))){$blocked=[IO.Path]::GetFullPath($blocked).TrimEnd('\');if($output -ieq $blocked -or $output.StartsWith($blocked+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Package outside the repository and iCloud Drive.'}}
if(Test-Path -LiteralPath $output){throw 'Choose a new output directory.'}
$null=[IO.Directory]::CreateDirectory((Join-Path $output 'RustUI'))
$version=(Get-Content (Join-Path $repo 'VERSION') -Raw).Trim()
if($version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid VERSION.'}
$entries=@()
$packageFiles=@($policy.Files)+@($policy.RustUI.Executable)+@($policy.RustUI.WorkerExecutable)
function Get-PackageSource([string]$File){
    if($File -ceq $policy.RustUI.Executable){return $build.WorkerPath}
    if($File -ceq $policy.RustUI.WorkerExecutable){return $backend.WorkerPath}
    return Join-Path $repo $File
}
$sourceHashes=@{}
foreach($file in $packageFiles){
    $source=Get-PackageSource $file
    $sourceHashes[$file]=(Get-FileHash -LiteralPath $source).Hash
}
foreach($file in $packageFiles){
    if($file -notmatch '^[A-Za-z0-9_./-]+$' -or $file -match '(^|/)\.\.?(/|$)'){throw 'Unsafe package input.'}
    $source=Get-PackageSource $file
    $hash=$sourceHashes[$file]
    $target=Join-Path $output $file;$null=[IO.Directory]::CreateDirectory((Split-Path $target -Parent))
    Copy-Item -LiteralPath $source -Destination $target
    if((Get-FileHash -LiteralPath $target).Hash -cne $hash){throw 'Package input changed while copying.'}
    $entries+=[pscustomobject]@{Path=$file;SHA256=$hash}
}
foreach($file in $sourceHashes.Keys){
    $source=Get-PackageSource $file
    if((Get-FileHash -LiteralPath $source).Hash -cne $sourceHashes[$file]){throw 'Package sources changed during snapshot creation. Start again from stable sources.'}
}
[pscustomobject]@{Version=$version;Interface='Rust';Development=$true;Signed=$false;Files=$entries}|ConvertTo-Json -Depth 5|Set-Content (Join-Path $output 'manifest.json') -Encoding UTF8
[pscustomobject]@{Directory=$output;Executable=(Join-Path $output $policy.RustUI.Executable);Version=$version;Signed=$false}
