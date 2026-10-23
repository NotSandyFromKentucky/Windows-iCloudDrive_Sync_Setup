# Project context

## Purpose and boundaries

A per-user Windows Known Folders configurator with graphical and CLI entry points, Windows-default reset, exact backup restore and separately approved copy/merge. It does not install iCloud, configure synchronization, automatically migrate files or modify unrelated profile entries.

The [repository layout and development workflow](DEVELOPMENT.md), [CLI reference](CLI.md), and [measured verification history](VERIFICATION.md) are separate documents. Keep architecture decisions here and historical test evidence in verification.

Release-policy parsing consumes the leading BOM preserved by git show and identifies legacy array format before pipeline unwrapping. The cross-shell release-input suite checks native/legacy policy equivalence and rejection of unsafe or duplicate paths.

The native WinUI 3 migration is in ui/ICloudFolderSetup. Its [review decisions, measured coverage and remaining gates](WINUI.md) are tracked separately. tools/Invoke-WinUIBridge.ps1 reuses Get-SetupRequest and existing backends, transports structured progress/results, and preserves direct error output for friendly classification. Native installation uses the same verified per-user installer. Folder, backup and result dialogs use Microsoft.Windows.Storage.Pickers associated directly with AppWindow.Id, with contextual titles/actions and JSON/text filters. Saving a result reports the destination after the write completes. Development Explorer entry points now launch NativeUI/ICloudFolderSetup.exe in setup, reset, check or install mode; an incomplete payload produces an actionable startup error. Published older releases remain unchanged.

Native control accents follow Windows through the standard AccentButtonStyle and selection resources. Decorative identity combines cloud blue and a theme-adjusted system accent; text stays on system foreground brushes. Light, dark and HighContrast dictionaries remain separate, with high contrast delegating identity colors to system window/text resources. Theme fixtures change only the app's requested theme, not Windows personalization settings. The heading and instructions scroll with form content so enlarged text cannot displace the pinned commands. Narrow windows put the primary action on its own full-width row, and the identity caption wraps within a constrained grid column.

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

Get-SetupRequest maps controls to existing scripts without duplicating registry logic. Encoded data passes user paths as data to a hidden child process. Output is read asynchronously; closing is blocked while running. Apply requires a matching successful preview/dry run and an action-specific confirmation with Cancel as the default. Option changes invalidate preview. The backend remains responsible for ShouldProcess and safety checks.

The optional installer copies only manifest/central-release-listed files into a unique per-user version directory. It captures validated source hashes during preflight and checks installed copies against those exact hashes before shortcut creation, so a source change during copying cannot become the new expected content. It preserves old binaries and backs up same-name shortcuts. A failed copy can leave an unlinked partial installation directory for inspection. It never redirects folders or installs iCloud. Portable execution and the legacy console wrapper remain supported.

## Explicit copy/merge

Get-CopyPairs reuses the core mapping/value reads, deduplicates alias pairs and validates registration/default destinations. Copy uses the same account mutex but never writes registry settings.

Preview hashes contents. Apply rebuilds the plan, checks paths and source/destination hashes, uses File.Copy with overwrite disabled, and verifies new contents. Identical files are skipped. Conflicting aliases or filenames, file/folder obstructions, overlap, encryption and unsupported reparse points stop the operation. Ancestors are checked; native tag lookup permits Windows Cloud Files placeholders while refusing junctions/symbolic links. Reading placeholders may hydrate content.

Sources are always retained. Partial destination copies remain on failure for inspection; no deletion-based rollback is attempted. This is not a metadata-complete backup or an application-consistent snapshot. Live iCloud hydration/copy is still outside fixture-test evidence.

## Validation and distribution

Local tests use fake registry access or unique file/GUI/install fixtures. Real integration is restricted to guarded disposable guests. Never use live developer-account redirection as a test. One real cloud round trip was observed on 2026-10-18; that does not certify all providers, versions or applications.

VERSION and build/ReleaseFiles.json define distribution inputs. The native project reads VERSION directly for executable/assembly metadata; the extracted-package suite checks both against the shipped VERSION. The version-2 release policy separates runtime files from native compile inputs and defines resource/dependency requirements and size bounds. Native builds archive exact Git source into a short temporary directory outside iCloud Drive, publish with locked dependencies, and validate the apphost/WinUI PE architecture and dependency target. A project-local target explicitly publishes the generated app PRI, working around the unpackaged SDK omission. Packages include every runtime file in the hash manifest and exclude compiler sources/intermediates. Optional signing covers project scripts and owned native binaries, retaining vendor signatures. Version-tag publication is gated by CI and remote-byte verification. Published tags/assets are immutable. Detailed commands and evidence belong in the linked development and verification guides.

## GUI progress and accessibility

Copy workers send prefixed JSON progress lines over standard output and accept a uniquely named local cancellation event. Cancellation is cooperative at file boundaries; copying and SHA-256 verification of the current file finish first. Exit code 3 means safely stopped. Registry writes are never interrupted through this mechanism. Technical output is optional; normal results explain next steps. Controls expose accessible names and descriptions, a logical tab sequence and keyboard mnemonics. Native path fields and advanced checkboxes attach their safety explanations as automation help text; the peer-level accessibility fixture verifies the mismatch restriction and retained-files guidance. Enter previews; confirmation defaults to Cancel. Auto-sized rows and wrapping accommodate enlarged text.

Test-UserExperience.ps1 exercises real UI Automation and MSAA properties, keyboard focus, modal cancellation, 100/125/150/200 percent layout/font fixtures, and a real child copy worker stopped after its first verified file. These fixtures do not certify Narrator speech or physical multi-monitor DPI transitions.

GUI fixture tests now run by default on a uniquely named hidden desktop, with the child's desktop verified before executing the suite. The runner never switches the input desktop and contains the process tree in a timeout-controlled job. This prevents test windows taking focus; it is not a security sandbox and does not relax the prohibition on live developer-account redirection tests. See DEVELOPMENT.md for commands and evidence boundaries.

Native high-contrast integration additionally requires Assert-IsolatedEnvironment.ps1 before any personalization API call. It temporarily toggles contrast only in disposable Sandbox/hosted Windows, restores settings in finally and checks the native app's observed palette. Hosted run 39982378929 verified real contrast rendering and restoration of all flags and original Light/Dark palettes. Windows initialized an initially empty inactive scheme name during activation; the fixture permits only this initialization while requiring exact preservation of pre-existing scheme names and all flags/colors. The complete contrast gate passed in hosted run 39998473905. Picker automation selects button-role controls explicitly and checks dismissal by dialog visibility plus the owner's enabled state, since a dismissed common dialog may retain its HWND.
