#requires -Version 5.1
$ErrorActionPreference='Stop'
# Theme changes affect the entire account, even when windows run on a hidden desktop.
# Refuse the developer account before initializing any UI or calling the settings API.
$environment=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
Add-Type -Path (Join-Path $PSScriptRoot 'ContrastSettings.cs')
function Read-Palettes {
    $repo=Split-Path $PSScriptRoot -Parent
    foreach($theme in @('light','dark')){
        Get-Content -LiteralPath (Join-Path $repo ('.local/hidden-desktop/winui-'+$theme+'.png.json')) -Raw | ConvertFrom-Json |
            Select-Object Theme,HighContrast,SystemAccent,WindowsColor,CloudColor | ConvertTo-Json -Compress
    }
}
& (Join-Path $PSScriptRoot 'Test-WinUITheme.ps1')
$baseline=@(Read-Palettes)
Write-Output 'Reading initial Windows contrast settings'
$original=[ICloudContrastFixture]::Read()
Write-Output ('Initial contrast flags: '+$original.Flags)
Write-Output ('Initial contrast state: '+($original|ConvertTo-Json -Compress))
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
    Write-Output ('Restored contrast state: '+($restored|ConvertTo-Json -Compress))
    & (Join-Path $PSScriptRoot 'Test-WinUITheme.ps1')
    if(@(Compare-Object -ReferenceObject $baseline -DifferenceObject @(Read-Palettes)).Count){throw 'Native theme palettes differ from the original after contrast restoration.'}
    Write-Output 'PASS: post-restoration native palettes match the original'
    if($restored.Flags -ne $original.Flags){throw 'High-contrast flags were not restored exactly.'}
    # On a fresh hosted account Windows initializes an empty default scheme on
    # first activation. It does not return to empty when contrast is disabled.
    # Require exact preservation of every pre-existing name, and never allow an
    # empty-name exception when contrast was originally enabled. Flags and the
    # original Light/Dark palettes must still match exactly in every case.
    if($restored.Scheme -cne $original.Scheme){
        if(($original.Flags -band 1) -ne 0 -or -not [string]::IsNullOrEmpty($original.Scheme) -or [string]::IsNullOrEmpty($restored.Scheme)){
            throw ('High-contrast scheme was not restored. Original: '+($original|ConvertTo-Json -Compress)+'; restored: '+($restored|ConvertTo-Json -Compress))
        }
        Write-Output ('Windows initialized the previously empty inactive contrast scheme: '+$restored.Scheme)
    }
}
Write-Output ('PASS: disposable '+$environment+' high-contrast palette and restored-settings render')
