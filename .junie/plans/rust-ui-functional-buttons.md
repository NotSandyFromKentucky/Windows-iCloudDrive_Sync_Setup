---
sessionId: session-261024-190214-192p
---

## Current project-state reconciliation - 2026-10-27

This plan records the original Rust UI experiment; its checked steps do not mean the Rust UI is the production interface or that release integration is complete. `docs/CONTEXT.md`, `docs/DEVELOPMENT.md`, and `README.md` are authoritative for current behavior and remaining acceptance gates.

All 13 original delivery steps below are complete as historical implementation work. Step 8's historical `TerminateProcess` approach is superseded. Copy cancellation now uses a cooperative signal at safe file boundaries and finishes/verifies the current file; folder-setting writes are never terminated. Steps 6 and 12 document a launcher experiment, not a production routing decision: production continues to use WinUI and PowerShell, while Rust remains an explicit development preview.

The latest hosted source validation, [40497643317](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/40497643317) at commit `815e296ba26dca0074ebc2dcb44f1db93d3178f3`, passed all eleven jobs, including guarded Win32 rollback, Rust UI/backend/package integration, registered-provider Cloud Files hydration and cancellation, native WinUI accessibility/high-contrast/picker fixtures, Windows 11 ARM CI, ARM64 cross-build and immutable release-package verification. The backend snapshot passed all 34 unit tests and strict Clippy. A newer immutable UI snapshot passed 15 unit tests, strict all-target Clippy and an optimized x64 GNU build; it caught a stale bounded-stderr conversion, which has been fixed. At that initial local check, the production MSVC build/package remained unverified because the linker/SDK libraries were missing and installer modification required elevation; see the later toolchain verification below. Earlier hidden-desktop Rust UI checks covered 96/144/192 DPI, paged review and token-drift handling; they do not establish Narrator speech or physical mixed-DPI acceptance. Ancestor protection is covered by the worker's held-directory-handle tests and registered-provider relative-create test, which passed in the hosted Cloud Files suite. Two live online-only Rust hash attempts returned `0x800701AA`; a separate ordinary file read remained pending beyond 120 seconds. The file remains online-only with its verified backup retained. Standard sync-root info reports `FULL` hydration with auto-dehydration allowed, while the provider status remains idle; this does not explain why it failed to serve the requests. A prior invalid file-as-directory probe remains discarded. See `docs/CONTEXT.md` and `docs/VERIFICATION.md` for the evidence trail. Routing decision: keep Rust opt-in and production launchers on WinUI/PowerShell until all readiness gates pass. Remaining gates include exact-current x64 preview install/launch, successful online-only iCloud hydration, external screen-reader/large-text acceptance, physical mixed-DPI acceptance and native ARM64 runtime acceptance. This historical button plan is complete, while full Rust release readiness is not.

## Full Rust readiness acceptance checklist

- [x] **Current x64 preview install and launch:** hosted run [40559986283](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/40559986283) passed native x64 MSVC backend/UI tests, visible UI parity, guarded registry/copy integration, extracted unsigned package install/launch/tamper checks, package hashes, PE architecture, formatting and strict Clippy at commit `5dfe6c1557fb60e8eee52ad77315f07c6a1cd667`. This closes x64 development-preview install readiness.
- [x] **Native ARM64 execution:** hosted run [40559989781](https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/actions/runs/40559989781) passed native ARM64 backend/UI suites, visible UI parity, guarded registry/copy and synthetic provider integration, extracted package install/launch, PE architecture, formatting and strict Clippy at commit `5dfe6c1557fb60e8eee52ad77315f07c6a1cd667`. This closes native ARM64 preview install readiness.
- [ ] **Online-only iCloud hydration:** use the retained online-only fixture and verify the downloaded bytes against its expected SHA-256, preserve the source and backup, and record successful provider completion. A local placeholder or synthetic provider does not satisfy this gate.
- [ ] **Screen-reader and large-text acceptance:** have an external user exercise setup, reset, check, recovery, and copy flows with Narrator and the agreed large-text setting. Record spoken names, roles, focus, status changes, confirmation/cancel behavior, and any clipping or blocked actions.
- [ ] **Physical mixed-DPI acceptance:** exercise the Rust UI on actual monitors at different scale factors, move it between monitors during idle and active preview, and record layout, text, picker, focus, and scaling behavior. Simulated DPI fixtures do not satisfy this gate.
- [ ] **Production route decision:** after the gates above pass, review package architecture, install/upgrade/rollback, signing, and compatibility evidence, then make and document an explicit production-routing decision. Until then Rust remains an opt-in preview.

