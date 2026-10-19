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
| build/ReleaseFiles.json | Central runtime/documentation package allowlist. |
| .github/workflows/ | Windows CI matrix and gated version-tag publication. |
| .local/ | Ignored local artifacts, logs, screenshots and evidence; never package or commit. |

Runtime files stay together at the root to preserve extracted-package paths, installed shortcuts, GUI worker lookup and existing CLI entry points. Do not relocate or delete compatibility wrappers just because a graphical alternative exists.

## Local verification

Run from the repository root:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ICloudFolders.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ExplorerLauncher.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Diagnostics.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-SetupUI.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FolderCopy.ps1
~~~

Core tests replace registry access with an in-memory boundary. GUI tests use a stub child script and render the real window. Installer/copy tests use unique fixture directories and fixture shortcuts, retaining personal files and live settings. The GUI suite checks Unicode paths, confirmation, preview invalidation, copy routes, package-style installation and tampered-source rejection.

Never test real apply/reset/restore against the developer account. Real-registry integration runs only behind tests/Assert-IsolatedEnvironment.ps1 in disposable Sandbox or GitHub-hosted Windows VMs. Self-hosted runners and ordinary accounts are refused. Integration covers real writes, exact restore, ACL denial, interrupted recovery, default-path reset, API behavior and a standard Save dialog fixture. This does not replace real iCloud cloud testing.

CI runs six OS/shell local-suite jobs, three guarded integration/API jobs, then package verification. The images are Windows Server 2022, Server 2025 and Windows 11 ARM. Server coverage does not imply Apple supports iCloud on Windows Server. Read [measured evidence](VERIFICATION.md), not just the workflow definition.

## Package verification

The builder reads an exact Git commit, not uncommitted working files. After committing the intended source:

~~~powershell
$package = .\tools\New-ReleasePackage.ps1
.\tools\Test-ReleasePackage.ps1 -Archive $package.Archive
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ReleaseTools.ps1
~~~

The release-tool suite checks reproducible unsigned bytes on the same runtime, valid contents, bad checksums, traversal rejection before extraction and unavailable signing certificates. Update VERSION and build/ReleaseFiles.json together with intended release inputs. Include documentation referenced by the shipped README; exclude tests, IDE state, credentials and personal artifacts from release files.

## Publish a release

Use a new version and matching CHANGELOG.md section. Commit and verify the source, then push an immutable version tag. The release workflow runs the full CI gates before publication. The publisher matches the tag, manifest commit and version; creates or resumes a draft; uploads the ZIP/checksum; downloads and verifies both; and publishes as latest. It refuses to overwrite an already published version.

Published tags/assets, including legacy releases, are immutable. The failed v2.3.0 tag was left unchanged. Optional signing uses an existing trusted code-signing certificate and staged files only; current packages are explicitly unsigned. Signing limits are described in [verification](VERIFICATION.md).

## Local cleanup

Ignored .local artifacts include recovery-related evidence and cloud-test state as well as rebuildable downloads. Do not use broad git clean or recursive deletion without identifying the contents and checking absolute target paths. Repository cleanup must not delete source files, recovery records, IDE state or cloud-synchronized test content. The Git-tracked tree and release allowlist define distributed content; ignoring a directory does not prevent iCloud from synchronizing it.
