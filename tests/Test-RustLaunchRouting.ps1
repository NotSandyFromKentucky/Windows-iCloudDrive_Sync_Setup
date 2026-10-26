#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'ICloudFolderSetup.Launch.psm1') -Force
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ICloudRustRouting-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory((Join-Path $fixture 'NativeUI'))
try{
    foreach($path in @('NativeUI/ICloudFolderSetup.exe','icloud-folder-launcher.exe','Start-ICloudRustUI.ps1')){[IO.File]::WriteAllText((Join-Path $fixture $path),'fixture only; never execute')}
    foreach($mode in @('Setup','Reset','Check','Install')){
        $spec=Get-NativeLaunchSpec -Source $fixture -InitialMode $mode
        if($spec.Executable -ne (Join-Path $fixture 'NativeUI\ICloudFolderSetup.exe') -or $spec.Arguments -ne ('--mode '+$mode)){throw 'Default routing lost its validated native mode'}
    }
    $spec=Get-NativeLaunchSpec -Source $fixture -UseRustPreview
    if($spec.Arguments -notlike '*Start-ICloudRustUI.ps1*' -or $spec.Executable -like '*launcher.exe'){throw 'Explicit preview bypassed its verified bootstrap'}
    foreach($mode in @('Setup','Reset','Check','Install')){
        $spec=Get-NativeLaunchSpec -Source $fixture -InitialMode $mode -UseRustPreview
        if($spec.Arguments -notlike ('*-InitialMode '+$mode)){throw 'Explicit Rust startup mode was lost'}
    }
    $null=[IO.Directory]::CreateDirectory((Join-Path $fixture 'RustUI'))
    [IO.File]::WriteAllText((Join-Path $fixture 'RustUI/icloud-folder-ui.exe'),'fixture only; never execute')
    [pscustomobject]@{Interface='Rust'}|ConvertTo-Json|Set-Content (Join-Path $fixture 'manifest.json') -Encoding UTF8
    foreach($mode in @('Setup','Reset','Check','Install')){
        $spec=Get-NativeLaunchSpec -Source $fixture -InitialMode $mode
        if($spec.Executable -ne (Join-Path $fixture 'RustUI/icloud-folder-ui.exe') -or $spec.Arguments -ne ('--mode '+$mode)){throw 'Explicit Rust package startup mode was lost'}
    }
    $spec=Get-NativeLaunchSpec -Source $fixture -ForceWinUI
    if($spec.Executable -notlike '*NativeUI*'){throw 'ForceWinUI did not override Rust package routing'}
    'PASS: production defaults preserved; explicit Rust source/package routes retain all startup modes'
}finally{
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $fixture.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($fixture) -notmatch '^ICloudRustRouting-[a-f0-9]{32}$'){throw 'Refusing cleanup outside routing fixture'}
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
