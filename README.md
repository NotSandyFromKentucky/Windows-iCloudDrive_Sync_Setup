# iCloud home folder settler

Preview and redirect selected Windows user folders into an existing iCloud Drive root. The tool changes paths for the current account; it does not install iCloud, enable synchronization, or move files.

## Download

Get the versioned ZIP from [GitHub Releases](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/releases/latest), extract the entire ZIP, and double-click `Open-ICloudFolderSetup.cmd` inside the extracted folder. Keep the scripts together; the launcher needs its accompanying PowerShell module and script. Each release includes `SHA256SUMS.txt` for checking the download. Starting with v2.1.0, packages also contain a per-file manifest and signature state.

See [CHANGELOG.md](CHANGELOG.md) for changes from the legacy batch release.

## Requirements

- Windows with Windows PowerShell 5.1 and iCloud for Windows already configured.
- Run as the account whose folders you want to change. Administrator access is unnecessary; do not run as a different administrator account.
- Confirm iCloud is signed in and the intended root is available. A registered provider path proves configuration, not working synchronization.

Windows PowerShell 5.1 is the tested runtime. Windows/iCloud integration still requires testing in an isolated account or VM before deployment to other machines. There are no third-party dependencies or Java requirements.

## Run from Explorer

Double-click **`Open-ICloudFolderSetup.cmd`**. It displays the default preview and asks you to type `APPLY` before changing settings. Press Enter to cancel. The window stays open afterward so you can read the result and backup path. Run it normally as your own account; administrator access is unnecessary.

This launcher uses an execution-policy override for its PowerShell process only. It uses the default root and leaves Music off. Existing-content and root-validation checks still apply; use the CLI options below if you need a custom root or have reviewed content that must remain in its old location.

## Check an existing setup

Double-click `Check-ICloudFolderSetup.cmd` for read-only diagnostics, or run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ICloudFolders.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ICloudFolders.ps1 -Json
```

This checks root registration, mappings, existing destination folders and Windows folder resolution. Exit code 0 means the checks passed, 2 means configuration needs attention, and 1 means an execution error. It does not prove cloud synchronization. See [verification guidance](docs/VERIFICATION.md) for an explicit two-way sync test, platform coverage, API evaluation and signing limits.

An observed cloud round trip passed on 2026-10-18 with iCloud for Windows 15.10.39.0: a Documents test file reached iCloud.com, was renamed there, and returned to Windows with unchanged SHA-256. Repeat this check on your own installation; it does not guarantee future synchronization or compatibility with every application.

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

## Folder scope

| Folder | Destination beneath root | Default |
| --- | --- | --- |
| Desktop | `Desktop` | Included |
| Documents | `Documents` | Included |
| Pictures | `Pictures` | Included |
| Videos | `Videos` | Included |
| Downloads | `Downloads` | Included |
| Captures | `Videos\Captures` | Included |
| Music | `Music` | Opt in |

Legacy named entries and local-folder aliases point to the same destination. `Images` is no longer a separate Pictures destination. OneDrive-specific entries, AppData, Start Menu, Startup, and unrelated settings are untouched. Existing `Images` contents are not merged into `Pictures`; review them separately if you used the old scripts.

## Backups, failures, and restore

### Reset to Windows defaults

Double-click **`Reset-WindowsFolderDefaults.cmd`** to preview local defaults for all seven managed folders, including Music. Type exactly `RESET` to acknowledge that existing files stay where they are and apply the displayed paths. Press Enter to cancel. Run as your own account.

For the CLI, preview first:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-ICloudFolders.ps1 -ResetToDefaults
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Set-ICloudFolders.ps1 -ResetToDefaults -Apply -AllowExistingContent
```

Reset asks Windows for each folder's default using `SHGetKnownFolderPath` with `KF_FLAG_DEFAULT_PATH`, `KF_FLAG_NOT_PARENT_RELATIVE` and `KF_FLAG_DONT_VERIFY`. This retrieves defaults independently of current redirection, including redirected parents, without creating missing directories during preview. Typical defaults are beneath `%USERPROFILE%`: Desktop, Documents, Pictures, Videos, Downloads, Music, and `Videos\Captures`; paths are supplied by Windows rather than guessed. If Windows cannot supply a default, reset stops before making changes. Aliases use the same destinations. The operation covers only this project's mappings; OneDrive-specific entries and unrelated profile settings remain untouched. It requires no iCloud root or sign-in and cannot be combined with `-ICloudRoot`, `-VerifiedSyncRoot`, `-IncludeMusic` or `-RestoreBackup`.

No historical backup is required or read. Missing or corrupt old backups do not prevent resetting to Windows defaults. A fresh, verified backup of the current settings is still required before applying, so a failed reset can roll back. This implements Windows default-location semantics, not every undocumented side effect of Explorer's Restore Default button or its optional file-moving prompts. The checked registry backend remains in place to preserve local aliases and exact rollback.

Reset changes folder pointers only. Files in iCloud stay there; they will not automatically appear in the new local folders. Review and copy content separately if needed. CLI apply requires `-AllowExistingContent` when a changing source contains files; the Explorer `RESET` acknowledgement accepts leaving that content in place. Preview and `-WhatIf` remain read-only. Missing local destinations are created only after apply is approved. The same exact backup and rollback protections apply, and `-RestoreBackup` can undo a reset. Sign out/in after applying and verify Explorer and applications. Existing policies or another sync provider may reapply their own locations.

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

## Verify after applying

1. Sign out and sign back in; save open work first.
2. Open each affected folder in Explorer and check its location and expected files. Also test applications that save to those folders.
3. Verify an ordinary test file synchronizes through iCloud to another device or iCloud.com. Registry read-back alone does not verify Explorer refresh or cloud sync.
4. Retain the backup until you have verified the new setup. Keep old source files until any separate migration has been checked.

## Development

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ICloudFolders.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ExplorerLauncher.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Diagnostics.ps1
```

Tests use an in-memory registry boundary and temporary folders inside this repository. They never write user-shell registry values. See [project context](docs/CONTEXT.md) for architecture, decisions, validation coverage, and integration checks still needed.

An isolated Windows Sandbox run additionally passed 29 real-registry integration checks on 2026-10-18, including apply, exact restore, and rollback after a partial write. `tests/Invoke-SandboxIntegration.ps1` is the guest-only test payload; it must be launched through a staged Sandbox configuration, never directly on the host. This used a synthetic local root and did not test iCloud synchronization or sign-out/sign-in behavior.
