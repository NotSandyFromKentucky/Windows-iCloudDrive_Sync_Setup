#requires -Version 5.1
[CmdletBinding()]
param([switch]$ForceRebuild,[ValidateSet('Setup','Reset','Check','Install')][string]$InitialMode='Setup')
$ErrorActionPreference='Stop'
$repo=$PSScriptRoot
$buildEnvironment=@{}
foreach($name in @('CARGO_HOME','CARGO_NET_OFFLINE')){$buildEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$projectCargoHome=Join-Path $repo '.local/cargo-home'
if(Test-Path -LiteralPath $projectCargoHome -PathType Container){$env:CARGO_HOME=$projectCargoHome;$env:CARGO_NET_OFFLINE='true'}
try{
$cacheFile=Join-Path $repo '.local/rust-ui-build.json'
$binary=$null
if(-not $ForceRebuild -and (Test-Path -LiteralPath $cacheFile)){
    try{
        $cached=Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json
        $valid=($cached.Sources.Count -eq 4 -and $cached.FolderMapSourceSHA256 -eq (Get-FileHash -LiteralPath (Join-Path $repo 'ICloudFolders.psm1')).Hash)
        foreach($file in @('Cargo.toml','Cargo.lock','src/main.rs','app.manifest')){
            $entry=@($cached.Sources | Where-Object Path -eq $file)
            if($entry.Count -ne 1 -or $entry[0].SHA256 -ne (Get-FileHash -LiteralPath (Join-Path $repo ('ui/rust/'+$file))).Hash){$valid=$false}
        }
        if($valid -and (Test-Path -LiteralPath $cached.WorkerPath -PathType Leaf) -and (Get-FileHash -LiteralPath $cached.WorkerPath).Hash -eq $cached.ExecutableSHA256){$binary=$cached.WorkerPath}
    }catch{$binary=$null}
}
if(-not $binary){
    $build=& (Join-Path $repo 'tools/Build-RustUI.ps1')
    $binary=$build.WorkerPath
    $null=[IO.Directory]::CreateDirectory((Join-Path $repo '.local'))
    $build | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cacheFile -Encoding UTF8
}
$backendCacheFile=Join-Path $repo '.local/native-backend-build.json'
$backend=$null
if(Test-Path -LiteralPath $backendCacheFile){
    try{
        $cachedBackend=Get-Content -LiteralPath $backendCacheFile -Raw|ConvertFrom-Json
        $validBackend=($cachedBackend.Sources.Count -eq 3 -and $cachedBackend.FolderMapSourceSHA256 -eq (Get-FileHash -LiteralPath (Join-Path $repo 'ICloudFolders.psm1')).Hash)
        foreach($file in @('Cargo.toml','Cargo.lock','src/main.rs')){
            $entry=@($cachedBackend.Sources|Where-Object Path -eq $file)
            if($entry.Count -ne 1 -or $entry[0].SHA256 -ne (Get-FileHash -LiteralPath (Join-Path $repo ('backend/'+$file))).Hash){$validBackend=$false}
        }
        if($validBackend -and (Test-Path -LiteralPath $cachedBackend.WorkerPath -PathType Leaf) -and (Get-FileHash -LiteralPath $cachedBackend.WorkerPath).Hash -eq $cachedBackend.ExecutableSHA256){$backend=$cachedBackend}
    }catch{$backend=$null}
}
if(-not $backend){
    $backend=& (Join-Path $repo 'tools/Build-NativeBackend.ps1')
    $null=[IO.Directory]::CreateDirectory((Join-Path $repo '.local'))
    $backend | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $backendCacheFile -Encoding UTF8
}
}finally{
    foreach($name in $buildEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$buildEnvironment[$name],'Process')}
}
$info=New-Object Diagnostics.ProcessStartInfo
$info.FileName=$binary;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=$repo
$info.Arguments='--mode '+$InitialMode
# Launch the preview and release the PowerShell bootstrap; it need not stay resident.
$previousScriptRoot=[Environment]::GetEnvironmentVariable('ICLOUD_SCRIPT_ROOT','Process')
$previousBackend=[Environment]::GetEnvironmentVariable('ICLOUD_NATIVE_BACKEND','Process')
try{
    [Environment]::SetEnvironmentVariable('ICLOUD_SCRIPT_ROOT',$repo,'Process')
    [Environment]::SetEnvironmentVariable('ICLOUD_NATIVE_BACKEND',$backend.WorkerPath,'Process')
    $process=[Diagnostics.Process]::Start($info)
}finally{
    [Environment]::SetEnvironmentVariable('ICLOUD_SCRIPT_ROOT',$previousScriptRoot,'Process')
    [Environment]::SetEnvironmentVariable('ICLOUD_NATIVE_BACKEND',$previousBackend,'Process')
}
$process.Dispose()