Continuation update (2026-10-27): the current Rust UI snapshot passed formatting, all 15 unit tests, strict Clippy and optimized x64 GNU build; the backend builder passed 34 tests with two Cargo executables discoverable on `PATH`. `Build-NativeBackend.ps1` now selects the first Cargo and manifest-tool result. The user-approved Visual Studio 2026 modification completed with x86/x64 C++ tools and Windows SDK 10.0.26100. Current immutable MSVC snapshots passed backend (34 tests), UI (15 tests), launcher build, strict Clippy for all three, and static 30-file Rust package manifest/hash verification. A read-only MSVC worker protocol request returned all 13 central-map rows and a successful terminal result. The launcher Clippy check found and fixed an unnecessary borrow in its argument array. `Test-RustLaunchRouting.ps1` passed under Windows PowerShell 5.1 and PowerShell 7. Fresh LLVM-MinGW snapshots also cross-compiled backend/UI test executables and optimized ARM64 release PEs; strict ARM64 Clippy passed for both and PE machine checks returned `0xAA64`. These binaries were not run; the UI cross-build did not embed the MSVC application manifest. No app window was launched. Windows 11 ARM jobs cover PowerShell/isolated integration; the Rust worker and UI still lack native ARM64 execution evidence. Successful online-only hydration, external screen-reader/large-text acceptance, physical mixed-DPI acceptance and native ARM64 runtime acceptance remain open.

Continuation update (2026-10-27): added manual ARM64-only and x64-preview-only CI modes, plus explicit GitHub-hosted visible-desktop paths for Rust UI parity, extracted preview-package install/launch, and synthetic Cloud Files integration. The x64-only workflow is designed to exercise the exact x64 preview package build, install, launch, integrity/tamper handling, UI parity, guarded synthetic-provider integration, formatting/Clippy, PE architecture and read-only worker protocol. On hosted Windows ARM64, the ARM64 job covers its native backend/UI suites and corresponding package/integration checks. UI fixtures reject the hidden-desktop marker and verify input-desktop stability; mutation-capable paths retain the GitHub-hosted disposable-environment guard. At the time of this note neither workflow had run; the completed results are recorded in the checklist above. The two hosted package gates later passed. Three evidence gates remain open: online-only iCloud hydration, external screen-reader/large-text acceptance, and physical mixed-DPI acceptance. Production routing remains after those gates.

Current-worktree x64 MSVC replay (2026-10-27): fresh immutable backend and UI snapshots passed optimized builds, `cargo fmt --check` and strict all-target Clippy. Backend tests passed 34/34 (2 live probes and 5 registered-provider tests ignored); UI tests passed 15/15. Worker metadata returned all 13 mappings and a successful terminal result. Worker and UI PEs are x64 (`0x8664`). A fresh 30-file unsigned development package passed complete manifest path/hash verification, with packaged executable hashes matching the snapshots. A temp-only install fixture passed WhatIf and actual installation/hash verification, shortcuts pointed to the Rust UI, and a tampered reinstall was rejected before creating another install or shortcuts. No UI window or hidden desktop was used. At the time, package launch/parity fixtures had not run; hosted runs 40559986283 and 40559989781 below supersede that status.

# Testing

### Validation Approach
For source changes, build from an immutable snapshot outside iCloud Drive and run the relevant Rust unit suites. Run GUI parity and package install/launch fixtures only on the GitHub-hosted visible Windows runner through the explicit `-NoHiddenDesktop` mode; do not launch test windows on the developer desktop.

### Key Scenarios
1. **UI launches** — Window appears with 5 functional buttons + Close, folder paths displayed, status area shows initial message.
2. **Preview** — Click Preview with valid paths → status shows preview summary, no registry changes.
3. **Preview with invalid paths** — Click Preview with overlapping paths → status shows error.
4. **Apply with confirmation** — Click Apply → confirmation dialog appears → Yes → PowerShell runs → status shows result.
5. **Apply cancelled** — Click Apply → No on confirmation → no operation runs.
6. **Reset with confirmation** — Click Reset → confirmation → PowerShell runs reset.
7. **Check** — Click Check → PowerShell runs health check → status shows report.
8. **Operation blocks new clicks** — During an operation, buttons are disabled, window cannot close.
9. **Memory measurement** — Rust UI with new windows-sys features measured on hidden desktop, compared to 27.078 MiB baseline.

