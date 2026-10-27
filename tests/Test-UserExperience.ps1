#requires -Version 5.1
$ErrorActionPreference='Stop'
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath
    if($LASTEXITCODE -ne 0){throw 'STA UX suite failed'};return
}
$repo=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $repo ('.test-ux-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$null=[IO.Directory]::CreateDirectory((Join-Path $repo '.local/ux'))
Import-Module (Join-Path $repo 'ICloudFolderSetup.UI.psm1') -Force
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::ThrowException)
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Wait-Ui([scriptblock]$Until){$deadline=[DateTime]::UtcNow.AddSeconds(25);while(-not (& $Until) -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 40};Assert (& $Until) 'UI operation timed out'}
function Focused($Control){foreach($child in $Control.Controls){if($child.Focused){return $child};if($child.ContainsFocus){return Focused $child}}}
try{
    foreach($case in @(
        @{Text='Different file already exists; nothing will be overwritten';Expected='*files conflict*'},
        @{Text='Folder destinations must be different: Desktop and Documents';Expected='*separate locations inside the selected iCloud Drive folder*'},
        @{Text='ROLLBACK INCOMPLETE';Expected='*Recovery needs attention*'},
        @{Text='Existing source content requires review';Expected='*Copy them using a separate copy action*'},
        @{Text='Access is denied';Expected='*check folder permissions*'},
        @{Text='Backup schema, user SID, or registry key does not match.';Expected='*trusted before.json*'},
        @{Text='The selected folder does not match your registered iCloud Drive location.';Expected='*known mismatch cannot be overridden*'}
    )){
        $result=Get-SetupOutcome -Action 'Set up iCloud folders' -Phase Apply -ExitCode 1 -Text $case.Text
        Assert ($result.Message -like $case.Expected) ('Unhelpful error: '+$result.Message)
    }
    foreach($action in @('Copy files into iCloud folders','Reset to Windows defaults','Restore a recovery backup','Clean up cloud test file')){
        $dialog=New-SetupConfirmation -Message 'Consequences of the selected fixture action.' -Action $action
        try{
            Assert ($dialog.Commit.Text -eq (Get-SetupActionLabel $action)) 'Confirmation has a generic commit button'
            Assert ($dialog.Form.AcceptButton -eq $dialog.Cancel -and $dialog.Form.CancelButton -eq $dialog.Cancel) 'Confirmation default is not Cancel'
            $dismiss=New-Object Windows.Forms.Timer;$dismiss.Interval=100
            $dismiss.Add_Tick({$dialog.Cancel.PerformClick()}.GetNewClosure())
            try{$dismiss.Start();$result=$dialog.Form.ShowDialog();Assert ($result -eq 'Cancel') 'Cancel did not dismiss confirmation'}finally{$dismiss.Stop();$dismiss.Dispose()}
        }finally{$dialog.Form.Dispose()}
    }
    'PASS: actionable errors, action-specific confirmations and cancellation defaults'
    $window=New-SetupWindow -Source $fixture
    try{
        $window.Form.Show();[Windows.Forms.Application]::DoEvents()
        Assert ($window.Form.AutoScaleMode -eq 'Font') 'Automatic font scaling is disabled'
        $window.Action.Focus() | Out-Null
        $null=$window.Form.SelectNextControl($window.Action,$true,$true,$true,$true)
        Assert ((Focused $window.Form) -eq $window.Root) 'Tab order does not proceed from action to destination'
        Assert ($window.Root.AccessibilityObject.Name -eq 'iCloud Drive folder') 'Screen-reader textbox name missing'
        Assert ($window.Output.AccessibilityObject.Description -like '*plan or result*') 'Screen-reader result description missing'
        Assert ($window.Stop.AccessibilityObject.Name -like '*Stop after current file*') 'Screen-reader stop action missing'
        Assert ($window.Form.AcceptButton -eq $window.Preview) 'Enter can apply without preview'
        Add-Type -AssemblyName UIAutomationClient
        Add-Type -AssemblyName UIAutomationTypes
        $refs=@([Windows.Automation.AutomationElement].Assembly.Location,[Windows.Automation.ControlType].Assembly.Location)
        if(-not ('SetupAccessibilityProbe' -as [type])){
            Add-Type -ReferencedAssemblies $refs -TypeDefinition @"
using System;
using System.Threading.Tasks;
using System.Windows.Automation;
public static class SetupAccessibilityProbe {
 public static Task<string> Read(IntPtr handle) {
  return Task.Run(() => {
   var element=AutomationElement.FromHandle(handle);
   return element.Current.Name+"|"+element.Current.ControlType.ProgrammaticName;
  });
 }
}
"@
        }
        $probe=[SetupAccessibilityProbe]::Read($window.Root.Handle)
        Wait-Ui {$probe.IsCompleted}
        Assert ($probe.Result -eq 'iCloud Drive folder|ControlType.Edit') ('UI Automation name/role incorrect: '+$probe.Result)
    }finally{$window.Form.Close();$window.Form.Dispose()}
    'PASS: keyboard tab path, safe Enter action, MSAA properties and native UI Automation name/role'
    foreach($scale in @(1.0,1.25,1.5,2.0)){
        $window=New-SetupWindow -Source $fixture
        try{
            $window.Form.AutoScaleMode='None'
            $window.Form.Scale((New-Object Drawing.SizeF($scale,$scale)))
            function Scale-Font($Control,$Scale){
                $family=if($Control -is [Windows.Forms.TextBox] -and $Control.Multiline){'Consolas'}else{'Segoe UI'}
                $Control.Font=New-Object Drawing.Font($family,(10*$Scale))
                foreach($child in $Control.Controls){Scale-Font $child $Scale}
            }
            Scale-Font $window.Form $scale
            $window.Form.Show();[Windows.Forms.Application]::DoEvents();$window.Form.PerformLayout()
            foreach($control in @($window.Music,$window.Verified,$window.KeepFiles,$window.Details)){
                Assert ($control.Width -ge $control.PreferredSize.Width -and $control.Right -le $control.Parent.ClientSize.Width -and $control.Bottom -le $control.Parent.ClientSize.Height) ('Clipped label at scale '+$scale+': '+$control.Text)
            }
            Assert ($window.Apply.AccessibilityObject.Name -eq 'Change locations') 'Scaled action lost accessible name'
            $bitmap=New-Object Drawing.Bitmap($window.Form.Width,$window.Form.Height)
            try{$window.Form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$bitmap.Save((Join-Path $repo ('.local/ux/layout-'+[int]($scale*100)+'.png')))}finally{$bitmap.Dispose()}
        }finally{$window.Form.Close();$window.Form.Dispose()}
    }
    'PASS: rendered 100/125/150/200 percent layout/font-scale fixtures; physical multi-monitor DPI requires a separate manual check'
    Copy-Item -LiteralPath (Join-Path $repo 'ICloudFolderCopy.psm1') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/Copy-CancelWorker.ps1') -Destination (Join-Path $fixture 'Copy-ICloudFolderFiles.ps1')
    $source=Join-Path $fixture 'source';$target=Join-Path $fixture 'target'
    $null=[IO.Directory]::CreateDirectory($source)
    [IO.File]::WriteAllText((Join-Path $source 'a.txt'),'first')
    [IO.File]::WriteAllText((Join-Path $source 'b.txt'),'second')
    $window=New-SetupWindow -Source $fixture -InitialAction 'Copy files into iCloud folders' -ConfirmAction {$true}
    try{
        $window.Root.Text=$source
        $window.Form.Show();[Windows.Forms.Application]::DoEvents()
        $window.Preview.PerformClick();Wait-Ui {$window.Preview.Enabled}
        Assert $window.Apply.Enabled ('Copy preview did not enable reviewed copy: '+$window.Output.Text)
        $window.Apply.PerformClick()
        Wait-Ui {$window.Progress.Value -eq 1 -and $window.Stop.Enabled}
        $window.Stop.PerformClick()
        Wait-Ui {$window.Preview.Enabled}
        Assert (-not $window.Details.Checked) 'Technical details should be hidden by default'
        Assert ($window.Output.Text -notlike '*Exit code:*') 'Raw exit code leaked into normal result'
        $window.Details.Checked=$true
        Assert ($window.Output.Text -like '*Exit code: 3*') 'Technical details did not reveal worker exit code'

        Assert ($window.Status.Text -like '*Copy stopped safely*') ('Cancellation outcome incorrect: '+$window.Status.Text)
        Assert (Test-Path (Join-Path $target 'a.txt')) 'Completed copy was lost'
        Assert (-not(Test-Path (Join-Path $target 'b.txt'))) 'Copy did not stop before next file'
        Assert ([IO.File]::ReadAllText((Join-Path $source 'a.txt')) -eq 'first') 'Cancellation changed original'
        Assert (-not $window.Apply.Enabled) 'Cancelled operation can reapply without review'
    }finally{$window.Form.Close();$window.Form.Dispose()}
    'PASS: live child progress and cooperative cancellation retain verified files and originals'
}finally{
    $path=[IO.Path]::GetFullPath($fixture)
    if($path.StartsWith([IO.Path]::GetFullPath($repo).TrimEnd('\')+'\.test-ux-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Recurse -Force}
}
