# Project context

## Purpose and boundaries

This repository contains a per-user Windows folder-path configurator for iCloud Drive. The original batch and broad registry snapshot have been retired. `Set-ICloudFolders.ps1` is the CLI; `ICloudFolders.psm1` contains the implementation; `Set-ICloudFolders.cmd` is a convenience launcher. `.idea` is local IDE state and is ignored. There is no application build, service, package installation, or Java dependency.

`Open-ICloudFolderSetup.cmd` is the Explorer entry point. It runs `Open-ICloudFolderSetup.ps1` using a process-only execution-policy override, then pauses and returns the script's exit code. The script previews first, applies only after an exact `APPLY` response, and stops on preview/apply errors. It uses the same module without changing mappings or bypassing any preflight checks. Advanced options remain on the CLI. The original CLI launchers retain their unattended behavior.

Version 2.1 adds `Test-ICloudFolders.ps1` and `Check-ICloudFolderSetup.cmd` for read-only diagnostics. They report root registration, mappings, destination existence and Windows folder resolution, with explicit unknown cloud status. Friendly plan labels are derived from `Get-FolderMap`; raw value names remain available in JSON diagnostics. See `docs/VERIFICATION.md` for the full validation and signing policy.

The Explorer wrapper passed five isolated checks using a stub module: cancel, explicit apply, other input cancelling, preview failure preventing apply, and apply failure returning a nonzero exit code. The existing 16 regression scenarios also passed after adding the wrapper. No live host-account apply was used to test the launcher.

## Decisions

