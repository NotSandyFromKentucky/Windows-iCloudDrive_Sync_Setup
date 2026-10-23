#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')][string]$SourceRef = 'HEAD',
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$Version,
    [string]$SigningCertificateThumbprint,
    [ValidateSet('win-x64','win-arm64')][string]$RuntimeIdentifier,
    [ValidatePattern('^https?://')][string]$TimestampServer = 'http://timestamp.digicert.com'
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'ReleaseInputs.psm1') -Force
if (-not $Version) { $Version = (Get-Content -LiteralPath (Join-Path $repo 'VERSION') -Raw).Trim() }
$defaultOutput=-not $OutputDirectory
if ($defaultOutput) { $OutputDirectory = Join-Path $repo ('.local\packages\v' + $Version) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$gitOptions = @('-c',"safe.directory=$repo",'-C',$repo)
$sourceVersion = (& git @gitOptions show ($SourceRef + ':VERSION'))
if ($LASTEXITCODE -ne 0 -or $sourceVersion.Trim() -cne $Version) { throw 'Requested version does not match VERSION at the source commit.' }
$commit = & git @gitOptions rev-parse ($SourceRef + '^{commit}')
if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$') { throw 'Source commit could not be resolved.' }
$fileJson = & git @gitOptions show ($SourceRef + ':build/ReleaseFiles.json')
if ($LASTEXITCODE -ne 0) { throw 'Release file allowlist is missing at source commit.' }
$inputs=Read-ReleaseInputs ($fileJson | Out-String)
$files=@($inputs.Files)
$native=$inputs.NativeUI
if($native -and -not $RuntimeIdentifier){$RuntimeIdentifier=$native.DefaultRuntimeIdentifier}
if(-not $native -and $RuntimeIdentifier){throw 'This source commit has no native release target.'}
if($native -and $defaultOutput){$OutputDirectory=[IO.Path]::GetFullPath((Join-Path $repo ('.local\packages\v'+$Version+'-'+$RuntimeIdentifier)))}
$certificate=$null
if($SigningCertificateThumbprint){
    $certificate=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$SigningCertificateThumbprint)
    if(-not $certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date) -or $certificate.NotBefore -gt (Get-Date) -or @($certificate.EnhancedKeyUsageList | Where-Object {$_.ObjectId -eq '1.3.6.1.5.5.7.3.3'}).Count -eq 0){throw 'A currently valid code-signing certificate with its private key is required.'}
}
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$scratchParent=if($native){[IO.Path]::GetFullPath([IO.Path]::GetTempPath())}else{$OutputDirectory}
$scratchPrefix=if($native){'ICloudBuild-'}else{'.build-'}
$scratch = Join-Path $scratchParent ($scratchPrefix + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($scratch)
try {
    $folderName = 'Windows-iCloudDrive_Sync_Setup-v' + $Version
    if($native){$folderName+='-'+$RuntimeIdentifier}
    $rawArchive = Join-Path $scratch 'source.zip'
    $sourceFiles=@((@($inputs.SourceFiles)+@('build/ReleaseFiles.json')) | Select-Object -Unique)
    & git @gitOptions archive --format=zip ('--output=' + $rawArchive) $commit -- @sourceFiles
    if ($LASTEXITCODE -ne 0) { throw 'git archive failed.' }
    $source=Join-Path $scratch 'source'
    Expand-Archive -LiteralPath $rawArchive -DestinationPath $source
    $actual=@(Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object {$_.FullName.Substring($source.Length+1).Replace('\','/')})
    if(@(Compare-Object @($sourceFiles | Sort-Object) @($actual | Sort-Object)).Count){throw 'Archive differs from the source allowlist.'}
    $package=Join-Path (Join-Path $scratch 'stage') $folderName
    $null=[IO.Directory]::CreateDirectory($package)
    foreach($file in $files){
        $target=Join-Path $package $file
        $null=[IO.Directory]::CreateDirectory((Split-Path $target -Parent))
        Copy-Item -LiteralPath (Join-Path $source $file) -Destination $target
    }
    $nativeFiles=@()
    if($native){
        $nativeOutput=Join-Path $package 'NativeUI'
        $platform=if($RuntimeIdentifier -eq 'win-arm64'){'ARM64'}else{'x64'}
        Push-Location $source
        try{
            & dotnet publish $native.Project -c Release ('-p:Platform='+$platform) -r $RuntimeIdentifier --self-contained true '-p:RestoreLockedMode=true' '-p:ContinuousIntegrationBuild=true' '-p:DebugType=none' '-p:DebugSymbols=false' ('-p:Version='+$Version) ('-p:PathMap='+$source+'=/_/') -o $nativeOutput --nologo | Out-Host
            if($LASTEXITCODE -ne 0){throw 'Native publish from committed source failed.'}
        }finally{Pop-Location}
        $nativeFiles=@(Assert-NativePayload -Directory $nativeOutput -Policy $native -RuntimeIdentifier $RuntimeIdentifier | ForEach-Object {'NativeUI/'+$_})
        $files+=@($nativeFiles)
    }
    $signed = $false
    if ($SigningCertificateThumbprint) {
        foreach ($scriptFile in @(Get-ChildItem -LiteralPath $package -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -or ($native -and $_.Name -in @('ICloudFolderSetup.exe','ICloudFolderSetup.dll')) })) {
            $signature = Set-AuthenticodeSignature -LiteralPath $scriptFile.FullName -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer
            if ($signature.Status -ne 'Valid') { throw "Signing failed for $($scriptFile.Name): $($signature.Status)" }
        }
        $signed = $true
    }
    $hashes = foreach ($file in @($files | Sort-Object)) {
        [pscustomobject]@{ Path=$file; SHA256=(Get-FileHash -LiteralPath (Join-Path $package $file) -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    [pscustomobject]@{ Version=$Version; Commit=$commit; Signed=$signed; CertificateThumbprint=$(if($signed){$SigningCertificateThumbprint}else{$null}); RuntimeIdentifier=$(if($native){$RuntimeIdentifier}else{$null}); NativeFiles=$nativeFiles; Files=@($hashes) } |
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
    if ($resolved.StartsWith($scratchParent.TrimEnd('\') + '\'+$scratchPrefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
