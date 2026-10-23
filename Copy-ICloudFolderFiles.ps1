#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param([string]$ICloudRoot="$env:USERPROFILE\iCloudDrive",[switch]$ResetToDefaults,[switch]$IncludeMusic,[switch]$VerifiedSyncRoot,[switch]$Apply,[string]$CancelEventName,[switch]$ProgressEvents,[hashtable]$FolderPaths=@{})
$ErrorActionPreference='Stop'
try{
    Import-Module (Join-Path $PSScriptRoot 'ICloudFolderCopy.psm1') -Force
    $options=@{ICloudRoot=$ICloudRoot;ResetToDefaults=$ResetToDefaults;IncludeMusic=$IncludeMusic;VerifiedSyncRoot=$VerifiedSyncRoot;Apply=$Apply;CancelEventName=$CancelEventName;ProgressEvents=$ProgressEvents;FolderPaths=$FolderPaths}
    if($WhatIfPreference){$options.WhatIf=$true}
    if($PSBoundParameters.ContainsKey('Confirm')){$options.Confirm=[bool]$PSBoundParameters.Confirm}
    Invoke-ICloudFolderCopy @options
    exit 0
}catch [OperationCanceledException]{[Console]::Error.WriteLine($_.Exception.Message);exit 3}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}
