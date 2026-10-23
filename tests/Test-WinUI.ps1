#requires -Version 5.1
$ErrorActionPreference='Stop'
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$repo=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $repo ('.test-winui-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory((Join-Path $fixture 'tools'))
$process=$null
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Wait-For([scriptblock]$Condition,[string]$Message){
    $until=[DateTime]::UtcNow.AddSeconds(35)
    while([DateTime]::UtcNow -lt $until){if(& $Condition){return};if($process -and $process.HasExited){throw ('WinUI exited: '+$process.ExitCode)};Start-Sleep -Milliseconds 120}
    throw $Message
}
function Find-Control([string]$Id){$window.FindFirst([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$Id)))}
function Find-Name([string]$Name){$window.FindFirst([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,$Name)))}
function Invoke-Control($Control){Assert ($null -ne $Control) 'Missing control';$Control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Select-Action([string]$Name){
    (Find-Control 'ActionChoice').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Wait-For {$null -ne (Find-Name $Name)} ('Action unavailable: '+$Name)
    (Find-Name $Name).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-For {
        $choice=Find-Control 'ActionChoice'
        if($null -eq $choice){return $false}
        $selection=$choice.GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)
        $selection.Current.GetSelection()[0].Current.Name -eq $Name -and $null -ne (Find-Control 'Preview')
    } ('Action selection did not settle: '+$Name)
}
function Select-OrInvoke($Control){
    Assert ($null -ne $Control) 'Missing navigation item'
    $pattern=$null
    if($Control.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern,[ref]$pattern)){$pattern.Select()}
    elseif($Control.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern,[ref]$pattern)){$pattern.Invoke()}
    else{throw ('Navigation item has no selection/invoke pattern: '+$Control.Current.Name+'; '+$Control.Current.ControlType.ProgrammaticName)}
}
function Select-NavigationId([string]$Id){
    Wait-For {$item=Find-Control $Id;$null -ne $item -and $item.Current.IsEnabled} ('Navigation item not ready: '+$Id)
    Select-OrInvoke (Find-Control $Id)
}
try{
    Copy-Item -LiteralPath (Join-Path $repo 'ICloudFolderSetup.UI.psm1') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $repo 'ICloudFolders.psm1') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $repo 'tools/Invoke-WinUIBridge.ps1') -Destination (Join-Path $fixture 'tools')
    # Delay only the read-only metadata fixture to prove the window renders
    # while startup work is pending and cannot execute an incomplete plan.
    $bridgePath=Join-Path $fixture 'tools/Invoke-WinUIBridge.ps1'
    $delay="if(`$request.Action -eq 'Get folder definitions'){ `$deadline=[DateTime]::UtcNow.AddSeconds(35); while(-not (Test-Path (Join-Path `$root 'release-metadata'))){if([DateTime]::UtcNow -gt `$deadline){throw 'Metadata fixture timed out'};Start-Sleep -Milliseconds 100};"
    $bridgeText=[IO.File]::ReadAllText($bridgePath).Replace("if(`$request.Action -eq 'Get folder definitions'){",$delay)
    [IO.File]::WriteAllText($bridgePath,$bridgeText)
    @'
