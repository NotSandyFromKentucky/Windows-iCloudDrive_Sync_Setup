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
        if($scriptFile -eq 'Set-ICloudFolders.ps1'){
            if($Phase -ne 'Preview'){$options.Apply=$true}
            if($Phase -eq 'DryRun'){$options.WhatIf=$true}
        } elseif($Phase -ne 'Apply'){$options.WhatIf=$true}
    }
    [pscustomobject]@{Script=$scriptFile;Options=$options;Mutates=$mutates;Action=$Action}
}
function Start-SetupWorker {
    param([string]$Source,$Request)
    # Encode a data object rather than interpolating user paths into executable code.
    $data=[pscustomobject]@{Path=(Join-Path $Source $Request.Script);Options=$Request.Options}
    $encodedData=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Depth 5 -Compress)))
    $command='$ErrorActionPreference="Stop";$d=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String("'+$encodedData+'")) | ConvertFrom-Json;$o=@{};foreach($p in $d.Options.PSObject.Properties){$o[$p.Name]=$p.Value};try{& $d.Path @o}catch{[Console]::Error.WriteLine($_.Exception.Message);exit 1}'
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName='powershell.exe'
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info.WorkingDirectory=$Source
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $info.StandardOutputEncoding=[Text.Encoding]::UTF8
    $info.StandardErrorEncoding=[Text.Encoding]::UTF8
    # Child console output explicitly uses UTF-8 to preserve international paths.
    $command='[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false);'+$command
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process=[Diagnostics.Process]::Start($info)
    [pscustomobject]@{Process=$process;Output=$process.StandardOutput.ReadToEndAsync();Error=$process.StandardError.ReadToEndAsync()}
}
function New-SetupWindow {
    param([string]$Source,[string]$InitialAction='Set up iCloud folders',[scriptblock]$ConfirmAction={param($Owner,$Message) [Windows.Forms.MessageBox]::Show($Owner,$Message,'Confirm action','YesNo','Warning','Button2') -eq 'Yes'})
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $form=New-Object Windows.Forms.Form
    $form.Text='iCloud folder setup';$form.Size=New-Object Drawing.Size(930,760)
    $form.MinimumSize=New-Object Drawing.Size(760,650);$form.StartPosition='CenterScreen'
    $form.Font=New-Object Drawing.Font('Segoe UI',10)
    $layout=New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(16)
    $layout.ColumnCount=1;$layout.RowCount=8
    foreach($height in @(48,40,40,40,110,44,34)){ $null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,$height))) }
    $null=$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
    $form.Controls.Add($layout)
    $notice=New-Object Windows.Forms.Label
    $notice.Text='Preview before applying. Existing files stay where they are. Run as your own Windows account; no administrator access is needed.'
    $notice.Dock='Fill';$layout.Controls.Add($notice,0,0)
    $actions=@('Set up iCloud folders','Reset to Windows defaults','Restore a recovery backup','Check iCloud configuration','Create cloud test file','Check cloud return','Clean up cloud test file')
    $action=New-Object Windows.Forms.ComboBox
    $action.DropDownStyle='DropDownList';$action.Dock='Fill';$action.AccessibleName='Action'
    $action.Items.AddRange([object[]]$actions);$action.SelectedItem=$InitialAction
    if($action.SelectedIndex -lt 0){$action.SelectedIndex=0};$layout.Controls.Add($action,0,1)
    $rootRow=New-Object Windows.Forms.TableLayoutPanel
    $rootRow.Dock='Fill';$rootRow.ColumnCount=3
    $null=$rootRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,110)))
    $null=$rootRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
    $null=$rootRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,100)))
    $rootLabel=New-Object Windows.Forms.Label;$rootLabel.Text='iCloud folder';$rootLabel.Dock='Fill'
    $root=New-Object Windows.Forms.TextBox;$root.Text=Join-Path $env:USERPROFILE 'iCloudDrive';$root.Dock='Fill';$root.AccessibleName='iCloud Drive root'
    $browseRoot=New-Object Windows.Forms.Button;$browseRoot.Text='Browse...';$browseRoot.Dock='Fill'
    $rootRow.Controls.Add($rootLabel,0,0);$rootRow.Controls.Add($root,1,0);$rootRow.Controls.Add($browseRoot,2,0);$layout.Controls.Add($rootRow,0,2)
    $backupRow=New-Object Windows.Forms.TableLayoutPanel
    $backupRow.Dock='Fill';$backupRow.ColumnCount=3
    foreach($s in $rootRow.ColumnStyles){$null=$backupRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle($s.SizeType,$s.Width)))}
    $backupLabel=New-Object Windows.Forms.Label;$backupLabel.Text='Recovery file';$backupLabel.Dock='Fill'
    $backup=New-Object Windows.Forms.TextBox;$backup.Dock='Fill';$backup.AccessibleName='Recovery backup file'
    $browseBackup=New-Object Windows.Forms.Button;$browseBackup.Text='Choose...';$browseBackup.Dock='Fill'
    $backupRow.Controls.Add($backupLabel,0,0);$backupRow.Controls.Add($backup,1,0);$backupRow.Controls.Add($browseBackup,2,0);$layout.Controls.Add($backupRow,0,3)
    $flags=New-Object Windows.Forms.FlowLayoutPanel;$flags.Dock='Fill';$flags.FlowDirection='TopDown';$flags.WrapContents=$false
    $music=New-Object Windows.Forms.CheckBox;$music.Text='Include Music (reset always includes Music)';$music.AutoSize=$true
    $verified=New-Object Windows.Forms.CheckBox;$verified.Text='I verified this active root in iCloud settings (only needed if Windows has no registration)';$verified.AutoSize=$true
    $keep=New-Object Windows.Forms.CheckBox;$keep.Text='I reviewed existing source files and accept leaving them in their current locations';$keep.AutoSize=$true
    $flags.Controls.AddRange(@($music,$verified,$keep));$layout.Controls.Add($flags,0,4)
    $buttons=New-Object Windows.Forms.FlowLayoutPanel;$buttons.Dock='Fill'
    $preview=New-Object Windows.Forms.Button;$preview.Text='Preview / Check';$preview.AutoSize=$true
    $dry=New-Object Windows.Forms.Button;$dry.Text='Dry run';$dry.AutoSize=$true
    $apply=New-Object Windows.Forms.Button;$apply.Text='Apply...';$apply.AutoSize=$true;$apply.Enabled=$false
    $install=New-Object Windows.Forms.Button;$install.Text='Install for me...';$install.AutoSize=$true
    $recovery=New-Object Windows.Forms.Button;$recovery.Text='Recovery files';$recovery.AutoSize=$true
    $help=New-Object Windows.Forms.Button;$help.Text='Help';$help.AutoSize=$true
    $buttons.Controls.AddRange(@($preview,$dry,$apply,$install,$recovery,$help));$layout.Controls.Add($buttons,0,5)
    $extra=New-Object Windows.Forms.FlowLayoutPanel;$extra.Dock='Fill'
    $json=New-Object Windows.Forms.CheckBox;$json.Text='Show diagnostics as JSON';$json.AutoSize=$true
    $save=New-Object Windows.Forms.Button;$save.Text='Save displayed result...';$save.AutoSize=$true
    $extra.Controls.AddRange(@($json,$save));$layout.Controls.Add($extra,0,6)
    $output=New-Object Windows.Forms.TextBox;$output.Multiline=$true;$output.ReadOnly=$true;$output.ScrollBars='Both';$output.WordWrap=$false;$output.Dock='Fill'
    $output.Font=New-Object Drawing.Font('Consolas',10);$output.AccessibleName='Plan and results'
    $output.Text='Choose an action and click Preview / Check. No folder settings have been changed.'
    $layout.Controls.Add($output,0,7)
    $state=@{Worker=$null;Fingerprint=$null;RunningRequest=$null;Phase=$null}
    $controls=@{Form=$form;Action=$action;Root=$root;Backup=$backup;Music=$music;Verified=$verified;KeepFiles=$keep;Json=$json;Preview=$preview;DryRun=$dry;Apply=$apply;Output=$output;Install=$install}
    $getRequest={param($phase) Get-SetupRequest -Action $action.Text -Root $root.Text -Backup $backup.Text -Music $music.Checked -Verified $verified.Checked -KeepFiles $keep.Checked -Json $json.Checked -Phase $phase}.GetNewClosure()
    $invalidate={$state.Fingerprint=$null;$apply.Enabled=$false}.GetNewClosure()
    $refresh={
        & $invalidate
        $setup=$action.Text -eq 'Set up iCloud folders'
        $rootRow.Enabled=$setup -or $action.Text -eq 'Check iCloud configuration'
        $backupRow.Enabled=$action.Text -eq 'Restore a recovery backup'
        $music.Enabled=$rootRow.Enabled;$verified.Enabled=$setup
        $keep.Enabled=$setup -or $action.Text -eq 'Reset to Windows defaults'
        $json.Enabled=$action.Text -eq 'Check iCloud configuration'
        $dry.Enabled=$action.Text -notin @('Check iCloud configuration','Check cloud return')
        $output.Text=switch($action.Text){
            'Reset to Windows defaults' {'Reset uses Windows defaults for all seven managed folders. Old backups are not needed. Files in iCloud stay there; review the plan before applying.'}
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
                if($request.Action -eq 'Create cloud test file'){$message='Create the small verification file in your iCloud Documents folder?'}
                if($request.Action -eq 'Clean up cloud test file'){$message='Delete the exact verification file(s)? This deletion will synchronize to iCloud and other devices.'}
                if(-not (& $ConfirmAction $form $message)){return}
            }
            $state.Worker=Start-SetupWorker -Source $Source -Request $request
            $state.RunningRequest=$request;$state.Phase=$phase
            $state.Fingerprint=$null
            foreach($c in @($action,$rootRow,$backupRow,$flags,$buttons,$extra)){$c.Enabled=$false}
            $output.Text='Working... Please keep this window open. No automatic file migration is performed.'
        }catch{$output.Text=$_.Exception.Message;$apply.Enabled=$false}
    }.GetNewClosure()
    $preview.Add_Click({& $run 'Preview'}.GetNewClosure())
    $dry.Add_Click({& $run 'DryRun'}.GetNewClosure())
    $apply.Add_Click({& $run 'Apply'}.GetNewClosure())
    $timer=New-Object Windows.Forms.Timer;$timer.Interval=150
    $timer.Add_Tick({
        if($null -eq $state.Worker -or -not $state.Worker.Process.HasExited){return}
        $worker=$state.Worker
        if(-not $worker.Output.IsCompleted -or -not $worker.Error.IsCompleted){return}
        $code=$worker.Process.ExitCode;$text=$worker.Output.Result+[Environment]::NewLine+$worker.Error.Result
        $output.Text=$text+[Environment]::NewLine+'Exit code: '+$code
        $worker.Process.Dispose();$state.Worker=$null
        foreach($c in @($action,$rootRow,$backupRow,$flags,$buttons,$extra)){$c.Enabled=$true}
        # Restore applicability without replacing the result.
        $resultText=$output.Text;& $refresh;$output.Text=$resultText
        if($code -eq 0 -and $state.Phase -in @('Preview','DryRun') -and $state.RunningRequest.Mutates){
            $state.Fingerprint=(& $getRequest 'Preview') | ConvertTo-Json -Depth 5 -Compress
            $apply.Enabled=$true
        }
    }.GetNewClosure())
    $form.Add_FormClosing({param($sender,$event) if($null -ne $state.Worker){$event.Cancel=$true;[Windows.Forms.MessageBox]::Show($form,'An operation is running. Wait for its result before closing.','Please wait') | Out-Null}}.GetNewClosure())
    $form.Add_FormClosed({$timer.Stop();$timer.Dispose()}.GetNewClosure())
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
    & $refresh;$timer.Start()
    $controls
}
Export-ModuleMember -Function Get-SetupRequest,Start-SetupWorker,New-SetupWindow
