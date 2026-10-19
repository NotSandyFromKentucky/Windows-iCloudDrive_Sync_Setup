#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){
    & powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File $PSCommandPath
    if($LASTEXITCODE -ne 0){throw 'STA graphical test process failed'}
    return
}
$fixture=Join-Path $repo ('.test-gui-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Expect-Failure([scriptblock]$Action){$failed=$false;try{& $Action | Out-Null}catch{$failed=$true};Assert $failed 'Expected failure'}
$ui=Import-Module (Join-Path $repo 'ICloudFolderSetup.UI.psm1') -Force -PassThru
$installer=Import-Module (Join-Path $repo 'ICloudFolderSetup.Install.psm1') -Force -PassThru
try{
    $r=Get-SetupRequest -Action 'Set up iCloud folders' -Root 'C:\cloud ! space' -Music $true -Verified $true -KeepFiles $true
    Assert (-not $r.Options.ContainsKey('Apply') -and $r.Options.IncludeMusic -and $r.Options.VerifiedSyncRoot -and $r.Options.AllowExistingContent) 'Setup options or read-only preview lost'
    $r=Get-SetupRequest -Action 'Set up iCloud folders' -Root 'C:\cloud' -Phase DryRun
    Assert ($r.Options.Apply -and $r.Options.WhatIf) 'Dry run lost ShouldProcess gate'
    $r=Get-SetupRequest -Action 'Reset to Windows defaults' -Root 'ignored' -Music $true -Verified $true -KeepFiles $true -Phase Apply
    Assert ($r.Options.ResetToDefaults -and $r.Options.Apply -and -not $r.Options.ContainsKey('ICloudRoot') -and -not $r.Options.ContainsKey('IncludeMusic')) 'Reset mixed cloud options'
    $r=Get-SetupRequest -Action 'Restore a recovery backup' -Backup 'C:\trusted\before.json' -Phase Apply
    Assert ($r.Options.RestoreBackup -eq 'C:\trusted\before.json' -and $r.Options.Apply) 'Backup selection not forwarded'
    Expect-Failure {Get-SetupRequest -Action 'Restore a recovery backup'}
    Expect-Failure {Get-SetupRequest -Action 'Set up iCloud folders' -Root ''}
    $r=Get-SetupRequest -Action 'Check iCloud configuration' -Root 'C:\cloud' -Music $true -Json $true
    Assert ($r.Options.Json -and $r.Options.IncludeMusic -and -not $r.Mutates) 'Diagnostics options lost'
    foreach($action in @('Create cloud test file','Clean up cloud test file')){
        $r=Get-SetupRequest -Action $action
        Assert ($r.Options.WhatIf -and $r.Mutates) 'Cloud mutation preview is not WhatIf'
        $r=Get-SetupRequest -Action $action -Phase Apply
        Assert (-not $r.Options.ContainsKey('WhatIf')) 'Explicit cloud action remained preview'
    }
    Assert (-not (Get-SetupRequest -Action 'Check cloud return').Mutates) 'Return check marked as mutation'
    'PASS: all supported actions and options preserve backend read-only previews'
    @('param([string]$ICloudRoot,[switch]$IncludeMusic,[switch]$Apply,[switch]$WhatIf)','[pscustomobject]@{Root=$ICloudRoot;Music=[bool]$IncludeMusic;Apply=[bool]$Apply;WhatIf=[bool]$WhatIf} | ConvertTo-Json -Compress','exit 0') | Set-Content (Join-Path $fixture 'Set-ICloudFolders.ps1') -Encoding UTF8
    $tricky="C:\space ! ' & "+[char]0x00E9
    $r=Get-SetupRequest -Action 'Set up iCloud folders' -Root $tricky -Music $true
    $worker=Start-SetupWorker -Source $fixture -Request $r
    try{
        Assert ($worker.Process.WaitForExit(10000)) 'Worker hung'
        $result=$worker.Output.Result | ConvertFrom-Json
        Assert ($worker.Process.ExitCode -eq 0 -and $result.Root -ceq $tricky -and $result.Music -and -not $result.Apply) 'Worker changed paths or flags'
    }finally{if(-not $worker.Process.HasExited){$worker.Process.Kill()};$worker.Process.Dispose()}
    'PASS: asynchronous child preserves Unicode, apostrophes and shell metacharacters as data'
    $window=New-SetupWindow -Source $fixture -ConfirmAction {$false}
    try{
        $window.Form.Show()
        [Windows.Forms.Application]::DoEvents()
        Assert (-not $window.Apply.Enabled) 'Apply enabled without preview'
        $window.Root.Text='C:\GUI fixture'
        $window.Preview.PerformClick()
        $deadline=[DateTime]::UtcNow.AddSeconds(12)
        while($window.Output.Text -notlike '*Exit code: 0*' -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
        Assert ($window.Output.Text -like '*Exit code: 0*' -and $window.Apply.Enabled) ('Preview failed: '+$window.Output.Text)
        $beforeCancel=$window.Output.Text
        $window.Apply.PerformClick()
        Assert ($window.Output.Text -ceq $beforeCancel -and $window.Apply.Enabled) 'Cancelling confirmation started a worker or changed the result'
        $window.DryRun.PerformClick()
        $deadline=[DateTime]::UtcNow.AddSeconds(12)
        while($window.Output.Text -notlike '*Exit code: 0*' -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
        Assert ($window.Apply.Enabled) 'Successful dry run did not enable reviewed apply'
        $window.Music.Checked=$true
        Assert (-not $window.Apply.Enabled) 'Changed options did not invalidate preview'
        $window.Action.SelectedItem='Reset to Windows defaults'
        Assert (-not $window.Root.Enabled -and -not $window.Apply.Enabled -and $window.KeepFiles.Enabled) 'Reset controls do not match mode'
        $window.Action.SelectedItem='Restore a recovery backup'
        Assert ($window.Backup.Enabled -and -not $window.Root.Enabled) 'Restore picker unavailable'
        $window.Action.SelectedItem='Check iCloud configuration'
        Assert ($window.Json.Enabled -and -not $window.DryRun.Enabled -and -not $window.Apply.Enabled) 'Read-only check exposes mutation'
        $window.Action.SelectedItem='Set up iCloud folders'
        $window.Root.Text='C:\Users\Example\iCloudDrive'
        $null=[IO.Directory]::CreateDirectory((Join-Path $repo '.local'))
        $bitmap=New-Object Drawing.Bitmap($window.Form.Width,$window.Form.Height)
        try{$window.Form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$bitmap.Width,$bitmap.Height)));$bitmap.Save((Join-Path $repo '.local\gui-preview.png'))}finally{$bitmap.Dispose()}
    }finally{$window.Form.Close();$window.Form.Dispose()}
    'PASS: rendered window, preview completion, changed-option invalidation and mode-specific controls'
    $window=New-SetupWindow -Source $fixture -ConfirmAction {$true}
    try{
        $window.Form.Show();[Windows.Forms.Application]::DoEvents()
        $window.Preview.PerformClick()
        $deadline=[DateTime]::UtcNow.AddSeconds(12)
        while($window.Output.Text -notlike '*Exit code: 0*' -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
        $window.Apply.PerformClick()
        $deadline=[DateTime]::UtcNow.AddSeconds(12)
        while($window.Output.Text -notlike '*Exit code: 0*' -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
        Assert ($window.Output.Text -like '*"Apply":true*' -and -not $window.Apply.Enabled) ('Confirmed apply did not execute only the reviewed fixture: '+$window.Output.Text)
        'exit 1' | Set-Content (Join-Path $fixture 'Set-ICloudFolders.ps1')
        $window.Preview.PerformClick()
        $deadline=[DateTime]::UtcNow.AddSeconds(12)
        while($window.Output.Text -notlike '*Exit code: 1*' -and [DateTime]::UtcNow -lt $deadline){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 50}
        Assert ($window.Output.Text -like '*Exit code: 1*' -and -not $window.Apply.Enabled) 'Failed preview enabled Apply or hid the error'
    }finally{$window.Form.Close();$window.Form.Dispose()}
    'PASS: confirmed apply reaches only the reviewed fixture and failed preview blocks mutation'
    $installOptions=@{Source=$repo;InstallRoot=(Join-Path $fixture 'installed');ProgramsDirectory=(Join-Path $fixture 'start-menu');DesktopDirectory=(Join-Path $fixture 'desktop')}
    Install-SetupFiles @installOptions -WhatIf
    Assert (-not(Test-Path $installOptions.InstallRoot)) 'Installer WhatIf wrote files'
    $installed=Install-SetupFiles @installOptions
    Assert ($installed.Shortcuts.Count -eq 2 -and (Test-Path (Join-Path $installed.Directory 'Start-ICloudFolderSetup.ps1'))) 'Install incomplete'
    $shell=New-Object -ComObject WScript.Shell
    try{
        $shortcut=$shell.CreateShortcut($installed.Shortcuts[0])
        try{Assert ($shortcut.Arguments -like '*-STA*Start-ICloudFolderSetup.ps1*' -and $shortcut.WorkingDirectory -ceq $installed.Directory) 'Shortcut target incorrect'}finally{$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)}
    }finally{$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    $second=Install-SetupFiles @installOptions
    Assert ($installed.Directory -cne $second.Directory -and (Test-Path $installed.Directory)) 'Reinstall overwrote old files'
    Assert (@(Get-ChildItem $second.Directory -Filter 'previous-shortcut-*.lnk').Count -eq 2) 'Existing shortcuts not backed up'
    'PASS: verified isolated install, shortcuts, WhatIf and safe reinstall'
    $bad=Join-Path $fixture 'bad-source';$null=[IO.Directory]::CreateDirectory($bad)
    [pscustomobject]@{Files=@([pscustomobject]@{Path='../escape';SHA256='0'})} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $bad 'manifest.json')
    Expect-Failure {Install-SetupFiles -Source $bad -InstallRoot (Join-Path $fixture 'bad-install') -ProgramsDirectory (Join-Path $fixture 'bad-menu')}
    Assert (-not(Test-Path (Join-Path $fixture 'bad-install'))) 'Invalid source wrote files'
    'PASS: unsafe source manifest rejected before installation'
    $package=Join-Path $fixture 'package-source';$null=[IO.Directory]::CreateDirectory($package)
    $releaseFiles=@(Get-Content (Join-Path $repo 'build\ReleaseFiles.json') -Raw | ConvertFrom-Json | ForEach-Object {$_})
    $entries=@()
    foreach($file in $releaseFiles){
        $target=Join-Path $package $file;$null=[IO.Directory]::CreateDirectory((Split-Path $target))
        Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $target
        $entries+=[pscustomobject]@{Path=$file;SHA256=(Get-FileHash -LiteralPath $target).Hash}
    }
    [pscustomobject]@{Files=$entries} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $package 'manifest.json')
    $packaged=Install-SetupFiles -Source $package -InstallRoot (Join-Path $fixture 'package-install') -ProgramsDirectory (Join-Path $fixture 'package-menu')
    Assert (Test-Path (Join-Path $packaged.Directory 'manifest.json')) 'Packaged manifest not retained'
    Add-Content (Join-Path $package 'ICloudFolders.psm1') '# tampered fixture'
    Expect-Failure {Install-SetupFiles -Source $package -InstallRoot (Join-Path $fixture 'tampered-install') -ProgramsDirectory (Join-Path $fixture 'tampered-menu')}
    Assert (-not(Test-Path (Join-Path $fixture 'tampered-install'))) 'Hash-mismatched source created install directory'
    'PASS: packaged manifest installation and tampered-file rejection before writes'
    'All graphical and installer checks passed without live folder or user shortcut changes.'
}finally{
    Remove-Module $ui,$installer -Force
    $path=[IO.Path]::GetFullPath($fixture)
    if($path.StartsWith([IO.Path]::GetFullPath($repo).TrimEnd('\')+'\.test-gui-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Recurse -Force}
}


