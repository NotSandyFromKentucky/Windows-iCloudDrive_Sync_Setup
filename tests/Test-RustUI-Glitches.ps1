#requires -Version 5.1
param([ValidateRange(5,300)][int]$OperationTimeoutSeconds = 45)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$screenshotDir = Join-Path $repo '.local\ui-glitch-screenshots'
if (Test-Path -LiteralPath $screenshotDir) {
    Get-ChildItem -LiteralPath $screenshotDir -Filter '*.png' -File | Remove-Item -Force
} else {
    $null = New-Item -ItemType Directory -Path $screenshotDir -Force
}

if (-not ('Win32' -as [type])) {
    $nativeCode = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class Win32 {
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern int GetWindowThreadProcessId(IntPtr window, out int processId);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr window, StringBuilder text, int maximum);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern int GetClassName(IntPtr window, StringBuilder name, int maximum);
    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr window);
    [DllImport("user32.dll")]
    public static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll")]
    public static extern uint GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")]
    public static extern int MapWindowPoints(IntPtr from, IntPtr to, ref RECT rect, uint count);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, string text);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr window, uint message, IntPtr wParam, StringBuilder text);
    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr window, IntPtr deviceContext, uint flags);
    [DllImport("user32.dll")]
    public static extern bool RedrawWindow(IntPtr window, IntPtr update, IntPtr region, uint flags);
    [DllImport("user32.dll")]
    public static extern bool UpdateWindow(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr window);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
    public delegate bool EnumWindowsProc(IntPtr window, IntPtr lParam);
}
'@
    Add-Type -TypeDefinition $nativeCode
}

