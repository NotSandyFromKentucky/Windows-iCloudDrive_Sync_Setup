#requires -Version 5.1
param([Parameter(Mandatory)][string]$WorkerPath)
$ErrorActionPreference='Stop'
$environment=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
$WorkerPath=(Resolve-Path -LiteralPath $WorkerPath).Path
Add-Type -Path (Join-Path $PSScriptRoot 'ContrastSettings.cs')
$original=[ICloudContrastFixture]::Read()
if(($original.Flags -band 2) -eq 0){throw 'High contrast is unavailable in this disposable Windows environment.'}
$enabled=New-Object ICloudContrastFixture+State
$enabled.Flags=$original.Flags -bor 1
$enabled.Scheme=$original.Scheme
try {
    [ICloudContrastFixture]::Write($enabled)
    if(([ICloudContrastFixture]::Read().Flags -band 1) -eq 0){throw 'Windows did not enable high contrast.'}
    & (Join-Path $PSScriptRoot 'Test-RustUITheme.ps1') -WorkerPath $WorkerPath -RequireHighContrast
} finally {
    [ICloudContrastFixture]::Write($original)
    $restored=[ICloudContrastFixture]::Read()
    if($restored.Flags -ne $original.Flags){throw 'High-contrast flags were not restored exactly.'}
    if($restored.Scheme -cne $original.Scheme){
        if(($original.Flags -band 1) -ne 0 -or -not [string]::IsNullOrEmpty($original.Scheme) -or [string]::IsNullOrEmpty($restored.Scheme)){
            throw 'The original high-contrast scheme was not restored.'
        }
        Write-Output ('Windows initialized the previously empty inactive contrast scheme: '+$restored.Scheme)
    }
    & (Join-Path $PSScriptRoot 'Test-RustUITheme.ps1') -WorkerPath $WorkerPath
}
Write-Output ('PASS: disposable '+$environment+' Rust high-contrast rendering and exact settings restoration')
