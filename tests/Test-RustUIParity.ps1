#requires -Version 5.1
param([Parameter(Mandatory)][string]$WorkerPath,[string]$BackendWorkerPath,[switch]$RunNativeIntegration)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$WorkerPath=(Resolve-Path -LiteralPath $WorkerPath).Path
if(-not $env:ICLOUD_TEST_DESKTOP){& (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{WorkerPath=$WorkerPath;BackendWorkerPath=$BackendWorkerPath;RunNativeIntegration=$RunNativeIntegration.IsPresent} -TimeoutSeconds 300;return}
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
if($RunNativeIntegration){$isolation=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1');if($isolation -notin @('GitHubHosted','WindowsSandbox')){throw 'Native UI integration tests require a disposable Windows environment.'}}
Add-Type -AssemblyName System.Drawing,Accessibility
Add-Type -Path (Join-Path $PSScriptRoot 'RustUIProbe.cs') -ReferencedAssemblies System.Drawing,Accessibility
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
function Wait-For([scriptblock]$Condition,[string]$Message){$end=[DateTime]::UtcNow.AddSeconds(20);while([DateTime]::UtcNow -lt $end){if(& $Condition){return};Start-Sleep -Milliseconds 30};throw $Message}
function Control([int]$Id){[RustUIProbe]::GetDlgItem($script:window,$Id)}
function Click([int]$Id){[RustUIProbe]::Click((Control $Id))}
function Status {([RustUIProbe]::Text((Control 403)))+' '+([RustUIProbe]::Text((Control 103)))}
function Wait-Status([string]$Pattern){Wait-For {(Status) -like $Pattern} ('Status timed out: '+$Pattern+'; '+(Status));if($Pattern -notin @('*Working*','*Copying*')){Wait-For {[RustUIProbe]::IsWindowEnabled((Control 1))} 'Operation result displayed before controls became ready'}}
function Choose([int]$Index){[RustUIProbe]::Send((Control 110),0x014e,[IntPtr]$Index,[IntPtr]::Zero)|Out-Null;[RustUIProbe]::Send($script:window,0x0111,[IntPtr](110 -bor (1 -shl 16)),(Control 110))|Out-Null}
function Confirm([bool]$Approve){
    [RustUIProbe]::PostMessage((Control 3),0x00f5,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Wait-For {$script:dialog=[RustUIProbe]::Dialog($script:process.Id);$script:dialog -ne [IntPtr]::Zero} 'Owned action confirmation missing'
    Wait-For {[RustUIProbe]::IsWindowVisible($script:dialog)} 'Confirmation did not become visible'
    if($Approve){[RustUIProbe]::Send($script:dialog,0x0466,[IntPtr]1000,[IntPtr]::Zero)|Out-Null}
    else{
        [RustUIProbe]::PostMessage($script:dialog,0x0100,[IntPtr]13,[IntPtr]::Zero)|Out-Null
        Wait-For {[RustUIProbe]::Dialog($script:process.Id) -eq [IntPtr]::Zero} 'Enter did not select default Cancel'
    }
}
function Start-UIWithEnvironment([string]$Arguments,[hashtable]$Environment){
    $names=@($Environment.Keys)
    $previous=@{}
    foreach($name in $names){$previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
    try{
        foreach($name in $names){[Environment]::SetEnvironmentVariable($name,[string]$Environment[$name],'Process')}
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$WorkerPath;$info.Arguments=$Arguments;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
        return [Diagnostics.Process]::Start($info)
    }finally{
        foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$previous[$name],'Process')}
    }
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ICloudRustUIFixture-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory((Join-Path $fixture 'tools'))
$stub=@'
param([string]$EncodedRequest)
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedRequest))|ConvertFrom-Json
$root=Split-Path $PSScriptRoot -Parent
$request|ConvertTo-Json -Depth 6 -Compress|Add-Content (Join-Path $root 'requests.jsonl') -Encoding UTF8
$mode=Get-Content (Join-Path $root 'mode.txt')
$code=0;$message='Fixture completed';$body=$request|ConvertTo-Json -Depth 6 -Compress
if($mode -eq 'slow'){Start-Sleep -Seconds 20}
if($mode -eq 'write'){Start-Sleep -Milliseconds 700;Set-Content (Join-Path $root 'write-finished.txt') 'Finished without termination'}
if($mode -eq 'large'){[Console]::Out.WriteLine(('x'*200000));[Console]::Error.WriteLine(('y'*200000))}
if($mode -eq 'overflow'){[Console]::Out.WriteLine(('x'*2200000))}
if($mode -eq 'copy'){
    $event=[Threading.EventWaitHandle]::OpenExisting($request.CancelEventName)
    try{
        [Console]::Out.WriteLine('@@ICloudProgress:{"Stage":"Copying","File":"fixture.txt","Completed":1,"Total":2}')
        $stopped=$event.WaitOne(10000)
        Set-Content (Join-Path $root 'copy-finished.txt') 'Worker reached safe boundary'
        if($stopped){$code=3;$message='Copy stopped safely'}else{throw 'Copy cancellation event was not signalled'}
    }finally{$event.Dispose()}
}
if($request.Action -eq 'Check iCloud configuration'){
    if(-not $request.Json){throw 'UI check must request structured JSON'}
    $body=@{Root=$request.Root;RootRegistered=$true;RootExists=$true;Healthy=$true;CloudSync='Not verified by this read-only check.';Errors=@();RegistryValues=@(@{Folder='Desktop';Current=$request.FolderPaths.Desktop;Matches=$true;DirectoryExists=$true});ResolvedFolders=@(@{Folder='Desktop';Current=$request.FolderPaths.Desktop;Matches=$true})}|ConvertTo-Json -Depth 6 -Compress
}
[Console]::Out.WriteLine(('@@ICloudResult:'+(@{ExitCode=$code;Message=$message;Text=$body}|ConvertTo-Json -Compress)))
if($mode -eq 'mismatch'){exit 2};exit $code
'@
[IO.File]::WriteAllText((Join-Path $fixture 'tools/Invoke-WinUIBridge.ps1'),$stub)
$evidence=Join-Path $repo '.local/rust-ui-parity';$null=[IO.Directory]::CreateDirectory($evidence)
$previousDpi=[RustUIProbe]::SetThreadDpiAwarenessContext([IntPtr](-4))
$inputDesktop=[ICloudTestDesktop]::InputName();$process=$null;$results=@()
try{
 foreach($dpi in @(96,144,192)){
    Set-Content (Join-Path $fixture 'mode.txt') 'large'
    $script:process=Start-UIWithEnvironment ('--fixture-dpi '+$dpi) @{ICLOUD_SCRIPT_ROOT=$fixture};$script:window=[IntPtr]::Zero
    Wait-For {$script:window=[RustUIProbe]::Find($process.Id);$window -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($window) -and (Control 110) -ne [IntPtr]::Zero} 'Owned UI window missing'
    Assert (-not [RustUIProbe]::IsWindowEnabled((Control 3))) 'Apply enabled before preview'
    [RustUIProbe]::Send($window,0x0111,[IntPtr]3,[IntPtr]::Zero)|Out-Null
    Wait-Status '*Preview required*'
    Assert (-not (Test-Path (Join-Path $fixture 'requests.jsonl'))) 'Forged unreviewed Apply reached worker'
    $drive=Join-Path $fixture ('Drive '+[char]0xe9+" ! & ' test")
    [RustUIProbe]::SetText((Control 100),$drive)
    Click 101;Click 102
    $custom=Join-Path $drive 'Custom Desktop'
    [RustUIProbe]::SetText((Control 200),$custom)
    Click 1;Wait-Status '*Fixture completed*'
    Assert ([RustUIProbe]::IsWindowEnabled((Control 3))) 'Successful preview did not enable Apply'
    $captured=Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json
    Assert ($captured.Root -ceq $drive -and $captured.FolderPaths.Desktop -ceq $custom -and $captured.FolderPaths.Captures -ceq (Join-Path $drive 'Videos\Captures')) 'Unicode/custom mapping transport changed'
    Confirm $false
    Assert ((Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json).Phase -eq 'Preview') 'Cancelled confirmation started Apply'
    [RustUIProbe]::SetText((Control 200),(Join-Path $drive 'Changed Desktop'))
    Assert (-not [RustUIProbe]::IsWindowEnabled((Control 3))) 'Path edit retained stale review'
    Set-Content (Join-Path $fixture 'mode.txt') 'normal'
    foreach($index in @(0,1,2,3,4,6,8)){
        Choose $index
        [RustUIProbe]::SetText((Control 111),(Join-Path $fixture 'before.json'))
        Click 116;Wait-Status '*Fixture completed*'
        Assert ([RustUIProbe]::IsWindowEnabled((Control 3))) 'Dry run did not enable reviewed action'
        Assert ((Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json).Phase -eq 'DryRun') 'Dry run phase was lost'
        Confirm $true;Wait-Status '*Fixture completed*'
        Wait-For {[RustUIProbe]::IsWindowEnabled((Control 1))} 'Apply did not finish'
        $captured=Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json
        Assert ($captured.Phase -eq 'Apply') 'Confirmed action did not reach fixture'
        Assert (-not [RustUIProbe]::IsWindowEnabled((Control 3))) 'Apply retained review for repeated writes'
    }
    Choose 7;Click 1;Wait-Status '*Fixture completed*'
    Assert (-not [RustUIProbe]::IsWindowVisible((Control 3))) 'Read-only action displays Apply'
    Click 6;Wait-Status '*Fixture completed*'
    Assert ([RustUIProbe]::IsWindowVisible((Control 115))) 'Structured configuration table missing'
    Assert ([RustUIProbe]::Send((Control 115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -eq 3) 'Configuration table has incorrect row count'
    Assert ([RustUIProbe]::AccessibleName((Control 115)) -eq 'Folder results') 'Table lacks accessible name'
    [RustUIProbe]::Screenshot($window,(Join-Path $evidence ('check-dpi-'+$dpi+'.png')))
    Click 114;Assert ([RustUIProbe]::IsWindowVisible((Control 103))) 'Technical details toggle failed';Click 114
    Choose 3;Click 1;Wait-Status '*Fixture completed*'
    Set-Content (Join-Path $fixture 'mode.txt') 'copy'
    Confirm $true;Wait-Status '*Copying*'
    [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Click 105;Wait-Status '*Copy stopped safely*'
    Assert (Test-Path (Join-Path $fixture 'copy-finished.txt')) 'Copy worker was terminated before safe boundary'
    Set-Content (Join-Path $fixture 'mode.txt') 'normal'
    Choose 1;Click 1;Wait-Status '*Fixture completed*'
    Set-Content (Join-Path $fixture 'mode.txt') 'write'
    Confirm $true
    [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    [RustUIProbe]::Send($window,0x0111,[IntPtr]105,[IntPtr]::Zero)|Out-Null
    Wait-Status '*Fixture completed*'
    Assert (Test-Path (Join-Path $fixture 'write-finished.txt')) 'Writing worker was terminated'
    Set-Content (Join-Path $fixture 'mode.txt') 'slow'
    Click 6;Wait-Status '*Working*'
    [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Start-Sleep -Milliseconds 100;Assert (-not $process.HasExited) 'Closed active operation'
    Click 105;Wait-Status '*Read-only check stopped*'
    Set-Content (Join-Path $fixture 'mode.txt') 'mismatch';Click 6;Wait-Status '*inconsistent exit codes*'
    Set-Content (Join-Path $fixture 'mode.txt') 'overflow';Click 6;Wait-Status '*output limit*'
    Assert ([RustUIProbe]::AccessibleName((Control 200)) -like '*Desktop*') 'Destination lost accessible name'
    Assert ([ICloudTestDesktop]::InputName() -ceq $inputDesktop) 'Input desktop changed'
    [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'UI did not close cleanly'
    $process.Dispose();$process=$null
    $results+=[pscustomobject]@{Dpi=$dpi;ActionRoutes=$true;Confirmation=$true;ReviewInvalidation=$true;StructuredTable=$true;CooperativeCopyStop=$true;WritesNotTerminated=$true}
    'PASS: DPI '+$dpi+' action routes, preview binding, confirmation/cancel, table, progress, safe copy stop, write protection, output bounds and clean close'
    Remove-Item -LiteralPath (Join-Path $fixture 'requests.jsonl') -Force
 }
 if($BackendWorkerPath -and $RunNativeIntegration){
    $nativeRoot=Join-Path $fixture 'native-check-drive';$null=[IO.Directory]::CreateDirectory($nativeRoot)
    $script:process=Start-UIWithEnvironment '--mode Setup' @{ICLOUD_SCRIPT_ROOT=$fixture;ICLOUD_NATIVE_BACKEND=$BackendWorkerPath};$script:window=[IntPtr]::Zero
    Wait-For {$script:window=[RustUIProbe]::Find($process.Id);$window -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($window) -and (Control 110) -ne [IntPtr]::Zero} 'Native-backend UI window missing'
    [RustUIProbe]::SetText((Control 100),$nativeRoot)
    Click 6;Wait-Status '*configuration*'
    Assert ([RustUIProbe]::IsWindowVisible((Control 115))) 'Native Rust check did not render the structured results table'
    Assert ([RustUIProbe]::Send((Control 115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -gt 1) 'Native Rust check returned no folder rows'
    Assert (-not(Test-Path (Join-Path $fixture 'requests.jsonl'))) 'Native Rust configuration check used the PowerShell bridge'
    [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Native-check UI did not close cleanly'
    $process.Dispose();$process=$null
    'PASS: Rust UI routes configuration Check through the Rust worker and renders its structured result without PowerShell'
    $beforeBootstrap=@(Get-Process -Name icloud-folder-ui -ErrorAction SilentlyContinue|ForEach-Object Id)
    & (Join-Path $repo 'Start-ICloudRustUI.ps1') -InitialMode Setup
    $uiBuild=Get-Content (Join-Path $repo '.local/rust-ui-build.json') -Raw|ConvertFrom-Json
    Wait-For {$script:process=Get-Process -Name icloud-folder-ui -ErrorAction SilentlyContinue|Where-Object {$_.Id -notin $beforeBootstrap -and $_.Path -ieq $uiBuild.WorkerPath}|Select-Object -First 1;$script:window=if($script:process){[RustUIProbe]::Find($script:process.Id)}else{[IntPtr]::Zero};$script:process -and $script:window -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($script:window)} 'Rust UI bootstrap did not launch its native window on the hidden desktop'
    $bootstrapRoot=Join-Path $fixture 'bootstrap-check-drive';$null=[IO.Directory]::CreateDirectory($bootstrapRoot)
    [RustUIProbe]::SetText((Control 100),$bootstrapRoot)
    Click 1;Wait-Status '*Setup preview*'
    Assert ([RustUIProbe]::IsWindowVisible((Control 115))) 'Bootstrap-launched UI did not render Rust setup preview results'
    Assert ([RustUIProbe]::Send((Control 115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -gt 1) 'Bootstrap-launched Rust setup preview returned no folder rows'
    Assert (-not [RustUIProbe]::IsWindowEnabled((Control 3))) 'Setup preview enabled Apply without completed review gates'
    Assert (-not(Test-Path (Join-Path $fixture 'requests.jsonl'))) 'Bootstrap-launched Rust setup preview used the PowerShell bridge'
    [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    $closed=$process.WaitForExit(10000)
    Assert ($closed -and $process.HasExited) 'Bootstrap-launched UI did not close cleanly'
    $process.Dispose();$process=$null
    'PASS: Start-ICloudRustUI builds/caches its worker and routes Check through it on the hidden desktop'

    $restoreRoot=Join-Path $fixture 'restore targets';$null=[IO.Directory]::CreateDirectory($restoreRoot)
    $module=Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force -PassThru
    $map=& $module { Get-FolderMap -IncludeMusic }
    $values=@(foreach($name in $map.Keys){
        $destination=Join-Path $restoreRoot $map[$name]
        $null=[IO.Directory]::CreateDirectory($destination)
        [pscustomobject]@{Name=$name;Exists=$true;Kind='ExpandString';Data=$destination}
    })
    $restoreBackup=[ordered]@{
        Version=1;Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        Key='Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
        CreatedUtc=[DateTime]::UtcNow.ToString('o');Values=$values
    }
    $restoreBackupPath=Join-Path $fixture 'synthetic-before.json'
    [IO.File]::WriteAllText($restoreBackupPath,($restoreBackup|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
    $script:process=Start-UIWithEnvironment '--mode Setup' @{ICLOUD_SCRIPT_ROOT=$fixture;ICLOUD_NATIVE_BACKEND=$BackendWorkerPath};$script:window=[IntPtr]::Zero
    Wait-For {$script:window=[RustUIProbe]::Find($process.Id);$window -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($window) -and (Control 110) -ne [IntPtr]::Zero} 'Rust restore-preview UI window missing'
    Choose 2
    [RustUIProbe]::SetText((Control 111),$restoreBackupPath)
    Click 116;Wait-Status '*Recovery preview is ready*'
    Assert ([RustUIProbe]::IsWindowVisible((Control 115))) 'Rust recovery preview did not render its structured table'
    Assert ([RustUIProbe]::Send((Control 115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -eq $values.Count) 'Rust recovery preview returned the wrong number of folder rows'
    Assert ([RustUIProbe]::IsWindowEnabled((Control 3))) 'Validated recovery preview did not enable reviewed Apply'
    Assert (-not(Test-Path (Join-Path $fixture 'requests.jsonl'))) 'Rust recovery preview used the PowerShell bridge'
    [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Rust recovery-preview UI did not close cleanly'
    $process.Dispose();$process=$null
    'PASS: Rust UI routes recovery Dry run through the native worker, validates the selected backup and renders the exact folder plan without applying it'
 }
 $results|ConvertTo-Json|Set-Content (Join-Path $evidence 'results.json') -Encoding UTF8
}catch{
    ($_|Format-List * -Force|Out-String)|Write-Host
    throw
}finally{
 [RustUIProbe]::SetThreadDpiAwarenessContext($previousDpi)|Out-Null
 if($process){if(-not $process.HasExited){$process.Kill();$process.WaitForExit()};$process.Dispose()}
 $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^ICloudRustUIFixture-[a-f0-9]{32}$'){throw 'Refusing cleanup outside fixture'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