[CmdletBinding(SupportsShouldProcess)]
param([string]$ICloudRoot,[switch]$IncludeMusic,[switch]$Apply,[switch]$VerifiedSyncRoot,[switch]$AllowExistingContent,[switch]$ResetToDefaults,[string]$RestoreBackup,[hashtable]$FolderPaths=@{})
if($ICloudRoot -eq 'FAIL'){[Console]::Error.WriteLine('Access is denied to the fixture folder.');exit 1}
switch($ICloudRoot){
    'BACKUP-FAIL' {[Console]::Error.WriteLine('The backup SID does not match this account.');exit 1}
    'ROOT-MISMATCH' {[Console]::Error.WriteLine('The registered iCloud root does not match.');exit 1}
    'ROLLBACK-FAIL' {[Console]::Error.WriteLine('ROLLBACK INCOMPLETE: retain fixture-before.json.');exit 1}
    'SOURCE-CONTENT' {[Console]::Error.WriteLine('Existing source content requires review.');exit 1}
}
$payload=[ordered]@{Root=$ICloudRoot;Apply=[bool]$Apply;DryRun=[bool]$WhatIfPreference;Reset=[bool]$ResetToDefaults;Backup=$RestoreBackup}
if($FolderPaths.Count){$payload.Paths=$FolderPaths}
[pscustomobject]$payload | ConvertTo-Json -Compress -Depth 4
Write-Host 'Recovery backup: fixture-before.json'
if($Apply -and -not $WhatIfPreference){[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'applied.txt'),'fixture only')}
exit 0
'@ | Set-Content -LiteralPath (Join-Path $fixture 'Set-ICloudFolders.ps1') -Encoding UTF8
    $exe=Join-Path $repo 'ui/ICloudFolderSetup/bin/x64/Debug/net10.0-windows10.0.19041.0/win-x64/ICloudFolderSetup.exe'
    Assert (Test-Path -LiteralPath $exe) 'Build the WinUI Debug x64 project first.'
    # The desktop itself is hidden. Permit normal rendering only after its identity was verified above.
    $start=New-Object Diagnostics.ProcessStartInfo
    $render=Join-Path $repo '.local/hidden-desktop/winui-default.png'
    if(Test-Path -LiteralPath $render){Remove-Item -LiteralPath $render}
    $start.FileName=$exe;$start.Arguments='--source "'+$fixture+'" --render-fixture "'+$render+'"';$start.UseShellExecute=$false
    $process=[Diagnostics.Process]::Start($start)
    Wait-For {[ICloudTestDesktop]::FindWindowForProcess($process.Id,'iCloud folder setup') -ne [IntPtr]::Zero} 'WinUI window did not start'
    $window=[Windows.Automation.AutomationElement]::FromHandle([ICloudTestDesktop]::FindWindowForProcess($process.Id,'iCloud folder setup'))
    Write-Output ('Native window: '+$window.Current.Name+'; '+$window.Current.ClassName)
    Wait-For {$null -ne (Find-Control 'CloudRoot')} 'Native controls did not become available'
    Assert (-not (Find-Control 'Preview').Current.IsEnabled) 'Preview enabled before delayed folder definitions loaded'
    Assert (-not (Find-Control 'Apply').Current.IsEnabled) 'Apply enabled during startup'
    Write-Output 'PASS: native window and automation respond during delayed startup; actions remain disabled'
    [IO.File]::WriteAllText((Join-Path $fixture 'release-metadata'),'continue')
    Wait-For {Test-Path -LiteralPath $render} 'WinUI rendering fixture did not complete'
    $root=Find-Control 'CloudRoot';$preview=Find-Control 'Preview';$apply=Find-Control 'Apply'
    Assert (-not $apply.Current.IsEnabled) 'Apply enabled before any preview'
    Assert ((Find-Name 'Include Music').GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) 'Optional Music starts selected or indeterminate'
    $tricky="C:\fixture ! ' & "+[char]0x00E9
    $root.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($tricky)
    Invoke-Control $preview
    Wait-For {$apply.Current.IsEnabled} 'Preview did not enable the reviewed action'
    Wait-For {$preview.Current.HasKeyboardFocus} 'Preview did not regain keyboard focus after operation'
    $results=Find-Control 'Results'
    $text=$results.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    $payload=[regex]::Match($text,'\{"Root".*?\}').Value | ConvertFrom-Json
    Assert ($text -like '*fixture-before.json*' -and $payload.Root -ceq $tricky) ('Preview lost recovery path or Unicode/special characters: '+$text)
    Assert (-not(Test-Path (Join-Path $fixture 'applied.txt'))) 'Preview wrote the mutation marker'
    Invoke-Control $apply
    Wait-For {$null -ne (Find-Name 'Cancel')} 'Action-specific confirmation did not open'
    Invoke-Control (Find-Name 'Cancel')
    Assert (-not(Test-Path (Join-Path $fixture 'applied.txt'))) 'Cancel performed a mutation'
    Assert $apply.Current.IsEnabled 'Cancel lost the reviewed preview'
    Invoke-Control $apply
    Wait-For {$null -ne (Find-Name 'Cancel')} 'Second confirmation did not open'
    $buttons=$window.FindAll([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,'Change locations')))
    Assert ($buttons.Count -ge 1) 'Confirmation does not name its action'
    Invoke-Control $buttons[$buttons.Count-1]
    Wait-For {Test-Path (Join-Path $fixture 'applied.txt')} 'Confirmed apply did not reach the fixture'
    Wait-For {$preview.Current.IsEnabled} 'Apply did not finish'
    Wait-For {$preview.Current.HasKeyboardFocus} 'Confirmed action did not restore keyboard focus to Preview'
    Assert (-not $apply.Current.IsEnabled) 'Apply can repeat without a fresh preview'
    $customize=Find-Control 'CustomizePaths'
    Assert ($customize.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -eq [Windows.Automation.ToggleState]::Off) 'Default mode unexpectedly customizes folder paths'
    foreach($id in @('Desktop','Documents','Pictures','Videos','Downloads','Captures','Music')){Assert ($null -ne (Find-Control ('DefaultDestination_'+$id))) ('Default destination missing: '+$id)}
    $customize.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    $customPath=$tricky+'\Personal '+[char]0x00E9
    (Find-Control 'Destination_Documents').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($customPath)
    Assert (-not $apply.Current.IsEnabled) 'Custom path edit retained approval'
    Invoke-Control $preview
    Wait-For {$apply.Current.IsEnabled} 'Custom path preview did not finish'
    $text=$results.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    $line=@($text -split '[\r\n]+'|Where-Object {$_ -like '{"Root"*'})[0]
    $payload=$line|ConvertFrom-Json
    Assert ($payload.Paths.Documents -ceq $customPath -and -not $payload.Paths.PSObject.Properties['Music']) 'Custom Unicode path or optional-Music scope was lost'
    $customize.GetCurrentPattern([Windows.Automation.TogglePattern]::Pattern).Toggle()
    Assert (-not $apply.Current.IsEnabled) 'Returning to default paths retained custom approval'
    'PASS: default destination rows, opt-in advanced Unicode paths and preview invalidation'
    $root.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue('FAIL')
    Invoke-Control $preview
    Wait-For {$preview.Current.IsEnabled} 'Failed preview did not complete'
    Assert (-not $apply.Current.IsEnabled) 'Failed preview enabled Apply'
    $text=$results.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
    Assert ($text -like '*Access was denied*' -and $text -like '*fixture folder*') ('Error lacks next step or exact affected context: '+$text)
    Wait-For {$preview.Current.HasKeyboardFocus} 'Failed operation did not restore keyboard focus to Preview'
    foreach($case in @(
        @{Root='BACKUP-FAIL';Message='*trusted before.json*'},
        @{Root='ROOT-MISMATCH';Message='*known mismatch cannot be overridden*'},
        @{Root='ROLLBACK-FAIL';Message='*Recovery needs attention*'},
        @{Root='SOURCE-CONTENT';Message='*select the option to change locations without copying files*'}
    )){
        $root.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($case.Root)
        Invoke-Control $preview
        Wait-For {$preview.Current.IsEnabled -and $results.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value -like $case.Message} ('Error fixture did not finish: '+$case.Root)
        $text=$results.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
        Assert ($text -like $case.Message -and -not $apply.Current.IsEnabled) ('Error lost recovery guidance or enabled Apply: '+$text)
    }
    'PASS: real WinUI controls, Unicode preview, recovery paths, action-specific confirmation, cancellation, fixture apply, repeat gate and actionable errors on hidden desktop'
    Select-Action 'Reset to Windows defaults'
    Assert (-not $apply.Current.IsEnabled) 'Switching action retained a reviewed setup plan'
    Wait-For {$null -ne (Find-Control 'DryRun')} 'Reset dry run control unavailable'
    Invoke-Control (Find-Control 'DryRun')
    Wait-For {$apply.Current.IsEnabled} 'Reset dry run did not finish'
    $payload=[regex]::Match($results.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value,'\{"Root".*?\}').Value | ConvertFrom-Json
    Assert ($payload.Reset -and $payload.DryRun -and $payload.Apply -and -not $payload.Root) 'Reset dry run lost its WhatIf/default-only routing'
    Select-Action 'Restore a recovery backup'
    Assert (-not $apply.Current.IsEnabled) 'Restore inherited reset approval'
    $backup=Join-Path $fixture ("before ' & "+[char]0x00E9+'.json')
    (Find-Control 'BackupFile').GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($backup)
    Invoke-Control $preview
    Wait-For {$apply.Current.IsEnabled} 'Restore preview did not finish'
    $payload=[regex]::Match($results.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value,'\{"Root".*?\}').Value | ConvertFrom-Json
    Assert ($payload.Backup -ceq $backup -and -not $payload.Apply -and -not $payload.Reset) 'Restore preview changed the path or requested mutation'
    'PASS: native reset WhatIf routing, restore Unicode path and cross-action preview invalidation'
    @'
