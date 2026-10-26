# iCloud home folder settler

Configure selected Windows user folders to use iCloud Drive, reset them to Windows defaults, or restore a recovery backup. The graphical interface also offers an explicit copy/merge operation that keeps originals. Nothing changes until you review and confirm an action.

## Download and install

Download the ZIP from [GitHub Releases](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/releases/latest) and extract the entire archive.

- **Install for your account:** double-click **Install-ICloudFolderSetup.cmd**, then **Install for me**. A Start menu shortcut is created; a desktop shortcut is optional. After a successful installation, the extracted download can be removed.
- **Run without installing:** double-click **Open-ICloudFolderSetup.cmd** and keep the extracted files together.

Run normally as your own Windows account. Administrator access is unnecessary. Installation copies application files only; it does not configure folders or install iCloud. Release archives include SHA-256 checksums and a per-file manifest. Packages are unsigned; hashes do not authenticate the publisher. See the [changelog](CHANGELOG.md).

If installation reports changed or incomplete application files, extract a fresh copy of the release ZIP and retry. Existing installations and their shortcuts remain available when file verification fails before shortcut creation.

## Requirements

- 64-bit Windows and Windows PowerShell 5.1. The current native package is x64 and bundles its .NET/Windows App SDK runtime. Native ARM64 execution is not yet certified. Explorer entry points use a process-only execution-policy override for the launcher/backend; machine policy is unchanged.
- iCloud for Windows signed in with an existing Drive folder for iCloud setup and cloud verification.
- Reset and backup restore do not require an available iCloud installation. Copying cloud-only files requires the provider to make their contents available.

Registration confirms the configured Drive path, not synchronization health. See [tested platforms and support limits](docs/VERIFICATION.md).

## Use the graphical window

Choose an action and its options, then click **Preview / Check** or **Dry run**. Review the displayed paths and warnings. An action-specific button becomes available only after a successful preview/dry run of the same options. Its confirmation names the action, with Cancel selected by default. Changing options invalidates the reviewed preview. The window remains responsive while operations run and cannot close until they finish. The production window scrolls at smaller sizes while action buttons remain visible; the experimental Rust UI adapts its two-pane layout without a main-window scrollbar. It uses Windows light/dark colors, pairs the system accent with restrained cloud blue, and keeps system colors in high contrast. Windows' native confirmation task dialog remains system-drawn and may stay light. Results use plain language; select **Technical details** for raw output and exit codes. Path fields and advanced options also expose their explanations to assistive technology.

| Action | What it does |
| --- | --- |
| Set up iCloud folders | Choose the existing Drive folder; optionally include Music. A manual verification fallback is available only as an acknowledgement when Windows has no registration; it cannot override a known mismatch. |
| Reset to Windows defaults | Ask Windows for all seven managed folders' default locations. No historical backup is needed, even if old backups are corrupt. |
| Restore a recovery backup | Choose a trusted before.json file for this Windows account. Preview validates its scope and destinations. |
| Copy files into iCloud / Windows default folders | Preview and explicitly approve a merge that retains originals. Folder settings do not change. |
| Check iCloud configuration | Check registration, paths and folder resolution. JSON output and saving the displayed result are optional. |
| Create / check / clean up cloud test | Create a harmless file, check a remotely renamed return, or preview and confirm its removal. Instructions appear in the window. |

For iCloud setup, the default view shows each folder's icon and proposed path immediately. **Customize each folder (advanced)** enables a textbox and **Browse** button for each destination. Custom destinations stay inside the selected iCloud Drive folder. Music remains optional. Returning to default paths or changing any destination requires a fresh preview; no files are moved. The same destinations are used by iCloud copy and configuration checks. Windows-default reset and backup restore retain their own destinations.

**Recovery files**, **Help**, and **Install for me** are available in the same window. The setup/reset acknowledgement **Change locations without copying files** permits changing locations while leaving content where it is; it never triggers copying.

For direct Explorer access, **Reset-WindowsFolderDefaults.cmd** opens reset mode and **Check-ICloudFolderSetup.cmd** opens diagnostics. All settings and safety checks are shared with the [command-line interface](docs/CLI.md).

## Folder scope

At startup, the window displays a loading status while it reads the shared folder definitions. Actions become available when loading finishes. Folder and navigation pictograms use Windows-provided icons alongside text labels.

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

Apply rebuilds the plan before writing and rechecks hashes. Changes in file content, paths, or destination state between planning passes stop copying. Originals and folder settings remain unchanged on failure; partial destination copies are retained for inspection. Copy progress reports the current file and verified file count. **Stop after current file** finishes copying and verifying the current file, then stops before the next. Planning can stop between files. A large file or cloud download can delay stopping. Completed copies remain; preview again before resuming. Folder-setting operations cannot be cancelled mid-write. This is a content merge, not a metadata-complete archival backup.

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

