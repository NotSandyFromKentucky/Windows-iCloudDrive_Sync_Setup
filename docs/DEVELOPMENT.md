# Development and releases

## Repository layout

| Location | Responsibility |
| --- | --- |
| Root CMD files | Explorer installation/setup/reset/check shortcuts and unattended CLI compatibility. |
| Root PS1 files | Thin graphical, installation, command-line, diagnostic and copy entry points. Open-ICloudFolderSetup.ps1 retains the legacy console wrapper. |
| Root PSM1 files | Folder mapping/registry backend, explicit copy/merge, GUI and per-user installation. |
| docs/ | User CLI reference, architecture, development guidance and verification evidence. |
| tests/ | Fixture suites plus guarded disposable-Windows integration and API experiments. |
| tools/ | Immutable release packaging/publication and the explicit cloud round-trip helper. |
| backend/ | Experimental read-only Rust worker; generated metadata and compiler outputs stay outside the source tree. |
| build/ReleaseFiles.json | Central runtime allowlist, native build inputs and payload validation policy. |
| .github/workflows/ | Windows CI matrix and gated version-tag publication. |
| .local/ | Ignored local artifacts, logs, screenshots and evidence; never package or commit. |

Runtime files stay together at the root to preserve extracted-package paths, installed shortcuts, GUI worker lookup and existing CLI entry points. Do not relocate or delete compatibility wrappers just because a graphical alternative exists.

## Local verification

Native WinUI builds and hidden-desktop UI Automation are described in [the migration guide](WINUI.md). The PowerShell backend and compatibility suites below remain required.

Keep active native build/test checkouts outside cloud-synchronized folders. iCloud conflict resolution can rename changing EXE/DLL files and leave an incomplete local build even after MSBuild succeeds. Use a separate local checkout or temporary source snapshot for native fixtures. The immutable package builder already stages and compiles outside iCloud Drive; do not remove conflict copies as part of testing.

Run from the repository root:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ICloudFolders.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ExplorerLauncher.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Diagnostics.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-HiddenDesktop.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ContrastQuery.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-SetupUI.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-InstallerIntegrity.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ReleaseInputs.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FolderCopy.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-UserExperience.ps1
~~~

Core tests replace registry access with an in-memory boundary. GUI tests use a stub child script and render the real window. Installer/copy tests use unique fixture directories and fixture shortcuts, retaining personal files and live settings. The GUI suite checks Unicode paths, confirmation, preview invalidation, copy routes, package-style installation and tampered-source rejection.

GUI suites automatically relaunch through tests/Invoke-HiddenDesktop.ps1 on a unique non-input Windows desktop. The runner verifies the child's desktop name before tests start, never switches the input desktop, and uses a kill-on-close job object to contain descendants. Logs are retained under ignored .local/hidden-desktop. Failures and timeouts fail the suite; there is no fallback to the user's active desktop. Test-HiddenDesktop.ps1 checks real window creation, unchanged input desktop, failure propagation and timeout cleanup of a descendant process. The Windows PowerShell 5.1 child explicitly resolves its own built-in module directories rather than inheriting a PowerShell 7 parent's incompatible module search path. A fixture verifies hashing remains available even when the parent module path is unusable. Future UI suites must use the same runner. A hidden desktop isolates window focus, not files, registry access, credentials or network activity; existing fixture and disposable-VM restrictions still apply.

To run another fixture script without taking focus:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-HiddenDesktop.ps1 -ScriptPath .\tests\Test-UserExperience.ps1
~~~

Hidden-desktop rendering does not verify spoken Narrator output or physical monitor transitions. Keep those checks separate and explicitly scheduled rather than opening an interactive test on the developer's desktop.

Never test real apply/reset/restore against the developer account. Real-registry integration runs only behind tests/Assert-IsolatedEnvironment.ps1 in disposable Sandbox or GitHub-hosted Windows VMs. Self-hosted runners and ordinary accounts are refused. Integration covers real writes, exact restore, ACL denial, interrupted recovery, default-path reset, API behavior and a standard Save dialog fixture. This does not replace real iCloud cloud testing.

