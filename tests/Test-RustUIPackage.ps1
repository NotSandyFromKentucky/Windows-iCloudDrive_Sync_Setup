#requires -Version 5.1
param([Parameter(Mandatory)][string]$PackageDirectory,[switch]$RunNativeIntegration)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$PackageDirectory=(Resolve-Path -LiteralPath $PackageDirectory).Path
if(-not $env:ICLOUD_TEST_DESKTOP){& (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{PackageDirectory=$PackageDirectory;RunNativeIntegration=$RunNativeIntegration.IsPresent} -TimeoutSeconds 180;return}
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
if($RunNativeIntegration){$isolation=& (Join-Path $PSScriptRoot 'Assert-IsolatedEnvironment.ps1');if($isolation -notin @('GitHubHosted','WindowsSandbox')){throw 'Native package integration tests require a disposable Windows environment.'}}
Add-Type -AssemblyName System.Drawing,Accessibility
Add-Type -Path (Join-Path $PSScriptRoot 'RustUIProbe.cs') -ReferencedAssemblies System.Drawing,Accessibility
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
function Wait-For([scriptblock]$Condition,[string]$Message){$end=[DateTime]::UtcNow.AddSeconds(35);while([DateTime]::UtcNow -lt $end){if(& $Condition){return};Start-Sleep -Milliseconds 50};throw $Message}
function Select-Action([IntPtr]$Window,[int]$Index){$combo=[RustUIProbe]::GetDlgItem($Window,110);[RustUIProbe]::Send($combo,0x014e,[IntPtr]$Index,[IntPtr]::Zero)|Out-Null;[RustUIProbe]::Send($Window,0x0111,[IntPtr](110 -bor (1 -shl 16)),$combo)|Out-Null}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ICloudRustInstall-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$inputDesktop=[ICloudTestDesktop]::InputName()
function Test-Launch([string]$Directory,[string]$Mode,[switch]$Cmd){
    $exe=Join-Path $Directory 'RustUI/icloud-folder-ui.exe'
    $bridgePath=Join-Path $Directory 'tools/Invoke-WinUIBridge.ps1';$bridgeQuarantine=$null
    $before=@(Get-Process -Name icloud-folder-ui -ErrorAction SilentlyContinue|ForEach-Object Id)
    $info=New-Object Diagnostics.ProcessStartInfo;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=$Directory
    if($Cmd){$info.FileName=$env:ComSpec;$info.Arguments='/d /c ""'+(Join-Path $Directory 'Open-ICloudFolderSetup.cmd')+'""'}else{$info.FileName=$exe;$info.Arguments='--mode '+$Mode}
    # The hidden test process does not set ICLOUD_SCRIPT_ROOT: package discovery must work on its own.
    $wrapper=[Diagnostics.Process]::Start($info);$native=$null
    try{
        Wait-For {$script:found=@(Get-Process -Name icloud-folder-ui -ErrorAction SilentlyContinue|Where-Object {$_.Id -notin $before -and $_.Path -ieq $exe -and [RustUIProbe]::Find($_.Id) -ne [IntPtr]::Zero});$script:found.Count -eq 1} 'Package did not create its owned native window'
        $native=$script:found[0];$null=$native.Handle;$window=[RustUIProbe]::Find($native.Id)
        Wait-For {[RustUIProbe]::IsWindowVisible($window)} 'Package window not ready'
        $expected=switch($Mode){Reset{1} Check{5} default{0}}
        Assert ([RustUIProbe]::Send([RustUIProbe]::GetDlgItem($window,110),0x0147,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -eq $expected) 'Package startup mode lost'
        Assert (-not [RustUIProbe]::IsWindowEnabled([RustUIProbe]::GetDlgItem($window,3))) 'Unreviewed package Apply enabled'
        if($Mode -eq 'Install'){
            Wait-For {$script:dialog=[RustUIProbe]::Dialog($native.Id);$script:dialog -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($script:dialog)} 'Install confirmation missing'
            [RustUIProbe]::Send($script:dialog,0x0466,[IntPtr]2,[IntPtr]::Zero)|Out-Null
        }
        if($Mode -eq 'Check' -and $RunNativeIntegration){
            $checkRoot=Join-Path $fixture 'cloud-check'
            $null=[IO.Directory]::CreateDirectory($checkRoot)
            [RustUIProbe]::SetText([RustUIProbe]::GetDlgItem($window,100),$checkRoot)
            [RustUIProbe]::Click([RustUIProbe]::GetDlgItem($window,6))
            Wait-For {[RustUIProbe]::IsWindowEnabled([RustUIProbe]::GetDlgItem($window,1)) -and [RustUIProbe]::IsWindowVisible([RustUIProbe]::GetDlgItem($window,115))} 'Packaged read-only check did not render a structured result'
            Assert ([RustUIProbe]::Send([RustUIProbe]::GetDlgItem($window,115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -gt 1) 'Packaged Rust worker returned no configuration rows'
        }
        if($Mode -eq 'Setup' -and $RunNativeIntegration){
            $setupRoot=Join-Path $fixture 'setup-preview-drive'
            $null=[IO.Directory]::CreateDirectory($setupRoot)
            [RustUIProbe]::SetText([RustUIProbe]::GetDlgItem($window,100),$setupRoot)
            [RustUIProbe]::Click([RustUIProbe]::GetDlgItem($window,1))
            Wait-For {([RustUIProbe]::Text([RustUIProbe]::GetDlgItem($window,403))+' '+[RustUIProbe]::Text([RustUIProbe]::GetDlgItem($window,103))) -like '*Setup preview*'} 'Packaged Rust setup preview did not finish'
            Assert ([RustUIProbe]::IsWindowVisible([RustUIProbe]::GetDlgItem($window,115))) 'Packaged Rust setup preview did not render folder rows'
            Assert ([RustUIProbe]::Send([RustUIProbe]::GetDlgItem($window,115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -gt 1) 'Packaged Rust setup preview returned no folder rows'
            Assert (-not [RustUIProbe]::IsWindowEnabled([RustUIProbe]::GetDlgItem($window,3))) 'Packaged setup preview enabled Apply before review gates passed'

            $restoreRoot=Join-Path $fixture 'package-restore-targets';$null=[IO.Directory]::CreateDirectory($restoreRoot)
            $module=Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force -PassThru
            $map=& $module { Get-FolderMap -IncludeMusic }
            $values=@(foreach($name in $map.Keys){$destination=Join-Path $restoreRoot $map[$name];$null=[IO.Directory]::CreateDirectory($destination);[pscustomobject]@{Name=$name;Exists=$true;Kind='ExpandString';Data=$destination}})
            $backup=[ordered]@{Version=1;Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Key='Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders';CreatedUtc=[DateTime]::UtcNow.ToString('o');Values=$values}
            $backupPath=Join-Path $fixture 'package-before.json'
            [IO.File]::WriteAllText($backupPath,($backup|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
            if(Test-Path -LiteralPath $bridgePath){$bridgeQuarantine=$bridgePath+'.disabled-for-native-restore-test';Move-Item -LiteralPath $bridgePath -Destination $bridgeQuarantine}
            try{
                Select-Action $window 2
                [RustUIProbe]::SetText([RustUIProbe]::GetDlgItem($window,111),$backupPath)
                [RustUIProbe]::Click([RustUIProbe]::GetDlgItem($window,116))
                Wait-For {([RustUIProbe]::Text([RustUIProbe]::GetDlgItem($window,403))+' '+[RustUIProbe]::Text([RustUIProbe]::GetDlgItem($window,103))) -like '*Recovery preview is ready*'} 'Packaged Rust recovery preview did not finish through the bundled worker'
                Assert ([RustUIProbe]::IsWindowVisible([RustUIProbe]::GetDlgItem($window,115))) 'Packaged recovery preview did not render its structured table'
                Assert ([RustUIProbe]::Send([RustUIProbe]::GetDlgItem($window,115),0x1004,[IntPtr]::Zero,[IntPtr]::Zero).ToInt32() -eq $values.Count) 'Packaged recovery preview returned the wrong number of rows'
                Assert ([RustUIProbe]::IsWindowEnabled([RustUIProbe]::GetDlgItem($window,3))) 'Packaged validated recovery preview did not enable reviewed Apply'
            }finally{if($bridgeQuarantine -and (Test-Path -LiteralPath $bridgeQuarantine)){Move-Item -LiteralPath $bridgeQuarantine -Destination $bridgePath;$bridgeQuarantine=$null}}
            'PASS: packaged Rust recovery Dry run uses the bundled worker when the PowerShell bridge is unavailable; no settings were applied'
        }
        [RustUIProbe]::PostMessage($window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
        Assert ($native.WaitForExit(10000) -and $native.ExitCode -eq 0) 'Package failed clean shutdown'
        Assert ($wrapper.WaitForExit(10000) -and $wrapper.ExitCode -eq 0) 'Package wrapper did not exit cleanly'
        'PASS: Rust package '+$Mode+'; actual CMD='+$Cmd+'; no folder changes'
    }finally{
        if($native){if(-not $native.HasExited){$native.Kill();$native.WaitForExit(5000)|Out-Null};$native.Dispose()}
        if(-not $wrapper.HasExited){$wrapper.Kill();$wrapper.WaitForExit(5000)|Out-Null};$wrapper.Dispose()
        if($bridgeQuarantine -and (Test-Path -LiteralPath $bridgeQuarantine)){Move-Item -LiteralPath $bridgeQuarantine -Destination $bridgePath}
    }
}
try{
    $manifest=Get-Content (Join-Path $PackageDirectory 'manifest.json') -Raw|ConvertFrom-Json
    $policy=Get-Content (Join-Path $repo 'build/ReleaseFiles.json') -Raw|ConvertFrom-Json
    $expected=@($policy.Files)+@($policy.RustUI.Executable)+@($policy.RustUI.WorkerExecutable)
    $actual=@(Get-ChildItem $PackageDirectory -Recurse -File|ForEach-Object {$_.FullName.Substring($PackageDirectory.Length+1).Replace('\','/')})
    Assert ($manifest.Interface -eq 'Rust' -and $manifest.Signed -eq $false) 'Wrong package interface or signing declaration'
    Assert (@(Compare-Object @($expected+'manifest.json'|Sort-Object) @($actual|Sort-Object)).Count -eq 0) 'Unexpected package files'
    foreach($entry in $manifest.Files){Assert ((Get-FileHash -LiteralPath (Join-Path $PackageDirectory $entry.Path)).Hash -ceq $entry.SHA256) 'Package manifest hash mismatch'}
    Import-Module (Join-Path $PackageDirectory 'ICloudFolderSetup.Install.psm1') -Force
    $installOptions=@{Source=$PackageDirectory;InstallRoot=(Join-Path $fixture 'installed');ProgramsDirectory=(Join-Path $fixture 'menu');DesktopDirectory=(Join-Path $fixture 'desktop');RequireNative=$true}
    $preview=Install-SetupFiles @installOptions -WhatIf
    Assert (-not (Test-Path $installOptions.InstallRoot)) 'WhatIf created an install'
    $installed=Install-SetupFiles @installOptions
    foreach($link in $installed.Shortcuts){
        $shell=New-Object -ComObject WScript.Shell;$shortcut=$shell.CreateShortcut($link)
        try{Assert ($shortcut.TargetPath -ieq (Join-Path $installed.Directory 'RustUI/icloud-folder-ui.exe')) 'Shortcut does not launch Rust directly'}finally{$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut);$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    }
    'PASS: verified Rust install, WhatIf and isolated native shortcuts'
    foreach($mode in @('Setup','Reset','Check','Install')){Test-Launch $PackageDirectory $mode}
    Test-Launch $PackageDirectory Setup -Cmd
    Test-Launch $installed.Directory Check
    # Tamper only the disposable installed fixture, preserving the review package.
    [IO.File]::AppendAllText((Join-Path $installed.Directory 'README.md'),' changed fixture')
    $rejected=$false
    try{Install-SetupFiles -Source $installed.Directory -InstallRoot (Join-Path $fixture 'rejected') -ProgramsDirectory (Join-Path $fixture 'rejected-menu') -RequireNative|Out-Null}catch{if($_.Exception.Message -notlike 'Installation source hash mismatch:*'){throw};$rejected=$true}
    Assert ($rejected -and -not (Test-Path (Join-Path $fixture 'rejected-menu'))) 'Tampered Rust package was installed'
    Assert ([ICloudTestDesktop]::InputName() -ceq $inputDesktop) 'Input desktop changed'
    'PASS: Rust reinstall refuses tampered package before shortcut creation'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notmatch '^ICloudRustInstall-[a-f0-9]{32}$'){throw 'Refusing cleanup outside fixture'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
