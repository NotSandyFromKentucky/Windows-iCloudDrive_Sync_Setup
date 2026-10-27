//! Win32 UI for iCloud folder setup. Uses the Rust worker for read-only checks when available.
#![cfg(windows)]
#![cfg_attr(not(test), windows_subsystem = "windows")]
use serde::{Deserialize, Serialize};
use std::{
    cell::RefCell,
    collections::BTreeSet,
    path::{Component, Path, PathBuf},
    ptr::null_mut,
};
use std::{
    io::{Read, Write},
    os::windows::process::CommandExt,
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    thread,
    time::Duration,
};
use windows::{
    Win32::{
        System::Com::{
            CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx,
            CoUninitialize,
        },
        UI::Accessibility::{
            CAccPropServices, HCF_HIGHCONTRASTON, HIGHCONTRASTW, HelpText_Property_GUID,
            IAccPropServices, Name_Property_GUID, PROPID_ACC_DESCRIPTION, PROPID_ACC_NAME,
        },
    },
    core::PCWSTR,
};
use windows_sys::Win32::{
    Foundation::*,
    Graphics::{Dwm::*, Gdi::*},
    System::{
        LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryW},
        Registry::*,
        SystemServices::SS_LEFT,
    },
    UI::{
        Controls::*,
        HiDpi::*,
        Input::KeyboardAndMouse::{EnableWindow, IsWindowEnabled, SetFocus},
        Shell::{SHGSI_ICON, SHGSI_SMALLICON, SHGetStockIconInfo, SHSTOCKICONINFO, SIID_FOLDER},
        WindowsAndMessaging::*,
    },
};
// Progress bar message constant (not in a separate module in windows-sys 0.61)
const PBM_SETMARQUEE: u32 = 0x40A;
const PBM_SETBKCOLOR: u32 = 0x2001;
const PBM_SETBARCOLOR: u32 = 0x409;
const DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1: u32 = 19;
type AllowDarkModeForWindow = unsafe extern "system" fn(HWND, i32) -> i32;
static ALLOW_DARK_MODE: std::sync::OnceLock<Option<AllowDarkModeForWindow>> =
    std::sync::OnceLock::new();

const MAP: &str = include_str!(env!("ICLOUD_FOLDER_MAP_PATH"));
const ROOT: usize = 100;
const MUSIC: usize = 101;
const ADVANCED: usize = 102;
const STATUS: usize = 103;
const PROGRESS_BAR: usize = 104;
const CANCEL: usize = 105;
const PREVIEW: usize = 1;
const CLOSE: usize = 2;
const APPLY: usize = 3;
const COPY: usize = 4;
const RESET: usize = 5;
const CHECK: usize = 6;
const ACTION: usize = 110;
const BACKUP: usize = 111;
const VERIFIED: usize = 112;
const KEEP: usize = 113;
const TECHNICAL: usize = 114;
const TABLE: usize = 115;
const DRY: usize = 116;
const BROWSE_ROOT: usize = 117;
const BROWSE_BACKUP: usize = 118;
const SAVE: usize = 119;
const RECOVERY: usize = 120;
const HELP: usize = 121;
const INSTALL: usize = 122;
const DESKTOP_SHORTCUT: usize = 123;
const PREVIOUS_PAGE: usize = 124;
const NEXT_PAGE: usize = 125;
const ACTIONS: [&str; 9] = [
    "Set up iCloud folders",
    "Reset to Windows defaults",
    "Restore a recovery backup",
    "Copy files into iCloud folders",
    "Copy files into Windows default folders",
    "Check iCloud configuration",
    "Create cloud test file",
    "Check cloud return",
    "Clean up cloud test file",
];
static SOURCE: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
thread_local! { static STATE: RefCell<Option<State>> = const { RefCell::new(None) }; }

#[derive(Clone, Copy, PartialEq)]
enum Operation {
    Preview,
    Apply,
    Check,
    DryRun,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "PascalCase")]
struct Options {
    action: String,
    root: String,
    backup: String,
    music: bool,
    verified: bool,
    keep_files: bool,
    json: bool,
    desktop_shortcut: bool,
    folder_paths: std::collections::BTreeMap<String, String>,
}
impl Options {
    fn mutates(&self) -> bool {
        !self.action.starts_with("Check")
    }
    fn copy(&self) -> bool {
        self.action.starts_with("Copy files")
    }
    fn label(&self) -> &'static str {
        match self.action.as_str() {
            "Reset to Windows defaults" => "Reset locations",
            "Restore a recovery backup" => "Restore locations",
            "Create cloud test file" => "Create test file",
            "Clean up cloud test file" => "Remove test file",
            "Install for me" => "Install for me",
            _ if self.copy() => "Copy files",
            _ => "Change locations",
        }
    }
    fn consequence(&self) -> &'static str {
        match self.action.as_str() {
            "Create cloud test file" => {
                "Create a small verification file in your iCloud Documents folder. Rename it on iCloud.com or another device, then use Check cloud return."
            }
            "Clean up cloud test file" => {
                "Remove only the exact verification files shown in the reviewed plan. Deletion will synchronize to iCloud and other devices."
            }
            "Install for me" => {
                "Copy the verified application package for your Windows account and add a Start menu shortcut. Folder locations will not change. Installation requires a complete package, rather than a source checkout."
            }
            _ if self.copy() => {
                "Copy the reviewed files and verify their contents. Existing files will not be overwritten. Originals and folder locations stay unchanged. Cloud files may download and destination copies may synchronize."
            }
            _ => {
                "Apply the reviewed folder locations. A fresh recovery backup will be created before changes. Existing files stay where they are. Wait for the operation to finish; folder changes cannot be interrupted."
            }
        }
    }
}
#[derive(Clone, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct WorkerResult {
    exit_code: i32,
    message: String,
    text: String,
}
enum WorkerMessage {
    Progress(serde_json::Value),
    Finished(Result<WorkerResult, String>),
}

#[derive(Deserialize)]
struct Mapping {
    relative_path: String,
    optional: bool,
}
struct Row {
    relative: String,
    optional: bool,
    label: HWND,
    icon: HWND,
    editor: HWND,
    browse: HWND,
}
struct State {
    accessibility: Accessibility,
    window: HWND,
    root: HWND,
    music: HWND,
    advanced: HWND,
    status: HWND,
    fixed: Vec<(HWND, (i32, i32, i32, i32))>,
    rows: Vec<Row>,
    preview: HWND,
    apply: HWND,
    copy: HWND,
    reset: HWND,
    check: HWND,
    close: HWND,
    cancel_btn: HWND,
    progress: HWND,
    status_label: HWND,
    font: HFONT,
    icon_font: HFONT,
    accent_font: HFONT,
    dpi: u32,
    fixture_dpi: Option<u32>,
    fixture_dark: Option<bool>,
    theme: Theme,
    background_brush: HBRUSH,
    field_brush: HBRUSH,
    is_running: bool,
    result: Option<mpsc::Receiver<WorkerMessage>>,
    action: HWND,
    backup: HWND,
    verified: HWND,
    keep: HWND,
    technical: HWND,
    table: HWND,
    table_label: HWND,
    previous_page: HWND,
    next_page: HWND,
    dry: HWND,
    browse_root: HWND,
    browse_backup: HWND,
    save: HWND,
    recovery: HWND,
    help: HWND,
    install: HWND,
    desktop_shortcut: HWND,
    reviewed: Option<Options>,
    review_token: Option<String>,
    copy_reviewed: Option<Options>,
    copy_review_token: Option<String>,
    copy_page_expected_token: Option<String>,
    copy_page_offsets: Vec<usize>,
    copy_page_next_offset: Option<usize>,
    running_options: Option<Options>,
    running_phase: String,
    raw: String,
    friendly: String,
    table_ready: bool,
    app_icons: Vec<HICON>,
    stop: Arc<AtomicBool>,
    // Accent theming
    accent_brush: HBRUSH,
    accent_text_brush: HBRUSH,
    accent_progress_brush: HBRUSH,
    heading: HWND,
}
struct Apartment;
impl Apartment {
    fn new() -> Result<Self, String> {
        unsafe {
            CoInitializeEx(None, COINIT_APARTMENTTHREADED)
                .ok()
                .map_err(|e| e.to_string())?;
        }
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            CoUninitialize();
        }
    }
}
struct Accessibility {
    service: IAccPropServices,
    windows: Vec<HWND>,
}
impl Accessibility {
    fn new() -> Result<Self, String> {
        let service = unsafe { CoCreateInstance(&CAccPropServices, None, CLSCTX_INPROC_SERVER) }
            .map_err(|e| e.to_string())?;
        Ok(Self {
            service,
            windows: Vec::new(),
        })
    }
    fn label(&mut self, window: HWND, name: &str, description: &str) -> Result<(), String> {
        let hwnd = windows::Win32::Foundation::HWND(window);
        // OBJID_CLIENT / CHILDID_SELF: annotate native controls without replacing their providers.
        self.windows.push(window);
        for (property, value) in [
            (PROPID_ACC_NAME, name),
            (Name_Property_GUID, name),
            (PROPID_ACC_DESCRIPTION, description),
            (HelpText_Property_GUID, description),
        ] {
            unsafe {
                self.service.SetHwndPropStr(
                    hwnd,
                    (-4i32) as u32,
                    0,
                    property,
                    PCWSTR(wide(value).as_ptr()),
                )
            }
            .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
    fn clear(&mut self) {
        for window in self.windows.drain(..) {
            let _ = unsafe {
                self.service.ClearHwndProps(
                    windows::Win32::Foundation::HWND(window),
                    (-4i32) as u32,
                    0,
                    &[
                        PROPID_ACC_NAME,
                        Name_Property_GUID,
                        HelpText_Property_GUID,
                        PROPID_ACC_DESCRIPTION,
                    ],
                )
            };
        }
    }
}
impl Drop for Accessibility {
    fn drop(&mut self) {
        self.clear();
    }
}
impl Drop for State {
    fn drop(&mut self) {
        // SAFETY: controls are destroyed before WM_NCDESTROY releases these owned GDI objects.
        unsafe {
            DeleteObject(self.font);
            DeleteObject(self.icon_font);
            DeleteObject(self.accent_font);
            DeleteObject(self.background_brush);
            DeleteObject(self.field_brush);
            DeleteObject(self.accent_brush);
            DeleteObject(self.accent_text_brush);
            DeleteObject(self.accent_progress_brush);
            for icon in self.app_icons.drain(..) {
                DestroyIcon(icon);
            }
        }
    }
}
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}
fn scaled(value: i32, dpi: u32) -> i32 {
    (value * dpi as i32 + 48) / 96
}

fn read_registry_dword(path: &str, name: &str) -> Option<u32> {
    unsafe {
        let key_path = wide(path);
        let value_name = wide(name);
        let mut key: HKEY = null_mut();
        if RegOpenKeyExW(HKEY_CURRENT_USER, key_path.as_ptr(), 0, KEY_READ, &mut key) != 0 {
            return None;
        }
        let mut dtype: u32 = 0;
        let mut size: u32 = std::mem::size_of::<u32>() as u32;
        let mut value: u32 = 0;
        let result = RegQueryValueExW(
            key,
            value_name.as_ptr(),
            null_mut(),
            &mut dtype,
            &mut value as *mut u32 as *mut u8,
            &mut size,
        );
        RegCloseKey(key);
        (result == 0 && size == 4 && dtype == REG_DWORD).then_some(value)
    }
}

#[derive(Clone, Copy)]
struct Theme {
    dark: bool,
    background: u32,
    text: u32,
    field: u32,
    field_text: u32,
    disabled: u32,
}

impl Theme {
    fn current(fixture_dark: Option<bool>) -> Self {
        let high_contrast = is_high_contrast();
        let dark = !high_contrast
            && fixture_dark.unwrap_or_else(|| {
                !read_registry_dword(
                    "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                    "AppsUseLightTheme",
                )
                .map(|value| value != 0)
                .unwrap_or(true)
            });
        if dark {
            Self {
                dark,
                background: 0x202020,
                text: 0xF0F0F0,
                field: 0x2B2B2B,
                field_text: 0xFFFFFF,
                disabled: 0x808080,
            }
        } else {
            unsafe {
                Self {
                    dark,
                    background: GetSysColor(COLOR_BTNFACE),
                    text: GetSysColor(COLOR_BTNTEXT),
                    field: GetSysColor(COLOR_WINDOW),
                    field_text: GetSysColor(COLOR_WINDOWTEXT),
                    disabled: GetSysColor(COLOR_GRAYTEXT),
                }
            }
        }
    }
}

/// Read the Windows system accent color from the registry.
/// Returns BGR(u32) or falls back to a blended iCloud/OneDrive blue.
fn read_system_accent_color() -> u32 {
    // iCloud blue: #007AFF (R=0, G=122, B=255)
    // OneDrive blue: #0078D4 (R=0, G=120, B=212)
    // Blended fallback: #0076C8 (R=0, G=118, B=200)
    let fallback = 0xC87600u32; // BGR format: B=0xC8, G=0x76, R=0x00
    for (path, name) in [
        (
            "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent",
            "AccentColorMenu",
        ),
        (
            "SOFTWARE\\Microsoft\\Windows\\DWM",
            "SystemColorPrevalentAccent",
        ),
    ] {
        if let Some(value) = read_registry_dword(path, name) {
            return value & 0xFFFFFF;
        }
    }
    if let Some(value) =
        read_registry_dword("SOFTWARE\\Microsoft\\Windows\\DWM", "ColorizationColor")
    {
        let rgb = value & 0xFFFFFF;
        return ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF);
    }
    fallback
}

/// Blend two BGR colors by the given weight (0-255, weight for color1).
fn blend_bgr(c1: u32, c2: u32, w: u32) -> u32 {
    let w2 = 255 - w;
    let r = (((c1 & 0xFF) * w + (c2 & 0xFF) * w2) / 255) & 0xFF;
    let g = ((((c1 >> 8) & 0xFF) * w + ((c2 >> 8) & 0xFF) * w2) / 255) & 0xFF;
    let b = ((((c1 >> 16) & 0xFF) * w + ((c2 >> 16) & 0xFF) * w2) / 255) & 0xFF;
    r | (g << 8) | (b << 16)
}

/// Cached accent color to avoid repeated registry reads.
static ACCENT_COLOR: std::sync::OnceLock<u32> = std::sync::OnceLock::new();

/// Create the blended accent color: 60% system accent, 40% iCloud/OneDrive blue blend.
/// Cached after first call to avoid repeated registry reads.
fn create_accent_color() -> u32 {
    *ACCENT_COLOR.get_or_init(|| {
        let system = read_system_accent_color();
        // iCloud/OneDrive blended blue in BGR: #0076C8 -> BGR: 0xC87600
        let cloud_blue = 0xC87600u32;
        blend_bgr(system, cloud_blue, 153) // 153/255 ≈ 60%
    })
}

fn is_high_contrast() -> bool {
    unsafe {
        let mut settings: HIGHCONTRASTW = std::mem::zeroed();
        settings.cbSize = std::mem::size_of::<HIGHCONTRASTW>() as u32;
        SystemParametersInfoW(
            SPI_GETHIGHCONTRAST,
            settings.cbSize,
            (&mut settings as *mut HIGHCONTRASTW).cast(),
            0,
        ) != 0
            && settings.dwFlags.0 & HCF_HIGHCONTRASTON.0 != 0
    }
}

fn initialize_theme_support() {
    unsafe {
        let module = LoadLibraryW(wide("uxtheme.dll").as_ptr());
        if module.is_null() {
            let _ = ALLOW_DARK_MODE.set(None);
            return;
        }
        if let Some(proc) = GetProcAddress(module, 135 as *const u8) {
            let set_preferred_app_mode: unsafe extern "system" fn(i32) -> i32 =
                std::mem::transmute(proc);
            set_preferred_app_mode(1);
        }
        let allow = GetProcAddress(module, 133 as *const u8)
            .map(|proc| std::mem::transmute::<_, AllowDarkModeForWindow>(proc));
        let _ = ALLOW_DARK_MODE.set(allow);
    }
}

fn allow_dark_mode(window: HWND, enable: bool) {
    if let Some(Some(function)) = ALLOW_DARK_MODE.get() {
        unsafe {
            function(window, enable as i32);
        }
    }
}

fn definitions() -> Result<Vec<Mapping>, String> {
    let all: Vec<Mapping> = serde_json::from_str(MAP).map_err(|e| e.to_string())?;
    let mut seen = BTreeSet::new();
    Ok(all
        .into_iter()
        .filter(|m| seen.insert(m.relative_path.clone()))
        .collect())
}
fn glyph(relative: &str) -> &'static str {
    match relative {
        "Desktop" => "\u{e7f4}",
        "Documents" => "\u{e8a5}",
        "Pictures" => "\u{e8b9}",
        "Videos" => "\u{e714}",
        "Downloads" => "\u{e896}",
        "Videos\\Captures" => "\u{e722}",
        "Music" => "\u{e8d6}",
        _ => "\u{e8b7}",
    }
}
unsafe fn control(
    parent: HWND,
    class: &str,
    title: &str,
    style: u32,
    id: usize,
) -> Result<HWND, String> {
    // SAFETY: owned NUL-terminated strings live through this synchronous call.
    let window = unsafe {
        CreateWindowExW(
            0,
            wide(class).as_ptr(),
            wide(title).as_ptr(),
            WS_CHILD
                | WS_VISIBLE
                | style
                | if class == "BUTTON" {
                    BS_NOTIFY as u32
                } else {
                    0
                },
            0,
            0,
            0,
            0,
            parent,
            id as HMENU,
            GetModuleHandleW(null_mut()),
            null_mut(),
        )
    };
    if window.is_null() {
        Err("Windows could not create a native control.".into())
    } else {
        Ok(window)
    }
}
fn text(window: HWND) -> String {
    // SAFETY: handles are live controls on this thread; buffer includes the terminator.
    unsafe {
        let count = GetWindowTextLengthW(window).clamp(0, 32000);
        let mut buffer = vec![0u16; count as usize + 1];
        let copied = GetWindowTextW(window, buffer.as_mut_ptr(), buffer.len() as i32);
        String::from_utf16_lossy(&buffer[..copied as usize])
    }
}
fn set_text(window: HWND, value: &str) {
    // SAFETY: text lives through the synchronous call; reentrant notifications are ignored while state is borrowed.
    unsafe {
        SetWindowTextW(window, wide(value).as_ptr());
    }
}
fn checked(window: HWND) -> bool {
    unsafe { SendMessageW(window, BM_GETCHECK, 0, 0) == BST_CHECKED as isize }
}
fn enable(window: HWND, enabled: bool) {
    unsafe {
        EnableWindow(window, i32::from(enabled));
    }
}
fn place(window: HWND, x: i32, y: i32, width: i32, height: i32, dpi: u32) {
    unsafe {
        MoveWindow(
            window,
            scaled(x, dpi),
            scaled(y, dpi),
            scaled(width.max(1), dpi),
            scaled(height.max(1), dpi),
            1,
        );
    }
}