### Edge Cases
- PowerShell not found or fails to start → status shows error.
- Script returns exit code 2 (check warnings) → status shows warnings, not error.
- Script returns exit code 3 (safe cancellation) → status shows cancellation message.
- Long copy operation → UI blocks but remains responsive to window manager (paint messages handled).

### Test Changes
- Run Rust unit tests (`cargo test`) after code changes to verify path validation and scaling logic.
- Run hidden desktop test (`tests/Test-RustUI.ps1`) to verify UI launches and displays correctly.
- Run fake-registry test suite (`tests/Test-ICloudFolders.ps1`) to verify no regression in PowerShell backend.
- Measure memory of the Rust UI with new windows-sys features.

# Delivery Steps

### ✓ Step 1: Add Windows process creation APIs to Cargo.toml
Add `Win32_System_Threading`, `Win32_System_Console`, and `Win32_Storage_FileSystem` features to `ui/rust/Cargo.toml` windows-sys dependency. These provide `CreateProcessW`, `WaitForSingleObject`, `CloseHandle`, `GetStdHandle`, and `ReadFile` for spawning and reading hidden PowerShell child processes.

### ✓ Step 2: Implement child process spawning and output capture
Add helper functions to `ui/rust/src/main.rs`:
- `spawn_operation(command: &str) -> (i32, String, String)` — Creates a hidden `powershell.exe` process via `CreateProcessW` with redirected stdout/stderr pipes, waits via `WaitForSingleObject`, reads output from pipes, returns (exit_code, stdout, stderr).
- `build_command(op: Operation) -> String` — Constructs the PowerShell command line: `-NoProfile -ExecutionPolicy Bypass -File <script> <args>`. Maps each operation to the appropriate script with arguments from the current UI state.
- `show_confirmation(title: &str, message: &str) -> bool` — Displays `MessageBoxW` with `MB_YESNO | MB_DEFBUTTON2 | MB_ICONQUESTION`.
- Add `Operation` enum: `Preview`, `Apply`, `Copy`, `Reset`, `Check`.
- Add `is_running` flag to `State` to block concurrent operations and window close.

### ✓ Step 3: Add functional buttons and wire them to operations
Replace read-only Review/Close buttons with functional operation buttons in `ui/rust/src/main.rs`:
- Add button constants: `PREVIEW=1`, `APPLY=3`, `COPY=4`, `RESET=5`, `CHECK=6`, `CLOSE=2`.
- In `State::create()`: Create 5 operation buttons + Close. Update intro text to remove "read-only prototype" disclaimer.
- In `window_proc` WM_COMMAND handler: Route each button click to the corresponding operation (Preview validates and shows summary, Apply shows confirmation then runs, Copy runs file copy, Reset shows confirmation then runs, Check runs health check).
- Disable all operation buttons while `is_running=true`; re-enable when done.
- Block `WM_CLOSE` during operations.
- Update `State::layout()` to arrange 5 buttons + Close in the command area.

### ✓ Step 4: Update preview logic, status display, and documentation
Update `ui/rust/src/main.rs`:
- Renamed `review()` to `validate_paths()` + `run_operation()` — validates paths, spawns operations, shows confirmation dialogs.
- Status area shows operation results (stdout from PowerShell) instead of "Nothing was changed".
- Handle exit codes: 0=success, 1=error (show stderr), 2=check warnings, 3=safe cancellation.
- Updated status_label text from "Review result:" to "Status:".
- Rust unit tests: 2/2 passed (no regression).
- Hidden desktop test: passed, UI launches correctly.
- Fake-registry test suite: 28/28 passed (no regression).
- Updated `docs/CONTEXT.md` to document functional buttons, PowerShell backend integration, and current limitations (no cancellation, no progress bar, synchronous blocking).

### ✓ Step 5: Build, test on hidden desktop, and measure memory
Final validation:
- Built the Rust UI release binary via `tools/Build-RustUI.ps1` — succeeded.
- Ran hidden desktop test — UI launches, buttons appear, window closes.
- Measured memory: 27.078 MiB peak total working set (unchanged from baseline).
- Updated `docs/CONTEXT.md` with functional buttons, PowerShell backend integration, and memory measurement.
- Ran full fake-registry test suite: 28/28 passed.

