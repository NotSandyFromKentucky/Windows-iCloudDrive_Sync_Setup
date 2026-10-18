#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')][string]$SourceRef = 'HEAD',
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,
    [string]$SigningCertificateThumbprint,
    [ValidatePattern('^https?://')][string]$TimestampServer = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not $Version) { $Version = (Get-Content -LiteralPath (Join-Path $repo 'VERSION') -Raw).Trim() }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo ('.local\packages\v' + $Version) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$gitOptions = @('-c',"safe.directory=$repo",'-C',$repo)
$sourceVersion = (& git @gitOptions show ($SourceRef + ':VERSION'))
if ($LASTEXITCODE -ne 0 -or $sourceVersion.Trim() -cne $Version) { throw 'Requested version does not match VERSION at the source commit.' }
$commit = & git @gitOptions rev-parse ($SourceRef + '^{commit}')
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$') { throw 'Source commit could not be resolved.' }
$fileJson = & git @gitOptions show ($SourceRef + ':build/ReleaseFiles.json')
if ($LASTEXITCODE -ne 0) { throw 'Release file allowlist is missing at source commit.' }
$files = @($fileJson | Out-String | ConvertFrom-Json)
$files = @($files | ForEach-Object { $_ })
foreach ($file in $files) { if ($file -notmatch '^[A-Za-z0-9_./-]+$' -or $file -match '(^|/)\.\.(/|$)' -or $file.StartsWith('/')) { throw 'Unsafe release file path.' } }
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$scratch = Join-Path $OutputDirectory ('.build-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($scratch)
try {
    $folderName = 'Windows-iCloudDrive_Sync_Setup-v' + $Version
    $rawArchive = Join-Path $scratch 'source.zip'
    & git @gitOptions archive --format=zip ('--prefix=' + $folderName + '/') ('--output=' + $rawArchive) $commit -- @files
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed.' }
    $stage = Join-Path $scratch 'stage'
    Expand-Archive -LiteralPath $rawArchive -DestinationPath $stage
    $package = Join-Path $stage $folderName
    $actual = @(Get-ChildItem -LiteralPath $package -Recurse -File | ForEach-Object { $_.FullName.Substring($package.Length+1).Replace('\','/') })
    if (@(Compare-Object @($files | Sort-Object) @($actual | Sort-Object)).Count) { throw 'Archive differs from the source allowlist.' }
    $signed = $false
    if ($SigningCertificateThumbprint) {
        $certificate = Get-Item -LiteralPath ('Cert:\CurrentUser\My\' + $SigningCertificateThumbprint)
        if (-not $certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date) -or $certificate.NotBefore -gt (Get-Date) -or @($certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' }).Count -eq 0) { throw 'A currently valid code-signing certificate with its private key is required.' }
        foreach ($scriptFile in @(Get-ChildItem -LiteralPath $package -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })) {
            $signature = Set-AuthenticodeSignature -LiteralPath $scriptFile.FullName -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer
            if ($signature.Status -ne 'Valid') { throw "Signing failed for $($scriptFile.Name): $($signature.Status)" }
        }
        $signed = $true
    }
    $hashes = foreach ($file in @($files | Sort-Object)) {
        [pscustomobject]@{ Path=$file; SHA256=(Get-FileHash -LiteralPath (Join-Path $package $file) -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    [pscustomobject]@{ Version=$Version; Commit=$commit; Signed=$signed; CertificateThumbprint=$(if($signed){$SigningCertificateThumbprint}else{$null}); Files=@($hashes) } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $package 'manifest.json') -Encoding UTF8
    $archive = Join-Path $OutputDirectory ($folderName + '.zip')
    if (Test-Path -LiteralPath $archive) { throw "Archive already exists; choose a new output directory: $archive" }
    # Stable ordering and commit timestamps make unsigned rebuilds byte-identical
    # on the same runtime, so an interrupted draft upload can be resumed safely.
    $epoch = & git @gitOptions show -s --format=%ct $commit
    if ($LASTEXITCODE -ne 0) { throw 'Commit timestamp lookup failed.' }
    $timestamp = [DateTimeOffset]::Parse('1970-01-01T00:00:00Z').AddSeconds([long]$epoch)
    if ($timestamp.Year -lt 1980 -or $timestamp.Year -gt 2107) { throw 'Commit timestamp is outside the ZIP timestamp range.' }
    Add-Type -AssemblyName System.IO.Compression
    $archiveStream = [IO.File]::Open($archive,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $zip = $null
    try {
        $zip = New-Object IO.Compression.ZipArchive($archiveStream,[IO.Compression.ZipArchiveMode]::Create,$true)
        foreach ($file in @(@($files) + 'manifest.json' | Sort-Object)) {
            $entry = $zip.CreateEntry($folderName + '/' + $file,[IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $timestamp
            $inputStream = [IO.File]::OpenRead((Join-Path $package $file))
            $outputStream = $entry.Open()
            try { $inputStream.CopyTo($outputStream) } finally { $inputStream.Dispose(); $outputStream.Dispose() }
        }
    } finally { if ($zip) { $zip.Dispose() }; $archiveStream.Dispose() }
    $digest = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $digest + '  ' + [IO.Path]::GetFileName($archive) | Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') -Encoding ascii
    [pscustomobject]@{ Archive=$archive; SHA256=$digest; Commit=$commit; Signed=$signed }
} finally {
    $resolved = [IO.Path]::GetFullPath($scratch)
    if ($resolved.StartsWith($OutputDirectory.TrimEnd('\') + '\.build-', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
