# Verification and support boundaries

## What a green result proves

`Test-ICloudFolders.ps1` checks configuration read-only: the root registration, every intended registry value, destination existence and Windows folder resolution. `-Json` returns a machine-readable report. Exit codes are 0 for healthy configuration, 2 for configuration needing attention, and 1 for an execution error. This check writes no logs, folders or registry settings, and never claims to certify cloud sync.

Double-click `Check-ICloudFolderSetup.cmd` for the same check from Explorer. Preview output uses folder names and distinguishes missing values, changes and already configured values.

## Graphical installer and copy/merge

[v2.3.1 release validation](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/39229331158), source commit f3fa56bc89d0ff65473bb0d23fc90b0ab275cd81, passed the six OS/shell local-suite jobs, three guarded integration jobs, package verification and publication. The local suites included GUI rendering/confirmation, fixture installer/reinstall/manifest checks, explicit copy routing, conflict refusal and retained sources after partial-copy failure. The public ZIP was independently verified and its installer tested using fixture application/shortcut directories. No developer-account folder redirection, personal-file merge or real Start menu modification was part of those tests. Real iCloud hydration/copy and every display scale remain outside this evidence.

## Repeatable tests

The complete [local suite commands and development workflow](DEVELOPMENT.md#local-verification) are maintained in one place. Run them with Windows PowerShell 5.1; the GUI suite starts an STA process when needed.

The core tests use an in-memory registry boundary and isolated temporary directories. They cover original value types and absence, scope, preflight errors, read-back corruption, partial failure, unavailable/malformed recovery records and rollback failure reporting. The launcher tests cover explicit apply, cancellation and error handling. Diagnostics tests cover mismatches, unavailable root registration, resolution errors and no filesystem changes.

The release-tool suite additionally checks a valid package, repeatable unsigned output on the same runtime, a bad archive checksum, traversal entries rejected before extraction, and failure when a requested signing certificate is unavailable.

CI runs these on Windows Server 2022, Server 2025 and Windows 11 ARM, using Windows PowerShell and PowerShell 7. The server images add coverage; they do not imply Apple supports iCloud on Windows Server. Report actual green runs and their commit IDs; the matrix definition alone is not evidence that a platform passed.

Measured baseline: [Windows validation run 39121620585](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/39121620585), commit `dbb648a0abf5995603b5ea591e908ba8e75a7a32`, passed all six OS/shell unit jobs, all three real-write/API jobs and package verification. Each integration job passed 36 checks, including real ACL denial and restoration after terminating a writer process.

Expanded evidence: [run 39122943292](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/39122943292), commit `f270c0fcddfcc3f241388334a9855a55f5bd7bbd`, passed all ten jobs. Each image passed **41 real integration checks**, now including safe sync-helper cleanup and the actual Windows Save dialog's default Documents folder. The dialog is instantiated without an initial directory, reports its physical folder through `IFileDialog`, and its dedicated guest fixture process is terminated after observation; no input is injected and no file is saved by that dialog. A separate application-style save through the Documents API is also verified. All six local-suite jobs passed 19 core, five launcher and five diagnostic scenarios; package verification additionally passed five release-tool scenarios.

| Disposable image | Core/launcher/diagnostics on Windows PowerShell and PowerShell 7 | Real writes, interrupted recovery and API restoration |
| --- | --- | --- |
| Server 2022, build 20348 | Passed | Passed |
| Server 2025, build 26100 | Passed | Passed |
| Windows 11 ARM, build 26200 | Passed | Passed |

The local account's installed iCloud package was `15.10.39.0` when checked. Its live mappings and resolved paths passed read-only diagnostics. Two-way cloud verification is a separate gate and must not be inferred from this table or the installed package version.

Live round trip passed on 2026-10-18 at 14:11 UTC with iCloud for Windows `15.10.39.0`. A unique 191-byte text file created through the redirected Windows Documents folder was observed in iCloud.com. After the user signed in, the file was renamed there through the visible Drive UI; the returned name arrived in Windows, the original name disappeared, and its SHA-256 matched the original exactly. No local rename was performed. Read-only folder diagnostics also remained healthy. Session metadata and the cloud screenshot stay under ignored `.local`; personal paths, identifiers and Apple credentials are not committed. This establishes one observed two-way round trip on this installation, not universal or ongoing sync health.

Real-registry integration runs only in disposable Windows Sandbox or GitHub-hosted Windows VMs. The guard refuses self-hosted runners and ordinary developer accounts. It is an accidental-execution guard, not protection against an attacker forging environment variables. Real tests include permission denial, exact restore and process termination after a real write, followed by recovery from the on-disk backup. A separate API experiment evaluates `SHSetKnownFolderPath` and restores both User Shell Folders and Shell Folders snapshots. Evidence is uploaded as CI artifacts.

## Reset to local defaults

Windows default-path evidence: [run 39136143690](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/39136143690), commit `4a896dd`, passed all ten jobs. The six OS/shell suites passed 26 core, ten launcher and five diagnostic scenarios. Each disposable image passed 53 real integration checks, including reset from redirected paths despite a corrupt historical backup, source retention, fresh-backup recovery to the redirected state and final exact restoration of the original guest state. The API experiment independently confirmed that `SHGetKnownFolderPath` with flags `0x4600` returns the same default before and after Documents redirection. Package verification passed. Actual-account API preview and WhatIf also passed with the complete live folder-registry snapshot unchanged. This validates Windows-supplied default destinations and our checked write/recovery flow, not undocumented Explorer UI internals or automatic file migration.

Reset feature evidence: [run 39135664146](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/39135664146), commit `3ab6d55`, passed all ten jobs. All six OS/shell suites passed 24 core, ten launcher and five diagnostic scenarios. Each disposable image passed 49 integration checks, including mutation-free reset preview/WhatIf, all 13 local-default entries including Music, source-file retention and exact restoration from the reset backup. Package verification also passed. On the development account, only reset preview and WhatIf ran; the complete User Shell Folders snapshot was unchanged. Reset does not move cloud content or establish application refresh after sign-out/sign-in.

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

Deleting the test file propagates through iCloud. No source data or unrelated files are removed. Session metadata stays under ignored .local until cleanup.

Rust Cloud Files copy probe (2026-10-27): Windows normally hides Cloud Files reparse points from some applications; the Rust worker now temporarily opts its protocol thread into exposing placeholders and restores its prior mode. The ignored live hash and copy probes passed on the recorded `-returned.txt` file. The test verified its recorded SHA-256 before and after copying to a unique temporary destination, verified the destination hash, and removed the temporary directory. The file had tag `0x9000601A` and state `0x9` (placeholder and in sync) without `PARTIALLY_ON_DISK`, so this verifies reading/copying already-local iCloud-managed content, not online-only hydration or download. This is one local provider observation and does not certify online-only behavior or ongoing sync health. See Microsoft's [Cloud Files compatibility guidance](https://learn.microsoft.com/en-us/windows/win32/cfapi/build-a-cloud-file-sync-engine) and [`RtlSetThreadPlaceholderCompatibilityMode`](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/nf-ntifs-rtlsetthreadplaceholdercompatibilitymode).

Online-only hydration attempt (2026-10-27): The same recorded fixture was saved to a temporary local backup first; its SHA-256 matched the recorded expected digest. After the fixture was deliberately dehydrated, its attributes showed `OFFLINE` and `RECALL_ON_DATA_ACCESS`. A synchronous native pin request waited. Windows `attrib +P` returned successfully, but the file remained online-only with recall set after a 60-second wait. `attrib -P` then cleared the temporary pin and restored the original unspecified pin intent. The subsequent Rust live hash probe ended after about 121 seconds with Windows error 426, “The cloud operation was not completed before the time-out period expired.” The fixture remains online-only, and the retained backup still matches the expected SHA-256. No file-content write was made. This attempt did not verify provider hydration; the backup is retained until the local fixture can be restored safely.

Hydration wait cancellation (2026-10-27): the worker now polls pending 64 KiB Cloud Files range requests, checks the copy cancellation event, and issues targeted `CancelIoEx` after 120 seconds. It keeps the handle and `OVERLAPPED` alive until Windows reports completion. The current immutable snapshot passed 34 unit tests, including cancellation/timeout decision cases, and built successfully; the read-only metadata protocol returned success with the generated mapping. Two live probes and five registered-provider integration tests were ignored in this ordinary run. A new registered-provider test holds a fetch until cancellation, then checks the cancellation callback and overlapped completion; it compiles but has not been executed in a disposable guest.

Rust maintainability pass (2026-10-27): copy-review controls and setup-preview inputs were grouped into named records, and the remaining mechanical Clippy findings were cleaned up. `cargo fmt --check` passed; the immutable release snapshot passed 34 backend unit tests (0 failed, 2 live-provider probes ignored), compiled all five registered-provider tests (all 5 remain ignored outside an isolated guest), built the release worker, and passed `cargo clippy --locked --all-targets -- -D warnings`. Snapshot worker SHA-256: `7DA1084B1BD0A9C5D5E6D685AE085D7CB4555795BEAFA6F32F91C02CF8941037`. Generated folder-map and source hashes matched.

Cloud Files Sandbox attempt (2026-10-27): the corrected immutable snapshot built in a disposable Windows Sandbox, but all five registered-provider tests failed at initial `CfRegisterSyncRoot` with HRESULT `0x80070057` before any test body or provider callback ran. No provider test passed. The guest shut down and temporary test roots were cleaned by their failure path. The exact snapshot then passed all five registered-provider tests on a GitHub-hosted Windows VM in run 40497643317, confirming that this registration failure was specific to the Sandbox environment.

Hosted continuation validation (2026-10-27): commit `815e296ba26dca0074ebc2dcb44f1db93d3178f3` passed all eleven jobs in [run 40497643317](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/40497643317). The registered-provider Cloud Files hydration suite passed, including the in-flight cancellation callback and overlapped-completion test that could not register its provider in Windows Sandbox. Rust UI/backend and package fixtures, the native WinUI accessibility/high-contrast/picker checks, six OS/shell suites, three isolated integration jobs, ARM64 cross-compilation and immutable release-package verification also passed. This hosted result does not verify online-only hydration through the developer iCloud provider, external screen-reader speech, physical mixed-DPI transitions, production routing or native ARM64 runtime support.

Rust UI maintainability pass (2026-10-27): removed redundant casts from color blending and changed terminal-result selection to use the double-ended iterator. `cargo fmt --check` passed; the immutable release snapshot passed all 13 UI unit tests, built successfully, and passed `cargo clippy --locked --all-targets -- -D warnings`. No UI window was launched, so this result adds no new visual or accessibility evidence.
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

The unsigned builder fixes entry order and ZIP timestamps to the source commit, enabling byte-identical retries on the same runtime. Signed timestamped builds need not be identical. Verification checks ZIP paths and the source policy's size limits before extraction. Publication additionally requires the manifest's commit and version to match the checked-out version tag. A draft with different already-uploaded bytes is retained for inspection rather than overwritten.

A version-tag push runs the full validation workflow before publishing. The release job requires the tag to point to the checked-out commit, creates or resumes a draft, verifies uploaded bytes by downloading them, then publishes. It refuses to overwrite a published version. The legacy `Release` and `v2.0.0` remain unchanged. The workflow has read-only permissions by default; only the publication job has contents-write access.

## Native candidate and external verification boundaries

[Hosted run 40002408818](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/40002408818), source 5ab9f356b81867c5471383ca9671dab11ee19ddf, passed all eleven jobs on 2026-10-23: six shell combinations, three guarded integration/API images, native UI and immutable package verification. Native coverage includes x64 Debug/Release builds, ARM64 cross-compilation, behavior, 54 layout variants, automation names/roles/help and focus navigation, real high-contrast rendering/restoration, and actual owned folder/open/save dialogs. Save cancellation, exact selected path/content and completion announcement passed. Windows may initialize an empty inactive contrast scheme name; all flags, original Light/Dark palettes and pre-existing scheme names must still be preserved.

Additional local native fixtures passed confirmed/cancelled stub cloud create/cleanup, fresh-preview gating and recovery-specific error guidance. A backup SID/schema mismatch no longer receives iCloud-root instructions. These tests ran from a temporary source snapshot outside iCloud after conflict copies disrupted local Debug binaries; no conflict copies were removed. PowerShell 5.1 and 7 pass release-policy BOM/legacy-array parsing and unsafe-path rejection. The complete release-tool suite also passes under PowerShell 7, including byte-identical rebuilds, changed checksums, traversal and unavailable-certificate rejection. Final main integration requires a green run for its exact source commit.

The unreleased native x64 package passed local checksum, complete-file manifest, syntax, PE architecture and dependency-target checks on 2026-10-23. Two builds from the same immutable source produced identical unsigned bytes. Rejection tests passed for changed checksums, unsafe ZIP paths and unavailable signing certificates. The updated verifier also accepted the published legacy v2.3.1 archive. On a verified hidden desktop, all four extracted entry modes started the Release app, and a complete fixture installation launched its installed checker. Native ARM64 runtime, Narrator speech and physical DPI transitions remain unverified. See [native migration evidence and remaining gates](WINUI.md).

- Repeat the documented remote round trip on each new installation or when diagnosing sync problems. The observed pass above applies to the tested account, version and time.
- Actual trusted signing requires a suitable certificate. Optional signing and rejection of an unavailable certificate are implemented; releases are explicitly unsigned until such a certificate is supplied.
- Application-specific custom save locations and other iCloud versions are not universally certified by a standard Windows dialog test. Retain this scope statement instead of claiming perfection or compatibility with every application/version.

## UX regression fixtures (2026-10-19, unreleased)

Local fixture tests verify actionable outcome text, action-specific confirmation with Cancel selected, keyboard focus and safe Enter behavior, native UI Automation name/role and MSAA properties. Layout/font fixtures render at 100, 125, 150 and 200 percent. A real child copy worker reports live progress and stops after its first verified file; originals and completed copies remain. No developer-account folder settings are changed. Actual Narrator speech and physical multi-monitor DPI transitions remain manual checks; scaled renderings are not evidence of those behaviors.
