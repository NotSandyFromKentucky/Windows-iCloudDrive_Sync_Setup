#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $repo ('.test-folder-definitions-'+[guid]::NewGuid().ToString('N'))
$output=Join-Path $fixture 'folder-definitions.json'
$null=[IO.Directory]::CreateDirectory($fixture)
$module=Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force -PassThru
function Assert($condition,$message){if(-not $condition){throw $message}}
try{
    $expected=@(& $module {Get-ICloudFolderDefinitions})
    & (Join-Path $repo 'tools/Generate-FolderDefinitions.ps1') -OutputPath $output
    Assert (Test-Path -LiteralPath $output -PathType Leaf) 'Build generator did not write the folder metadata resource.'
    $bytes=[IO.File]::ReadAllBytes($output)
    $hasUtf8Bom=$bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $json=[IO.File]::ReadAllText($output)
    Assert ($bytes.Length -lt 64KB -and -not $hasUtf8Bom) 'Generated metadata is oversized or has an unexpected encoding marker.'
    $parsed=ConvertFrom-Json -InputObject $json
    $actual=if($parsed -is [array]){$parsed}else{@($parsed)}
    Assert ($actual.Count -eq $expected.Count) ("Generated metadata count differs from Get-ICloudFolderDefinitions (resource=$($actual.Count), source=$($expected.Count)).")
    for($index=0;$index -lt $expected.Count;$index++){
        Assert ($actual[$index].Id -ceq $expected[$index].Id -and $actual[$index].RelativePath -ceq $expected[$index].RelativePath) ('Generated metadata differs at entry '+$index+'.')
    }
    Write-Host ('PASS: generated '+$actual.Count+' folder definitions match the central map exactly.')
}finally{
    Remove-Module $module -Force
    $resolved=[IO.Path]::GetFullPath($fixture)
    $prefix=[IO.Path]::GetFullPath($repo).TrimEnd('\')+'\.test-folder-definitions-'
    if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
