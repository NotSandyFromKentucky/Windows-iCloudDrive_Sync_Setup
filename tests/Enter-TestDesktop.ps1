#requires -Version 5.1
param([Parameter(Mandatory)][string]$ScriptPath)
$ErrorActionPreference='Stop'
if(-not $env:ICLOUD_TEST_DESKTOP){
    & (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $ScriptPath | Out-Host
    return $true
}
if(-not ('ICloudTestDesktop' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'HiddenDesktop.cs')}
if($env:ICLOUD_TEST_DESKTOP -notmatch '^ICloudTests-[a-f0-9]{32}$' -or [ICloudTestDesktop]::CurrentName() -cne $env:ICLOUD_TEST_DESKTOP){
    throw 'UI tests require a verified hidden desktop. Use Invoke-HiddenDesktop.ps1.'
}
return $false