The CI workflow defines six OS/shell local-suite jobs, three guarded integration/API jobs, a native WinUI build/hidden-desktop job with ARM64 cross-compilation, then package verification. Run 40002408818 passed all eleven jobs, including native picker/contrast checks and hosted immutable package verification. Every subsequent release candidate still requires a complete green run for its exact source commit. The images are Windows Server 2022, Server 2025 and Windows 11 ARM. Server coverage does not imply Apple supports iCloud on Windows Server. Read [measured evidence](VERIFICATION.md), not just the workflow definition.

## Experimental Rust backend

The opt-in worker requires Rust 1.85+ with an MSVC Windows target and Windows SDK/CRT linker libraries. It is independent of the current UI/backend and is not included in release packages. Build a source snapshot outside iCloud Drive and run its Rust unit tests and hidden-desktop fixtures:

~~~powershell
$build = .\tools\Build-NativeBackend.ps1 -Test
./tests/Test-NativeCopyPlan.ps1 -WorkerPath $build.WorkerPath
.\tests\Test-NativeBackend.ps1 -WorkerPath $build.WorkerPath
./tests/Test-NativeCloudFiles.ps1 -Snapshot $build.Snapshot # guarded; disposable Sandbox/GitHub-hosted only
'{"version":1,"operation":"metadata"}' | & $build.WorkerPath
~~~

If MSVC's linker is unavailable, `-UseRustLld -LinkerLibraryDirectories <SDK-um>,<SDK-ucrt>,<VC-CRT>` uses Rust's bundled linker with libraries you already obtained from Microsoft. The script restores its process-local build environment afterward. Keep Cargo.lock; dependency updates require explicit review and regeneration. Build logs, generated mapping and build-info.json stay with the temporary snapshot. A custom output directory must be new and outside the repository/iCloud Drive. No generated map or executable belongs in the source tree.

The version-1 stdin protocol supports metadata, raw registry inspection, current and default Windows folder-path lookup, a read-only configuration check, `setup_preview`/`reset_preview`, `backup_snapshot`/`validate_backup`, `restore_preview`/`restore_preview_file`, `copy_pairs`/`copy_plan`, and read-only `plan`/`plan_many` requests. Setup/reset previews return existing and proposed registry values, action labels, root-registration status, directory obstruction checks and content warnings. They do not create directories, test write access, create backups or change registry values. Setup preview enumerates only enough of each existing source folder to detect whether it contains an item; cloud-provider behavior has not been certified. Reset uses Windows default paths and fails closed if Windows cannot supply them. `review_gates_passed` covers preview acknowledgements and root-registration gates only; it does not prove that a future backup or registry write will succeed. `backup_snapshot` reads all mapped current-user values, their original registry kinds and presence, the current SID, and a UTC timestamp into the existing version-1 recovery-record shape; Music is optional. It returns this record in memory only and does not create a backup file. `validate_backup` applies the current PowerShell schema rules to an in-memory account-bound record, including the generated folder allowlist, user SID, exact registry key, value presence/type and local path checks. Backup property names are matched case-insensitively, and duplicate names differing only by case are refused. It neither reads nor writes a backup file and does not restore values. `restore_preview_file` reads a caller-selected recovery JSON file with a 4 MiB bound, accepts UTF-8 with or without a BOM, refuses encrypted/reparse paths, then applies the same account/schema/destination checks as the in-memory preview. The file read is bounded and opened without sharing write/delete access. Neither restore-preview form changes settings. `copy_pairs` derives unique source/destination pairs from current-user `User Shell Folders` values and the generated central mapping, enforcing the selected iCloud root registration and custom destination rules. It reads registry data only and does not enumerate or hash source files. `copy_plan` derives the same pairs and then plans their content; reading cloud files can hydrate placeholders. `plan_many` accepts a list of pairs, performs cross-pair overlap checks, hashes the full source trees, refuses conflicts and deduplicates identical files targeting the same path. It buffers the bounded plan until preflight succeeds, so errors do not emit partial entries. The check request accepts `root`, optional `include_music`, and optional `folder_paths` keyed by the logical names from `Get-FolderMap` (`Desktop`, `Documents`, `Pictures`, `Videos`, `Downloads`, `Captures`, `Music`). It validates local destinations and containment/overlap rules, reads the mapped `User Shell Folders` values, checks existing directories and iCloud root registration, and resolves current Windows Known Folders. Registration enumeration keeps every current-SID root from case-insensitive `iCloudDrive!` provider entries and fails closed on malformed path values. It always labels cloud synchronization as unverified. Windows Known Folder lookups call `SHGetKnownFolderPath` from an initialized COM apartment; the check operation aggregates per-folder lookup errors while retaining successful rows and omits Music unless requested. Standalone default lookup fails closed if Windows supplies no default. Hidden-desktop fixtures compare configuration, pair derivation and multi-source planning with PowerShell. The worker still has no copy/write operation. Do not connect it to production apply/reset/restore or treat a missing terminal summary as a successful preview.
For copy planning, Rust queries exposed reparse tags through `GetFileInformationByHandleEx(FileAttributeTagInfo)` using `FILE_FLAG_OPEN_REPARSE_POINT`. It distinguishes the `IO_REPARSE_TAG_CLOUD` family also recognized by `Assert-CopyPath`. Recognized Cloud Files placeholders are hydrated in bounded 64 KiB ranges through the registered provider; the worker reopens the data stream and verifies stable file identity and metadata before hashing. This can download cloud-only data during a read-only plan. Links and other reparse points remain refused. The guarded provider test compiles but has not run on this developer account, so provider integration and actual iCloud hydration remain unverified.

