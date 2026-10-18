#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ShellKey = 'Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'

function Get-FolderMap {
    param([switch]$IncludeMusic)
    # Registry aliases are deliberately explicit. No OneDrive-specific IDs.
    $map = [ordered]@{
        'Desktop' = 'Desktop'
        '{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}' = 'Desktop' # Local Desktop
        'Personal' = 'Documents'
        '{F42EE2D3-909F-4907-8871-4C22FC0BF756}' = 'Documents' # Local Documents
        'My Pictures' = 'Pictures'
        '{0DDD015D-B06C-45D5-8C4C-F59713854639}' = 'Pictures' # Local Pictures
        'My Video' = 'Videos'
        '{35286A68-3C57-41A1-BBB1-0EAE73D76C95}' = 'Videos' # Local Videos
        '{374DE290-123F-4565-9164-39C4925E467B}' = 'Downloads'
        '{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}' = 'Downloads' # Local Downloads
        '{EDC0FE71-98D8-4F4A-B920-C8DC133CB165}' = 'Videos\Captures'
    }
    if ($IncludeMusic) {
        $map['My Music'] = 'Music'
        $map['{A0C69A99-21C8-4671-8703-7934162FCF1D}'] = 'Music' # Local Music
    }
    return $map
}

function Get-UserSid { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Get-RecoveryRoot { Get-NormalPath (Join-Path $env:LOCALAPPDATA 'ICloudFolderSettler\Recovery') }

function Get-RegisteredICloudRoots {
    $base = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager')
    if (-not $base) { return }
    try {
        foreach ($name in $base.GetSubKeyNames()) {
            if ($name -notlike 'iCloudDrive!*') { continue }
            $roots = $base.OpenSubKey($name + '\UserSyncRoots')
            if ($roots) {
                try {
                    $path = $roots.GetValue((Get-UserSid))
                    if ($path) { Get-NormalPath $path }
                } finally { $roots.Dispose() }
            }
        }
    } finally { $base.Dispose() }
}

function Read-FolderValue {
    param([string]$Name)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:ShellKey)
    try {
        if ($null -eq $key -or $key.GetValueNames() -notcontains $Name) {
            return [pscustomobject]@{ Name=$Name; Exists=$false; Kind=$null; Data=$null }
        }
        $kind = $key.GetValueKind($Name).ToString()
        if ($kind -notin @('String','ExpandString')) { throw "Unsupported registry type for ${Name}: $kind" }
        [pscustomobject]@{
            Name=$Name; Exists=$true; Kind=$kind
            Data=$key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } finally { if ($key) { $key.Dispose() } }
}

function Write-FolderValue {
    param($Value)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:ShellKey, $true)
    if (-not $key) { throw 'User Shell Folders key is missing or not writable.' }
    try {
        if ($Value.Exists) {
            $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind], $Value.Kind)
            $key.SetValue($Value.Name, [string]$Value.Data, $kind)
        } else { $key.DeleteValue($Value.Name, $false) }
        $key.Flush()
    } finally { $key.Dispose() }
}

function Assert-Values {
    param([object[]]$Values)
    foreach ($value in $Values) {
        $actual = Read-FolderValue $value.Name
        if ($actual.Exists -ne $value.Exists -or $actual.Kind -cne $value.Kind -or $actual.Data -cne $value.Data) {
            throw "Read-back mismatch: $($value.Name)"
        }
    }
}

