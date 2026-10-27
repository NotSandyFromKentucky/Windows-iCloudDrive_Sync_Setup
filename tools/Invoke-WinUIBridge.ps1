#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EncodedRequest)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
$root=Split-Path $PSScriptRoot -Parent
$code=1;$text='';$message='The action could not start. Review technical details and preview again.'
$capture=@{Prefix='';Suffix='';Critical='';Total=0L;Truncated=$false;RollbackIncomplete=$false}
function Add-BoundedBridgeText {
    param([hashtable]$Capture,[string]$Value)
    if([string]::IsNullOrEmpty($Value)){return}
    $Capture.Total += $Value.Length
    $prefixLimit=24576;$suffixLimit=8192;$criticalLimit=4096
    if($Capture.Total -gt $prefixLimit){$Capture.Truncated=$true}
    if($Capture.Prefix.Length -lt $prefixLimit){$take=[Math]::Min($prefixLimit-$Capture.Prefix.Length,$Value.Length);$Capture.Prefix += $Value.Substring(0,$take)}
    if($Value.Length -ge $suffixLimit){$Capture.Suffix=$Value.Substring($Value.Length-$suffixLimit);$Capture.Truncated=$true}
    elseif($Capture.Suffix.Length+$Value.Length -gt $suffixLimit){$remove=$Capture.Suffix.Length+$Value.Length-$suffixLimit;$Capture.Suffix=$Capture.Suffix.Substring($remove)+$Value;$Capture.Truncated=$true}
    else{$Capture.Suffix += $Value}
    if($Value -match 'ROLLBACK INCOMPLETE'){$Capture.RollbackIncomplete=$true}
    if($Value -match '(?i)recovery|backup|ROLLBACK INCOMPLETE'){
        $snippet=$Value.Trim()
        if($snippet.Length -gt 512){$snippet=$snippet.Substring(0,512)}
        if($Capture.Critical.Length -lt $criticalLimit){$Capture.Critical += $snippet+[Environment]::NewLine;if($Capture.Critical.Length -gt $criticalLimit){$Capture.Critical=$Capture.Critical.Substring(0,$criticalLimit)}}
    }
}
function Get-BoundedBridgeText {
    param([hashtable]$Capture)
    if(-not $Capture.Truncated){return $Capture.Prefix}
    $parts=New-Object 'Collections.Generic.List[string]'
    if($Capture.RollbackIncomplete){$parts.Add('CRITICAL: ROLLBACK INCOMPLETE was reported. Retain and inspect the recovery backup before retrying.')}
    $parts.Add($Capture.Prefix)
    $parts.Add("[Output summary. Total captured characters: $($Capture.Total).]")
    if($Capture.Critical){$parts.Add('[Recovery and backup details retained:]');$parts.Add($Capture.Critical)}
    $parts.Add('[Most recent output:]')
    $tail=$Capture.Suffix
    $overlap=[Math]::Max(0,$Capture.Prefix.Length+$tail.Length-$Capture.Total)
    if($overlap -gt 0){$tail=$tail.Substring([Math]::Min($overlap,$tail.Length))}
    $parts.Add($tail)
    return ($parts -join [Environment]::NewLine)
}
function New-BoundedConsoleWriter {
    if(-not ('ICloudBridge.BoundedTextWriter' -as [type])){
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
namespace ICloudBridge {
 public sealed class BoundedTextWriter : TextWriter {
  private readonly int prefixLimit; private readonly int suffixLimit; private readonly StringBuilder prefix=new StringBuilder(); private readonly StringBuilder suffix=new StringBuilder(); public long TotalCharacters {get;private set;} public bool Truncated {get{return TotalCharacters>prefixLimit+suffixLimit;}} public override Encoding Encoding { get { return Encoding.UTF8; } }
  public BoundedTextWriter(int maximumCharacters){prefixLimit=maximumCharacters/2;suffixLimit=maximumCharacters-prefixLimit;}
  private void AppendCharacter(char character){TotalCharacters++;if(prefix.Length<prefixLimit)prefix.Append(character);else{if(suffix.Length==suffixLimit)suffix.Remove(0,1);suffix.Append(character);}}
  public override void Write(char character){AppendCharacter(character);}
  public override void Write(string text){if(text==null)return;for(int index=0;index<text.Length;index++)AppendCharacter(text[index]);}
  public override void Write(char[] buffer,int index,int count){if(buffer==null)throw new ArgumentNullException("buffer");for(int position=index;position<index+count;position++)AppendCharacter(buffer[position]);}
  public override string ToString(){int overlap=(int)Math.Max(0,prefix.Length+suffix.Length-TotalCharacters);return prefix.ToString()+(overlap<suffix.Length?suffix.ToString(overlap,suffix.Length-overlap):String.Empty);}
 }
}
"@
    }
    return New-Object ICloudBridge.BoundedTextWriter(16384)
}
try{
    $request=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($EncodedRequest)) | ConvertFrom-Json
    if($request.Phase -notin @('Preview','DryRun','Apply')){throw 'Unsupported operation phase.'}
    if($request.Action -eq 'Get folder definitions'){
        if($request.Phase -ne 'Preview'){throw 'Folder definitions are read only.'}
        Import-Module (Join-Path $root 'ICloudFolders.psm1') -Force
        $definitions=Get-ICloudFolderDefinitions | ConvertTo-Json -Depth 4 -Compress
        [Console]::Out.WriteLine(('@@ICloudResult:'+([pscustomobject]@{Version=2;ExitCode=0;Message='Folder definitions loaded.';Text=$definitions;TextTruncated=$false;CapturedCharacters=$definitions.Length}|ConvertTo-Json -Compress)))
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
    if($plan.Script -eq 'Copy-ICloudFolderFiles.ps1' -and $request.StructuredCopyPage){
        $plan.Options.StructuredPage=$true
        $plan.Options.PageOffset=[int]$request.CopyPageOffset
        if($request.Phase -eq 'Apply'){$plan.Options.ReviewToken=[string]$request.CopyReviewToken}
    }
    $global:LASTEXITCODE=0
    $invokeOptions=$plan.Options
    $previousError=[Console]::Error
    $capturedErrors=New-BoundedConsoleWriter
    try{
        [Console]::SetError($capturedErrors)
        & (Join-Path $root $plan.Script) @invokeOptions *>&1 | ForEach-Object {
            $formatted=Out-String -InputObject $_ -Width 240
            Add-BoundedBridgeText -Capture $capture -Value $formatted
        }
    }finally{
        [Console]::SetError($previousError)
        Add-BoundedBridgeText -Capture $capture -Value $capturedErrors.ToString()
        if($capturedErrors.Truncated){$capture.Truncated=$true;$capture.Total += [Math]::Max(0,$capturedErrors.TotalCharacters-$capturedErrors.ToString().Length)}
        $capturedErrors.Dispose()
    }
    $text=Get-BoundedBridgeText -Capture $capture
    $code=$LASTEXITCODE
    $message=(Get-SetupOutcome -Action $request.Action -Phase $request.Phase -ExitCode $code -Text $text).Message
    if($code -eq 0 -and $request.Action -eq 'Install for me'){$message='Application installed for your Windows account. Open iCloud folder setup from the Start menu. Folder locations have not changed.'}
}catch{
    $code=1
    Add-BoundedBridgeText -Capture $capture -Value ($_ | Out-String)
    $text=Get-BoundedBridgeText -Capture $capture
    if(Get-Command Get-SetupOutcome -ErrorAction SilentlyContinue){$message=(Get-SetupOutcome -Action $request.Action -Phase $request.Phase -ExitCode 1 -Text $text).Message}
}
$omittedCharacters=[Math]::Max(0,$capture.Total-$capture.Prefix.Length-$capture.Suffix.Length)
[Console]::Out.WriteLine(('@@ICloudResult:'+([pscustomobject]@{Version=2;ExitCode=$code;Message=$message;Text=$text;TextTruncated=($omittedCharacters -gt 0);CapturedCharacters=$capture.Total} | ConvertTo-Json -Compress -Depth 5)))
exit $code
