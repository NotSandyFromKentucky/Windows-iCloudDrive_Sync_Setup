#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [hashtable]$Parameters=@{},
    [ValidateRange(1,1800)][int]$TimeoutSeconds=180
)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$scriptFile=(Resolve-Path -LiteralPath $ScriptPath).Path
if([IO.Path]::GetExtension($scriptFile) -ne '.ps1'){throw 'Choose a PowerShell test script.'}
$native=Join-Path $PSScriptRoot 'HiddenDesktop.cs'
if(-not ('ICloudTestDesktop' -as [type])){Add-Type -Path $native}
$desktop='ICloudTests-'+[guid]::NewGuid().ToString('N')
$logs=Join-Path $repo '.local/hidden-desktop'
$null=[IO.Directory]::CreateDirectory($logs)
$log=Join-Path $logs ($desktop+'.log')
$spec=@{Script=$scriptFile;Parameters=$Parameters;Native=$native;Desktop=$desktop;Log=$log}
$data=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($spec | ConvertTo-Json -Depth 8 -Compress)))
$command=@'
$ErrorActionPreference='Stop'
$spec=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('DATA')) | ConvertFrom-Json
try {
    Add-Type -Path $spec.Native
    $actual=[ICloudTestDesktop]::CurrentName()
    if($actual -cne $spec.Desktop){throw ('Wrong desktop: '+$actual)}
    $env:ICLOUD_TEST_DESKTOP=$actual
    ('Verified hidden desktop: '+$actual) | Out-File -LiteralPath $spec.Log -Encoding utf8
    $parameters=@{};foreach($property in $spec.Parameters.PSObject.Properties){$parameters[$property.Name]=$property.Value}
    $global:LASTEXITCODE=0
    & $spec.Script @parameters *>&1 | Out-File -LiteralPath $spec.Log -Encoding utf8 -Append -Width 240
    exit $LASTEXITCODE
} catch {
    ($_ | Out-String) | Out-File -LiteralPath $spec.Log -Encoding utf8 -Append
    exit 1
}
'@
$command=$command.Replace('DATA',$data)
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
Write-Output ('Running on a separate, non-input desktop. Log: '+$log)
try{$code=[ICloudTestDesktop]::Run($exe,('-NoProfile -STA -ExecutionPolicy Bypass -EncodedCommand '+$encoded),$repo,$desktop,$TimeoutSeconds)}
finally{if(Test-Path -LiteralPath $log){Get-Content -LiteralPath $log}}
if($code -ne 0){throw ('Hidden-desktop test failed with exit code '+$code+'. Log: '+$log)}
