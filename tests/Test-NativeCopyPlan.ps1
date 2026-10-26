#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkerPath)
$ErrorActionPreference = 'Stop'
$WorkerPath = (Resolve-Path -LiteralPath $WorkerPath).Path
if (-not $env:ICLOUD_TEST_DESKTOP) {
    & (Join-Path $PSScriptRoot 'Invoke-HiddenDesktop.ps1') -ScriptPath $PSCommandPath -Parameters @{ WorkerPath = $WorkerPath } -TimeoutSeconds 120
    return
}
if (& (Join-Path $PSScriptRoot 'Enter-TestDesktop.ps1') -ScriptPath $PSCommandPath) { return }

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Worker([string]$Request) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $WorkerPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $bytes = [Text.Encoding]::UTF8.GetBytes($Request)
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Native copy-plan worker timed out.' }
        Assert ($process.ExitCode -eq 0) ('Worker exited with code ' + $process.ExitCode + ': ' + $stderr.Result)
        Assert ($stderr.Result -eq '') ('Worker wrote to stderr: ' + $stderr.Result)
        return @($stdout.Result -split '\r?\n' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
    } finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) ('ICloudNativeCopyPlan-' + [guid]::NewGuid().ToString('N'))
$sourceRoot = Join-Path $fixture 'source'
$destinationRoot = Join-Path $fixture 'destination'
$sourceFile = Join-Path $sourceRoot 'known-vector.txt'
$destinationFile = Join-Path $destinationRoot 'known-vector.txt'
$expectedContent = 'abc'
$expectedHash = 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
$null = [IO.Directory]::CreateDirectory($sourceRoot)
try {
    [IO.File]::WriteAllText($sourceFile, $expectedContent, [Text.Encoding]::ASCII)
    $request = [ordered]@{
        version = 1
        operation = 'plan'
        source = $sourceRoot
        destination = $destinationRoot
    } | ConvertTo-Json -Compress

    $records = @(Invoke-Worker $request)
    Assert ($records.Count -ge 3 -and $records[-1].type -eq 'result' -and $records[-1].ok) 'Worker omitted a successful terminal result.'
    $entries = @($records | Where-Object { $_.type -ceq 'entry' })
    $summary = @($records | Where-Object { $_.type -ceq 'summary' })
    Assert ($entries.Count -eq 2 -and $summary.Count -eq 1 -and $summary[0].entries -eq 2) 'Worker returned an unexpected copy-plan shape.'
    $fileEntry = @($entries | Where-Object { $_.entry.source -ceq $sourceFile })
    Assert ($fileEntry.Count -eq 1 -and $fileEntry[0].entry.hash -ceq $expectedHash) 'Windows CNG hash differs from the expected SHA-256 value.'
    Assert ($fileEntry[0].entry.action -ceq 'Copy') 'Read-only planning returned an unexpected file action.'
    Assert ([IO.File]::ReadAllText($sourceFile) -ceq $expectedContent) 'Planning changed the source file.'
    Assert (-not [IO.Directory]::Exists($destinationRoot)) 'Read-only planning created the destination directory.'

    $null = [IO.Directory]::CreateDirectory($destinationRoot)
    [IO.File]::WriteAllText($destinationFile, $expectedContent, [Text.Encoding]::ASCII)
    $identicalRecords = @(Invoke-Worker $request)
    $identicalEntries = @($identicalRecords | Where-Object { $_.type -ceq 'entry' })
    $identicalFile = @($identicalEntries | Where-Object { $_.entry.source -ceq $sourceFile })
    Assert ($identicalRecords[-1].type -ceq 'result' -and $identicalRecords[-1].ok) 'Identical-file plan omitted a successful terminal result.'
    Assert ($identicalFile.Count -eq 1 -and $identicalFile[0].entry.hash -ceq $expectedHash -and $identicalFile[0].entry.action -ceq 'SkipIdentical') 'Native planning failed to recognize an identical destination.'
    Assert ([IO.File]::ReadAllText($sourceFile) -ceq $expectedContent -and [IO.File]::ReadAllText($destinationFile) -ceq $expectedContent) 'Planning changed fixture contents.'
    'PASS: native copy plan uses Windows CNG SHA-256, recognizes identical files, and does not copy'
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixture)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    Assert ($resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolvedFixture).StartsWith('ICloudNativeCopyPlan-', [StringComparison]::Ordinal)) 'Refusing to remove a fixture outside its unique temp directory.'
    if ([IO.Directory]::Exists($resolvedFixture)) { [IO.Directory]::Delete($resolvedFixture, $true) }
}