File-plan SHA-256 uses Windows CNG through `BCrypt` with one provider per plan and a reusable bounded input buffer. The planner opens regular files with `CreateFileW`, `FILE_SHARE_READ`, and `FILE_FLAG_OPEN_REPARSE_POINT`, streams them through synchronous `ReadFile`, and compares volume/file identity, size and last-write metadata through `GetFileInformationByHandle` before and after hashing. The owned handle is closed on every return path. A hidden-desktop fixture checks the public `plan` protocol against a known digest, verifies the terminal success record, confirms an absent destination remains absent, and confirms an identical destination is recognized without copying or changing either fixture file. It needs no registry access or isolated account. `sha2` was removed from the runtime dependency graph; the Windows API implementation must keep the existing uppercase 64-character SHA-256 representation.

The Rust unit suite includes a test-only CFAPI protected-handle lifecycle probe against a unique ordinary file under the system temp directory. It uses the foreground flag, matches each protected-handle reference with a release, reads with an `OVERLAPPED` and waits for completion, and closes only the opaque handle with `CfCloseHandle`. This confirms basic handle ownership and asynchronous reads for a normal local file; it is not evidence for Cloud Files placeholders, hydration, iCloud or copy parity. The probe is excluded from the runtime worker protocol.

Registry-dependent reads and previews acquire the existing `Local\ICloudFolders-<SID>` mutex with a zero-timeout wait. The name and fail-fast behavior match the PowerShell settings operation; an abandoned mutex is treated as acquired. This serializes the worker with PowerShell's operations without claiming to block unrelated applications. Hidden-desktop coverage holds the PowerShell mutex and confirms Rust refuses a backup snapshot while it is owned.

`restore_preview` accepts an in-memory `backup` record using the existing PowerShell recovery schema. It validates the account/key/allowlist before reading only the selected current registry values, checks that present restored destinations exist as directories, rejects recovery storage inside current or proposed folders, and reports exact proposed strings/types and removals for originally absent values. It does not create directories, read source contents or write settings. Its destination checks and action rules are compared with PowerShell using synthetic recovery records on the hidden desktop.

The `persist_backup_new` prototype is compiled only for Rust unit tests. It saves synthetic records in a unique local temporary directory with create-new semantics, a UTF-8 BOM compatible with Windows PowerShell 5.1, a flush, schema validation and exact serialization round-trip. Tests confirm Unicode interoperability with PowerShell, preservation of pre-existing files and rejection before file creation for invalid records. Failed partial records are retained; this helper performs no deletion-based recovery. Account-private recovery-directory creation, race-resistant path ownership, failure injection, checked registry writes and rollback remain separate gates before this helper can become a runtime operation.

