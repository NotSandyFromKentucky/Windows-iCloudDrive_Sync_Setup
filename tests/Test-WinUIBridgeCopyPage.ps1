#requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture=Join-Path $temp ('.test-bridge-copy-page-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory((Join-Path $fixture 'tools'))
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
try{
    Copy-Item -LiteralPath (Join-Path $repo 'ICloudFolderSetup.UI.psm1') -Destination $fixture
    Copy-Item -LiteralPath (Join-Path $repo 'tools/Invoke-WinUIBridge.ps1') -Destination (Join-Path $fixture 'tools')
    @'
param([string]$ICloudRoot,[switch]$Apply,[switch]$WhatIf,[string]$CancelEventName,[switch]$ProgressEvents,[switch]$StructuredPage,[int]$PageOffset=0,[string]$ReviewToken='')
$page=[pscustomobject]@{Version=1;Type='copy_review_page';ApprovalToken=('a'*64);Offset=$PageOffset;NextOffset=$null;TotalEntries=0;Entries=@();StructuredPage=[bool]$StructuredPage;Apply=[bool]$Apply;WhatIf=[bool]$WhatIf;CancelEventName=$CancelEventName;ProgressEvents=[bool]$ProgressEvents;ReviewToken=$ReviewToken}
[Console]::Out.WriteLine(('@@ICloudCopyPage:'+($page|ConvertTo-Json -Compress -Depth 3)))
Write-Output 'Fixture copy operation result.'
if($env:ICLOUD_BRIDGE_LARGE_OUTPUT){Write-Output ('x'*50000);[Console]::Error.Write(('e'*30000))}
exit 0
'@ | Set-Content -LiteralPath (Join-Path $fixture 'Copy-ICloudFolderFiles.ps1') -Encoding UTF8

    function Invoke-Bridge([string]$Phase,[int]$Offset,[string]$Token,[switch]$LargeOutput){
        $request=@{Action='Copy files into iCloud folders';Root=(Join-Path $fixture 'source');Backup='';Music=$false;Verified=$true;KeepFiles=$false;Json=$false;DesktopShortcut=$false;FolderPaths=$null;Phase=$Phase;CancelEventName=('Local\ICloudCopy-'+[guid]::NewGuid().ToString('N'));StructuredCopyPage=$true;CopyPageOffset=$Offset;CopyReviewToken=$Token}
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request|ConvertTo-Json -Compress -Depth 4)))
        $priorLarge=$env:ICLOUD_BRIDGE_LARGE_OUTPUT
        try{
            if($LargeOutput){$env:ICLOUD_BRIDGE_LARGE_OUTPUT='1'}else{Remove-Item Env:ICLOUD_BRIDGE_LARGE_OUTPUT -ErrorAction SilentlyContinue}
            $output=@(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'tools/Invoke-WinUIBridge.ps1') -EncodedRequest $encoded 2>&1)
        }finally{if($null -eq $priorLarge){Remove-Item Env:ICLOUD_BRIDGE_LARGE_OUTPUT -ErrorAction SilentlyContinue}else{$env:ICLOUD_BRIDGE_LARGE_OUTPUT=$priorLarge}}
        Assert ($LASTEXITCODE -eq 0) ("Bridge failed for ${Phase}: "+($output -join [Environment]::NewLine))
        $pageLine=@($output|Where-Object {$_ -is [string] -and $_.StartsWith('@@ICloudCopyPage:')})
        $resultLine=@($output|Where-Object {$_ -is [string] -and $_.StartsWith('@@ICloudResult:')})
        Assert ($pageLine.Count -eq 1 -and $resultLine.Count -eq 1) "Bridge did not return exactly one bounded page and one terminal result for $Phase"
        $page=$pageLine[0].Substring(17)|ConvertFrom-Json
        $result=$resultLine[0].Substring(15)|ConvertFrom-Json
        Assert ($page.Offset -eq $Offset -and $page.StructuredPage -and $page.ProgressEvents) 'Bridge lost structured-page or progress parameters'
        Assert ($page.Apply -eq ($Phase -ne 'Preview') -and $page.WhatIf -eq ($Phase -eq 'DryRun')) 'Bridge mapped Preview, DryRun or Apply incorrectly'
        Assert ($page.ReviewToken -ceq $(if($Phase -eq 'Apply'){$Token}else{''})) 'Bridge lost the full-plan approval token'
        Assert ($result.ExitCode -eq 0 -and $result.Text -like '*Fixture copy operation result.*') 'Bridge terminal result did not retain the bounded operation summary'
        Assert ($result.Version -eq 2 -and $result.Text.Length -le 40*1024 -and $result.CapturedCharacters -ge 0) 'Bridge result did not follow the bounded version-2 contract'
        if($LargeOutput){Assert ($result.TextTruncated -and $result.CapturedCharacters -gt $result.Text.Length -and $result.Text -like '*Output summary*' -and $result.Text -like '*Most recent output*') 'Bridge did not bound oversized stdout/stderr while retaining a readable summary'}
        $page
    }
    $preview=Invoke-Bridge 'Preview' 37 ''
    $dryRun=Invoke-Bridge 'DryRun' 63 ''
    $token='b'*64
    $apply=Invoke-Bridge 'Apply' 0 $token
    $large=Invoke-Bridge 'Preview' 0 '' -LargeOutput
    Assert ($preview.Offset -eq 37 -and $dryRun.Offset -eq 63 -and $apply.ReviewToken -ceq $token) 'Copy page offsets or Apply token changed in transport'
    'PASS: WinUI bridge bounds non-copy output and transports copy pages and full-plan Apply tokens'
}finally{
    $full=[IO.Path]::GetFullPath($fixture)
    if($full.StartsWith($temp+'\.test-bridge-copy-page-',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -match '^\.test-bridge-copy-page-[a-f0-9]{32}$'){Remove-Item -LiteralPath $full -Recurse -Force}
}
