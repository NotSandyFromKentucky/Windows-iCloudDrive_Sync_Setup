#requires -Version 5.1
$ErrorActionPreference='Stop'
try{
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'ICloudFolderSetup.Install.psm1') -Force
$form=New-Object Windows.Forms.Form
$form.Text='Install iCloud folder setup';$form.Size=New-Object Drawing.Size(570,330);$form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10);$form.FormBorderStyle='FixedDialog';$form.MaximizeBox=$false
$panel=New-Object Windows.Forms.FlowLayoutPanel;$panel.Dock='Fill';$panel.Padding=New-Object Windows.Forms.Padding(18);$panel.FlowDirection='TopDown';$panel.WrapContents=$false
$form.Controls.Add($panel)
$label=New-Object Windows.Forms.Label;$label.AutoSize=$false;$label.Size=New-Object Drawing.Size(510,115)
$label.Text="Install application files for your Windows account and add a Start menu shortcut. No administrator access is needed. Installation does not change folder locations or move files. You can also cancel and run the extracted copy without installing."
$panel.Controls.Add($label)
$desktop=New-Object Windows.Forms.CheckBox;$desktop.Text='Also add a desktop shortcut';$desktop.AutoSize=$true;$panel.Controls.Add($desktop)
$button=New-Object Windows.Forms.Button;$button.Text='Install for me';$button.AutoSize=$true;$panel.Controls.Add($button)
$status=New-Object Windows.Forms.Label;$status.AutoSize=$false;$status.Size=New-Object Drawing.Size(510,60);$panel.Controls.Add($status)
$button.Add_Click({
    $button.Enabled=$false
    try{
        $options=@{Source=$PSScriptRoot;InstallRoot=(Join-Path $env:LOCALAPPDATA 'Programs\ICloudFolderSettler');ProgramsDirectory=([Environment]::GetFolderPath('Programs'))}
        if($desktop.Checked){$options.DesktopDirectory=[Environment]::GetFolderPath('DesktopDirectory')}
        $installed=Install-SetupFiles @options
        $status.Text='Installed. Open "iCloud folder setup" from the Start menu.'
        $button.Text='Installed'
        [Windows.Forms.MessageBox]::Show($form,('Installed to '+$installed.Directory+'. Your folder settings were not changed.'),'Installation complete') | Out-Null
    }catch{$status.Text=$_.Exception.Message;$button.Enabled=$true}
})
try{$null=$form.ShowDialog()}finally{$form.Dispose()}

}catch{Add-Type -AssemblyName System.Windows.Forms;[Windows.Forms.MessageBox]::Show($_.Exception.Message,'Installer could not start','OK','Error') | Out-Null;exit 1}
