#requires -Version 5.1
Set-StrictMode -Version Latest
function Get-NativeLaunchSpec {
    param([Parameter(Mandatory)][string]$Source,[ValidateSet('Setup','Reset','Check','Install')][string]$InitialMode='Setup')
    $root=[IO.Path]::GetFullPath($Source)
    $executable=Join-Path $root 'NativeUI\ICloudFolderSetup.exe'
    if(-not(Test-Path -LiteralPath $executable -PathType Leaf)){throw 'The native application files are missing. Extract the entire WinUI release package, or build the native development project. Keep the NativeUI folder beside the launcher.'}
    [pscustomobject]@{Executable=$executable;Arguments=('--mode '+$InitialMode);WorkingDirectory=$root}
}
Export-ModuleMember -Function Get-NativeLaunchSpec
