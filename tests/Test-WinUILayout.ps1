#requires -Version 5.1
$ErrorActionPreference='Stop'
if(-not $env:ICLOUD_TEST_DESKTOP){& (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -TimeoutSeconds 600;return}
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
foreach($fontScale in @(1,2)){
foreach($case in $cases){
foreach($custom in @($false,$true)){
    if($custom -and -not($case.Category -eq 'Locations' -and $case.Index -eq 0)){continue}
    $suffix=if($custom){'-custom'}else{''}
    $image=Join-Path $repo ('.local/hidden-desktop/winui-layout-'+$size.Width+'-'+$case.Category+'-'+$case.Index+'-font'+$fontScale+$suffix+'.png')
    foreach($file in @($image,($image+'.json'))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$exe;$start.UseShellExecute=$false
    $start.Arguments='--source "'+$repo+'" --render-fixture "'+$image+'" --fixture-width '+$size.Width+' --fixture-height '+$size.Height
    $start.Arguments+=' --fixture-category '+$case.Category+' --fixture-action-index '+$case.Index
    $start.Arguments+=' --fixture-font-scale '+$fontScale
    if($custom){$start.Arguments+=' --fixture-custom-paths'}
    $process=[Diagnostics.Process]::Start($start)
    try{
        $until=[DateTime]::UtcNow.AddSeconds(30)
        while(-not(Test-Path -LiteralPath ($image+'.json')) -and [DateTime]::UtcNow -lt $until){
            if($process.HasExited){throw ('Layout fixture exited: '+$process.ExitCode)}
            Start-Sleep -Milliseconds 100
        }
        if(-not(Test-Path -LiteralPath ($image+'.json'))){throw 'Layout fixture timed out.'}
        $report=Get-Content -LiteralPath ($image+'.json') -Raw | ConvertFrom-Json
        if($report.FontScale -ne $fontScale){throw 'Requested fixture font scale did not apply.'}
        $layout=$report.Layout
        if($null -eq $layout){throw 'Debug build lacks layout measurements.'}
        if($layout.Viewport.Height -lt 100){throw ('Scrollable content viewport is unusably small: '+$case.Action)}
        if($layout.Action -cne $case.Action){throw ('Wrong fixture action: '+$layout.Action)}
        if($layout.CustomPaths -ne $custom){throw 'Wrong folder path mode in layout fixture.'}
        if($case.Root -and @($layout.Destinations).Count -ne 7){throw 'Not all folder destinations are displayed.'}
        foreach($row in $layout.Destinations){
            foreach($name in @($(if($custom){'Editor','Browse'}else{'Display'}))){
                $bounds=$row.$name
                if($bounds.Width -le 0 -or $bounds.X -lt 0 -or $bounds.X+$bounds.Width -gt $layout.Width+1){throw ('Folder destination clipped horizontally: '+$row.Id+'; '+$name)}
            }
        }
        if($size.Width -eq 480 -and $case.Mutates -and ($layout.Apply.X -gt $layout.Preview.X+1 -or $layout.Apply.Y -lt $layout.Preview.Y+$layout.Preview.Height)){throw ('Narrow primary action did not reflow: '+$case.Action)}
        if($layout.Apply.Visible -ne $case.Mutates -or $layout.DryRun.Visible -ne $case.Mutates){throw ('Incorrect mutation control visibility: '+$case.Action)}
        if($layout.CloudRoot.Visible -ne $case.Root -or $layout.Backup.Visible -ne $case.Backup){throw ('Incorrect path control visibility: '+$case.Action)}
        $commands=@()
        foreach($name in @('Preview','DryRun','Apply')){
            $bounds=$layout.$name
            if(-not $bounds.Visible){continue}
            if($bounds.Width -le 0 -or $bounds.Height -le 0 -or $bounds.X -lt 0 -or $bounds.Y -lt 0 -or $bounds.X+$bounds.Width -gt $layout.Width+1 -or $bounds.Y+$bounds.Height -gt $layout.Height+1){throw ('Command outside client area: '+$name+' at '+$size.Width)}
            foreach($previous in $commands){
                if($bounds.X -lt $previous.X+$previous.Width-1 -and $previous.X -lt $bounds.X+$bounds.Width-1 -and $bounds.Y -lt $previous.Y+$previous.Height-1 -and $previous.Y -lt $bounds.Y+$bounds.Height-1){throw ('Overlapping commands at '+$size.Width)}
            }
            $commands+=$bounds
        }
        foreach($name in @('CloudRoot','Backup')){
            $bounds=$layout.$name
            if($bounds.Visible -and ($bounds.Width -le 0 -or $bounds.X -lt 0 -or $bounds.X+$bounds.Width -gt $layout.Width+1)){throw ('Path controls clipped horizontally: '+$case.Action)}
        }
        Write-Output ('PASS: '+$case.Action+' layout at '+$size.Width+' x '+$size.Height+' logical pixels, font scale '+$fontScale+'; '+$image)
    }finally{if(-not $process.HasExited){$process.Kill();$process.WaitForExit(5000)|Out-Null};$process.Dispose()}
}
}
}
}
