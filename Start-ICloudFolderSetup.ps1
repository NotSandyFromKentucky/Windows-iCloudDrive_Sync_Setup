#requires -Version 5.1
param([ValidateSet('Setup','Reset','Check')][string]$InitialMode='Setup')
$ErrorActionPreference='Stop'
try{
    Add-Type -AssemblyName System.Windows.Forms
    Import-Module (Join-Path $PSScriptRoot 'ICloudFolderSetup.UI.psm1') -Force
    $action=switch($InitialMode){'Reset'{'Reset to Windows defaults'} 'Check'{'Check iCloud configuration'} default{'Set up iCloud folders'}}
    $window=New-SetupWindow -Source $PSScriptRoot -InitialAction $action
    try{$null=$window.Form.ShowDialog()}finally{$window.Form.Dispose()}
}catch{
    Add-Type -AssemblyName System.Windows.Forms
    [Windows.Forms.MessageBox]::Show($_.Exception.Message,'iCloud folder setup could not start','OK','Error') | Out-Null
    exit 1
}