const OUTPUT_LIMIT: usize = 2 * 1024 * 1024;
const OUTPUT_TAIL_LIMIT: usize = 32 * 1024;
const OVERFLOW_DIAGNOSTIC_LIMIT: usize = 24 * 1024;

#[derive(Default)]
struct BoundedOutput {
    prefix: Vec<u8>,
    suffix: Vec<u8>,
    total_bytes: u64,
}

impl BoundedOutput {
    fn push(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.total_bytes = self.total_bytes.saturating_add(bytes.len() as u64);
        let prefix_limit = OUTPUT_LIMIT - OUTPUT_TAIL_LIMIT;
        let keep = bytes
            .len()
            .min(prefix_limit.saturating_sub(self.prefix.len()));
        self.prefix.extend_from_slice(&bytes[..keep]);

        if bytes.len() >= OUTPUT_TAIL_LIMIT {
            self.suffix.clear();
            self.suffix
                .extend_from_slice(&bytes[bytes.len() - OUTPUT_TAIL_LIMIT..]);
        } else {
            let remove = self
                .suffix
                .len()
                .saturating_add(bytes.len())
                .saturating_sub(OUTPUT_TAIL_LIMIT);
            if remove > 0 {
                drop(self.suffix.drain(..remove));
            }
            self.suffix.extend_from_slice(bytes);
        }
    }

    fn is_empty(&self) -> bool {
        self.total_bytes == 0
    }

    fn exceeded_limit(&self) -> bool {
        self.total_bytes > OUTPUT_LIMIT as u64
    }

    fn as_bytes(&self) -> Vec<u8> {
        let overlap = self
            .prefix
            .len()
            .saturating_add(self.suffix.len())
            .saturating_sub(self.total_bytes.min(usize::MAX as u64) as usize);
        let mut bytes = Vec::with_capacity(self.prefix.len() + self.suffix.len());
        bytes.extend_from_slice(&self.prefix);
        bytes.extend_from_slice(&self.suffix[overlap.min(self.suffix.len())..]);
        bytes
    }

    fn summary(&self, maximum_bytes: usize) -> String {
        if self.total_bytes <= maximum_bytes as u64 && !self.exceeded_limit() {
            let mut summary = String::from_utf8_lossy(&self.as_bytes()).into_owned();
            let mut end = maximum_bytes.min(summary.len());
            while !summary.is_char_boundary(end) {
                end -= 1;
            }
            summary.truncate(end);
            return summary;
        }
        let marker = format!(
            "\n[Output bounded; {} bytes observed. Middle content may be omitted.]\n",
            self.total_bytes
        );
        let room = maximum_bytes.saturating_sub(marker.len());
        let head = room.min(self.prefix.len()).min(room / 2);
        let tail = room.saturating_sub(head).min(self.suffix.len());
        let start = self.suffix.len().saturating_sub(tail);
        let mut summary = format!(
            "{}{}{}",
            String::from_utf8_lossy(&self.prefix[..head]),
            marker,
            String::from_utf8_lossy(&self.suffix[start..])
        );
        let mut end = maximum_bytes.min(summary.len());
        while !summary.is_char_boundary(end) {
            end -= 1;
        }
        summary.truncate(end);
        summary
    }
}

fn overflow_diagnostic(output: &BoundedOutput, errors: &BoundedOutput) -> String {
    let stdout_budget = 14 * 1024;
    let stderr_budget = 8 * 1024;
    let mut message = String::from(
        "The operation exceeded the 2 MiB output limit. It has finished; inspect the retained recovery records before retrying changes.",
    );
    if !output.is_empty() {
        message.push_str(&format!(
            "\n\nStandard output ({} bytes):\n{}",
            output.total_bytes,
            output.summary(stdout_budget)
        ));
    }
    if !errors.is_empty() {
        message.push_str(&format!(
            "\n\nStandard error ({} bytes):\n{}",
            errors.total_bytes,
            errors.summary(stderr_budget)
        ));
    }
    let mut message_end = OVERFLOW_DIAGNOSTIC_LIMIT.min(message.len());
    while !message.is_char_boundary(message_end) {
        message_end -= 1;
    }
    message.truncate(message_end);
    message
}

