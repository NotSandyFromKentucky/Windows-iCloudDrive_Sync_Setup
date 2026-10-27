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
| backend/ | Experimental Rust worker; generated metadata and compiler outputs stay outside the source tree. |
| build/ReleaseFiles.json | Central runtime allowlist, native build inputs and payload validation policy. |
| .github/workflows/ | Windows CI matrix and gated version-tag publication. |
| .local/ | Ignored local artifacts, logs, screenshots and evidence; never package or commit. |

This layout follows runtime boundaries instead of adding a generic `src/` layer: PowerShell entry points and modules stay at the root because extracted packages, Explorer shortcuts and scripts depend on those paths; the Rust worker and UI have separate build roots; tests, build policy, release tools and documentation each have one home. For new work, extend the owning module and its established test suite instead of adding numbered or ad hoc duplicate scripts. Keep machine-specific caches and bulky run evidence out of release inputs. This checkout currently keeps them under ignored `.local/` for compatibility with existing builders; moving them outside the iCloud-synced tree requires centralizing and verifying all cache paths first.

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

The version-1 stdin protocol supports metadata, raw registry inspection, current/default Windows folder lookup, configuration checks, setup/reset previews and Apply, backup snapshot/validation, restore previews and Apply, copy-pair/planning, preview-bound copy Preview/Apply, and read-only `plan`/`plan_many` requests. Setup/reset previews return existing and proposed registry values, actions, root-registration status, destination obstruction checks and content warnings. Setup preview enumerates only enough of each existing source folder to detect whether it contains an item; synthetic Cloud Files provider integration passed hosted run 40388160044, while actual iCloud behavior has not been certified. Reset uses Windows default paths and fails closed if Windows cannot supply them. `backup_snapshot` returns current values, registry kinds/presence, SID and UTC time in memory; it does not create a file. `validate_backup` applies the account-bound PowerShell schema and generated folder allowlist. Restore file previews are bounded to 4 MiB, accept UTF-8 with or without a BOM, refuse encrypted/reparse files and validate the selected account, destinations and recovery-folder placement. The `setup_apply`, `reset_apply` and `restore_apply` requests require `confirmed: true` and a SHA-256 token matching a freshly generated preview. They create and validate a new recovery backup, check destination access, reread registry values after the backup to detect races, then verify each write and attempt reverse-order rollback. Hosted guarded success/token/backup checks passed; injected Win32 rollback failure remains untested. Copy Apply also requires `confirmed: true`, rebuilds the full review under the shared settings mutex, rejects stale tokens, binds existing directory identities into the approval token, and holds those directories open without delete sharing through the copy. Each missing child directory and file is created atomically relative to its pinned parent handle using [`NtCreateFile`](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile)'s `RootDirectory` support and the `FILE_CREATE` disposition; returned handles remain open through verification. Local NTFS fixtures verify that existing and newly created directories cannot be renamed while held and that copy Apply uses create-only relative writes. A disposable-provider fixture for Cloud Files root compatibility is compiled but has not yet run. The `copy_pairs`/`copy_plan` requests derive pairs from current values and central mappings; planning can hydrate cloud placeholders. `plan_many` performs cross-pair overlap checks, hashes all source trees, refuses conflicts, and buffers the plan until preflight succeeds. Install remains in the compatibility PowerShell bridge; the Rust worker does not provide package installation.
For copy planning, Rust queries exposed reparse tags through `GetFileInformationByHandleEx(FileAttributeTagInfo)` using `FILE_FLAG_OPEN_REPARSE_POINT`. It distinguishes the `IO_REPARSE_TAG_CLOUD` family also recognized by `Assert-CopyPath`. Recognized Cloud Files placeholders are hydrated in bounded 64 KiB ranges through the registered provider; the worker reopens the data stream and verifies stable file identity and metadata before hashing. This can download cloud-only data during a read-only plan. Links and other reparse points remain refused. The guarded provider test compiles but has not run on this developer account, so provider integration and actual iCloud hydration remain unverified.

