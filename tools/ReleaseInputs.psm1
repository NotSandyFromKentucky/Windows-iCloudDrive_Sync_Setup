#requires -Version 5.1
Set-StrictMode -Version Latest
function Read-ReleaseInputs {
    param([Parameter(Mandatory)][string]$Json)
    # git show preserves a UTF-8 file's leading BOM in its text output. Unlike
    # file readers, PowerShell 7's JSON parser does not consume that marker.
    $normalized=$Json.TrimStart([char]0xFEFF)
    $inputData=$normalized | ConvertFrom-Json
    # PowerShell 7 unwraps single-item arrays at the pipeline boundary.
    # Identify the legacy JSON shape before relying on the parsed CLR type.
    if($normalized.TrimStart().StartsWith('[')){$files=@($inputData);$native=$null}
    else{
        if($inputData.SchemaVersion -ne 2){throw 'Unsupported release input schema.'}
        $files=@($inputData.Files);$native=$inputData.NativeUI
    }
    $all=@($files)
    if($null -ne $native){
        if($native.DefaultRuntimeIdentifier -notin @('win-x64','win-arm64') -or $native.Project -notlike 'ui/*.csproj' -or $native.SourceFiles -notcontains $native.Project -or $native.SourceFiles -notcontains 'global.json' -or $native.SourceFiles -notcontains 'ui/ICloudFolderSetup/packages.lock.json'){throw 'Invalid native release inputs.'}
        $all+=@($native.SourceFiles)
        if($native.MaximumFiles -lt 1 -or $native.MaximumFiles -gt 4096 -or $native.MaximumExpandedBytes -lt 1 -or $native.MaximumExpandedBytes -gt 1GB){throw 'Invalid native package limits.'}
        foreach($file in $native.RequiredFiles){if($file -notmatch '^[A-Za-z0-9_.-]+$' -or $file -match '^\.') {throw 'Unsafe required native filename.'}}
    }
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($file in $all){
        if($file -isnot [string] -or $file -notmatch '^[A-Za-z0-9_./-]+$' -or $file -match '(^|/)\.\.?(/|$)' -or [IO.Path]::IsPathRooted($file) -or -not $seen.Add($file)){throw 'Unsafe or duplicate release input path.'}
    }
    if(-not $files.Count){throw 'Empty release file list.'}
    [pscustomobject]@{Files=$files;NativeUI=$native;SourceFiles=$all}
}
function Assert-NativePayload {
    param([Parameter(Mandatory)][string]$Directory,[Parameter(Mandatory)]$Policy,[Parameter(Mandatory)][ValidateSet('win-x64','win-arm64')][string]$RuntimeIdentifier)
    $files=@(Get-ChildItem -LiteralPath $Directory -Recurse -File)
    if($files.Count -gt $Policy.MaximumFiles -or ($files | Measure-Object Length -Sum).Sum -gt $Policy.MaximumExpandedBytes){throw 'Native payload exceeds its limits.'}
    foreach($file in $Policy.RequiredFiles){if(-not(Test-Path -LiteralPath (Join-Path $Directory $file) -PathType Leaf)){throw "Native payload is incomplete: $file"}}
    foreach($file in $files){
        $relative=$file.FullName.Substring($Directory.TrimEnd('\').Length+1).Replace('\','/')
        if($relative -notmatch '^[A-Za-z0-9_./-]+$' -or $relative -match '(^|/)\.\.?(/|$)' -or $file.Extension -in @('.ps1','.psm1','.cmd','.bat','.pdb','.cs','.csproj')){throw "Unexpected native payload file: $relative"}
        if($file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Native payload contains a reparse point.'}
    }
    foreach($file in @('ICloudFolderSetup.exe','Microsoft.ui.xaml.dll')){
        $stream=[IO.File]::OpenRead((Join-Path $Directory $file));$reader=New-Object IO.BinaryReader($stream)
        try{
            if($reader.ReadUInt16() -ne 0x5A4D){throw 'Invalid native executable header.'}
            $stream.Position=0x3C;$offset=$reader.ReadUInt32();$stream.Position=$offset
            if($reader.ReadUInt32() -ne 0x4550){throw 'Invalid PE signature.'}
            $expected=if($RuntimeIdentifier -eq 'win-x64'){0x8664}else{0xAA64}
            if($reader.ReadUInt16() -ne $expected){throw "Native payload architecture mismatch: $file"}
        }finally{$reader.Dispose()}
    }
    $deps=Get-Content -LiteralPath (Join-Path $Directory 'ICloudFolderSetup.deps.json') -Raw | ConvertFrom-Json
    if($deps.runtimeTarget.name -notlike ('*/'+$RuntimeIdentifier)){throw 'Native dependency graph does not match the requested architecture.'}
    @($files | ForEach-Object {$_.FullName.Substring($Directory.TrimEnd('\').Length+1).Replace('\','/')})
}
Export-ModuleMember -Function Read-ReleaseInputs,Assert-NativePayload
