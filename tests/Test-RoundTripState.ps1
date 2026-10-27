#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $repo ('.test-roundtrip-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixture)
$helper=Join-Path $repo 'tools\Test-ICloudRoundTrip.ps1'
$statePath=Join-Path $fixture 'state.json'
$docs=[Environment]::GetFolderPath('MyDocuments')
$token=[guid]::NewGuid().ToString('N')
$name='ICloudFolderSetup-SyncTest-'+$token.Substring(0,10)+'-upload.txt'
$state=[pscustomobject]@{
    Path=Join-Path $docs $name
    FileName=$name
    ReturnPath=Join-Path $docs $name.Replace('-upload.txt','-returned.txt')
    ReturnName=$name.Replace('-upload.txt','-returned.txt')
    Token=$token
    Sha256=('A'*64)
    CreatedUtc=[DateTime]::UtcNow.ToString('o')
    Verified=$false
}
function Assert($condition,$message){if(-not $condition){throw $message}}
function Expect-Failure([string]$text,[string]$expected){
    [IO.File]::WriteAllText($statePath,$text)
    $caught=$null
    try{& $helper -Mode Check -StatePath $statePath|Out-Null}catch{$caught=$_.Exception.Message}
    Assert ($null -ne $caught -and $caught -like "*$expected*") "Expected '$expected'; got '$caught'"
}
try{
    $state|ConvertTo-Json -Compress|Set-Content -LiteralPath $statePath -Encoding UTF8
    $result=& $helper -Mode Check -StatePath $statePath
    Assert ($result.UploadFile -ceq $name -and -not $result.ReturnDetected) 'A valid round-trip state did not pass the read-only check.'
    Write-Host 'PASS: valid state remains a read-only check'

    Expect-Failure (' '*131073) '128 KiB'
    Write-Host 'PASS: oversized state is rejected before parsing'
    Expect-Failure '[[[0]]]' '2-level nesting'
    Write-Host 'PASS: excessive JSON nesting is rejected before parsing'
    $extra=[ordered]@{}
    foreach($property in $state.PSObject.Properties){$extra[$property.Name]=$property.Value}
    $extra['Unexpected']='value'
    Expect-Failure (ConvertTo-Json -InputObject $extra -Compress) 'unsupported schema'
    Write-Host 'PASS: unexpected state records are rejected'
    $long=ConvertFrom-Json ($state|ConvertTo-Json -Compress)
    $long.Sha256='A'*32768
    Expect-Failure (ConvertTo-Json -InputObject $long -Compress) '32,767 characters'
    Write-Host 'PASS: overlong strings are rejected'
    $bad=ConvertFrom-Json ($state|ConvertTo-Json -Compress)
    $bad.Verified='false'
    Expect-Failure (ConvertTo-Json -InputObject $bad -Compress) 'Verified field is invalid'
    Write-Host 'PASS: invalid field types are rejected'
    Write-Host '6 round-trip state checks passed; no cloud file or live state was changed.'
}finally{
    $resolved=[IO.Path]::GetFullPath($fixture)
    $prefix=[IO.Path]::GetFullPath($repo).TrimEnd('\')+'\.test-roundtrip-'
    if($resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
