#requires -Version 5.1
$ErrorActionPreference='Stop'
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
$repo=Split-Path $PSScriptRoot -Parent
$exe=Join-Path $repo 'ui/ICloudFolderSetup/bin/x64/Debug/net10.0-windows10.0.19041.0/win-x64/ICloudFolderSetup.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'Build the native Debug x64 project first.'}
$cases=@(
    @{Category='Locations';Index=0;Action='Set up iCloud folders';Mutates=$true;Root=$true;Backup=$false},
    @{Category='Locations';Index=1;Action='Reset to Windows defaults';Mutates=$true;Root=$false;Backup=$false},
    @{Category='Locations';Index=2;Action='Restore a recovery backup';Mutates=$true;Root=$false;Backup=$true},
    @{Category='Copy';Index=0;Action='Copy files into iCloud folders';Mutates=$true;Root=$true;Backup=$false},
    @{Category='Copy';Index=1;Action='Copy files into Windows default folders';Mutates=$true;Root=$false;Backup=$false},
    @{Category='Check';Index=0;Action='Check iCloud configuration';Mutates=$false;Root=$true;Backup=$false},
    @{Category='Cloud';Index=0;Action='Create cloud test file';Mutates=$true;Root=$false;Backup=$false},
    @{Category='Cloud';Index=1;Action='Check cloud return';Mutates=$false;Root=$false;Backup=$false},
    @{Category='Cloud';Index=2;Action='Clean up cloud test file';Mutates=$true;Root=$false;Backup=$false}
)
foreach($size in @(@{Width=960;Height=800},@{Width=640;Height=720},@{Width=480;Height=640})){
foreach($case in $cases){
    $image=Join-Path $repo ('.local/hidden-desktop/winui-layout-'+$size.Width+'-'+$case.Category+'-'+$case.Index+'.png')
    foreach($file in @($image,($image+'.json'))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$exe;$start.UseShellExecute=$false
    $start.Arguments='--source "'+$repo+'" --render-fixture "'+$image+'" --fixture-width '+$size.Width+' --fixture-height '+$size.Height
    $start.Arguments+=' --fixture-category '+$case.Category+' --fixture-action-index '+$case.Index
    $process=[Diagnostics.Process]::Start($start)
    try{
        $until=[DateTime]::UtcNow.AddSeconds(30)
        while(-not(Test-Path -LiteralPath ($image+'.json')) -and [DateTime]::UtcNow -lt $until){
            if($process.HasExited){throw ('Layout fixture exited: '+$process.ExitCode)}
            Start-Sleep -Milliseconds 100
        }
        if(-not(Test-Path -LiteralPath ($image+'.json'))){throw 'Layout fixture timed out.'}
        $layout=(Get-Content -LiteralPath ($image+'.json') -Raw | ConvertFrom-Json).Layout
        if($null -eq $layout){throw 'Debug build lacks layout measurements.'}
        if($layout.Action -cne $case.Action){throw ('Wrong fixture action: '+$layout.Action)}
        if($layout.Apply.Visible -ne $case.Mutates -or $layout.DryRun.Visible -ne $case.Mutates){throw ('Incorrect mutation control visibility: '+$case.Action)}
        if($layout.CloudRoot.Visible -ne $case.Root -or $layout.Backup.Visible -ne $case.Backup){throw ('Incorrect path control visibility: '+$case.Action)}
        $previous=$null
        foreach($name in @('Preview','DryRun','Apply')){
            $bounds=$layout.$name
            if(-not $bounds.Visible){continue}
            if($bounds.Width -le 0 -or $bounds.Height -le 0 -or $bounds.X -lt 0 -or $bounds.Y -lt 0 -or $bounds.X+$bounds.Width -gt $layout.Width+1 -or $bounds.Y+$bounds.Height -gt $layout.Height+1){throw ('Command outside client area: '+$name+' at '+$size.Width)}
            if($previous -and $bounds.X -lt $previous.X+$previous.Width-1){throw ('Overlapping commands at '+$size.Width)}
            $previous=$bounds
        }
        foreach($name in @('CloudRoot','Backup')){
            $bounds=$layout.$name
            if($bounds.Visible -and ($bounds.Width -le 0 -or $bounds.X -lt 0 -or $bounds.X+$bounds.Width -gt $layout.Width+1)){throw ('Path controls clipped horizontally: '+$case.Action)}
        }
        Write-Output ('PASS: '+$case.Action+' layout at '+$size.Width+' x '+$size.Height+' logical pixels; '+$image)
    }finally{if(-not $process.HasExited){$process.Kill();$process.WaitForExit(5000)|Out-Null};$process.Dispose()}
}
}