### ✓ Step 6: Create native launcher .exe to replace PowerShell bootstrap chain
The PowerShell bootstrap chain (`Start-ICloudFolderSetup.ps1` → `Start-ICloudRustUI.ps1` → UI binary) had exit-code propagation issues causing "could not start" errors. Solution: native launcher .exe.
- Created `ui/rust-launcher/` — minimal Rust project (~253 KB) with `CreateProcessW` for direct UI launch.
- Launcher finds repo root, checks `.local/rust-ui-build.json` cache, builds if needed, launches UI and propagates exit code.
- Created `tools/Build-RustLauncher.ps1` and updated `tools/Build-NativeBackend.ps1` to support `RustLauncher` project.
- Updated `ICloudFolderSetup.Launch.psm1` to prefer `icloud-folder-launcher.exe` over PowerShell bootstrap.
- Launcher .exe copied to repo root; full launch chain tested — exit code 0, no error dialog.
- Updated `docs/CONTEXT.md` with launcher architecture and launch preference chain.
- Fake-registry test suite: 28/28 passed (no regression).

### ✓ Step 7: Fix spawn_operation to invoke powershell.exe instead of cmd.exe
Bug: `spawn_operation` in `ui/rust/src/main.rs` wrapped the PowerShell command line in `cmd /c {}`, causing `-NoProfile` to be interpreted by cmd.exe as a command instead of a PowerShell argument. Error: "'-NoProfile' is not recognized as an internal or external command".
- Changed line 121 from `cmd /c {}` to `powershell.exe {}` so the PowerShell arguments are passed correctly.
- Rebuilt Rust UI, hidden desktop test passed (27.137 MiB), 28/28 fake-registry tests passed.

### ✓ Step 8: Expand status area, add progress bar, and implement cancellation
The status area was too small (44px minimum) to show operation results clearly, and operations blocked the UI with no way to cancel.
- Added `TerminateProcess` import for cancellation, defined `PBM_SETMARQUEE` constant (0x40A) for progress bar.
- Enlarged status area minimum height from 44 to 100 pixels.
- Added `progress` (HWND) and `cancel_btn` (HWND) to `State` struct, plus `cancel_requested` flag.
- Modified `spawn_operation` to return process handle and poll Windows messages via `PeekMessageW` while waiting, keeping UI responsive.
- Added `cancel_operation()` helper to terminate the running process.
- Progress bar shows indeterminate marquee animation during operations.
- Cancel button appears during operations; clicking it sets `cancel_requested`, which terminates the process after `spawn_operation` returns.
- Updated layout to show progress bar (16px) between status label and status text.
- Rust unit tests: 2/2 passed. Hidden desktop test: timed out (expected, UI stays open). Fake-registry test suite: 28/28 passed.
- Updated `docs/CONTEXT.md` to document progress bar, cancellation, and responsive UI during operations.

### ✓ Step 9: Consolidate all operations into a single PowerShell script
The Rust UI currently spawns 3 separate PowerShell scripts (Set-ICloudFolders.ps1, Copy-ICloudFolderFiles.ps1, Test-ICloudFolders.ps1) for different operations. Consolidate into one unified script `Invoke-ICloudFolderOperation.ps1` that accepts an `-Operation` parameter (Preview, Apply, Copy, Reset, Check) and routes to the appropriate module function. Update `build_command()` in `ui/rust/src/main.rs` to call this single script. This simplifies the launch chain and makes it easier to manage operations from one entry point.
- Created `Invoke-ICloudFolderOperation.ps1` — unified entry point that imports ICloudFolders.psm1 and/or ICloudFolderCopy.psm1 based on the operation, then routes to `Invoke-ICloudFolders` (Preview/Apply/Reset), `Invoke-ICloudFolderCopy` (Copy), or `Test-ICloudFolderSetup` (Check).
- Updated `build_command()` in `ui/rust/src/main.rs` to call `Invoke-ICloudFolderOperation.ps1 -Operation <name>` instead of separate scripts.
- Rust unit tests: 2/2 passed. Fake-registry test suite: 28/28 passed (no regression).
- Updated `docs/CONTEXT.md` to document the unified script.