- One canonical mapping lives in `Get-FolderMap`. Pictures and its local alias use `Pictures`; no `Images` directory is created. Music is optional. Desktop and Downloads local aliases are included to keep those entries consistent too.
- No OneDrive-specific identifiers are modified. Old runs may have changed those values; this tool cannot infer their original paths and does not silently repair them. Restore such values from a known prior backup or the relevant provider's settings.
- The old `.reg` file is removed rather than generated: importing a file would bypass preflight, backup, checked writes, and rollback. Historical values are not a trustworthy rollback baseline.
- New values use `REG_EXPAND_SZ` with normalized absolute paths. This supports an explicit root on another drive without manufacturing environment-variable substitutions. Backups preserve original types and unexpanded values exactly. Unexpected original types abort instead of being coerced.
- Windows SyncRootManager's `iCloudDrive!*` registrations and `UserSyncRoots` SID value provide root validation where available. Registration layouts may vary; `-VerifiedSyncRoot` is an explicit manual fallback when no registration is found. It cannot override a known mismatch. Registration does not prove sign-in or sync health.
- The current implementation retains scoped User Shell Folders registry writes for explicit alias control and exact restoration of originally absent entries. [SHSetKnownFolderPath](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shsetknownfolderpath) was evaluated: it provides documented folder redirection, but switching mechanisms needs isolated integration tests for additional side effects and alias behavior. Do not combine an API call with registry writes without expanding backup and verification coverage. See also [Known Folders](https://learn.microsoft.com/en-us/windows/win32/shell/known-folders) and [known-folder identifiers](https://learn.microsoft.com/en-us/windows/win32/shell/knownfolderid).
- No data migration is implemented. Existing-content checks require an explicit opt-in before a pointer changes. A future migration feature must be a separate operation with collision policy, copy verification, and source retention; do not add implicit move/delete commands to apply or restore.
- Default execution is read-only. `-Apply` and `ShouldProcess` gate mutations. Recovery files go under local application data, outside redirected sources/destinations; overlapping storage aborts. A per-account mutex serializes this tool, and a second snapshot comparison detects changes before the first write. This is not an OS registry transaction and cannot prevent changes by other applications.

## Change flow

1. Acquire per-account mutex; read current values without environment expansion.
2. Validate root, source paths/content, destination structure, and recovery location. Display complete old/new plan.
3. Return for preview, or validate apply conditions and call `ShouldProcess`.
4. Write recovery JSON; parse, validate, and compare it with the captured snapshot and current settings.
5. Create/probe all destinations, then recheck the snapshot before registry writes.
6. Write and verify each desired value, then verify the complete set. On failure, attempt and verify restoration of every original value; report any rollback errors and recovery path.

Manual restore uses the same backup/write/verification/recovery flow, accepts only mapped names and the current SID, and requires original existing paths to be available. It does not remove created folders or move data.

## Validation and release limits

The dependency-free PowerShell tests exercise preview and WhatIf without writes, missing root verification, registered-root mismatch, injected destination-access failure, file obstruction, existing-content gating, partial-write rollback, exact original type/absence restoration, scoped aliases, unrelated values, repeated apply, manual restore, rejected backup scope/SID, optional Music, Unicode and `!`/space paths, and incomplete rollback reporting. The fake registry is deliberate: running tests must not redirect the developer's folders.

The CLI is also checked using real read-only registry access. The fake-registry suite alone does not certify the production registry write boundary; the isolated integration result below covers that boundary on the tested guest. Explorer refresh, application compatibility, iCloud login state, and cloud synchronization remain unverified. Windows PowerShell 5.1 is the verified runtime; other PowerShell versions and Windows/iCloud releases are not certified.

Windows Sandbox integration on 2026-10-18: all 29 checks in `tests/Invoke-SandboxIntegration.ps1` passed using the real guest registry and filesystem. This verified 13 mapped values including Music, mutation-free preview/WhatIf, stable repeated apply, preservation of a source file, restore preview, exact restoration of the complete original registry snapshot (including absent aliases), and exact rollback after two real writes followed by an injected failure. A fresh process's Documents API resolved the redirected path. The host's complete User Shell Folders snapshot was unchanged before/after.

The Sandbox used a synthetic guest-local root, not an iCloud installation. Networking, clipboard, devices and GPU sharing were disabled. Only staged code was mapped read-only; a separate ignored `.local/sandbox/<run>/results` folder accepted logs and JSON results. The test refuses to run unless it is the `WDAGUtilityAccount` guest with a different SID and computer name from its staging marker. Do not run it directly on the host. Generated `.wsb` configurations and personal host snapshots stay under `.local` and are not committed.

This integration run validates the production registry write boundary on the tested guest. Explorer/application behavior after sign-out/sign-in, actual iCloud registration variations, cloud synchronization, real access-denied conditions, and crash recovery still need separate validation. Sandbox does not establish those results.

After the run, the test Sandbox client was closed and the temporarily enabled Windows Sandbox feature was disabled successfully with `-NoRestart`. Windows reported that another restart is required to finish disabling it; no automatic restart was performed.

Verification on 2026-10-17: all 16 regression scenarios passed under Windows PowerShell 5.1; all PowerShell files parsed without syntax errors. A real default CLI preview returned exit code 0 and flagged existing source content, and an invalid-root CLI invocation returned exit code 1. Neither invocation used `-Apply`; user-shell settings were not changed.

After the user manually applied the Explorer setup, read-only checks of the real account confirmed all 11 default registry mappings and destination directories, and all six resolved Windows folder paths matched the plan. The setup log recorded completion and its recovery backup matched the account. iCloud Drive's registered root matched and its process was running. This verifies the current folder configuration, but does not prove cloud synchronization or all application save-dialog behavior. No live host-account apply was performed by the development tests.

Before deploying to another account/machine, run isolated Windows integration checks:

- Capture original known-folder API results and registry state, apply, sign out/in, and compare Explorer/API resolutions against the plan for all aliases.
- Verify default and custom roots against installed iCloud registration, and test disabled/unavailable iCloud.
- Exercise real access-denied conditions, partial writes, unavailable restore destinations, and recovery following a terminated process.
- Verify existing files remain intact, a test file synchronizes, and manual restore returns the account to its original state. Test PowerShell execution policy and launcher exit codes.

No live host-account folder redirection is part of development verification. Registry/cloud integration results must be recorded when actually performed; do not infer them from the mock tests.

## Releases

The legacy GitHub release uses the tag `Release`; preserve it and `v2.0.0`. Versioned distribution started with `v2.0.0` because the old batch entry point was replaced by a multi-file PowerShell utility. Version 2.1 introduces CI and automated version-tag publication. A push to `main` runs validation; only a version tag (or manual release workflow on an already tagged commit) can publish a release.

For a release, commit and test the intended source. `tools/New-ReleasePackage.ps1` uses `git archive` with the versioned `build/ReleaseFiles.json` allowlist, optionally signs staged PowerShell files with an existing valid certificate, adds a per-file manifest and generates `SHA256SUMS.txt`. `tools/Test-ReleasePackage.ps1` verifies contents, hashes, syntax and declared signatures. Never package `.local`, IDE state, credentials, personal registry snapshots, recovery files, or test output.

Create an immutable version tag on that commit. `.github/workflows/release.yml` calls the full Windows validation workflow, then `tools/Publish-Release.ps1` creates/resumes a draft, uploads the ZIP/checksum, downloads and verifies both assets, and publishes using the corresponding changelog section. It refuses to modify a published version. The default token is read-only; only publication receives contents-write. Action dependencies are pinned to official commit IDs.