The unit-test-only transaction model applies a supplied set of desired values through a fake registry adapter, checks every read-back, and on failure restores touched values in reverse order, including removal of values absent from the original snapshot. Injected write and rollback failures verify the success and `ROLLBACK INCOMPLETE` reporting paths. It does not call Win32 registry mutation APIs and is not a runtime write implementation. Direct API writes still need isolated-environment integration, durable backup ordering and failure-injection parity before runtime exposure.

## Experimental Rust UI

Production launchers retain WinUI and its Setup/Reset/Check/Install modes. The Rust UI is an experimental native development interface with asynchronous preview/action flows that require a current preview and action-specific confirmation. When a Rust backend worker is configured or bundled, Check, setup Preview, and recovery Dry run use read-only Win32 implementations; setup keeps Apply disabled unless its review gates pass, and restore previews validate the selected account-bound recovery file and show exact current/proposed values and removals. Final Apply and other actions still use the PowerShell bridge. Setup Preview enumerates one item from existing source folders, while recovery Dry run reads the selected recovery file and current mapped registry values; tests exercising either route must run behind `tests/Assert-IsolatedEnvironment.ps1` in Windows Sandbox or on a GitHub-hosted Windows runner. Copy cancellation is cooperative at safe file boundaries; a folder-setting write is never terminated. The Rust UI remains outside production release routing: package/launcher fixtures pass, while full operation parity and UI Automation/screen-reader gates remain open. It requires the same Rust/linker prerequisites plus the Windows SDK manifest tool (mt.exe). The builder discovers an installed or NuGet-cached SDK tool without changing global PATH.

~~~powershell
$build = .\tools\Build-RustUI.ps1 -Test
.\tests\Test-RustUI.ps1 -WorkerPath $build.WorkerPath
.\tests\Test-RustLaunchRouting.ps1
.\Start-ICloudFolderSetup.ps1 -UseRustPreview
~~~

The direct alternative is `Start-ICloudRustUI.ps1`. It validates the cached UI against the executable, four Rust source/manifest inputs and central mapping-source hash, and validates the backend against its three Rust inputs, generated mapping-source hash and executable. A stale or missing build is rebuilt from an immutable snapshot; the bootstrap supplies `ICLOUD_NATIVE_BACKEND` and returns after launching the GUI. Extracted development packages bundle both executables and declare `Interface: Rust` in `manifest.json`; source checkouts keep WinUI as the default, and `-ForceWinUI` bypasses a Rust package selection. The experimental native `icloud-folder-launcher.exe` is retained locally but is not selected automatically. Do not publish it or rely on its older cache handling as validated release logic.

Rust UI fixtures own exact PIDs on the verified hidden desktop. Local fixture mode uses a stub bridge for large-output, cancellation and protocol tests; it does not invoke real registry-backed routes. The GitHub-hosted integration mode is enabled explicitly with `-RunNativeIntegration`, calls `Assert-IsolatedEnvironment`, and exercises worker-backed Check, setup Preview, and recovery Dry run. Restore integration uses a synthetic account-bound backup in the disposable test environment, verifies every table row and leaves Apply unclicked. Package integration also disables the bridge temporarily while testing the bundled worker, then restores the bridge file. The setup test verifies table rows and that failed review gates keep Apply disabled. Package integration tests exercise the bundled worker from the extracted and installed package, plus CMD launch and tamper rejection. Fixtures check native MSAA labels/roles and keyboard Tab behavior, and capture layouts with a per-monitor-aware test thread. The results list uses a visible “Folder results” static label. The parity test compiles a standalone managed accessibility probe that registers the standard Windows client-side providers, then verifies the list is exposed as a named UI Automation DataGrid and an MSAA list at 96, 144 and 192 logical DPI. This verifies the fixture's prior generic fallback Pane gap; it does not verify Narrator speech or external accessibility-client behavior. Spoken Narrator output, high contrast, large text and physical mixed-DPI transitions still need acceptance. No test timeout, forced cleanup or mere window appearance counts as successful validation.

