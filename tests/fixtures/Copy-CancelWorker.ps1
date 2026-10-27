param([string]$ICloudRoot,[switch]$Apply,[switch]$WhatIf,[string]$CancelEventName,[switch]$ProgressEvents,[switch]$StructuredPage,[int]$PageOffset=0,[string]$ReviewToken='')
$ErrorActionPreference='Stop'
$m=Import-Module (Join-Path $PSScriptRoot 'ICloudFolderCopy.psm1') -Force -PassThru
& $m {
    param($Directory)
    $script:Pairs=@([pscustomobject]@{Source=$Directory;Destination=(Join-Path (Split-Path $Directory -Parent) 'target')})
    function script:Get-CopyPairs {$script:Pairs}
    $script:SendOriginal=(Get-Item Function:Send-CopyProgress).ScriptBlock
    function script:Send-CopyProgress {
        param($Stage,$File,$Completed=0,$Total=0)
        & $script:SendOriginal $Stage $File $Completed $Total
        if($Stage -eq 'Verified' -and $Completed -eq 1){Start-Sleep -Seconds 3}
    }
} $ICloudRoot
try{
    Invoke-ICloudFolderCopy -ICloudRoot $ICloudRoot -Apply:$Apply -WhatIf:$WhatIf -CancelEventName $CancelEventName -ProgressEvents:$ProgressEvents -StructuredPage:$StructuredPage -PageOffset $PageOffset -ReviewToken $ReviewToken
    exit 0
}catch [OperationCanceledException]{[Console]::Error.WriteLine($_.Exception.Message);exit 3}
