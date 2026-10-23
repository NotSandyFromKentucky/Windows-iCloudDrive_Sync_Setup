#requires -Version 5.1
$ErrorActionPreference='Stop'
# Theme changes affect the entire account, even when windows run on a hidden desktop.
# Refuse the developer account before initializing any UI or calling the settings API.
$environment=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
Add-Type -Path (Join-Path $PSScriptRoot 'ContrastSettings.cs')
Write-Output 'Reading initial Windows contrast settings'
$original=[ICloudContrastFixture]::Read()
Write-Output ('Initial contrast flags: '+$original.Flags)
if(($original.Flags -band 2) -eq 0){throw 'High contrast is unavailable in this disposable Windows environment.'}
$enabled=New-Object ICloudContrastFixture+State
$enabled.Flags=$original.Flags -bor 1
$enabled.Scheme=$original.Scheme
try{
    Write-Output 'Enabling Windows contrast in disposable environment'
    [ICloudContrastFixture]::Write($enabled)
    Write-Output 'Contrast setter returned; checking Windows state'
    if(([ICloudContrastFixture]::Read().Flags -band 1) -eq 0){throw 'Windows did not enable high contrast.'}
    & (Join-Path $PSScriptRoot 'Test-WinUITheme.ps1') -RequireHighContrast
}finally{
    Write-Output 'Restoring original Windows contrast settings'
    [ICloudContrastFixture]::Write($original)
    $restored=[ICloudContrastFixture]::Read()
    if($restored.Flags -ne $original.Flags -or $restored.Scheme -cne $original.Scheme){throw 'High-contrast settings were not restored exactly.'}
}
& (Join-Path $PSScriptRoot 'Test-WinUITheme.ps1')
Write-Output ('PASS: disposable '+$environment+' high-contrast palette and restored-settings render')