### ✓ Step 10: Add accent color theming and modern design to Rust UI
Added accent colors combining Windows system accent color with iCloud/OneDrive blue tones, plus modern design elements.
- Added `read_system_accent_color()` — reads Windows system accent from registry (`HKCU\SOFTWARE\Microsoft\Windows\DWM\SystemColorPrevalentAccent`), falls back to blended iCloud/OneDrive blue (#0076C8).
- Added `blend_bgr()` and `create_accent_color()` — blends 60% system accent with 40% cloud blue for a unified identity color.
- Added `accent_brush`, `accent_text_brush`, `accent_progress_brush` to `State` struct for custom painting.
- Added `WM_CTLCOLORSTATIC` handler — applies accent background with white text to the heading ("iCloud folder setup").
- Added `WM_CTLCOLORBTN` handler — applies accent background with white text to the Preview (primary) button.
- Added bold accent font for the heading via `accent_font` field in `State`.
- Set progress bar accent color via `PBM_SETBARCOLOR` message.
- Added `Win32_System_Registry` feature to Cargo.toml for accent color registry read.
- High contrast mode: accent brushes are null when high contrast is detected (currently defaults to off; Windows overrides system controls in actual high contrast).
- Rust unit tests: 4/4 passed. Hidden desktop test: passed. Fake-registry test suite: 28/28 passed.
- Updated `docs/CONTEXT.md` to document accent theming approach.

### ✓ Step 11: Optimize CPU cycles and RAM usage
Reduced wasted CPU cycles and memory allocations in the Rust UI:
- Removed `Win32_System_Diagnostics_Debug` from Cargo.toml — was listed but never used in code.
- Cached accent color in `std::sync::OnceLock<u32>` — `create_accent_color()` now reads the registry once instead of on every call (was called twice: State::create() and main() for progress bar).
- Replaced `CompareStringOrdinal` from `Win32_Globalization` with `to_lowercase()` string comparison in `ordinal()` — eliminates loading `shlwapi.dll` at runtime and avoids Vec<u16> allocation per path component comparison. Removed `Win32_Globalization` from Cargo.toml.
- Memory measurement: 27.137 MiB (unchanged — the removed features didn't load additional DLLs; core UI libraries dominate).
- Rust unit tests: 4/4 passed. Hidden desktop test: passed. Fake-registry test suite: 28/28 passed.
- Updated `docs/CONTEXT.md` to document optimization approach.

### ✓ Step 12: Fix outdated launcher .exe and update launch preference
Bug: `icloud-folder-launcher.exe` at the repo root was outdated (built at 12:49, source modified at 17:03 with the `--source` fix). Direct double-click showed a blank window because the old binary didn't pass `--source` to the UI.
- Rebuilt the launcher via `tools/Build-NativeBackend.ps1 -Project RustLauncher`.
- Copied the new .exe to the repo root.
- Updated `ICloudFolderSetup.Launch.psm1` to prefer `icloud-folder-launcher.exe` over WinUI 3. Preference chain: native launcher → manifest.json Rust package → WinUI 3 fallback.
- Hidden desktop test: passed, launcher started and UI stayed open.
- Fake-registry test suite: 28/28 passed (no regression).
- Updated `docs/CONTEXT.md` with the fix, launch preference chain, and mandatory hidden desktop testing requirement.

### ✓ Step 13: Fix launcher BOM and JSON parsing bugs
Bug: User saw blank window for 10+ seconds then "The Rust UI could not be built. Failed to parse build output: expected value at line 2 column 4". Two root causes:
1. The cache file `.local/rust-ui-build.json` was written by PowerShell with a UTF-8 BOM. The launcher's `serde_json::from_str` failed silently on the BOM-prefixed content, causing `get_cached_binary()` to return `None` even though the cached binary existed.
2. The `build_ui()` fallback JSON parser tried to parse the entire stdout (which includes Cargo compilation progress) as JSON, failing with "expected value at line 2 column 4".
- Fixed `get_cached_binary()` to strip UTF-8 BOM (`\u{feff}`) before JSON parsing.
- Rewrote `build_ui()` JSON parsing to search for lines containing `WorkerPath` and falling back to parsing from the last `{` in stdout, handling multi-line JSON output.
- Rebuilt launcher, hidden desktop test passed, 28/28 fake-registry tests passed.
- Updated `docs/CONTEXT.md` to document the BOM issue and robust JSON parsing.
