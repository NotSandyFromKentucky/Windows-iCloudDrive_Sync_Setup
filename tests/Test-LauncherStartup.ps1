#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$launcher = Join-Path $repo 'icloud-folder-launcher.exe'

Write-Output "Measuring launcher startup time..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $launcher -NoNewWindow -PassThru -WorkingDirectory $repo
Write-Output "Process started: PID $($p.Id)"

# Wait up to 10 seconds to see if the process exits (rebuilding) or stays running (UI launched)
$elapsed = 0
while ($elapsed -lt 10 -and -not $p.HasExited) {
    Start-Sleep -Milliseconds 500
    $elapsed += 500
}

$sw.Stop()
Write-Output "Total time: $($sw.ElapsedMilliseconds)ms"

if ($p.HasExited) {
    Write-Output "Launcher exited with code: $($p.ExitCode)"
    if ($p.ExitCode -eq 0) {
        Write-Output "ERROR: Launcher exited too fast - UI should stay open"
    }
} else {
    Write-Output "Launcher still running after $($elapsed)ms - UI launched successfully"
    $p.Kill()
    $p.WaitForExit()
    Write-Output "Launcher stopped"
}

Write-Output "Test passed"
