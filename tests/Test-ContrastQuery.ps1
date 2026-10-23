#requires -Version 5.1
$ErrorActionPreference='Stop'
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
Add-Type -Path (Join-Path $PSScriptRoot 'ContrastSettings.cs')
for($i=0;$i -lt 20;$i++){
    $state=[ICloudContrastFixture]::Read()
    if($null -eq $state){throw 'Contrast query returned no state.'}
}
'PASS: twenty read-only Windows contrast queries without freeing the Windows-owned scheme pointer; no settings changed'
