# Changelog

## v2.3.1

- Creates the GUI rendering test's output directory explicitly so validation works on clean Windows runners. The failed v2.3.0 tag was not published.

- Adds a graphical Explorer interface for every supported setup, reset, restore, diagnostic and cloud-test option, with pickers, preview/dry run and explicit confirmation.
- Adds optional per-user installation with verified copies and Start menu/desktop shortcuts. Folder configuration remains unchanged until separately reviewed and applied.

## v2.2.0

- Adds preview-first `-ResetToDefaults` for every managed folder including Music, with exact backup, checked writes and rollback. Existing files stay in place.
- Adds `Reset-WindowsFolderDefaults.cmd` for Explorer, requiring an exact `RESET` acknowledgement after previewing destinations and the existing-content notice.
- Reset queries Windows for actual default locations, independently of current and parent redirection. It needs no historical backup, including when old backups are corrupt, and still requires a fresh recovery backup before applying.

Validation: 26 core, ten launcher and five diagnostic scenarios passed across the six Windows OS/shell combinations. Each of the three disposable Windows images passed 53 real integration checks, including corrupt historical backups and exact recovery after reset. Packages remain explicitly unsigned; checksums and per-file hashes are included.

## v2.1.0

- Adds read-only setup diagnostics, JSON output and an Explorer check launcher.
- Previews use friendly folder labels and show whether each value will be added, updated or retained.
- Adds Windows CI across Server 2022, Server 2025 and Windows 11 ARM, with Windows PowerShell and PowerShell 7 unit coverage and disposable-runner real-registry tests.
- Expands failure coverage to damaged backups, read-back corruption, real permission denial and recovery after process termination. All three disposable Windows images passed 41 integration checks, including a real standard Save dialog folder check and sync-helper cleanup safeguards.
- Evaluates the documented Known Folder API in disposable VMs with exact registry restoration; production retains its checked registry backend.
- Adds versioned package automation, per-file manifests, SHA-256 checksums, explicit signature state and optional Authenticode signing with an existing certificate.
- Version-tag releases run validation, verify uploaded bytes and publish automatically; existing published versions are never overwritten.
- Adds an explicit cloud round-trip helper and detailed verification guidance. Cloud tests require remote observation and a rename on iCloud.com or another device; local diagnostics alone never certify sync.

Packages are unsigned by default. No code-signing certificate or Apple credentials are bundled. See `docs/VERIFICATION.md` for tested scope and remaining external checks.

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
