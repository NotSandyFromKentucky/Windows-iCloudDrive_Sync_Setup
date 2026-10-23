#requires -Version 5.1
Set-StrictMode -Version Latest
$script:CopyCancelHandle=$null;$script:CopyProgressEnabled=$false
function Assert-CopyPath {
    param([string]$Path)
    # Cloud Files reparse points are data placeholders; name-surrogate links are not.
    if(-not ('ICloudCopy.PathTags' -as [type])){
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace ICloudCopy {
 public static class PathTags {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct Data {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Created,Accessed,Written;
   public uint SizeHigh,SizeLow,Tag,Reserved;
   [MarshalAs(UnmanagedType.ByValTStr,SizeConst=260)] public string Name;
   [MarshalAs(UnmanagedType.ByValTStr,SizeConst=14)] public string Alternate;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  static extern IntPtr FindFirstFileW(string name,out Data data);
  [DllImport("kernel32.dll")] static extern bool FindClose(IntPtr handle);
  public static uint Tag(string path) {
   Data data; var handle=FindFirstFileW(path,out data);
   if(handle==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
   try { return data.Tag; } finally { FindClose(handle); }
  }
 }
}
"@
    }
    $original=[IO.Path]::GetFullPath($Path).TrimEnd('\');$cursor=$original
    while($cursor -and $cursor.TrimEnd('\') -ne [IO.Path]::GetPathRoot($cursor).TrimEnd('\')){
        if(Test-Path -LiteralPath $cursor){
            $item=Get-Item -LiteralPath $cursor -Force
            if($cursor -ine $original -and -not $item.PSIsContainer){throw "A copy path is blocked by a file: $cursor"}
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){
                $tag=[ICloudCopy.PathTags]::Tag($cursor)
                if(($tag -band [uint32]4294905855) -ne [uint32]2415919130){throw "Copy refuses links or unsupported reparse points: $cursor"}
            }
        }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}
function Get-CopyHash {
    param([string]$Path)
    Assert-CopyPath $Path
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}
function Get-CopyPairs {
    param([string]$ICloudRoot,[switch]$ResetToDefaults,[switch]$IncludeMusic,[switch]$VerifiedSyncRoot,[switch]$ForApply,[hashtable]$FolderPaths=@{})
    $core=Import-Module (Join-Path $PSScriptRoot 'ICloudFolders.psm1') -Force -PassThru
    & $core {
        param($Root,$Reset,$Music,$Verified,$Applying,$CustomPaths)
        if($Reset -and $CustomPaths.Count){throw 'Custom folder paths cannot replace Windows defaults.'}
        if($Reset){$map=Get-FolderMap -IncludeMusic -SystemDefaults}
        else{
            $Root=Get-NormalPath $Root
            if(-not(Test-Path -LiteralPath $Root -PathType Container)){throw 'Choose an existing iCloud Drive folder.'}
            $registered=@(Get-RegisteredICloudRoots)
            if($registered.Count -gt 0 -and $registered -notcontains $Root){throw 'The selected folder does not match your registered iCloud Drive location.'}
            if($Applying -and $registered.Count -eq 0 -and -not $Verified){throw 'Windows has no iCloud registration. Verify the active folder in iCloud settings before copying.'}
            $map=Get-FolderMap -IncludeMusic:$Music -Root $Root -FolderPaths $CustomPaths
        }
        $seen=@{}
        foreach($name in $map.Keys){
            $value=Read-FolderValue $name
            if(-not $value.Exists){continue}
            $source=Get-NormalPath $value.Data
            $target=$map[$name]
            if($source -ieq $target){continue}
            $key=$source+'|'+$target
            if(-not $seen.ContainsKey($key)){$seen[$key]=$true;[pscustomobject]@{Source=$source;Destination=$target}}
        }
    } $ICloudRoot ([bool]$ResetToDefaults) ([bool]$IncludeMusic) ([bool]$VerifiedSyncRoot) ([bool]$ForApply) $FolderPaths
}
function Test-CopyCancellation {
    if($script:CopyCancelHandle -and $script:CopyCancelHandle.WaitOne(0)){
        throw (New-Object OperationCanceledException('Copy stopped at a safe boundary. Originals and completed files are retained; folder settings are unchanged.'))
    }
}
function Send-CopyProgress {
    param([string]$Stage,[string]$File,[int]$Completed=0,[int]$Total=0)
    if($script:CopyProgressEnabled){
        [Console]::Out.WriteLine(('@@ICloudProgress:'+([pscustomobject]@{Stage=$Stage;File=$File;Completed=$Completed;Total=$Total} | ConvertTo-Json -Compress)))
    }
}
function Get-CopyPlan {
    param([object[]]$Pairs)
    $plan=New-Object Collections.Generic.List[object]
    $seen=@{}
    $sourceRoots=@($Pairs | ForEach-Object {[IO.Path]::GetFullPath($_.Source).TrimEnd('\')})
    $queue=New-Object Collections.Queue
    foreach($pair in $Pairs){
        $source=[IO.Path]::GetFullPath($pair.Source).TrimEnd('\')
        $target=[IO.Path]::GetFullPath($pair.Destination).TrimEnd('\')
        if($source -ieq $target){continue}
        foreach($root in $sourceRoots){
            if($target -ieq $root -or $target.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith($target+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Copy source and destination trees overlap. Choose non-overlapping folders.'}
        }
        Assert-CopyPath $source;Assert-CopyPath $target
        if(-not(Test-Path -LiteralPath $source -PathType Container)){throw "Source folder is unavailable: $source"}
        $queue.Enqueue([pscustomobject]@{Source=$source;Destination=$target})
    }
    while($queue.Count){
        Test-CopyCancellation
        $item=$queue.Dequeue();$source=$item.Source;$target=$item.Destination
        Send-CopyProgress -Stage 'Reading files' -File $source
        Assert-CopyPath $source;Assert-CopyPath $target
        $sourceItem=Get-Item -LiteralPath $source -Force
        if($sourceItem.Attributes -band [IO.FileAttributes]::Encrypted){throw "Encrypted files require a separate reviewed copy: $source"}
        $isDirectory=$sourceItem.PSIsContainer
        $hash=if($isDirectory){$null}else{Get-CopyHash $source}
        if($seen.ContainsKey($target)){
            $previous=$seen[$target]
            if($previous.Directory -ne $isDirectory -or (-not $isDirectory -and $previous.Hash -cne $hash)){throw "Different source files map to the same destination: $target"}
        }else{
            $exists=Test-Path -LiteralPath $target
            $status=if($exists){'Already identical'}else{'Copy'}
            if($exists){
                $destItem=Get-Item -LiteralPath $target -Force
                if($destItem.PSIsContainer -ne $isDirectory){throw "File/folder conflict at destination: $target"}
                if(-not $isDirectory -and (Get-CopyHash $target) -cne $hash){throw "Different file already exists; nothing will be overwritten: $target"}
            }
            $entry=[pscustomobject]@{Source=$source;Destination=$target;Directory=$isDirectory;Hash=$hash;Action=$status}
            $seen[$target]=$entry;$plan.Add($entry)
        }
        if($isDirectory){
            foreach($child in @(Get-ChildItem -LiteralPath $source -Force -ErrorAction Stop)){
                $queue.Enqueue([pscustomobject]@{Source=$child.FullName;Destination=(Join-Path $target $child.Name)})
            }
        }
    }
    $plan.ToArray()
}
function Invoke-ICloudFolderCopy {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$ICloudRoot="$env:USERPROFILE\iCloudDrive",[switch]$ResetToDefaults,[switch]$IncludeMusic,[switch]$VerifiedSyncRoot,[switch]$Apply,[string]$CancelEventName,[switch]$ProgressEvents,[hashtable]$FolderPaths=@{})
    $mutex=New-Object Threading.Mutex($false,('Local\ICloudFolders-'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
    $locked=$false
    $script:CopyCancelHandle=$null;$script:CopyProgressEnabled=[bool]$ProgressEvents
    try{
        if($CancelEventName){
            if($CancelEventName -notmatch '^Local\\ICloudCopy-[a-f0-9]{32}$'){throw 'Invalid cancellation channel.'}
            $script:CopyCancelHandle=[Threading.EventWaitHandle]::OpenExisting($CancelEventName)
        }
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'Another folder operation is running for this account.'}
        $pairs=@(Get-CopyPairs -ICloudRoot $ICloudRoot -ResetToDefaults:$ResetToDefaults -IncludeMusic:$IncludeMusic -VerifiedSyncRoot:$VerifiedSyncRoot -ForApply:$Apply -FolderPaths $FolderPaths)
        $plan=@(Get-CopyPlan $pairs)
        $plan | Select-Object Action,Source,Destination | Format-List | Out-Host
        Write-Host 'Copy only: originals stay in place. Folder settings are not changed. Reading cloud files may download their contents.'
        if(-not $Apply){Write-Host 'Preview only. No files or directories were written.';return}
        if(-not $PSCmdlet.ShouldProcess('Displayed file-copy plan','Copy missing files, verify SHA-256 and retain every original')){return}
        # Rebuild before the first write to reject changed source/destination content.
        $fresh=@(Get-CopyPlan $pairs)
        if(($fresh | ConvertTo-Json -Depth 5 -Compress) -cne ($plan | ConvertTo-Json -Depth 5 -Compress)){throw 'Files changed after planning. Preview again.'}
        $copied=0;$completed=0;$total=@($plan | Where-Object {-not $_.Directory}).Count
        try{
            foreach($entry in $plan){
                Test-CopyCancellation
                if(-not $entry.Directory){Send-CopyProgress -Stage 'Copying and verifying' -File $entry.Source -Completed $completed -Total $total}
                Assert-CopyPath $entry.Source;Assert-CopyPath $entry.Destination
                if($entry.Directory){
                    if(Test-Path -LiteralPath $entry.Destination){if(-not(Test-Path -LiteralPath $entry.Destination -PathType Container)){throw 'Destination changed to a file.'}}
                    else{$null=[IO.Directory]::CreateDirectory($entry.Destination)}
                    continue
                }
                if((Get-CopyHash $entry.Source) -cne $entry.Hash){throw "Source changed: $($entry.Source)"}
                if(Test-Path -LiteralPath $entry.Destination){
                    if((Get-CopyHash $entry.Destination) -cne $entry.Hash){throw "Destination changed: $($entry.Destination)"}
                    $completed++;Send-CopyProgress -Stage 'Verified' -File $entry.Source -Completed $completed -Total $total
                    continue
                }
                # File.Copy(false) atomically refuses an existing destination; never overwrite.
                [IO.File]::Copy($entry.Source,$entry.Destination,$false)
                if((Get-CopyHash $entry.Destination) -cne $entry.Hash -or (Get-CopyHash $entry.Source) -cne $entry.Hash){throw "Copy verification failed: $($entry.Destination)"}
                $copied++;$completed++
                Send-CopyProgress -Stage 'Verified' -File $entry.Source -Completed $completed -Total $total
            }
        }catch [OperationCanceledException]{throw}catch{throw "Copy stopped: $($_.Exception.Message) Originals and folder settings are unchanged. Completed or incomplete destination copies are retained for inspection; no files were deleted."}
        Write-Host "Copy verified. New files copied: $copied. Originals retained. Folder settings unchanged. Preview the folder setup/reset separately before applying it."
    }finally{if($script:CopyCancelHandle){$script:CopyCancelHandle.Dispose();$script:CopyCancelHandle=$null};if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
Export-ModuleMember -Function Invoke-ICloudFolderCopy
