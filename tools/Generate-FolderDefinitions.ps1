#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repo 'ICloudFolders.psm1') -Force
$definitions=@(Get-ICloudFolderDefinitions)
if($definitions.Count -eq 0){throw 'The central folder map produced no folder definitions.'}
$ids=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach($definition in $definitions){
    if([string]::IsNullOrWhiteSpace($definition.Id) -or [string]::IsNullOrWhiteSpace($definition.RelativePath) -or -not $ids.Add($definition.Id)){
        throw 'The central folder map produced invalid or duplicate folder definitions.'
    }
}
$fullPath=[IO.Path]::GetFullPath($OutputPath)
$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
$json=ConvertTo-Json -InputObject $definitions -Depth 4 -Compress
[IO.File]::WriteAllText($fullPath,$json,[Text.UTF8Encoding]::new($false))
