#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param([ValidateSet('Start','Check','Cleanup')][string]$Mode='Check', [string]$StatePath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
if (-not $StatePath) { $StatePath=Join-Path $repo '.local\sync-verification.json' }
if ($Mode -eq 'Start') {
    if (Test-Path -LiteralPath $StatePath) { throw 'A round-trip session already exists. Check or clean it up before starting another.' }
    $docs=[Environment]::GetFolderPath('MyDocuments')
    if (-not (Test-Path -LiteralPath $docs -PathType Container)) { throw 'The current Windows Documents folder is unavailable.' }
    Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force
    $module=Get-Module ICloudFolders
    $registered=@(& $module { Get-RegisteredICloudRoots })
    if (@($registered | Where-Object { (Join-Path $_ 'Documents') -ieq $docs }).Count -eq 0) { throw 'Documents does not match a registered iCloud root.' }
    $token=[guid]::NewGuid().ToString('N')
    $name='ICloudFolderSetup-SyncTest-'+$token.Substring(0,10)+'-upload.txt'
    $path=Join-Path $docs $name
    if (-not $PSCmdlet.ShouldProcess($path,'Create a small iCloud round-trip verification file')) { return }
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $writer=New-Object IO.StreamWriter($stream)
        $writer.WriteLine('iCloud folder setup verification')
        $writer.WriteLine('Token: '+$token)
        $writer.WriteLine('Rename this file from -upload.txt to -returned.txt on iCloud.com or another device.')
        $writer.Flush()
    } finally { if ($writer) { $writer.Dispose() } else { $stream.Dispose() } }
    $null=[IO.Directory]::CreateDirectory((Split-Path ([IO.Path]::GetFullPath($StatePath)) -Parent))
    [pscustomobject]@{Path=$path;FileName=$name;ReturnPath=(Join-Path $docs $name.Replace('-upload.txt','-returned.txt'));ReturnName=$name.Replace('-upload.txt','-returned.txt');Token=$token;Sha256=(Get-FileHash -LiteralPath $path).Hash;CreatedUtc=[DateTime]::UtcNow.ToString('o');Verified=$false} |
        ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}
if (-not (Test-Path -LiteralPath $StatePath)) { throw 'No sync session exists. Use -Mode Start.' }
$state=Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
$docs=[Environment]::GetFolderPath('MyDocuments')
if ($state.Token -notmatch '^[a-f0-9]{32}$' -or $state.FileName -cne ('ICloudFolderSetup-SyncTest-'+$state.Token.Substring(0,10)+'-upload.txt') -or $state.ReturnName -cne $state.FileName.Replace('-upload.txt','-returned.txt') -or [IO.Path]::GetFullPath($state.Path) -ine (Join-Path $docs $state.FileName) -or [IO.Path]::GetFullPath($state.ReturnPath) -ine (Join-Path $docs $state.ReturnName)) { throw 'Round-trip session paths or token are invalid for this account.' }
if ($Mode -eq 'Cleanup') {
    foreach ($file in @($state.Path,$state.ReturnPath)) {
        if (Test-Path -LiteralPath $file) {
            if ((Get-FileHash -LiteralPath $file).Hash -ine $state.Sha256) { throw 'Test file content changed; automatic cleanup refused.' }
            if ($PSCmdlet.ShouldProcess($file,'Delete this round-trip test file (deletion will sync)')) { Remove-Item -LiteralPath $file }
        }
    }
    if (-not (Test-Path -LiteralPath $state.Path) -and -not (Test-Path -LiteralPath $state.ReturnPath) -and $PSCmdlet.ShouldProcess($StatePath,'Remove completed local sync session')) { Remove-Item -LiteralPath $StatePath }
    return
}
$returned=Test-Path -LiteralPath $state.ReturnPath -PathType Leaf
$contentMatches=$returned -and (Get-FileHash -LiteralPath $state.ReturnPath).Hash -ieq $state.Sha256
[pscustomobject]@{ UploadFile=$state.FileName; RenameRemotelyTo=$state.ReturnName; ReturnDetected=$returned; ContentUnchanged=$contentMatches; Proof='A matching return is meaningful only if the rename was performed on iCloud.com or another device; this script never performs that rename.' }
if ($returned -and -not $contentMatches) { throw 'Returned file content does not match the upload.' }
