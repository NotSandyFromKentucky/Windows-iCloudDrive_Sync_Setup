param([ValidateSet('Window','Fail','Timeout')][string]$Mode='Window',[string]$PidFile)
$ErrorActionPreference='Stop'
if([ICloudTestDesktop]::CurrentName() -eq [ICloudTestDesktop]::InputName()){throw 'Probe is on the input desktop.'}
switch($Mode){
    Window {
        if($PSVersionTable.PSVersion.Major -ne 5){throw 'Hidden fixture did not use Windows PowerShell 5.1.'}
        $hash=Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256
        if($hash.Hash.Length -ne 64){throw 'Built-in hashing unavailable in hidden child.'}
        Add-Type -AssemblyName System.Windows.Forms
        $form=New-Object Windows.Forms.Form
        try{
            $form.Text='Hidden test fixture';$form.Show();[Windows.Forms.Application]::DoEvents()
            if(-not $form.Visible){throw 'Fixture did not create a visible window on the hidden desktop.'}
            if([ICloudTestDesktop]::CurrentName() -eq [ICloudTestDesktop]::InputName()){throw 'Input desktop switched.'}
            'PASS: fixture window exists on the non-input desktop'
            'PASS: Windows PowerShell built-in modules resolve independently of parent module paths'
        }finally{$form.Dispose()}
    }
    Fail {throw 'Expected hidden-desktop fixture failure'}
    Timeout {
        $exe=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $worker=Start-Process -FilePath $exe -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 120"' -WindowStyle Hidden -PassThru
        [IO.File]::WriteAllText($PidFile,[string]$worker.Id)
        Start-Sleep -Seconds 120
    }
}