File-plan SHA-256 uses Windows CNG through `BCrypt` with one provider per plan and a reusable bounded input buffer. The planner opens regular files with `CreateFileW`, `FILE_SHARE_READ`, and `FILE_FLAG_OPEN_REPARSE_POINT`, streams them through synchronous `ReadFile`, and compares volume/file identity, size and last-write metadata through `GetFileInformationByHandle` before and after hashing. The owned handle is closed on every return path. A hidden-desktop fixture checks the public `plan` protocol against a known digest, verifies the terminal success record, confirms an absent destination remains absent, and confirms an identical destination is recognized without copying or changing either fixture file. It needs no registry access or isolated account. `sha2` was removed from the runtime dependency graph; the Windows API implementation must keep the existing uppercase 64-character SHA-256 representation.

The Rust unit suite includes a test-only CFAPI protected-handle lifecycle probe against a unique ordinary file under the system temp directory. It uses the foreground flag, matches each protected-handle reference with a release, reads with an `OVERLAPPED` and waits for completion, and closes only the opaque handle with `CfCloseHandle`. This confirms basic handle ownership and asynchronous reads for a normal local file; it is not evidence for Cloud Files placeholders, hydration, iCloud or copy parity. The probe is excluded from the runtime worker protocol.

Registry-dependent reads and previews acquire the existing `Local\ICloudFolders-<SID>` mutex with a zero-timeout wait. The name and fail-fast behavior match the PowerShell settings operation; an abandoned mutex is treated as acquired. This serializes the worker with PowerShell's operations without claiming to block unrelated applications. Hidden-desktop coverage holds the PowerShell mutex and confirms Rust refuses a backup snapshot while it is owned.

`restore_preview` accepts an in-memory `backup` record using the existing PowerShell recovery schema. It validates the account/key/allowlist before reading only the selected current registry values, checks that present restored destinations exist as directories, rejects recovery storage inside current or proposed folders, and reports exact proposed strings/types and removals for originally absent values. It does not create directories, read source contents or write settings. Its destination checks and action rules are compared with PowerShell using synthetic recovery records on the hidden desktop.

`persist_backup_new` retains create-new semantics, a UTF-8 BOM compatible with Windows PowerShell 5.1, a flush, schema validation and exact serialization round-trip. A separate helper creates protected recovery directories with a current-SID and LocalSystem DACL, and refuses reparse points and non-directories. The checked transaction algorithm is shared by the fake registry fixture and Win32 adapter; it checks each read-back and rolls touched values back in reverse order, including originally absent values. Hosted integration has passed setup/reset/restore writes, stale-token refusal and durable-backup checks across Windows Server 2022, 2025 and ARM. The remaining rollback gap is a forced Win32 API failure; rollback failure behavior is tested through the fake adapter.

The shared transaction algorithm is tested through a fake registry adapter, including read-back failures, reverse-order rollback, originally absent values and incomplete rollback reporting. The Win32 adapter implements `RegSetValueExW` and `RegDeleteValueW`; it is reachable only through confirmed, preview-bound worker write requests. `Build-NativeBackend.ps1 -Test` enables a test-only hook that sends an invalid handle to the Win32 write API once, then verifies hosted rollback restores exact values; ordinary worker builds omit this hook. Hosted runs [40388160044](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/40388160044), [40390782582](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/40390782582), and the latest readiness run [40400292958](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/40400292958) passed settings/copy integration, stale-token refusal, durable backups, Win32 failure injection and exact disposable registry restoration. The Rust worker remains a development backend and production launchers still select WinUI/PowerShell.

## Experimental Rust UI

