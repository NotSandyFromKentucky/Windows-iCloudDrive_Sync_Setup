#requires -Version 5.1
param([string]$SourceRef='HEAD')
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixture=Join-Path $tempRoot ('ICloudPackageTools-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
function Expect-Failure([scriptblock]$Action,[string]$Pattern){$caught=$null;try{& $Action}catch{$caught=$_.Exception.Message};Assert ($caught -and $caught -like ('*'+$Pattern+'*')) "Expected '$Pattern', received '$caught'"}
try {
    $first=& (Join-Path $repo 'tools\New-ReleasePackage.ps1') -SourceRef $SourceRef -OutputDirectory (Join-Path $fixture 'first')
    & (Join-Path $repo 'tools\Test-ReleasePackage.ps1') -Archive $first.Archive
    Write-Host 'PASS: package checksum, manifest, file allowlist and syntax'
    $second=& (Join-Path $repo 'tools\New-ReleasePackage.ps1') -SourceRef $SourceRef -OutputDirectory (Join-Path $fixture 'second')
    Assert ($first.SHA256 -ceq $second.SHA256) 'Unsigned rebuild of the same source was not byte-identical.'
    Write-Host 'PASS: unsigned builds are reproducible on this runtime'
    $checksums=Join-Path (Split-Path $second.Archive -Parent) 'SHA256SUMS.txt'
    ('0'*64)+'  '+[IO.Path]::GetFileName($second.Archive) | Set-Content -LiteralPath $checksums -Encoding ascii
    Expect-Failure { & (Join-Path $repo 'tools\Test-ReleasePackage.ps1') -Archive $second.Archive } 'checksum mismatch'
    Write-Host 'PASS: changed archive checksum is rejected'
    $malicious=Join-Path $fixture 'unsafe'
    $null=[IO.Directory]::CreateDirectory($malicious)
    $zipPath=Join-Path $malicious ([IO.Path]::GetFileName($first.Archive))
    Copy-Item -LiteralPath $first.Archive -Destination $zipPath
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::Open($zipPath,[IO.Compression.ZipArchiveMode]::Update)
    try {$entry=$zip.CreateEntry('../escape.txt');$stream=$entry.Open();try{$bytes=[Text.Encoding]::ASCII.GetBytes('unsafe');$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}finally{$zip.Dispose()}
    (Get-FileHash -LiteralPath $zipPath).Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($zipPath) | Set-Content -LiteralPath (Join-Path $malicious 'SHA256SUMS.txt') -Encoding ascii
    Expect-Failure { & (Join-Path $repo 'tools\Test-ReleasePackage.ps1') -Archive $zipPath } 'Unsafe or unexpected ZIP entries'
    Assert (@(Get-ChildItem -LiteralPath $fixture -Recurse -Filter escape.txt).Count -eq 0) 'Unsafe archive escaped before validation.'
    Write-Host 'PASS: unsafe ZIP entries are rejected before extraction'
    Expect-Failure { & (Join-Path $repo 'tools\New-ReleasePackage.ps1') -SourceRef $SourceRef -OutputDirectory (Join-Path $fixture 'signing') -SigningCertificateThumbprint ('0'*40) } ''
    $signingDirectory=Join-Path $fixture 'signing'
    Assert (-not(Test-Path -LiteralPath $signingDirectory) -or @(Get-ChildItem -LiteralPath $signingDirectory -Filter *.zip).Count -eq 0) 'Invalid certificate produced a release archive.'
    Write-Host 'PASS: unavailable certificate prevents signing without producing an archive'
    Write-Host '5 release-tool checks passed.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    if($resolved.StartsWith($tempRoot.TrimEnd('\')+'\ICloudPackageTools-',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
