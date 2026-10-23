#requires -Version 5.1
param([switch]$RequireHighContrast)
$ErrorActionPreference='Stop'
if(-not $env:ICLOUD_TEST_DESKTOP){& (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{RequireHighContrast=[bool]$RequireHighContrast};return}
if(& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath){return}
$repo=Split-Path $PSScriptRoot -Parent
$exe=Join-Path $repo 'ui/ICloudFolderSetup/bin/x64/Debug/net10.0-windows10.0.19041.0/win-x64/ICloudFolderSetup.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'Build the native Debug x64 project first.'}
foreach($theme in @('Light','Dark')){
    $image=Join-Path $repo ('.local/hidden-desktop/winui-'+$theme.ToLowerInvariant()+'.png')
    foreach($file in @($image,($image+'.json'))){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$exe;$start.UseShellExecute=$false
    $start.Arguments='--source "'+$repo+'" --render-fixture "'+$image+'" --fixture-theme '+$theme
    $process=[Diagnostics.Process]::Start($start)
    try{
        $until=[DateTime]::UtcNow.AddSeconds(30)
        while(-not(Test-Path -LiteralPath ($image+'.json')) -and [DateTime]::UtcNow -lt $until){
            if($process.HasExited){throw ('Theme fixture exited: '+$process.ExitCode)}
            Start-Sleep -Milliseconds 100
        }
        if(-not(Test-Path -LiteralPath ($image+'.json'))){throw ('Theme fixture timed out: '+$theme)}
        $palette=Get-Content -LiteralPath ($image+'.json') -Raw | ConvertFrom-Json
        if($RequireHighContrast -and -not $palette.HighContrast){throw 'The native application did not observe Windows high contrast.'}
        if($palette.Theme -cne $theme){throw 'Requested app theme did not apply.'}
        if(-not $palette.HighContrast){
            if($palette.WindowsColor -cne $palette.ExpectedWindowsColor){throw ('Identity accent does not follow Windows: '+($palette | ConvertTo-Json -Compress))}
            $expectedCloud=if($theme -eq 'Light'){'#FF0067C0'}else{'#FF73B9FF'}
            if($palette.CloudColor -cne $expectedCloud){throw ('Cloud identity did not adapt to theme: '+$palette.CloudColor)}
        }else{
            if($palette.WindowsColor -cne $palette.ExpectedWindowsColor -or $palette.CloudColor -cne $palette.ExpectedWindowsColor){throw ('High-contrast identity differs from system window text: '+($palette | ConvertTo-Json -Compress))}
        }
        $paletteKind=if($palette.HighContrast){'system high-contrast'}else{'system-accent/theme'}
        Write-Output ('PASS: real '+$theme+' render and '+$paletteKind+' palette; screenshot: '+$image)
    }finally{if(-not $process.HasExited){$process.Kill();$process.WaitForExit(5000) | Out-Null};$process.Dispose()}
}
[xml]$resources=[IO.File]::ReadAllText((Join-Path $repo 'ui/ICloudFolderSetup/App.xaml'))
$ns=New-Object Xml.XmlNamespaceManager($resources.NameTable)
$ns.AddNamespace('x','http://schemas.microsoft.com/winfx/2006/xaml');$ns.AddNamespace('p','http://schemas.microsoft.com/winfx/2006/xaml/presentation')
$contrast=$resources.SelectSingleNode('//p:ResourceDictionary[@x:Key="HighContrast"]',$ns)
if($null -eq $contrast -or $contrast.ChildNodes.Count -ne 4){throw 'Missing high-contrast identity palette.'}
foreach($brush in $contrast.ChildNodes){if($brush.Color -notlike '{ThemeResource SystemColor*}'){throw 'High-contrast branding uses a fixed color.'}}
'PASS: high-contrast resource palette delegates to system colors; OS switching is verified separately by the guarded contrast suite'
