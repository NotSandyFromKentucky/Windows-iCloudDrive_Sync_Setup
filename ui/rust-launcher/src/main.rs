//! Bootstrap launcher for the iCloud folder setup Rust UI.
//! Checks for a cached binary, builds from source if needed, then launches the UI.
#![cfg(windows)]
#![cfg_attr(not(test), windows_subsystem = "windows")]

use std::path::{Path, PathBuf};
use std::process::Command;
use std::ptr::null_mut;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::System::Threading::{
    CREATE_NO_WINDOW, CreateProcessW, GetExitCodeProcess, INFINITE, PROCESS_INFORMATION,
    STARTUPINFOW, WaitForSingleObject,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{MB_ICONERROR, MB_OK, MessageBoxW};

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Find the repository root by walking up from the executable's directory.
fn find_repo_root() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let mut current = exe.parent()?.to_path_buf();
    for _ in 0..20 {
        if current.join("ICloudFolderSetup.Launch.psm1").exists() {
            return Some(current);
        }
        current = current.parent()?.to_path_buf();
    }
    None
}

/// Read the cached build info and return the worker path if valid.
fn get_cached_binary(repo: &Path) -> Option<PathBuf> {
    let cache = repo.join(".local").join("rust-ui-build.json");
    let content = std::fs::read_to_string(&cache).ok()?;
    // Strip UTF-8 BOM if present (PowerShell may write it)
    let content = content.strip_prefix('\u{feff}').unwrap_or(&content);
    let parsed: serde_json::Value = serde_json::from_str(content).ok()?;
    let worker_path = parsed.get("WorkerPath")?.as_str()?;
    let path = PathBuf::from(worker_path);
    if path.exists() { Some(path) } else { None }
}

/// Build the Rust UI by invoking the PowerShell build script.
fn build_ui(repo: &Path) -> Result<PathBuf, String> {
    let build_script = repo.join("tools").join("Build-RustUI.ps1");
    if !build_script.exists() {
        return Err("Build script not found at tools\\Build-RustUI.ps1".to_string());
    }

    // Run PowerShell build script and capture output
    let output = Command::new("powershell.exe")
        .args(&[
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            build_script.to_str().unwrap(),
        ])
        .current_dir(repo)
        .output()
        .map_err(|e| format!("Failed to start build: {}", e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("Build failed: {}", stderr.trim()));
    }

    // Parse the JSON output from the build script
    let stdout = String::from_utf8_lossy(&output.stdout);
    // The build script outputs Cargo progress mixed with JSON at the end.
    // Find the last line starting with '{' that contains WorkerPath.
    let mut last_json_error: Option<String> = None;
    for line in stdout.lines() {
        let trimmed = line.trim();
        // Strip BOM if present
        let trimmed = trimmed.strip_prefix('\u{feff}').unwrap_or(trimmed);
        if trimmed.starts_with('{') && trimmed.contains("WorkerPath") {
            match serde_json::from_str::<serde_json::Value>(trimmed) {
                Ok(parsed) => {
                    if let Some(worker_path) = parsed.get("WorkerPath").and_then(|v| v.as_str()) {
                        return Ok(PathBuf::from(worker_path));
                    }
                }
                Err(e) => {
                    last_json_error = Some(e.to_string());
                }
            }
        }
    }

    // If no single line worked, try to find a multi-line JSON object in the output
    // Look for the last '{' and try to parse from there
    if let Some(start) = stdout.rfind('{') {
        let from_last_brace = &stdout[start..];
        // Strip BOM if present
        let from_last_brace = from_last_brace
            .strip_prefix('\u{feff}')
            .unwrap_or(from_last_brace);
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(from_last_brace) {
            if let Some(worker_path) = parsed.get("WorkerPath").and_then(|v| v.as_str()) {
                return Ok(PathBuf::from(worker_path));
            }
        }
    }

    let error_msg = last_json_error
        .unwrap_or_else(|| "No JSON with WorkerPath found in build output".to_string());
    Err(format!("Failed to parse build output: {}", error_msg))
}

/// Launch the UI binary and wait for it to exit.
fn launch_ui(binary: &Path, repo: &Path) -> i32 {
    // Quote paths to handle spaces (e.g., iCloud Drive paths)
    let cmd = format!("\"{}\" --source \"{}\"", binary.display(), repo.display());
    let cmd_wide: Vec<u16> = wide(&cmd);
    unsafe {
        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;

        let mut cmd_mut: Vec<u16> = cmd_wide.clone();
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();

        let result = CreateProcessW(
            null_mut(),
            cmd_mut.as_mut_ptr(),
            null_mut(),
            null_mut(),
            0, // do not inherit handles
            CREATE_NO_WINDOW,
            null_mut(),
            null_mut(),
            &si,
            &mut pi,
        );

        if result == 0 {
            let error_code = GetLastError();
            show_error(
                "Failed to launch UI",
                &format!(
                    "CreateProcessW failed with error code: {}\nBinary: {}",
                    error_code, cmd
                ),
            );
            return -1;
        }

        WaitForSingleObject(pi.hProcess, INFINITE);
        let mut exit_code: u32 = 0;
        GetExitCodeProcess(pi.hProcess, &mut exit_code);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        exit_code as i32
    }
}

fn show_error(title: &str, message: &str) {
    unsafe {
        MessageBoxW(
            null_mut(),
            wide(message).as_ptr(),
            wide(title).as_ptr(),
            MB_OK | MB_ICONERROR,
        );
    }
}

fn main() {
    let repo = match find_repo_root() {
        Some(r) => r,
        None => {
            show_error(
                "iCloud folder setup could not start",
                "The launcher could not find the repository. Extract the complete package and try again.",
            );
            std::process::exit(1);
        }
    };

    // Try cached binary first
    let binary = match get_cached_binary(&repo) {
        Some(b) => b,
        None => {
            // Build from source
            match build_ui(&repo) {
                Ok(b) => b,
                Err(e) => {
                    show_error(
                        "iCloud folder setup could not start",
                        &format!("The Rust UI could not be built.\n\n{}", e),
                    );
                    std::process::exit(1);
                }
            }
        }
    };

    // Launch the UI and propagate its exit code
    let exit_code = launch_ui(&binary, &repo);
    std::process::exit(exit_code);
}
