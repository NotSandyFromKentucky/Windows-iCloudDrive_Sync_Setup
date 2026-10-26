#requires -Version 5.1
param([ValidateSet('Setup','Reset','Check','Install')][string]$InitialMode='Setup',[switch]$ForceWinUI,[switch]$UseRustPreview)
$ErrorActionPreference='Stop'
try{
    Import-Module (Join-Path $PSScriptRoot 'ICloudFolderSetup.Launch.psm1') -Force
    $spec=Get-NativeLaunchSpec -Source $PSScriptRoot -InitialMode $InitialMode -ForceWinUI:$ForceWinUI -UseRustPreview:$UseRustPreview
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$spec.Executable;$info.Arguments=$spec.Arguments;$info.WorkingDirectory=$spec.WorkingDirectory
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $process=[Diagnostics.Process]::Start($info)
    try{$process.WaitForExit();if($process.ExitCode -ne 0){throw 'The native application could not start. Check %LOCALAPPDATA%\ICloudFolderSettler\Logs, then extract or reinstall the complete package.'}}finally{$process.Dispose()}
}catch{
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'iCloud folder setup could not start','OK','Error') | Out-Null
    exit 1
}
