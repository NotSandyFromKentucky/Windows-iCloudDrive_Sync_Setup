#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EncodedRequest)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$root=Split-Path $PSScriptRoot -Parent
$code=1;$text='';$message='The action could not start. Review technical details and preview again.'
try{
    $request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedRequest)) | ConvertFrom-Json
    if($request.Phase -notin @('Preview','DryRun','Apply')){throw 'Unsupported operation phase.'}
    if($request.Action -eq 'Get folder definitions'){
        if($request.Phase -ne 'Preview'){throw 'Folder definitions are read only.'}
        Import-Module (Join-Path $root 'ICloudFolders.psm1') -Force
        $definitions=Get-ICloudFolderDefinitions | ConvertTo-Json -Depth 4 -Compress
        [Console]::Out.WriteLine(('@@ICloudResult:'+([pscustomobject]@{ExitCode=0;Message='Folder definitions loaded.';Text=$definitions}|ConvertTo-Json -Compress)))
        exit 0
    }
    Import-Module (Join-Path $root 'ICloudFolderSetup.UI.psm1') -Force
    if($request.Action -eq 'Install for me'){
        if($request.Phase -ne 'Apply'){throw 'Installation requires explicit confirmation.'}
        $plan=[pscustomobject]@{Script='tools\Invoke-WinUIInstall.ps1';Options=@{DesktopShortcut=[bool]$request.DesktopShortcut}}
    }else{
        $options=@{Action=[string]$request.Action;Root=[string]$request.Root;Backup=[string]$request.Backup;Music=[bool]$request.Music;Verified=[bool]$request.Verified;KeepFiles=[bool]$request.KeepFiles;Json=[bool]$request.Json;Phase=[string]$request.Phase}
        if($request.PSObject.Properties['FolderPaths'] -and $request.FolderPaths){
            $paths=@{};foreach($property in $request.FolderPaths.PSObject.Properties){$paths[$property.Name]=$property.Value};$options.FolderPaths=$paths
        }
        $plan=Get-SetupRequest @options
    }
    if($request.CancelEventName -and $plan.Script -eq 'Copy-ICloudFolderFiles.ps1'){
        $plan.Options.CancelEventName=[string]$request.CancelEventName
        $plan.Options.ProgressEvents=$true
    }
    $global:LASTEXITCODE=0
    $invokeOptions=$plan.Options
    $previousError=[Console]::Error
    $capturedErrors=New-Object IO.StringWriter
    try{
        [Console]::SetError($capturedErrors)
        $text=(& (Join-Path $root $plan.Script) @invokeOptions *>&1 | Out-String -Width 240)
    }finally{
        [Console]::SetError($previousError)
        $text+=[Environment]::NewLine+$capturedErrors.ToString()
        $capturedErrors.Dispose()
    }
    $code=$LASTEXITCODE
    $message=(Get-SetupOutcome -Action $request.Action -Phase $request.Phase -ExitCode $code -Text $text).Message
    if($code -eq 0 -and $request.Action -eq 'Install for me'){$message='Application installed for your Windows account. Open iCloud folder setup from the Start menu. Folder locations have not changed.'}
}catch{
    $code=1
    $text=$_ | Out-String
    if(Get-Command Get-SetupOutcome -ErrorAction SilentlyContinue){$message=(Get-SetupOutcome -Action $request.Action -Phase $request.Phase -ExitCode 1 -Text $text).Message}
}
[Console]::Out.WriteLine(('@@ICloudResult:'+([pscustomobject]@{ExitCode=$code;Message=$message;Text=$text} | ConvertTo-Json -Compress -Depth 5)))
exit $code
