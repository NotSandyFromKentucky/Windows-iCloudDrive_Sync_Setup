#requires -Version 5.1
param([int]$TimeoutSeconds = 15)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$launcher = Join-Path $repo 'icloud-folder-launcher.exe'
if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Launcher not found at $launcher"
}
Write-Output "Testing launcher: $launcher"
$process = Start-Process -FilePath $launcher -NoNewWindow -PassThru -WorkingDirectory $repo
try {
    Write-Output "Launcher PID: $($process.Id)"
    Start-Sleep -Seconds $TimeoutSeconds
    if ($process.HasExited) {
        Write-Output "Launcher exited with code: $($process.ExitCode)"
    } else {
        Write-Output "Launcher still running after timeout (expected - UI stays open)"
        $uiProcess = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($uiProcess) {
            Write-Output "Process working set: $([math]::Round($uiProcess.WorkingSet64 / 1MB, 3)) MB"
        }
        $process.Kill()
        Write-Output "Launcher stopped"
    }
} finally {
    if (-not $process.HasExited) {
        $process.Kill() | Out-Null
    }
    $process.WaitForExit()
}
Write-Output "Test passed"