Production launchers retain WinUI and their Setup/Reset/Check/Install modes. The Rust UI is an experimental native development interface with asynchronous preview/action flows that require a current preview and action-specific confirmation. When a Rust backend worker is configured or bundled, Check, setup/reset Preview, recovery Dry run and copy Preview use the worker; reviewed setup/reset/restore/copy Apply requests pass the current token to it. Copy Apply rebuilds the plan, creates destinations without overwriting, verifies hashes, retains originals and observes cancellation at safe file boundaries. The current local change also reports progress and checks cancellation during the fresh copy preflight, between entries and while streaming hashes; a single active Cloud Files hydration request may still delay Stop. Registry-backed and copy Apply integration must run behind `tests/Assert-IsolatedEnvironment.ps1` in Windows Sandbox or on a GitHub-hosted Windows runner. Latest hosted run [40400292958](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/40400292958) passed backend and UI/package integration, including the Rust UI confirmation-to-copy-Apply route and high-contrast rendering. Cloud test and Install intentionally retain the compatibility PowerShell bridge, and hidden-desktop tests verify their exact action/phase requests through that bridge. Production release routing remains open. Rust UI fixtures verify native MSAA and UI Automation exposure at 96, 144 and 192 DPI, but do not verify Narrator speech, external assistive-technology behavior or physical mixed-DPI transitions. The builder requires the Rust/linker prerequisites plus the Windows SDK manifest tool (mt.exe), which it discovers from an installed or NuGet-cached SDK without changing global PATH.

~~~powershell
$build = .\tools\Build-RustUI.ps1 -Test
.\tests\Test-RustUI.ps1 -WorkerPath $build.WorkerPath
.\tests\Test-RustLaunchRouting.ps1
.\Start-ICloudFolderSetup.ps1 -UseRustPreview
~~~

The direct alternative is `Start-ICloudRustUI.ps1`. It validates the cached UI against the executable, four Rust source/manifest inputs and central mapping-source hash, and validates the backend against its three Rust inputs, generated mapping-source hash and executable. A stale or missing build is rebuilt from an immutable snapshot; the bootstrap supplies `ICLOUD_NATIVE_BACKEND` and returns after launching the GUI. Extracted development packages bundle both executables and declare `Interface: Rust` in `manifest.json`; source checkouts keep WinUI as the default, and `-ForceWinUI` bypasses a Rust package selection. The experimental native `icloud-folder-launcher.exe` is retained locally but is not selected automatically. Do not publish it or rely on its older cache handling as validated release logic.

Rust UI fixtures own exact PIDs on the verified hidden desktop. Local fixture mode uses a stub bridge for large-output, cancellation and protocol tests; it does not invoke real registry-backed routes. The GitHub-hosted integration mode is enabled explicitly with `-RunNativeIntegration` and calls `Assert-IsolatedEnvironment`. It exercises worker-backed Check, setup/reset Preview, recovery Dry run and Windows-default copy Preview; restore integration uses a synthetic account-bound backup and verifies every table row without clicking Apply. Package integration disables the bridge temporarily while testing bundled worker routes, then restores the bridge file. The setup and copy tests verify table rows and that failed review gates keep Apply disabled. The backend integration separately exercises guarded settings Apply and copy Apply. Package tests cover the extracted and installed package, CMD launch and tamper rejection. On hosted Windows, backend parity failures write only a redacted assertion or terminal-error label to `GITHUB_STEP_SUMMARY` and `ICloudNativeBackendAssertion.txt`; the workflow retains that one-line file as a short-lived artifact and supplies a generic redacted fallback if the guarded step cannot write a label. Path-bearing messages and worker protocol details remain withheld. UI fixtures check native MSAA labels/roles and keyboard Tab behavior, and capture layouts with a per-monitor-aware test thread. The results list uses a visible “Folder results” static label. A standalone managed accessibility probe registers the standard Windows client-side providers and verifies the list is exposed as a named UI Automation DataGrid and an MSAA list at 96, 144 and 192 logical DPI. This verifies the fixture's prior generic fallback Pane gap; it does not verify Narrator speech or external-client behavior. Hosted Windows high-contrast settings have been exercised by the production UI job; Rust-specific Narrator speech, external assistive-technology behavior, large-text acceptance and physical mixed-DPI transitions remain open. No test timeout, forced cleanup or mere window appearance counts as successful validation.

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
