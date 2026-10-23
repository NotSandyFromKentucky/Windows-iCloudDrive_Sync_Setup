#requires -Version 5.1
param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference='Stop'
if(-not $env:ICLOUD_TEST_DESKTOP){& (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{Archive=$Archive} -TimeoutSeconds 300;return}
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$repo=Split-Path $PSScriptRoot -Parent
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $temp ('ICloudNativeTest-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Find-Control($Window,[string]$Id){$Window.FindFirst([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty,$Id)))}
function Wait-For([scriptblock]$Condition,[string]$Message){$end=[DateTime]::UtcNow.AddSeconds(30);while([DateTime]::UtcNow -lt $end){if(& $Condition){return};Start-Sleep -Milliseconds 100};throw $Message}
function Test-Launcher([string]$Source,[string]$Mode){
    $launcher=Join-Path $Source 'Start-ICloudFolderSetup.ps1'
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $info.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$launcher+'" -InitialMode '+$Mode
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $wrapper=[Diagnostics.Process]::Start($info);$native=$null
    try{
        $expected=[IO.Path]::GetFullPath((Join-Path $Source 'NativeUI/ICloudFolderSetup.exe'))
        Wait-For {$script:found=@(Get-Process -Name ICloudFolderSetup -ErrorAction SilentlyContinue | Where-Object {$_.Path -ceq $expected});$script:found.Count -eq 1} ('No native process for '+$Mode)
        $native=$script:found[0]
        Wait-For {[ICloudTestDesktop]::FindWindowForProcess($native.Id,'iCloud folder setup') -ne [IntPtr]::Zero} 'No native window'
        $handle=[ICloudTestDesktop]::FindWindowForProcess($native.Id,'iCloud folder setup')
        $window=[Windows.Automation.AutomationElement]::FromHandle($handle)
        if($Mode -eq 'Install'){
            $cancel=$null
            Wait-For {$script:cancelButton=$window.FindFirst([Windows.Automation.TreeScope]::Descendants,(New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty,'Cancel')));$null -ne $script:cancelButton} 'Install mode did not open native confirmation'
            $script:cancelButton.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
        }else{
            Wait-For {$null -ne (Find-Control $window 'ActionChoice')} 'Packaged native controls unavailable'
            Wait-For {$preview=Find-Control $window 'Preview';$null -ne $preview -and $preview.Current.IsEnabled} 'Packaged native initialization did not finish'
            $selection=(Find-Control $window 'ActionChoice').GetCurrentPattern([Windows.Automation.SelectionPattern]::Pattern)
            $choice=$selection.Current.GetSelection()[0].Current.Name
            $expectedAction=switch($Mode){Reset{'Reset to Windows defaults'} Check{'Check iCloud configuration'} default{'Set up iCloud folders'}}
            Assert ($choice -ceq $expectedAction) ('Wrong native initial action: '+$choice)
            $apply=Find-Control $window 'Apply'
            Assert ($null -eq $apply -or -not $apply.Current.IsEnabled) 'Packaged launcher enabled unreviewed Apply'
        }
        [ICloudTestDesktop]::CloseWindow($handle)
        Assert ($wrapper.WaitForExit(10000) -and $wrapper.ExitCode -eq 0) 'Native launcher did not close successfully'
        Write-Output ('PASS: packaged Explorer launcher mode '+$Mode+' starts native UI without applying settings')
    }finally{
        if($native){if(-not $native.HasExited){$native.Kill();$native.WaitForExit(5000)|Out-Null};$native.Dispose()}
        if(-not $wrapper.HasExited){$wrapper.Kill();$wrapper.WaitForExit(5000)|Out-Null};$wrapper.Dispose()
    }
}
try{
    & (Join-Path $repo 'tools/Test-ReleasePackage.ps1') -Archive $Archive
    Expand-Archive -LiteralPath $Archive -DestinationPath (Join-Path $fixture 'extracted')
    $package=(Get-ChildItem (Join-Path $fixture 'extracted') -Directory | Select-Object -First 1).FullName
    $version=(Get-Content -LiteralPath (Join-Path $package 'VERSION') -Raw).Trim()
    foreach($name in @('ICloudFolderSetup.exe','ICloudFolderSetup.dll')){
        $metadata=[Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $package ('NativeUI/'+$name)))
        Assert ($metadata.ProductVersion.Split('+')[0] -ceq $version -and $metadata.FileVersion -ceq ($version+'.0')) ('Native version does not match package VERSION: '+$name)
    }
    'PASS: native executable and assembly versions match the package VERSION'
    foreach($mode in @('Setup','Reset','Check','Install')){Test-Launcher -Source $package -Mode $mode}
    Import-Module (Join-Path $repo 'ICloudFolderSetup.Install.psm1') -Force
    $previewRoot=Join-Path $fixture 'whatif-installed'
    $null=Install-SetupFiles -Source $package -InstallRoot $previewRoot -ProgramsDirectory (Join-Path $fixture 'whatif-menu') -RequireNative -WhatIf
    Assert (-not(Test-Path -LiteralPath $previewRoot) -and -not(Test-Path -LiteralPath (Join-Path $fixture 'whatif-menu'))) 'Native installation WhatIf created files or shortcuts'
    $installed=Install-SetupFiles -Source $package -InstallRoot (Join-Path $fixture 'installed') -ProgramsDirectory (Join-Path $fixture 'menu') -DesktopDirectory (Join-Path $fixture 'desktop') -RequireNative
    $shell=New-Object -ComObject WScript.Shell
    try{foreach($link in $installed.Shortcuts){$shortcut=$shell.CreateShortcut($link);try{Assert ($shortcut.TargetPath -ceq (Join-Path $installed.Directory 'NativeUI\ICloudFolderSetup.exe')) 'Installed shortcut does not target native UI'}finally{$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)}}}finally{$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    Test-Launcher -Source $installed.Directory -Mode Check
    'PASS: real native package installation, verified runtime copies, fixture shortcuts and installed native launch'
    $shortcutHashes=@($installed.Shortcuts | ForEach-Object {(Get-FileHash -LiteralPath $_).Hash})
    $reinstalled=Install-SetupFiles -Source $installed.Directory -InstallRoot (Join-Path $fixture 'installed') -ProgramsDirectory (Join-Path $fixture 'menu') -DesktopDirectory (Join-Path $fixture 'desktop') -RequireNative
    Assert ($reinstalled.Directory -cne $installed.Directory) 'Native reinstall reused its old directory'
    $manifest=Get-Content -LiteralPath (Join-Path $installed.Directory 'manifest.json') -Raw | ConvertFrom-Json
    foreach($entry in $manifest.Files){Assert ((Get-FileHash -LiteralPath (Join-Path $installed.Directory $entry.Path)).Hash -ieq $entry.SHA256) ('Reinstall changed the previous installation: '+$entry.Path)}
    $backups=@(Get-ChildItem -LiteralPath $reinstalled.Directory -Filter 'previous-shortcut-*.lnk')
    Assert ($backups.Count -eq 2) 'Native reinstall did not preserve both previous shortcuts'
    foreach($backup in $backups){Assert ($shortcutHashes -contains (Get-FileHash -LiteralPath $backup.FullName).Hash) 'Previous shortcut backup differs from original'}
    $shell=New-Object -ComObject WScript.Shell
    try{foreach($link in $reinstalled.Shortcuts){$shortcut=$shell.CreateShortcut($link);try{Assert ($shortcut.TargetPath -ceq (Join-Path $reinstalled.Directory 'NativeUI\ICloudFolderSetup.exe')) 'Reinstalled shortcut does not target the new native UI'}finally{$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)}}}finally{$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    Test-Launcher -Source $reinstalled.Directory -Mode Check
    'PASS: native WhatIf, reinstall from installed runtime, intact previous payload, exact shortcut backups and reinstalled launch'
    $dll=Join-Path $package 'NativeUI/ICloudFolderSetup.dll'
    [IO.File]::AppendAllText($dll,'tampered fixture')
    $blockedRoot=Join-Path $fixture 'blocked-installed';$blockedMenu=Join-Path $fixture 'blocked-menu'
    $rejected=$false
    try{$null=Install-SetupFiles -Source $package -InstallRoot $blockedRoot -ProgramsDirectory $blockedMenu -RequireNative}catch{if($_.Exception.Message -notlike '*hash mismatch*'){throw};$rejected=$true}
    Assert ($rejected -and -not(Test-Path -LiteralPath $blockedRoot) -and -not(Test-Path -LiteralPath $blockedMenu)) 'Tampered native payload was not rejected before writes'
    Copy-Item -LiteralPath (Join-Path $installed.Directory 'NativeUI/ICloudFolderSetup.dll') -Destination $dll -Force
    Remove-Item -LiteralPath (Join-Path $package 'NativeUI/ICloudFolderSetup.pri')
    $rejected=$false
    try{$null=Install-SetupFiles -Source $package -InstallRoot $blockedRoot -ProgramsDirectory $blockedMenu -RequireNative}catch{if($_.Exception.Message -notlike '*source is incomplete*'){throw};$rejected=$true}
    Assert ($rejected -and -not(Test-Path -LiteralPath $blockedRoot) -and -not(Test-Path -LiteralPath $blockedMenu)) 'Missing native resources were not rejected before writes'
    'PASS: modified native DLL and missing application PRI are rejected before creating install directories or shortcuts'
}finally{
    $path=[IO.Path]::GetFullPath($fixture)
    if($path.StartsWith($temp.TrimEnd('\')+'\ICloudNativeTest-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Continue}
}
