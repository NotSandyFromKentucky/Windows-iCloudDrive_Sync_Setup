#requires -Version 5.1
Set-StrictMode -Version Latest
function Read-InstallerMetadata {
    param([Parameter(Mandatory)][string]$Path)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        if($stream.Length -gt 4MB){throw 'Installation metadata exceeds the supported 4 MiB size limit.'}
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        try{$json=$reader.ReadToEnd()}finally{$reader.Dispose()}
    }finally{$stream.Dispose()}
    $depth=0;$inString=$false;$escaped=$false
    for($index=0;$index -lt $json.Length;$index++){
        $character=$json[$index]
        if($inString){
            if($escaped){$escaped=$false;continue}
            if($character -eq '\'){$escaped=$true;continue}
            if($character -eq '"'){$inString=$false}
            continue
        }
        if($character -eq '"'){$inString=$true;continue}
        if($character -eq '{' -or $character -eq '['){
            $depth++
            if($depth -gt 16){throw 'Installation metadata exceeds the supported 16-level nesting limit.'}
        }elseif($character -eq '}' -or $character -eq ']'){
            $depth--
            if($depth -lt 0){throw 'Installation metadata has invalid nesting.'}
        }
    }
    if($inString -or $depth -ne 0){throw 'Installation metadata has invalid nesting.'}
    ConvertFrom-Json -InputObject $json
}
function Install-SetupFiles {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$InstallRoot,[Parameter(Mandatory)][string]$ProgramsDirectory,[string]$DesktopDirectory,[switch]$RequireNative)
    $sourceFull=[IO.Path]::GetFullPath($Source).TrimEnd('\')
    $manifestPath=Join-Path $sourceFull 'manifest.json'
    if(Test-Path -LiteralPath $manifestPath){
        $manifest=Read-InstallerMetadata -Path $manifestPath
        $manifestFiles=@($manifest.Files)
        if($manifestFiles.Count -gt 4199){throw 'Invalid installation file list.'}
        $files=@($manifestFiles | ForEach-Object {$_.Path})
    }else{
        $inputs=Read-InstallerMetadata -Path (Join-Path $sourceFull 'build\ReleaseFiles.json')
        $files=if($inputs -is [array]){@($inputs)}elseif($inputs.SchemaVersion -eq 2){@($inputs.Files)}else{throw 'Unsupported release input schema.'}
        if($files.Count -gt 4199){throw 'Invalid installation file list.'}
        $manifest=$null
    }
    $files=@($files | ForEach-Object {$_})
    $validatedHashes=@{}
    if($files.Count -lt 1 -or @($files | Select-Object -Unique).Count -ne $files.Count){throw 'Invalid installation file list.'}
    $manifestEntriesByPath=$null
    if($null -ne $manifest){
        # Ordinal lookup preserves the existing case-sensitive Path equality.
        $manifestEntriesByPath=[System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach($entry in @($manifest.Files)){
            $entryPath=if($null -ne $entry){[string]$entry.Path}else{''}
            if($manifestEntriesByPath.ContainsKey($entryPath)){throw 'Invalid installation file list.'}
            $manifestEntriesByPath.Add($entryPath,$entry)
        }
    }
    foreach($file in $files){
        if($file -notmatch '^[A-Za-z0-9_./-]+$' -or $file -match '(^|/)\.\.?(/|$)' -or [IO.Path]::IsPathRooted($file)){throw 'Unsafe installation file path.'}
        $path=Join-Path $sourceFull $file
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)){throw "Installation source is incomplete: $file"}
        $validatedHashes[$file]=(Get-FileHash -LiteralPath $path).Hash
        if($null -ne $manifest){
            if(-not $manifestEntriesByPath.ContainsKey($file) -or $validatedHashes[$file] -ine $manifestEntriesByPath[$file].SHA256){throw "Installation source hash mismatch: $file"}
        }
    }
    foreach($required in @('Start-ICloudFolderSetup.ps1','ICloudFolderSetup.UI.psm1','ICloudFolderSetup.Install.psm1','Install-ICloudFolderSetup.ps1','ICloudFolders.psm1')){
        if($files -notcontains $required){throw "Required installation file is missing: $required"}
    }
    $native=($files -contains 'NativeUI/ICloudFolderSetup.exe')
    $rust=($null -ne $manifest -and $manifest.PSObject.Properties['Interface'] -and $manifest.Interface -eq 'Rust' -and $files -contains 'RustUI/icloud-folder-ui.exe')
    if($RequireNative -and -not ($native -or $rust)){throw 'The native application package is incomplete. Install from a complete native package; a source checkout is not an installable native package.'}
    if($native -or $rust){foreach($required in @('tools/Invoke-WinUIBridge.ps1','tools/Invoke-WinUIInstall.ps1','ICloudFolderSetup.Launch.psm1')){if($files -notcontains $required){throw "Required native installation file is missing: $required"}}}
    if($native -and $files -notcontains 'NativeUI/folder-definitions.json'){throw 'Required native installation file is missing: NativeUI/folder-definitions.json'}
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
        if((Get-FileHash -LiteralPath $target).Hash -cne $validatedHashes[$file]){throw "Installed copy verification failed: $file. The source may have changed during installation; extract a fresh package and retry."}
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
                if($rust){
                    $shortcut.TargetPath=Join-Path $destination 'RustUI\icloud-folder-ui.exe'
                    $shortcut.Arguments=''
                }elseif($native){
                    $shortcut.TargetPath=Join-Path $destination 'NativeUI\ICloudFolderSetup.exe'
                    $shortcut.Arguments=''
                }else{
                    $shortcut.TargetPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $shortcut.Arguments='-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $destination 'Start-ICloudFolderSetup.ps1')+'"'
                }
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