[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Start','Check','Cleanup')][string]$Mode)
[pscustomobject]@{Mode=$Mode;DryRun=[bool]$WhatIfPreference} | ConvertTo-Json -Compress
if(-not $WhatIfPreference -and $Mode -ne 'Check'){[IO.File]::WriteAllText((Join-Path $PSScriptRoot ($Mode+'.txt')),'fixture only')}
exit 0
'@ | Set-Content -LiteralPath (Join-Path $fixture 'tools/Test-ICloudRoundTrip.ps1') -Encoding UTF8
    Select-OrInvoke (Find-Name 'Cloud verification')
    foreach($case in @(
        @{Action='Create cloud test file';Mode='Start';ReadOnly=$false},
        @{Action='Check cloud return';Mode='Check';ReadOnly=$true},
        @{Action='Clean up cloud test file';Mode='Cleanup';ReadOnly=$false}
    )){
        Select-Action $case.Action
        Invoke-Control $preview
        Wait-For {$preview.Current.IsEnabled} ('Cloud preview did not finish: '+$case.Action)
        $payload=[regex]::Match($results.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value,'\{"Mode".*?\}').Value | ConvertFrom-Json
        Assert ($payload.Mode -eq $case.Mode -and $payload.DryRun -eq (-not $case.ReadOnly)) ('Unsafe cloud preview routing: '+$case.Action)
        Assert ($apply.Current.IsEnabled -eq (-not $case.ReadOnly)) ('Incorrect cloud approval state: '+$case.Action)
        if(-not $case.ReadOnly){
            $marker=Join-Path (Join-Path $fixture 'tools') ($case.Mode+'.txt')
            Assert (-not(Test-Path $marker)) 'Cloud preview reached a mutation'
            Invoke-Control $apply
            Wait-For {$null -ne (Find-Name 'Cancel')} 'Cloud confirmation did not open'
            Invoke-Control (Find-Name 'Cancel')
            Assert (-not(Test-Path $marker)) 'Cancelled cloud confirmation reached a mutation'
            Invoke-Control $apply
            $label=if($case.Mode -eq 'Start'){'Create test file'}else{'Remove test file'}
            Wait-For {$null -ne (Find-Name 'Cancel')} 'Cloud confirmation did not reopen'
            $condition=New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,$label)),(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button)))
            Invoke-Control ($window.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition))
            Wait-For {$preview.Current.IsEnabled -and (Test-Path $marker)} 'Confirmed cloud action did not reach its fixture'
            $payload=[regex]::Match($results.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value,'\{"Mode".*?\}').Value | ConvertFrom-Json
            Assert ($payload.Mode -eq $case.Mode -and -not $payload.DryRun -and -not $apply.Current.IsEnabled) 'Confirmed cloud action lost its mode or fresh-preview requirement'
        }
    }
    'PASS: native cloud previews, read-only checks, cancellation, confirmed fixture create/cleanup and fresh-preview gating'
    Copy-Item -LiteralPath (Join-Path $repo 'ICloudFolderCopy.psm1') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/Copy-CancelWorker.ps1') -Destination (Join-Path $fixture 'Copy-ICloudFolderFiles.ps1')
    $source=Join-Path $fixture 'source';$target=Join-Path $fixture 'target'
    $null=[IO.Directory]::CreateDirectory($source)
    [IO.File]::WriteAllText((Join-Path $source 'a.txt'),'first')
    [IO.File]::WriteAllText((Join-Path $source 'b.txt'),'second')
    (Find-Name 'Copy files').GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Invoke-Control $preview
    Wait-For {$apply.Current.IsEnabled} 'Copy preview did not finish'
    Invoke-Control $apply
    Wait-For {$null -ne (Find-Name 'Cancel')} 'Copy confirmation did not open'
    $condition=New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,'Copy files')),(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button)))
    Invoke-Control ($window.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition))
    $status=Find-Control 'OperationStatus'
    Wait-For {$status.Current.Name -like '*1 of 2 files verified*'} 'Native copy did not show live verified-file progress'
    $stop=Find-Control 'Stop'
    Assert $stop.Current.IsEnabled 'Stop button is disabled by busy navigation state'
    Invoke-Control $stop
    Wait-For {$preview.Current.IsEnabled} 'Native copy did not stop'
    Assert ($status.Current.Name -like '*Copy stopped safely*') 'Safe cancellation outcome was lost'
    Assert ((Test-Path (Join-Path $target 'a.txt')) -and -not(Test-Path (Join-Path $target 'b.txt'))) 'Copy did not stop between files'
    Assert ([IO.File]::ReadAllText((Join-Path $source 'a.txt')) -eq 'first') 'Native copy cancellation modified the original'
    Assert (-not $apply.Current.IsEnabled) 'Stopped copy can restart without a new preview'
    'PASS: native live copy progress, enabled stop control, verified-file boundary cancellation and retained originals'
    @'
