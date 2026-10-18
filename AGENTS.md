# Repository guidance

- Read `README.md` and `docs/CONTEXT.md` for scope and implementation decisions.
- Keep folder mappings centralized in `Get-FolderMap` and consistent across aliases. Do not add OneDrive or unrelated profile entries.
- Preserve read-only default execution, `ShouldProcess`, exact backups, checked writes, and rollback that removes originally absent values.
- Never run live folder redirection or restore on the developer's account as a test. Use the fake-registry suite; integration testing belongs in an isolated account or VM.
- Run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-ICloudFolders.ps1` after behavioral changes. The override applies only to that process.
- Also run the Explorer launcher and diagnostic suites after changing their behavior. Real-registry tests may run only behind `tests/Assert-IsolatedEnvironment.ps1` in disposable Windows Sandbox or GitHub-hosted Windows VMs, never a developer account or self-hosted runner.
- Do not add automatic file migration, delete source content, or commit registry exports, personal backups, logs, or IDE state.
- Update the README and context when behavior changes. Document unverified Windows/iCloud integration honestly.
- Keep release inputs centralized in `VERSION` and `build/ReleaseFiles.json`. Never move a published tag, overwrite published assets, fabricate cloud-sync evidence or imply that unsigned packages have publisher authentication.
