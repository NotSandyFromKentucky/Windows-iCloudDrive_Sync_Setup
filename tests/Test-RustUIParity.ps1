#requires -Version 5.1
param([Parameter(Mandatory)][string]$WorkerPath,[string]$BackendWorkerPath,[switch]$RunNativeIntegration,[switch]$NoHiddenDesktop)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$WorkerPath=(Resolve-Path -LiteralPath $WorkerPath).Path
if(-not $env:ICLOUD_TEST_DESKTOP -and -not $NoHiddenDesktop){& (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{WorkerPath=$WorkerPath;BackendWorkerPath=$BackendWorkerPath;RunNativeIntegration=$RunNativeIntegration.IsPresent} -TimeoutSeconds 300;return}
if($NoHiddenDesktop){
    $visibleEnvironment=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
    if($visibleEnvironment -ne 'GitHubHosted'){throw 'NoHiddenDesktop UI automation is restricted to a GitHub-hosted runner.'}
    if($env:ICLOUD_TEST_DESKTOP){throw 'NoHiddenDesktop mode must run on the visible runner desktop.'}
    if(-not ('ICloudTestDesktop' -as [type])){Add-Type -Path (Join-Path $PSScriptRoot 'HiddenDesktop.cs')}
}elseif(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
if($RunNativeIntegration){$isolation=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1');if($isolation -notin @('GitHubHosted','WindowsSandbox')){throw 'Native UI integration tests require a disposable Windows environment.'}}
Add-Type -AssemblyName System.Drawing,Accessibility
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
Add-Type -Path (Join-Path $PSScriptRoot 'RustUIProbe.cs') -ReferencedAssemblies System.Drawing,Accessibility
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
function Wait-For([scriptblock]$Condition,[string]$Message){$end=[DateTime]::UtcNow.AddSeconds(20);while([DateTime]::UtcNow -lt $end){if(& $Condition){return};Start-Sleep -Milliseconds 30};throw $Message}
function Control([int]$Id){[RustUIProbe]::GetDlgItem($script:window,$Id)}
function TableLabel {([RustUIProbe]::Text((Control 404))).Trim()}
function HasTablePage([int]$Page){(TableLabel) -like ('*rows '+$Page+'*of 2')}
function Click([int]$Id){[RustUIProbe]::Click((Control $Id))}
function Post-Click([int]$Id){[RustUIProbe]::PostMessage($script:window,0x0111,[IntPtr]$Id,[IntPtr]::Zero)|Out-Null}
function Status {([RustUIProbe]::Text((Control 403)))+' '+([RustUIProbe]::Text((Control 103)))}
function Wait-Status([string]$Pattern){Wait-For {(Status) -like $Pattern} ('Status timed out: '+$Pattern+'; '+(Status));if($Pattern -notin @('*Working*','*Copying*')){Wait-For {[RustUIProbe]::IsWindowEnabled((Control 1))} 'Operation result displayed before controls became ready'}}
function Choose([int]$Index){[RustUIProbe]::Send((Control 110),0x014e,[IntPtr]$Index,[IntPtr]::Zero)|Out-Null;[RustUIProbe]::Send($script:window,0x0111,[IntPtr](110 -bor (1 -shl 16)),(Control 110))|Out-Null}
function Cancel-Picker {
    Wait-For {$script:dialog=[RustUIProbe]::Dialog($process.Id);$dialog -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($dialog)} 'Owned file/folder picker did not become visible'
    [RustUIProbe]::Send($dialog,0x0111,[IntPtr]2,[IntPtr]::Zero)|Out-Null
    Wait-For {[RustUIProbe]::Dialog($process.Id) -eq [IntPtr]::Zero} 'Owned picker did not close after cancellation'
}
function Select-PickerFolder([int]$Id,[string]$Path) {
    Post-Click $Id
    Wait-For {$script:dialog=[RustUIProbe]::Dialog($process.Id);$dialog -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($dialog)} 'Owned folder picker did not become visible for selection'
    $handle=$script:dialog.ToInt64().ToString([Globalization.CultureInfo]::InvariantCulture)
    $output=& $accessibilityProbe '--select-folder' $handle $process.Id $Path
    Assert ($LASTEXITCODE -eq 0) ('Owned folder picker selection probe failed: '+($output -join ' '))
    Wait-For {([RustUIProbe]::Dialog($process.Id) -eq [IntPtr]::Zero -or -not [RustUIProbe]::IsWindowVisible([RustUIProbe]::Dialog($process.Id))) -and [RustUIProbe]::IsWindowEnabled($script:window)} 'Selected folder picker did not dismiss'
}
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
    if($NoHiddenDesktop){$Environment['ICLOUD_UI_FIXTURE_MODE']='1'}
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
function Invoke-NativeBackend([string]$Worker,[string]$Request){
    if([string]::IsNullOrWhiteSpace($Request)){throw 'Native backend test request is empty.'}
    $previousEncoding=$OutputEncoding
    try{
        $OutputEncoding=New-Object Text.UTF8Encoding($false)
        $raw=@($Request | & $Worker 2>&1)
        $exitCode=$LASTEXITCODE
        $nativeErrors=@($raw|Where-Object {$_ -is [System.Management.Automation.ErrorRecord]})
        $stdoutText=(@($raw|Where-Object {$_ -isnot [System.Management.Automation.ErrorRecord]}|ForEach-Object {[string]$_}) -join [Environment]::NewLine)
        $stderrText=(@($nativeErrors|ForEach-Object {[string]$_.ToString()}) -join [Environment]::NewLine)
        if($exitCode -ne 0 -or $nativeErrors.Count -gt 0){
            if($stdoutText.Length -gt 2000){$stdoutText=$stdoutText.Substring(0,2000)}
            if($stderrText.Length -gt 2000){$stderrText=$stderrText.Substring(0,2000)}
            throw ('Native backend default-path query failed (exit '+$exitCode+'). stderr: '+$stderrText+' stdout: '+$stdoutText)
        }
        return @($stdoutText -split '\r?\n'|Where-Object {$_}|ForEach-Object {$_|ConvertFrom-Json})
    }finally{$OutputEncoding=$previousEncoding}
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ICloudRustUIFixture-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory((Join-Path $fixture 'tools'))
$accessibilityProbe=Join-Path $fixture 'RustUIAccessibilityProbe.exe'
$automationReferences=@('System.dll',([Windows.Automation.AutomationElement].Assembly.Location),([Windows.Automation.ControlType].Assembly.Location),([Accessibility.IAccessible].Assembly.Location))
Add-Type -Path (Join-Path $PSScriptRoot 'RustUIAccessibilityProbe.cs') -ReferencedAssemblies $automationReferences -OutputType ConsoleApplication -OutputAssembly $accessibilityProbe
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
[Console]::Out.WriteLine(('@@ICloudResult:'+(@{Version=2;ExitCode=$code;Message=$message;Text=$body;TextTruncated=$false;CapturedCharacters=$body.Length}|ConvertTo-Json -Compress)))
if($mode -eq 'mismatch'){exit 2};exit $code
'@
[IO.File]::WriteAllText((Join-Path $fixture 'tools/Invoke-WinUIBridge.ps1'),$stub)
$fakeNativeSource=@'
using System;
using System.IO;
using System.Text.RegularExpressions;
public static class FakeNativeCopyWorker {
    static string Quote(string value) { return "\""+value.Replace("\\", "\\\\").Replace("\"", "\\\"")+"\""; }
    public static int Main() {
        string request=Console.In.ReadToEnd();
        Match match=Regex.Match(request,@"""page_offset""\s*:\s*(\d+)");
        if(!match.Success){Console.Error.WriteLine("Missing page_offset");return 2;}
        int offset=Int32.Parse(match.Groups[1].Value);
        string folder=Path.GetDirectoryName(typeof(FakeNativeCopyWorker).Assembly.Location);
        bool drift=offset>0 && File.Exists(Path.Combine(folder,"drift.flag"));
        string token=new String(drift?'B':'A',64);
        string next=offset==0?"1":"null";
        string source=@"C:\Fixture\source-"+offset+".txt";
        string destination=@"C:\Fixture\destination-"+offset+".txt";
        string row="{\"directory\":false,\"source\":"+Quote(source)+",\"destination\":"+Quote(destination)+",\"action\":\"Copy\"}";
        string root=Quote(@"C:\Fixture");
        string page="{\"version\":1,\"type\":\"copy_preview_page\",\"preview\":{\"operation\":\"copy_to_icloud\",\"root\":"+root+",\"reset_to_defaults\":false,\"review_gates_passed\":true,\"root_registered\":true,\"registered_roots\":["+root+"],\"page_offset\":"+offset+",\"next_offset\":"+next+",\"total_entries\":2,\"entries\":["+row+"]},\"approval_token\":\""+token+"\"}";
        File.AppendAllText(Path.Combine(folder,"page-requests.log"),offset+":"+(drift?"drift":"stable")+Environment.NewLine);
        Console.WriteLine(page);
        Console.WriteLine("{\"version\":1,\"type\":\"result\",\"ok\":true,\"read_only\":true}");
        return 0;
    }
}
'@
$fakeNativeWorker=Join-Path $fixture 'fake-native-copy-worker.exe'
Add-Type -TypeDefinition $fakeNativeSource -OutputType ConsoleApplication -OutputAssembly $fakeNativeWorker
$evidence=Join-Path $repo '.local/rust-ui-parity';$null=[IO.Directory]::CreateDirectory($evidence)
$previousDpi=[RustUIProbe]::SetThreadDpiAwarenessContext([IntPtr](-4))
$inputDesktop=[ICloudTestDesktop]::InputName();$process=$null;$results=@();$script:copyApplyRunning=$false
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
    if($dpi -eq 96){
        Post-Click 117;Cancel-Picker
        Assert ([RustUIProbe]::Text((Control 100)) -ceq $drive) 'Cancelling the root folder picker changed the selected path'
        $pickedRoot=Join-Path $fixture ('Picked Root '+[char]0xe9);$null=[IO.Directory]::CreateDirectory($pickedRoot)
        Select-PickerFolder 117 $pickedRoot
        Wait-For {([RustUIProbe]::Text((Control 100)) -ceq $pickedRoot)} 'Root picker did not apply the selected Unicode folder'
        $drive=$pickedRoot
    }
    Click 101;Click 102
    $custom=Join-Path $drive 'Custom Desktop'
    [RustUIProbe]::SetText((Control 200),$custom)
    if($dpi -eq 96){
        Assert ([RustUIProbe]::IsWindowVisible((Control 300))) 'Advanced folder picker was not shown with custom paths enabled'
        Post-Click 300;Cancel-Picker
        Assert ([RustUIProbe]::Text((Control 200)) -ceq $custom) 'Cancelling a per-folder picker changed its custom path'
        $pickedCustom=Join-Path $drive ('Picked Desktop '+[char]0xe9);$null=[IO.Directory]::CreateDirectory($pickedCustom)
        Select-PickerFolder 300 $pickedCustom
        Wait-For {([RustUIProbe]::Text((Control 200)) -ceq $pickedCustom)} 'Advanced picker did not apply the selected Unicode folder'
        $custom=$pickedCustom
    }
    Click 1;Wait-Status '*Fixture completed*'
    Assert ([RustUIProbe]::IsWindowEnabled((Control 3))) 'Successful preview did not enable Apply'
    $captured=Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json
    Assert ($captured.Root -ceq $drive -and $captured.FolderPaths.Desktop -ceq $custom -and $captured.FolderPaths.Captures -ceq (Join-Path $drive 'Videos\Captures')) 'Unicode/custom mapping transport changed'
    Confirm $false
    Assert ((Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json).Phase -eq 'Preview') 'Cancelled confirmation started Apply'
    if($dpi -eq 96){
        $changedCustom=Join-Path $drive ('Changed Desktop '+[char]0xe9);$null=[IO.Directory]::CreateDirectory($changedCustom)
        Select-PickerFolder 300 $changedCustom
        Wait-For {([RustUIProbe]::Text((Control 200)) -ceq $changedCustom)} 'Second advanced picker selection did not update its path'
        Assert (-not [RustUIProbe]::IsWindowEnabled((Control 3))) 'Picker selection retained stale review'
        Click 1;Wait-Status '*Fixture completed*'
        $captured=Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json
        Assert ($captured.FolderPaths.Desktop -ceq $changedCustom) 'Re-preview did not transport the newly selected folder'
    }else{
        [RustUIProbe]::SetText((Control 200),(Join-Path $drive 'Changed Desktop'))
        Assert (-not [RustUIProbe]::IsWindowEnabled((Control 3))) 'Path edit retained stale review'
    }
    Set-Content (Join-Path $fixture 'mode.txt') 'normal'
    $expectedActions=@{0='Set up iCloud folders';1='Reset to Windows defaults';2='Restore a recovery backup';3='Copy files into iCloud folders';4='Copy files into Windows default folders';6='Create cloud test file';8='Clean up cloud test file'}
    foreach($index in @(0,1,2,3,4,6,8)){
        Choose $index
        [RustUIProbe]::SetText((Control 111),(Join-Path $fixture 'before.json'))
        Click 116;Wait-Status '*Fixture completed*'
        Assert ([RustUIProbe]::IsWindowEnabled((Control 3))) 'Dry run did not enable reviewed action'
        Assert ((Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json).Phase -eq 'DryRun') 'Dry run phase was lost'
        Confirm $true;Wait-Status '*Fixture completed*'
        Wait-For {[RustUIProbe]::IsWindowEnabled((Control 1))} 'Apply did not finish'
        $captured=Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json
        Assert ($captured.Phase -eq 'Apply' -and $captured.Action -ceq $expectedActions[$index]) ('Confirmed '+$expectedActions[$index]+' action did not reach the compatibility bridge unchanged')
        Assert (-not [RustUIProbe]::IsWindowEnabled((Control 3))) 'Apply retained review for repeated writes'
    }
    Choose 7;Click 1;Wait-Status '*Fixture completed*'
    $captured=Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json
    Assert ($captured.Action -ceq 'Check cloud return' -and $captured.Phase -eq 'Preview') 'Cloud return check did not use the read-only compatibility route'
    Assert (-not [RustUIProbe]::IsWindowVisible((Control 3))) 'Read-only action displays Apply'
    Click 6;Wait-Status '*Fixture completed*'
    Assert ([RustUIProbe]::IsWindowVisible((Control 115))) 'Structured configuration table missing'
    Assert ([RustUIProbe]::Send((Control 115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -eq 3) 'Configuration table has incorrect row count'
    $tableProbeText=& $accessibilityProbe $process.Id 115
    Assert ($LASTEXITCODE -eq 0) 'Standalone accessibility provider probe failed for the results table'
    $tableProbe=$tableProbeText|ConvertFrom-Json
    Assert ($tableProbe.uia_type -eq 'ControlType.DataGrid') ('Results table has wrong UIA control type: '+$tableProbe.uia_type)
    Assert ($tableProbe.msaa_name -eq 'Folder results') ('Results table MSAA name mismatch (actual: "'+$tableProbe.msaa_name+'", UIA name: "'+$tableProbe.uia_name+'")')
    Assert ($tableProbe.uia_name -eq 'Folder results') ('Results table UIA name mismatch (actual: "'+$tableProbe.uia_name+'")')
    [RustUIProbe]::Screenshot($window,(Join-Path $evidence ('check-dpi-'+$dpi+'.png')))
    if($dpi -eq 96){
        Post-Click 122
        Confirm $true;Wait-Status '*Fixture completed*'
        $captured=Get-Content (Join-Path $fixture 'requests.jsonl') -Tail 1|ConvertFrom-Json
        Assert ($captured.Action -ceq 'Install for me' -and $captured.Phase -eq 'Apply' -and -not $captured.DesktopShortcut) 'Install confirmation did not route its reviewed options to the compatibility bridge'
        'PASS: Rust UI cloud-test and Install routes preserve action, phase and reviewed options through the compatibility bridge'
    }
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
    $results+=[pscustomobject]@{Dpi=$dpi;ActionRoutes=$true;CloudTestBridge=$true;InstallBridge=($dpi -eq 96);Confirmation=$true;ReviewInvalidation=$true;StructuredTable=$true;CooperativeCopyStop=$true;WritesNotTerminated=$true}
    'PASS: DPI '+$dpi+' action routes, preview binding, confirmation/cancel, table, progress, safe copy stop, write protection, output bounds and clean close'
    Remove-Item -LiteralPath (Join-Path $fixture 'requests.jsonl') -Force
 }
 foreach($drift in @($false,$true)){
    $requestLog=Join-Path $fixture 'page-requests.log'
    if(Test-Path -LiteralPath $requestLog){Remove-Item -LiteralPath $requestLog -Force}
    $driftFlag=Join-Path $fixture 'drift.flag'
    if(Test-Path -LiteralPath $driftFlag){Remove-Item -LiteralPath $driftFlag -Force}
    $script:process=Start-UIWithEnvironment '--mode Setup' @{ICLOUD_SCRIPT_ROOT=$fixture;ICLOUD_NATIVE_BACKEND=$fakeNativeWorker};$script:window=[IntPtr]::Zero
    try{
        Wait-For {$script:window=[RustUIProbe]::Find($process.Id);$window -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($window) -and (Control 110) -ne [IntPtr]::Zero} 'Paged-copy fixture UI window missing'
        Choose 4
        Click 1
        Wait-For {[RustUIProbe]::IsWindowEnabled((Control 1))} 'Fake native copy preview did not finish'
        Assert (HasTablePage 1) ('First native copy-review page did not render; status: '+(Status)+'; table label: '+(TableLabel))
        Assert ([RustUIProbe]::IsWindowVisible((Control 125))) 'Next page control was hidden while another page was available'
        Assert ([RustUIProbe]::IsWindowEnabled((Control 3))) 'Valid first copy-review page did not bind Apply'
        Assert ([RustUIProbe]::Send((Control 115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -eq 1) 'First native review page returned an unexpected row count'
        if($drift){[IO.File]::WriteAllText($driftFlag,'change the full-plan token on the next page')}
        Click 125
        Wait-For {(Test-Path -LiteralPath $requestLog) -and @(Get-Content -LiteralPath $requestLog).Count -ge 2} 'Native worker did not receive the next-page request'
        $pageCalls=@(Get-Content -LiteralPath $requestLog)
        $expectedSecond=if($drift){'1:drift'}else{'1:stable'}
        Assert ($pageCalls.Count -eq 2 -and $pageCalls[0] -eq '0:stable' -and $pageCalls[1] -eq $expectedSecond) ('UI did not request both native pages in order: '+($pageCalls -join ', '))
        if($drift){
            Wait-For {([RustUIProbe]::Text((Control 403)) -like '*copy plan changed while loading this page*')} 'Changed native plan did not invalidate the copy review'
            Assert (-not [RustUIProbe]::IsWindowEnabled((Control 3))) 'Plan drift left Apply enabled'
            Assert (-not [RustUIProbe]::IsWindowVisible((Control 115))) 'Plan drift left stale page rows visible'
            Assert (-not [RustUIProbe]::IsWindowVisible((Control 124)) -and -not [RustUIProbe]::IsWindowVisible((Control 125))) 'Plan drift left stale page navigation visible'
        }else{
            Wait-For {HasTablePage 2} 'Second native copy-review page did not render'
            Assert ([RustUIProbe]::IsWindowVisible((Control 124))) 'Previous page control was hidden after advancing'
            Assert (-not [RustUIProbe]::IsWindowVisible((Control 125))) 'Next page control remained visible after the final page'
            Assert ([RustUIProbe]::IsWindowEnabled((Control 3))) 'Stable page token lost the reviewed Apply binding'
            Assert ([RustUIProbe]::Send((Control 115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -eq 1) 'Second native review page returned an unexpected row count'
            Click 124
            Wait-For {HasTablePage 1} 'Previous native copy-review page did not return to the first page'
        }
        if(-not $drift){
            $pageCalls=@(Get-Content -LiteralPath $requestLog)
            Assert ($pageCalls.Count -eq 3 -and $pageCalls[2] -eq '0:stable') 'Previous-page navigation did not request the first page again'
        }
        if($drift){'PASS: native page token drift discards stale copy rows and disables Apply'}else{'PASS: native copy review navigates next/previous pages while preserving the full-plan Apply binding'}
    }finally{
        if($process -and -not $process.HasExited){[RustUIProbe]::PostMessage([RustUIProbe]::Find($process.Id),0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null;if(-not $process.WaitForExit(10000)){$process.Kill();$process.WaitForExit()}}
        if($process){$process.Dispose();$process=$null}
    }
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

    $copyKey=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',$true)
    Assert ($null -ne $copyKey) 'Current-user shell-folder registry key is unavailable for the isolated Rust UI copy fixture'
    $copySourceRoot=Join-Path $fixture 'native-ui-copy-source';$null=[IO.Directory]::CreateDirectory($copySourceRoot)
    $copyName='native-ui-copy-'+[guid]::NewGuid().ToString('N')+'.txt'
    $copySourceFile=Join-Path $copySourceRoot $copyName
    $copyContents='native Rust UI copy fixture remains intact'
    [IO.File]::WriteAllText($copySourceFile,$copyContents)
    $hadPersonal=$copyKey.GetValueNames() -contains 'Personal'
    $personalKind=$null;$personalValue=$null
    if($hadPersonal){$personalKind=$copyKey.GetValueKind('Personal');$personalValue=$copyKey.GetValue('Personal',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
    $defaultRows=Invoke-NativeBackend $BackendWorkerPath '{"version":1,"operation":"defaults"}'
    $documents=@($defaultRows|Where-Object {$_.type -eq 'defaults'}|ForEach-Object {$_.folders}|Where-Object folder -eq 'Documents')
    Assert ($documents.Count -eq 1 -and $documents[0].path.StartsWith($env:USERPROFILE+'\',[StringComparison]::OrdinalIgnoreCase)) 'Windows default Documents path is unavailable or outside the disposable user profile'
    $copyDestinationRoot=[string]$documents[0].path
    $copyDestinationFile=Join-Path $copyDestinationRoot $copyName
    Assert (-not(Test-Path -LiteralPath $copyDestinationFile)) 'Unique Rust UI copy fixture destination already exists'
    $copyDestinationRootExisted=[IO.Directory]::Exists($copyDestinationRoot)
    try{
        $copyKey.SetValue('Personal',$copySourceRoot,[Microsoft.Win32.RegistryValueKind]::ExpandString)
        $script:process=Start-UIWithEnvironment '--mode Setup' @{ICLOUD_SCRIPT_ROOT=$fixture;ICLOUD_NATIVE_BACKEND=$BackendWorkerPath};$script:window=[IntPtr]::Zero
        Wait-For {$script:window=[RustUIProbe]::Find($process.Id);$window -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($window) -and (Control 110) -ne [IntPtr]::Zero} 'Native-copy UI window missing'
        Choose 4
        Click 1;Wait-Status '*File-copy preview*'
        Assert ([RustUIProbe]::IsWindowVisible((Control 115))) 'Native Rust copy preview did not render its structured plan table'
        Assert ([RustUIProbe]::IsWindowEnabled((Control 3))) 'Validated Windows-default copy preview did not enable reviewed Apply'
        Assert (-not(Test-Path (Join-Path $fixture 'requests.jsonl'))) 'Native Rust copy preview used the PowerShell bridge'
        Confirm $true;$script:copyApplyRunning=$true
        Wait-Status '*Copy verified*'
        $script:copyApplyRunning=$false
        Assert ((Test-Path -LiteralPath $copyDestinationFile -PathType Leaf) -and [IO.File]::ReadAllText($copyDestinationFile) -ceq $copyContents) 'Rust UI Apply did not create the verified Windows-default copy'
        Assert ([IO.File]::ReadAllText($copySourceFile) -ceq $copyContents) 'Rust UI Apply changed the source file'
        Assert (-not(Test-Path (Join-Path $fixture 'requests.jsonl'))) 'Native Rust copy Apply used the PowerShell bridge'
        [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
        Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Native-copy UI did not close cleanly'
        $process.Dispose();$process=$null
        'PASS: Rust UI routes Windows-default copy Preview and confirmed Apply through the native worker; source retained and destination verified'
    }finally{
        if($script:process){
            if(-not $script:process.HasExited -and $script:copyApplyRunning){
                if([RustUIProbe]::IsWindowEnabled((Control 105))){Click 105}
                Wait-For {[RustUIProbe]::IsWindowEnabled((Control 1))} 'Copy Apply did not finish at a safe boundary after the fixture requested cancellation'
                $script:copyApplyRunning=$false
            }
            if(-not $script:process.HasExited){[RustUIProbe]::PostMessage([RustUIProbe]::Find($script:process.Id),0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null;if(-not $script:process.WaitForExit(10000) -and -not $script:copyApplyRunning){$script:process.Kill();$script:process.WaitForExit()}}
            $script:process.Dispose();$script:process=$null
        }
        if($hadPersonal){$copyKey.SetValue('Personal',$personalValue,$personalKind)}else{$copyKey.DeleteValue('Personal',$false)}
        $copyKey.Dispose()
        if(Test-Path -LiteralPath $copyDestinationFile -PathType Leaf){Remove-Item -LiteralPath $copyDestinationFile -Force}
        if(-not $copyDestinationRootExisted -and [IO.Directory]::Exists($copyDestinationRoot) -and @(Get-ChildItem -LiteralPath $copyDestinationRoot -Force).Count -eq 0){Remove-Item -LiteralPath $copyDestinationRoot -Force}
    }

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

    $script:process=Start-UIWithEnvironment '--mode Setup' @{ICLOUD_SCRIPT_ROOT=$fixture;ICLOUD_NATIVE_BACKEND=$BackendWorkerPath};$script:window=[IntPtr]::Zero
    Wait-For {$script:window=[RustUIProbe]::Find($process.Id);$window -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($window) -and (Control 110) -ne [IntPtr]::Zero} 'Rust reset-preview UI window missing'
    Choose 1
    Click 113
    Click 1;Wait-Status '*Reset preview is ready*'
    Assert ([RustUIProbe]::IsWindowVisible((Control 115))) 'Rust reset preview did not render its structured table'
    Assert ([RustUIProbe]::Send((Control 115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -ge 6) 'Rust reset preview returned too few managed-folder rows'
    Assert ([RustUIProbe]::IsWindowEnabled((Control 3))) 'Validated reset preview did not enable reviewed Apply'
    Assert (-not(Test-Path (Join-Path $fixture 'requests.jsonl'))) 'Rust reset preview used the PowerShell bridge'
    [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Assert ($process.WaitForExit(10000) -and $process.ExitCode -eq 0) 'Rust reset-preview UI did not close cleanly'
    $process.Dispose();$process=$null
    'PASS: Rust UI routes reset Preview through the native worker and binds Apply to the returned review token without applying it'

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
 if($process){if(-not $process.HasExited -and -not $script:copyApplyRunning){$process.Kill();$process.WaitForExit()};$process.Dispose()}
 $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^ICloudRustUIFixture-[a-f0-9]{32}$'){throw 'Refusing cleanup outside fixture'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