function Get-NormalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty path is not allowed.' }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -match '%[^%]+%') { throw "Unresolved environment variable: $Path" }
    if ($expanded -notmatch '^[A-Za-z]:\\') { throw "An absolute local drive path is required: $Path" }
    $full = [IO.Path]::GetFullPath($expanded)
    if ($full.TrimEnd('\') -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw 'A drive root cannot be used as a user folder.' }
    $full.TrimEnd('\')
}

function Test-WithinPath {
    param([string]$Path, [string]$Parent)
    $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-DirectoryPath {
    param([string]$Path)
    $cursor = $Path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if (-not (Get-Item -LiteralPath $cursor -Force).PSIsContainer) { throw "Path is occupied by a file: $cursor" }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Test-DestinationAccess {
    param([string[]]$Paths)
    foreach ($path in $Paths) {
        $null = [IO.Directory]::CreateDirectory($path)
        # Probe actual write access; remove only our unique probe file.
        $probe = Join-Path $path ('.icloud-folder-probe-' + [guid]::NewGuid().ToString('N'))
        $stream = [IO.File]::Open($probe, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        Remove-Item -LiteralPath $probe -ErrorAction Stop
    }
}

function Assert-Backup {
    param($Backup)
    if ($Backup.Version -ne 1 -or $Backup.Sid -ne (Get-UserSid) -or $Backup.Key -cne $script:ShellKey) {
        throw 'Backup schema, user SID, or registry key does not match.'
    }
    $allowed = Get-FolderMap -IncludeMusic
    $seen = @{}
    if (@($Backup.Values).Count -eq 0) { throw 'Backup has no values.' }
    foreach ($v in $Backup.Values) {
        if (-not $allowed.Contains($v.Name) -or $seen.ContainsKey($v.Name)) { throw "Unexpected or duplicate backup value: $($v.Name)" }
        $seen[$v.Name] = $true
        if ($v.Exists -isnot [bool]) { throw 'Invalid existence flag in backup.' }
        if ($v.Exists) {
            if ($v.Kind -notin @('String','ExpandString') -or $v.Data -isnot [string]) { throw 'Invalid registry value in backup.' }
            $null = Get-NormalPath $v.Data
        } elseif ($null -ne $v.Kind -or $null -ne $v.Data) { throw 'Invalid absent value in backup.' }
    }
}

function Invoke-ICloudFolders {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ICloudRoot = "$env:USERPROFILE\iCloudDrive",
        [switch]$Apply, [switch]$VerifiedSyncRoot, [switch]$IncludeMusic,
        [switch]$AllowExistingContent, [string]$RestoreBackup
    )
    $mutex = New-Object Threading.Mutex($false, ('Local\ICloudFolders-' + (Get-UserSid)))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another ICloudFolders operation is running for this user.' }
        $recoveryRoot = Get-RecoveryRoot
        $before = @()
        $desired = @()
        $destinations = @()
        $contentWarnings = @()
        $registeredRoots = @()
        if ($RestoreBackup) {
            $backup = Get-Content -LiteralPath $RestoreBackup -Raw | ConvertFrom-Json
            Assert-Backup $backup
            $desired = @($backup.Values)
            foreach ($v in $desired) {
                $before += Read-FolderValue $v.Name
                if ($v.Exists) {
                    $path = Get-NormalPath $v.Data
                    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Restore destination is unavailable: $path" }
                }
            }
        } else {
            $root = Get-NormalPath $ICloudRoot
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "iCloud root must already exist: $root" }
            $registeredRoots = @(Get-RegisteredICloudRoots)
            $map = Get-FolderMap -IncludeMusic:$IncludeMusic
            foreach ($name in $map.Keys) {
                $old = Read-FolderValue $name
                $before += $old
                $target = Join-Path $root $map[$name]
                $destinations += $target
                $desired += [pscustomobject]@{ Name=$name; Exists=$true; Kind='ExpandString'; Data=$target }
                if ($old.Exists) {
                    $source = Get-NormalPath $old.Data
                    if ($source -ine $target -and (Test-Path -LiteralPath $source -PathType Container)) {
                        $item = Get-ChildItem -LiteralPath $source -Force | Select-Object -First 1
                        if ($item -and -not $AllowExistingContent) {
                            $contentWarnings += "Existing content at '$source'. No files are moved. Review it, then use -AllowExistingContent to redirect anyway."
                        }
                    }
                }
            }
        }
        foreach ($v in @($before) + @($desired)) {
            if ($v.Exists -and (Test-WithinPath $recoveryRoot (Get-NormalPath $v.Data))) {
                throw 'Recovery storage is inside a source or destination folder. Resolve this before applying.'
            }
        }
        $destinations = @($destinations | Select-Object -Unique)
        foreach ($path in $destinations) { Assert-DirectoryPath $path }
        $plan = for ($i=0; $i -lt $desired.Count; $i++) {
            [pscustomobject]@{ Name=$desired[$i].Name; Current=$before[$i].Data; Proposed=$desired[$i].Data; ExistsAfter=$desired[$i].Exists }
        }
        $plan | Format-List Name, Current, Proposed, ExistsAfter | Out-Host
        foreach ($message in @($contentWarnings | Select-Object -Unique)) { Write-Warning $message }
        if (-not $Apply) { Write-Host 'Preview only. Use -Apply to change settings. No files are moved.'; return }
        if ($contentWarnings.Count) { throw 'Existing source content requires review. See the warnings above.' }
        if (-not $RestoreBackup) {
            if ($registeredRoots.Count -gt 0 -and $registeredRoots -notcontains $root) {
                throw "Requested root does not match this user's registered iCloud root(s): $($registeredRoots -join ', ')"
            }
            if ($registeredRoots.Count -eq 0 -and -not $VerifiedSyncRoot) {
                throw 'No registered iCloud root was found. Confirm the active root in iCloud settings, then supply -VerifiedSyncRoot. Sync health cannot be established by this tool.'
            }
        }
        if (-not $PSCmdlet.ShouldProcess('Current user folder settings', 'Back up and apply the displayed plan')) { return }
        $null = [IO.Directory]::CreateDirectory($recoveryRoot)
        $run = Join-Path $recoveryRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
        $null = [IO.Directory]::CreateDirectory($run)
        $backupPath = Join-Path $run 'before.json'
        $log = Join-Path $run 'operation.log'
        $record = [pscustomobject]@{ Version=1; Sid=(Get-UserSid); Key=$script:ShellKey; CreatedUtc=[DateTime]::UtcNow.ToString('o'); Values=@($before) }
        $record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $backupPath -Encoding UTF8
        $saved = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
        Assert-Backup $saved
        if (($saved.Values | ConvertTo-Json -Depth 6 -Compress) -cne ($before | ConvertTo-Json -Depth 6 -Compress)) {
            throw "Backup round-trip mismatch: $backupPath"
        }
        Assert-Values $saved.Values
        Write-Host "Recovery backup: $backupPath"
        "Started $([DateTime]::UtcNow.ToString('o'))" | Set-Content -LiteralPath $log
        $writesStarted = $false
        try {
            Test-DestinationAccess $destinations
            # Detect competing changes since the plan/backup was taken.
            Assert-Values $before
            foreach ($v in $desired) {
                $writesStarted = $true
                Write-FolderValue $v
                Assert-Values @($v)
                "Verified $($v.Name)" | Add-Content -LiteralPath $log
            }
            Assert-Values $desired
            'Completed' | Add-Content -LiteralPath $log
        } catch {
            $failure = $_.Exception.Message
            $rollbackErrors = @()
            if ($writesStarted) {
                foreach ($v in $before) {
                    try { Write-FolderValue $v; Assert-Values @($v) } catch { $rollbackErrors += $_.Exception.Message }
                }
            }
            $status = if ($rollbackErrors.Count) { 'ROLLBACK INCOMPLETE: ' + ($rollbackErrors -join '; ') } else { 'Original settings retained/restored.' }
            try { "$failure`r`n$status" | Add-Content -LiteralPath $log } catch { }
            throw "$failure $status Recovery backup: $backupPath"
        }
        Write-Host "Settings verified. Sign out and sign back in, then verify Explorer and applications. Cloud sync was not tested. Log: $log"
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Export-ModuleMember -Function Invoke-ICloudFolders
