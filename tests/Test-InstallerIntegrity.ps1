#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $temp ('ICloudInstallIntegrity-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$module=$null
try{
    $modulePath=Join-Path $fixture 'FixtureInstaller.psm1'
    Copy-Item -LiteralPath (Join-Path $repo 'ICloudFolderSetup.Install.psm1') -Destination $modulePath
    $module=Import-Module $modulePath -Force -PassThru
    & $module {
        function script:Copy-Item {
            [CmdletBinding()]
            param([string]$LiteralPath,[string]$Destination)
            # Simulate a source update after preflight hashing, immediately before copying.
            [IO.File]::AppendAllText($LiteralPath,' changed during copy')
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -ErrorAction Stop
        }
    }
    foreach($packaged in @($false,$true)){
        $source=Join-Path $fixture ('source-'+$packaged)
        $null=[IO.Directory]::CreateDirectory((Join-Path $source 'build'))
        $files=@('Start-ICloudFolderSetup.ps1','ICloudFolderSetup.UI.psm1','ICloudFolderSetup.Install.psm1','Install-ICloudFolderSetup.ps1','ICloudFolders.psm1','VERSION')
        foreach($file in $files){[IO.File]::WriteAllText((Join-Path $source $file),$(if($file -eq 'VERSION'){'1.0.0'}else{'fixture content'}))}
        $files | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $source 'build/ReleaseFiles.json') -Encoding UTF8
        if($packaged){
            $entries=@($files | ForEach-Object {[pscustomobject]@{Path=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $source $_)).Hash}})
            [pscustomobject]@{Files=$entries} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $source 'manifest.json') -Encoding UTF8
        }
        $menu=Join-Path $fixture ('menu-'+$packaged)
        $options=@{Source=$source;InstallRoot=(Join-Path $fixture ('installed-'+$packaged));ProgramsDirectory=$menu}
        $rejected=$false
        try{& $module {param($Options) Install-SetupFiles @Options} $options | Out-Null}catch{
            if($_.Exception.Message -notlike 'Installed copy verification failed:*'){throw}
            $rejected=$true
        }
        if(-not $rejected -or (Test-Path -LiteralPath $menu)){throw 'Source changes during copying were not rejected before shortcut creation.'}
        Write-Output ('PASS: source mutation during copy rejected against preflight hash; packaged='+$packaged)
    }
    $tooManyEntries=@(for($index=0;$index -lt 4200;$index++){[pscustomobject]@{Path=('file'+$index+'.txt');SHA256=('0'*64)}})
    $cases=@(
        [pscustomobject]@{Name='oversized';Json=(' '*(4MB+1));Expected='Installation metadata exceeds the supported 4 MiB size limit.'},
        [pscustomobject]@{Name='deep';Json=('{"Files":'+('['*17)+'null'+(']'*17)+'}');Expected='Installation metadata exceeds the supported 16-level nesting limit.'},
        [pscustomobject]@{Name='too-many-files';Json=([pscustomobject]@{Files=$tooManyEntries}|ConvertTo-Json -Depth 4);Expected='Invalid installation file list.'}
    )
    foreach($case in $cases){
        $source=Join-Path $fixture ('bounded-'+$case.Name)
        $null=[IO.Directory]::CreateDirectory($source)
        [IO.File]::WriteAllText((Join-Path $source 'manifest.json'),$case.Json)
        $options=@{Source=$source;InstallRoot=(Join-Path $fixture ('bounded-installed-'+$case.Name));ProgramsDirectory=(Join-Path $fixture ('bounded-menu-'+$case.Name))}
        $rejected=$false
        try{& $module {param($Options) Install-SetupFiles @Options} $options|Out-Null}catch{if($_.Exception.Message -cne $case.Expected){throw};$rejected=$true}
        if(-not $rejected -or (Test-Path -LiteralPath $options.InstallRoot) -or (Test-Path -LiteralPath $options.ProgramsDirectory)){throw "Invalid installer metadata was not rejected before writes: $($case.Name)"}
        Write-Output ('PASS: '+$case.Name+' installer metadata rejected before writes')
    }
    $nativeSource=Join-Path $fixture 'native-missing-folder-definitions'
    $nativeFiles=@('Start-ICloudFolderSetup.ps1','ICloudFolderSetup.UI.psm1','ICloudFolderSetup.Install.psm1','Install-ICloudFolderSetup.ps1','ICloudFolders.psm1','ICloudFolderSetup.Launch.psm1','VERSION','tools/Invoke-WinUIBridge.ps1','tools/Invoke-WinUIInstall.ps1','NativeUI/ICloudFolderSetup.exe')
    foreach($file in $nativeFiles){$path=Join-Path $nativeSource $file;$null=[IO.Directory]::CreateDirectory((Split-Path $path -Parent));[IO.File]::WriteAllText($path,'native fixture')}
    $nativeEntries=@($nativeFiles|ForEach-Object {[pscustomobject]@{Path=$_;SHA256=(Get-FileHash -LiteralPath (Join-Path $nativeSource $_)).Hash}})
    [pscustomobject]@{Files=$nativeEntries}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath (Join-Path $nativeSource 'manifest.json') -Encoding UTF8
    $nativeRoot=Join-Path $fixture 'native-missing-resource-installed';$nativeMenu=Join-Path $fixture 'native-missing-resource-menu'
    $rejected=$false
    try{& $module {param($Source,$InstallRoot,$ProgramsDirectory) Install-SetupFiles -Source $Source -InstallRoot $InstallRoot -ProgramsDirectory $ProgramsDirectory -RequireNative} $nativeSource $nativeRoot $nativeMenu|Out-Null}catch{if($_.Exception.Message -cne 'Required native installation file is missing: NativeUI/folder-definitions.json'){throw};$rejected=$true}
    if(-not $rejected -or (Test-Path -LiteralPath $nativeRoot) -or (Test-Path -LiteralPath $nativeMenu)){throw 'Native package without generated folder definitions was not rejected before writes.'}
    Write-Output 'PASS: native package missing generated folder definitions rejected before writes'
    $policySource=Join-Path $fixture 'bounded-release-policy'
    $null=[IO.Directory]::CreateDirectory((Join-Path $policySource 'build'))
    $policyEntries=@(for($index=0;$index -lt 4200;$index++){'file'+$index+'.txt'})
    [IO.File]::WriteAllText((Join-Path $policySource 'build/ReleaseFiles.json'),($policyEntries|ConvertTo-Json))
    $options=@{Source=$policySource;InstallRoot=(Join-Path $fixture 'bounded-policy-installed');ProgramsDirectory=(Join-Path $fixture 'bounded-policy-menu')}
    $rejected=$false
    try{& $module {param($Options) Install-SetupFiles @Options} $options|Out-Null}catch{if($_.Exception.Message -cne 'Invalid installation file list.'){throw};$rejected=$true}
    if(-not $rejected -or (Test-Path -LiteralPath $options.InstallRoot) -or (Test-Path -LiteralPath $options.ProgramsDirectory)){throw 'Oversized ReleaseFiles policy was not rejected before install writes.'}
    Write-Output 'PASS: oversized ReleaseFiles policy rejected before install writes'
}finally{
    if($module){Remove-Module $module -Force}
    $path=[IO.Path]::GetFullPath($fixture)
    if($path.StartsWith($temp.TrimEnd('\')+'\ICloudInstallIntegrity-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Recurse -Force}
}
