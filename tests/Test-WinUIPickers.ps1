#requires -Version 5.1
$ErrorActionPreference='Stop'
$null=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1')
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$repo=Split-Path $PSScriptRoot -Parent
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $temp ('ICloudPickerTest-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$process=$null;$dialog=$null
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Wait-For([scriptblock]$Condition,[string]$Message){$end=[DateTime]::UtcNow.AddSeconds(30);while([DateTime]::UtcNow -lt $end){if($process -and $process.HasExited){throw ('Native picker app exited: '+$process.ExitCode)};if(& $Condition){return};Start-Sleep -Milliseconds 100};throw $Message}
function Find-Id($Parent,[string]$Id){$Parent.FindFirst([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$Id)))}
function Invoke-Control($Control){Assert ($null -ne $Control) 'Missing picker control';$Control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Read-Value([string]$Id){$control=Find-Id $window $Id;if($null -eq $control){return $null};$control.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value}
function Open-Picker([string]$Button,[string]$Title){
    Invoke-Control (Find-Id $window $Button)
    Wait-For {[ICloudTestDesktop]::FindWindowForProcess($process.Id,$Title) -ne [IntPtr]::Zero} ('Owned native picker not found on hidden desktop: '+$Title)
    $script:dialogHandle=[ICloudTestDesktop]::FindWindowForProcess($process.Id,$Title)
    $script:dialog=[Windows.Automation.AutomationElement]::FromHandle($script:dialogHandle)
    Wait-For {$null -ne (Find-Id $script:dialog '2')} 'Picker Cancel button not ready'
}
function Cancel-Picker(){
    Invoke-Control (Find-Id $script:dialog '2')
    Wait-For {(Find-Id $window 'ActionChoice').Current.IsEnabled} 'Picker cancel did not restore the owner window'
    $script:dialog=$null
}
function Choose-Path([string]$Path){
    $hostControl=Find-Id $script:dialog '1148'
    Assert ($null -ne $hostControl) 'Native picker filename field missing'
    $value=$null
    if(-not $hostControl.TryGetCurrentPattern([Windows.Automation.ValuePattern]::Pattern,[ref]$value)){
        $edit=$hostControl.FindFirst([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Edit)))
        Assert ($null -ne $edit) 'Native picker filename edit missing'
        $value=$edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern)
    }
    $value.SetValue($Path)
    Invoke-Control (Find-Id $script:dialog '1')
}
try{
    $exe=Join-Path $repo 'ui/ICloudFolderSetup/bin/x64/Debug/net10.0-windows10.0.19041.0/win-x64/ICloudFolderSetup.exe'
    Assert (Test-Path -LiteralPath $exe) 'Build native Debug x64 source first'
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$exe;$start.Arguments='--source "'+$repo+'"';$start.UseShellExecute=$false
    $process=[Diagnostics.Process]::Start($start)
    Wait-For {[ICloudTestDesktop]::FindWindowForProcess($process.Id,'iCloud folder setup') -ne [IntPtr]::Zero} 'Native picker fixture did not start'
    $window=[Windows.Automation.AutomationElement]::FromHandle([ICloudTestDesktop]::FindWindowForProcess($process.Id,'iCloud folder setup'))
    Wait-For {$null -ne (Find-Id $window 'BrowseRoot')} 'Native folder browse button unavailable'
    $original=Read-Value 'CloudRoot'
    Open-Picker 'BrowseRoot' 'Choose your iCloud Drive folder';Cancel-Picker
    Assert ((Read-Value 'CloudRoot') -ceq $original) 'Folder picker cancellation changed its path'
    $chosen=Join-Path $fixture ('chosen '+[char]0x00E9)
    $null=[IO.Directory]::CreateDirectory($chosen)
    Open-Picker 'BrowseRoot' 'Choose your iCloud Drive folder';Choose-Path $chosen
    Wait-For {(Read-Value 'CloudRoot') -ceq $chosen} 'Folder selection did not return its exact Unicode path'
    'PASS: owned native folder picker cancellation and Unicode selection'
    (Find-Id $window 'ActionChoice').GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    Wait-For {$null -ne $window.FindFirst([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,'Restore a recovery backup')))} 'Restore action unavailable'
    $item=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,'Restore a recovery backup')))
    $item.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-For {$null -ne (Find-Id $window 'BrowseBackup')} 'Backup browse control unavailable'
    $original=Read-Value 'BackupFile'
    Open-Picker 'BrowseBackup' 'Choose a recovery backup';Cancel-Picker
    Assert ((Read-Value 'BackupFile') -ceq $original) 'Backup picker cancellation changed its path'
    $backup=Join-Path $chosen 'before.json';[IO.File]::WriteAllText($backup,'{}')
    Open-Picker 'BrowseBackup' 'Choose a recovery backup';Choose-Path $backup
    Wait-For {(Read-Value 'BackupFile') -ceq $backup} 'Backup selection did not return its exact path'
    Assert (-not (Find-Id $window 'Apply').Current.IsEnabled) 'Choosing a backup enabled Apply without preview'
    'PASS: owned JSON backup picker cancellation and selection without mutation approval'
    $result=Read-Value 'Results'
    Open-Picker 'Save' 'Save folder setup result';Cancel-Picker
    Assert (@(Get-ChildItem -LiteralPath $fixture -Filter '*.txt' -Recurse).Count -eq 0) 'Cancelled save created a result file'
    $saved=Join-Path $chosen 'result.txt'
    Open-Picker 'Save' 'Save folder setup result';Choose-Path $saved
    Wait-For {(Test-Path -LiteralPath $saved) -and [IO.File]::ReadAllText($saved) -ceq $result} 'Save picker did not save the displayed result exactly'
    Wait-For {(Find-Id $window 'OperationStatus').Current.Name -like '*Result saved*'} 'Successful save lacks a readable result'
    'PASS: owned save picker cancellation and exact result-file contents'
}catch{
    Write-Output $_.ScriptStackTrace
    if($dialog){$nodes=$dialog.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition);foreach($node in $nodes|Select-Object -First 60){Write-Output ($node.Current.AutomationId+' | '+$node.Current.Name+' | '+$node.Current.ControlType.ProgrammaticName)}}
    throw
}finally{
    if($process){if(-not $process.HasExited){$process.Kill();$process.WaitForExit(5000)|Out-Null};$process.Dispose()}
    $path=[IO.Path]::GetFullPath($fixture)
    if($path.StartsWith($temp.TrimEnd('\')+'\ICloudPickerTest-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Recurse -Force}
}
