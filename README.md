# iCloud home folder settler

Configure selected Windows user folders to use iCloud Drive, reset them to Windows defaults, or restore a recovery backup. The graphical interface also offers an explicit copy/merge operation that keeps originals. Nothing changes until you review and confirm an action.

## Download and install

Download the ZIP from [GitHub Releases](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/releases/latest) and extract the entire archive.

- **Install for your account:** double-click **Install-ICloudFolderSetup.cmd**, then **Install for me**. A Start menu shortcut is created; a desktop shortcut is optional. After a successful installation, the extracted download can be removed.
- **Run without installing:** double-click **Open-ICloudFolderSetup.cmd** and keep the extracted files together.

Run normally as your own Windows account. Administrator access is unnecessary. Installation copies application files only; it does not configure folders or install iCloud. Release archives include SHA-256 checksums and a per-file manifest. Packages are unsigned; hashes do not authenticate the publisher. See the [changelog](CHANGELOG.md).

## Requirements

- Windows and Windows PowerShell 5.1. The graphical launchers use Windows Forms and a process-only execution-policy override; machine policy is unchanged.
- iCloud for Windows signed in with an existing Drive folder for iCloud setup and cloud verification.
- Reset and backup restore do not require an available iCloud installation. Copying cloud-only files requires the provider to make their contents available.

Registration confirms the configured Drive path, not synchronization health. See [tested platforms and support limits](docs/VERIFICATION.md).

## Use the graphical window

Choose an action and its options, then click **Preview / Check** or **Dry run**. Review the displayed paths and warnings. An action-specific button becomes available only after a successful preview/dry run of the same options. Its confirmation names the action, with Cancel selected by default. Changing options invalidates the reviewed preview. The window remains responsive while operations run and cannot close until they finish. Results use plain language; select **Technical details** for raw output and exit codes.

| Action | What it does |
| --- | --- |
| Set up iCloud folders | Choose the existing Drive folder; optionally include Music. A manual verification fallback is available only as an acknowledgement when Windows has no registration; it cannot override a known mismatch. |
| Reset to Windows defaults | Ask Windows for all seven managed folders' default locations. No historical backup is needed, even if old backups are corrupt. |
| Restore a recovery backup | Choose a trusted before.json file for this Windows account. Preview validates its scope and destinations. |
| Copy files into iCloud / Windows default folders | Preview and explicitly approve a merge that retains originals. Folder settings do not change. |
| Check iCloud configuration | Check registration, paths and folder resolution. JSON output and saving the displayed result are optional. |
| Create / check / clean up cloud test | Create a harmless file, check a remotely renamed return, or preview and confirm its removal. Instructions appear in the window. |

**Recovery files**, **Help**, and **Install for me** are available in the same window. The setup/reset acknowledgement **Change locations without copying files** permits changing locations while leaving content where it is; it never triggers copying.

For direct Explorer access, **Reset-WindowsFolderDefaults.cmd** opens reset mode and **Check-ICloudFolderSetup.cmd** opens diagnostics. All settings and safety checks are shared with the [command-line interface](docs/CLI.md).

## Folder scope

| Folder | Destination beneath the iCloud root | Setup default |
| --- | --- | --- |
| Desktop | Desktop | Included |
| Documents | Documents | Included |
| Pictures | Pictures | Included |
| Videos | Videos | Included |
| Downloads | Downloads | Included |
| Captures | Videos\Captures | Included |
| Music | Music | Optional |

Aliases use the same destination. Reset always includes Music. OneDrive-specific entries and unrelated profile settings are untouched. The old Images destination is not automatically merged into Pictures.

## Copy and merge existing files

Select either copy action, inspect its plan, and explicitly confirm Apply. **Copy first, verify, then change folder locations separately.**

Missing files are copied and verified with SHA-256; identical files are skipped and empty directories retained. Different same-name files, file/folder mismatches and conflicting aliases stop planning before writes. No source is deleted and no destination file is overwritten.

Unavailable sources, overlapping trees, encrypted files, junctions, symbolic links and unsupported reparse points are refused. Reading Windows Cloud Files placeholders may download content, and destination copies may synchronize. Live iCloud hydration/copy is not certified by fixture tests.

Apply rebuilds the plan before writing and rechecks hashes. Active file changes can stop copying. Originals and folder settings remain unchanged on failure; partial destination copies are retained for inspection. Copy progress reports the current file and verified file count. **Stop after current file** finishes copying and verifying the current file, then stops before the next. Planning can stop between files. A large file or cloud download can delay stopping. Completed copies remain; preview again before resuming. Folder-setting operations cannot be cancelled mid-write. This is a content merge, not a metadata-complete archival backup.

## Backups and recovery

Before any folder-setting change, the tool creates and verifies a new account-bound recovery backup under:

~~~text
%LOCALAPPDATA%\ICloudFolderSettler\Recovery\<timestamp>-<unique-id>\
~~~

The window displays the backup and operation-log paths. Backups preserve exact unexpanded values, registry types and originally absent entries. Keep them local and retain them until the new configuration is verified. Use **Restore a recovery backup** to undo a setup or reset; restoration makes another backup first.

Writes are checked. A failure triggers best-effort rollback, including removal of originally absent values. **ROLLBACK INCOMPLETE** identifies a recovery problem requiring attention. A crash or power loss cannot automatically roll back: use the printed backup manually. Newly created directories and their contents are never automatically removed.

A reset obtains defaults from Windows without reading old backups. It still requires a fresh recovery backup before applying. Source files stay in place unless you separately approve copying. Existing policies or another sync provider can reapply their own locations. Full [CLI and recovery details](docs/CLI.md) are available for advanced use.

## Verify afterward

Save work, sign out/in, and verify Explorer paths and application save locations. Retain backups and source files until checked. Check an ordinary file through iCloud.com or another device; local diagnostics cannot prove cloud synchronization. The configuration checker expects iCloud destinations and reports mismatches after an intentional reset to local defaults.

A real round trip passed on 2026-10-18 with iCloud for Windows 15.10.39.0. That result applies to one installation and time, not ongoing health or every application. See [verification evidence and the repeatable procedure](docs/VERIFICATION.md).

## Installation details

Application files are copied into unique version directories beneath %LOCALAPPDATA%\Programs\ICloudFolderSettler. Copies are hash-verified before current-user shortcuts are created. Existing binaries, recovery records and same-name shortcuts are retained or backed up. A failed install can leave its isolated directory for inspection; it never applies folder changes.

## Project documentation

- [Command-line reference](docs/CLI.md)
- [Architecture and repository structure](docs/CONTEXT.md)
- [Development, tests and releases](docs/DEVELOPMENT.md)
- [Verification evidence and limitations](docs/VERIFICATION.md)
