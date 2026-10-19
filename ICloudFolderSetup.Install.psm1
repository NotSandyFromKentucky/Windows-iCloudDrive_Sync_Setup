#requires -Version 5.1
Set-StrictMode -Version Latest
function Install-SetupFiles {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$ProgramsDirectory,[string]$DesktopDirectory)
    $sourceFull=[IO.Path]::GetFullPath($Source).TrimEnd('\')
    $manifestPath=Join-Path $sourceFull 'manifest.json'
    if(Test-Path -LiteralPath $manifestPath){
        $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        $files=@($manifest.Files | ForEach-Object {$_.Path})
    }else{
        $files=@(Get-Content -LiteralPath (Join-Path $sourceFull 'build\ReleaseFiles.json') -Raw | ConvertFrom-Json)
        $manifest=$null
    }
    $files=@($files | ForEach-Object {$_})
    if($files.Count -lt 1 -or @($files | Select-Object -Unique).Count -ne $files.Count){throw 'Invalid installation file list.'}
    foreach($file in $files){
        if($file -notmatch '^[A-Za-z0-9_./-]+$' -or $file -match '(^|/)\.\.?(/|$)' -or [IO.Path]::IsPathRooted($file)){throw 'Unsafe installation file path.'}
        $path=Join-Path $sourceFull $file
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Installation source is incomplete: $file"}
        if($null -ne $manifest){
            $entry=@($manifest.Files | Where-Object {$_.Path -ceq $file})
            if($entry.Count -ne 1 -or (Get-FileHash -LiteralPath $path).Hash -ine $entry[0].SHA256){throw "Installation source hash mismatch: $file"}
        }
    }
    foreach($required in @('Start-ICloudFolderSetup.ps1','ICloudFolderSetup.UI.psm1','ICloudFolderSetup.Install.psm1','Install-ICloudFolderSetup.ps1','ICloudFolders.psm1')){
        if($files -notcontains $required){throw "Required installation file is missing: $required"}
    }
    $version=(Get-Content -LiteralPath (Join-Path $sourceFull 'VERSION') -Raw).Trim()
    if($version -notmatch '^\d+\.\d+\.\d+$'){throw 'Invalid version.'}
    $destination=Join-Path ([IO.Path]::GetFullPath($InstallRoot)) ($version+'-'+[guid]::NewGuid().ToString('N'))
    if(-not $PSCmdlet.ShouldProcess($destination,'Copy verified application files and create current-user shortcuts')){return}
    $null=[IO.Directory]::CreateDirectory($destination)
    # Each installation gets a unique directory; existing binaries or data are never overwritten.
    foreach($file in $files){
        $target=Join-Path $destination $file
        $null=[IO.Directory]::CreateDirectory((Split-Path $target))
        Copy-Item -LiteralPath (Join-Path $sourceFull $file) -Destination $target -ErrorAction Stop
        if((Get-FileHash -LiteralPath $target).Hash -cne (Get-FileHash -LiteralPath (Join-Path $sourceFull $file)).Hash){throw "Installed copy verification failed: $file"}
    }
    if($null -ne $manifest){Copy-Item -LiteralPath $manifestPath -Destination $destination}
    # Checkout installs retain the central list so they can be installed again from the GUI.
    else{
        $null=[IO.Directory]::CreateDirectory((Join-Path $destination 'build'))
        Copy-Item -LiteralPath (Join-Path $sourceFull 'build\ReleaseFiles.json') -Destination (Join-Path $destination 'build\ReleaseFiles.json')
    }
    $shell=New-Object -ComObject WScript.Shell
    $shortcuts=@()
    try{
        foreach($directory in @($ProgramsDirectory,$DesktopDirectory) | Where-Object {$_}){
            $null=[IO.Directory]::CreateDirectory($directory)
            $link=Join-Path $directory 'iCloud folder setup.lnk'
            if(Test-Path -LiteralPath $link){
                $backup=Join-Path $destination ('previous-shortcut-'+[guid]::NewGuid().ToString('N')+'.lnk')
                Copy-Item -LiteralPath $link -Destination $backup
            }
            $shortcut=$shell.CreateShortcut($link)
            try{
                $shortcut.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $shortcut.Arguments='-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $destination 'Start-ICloudFolderSetup.ps1')+'"'
                $shortcut.WorkingDirectory=$destination
                $shortcut.Description='Preview, configure, check, reset or restore Windows iCloud folder locations.'
                $shortcut.Save()
            }finally{if($shortcut){$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)}}
            if(-not(Test-Path -LiteralPath $link)){throw 'Shortcut creation failed.'}
            $shortcuts+=$link
        }
    }finally{$null=[Runtime.InteropServices.Marshal]::ReleaseComObject($shell)}
    [pscustomobject]@{Directory=$destination;Shortcuts=$shortcuts;Version=$version}
}
Export-ModuleMember -Function Install-SetupFiles