param([switch]$DesktopShortcut)
[IO.File]::WriteAllText((Join-Path (Split-Path $PSScriptRoot -Parent) 'install-fixture.txt'),'fixture only')
Write-Output 'Installed application: isolated fixture'
'@ | Set-Content -LiteralPath (Join-Path $fixture 'tools/Invoke-WinUIInstall.ps1') -Encoding UTF8
    Select-NavigationId 'InstallNavigation'
    Wait-For {$null -ne (Find-Name 'Cancel')} 'Native install confirmation did not open'
    Invoke-Control (Find-Name 'Cancel')
    Assert (-not(Test-Path (Join-Path $fixture 'install-fixture.txt'))) 'Cancelled installation reached backend'
    # Selecting the same footer item again may not raise SelectionChanged; select a category first.
    (Find-Name 'Folder locations').GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Select-NavigationId 'InstallNavigation'
    Wait-For {$null -ne (Find-Name 'Cancel')} 'Native install confirmation did not reopen'
    $condition=New-Object Windows.Automation.AndCondition((New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,'Install for me')),(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button)))
    Invoke-Control ($window.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition))
    Wait-For {$preview.Current.IsEnabled -and (Test-Path (Join-Path $fixture 'install-fixture.txt'))} 'Confirmed native installation did not reach its stub backend'
    Assert ($status.Current.Name -like '*Installation completed*') 'Native install result was not reported'
    'PASS: native installation dialog, cancel default path, confirmed fixture backend and installation result'
}catch{
    Write-Output $_.ScriptStackTrace
    if($window){
        $buttons=$window.FindAll([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Button)))
        foreach($button in $buttons){Write-Output ('Available button: '+$button.Current.Name+' ['+$button.Current.AutomationId+']')}
    }
    throw
}finally{
    if($process){if(-not $process.HasExited){$process.Kill();$process.WaitForExit(5000) | Out-Null};$process.Dispose()}
    $path=[IO.Path]::GetFullPath($fixture)
    if($path.StartsWith([IO.Path]::GetFullPath($repo).TrimEnd('\')+'\.test-winui-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Continue}
}