fn base64(bytes: &[u8]) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for b in bytes.chunks(3) {
        let n = ((b[0] as u32) << 16)
            | ((b.get(1).copied().unwrap_or(0) as u32) << 8)
            | b.get(2).copied().unwrap_or(0) as u32;
        out.push(CHARS[(n >> 18) as usize] as char);
        out.push(CHARS[((n >> 12) & 63) as usize] as char);
        out.push(if b.len() > 1 {
            CHARS[((n >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if b.len() > 2 {
            CHARS[(n & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}

fn request(options: &Options, phase: &str, cancel: Option<&str>) -> Result<String, String> {
    if !matches!(phase, "Preview" | "DryRun" | "Apply") {
        return Err("Unsupported operation phase.".into());
    }
    if !ACTIONS.contains(&options.action.as_str()) && options.action != "Install for me" {
        return Err("Choose a supported action.".into());
    }
    let mut value = serde_json::to_value(options).map_err(|e| e.to_string())?;
    value["Phase"] = phase.into();
    if let Some(name) = cancel {
        value["CancelEventName"] = name.into();
    }
    let bytes = serde_json::to_vec(&value).map_err(|e| e.to_string())?;
    if bytes.len() > 16000 {
        return Err("The request exceeds 16,000 bytes. Shorten the paths and retry.".into());
    }
    Ok(base64(&bytes))
}
fn drain(mut input: impl Read) -> Result<(BoundedOutput, bool), String> {
    let mut output = BoundedOutput::default();
    let mut buffer = [0u8; 8192];
    loop {
        let n = input.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        output.push(&buffer[..n]);
    }
    let overflow = output.exceeded_limit();
    Ok((output, overflow))
}

fn retain_output_line(
    line: &BoundedOutput,
    output: &mut BoundedOutput,
    sender: &mpsc::SyncSender<WorkerMessage>,
) -> bool {
    let bytes = line.as_bytes();
    if line.prefix.starts_with(b"@@ICloudProgress:") {
        if !line.exceeded_limit() {
            if let Ok(value) = serde_json::from_slice(&bytes[17..]) {
                let _ = sender.try_send(WorkerMessage::Progress(value));
            }
        }
        return line.exceeded_limit();
    }
    output.push(&bytes);
    output.push(b"\n");
    line.exceeded_limit() || output.exceeded_limit()
}

fn native_records(
    request: serde_json::Value,
    worker: &Path,
    source: &Path,
    stop: &AtomicBool,
    allow_write: bool,
    progress_sender: Option<&mpsc::SyncSender<WorkerMessage>>,
    cancellation: Option<&CancelEvent>,
) -> Result<Option<Vec<serde_json::Value>>, String> {
    if !worker.is_file() {
        return Err("The Rust backend worker is missing. Rebuild the development package.".into());
    }
    let bytes = serde_json::to_vec(&request).map_err(|error| error.to_string())?;
    if bytes.len() > 65536 {
        return Err("The Rust request exceeds 64 KiB. Shorten the paths and retry.".into());
    }
    let mut child = Command::new(worker)
        .current_dir(source)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(0x08000000)
        .spawn()
        .map_err(|error| format!("Could not start the Rust backend: {error}"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or("Missing native standard output.")?;
    let stderr = child
        .stderr
        .take()
        .ok_or("Missing native standard error.")?;
    let progress = progress_sender
        .cloned()
        .unwrap_or_else(|| mpsc::sync_channel(1).0);
    let out = thread::spawn(move || read_output(stdout, progress));
    let err = thread::spawn(move || drain(stderr));
    let mut input = child.stdin.take().ok_or("Missing native standard input.")?;
    input
        .write_all(&bytes)
        .map_err(|error| format!("Could not send the check request: {error}"))?;
    drop(input);

    let started = std::time::Instant::now();
    let mut killed = false;
    let mut signalled = false;
    let exit = loop {
        if !allow_write && stop.load(Ordering::Relaxed) && !killed {
            let _ = child.kill();
            killed = true;
        }
        if allow_write && stop.load(Ordering::Relaxed) && !signalled {
            signalled = true;
            if let Some(cancellation) = cancellation {
                cancellation.signal();
            }
        }
        if !allow_write && !killed && started.elapsed() > Duration::from_secs(120) {
            let _ = child.kill();
            killed = true;
        }
        if let Some(status) = child.try_wait().map_err(|error| error.to_string())? {
            break status;
        }
        thread::sleep(Duration::from_millis(25));
    };
    let (output, overflow) = out.join().map_err(|_| "Native output reader failed.")??;
    let (errors, error_overflow) = err.join().map_err(|_| "Native error reader failed.")??;
    if killed {
        return Ok(None);
    }
    if overflow || error_overflow {
        return Err(overflow_diagnostic(&output, &errors));
    }
    if !errors.is_empty() {
        return Err(format!(
            "The Rust backend wrote unexpected diagnostic output: {}",
            errors.summary(OVERFLOW_DIAGNOSTIC_LIMIT)
        ));
    }
    let output = String::from_utf8(output.as_bytes())
        .map_err(|_| "The Rust backend returned invalid UTF-8.")?;
    let records: Vec<serde_json::Value> = output
        .lines()
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_str(line).map_err(|error| error.to_string()))
        .collect::<std::result::Result<Vec<_>, String>>()?;
    let terminal: Vec<_> = records
        .iter()
        .filter(|record| record["type"] == "result")
        .collect();
    if terminal.len() != 1 || records.last() != terminal.first().copied() {
        return Err("The Rust backend ended without one final result record.".into());
    }
    let terminal = terminal[0];
    if terminal["version"] != 1 {
        return Err("The Rust backend returned an unsupported result version.".into());
    }
    if terminal["read_only"] != !allow_write {
        return Err("The Rust backend returned an inconsistent operation safety state.".into());
    }
    let exit_code = exit.code().unwrap_or(-1);
    if terminal["ok"] != true {
        if exit_code == 0 {
            return Err("The Rust backend reported failure with a successful exit status.".into());
        }
        return Err(terminal["message"]
            .as_str()
            .unwrap_or("The Rust backend could not complete this operation.")
            .to_owned());
    }
    if exit_code != 0 {
        return Err("The Rust backend returned inconsistent success and exit status.".into());
    }
    Ok(Some(records))
}

fn native_check(
    options: &Options,
    worker: &Path,
    source: &Path,
    stop: &AtomicBool,
) -> Result<WorkerResult, String> {
    let request = serde_json::json!({
        "version": 1,
        "operation": "check",
        "root": options.root,
        "include_music": options.music,
        "folder_paths": options.folder_paths,
    });
    let Some(records) = native_records(request, worker, source, stop, false, None, None)? else {
        return Ok(WorkerResult {
            exit_code: 3,
            message: "Read-only check stopped. No folder settings or files were changed.".into(),
            text: String::new(),
        });
    };
    let reports: Vec<_> = records
        .iter()
        .filter(|record| record["type"] == "check")
        .collect();
    if reports.len() != 1 {
        return Err("The Rust backend returned no unique configuration report.".into());
    }
    let report = &reports[0]["check"];
    let registry_values = report["registry_values"]
        .as_array()
        .ok_or("The Rust configuration report omitted registry values.")?
        .iter()
        .map(|row| {
            serde_json::json!({
                "Folder": row["folder"],
                "Current": row["current"],
                "Matches": row["matches"],
                "DirectoryExists": row["directory_exists"],
            })
        })
        .collect::<Vec<_>>();
    let resolved_folders = report["resolved_folders"]
        .as_array()
        .ok_or("The Rust configuration report omitted Windows folder paths.")?
        .iter()
        .map(|row| {
            serde_json::json!({
                "Folder": row["folder"],
                "Current": row["current"],
                "Matches": row["matches"],
            })
        })
        .collect::<Vec<_>>();
    let report = serde_json::json!({
        "Root": report["root"],
        "RootRegistered": report["root_registered"],
        "RootExists": report["root_exists"],
        "Healthy": report["healthy"],
        "CloudSync": report["cloud_sync"],
        "Errors": report["errors"],
        "RegistryValues": registry_values,
        "ResolvedFolders": resolved_folders,
    });
    Ok(WorkerResult {
        exit_code: 0,
        message: if report["Healthy"] == true {
            "iCloud folder configuration checks passed.".into()
        } else {
            "Review the iCloud folder configuration details.".into()
        },
        text: serde_json::to_string(&report).map_err(|error| error.to_string())?,
    })
}

fn native_setup_preview(
    options: &Options,
    worker: &Path,
    source: &Path,
    stop: &AtomicBool,
) -> Result<WorkerResult, String> {
    let request = setup_preview_request(options);
    let Some(records) = native_records(request, worker, source, stop, false, None, None)? else {
        return Ok(WorkerResult {
            exit_code: 3,
            message: "Read-only preview stopped. No folder settings or files were changed.".into(),
            text: String::new(),
        });
    };
    let previews: Vec<_> = records
        .iter()
        .filter(|record| record["type"] == "folder_preview")
        .collect();
    if previews.len() != 1 {
        return Err("The Rust backend returned no unique setup preview.".into());
    }
    let token = previews[0]["approval_token"]
        .as_str()
        .filter(|value| value.len() == 64)
        .ok_or("The Rust setup preview omitted its review token.")?;
    setup_preview_result(&previews[0]["preview"], token)
}

fn native_restore_preview(
    options: &Options,
    worker: &Path,
    source: &Path,
    stop: &AtomicBool,
) -> Result<WorkerResult, String> {
    let request = restore_preview_request(options)?;
    let Some(records) = native_records(request, worker, source, stop, false, None, None)? else {
        return Ok(WorkerResult {
            exit_code: 3,
            message: "Read-only preview stopped. No folder settings or files were changed.".into(),
            text: String::new(),
        });
    };
    let previews: Vec<_> = records
        .iter()
        .filter(|record| record["type"] == "restore_preview")
        .collect();
    if previews.len() != 1 {
        return Err("The Rust backend returned no unique recovery preview.".into());
    }
    let token = previews[0]["approval_token"]
        .as_str()
        .filter(|value| value.len() == 64)
        .ok_or("The Rust recovery preview omitted its review token.")?;
    restore_preview_result(&previews[0]["preview"], &options.backup, token)
}

fn copy_preview_request(options: &Options, page_offset: usize) -> serde_json::Value {
    let reset_to_defaults = options.action == ACTIONS[4];
    serde_json::json!({
        "version": 1,
        "operation": "copy_preview_page",
        "root": options.root,
        "reset_to_defaults": reset_to_defaults,
        "include_music": options.music || reset_to_defaults,
        "verified_sync_root": options.verified,
        "folder_paths": if reset_to_defaults { serde_json::json!({}) } else { serde_json::to_value(&options.folder_paths).unwrap_or_default() },
        "page_offset": page_offset,
    })
}

fn copy_preview_result(preview: &serde_json::Value, token: &str) -> Result<WorkerResult, String> {
    let entries = preview["entries"]
        .as_array()
        .ok_or("The Rust copy preview page omitted its entries.")?;
    let page_offset = preview["page_offset"]
        .as_u64()
        .ok_or("The Rust copy preview page omitted its starting row.")?;
    let total_entries = preview["total_entries"]
        .as_u64()
        .ok_or("The Rust copy preview page omitted its total row count.")?;
    let next_offset = match &preview["next_offset"] {
        serde_json::Value::Null => None,
        value => Some(
            value
                .as_u64()
                .ok_or("The Rust copy preview page returned an invalid next-row offset.")?,
        ),
    };
    let expected_next = page_offset.saturating_add(entries.len() as u64);
    if page_offset > total_entries
        || expected_next > total_entries
        || next_offset.is_some_and(|next| next != expected_next || next >= total_entries)
        || (expected_next < total_entries && next_offset.is_none())
    {
        return Err("The Rust copy preview page has inconsistent row bounds.".into());
    }
    let rows: Vec<_> = entries
        .iter()
        .map(|entry| {
            serde_json::json!({
                "Type": if entry["directory"] == true { "Folder" } else { "File" },
                "Source": entry["source"],
                "Destination": entry["destination"],
                "Action": entry["action"],
            })
        })
        .collect();
    let passed = preview["review_gates_passed"] == true;
    let report = serde_json::json!({
        "Operation": preview["operation"],
        "Root": preview["root"],
        "RootRegistered": preview["root_registered"],
        "RegisteredRoots": preview["registered_roots"],
        "ReviewGatesPassed": passed,
        "ResetToDefaults": preview["reset_to_defaults"],
        "ApprovalToken": token,
        "PageOffset": page_offset,
        "NextOffset": next_offset,
        "TotalEntries": total_entries,
        "Rows": rows,
    });
    Ok(WorkerResult {
        exit_code: if passed { 0 } else { 3 },
        message: if passed {
            "File-copy preview is ready. No files or folders have changed.".into()
        } else {
            "Review the iCloud registration acknowledgement before copying.".into()
        },
        text: serde_json::to_string(&report).map_err(|error| error.to_string())?,
    })
}

fn copy_apply_request(
    options: &Options,
    preview_token: &str,
    cancellation_event: &str,
) -> serde_json::Value {
    let reset_to_defaults = options.action == ACTIONS[4];
    serde_json::json!({
        "version": 1,
        "operation": "copy_apply",
        "root": options.root,
        "reset_to_defaults": reset_to_defaults,
        "include_music": options.music || reset_to_defaults,
        "verified_sync_root": options.verified,
        "folder_paths": if reset_to_defaults { serde_json::json!({}) } else { serde_json::to_value(&options.folder_paths).unwrap_or_default() },
        "confirmed": true,
        "preview_token": preview_token,
        "cancellation_event": cancellation_event,
    })
}

fn native_copy_preview(
    options: &Options,
    worker: &Path,
    source: &Path,
    page_offset: usize,
    stop: &AtomicBool,
    sender: &mpsc::SyncSender<WorkerMessage>,
) -> Result<WorkerResult, String> {
    let Some(records) = native_records(
        copy_preview_request(options, page_offset),
        worker,
        source,
        stop,
        false,
        Some(sender),
        None,
    )?
    else {
        return Ok(WorkerResult {
            exit_code: 3,
            message:
                "Read-only copy preview stopped. No destination files or folders were written."
                    .into(),
            text: String::new(),
        });
    };
    let previews: Vec<_> = records
        .iter()
        .filter(|record| record["type"] == "copy_preview_page")
        .collect();
    if previews.len() != 1 {
        return Err("The Rust backend returned no unique file-copy preview page.".into());
    }
    let preview = &previews[0]["preview"];
    let token = previews[0]["approval_token"]
        .as_str()
        .filter(|value| value.len() == 64)
        .ok_or("The Rust copy preview omitted its review token.")?;
    copy_preview_result(preview, token)
}

fn native_copy_apply(
    options: &Options,
    worker: &Path,
    source: &Path,
    token: &str,
    cancellation: &CancelEvent,
    stop: &AtomicBool,
    sender: &mpsc::SyncSender<WorkerMessage>,
) -> Result<WorkerResult, String> {
    let Some(records) = native_records(
        copy_apply_request(options, token, &cancellation.name),
        worker,
        source,
        stop,
        true,
        Some(sender),
        Some(cancellation),
    )?
    else {
        return Err("The file-copy worker stopped without a result. Inspect completed destination files before retrying.".into());
    };
    let results: Vec<_> = records
        .iter()
        .filter(|record| record["type"] == "copy_apply")
        .collect();
    if results.len() != 1 {
        return Err("The Rust backend returned no unique file-copy result.".into());
    }
    let result = results[0];
    let cancelled = result["cancelled"] == true;
    let preflight_cancelled = result["preflight_cancelled"] == true;
    let copied = result["copied"].as_u64().unwrap_or(0);
    let completed = result["completed"].as_u64().unwrap_or(0);
    let total = result["total"].as_u64().unwrap_or(0);
    let report = serde_json::json!({"Copied":copied,"Completed":completed,"Total":total,"Cancelled":cancelled,"PreflightCancelled":preflight_cancelled});
    Ok(WorkerResult {
        exit_code: if cancelled { 3 } else { 0 },
        message: if cancelled {
            if preflight_cancelled {
                "Copy review stopped before any destination files were changed. Originals and folder settings are unchanged.".into()
            } else {
                "Copy stopped at a safe file boundary. Originals and folder settings are unchanged; completed destination files are retained.".into()
            }
        } else {
            format!(
                "Copy verified. New files copied: {copied}. Originals retained; folder settings unchanged."
            )
        },
        text: serde_json::to_string(&report).map_err(|error| error.to_string())?,
    })
}

fn native_reset_preview(
    options: &Options,
    worker: &Path,
    source: &Path,
    stop: &AtomicBool,
) -> Result<WorkerResult, String> {
    let request = reset_preview_request(options);
    let Some(records) = native_records(request, worker, source, stop, false, None, None)? else {
        return Ok(WorkerResult {
            exit_code: 3,
            message: "Read-only preview stopped. No folder settings or files were changed.".into(),
            text: String::new(),
        });
    };
    let previews: Vec<_> = records
        .iter()
        .filter(|record| record["type"] == "folder_preview")
        .collect();
    if previews.len() != 1 {
        return Err("The Rust backend returned no unique reset preview.".into());
    }
    let token = previews[0]["approval_token"]
        .as_str()
        .filter(|value| value.len() == 64)
        .ok_or("The Rust reset preview omitted its review token.")?;
    reset_preview_result(&previews[0]["preview"], token)
}

fn native_apply(
    options: &Options,
    worker: &Path,
    source: &Path,
    approval_token: Option<&str>,
    stop: &AtomicBool,
) -> Result<WorkerResult, String> {
    let token = approval_token
        .filter(|token| token.len() == 64 && token.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or("The current review token is missing. Preview again before applying.")?;
    let request = match options.action.as_str() {
        "Set up iCloud folders" => setup_apply_request(options, token),
        "Reset to Windows defaults" => reset_apply_request(options, token),
        "Restore a recovery backup" => restore_apply_request(options, token)?,
        _ => return Err("This Rust operation does not have a native Apply route.".into()),
    };
    let Some(records) = native_records(request, worker, source, stop, true, None, None)? else {
        return Err("The settings operation did not return a result. Inspect the recovery folder before retrying.".into());
    };
    let applied: Vec<_> = records
        .iter()
        .filter(|record| record["type"] == "settings_apply")
        .collect();
    if applied.len() != 1 || applied[0]["recovery_backup"].as_str().is_none() {
        return Err("The Rust backend returned no unique verified settings result.".into());
    }
    let report = serde_json::json!({
        "Operation": applied[0]["operation"],
        "RecoveryBackup": applied[0]["recovery_backup"],
    });
    Ok(WorkerResult {
        exit_code: 0,
        message: "Folder settings were applied and verified. Sign out and back in before checking Explorer and applications.".into(),
        text: serde_json::to_string(&report).map_err(|error| error.to_string())?,
    })
}

fn setup_preview_request(options: &Options) -> serde_json::Value {
    serde_json::json!({
        "version": 1,
        "operation": "setup_preview",
        "root": options.root,
        "include_music": options.music,
        "allow_existing_content": options.keep_files,
        "verified_sync_root": options.verified,
        "folder_paths": options.folder_paths,
    })
}

fn setup_apply_request(options: &Options, preview_token: &str) -> serde_json::Value {
    serde_json::json!({
        "version": 1,
        "operation": "setup_apply",
        "root": options.root,
        "include_music": options.music,
        "allow_existing_content": options.keep_files,
        "verified_sync_root": options.verified,
        "folder_paths": options.folder_paths,
        "confirmed": true,
        "preview_token": preview_token,
    })
}

fn reset_preview_request(options: &Options) -> serde_json::Value {
    serde_json::json!({
        "version": 1,
        "operation": "reset_preview",
        "allow_existing_content": options.keep_files,
    })
}

fn reset_apply_request(options: &Options, preview_token: &str) -> serde_json::Value {
    serde_json::json!({
        "version": 1,
        "operation": "reset_apply",
        "allow_existing_content": options.keep_files,
        "confirmed": true,
        "preview_token": preview_token,
    })
}

fn restore_preview_request(options: &Options) -> Result<serde_json::Value, String> {
    if options.backup.trim().is_empty() {
        return Err("Choose a recovery backup file before running the restore preview.".into());
    }
    Ok(serde_json::json!({
        "version": 1,
        "operation": "restore_preview_file",
        "path": options.backup,
    }))
}

fn restore_apply_request(
    options: &Options,
    preview_token: &str,
) -> Result<serde_json::Value, String> {
    if options.backup.trim().is_empty() {
        return Err("Choose a recovery backup file before applying the restore.".into());
    }
    Ok(serde_json::json!({
        "version": 1,
        "operation": "restore_apply",
        "path": options.backup,
        "confirmed": true,
        "preview_token": preview_token,
    }))
}

fn setup_preview_result(
    preview: &serde_json::Value,
    approval_token: &str,
) -> Result<WorkerResult, String> {
    let root = preview["root"]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or("The Rust setup preview omitted the selected root.")?;
    let recovery_root = preview["recovery_root"]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or("The Rust setup preview omitted the recovery folder.")?;
    let root_registered = &preview["root_registered"];
    if !(root_registered.is_null() || root_registered.is_boolean()) {
        return Err("The Rust setup preview returned an invalid root-registration state.".into());
    }
    let verified_sync_root = preview["verified_sync_root"]
        .as_bool()
        .ok_or("The Rust setup preview omitted the sync-root review state.")?;
    let worker_gates_passed = preview["review_gates_passed"]
        .as_bool()
        .ok_or("The Rust setup preview omitted its review-gate result.")?;
    let warnings = preview["content_warnings"]
        .as_array()
        .ok_or("The Rust setup preview omitted its content warnings.")?;
    if warnings.iter().any(|warning| warning.as_str().is_none()) {
        return Err("The Rust setup preview returned an invalid content warning.".into());
    }
    let rows = preview["rows"]
        .as_array()
        .ok_or("The Rust setup preview omitted its folder rows.")?
        .iter()
        .map(|row| -> Result<serde_json::Value, String> {
            let folder = row["folder"]
                .as_str()
                .filter(|value| !value.is_empty())
                .ok_or("The Rust setup preview returned a row without a folder name.")?;
            let proposed = row["proposed"]
                .as_str()
                .filter(|value| !value.is_empty())
                .ok_or("The Rust setup preview returned a row without a proposed path.")?;
            let action = row["action"]
                .as_str()
                .filter(|value| !value.is_empty())
                .ok_or("The Rust setup preview returned a row without an action.")?;
            let current = &row["current"];
            if !(current.is_null() || current.is_string()) {
                return Err("The Rust setup preview returned an invalid current path.".into());
            }
            Ok(serde_json::json!({
                "Folder": folder,
                "Current": current,
                "Proposed": proposed,
                "Action": action,
            }))
        })
        .collect::<Result<Vec<_>, String>>()?;
    if rows.is_empty() {
        return Err("The Rust setup preview returned no managed folders.".into());
    }
    let gates_passed = worker_gates_passed && warnings.is_empty();
    let report = serde_json::json!({
        "Root": root,
        "RootRegistered": root_registered,
        "VerifiedSyncRoot": verified_sync_root,
        "ReviewGatesPassed": gates_passed,
        "RecoveryRoot": recovery_root,
        "ApprovalToken": approval_token,
        "Rows": rows,
        "ContentWarnings": warnings,
    });
    Ok(WorkerResult {
        exit_code: if gates_passed { 0 } else { 3 },
        message: if gates_passed {
            "Setup preview is ready. Review the proposed folder locations.".into()
        } else {
            "Setup preview needs attention. Apply remains unavailable until its review checks pass."
                .into()
        },
        text: serde_json::to_string(&report).map_err(|error| error.to_string())?,
    })
}

fn reset_preview_result(
    preview: &serde_json::Value,
    approval_token: &str,
) -> Result<WorkerResult, String> {
    if preview["operation"] != "reset" {
        return Err("The Rust backend returned the wrong preview type for reset.".into());
    }
    let recovery_root = preview["recovery_root"]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or("The Rust reset preview omitted the recovery folder.")?;
    let worker_gates_passed = preview["review_gates_passed"]
        .as_bool()
        .ok_or("The Rust reset preview omitted its review-gate result.")?;
    let warnings = preview["content_warnings"]
        .as_array()
        .ok_or("The Rust reset preview omitted its content warnings.")?;
    if warnings.iter().any(|warning| warning.as_str().is_none()) {
        return Err("The Rust reset preview returned an invalid content warning.".into());
    }
    let rows = preview["rows"]
        .as_array()
        .ok_or("The Rust reset preview omitted its folder rows.")?
        .iter()
        .map(|row| -> Result<serde_json::Value, String> {
            let folder = row["folder"]
                .as_str()
                .filter(|value| !value.is_empty())
                .ok_or("The Rust reset preview returned a row without a folder name.")?;
            let proposed = row["proposed"]
                .as_str()
                .filter(|value| !value.is_empty())
                .ok_or("The Rust reset preview returned a row without a proposed path.")?;
            let action = row["action"]
                .as_str()
                .filter(|value| !value.is_empty())
                .ok_or("The Rust reset preview returned a row without an action.")?;
            let current = &row["current"];
            if !(current.is_null() || current.is_string()) {
                return Err("The Rust reset preview returned an invalid current path.".into());
            }
            Ok(serde_json::json!({
                "Folder": folder,
                "Current": current,
                "Proposed": proposed,
                "Action": action,
            }))
        })
        .collect::<Result<Vec<_>, String>>()?;
    if rows.is_empty() {
        return Err("The Rust reset preview returned no managed folders.".into());
    }
    let gates_passed = worker_gates_passed && warnings.is_empty();
    let report = serde_json::json!({
        "Operation": "reset",
        "ReviewGatesPassed": gates_passed,
        "RecoveryRoot": recovery_root,
        "ApprovalToken": approval_token,
        "Rows": rows,
        "ContentWarnings": warnings,
    });
    Ok(WorkerResult {
        exit_code: if gates_passed { 0 } else { 3 },
        message: if gates_passed {
            "Reset preview is ready. Review every proposed Windows folder location.".into()
        } else {
            "Reset preview needs attention. Apply remains unavailable until its review checks pass."
                .into()
        },
        text: serde_json::to_string(&report).map_err(|error| error.to_string())?,
    })
}

fn restore_preview_result(
    preview: &serde_json::Value,
    backup_path: &str,
    approval_token: &str,
) -> Result<WorkerResult, String> {
    if preview["operation"] != "restore" {
        return Err("The Rust backend returned the wrong preview type for recovery.".into());
    }
    let recovery_root = preview["recovery_root"]
        .as_str()
        .filter(|value| !value.is_empty())
        .ok_or("The Rust recovery preview omitted the recovery folder.")?;
    let rows = preview["rows"]
        .as_array()
        .ok_or("The Rust recovery preview omitted its folder rows.")?
        .iter()
        .map(|row| -> Result<serde_json::Value, String> {
            let folder = row["folder"]
                .as_str()
                .filter(|value| !value.is_empty())
                .ok_or("The Rust recovery preview returned a row without a folder name.")?;
            let current_exists = row["current_exists"]
                .as_bool()
                .ok_or("The Rust recovery preview omitted current-value presence.")?;
            let proposed_exists = row["proposed_exists"]
                .as_bool()
                .ok_or("The Rust recovery preview omitted restored-value presence.")?;
            let current = &row["current"];
            let proposed = &row["proposed"];
            let current_kind = &row["current_kind"];
            let proposed_kind = &row["proposed_kind"];
            let action = row["action"]
                .as_str()
                .filter(|value| !value.is_empty())
                .ok_or("The Rust recovery preview returned a row without an action.")?;
            let kind_is_valid =
                |kind: &serde_json::Value, exists: bool| match (exists, kind.as_str()) {
                    (true, Some(value)) => {
                        value.eq_ignore_ascii_case("String")
                            || value.eq_ignore_ascii_case("ExpandString")
                    }
                    (false, None) => true,
                    _ => false,
                };
            if !(current.is_null() || current.as_str().is_some_and(|value| !value.is_empty()))
                || !(proposed.is_null() || proposed.as_str().is_some_and(|value| !value.is_empty()))
                || current_exists != current.is_string()
                || proposed_exists != proposed.is_string()
                || !kind_is_valid(current_kind, current_exists)
                || !kind_is_valid(proposed_kind, proposed_exists)
                || ![
                    "Already configured",
                    "Add missing value",
                    "Update value",
                    "Remove value",
                ]
                .contains(&action)
            {
                return Err(
                    "The Rust recovery preview returned inconsistent registry values.".into(),
                );
            }
            Ok(serde_json::json!({
                "Folder": folder,
                "Current": current,
                "CurrentExists": current_exists,
                "CurrentKind": current_kind,
                "Proposed": proposed,
                "ProposedExists": proposed_exists,
                "ProposedKind": proposed_kind,
                "Action": action,
            }))
        })
        .collect::<Result<Vec<_>, String>>()?;
    if rows.is_empty() {
        return Err("The Rust recovery preview returned no managed folders.".into());
    }
    let report = serde_json::json!({
        "BackupPath": backup_path,
        "RecoveryRoot": recovery_root,
        "ApprovalToken": approval_token,
        "Rows": rows,
    });
    Ok(WorkerResult {
        exit_code: 0,
        message: "Recovery preview is ready. Review every proposed location before applying."
            .into(),
        text: serde_json::to_string(&report).map_err(|error| error.to_string())?,
    })
}

struct CancelEvent {
    handle: HANDLE,
    name: String,
}
unsafe impl Send for CancelEvent {}
impl CancelEvent {
    fn new() -> Result<Self, String> {
        unsafe {
            use windows_sys::Win32::System::Threading::*;
            let ticks = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|e| e.to_string())?
                .as_nanos();
            let name = copy_cancel_event_name(std::process::id(), ticks);
            let handle = CreateEventW(null_mut(), 1, 0, wide(&name).as_ptr());
            if handle.is_null() {
                return Err("Windows could not create the copy cancellation event.".into());
            }
            Ok(Self { handle, name })
        }
    }
    fn signal(&self) {
        unsafe {
            windows_sys::Win32::System::Threading::SetEvent(self.handle);
        }
    }
}

fn copy_cancel_event_name(process_id: u32, ticks: u128) -> String {
    // ICloudFolderCopy.psm1 accepts exactly 32 hexadecimal characters after this prefix.
    // Keep the producer and consumer on the same bounded named-event contract.
    format!(
        "Local\\ICloudCopy-{:032x}",
        ticks ^ (u128::from(process_id) << 64)
    )
}
impl Drop for CancelEvent {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.handle);
        }
    }
}
fn operation(
    options: Options,
    phase: String,
    review_token: Option<String>,
    copy_page_offset: usize,
    stop: Arc<AtomicBool>,
    sender: mpsc::SyncSender<WorkerMessage>,
) -> Result<WorkerResult, String> {
    let source = SOURCE
        .get()
        .cloned()
        .ok_or("The application source directory is unavailable.")?;
    let native_copy_apply_requested = phase == "Apply" && options.copy() && review_token.is_some();
    let native_apply_requested = phase == "Apply"
        && review_token.is_some()
        && (native_copy_apply_requested
            || matches!(
                options.action.as_str(),
                "Set up iCloud folders" | "Reset to Windows defaults" | "Restore a recovery backup"
            ));
    let needs_native = options.action == "Check iCloud configuration"
        || (options.action == "Set up iCloud folders" && phase == "Preview")
        || (options.action == "Reset to Windows defaults" && phase == "Preview")
        || (options.action == "Restore a recovery backup" && phase == "DryRun")
        || (options.copy() && matches!(phase.as_str(), "Preview" | "CopyPage"))
        || native_apply_requested;
    if needs_native {
        let configured = std::env::var_os("ICLOUD_NATIVE_BACKEND").map(PathBuf::from);
        let bundled = source.join("RustUI/icloud-folder-worker.exe");
        if let Some(worker) = configured.or_else(|| bundled.is_file().then_some(bundled)) {
            return if options.copy() && matches!(phase.as_str(), "Preview" | "CopyPage") {
                native_copy_preview(&options, &worker, &source, copy_page_offset, &stop, &sender)
            } else if native_copy_apply_requested {
                let cancellation = CancelEvent::new()?;
                native_copy_apply(
                    &options,
                    &worker,
                    &source,
                    review_token
                        .as_deref()
                        .expect("copy apply requires a review token"),
                    &cancellation,
                    &stop,
                    &sender,
                )
            } else if options.action == "Check iCloud configuration" {
                native_check(&options, &worker, &source, &stop)
            } else if options.action == "Set up iCloud folders" {
                if phase == "Preview" {
                    native_setup_preview(&options, &worker, &source, &stop)
                } else {
                    native_apply(&options, &worker, &source, review_token.as_deref(), &stop)
                }
            } else if options.action == "Reset to Windows defaults" {
                if phase == "Preview" {
                    native_reset_preview(&options, &worker, &source, &stop)
                } else {
                    native_apply(&options, &worker, &source, review_token.as_deref(), &stop)
                }
            } else if native_apply_requested {
                native_apply(&options, &worker, &source, review_token.as_deref(), &stop)
            } else {
                native_restore_preview(&options, &worker, &source, &stop)
            };
        } else if native_apply_requested {
            return Err("The Rust backend required by this reviewed Apply is missing. Rebuild the development package; no settings were changed.".into());
        }
    }
    let bridge = source.join("tools/Invoke-WinUIBridge.ps1");
    if !bridge.is_file() {
        return Err("The backend bridge is missing. Extract the complete application.".into());
    }
    let cancel = if options.copy() {
        Some(CancelEvent::new()?)
    } else {
        None
    };
    let encoded = request(&options, &phase, cancel.as_ref().map(|v| v.name.as_str()))?;
    let readonly = phase != "Apply" || !options.mutates();
    let powershell =
        PathBuf::from(std::env::var_os("SystemRoot").ok_or("Windows directory unavailable.")?)
            .join("System32/WindowsPowerShell/v1.0/powershell.exe");
    let mut child = Command::new(powershell)
        .args([
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
        ])
        .arg(bridge)
        .args(["-EncodedRequest", &encoded])
        .current_dir(&source)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(0x08000000)
        .spawn()
        .map_err(|e| format!("Could not start the operation: {e}"))?;
    let stdout = child.stdout.take().ok_or("Missing standard output.")?;
    let stderr = child.stderr.take().ok_or("Missing standard error.")?;
    let progress = sender.clone();
    let out = thread::spawn(move || read_output(stdout, progress));
    let err = thread::spawn(move || drain(stderr));
    let started = std::time::Instant::now();
    let mut killed = false;
    let mut signalled = false;
    let exit = loop {
        if stop.load(Ordering::Relaxed) && !signalled {
            signalled = true;
            if let Some(event) = &cancel {
                event.signal();
            } else if readonly {
                let _ = child.kill();
                killed = true;
            }
        }
        // Never kill a writing process, including on timeout. It owns backup/rollback.
        if readonly && !options.copy() && !killed && started.elapsed() > Duration::from_secs(120) {
            let _ = child.kill();
            killed = true;
        }
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            break status;
        }
        thread::sleep(Duration::from_millis(25));
    };
    let (output, overflow) = out.join().map_err(|_| "Output reader failed.")??;
    let (errors, error_overflow) = err.join().map_err(|_| "Error reader failed.")??;
    if killed {
        return Ok(WorkerResult {
            exit_code: 3,
            message: "Read-only check stopped. No folder settings or files were changed.".into(),
            text: String::new(),
        });
    }
    if overflow || error_overflow {
        return Err(overflow_diagnostic(&output, &errors));
    }
    let output = String::from_utf8(output.as_bytes()).map_err(|_| "Invalid UTF-8 result.")?;
    let record=output.lines().filter_map(|line|line.strip_prefix("@@ICloudResult:")).next_back().ok_or_else(||format!("The operation ended without a complete result. Review recovery records before retrying. {}",errors.summary(8 * 1024)))?;
    let mut result: WorkerResult = serde_json::from_str(record).map_err(|e| e.to_string())?;
    if Some(result.exit_code) != exit.code() {
        return Err(
            "The worker returned inconsistent exit codes. Review recovery records before retrying."
                .into(),
        );
    }
    result
        .text
        .push_str(&errors.summary(OVERFLOW_DIAGNOSTIC_LIMIT));
    Ok(result)
}
// Bound each record and retained output, but always drain both pipes. Progress
// uses a bounded nonblocking channel so a busy UI can never deadlock the worker.
fn read_output(
    mut input: impl Read,
    sender: mpsc::SyncSender<WorkerMessage>,
) -> Result<(BoundedOutput, bool), String> {
    let mut output = BoundedOutput::default();
    let mut line = BoundedOutput::default();
    let mut overflow = false;
    let mut buffer = [0u8; 8192];
    loop {
        let n = input.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        let mut start = 0;
        for (index, byte) in buffer[..n].iter().enumerate() {
            if *byte == b'\n' {
                line.push(&buffer[start..index]);
                overflow |= retain_output_line(&line, &mut output, &sender);
                line = BoundedOutput::default();
                start = index + 1;
            }
        }
        if start < n {
            line.push(&buffer[start..n]);
            overflow |= line.exceeded_limit();
        }
    }
    if !line.is_empty() {
        overflow |= retain_output_line(&line, &mut output, &sender);
    }
    overflow |= output.exceeded_limit();
    Ok((output, overflow))
}
fn confirm(owner: HWND, options: &Options) -> Result<bool, String> {
    unsafe {
        let title = wide("iCloud folder setup");
        let label = wide(options.label());
        let content = wide(options.consequence());
        let button = TASKDIALOG_BUTTON {
            nButtonID: 1000,
            pszButtonText: label.as_ptr(),
        };
        let mut config: TASKDIALOGCONFIG = std::mem::zeroed();
        config.cbSize = std::mem::size_of::<TASKDIALOGCONFIG>() as u32;
        config.hwndParent = owner;
        config.dwFlags =
            TDF_POSITION_RELATIVE_TO_WINDOW | TDF_ALLOW_DIALOG_CANCELLATION | TDF_SIZE_TO_CONTENT;
        config.dwCommonButtons = TDCBF_CANCEL_BUTTON;
        config.pszWindowTitle = title.as_ptr();
        config.pszMainInstruction = label.as_ptr();
        config.pszContent = content.as_ptr();
        config.cButtons = 1;
        config.pButtons = &button;
        config.nDefaultButton = IDCANCEL;
        let mut answer = 0;
        let hr = TaskDialogIndirect(&config, &mut answer, null_mut(), null_mut());
        if hr < 0 {
            return Err(format!(
                "Windows could not open the confirmation ({hr:#x})."
            ));
        }
        Ok(answer == 1000)
    }
}
fn picker(owner: HWND, folder: bool, save: bool, title: &str) -> Result<Option<String>, String> {
    use windows::Win32::UI::Shell::*;
    unsafe {
        let dialog: IFileDialog = if save {
            let d: IFileSaveDialog = CoCreateInstance(&FileSaveDialog, None, CLSCTX_INPROC_SERVER)
                .map_err(|e| e.to_string())?;
            windows::core::Interface::cast(&d).map_err(|e| e.to_string())?
        } else {
            let d: IFileOpenDialog = CoCreateInstance(&FileOpenDialog, None, CLSCTX_INPROC_SERVER)
                .map_err(|e| e.to_string())?;
            windows::core::Interface::cast(&d).map_err(|e| e.to_string())?
        };
        let flags = dialog.GetOptions().map_err(|e| e.to_string())?;
        dialog
            .SetOptions(
                flags
                    | FOS_FORCEFILESYSTEM
                    | if folder {
                        FOS_PICKFOLDERS
                    } else if save {
                        FOS_OVERWRITEPROMPT
                    } else {
                        FOS_FILEMUSTEXIST
                    },
            )
            .map_err(|e| e.to_string())?;
        dialog
            .SetTitle(PCWSTR(wide(title).as_ptr()))
            .map_err(|e| e.to_string())?;
        if !folder {
            let name = wide(if save {
                "Text result"
            } else {
                "Recovery backup"
            });
            let extension = wide(if save { "*.txt" } else { "*.json" });
            dialog
                .SetFileTypes(&[Common::COMDLG_FILTERSPEC {
                    pszName: PCWSTR(name.as_ptr()),
                    pszSpec: PCWSTR(extension.as_ptr()),
                }])
                .map_err(|e| e.to_string())?;
            if save {
                dialog
                    .SetDefaultExtension(PCWSTR(wide("txt").as_ptr()))
                    .map_err(|e| e.to_string())?;
            }
        }
        if let Err(e) = dialog.Show(Some(windows::Win32::Foundation::HWND(owner))) {
            if e.code().0 == 0x800704c7u32 as i32 {
                return Ok(None);
            }
            return Err(e.to_string());
        }
        let item = dialog.GetResult().map_err(|e| e.to_string())?;
        let value = item
            .GetDisplayName(SIGDN_FILESYSPATH)
            .map_err(|e| e.to_string())?;
        let result = value.to_string().map_err(|e| e.to_string());
        windows::Win32::System::Com::CoTaskMemFree(Some(value.0.cast()));
        result.map(Some)
    }
}

/// Collect current UI state into paths for command building.
fn collect_paths(state: &State) -> Vec<(String, String)> {
    let mut paths = Vec::new();
    for row in &state.rows {
        if row.optional && !checked(state.music) {
            continue;
        }
        let path = text(row.editor);
        paths.push((row.relative.clone(), path));
    }
    paths
}
impl State {
    unsafe fn create(
        window: HWND,
        fixture_dpi: Option<u32>,
        fixture_dark: Option<bool>,
    ) -> Result<Self, String> {
        let dpi = fixture_dpi
            .unwrap_or(unsafe { GetDpiForWindow(window) })
            .max(96);
        let mut fixed = Vec::new();
        let heading = unsafe { control(window, "STATIC", "iCloud folder setup", SS_LEFT, 400)? };
        fixed.push((heading, (20, 16, 560, 28)));
        let intro = unsafe {
            control(
                window,
                "STATIC",
                "Review a plan before applying. Originals stay in place. Copying is a separate action.",
                SS_LEFT,
                401,
            )?
        };
        fixed.push((intro, (20, 52, 560, 44)));
        let root_label = unsafe { control(window, "STATIC", "&Drive folder:", SS_LEFT, 402)? };
        fixed.push((root_label, (20, 108, 112, 26)));
        let root = unsafe {
            control(
                window,
                "EDIT",
                "",
                WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                ROOT,
            )?
        };
        let music = unsafe {
            control(
                window,
                "BUTTON",
                "Include &Music",
                WS_TABSTOP | BS_AUTOCHECKBOX as u32,
                MUSIC,
            )?
        };
        let advanced = unsafe {
            control(
                window,
                "BUTTON",
                "Customize &paths",
                WS_TABSTOP | BS_AUTOCHECKBOX as u32,
                ADVANCED,
            )?
        };
        let mut rows = Vec::new();
        for (index, mapping) in definitions()?.into_iter().enumerate() {
            let icon = unsafe {
                control(
                    window,
                    "STATIC",
                    glyph(&mapping.relative_path),
                    SS_LEFT,
                    600 + index,
                )?
            };
            let name = mapping
                .relative_path
                .rsplit('\\')
                .next()
                .unwrap_or(&mapping.relative_path);
            let label = unsafe {
                control(
                    window,
                    "STATIC",
                    &(name.to_owned() + ":"),
                    SS_LEFT,
                    500 + index,
                )?
            };
            let editor = unsafe {
                control(
                    window,
                    "EDIT",
                    "",
                    WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32 | ES_READONLY as u32,
                    200 + index,
                )?
            };
            unsafe {
                SendMessageW(editor, EM_SETLIMITTEXT, 32000, 0);
            }
            rows.push(Row {
                relative: mapping.relative_path,
                optional: mapping.optional,
                label,
                icon,
                editor,
                browse: unsafe {
                    control(
                        window,
                        "BUTTON",
                        "Browse...",
                        WS_TABSTOP | BS_PUSHBUTTON as u32,
                        300 + index,
                    )?
                },
            });
        }
        let status_label = unsafe { control(window, "STATIC", "Status:", SS_LEFT, 403)? };
        // Progress bar (initially hidden)
        let progress_class = wide("msctls_progress32");
        let progress = unsafe {
            CreateWindowExW(
                0,
                progress_class.as_ptr(),
                null_mut(),
                WS_CHILD | WS_VISIBLE | PBS_MARQUEE,
                0,
                0,
                0,
                0,
                window,
                PROGRESS_BAR as HMENU,
                GetModuleHandleW(null_mut()),
                null_mut(),
            )
        };
        if progress.is_null() {
            return Err("Windows could not create the progress bar.".into());
        }
        // Set indeterminate (marquee) mode
        unsafe {
            SendMessageW(progress, PBM_SETMARQUEE, 1, 30);
        }
        let status = unsafe {
            control(
                window,
                "EDIT",
                "Choose an action, review its options, then Preview. No changes have been made.",
                WS_BORDER
                    | WS_TABSTOP
                    | ES_MULTILINE as u32
                    | ES_READONLY as u32
                    | ES_AUTOVSCROLL as u32
                    | WS_VSCROLL,
                STATUS,
            )?
        };
        let preview = unsafe {
            control(
                window,
                "BUTTON",
                "&Preview",
                WS_TABSTOP | BS_DEFPUSHBUTTON as u32,
                PREVIEW,
            )?
        };
        let apply = unsafe {
            control(
                window,
                "BUTTON",
                "&Apply",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                APPLY,
            )?
        };
        let copy = unsafe {
            control(
                window,
                "BUTTON",
                "&Copy files",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                COPY,
            )?
        };
        let reset = unsafe {
            control(
                window,
                "BUTTON",
                "&Reset",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                RESET,
            )?
        };
        let check = unsafe {
            control(
                window,
                "BUTTON",
                "&Check",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                CHECK,
            )?
        };
        let close = unsafe {
            control(
                window,
                "BUTTON",
                "&Close",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                CLOSE,
            )?
        };
        let cancel_btn = unsafe {
            control(
                window,
                "BUTTON",
                "Ca&ncel",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                CANCEL,
            )?
        };
        unsafe {
            SendMessageW(root, EM_SETLIMITTEXT, 32000, 0);
        }
        let action = unsafe {
            control(
                window,
                "COMBOBOX",
                "",
                WS_TABSTOP | CBS_DROPDOWNLIST as u32 | WS_VSCROLL,
                ACTION,
            )?
        };
        for name in ACTIONS {
            unsafe {
                SendMessageW(action, CB_ADDSTRING, 0, wide(name).as_ptr() as isize);
            }
        }
        unsafe {
            SendMessageW(action, CB_SETCURSEL, 0, 0);
        }
        let backup = unsafe {
            control(
                window,
                "EDIT",
                "",
                WS_BORDER | WS_TABSTOP | ES_AUTOHSCROLL as u32,
                BACKUP,
            )?
        };
        let verified = unsafe {
            control(
                window,
                "BUTTON",
                "Use a manually verified iCloud folder",
                WS_TABSTOP | BS_AUTOCHECKBOX as u32,
                VERIFIED,
            )?
        };
        let keep = unsafe {
            control(
                window,
                "BUTTON",
                "Change locations without copying existing files",
                WS_TABSTOP | BS_AUTOCHECKBOX as u32,
                KEEP,
            )?
        };
        let technical = unsafe {
            control(
                window,
                "BUTTON",
                "Technical details",
                WS_TABSTOP | BS_AUTOCHECKBOX as u32,
                TECHNICAL,
            )?
        };
        let desktop_shortcut = unsafe {
            control(
                window,
                "BUTTON",
                "Add desktop shortcut",
                WS_TABSTOP | BS_AUTOCHECKBOX as u32,
                DESKTOP_SHORTCUT,
            )?
        };
        // MSAA's common-controls proxy names ListViews from a preceding static
        // label. Keep this label directly before the results control in child
        // creation order and expose the same name through direct annotation.
        let table_label = unsafe { control(window, "STATIC", "Folder results", SS_LEFT, 404)? };
        let table = unsafe {
            control(
                window,
                "SysListView32",
                "",
                WS_BORDER | WS_TABSTOP | LVS_REPORT | LVS_SHOWSELALWAYS,
                TABLE,
            )?
        };
        let previous_page = unsafe {
            control(
                window,
                "BUTTON",
                "Previous page",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                PREVIOUS_PAGE,
            )?
        };
        let next_page = unsafe {
            control(
                window,
                "BUTTON",
                "Next page",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                NEXT_PAGE,
            )?
        };
        unsafe {
            ShowWindow(previous_page, SW_HIDE);
            ShowWindow(next_page, SW_HIDE);
        }
        unsafe {
            SendMessageW(
                table,
                LVM_SETEXTENDEDLISTVIEWSTYLE,
                0,
                (LVS_EX_FULLROWSELECT | LVS_EX_DOUBLEBUFFER | LVS_EX_LABELTIP) as isize,
            );
        }
        for (index, name) in ["Folder / check", "Current location", "Matches", "Exists"]
            .iter()
            .enumerate()
        {
            unsafe {
                let mut name = wide(name);
                let mut column: LVCOLUMNW = std::mem::zeroed();
                column.mask = LVCF_TEXT | LVCF_WIDTH | LVCF_SUBITEM;
                column.pszText = name.as_mut_ptr();
                column.cx = 160;
                column.iSubItem = index as i32;
                SendMessageW(
                    table,
                    LVM_INSERTCOLUMNW,
                    index,
                    (&column as *const LVCOLUMNW) as isize,
                );
            }
        }
        let dry = unsafe {
            control(
                window,
                "BUTTON",
                "&Dry run",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                DRY,
            )?
        };
        let browse_root = unsafe {
            control(
                window,
                "BUTTON",
                "Browse...",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                BROWSE_ROOT,
            )?
        };
        let browse_backup = unsafe {
            control(
                window,
                "BUTTON",
                "Recovery file...",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                BROWSE_BACKUP,
            )?
        };
        let save = unsafe {
            control(
                window,
                "BUTTON",
                "Save result...",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                SAVE,
            )?
        };
        let recovery = unsafe {
            control(
                window,
                "BUTTON",
                "Recovery files",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                RECOVERY,
            )?
        };
        let help = unsafe {
            control(
                window,
                "BUTTON",
                "Help",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                HELP,
            )?
        };
        let install = unsafe {
            control(
                window,
                "BUTTON",
                "Install for me...",
                WS_TABSTOP | BS_PUSHBUTTON as u32,
                INSTALL,
            )?
        };
        let mut app_icons = Vec::new();
        for (size, flags) in [
            (ICON_SMALL, SHGSI_ICON | SHGSI_SMALLICON),
            (ICON_BIG, SHGSI_ICON),
        ] {
            unsafe {
                let mut icon: SHSTOCKICONINFO = std::mem::zeroed();
                icon.cbSize = std::mem::size_of::<SHSTOCKICONINFO>() as u32;
                if SHGetStockIconInfo(SIID_FOLDER, flags, &mut icon) >= 0 {
                    SendMessageW(window, WM_SETICON, size as usize, icon.hIcon as isize);
                    app_icons.push(icon.hIcon);
                }
            }
        }
        let accent_color = create_accent_color();
        let hc = is_high_contrast();
        let theme = Theme::current(fixture_dark);
        let background_brush = unsafe { CreateSolidBrush(theme.background) };
        let field_brush = unsafe { CreateSolidBrush(theme.field) };
        if background_brush.is_null() || field_brush.is_null() {
            unsafe {
                DeleteObject(background_brush);
                DeleteObject(field_brush);
            }
            return Err("Windows could not create the interface colors.".into());
        }
        let mut state = Self {
            accessibility: Accessibility::new()?,
            window,
            root,
            music,
            advanced,
            status,
            fixed,
            rows,
            preview,
            apply,
            copy,
            reset,
            check,
            close,
            cancel_btn,
            progress,
            status_label,
            font: null_mut(),
            icon_font: null_mut(),
            accent_font: null_mut(),
            dpi,
            fixture_dpi,
            fixture_dark,
            theme,
            background_brush,
            field_brush,
            is_running: false,
            result: None,
            stop: Arc::new(AtomicBool::new(false)),
            action,
            backup,
            verified,
            keep,
            technical,
            table,
            table_label,
            previous_page,
            next_page,
            dry,
            browse_root,
            browse_backup,
            save,
            recovery,
            help,
            install,
            desktop_shortcut,
            reviewed: None,
            review_token: None,
            copy_reviewed: None,
            copy_review_token: None,
            copy_page_expected_token: None,
            copy_page_offsets: Vec::new(),
            copy_page_next_offset: None,
            running_options: None,
            running_phase: String::new(),
            raw: String::new(),
            friendly: String::new(),
            table_ready: false,
            app_icons,
            // Accent theming — skip in high contrast mode
            accent_brush: if hc {
                null_mut()
            } else {
                unsafe { CreateSolidBrush(accent_color) }
            },
            accent_text_brush: if hc {
                null_mut()
            } else {
                unsafe { CreateSolidBrush(0xFFFFFF) }
            },
            accent_progress_brush: if hc {
                null_mut()
            } else {
                unsafe { CreateSolidBrush(accent_color) }
            },
            heading,
        };
        state.fonts()?;
        state.apply_theme();
        state.accessibility.label(
            state.root,
            "Drive folder",
            "Choose the existing folder used by iCloud Drive.",
        )?;
        state.accessibility.label(
            state.status,
            "Status",
            "Operation results. Technical details can be saved for review.",
        )?;
        for (hwnd, name, help) in [
            (
                state.action,
                "Action",
                "Choose setup, reset, restore, copy, configuration check or cloud verification.",
            ),
            (
                state.backup,
                "Recovery backup file",
                "Choose a trusted before.json recovery file for this account.",
            ),
            (
                state.verified,
                "Use a manually verified iCloud folder",
                "Only when Windows has no registration. A known mismatch cannot be overridden.",
            ),
            (
                state.keep,
                "Change locations without copying files",
                "Existing content stays at its original locations. Copying requires a separate action.",
            ),
            (
                state.table,
                "Folder results",
                "Folder locations, proposed paths, check state and directory existence. Use arrow keys to review rows.",
            ),
        ] {
            state.accessibility.label(hwnd, name, help)?;
        }
        for row in &state.rows {
            let name = row.relative.rsplit('\\').next().unwrap_or(&row.relative);
            state.accessibility.label(
                row.editor,
                &format!("{name} destination"),
                "Proposed destination. Originals remain in place.",
            )?;
            state.accessibility.label(row.icon, "", "")?;
        }
        let root = std::env::var_os("USERPROFILE")
            .map(PathBuf::from)
            .unwrap_or_default()
            .join("iCloudDrive");
        set_text(state.root, &root.to_string_lossy());
        state.refresh();
        state.set_buttons_enabled(true);
        state.layout();
        Ok(state)
    }
    fn fonts(&mut self) -> Result<(), String> {
        unsafe {
            let mut metrics: NONCLIENTMETRICSW = std::mem::zeroed();
            metrics.cbSize = std::mem::size_of::<NONCLIENTMETRICSW>() as u32;
            if SystemParametersInfoForDpi(
                SPI_GETNONCLIENTMETRICS,
                metrics.cbSize,
                (&mut metrics as *mut NONCLIENTMETRICSW).cast(),
                0,
                self.dpi,
            ) == 0
            {
                return Err("Windows could not provide the interface font.".into());
            }
            let font = CreateFontIndirectW(&metrics.lfMessageFont);
            // Accent font: bold version of the message font for the heading
            let mut accent_metrics = metrics.lfMessageFont;
            accent_metrics.lfWeight = 700; // FW_BOLD
            let accent_font = CreateFontIndirectW(&accent_metrics);
            let mut icon_metrics = metrics.lfMessageFont;
            icon_metrics.lfHeight = -scaled(20, self.dpi);
            icon_metrics.lfFaceName = [0; 32];
            let name = wide("Segoe Fluent Icons");
            icon_metrics.lfFaceName[..name.len()].copy_from_slice(&name);
            let icons = CreateFontIndirectW(&icon_metrics);
            if font.is_null() || icons.is_null() || accent_font.is_null() {
                DeleteObject(font);
                DeleteObject(icons);
                DeleteObject(accent_font);
                return Err("Windows could not create the interface fonts.".into());
            }
            for (window, _) in &self.fixed {
                SendMessageW(*window, WM_SETFONT, font as usize, 1);
            }
            // Apply accent font to heading
            SendMessageW(self.heading, WM_SETFONT, accent_font as usize, 1);
            for window in [
                self.root,
                self.music,
                self.advanced,
                self.status,
                self.preview,
                self.apply,
                self.copy,
                self.reset,
                self.check,
                self.close,
                self.cancel_btn,
                self.status_label,
                self.action,
                self.backup,
                self.verified,
                self.keep,
                self.technical,
                self.table,
                self.table_label,
                self.dry,
                self.browse_root,
                self.browse_backup,
                self.save,
                self.recovery,
                self.help,
                self.install,
                self.desktop_shortcut,
            ] {
                SendMessageW(window, WM_SETFONT, font as usize, 1);
            }
            for row in &self.rows {
                SendMessageW(row.editor, WM_SETFONT, font as usize, 1);
                SendMessageW(row.browse, WM_SETFONT, font as usize, 1);
                SendMessageW(row.label, WM_SETFONT, font as usize, 1);
                SendMessageW(row.icon, WM_SETFONT, icons as usize, 1);
            }
            DeleteObject(self.font);
            DeleteObject(self.icon_font);
            DeleteObject(self.accent_font);
            self.font = font;
            self.icon_font = icons;
            self.accent_font = accent_font;
        }
        Ok(())
    }

    fn refresh_theme(&mut self) -> Result<(), String> {
        let theme = Theme::current(self.fixture_dark);
        let background = unsafe { CreateSolidBrush(theme.background) };
        let field = unsafe { CreateSolidBrush(theme.field) };
        if background.is_null() || field.is_null() {
            unsafe {
                DeleteObject(background);
                DeleteObject(field);
            }
            return Err("Windows could not create the interface colors.".into());
        }
        unsafe {
            DeleteObject(self.background_brush);
            DeleteObject(self.field_brush);
        }
        self.theme = theme;
        self.background_brush = background;
        self.field_brush = field;
        self.apply_theme();
        Ok(())
    }

    fn apply_theme(&self) {
        unsafe {
            let dark = self.theme.dark as i32;
            let result = DwmSetWindowAttribute(
                self.window,
                DWMWA_USE_IMMERSIVE_DARK_MODE as u32,
                (&dark as *const i32).cast(),
                std::mem::size_of::<i32>() as u32,
            );
            if result < 0 {
                let _ = DwmSetWindowAttribute(
                    self.window,
                    DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1,
                    (&dark as *const i32).cast(),
                    std::mem::size_of::<i32>() as u32,
                );
            }
            let explorer = wide(if dark != 0 {
                "DarkMode_Explorer"
            } else {
                "Explorer"
            });
            let items = wide(if dark != 0 {
                "DarkMode_ItemsView"
            } else {
                "ItemsView"
            });
            let cfd = wide(if dark != 0 {
                "DarkMode_CFD"
            } else {
                "Explorer"
            });
            let header = SendMessageW(self.table, LVM_GETHEADER, 0, 0) as HWND;
            let mut windows: Vec<HWND> = self.fixed.iter().map(|(window, _)| *window).collect();
            windows.extend([
                self.root,
                self.music,
                self.advanced,
                self.table_label,
                self.status,
                self.preview,
                self.apply,
                self.copy,
                self.reset,
                self.check,
                self.close,
                self.cancel_btn,
                self.status_label,
                self.action,
                self.backup,
                self.verified,
                self.keep,
                self.technical,
                self.table,
                self.dry,
                self.browse_root,
                self.browse_backup,
                self.save,
                self.recovery,
                self.help,
                self.install,
                self.desktop_shortcut,
            ]);
            if !header.is_null() {
                windows.push(header);
            }
            for row in &self.rows {
                windows.push(row.label);
                windows.push(row.icon);
                windows.push(row.editor);
                windows.push(row.browse);
            }
            for window in windows {
                let is_field = window == self.root
                    || window == self.backup
                    || window == self.status
                    || window == self.action
                    || self.rows.iter().any(|row| row.editor == window);
                let name = if window == self.table || window == header {
                    &items
                } else if is_field {
                    &cfd
                } else {
                    &explorer
                };
                allow_dark_mode(window, self.theme.dark);
                SetWindowTheme(window, name.as_ptr(), null_mut());
            }
            SendMessageW(self.table, LVM_SETBKCOLOR, 0, self.theme.field as isize);
            SendMessageW(
                self.table,
                LVM_SETTEXTCOLOR,
                0,
                self.theme.field_text as isize,
            );
            SendMessageW(self.table, LVM_SETTEXTBKCOLOR, 0, self.theme.field as isize);
            SendMessageW(self.progress, PBM_SETBKCOLOR, 0, self.theme.field as isize);
            SendMessageW(
                self.progress,
                PBM_SETBARCOLOR,
                0,
                create_accent_color() as isize,
            );
            RedrawWindow(
                self.window,
                null_mut(),
                null_mut(),
                RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN,
            );
        }
    }

    fn control_colors(&self, message: u32, child: HWND) -> (HBRUSH, u32, u32, i32) {
        let enabled = unsafe { IsWindowEnabled(child) != 0 };
        let text = if enabled {
            self.theme.text
        } else {
            self.theme.disabled
        };
        match message {
            WM_CTLCOLORSTATIC => {
                if child == self.heading && !self.accent_brush.is_null() {
                    (
                        self.accent_brush,
                        0xFFFFFF,
                        create_accent_color(),
                        TRANSPARENT as i32,
                    )
                } else {
                    (
                        self.background_brush,
                        text,
                        self.theme.background,
                        TRANSPARENT as i32,
                    )
                }
            }
            WM_CTLCOLORBTN => {
                if child == self.preview && !self.accent_brush.is_null() {
                    (
                        self.accent_brush,
                        0xFFFFFF,
                        create_accent_color(),
                        TRANSPARENT as i32,
                    )
                } else {
                    (
                        self.background_brush,
                        text,
                        self.theme.background,
                        TRANSPARENT as i32,
                    )
                }
            }
            WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX => (
                self.field_brush,
                self.theme.field_text,
                self.theme.field,
                OPAQUE as i32,
            ),
            WM_CTLCOLORDLG => (
                self.background_brush,
                text,
                self.theme.background,
                TRANSPARENT as i32,
            ),
            _ => (
                null_mut(),
                self.theme.text,
                self.theme.background,
                TRANSPARENT as i32,
            ),
        }
    }

    fn action_name(&self) -> String {
        unsafe {
            let index = SendMessageW(self.action, CB_GETCURSEL, 0, 0);
            ACTIONS
                .get(index as usize)
                .unwrap_or(&ACTIONS[0])
                .to_string()
        }
    }
    fn snapshot(&self) -> Result<Options, String> {
        let action = self.action_name();
        let cloud = matches!(
            action.as_str(),
            "Set up iCloud folders"
                | "Copy files into iCloud folders"
                | "Check iCloud configuration"
        );
        let paths = if cloud {
            self.validate_paths()?
        } else {
            Vec::new()
        };
        Ok(Options {
            json: action == "Check iCloud configuration",
            action,
            root: text(self.root),
            backup: text(self.backup),
            music: checked(self.music),
            verified: checked(self.verified),
            keep_files: checked(self.keep),
            desktop_shortcut: checked(self.desktop_shortcut),
            folder_paths: paths
                .into_iter()
                .map(|(name, value)| (name.rsplit('\\').next().unwrap_or(&name).to_string(), value))
                .collect(),
        })
    }
    fn invalidate(&mut self) {
        self.reviewed = None;
        self.review_token = None;
        self.reset_copy_review();
        self.table_ready = false;
        self.raw.clear();
        self.friendly.clear();
        set_text(
            self.status_label,
            "Options changed. Preview again before applying.",
        );
        set_text(self.status, "");
        self.set_buttons_enabled(true);
        self.layout();
    }
    fn reset_copy_review(&mut self) {
        self.copy_reviewed = None;
        self.copy_review_token = None;
        self.copy_page_expected_token = None;
        self.copy_page_offsets.clear();
        self.copy_page_next_offset = None;
        set_text(self.table_label, "Folder results");
    }
    fn refresh(&mut self) {
        let custom = checked(self.advanced);
        let music = checked(self.music);
        let root = PathBuf::from(text(self.root));
        let cloud = matches!(
            self.action_name().as_str(),
            "Set up iCloud folders"
                | "Copy files into iCloud folders"
                | "Check iCloud configuration"
        );
        for row in &self.rows {
            if !custom {
                set_text(row.editor, &root.join(&row.relative).to_string_lossy());
            }
            unsafe {
                SendMessageW(row.editor, EM_SETREADONLY, usize::from(!custom), 0);
            }
            let show = if cloud && (!row.optional || music) {
                SW_SHOW
            } else {
                SW_HIDE
            };
            unsafe {
                for window in [row.icon, row.label, row.editor] {
                    ShowWindow(window, show);
                }
                ShowWindow(
                    row.browse,
                    if show == SW_SHOW && custom {
                        SW_SHOW
                    } else {
                        SW_HIDE
                    },
                );
            }
        }
        let action = self.action_name();
        unsafe {
            for window in [self.root, self.browse_root, self.music, self.advanced] {
                ShowWindow(window, if cloud { SW_SHOW } else { SW_HIDE });
            }
            for window in [self.backup, self.browse_backup] {
                ShowWindow(
                    window,
                    if action == "Restore a recovery backup" {
                        SW_SHOW
                    } else {
                        SW_HIDE
                    },
                );
            }
            ShowWindow(
                self.verified,
                if matches!(
                    action.as_str(),
                    "Set up iCloud folders" | "Copy files into iCloud folders"
                ) {
                    SW_SHOW
                } else {
                    SW_HIDE
                },
            );
            ShowWindow(
                self.keep,
                if matches!(
                    action.as_str(),
                    "Set up iCloud folders" | "Reset to Windows defaults"
                ) {
                    SW_SHOW
                } else {
                    SW_HIDE
                },
            );
            ShowWindow(self.desktop_shortcut, SW_SHOW);
        }
        set_text(
            self.apply,
            self.snapshot()
                .map(|v| format!("{}...", v.label()))
                .unwrap_or_else(|_| "Apply...".into())
                .as_str(),
        );
    }
    fn layout(&self) {
        unsafe {
            let mut client: RECT = std::mem::zeroed();
            GetClientRect(self.window, &mut client);
            let width = client.right * 96 / self.dpi as i32;
            let height = client.bottom * 96 / self.dpi as i32;
            let action = self.action_name();
            let cloud = matches!(
                action.as_str(),
                "Set up iCloud folders"
                    | "Copy files into iCloud folders"
                    | "Check iCloud configuration"
            );
            let restore = action == "Restore a recovery backup";
            let custom = checked(self.advanced);

            // The main window never scrolls. The configuration and result panes
            // share one viewport, and the density changes before anything clips.
            let tight = height < 560;
            let compact = height < 700;
            let footer = 96;
            let viewport = (height - footer).max(1);
            let margin = 20;
            let gap = if width < 900 { 16 } else { 20 };
            let content_width = (width - margin * 2).max(1);
            let two_pane = width >= 800;
            let left_w = if two_pane {
                ((content_width - gap) * 56 / 100)
                    .max(380)
                    .min((content_width - gap - 280).max(320))
            } else {
                content_width
            };
            let right_x = if two_pane {
                margin + left_w + gap
            } else {
                margin
            };
            let right_w = if two_pane {
                (width - margin - right_x).max(280)
            } else {
                content_width
            };

            let (
                heading_y,
                heading_h,
                intro_y,
                intro_h,
                action_y,
                action_h,
                content_y,
                root_label_y,
                root_edit_y,
                root_edit_h,
                options_y,
                options_h,
                rows_y,
                row_step,
                row_h,
                icon_size,
                label_dy,
                label_h,
                checkbox_h,
                status_h,
                progress_y,
                technical_y,
                technical_h,
                result_y,
            ) = if tight {
                (
                    6, 20, 28, 20, 50, 220, 78, 78, 74, 22, 102, 26, 130, 26, 23, 22, 2, 20, 27,
                    32, 114, 130, 26, 158,
                )
            } else if compact {
                (
                    8, 22, 34, 28, 64, 240, 96, 96, 92, 25, 124, 29, 156, 30, 26, 24, 3, 22, 30,
                    42, 142, 160, 28, 192,
                )
            } else {
                (
                    12, 26, 42, 38, 84, 280, 132, 132, 128, 28, 166, 32, 204, 36, 28, 28, 4, 26,
                    32, 52, 190, 208, 30, 244,
                )
            };
            let checkbox_step = checkbox_h + 2;

            let put = |hwnd: HWND, x: i32, y: i32, w: i32, h: i32| {
                place(hwnd, x, y, w, h, self.dpi);
            };

            for (index, (window, _)) in self.fixed.iter().enumerate() {
                match index {
                    0 => put(*window, margin, heading_y, width - margin * 2, heading_h),
                    1 => put(*window, margin, intro_y, width - margin * 2, intro_h),
                    _ => {
                        ShowWindow(*window, if cloud { SW_SHOW } else { SW_HIDE });
                        if cloud {
                            put(*window, margin, root_label_y, 100, 22);
                        }
                    }
                }
            }
            put(self.action, margin, action_y, width - margin * 2, action_h);

            put(
                self.root,
                margin + 112,
                root_edit_y,
                (left_w - 112 - 92).max(80),
                root_edit_h,
            );
            put(
                self.browse_root,
                margin + left_w - 84,
                root_edit_y,
                84,
                root_edit_h,
            );
            put(self.music, margin, options_y, 210, options_h);
            put(
                self.advanced,
                margin + 224,
                options_y,
                (left_w - 224).max(120),
                options_h,
            );
            put(
                self.backup,
                margin,
                root_edit_y,
                (left_w - 148).max(80),
                root_edit_h,
            );
            put(
                self.browse_backup,
                margin + left_w - 128,
                root_edit_y,
                128,
                root_edit_h,
            );

            let mut y = if cloud {
                rows_y
            } else if restore {
                content_y + 38
            } else {
                content_y
            };
            if cloud {
                for row in &self.rows {
                    if row.optional && !checked(self.music) {
                        continue;
                    }
                    put(row.icon, margin, y + 2, icon_size, icon_size);
                    put(row.label, margin + 36, y + label_dy, 100, label_h);
                    let editor_width = if custom {
                        (left_w - 140 - 92).max(80)
                    } else {
                        (left_w - 140).max(80)
                    };
                    put(row.editor, margin + 140, y, editor_width, row_h);
                    put(row.browse, margin + left_w - 84, y, 84, row_h);
                    y += row_step;
                }
            }
            if matches!(
                action.as_str(),
                "Set up iCloud folders" | "Copy files into iCloud folders"
            ) {
                put(self.verified, margin, y, left_w, checkbox_h);
                y += checkbox_step;
            }
            if matches!(
                action.as_str(),
                "Set up iCloud folders" | "Reset to Windows defaults"
            ) {
                put(self.keep, margin, y, left_w, checkbox_h);
                y += checkbox_step;
            }

            let (status_x, status_top, status_width, progress_top, technical_top, result_top) =
                if two_pane {
                    (
                        right_x,
                        content_y,
                        right_w,
                        progress_y,
                        technical_y,
                        result_y,
                    )
                } else {
                    let top = y + 12;
                    (
                        margin,
                        top,
                        content_width,
                        top + status_h + 6,
                        top + status_h + 24,
                        top + status_h + 60,
                    )
                };
            put(
                self.status_label,
                status_x,
                status_top,
                status_width,
                status_h,
            );
            put(self.progress, status_x, progress_top, status_width, 12);
            put(
                self.technical,
                status_x,
                technical_top,
                status_width,
                technical_h,
            );
            let table_top = result_top + scaled(24, self.dpi);
            let result_height = (viewport - result_top - 8).max(80);
            let table_height = (viewport - table_top - 8).max(80);
            put(
                self.status,
                status_x,
                result_top,
                status_width,
                result_height,
            );
            let can_page = self.table_ready
                && action.starts_with("Copy files")
                && (self.copy_page_offsets.len() > 1 || self.copy_page_next_offset.is_some());
            let navigation_width = if can_page { 174 } else { 0 };
            put(
                self.table_label,
                status_x,
                result_top,
                (status_width - navigation_width).max(80),
                20,
            );
            let page_button_width = 82;
            put(
                self.previous_page,
                status_x + status_width - navigation_width,
                result_top,
                page_button_width,
                22,
            );
            put(
                self.next_page,
                status_x + status_width - page_button_width,
                result_top,
                page_button_width,
                22,
            );
            put(self.table, status_x, table_top, status_width, table_height);

            let column0 = (status_width * 42 / 100).clamp(130, 180);
            let column2 = if status_width < 360 { 56 } else { 64 };
            let column3 = 56;
            let column1 = (status_width - column0 - column2 - column3).max(60);
            for (index, w) in [column0, column1, column2, column3].into_iter().enumerate() {
                SendMessageW(
                    self.table,
                    LVM_SETCOLUMNWIDTH,
                    index,
                    scaled(w, self.dpi) as isize,
                );
            }
            ShowWindow(
                self.table,
                if self.table_ready && !checked(self.technical) {
                    SW_SHOW
                } else {
                    SW_HIDE
                },
            );
            ShowWindow(
                self.table_label,
                if self.table_ready && !checked(self.technical) {
                    SW_SHOW
                } else {
                    SW_HIDE
                },
            );
            ShowWindow(
                self.previous_page,
                if can_page && !checked(self.technical) && self.copy_page_offsets.len() > 1 {
                    SW_SHOW
                } else {
                    SW_HIDE
                },
            );
            ShowWindow(
                self.next_page,
                if can_page && !checked(self.technical) && self.copy_page_next_offset.is_some() {
                    SW_SHOW
                } else {
                    SW_HIDE
                },
            );
            ShowWindow(
                self.status,
                if !self.table_ready || checked(self.technical) {
                    SW_SHOW
                } else {
                    SW_HIDE
                },
            );

            let fy = height - footer + 6;
            place(self.preview, 20, fy, 108, 32, self.dpi);
            place(self.dry, 136, fy, 100, 32, self.dpi);
            place(self.apply, 244, fy, 176, 32, self.dpi);
            place(self.check, 428, fy, 100, 32, self.dpi);
            place(self.close, width - 112, fy, 92, 32, self.dpi);
            place(self.cancel_btn, width - 224, fy, 204, 32, self.dpi);
            place(self.save, 20, fy + 40, 112, 30, self.dpi);
            place(self.recovery, 140, fy + 40, 120, 30, self.dpi);
            place(self.help, 268, fy + 40, 60, 30, self.dpi);
            place(self.install, 336, fy + 40, 182, 30, self.dpi);
            place(
                self.desktop_shortcut,
                526,
                fy + 40,
                (width - 546).max(120),
                30,
                self.dpi,
            );
            for hwnd in [self.copy, self.reset] {
                ShowWindow(hwnd, SW_HIDE);
            }
            let mutates = !action.starts_with("Check");
            ShowWindow(self.apply, if mutates { SW_SHOW } else { SW_HIDE });
            ShowWindow(self.dry, if mutates { SW_SHOW } else { SW_HIDE });
            let stoppable = self
                .running_options
                .as_ref()
                .map(|o| o.copy() || self.running_phase != "Apply" || !o.mutates())
                .unwrap_or(false);
            ShowWindow(
                self.check,
                if self.is_running && stoppable {
                    SW_HIDE
                } else {
                    SW_SHOW
                },
            );
            ShowWindow(
                self.cancel_btn,
                if self.is_running && stoppable {
                    SW_SHOW
                } else {
                    SW_HIDE
                },
            );
            ShowWindow(
                self.close,
                if self.is_running && stoppable {
                    SW_HIDE
                } else {
                    SW_SHOW
                },
            );
            ShowWindow(
                self.progress,
                if self.is_running { SW_SHOW } else { SW_HIDE },
            );
            set_text(
                self.cancel_btn,
                if self
                    .running_options
                    .as_ref()
                    .map(|o| o.copy())
                    .unwrap_or(false)
                {
                    "Stop after current file"
                } else {
                    "Stop check"
                },
            );
        }
    }
    fn render(&self) {
        set_text(
            self.status,
            if checked(self.technical) {
                &self.raw
            } else {
                &self.friendly
            },
        );
        self.layout();
    }
    fn show_report(&mut self, result: &WorkerResult) {
        self.table_ready = false;
        self.raw = format!(
            "{}\r\n{}\r\nExit code: {}",
            result.message, result.text, result.exit_code
        );
        self.friendly = format!("{}\r\n{}", result.message, result.text);
        let is_setup = self
            .running_options
            .as_ref()
            .map(|options| options.action == "Set up iCloud folders")
            .unwrap_or(false);
        if is_setup {
            if let Ok(report) = serde_json::from_str::<serde_json::Value>(result.text.trim()) {
                if let Some(values) = report["Rows"].as_array() {
                    self.set_table_headers([
                        "Folder",
                        "Current location",
                        "Proposed location",
                        "Planned action",
                    ]);
                    unsafe {
                        SendMessageW(self.table, LVM_DELETEALLITEMS, 0, 0);
                    }
                    let rows: Vec<[String; 4]> = values
                        .iter()
                        .map(|row| {
                            [
                                row["Folder"].as_str().unwrap_or("Folder").to_owned(),
                                row["Current"].as_str().unwrap_or("Not set").to_owned(),
                                row["Proposed"].as_str().unwrap_or("Unavailable").to_owned(),
                                row["Action"].as_str().unwrap_or("Review").to_owned(),
                            ]
                        })
                        .collect();
                    self.insert_result_rows(&rows);
                    self.table_ready = true;
                    let registration = match report["RootRegistered"].as_bool() {
                        Some(true) => "registered with Windows",
                        Some(false) if report["VerifiedSyncRoot"] == true => {
                            "not listed with Windows; manually confirmed"
                        }
                        Some(false) => "not registered with Windows",
                        None => "not checked",
                    };
                    let warnings = report["ContentWarnings"]
                        .as_array()
                        .map(|items| {
                            items
                                .iter()
                                .filter_map(|item| item.as_str())
                                .collect::<Vec<_>>()
                                .join("\r\n")
                        })
                        .unwrap_or_default();
                    let gate_status = if report["ReviewGatesPassed"] == true {
                        "Review checks passed. No settings or files have changed."
                    } else {
                        "Review checks need attention. Apply remains unavailable."
                    };
                    self.friendly = format!(
                        "{}\r\niCloud Drive: {}\r\nWindows registration: {}\r\nRecovery folder: {} (a backup is created only after you apply)\r\n{}\r\n{}",
                        result.message,
                        report["Root"].as_str().unwrap_or("Unavailable"),
                        registration,
                        report["RecoveryRoot"].as_str().unwrap_or("Unavailable"),
                        gate_status,
                        warnings
                    );
                }
            }
        } else if self
            .running_options
            .as_ref()
            .map(|options| options.action == "Reset to Windows defaults")
            .unwrap_or(false)
        {
            if let Ok(report) = serde_json::from_str::<serde_json::Value>(result.text.trim()) {
                if let Some(values) = report["Rows"].as_array() {
                    self.set_table_headers([
                        "Folder",
                        "Current location",
                        "Windows default",
                        "Planned action",
                    ]);
                    unsafe {
                        SendMessageW(self.table, LVM_DELETEALLITEMS, 0, 0);
                    }
                    let rows: Vec<[String; 4]> = values
                        .iter()
                        .map(|row| {
                            [
                                row["Folder"].as_str().unwrap_or("Folder").to_owned(),
                                row["Current"].as_str().unwrap_or("Not set").to_owned(),
                                row["Proposed"].as_str().unwrap_or("Unavailable").to_owned(),
                                row["Action"].as_str().unwrap_or("Review").to_owned(),
                            ]
                        })
                        .collect();
                    self.insert_result_rows(&rows);
                    self.table_ready = true;
                    let gate_status = if report["ReviewGatesPassed"] == true {
                        "Review checks passed. No settings or files have changed."
                    } else {
                        "Review checks need attention. Apply remains unavailable."
                    };
                    let warnings = report["ContentWarnings"]
                        .as_array()
                        .map(|items| {
                            items
                                .iter()
                                .filter_map(|item| item.as_str())
                                .collect::<Vec<_>>()
                                .join("\r\n")
                        })
                        .unwrap_or_default();
                    self.friendly = format!(
                        "{}\r\nWindows defaults\r\nRecovery folder: {} (a backup is created only after you apply)\r\n{}\r\n{}",
                        result.message,
                        report["RecoveryRoot"].as_str().unwrap_or("Unavailable"),
                        gate_status,
                        warnings
                    );
                }
            }
        } else if self
            .running_options
            .as_ref()
            .map(|options| options.copy())
            .unwrap_or(false)
        {
            if let Ok(report) = serde_json::from_str::<serde_json::Value>(result.text.trim()) {
                if let Some(values) = report["Rows"].as_array() {
                    let page_offset = report["PageOffset"].as_u64().unwrap_or(0) as usize;
                    let total_entries = report["TotalEntries"].as_u64().unwrap_or(0) as usize;
                    self.copy_reviewed = self.running_options.clone();
                    self.copy_review_token = report["ApprovalToken"].as_str().map(str::to_owned);
                    self.copy_page_next_offset = report["NextOffset"].as_u64().map(|v| v as usize);
                    let first_row = if values.is_empty() {
                        0
                    } else {
                        page_offset + 1
                    };
                    let last_row = page_offset + values.len();
                    set_text(
                        self.table_label,
                        &format!("Folder results: rows {first_row}–{last_row} of {total_entries}"),
                    );
                    self.set_table_headers(["Source", "Destination", "Type", "Action"]);
                    unsafe {
                        SendMessageW(self.table, LVM_DELETEALLITEMS, 0, 0);
                    }
                    let rows: Vec<[String; 4]> = values
                        .iter()
                        .map(|row| {
                            [
                                row["Source"].as_str().unwrap_or("Unavailable").to_owned(),
                                row["Destination"]
                                    .as_str()
                                    .unwrap_or("Unavailable")
                                    .to_owned(),
                                row["Type"].as_str().unwrap_or("Entry").to_owned(),
                                row["Action"].as_str().unwrap_or("Review").to_owned(),
                            ]
                        })
                        .collect();
                    self.insert_result_rows(&rows);
                    self.table_ready = true;
                    let registration = match report["RootRegistered"].as_bool() {
                        Some(true) => "registered with Windows",
                        Some(false) if report["ReviewGatesPassed"] == true => {
                            "not listed with Windows; manually confirmed"
                        }
                        Some(false) => "not registered with Windows",
                        None => "Windows default folders",
                    };
                    let gate_status = if report["ReviewGatesPassed"] == true {
                        "Review checks passed. No files or folders have changed."
                    } else {
                        "Review checks need attention. Apply remains unavailable."
                    };
                    self.friendly = format!(
                        "{}\r\nShowing rows {first_row}–{last_row} of {total_entries}.\r\nCopy target: {}\r\nWindows registration: {}\r\n{}\r\nOriginals stay in place; folder settings are unchanged. Cloud files may download.",
                        result.message,
                        if report["ResetToDefaults"] == true {
                            "Windows default folders"
                        } else {
                            report["Root"].as_str().unwrap_or("Unavailable")
                        },
                        registration,
                        gate_status
                    );
                }
            }
        } else if self
            .running_options
            .as_ref()
            .map(|options| options.action == "Restore a recovery backup")
            .unwrap_or(false)
        {
            if let Ok(report) = serde_json::from_str::<serde_json::Value>(result.text.trim()) {
                if let Some(values) = report["Rows"].as_array() {
                    self.set_table_headers([
                        "Folder",
                        "Current location",
                        "Restored location",
                        "Planned action",
                    ]);
                    unsafe {
                        SendMessageW(self.table, LVM_DELETEALLITEMS, 0, 0);
                    }
                    let rows: Vec<[String; 4]> = values
                        .iter()
                        .map(|row| {
                            [
                                row["Folder"].as_str().unwrap_or("Folder").to_owned(),
                                if row["CurrentExists"] == true {
                                    row["Current"].as_str().unwrap_or("Unavailable").to_owned()
                                } else {
                                    "Not set".into()
                                },
                                if row["ProposedExists"] == true {
                                    row["Proposed"].as_str().unwrap_or("Unavailable").to_owned()
                                } else {
                                    "Not set".into()
                                },
                                row["Action"].as_str().unwrap_or("Review").to_owned(),
                            ]
                        })
                        .collect();
                    self.insert_result_rows(&rows);
                    self.table_ready = true;
                    self.friendly = format!(
                        "{}\r\nRecovery file: {}\r\nA fresh backup will be created before settings change. Recovery folder: {}\r\nNo settings or files have changed.",
                        result.message,
                        report["BackupPath"].as_str().unwrap_or("Unavailable"),
                        report["RecoveryRoot"].as_str().unwrap_or("Unavailable"),
                    );
                }
            }
        } else if self
            .running_options
            .as_ref()
            .map(|o| o.action == "Check iCloud configuration")
            .unwrap_or(false)
        {
            if let Ok(report) = serde_json::from_str::<serde_json::Value>(result.text.trim()) {
                self.set_table_headers(["Folder / check", "Current location", "Matches", "Exists"]);
                unsafe {
                    SendMessageW(self.table, LVM_DELETEALLITEMS, 0, 0);
                }
                let mut rows = Vec::new();
                for (key, prefix) in [("RegistryValues", ""), ("ResolvedFolders", "Windows: ")] {
                    if let Some(values) = report[key].as_array() {
                        for row in values {
                            rows.push([
                                format!("{prefix}{}", row["Folder"].as_str().unwrap_or("Folder")),
                                row["Current"].as_str().unwrap_or("Unavailable").to_string(),
                                if row["Matches"].as_bool() == Some(true) {
                                    "Yes"
                                } else {
                                    "Needs attention"
                                }
                                .into(),
                                match row["DirectoryExists"].as_bool() {
                                    Some(true) => "Yes",
                                    Some(false) => "Missing",
                                    None => "-",
                                }
                                .into(),
                            ]);
                        }
                    }
                }
                rows.insert(
                    0,
                    [
                        "iCloud root".into(),
                        report["Root"].as_str().unwrap_or("").into(),
                        if report["RootRegistered"].as_bool() == Some(true) {
                            "Registered"
                        } else {
                            "Unverified"
                        }
                        .into(),
                        if report["RootExists"].as_bool() == Some(true) {
                            "Yes"
                        } else {
                            "Missing"
                        }
                        .into(),
                    ],
                );
                self.insert_result_rows(&rows);
                self.table_ready = true;
                self.friendly = format!(
                    "{}\r\nCloud synchronization: {}\r\n{}",
                    result.message,
                    report["CloudSync"]
                        .as_str()
                        .unwrap_or("Not verified by this configuration check."),
                    report["Errors"]
                        .as_array()
                        .map(|a| a
                            .iter()
                            .filter_map(|v| v.as_str())
                            .collect::<Vec<_>>()
                            .join("\r\n"))
                        .unwrap_or_default()
                );
            }
        }
        set_text(
            self.status_label,
            &self
                .friendly
                .lines()
                .take(if self.table_ready { 3 } else { 1 })
                .collect::<Vec<_>>()
                .join("\r\n"),
        );
        self.render();
    }

    fn set_table_headers(&self, headers: [&str; 4]) {
        for (index, title) in headers.iter().enumerate() {
            unsafe {
                let mut title = wide(title);
                let mut column: LVCOLUMNW = std::mem::zeroed();
                column.mask = LVCF_TEXT;
                column.pszText = title.as_mut_ptr();
                SendMessageW(
                    self.table,
                    LVM_SETCOLUMNW,
                    index,
                    (&column as *const LVCOLUMNW) as isize,
                );
            }
        }
    }

    fn insert_result_rows(&self, rows: &[[String; 4]]) {
        for (index, row) in rows.iter().enumerate() {
            for (column, value) in row.iter().enumerate() {
                unsafe {
                    let mut value = wide(value);
                    let mut item: LVITEMW = std::mem::zeroed();
                    item.mask = LVIF_TEXT;
                    item.iItem = index as i32;
                    item.iSubItem = column as i32;
                    item.pszText = value.as_mut_ptr();
                    SendMessageW(
                        self.table,
                        if column == 0 {
                            LVM_INSERTITEMW
                        } else {
                            LVM_SETITEMW
                        },
                        0,
                        (&item as *const LVITEMW) as isize,
                    );
                }
            }
        }
    }

    /// Validate all paths from the current UI state.
    fn validate_paths(&self) -> Result<Vec<(String, String)>, String> {
        let root = PathBuf::from(text(self.root));
        valid_path(&root)?;
        let paths = collect_paths(self);
        for (name, path_str) in &paths {
            let path = PathBuf::from(path_str);
            valid_path(&path)?;
            if same_path(&path, &root) || !within(&path, &root) {
                return Err(format!(
                    "The destination for {} must be inside the selected Drive folder.",
                    name
                ));
            }
        }
        for i in 0..paths.len() {
            for j in (i + 1)..paths.len() {
                let path_a = PathBuf::from(&paths[i].1);
                let path_b = PathBuf::from(&paths[j].1);
                let name_a = &paths[i].0;
                let name_b = &paths[j].0;
                if same_path(&path_a, &path_b) {
                    return Err(format!(
                        "Use a different destination for {} and {}.",
                        name_a, name_b
                    ));
                }
                if within(&path_a, &path_b) || within(&path_b, &path_a) {
                    let captures = (name_a == "Videos\\Captures"
                        && *name_b == "Videos"
                        && within(&path_a, &path_b))
                        || (name_b == "Videos\\Captures"
                            && *name_a == "Videos"
                            && within(&path_b, &path_a));
                    if !captures {
                        return Err("Folder destinations overlap. Choose separate folders.".into());
                    }
                }
            }
        }
        Ok(paths)
    }

    fn run_operation(&mut self, op: Operation) {
        if self.is_running {
            return;
        }
        if op == Operation::Check {
            unsafe {
                SendMessageW(self.action, CB_SETCURSEL, 5, 0);
            }
            self.refresh();
            self.reviewed = None;
        }
        let options = match self.snapshot() {
            Ok(v) => v,
            Err(e) => {
                set_text(self.status, &e);
                return;
            }
        };
        let phase = match op {
            Operation::Apply => "Apply",
            Operation::DryRun => "DryRun",
            _ => "Preview",
        };
        if phase == "Preview" && options.copy() {
            self.reset_copy_review();
            self.copy_page_offsets.push(0);
        }
        if op == Operation::Apply {
            if self.reviewed.as_ref() != Some(&options) {
                set_text(
                    self.status,
                    "Preview required. Options changed; review the plan again before applying.",
                );
                return;
            }
            match confirm(self.window, &options) {
                Ok(true) => {}
                Ok(false) => return,
                Err(e) => {
                    set_text(self.status, &e);
                    return;
                }
            }
        }
        self.start(options, phase, 0);
    }
    fn change_copy_page(&mut self, next: bool) {
        if self.is_running {
            return;
        }
        let options = match self.snapshot() {
            Ok(options) => options,
            Err(error) => {
                set_text(self.status, &error);
                return;
            }
        };
        if !options.copy()
            || self.copy_reviewed.as_ref() != Some(&options)
            || self.copy_review_token.is_none()
        {
            self.invalidate();
            return;
        }
        let offset = if next {
            let Some(offset) = self.copy_page_next_offset else {
                return;
            };
            if self.copy_page_offsets.last().copied() == Some(offset) {
                return;
            }
            self.copy_page_offsets.push(offset);
            offset
        } else {
            if self.copy_page_offsets.len() <= 1 {
                return;
            }
            self.copy_page_offsets.pop();
            *self.copy_page_offsets.last().unwrap_or(&0)
        };
        self.start(options, "CopyPage", offset);
    }
    fn start(&mut self, options: Options, phase: &str, copy_page_offset: usize) {
        let review_token = if phase == "Apply" {
            self.review_token.take()
        } else {
            None
        };
        if phase == "CopyPage" {
            self.copy_page_expected_token = self.copy_review_token.clone();
        } else if phase == "Preview" && options.copy() {
            self.copy_page_expected_token = None;
        } else {
            self.copy_page_expected_token = None;
            self.reset_copy_review();
        }
        if phase != "CopyPage" {
            self.reviewed = None;
            self.review_token = None;
        }
        self.table_ready = false;
        self.running_options = Some(options.clone());
        self.running_phase = phase.into();
        let (send, receive) = mpsc::sync_channel(64);
        self.stop = Arc::new(AtomicBool::new(false));
        let stop = self.stop.clone();
        let phase = phase.to_string();
        match thread::Builder::new()
            .name("folder-operation".into())
            .spawn(move || {
                let result = operation(
                    options,
                    phase,
                    review_token,
                    copy_page_offset,
                    stop,
                    send.clone(),
                );
                let _ = send.send(WorkerMessage::Finished(result));
            }) {
            Ok(_) => {
                self.result = Some(receive);
                self.is_running = true;
                self.set_buttons_enabled(false);
                self.layout();
                set_text(
                    self.status_label,
                    "Working. Folder changes cannot be interrupted; copying can stop safely after the current file.",
                );
                set_text(self.status, "");
                unsafe {
                    SetTimer(self.window, 1, 50, None);
                }
            }
            Err(e) => {
                set_text(self.status, &format!("Could not start the operation: {e}"));
                self.set_buttons_enabled(true);
            }
        }
    }
    fn poll(&mut self) {
        loop {
            let message=match &self.result{Some(receive)=>match receive.try_recv(){Ok(v)=>v,Err(mpsc::TryRecvError::Empty)=>return,Err(_)=>WorkerMessage::Finished(Err("The worker stopped unexpectedly. Review recovery records before retrying changes.".into()))},None=>return};
            match message {
                WorkerMessage::Progress(v) => {
                    let total = v["Total"].as_u64().unwrap_or(0);
                    let done = v["Completed"].as_u64().unwrap_or(0);
                    let stage = v["Stage"].as_str().unwrap_or("Working");
                    let file = v["File"].as_str().unwrap_or("");
                    if stage == "Reviewing copy plan" {
                        set_text(
                            self.status_label,
                            &format!("Reviewing copy plan: {done} entries checked\r\n{file}"),
                        );
                    } else {
                        set_text(
                            self.status_label,
                            &format!("{stage}: {done} of {total} files verified\r\n{file}"),
                        );
                    }
                    if total > 0 {
                        unsafe {
                            SendMessageW(self.progress, PBM_SETMARQUEE, 0, 0);
                            SendMessageW(
                                self.progress,
                                PBM_SETRANGE32,
                                0,
                                total.min(i32::MAX as u64) as isize,
                            );
                            SendMessageW(
                                self.progress,
                                PBM_SETPOS,
                                done.min(i32::MAX as u64) as usize,
                                0,
                            );
                        }
                    }
                }
                WorkerMessage::Finished(result) => {
                    self.result = None;
                    self.is_running = false;
                    match result {
                        Ok(result) => {
                            if self.running_phase == "CopyPage" {
                                let current_token =
                                    serde_json::from_str::<serde_json::Value>(result.text.trim())
                                        .ok()
                                        .and_then(|report| {
                                            report["ApprovalToken"].as_str().map(str::to_owned)
                                        });
                                if current_token != self.copy_page_expected_token {
                                    self.reset_copy_review();
                                    self.reviewed = None;
                                    self.review_token = None;
                                    self.raw.clear();
                                    self.friendly = "The copy plan changed while loading this page. Preview again before applying.".into();
                                    set_text(self.status_label, &self.friendly);
                                    self.render();
                                    self.running_options = None;
                                    self.set_buttons_enabled(true);
                                    unsafe {
                                        KillTimer(self.window, 1);
                                        SetFocus(self.preview);
                                    }
                                    return;
                                }
                            }
                            if result.exit_code == 0
                                && self.running_phase != "Apply"
                                && self
                                    .running_options
                                    .as_ref()
                                    .map(|o| o.mutates())
                                    .unwrap_or(false)
                            {
                                self.reviewed = self.running_options.clone();
                                self.review_token =
                                    serde_json::from_str::<serde_json::Value>(result.text.trim())
                                        .ok()
                                        .and_then(|report| {
                                            report["ApprovalToken"].as_str().map(str::to_owned)
                                        });
                            }
                            self.show_report(&result);
                        }
                        Err(e) => {
                            if self.running_phase == "CopyPage" {
                                self.reset_copy_review();
                                self.reviewed = None;
                                self.review_token = None;
                            }
                            self.raw = e.clone();
                            self.friendly = e.clone();
                            set_text(
                                self.status_label,
                                "Action needs attention. Review details before retrying.",
                            );
                            self.render();
                        }
                    }
                    self.running_options = None;
                    self.set_buttons_enabled(true);
                    self.layout();
                    unsafe {
                        KillTimer(self.window, 1);
                        SetFocus(self.preview);
                    }
                    return;
                }
            }
        }
    }
    fn set_buttons_enabled(&self, enabled: bool) {
        for window in [
            self.preview,
            self.dry,
            self.check,
            self.close,
            self.root,
            self.music,
            self.advanced,
            self.action,
            self.backup,
            self.verified,
            self.keep,
            self.save,
            self.recovery,
            self.help,
            self.install,
            self.desktop_shortcut,
            self.previous_page,
            self.next_page,
            self.browse_root,
            self.browse_backup,
        ] {
            enable(window, enabled);
        }
        for row in &self.rows {
            enable(row.editor, enabled);
            enable(row.browse, enabled);
        }
        enable(
            self.apply,
            enabled
                && self.snapshot().ok().as_ref() == self.reviewed.as_ref()
                && self.reviewed.is_some(),
        );
        enable(
            self.previous_page,
            enabled && self.copy_page_offsets.len() > 1 && self.copy_review_token.is_some(),
        );
        enable(
            self.next_page,
            enabled && self.copy_page_next_offset.is_some() && self.copy_review_token.is_some(),
        );
        enable(self.cancel_btn, !enabled);
    }
    fn browse(&mut self, id: usize) {
        let (folder, save, title) = match id {
            BROWSE_ROOT => (true, false, "Choose your existing iCloud Drive folder"),
            BROWSE_BACKUP => (false, false, "Choose a trusted recovery backup"),
            SAVE => (false, true, "Save folder setup result"),
            _ => (true, false, "Choose a folder destination"),
        };
        match picker(self.window, folder, save, title) {
            Ok(Some(path)) => {
                if id == SAVE {
                    match std::fs::write(
                        &path,
                        if checked(self.technical) {
                            &self.raw
                        } else {
                            &self.friendly
                        },
                    ) {
                        Ok(_) => set_text(self.status_label, &format!("Result saved: {path}")),
                        Err(e) => {
                            set_text(self.status_label, &format!("Could not save result: {e}"))
                        }
                    };
                    return;
                }
                let target = match id {
                    BROWSE_ROOT => self.root,
                    BROWSE_BACKUP => self.backup,
                    _ => match self.rows.get(id - 300) {
                        Some(row) => row.editor,
                        None => return,
                    },
                };
                set_text(target, &path);
                if id == BROWSE_ROOT {
                    self.refresh();
                }
                self.invalidate();
            }
            Ok(None) => {}
            Err(e) => set_text(
                self.status_label,
                &format!("Could not open the picker: {e}"),
            ),
        }
    }
    fn open_location(&self, path: &std::ffi::OsStr) {
        unsafe {
            let value: Vec<u16> = std::os::windows::ffi::OsStrExt::encode_wide(path)
                .chain(Some(0))
                .collect();
            let result = windows_sys::Win32::UI::Shell::ShellExecuteW(
                self.window,
                wide("open").as_ptr(),
                value.as_ptr(),
                null_mut(),
                null_mut(),
                SW_SHOWNORMAL,
            );
            if result as usize <= 32 {
                set_text(
                    self.status_label,
                    "Windows could not open this location. Check that it exists.",
                );
            }
        }
    }
}
fn valid_path(path: &Path) -> Result<(), String> {
    if !path.is_absolute()
        || path.to_str().is_none()
        || path.as_os_str().len() > 32000
        || path.components().any(|c| match c {
            Component::ParentDir => true,
            Component::Normal(s) => s.to_str().is_none_or(|s| {
                s.contains([':', '\0', '*', '?', '"', '<', '>', '|']) || s.ends_with(['.', ' '])
            }),
            _ => false,
        })
    {
        Err("Enter an absolute folder path without parent components, then review again.".into())
    } else {
        Ok(())
    }
}
fn ordinal(a: &std::ffi::OsStr, b: &std::ffi::OsStr) -> bool {
    // Case-insensitive path component comparison without allocation.
    // Windows paths are case-insensitive, so we compare lowercased strings.
    // For ASCII paths (the common case), this avoids any heap allocation.
    let a_bytes = a.as_encoded_bytes();
    let b_bytes = b.as_encoded_bytes();
    if a_bytes.len() != b_bytes.len() {
        return false;
    }
    // UTF-16 le lowercase: for BMP chars, just flip the ASCII bit for A-Z.
    // For non-BMP or non-ASCII, we need char-level lowering.
    // Since path components are short, decode to chars, lowercase, and compare.
    let a_str = a.to_string_lossy();
    let b_str = b.to_string_lossy();
    a_str.to_lowercase() == b_str.to_lowercase()
}
fn same_path(a: &Path, b: &Path) -> bool {
    a.components().count() == b.components().count() && within(a, b)
}
fn within(path: &Path, root: &Path) -> bool {
    if path.components().count() < root.components().count() {
        return false;
    }
    path.components()
        .zip(root.components())
        .all(|(a, b)| ordinal(a.as_os_str(), b.as_os_str()))
}

unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if message == WM_DESTROY {
        STATE.with(|slot| {
            if let Ok(mut slot) = slot.try_borrow_mut() {
                if let Some(state) = slot.as_mut() {
                    state.accessibility.clear();
                }
            }
        });
        unsafe { PostQuitMessage(0) };
        return 0;
    }
    if message == WM_NCDESTROY {
        STATE.with(|state| {
            if let Ok(mut state) = state.try_borrow_mut() {
                state.take();
            }
        });
    }
    // Handle WM_CTLCOLOR* messages — they need to return HBRUSH as LRESULT
    if message == WM_ERASEBKGND {
        let erased = STATE.with(|s| {
            s.try_borrow().ok().and_then(|st| {
                st.as_ref().map(|state| unsafe {
                    let mut rect: RECT = std::mem::zeroed();
                    GetClientRect(window, &mut rect);
                    FillRect(wparam as HDC, &rect, state.background_brush);
                })
            })
        });
        if erased.is_some() {
            return 1;
        }
    }
    if matches!(
        message,
        WM_CTLCOLORSTATIC | WM_CTLCOLORBTN | WM_CTLCOLOREDIT | WM_CTLCOLORLISTBOX | WM_CTLCOLORDLG
    ) {
        let colors = STATE.with(|s| {
            s.try_borrow().ok().and_then(|st| {
                st.as_ref()
                    .map(|state| state.control_colors(message, lparam as HWND))
            })
        });
        if let Some((brush, text, background, mode)) = colors {
            if !brush.is_null() {
                unsafe {
                    SetTextColor(wparam as HDC, text);
                    SetBkColor(wparam as HDC, background);
                    SetBkMode(wparam as HDC, mode);
                }
                return brush as LRESULT;
            }
        }
        return unsafe { DefWindowProcW(window, message, wparam, lparam) };
    }
    let handled = STATE.with(|slot| {
        let Ok(mut slot) = slot.try_borrow_mut() else {
            return false;
        };
        let Some(state) = slot.as_mut() else {
            return false;
        };
        match message {
            WM_SIZE => {
                state.layout();
                true
            }
            WM_GETMINMAXINFO => {
                if lparam != 0 {
                    unsafe {
                        let mut window_rect: RECT = std::mem::zeroed();
                        let mut client_rect: RECT = std::mem::zeroed();
                        GetWindowRect(window, &mut window_rect);
                        GetClientRect(window, &mut client_rect);
                        let frame_width = ((window_rect.right - window_rect.left)
                            - (client_rect.right - client_rect.left))
                            .max(0);
                        let frame_height = ((window_rect.bottom - window_rect.top)
                            - (client_rect.bottom - client_rect.top))
                            .max(0);
                        let info = &mut *(lparam as *mut MINMAXINFO);
                        info.ptMinTrackSize = POINT {
                            x: scaled(800, state.dpi) + frame_width,
                            y: scaled(470, state.dpi) + frame_height,
                        };
                    }
                }
                true
            }

            WM_COMMAND=>{
                let id=wparam&0xffff;let event=(wparam>>16) as u32;
                if state.is_running&&id!=CANCEL{return true;}
                if id==CANCEL {
                    if state.is_running{state.stop.store(true,Ordering::Relaxed);enable(state.cancel_btn,false);set_text(state.status_label,"Stop requested. Waiting for the current file and verification to finish.");}
                }else if id==CLOSE{unsafe{PostMessageW(window,WM_CLOSE,0,0);}}
                else if id==ACTION&&event==CBN_SELCHANGE{state.refresh();state.invalidate();}
                else if event==BN_CLICKED{
                    match id{
                        PREVIEW=>state.run_operation(Operation::Preview),APPLY=>state.run_operation(Operation::Apply),CHECK=>state.run_operation(Operation::Check),DRY=>state.run_operation(Operation::DryRun),
                        PREVIOUS_PAGE=>state.change_copy_page(false),NEXT_PAGE=>state.change_copy_page(true),
                        MUSIC|ADVANCED|VERIFIED|KEEP|DESKTOP_SHORTCUT=>{state.refresh();state.invalidate();},
                        TECHNICAL=>state.render(),
                        BROWSE_ROOT|BROWSE_BACKUP|SAVE=>state.browse(id),
                        300..=315=>{if checked(state.advanced){state.browse(id);}},
                        RECOVERY=>{if let Some(local)=std::env::var_os("LOCALAPPDATA"){state.open_location(PathBuf::from(local).join("ICloudFolderSettler/Recovery").as_os_str());}},
                        HELP=>{if let Some(root)=SOURCE.get(){state.open_location(root.join("README.md").as_os_str());}},
                        INSTALL=>{
                            if let Ok(mut options)=state.snapshot(){options.action="Install for me".into();options.folder_paths.clear();
                                match confirm(state.window,&options){Ok(true)=>state.start(options,"Apply",0),Ok(false)=>{},Err(e)=>set_text(state.status_label,&e)}
                            }
                        }
                        _=>{}
                    }
                }else if (id==ROOT||id==BACKUP||(200..216).contains(&id))&&event==EN_CHANGE{
                    if id==ROOT{state.refresh();}state.invalidate();
                }
                true
            }
            WM_TIMER => {
                state.poll();
                true
            }
            WM_CLOSE => state.is_running,
            WM_DPICHANGED => {
                state.dpi = state
                    .fixture_dpi
                    .unwrap_or((wparam & 0xffff) as u32)
                    .max(96);
                if let Err(error) = state.fonts() {
                    set_text(state.status, &error);
                }
                if lparam != 0 {
                    unsafe {
                        let rect = &*(lparam as *const RECT);
                        SetWindowPos(
                            window,
                            null_mut(),
                            rect.left,
                            rect.top,
                            rect.right - rect.left,
                            rect.bottom - rect.top,
                            SWP_NOZORDER | SWP_NOACTIVATE,
                        );
                    }
                }
                state.layout();
                true
            }
            WM_SETTINGCHANGE | WM_THEMECHANGED | WM_SYSCOLORCHANGE => {
                if let Err(error) = state.fonts() {
                    set_text(state.status, &error);
                }
                if let Err(error) = state.refresh_theme() {
                    set_text(state.status, &error);
                }
                true
            }
            _ => false,
        }
    });
    if handled {
        0
    } else {
        unsafe { DefWindowProcW(window, message, wparam, lparam) }
    }
}
fn run() -> Result<(), String> {
    let _apartment = Apartment::new()?;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut fixture_dpi = None;
    let mut fixture_dark = None;
    let mut mode = "Setup";
    let mut explicit_source = None;
    for pair in args.chunks(2) {
        if pair.len() != 2 {
            return Err("A startup option is missing its value.".into());
        }
        match pair[0].as_str() {
            "--mode" if ["Setup", "Reset", "Check", "Install"].contains(&pair[1].as_str()) => {
                mode = &pair[1]
            }
            "--source" => explicit_source = Some(PathBuf::from(&pair[1])),
            "--fixture-dpi" if std::env::var("ICLOUD_TEST_DESKTOP").is_ok() => {
                let dpi = pair[1].parse::<u32>().map_err(|e| e.to_string())?;
                if ![96, 144, 192].contains(&dpi) {
                    return Err("Unsupported fixture DPI.".into());
                }
                fixture_dpi = Some(dpi);
            }
            "--fixture-theme" if std::env::var("ICLOUD_TEST_DESKTOP").is_ok() => {
                fixture_dark = Some(match pair[1].as_str() {
                    "dark" => true,
                    "light" => false,
                    _ => return Err("Unsupported fixture theme.".into()),
                });
            }
            _ => return Err("Unsupported UI argument.".into()),
        }
    }
    let source = explicit_source
        .or_else(|| std::env::var_os("ICLOUD_SCRIPT_ROOT").map(PathBuf::from))
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|p| p.parent()?.parent().map(Path::to_path_buf))
        })
        .ok_or("Application directory unavailable.")?;
    if !source.is_absolute() || !source.join("tools/Invoke-WinUIBridge.ps1").is_file() {
        return Err("The application backend is missing. Extract the complete package or use Start-ICloudRustUI.ps1.".into());
    }
    SOURCE
        .set(source)
        .map_err(|_| "Application source initialized twice.")?;
    initialize_theme_support();
    unsafe {
        let controls = INITCOMMONCONTROLSEX {
            dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_LISTVIEW_CLASSES | ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES,
        };
        InitCommonControlsEx(&controls);
        let instance = GetModuleHandleW(null_mut());
        let class = wide("ICloudRustPreview");
        let mut wc: WNDCLASSW = std::mem::zeroed();
        wc.lpfnWndProc = Some(window_proc);
        wc.hInstance = instance;
        wc.lpszClassName = class.as_ptr();
        wc.hCursor = LoadCursorW(null_mut(), IDC_ARROW);
        wc.hbrBackground = null_mut();
        if RegisterClassW(&wc) == 0 {
            return Err("Windows could not register the preview window.".into());
        }
        let dpi = fixture_dpi.unwrap_or(GetDpiForSystem());
        let mut work: RECT = std::mem::zeroed();
        SystemParametersInfoW(SPI_GETWORKAREA, 0, (&mut work as *mut RECT).cast(), 0);
        let window = CreateWindowExW(
            WS_EX_CONTROLPARENT,
            class.as_ptr(),
            wide("iCloud folder setup - Rust development build").as_ptr(),
            WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            scaled(1000, dpi).min((work.right - work.left).max(640)),
            scaled(780, dpi).min((work.bottom - work.top).max(480)),
            null_mut(),
            null_mut(),
            instance,
            null_mut(),
        );
        if window.is_null() {
            return Err("Windows could not create the preview window.".into());
        }
        let mut state = match State::create(window, fixture_dpi, fixture_dark) {
            Ok(state) => state,
            Err(error) => {
                DestroyWindow(window);
                return Err(error);
            }
        };
        let index = match mode {
            "Reset" => 1,
            "Check" => 5,
            _ => 0,
        };
        SendMessageW(state.action, CB_SETCURSEL, index, 0);
        state.refresh();
        state.layout();
        let root = state.root;
        STATE.with(|slot| *slot.borrow_mut() = Some(state));
        ShowWindow(window, SW_SHOW);
        UpdateWindow(window);
        SetFocus(root);
        if mode == "Install" {
            PostMessageW(window, WM_COMMAND, INSTALL, 0);
        }
        let mut message: MSG = std::mem::zeroed();
        loop {
            let status = GetMessageW(&mut message, null_mut(), 0, 0);
            if status == 0 {
                break;
            }
            if status < 0 {
                return Err("Windows stopped delivering interface messages.".into());
            }
            if IsDialogMessageW(window, &message) == 0 {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
    }
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        unsafe {
            MessageBoxW(
                null_mut(),
                wide(&error).as_ptr(),
                wide("iCloud folder setup could not start").as_ptr(),
                MB_OK | MB_ICONERROR,
            );
        }
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn request_validation_and_encoding_is_exact() {
        for (input, expected) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("\u{e9}", "w6k="),
        ] {
            assert_eq!(base64(input.as_bytes()), expected);
        }

        let options = Options {
            action: ACTIONS[0].into(),
            root: "C:\\Drive".into(),
            backup: String::new(),
            music: false,
            verified: false,
            keep_files: false,
            json: false,
            desktop_shortcut: false,
            folder_paths: Default::default(),
        };
        assert!(request(&options, "Preview", None).is_ok());
        assert!(request(&options, "Bogus", None).is_err());
        let mut large = options.clone();
        large.root = "x".repeat(16001);
        assert!(request(&large, "Preview", None).is_err());

        assert!(same_path(Path::new("C:\\É"), Path::new("c:\\é")));
    }
    #[test]
    fn setup_preview_request_preserves_user_acknowledgements_and_custom_paths() {
        let mut options = Options {
            action: ACTIONS[0].into(),
            root: "C:\\Drive".into(),
            backup: String::new(),
            music: true,
            verified: true,
            keep_files: true,
            json: false,
            desktop_shortcut: false,
            folder_paths: Default::default(),
        };
        options
            .folder_paths
            .insert("Desktop".into(), "C:\\Drive\\Work Desktop".into());
        let request = setup_preview_request(&options);
        assert_eq!(request["operation"], "setup_preview");
        assert_eq!(request["include_music"], true);
        assert_eq!(request["verified_sync_root"], true);
        assert_eq!(request["allow_existing_content"], true);
        assert_eq!(
            request["folder_paths"]["Desktop"],
            "C:\\Drive\\Work Desktop"
        );
    }
    #[test]
    fn reset_preview_and_apply_are_bound_to_review_token() {
        let options = Options {
            action: "Reset to Windows defaults".into(),
            root: String::new(),
            backup: String::new(),
            music: false,
            verified: false,
            keep_files: true,
            json: false,
            desktop_shortcut: false,
            folder_paths: Default::default(),
        };
        let preview_request = reset_preview_request(&options);
        assert_eq!(preview_request["operation"], "reset_preview");
        assert_eq!(preview_request["allow_existing_content"], true);

        let token = "C".repeat(64);
        let preview = serde_json::json!({
            "operation":"reset",
            "review_gates_passed":true,
            "recovery_root":"C:\\Users\\Test\\AppData\\Local\\ICloudFolderSettler\\Recovery",
            "content_warnings":[],
            "rows":[{"folder":"Desktop","current":"D:\\Desktop","proposed":"C:\\Users\\Test\\Desktop","action":"Update value"}]
        });
        let result = reset_preview_result(&preview, &token).unwrap();
        let report: serde_json::Value = serde_json::from_str(&result.text).unwrap();
        assert_eq!(report["ApprovalToken"], token);
        assert_eq!(report["Operation"], "reset");
        assert_eq!(report["ReviewGatesPassed"], true);
        assert_eq!(report["Rows"][0]["Proposed"], "C:\\Users\\Test\\Desktop");

        let mut blocked_preview = preview.clone();
        blocked_preview["review_gates_passed"] = false.into();
        blocked_preview["content_warnings"] = serde_json::json!(["Existing content needs review."]);
        let blocked = reset_preview_result(&blocked_preview, &token).unwrap();
        assert_eq!(blocked.exit_code, 3);
        assert!(blocked.message.contains("Apply remains unavailable"));
        let blocked_report: serde_json::Value = serde_json::from_str(&blocked.text).unwrap();
        assert_eq!(blocked_report["ReviewGatesPassed"], false);

        let apply = reset_apply_request(&options, &token);
        assert_eq!(apply["operation"], "reset_apply");
        assert_eq!(apply["confirmed"], true);
        assert_eq!(apply["preview_token"], token);
        assert!(reset_preview_result(&serde_json::json!({"operation":"setup"}), &token).is_err());
    }

    #[test]
    fn copy_cancel_event_name_matches_power_shell_contract() {
        let name = copy_cancel_event_name(123, 456);
        let suffix = name.strip_prefix("Local\\ICloudCopy-").unwrap();
        assert_eq!(suffix.len(), 32);
        assert!(
            suffix
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        );
    }

    #[test]
    fn copy_preview_and_apply_requests_bind_target_options_and_review() {
        let mut options = Options {
            action: ACTIONS[3].into(),
            root: "C:\\Drive".into(),
            backup: String::new(),
            music: true,
            verified: true,
            keep_files: false,
            json: false,
            desktop_shortcut: false,
            folder_paths: Default::default(),
        };
        options
            .folder_paths
            .insert("Desktop".into(), "C:\\Drive\\Work Desktop".into());
        let preview = copy_preview_request(&options, 7);
        assert_eq!(preview["operation"], "copy_preview_page");
        assert_eq!(preview["page_offset"], 7);
        assert_eq!(preview["reset_to_defaults"], false);
        assert_eq!(preview["include_music"], true);
        assert_eq!(preview["verified_sync_root"], true);
        assert_eq!(
            preview["folder_paths"]["Desktop"],
            "C:\\Drive\\Work Desktop"
        );

        let token = "A".repeat(64);
        let apply = copy_apply_request(
            &options,
            &token,
            "Local\\ICloudCopy-0123456789abcdef0123456789abcdef",
        );
        assert_eq!(apply["operation"], "copy_apply");
        assert_eq!(apply["confirmed"], true);
        assert_eq!(apply["preview_token"], token);
        assert_eq!(
            apply["cancellation_event"],
            "Local\\ICloudCopy-0123456789abcdef0123456789abcdef"
        );

        options.action = ACTIONS[4].into();
        let defaults = copy_preview_request(&options, 0);
        assert_eq!(defaults["reset_to_defaults"], true);
        assert_eq!(defaults["include_music"], true);
        assert_eq!(defaults["folder_paths"], serde_json::json!({}));
    }

    #[test]
    fn copy_preview_report_retains_rows_and_blocks_unverified_roots() {
        let preview = serde_json::json!({
            "operation":"copy_to_icloud",
            "root":"C:\\Drive",
            "root_registered":false,
            "registered_roots":[],
            "review_gates_passed":false,
            "reset_to_defaults":false,
            "page_offset":0,
            "next_offset":null,
            "total_entries":1,
            "entries":[{"directory":false,"source":"C:\\Users\\Test\\Desktop\\a.txt","destination":"C:\\Drive\\Desktop\\a.txt","action":"Copy"}]
        });
        let result = copy_preview_result(&preview, &"B".repeat(64)).unwrap();
        let report: serde_json::Value = serde_json::from_str(&result.text).unwrap();
        assert_eq!(result.exit_code, 3);
        assert_eq!(report["ReviewGatesPassed"], false);
        assert_eq!(report["Rows"].as_array().unwrap().len(), 1);
        assert_eq!(report["Rows"][0]["Type"], "File");
        assert_eq!(report["Rows"][0]["Action"], "Copy");
        assert_eq!(report["PageOffset"], 0);
        assert_eq!(report["TotalEntries"], 1);
        assert_eq!(report["NextOffset"], serde_json::Value::Null);
    }

    #[test]
    fn copy_preview_page_rejects_inconsistent_paging_metadata() {
        let token = "B".repeat(64);
        let preview = serde_json::json!({
            "operation":"copy_to_icloud",
            "root":"C:\\Drive",
            "root_registered":true,
            "registered_roots":["C:\\Drive"],
            "review_gates_passed":true,
            "reset_to_defaults":false,
            "page_offset":4,
            "next_offset":9,
            "total_entries":10,
            "entries":[{"directory":false,"source":"C:\\a","destination":"C:\\b","action":"Copy"}]
        });
        assert!(copy_preview_result(&preview, &token).is_err());
        let mut valid = preview;
        valid["next_offset"] = 5.into();
        assert_eq!(copy_preview_result(&valid, &token).unwrap().exit_code, 0);
    }

    #[test]
    fn setup_preview_retains_rows_and_never_passes_failed_review_gates() {
        let mut preview = serde_json::json!({
            "root":"C:\\Drive",
            "root_registered":false,
            "verified_sync_root":false,
            "review_gates_passed":false,
            "recovery_root":"C:\\Users\\Test\\AppData\\Local\\ICloudFolderSettler\\Recovery",
            "rows":[{"folder":"Desktop","current":null,"proposed":"C:\\Drive\\Desktop","action":"Add missing value"}],
            "content_warnings":["Existing content needs review."]
        });
        let token = "A".repeat(64);
        let blocked = setup_preview_result(&preview, &token).unwrap();
        assert_eq!(blocked.exit_code, 3);
        assert!(blocked.message.contains("Apply remains unavailable"));
        let report: serde_json::Value = serde_json::from_str(&blocked.text).unwrap();
        assert_eq!(report["ApprovalToken"], token);
        assert_eq!(report["Rows"][0]["Current"], serde_json::Value::Null);
        assert_eq!(report["Rows"][0]["Proposed"], "C:\\Drive\\Desktop");
        assert_eq!(
            report["ContentWarnings"][0],
            "Existing content needs review."
        );

        preview["review_gates_passed"] = true.into();
        preview["content_warnings"] = serde_json::json!([]);
        let accepted = setup_preview_result(&preview, &token).unwrap();
        assert_eq!(accepted.exit_code, 0);
        assert!(accepted.message.contains("Setup preview is ready"));
        let apply = setup_apply_request(
            &Options {
                action: ACTIONS[0].into(),
                root: "C:\\Drive".into(),
                backup: String::new(),
                music: true,
                verified: true,
                keep_files: true,
                json: false,
                desktop_shortcut: false,
                folder_paths: Default::default(),
            },
            &token,
        );
        assert_eq!(apply["operation"], "setup_apply");
        assert_eq!(apply["confirmed"], true);
        assert_eq!(apply["preview_token"], token);

        preview["rows"] = serde_json::json!([]);
        assert!(setup_preview_result(&preview, &token).is_err());
    }
    #[test]
    fn restore_preview_request_preserves_selected_backup_path() {
        let options = Options {
            action: ACTIONS[2].into(),
            root: String::new(),
            backup: " C:\\Users\\Test\\Recovery Files\\before !.json ".into(),
            music: false,
            verified: false,
            keep_files: false,
            json: false,
            desktop_shortcut: false,
            folder_paths: Default::default(),
        };
        let request = restore_preview_request(&options).unwrap();
        assert_eq!(request["operation"], "restore_preview_file");
        assert_eq!(request["path"], options.backup);

        let mut missing = options;
        missing.backup.clear();
        assert!(restore_preview_request(&missing).is_err());
    }
    #[test]
    fn restore_preview_keeps_exact_values_and_rejects_inconsistent_absence() {
        let mut preview = serde_json::json!({
            "operation":"restore",
            "recovery_root":"C:\\Users\\Test\\AppData\\Local\\ICloudFolderSettler\\Recovery",
            "rows":[
                {"folder":"Documents","current_exists":true,"current_kind":"ExpandString","current":"%USERPROFILE%\\Documents","proposed_exists":true,"proposed_kind":"String","proposed":"D:\\Archive\\Documents","action":"Update value"},
                {"folder":"Downloads","current_exists":true,"current_kind":"ExpandString","current":"%USERPROFILE%\\Downloads","proposed_exists":false,"proposed_kind":null,"proposed":null,"action":"Remove value"}
            ]
        });
        let token = "B".repeat(64);
        let result = restore_preview_result(&preview, "C:\\Recovery\\before.json", &token).unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(result.message.contains("Review every proposed location"));
        let report: serde_json::Value = serde_json::from_str(&result.text).unwrap();
        assert_eq!(report["ApprovalToken"], token);
        assert_eq!(report["BackupPath"], "C:\\Recovery\\before.json");
        assert_eq!(report["Rows"][0]["Current"], "%USERPROFILE%\\Documents");
        assert_eq!(report["Rows"][0]["ProposedKind"], "String");
        assert_eq!(report["Rows"][1]["ProposedExists"], false);
        assert_eq!(report["Rows"][1]["Proposed"], serde_json::Value::Null);
        assert_eq!(report["Rows"][1]["Action"], "Remove value");

        let restore = restore_apply_request(
            &Options {
                action: ACTIONS[2].into(),
                root: String::new(),
                backup: "C:\\Recovery\\before.json".into(),
                music: false,
                verified: false,
                keep_files: false,
                json: false,
                desktop_shortcut: false,
                folder_paths: Default::default(),
            },
            &token,
        )
        .unwrap();
        assert_eq!(restore["operation"], "restore_apply");
        assert_eq!(restore["confirmed"], true);
        assert_eq!(restore["preview_token"], token);

        preview["rows"][1]["proposed_exists"] = true.into();
        assert!(restore_preview_result(&preview, "C:\\Recovery\\before.json", &token).is_err());
        preview["operation"] = "setup".into();
        assert!(restore_preview_result(&preview, "C:\\Recovery\\before.json", &token).is_err());
    }
    #[test]
    fn output_is_bounded_but_drained() {
        let mut data = vec![b'x'; OUTPUT_LIMIT + 20000];
        data.extend_from_slice(b"\nRecovery backup: C:\\fixture\\before.json");
        let (captured, overflow) = drain(data.as_slice()).unwrap();
        assert_eq!(captured.as_bytes().len(), OUTPUT_LIMIT);
        assert_eq!(captured.total_bytes, data.len() as u64);
        assert!(overflow);
        assert!(captured.summary(8192).contains("C:\\fixture\\before.json"));
    }
    #[test]
    fn bounded_output_preserves_small_text_and_terminal_tail() {
        let mut small = BoundedOutput::default();
        small.push(b"short output");
        assert_eq!(small.as_bytes(), b"short output");

        let mut input = vec![b'x'; OUTPUT_LIMIT + 10000];
        input.push(b'\n');
        input.extend_from_slice(b"@@ICloudResult:{\"type\":\"result\",\"message\":\"done\"}\n");
        let (sender, _receiver) = mpsc::sync_channel(1);
        let (captured, overflow) = read_output(input.as_slice(), sender).unwrap();
        let summary = captured.summary(8192);
        assert!(overflow);
        assert!(summary.contains("@@ICloudResult:"));
        assert!(summary.contains("done"));
        assert!(summary.len() <= 8192);
    }
    #[test]
    fn overflow_diagnostic_keeps_stdout_and_recovery_tails_bounded() {
        let mut output = BoundedOutput::default();
        output.push(&vec![b'x'; OUTPUT_LIMIT + 100]);
        output.push(b"\nTerminal result retained");
        let mut errors = BoundedOutput::default();
        errors.push(&vec![b'e'; OUTPUT_LIMIT + 100]);
        errors.push(b"\nRecovery backup: C:\\fixture\\before.json");

        let message = overflow_diagnostic(&output, &errors);
        assert!(message.len() <= OVERFLOW_DIAGNOSTIC_LIMIT);
        assert!(message.contains("Terminal result retained"));
        assert!(message.contains("C:\\fixture\\before.json"));
    }
    #[test]
    fn generated_definitions_are_unique() {
        let rows = definitions().unwrap();
        let unique: BTreeSet<_> = rows.iter().map(|r| &r.relative_path).collect();
        assert_eq!(rows.len(), unique.len());
        assert!(rows.len() <= 16);
        assert!(rows.iter().any(|r| r.optional));
    }
    #[test]
    fn scaling_and_path_validation() {
        assert_eq!(scaled(20, 144), 30);
        assert_eq!(scaled(20, 192), 40);
        assert!(valid_path(Path::new("C:\\Drive\\Desktop")).is_ok());
        assert!(valid_path(Path::new("relative")).is_err());
        assert!(valid_path(Path::new("C:\\Drive\\..\\Desktop")).is_err());
    }
}
