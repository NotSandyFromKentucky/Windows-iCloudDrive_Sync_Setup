# Changelog

## v2.0.0

Replaces the legacy batch implementation with a preview-first PowerShell utility and an interactive Explorer launcher.

### Use

Download and extract `Windows-iCloudDrive_Sync_Setup-v2.0.0.zip`, then double-click `Open-ICloudFolderSetup.cmd`. Review the preview and type `APPLY` to proceed, or press Enter to cancel. Run normally as your own Windows account; administrator access is unnecessary.

### Changes

- A single folder mapping keeps legacy names and local aliases consistent. Pictures uses `Pictures`; Music is opt in.
- Root validation checks the current account's iCloud registration where available.
- Existing-content checks stop unexpected pointer changes; no files are automatically moved or deleted.
- Exact backups preserve original value types, unexpanded strings, and originally absent values.
- Checked writes and read-back verification trigger rollback on failure; validated manual restore is available.
- The Explorer launcher keeps the result and backup path visible. CLI preview, WhatIf, and advanced options remain available.
- OneDrive-specific and unrelated profile settings are excluded.

### Migration from the legacy release

The previous `set_onedrivefolder.bat` entry point is retired. Extract the complete new release into its own directory; downloading only a single launcher is insufficient. Use the README's CLI instructions for custom roots and optional Music.

An old `iCloudDrive\Images` mapping is normalized to `iCloudDrive\Pictures`. Files already in `Images` stay there; review them separately. The tool does not infer or repair OneDrive settings changed by older versions. New JSON recovery files are not interchangeable with old registry exports or `RestoreRegistry.bat`.

### Validation and limits

- 16 regression tests and five Explorer launcher checks passed.
- 29 isolated Windows Sandbox integration checks passed, including real writes, repeated apply, exact restore, and rollback after a partial write.
- Read-only checks after the user's manual setup confirmed all 11 default mappings and all six resolved Windows folder paths.
- Windows PowerShell 5.1 is the tested runtime. Actual cloud synchronization, other Windows/iCloud versions, and all application save dialogs are not certified. Registration and running processes do not prove synchronization.

The release ZIP contains the runtime scripts and documentation. Source code and test suites are available in the tagged repository. `SHA256SUMS.txt` contains the ZIP's SHA-256 digest.
