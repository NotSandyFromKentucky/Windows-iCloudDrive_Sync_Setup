#requires -Version 5.1
$ErrorActionPreference='Stop'
$null=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName WindowsBase
$repo=Split-Path $PSScriptRoot -Parent
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $temp ('ICloudPickerTest-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
try{
    $driver=Join-Path $fixture 'PickerDriver.exe'
    $references=@('System.dll',([Windows.Automation.AutomationElement].Assembly.Location),([Windows.Automation.ControlType].Assembly.Location),([Windows.Rect].Assembly.Location))
    Add-Type -Path @((Join-Path $PSScriptRoot 'WinUIPickerDriver.cs'),(Join-Path $PSScriptRoot 'HiddenDesktop.cs')) -ReferencedAssemblies $references -OutputType ConsoleApplication -OutputAssembly $driver
    & $driver $repo $fixture
    if($LASTEXITCODE){throw ('Native picker driver failed: '+$LASTEXITCODE)}
}finally{
    $path=[IO.Path]::GetFullPath($fixture)
    if($path.StartsWith($temp.TrimEnd('\')+'\ICloudPickerTest-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Recurse -Force}
}