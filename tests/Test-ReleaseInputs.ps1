#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'tools/ReleaseInputs.psm1') -Force
$json=Get-Content -LiteralPath (Join-Path $repo 'build/ReleaseFiles.json') -Raw
$plain=Read-ReleaseInputs $json
$marked=Read-ReleaseInputs ([string][char]0xFEFF+$json)
if(($plain|ConvertTo-Json -Depth 8 -Compress) -cne ($marked|ConvertTo-Json -Depth 8 -Compress)){throw 'BOM-prefixed release policy changed its parsed inputs.'}
if(@($plain.SourceFiles|Where-Object {$_ -ceq 'ICloudFolders.psm1'}).Count -ne 1){throw 'A runtime module shared with the native build was not emitted exactly once.'}
$duplicateNative=ConvertFrom-Json $json
$duplicateNative.NativeUI.SourceFiles=@($duplicateNative.NativeUI.SourceFiles)+'ICloudFolders.psm1'
$rejected=$false
try{$null=Read-ReleaseInputs ($duplicateNative|ConvertTo-Json -Depth 8 -Compress)}catch{$rejected=$_.Exception.Message -like '*Unsafe or duplicate*'}
if(-not $rejected){throw 'A duplicate native source input was accepted.'}
$caseCollision=ConvertFrom-Json $json
$caseCollision.NativeUI.SourceFiles=@($caseCollision.NativeUI.SourceFiles)+'icloudfolders.psm1'
$rejected=$false
try{$null=Read-ReleaseInputs ($caseCollision|ConvertTo-Json -Depth 8 -Compress)}catch{$rejected=$_.Exception.Message -like '*Unsafe or duplicate*'}
if(-not $rejected){throw 'A case-only runtime/native source collision was accepted.'}
foreach($prefix in @('',([string][char]0xFEFF))){
    $legacy=Read-ReleaseInputs ($prefix+'["VERSION","README.md"]')
    if($legacy.Files.Count -ne 2 -or $null -ne $legacy.NativeUI){throw 'Legacy release input compatibility failed.'}
    $single=Read-ReleaseInputs ($prefix+'["VERSION"]')
    if($single.Files.Count -ne 1 -or $single.Files[0] -cne 'VERSION'){throw 'Single-file legacy release inputs failed.'}
    foreach($invalid in @('["../escape.txt"]','["VERSION","version"]')){
        $rejected=$false
        try{$null=Read-ReleaseInputs ($prefix+$invalid)}catch{$rejected=$_.Exception.Message -like '*Unsafe or duplicate*'}
        if(-not $rejected){throw 'Unsafe release policy was accepted.'}
    }
}
'PASS: BOM-prefixed native/legacy policies preserve inputs, share exact build/runtime paths once and reject collisions/traversal'
