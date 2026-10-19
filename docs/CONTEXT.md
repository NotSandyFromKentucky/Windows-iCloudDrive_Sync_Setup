# Project context

## Purpose and boundaries

A per-user Windows Known Folders configurator with graphical and CLI entry points, Windows-default reset, exact backup restore and separately approved copy/merge. It does not install iCloud, configure synchronization, automatically migrate files or modify unrelated profile entries.

The [repository layout and development workflow](DEVELOPMENT.md), [CLI reference](CLI.md), and [measured verification history](VERIFICATION.md) are separate documents. Keep architecture decisions here and historical test evidence in verification.

## Components

| File | Role |
| --- | --- |
| ICloudFolders.psm1 | Central Get-FolderMap, registration/default lookup, checked registry writes, backup, rollback and diagnostics. |
| ICloudFolderCopy.psm1 | Explicit non-overwriting copy plans and hash-verified execution. |
| ICloudFolderSetup.UI.psm1 | Controls, option routing, asynchronous worker and confirmation. |
| ICloudFolderSetup.Install.psm1 | Allowlisted copies, installed-file verification and current-user shortcuts. |
| Start-ICloudFolderSetup.ps1 / Install-ICloudFolderSetup.ps1 | Graphical setup/installer entry points. |
| Set-ICloudFolders.ps1 / Test-ICloudFolders.ps1 / Copy-ICloudFolderFiles.ps1 | Thin command-line entry points used by the GUI worker. |
| Open-ICloudFolderSetup.ps1 | Retained text-based compatibility wrapper. |

CMD entry points stay at the root with runtime scripts/modules. The GUI/package/installer depend on those paths. Folder mappings must not be duplicated in a second component.

## Folder and registry decisions

- Get-FolderMap is authoritative for canonical entries and aliases. Pictures maps to Pictures; old Images content is not automatically merged. Music is optional for iCloud setup; reset includes it. No OneDrive-specific or unrelated entries are modified.
- New values are normalized absolute REG_EXPAND_SZ strings. Existing types and unexpanded strings are preserved exactly in backups; unsupported original types abort.
- SyncRootManager iCloudDrive registrations validate the current account's active root. A known mismatch cannot be overridden. Manual verification is a fallback only if no registration exists; registration never proves sync health.
- Reset uses Get-FolderMap with SystemDefaults. Canonical Known Folder IDs are defined alongside the mapping. SHGetKnownFolderPath flags 0x4600 request defaults independently of current/parent redirection without creating absent directories. Allocations are freed even on error; failed queries have no guessed fallback.
- Historical backups are never needed for reset. Every apply/reset/restore still creates a fresh exact recovery record.
- The checked registry backend remains intentional. The isolated SHSetKnownFolderPath experiment changed both User Shell Folders and Shell Folders, but a seeded local Documents alias did not follow. Replacing the backend would require separate alias handling and a larger backup/verification surface. See verification for the measured results.

## Settings-change flow

1. Acquire the account mutex and snapshot current values without expansion.
2. Validate destinations, source content, recovery location and complete plan.
3. Return for preview, or enforce apply conditions and ShouldProcess.
4. Write, parse, validate and compare an account-bound exact backup.
5. Probe destination access and compare the snapshot again before writes.
6. Write/check every desired value and the complete set. On failure, restore/check all original values, including deletion of values originally absent.

Recovery storage must not overlap source/destination trees. Manual restore accepts only the mapped allowlist and current SID, requires original destinations to be available, and makes a fresh backup of current settings. No file movement or directory deletion is part of settings changes. Crash/power-loss recovery is manual. Other applications can still change settings; the mutex is not an OS-wide registry transaction.

## Graphical flow and installation

Get-SetupRequest maps controls to existing scripts without duplicating registry logic. Encoded data passes user paths as data to a hidden child process. Output is read asynchronously; closing is blocked while running. Apply requires a matching successful preview/dry run and default-No confirmation. Option changes invalidate preview. The backend remains responsible for ShouldProcess and safety checks.

The optional installer copies only manifest/central-release-listed files into a unique per-user version directory. It verifies copies before shortcut creation, preserves old binaries and backs up same-name shortcuts. It never redirects folders or installs iCloud. Portable execution and the legacy console wrapper remain supported.

## Explicit copy/merge

Get-CopyPairs reuses the core mapping/value reads, deduplicates alias pairs and validates registration/default destinations. Copy uses the same account mutex but never writes registry settings.

Preview hashes contents. Apply rebuilds the plan, checks paths and source/destination hashes, uses File.Copy with overwrite disabled, and verifies new contents. Identical files are skipped. Conflicting aliases or filenames, file/folder obstructions, overlap, encryption and unsupported reparse points stop the operation. Ancestors are checked; native tag lookup permits Windows Cloud Files placeholders while refusing junctions/symbolic links. Reading placeholders may hydrate content.

Sources are always retained. Partial destination copies remain on failure for inspection; no deletion-based rollback is attempted. This is not a metadata-complete backup or an application-consistent snapshot. Live iCloud hydration/copy is still outside fixture-test evidence.

## Validation and distribution

Local tests use fake registry access or unique file/GUI/install fixtures. Real integration is restricted to guarded disposable guests. Never use live developer-account redirection as a test. One real cloud round trip was observed on 2026-10-18; that does not certify all providers, versions or applications.

VERSION and build/ReleaseFiles.json define distribution inputs. Packages are built from exact committed source, optionally signed in staging, manifested and checksummed. Version-tag publication is gated by CI and remote-byte verification. Published tags/assets are immutable. Detailed commands and evidence belong in the linked development and verification guides.
