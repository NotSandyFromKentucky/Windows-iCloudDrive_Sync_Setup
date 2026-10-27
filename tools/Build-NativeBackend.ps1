#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string[]]$LinkerLibraryDirectories=@(),
    [switch]$UseRustLld,
    [switch]$Test,
    [ValidateSet('Backend','RustUI','RustLauncher')][string]$Project='Backend'
)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if($Project -eq 'RustUI'){$sourceDirectory='ui/rust'}
elseif($Project -eq 'RustLauncher'){$sourceDirectory='ui/rust-launcher'}
else{$sourceDirectory='backend'}
if($Project -eq 'RustUI'){$executable='icloud-folder-ui.exe'}
elseif($Project -eq 'RustLauncher'){$executable='icloud-folder-launcher.exe'}
else{$executable='icloud-folder-worker.exe'}
$sourceFiles=@('Cargo.toml','Cargo.lock','src/main.rs')
if($Project -eq 'RustUI'){$sourceFiles+='app.manifest'}
elseif($Project -eq 'Backend' -and $Test){$sourceFiles+='tests/cloud_files_hydration.rs'}
if(-not $OutputDirectory){$OutputDirectory=Join-Path ([IO.Path]::GetTempPath()) ('ICloudFolderWorker-'+[guid]::NewGuid().ToString('N'))}
$output=[IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
$cloudRoots=@($repo)
if($env:USERPROFILE){$cloudRoots+=Join-Path $env:USERPROFILE 'iCloudDrive'}
foreach($cloudRoot in $cloudRoots){
    $cloudRoot=[IO.Path]::GetFullPath($cloudRoot).TrimEnd('\')
    if($output -ieq $cloudRoot -or $output.StartsWith($cloudRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Build outside the repository and iCloud Drive.'}
}
if(Test-Path -LiteralPath $output){throw 'Choose a new output directory to preserve earlier build evidence.'}
$null=[IO.Directory]::CreateDirectory((Join-Path $output 'src'))
if($sourceFiles -contains 'tests/cloud_files_hydration.rs'){$null=[IO.Directory]::CreateDirectory((Join-Path $output 'tests'))}
foreach($file in $sourceFiles){
    Copy-Item -LiteralPath (Join-Path $repo ($sourceDirectory+'/'+$file)) -Destination (Join-Path $output $file)
}
$metadata=$null
if($Project -ne 'RustLauncher'){
    $module=Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force -PassThru
    $map=@(& $module {
        $all=Get-FolderMap -IncludeMusic
        $normal=Get-FolderMap
        $known=Get-WindowsKnownFolderIds
        foreach($name in $all.Keys){
            $relative=$all[$name]
            $id=if($relative -eq 'Videos\Captures'){'Captures'}else{$relative}
            [pscustomobject]@{value_name=$name;relative_path=$relative;optional=(-not $normal.Contains($name));known_folder_id=$known[$id]}
        }
    })
    $metadata=Join-Path $output 'folder-map.json'
    [IO.File]::WriteAllText($metadata,($map | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
}
$before=@{}
foreach($name in @('ICLOUD_FOLDER_MAP_PATH','CARGO_TARGET_DIR','RUSTFLAGS','CARGO_ENCODED_RUSTFLAGS','LIB','PATH')){$before[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
    if($Project -eq 'RustUI'){
        $manifestTool=Get-Command mt.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if(-not $manifestTool){
            $arch=if($env:PROCESSOR_ARCHITECTURE -eq 'ARM64'){'arm64'}else{'x64'}
            $patterns=@((Join-Path ${env:ProgramFiles(x86)} ('Windows Kits/10/bin/*/'+$arch+'/mt.exe')),(Join-Path $env:USERPROFILE ('.nuget/packages/microsoft.windows.sdk.buildtools/*/bin/*/'+$arch+'/mt.exe')))
            $manifestTool=Get-ChildItem -Path $patterns -File -ErrorAction SilentlyContinue | Sort-Object FullName -Descending | Select-Object -First 1
        }
        if(-not $manifestTool){throw 'The Windows SDK manifest tool (mt.exe) is required for the Rust UI build. Install Windows SDK Build Tools or add its directory to this process PATH.'}
        $toolPath=if($manifestTool -is [IO.FileInfo]){$manifestTool.FullName}else{$manifestTool.Source}
        $env:PATH=(Split-Path $toolPath -Parent)+';'+$before.PATH
    }
    $env:ICLOUD_FOLDER_MAP_PATH=$metadata
    $env:CARGO_TARGET_DIR=Join-Path $output 'target'
    # Link the CRT statically; the worker needs no separately installed VC redistributable.
    $flags=@()
    if($before.CARGO_ENCODED_RUSTFLAGS){$flags+= $before.CARGO_ENCODED_RUSTFLAGS -split [char]31}
    elseif($before.RUSTFLAGS){$flags+= $before.RUSTFLAGS -split '\s+'}
    $flags+=@('-C','target-feature=+crt-static')
    if($Project -eq 'RustUI'){
        $flags+=@('-C','link-arg=/MANIFEST:EMBED','-C',('link-arg=/MANIFESTINPUT:'+(Join-Path $output 'app.manifest')))
    }
    # RustLauncher doesn't need manifest embedding or folder map
    if($UseRustLld){
        $sysroot=(& rustc --print sysroot).Trim()
        if($LASTEXITCODE){throw 'rustc could not report its sysroot.'}
        $hostLine=(& rustc -vV | Where-Object {$_ -like 'host: *'})
        $hostTarget=$hostLine.Substring(6)
        $lld=Join-Path $sysroot ('lib/rustlib/'+$hostTarget+'/bin/rust-lld.exe')
        if(-not(Test-Path -LiteralPath $lld)){throw 'The installed Rust linker was not found.'}
        $flags+=@('-C',('linker='+$lld))
    }
    $env:CARGO_ENCODED_RUSTFLAGS=$flags -join [char]31
    if($LinkerLibraryDirectories.Count){
        foreach($directory in $LinkerLibraryDirectories){if(-not(Test-Path -LiteralPath $directory -PathType Container)){throw 'Missing linker library directory.'}}
        $env:LIB=($LinkerLibraryDirectories -join ';')+';'+$before.LIB
    }
    $manifest=Join-Path $output 'Cargo.toml'
    $cargo=(Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $commands=@('build');if($Test){$commands=@('test','build')}
    foreach($command in $commands){
        $stdout=Join-Path $output ($command+'.stdout.txt');$stderr=Join-Path $output ($command+'.stderr.txt')
        $info=New-Object Diagnostics.ProcessStartInfo
        $features=if($Test -and $Project -eq 'Backend'){' --features test-injection'}else{''}
        $info.FileName=$cargo;$info.Arguments=$command+' --locked --manifest-path "'+$manifest+'" --release'+$features
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $process=[Diagnostics.Process]::Start($info)
        try{
            $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
            if(-not $process.WaitForExit(600000)){$process.Kill();throw 'Native build timed out.'}
            [IO.File]::WriteAllText($stdout,$out.Result);[IO.File]::WriteAllText($stderr,$err.Result)
            $out.Result | Out-Host
            $err.Result | Out-Host
            if($process.ExitCode -ne 0){throw ('Native backend '+$command+' failed.')}
        }finally{$process.Dispose()}
    }
    $worker=Join-Path $output ('target/release/'+$executable)
    if(-not(Test-Path -LiteralPath $worker)){throw 'The Windows worker executable is missing.'}
    $sources=@(foreach($file in $sourceFiles){[pscustomobject]@{Path=$file;SHA256=(Get-FileHash -LiteralPath (Join-Path $output $file)).Hash}})
    $result=[ordered]@{WorkerPath=$worker;Snapshot=$output;ExecutableSHA256=(Get-FileHash -LiteralPath $worker).Hash;Sources=$sources}
    if($metadata){$result.FolderMapSHA256=(Get-FileHash -LiteralPath $metadata).Hash;$result.FolderMapSourceSHA256=(Get-FileHash -LiteralPath (Join-Path $repo 'ICloudFolders.psm1')).Hash}
    $result=[pscustomobject]$result
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'build-info.json') -Encoding UTF8
    $result
}finally{
    foreach($name in $before.Keys){[Environment]::SetEnvironmentVariable($name,$before[$name],'Process')}
}
