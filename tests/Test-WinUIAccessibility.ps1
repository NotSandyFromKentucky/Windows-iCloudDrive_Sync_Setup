#requires -Version 5.1
$ErrorActionPreference='Stop'
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
$repo=Split-Path $PSScriptRoot -Parent
$exe=Join-Path $repo 'ui/ICloudFolderSetup/bin/x64/Debug/net10.0-windows10.0.19041.0/win-x64/ICloudFolderSetup.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'Build the native Debug x64 project first.'}
$image=Join-Path $repo '.local/hidden-desktop/winui-keyboard.png'
foreach($file in @($image,($image+'.json'))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=$exe;$start.UseShellExecute=$false
$start.Arguments='--source "'+$repo+'" --render-fixture "'+$image+'" --fixture-keyboard'
$process=[Diagnostics.Process]::Start($start)
try{
    $until=[DateTime]::UtcNow.AddSeconds(35)
    while(-not(Test-Path -LiteralPath ($image+'.json')) -and [DateTime]::UtcNow -lt $until){
        if($process.HasExited){throw ('Keyboard fixture exited: '+$process.ExitCode)}
        Start-Sleep -Milliseconds 100
    }
    if(-not(Test-Path -LiteralPath ($image+'.json'))){throw 'Keyboard fixture timed out.'}
    $report=Get-Content -LiteralPath ($image+'.json') -Raw | ConvertFrom-Json
    $report.Keyboard | Format-Table -AutoSize | Out-String | Write-Output
    if(-not $report.KeyboardBoundary){throw 'Forward navigation did not reach the window boundary.'}
    $forward=@($report.Keyboard)
    $reverse=@($report.KeyboardReverse)
    if($reverse.Count -ne $forward.Count-1){throw 'Reverse navigation did not return through all forward tab stops.'}
    for($i=0;$i -lt $reverse.Count;$i++){
        if($reverse[$i] -cne $forward[$forward.Count-2-$i].Element){throw 'Reverse tab order differs from forward order.'}
    }
    $expected=@{
        ActionChoice=@('Action','ComboBox');CloudRoot=@('iCloud Drive folder','Edit');
        Music=@('Include Music','CheckBox');ManualRoot=@('Use a manually verified iCloud folder','CheckBox');
        KeepFiles=@('Change locations without copying existing files','CheckBox');
        Results=@('Plan and results','Edit');Technical=@('Technical details','CheckBox');
        Preview=@('Preview','Button');DryRun=@('Dry run','Button')
    }
    foreach($id in $expected.Keys){
        $nodes=@($report.Keyboard | Where-Object {$_.Element -eq $id -or $_.Id -eq $id})
        if($nodes.Count -ne 1){throw ('Expected one reachable tab stop: '+$id)}
        if($nodes[0].Name -cne $expected[$id][0] -or $nodes[0].Role -cne $expected[$id][1]){throw ('Incorrect accessible name/role: '+$id)}
    }
    if(@($report.Keyboard | Where-Object {$_.Element -eq 'Apply' -or $_.Id -eq 'Apply'}).Count){throw 'Disabled Apply is in the tab sequence.'}
    foreach($id in @('CloudRoot','Music','ManualRoot','KeepFiles')){
        $node=@($report.Keyboard|Where-Object Element -eq $id)[0]
        if([string]::IsNullOrWhiteSpace($node.Help)){throw ('Explanatory help is unavailable to assistive technology: '+$id)}
    }
    if(($report.Keyboard|Where-Object Element -eq 'ManualRoot').Help -notlike '*cannot be overridden*'){throw 'Manual-root accessibility help omits the mismatch restriction.'}
    if(($report.Keyboard|Where-Object Element -eq 'KeepFiles').Help -notlike '*files stay where they are*'){throw 'Existing-content accessibility help omits retained originals.'}
    'PASS: native forward/reverse focus navigation, reachable named controls, logical reverse order and skipped disabled Apply'
}finally{if(-not $process.HasExited){$process.Kill();$process.WaitForExit(5000)|Out-Null};$process.Dispose()}
