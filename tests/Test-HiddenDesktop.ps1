#requires -Version 5.1
$ErrorActionPreference='Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'HiddenDesktop.cs')
$runner=Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1'
$probe=Join-Path $PSScriptRoot 'fixtures/HiddenDesktopProbe.ps1'
$before=[ICloudTestDesktop]::InputName()
& $runner -ScriptPath $probe
if([ICloudTestDesktop]::InputName() -cne $before){throw 'Input desktop changed.'}
$failed=$false
try{& $runner -ScriptPath $probe -Parameters @{Mode='Fail'}}catch{$failed=$_.Exception.Message -like '*exit code 1*'}
if(-not $failed){throw 'Child failure did not propagate.'}
$pidFile=Join-Path (Split-Path $PSScriptRoot -Parent) ('.local/hidden-desktop/timeout-'+[guid]::NewGuid().ToString('N')+'.pid')
$timedOut=$false
try{& $runner -ScriptPath $probe -Parameters @{Mode='Timeout';PidFile=$pidFile} -TimeoutSeconds 8}catch{$timedOut=$_.Exception.ToString() -like '*exceeded its timeout*'}
if(-not $timedOut -or -not(Test-Path -LiteralPath $pidFile)){throw 'Timeout probe did not execute.'}
$childId=[int][IO.File]::ReadAllText($pidFile)
$deadline=[DateTime]::UtcNow.AddSeconds(5)
while((Get-Process -Id $childId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
if(Get-Process -Id $childId -ErrorAction SilentlyContinue){throw 'Timed-out child process survived job disposal.'}
if([ICloudTestDesktop]::InputName() -cne $before){throw 'Input desktop changed after failure/timeout.'}
'PASS: hidden desktop, failure propagation, timeout process-tree cleanup and unchanged input desktop'
