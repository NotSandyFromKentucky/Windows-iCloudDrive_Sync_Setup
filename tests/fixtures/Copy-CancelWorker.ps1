param([switch]$Apply,[switch]$WhatIf,[string]$CancelEventName,[switch]$ProgressEvents)
$ErrorActionPreference='Stop'
$m=Import-Module (Join-Path $PSScriptRoot 'ICloudFolderCopy.psm1') -Force -PassThru
& $m {
    param($Directory)
    $script:Pairs=@([pscustomobject]@{Source=(Join-Path $Directory 'source');Destination=(Join-Path $Directory 'target')})
    function script:Get-CopyPairs {$script:Pairs}
    $script:SendOriginal=(Get-Item Function:Send-CopyProgress).ScriptBlock
    function script:Send-CopyProgress {
        param($Stage,$File,$Completed=0,$Total=0)
        & $script:SendOriginal $Stage $File $Completed $Total
        if($Stage -eq 'Verified' -and $Completed -eq 1){Start-Sleep -Seconds 3}
    }
} $PSScriptRoot
try{
    Invoke-ICloudFolderCopy -Apply:$Apply -WhatIf:$WhatIf -CancelEventName $CancelEventName -ProgressEvents:$ProgressEvents
    exit 0
}catch [OperationCanceledException]{[Console]::Error.WriteLine($_.Exception.Message);exit 3}
