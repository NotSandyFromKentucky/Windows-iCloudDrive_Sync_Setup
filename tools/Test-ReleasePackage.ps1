#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive, [switch]$PassThru)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$Archive = (Resolve-Path -LiteralPath $Archive).Path
$folder = Split-Path $Archive -Parent
$checksum = (Get-Content -LiteralPath (Join-Path $folder 'SHA256SUMS.txt') -Raw).Trim()
if ($checksum -notmatch '^([a-f0-9]{64})  (.+)$' -or $Matches[2] -cne [IO.Path]::GetFileName($Archive) -or (Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant() -cne $Matches[1]) { throw 'Archive checksum mismatch.' }
$scratch = Join-Path $folder ('.verify-' + [guid]::NewGuid().ToString('N'))
try {
    # Reject unexpected/traversing ZIP entries before extraction can write anything.
    $files = @(Get-Content -LiteralPath (Join-Path $repo 'build\ReleaseFiles.json') -Raw | ConvertFrom-Json)
    $files = @($files | ForEach-Object { $_ })
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        $entryNames = @($zip.Entries | ForEach-Object { $_.FullName.Replace('\','/') })
        if ($entryNames.Count -ne $files.Count + 1 -or @($entryNames | Where-Object { $_ -notmatch '^Windows-iCloudDrive_Sync_Setup-v[0-9]+\.[0-9]+\.[0-9]+/[A-Za-z0-9_./-]+$' -or $_ -match '(^|/)\.\.?(/|$)' }).Count) { throw 'Unsafe or unexpected ZIP entries.' }
        $prefixes = @($entryNames | ForEach-Object { ($_ -split '/')[0] } | Select-Object -Unique)
        $relative = @($entryNames | ForEach-Object { $_.Substring($_.IndexOf('/')+1) } | Sort-Object)
        if ($prefixes.Count -ne 1 -or @($relative | Select-Object -Unique).Count -ne $relative.Count -or @(Compare-Object @(@($files)+'manifest.json' | Sort-Object) $relative).Count) { throw 'ZIP entries differ from the package allowlist.' }
        if (($zip.Entries | Measure-Object -Property Length -Sum).Sum -gt 20MB) { throw 'Package exceeds the expected script-only size limit.' }
    } finally { $zip.Dispose() }
    Expand-Archive -LiteralPath $Archive -DestinationPath $scratch
    $roots = @(Get-ChildItem -LiteralPath $scratch -Force)
    if ($roots.Count -ne 1 -or -not $roots[0].PSIsContainer) { throw 'Expected one top-level package folder.' }
    $package = $roots[0].FullName
    $manifest = Get-Content -LiteralPath (Join-Path $package 'manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.Commit -notmatch '^[a-f0-9]{40}$' -or $manifest.Version -cne (Get-Content -LiteralPath (Join-Path $package 'VERSION') -Raw).Trim()) { throw 'Invalid package version or commit.' }
    if ($roots[0].Name -cne ('Windows-iCloudDrive_Sync_Setup-v'+$manifest.Version) -or [IO.Path]::GetFileName($Archive) -cne ($roots[0].Name+'.zip') -or $manifest.Signed -isnot [bool]) { throw 'Package filename, root folder or signature declaration is invalid.' }
    $actual = @(Get-ChildItem -LiteralPath $package -Recurse -File | ForEach-Object { $_.FullName.Substring($package.Length+1).Replace('\','/') } | Sort-Object)
    if (@(Compare-Object @(@($files) + 'manifest.json' | Sort-Object) $actual).Count) { throw 'Unexpected package files.' }
    if (@($manifest.Files).Count -ne $files.Count) { throw 'Manifest file count differs.' }
    foreach ($file in $files) {
        $entry = @($manifest.Files | Where-Object { $_.Path -ceq $file })
        if ($entry.Count -ne 1 -or (Get-FileHash -LiteralPath (Join-Path $package $file)).Hash.ToLowerInvariant() -cne $entry[0].SHA256) { throw "Manifest mismatch: $file" }
    }
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $package -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })) {
        $tokens=$null; $errors=$null
        $null=[Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName,[ref]$tokens,[ref]$errors)
        if (@($errors).Count) { throw "Packaged syntax error: $($scriptFile.Name)" }
        if ($manifest.Signed) {
            $signature = Get-AuthenticodeSignature -LiteralPath $scriptFile.FullName
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ine $manifest.CertificateThumbprint) { throw 'Packaged signature is invalid.' }
        }
    }
    Write-Host "Package verified: checksum, $($files.Count) source files, manifest, syntax and declared signature state."
    if ($PassThru) { [pscustomobject]@{ Version=$manifest.Version; Commit=$manifest.Commit; Signed=$manifest.Signed; FileCount=$files.Count } }
} finally {
    $resolved=[IO.Path]::GetFullPath($scratch)
    if ($resolved.StartsWith($folder.TrimEnd('\')+'\.verify-',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
