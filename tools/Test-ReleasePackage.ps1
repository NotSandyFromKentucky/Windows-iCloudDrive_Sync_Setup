#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive,[switch]$PassThru)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'ReleaseInputs.psm1') -Force
$Archive=(Resolve-Path -LiteralPath $Archive).Path
$folder=Split-Path $Archive -Parent
$checksum=(Get-Content -LiteralPath (Join-Path $folder 'SHA256SUMS.txt') -Raw).Trim()
if($checksum -notmatch '^([a-f0-9]{64})  (.+)$' -or $Matches[2] -cne [IO.Path]::GetFileName($Archive) -or (Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant() -cne $Matches[1]){throw 'Archive checksum mismatch.'}
$scratch=Join-Path $folder ('.verify-'+[guid]::NewGuid().ToString('N'))
try{
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
    try{
        $entryNames=@($zip.Entries | ForEach-Object {$_.FullName.Replace('\','/')})
        $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($name in $entryNames){
            if($name -notmatch '^Windows-iCloudDrive_Sync_Setup-v[0-9]+\.[0-9]+\.[0-9]+(?:-win-(?:x64|arm64))?/[A-Za-z0-9_./-]+$' -or $name -match '(^|/)\.\.?(/|$)' -or -not $seen.Add($name)){throw 'Unsafe or unexpected ZIP entries.'}
        }
        $prefixes=@($entryNames | ForEach-Object {($_ -split '/')[0]} | Select-Object -Unique)
        if($prefixes.Count -ne 1 -or $entryNames.Count -gt 4200){throw 'Unsafe or unexpected ZIP entries.'}
        $manifestEntry=$zip.GetEntry($prefixes[0]+'/manifest.json')
        if($null -eq $manifestEntry -or $manifestEntry.Length -gt 4MB){throw 'Missing or oversized package manifest.'}
        $reader=New-Object IO.StreamReader($manifestEntry.Open())
        try{$manifest=$reader.ReadToEnd() | ConvertFrom-Json}finally{$reader.Dispose()}
        if($manifest.Commit -notmatch '^[a-f0-9]{40}$' -or $manifest.Version -notmatch '^\d+\.\d+\.\d+$' -or $manifest.Signed -isnot [bool]){throw 'Invalid package manifest.'}
        # Use the allowlist belonging to the declared immutable source when it is
        # locally available, preserving validation of historical script releases.
        $inputJson=$null
        if(Get-Command git -ErrorAction SilentlyContinue){
            $inputJson=& git -c "safe.directory=$repo" -C $repo show ($manifest.Commit+':build/ReleaseFiles.json') 2>$null
            if($LASTEXITCODE -ne 0){$inputJson=$null}
        }
        if($inputJson){$policy=Read-ReleaseInputs ($inputJson | Out-String)}
        else{$policy=Read-ReleaseInputs (Get-Content -LiteralPath (Join-Path $repo 'build/ReleaseFiles.json') -Raw)}
        $native=$null -ne $policy.NativeUI
        $runtime=if($manifest.PSObject.Properties['RuntimeIdentifier']){[string]$manifest.RuntimeIdentifier}else{''}
        if($native -and $runtime -notin @('win-x64','win-arm64')){throw 'Native package has no valid runtime identifier.'}
        if(-not $native -and $runtime){throw 'Unexpected native runtime for a script-only source.'}
        $files=@($policy.Files)
        if($native){
            $nativeFiles=@($manifest.NativeFiles)
            if(-not $nativeFiles.Count -or $nativeFiles.Count -gt $policy.NativeUI.MaximumFiles){throw 'Invalid native payload file count.'}
            foreach($path in $nativeFiles){if($path -isnot [string] -or $path -notmatch '^NativeUI/[A-Za-z0-9_./-]+$' -or $path -match '(^|/)\.\.?(/|$)'){throw 'Unsafe native payload path.'}}
            $files+=@($nativeFiles)
        }
        $expectedRoot='Windows-iCloudDrive_Sync_Setup-v'+$manifest.Version+$(if($native){'-'+$runtime}else{''})
        if($prefixes[0] -cne $expectedRoot -or [IO.Path]::GetFileName($Archive) -cne ($expectedRoot+'.zip')){throw 'Package filename or root folder is invalid.'}
        $relative=@($entryNames | ForEach-Object {$_.Substring($_.IndexOf('/')+1)})
        if(@(Compare-Object @(@($files)+'manifest.json' | Sort-Object) @($relative | Sort-Object)).Count){throw 'ZIP entries differ from the package allowlist.'}
        $maximum=if($native){[long]$policy.NativeUI.MaximumExpandedBytes+20MB}else{20MB}
        if(($zip.Entries | Measure-Object Length -Sum).Sum -gt $maximum){throw 'Package exceeds its expanded size limit.'}
    }finally{$zip.Dispose()}
    # No archive content is extracted until names, counts, sizes and policy pass.
    Expand-Archive -LiteralPath $Archive -DestinationPath $scratch
    $package=Join-Path $scratch $expectedRoot
    if($manifest.Version -cne (Get-Content -LiteralPath (Join-Path $package 'VERSION') -Raw).Trim()){throw 'Package version differs from VERSION.'}
    $actual=@(Get-ChildItem -LiteralPath $package -Recurse -File | ForEach-Object {$_.FullName.Substring($package.Length+1).Replace('\','/')})
    if(@(Compare-Object @(@($files)+'manifest.json' | Sort-Object) @($actual | Sort-Object)).Count){throw 'Unexpected package files.'}
    if(@($manifest.Files).Count -ne $files.Count){throw 'Manifest file count differs.'}
    foreach($file in $files){
        $entry=@($manifest.Files | Where-Object {$_.Path -ceq $file})
        if($entry.Count -ne 1 -or $entry[0].SHA256 -notmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath (Join-Path $package $file)).Hash.ToLowerInvariant() -cne $entry[0].SHA256){throw "Manifest mismatch: $file"}
    }
    if($native){
        $nativeActual=@(Assert-NativePayload -Directory (Join-Path $package 'NativeUI') -Policy $policy.NativeUI -RuntimeIdentifier $runtime | ForEach-Object {'NativeUI/'+$_})
        if(@(Compare-Object @($nativeFiles | Sort-Object) @($nativeActual | Sort-Object)).Count){throw 'Native payload manifest differs.'}
    }
    foreach($file in @(Get-ChildItem -LiteralPath $package -Recurse -File)){
        if($file.Extension -in @('.ps1','.psm1')){
            $tokens=$null;$errors=$null
            $null=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
            if($errors.Count){throw "Packaged syntax error: $($file.Name)"}
        }
        if($manifest.Signed -and ($file.Extension -in @('.ps1','.psm1') -or ($native -and $file.Name -in @('ICloudFolderSetup.exe','ICloudFolderSetup.dll')))){
            $signature=Get-AuthenticodeSignature -LiteralPath $file.FullName
            if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ine $manifest.CertificateThumbprint){throw 'Packaged signature is invalid.'}
        }
    }
    $nativeChecks=if($native){', native architecture/dependencies'}else{''}
    Write-Host "Package verified: checksum, $($files.Count) files$nativeChecks, manifest, syntax and declared signature state."
    if($PassThru){[pscustomobject]@{Version=$manifest.Version;Commit=$manifest.Commit;Signed=$manifest.Signed;FileCount=$files.Count;RuntimeIdentifier=$runtime}}
}finally{
    $resolved=[IO.Path]::GetFullPath($scratch)
    if($resolved.StartsWith($folder.TrimEnd('\')+'\.verify-',[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
