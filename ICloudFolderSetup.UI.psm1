#requires -Version 5.1
Set-StrictMode -Version Latest
function Get-SetupRequest {
    param([string]$Action,[string]$Root,[string]$Backup,[bool]$Music,[bool]$Verified,[bool]$KeepFiles,[bool]$Json,[ValidateSet('Preview','DryRun','Apply')][string]$Phase='Preview')
    $options=@{}
    $mutates=$false
    switch ($Action) {
        'Set up iCloud folders' {
            if ([string]::IsNullOrWhiteSpace($Root)) { throw 'Choose your existing iCloud Drive folder.' }
            $scriptFile='Set-ICloudFolders.ps1'; $options.ICloudRoot=$Root
            if($Music){$options.IncludeMusic=$true}
            if($Verified){$options.VerifiedSyncRoot=$true}
            if($KeepFiles){$options.AllowExistingContent=$true}
            $mutates=$true
        }
        'Copy files into iCloud folders' {
            if([string]::IsNullOrWhiteSpace($Root)){throw 'Choose your existing iCloud Drive folder.'}
            $scriptFile='Copy-ICloudFolderFiles.ps1';$options.ICloudRoot=$Root
            if($Music){$options.IncludeMusic=$true}
            if($Verified){$options.VerifiedSyncRoot=$true}
            $mutates=$true
        }
        'Copy files into Windows default folders' {
            $scriptFile='Copy-ICloudFolderFiles.ps1';$options.ResetToDefaults=$true;$mutates=$true
        }
        'Reset to Windows defaults' {
            $scriptFile='Set-ICloudFolders.ps1';$options.ResetToDefaults=$true
            if($KeepFiles){$options.AllowExistingContent=$true}
            $mutates=$true
        }
        'Restore a recovery backup' {
            if([string]::IsNullOrWhiteSpace($Backup)){throw 'Choose a trusted before.json recovery backup for this account.'}
            $scriptFile='Set-ICloudFolders.ps1';$options.RestoreBackup=$Backup;$mutates=$true
        }
        'Check iCloud configuration' {
            $scriptFile='Test-ICloudFolders.ps1';$options.ICloudRoot=$Root
            if($Music){$options.IncludeMusic=$true}
            if($Json){$options.Json=$true}
        }
        'Create cloud test file' {$scriptFile='tools\Test-ICloudRoundTrip.ps1';$options.Mode='Start';$mutates=$true}
        'Check cloud return' {$scriptFile='tools\Test-ICloudRoundTrip.ps1';$options.Mode='Check'}
        'Clean up cloud test file' {$scriptFile='tools\Test-ICloudRoundTrip.ps1';$options.Mode='Cleanup';$mutates=$true}
        default {throw 'Choose a supported action.'}
    }
    if($mutates){
        if($scriptFile -in @('Set-ICloudFolders.ps1','Copy-ICloudFolderFiles.ps1')){
            if($Phase -ne 'Preview'){$options.Apply=$true}
            if($Phase -eq 'DryRun'){$options.WhatIf=$true}
        } elseif($Phase -ne 'Apply'){$options.WhatIf=$true}
    }
    [pscustomobject]@{Script=$scriptFile;Options=$options;Mutates=$mutates;Action=$Action}
}
function Get-SetupActionLabel {
    param([string]$Action)
    switch -Wildcard($Action){
        'Copy files*' {'Copy files';break}
        'Reset*' {'Reset locations';break}
        'Restore*' {'Restore locations';break}
        'Create*' {'Create test file';break}
        'Clean up*' {'Remove test file';break}
        default {'Change locations'}
    }
}
function New-SetupConfirmation {
    param([string]$Message,[string]$Action)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text=Get-SetupActionLabel $Action
    $dialog.Font=New-Object Drawing.Font('Segoe UI',10)
    $dialog.AutoScaleMode='Font';$dialog.AutoSize=$true;$dialog.AutoSizeMode='GrowAndShrink'
    $dialog.MinimumSize=New-Object Drawing.Size(500,190)
    $dialog.FormBorderStyle='FixedDialog';$dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false;$dialog.StartPosition='CenterParent'
    $panel=New-Object Windows.Forms.FlowLayoutPanel
    $panel.AutoSize=$true;$panel.AutoSizeMode='GrowAndShrink';$panel.FlowDirection='TopDown';$panel.WrapContents=$false;$panel.Padding=New-Object Windows.Forms.Padding(18)
    $dialog.Controls.Add($panel)
    $label=New-Object Windows.Forms.Label;$label.AutoSize=$true;$label.MaximumSize=New-Object Drawing.Size(520,0);$label.Text=$Message;$label.AccessibleName='Action consequences'
    $panel.Controls.Add($label)
    $row=New-Object Windows.Forms.FlowLayoutPanel;$row.AutoSize=$true
    $commit=New-Object Windows.Forms.Button;$commit.AutoSize=$true;$commit.Text=(Get-SetupActionLabel $Action);$commit.AccessibleName=$commit.Text;$commit.DialogResult='OK'
    $cancel=New-Object Windows.Forms.Button;$cancel.AutoSize=$true;$cancel.Text='&Cancel';$cancel.AccessibleName='Cancel';$cancel.DialogResult='Cancel'
    $commit.TabIndex=0;$cancel.TabIndex=1
    $row.Controls.AddRange(@($commit,$cancel));$panel.Controls.Add($row)
    $dialog.AcceptButton=$cancel;$dialog.CancelButton=$cancel;$dialog.ActiveControl=$cancel
    [pscustomobject]@{Form=$dialog;Commit=$commit;Cancel=$cancel}
}
function Confirm-SetupAction {
    param($Owner,[string]$Message,[string]$Action)
    $confirmation=New-SetupConfirmation -Message $Message -Action $Action
    try{$confirmation.Form.ShowDialog($Owner) -eq 'OK'}finally{$confirmation.Form.Dispose()}
}
function Get-SetupOutcome {
    param([string]$Action,[string]$Phase,[int]$ExitCode,[string]$Text)
    $message=''
    if($Text -like '*ROLLBACK INCOMPLETE*'){
        $message='Recovery needs attention. Do not retry the change yet. Open Recovery files and inspect the backup and error details before restoring.'
    }elseif($ExitCode -eq 3){
        $message='Copy stopped safely. Originals and completed, verified files are retained. Folder locations were not changed. Preview again when you are ready to continue.'
    }elseif($ExitCode -eq 0){
        if($Phase -eq 'Preview'){$message='Preview ready. Review the paths below. Nothing was applied.'}
        elseif($Phase -eq 'DryRun'){$message='Dry run completed. Nothing was applied. You can review and confirm the action.'}
        elseif($Action -like 'Copy files*'){$message='Copy completed and verified. Originals are retained. Folder locations have not changed.'}
        else{$message='Action completed. Review the result below and verify the affected folders before discarding any backup.'}
        if($Action -eq 'Check iCloud configuration'){$message='Folder configuration checks passed. Cloud synchronization still needs a separate check.'}
        if($Action -eq 'Check cloud return'){$message='Review the returned-file result below. A match is meaningful only if the file was renamed on iCloud.com or another device.'}
    }elseif($ExitCode -eq 2 -and $Action -eq 'Check iCloud configuration'){
        $message='Some folder locations need attention. Review the listed mismatches, confirm the selected iCloud folder, and check again. This is expected after intentionally resetting to local defaults.'
    }else{
        $message=switch -Regex($Text){
            'nothing will be overwritten|Different source files|File/folder conflict' {'Copy could not start because files conflict. Compare the named files and rename or relocate the conflicting destination yourself, then preview again.';break}
            'registration|registered iCloud' {'The iCloud folder could not be verified. Choose the folder shown in iCloud settings. Use manual verification only when Windows has no registration; a known mismatch cannot be overridden.';break}
            'Existing source content requires review' {'Existing files need your decision. Copy them using a separate copy action, or select the option to change locations without copying files, then preview again.';break}
            'backup|\bSID\b|\bschema\b' {'The recovery file could not be used. Choose a trusted before.json file for this Windows account and ensure its original destination folders are available.';break}
            'access.*denied|Access.*denied|permission|Unauthorized' {'Access was denied. Close applications using the files, check folder permissions, then preview again. Do not run as a different Windows account.';break}
            'unavailable|must already exist|does not exist' {'A required folder is unavailable. Reconnect its drive or choose an existing accessible location, then preview again.';break}
            default {'The action did not complete. Review Technical details for the named file or folder, correct the reported problem, then preview again. Retain any recovery backup and partial destination copies.'}
        }
    }
    [pscustomobject]@{Message=$message;Succeeded=($ExitCode -eq 0);Cancelled=($ExitCode -eq 3)}
}
function Initialize-SetupOutputReader {
    if('ICloudSetup.LiveOutput' -as [type]){return}
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Collections.Concurrent;
namespace ICloudSetup {
 public static class LiveOutput {
  public static Task<string> Collect(StreamReader reader,ConcurrentQueue<string> lines) {
   return Task.Run(async () => {
    var all=new StringBuilder(); string line;
    while((line=await reader.ReadLineAsync())!=null){all.AppendLine(line);lines.Enqueue(line);}
    return all.ToString();
   });
  }
 }
}
"@
}
function Start-SetupWorker {
    param([string]$Source,$Request)
    # Encode a data object rather than interpolating user paths into executable code.
    Initialize-SetupOutputReader
    $options=@{};foreach($key in $Request.Options.Keys){$options[$key]=$Request.Options[$key]}
    $cancelHandle=$null
    if($Request.Script -eq 'Copy-ICloudFolderFiles.ps1'){
        $name='Local\ICloudCopy-'+[guid]::NewGuid().ToString('N')
        $cancelHandle=New-Object Threading.EventWaitHandle($false,[Threading.EventResetMode]::ManualReset,$name)
        $options.CancelEventName=$name;$options.ProgressEvents=$true
    }
    $data=[pscustomobject]@{Path=(Join-Path $Source $Request.Script);Options=$options}
    $encodedData=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Depth 5 -Compress)))
    $command='$ProgressPreference="SilentlyContinue";$ErrorActionPreference="Stop";$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'+$encodedData+'")) | ConvertFrom-Json;$o=@{};foreach($p in $d.Options.PSObject.Properties){$o[$p.Name]=$p.Value};try{$global:LASTEXITCODE=0;& $d.Path @o *>&1 | Out-String -Width 240 | ForEach-Object {[Console]::Out.Write($_)};exit $LASTEXITCODE}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}'
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='powershell.exe'
    $info.WorkingDirectory=$Source
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8
    $info.StandardErrorEncoding=[Text.Encoding]::UTF8
    # Child console output explicitly uses UTF-8 to preserve international paths.
    $command='[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);'+$command
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=$null;try{$process=[Diagnostics.Process]::Start($info)}catch{if($cancelHandle){$cancelHandle.Dispose()};throw}
    $lines=New-Object 'Collections.Concurrent.ConcurrentQueue[string]'
    [pscustomobject]@{Process=$process;Output=[ICloudSetup.LiveOutput]::Collect($process.StandardOutput,$lines);Error=$process.StandardError.ReadToEndAsync();Lines=$lines;CancelHandle=$cancelHandle}
}
function New-SetupWindow {
    param([string]$Source,[string]$InitialAction='Set up iCloud folders',[scriptblock]$ConfirmAction={param($Owner,$Message,$Action) Confirm-SetupAction $Owner $Message $Action})
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form
    $form.Text='iCloud folder setup';$form.Size=New-Object Drawing.Size(930,760)
    $form.MinimumSize=New-Object Drawing.Size(760,650);$form.StartPosition='CenterScreen'
    $form.Font=New-Object Drawing.Font('Segoe UI',10)
    $form.AutoScaleMode='Font';$form.AutoScroll=$true
    $layout=New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock='Fill';$layout.AutoScroll=$true;$layout.Padding=New-Object Windows.Forms.Padding(16)
    $layout.ColumnCount=1;$layout.RowCount=9
    foreach($height in @(48,40,40,40,110,44,34,56)){ $null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height))) }
    $null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    foreach($rowIndex in @(0,1,2,3,4,5,6,7)){$layout.RowStyles[$rowIndex].SizeType='AutoSize'}
    $rootRow=$null
    $form.Controls.Add($layout)
    $notice=New-Object Windows.Forms.Label
    $notice.Text='Preview before applying. Existing files stay where they are. Run as your own Windows account; no administrator access is needed.'
    $notice.Dock='Fill';$notice.AutoSize=$true;$notice.MaximumSize=New-Object Drawing.Size(830,0);$layout.Controls.Add($notice,0,0)
    $actions=@('Set up iCloud folders','Reset to Windows defaults','Restore a recovery backup','Copy files into iCloud folders','Copy files into Windows default folders','Check iCloud configuration','Create cloud test file','Check cloud return','Clean up cloud test file')
    $action=New-Object Windows.Forms.ComboBox
    $action.DropDownStyle='DropDownList';$action.Dock='Fill';$action.AccessibleName='Action'
    $action.Items.AddRange([object[]]$actions);$action.SelectedItem=$InitialAction
    if($action.SelectedIndex -lt 0){$action.SelectedIndex=0};$layout.Controls.Add($action,0,1)
    $rootRow=New-Object Windows.Forms.TableLayoutPanel
    $rootRow.Dock='Fill';$rootRow.AutoSize=$true;$rootRow.ColumnCount=3
    $null=$rootRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    $null=$rootRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    $null=$rootRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::AutoSize)))
    $rootLabel=New-Object Windows.Forms.Label;$rootLabel.Text='iCloud folder';$rootLabel.Dock='Top';$rootLabel.AutoSize=$true
    $root=New-Object Windows.Forms.TextBox;$root.Text=Join-Path $env:USERPROFILE 'iCloudDrive';$root.Dock='Fill';$root.AccessibleName='iCloud Drive root'
    $browseRoot=New-Object Windows.Forms.Button;$browseRoot.Text='Browse...';$browseRoot.Dock='Top';$browseRoot.AutoSize=$true
    $rootRow.Controls.Add($rootLabel,0,0);$rootRow.Controls.Add($root,1,0);$rootRow.Controls.Add($browseRoot,2,0);$layout.Controls.Add($rootRow,0,2)
    $backupRow=New-Object Windows.Forms.TableLayoutPanel
    $backupRow.Dock='Fill';$backupRow.AutoSize=$true;$backupRow.ColumnCount=3
    foreach($s in $rootRow.ColumnStyles){$null=$backupRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle($s.SizeType,$s.Width)))}
    $backupLabel=New-Object Windows.Forms.Label;$backupLabel.Text='Recovery file';$backupLabel.Dock='Top';$backupLabel.AutoSize=$true
    $backup=New-Object Windows.Forms.TextBox;$backup.Dock='Fill';$backup.AccessibleName='Recovery backup file'
    $browseBackup=New-Object Windows.Forms.Button;$browseBackup.Text='Choose...';$browseBackup.Dock='Top';$browseBackup.AutoSize=$true
    $backupRow.Controls.Add($backupLabel,0,0);$backupRow.Controls.Add($backup,1,0);$backupRow.Controls.Add($browseBackup,2,0);$layout.Controls.Add($backupRow,0,3)
    $flags=New-Object Windows.Forms.FlowLayoutPanel;$flags.Dock='Fill';$flags.AutoSize=$true;$flags.FlowDirection='TopDown';$flags.WrapContents=$false
    $music=New-Object Windows.Forms.CheckBox;$music.Text='Include Music (reset always includes Music)';$music.AutoSize=$true
    $verified=New-Object Windows.Forms.CheckBox;$verified.Text='Use a manually verified iCloud folder';$verified.AutoSize=$true
    $keep=New-Object Windows.Forms.CheckBox;$keep.Text='Change locations without copying files';$keep.AutoSize=$true
    $flags.Controls.AddRange(@($music,$verified,$keep));$layout.Controls.Add($flags,0,4)
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill';$buttons.AutoSize=$true
    $preview=New-Object Windows.Forms.Button;$preview.Text='Preview / Check';$preview.AutoSize=$true
    $dry=New-Object Windows.Forms.Button;$dry.Text='Dry run';$dry.AutoSize=$true
    $apply=New-Object Windows.Forms.Button;$apply.Text='Apply...';$apply.AutoSize=$true;$apply.Enabled=$false
    $install=New-Object Windows.Forms.Button;$install.Text='Install for me...';$install.AutoSize=$true
    $recovery=New-Object Windows.Forms.Button;$recovery.Text='Recovery files';$recovery.AutoSize=$true
    $help=New-Object Windows.Forms.Button;$help.Text='Help';$help.AutoSize=$true
    $stop=New-Object Windows.Forms.Button;$stop.Text='S&top after current file';$stop.AutoSize=$true;$stop.Enabled=$false
    $buttons.Controls.AddRange(@($preview,$dry,$apply,$install,$recovery,$help));$layout.Controls.Add($buttons,0,5)
    $extra=New-Object Windows.Forms.FlowLayoutPanel;$extra.Dock='Fill';$extra.AutoSize=$true
    $json=New-Object Windows.Forms.CheckBox;$json.Text='Show diagnostics as JSON';$json.AutoSize=$true
    $save=New-Object Windows.Forms.Button;$save.Text='Save displayed result...';$save.AutoSize=$true
    $details=New-Object Windows.Forms.CheckBox;$details.Text='Technical detai&ls';$details.AutoSize=$true
    $extra.Controls.AddRange(@($json,$save,$details,$stop));$layout.Controls.Add($extra,0,6)
    $output=New-Object Windows.Forms.TextBox;$output.Multiline=$true;$output.ReadOnly=$true;$output.ScrollBars='Both';$output.WordWrap=$false;$output.Dock='Fill'
    $output.MinimumSize=New-Object Drawing.Size(0,100);$output.Font=New-Object Drawing.Font('Consolas',10);$output.AccessibleName='Plan and results'
    $output.Text='Choose an action and click Preview / Check. No folder settings have been changed.'
    $layout.Controls.Add($output,0,8)
    $status=New-Object Windows.Forms.Label;$status.Text='Ready. Choose an action and preview first.';$status.AutoSize=$true;$status.MaximumSize=New-Object Drawing.Size(830,0);$status.Padding=New-Object Windows.Forms.Padding(0,0,0,16);$status.Dock='Fill';$status.AccessibleName='Operation status';$status.AccessibleRole='StatusBar'
    $progress=New-Object Windows.Forms.ProgressBar;$progress.Dock='Bottom';$progress.Height=12;$progress.AccessibleName='Files completed';$status.Controls.Add($progress)
    $layout.Controls.Add($status,0,7)
    $state=@{Worker=$null;Fingerprint=$null;RunningRequest=$null;Phase=$null;Raw='';Friendly='';ProgressFile=''}
    $controls=@{Form=$form;Action=$action;Root=$root;Backup=$backup;Music=$music;Verified=$verified;KeepFiles=$keep;Json=$json;Preview=$preview;DryRun=$dry;Apply=$apply;Output=$output;Install=$install;Stop=$stop;Status=$status;Progress=$progress;Details=$details}
    $getRequest={param($phase) Get-SetupRequest -Action $action.Text -Root $root.Text -Backup $backup.Text -Music $music.Checked -Verified $verified.Checked -KeepFiles $keep.Checked -Json $json.Checked -Phase $phase}.GetNewClosure()
    $invalidate={$state.Fingerprint=$null;$apply.Enabled=$false;$state.Raw='';$state.Friendly='';$status.Text='Options changed. Preview again before applying.';$progress.Value=0}.GetNewClosure()
    $refresh={
        & $invalidate
        $apply.Text=(Get-SetupActionLabel $action.Text)+'...';$apply.AccessibleName=Get-SetupActionLabel $action.Text
        $setup=$action.Text -in @('Set up iCloud folders','Copy files into iCloud folders')
        $rootRow.Enabled=$setup -or $action.Text -eq 'Check iCloud configuration'
        $backupRow.Enabled=$action.Text -eq 'Restore a recovery backup'
        $music.Enabled=$rootRow.Enabled;$verified.Enabled=$setup
        $keep.Enabled=$action.Text -in @('Set up iCloud folders','Reset to Windows defaults')
        $json.Enabled=$action.Text -eq 'Check iCloud configuration'
        $dry.Enabled=$action.Text -notin @('Check iCloud configuration','Check cloud return')
        $output.Text=switch($action.Text){
            'Copy files into iCloud folders' {'Merge files into the selected iCloud folders. Missing files are copied and verified; identical files are skipped. Different same-name files block the operation. Originals and folder settings stay unchanged.'}
            'Copy files into Windows default folders' {'Merge files into Windows default folders, keeping every original. Nothing is overwritten. Copy first, then select Reset to Windows defaults to change folder locations separately.'}
            'Restore a recovery backup' {'Choose a trusted before.json file. Preview validates the account and contents. Files are never moved.'}
            'Create cloud test file' {'Creates one harmless text file in redirected Documents after approval. On iCloud.com or another device, rename -upload.txt to -returned.txt; never rename locally.'}
            'Check cloud return' {'Checks the returned filename and original SHA-256. A match proves a round trip only if the rename was performed remotely.'}
            'Clean up cloud test file' {'Preview shows the exact test files to remove. Deletion will propagate through iCloud; modified files are refused.'}
            default {'Preview displays the plan. Check reports configuration only; it cannot certify cloud synchronization.'}
        }
    }.GetNewClosure()
    $action.Add_SelectedIndexChanged($refresh)
    foreach($c in @($root,$backup)){$c.Add_TextChanged($invalidate)}
    foreach($c in @($music,$verified,$keep,$json)){$c.Add_CheckedChanged($invalidate)}
    $browseRoot.Add_Click({
        $dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Select the existing iCloud Drive root';$dialog.ShowNewFolderButton=$false
        try{if($dialog.ShowDialog($form) -eq 'OK'){$root.Text=$dialog.SelectedPath}}finally{$dialog.Dispose()}
    }.GetNewClosure())
    $browseBackup.Add_Click({
        $dialog=New-Object Windows.Forms.OpenFileDialog;$dialog.Filter='Recovery backup (before.json)|before.json|JSON files (*.json)|*.json';$dialog.Title='Choose a trusted recovery backup'
        try{if($dialog.ShowDialog($form) -eq 'OK'){$backup.Text=$dialog.FileName}}finally{$dialog.Dispose()}
    }.GetNewClosure())
    $run={
        param($phase)
        try{
            $request=& $getRequest $phase
            $fingerprint=(& $getRequest 'Preview') | ConvertTo-Json -Depth 5 -Compress
            if($phase -eq 'Apply'){
                if($state.Fingerprint -cne $fingerprint){throw 'Options changed. Preview this plan again before applying.'}
                $message=$request.Action+". Existing files stay in place. A fresh recovery backup is required for folder changes."
                if($request.Script -eq 'Copy-ICloudFolderFiles.ps1'){$message='Copy files according to this plan? Existing files will not be overwritten, originals stay in place, and folder locations will not change. Cloud files may download and destination copies may synchronize.'}
                if($request.Action -eq 'Create cloud test file'){$message='Create the small verification file in your iCloud Documents folder?'}
                if($request.Action -eq 'Clean up cloud test file'){$message='Delete the exact verification file(s)? This deletion will synchronize to iCloud and other devices.'}
                if(-not (& $ConfirmAction $form $message $request.Action)){return}
            }
            $state.StopRequested=$false
            $state.Worker=Start-SetupWorker -Source $Source -Request $request
            $state.RunningRequest=$request;$state.Phase=$phase
            $state.Fingerprint=$null
            foreach($c in @($action,$rootRow,$backupRow,$flags,$buttons,$extra)){$c.Enabled=$false}
            $extra.Enabled=$true;$json.Enabled=$false;$save.Enabled=$false;$details.Enabled=$false
            $stop.Enabled=($null -ne $state.Worker.CancelHandle)
            $status.Text='Working. Folder changes cannot be interrupted; copying can stop after the current file.'
            $progress.Style='Marquee';$progress.Value=0
            $output.Text='Preparing the operation. Progress will appear here.'
        }catch{
            $state.Raw=$_.Exception.Message
            $state.Friendly=(Get-SetupOutcome -Action $action.Text -Phase $phase -ExitCode 1 -Text $state.Raw).Message
            $status.Text=$state.Friendly;$output.Text=if($details.Checked){$state.Raw}else{$state.Friendly}
            $apply.Enabled=$false
        }
    }.GetNewClosure()
    $preview.Add_Click({& $run 'Preview'}.GetNewClosure())
    $dry.Add_Click({& $run 'DryRun'}.GetNewClosure())
    $apply.Add_Click({& $run 'Apply'}.GetNewClosure())
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=150
    $timer.Add_Tick({
        if($null -eq $state.Worker){return}
        $line=$null
        while($state.Worker.Lines.TryDequeue([ref]$line)){
            if($line.StartsWith('@@ICloudProgress:')){
                try{
                    $event=$line.Substring(17) | ConvertFrom-Json
                    $state.ProgressFile=$event.File
                    $status.Text=$event.Stage+': '+$event.Completed+' of '+$event.Total+' files verified'
                    $output.Text=$event.File
                    if($state.StopRequested){$status.Text='Stop requested. Finishing the current file and verification before stopping.'}
                    if($event.Total -gt 0){$progress.Style='Continuous';$progress.Maximum=[Math]::Max(1,[int]$event.Total);$progress.Value=[Math]::Min([int]$event.Completed,$progress.Maximum)}
                }catch{}
            }
        }
        if(-not $state.Worker.Process.HasExited){return}
        $worker=$state.Worker
        if(-not $worker.Output.IsCompleted -or -not $worker.Error.IsCompleted){return}
        $code=$worker.Process.ExitCode
        # PowerShell may serialize host information/progress on stderr even though
        # actual script errors are written as plain text by our CLI wrappers.
        $errorText=[regex]::Replace($worker.Error.Result,'(?s)<Objs\b.*?</Objs>','')
        $errorText=$errorText.Replace('#< CLIXML','').Trim()
        $text=$worker.Output.Result+[Environment]::NewLine+$errorText
        $state.Raw=([regex]::Replace($text,'(?m)^@@ICloudProgress:.*\r?\n?',''))+[Environment]::NewLine+'Exit code: '+$code
        $outcome=Get-SetupOutcome -Action $state.RunningRequest.Action -Phase $state.Phase -ExitCode $code -Text $text
        $state.Friendly=$outcome.Message
        if($state.Phase -in @('Preview','DryRun') -or $state.RunningRequest.Action -like 'Check*'){$state.Friendly+=[Environment]::NewLine+[regex]::Replace($text,'(?m)^@@ICloudProgress:.*\r?\n?','')}
        else{
            $locations=@($text -split '\r?\n' | Where-Object {$_ -match 'Recovery backup:|Log:'})
            if($locations.Count){$state.Friendly+=[Environment]::NewLine+($locations -join [Environment]::NewLine)}
        }
        $output.Text=if($details.Checked){$state.Raw}else{$state.Friendly}
        $status.Text=$outcome.Message;$progress.Style='Continuous'
        if($code -eq 0){$progress.Value=$progress.Maximum}
        if($worker.CancelHandle){$worker.CancelHandle.Dispose()}
        $stop.Enabled=$false
        $worker.Process.Dispose();$state.Worker=$null
        foreach($c in @($action,$rootRow,$backupRow,$flags,$buttons,$extra)){$c.Enabled=$true}
        # Restore applicability without replacing the result.
        $resultText=$output.Text;$resultStatus=$status.Text;$resultRaw=$state.Raw;$resultFriendly=$state.Friendly;& $refresh;$output.Text=$resultText;$status.Text=$resultStatus;$state.Raw=$resultRaw;$state.Friendly=$resultFriendly
        if($code -eq 0 -and $state.Phase -in @('Preview','DryRun') -and $state.RunningRequest.Mutates){
            $state.Fingerprint=(& $getRequest 'Preview') | ConvertTo-Json -Depth 5 -Compress
            $apply.Enabled=$true
        }
    }.GetNewClosure())
    $form.Add_FormClosing({param($sender,$event) if($null -ne $state.Worker){$event.Cancel=$true;[Windows.Forms.MessageBox]::Show($form,'An operation is running. Wait for its result before closing.','Please wait') | Out-Null}}.GetNewClosure())
    $form.Add_FormClosed({$timer.Stop();$timer.Dispose()}.GetNewClosure())
    $stop.Add_Click({
        if($state.Worker -and $state.Worker.CancelHandle){
            $state.StopRequested=$true;$null=$state.Worker.CancelHandle.Set();$stop.Enabled=$false
            $status.Text='Stop requested. Finishing the current file and verification before stopping.'
        }
    }.GetNewClosure())
    $details.Add_CheckedChanged({if($state.Raw){$output.Text=if($details.Checked){$state.Raw}else{$state.Friendly}}}.GetNewClosure())
    $install.Add_Click({try{& (Join-Path $Source 'Install-ICloudFolderSetup.ps1')}catch{[Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Install failed') | Out-Null}}.GetNewClosure())
    $recovery.Add_Click({
        $path=Join-Path $env:LOCALAPPDATA 'ICloudFolderSettler\Recovery'
        if(Test-Path -LiteralPath $path){Start-Process explorer.exe -ArgumentList ('"'+$path+'"')}else{[Windows.Forms.MessageBox]::Show($form,'No recovery folder exists yet. Preview does not create one.','Recovery files') | Out-Null}
    }.GetNewClosure())
    $help.Add_Click({Start-Process -FilePath (Join-Path $Source 'README.md')}.GetNewClosure())
    $save.Add_Click({
        $dialog=New-Object Windows.Forms.SaveFileDialog;$dialog.Filter='Text file (*.txt)|*.txt';$dialog.FileName='folder-setup-result.txt'
        try{if($dialog.ShowDialog($form) -eq 'OK'){[IO.File]::WriteAllText($dialog.FileName,$output.Text,[Text.Encoding]::UTF8)}}finally{$dialog.Dispose()}
    }.GetNewClosure())
    $preview.Text='&Preview / Check';$dry.Text='&Dry run';$apply.AccessibleDescription='Enabled only after reviewing the same options.'
    $install.Text='&Install for me...';$recovery.Text='&Recovery files';$help.Text='&Help'
    $browseRoot.Text='&Browse...';$browseBackup.Text='Ch&oose...';$save.Text='&Save result...'
    $rootLabel.Text='i&Cloud folder';$backupLabel.Text='Recovery &file'
    $music.Text='Include &Music';$music.AccessibleDescription='Optional for iCloud setup; Windows-default reset always includes Music.'
    foreach($buttonControl in @($browseRoot,$browseBackup,$preview,$dry,$apply,$install,$recovery,$help,$save,$stop)){$buttonControl.AutoSizeMode='GrowAndShrink'}
    $order=0
    foreach($container in @($layout,$rootRow,$backupRow,$flags,$buttons,$extra)){
        $index=0
        foreach($control in $container.Controls){
            $control.TabIndex=$index;$index++
            if($control -is [Windows.Forms.Panel] -or $control -is [Windows.Forms.Label]){$control.TabStop=$false}
            elseif([string]::IsNullOrWhiteSpace($control.AccessibleName)){$control.AccessibleName=$control.Text.Replace('&','').TrimEnd('.')}
        }
    }
    $root.AccessibleName='iCloud Drive folder';$backup.AccessibleName='Recovery backup file'
    $root.AccessibleDescription='Choose the existing folder used by iCloud Drive.'
    $backup.AccessibleDescription='Choose a trusted recovery file for this Windows account.'
    $output.AccessibleDescription='Review the plan or result. Technical details are optional.'
    $stop.AccessibleDescription='Requests a cooperative stop. It never kills a process or changes original files.'
    $form.AccessibleName='iCloud folder setup';$form.AccessibleDescription='Preview, configure, copy, reset or restore user folder locations.'
    $fitLayout={
        $width=[Math]::Max(300,$form.ClientSize.Width-48)
        foreach($control in @($notice,$rootRow,$backupRow,$flags,$buttons,$extra,$status)){$control.MaximumSize=New-Object Drawing.Size($width,0)}
        foreach($control in @($music,$verified,$keep)){$control.MaximumSize=New-Object Drawing.Size(($width - 8),0)}
    }.GetNewClosure()
    $form.Add_SizeChanged($fitLayout);$form.Add_Shown($fitLayout)
    $verified.AccessibleDescription='Only use this fallback after checking iCloud settings when Windows has no registration. A known mismatch cannot be overridden.'
    $keep.AccessibleDescription='Original files stay where they are. Use a separate Copy files action first if you want to merge contents into the new locations.'
    $status.Add_TextChanged({
        $status.AccessibleName='Operation status: '+$status.Text
    }.GetNewClosure())
    $form.AcceptButton=$preview
    & $refresh;$status.Text='Ready. Choose an action and preview first.';$timer.Start()
    $controls
}
Export-ModuleMember -Function Get-SetupRequest,Start-SetupWorker,New-SetupWindow,Get-SetupOutcome,Get-SetupActionLabel,New-SetupConfirmation,Confirm-SetupAction
