#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$null = Get-Command gh -ErrorAction Stop
& (Join-Path $PSScriptRoot 'Test-ReleasePackage.ps1') -Archive $Archive
$version = (Get-Content -LiteralPath (Join-Path $repo 'VERSION') -Raw).Trim()
$tag = 'v' + $version
$tagCommit = & git -C $repo rev-parse ($tag + '^{commit}')
$headCommit = & git -C $repo rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $tagCommit -cne $headCommit) { throw 'The version tag must exist and point to the checked-out commit.' }
$notes = Get-Content -LiteralPath (Join-Path $repo 'CHANGELOG.md') -Raw
$pattern = '(?ms)^## v' + [regex]::Escape($version) + '\s*\r?\n(.*?)(?=^## |\z)'
if ($notes -notmatch $pattern) { throw 'Changelog section for this version is missing.' }
$body = $Matches[1].Trim()
$folder = Split-Path ([IO.Path]::GetFullPath($Archive)) -Parent
$notesFile = Join-Path $folder 'release-notes.md'
$body | Set-Content -LiteralPath $notesFile -Encoding UTF8
$oldPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
$existing = & gh release view $tag --repo $Repository --json isDraft,assets,url 2>$null
$viewExit=$LASTEXITCODE; $ErrorActionPreference=$oldPreference
if ($viewExit -eq 0) {
    $state = $existing | ConvertFrom-Json
    if (-not $state.isDraft) { throw 'This version is already published; published releases are never overwritten.' }
} else {
    & gh release create $tag --repo $Repository --verify-tag --draft --title "$tag - iCloud folder setup" --notes-file $notesFile
    if ($LASTEXITCODE -ne 0) { throw 'Draft release creation failed.' }
}
$assets = @([IO.Path]::GetFullPath($Archive), (Join-Path $folder 'SHA256SUMS.txt'))
$state = (& gh release view $tag --repo $Repository --json isDraft,assets | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or -not $state.isDraft) { throw 'Draft state check failed.' }
foreach ($file in $assets) {
    $name=[IO.Path]::GetFileName($file)
    if (@($state.assets | Where-Object { $_.name -ceq $name }).Count -eq 0) {
        & gh release upload $tag $file --repo $Repository
        if ($LASTEXITCODE -ne 0) { throw "Asset upload failed: $name" }
    }
}
$download = Join-Path $folder ('.remote-verify-' + [guid]::NewGuid().ToString('N'))
try {
    $null = [IO.Directory]::CreateDirectory($download)
    & gh release download $tag --repo $Repository --dir $download --pattern ([IO.Path]::GetFileName($Archive)) --pattern SHA256SUMS.txt
    if ($LASTEXITCODE -ne 0) { throw 'Remote verification download failed.' }
    foreach ($file in $assets) {
        if ((Get-FileHash -LiteralPath $file).Hash -cne (Get-FileHash -LiteralPath (Join-Path $download ([IO.Path]::GetFileName($file)))).Hash) { throw 'Uploaded release bytes differ; draft retained for inspection.' }
    }
    $state = (& gh release view $tag --repo $Repository --json assets | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or @($state.assets).Count -ne 2) { throw 'Unexpected release assets; draft retained for inspection.' }
    & gh release edit $tag --repo $Repository --notes-file $notesFile --draft=false --latest
    if ($LASTEXITCODE -ne 0) { throw 'Publishing failed; inspect the draft.' }
    $state = (& gh release view $tag --repo $Repository --json isDraft,url | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0 -or $state.isDraft) { throw 'Release publication was not confirmed.' }
    Write-Host "Published and verified: $($state.url)"
} finally {
    $resolved=[IO.Path]::GetFullPath($download)
    if ($resolved.StartsWith($folder.TrimEnd('\')+'\.remote-verify-',[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