# The UI is per-monitor DPI aware. Without matching awareness this process sees
# virtualized 96-DPI coordinates while screenshots contain physical pixels, which
# crops the capture and misplaces every probe rectangle.
$script:dpiAware = $false
try { $script:dpiAware = [Win32]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
if (-not $script:dpiAware) {
    try { $script:dpiAware = [Win32]::SetProcessDPIAware() } catch { }
}

Add-Type -AssemblyName System.Drawing

if (-not ('GlitchCheck' -as [type])) {
    $glitchCode = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Collections.Generic;
public class GlitchStats {
    public int Width;
    public int Height;
    public int Samples;
    public int Distinct;
    public int Background;
    public int Black;
    public int White;
    public int Magenta;
    public int Lime;
    public int DominantCount;
    public int DominantR;
    public int DominantG;
    public int DominantB;
    public double MeanR;
    public double MeanG;
    public double MeanB;
}
public static class GlitchCheck {
    public static GlitchStats Analyze(string path, int backgroundR, int backgroundG, int backgroundB) {
        using (var bitmap = new Bitmap(path)) {
            return AnalyzeBitmap(bitmap, new Rectangle(0, 0, bitmap.Width, bitmap.Height), backgroundR, backgroundG, backgroundB);
        }
    }
    public static GlitchStats AnalyzeRegion(string path, int x, int y, int width, int height, int backgroundR, int backgroundG, int backgroundB) {
        using (var bitmap = new Bitmap(path)) {
            int left = Math.Max(0, Math.Min(x, bitmap.Width - 1));
            int top = Math.Max(0, Math.Min(y, bitmap.Height - 1));
            int right = Math.Max(left + 1, Math.Min(x + width, bitmap.Width));
            int bottom = Math.Max(top + 1, Math.Min(y + height, bitmap.Height));
            return AnalyzeBitmap(bitmap, new Rectangle(left, top, right - left, bottom - top), backgroundR, backgroundG, backgroundB);
        }
    }
    public static int MaxWhiteRun(string path, int x, int y, int width, int height) {
        using (var bitmap = new Bitmap(path)) {
            int left = Math.Max(0, Math.Min(x, bitmap.Width - 1));
            int top = Math.Max(0, Math.Min(y, bitmap.Height - 1));
            int right = Math.Max(left + 1, Math.Min(x + width, bitmap.Width));
            int bottom = Math.Max(top + 1, Math.Min(y + height, bitmap.Height));
            var region = new Rectangle(left, top, right - left, bottom - top);
            var data = bitmap.LockBits(region, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try {
                var bytes = new byte[data.Stride * region.Height];
                Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
                int best = 0;
                for (int rowIndex = 0; rowIndex < region.Height; rowIndex++) {
                    int row = rowIndex * data.Stride;
                    int run = 0;
                    for (int column = 0; column < region.Width; column++) {
                        int offset = row + column * 4;
                        if (bytes[offset] == 255 && bytes[offset + 1] == 255 && bytes[offset + 2] == 255) {
                            run++;
                            if (run > best) best = run;
                        } else {
                            run = 0;
                        }
                    }
                }
                return best;
            } finally {
                bitmap.UnlockBits(data);
            }
        }
    }
    private static GlitchStats AnalyzeBitmap(Bitmap bitmap, Rectangle region, int backgroundR, int backgroundG, int backgroundB) {
        var stats = new GlitchStats();
        stats.Width = bitmap.Width;
        stats.Height = bitmap.Height;
        var data = bitmap.LockBits(region, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int stride = data.Stride;
            int width = region.Width;
            int height = region.Height;
            var bytes = new byte[stride * height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            var colors = new Dictionary<int, int>();
            long sumR = 0, sumG = 0, sumB = 0;
            int samples = 0;
            int step = Math.Max(1, Math.Min(width, height) / 160);
            for (int rowIndex = 0; rowIndex < height; rowIndex += step) {
                int row = rowIndex * stride;
                for (int column = 0; column < width; column += step) {
                    int offset = row + column * 4;
                    int b = bytes[offset];
                    int g = bytes[offset + 1];
                    int r = bytes[offset + 2];
                    samples++;
                    sumR += r;
                    sumG += g;
                    sumB += b;
                    if (r == backgroundR && g == backgroundG && b == backgroundB) stats.Background++;
                    if (r == 0 && g == 0 && b == 0) stats.Black++;
                    if (r == 255 && g == 255 && b == 255) stats.White++;
                    if (r == 255 && g == 0 && b == 255) stats.Magenta++;
                    if (r == 0 && g == 255 && b == 0) stats.Lime++;
                    int quantized = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
                    int count;
                    if (colors.TryGetValue(quantized, out count)) colors[quantized] = count + 1;
                    else colors[quantized] = 1;
                }
            }
            stats.Samples = samples;
            stats.Distinct = colors.Count;
            if (samples > 0) {
                stats.MeanR = (double)sumR / samples;
                stats.MeanG = (double)sumG / samples;
                stats.MeanB = (double)sumB / samples;
            }
            int bestCount = 0;
            int bestColor = 0;
            foreach (var pair in colors) {
                if (pair.Value > bestCount) {
                    bestCount = pair.Value;
                    bestColor = pair.Key;
                }
            }
            stats.DominantCount = bestCount;
            stats.DominantR = ((bestColor >> 10) & 31) << 3;
            stats.DominantG = ((bestColor >> 5) & 31) << 3;
            stats.DominantB = (bestColor & 31) << 3;
        } finally {
            bitmap.UnlockBits(data);
        }
        return stats;
    }
}
'@
    Add-Type -TypeDefinition $glitchCode -ReferencedAssemblies 'System.Drawing.dll'
}

$WM_COMMAND = 0x0111
$WM_SETTEXT = 0x000C
$WM_GETTEXT = 0x000D
$WM_CLOSE = 0x0010
$WM_SETFOCUS = 0x0007
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP = 0x0202
$WM_PRINT = 0x0317
$BM_CLICK = 0x00F5
$BM_GETCHECK = 0x00F0
$EM_SETSEL = 0x00B1
$CB_GETCOUNT = 0x0146
$CB_GETCURSEL = 0x0147
$CB_SETCURSEL = 0x014E
$CBN_SELCHANGE = 1
$SWP_NOMOVE = 0x0002
$SWP_NOZORDER = 0x0004
$RDW_INVALIDATE = 0x0001
$RDW_UPDATENOW = 0x0100
$RDW_ALLCHILDREN = 0x0080
$PW_CLIENTONLY = 0x00000001
$PW_RENDERFULLCONTENT = 0x00000002
$IDNO = 7
$BACKGROUND_R = 1
$BACKGROUND_G = 2
$BACKGROUND_B = 3

function Get-WindowText {
    param([System.IntPtr]$Handle)
    $buffer = New-Object System.Text.StringBuilder(512)
    [Win32]::GetWindowText($Handle, $buffer, $buffer.Capacity) | Out-Null
    return $buffer.ToString()
}

function Get-WindowClass {
    param([System.IntPtr]$Handle)
    $buffer = New-Object System.Text.StringBuilder(256)
    [Win32]::GetClassName($Handle, $buffer, $buffer.Capacity) | Out-Null
    return $buffer.ToString()
}

function Get-ControlText {
    param([System.IntPtr]$Handle)
    $buffer = New-Object System.Text.StringBuilder(4096)
    [Win32]::SendMessage($Handle, $WM_GETTEXT, [System.IntPtr]$buffer.Capacity, $buffer) | Out-Null
    return $buffer.ToString()
}

function Set-ControlText {
    param([System.IntPtr]$Handle, [string]$Text)
    [Win32]::SendMessage($Handle, $WM_SETTEXT, [System.IntPtr]::Zero, $Text) | Out-Null
}

function Get-TopWindows {
    $list = New-Object System.Collections.Generic.List[object]
    $callback = [Win32+EnumWindowsProc] {
        param([System.IntPtr]$Handle, [System.IntPtr]$Parameter)
        $processId = 0
        [Win32]::GetWindowThreadProcessId($Handle, [ref]$processId) | Out-Null
        $rect = New-Object Win32+RECT
        $area = 0
        if ([Win32]::GetWindowRect($Handle, [ref]$rect)) {
            $area = [Math]::Max(0, $rect.Right - $rect.Left) * [Math]::Max(0, $rect.Bottom - $rect.Top)
        }
        $text = New-Object System.Text.StringBuilder(512)
        [Win32]::GetWindowText($Handle, $text, $text.Capacity) | Out-Null
        $list.Add([pscustomobject]@{
            Handle = $Handle
            Pid = $processId
            Title = $text.ToString()
            Area = $area
        })
        return $true
    }
    [Win32]::EnumWindows($callback, [System.IntPtr]::Zero) | Out-Null
    return $list.ToArray()
}

function Get-ChildWindows {
    param([System.IntPtr]$Parent)
    $list = New-Object System.Collections.Generic.List[System.IntPtr]
    $callback = [Win32+EnumWindowsProc] {
        param([System.IntPtr]$Handle, [System.IntPtr]$Parameter)
        $list.Add($Handle)
        return $true
    }
    [Win32]::EnumChildWindows($Parent, $callback, [System.IntPtr]::Zero) | Out-Null
    return $list.ToArray()
}

function Get-ControlClientRect {
    param([System.IntPtr]$Handle, [System.IntPtr]$Main)
    $rect = New-Object Win32+RECT
    [Win32]::GetWindowRect($Handle, [ref]$rect) | Out-Null
    [Win32]::MapWindowPoints([System.IntPtr]::Zero, $Main, [ref]$rect, 2) | Out-Null
    return $rect
}

function Get-ControlInfo {
    param([System.IntPtr]$Handle, [System.IntPtr]$Main)
    $rect = Get-ControlClientRect -Handle $Handle -Main $Main
    $style = [uint32][Win32]::GetWindowLong($Handle, -16)
    return [pscustomobject]@{
        Handle = $Handle
        Id = [Win32]::GetDlgCtrlID($Handle)
        Class = Get-WindowClass -Handle $Handle
        Text = Get-ControlText -Handle $Handle
        Style = $style
        Visible = [Win32]::IsWindowVisible($Handle)
        Enabled = [Win32]::IsWindowEnabled($Handle)
        X = $rect.Left
        Y = $rect.Top
        Width = $rect.Right - $rect.Left
        Height = $rect.Bottom - $rect.Top
    }
}

function Assert-ResponsiveLayout {
    param([System.IntPtr]$Main, [string]$Label)
    $client = New-Object Win32+RECT
    [Win32]::GetClientRect($Main, [ref]$client) | Out-Null
    $style = [uint32][Win32]::GetWindowLong($Main, -16)
    if (($style -band 0x00200000) -ne 0) {
        $script:failures.Add(("{0}: the main window still has a vertical scrollbar." -f $Label))
    }
    $controls = @(Get-ChildWindows -Parent $Main | ForEach-Object {
        Get-ControlInfo -Handle $_ -Main $Main
    } | Where-Object {
        $_.Visible -and $_.Width -gt 0 -and $_.Height -gt 0
    })
    foreach ($control in $controls) {
        if ($control.X -lt 0 -or $control.Y -lt 0 -or
            ($control.X + $control.Width) -gt $client.Right -or
            ($control.Y + $control.Height) -gt $client.Bottom) {
            $script:failures.Add((
                "{0}: control {1} ({2}) is clipped at {3},{4} {5}x{6} in a {7}x{8} client." -f
                $Label, $control.Id, $control.Class, $control.X, $control.Y,
                $control.Width, $control.Height, $client.Right, $client.Bottom))
            break
        }
    }
    $applyRect = Get-ControlClientRect -Handle $byId[1].Handle -Main $Main
    $bottomGap = $client.Bottom - $applyRect.Bottom
    $scaledClientDpi = [Win32]::GetDpiForWindow($Main)
    $minimumGap = [int][Math]::Round(40 * $scaledClientDpi / 96.0)
    $maximumGap = [int][Math]::Round(80 * $scaledClientDpi / 96.0)
    if ($bottomGap -lt $minimumGap -or $bottomGap -gt $maximumGap) {
        $script:failures.Add((
            "{0}: the command footer is not pinned to the bottom (gap {1})." -f
            $Label, $bottomGap))
    }
    return $controls
}

function Save-Screenshot {
    param([System.IntPtr]$Window, [string]$Name, [string]$Note = '')
    $rect = New-Object Win32+RECT
    [Win32]::GetClientRect($Window, [ref]$rect) | Out-Null
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 100 -or $height -lt 80) {
        throw ("Cannot capture '{0}': window client size is {1}x{2}." -f $Name, $width, $height)
    }
    $bitmap = New-Object System.Drawing.Bitmap($width, $height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.Clear([System.Drawing.Color]::FromArgb($BACKGROUND_R, $BACKGROUND_G, $BACKGROUND_B))
        [Win32]::RedrawWindow($Window, [System.IntPtr]::Zero, [System.IntPtr]::Zero,
            ($RDW_INVALIDATE -bor $RDW_UPDATENOW -bor $RDW_ALLCHILDREN)) | Out-Null
        [Win32]::UpdateWindow($Window) | Out-Null
        Start-Sleep -Milliseconds 80
        $deviceContext = $graphics.GetHdc()
        try {
            $printed = [Win32]::PrintWindow($Window, $deviceContext, ($PW_CLIENTONLY -bor $PW_RENDERFULLCONTENT))
            if (-not $printed) {
                [Win32]::SendMessage($Window, $WM_PRINT, $deviceContext, [System.IntPtr]28) | Out-Null
            }
        } finally {
            $graphics.ReleaseHdc($deviceContext)
        }
        $path = Join-Path $screenshotDir $Name
        $bitmap.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
    $length = (Get-Item -LiteralPath $path).Length
    if ($length -lt 500) {
        throw ("Screenshot '{0}' is only {1} bytes; the window did not render." -f $Name, $length)
    }
    $script:shots.Add([pscustomobject]@{ Name = $Name; Path = $path; Note = $Note })
    Write-Output ("SCREENSHOT {0} ({1}x{2}) {3}" -f $Name, $width, $height, $Note)
}

function Set-ComboSelection {
    param([System.IntPtr]$Combo, [System.IntPtr]$Main, [int]$Index)
    [Win32]::SendMessage($Combo, $CB_SETCURSEL, [System.IntPtr]$Index, [System.IntPtr]::Zero) | Out-Null
    $command = [System.IntPtr]((($CBN_SELCHANGE -band 0xFFFF) -shl 16) -bor 110)
    [Win32]::SendMessage($Main, $WM_COMMAND, $command, $Combo) | Out-Null
    Start-Sleep -Milliseconds 120
    $selected = [int][Win32]::SendMessage($Combo, $CB_GETCURSEL, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
    if ($selected -ne $Index) {
        throw ("Combo selection did not change to {0} (reported {1})." -f $Index, $selected)
    }
}

function Set-CheckboxState {
    param([System.IntPtr]$Checkbox, [bool]$Checked)
    $state = [int][Win32]::SendMessage($Checkbox, $BM_GETCHECK, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
    $current = ($state -eq 1)
    if ($current -ne $Checked) {
        [Win32]::SendMessage($Checkbox, $BM_CLICK, [System.IntPtr]::Zero, [System.IntPtr]::Zero) | Out-Null
        Start-Sleep -Milliseconds 120
        $state = [int][Win32]::SendMessage($Checkbox, $BM_GETCHECK, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
        $current = ($state -eq 1)
    }
    if ($current -ne $Checked) {
        throw ("Checkbox did not reach requested state {0}." -f $Checked)
    }
}

function Click-Button {
    param([System.IntPtr]$Button)
    [Win32]::SendMessage($Button, $BM_CLICK, [System.IntPtr]::Zero, [System.IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 80
}

function Focus-Control {
    param([System.IntPtr]$Handle, [int]$X = 10, [int]$Y = 10, [switch]$SelectAll)
    $position = [System.IntPtr]((($Y -band 0xFFFF) -shl 16) -bor ($X -band 0xFFFF))
    [Win32]::SendMessage($Handle, $WM_LBUTTONDOWN, [System.IntPtr]1, $position) | Out-Null
    [Win32]::SendMessage($Handle, $WM_LBUTTONUP, [System.IntPtr]::Zero, $position) | Out-Null
    if ($SelectAll) {
        [Win32]::SendMessage($Handle, $EM_SETSEL, [System.IntPtr]1, [System.IntPtr](-1)) | Out-Null
    }
    Start-Sleep -Milliseconds 120
}

function Wait-Operation {
    param([System.IntPtr]$PreviewButton, [System.IntPtr]$CancelButton, [int]$TimeoutSeconds)
    $startDeadline = (Get-Date).AddSeconds(3)
    while ((Get-Date) -lt $startDeadline) {
        $busy = ((-not [Win32]::IsWindowEnabled($PreviewButton)) -or [Win32]::IsWindowVisible($CancelButton))
        if ($busy) { break }
        Start-Sleep -Milliseconds 40
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $busy = ((-not [Win32]::IsWindowEnabled($PreviewButton)) -or [Win32]::IsWindowVisible($CancelButton))
        if (-not $busy) {
            Start-Sleep -Milliseconds 120
            $busy = ((-not [Win32]::IsWindowEnabled($PreviewButton)) -or [Win32]::IsWindowVisible($CancelButton))
            if (-not $busy) { return $true }
        }
        Start-Sleep -Milliseconds 80
    }
    return $false
}

function Find-ProcessDialog {
    param([int]$TargetPid, [System.IntPtr]$Exclude)
    foreach ($window in (Get-TopWindows)) {
        if ($window.Pid -ne $TargetPid) { continue }
        if ($window.Handle -eq $Exclude) { continue }
        if (-not [Win32]::IsWindowVisible($window.Handle)) { continue }
        if ((Get-WindowClass -Handle $window.Handle) -eq '#32770') {
            return $window.Handle
        }
    }
    return [System.IntPtr]::Zero
}

function Get-Slug {
    param([string]$Text)
    return (($Text -replace '[^A-Za-z0-9]+', '_').Trim('_').ToLowerInvariant())
}

$script:shots = New-Object System.Collections.Generic.List[object]
$script:failures = New-Object System.Collections.Generic.List[string]
$script:warnings = New-Object System.Collections.Generic.List[string]
$script:testError = $null
$script:progressRects = @{}
$coverage = [ordered]@{}
$launcherProcess = $null
$uiProcess = $null
$uiDpi = 96
if (-not $script:dpiAware) {
    $script:warnings.Add('Per-monitor DPI awareness could not be enabled; screenshot coordinates may be virtualized.')
}

try {
    $launcher = Join-Path $repo 'icloud-folder-launcher.exe'
    if (-not (Test-Path -LiteralPath $launcher)) {
        throw "Launcher not found at $launcher"
    }
    Write-Output 'Launching the Rust UI on the hidden desktop...'
    $launcherProcess = Start-Process -FilePath $launcher -NoNewWindow -PassThru -WorkingDirectory $repo

    $mainHandle = [System.IntPtr]::Zero
    $uiPid = 0
    $windowDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $windowDeadline -and $mainHandle -eq [System.IntPtr]::Zero) {
        Start-Sleep -Milliseconds 250
        $candidates = @(Get-TopWindows | Where-Object {
            $_.Title -like '*iCloud folder setup*' -and $_.Area -gt 100000
        })
        if ($candidates.Count -gt 0) {
            $best = $candidates | Sort-Object Area -Descending | Select-Object -First 1
            $mainHandle = $best.Handle
            $uiPid = $best.Pid
        }
    }
    if ($mainHandle -eq [System.IntPtr]::Zero) {
        throw 'The Rust UI did not open a main window within 60 seconds.'
    }
$uiProcess = Get-Process -Id $uiPid -ErrorAction Stop
$uiDpi = [Win32]::GetDpiForWindow($mainHandle)
Write-Output ("Main window: '{0}' (PID {1}, DPI {2}, aware={3})" -f (Get-WindowText -Handle $mainHandle), $uiPid, $uiDpi, $script:dpiAware)

    $controls = @(Get-ChildWindows -Parent $mainHandle | ForEach-Object {
        Get-ControlInfo -Handle $_ -Main $mainHandle
    })
    $byId = @{}
    foreach ($control in $controls) {
        if ($control.Id -ne 0) {
            $byId[[int]$control.Id] = $control
        }
    }
    Write-Output ("Enumerated {0} child controls ({1} with dialog IDs)." -f $controls.Count, $byId.Count)

    $required = @(1, 2, 3, 4, 5, 6, 100, 101, 102, 103, 104, 105, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119, 120, 121, 122, 123)
    foreach ($id in $required) {
        if (-not $byId.ContainsKey($id)) {
            $script:failures.Add(("Missing expected control ID {0}." -f $id))
        }
    }
    $folderEditors = @($controls | Where-Object { $_.Id -ge 200 -and $_.Id -le 215 })
    if ($folderEditors.Count -lt 6) {
        $script:failures.Add(("Expected at least 6 folder editors, found {0}." -f $folderEditors.Count))
    }
    $checkboxes = @($controls | Where-Object {
        $_.Class -eq 'Button' -and ((($_.Style -band 0xF) -eq 2) -or (($_.Style -band 0xF) -eq 3) -or (($_.Style -band 0xF) -eq 5) -or (($_.Style -band 0xF) -eq 6))
    })
    Write-Output ("Detected {0} checkboxes, {1} folder editors." -f $checkboxes.Count, $folderEditors.Count)
    foreach ($checkbox in $checkboxes) {
        Write-Output ("  checkbox {0}: '{1}' visible={2} checked={3}" -f $checkbox.Id, $checkbox.Text, $checkbox.Visible,
            (([int][Win32]::SendMessage($checkbox.Handle, $BM_GETCHECK, [System.IntPtr]::Zero, [System.IntPtr]::Zero)) -eq 1))
    }
    if ($script:failures.Count -gt 0) {
        throw ($script:failures -join ' ')
    }

    $comboHandle = $byId[110].Handle
    $previewHandle = $byId[1].Handle
    $cancelHandle = $byId[105].Handle
    $progressHandle = $byId[104].Handle
    $headingHandle = $byId[400].Handle
    $previewButtonHandle = $byId[1].Handle
    $statusHandle = $byId[103].Handle
    $technicalHandle = $byId[114].Handle
    $advancedHandle = $byId[102].Handle

    $actionCount = [int][Win32]::SendMessage($comboHandle, $CB_GETCOUNT, [System.IntPtr]::Zero, [System.IntPtr]::Zero)
    if ($actionCount -ne 9) {
        $script:failures.Add(("Expected 9 action choices, found {0}." -f $actionCount))
    }

    $headingRect = Get-ControlClientRect -Handle $headingHandle -Main $mainHandle
    $previewRect = Get-ControlClientRect -Handle $previewButtonHandle -Main $mainHandle

    Save-Screenshot -Window $mainHandle -Name '00_initial.png' -Note 'Initial layout and accent theme'
    $initialScreenshot = (Join-Path $screenshotDir '00_initial.png')

    $actionNames = @(
        'Set up iCloud folders',
        'Reset to Windows defaults',
        'Restore a recovery backup',
        'Copy files into iCloud folders',
        'Copy files into Windows default folders',
        'Check iCloud configuration',
        'Create cloud test file',
        'Check cloud return',
        'Clean up cloud test file'
    )
    $comboSelections = 0
    for ($index = 0; $index -lt $actionNames.Count; $index++) {
        Set-ComboSelection -Combo $comboHandle -Main $mainHandle -Index $index
        $name = 'combo_{0:D2}_{1}.png' -f $index, (Get-Slug -Text $actionNames[$index])
        Save-Screenshot -Window $mainHandle -Name $name -Note ("Action: {0}" -f $actionNames[$index])
        $comboSelections++
    }
    Set-ComboSelection -Combo $comboHandle -Main $mainHandle -Index 0
    $coverage['action selections'] = $comboSelections

    $checkboxTests = @(
        @{ Id = 101; Name = 'include_music' },
        @{ Id = 102; Name = 'customize_paths' },
        @{ Id = 112; Name = 'verified_folder' },
        @{ Id = 113; Name = 'keep_files' },
        @{ Id = 114; Name = 'technical_details' },
        @{ Id = 123; Name = 'desktop_shortcut' }
    )
    $checkboxToggles = 0
    foreach ($test in $checkboxTests) {
        $handle = $byId[$test.Id].Handle
        if (-not [Win32]::IsWindowVisible($handle)) {
            $script:failures.Add(("Checkbox '{0}' was not visible in the default action." -f $test.Name))
            continue
        }
        Set-CheckboxState -Checkbox $handle -Checked $false
        Set-CheckboxState -Checkbox $handle -Checked $true
        Save-Screenshot -Window $mainHandle -Name ("checkbox_{0}_on.png" -f $test.Name) -Note ("Checked {0}" -f $test.Name)
        $checkboxToggles++
        Set-CheckboxState -Checkbox $handle -Checked $false
        Save-Screenshot -Window $mainHandle -Name ("checkbox_{0}_off.png" -f $test.Name) -Note ("Unchecked {0}" -f $test.Name)
        $checkboxToggles++
        $onShot = Join-Path $screenshotDir ("checkbox_{0}_on.png" -f $test.Name)
        $offShot = Join-Path $screenshotDir ("checkbox_{0}_off.png" -f $test.Name)
        if ((Get-FileHash -LiteralPath $onShot -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $offShot -Algorithm SHA256).Hash) {
            $script:failures.Add(("Checkbox '{0}' checked and unchecked frames were identical; its state was not visible in the capture." -f $test.Name))
        }
    }
    $coverage['checkbox toggles'] = $checkboxToggles

    $editTests = 0
    Set-ComboSelection -Combo $comboHandle -Main $mainHandle -Index 0
    $rootHandle = $byId[100].Handle
    Focus-Control -Handle $rootHandle -X 12 -Y 12 -SelectAll
    Save-Screenshot -Window $mainHandle -Name 'edit_root_selected.png' -Note 'Drive folder text field focused and selected'
    $originalRoot = Get-ControlText -Handle $rootHandle
    $longRoot = $originalRoot + '\GlitchCheck-' + (Get-Date -Format 'yyyyMMddHHmmss')
    Set-ControlText -Handle $rootHandle -Text $longRoot
    Start-Sleep -Milliseconds 150
    $readBack = Get-ControlText -Handle $rootHandle
    if ($readBack -ne $longRoot) {
        $script:failures.Add('Drive folder text field did not accept the long value.')
    }
    Save-Screenshot -Window $mainHandle -Name 'edit_root_long_value.png' -Note 'Drive folder text field with long value'
    Set-ControlText -Handle $rootHandle -Text $originalRoot
    Start-Sleep -Milliseconds 150
    $readBack = Get-ControlText -Handle $rootHandle
    if ($readBack -ne $originalRoot) {
        $script:failures.Add('Drive folder text field did not restore its original value.')
    }
    Save-Screenshot -Window $mainHandle -Name 'edit_root_restored.png' -Note 'Drive folder text field restored'
    $editTests++

    Set-CheckboxState -Checkbox $advancedHandle -Checked $true
    $visibleEditors = @($folderEditors | Where-Object {
        [Win32]::IsWindowVisible($_.Handle) -and $_.Width -gt 0 -and $_.Height -gt 0
    } | Sort-Object Id)
    if ($visibleEditors.Count -eq 0) {
        $script:failures.Add('No folder text fields became visible after enabling Customize paths.')
    } else {
        $firstEditor = $visibleEditors[0]
        $lastEditor = $visibleEditors[$visibleEditors.Count - 1]
        Focus-Control -Handle $firstEditor.Handle -X 12 -Y 12 -SelectAll
        Save-Screenshot -Window $mainHandle -Name 'edit_folder_first_selected.png' -Note ("Folder field {0} focused" -f $firstEditor.Id)
        Focus-Control -Handle $lastEditor.Handle -X 12 -Y 12 -SelectAll
        Save-Screenshot -Window $mainHandle -Name 'edit_folder_last_selected.png' -Note ("Folder field {0} focused" -f $lastEditor.Id)
        $editTests += 2
    }
    Set-CheckboxState -Checkbox $advancedHandle -Checked $false

    Set-ComboSelection -Combo $comboHandle -Main $mainHandle -Index 2
    $backupHandle = $byId[111].Handle
    if ([Win32]::IsWindowVisible($backupHandle)) {
        Focus-Control -Handle $backupHandle -X 12 -Y 12 -SelectAll
        $originalBackup = Get-ControlText -Handle $backupHandle
        $backupValue = Join-Path $env:LOCALAPPDATA 'ICloudFolderSettler\Recovery\glitch-check'
        Set-ControlText -Handle $backupHandle -Text $backupValue
        Start-Sleep -Milliseconds 150
        if ((Get-ControlText -Handle $backupHandle) -ne $backupValue) {
            $script:failures.Add('Recovery path text field did not accept text.')
        }
        Save-Screenshot -Window $mainHandle -Name 'edit_backup_value.png' -Note 'Recovery text field with value'
        Set-ControlText -Handle $backupHandle -Text $originalBackup
        Start-Sleep -Milliseconds 150
        $editTests++
    } else {
        $script:failures.Add('Recovery path text field was not visible for the Restore action.')
    }
    Set-ComboSelection -Combo $comboHandle -Main $mainHandle -Index 0
    $coverage['text controls'] = $editTests

    Set-ComboSelection -Combo $comboHandle -Main $mainHandle -Index 0
    Click-Button -Button $previewHandle
    Start-Sleep -Milliseconds 120
    $sawProgress = $false
    $progressDeadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $progressDeadline -and -not $sawProgress) {
        $sawProgress = [Win32]::IsWindowVisible($progressHandle)
        if (-not $sawProgress) {
            Start-Sleep -Milliseconds 50
        }
    }
    if ($sawProgress) {
        $script:progressRects['preview'] = Get-ControlClientRect -Handle $progressHandle -Main $mainHandle
    }
    Save-Screenshot -Window $mainHandle -Name 'button_preview_running.png' -Note ("Preview running; progress visible={0}" -f $sawProgress)
    if (-not (Wait-Operation -PreviewButton $previewHandle -CancelButton $cancelHandle -TimeoutSeconds $OperationTimeoutSeconds)) {
        $script:failures.Add('Preview operation did not finish before the timeout.')
    }
    Save-Screenshot -Window $mainHandle -Name 'button_preview_done.png' -Note 'Preview result'
    $previewStatus = Get-ControlText -Handle $statusHandle
    $applyEnabled = [Win32]::IsWindowEnabled($byId[3].Handle)

    $dialog = [System.IntPtr]::Zero
    [Win32]::PostMessage($byId[3].Handle, $BM_CLICK, [System.IntPtr]::Zero, [System.IntPtr]::Zero) | Out-Null
    $dialogDeadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $dialogDeadline -and $dialog -eq [System.IntPtr]::Zero) {
        Start-Sleep -Milliseconds 100
        $dialog = Find-ProcessDialog -TargetPid $uiPid -Exclude $mainHandle
    }
    $coverage['confirmation dialogs'] = 0
    if ($dialog -ne [System.IntPtr]::Zero) {
        Save-Screenshot -Window $dialog -Name 'apply_confirmation_dialog.png' -Note 'Apply confirmation dialog'
        [Win32]::PostMessage($dialog, $WM_COMMAND, [System.IntPtr]$IDNO, [System.IntPtr]::Zero) | Out-Null
        $closeDeadline = (Get-Date).AddSeconds(6)
        while ((Get-Date) -lt $closeDeadline -and [Win32]::IsWindow($dialog)) {
            Start-Sleep -Milliseconds 100
        }
        if ([Win32]::IsWindow($dialog)) {
            [Win32]::PostMessage($dialog, $WM_CLOSE, [System.IntPtr]::Zero, [System.IntPtr]::Zero) | Out-Null
            Start-Sleep -Milliseconds 400
        }
        if ([Win32]::IsWindow($dialog)) {
            $script:failures.Add('Apply confirmation dialog could not be dismissed.')
        }
        Start-Sleep -Milliseconds 250
        Save-Screenshot -Window $mainHandle -Name 'apply_confirmation_cancelled.png' -Note 'Apply cancelled without changes'
        $coverage['confirmation dialogs'] = 1
    } else {
        $script:warnings.Add(("Apply did not open a confirmation dialog (apply enabled={0}; preview status={1})." -f $applyEnabled, ($previewStatus -replace '\s+', ' ').Trim()))
        Save-Screenshot -Window $mainHandle -Name 'apply_no_dialog.png' -Note 'Apply without confirmation dialog'
    }
    if ([Win32]::IsWindowVisible($cancelHandle)) {
        $script:failures.Add('An operation started even though the confirmation was declined.')
    }

    Set-ComboSelection -Combo $comboHandle -Main $mainHandle -Index 0
    Click-Button -Button $byId[6].Handle
    Start-Sleep -Milliseconds 120
    $sawProgress = [Win32]::IsWindowVisible($progressHandle)
    if ($sawProgress) {
        $script:progressRects['check'] = Get-ControlClientRect -Handle $progressHandle -Main $mainHandle
    }
    Save-Screenshot -Window $mainHandle -Name 'button_check_running.png' -Note ("Check running; progress visible={0}" -f $sawProgress)
    if (-not (Wait-Operation -PreviewButton $previewHandle -CancelButton $cancelHandle -TimeoutSeconds $OperationTimeoutSeconds)) {
        $script:failures.Add('Check operation did not finish before the timeout.')
    }
    Save-Screenshot -Window $mainHandle -Name 'button_check_done.png' -Note 'Check result'

    Focus-Control -Handle $statusHandle -X 12 -Y 12 -SelectAll
    Save-Screenshot -Window $mainHandle -Name 'edit_status_selected.png' -Note 'Status text focused after check'
    $coverage['text controls'] = $editTests + 1

    Set-ComboSelection -Combo $comboHandle -Main $mainHandle -Index 0
    Click-Button -Button $byId[116].Handle
    Start-Sleep -Milliseconds 120
    $sawProgress = [Win32]::IsWindowVisible($progressHandle)
    if ($sawProgress) {
        $script:progressRects['dry_run'] = Get-ControlClientRect -Handle $progressHandle -Main $mainHandle
    }
    Save-Screenshot -Window $mainHandle -Name 'button_dry_run_running.png' -Note ("Dry run running; progress visible={0}" -f $sawProgress)
    if (-not (Wait-Operation -PreviewButton $previewHandle -CancelButton $cancelHandle -TimeoutSeconds $OperationTimeoutSeconds)) {
        $script:failures.Add('Dry run operation did not finish before the timeout.')
    }
    Save-Screenshot -Window $mainHandle -Name 'button_dry_run_done.png' -Note 'Dry run result'
    $coverage['safe buttons'] = 3

    $windowRect = New-Object Win32+RECT
    [Win32]::GetWindowRect($mainHandle, [ref]$windowRect) | Out-Null
    $originalWidth = $windowRect.Right - $windowRect.Left
    $originalHeight = $windowRect.Bottom - $windowRect.Top
    $largeWidth = [int][Math]::Round(1150 * $uiDpi / 96.0)
    $largeHeight = [int][Math]::Round(940 * $uiDpi / 96.0)
    $narrowWidth = [int][Math]::Round(760 * $uiDpi / 96.0)
    $narrowHeight = [int][Math]::Round(640 * $uiDpi / 96.0)
    [Win32]::SetWindowPos($mainHandle, [System.IntPtr]::Zero, 0, 0, $largeWidth, $largeHeight, ($SWP_NOMOVE -bor $SWP_NOZORDER)) | Out-Null
    Start-Sleep -Milliseconds 500
    Save-Screenshot -Window $mainHandle -Name 'resize_large.png' -Note 'Resized large'
    $null = Assert-ResponsiveLayout -Main $mainHandle -Label 'Large window'

    [Win32]::SetWindowPos($mainHandle, [System.IntPtr]::Zero, 0, 0, $narrowWidth, $narrowHeight, ($SWP_NOMOVE -bor $SWP_NOZORDER)) | Out-Null
    Start-Sleep -Milliseconds 500
    Save-Screenshot -Window $mainHandle -Name 'resize_narrow.png' -Note 'Resized narrow'
    $null = Assert-ResponsiveLayout -Main $mainHandle -Label 'Narrow window'

    $resizedRect = New-Object Win32+RECT
    $resizedClient = New-Object Win32+RECT
    [Win32]::GetWindowRect($mainHandle, [ref]$resizedRect) | Out-Null
    [Win32]::GetClientRect($mainHandle, [ref]$resizedClient) | Out-Null
    $frameWidth = ($resizedRect.Right - $resizedRect.Left) - ($resizedClient.Right - $resizedClient.Left)
    $frameHeight = ($resizedRect.Bottom - $resizedRect.Top) - ($resizedClient.Bottom - $resizedClient.Top)
    $minimumWidth = [int][Math]::Round(800 * $uiDpi / 96.0) + $frameWidth
    $minimumHeight = [int][Math]::Round(470 * $uiDpi / 96.0) + $frameHeight
    [Win32]::SetWindowPos($mainHandle, [System.IntPtr]::Zero, 0, 0, $minimumWidth, $minimumHeight, ($SWP_NOMOVE -bor $SWP_NOZORDER)) | Out-Null
    Start-Sleep -Milliseconds 500
    Save-Screenshot -Window $mainHandle -Name 'resize_minimum.png' -Note 'Minimum window size'
    $null = Assert-ResponsiveLayout -Main $mainHandle -Label 'Minimum window'

    [Win32]::SetWindowPos($mainHandle, [System.IntPtr]::Zero, $windowRect.Left, $windowRect.Top, $originalWidth, $originalHeight, $SWP_NOZORDER) | Out-Null
    Start-Sleep -Milliseconds 500
    Save-Screenshot -Window $mainHandle -Name 'resize_restored.png' -Note 'Original size restored'
    $null = Assert-ResponsiveLayout -Main $mainHandle -Label 'Restored window'
    $coverage['responsive resizes'] = 4

    Set-ComboSelection -Combo $comboHandle -Main $mainHandle -Index 0
    Set-CheckboxState -Checkbox $technicalHandle -Checked $false
    Save-Screenshot -Window $mainHandle -Name 'final_before_close.png' -Note 'Final state before close'

    Click-Button -Button $byId[2].Handle
    $exitDeadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $exitDeadline -and -not $uiProcess.HasExited) {
        Start-Sleep -Milliseconds 100
    }
    if (-not $uiProcess.HasExited) {
        $script:failures.Add('Close button did not exit the UI process.')
        [Win32]::PostMessage($mainHandle, $WM_CLOSE, [System.IntPtr]::Zero, [System.IntPtr]::Zero) | Out-Null
        Start-Sleep -Milliseconds 500
    }
    $coverage['close'] = if ($uiProcess.HasExited) { 1 } else { 0 }
} catch {
    $script:testError = ($_ | Out-String).Trim()
} finally {
    if ($uiProcess -and -not $uiProcess.HasExited) {
        & taskkill.exe /PID $uiProcess.Id /T /F 2>$null | Out-Null
    }
    if ($launcherProcess -and -not $launcherProcess.HasExited) {
        Stop-Process -Id $launcherProcess.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Output ''
Write-Output '=== Frame analysis ==='
$analysis = New-Object System.Collections.Generic.List[object]
foreach ($shot in $script:shots) {
    if (-not (Test-Path -LiteralPath $shot.Path)) {
        $script:failures.Add(("Screenshot '{0}' is missing." -f $shot.Name))
        continue
    }
    $length = (Get-Item -LiteralPath $shot.Path).Length
    $stats = [GlitchCheck]::Analyze($shot.Path, $BACKGROUND_R, $BACKGROUND_G, $BACKGROUND_B)
    $samples = [Math]::Max(1, $stats.Samples)
    $unpainted = 100.0 * $stats.Background / $samples
    $white = 100.0 * $stats.White / $samples
    $black = 100.0 * $stats.Black / $samples
    $magenta = 100.0 * $stats.Magenta / $samples
    $lime = 100.0 * $stats.Lime / $samples
    $analysis.Add([pscustomobject]@{
        Name = $shot.Name
        Bytes = $length
        Width = $stats.Width
        Height = $stats.Height
        Colors = $stats.Distinct
        WhitePct = [Math]::Round($white, 2)
        BlackPct = [Math]::Round($black, 2)
        UnpaintedPct = [Math]::Round($unpainted, 2)
        MagentaPct = [Math]::Round($magenta, 3)
        LimePct = [Math]::Round($lime, 3)
        Dominant = ("{0},{1},{2}" -f $stats.DominantR, $stats.DominantG, $stats.DominantB)
    })
    if ($stats.Width -lt 120 -or $stats.Height -lt 80) {
        $script:failures.Add(("'{0}' has an invalid size {1}x{2}." -f $shot.Name, $stats.Width, $stats.Height))
    }
    if ($length -lt 2000) {
        $script:failures.Add(("'{0}' is only {1} bytes." -f $shot.Name, $length))
    }
    if ($stats.Distinct -lt 6) {
        $script:failures.Add(("'{0}' appears blank (only {1} sampled colors)." -f $shot.Name, $stats.Distinct))
    }
    if ($unpainted -gt 2.0) {
        $script:failures.Add(("'{0}' has {1:N2}% unpainted capture area." -f $shot.Name, $unpainted))
    }
    if ($white -gt 95.0) {
        $script:failures.Add(("'{0}' is {1:N2}% pure white." -f $shot.Name, $white))
    }
    if ($black -gt 95.0) {
        $script:failures.Add(("'{0}' is {1:N2}% pure black." -f $shot.Name, $black))
    }
    if ($magenta -gt 0.5) {
        $script:failures.Add(("'{0}' contains {1:N3}% magenta artifact pixels." -f $shot.Name, $magenta))
    }
    if ($lime -gt 0.5) {
        $script:failures.Add(("'{0}' contains {1:N3}% lime artifact pixels." -f $shot.Name, $lime))
    }
    if (100.0 * $stats.DominantCount / $samples -gt 95.0) {
        $script:warnings.Add(("'{0}' is more than 95% a single color ({1})." -f $shot.Name, $stats.DominantCount))
    }
}

foreach ($row in $analysis) {
    Write-Output ("{0,-40} {1,6}B {2,4}x{3,-4} colors={4,-4} white={5,6:N2}% black={6,5:N2}% unpainted={7,6:N2}% magenta={8,5:N2}% lime={9,5:N2}% dominant={10}" -f `
        $row.Name, $row.Bytes, $row.Width, $row.Height, $row.Colors, $row.WhitePct, $row.BlackPct, $row.UnpaintedPct, $row.MagentaPct, $row.LimePct, $row.Dominant)
}

$hashes = @{}
foreach ($shot in $script:shots) {
    if (Test-Path -LiteralPath $shot.Path) {
        $hashes[(Get-FileHash -LiteralPath $shot.Path -Algorithm SHA256).Hash] = $true
    }
}
Write-Output ("Unique frames: {0} of {1}" -f $hashes.Count, $script:shots.Count)
if ($hashes.Count -lt 6) {
    $script:failures.Add('Fewer than 6 unique frames; the screenshots may be stale.')
}

Write-Output ''
Write-Output '=== Accent and progress probes ==='
if (Test-Path -LiteralPath $initialScreenshot) {
    $heading = [GlitchCheck]::AnalyzeRegion($initialScreenshot, $headingRect.Left, $headingRect.Top,
        ($headingRect.Right - $headingRect.Left), ($headingRect.Bottom - $headingRect.Top), $BACKGROUND_R, $BACKGROUND_G, $BACKGROUND_B)
    $preview = [GlitchCheck]::AnalyzeRegion($initialScreenshot, $previewRect.Left, $previewRect.Top,
        ($previewRect.Right - $previewRect.Left), ($previewRect.Bottom - $previewRect.Top), $BACKGROUND_R, $BACKGROUND_G, $BACKGROUND_B)
    $headingChroma = [Math]::Max($heading.DominantR, [Math]::Max($heading.DominantG, $heading.DominantB)) - [Math]::Min($heading.DominantR, [Math]::Min($heading.DominantG, $heading.DominantB))
    $previewChroma = [Math]::Max($preview.DominantR, [Math]::Max($preview.DominantG, $preview.DominantB)) - [Math]::Min($preview.DominantR, [Math]::Min($preview.DominantG, $preview.DominantB))
    Write-Output ("Heading dominant RGB=({0},{1},{2}) chroma={3}" -f $heading.DominantR, $heading.DominantG, $heading.DominantB, $headingChroma)
    Write-Output ("Preview dominant RGB=({0},{1},{2}) chroma={3}" -f $preview.DominantR, $preview.DominantG, $preview.DominantB, $previewChroma)
    $headingWhiteRun = [GlitchCheck]::MaxWhiteRun($initialScreenshot, $headingRect.Left, $headingRect.Top,
        ($headingRect.Right - $headingRect.Left), ($headingRect.Bottom - $headingRect.Top))
    $maxHeadingWhiteRun = [int][Math]::Round(55 * $uiDpi / 96.0)
    Write-Output ("Heading longest white run={0}px (limit {1}px)" -f $headingWhiteRun, $maxHeadingWhiteRun)
    if ($headingWhiteRun -gt $maxHeadingWhiteRun) {
        $script:failures.Add(("Heading contains a {0}px solid white run (limit {1}px); its text background is opaque." -f $headingWhiteRun, $maxHeadingWhiteRun))
    }
    if ($headingChroma -lt 8 -and $previewChroma -lt 8) {
        $script:warnings.Add('Accent color was not detected on the heading or primary button.')
    }
}

foreach ($name in @('preview', 'check', 'dry_run')) {
    if (-not $script:progressRects.ContainsKey($name)) { continue }
    $shot = $script:shots | Where-Object { $_.Name -eq ("button_{0}_running.png" -f $name) } | Select-Object -First 1
    if (-not $shot) { continue }
    $rect = $script:progressRects[$name]
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) {
        $script:warnings.Add(("Progress bar for {0} had no drawable area." -f $name))
        continue
    }
    $progress = [GlitchCheck]::AnalyzeRegion($shot.Path, $rect.Left, $rect.Top, $width, $height, $BACKGROUND_R, $BACKGROUND_G, $BACKGROUND_B)
    Write-Output ("Progress '{0}': {1}x{2}, colors={3}, dominant=({4},{5},{6})" -f $name, $width, $height, $progress.Distinct, $progress.DominantR, $progress.DominantG, $progress.DominantB)
    if ($progress.Distinct -lt 2) {
        $script:warnings.Add(("Progress bar for {0} appeared blank." -f $name))
    }
}
if ($script:progressRects.Count -eq 0) {
    $script:warnings.Add('Progress bar was not observed during any operation.')
}

Write-Output ''
Write-Output '=== Coverage ==='
foreach ($key in $coverage.Keys) {
    Write-Output ("{0}: {1}" -f $key, $coverage[$key])
}
Write-Output 'Safe button clicks: Preview, Apply (confirmation declined), Check, Dry run, Close.'
Write-Output 'Not clicked: Copy, Reset (hidden write actions), Install for me, Browse/Recovery/Save (file dialogs), Recovery files/Help (external shell), Help.'
Write-Output ("Screenshots: {0} in {1}" -f $script:shots.Count, $screenshotDir)

if ($script:warnings.Count -gt 0) {
    Write-Output ''
    Write-Output '=== Warnings ==='
    foreach ($warning in $script:warnings) { Write-Output ("WARNING: {0}" -f $warning) }
}
if ($script:failures.Count -gt 0) {
    Write-Output ''
    Write-Output '=== Failures ==='
    foreach ($failure in $script:failures) { Write-Output ("FAIL: {0}" -f $failure) }
}

if ($script:testError) {
    throw ("UI glitch test aborted: {0}" -f $script:testError)
}
if ($script:failures.Count -gt 0) {
    throw ("UI glitch test failed with {0} issue(s)." -f $script:failures.Count)
}
Write-Output ''
Write-Output 'UI glitch test passed: interactions completed and no blank, unpainted or artifact frames were detected.'
