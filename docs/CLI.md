# Command-line reference

The [graphical setup](../README.md) exposes the supported operations without typed commands. This guide is for automation and advanced use. Run commands from the extracted package/repository root as the account being configured, without administrator elevation. Windows PowerShell 5.1 is the runtime used by the launchers.

All folder-setting and copy commands default to preview. Process-only execution-policy overrides shown below do not change machine policy.

## Custom iCloud destinations

From PowerShell, pass a hashtable to `-FolderPaths` for setup, iCloud copying or diagnostics. Keys are Desktop, Documents, Pictures, Videos, Downloads, Captures and optional Music. Values must be absolute local paths inside the selected iCloud root. Unspecified folders keep their default destinations; aliases always share a destination. Include `-IncludeMusic` to customize Music. Duplicate/overlapping folders are refused, except Captures may be beneath Videos. Reset and backup restore do not accept overrides.

```powershell
$paths = @{ Documents = "$env:USERPROFILE\iCloudDrive\Personal files" }
.\Set-ICloudFolders.ps1 -FolderPaths $paths
.\Copy-ICloudFolderFiles.ps1 -FolderPaths $paths
.\Test-ICloudFolders.ps1 -FolderPaths $paths
```

Keep the same overrides when separately copying, changing locations and checking them. These commands remain previews/read-only; use the documented apply flow only after reviewing the plan. The native interface retains your advanced choices for the current session.
## Preview

From this directory:

```powershell
powershell.exe -NoProfile -File .\Set-ICloudFolders.ps1
```

The default root is `$env:USERPROFILE\iCloudDrive`. Specify a different existing location when needed:

```powershell
powershell.exe -NoProfile -File .\Set-ICloudFolders.ps1 -ICloudRoot 'D:\iCloudDrive'
```

Preview displays every current and proposed registry value and warns about existing source content. It creates no folders, backups, or logs and writes no settings. Missing roots, file obstructions, unsupported registry types, and unreadable paths produce errors rather than a misleading plan.

If local execution policy blocks scripts, a one-process override can run a reviewed local script without changing the machine policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-ICloudFolders.ps1
```

`Set-ICloudFolders.cmd` is an optional launcher that forwards arguments, respects execution policy, returns the PowerShell exit code, and never pauses. Use PowerShell directly for paths containing cmd metacharacters such as `%`.

## Apply

Review the preview and decide how existing files will be handled first. Nothing copies, merges, overwrites, or deletes your existing files.

```powershell
powershell.exe -NoProfile -File .\Set-ICloudFolders.ps1 -Apply
```

The root is compared with the current account's iCloud Drive registration in Windows SyncRootManager. A mismatch stops application, even if `-VerifiedSyncRoot` is supplied. If no registration is available on your version of iCloud, manually check the root in iCloud settings and use the fallback:

```powershell
powershell.exe -NoProfile -File .\Set-ICloudFolders.ps1 -Apply -VerifiedSyncRoot
```

If a source folder contains files and its path will change, application stops. After reviewing or separately copying that content, `-AllowExistingContent` permits changing the pointer while leaving all source files in place. This flag performs no migration. The same rule applies to changing an already redirected location.

```powershell
powershell.exe -NoProfile -File .\Set-ICloudFolders.ps1 -Apply -AllowExistingContent
```

Add `-IncludeMusic` to both preview and apply if Music should be redirected. `-Apply -WhatIf` performs the apply preflight but writes nothing. `-Confirm` can request PowerShell's standard confirmation for the complete operation. Exit code `0` means preview/completion/WhatIf; `1` means failure.

## Check an existing setup

Double-click `Check-ICloudFolderSetup.cmd` for read-only diagnostics, or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ICloudFolders.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ICloudFolders.ps1 -Json
```

This checks root registration, mappings, existing destination folders and Windows folder resolution. Exit code 0 means the checks passed, 2 means configuration needs attention, and 1 means an execution error. It does not prove cloud synchronization. See [verification guidance](VERIFICATION.md) for an explicit two-way sync test, platform coverage, API evaluation and signing limits.

An observed cloud round trip passed on 2026-10-18 with iCloud for Windows 15.10.39.0: a Documents test file reached iCloud.com, was renamed there, and returned to Windows with unchanged SHA-256. Repeat this check on your own installation; it does not guarantee future synchronization or compatibility with every application.

## Backups, failures, and restore

### Reset to Windows defaults

Double-click **Reset-WindowsFolderDefaults.cmd** to open the graphical window in reset mode. Review existing files, select the acknowledgement checkbox, preview the defaults for all seven managed folders including Music, then click Apply and confirm. Cancel leaves the configuration unchanged.

