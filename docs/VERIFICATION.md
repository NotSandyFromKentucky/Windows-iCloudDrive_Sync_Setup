# Verification and support boundaries

## What a green result proves

`Test-ICloudFolders.ps1` checks configuration read-only: the root registration, every intended registry value, destination existence and Windows folder resolution. `-Json` returns a machine-readable report. Exit codes are 0 for healthy configuration, 2 for configuration needing attention, and 1 for an execution error. This check writes no logs, folders or registry settings, and never claims to certify cloud sync.

Double-click `Check-ICloudFolderSetup.cmd` for the same check from Explorer. Preview output uses folder names and distinguishes missing values, changes and already configured values.

## Repeatable tests

Run these locally with Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ICloudFolders.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ExplorerLauncher.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Diagnostics.ps1
```

The core tests use an in-memory registry boundary and isolated temporary directories. They cover original value types and absence, scope, preflight errors, read-back corruption, partial failure, unavailable/malformed recovery records and rollback failure reporting. The launcher tests cover explicit apply, cancellation and error handling. Diagnostics tests cover mismatches, unavailable root registration, resolution errors and no filesystem changes.

The release-tool suite additionally checks a valid package, repeatable unsigned output on the same runtime, a bad archive checksum, traversal entries rejected before extraction, and failure when a requested signing certificate is unavailable.

CI runs these on Windows Server 2022, Server 2025 and Windows 11 ARM, using Windows PowerShell and PowerShell 7. The server images add coverage; they do not imply Apple supports iCloud on Windows Server. Report actual green runs and their commit IDs; the matrix definition alone is not evidence that a platform passed.

Measured baseline: [Windows validation run 39121620585](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/39121620585), commit `dbb648a0abf5995603b5ea591e908ba8e75a7a32`, passed all six OS/shell unit jobs, all three real-write/API jobs and package verification. Each integration job passed 36 checks, including real ACL denial and restoration after terminating a writer process.

| Disposable image | Core/launcher/diagnostics on Windows PowerShell and PowerShell 7 | Real writes, interrupted recovery and API restoration |
| --- | --- | --- |
| Server 2022, build 20348 | Passed | Passed |
| Server 2025, build 26100 | Passed | Passed |
| Windows 11 ARM, build 26200 | Passed | Passed |

The local account's installed iCloud package was `15.10.39.0` when checked. Its live mappings and resolved paths passed read-only diagnostics. Two-way cloud verification is a separate gate and must not be inferred from this table or the installed package version.

Real-registry integration runs only in disposable Windows Sandbox or GitHub-hosted Windows VMs. The guard refuses self-hosted runners and ordinary developer accounts. It is an accidental-execution guard, not protection against an attacker forging environment variables. Real tests include permission denial, exact restore and process termination after a real write, followed by recovery from the on-disk backup. A separate API experiment evaluates `SHSetKnownFolderPath` and restores both User Shell Folders and Shell Folders snapshots. Evidence is uploaded as CI artifacts.

## Real iCloud round trip

This needs an account already signed into iCloud and another device or iCloud.com. Never share Apple passwords or verification codes with automation.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ICloudRoundTrip.ps1 -Mode Start
```

The tool creates one uniquely named harmless text file through the currently resolved Documents folder, after verifying it belongs to the registered iCloud root. On another device or iCloud.com, find the upload file and rename its `-upload.txt` suffix to `-returned.txt`. Do not rename it locally; that would not prove a cloud round trip.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ICloudRoundTrip.ps1 -Mode Check
```

The return name and original SHA-256 must both match. Record the remote action as manually observed; a local file check alone cannot distinguish a remote rename from a local one. This proves one round trip at that time, not every file type, offline case, device or future sync health. Test application save dialogs and Windows sign-out/sign-in separately in an isolated account or VM before claiming those combinations are supported.

After confirming the result, cleanup is explicit and validates exact filenames and content hashes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ICloudRoundTrip.ps1 -Mode Cleanup -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-ICloudRoundTrip.ps1 -Mode Cleanup
```

Deleting the test file propagates through iCloud. No source data or unrelated files are removed. Session metadata stays under ignored `.local` until cleanup.

## Known Folder API decision

Microsoft documents [SHSetKnownFolderPath](https://learn.microsoft.com/en-us/windows/win32/api/shlobj_core/nf-shlobj_core-shsetknownfolderpath) for redirection. Our isolated evaluation records which registry values it changes, confirms the canonical path, retains a source file, and verifies exact restoration. The production backend remains scoped registry writes until those results establish that an API backend can also preserve all local aliases, originally absent values and recovery guarantees. An API call alone is not assumed equivalent to updating every alias.

The measured evaluations on all three images changed `Personal` in both User Shell Folders and Shell Folders, retained the source file, and restored both complete snapshots exactly. A seeded existing local Documents alias did **not** follow the API change on any image (`LocalAliasFollowsApi: false`). A replacement backend would need an expanded backup surface for Shell Folders and separate alias handling. Keeping the current backend preserves its tested recovery scope while the API experiment remains reproducible.

## Signing

No usable code-signing certificate was available on the development account when this work began. Unsigned packages are explicitly marked `Signed: false` in their manifest. Checksums detect accidental download changes; they are not a substitute for publisher identity.

The package builder optionally signs staged PowerShell files using an existing, valid, trusted code-signing certificate from `Cert:\CurrentUser\My`:

```powershell
.\tools\New-ReleasePackage.ps1 -SigningCertificateThumbprint '<existing certificate thumbprint>'
```

It requires a code-signing EKU and private key, uses SHA-256 and an Authenticode timestamp, and rejects invalid signatures. It never exports keys, installs trust certificates, signs working-tree files or creates a self-signed publisher identity. The verifier checks each declared signature. Actual trusted signing cannot be certified until an appropriate certificate is supplied. CI releases remain unsigned unless a separately reviewed signing integration is configured.

## Release gates

`VERSION` and `build/ReleaseFiles.json` define the version and runtime allowlist. `tools/New-ReleasePackage.ps1` packages an exact Git commit, adds per-file hashes and signature state, and writes an archive checksum. `tools/Test-ReleasePackage.ps1` verifies contents, manifest, syntax and signatures when declared.

The unsigned builder fixes entry order and ZIP timestamps to the source commit, enabling byte-identical retries on the same runtime. Signed timestamped builds need not be identical. Verification checks ZIP paths and the script-only size limit before extraction. Publication additionally requires the manifest's commit and version to match the checked-out version tag. A draft with different already-uploaded bytes is retained for inspection rather than overwritten.

A version-tag push runs the full validation workflow before publishing. The release job requires the tag to point to the checked-out commit, creates or resumes a draft, verifies uploaded bytes by downloading them, then publishes. It refuses to overwrite a published version. The legacy `Release` and `v2.0.0` remain unchanged. The workflow has read-only permissions by default; only the publication job has contents-write access.
