#requires -Version 5.1
# Test the interactive wrapper with a stub module; no real settings access.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $repo ('.test-explorer-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($fixture)
try {
    Copy-Item -LiteralPath (Join-Path $repo 'Open-ICloudFolderSetup.ps1') -Destination $fixture
    @'
function Invoke-ICloudFolders {
    param([switch]$Apply)
    $phase = if ($Apply) { 'apply' } else { 'preview' }
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'calls.txt') -Value $phase
    $mode = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'mode.txt')
    if ($mode -eq ($phase + '-fails')) { throw 'Injected launcher failure' }
}
Export-ModuleMember -Function Invoke-ICloudFolders
'@ | Set-Content -LiteralPath (Join-Path $fixture 'ICloudFolders.psm1') -Encoding UTF8
    $cases = @(
        @{Name='cancel';Input='';Mode='ok';ExpectedCalls='preview';Exit=0},
        @{Name='explicit apply';Input='APPLY';Mode='ok';ExpectedCalls='preview,apply';Exit=0},
        @{Name='other input cancels';Input='yes';Mode='ok';ExpectedCalls='preview';Exit=0},
        @{Name='preview failure stops';Input='APPLY';Mode='preview-fails';ExpectedCalls='preview';Exit=1},
        @{Name='apply failure reported';Input='APPLY';Mode='apply-fails';ExpectedCalls='preview,apply';Exit=1}
    )
    foreach ($case in $cases) {
        $calls = Join-Path $fixture 'calls.txt'
        if (Test-Path -LiteralPath $calls) { Remove-Item -LiteralPath $calls }
        Set-Content -LiteralPath (Join-Path $fixture 'mode.txt') -Value $case.Mode
        $processInfo = New-Object Diagnostics.ProcessStartInfo
        $processInfo.FileName = 'powershell.exe'
        $processInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $fixture 'Open-ICloudFolderSetup.ps1') + '"'
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true
        $processInfo.RedirectStandardInput = $true
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($processInfo)
        $process.StandardInput.WriteLine($case.Input)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $actualCalls = (Get-Content -LiteralPath $calls) -join ','
        if ($process.ExitCode -ne $case.Exit -or $actualCalls -cne $case.ExpectedCalls) {
            throw "Launcher case '$($case.Name)' failed: exit=$($process.ExitCode), calls=$actualCalls, output=$stdout $stderr"
        }
        $process.Dispose()
        Write-Host "PASS: $($case.Name)"
    }
    Write-Host '5 Explorer launcher checks passed; no user-folder settings accessed.'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith([IO.Path]::GetFullPath($repo).TrimEnd('\') + '\.test-explorer-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