For the CLI, preview first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-ICloudFolders.ps1 -ResetToDefaults
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-ICloudFolders.ps1 -ResetToDefaults -Apply -AllowExistingContent
```

Reset asks Windows for each folder's default using `SHGetKnownFolderPath` with `KF_FLAG_DEFAULT_PATH`, `KF_FLAG_NOT_PARENT_RELATIVE` and `KF_FLAG_DONT_VERIFY`. This retrieves defaults independently of current redirection, including redirected parents, without creating missing directories during preview. Typical defaults are beneath `%USERPROFILE%`: Desktop, Documents, Pictures, Videos, Downloads, Music, and `Videos\Captures`; paths are supplied by Windows rather than guessed. If Windows cannot supply a default, reset stops before making changes. Aliases use the same destinations. The operation covers only this project's mappings; OneDrive-specific entries and unrelated profile settings remain untouched. It requires no iCloud root or sign-in and cannot be combined with `-ICloudRoot`, `-VerifiedSyncRoot`, `-IncludeMusic` or `-RestoreBackup`.

No historical backup is required or read. Missing or corrupt old backups do not prevent resetting to Windows defaults. A fresh, verified backup of the current settings is still required before applying, so a failed reset can roll back. This implements Windows default-location semantics, not every undocumented side effect of Explorer's Restore Default button or its optional file-moving prompts. The checked registry backend remains in place to preserve local aliases and exact rollback.

Reset changes folder pointers only. Files in iCloud stay there; they will not automatically appear in the new local folders. Review and copy content separately if needed. CLI apply requires `-AllowExistingContent` when a changing source contains files; the graphical existing-content acknowledgement accepts leaving that content in place. Preview and `-WhatIf` remain read-only. Missing local destinations are created only after apply is approved. The same exact backup and rollback protections apply, and `-RestoreBackup` can undo a reset. Sign out/in after applying and verify Explorer and applications. Existing policies or another sync provider may reapply their own locations.

Reset passed fake-registry tests and real reset/restore checks on all three disposable Windows CI images in [run 39135664146](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/39135664146). Your account was used only for read-only preview/WhatIf, with the complete registry snapshot unchanged. The previous cloud round-trip result applies to the iCloud setup, not to local defaults. `Check-ICloudFolderSetup.cmd` checks iCloud destinations and will therefore report mismatches after an intentional reset to local defaults.

### Recovery records

Before any registry write, the tool saves and verifies:

```text
%LOCALAPPDATA%\ICloudFolderSettler\Recovery\<timestamp>-<unique-id>\before.json
%LOCALAPPDATA%\ICloudFolderSettler\Recovery\<timestamp>-<unique-id>\operation.log
```

The backup records exact unexpanded strings, registry types, and whether each value originally existed. It is bound to the account SID and the specific registry key. It is local to this machine/account, contains personal paths, and should not be committed. Backups are retained until you choose to remove them.

Destination creation and write-access probes complete before registry changes. Writes are checked immediately and at completion. A failure after writes begin triggers best-effort restoration of all affected values, including deletion of newly introduced values. If rollback itself fails, the error explicitly says `ROLLBACK INCOMPLETE` and identifies the backup. Read the log and correct the underlying permissions or availability problem before restoring.

Preview and then restore a trusted backup:

```powershell
powershell.exe -NoProfile -File .\Set-ICloudFolders.ps1 -RestoreBackup 'C:\path\to\before.json'
powershell.exe -NoProfile -File .\Set-ICloudFolders.ps1 -RestoreBackup 'C:\path\to\before.json' -Apply
```

Restore checks the backup schema, SID, value-name allowlist, and original destination availability. It also makes a new backup of current values, so restoration can be reversed. It changes settings only; files remain where they are. Do not edit recovery JSON or load untrusted backups.

Preflight failures are printed to the console. Logs start only after apply is approved and recovery storage is ready. New destination directories can remain after a failed operation; the tool deliberately does not delete them or their contents. A process crash, shutdown, or power failure cannot trigger automatic rollback: use the printed backup manually. The mutex prevents concurrent instances of this tool for the account, but other applications can still change folder settings.

## Explicit copy and merge

Preview or dry-run before applying:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Copy-ICloudFolderFiles.ps1 -ICloudRoot 'D:\iCloudDrive'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Copy-ICloudFolderFiles.ps1 -ICloudRoot 'D:\iCloudDrive' -Apply -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Copy-ICloudFolderFiles.ps1 -ICloudRoot 'D:\iCloudDrive' -Apply
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Copy-ICloudFolderFiles.ps1 -ResetToDefaults
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Copy-ICloudFolderFiles.ps1 -ResetToDefaults -Apply
~~~

Copy supports optional Music and the manually verified iCloud-root fallback when Windows has no registration. A known registration mismatch cannot be overridden. Defaults include all managed folders including Music. Copying does not change folder locations: apply setup or reset separately after verification. Originals are retained, identical files are skipped, and different same-name files abort before writes. See the [copy workflow and limitations](../README.md#copy-and-merge-existing-files).

## Legacy console wrapper

Open-ICloudFolderSetup.ps1 retains its text-based preview and exact APPLY/RESET confirmation for existing users. The CMD Explorer launchers now open the graphical window; Set-ICloudFolders.cmd remains the unattended CLI launcher. Keep these compatibility entry points together with their modules.

## Further references

- [Verification, cloud round-trip procedure and signing](VERIFICATION.md)
- [Development and release workflow](DEVELOPMENT.md)
