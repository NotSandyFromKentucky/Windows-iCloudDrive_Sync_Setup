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
}finally{
    if($module){Remove-Module $module -Force}
    $path=[IO.Path]::GetFullPath($fixture)
    if($path.StartsWith($temp.TrimEnd('\')+'\ICloudInstallIntegrity-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $path -Recurse -Force}
}
