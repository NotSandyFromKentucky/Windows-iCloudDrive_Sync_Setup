#requires -Version 5.1
Set-StrictMode -Version Latest
function Get-NativeLaunchSpec {
    param([Parameter(Mandatory)][string]$Source,[ValidateSet('Setup','Reset','Check','Install')][string]$InitialMode='Setup',[switch]$ForceWinUI,[switch]$UseRustPreview)
    $root=[IO.Path]::GetFullPath($Source)
    if($UseRustPreview -and $ForceWinUI){throw 'Choose either the Rust development preview or WinUI.'}
    if($UseRustPreview){
        $bootstrap=Join-Path $root 'Start-ICloudRustUI.ps1'
        if(-not(Test-Path -LiteralPath $bootstrap -PathType Leaf)){throw 'The Rust development preview bootstrap is missing.'}
        $powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        return [pscustomobject]@{Executable=$powershell;Arguments=('-NoProfile -ExecutionPolicy Bypass -File "'+$bootstrap+'" -InitialMode '+$InitialMode);WorkingDirectory=$root}
    }
    # A package manifest explicitly selects its UI. The shipped WinUI package
    # has no Rust manifest, so this cannot switch a release package.
    $manifestPath=Join-Path $root 'manifest.json'
    if(-not $ForceWinUI -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)){
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if($manifest.PSObject.Properties['Interface'] -and $manifest.Interface -eq 'Rust'){
            $executable=Join-Path $root 'RustUI\icloud-folder-ui.exe'
            if(-not(Test-Path -LiteralPath $executable -PathType Leaf)){throw 'The Rust application package is incomplete. Extract the entire package again.'}
            return [pscustomobject]@{Executable=$executable;Arguments='--mode '+$InitialMode;WorkingDirectory=$root}
        }
    }

    # Prefer the validated production launcher (WinUI) for source checkouts.
    $nativeUI=Join-Path $root 'NativeUI\ICloudFolderSetup.exe'
    if(-not $ForceWinUI -and (Test-Path -LiteralPath $nativeUI -PathType Leaf)){
        return [pscustomobject]@{Executable=$nativeUI;Arguments='--mode '+$InitialMode;WorkingDirectory=$root}
    }
    $rustLauncher=Join-Path $root 'icloud-folder-launcher.exe'
    if(-not $ForceWinUI -and (Test-Path -LiteralPath $rustLauncher -PathType Leaf)){
        return [pscustomobject]@{Executable=$rustLauncher;Arguments='';WorkingDirectory=$root}
    }
    # Preserve the validated production launcher and every initial mode until Rust parity is verified.
    $executable=Join-Path $root 'NativeUI\ICloudFolderSetup.exe'
    if(-not(Test-Path -LiteralPath $executable -PathType Leaf)){throw 'The native application files are missing. Extract the entire WinUI release package, or build the native development project. Keep the NativeUI folder beside the launcher.'}
    [pscustomobject]@{Executable=$executable;Arguments=('--mode '+$InitialMode);WorkingDirectory=$root}
}
Export-ModuleMember -Function Get-NativeLaunchSpec