Changing folder locations does not add Quick access pins. If Desktop, Pictures or another folder is missing from Explorer's left panel, open **Home**, click the **Up** arrow beside the address bar, then right-click the missing folder and choose **Pin to Quick access**. You can also pin its configured destination directly. Do not repeat Apply merely to restore a sidebar shortcut. See [Microsoft's File Explorer instructions](https://support.microsoft.com/en-gb/windows/experience/fileexplorer/file-explorer-in-windows).

A real round trip passed on 2026-10-18 with iCloud for Windows 15.10.39.0. That result applies to one installation and time, not ongoing health or every application. See [verification evidence and the repeatable procedure](docs/VERIFICATION.md).

## Installation details

Application files are copied into unique version directories beneath %LOCALAPPDATA%\Programs\ICloudFolderSettler. Copies are hash-verified before current-user shortcuts are created. Existing binaries, recovery records and same-name shortcuts are retained or backed up. A failed install can leave its isolated directory for inspection; it never applies folder changes.

## Project documentation

Development is also testing a Rust backend and a direct-Win32 Rust UI. The read-only worker includes experimental configuration and setup/reset previews, an in-memory recovery-record snapshot and account-bound backup validation, bounded recovery-file previews, and single-/multi-source copy planning. It derives copy pairs from current registry values and compares proposed folder settings without writing; setup preview checks whether source folders contain content. Its registered-root lookup reads the current user's iCloud `UserSyncRoots` values relative to the enumerated SyncRootManager handle, matching the PowerShell reference lookup. When Windows reports Captures as unavailable, Rust Check retains the PowerShell checker's null `Videos\Captures` row and marks the configuration unhealthy. The snapshot reads mapped current-user registry values but does not create a backup file; validation checks a supplied record but does not restore or change settings. Full copy planning reads content metadata and can hydrate cloud placeholders. The Rust planner recognizes Cloud Files placeholders and hydrates their content through the registered provider in bounded 64 KiB ranges before hashing; a read-only plan may therefore download cloud-only content. It reopens the data stream only after hydration and checks that file identity and metadata remain stable. Other links and unsupported reparse points remain refused. The guarded worker-provider test compiles but has not run on this developer account, and actual iCloud hydration has not been verified. The Rust UI's configuration **Check**, setup **Preview**, and recovery **Dry run** can use the direct Rust worker; restore results show exact current and proposed values, types and removals. Final Apply still uses the PowerShell backend. The worker remains read-only and separate from production, whose entry points continue to use WinUI and PowerShell. The Rust UI has an adaptive two-pane window: configuration on the left, status/results on the right, compact spacing at smaller heights, a pinned command footer and no main-window scrollbar; its minimum client area is 800x470 logical pixels. Its results list has a visible “Folder results” label, and the hidden-desktop fixture verifies its UI Automation DataGrid type and UIA/MSAA names. Narrator speech, high contrast, large text and physical mixed-DPI acceptance remain separate gates. See [project context](docs/CONTEXT.md) for measured memory, launch commands and migration status.

The Rust worker also offers read-only restore previews for an in-memory recovery record or a selected JSON file. File previews accept UTF-8 with or without a BOM, refuse files over 4 MiB and reject reparse/encrypted paths. Both forms check the account, allowed values, destination availability and recovery-folder placement, and show exact additions, updates or removals. They do not restore settings. Recovery-file persistence is exercised only by an isolated test helper; the worker protocol remains read-only.

Its unit tests also exercise a fake-registry transaction model with checked read-back, exact rollback and originally absent value removal. This is not a Win32 write implementation; direct registry mutation and isolated integration remain unfinished.

Backup validation accepts property names in any letter casing, matching PowerShell's case-insensitive property lookup, and rejects duplicate names that differ only by casing.

Registry-dependent Rust reads and previews acquire the same per-account Windows mutex as PowerShell setup/reset/restore/copy operations. They fail immediately if another operation owns it, avoiding snapshots taken during a folder-settings transaction.

The v2.4.0 sources use the [native WinUI 3 interface](docs/WINUI.md). Source entry points expect the complete NativeUI payload from the native package. The v2.3.1 and earlier release archives retain their original interface; no release assets have been replaced. Building from source requires the pinned .NET SDK and the native packaging workflow. VERSION also sets the native executable and assembly version.

A source checkout alone cannot launch the native interface. Build a complete native package outside iCloud Drive, or use an already verified matching package; keep its entire NativeUI directory together. Local NativeUI runtime files are ignored by Git. The CMD entry point can briefly display a console while starting; opening NativeUI/ICloudFolderSetup.exe directly avoids the batch-file console and opens Setup mode.

- [Command-line reference](docs/CLI.md)
- [Architecture and repository structure](docs/CONTEXT.md)
- [Development, tests and releases](docs/DEVELOPMENT.md)
- [Verification evidence and limitations](docs/VERIFICATION.md)