## Package verification

The release builder reads an exact Git commit, not uncommitted working files. After committing the intended source:

~~~powershell
$package = .\tools\New-ReleasePackage.ps1
.\tools\Test-ReleasePackage.ps1 -Archive $package.Archive
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-NativePackage.ps1 -Archive $package.Archive
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ReleaseTools.ps1
~~~

The version-2 release policy separates shipped runtime paths from native compilation inputs. The builder uses the pinned SDK and locked packages, publishes outside iCloud Drive, includes the generated application PRI, and validates architecture and required dependencies. The native package suite tests all four Explorer entry modes and a complete fixture installation on a hidden desktop; it creates no real user shortcuts or folder redirections.

The release-tool suite checks reproducible unsigned bytes on the same runtime, valid contents, bad checksums, traversal rejection before extraction and unavailable signing certificates. Update VERSION and build/ReleaseFiles.json together with intended release inputs. Include documentation referenced by the shipped README; exclude tests, IDE state, credentials and personal artifacts from release files.

## Publish a release

Use a new version and matching CHANGELOG.md section. Commit and verify the source, then push an immutable version tag. The release workflow runs the full CI gates before publication. The publisher matches the tag, manifest commit and version; creates or resumes a draft; uploads the ZIP/checksum; downloads and verifies both; and publishes as latest. It refuses to overwrite an already published version.

Published tags/assets, including legacy releases, are immutable. The failed v2.3.0 tag was left unchanged. Optional signing uses an existing trusted code-signing certificate and staged files only; current packages are explicitly unsigned. Signing limits are described in [verification](VERIFICATION.md).

## Local cleanup

### Preserve Git staging during continuation

Check the dated handoff in [project context](CONTEXT.md) before Git writes. This workspace has an intentionally absent real `.git/index`; default Git status/diff can therefore suggest mass staged deletions. Do not reset, rebuild that index, or stage those deletions. Inspect working files against HEAD using a fresh alternate index. For example, in PowerShell:

~~~powershell
$previousIndex = $env:GIT_INDEX_FILE
$reviewIndex = Join-Path $PWD ('.local/review-' + [guid]::NewGuid().ToString('N') + '.index')
try {
    $env:GIT_INDEX_FILE = $reviewIndex
    git read-tree HEAD
    git diff -- AGENTS.md docs/CONTEXT.md docs/DEVELOPMENT.md
    # For a commit, add only intended paths to this index and inspect its cached diff.
    # Seed a new alternate index from current HEAD for every later candidate.
} finally {
    $env:GIT_INDEX_FILE = $previousIndex
}
~~~

Create the ignored `.local` directory first if absent. If Git reports dubious ownership, use a checkout-specific `-c safe.directory=<absolute checkout path>` on each command rather than a global wildcard exception. Verify the real index is still absent afterward. Compare local/remote refs before a non-forced push, and never overwrite unrelated changes. Local benchmark JSON, screenshots, logs and temporary indexes are evidence/artifacts, not source inputs.

If `.git/objects` is read-only during patch inspection, a temporary `GIT_OBJECT_DIRECTORY` under `.local` plus `GIT_ALTERNATE_OBJECT_DIRECTORIES` pointing to the existing `.git/objects` lets the alternate index stage review blobs without changing the real object database. Restore both environment variables afterward. Those review-only objects are not automatically available for a real commit or push.

Ignored .local artifacts include recovery-related evidence and cloud-test state as well as rebuildable downloads. Do not use broad git clean or recursive deletion without identifying the contents and checking absolute target paths. Repository cleanup must not delete source files, recovery records, IDE state or cloud-synchronized test content. The Git-tracked tree and release allowlist define distributed content; ignoring a directory does not prevent iCloud from synchronizing it.

The UX suite briefly opens fixture windows and saves scaled screenshots under ignored .local/ux. It verifies UI Automation/MSAA metadata and keyboard focus, not spoken screen-reader output. Manually check Narrator announcements and moving the window between monitors with different DPI before claiming full accessibility coverage.
