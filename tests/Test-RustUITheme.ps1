#requires -Version 5.1
param([Parameter(Mandatory)][string]$WorkerPath,[switch]$RequireHighContrast)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$WorkerPath=(Resolve-Path -LiteralPath $WorkerPath).Path
if(-not $env:ICLOUD_TEST_DESKTOP){& (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{WorkerPath=$WorkerPath;RequireHighContrast=$RequireHighContrast.IsPresent} -TimeoutSeconds 180;return}
Add-Type -AssemblyName System.Drawing,Accessibility
Add-Type -Path (Join-Path $PSScriptRoot 'RustUIProbe.cs') -ReferencedAssemblies System.Drawing,Accessibility
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ThemeProbe {
    [StructLayout(LayoutKind.Sequential)] public struct HighContrast { public uint Size; public uint Flags; public IntPtr Scheme; }
    [DllImport("user32.dll")] static extern bool SystemParametersInfo(uint action,uint parameter,ref HighContrast value,uint winIni);
    public static bool HighContrastActive(){var value=new HighContrast();value.Size=(uint)Marshal.SizeOf(value);return SystemParametersInfo(66,value.Size,ref value,0)&&(value.Flags&1)!=0;}
    [DllImport("user32.dll")] public static extern uint GetSysColor(int index);
}
'@
function Assert($Value,[string]$Message){if(-not $Value){throw $Message}}
function Wait-For([scriptblock]$Condition,[string]$Message){$end=[DateTime]::UtcNow.AddSeconds(20);while([DateTime]::UtcNow -lt $end){if(& $Condition){return};Start-Sleep -Milliseconds 50};throw $Message}
function Median([int[]]$Values){$sorted=@($Values|Sort-Object);return $sorted[[int][Math]::Floor($sorted.Count/2)]}
function Control([int]$Id){[RustUIProbe]::GetDlgItem($script:window,$Id)}

$evidence=Join-Path $repo '.local/rust-ui-theme'
$null=[IO.Directory]::CreateDirectory($evidence)
$lightSetting=(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
$expected=if($null -eq $lightSetting -or $lightSetting -ne 0){'light'}else{'dark'}
$highContrast=[ThemeProbe]::HighContrastActive()
if($RequireHighContrast -and -not $highContrast){throw 'Rust high-contrast fixture requires Windows high contrast to be active.'}
$previousDpi=[RustUIProbe]::SetThreadDpiAwarenessContext([IntPtr](-4))
$process=$null
$script:process=$null
$script:window=[IntPtr]::Zero
$script:results=@()
function Start-ThemeWindow([string]$Mode){
    $info=New-Object Diagnostics.ProcessStartInfo
    $fixture=if($Mode -eq 'system'){''}else{' --fixture-theme '+$Mode}
    $info.FileName=$WorkerPath
    $info.Arguments='--fixture-dpi 96'+$fixture+' --source "'+$repo+'"'
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $script:process=[Diagnostics.Process]::Start($info)
    $script:window=[IntPtr]::Zero
    Wait-For {$script:window=[RustUIProbe]::Find($script:process.Id);$script:window -ne [IntPtr]::Zero -and [RustUIProbe]::IsWindowVisible($script:window) -and (Control 110) -ne [IntPtr]::Zero} ('Theme window missing for '+$Mode)
    Start-Sleep -Milliseconds 500
}
function Sample([string]$Path,[int]$Id){
    $windowRect=New-Object RustUIProbe+Rect
    [RustUIProbe]::GetWindowRect($script:window,[ref]$windowRect)|Out-Null
    $rect=New-Object RustUIProbe+Rect
    [RustUIProbe]::GetWindowRect((Control $Id),[ref]$rect)|Out-Null
    $bitmap=[Drawing.Bitmap]::FromFile($Path)
    try {
        $values=@()
        foreach($xp in @(0.25,0.5,0.75)){
            foreach($yp in @(0.25,0.5,0.75)){
                $x=[int]($rect.Left-$windowRect.Left+($rect.Right-$rect.Left)*$xp)
                $y=[int]($rect.Top-$windowRect.Top+($rect.Bottom-$rect.Top)*$yp)
                $c=$bitmap.GetPixel([Math]::Max(0,[Math]::Min($x,$bitmap.Width-1)),[Math]::Max(0,[Math]::Min($y,$bitmap.Height-1)))
                $values+= [int][Math]::Round(0.2126*$c.R+0.7152*$c.G+0.0722*$c.B)
            }
        }
        return Median $values
    } finally {$bitmap.Dispose()}
}
function Verify-Theme([string]$Mode,[string]$Expected){
    $path=Join-Path $evidence ($Mode+'.png')
    [RustUIProbe]::Screenshot($script:window,$path)
    $samples=@()
    foreach($id in @(100,103,110,4)){$samples+=(Sample $path $id)}
    $text=if($RequireHighContrast){'Windows high contrast'}elseif($Expected -eq 'dark'){'dark'}else{'light'}
    if($RequireHighContrast){
        $system= [ThemeProbe]::GetSysColor(5)
        $expectedWindowLuma=[int][Math]::Round(0.2126*($system -band 0xFF)+0.7152*(($system -shr 8)-band 0xFF)+0.0722*(($system -shr 16)-band 0xFF))
        foreach($index in @(0,1)){
            Assert ([Math]::Abs($samples[$index]-$expectedWindowLuma) -le 3) ('High-contrast edit background does not use COLOR_WINDOW: actual '+$samples[$index]+', expected '+$expectedWindowLuma)
        }
    } else {
        foreach($luma in $samples){
            if($Expected -eq 'dark'){Assert ($luma -lt 110) ('Control background is not dark: '+$luma)}
            else{Assert ($luma -gt 170) ('Control background is not light: '+$luma)}
        }
    }
    Write-Output ('PASS: '+$Mode+' follows '+$text+'; control luminance '+($samples -join ',')+$(if($RequireHighContrast){'; COLOR_WINDOW luminance '+$expectedWindowLuma}else{''}))
    [RustUIProbe]::PostMessage($script:window,0x001A,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Start-Sleep -Milliseconds 250
    Assert (-not $script:process.HasExited) 'Theme-change notification closed the window'
    $after=Join-Path $evidence ($Mode+'-after-setting-change.png')
    [RustUIProbe]::Screenshot($script:window,$after)
    Assert ((Sample $after 100) -eq $samples[0]) 'Theme-change notification changed the fixture theme'
    [RustUIProbe]::PostMessage($script:window,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
    Assert ($script:process.WaitForExit(10000) -and $script:process.ExitCode -eq 0) 'Theme window did not close cleanly'
    $script:process.Dispose();$script:process=$null
    $script:results+=[pscustomobject]@{Mode=$Mode;Expected=$text;ControlLuminance=($samples -join ',')}
}
try {
    Start-ThemeWindow 'system'
    Verify-Theme 'system' $expected
    if($RequireHighContrast){
        Start-ThemeWindow 'dark'
        Verify-Theme 'dark' 'dark'
    } elseif($highContrast){
        Write-Output 'High contrast is active; fixture themes intentionally use system colors.'
    } else {
        Start-ThemeWindow 'light'
        Verify-Theme 'light' 'light'
        Start-ThemeWindow 'dark'
        Verify-Theme 'dark' 'dark'
    }
    $script:results|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $evidence 'results.json') -Encoding UTF8
} finally {
    [RustUIProbe]::SetThreadDpiAwarenessContext($previousDpi)|Out-Null
    if($script:process){if(-not $script:process.HasExited){$script:process.Kill();$script:process.WaitForExit()};$script:process.Dispose()}
}
