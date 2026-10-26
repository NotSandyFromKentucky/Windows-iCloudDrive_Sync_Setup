//! Opt-in migration worker. Write operations remain gated until their preview and recovery checks pass.
#![cfg(windows)]
use serde::{Deserialize, Deserializer, Serialize, de};
use std::{
    cmp::Ordering,
    collections::{BTreeMap, BTreeSet, VecDeque},
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::windows::fs::{MetadataExt, OpenOptionsExt},
    path::{Component, Path, PathBuf, Prefix},
    slice,
};
use windows_sys::Win32::{
    Foundation::{
        CloseHandle, ERROR_ALREADY_EXISTS, ERROR_FILE_NOT_FOUND, ERROR_MORE_DATA,
        ERROR_NO_MORE_ITEMS, ERROR_SUCCESS, GetLastError, HANDLE, HLOCAL, INVALID_HANDLE_VALUE,
        LocalFree, SYSTEMTIME, WAIT_ABANDONED, WAIT_FAILED, WAIT_OBJECT_0, WAIT_TIMEOUT,
    },
    Globalization::CompareStringOrdinal,
    Security::Authorization::{
        ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW,
    },
    Security::{
        Cryptography::{
            BCRYPT_ALG_HANDLE, BCRYPT_HASH_HANDLE, BCRYPT_HASH_LENGTH, BCRYPT_OBJECT_LENGTH,
            BCRYPT_SHA256_ALGORITHM, BCryptCloseAlgorithmProvider, BCryptCreateHash,
            BCryptDestroyHash, BCryptFinishHash, BCryptGetProperty, BCryptHashData,
            BCryptOpenAlgorithmProvider,
        },
        DACL_SECURITY_INFORMATION, GetTokenInformation, PROTECTED_DACL_SECURITY_INFORMATION,
        SECURITY_ATTRIBUTES, SetFileSecurityW, TOKEN_QUERY, TOKEN_USER, TokenUser,
    },
    Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, CreateDirectoryW, CreateFileW, FILE_ATTRIBUTE_DEVICE,
        FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_TAG_INFO, FILE_FLAG_BACKUP_SEMANTICS,
        FILE_FLAG_OPEN_REPARSE_POINT, FILE_GENERIC_READ, FILE_READ_ATTRIBUTES, FILE_SHARE_DELETE,
        FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_TYPE_DISK, FileAttributeTagInfo,
        GetFileInformationByHandle, GetFileInformationByHandleEx, GetFileType, GetFullPathNameW,
        OPEN_EXISTING, ReadFile,
    },
    System::{
        Environment::ExpandEnvironmentStringsW,
        Registry::{
            HKEY, HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_ENUMERATE_SUB_KEYS, KEY_QUERY_VALUE,
            KEY_SET_VALUE, REG_EXPAND_SZ, REG_SZ, RegCloseKey, RegDeleteValueW, RegEnumKeyExW,
            RegOpenKeyExW, RegQueryValueExW, RegSetValueExW,
        },
        SystemInformation::GetSystemTime,
        Threading::{
            CreateMutexW, GetCurrentProcess, OpenProcessToken, ReleaseMutex, WaitForSingleObject,
        },
    },
};

const REQUEST_LIMIT: u64 = 65536;
const ENTRY_LIMIT: usize = 10000;
const DEPTH_LIMIT: usize = 64;
const REPARSE_OR_ENCRYPTED: u32 = 0x400 | 0x4000;
const BACKUP_BYTE_LIMIT: usize = 4 * 1024 * 1024;
const UTF8_BOM: &[u8] = b"\xEF\xBB\xBF";
const SHELL_KEY: &str =
    "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders";
const SETTINGS_MUTEX_PREFIX: &str = "Local\\ICloudFolders-";
const MAP: &str = include_str!(env!("ICLOUD_FOLDER_MAP_PATH"));
type Result<T> = std::result::Result<T, String>;

struct SettingsMutex(HANDLE);

impl Drop for SettingsMutex {
    fn drop(&mut self) {
        // SAFETY: this guard is created only after successful acquisition and is dropped on
        // the same worker thread that owns the Windows mutex.
        unsafe {
            ReleaseMutex(self.0);
            CloseHandle(self.0);
        }
    }
}

fn acquire_settings_mutex() -> Result<SettingsMutex> {
    let name = format!("{SETTINGS_MUTEX_PREFIX}{}", user_sid()?);
    let name: Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
    // SAFETY: the name is a valid NUL-terminated UTF-16 string; default security attributes
    // match the current-user named mutex created by the PowerShell backend.
    let handle = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
    if handle.is_null() {
        return Err(format!(
            "Cannot create the account settings mutex (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    // SAFETY: handle is a live mutex handle returned by CreateMutexW.
    match unsafe { WaitForSingleObject(handle, 0) } {
        WAIT_OBJECT_0 | WAIT_ABANDONED => Ok(SettingsMutex(handle)),
        WAIT_TIMEOUT => {
            // SAFETY: handle is live and not owned by this thread.
            unsafe { CloseHandle(handle) };
            Err("Another ICloudFolders operation is running for this user.".into())
        }
        WAIT_FAILED => {
            let error = unsafe { GetLastError() };
            unsafe { CloseHandle(handle) };
            Err(format!(
                "Cannot acquire the account settings mutex (Windows error {error})."
            ))
        }
        status => {
            unsafe { CloseHandle(handle) };
            Err(format!(
                "Unexpected account settings mutex status {status}."
            ))
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    Metadata {
        version: u32,
    },
    Inspect {
        version: u32,
    },
    Defaults {
        version: u32,
    },
    Resolve {
        version: u32,
    },
    Check {
        version: u32,
        root: PathBuf,
        #[serde(default)]
        include_music: bool,
        #[serde(default)]
        folder_paths: BTreeMap<String, PathBuf>,
    },
    Plan {
        version: u32,
        source: PathBuf,
        destination: PathBuf,
    },
    PlanMany {
        version: u32,
        pairs: Vec<CopyPair>,
    },
    CopyPlan {
        version: u32,
        root: PathBuf,
        #[serde(default)]
        include_music: bool,
        #[serde(default)]
        folder_paths: BTreeMap<String, PathBuf>,
    },
    CopyPairs {
        version: u32,
        root: PathBuf,
        #[serde(default)]
        include_music: bool,
        #[serde(default)]
        folder_paths: BTreeMap<String, PathBuf>,
    },
    SetupPreview {
        version: u32,
        root: PathBuf,
        #[serde(default)]
        include_music: bool,
        #[serde(default)]
        allow_existing_content: bool,
        #[serde(default)]
        verified_sync_root: bool,
        #[serde(default)]
        folder_paths: BTreeMap<String, PathBuf>,
    },
    SetupApply {
        version: u32,
        root: PathBuf,
        #[serde(default)]
        include_music: bool,
        #[serde(default)]
        allow_existing_content: bool,
        #[serde(default)]
        verified_sync_root: bool,
        #[serde(default)]
        folder_paths: BTreeMap<String, PathBuf>,
        #[serde(default)]
        confirmed: bool,
        preview_token: String,
    },
    ResetPreview {
        version: u32,
        #[serde(default)]
        allow_existing_content: bool,
    },
    ResetApply {
        version: u32,
        #[serde(default)]
        allow_existing_content: bool,
        #[serde(default)]
        confirmed: bool,
        preview_token: String,
    },
    ValidateBackup {
        version: u32,
        backup: BackupRecord,
    },
    BackupSnapshot {
        version: u32,
        #[serde(default)]
        include_music: bool,
    },
    RestorePreview {
        version: u32,
        backup: BackupRecord,
    },
    RestorePreviewFile {
        version: u32,
        path: PathBuf,
    },
    RestoreApply {
        version: u32,
        path: PathBuf,
        #[serde(default)]
        confirmed: bool,
        preview_token: String,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
struct BackupRecord {
    version: u32,
    sid: String,
    key: String,
    #[serde(default, rename = "CreatedUtc")]
    _created_utc: Option<String>,
    values: Vec<BackupValue>,
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "PascalCase")]
struct BackupValue {
    name: String,
    exists: bool,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    data: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct BackupRecordFields {
    version: u32,
    sid: String,
    key: String,
    #[serde(default, rename = "CreatedUtc", alias = "_created_utc")]
    created_utc: Option<String>,
    values: Vec<BackupValueFields>,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
struct BackupValueFields {
    name: String,
    exists: bool,
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    data: Option<String>,
}

fn normalize_backup_fields(value: &mut serde_json::Value) -> std::result::Result<(), String> {
    fn normalize_object(
        value: &mut serde_json::Value,
        fields: &[(&str, &[&str])],
    ) -> std::result::Result<(), String> {
        let Some(object) = value.as_object_mut() else {
            return Err("Backup record must be a JSON object.".into());
        };
        let old = std::mem::take(object);
        let mut normalized = serde_json::Map::new();
        for (name, value) in old {
            let canonical = fields
                .iter()
                .find(|(field, aliases)| {
                    name.eq_ignore_ascii_case(field)
                        || aliases.iter().any(|alias| name.eq_ignore_ascii_case(alias))
                })
                .map_or(name.as_str(), |(field, _)| *field);
            if normalized.contains_key(canonical) {
                return Err(format!(
                    "Backup contains duplicate property names for {canonical}."
                ));
            }
            normalized.insert(canonical.to_owned(), value);
        }
        *object = normalized;
        Ok(())
    }

    normalize_object(
        value,
        &[
            ("Version", &[]),
            ("Sid", &[]),
            ("Key", &[]),
            ("CreatedUtc", &["_created_utc"]),
            ("Values", &[]),
        ],
    )?;
    if let Some(values) = value
        .get_mut("Values")
        .and_then(serde_json::Value::as_array_mut)
    {
        for entry in values {
            normalize_object(
                entry,
                &[("Name", &[]), ("Exists", &[]), ("Kind", &[]), ("Data", &[])],
            )?;
        }
    }
    Ok(())
}

impl<'de> Deserialize<'de> for BackupRecord {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let mut raw = serde_json::Value::deserialize(deserializer)?;
        normalize_backup_fields(&mut raw).map_err(de::Error::custom)?;
        let fields: BackupRecordFields = serde_json::from_value(raw).map_err(de::Error::custom)?;
        Ok(Self {
            version: fields.version,
            sid: fields.sid,
            key: fields.key,
            _created_utc: fields.created_utc,
            values: fields
                .values
                .into_iter()
                .map(|value| BackupValue {
                    name: value.name,
                    exists: value.exists,
                    kind: value.kind,
                    data: value.data,
                })
                .collect(),
        })
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct CopyPair {
    source: PathBuf,
    destination: PathBuf,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Mapping {
    value_name: String,
    relative_path: String,
    optional: bool,
    known_folder_id: String,
}

#[derive(Serialize)]
struct FolderPath {
    folder: String,
    path: String,
}

#[derive(Serialize)]
struct RegistryCheckRow {
    folder: String,
    value_name: String,
    current: Option<String>,
    expected: String,
    matches: bool,
    directory_exists: bool,
}

#[derive(Serialize)]
struct ResolvedCheckRow {
    folder: String,
    current: Option<String>,
    expected: String,
    matches: bool,
}

#[derive(Serialize)]
struct CheckResult {
    healthy: bool,
    root: String,
    root_exists: bool,
    root_registered: bool,
    registered_roots: Vec<String>,
    user_sid: String,
    registry_values: Vec<RegistryCheckRow>,
    resolved_folders: Vec<ResolvedCheckRow>,
    errors: Vec<String>,
    cloud_sync: &'static str,
}

#[derive(Clone)]
struct StoredFolderValue {
    exists: bool,
    kind: Option<&'static str>,
    data: Option<String>,
}

#[derive(Serialize)]
struct PreviewRow {
    folder: String,
    value_name: String,
    current: Option<String>,
    current_exists: bool,
    current_kind: Option<&'static str>,
    proposed: String,
    proposed_kind: &'static str,
    action: &'static str,
}

#[derive(Serialize)]
struct FolderPreview {
    operation: &'static str,
    root: Option<String>,
    recovery_root: String,
    registered_roots: Vec<String>,
    root_registered: Option<bool>,
    verified_sync_root: bool,
    review_gates_passed: bool,
    rows: Vec<PreviewRow>,
    content_warnings: Vec<String>,
}

#[derive(Serialize)]
struct RestorePreviewRow {
    folder: String,
    value_name: String,
    current_exists: bool,
    current_kind: Option<&'static str>,
    current: Option<String>,
    proposed_exists: bool,
    proposed_kind: Option<String>,
    proposed: Option<String>,
    action: &'static str,
}

#[derive(Serialize)]
struct RestorePreview {
    operation: &'static str,
    recovery_root: String,
    rows: Vec<RestorePreviewRow>,
}

#[repr(C)]
struct Guid {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [u8; 8],
}

#[link(name = "shell32")]
unsafe extern "system" {
    fn SHGetKnownFolderPath(
        folder_id: *const Guid,
        flags: u32,
        token: *mut std::ffi::c_void,
        path: *mut *mut u16,
    ) -> i32;
}

#[link(name = "ole32")]
unsafe extern "system" {
    fn CoInitializeEx(reserved: *mut std::ffi::c_void, flags: u32) -> i32;
    fn CoUninitialize();
    fn CoTaskMemFree(memory: *const std::ffi::c_void);
}

struct ComApartment;
impl ComApartment {
    fn initialize() -> Result<Self> {
        // COINIT_APARTMENTTHREADED. SHGetKnownFolderPath requires COM initialized.
        // SAFETY: this worker owns its main thread and has not initialized COM elsewhere.
        let status = unsafe { CoInitializeEx(std::ptr::null_mut(), 0x2) };
        if status < 0 {
            return Err(format!(
                "Windows shell initialization failed (HRESULT 0x{:08X}).",
                status as u32
            ));
        }
        Ok(Self)
    }
}
impl Drop for ComApartment {
    fn drop(&mut self) {
        // SAFETY: initialize returned S_OK or S_FALSE for this thread.
        unsafe { CoUninitialize() };
    }
}

struct CoTaskMem(*mut u16);
impl Drop for CoTaskMem {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: SHGetKnownFolderPath returns this allocation for CoTaskMemFree.
            unsafe { CoTaskMemFree(self.0.cast()) };
        }
    }
}

#[derive(Serialize)]
struct RegistryValue {
    value_name: String,
    exists: bool,
    kind: u32,
    // Unexpanded bytes preserve malformed strings and non-string registry values too.
    data_hex: String,
}

#[derive(Serialize)]
struct Entry {
    source: String,
    destination: String,
    directory: bool,
    hash: Option<String>,
    action: &'static str,
}

fn emit(output: &mut impl Write, value: &impl Serialize) -> Result<()> {
    serde_json::to_writer(&mut *output, value).map_err(|e| e.to_string())?;
    output.write_all(b"\n").map_err(|e| e.to_string())
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}

struct Key(HKEY);
impl Drop for Key {
    fn drop(&mut self) {
        // SAFETY: this owns exactly one successful RegOpenKeyExW handle.
        unsafe { RegCloseKey(self.0) };
    }
}

fn open_key(root: HKEY, path: &str, access: u32) -> Result<Option<Key>> {
    let path = wide(path);
    let mut raw = std::ptr::null_mut();
    // SAFETY: path is NUL-terminated and raw is a live output slot.
    let status = unsafe { RegOpenKeyExW(root, path.as_ptr(), 0, access, &mut raw) };
    match status {
        ERROR_SUCCESS => Ok(Some(Key(raw))),
        ERROR_FILE_NOT_FOUND => Ok(None),
        _ => Err(format!(
            "Cannot open a required registry key (Windows error {status})."
        )),
    }
}

fn query_value(key: HKEY, name: &str) -> Result<Option<(u32, Vec<u8>)>> {
    let name_wide = wide(name);
    let mut kind = 0u32;
    let mut bytes = vec![0u8; REQUEST_LIMIT as usize];
    let mut size = bytes.len() as u32;
    // SAFETY: value name and output buffers remain valid for the API call.
    let status = unsafe {
        RegQueryValueExW(
            key,
            name_wide.as_ptr(),
            std::ptr::null(),
            &mut kind,
            bytes.as_mut_ptr(),
            &mut size,
        )
    };
    match status {
        ERROR_SUCCESS => {
            bytes.truncate(size as usize);
            Ok(Some((kind, bytes)))
        }
        ERROR_FILE_NOT_FOUND => Ok(None),
        ERROR_MORE_DATA => Err(format!(
            "Registry value {name} exceeds 64 KiB and is refused."
        )),
        _ => Err(format!(
            "Cannot read registry value {name} (Windows error {status})."
        )),
    }
}

struct Token(HANDLE);
impl Drop for Token {
    fn drop(&mut self) {
        // SAFETY: this owns the process token handle returned by OpenProcessToken.
        unsafe { CloseHandle(self.0) };
    }
}

struct LocalAllocation(HLOCAL);
impl Drop for LocalAllocation {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: ConvertSidToStringSidW allocates this string with LocalAlloc.
            unsafe { LocalFree(self.0) };
        }
    }
}

fn user_sid() -> Result<String> {
    let mut token = std::ptr::null_mut();
    // SAFETY: GetCurrentProcess returns a pseudo-handle; token is an output slot.
    if unsafe { OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) } == 0 {
        return Err(format!(
            "Cannot open the current user token (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    let token = Token(token);
    let mut needed = 0u32;
    // SAFETY: this first call requests the required size and supplies no destination buffer.
    let _ =
        unsafe { GetTokenInformation(token.0, TokenUser, std::ptr::null_mut(), 0, &mut needed) };
    if needed == 0 || needed > 65536 {
        return Err("Windows returned an invalid current-user token size.".into());
    }
    let mut bytes = vec![0u8; needed as usize];
    // SAFETY: bytes is suitably aligned by the allocator and large enough for TOKEN_USER.
    if unsafe {
        GetTokenInformation(
            token.0,
            TokenUser,
            bytes.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    } == 0
    {
        return Err(format!(
            "Cannot read the current user SID (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    // SAFETY: GetTokenInformation filled a valid TOKEN_USER at the start of this buffer.
    let token_user = unsafe { &*(bytes.as_ptr().cast::<TOKEN_USER>()) };
    let mut raw = std::ptr::null_mut();
    // SAFETY: the SID pointer is owned by the live token-information buffer.
    if unsafe { ConvertSidToStringSidW(token_user.User.Sid, &mut raw) } == 0 {
        return Err(format!(
            "Cannot format the current user SID (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    let sid = LocalAllocation(raw.cast());
    // SAFETY: ConvertSidToStringSidW returns a NUL-terminated UTF-16 allocation.
    let length = unsafe {
        (0usize..=256)
            .take_while(|index| *sid.0.cast::<u16>().add(*index) != 0)
            .count()
    };
    if length == 0 || length > 256 {
        return Err("Windows returned an invalid current-user SID string.".into());
    }
    // SAFETY: the LocalAlloc string contains `length` UTF-16 units before its terminator.
    String::from_utf16(unsafe { slice::from_raw_parts(sid.0.cast::<u16>(), length) })
        .map_err(|_| "Windows returned an invalid current-user SID string.".into())
}

fn utf16_registry_string(bytes: &[u8]) -> Result<String> {
    if bytes.len() % 2 != 0 {
        return Err("Registry path has an invalid UTF-16 byte length.".into());
    }
    let units: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    let end = units
        .iter()
        .position(|unit| *unit == 0)
        .unwrap_or(units.len());
    if end == 0 {
        return Err("Registry path is empty.".into());
    }
    String::from_utf16(&units[..end]).map_err(|_| "Registry path contains invalid UTF-16.".into())
}

fn expand_environment(value: &str) -> Result<String> {
    let source = wide(value);
    // SAFETY: a zero-size query returns the required UTF-16 buffer length.
    let needed = unsafe { ExpandEnvironmentStringsW(source.as_ptr(), std::ptr::null_mut(), 0) };
    if needed == 0 || needed > 32001 {
        return Err(format!(
            "Cannot expand a path's environment variables (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    let mut buffer = vec![0u16; needed as usize];
    // SAFETY: buffer has the size reported by the first call and source remains live.
    let written =
        unsafe { ExpandEnvironmentStringsW(source.as_ptr(), buffer.as_mut_ptr(), needed) };
    if written == 0 || written > needed {
        return Err(format!(
            "Cannot expand a path's environment variables (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    buffer.truncate(written.saturating_sub(1) as usize);
    String::from_utf16(&buffer).map_err(|_| "Expanded path contains invalid UTF-16.".into())
}

fn full_path(value: &str) -> Result<PathBuf> {
    let input = wide(value);
    // SAFETY: a zero-size query returns the buffer length required for the full path.
    let needed = unsafe {
        GetFullPathNameW(
            input.as_ptr(),
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if needed == 0 || needed > 32000 {
        return Err(format!(
            "Cannot normalize a folder path (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    let mut buffer = vec![0u16; needed as usize + 1];
    // SAFETY: buffer exceeds the required size and input is NUL-terminated.
    let written = unsafe {
        GetFullPathNameW(
            input.as_ptr(),
            buffer.len() as u32,
            buffer.as_mut_ptr(),
            std::ptr::null_mut(),
        )
    };
    if written == 0 || written as usize >= buffer.len() {
        return Err(format!(
            "Cannot normalize a folder path (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    String::from_utf16(&buffer[..written as usize])
        .map(PathBuf::from)
        .map_err(|_| "Normalized folder path contains invalid UTF-16.".into())
}

fn normalize_local_path(path: &Path) -> Result<PathBuf> {
    let raw = text(path)?;
    let expanded = expand_environment(&raw)?;
    if expanded.trim().is_empty() || expanded.contains('%') {
        return Err("Folder path is empty or contains an unresolved environment variable.".into());
    }
    let full = full_path(&expanded)?;
    validate_path(&full)?;
    if !matches!(full.components().next(), Some(Component::Prefix(p)) if matches!(p.kind(), Prefix::Disk(_)))
        || full.file_name().is_none()
    {
        return Err("A non-root absolute local drive folder path is required.".into());
    }
    Ok(full)
}

fn normalize_registered_root(root: &str) -> Result<String> {
    let path = Path::new(root);
    if !path.is_absolute() {
        return Err("A registered iCloud root must be an absolute local path.".into());
    }
    text(&normalize_local_path(path)?)
}

fn enumerate_subkeys(key: HKEY) -> Result<Vec<String>> {
    const MAX_SUBKEYS: u32 = 4096;
    let mut names = Vec::new();
    for index in 0..MAX_SUBKEYS {
        let mut buffer = vec![0u16; 1024];
        let mut length = buffer.len() as u32;
        // SAFETY: buffer and length are writable; unused class/time outputs are null.
        let status = unsafe {
            RegEnumKeyExW(
                key,
                index,
                buffer.as_mut_ptr(),
                &mut length,
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        match status {
            ERROR_SUCCESS => names.push(
                String::from_utf16(&buffer[..length as usize])
                    .map_err(|_| "Registry subkey contains invalid UTF-16.".to_string())?,
            ),
            ERROR_NO_MORE_ITEMS => return Ok(names),
            ERROR_MORE_DATA => return Err("Registry subkey name exceeds its safe limit.".into()),
            _ => {
                return Err(format!(
                    "Cannot enumerate registry subkeys (Windows error {status})."
                ));
            }
        }
    }
    Err("Registry subkey enumeration exceeded 4,096 entries.".into())
}

fn registry_string(key: HKEY, name: &str) -> Result<Option<String>> {
    let Some((kind, bytes)) = query_value(key, name)? else {
        return Ok(None);
    };
    if kind != 1 && kind != 2 {
        return Err(format!("Registry path {name} has unsupported type {kind}."));
    }
    let raw = utf16_registry_string(&bytes)?;
    if kind == 2 {
        Ok(Some(expand_environment(&raw)?))
    } else {
        Ok(Some(raw))
    }
}

fn collect_registered_icloud_roots<F>(
    entries: impl IntoIterator<Item = (String, Option<String>)>,
    mut normalize: F,
) -> Result<Vec<String>>
where
    F: FnMut(&str) -> Result<String>,
{
    let mut roots = Vec::new();
    for (name, root) in entries {
        if !name.to_ascii_lowercase().starts_with("iclouddrive!") {
            continue;
        }
        if let Some(root) = root {
            roots.push(normalize(&root)?);
        }
    }
    Ok(roots)
}

fn registered_roots(sid: &str) -> Result<Vec<String>> {
    let Some(manager) = open_key(
        HKEY_LOCAL_MACHINE,
        "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\SyncRootManager",
        KEY_ENUMERATE_SUB_KEYS,
    )?
    else {
        return Ok(Vec::new());
    };
    let mut entries = Vec::new();
    for name in enumerate_subkeys(manager.0)? {
        if !name.to_ascii_lowercase().starts_with("iclouddrive!") {
            continue;
        }
        // Open the child relative to the enumerated manager handle. Reopening
        // this full HKLM path can miss an existing provider child on Windows.
        let path = format!("{name}\\UserSyncRoots");
        let Some(values) = open_key(manager.0, &path, KEY_QUERY_VALUE)? else {
            continue;
        };
        entries.push((name, registry_string(values.0, sid)?));
    }
    collect_registered_icloud_roots(entries, normalize_registered_root)
}

fn inspect(map: &[Mapping]) -> Result<Vec<RegistryValue>> {
    let key = open_key(
        HKEY_CURRENT_USER,
        "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders",
        KEY_QUERY_VALUE,
    )?;
    let mut rows = Vec::with_capacity(map.len());
    for item in map {
        let mut row = RegistryValue {
            value_name: item.value_name.clone(),
            exists: false,
            kind: 0,
            data_hex: String::new(),
        };
        if let Some(key) = &key {
            match query_value(key.0, &item.value_name)? {
                Some((kind, bytes)) => {
                    row.exists = true;
                    row.kind = kind;
                    row.data_hex = hex(&bytes);
                }
                None => {
                    row.kind = 0;
                }
            }
        }
        rows.push(row);
    }
    Ok(rows)
}

fn parse_guid(value: &str) -> Result<Guid> {
    let parts: Vec<_> = value.split('-').collect();
    if parts.len() != 5
        || parts.iter().map(|part| part.len()).collect::<Vec<_>>() != [8, 4, 4, 4, 12]
    {
        return Err("Invalid build-time Known Folder ID.".into());
    }
    let data1 =
        u32::from_str_radix(parts[0], 16).map_err(|_| "Invalid build-time Known Folder ID.")?;
    let data2 =
        u16::from_str_radix(parts[1], 16).map_err(|_| "Invalid build-time Known Folder ID.")?;
    let data3 =
        u16::from_str_radix(parts[2], 16).map_err(|_| "Invalid build-time Known Folder ID.")?;
    let tail = format!("{}{}", parts[3], parts[4]);
    let mut data4 = [0u8; 8];
    for (index, pair) in tail.as_bytes().chunks_exact(2).enumerate() {
        let pair = std::str::from_utf8(pair).map_err(|_| "Invalid build-time Known Folder ID.")?;
        data4[index] =
            u8::from_str_radix(pair, 16).map_err(|_| "Invalid build-time Known Folder ID.")?;
    }
    Ok(Guid {
        data1,
        data2,
        data3,
        data4,
    })
}

fn known_folder_path(id: &str, flags: u32) -> Result<String> {
    let id = parse_guid(id)?;
    let mut raw = std::ptr::null_mut();
    // SAFETY: the GUID and output slot remain live for the duration of the Windows API call.
    let status = unsafe { SHGetKnownFolderPath(&id, flags, std::ptr::null_mut(), &mut raw) };
    let path = CoTaskMem(raw);
    if status < 0 {
        return Err(format!(
            "SHGetKnownFolderPath failed (HRESULT 0x{:08X}).",
            status as u32
        ));
    }
    if path.0.is_null() {
        return Err("Windows returned an empty default-folder path.".into());
    }
    // SAFETY: the documented SHGetKnownFolderPath result is a NUL-terminated UTF-16 string.
    let length = unsafe {
        (0usize..=32000)
            .take_while(|index| *path.0.add(*index) != 0)
            .count()
    };
    if length == 0 || length > 32000 {
        return Err("Windows returned an invalid default-folder path length.".into());
    }
    // SAFETY: the allocation contains at least `length` UTF-16 units before its terminator.
    let units = unsafe { slice::from_raw_parts(path.0, length) };
    String::from_utf16(units).map_err(|_| "Windows returned an invalid UTF-16 folder path.".into())
}

fn collect_folder_paths<F>(
    map: &[Mapping],
    include_music: bool,
    purpose: &str,
    mut resolve_one: F,
) -> (Vec<FolderPath>, Vec<String>)
where
    F: FnMut(&Mapping) -> Result<String>,
{
    let mut seen = BTreeSet::new();
    let mut folders = Vec::new();
    let mut errors = Vec::new();
    for item in map.iter().filter(|item| include_music || !item.optional) {
        if !seen.insert(item.known_folder_id.clone()) {
            continue;
        }
        let folder = if item.relative_path == "Videos\\Captures" {
            "Captures"
        } else {
            &item.relative_path
        };
        match resolve_one(item) {
            Ok(path) => folders.push(FolderPath {
                folder: folder.to_owned(),
                path,
            }),
            Err(error) => errors.push(format!(
                "Cannot resolve the Windows {purpose} for {folder}: {error}"
            )),
        }
    }
    (folders, errors)
}

fn is_missing_captures_folder(error: &str) -> bool {
    error
        == "Cannot resolve the Windows current folder for Captures: SHGetKnownFolderPath failed (HRESULT 0x80070002)."
}

fn folder_paths(map: &[Mapping], flags: u32, purpose: &str) -> Result<Vec<FolderPath>> {
    let _apartment = ComApartment::initialize()?;
    let (folders, errors) = collect_folder_paths(map, true, purpose, |item| {
        known_folder_path(&item.known_folder_id, flags)
    });
    match errors.into_iter().next() {
        Some(error) => Err(error),
        None => Ok(folders),
    }
}

fn defaults(map: &[Mapping]) -> Result<Vec<FolderPath>> {
    // KF_FLAG_DEFAULT_PATH | KF_FLAG_DONT_VERIFY | KF_FLAG_NOT_PARENT_RELATIVE.
    folder_paths(map, 0x4600, "default")
}

fn resolve(map: &[Mapping]) -> Result<Vec<FolderPath>> {
    // KF_FLAG_DEFAULT: resolve the current, possibly redirected path.
    folder_paths(map, 0, "current folder")
}

fn path_is_within(child: &Path, parent: &Path) -> Result<bool> {
    let child = OrdinalPath::new(child)?.0;
    let parent = OrdinalPath::new(parent)?.0;
    if child.len() <= parent.len() || child[parent.len()] != b'\\' as u16 {
        return Ok(false);
    }
    // SAFETY: the prefix slices are valid UTF-16 buffers and remain live for the call.
    Ok(unsafe {
        CompareStringOrdinal(
            child.as_ptr(),
            parent.len() as i32,
            parent.as_ptr(),
            parent.len() as i32,
            1,
        )
    } == 2)
}

fn folder_targets(
    map: &[Mapping],
    root: &Path,
    include_music: bool,
    custom: &BTreeMap<String, PathBuf>,
) -> Result<(PathBuf, BTreeMap<String, PathBuf>)> {
    let root = normalize_local_path(root)?;
    let mut folders = BTreeMap::<String, PathBuf>::new();
    for item in map.iter().filter(|item| include_music || !item.optional) {
        let label = if item.relative_path == "Videos\\Captures" {
            "Captures"
        } else {
            &item.relative_path
        };
        folders
            .entry(label.to_owned())
            .or_insert_with(|| root.join(&item.relative_path));
    }
    let mut assigned = BTreeSet::new();
    for (label, path) in custom {
        let Some(canonical) = folders
            .keys()
            .find(|known| paths_equal(label, known))
            .cloned()
        else {
            return Err(format!("Unsupported custom folder: {label}."));
        };
        if !assigned.insert(canonical.clone()) {
            return Err(format!(
                "Custom folder is specified more than once: {canonical}."
            ));
        }
        let path = normalize_local_path(path)?;
        if !path_is_within(&path, &root)? {
            return Err(format!(
                "Custom folder destinations must be inside the selected iCloud Drive folder: {label}."
            ));
        }
        folders.insert(canonical, path);
    }
    let names: Vec<_> = folders.keys().cloned().collect();
    for i in 0..names.len() {
        for j in i + 1..names.len() {
            let a = &names[i];
            let b = &names[j];
            let ap = &folders[a];
            let bp = &folders[b];
            if OrdinalPath::new(ap)? == OrdinalPath::new(bp)? {
                return Err(format!(
                    "Folder destinations must be different: {a} and {b}."
                ));
            }
            let nested = path_is_within(ap, bp)? || path_is_within(bp, ap)?;
            let captures_inside_videos =
                (a == "Captures" && b == "Videos" && path_is_within(ap, bp)?)
                    || (b == "Captures" && a == "Videos" && path_is_within(bp, ap)?);
            if nested && !captures_inside_videos {
                return Err(format!("Folder destinations overlap: {a} and {b}."));
            }
        }
    }
    Ok((root, folders))
}

fn check(
    map: &[Mapping],
    root: &Path,
    include_music: bool,
    custom: &BTreeMap<String, PathBuf>,
) -> Result<CheckResult> {
    let (root, folders) = folder_targets(map, root, include_music, custom)?;

    let sid = user_sid()?;
    let roots = registered_roots(&sid)?;
    let root_text = text(&root)?;
    let root_registered = roots.iter().any(|registered| {
        match (
            OrdinalPath::new(Path::new(registered)),
            OrdinalPath::new(&root),
        ) {
            (Ok(registered), Ok(root)) => registered == root,
            _ => false,
        }
    });
    let root_exists = fs::metadata(&root)
        .map(|meta| meta.is_dir())
        .unwrap_or(false);
    let values_key = open_key(
        HKEY_CURRENT_USER,
        "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders",
        KEY_QUERY_VALUE,
    )?;
    let mut errors = Vec::new();
    let mut registry_values = Vec::new();
    for item in map.iter().filter(|item| include_music || !item.optional) {
        let label = if item.relative_path == "Videos\\Captures" {
            "Captures"
        } else {
            &item.relative_path
        };
        let expected = text(&folders[label])?;
        let current = match values_key.as_ref() {
            Some(key) => match query_value(key.0, &item.value_name) {
                Ok(Some((kind, bytes))) if kind == 1 || kind == 2 => {
                    match utf16_registry_string(&bytes) {
                        Ok(raw) => match if kind == 2 {
                            expand_environment(&raw)
                        } else {
                            Ok(raw)
                        } {
                            Ok(value) => Some(value),
                            Err(error) => {
                                errors.push(error);
                                None
                            }
                        },
                        Err(error) => {
                            errors.push(error);
                            None
                        }
                    }
                }
                Ok(Some((kind, _))) => {
                    errors.push(format!(
                        "Registry path {} has unsupported type {kind}.",
                        item.value_name
                    ));
                    None
                }
                Ok(None) => None,
                Err(error) => {
                    errors.push(error);
                    None
                }
            },
            None => None,
        };
        let matches = current
            .as_ref()
            .is_some_and(|value| paths_equal(value, &expected));
        let directory_exists = fs::metadata(&folders[label])
            .map(|meta| meta.is_dir())
            .unwrap_or(false);
        registry_values.push(RegistryCheckRow {
            folder: label.to_owned(),
            value_name: item.value_name.clone(),
            current,
            expected,
            matches,
            directory_exists,
        });
    }
    // PowerShell reports each Known Folder lookup failure while retaining the other
    // resolved rows. Keep the check report useful when one folder API call fails, and
    // do not query optional Music unless this request includes it.
    let (resolved_now, resolution_errors) = match ComApartment::initialize() {
        Ok(_apartment) => collect_folder_paths(map, include_music, "current folder", |item| {
            known_folder_path(&item.known_folder_id, 0)
        }),
        Err(error) => (
            Vec::new(),
            vec![format!(
                "Cannot initialize Windows folder resolution: {error}"
            )],
        ),
    };
    let mut missing_captures = false;
    for error in resolution_errors {
        if is_missing_captures_folder(&error) {
            // PowerShell's shell:Captures lookup returns a null path without an error
            // when this optional Known Folder is unavailable. Preserve that row below.
            missing_captures = true;
        } else {
            errors.push(error);
        }
    }
    let mut resolved_folders = Vec::new();
    let mut seen = BTreeSet::new();
    for resolved in resolved_now {
        if !folders.contains_key(&resolved.folder) {
            continue;
        }
        let expected = text(&folders[&resolved.folder])?;
        let matches = paths_equal(&resolved.path, &expected);
        let folder = if resolved.folder == "Captures" {
            "Videos\\Captures".to_owned()
        } else {
            resolved.folder
        };
        if !seen.insert(folder.clone()) {
            continue;
        }
        resolved_folders.push(ResolvedCheckRow {
            folder,
            current: Some(resolved.path),
            expected,
            matches,
        });
    }
    if missing_captures && folders.contains_key("Captures") {
        let folder = "Videos\\Captures".to_owned();
        if seen.insert(folder.clone()) {
            let expected = text(&folders["Captures"])?;
            resolved_folders.push(ResolvedCheckRow {
                folder,
                current: None,
                expected,
                matches: false,
            });
        }
    }
    let healthy = root_exists
        && root_registered
        && registry_values
            .iter()
            .all(|row| row.matches && row.directory_exists)
        && resolved_folders.iter().all(|row| row.matches)
        && resolved_folders.len() == folders.len()
        && errors.is_empty();
    Ok(CheckResult {
        healthy,
        root: root_text,
        root_exists,
        root_registered,
        registered_roots: roots,
        user_sid: sid,
        registry_values,
        resolved_folders,
        errors,
        cloud_sync: "Not verified by this read-only check.",
    })
}

fn read_folder_values(
    map: &[Mapping],
    include_music: bool,
) -> Result<BTreeMap<String, StoredFolderValue>> {
    read_named_folder_values(
        map.iter()
            .filter(|item| include_music || !item.optional)
            .map(|item| item.value_name.as_str()),
    )
}

fn read_named_folder_values<'a>(
    names: impl IntoIterator<Item = &'a str>,
) -> Result<BTreeMap<String, StoredFolderValue>> {
    let key = open_key(HKEY_CURRENT_USER, SHELL_KEY, KEY_QUERY_VALUE)?;
    let mut values = BTreeMap::new();
    for name in names {
        let value = if let Some(key) = key.as_ref() {
            match query_value(key.0, name)? {
                Some((kind, bytes)) if kind == 1 || kind == 2 => StoredFolderValue {
                    exists: true,
                    kind: Some(if kind == 1 { "String" } else { "ExpandString" }),
                    data: Some(utf16_registry_string(&bytes)?),
                },
                Some((kind, _)) => {
                    return Err(format!("Unsupported registry type for {}: {kind}.", name));
                }
                None => StoredFolderValue {
                    exists: false,
                    kind: None,
                    data: None,
                },
            }
        } else {
            StoredFolderValue {
                exists: false,
                kind: None,
                data: None,
            }
        };
        values.insert(name.to_owned(), value);
    }
    Ok(values)
}

fn validate_backup(backup: &BackupRecord, map: &[Mapping], sid: &str) -> Result<usize> {
    if backup.version != 1 || !backup.sid.eq_ignore_ascii_case(sid) || backup.key != SHELL_KEY {
        return Err("Backup schema, user SID, or registry key does not match.".into());
    }
    if backup.values.is_empty() {
        return Err("Backup has no values.".into());
    }
    let mut seen = BTreeSet::new();
    for value in &backup.values {
        let allowed = map
            .iter()
            .any(|item| item.value_name.eq_ignore_ascii_case(&value.name));
        if !allowed || !seen.insert(value.name.to_ascii_lowercase()) {
            return Err(format!(
                "Unexpected or duplicate backup value: {}",
                value.name
            ));
        }
        if value.exists {
            let kind_is_valid = value.kind.as_deref().is_some_and(|kind| {
                kind.eq_ignore_ascii_case("String") || kind.eq_ignore_ascii_case("ExpandString")
            });
            let Some(data) = value.data.as_deref() else {
                return Err("Invalid registry value in backup.".into());
            };
            if !kind_is_valid {
                return Err("Invalid registry value in backup.".into());
            }
            normalize_local_path(Path::new(data))?;
        } else if value.kind.is_some() || value.data.is_some() {
            return Err("Invalid absent value in backup.".into());
        }
    }
    Ok(backup.values.len())
}

const BACKUP_FILE_LIMIT: u64 = 4 * 1024 * 1024;
const UTF8_SIGNATURE: &[u8] = b"\xEF\xBB\xBF";

fn read_backup_file(path: &Path, map: &[Mapping], sid: &str) -> Result<BackupRecord> {
    let path = full_path(&text(path)?)?;
    validate_path(&path)?;
    guarded_metadata(&path)?;
    // Open the final reparse point itself and prevent concurrent writers or deletion while
    // parsing the account's recovery record.
    let mut file = OpenOptions::new()
        .read(true)
        .share_mode(1)
        .custom_flags(0x00200000)
        .open(&path)
        .map_err(|error| format!("Cannot read recovery record: {error}"))?;
    let before = file
        .metadata()
        .map_err(|error| format!("Cannot inspect recovery record: {error}"))?;
    if !before.is_file() || before.file_attributes() & REPARSE_OR_ENCRYPTED != 0 {
        return Err(
            "Recovery record must be a regular, unencrypted file without reparse points.".into(),
        );
    }
    if before.file_size() > BACKUP_FILE_LIMIT {
        return Err("Recovery record exceeds the 4 MiB safety limit.".into());
    }
    let mut bytes = Vec::with_capacity(before.file_size() as usize);
    (&mut file)
        .take(BACKUP_FILE_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|error| format!("Cannot read recovery record: {error}"))?;
    if bytes.len() as u64 > BACKUP_FILE_LIMIT {
        return Err("Recovery record exceeds the 4 MiB safety limit.".into());
    }
    let after = file
        .metadata()
        .map_err(|error| format!("Cannot verify recovery record: {error}"))?;
    if before.file_size() != after.file_size()
        || before.last_write_time() != after.last_write_time()
    {
        return Err("Recovery record changed while it was being read. Select it again.".into());
    }
    let payload = bytes.strip_prefix(UTF8_SIGNATURE).unwrap_or(&bytes);
    let backup: BackupRecord = serde_json::from_slice(payload)
        .map_err(|error| format!("Recovery record is not valid UTF-8 JSON: {error}"))?;
    validate_backup(&backup, map, sid)?;
    Ok(backup)
}

fn evaluate_restore_preview(
    backup: &BackupRecord,
    map: &[Mapping],
    sid: &str,
    current: &BTreeMap<String, StoredFolderValue>,
    recovery: &Path,
) -> Result<RestorePreview> {
    validate_backup(backup, map, sid)?;
    let mut rows = Vec::new();
    for desired in &backup.values {
        let item = map
            .iter()
            .find(|item| item.value_name.eq_ignore_ascii_case(&desired.name))
            .ok_or("Backup contains an unsupported folder value.")?;
        let before = current
            .get(&desired.name)
            .ok_or("Current snapshot omitted a restore value.")?;
        for raw in [
            before.data.as_deref().filter(|_| before.exists),
            desired.data.as_deref().filter(|_| desired.exists),
        ]
        .into_iter()
        .flatten()
        {
            let path = normalize_local_path(Path::new(raw))?;
            if is_inside_or_equal(recovery, &path)? {
                return Err("Recovery storage is inside a source or destination folder. Resolve this before applying.".into());
            }
        }
        if desired.exists {
            let path = normalize_local_path(Path::new(
                desired
                    .data
                    .as_deref()
                    .ok_or("Restore value has no data.")?,
            ))?;
            if !fs::metadata(&path).is_ok_and(|metadata| metadata.is_dir()) {
                return Err(format!(
                    "Restore destination is unavailable: {}",
                    path.display()
                ));
            }
        }
        let action = if !desired.exists {
            "Remove value"
        } else if !before.exists {
            "Add missing value"
        } else if before.kind == desired.kind.as_deref() && before.data == desired.data {
            "Already configured"
        } else {
            "Update value"
        };
        rows.push(RestorePreviewRow {
            folder: folder_label(item),
            value_name: desired.name.clone(),
            current_exists: before.exists,
            current_kind: before.kind,
            current: before.data.clone(),
            proposed_exists: desired.exists,
            proposed_kind: desired.kind.clone(),
            proposed: desired.data.clone(),
            action,
        });
    }
    Ok(RestorePreview {
        operation: "restore",
        recovery_root: text(recovery)?,
        rows,
    })
}

fn persist_backup_new(
    path: &Path,
    backup: &BackupRecord,
    map: &[Mapping],
    sid: &str,
) -> Result<()> {
    validate_backup(backup, map, sid)?;
    let path = normalize_local_path(path)?;
    let parent = path
        .parent()
        .ok_or("Recovery file has no parent directory.")?;
    let parent_meta = guarded_metadata(parent)?
        .ok_or("Recovery directory must already exist before saving a backup.")?;
    if !parent_meta.is_dir() {
        return Err("Recovery file parent is not a directory.".into());
    }
    let mut bytes = UTF8_BOM.to_vec();
    bytes.extend(serde_json::to_vec(backup).map_err(|error| error.to_string())?);
    if bytes.len() > BACKUP_BYTE_LIMIT {
        return Err("Recovery record exceeds the 4 MiB safety limit.".into());
    }
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .share_mode(0)
            .custom_flags(0x00200000)
            .open(&path)
            .map_err(|error| format!("Cannot create recovery file without overwriting: {error}"))?;
        file.write_all(&bytes)
            .map_err(|error| format!("Cannot write recovery record: {error}"))?;
        file.sync_all()
            .map_err(|error| format!("Cannot flush recovery record: {error}"))?;
        drop(file);

        let persisted = fs::read(&path)
            .map_err(|error| format!("Cannot read back recovery record: {error}"))?;
        if persisted.len() > BACKUP_BYTE_LIMIT {
            return Err("Recovery record exceeds the 4 MiB safety limit after write.".into());
        }
        let payload = persisted
            .strip_prefix(UTF8_BOM)
            .ok_or("Recovery record is missing its UTF-8 signature.")?;
        let reopened: BackupRecord = serde_json::from_slice(payload)
            .map_err(|error| format!("Recovery record could not be parsed after write: {error}"))?;
        validate_backup(&reopened, map, sid)?;
        let mut round_trip = UTF8_BOM.to_vec();
        round_trip.extend(serde_json::to_vec(&reopened).map_err(|error| error.to_string())?);
        if round_trip != bytes {
            return Err("Recovery record round-trip did not preserve exact values.".into());
        }
        Ok(())
    })();
    result
}

fn same_live_value(left: &StoredFolderValue, right: &StoredFolderValue) -> bool {
    left.exists == right.exists && left.kind == right.kind && left.data == right.data
}

trait FolderRegistry {
    fn read(&mut self, name: &str) -> Result<Option<StoredFolderValue>>;
    fn write(&mut self, name: &str, kind: &'static str, data: &str) -> Result<()>;
    fn remove(&mut self, name: &str) -> Result<()>;
}

struct CurrentUserFolderRegistry;

impl FolderRegistry for CurrentUserFolderRegistry {
    fn read(&mut self, name: &str) -> Result<Option<StoredFolderValue>> {
        Ok(read_named_folder_values([name])?.remove(name))
    }

    fn write(&mut self, name: &str, kind: &'static str, data: &str) -> Result<()> {
        write_named_folder_value(
            name,
            &StoredFolderValue {
                exists: true,
                kind: Some(kind),
                data: Some(data.to_owned()),
            },
        )
    }

    fn remove(&mut self, name: &str) -> Result<()> {
        write_named_folder_value(
            name,
            &StoredFolderValue {
                exists: false,
                kind: None,
                data: None,
            },
        )
    }
}

fn write_named_folder_value(name: &str, value: &StoredFolderValue) -> Result<()> {
    let key = open_key(HKEY_CURRENT_USER, SHELL_KEY, KEY_SET_VALUE)?
        .ok_or("The current-user folder settings key is unavailable.")?;
    let name_wide = wide(name);
    let status = if value.exists {
        let data = value
            .data
            .as_deref()
            .ok_or("A present registry value has no data.")?;
        let kind = match value.kind {
            Some("String") => REG_SZ,
            Some("ExpandString") => REG_EXPAND_SZ,
            _ => return Err("A registry value has an unsupported type.".into()),
        };
        let mut bytes = Vec::with_capacity((data.encode_utf16().count() + 1) * 2);
        for unit in data.encode_utf16().chain(Some(0)) {
            bytes.extend_from_slice(&unit.to_le_bytes());
        }
        // SAFETY: key and name are live, the UTF-16 payload is terminated, and its byte count
        // is checked before it is passed to the registry API.
        unsafe {
            RegSetValueExW(
                key.0,
                name_wide.as_ptr(),
                0,
                kind,
                bytes.as_ptr(),
                u32::try_from(bytes.len()).map_err(|_| "Registry value is too large.")?,
            )
        }
    } else {
        // SAFETY: key is open for value writes and name is NUL-terminated.
        unsafe { RegDeleteValueW(key.0, name_wide.as_ptr()) }
    };
    if status == ERROR_SUCCESS || (!value.exists && status == ERROR_FILE_NOT_FOUND) {
        Ok(())
    } else {
        Err(format!(
            "Cannot {} registry value {name} (Windows error {status}).",
            if value.exists { "write" } else { "remove" }
        ))
    }
}

fn apply_checked_transaction(
    registry: &mut impl FolderRegistry,
    before: &BTreeMap<String, StoredFolderValue>,
    desired: &[BackupValue],
) -> Result<()> {
    let mut touched = Vec::new();
    for value in desired {
        let original = before
            .get(&value.name)
            .ok_or("Original snapshot omitted a managed registry value.")?;
        touched.push((value.name.as_str(), original));
        let operation = (|| {
            if value.exists {
                let kind = value
                    .kind
                    .as_deref()
                    .filter(|kind| kind.eq_ignore_ascii_case("String"))
                    .map_or("ExpandString", |_| "String");
                registry.write(
                    &value.name,
                    kind,
                    value
                        .data
                        .as_deref()
                        .ok_or("Missing desired registry data.")?,
                )?;
            } else {
                registry.remove(&value.name)?;
            }
            let actual = registry
                .read(&value.name)?
                .ok_or("Registry read-back omitted a changed value.")?;
            let expected = StoredFolderValue {
                exists: value.exists,
                kind: value.kind.as_deref().map(|kind| {
                    if kind.eq_ignore_ascii_case("String") {
                        "String"
                    } else {
                        "ExpandString"
                    }
                }),
                data: value.data.clone(),
            };
            if !same_live_value(&actual, &expected) {
                return Err(format!("Registry verification failed for {}.", value.name));
            }
            Ok(())
        })();
        if let Err(cause) = operation {
            let mut rollback_errors = Vec::new();
            for (name, original) in touched.iter().rev() {
                let restore = if original.exists {
                    registry.write(
                        name,
                        original.kind.ok_or("Original registry type is missing.")?,
                        original
                            .data
                            .as_deref()
                            .ok_or("Original registry data is missing.")?,
                    )
                } else {
                    registry.remove(name)
                };
                if let Err(error) = restore {
                    rollback_errors.push(error);
                    continue;
                }
                match registry.read(name) {
                    Ok(Some(actual)) if same_live_value(&actual, original) => {}
                    Ok(_) => {
                        rollback_errors.push(format!("Rollback verification failed for {name}."))
                    }
                    Err(error) => rollback_errors.push(error),
                }
            }
            return if rollback_errors.is_empty() {
                Err(format!("{cause} Rollback verified."))
            } else {
                Err(format!(
                    "{cause} ROLLBACK INCOMPLETE: {}",
                    rollback_errors.join("; ")
                ))
            };
        }
    }
    Ok(())
}

fn apply_registry_transaction(
    before: &BTreeMap<String, StoredFolderValue>,
    desired: &[BackupValue],
) -> Result<()> {
    apply_checked_transaction(&mut CurrentUserFolderRegistry, before, desired)
}

fn derive_copy_pairs(
    map: &[Mapping],
    root: &Path,
    include_music: bool,
    custom: &BTreeMap<String, PathBuf>,
    shell_paths: &BTreeMap<String, String>,
) -> Result<Vec<CopyPair>> {
    let (_, targets) = folder_targets(map, root, include_music, custom)?;
    let mut pairs = Vec::new();
    let mut unique = BTreeSet::new();
    for item in map.iter().filter(|item| include_music || !item.optional) {
        let Some(raw) = shell_paths.get(&item.value_name) else {
            continue;
        };
        let source = normalize_local_path(Path::new(raw))?;
        let label = if item.relative_path == "Videos\\Captures" {
            "Captures"
        } else {
            &item.relative_path
        };
        let destination = &targets[label];
        if OrdinalPath::new(&source)? == OrdinalPath::new(destination)? {
            continue;
        }
        let identity = (OrdinalPath::new(&source)?, OrdinalPath::new(destination)?);
        if unique.insert(identity) {
            pairs.push(CopyPair {
                source,
                destination: destination.clone(),
            });
        }
    }
    Ok(pairs)
}

fn copy_pairs(
    map: &[Mapping],
    root: &Path,
    include_music: bool,
    custom: &BTreeMap<String, PathBuf>,
) -> Result<Vec<CopyPair>> {
    let (root, _) = folder_targets(map, root, include_music, custom)?;
    if !fs::metadata(&root).is_ok_and(|meta| meta.is_dir()) {
        return Err("Choose an existing iCloud Drive folder.".into());
    }
    let sid = user_sid()?;
    let registered = registered_roots(&sid)?;
    let root_text = text(&root)?;
    if !registered.is_empty()
        && !registered
            .iter()
            .any(|candidate| paths_equal(candidate, &root_text))
    {
        return Err(
            "The selected folder does not match your registered iCloud Drive location.".into(),
        );
    }
    let values = read_folder_values(map, include_music)?;
    let paths = values
        .into_iter()
        .filter_map(|(name, value)| value.data.map(|data| (name, data)))
        .collect();
    derive_copy_pairs(map, &root, include_music, custom, &paths)
}

fn folder_label(item: &Mapping) -> String {
    let folder = if item.relative_path == "Videos\\Captures" {
        "Captures"
    } else {
        &item.relative_path
    };
    let canonical = matches!(
        item.value_name.as_str(),
        "{374DE290-123F-4565-9164-39C4925E467B}" | "{EDC0FE71-98D8-4F4A-B920-C8DC133CB165}"
    );
    if item.value_name.starts_with('{') && !canonical {
        format!("{folder} (local alias)")
    } else {
        folder.to_owned()
    }
}

fn preview_action(current: &StoredFolderValue, proposed: &str) -> &'static str {
    if !current.exists {
        "Add missing value"
    } else if current.kind == Some("ExpandString") && current.data.as_deref() == Some(proposed) {
        "Already configured"
    } else {
        "Update value"
    }
}

fn make_preview_rows(
    map: &[Mapping],
    include_music: bool,
    targets: &BTreeMap<String, PathBuf>,
    values: &BTreeMap<String, StoredFolderValue>,
) -> Result<Vec<PreviewRow>> {
    let mut rows = Vec::new();
    for item in map.iter().filter(|item| include_music || !item.optional) {
        let label_key = if item.relative_path == "Videos\\Captures" {
            "Captures"
        } else {
            &item.relative_path
        };
        let proposed = text(&targets[label_key])?;
        let absent = StoredFolderValue {
            exists: false,
            kind: None,
            data: None,
        };
        let current = values.get(&item.value_name).unwrap_or(&absent);
        rows.push(PreviewRow {
            folder: folder_label(item),
            value_name: item.value_name.clone(),
            current: current.data.clone(),
            current_exists: current.exists,
            current_kind: current.kind,
            proposed: proposed.clone(),
            proposed_kind: "ExpandString",
            action: preview_action(current, &proposed),
        });
    }
    Ok(rows)
}

fn recovery_root() -> Result<PathBuf> {
    let local = std::env::var_os("LOCALAPPDATA")
        .ok_or("The current user's local application-data folder is unavailable.")?;
    normalize_local_path(&PathBuf::from(local).join("ICloudFolderSettler\\Recovery"))
}

fn ensure_private_recovery_directory(path: &Path, sid: &str) -> Result<()> {
    if let Some(metadata) = guarded_metadata(path)? {
        if !metadata.is_dir() {
            return Err("The recovery path is not a directory.".into());
        }
    }
    let path_text = text(path)?;
    let path_wide = wide(&path_text);
    let descriptor_text = wide(&format!("D:P(A;OICI;FA;;;{sid})(A;OICI;FA;;;SY)"));
    let mut descriptor = std::ptr::null_mut();
    // SAFETY: the SDDL string is built from the current Windows SID and valid fixed ACEs; the
    // API allocates a self-relative descriptor that is released below with LocalFree.
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            descriptor_text.as_ptr(),
            1,
            &mut descriptor,
            std::ptr::null_mut(),
        )
    } == 0
    {
        return Err(format!(
            "Cannot prepare private recovery permissions (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    let descriptor = LocalAllocation(descriptor.cast());
    let mut attributes = SECURITY_ATTRIBUTES::default();
    attributes.nLength = std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32;
    attributes.lpSecurityDescriptor = descriptor.0.cast();
    // SAFETY: path and security descriptor remain live for this call. The protected DACL grants
    // full control to this account and LocalSystem, and propagates only to children.
    let created = unsafe { CreateDirectoryW(path_wide.as_ptr(), &attributes) };
    if created == 0 {
        let error = unsafe { GetLastError() };
        if error != ERROR_ALREADY_EXISTS {
            return Err(format!(
                "Cannot create private recovery directory (Windows error {error})."
            ));
        }
    }
    // Apply the same protected ACL when the directory already exists, then verify it is a real
    // directory without a reparse point before trusting it for backups.
    // SAFETY: descriptor and path remain valid for this call.
    if unsafe {
        SetFileSecurityW(
            path_wide.as_ptr(),
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor.0.cast(),
        )
    } == 0
    {
        return Err(format!(
            "Cannot secure the recovery directory (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    let metadata =
        guarded_metadata(path)?.ok_or("The recovery directory disappeared after creation.")?;
    if !metadata.is_dir() {
        return Err("The recovery path is not a directory.".into());
    }
    Ok(())
}

fn create_recovery_run_directory(root: &Path, sid: &str) -> Result<PathBuf> {
    let parent = root
        .parent()
        .ok_or("Recovery directory has no application-data parent.")?;
    ensure_private_recovery_directory(parent, sid)?;
    ensure_private_recovery_directory(root, sid)?;
    for attempt in 0..16u32 {
        let tick = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| "System clock is before the Unix epoch.")?
            .as_nanos();
        let path = root.join(format!("{:x}-{:x}-{attempt}", std::process::id(), tick));
        let path_wide = wide(&text(&path)?);
        // SAFETY: the recovery directory is secured and the candidate path is NUL-terminated;
        // CreateDirectoryW atomically refuses to reuse an existing run directory.
        if unsafe { CreateDirectoryW(path_wide.as_ptr(), std::ptr::null()) } != 0 {
            ensure_private_recovery_directory(&path, sid)?;
            return Ok(path);
        }
        let error = unsafe { GetLastError() };
        if error != ERROR_ALREADY_EXISTS {
            return Err(format!(
                "Cannot create a unique recovery run directory (Windows error {error})."
            ));
        }
    }
    Err("Could not allocate a unique recovery run directory.".into())
}

fn backup_from_preview(
    preview: &FolderPreview,
    map: &[Mapping],
    sid: &str,
) -> Result<BackupRecord> {
    if preview.rows.is_empty() {
        return Err("The reviewed plan contains no managed folder values.".into());
    }
    let mut values = Vec::with_capacity(preview.rows.len());
    let mut seen = BTreeSet::new();
    for row in &preview.rows {
        if !map.iter().any(|item| item.value_name == row.value_name)
            || !seen.insert(row.value_name.to_ascii_lowercase())
        {
            return Err(
                "The reviewed plan contains an unsupported or duplicate registry value.".into(),
            );
        }
        values.push(BackupValue {
            name: row.value_name.clone(),
            exists: row.current_exists,
            kind: row.current_kind.map(str::to_owned),
            data: row.current.clone(),
        });
    }
    let mut timestamp = SYSTEMTIME::default();
    // SAFETY: GetSystemTime writes a complete SYSTEMTIME to this live local value.
    unsafe { GetSystemTime(&mut timestamp) };
    Ok(BackupRecord {
        version: 1,
        sid: sid.to_owned(),
        key: SHELL_KEY.to_owned(),
        _created_utc: Some(format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}0000Z",
            timestamp.wYear,
            timestamp.wMonth,
            timestamp.wDay,
            timestamp.wHour,
            timestamp.wMinute,
            timestamp.wSecond,
            timestamp.wMilliseconds
        )),
        values,
    })
}

fn snapshot_from_backup(backup: &BackupRecord) -> BTreeMap<String, StoredFolderValue> {
    backup
        .values
        .iter()
        .map(|value| {
            (
                value.name.clone(),
                StoredFolderValue {
                    exists: value.exists,
                    kind: value.kind.as_deref().map(|kind| {
                        if kind.eq_ignore_ascii_case("String") {
                            "String"
                        } else {
                            "ExpandString"
                        }
                    }),
                    data: value.data.clone(),
                },
            )
        })
        .collect()
}

fn desired_from_preview(preview: &FolderPreview) -> Vec<BackupValue> {
    preview
        .rows
        .iter()
        .map(|row| BackupValue {
            name: row.value_name.clone(),
            exists: true,
            kind: Some(row.proposed_kind.to_owned()),
            data: Some(row.proposed.clone()),
        })
        .collect()
}

fn ensure_destination_access(paths: impl IntoIterator<Item = PathBuf>) -> Result<()> {
    let mut seen = BTreeSet::new();
    for path in paths {
        let identity = OrdinalPath::new(&path)?;
        if !seen.insert(identity) {
            continue;
        }
        validate_path(&path)?;
        guarded_metadata(&path)?;
        fs::create_dir_all(&path).map_err(|error| {
            format!(
                "Cannot create destination directory {}: {error}",
                path.display()
            )
        })?;
        let metadata = guarded_metadata(&path)?
            .ok_or("A destination directory disappeared after creation.")?;
        if !metadata.is_dir() {
            return Err(format!(
                "Destination path is not a directory: {}",
                path.display()
            ));
        }
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| "System clock is before the Unix epoch.")?
            .as_nanos();
        let probe = path.join(format!(
            ".icloud-folder-probe-{}-{unique}",
            std::process::id()
        ));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .share_mode(0)
            .open(&probe)
            .map_err(|error| {
                format!(
                    "Cannot test destination write access at {}: {error}",
                    path.display()
                )
            })?;
        let write_result = file
            .write_all(b"iCloud folder destination probe")
            .and_then(|()| file.sync_all());
        drop(file);
        if let Err(error) = write_result {
            return Err(format!("Cannot write destination access probe: {error}"));
        }
        fs::remove_file(&probe).map_err(|error| {
            format!("Cannot remove the uniquely created destination probe: {error}")
        })?;
    }
    Ok(())
}

fn write_operation_log(path: &Path, line: &str, create: bool) -> Result<()> {
    let mut options = OpenOptions::new();
    options
        .write(true)
        .append(!create)
        .create_new(create)
        .share_mode(0);
    let mut file = options
        .open(path)
        .map_err(|error| format!("Cannot update operation log: {error}"))?;
    file.write_all(line.as_bytes())
        .and_then(|()| file.write_all(b"\r\n"))
        .and_then(|()| file.sync_all())
        .map_err(|error| format!("Cannot flush operation log: {error}"))
}

fn apply_reviewed_preview(map: &[Mapping], preview: &FolderPreview, sid: &str) -> Result<PathBuf> {
    if !preview.review_gates_passed || !preview.content_warnings.is_empty() {
        return Err("Preview review gates did not pass. No folder settings were changed.".into());
    }
    let backup = backup_from_preview(preview, map, sid)?;
    validate_backup(&backup, map, sid)?;
    let before = snapshot_from_backup(&backup);
    let desired = desired_from_preview(preview);
    if desired.len() != before.len() {
        return Err("Reviewed plan and backup snapshot do not have matching values.".into());
    }

    let recovery = recovery_root()?;
    let run_directory = create_recovery_run_directory(&recovery, sid)?;
    let backup_path = run_directory.join("before.json");
    if let Err(error) = persist_backup_new(&backup_path, &backup, map, sid) {
        return Err(format!(
            "{error} Recovery backup path: {}",
            backup_path.display()
        ));
    }
    let log_path = run_directory.join("operation.log");
    write_operation_log(&log_path, "Started settings transaction.", true)
        .map_err(|error| format!("{error} Recovery backup: {}", backup_path.display()))?;

    let destinations = preview.rows.iter().map(|row| PathBuf::from(&row.proposed));
    if let Err(error) = ensure_destination_access(destinations) {
        let _ = write_operation_log(&log_path, &error, false);
        return Err(format!(
            "{error} No registry values were changed. Recovery backup: {}",
            backup_path.display()
        ));
    }

    let current = read_named_folder_values(before.keys().map(String::as_str)).map_err(|error| {
        format!(
            "{error} No registry values were changed. Recovery backup: {}",
            backup_path.display()
        )
    })?;
    if current.len() != before.len()
        || before.iter().any(|(name, original)| {
            current
                .get(name)
                .is_none_or(|actual| !same_live_value(actual, original))
        })
    {
        let message = "Settings changed after the recovery backup was written. Preview again; no settings were changed.";
        let _ = write_operation_log(&log_path, message, false);
        return Err(format!(
            "{message} Recovery backup: {}",
            backup_path.display()
        ));
    }

    if let Err(error) = apply_registry_transaction(&before, &desired) {
        let _ = write_operation_log(&log_path, &error, false);
        return Err(format!(
            "{error} Recovery backup: {}",
            backup_path.display()
        ));
    }
    write_operation_log(&log_path, "All registry values were verified.", false).map_err(
        |error| {
            format!(
                "Settings were applied and verified, but {error} Recovery backup: {}",
                backup_path.display()
            )
        },
    )?;
    Ok(backup_path)
}

fn apply_reviewed_restore(map: &[Mapping], preview: &RestorePreview, sid: &str) -> Result<PathBuf> {
    if preview.rows.is_empty() {
        return Err("The recovery preview contains no values to restore.".into());
    }
    let before_backup = BackupRecord {
        version: 1,
        sid: sid.to_owned(),
        key: SHELL_KEY.to_owned(),
        _created_utc: None,
        values: preview
            .rows
            .iter()
            .map(|row| BackupValue {
                name: row.value_name.clone(),
                exists: row.current_exists,
                kind: row.current_kind.map(str::to_owned),
                data: row.current.clone(),
            })
            .collect(),
    };
    validate_backup(&before_backup, map, sid)?;
    let before = snapshot_from_backup(&before_backup);
    let desired = preview
        .rows
        .iter()
        .map(|row| BackupValue {
            name: row.value_name.clone(),
            exists: row.proposed_exists,
            kind: row.proposed_kind.clone(),
            data: row.proposed.clone(),
        })
        .collect::<Vec<_>>();
    let recovery = recovery_root()?;
    let run_directory = create_recovery_run_directory(&recovery, sid)?;
    let backup_path = run_directory.join("before.json");
    if let Err(error) = persist_backup_new(&backup_path, &before_backup, map, sid) {
        return Err(format!(
            "{error} Recovery backup path: {}",
            backup_path.display()
        ));
    }
    let log_path = run_directory.join("operation.log");
    write_operation_log(&log_path, "Started recovery restore transaction.", true)
        .map_err(|error| format!("{error} Recovery backup: {}", backup_path.display()))?;

    let current = read_named_folder_values(before.keys().map(String::as_str)).map_err(|error| {
        format!(
            "{error} No registry values were changed. Recovery backup: {}",
            backup_path.display()
        )
    })?;
    if current.len() != before.len()
        || before.iter().any(|(name, original)| {
            current
                .get(name)
                .is_none_or(|actual| !same_live_value(actual, original))
        })
    {
        let message = "Settings changed after the recovery backup was written. Preview again; no settings were changed.";
        let _ = write_operation_log(&log_path, message, false);
        return Err(format!(
            "{message} Recovery backup: {}",
            backup_path.display()
        ));
    }
    if let Err(error) = apply_registry_transaction(&before, &desired) {
        let _ = write_operation_log(&log_path, &error, false);
        return Err(format!(
            "{error} Recovery backup: {}",
            backup_path.display()
        ));
    }
    write_operation_log(
        &log_path,
        "All restored registry values were verified.",
        false,
    )
    .map_err(|error| {
        format!(
            "Settings were applied and verified, but {error} Recovery backup: {}",
            backup_path.display()
        )
    })?;
    Ok(backup_path)
}

fn ensure_directory_path(path: &Path) -> Result<()> {
    let mut current = Some(path);
    while let Some(candidate) = current {
        match fs::metadata(candidate) {
            Ok(meta) if !meta.is_dir() => {
                return Err(format!(
                    "Path is occupied by a file: {}",
                    candidate.display()
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(format!("Cannot inspect destination path: {error}")),
        }
        current = candidate.parent();
    }
    Ok(())
}

fn is_inside_or_equal(candidate: &Path, containing: &Path) -> Result<bool> {
    Ok(
        paths_equal(&text(candidate)?, &text(containing)?)
            || path_is_within(candidate, containing)?,
    )
}

fn finish_preview(
    map: &[Mapping],
    reset: bool,
    root: Option<PathBuf>,
    include_music: bool,
    allow_existing_content: bool,
    verified_sync_root: bool,
    targets: BTreeMap<String, PathBuf>,
    values: &BTreeMap<String, StoredFolderValue>,
    registered: Vec<String>,
    root_registered: Option<bool>,
    registration_ok: bool,
    recovery: &Path,
) -> Result<FolderPreview> {
    let rows = make_preview_rows(map, include_music, &targets, values)?;
    let mut warnings = Vec::new();
    let mut destinations = BTreeSet::new();
    for item in map.iter().filter(|item| include_music || !item.optional) {
        let label = if item.relative_path == "Videos\\Captures" {
            "Captures"
        } else {
            &item.relative_path
        };
        let destination = &targets[label];
        if destinations.insert(OrdinalPath::new(destination)?) {
            ensure_directory_path(destination)?;
            if is_inside_or_equal(recovery, destination)? {
                return Err("Recovery storage is inside a destination folder. Resolve this before applying.".into());
            }
        }
        let Some(value) = values.get(&item.value_name).filter(|value| value.exists) else {
            continue;
        };
        let source_text = value
            .data
            .as_deref()
            .ok_or("A current registry value has no data.")?;
        let source = normalize_local_path(Path::new(source_text))?;
        if is_inside_or_equal(recovery, &source)? {
            return Err(
                "Recovery storage is inside a source folder. Resolve this before applying.".into(),
            );
        }
        if !paths_equal(&text(&source)?, &text(destination)?) {
            match fs::metadata(&source) {
                Ok(meta) if meta.is_dir() => {
                    let mut children = fs::read_dir(&source).map_err(|error| error.to_string())?;
                    if children
                        .next()
                        .transpose()
                        .map_err(|error| error.to_string())?
                        .is_some()
                        && !allow_existing_content
                    {
                        let message = format!(
                            "Existing content at '{}'. No files are moved. Review it, then use -AllowExistingContent to redirect anyway.",
                            source.display()
                        );
                        if !warnings.contains(&message) {
                            warnings.push(message);
                        }
                    }
                }
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(format!("Cannot inspect a source folder: {error}")),
            }
        }
    }
    let root_text = root.as_ref().map(|path| text(path)).transpose()?;
    let recovery_text = text(recovery)?;
    let review_gates_passed = warnings.is_empty() && registration_ok;
    Ok(FolderPreview {
        operation: if reset { "reset" } else { "setup" },
        root: root_text,
        recovery_root: recovery_text,
        registered_roots: registered,
        root_registered,
        verified_sync_root,
        review_gates_passed,
        rows,
        content_warnings: warnings,
    })
}

fn preview(
    map: &[Mapping],
    reset: bool,
    root: Option<&Path>,
    include_music: bool,
    allow_existing_content: bool,
    verified_sync_root: bool,
    custom: &BTreeMap<String, PathBuf>,
) -> Result<FolderPreview> {
    if reset && (!custom.is_empty() || include_music) {
        return Err("Windows-default reset includes every managed folder and cannot use custom destinations.".into());
    }
    let (root, targets, include_music) = if reset {
        let defaults = defaults(map)?;
        let mut targets = BTreeMap::new();
        for folder in defaults {
            targets.insert(folder.folder, PathBuf::from(folder.path));
        }
        for item in map {
            let key = if item.relative_path == "Videos\\Captures" {
                "Captures"
            } else {
                &item.relative_path
            };
            if !targets.contains_key(key) {
                return Err(format!(
                    "Windows did not provide the default path for {key}."
                ));
            }
        }
        (None, targets, true)
    } else {
        let root = root.ok_or("An iCloud root is required for setup preview.")?;
        let (root, targets) = folder_targets(map, root, include_music, custom)?;
        if !fs::metadata(&root).is_ok_and(|meta| meta.is_dir()) {
            return Err(format!(
                "iCloud root must already exist: {}",
                root.display()
            ));
        }
        (Some(root), targets, include_music)
    };

    let values = read_folder_values(map, include_music)?;
    let recovery = recovery_root()?;
    let mut registered = Vec::new();
    let mut root_registered = None;
    let mut registration_ok = true;
    if let Some(root) = root.as_ref() {
        let sid = user_sid()?;
        registered = registered_roots(&sid)?;
        let root_text = text(root)?;
        root_registered = Some(
            registered
                .iter()
                .any(|candidate| paths_equal(candidate, &root_text)),
        );
        registration_ok = if registered.is_empty() {
            verified_sync_root
        } else {
            root_registered.unwrap_or(false)
        };
    }

    finish_preview(
        map,
        reset,
        root,
        include_music,
        allow_existing_content,
        verified_sync_root,
        targets,
        &values,
        registered,
        root_registered,
        registration_ok,
        &recovery,
    )
}

fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789ABCDEF";
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        text.push(DIGITS[(byte >> 4) as usize] as char);
        text.push(DIGITS[(byte & 15) as usize] as char);
    }
    text
}

// Windows ordinal case comparison, rather than Unicode lowercase approximations.
struct OrdinalPath(Vec<u16>);
impl PartialEq for OrdinalPath {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for OrdinalPath {}
impl OrdinalPath {
    fn new(path: &Path) -> Result<Self> {
        Ok(Self(text(path)?.encode_utf16().collect()))
    }
}
impl Ord for OrdinalPath {
    fn cmp(&self, other: &Self) -> Ordering {
        // SAFETY: paths are validated below the Windows length limit; both slices live through this call.
        match unsafe {
            CompareStringOrdinal(
                self.0.as_ptr(),
                self.0.len() as i32,
                other.0.as_ptr(),
                other.0.len() as i32,
                1,
            )
        } {
            1 => Ordering::Less,
            2 => Ordering::Equal,
            3 => Ordering::Greater,
            _ => unreachable!("validated slices are valid CompareStringOrdinal arguments"),
        }
    }
}
impl PartialOrd for OrdinalPath {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

fn paths_equal(left: &str, right: &str) -> bool {
    match (
        OrdinalPath::new(Path::new(left)),
        OrdinalPath::new(Path::new(right)),
    ) {
        (Ok(left), Ok(right)) => left == right,
        _ => false,
    }
}

fn text(path: &Path) -> Result<String> {
    path.to_str().map(String::from).ok_or_else(|| {
        "Paths containing unpaired UTF-16 surrogates are not supported by this prototype.".into()
    })
}

fn validate_path(path: &Path) -> Result<()> {
    if !path.is_absolute() || path.as_os_str().len() > 32000 {
        return Err("Choose an absolute drive or UNC path shorter than 32,000 bytes.".into());
    }
    for component in path.components() {
        match component {
            Component::Prefix(p) if matches!(p.kind(), Prefix::Disk(_) | Prefix::UNC(_, _)) => {}
            Component::RootDir => {}
            Component::Normal(s) => {
                let s = s.to_str().ok_or("Unsupported path encoding.")?;
                let stem = s.split('.').next().unwrap_or("").to_ascii_uppercase();
                let device = matches!(
                    stem.as_str(),
                    "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
                ) || ["COM", "LPT"].iter().any(|p| {
                    stem.strip_prefix(p).is_some_and(|n| {
                        matches!(
                            n,
                            "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
                        )
                    })
                });
                if s.contains([':', '\0', '*', '?', '"', '<', '>', '|'])
                    || s.ends_with(['.', ' '])
                    || device
                {
                    return Err("Device names, alternate streams and ambiguous path components are refused.".into());
                }
            }
            _ => return Err("Relative, parent and device paths are refused.".into()),
        }
    }
    text(path)?;
    Ok(())
}

const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
const FILE_ATTRIBUTE_ENCRYPTED: u32 = 0x4000;

fn cloud_file_reparse_tag(path: &Path) -> Result<u32> {
    let name = wide(&text(path)?);
    // SAFETY: the path is a validated, NUL-terminated UTF-16 string. OPEN_REPARSE_POINT
    // asks for metadata about the link itself; BACKUP_SEMANTICS also permits directories.
    let handle = unsafe {
        CreateFileW(
            name.as_ptr(),
            FILE_READ_ATTRIBUTES,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS,
            std::ptr::null_mut(),
        )
    };
    if handle == -1isize as HANDLE {
        return Err(format!(
            "Cannot inspect reparse tag (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    let mut info = FILE_ATTRIBUTE_TAG_INFO::default();
    // SAFETY: info is a live, correctly sized FILE_ATTRIBUTE_TAG_INFO output buffer and
    // handle is the live file handle returned by CreateFileW.
    let ok = unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileAttributeTagInfo,
            (&mut info as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
            std::mem::size_of::<FILE_ATTRIBUTE_TAG_INFO>() as u32,
        )
    };
    let error = if ok == 0 {
        Some(unsafe { GetLastError() })
    } else {
        None
    };
    // SAFETY: handle is live and owned by this function.
    unsafe { CloseHandle(handle) };
    if let Some(error) = error {
        return Err(format!(
            "Cannot inspect reparse tag (Windows error {error})."
        ));
    }
    if info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT == 0 {
        return Ok(0);
    }
    Ok(info.ReparseTag)
}

fn is_cloud_file_reparse_tag(tag: u32) -> bool {
    // Match the production PowerShell check: accept IO_REPARSE_TAG_CLOUD and its
    // versioned variants, while keeping links and unrelated reparse providers refused.
    tag & 0xFFFF_0FFF == 0x9000_001A
}

fn guarded_metadata(path: &Path) -> Result<Option<fs::Metadata>> {
    guarded_metadata_with_cloud(path, false)
}

fn guarded_copy_metadata(path: &Path) -> Result<Option<fs::Metadata>> {
    guarded_metadata_with_cloud(path, true)
}

fn guarded_metadata_with_cloud(
    path: &Path,
    allow_cloud_file_or_directory: bool,
) -> Result<Option<fs::Metadata>> {
    let mut result = None;
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(meta) => {
                let attributes = meta.file_attributes();
                if attributes & FILE_ATTRIBUTE_ENCRYPTED != 0 {
                    return Err(format!(
                        "Encrypted paths are not supported by this prototype: {}",
                        path.display()
                    ));
                }
                if attributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
                    if is_cloud_file_reparse_tag(cloud_file_reparse_tag(ancestor)?) {
                        let cloud_directory = meta.is_dir();
                        let cloud_file = ancestor == path && meta.is_file();
                        if allow_cloud_file_or_directory && (cloud_directory || cloud_file) {
                            if ancestor == path {
                                result = Some(meta);
                            }
                            continue;
                        }
                        return Err(format!(
                            "Cloud Files placeholders are supported only for guarded copy planning: {}",
                            path.display()
                        ));
                    }
                    return Err(format!(
                        "Links or unsupported reparse points are not supported by this prototype: {}",
                        path.display()
                    ));
                }
                if ancestor != path && !meta.is_dir() {
                    return Err("A parent path is blocked by a file.".into());
                }
                if ancestor == path {
                    result = Some(meta);
                }
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("Cannot inspect {}: {e}", ancestor.display())),
        }
    }
    Ok(result)
}

struct CngSha256Provider {
    handle: BCRYPT_ALG_HANDLE,
    object_length: u32,
    digest_length: u32,
}

impl CngSha256Provider {
    fn new() -> Result<Self> {
        let mut handle = std::ptr::null_mut();
        // SAFETY: handle points to writable storage, and the algorithm identifier is a static
        // NUL-terminated UTF-16 string supplied by windows-sys.
        let status = unsafe {
            BCryptOpenAlgorithmProvider(&mut handle, BCRYPT_SHA256_ALGORITHM, std::ptr::null(), 0)
        };
        if status < 0 || handle.is_null() {
            return Err(cng_error("open SHA-256 provider", status));
        }
        let mut provider = Self {
            handle,
            object_length: 0,
            digest_length: 0,
        };
        provider.object_length = provider.property_u32(BCRYPT_OBJECT_LENGTH)?;
        provider.digest_length = provider.property_u32(BCRYPT_HASH_LENGTH)?;
        if provider.object_length == 0 || provider.digest_length != 32 {
            return Err("Windows CNG returned unexpected SHA-256 provider sizes.".into());
        }
        Ok(provider)
    }

    fn property_u32(&self, property: windows_sys::core::PCWSTR) -> Result<u32> {
        let mut value = 0u32;
        let mut returned = 0u32;
        // SAFETY: value and returned point to writable storage of the sizes required by CNG.
        let status = unsafe {
            BCryptGetProperty(
                self.handle,
                property,
                (&mut value as *mut u32).cast(),
                std::mem::size_of::<u32>() as u32,
                &mut returned,
                0,
            )
        };
        if status < 0 {
            return Err(cng_error("query SHA-256 provider property", status));
        }
        if returned != std::mem::size_of::<u32>() as u32 {
            return Err("Windows CNG returned an invalid SHA-256 property size.".into());
        }
        Ok(value)
    }

    fn digest_reader(&self, reader: &mut impl Read, buffer: &mut [u8]) -> Result<String> {
        let mut object = vec![0u8; self.object_length as usize];
        let mut handle: BCRYPT_HASH_HANDLE = std::ptr::null_mut();
        // SAFETY: the provider is live and object is writable for its queried provider size.
        let status = unsafe {
            BCryptCreateHash(
                self.handle,
                &mut handle,
                object.as_mut_ptr(),
                self.object_length,
                std::ptr::null(),
                0,
                0,
            )
        };
        if status < 0 || handle.is_null() {
            return Err(cng_error("create SHA-256 hash", status));
        }
        let hash = CngHashObject {
            handle,
            _object: object,
        };
        loop {
            let count = reader.read(buffer).map_err(|error| error.to_string())?;
            if count == 0 {
                break;
            }
            // SAFETY: buffer contains count readable bytes and hash is a live CNG hash object.
            let status = unsafe { BCryptHashData(hash.handle, buffer.as_ptr(), count as u32, 0) };
            if status < 0 {
                return Err(cng_error("hash file data", status));
            }
        }
        let mut digest = vec![0u8; self.digest_length as usize];
        // SAFETY: digest is writable for the provider-reported SHA-256 output length.
        let status =
            unsafe { BCryptFinishHash(hash.handle, digest.as_mut_ptr(), self.digest_length, 0) };
        if status < 0 {
            return Err(cng_error("finish SHA-256 hash", status));
        }
        Ok(hex(&digest))
    }
}

impl Drop for CngSha256Provider {
    fn drop(&mut self) {
        // SAFETY: this provider owns the live algorithm handle returned by CNG.
        unsafe { BCryptCloseAlgorithmProvider(self.handle, 0) };
    }
}

fn approval_token<T: Serialize>(value: &T) -> Result<String> {
    let bytes = serde_json::to_vec(value).map_err(|error| error.to_string())?;
    let mut buffer = vec![0u8; 64 * 1024];
    CngSha256Provider::new()?.digest_reader(&mut io::Cursor::new(bytes), &mut buffer)
}

struct CngHashObject {
    handle: BCRYPT_HASH_HANDLE,
    _object: Vec<u8>,
}

impl Drop for CngHashObject {
    fn drop(&mut self) {
        // SAFETY: the hash object owns the live handle and backing buffer until this drop.
        unsafe { BCryptDestroyHash(self.handle) };
    }
}

struct Win32ReadHandle(HANDLE);

impl Read for Win32ReadHandle {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let requested = buffer.len().min(u32::MAX as usize) as u32;
        let mut bytes_read = 0u32;
        // SAFETY: this handle was opened synchronously for reading and buffer is writable for
        // requested bytes. The OVERLAPPED pointer is null because FILE_FLAG_OVERLAPPED is absent.
        let succeeded = unsafe {
            ReadFile(
                self.0,
                buffer.as_mut_ptr(),
                requested,
                &mut bytes_read,
                std::ptr::null_mut(),
            )
        };
        if succeeded == 0 {
            return Err(io::Error::from_raw_os_error(
                unsafe { GetLastError() } as i32
            ));
        }
        Ok(bytes_read as usize)
    }
}

impl Drop for Win32ReadHandle {
    fn drop(&mut self) {
        // SAFETY: this wrapper owns the valid synchronous file handle returned by CreateFileW.
        unsafe { CloseHandle(self.0) };
    }
}

fn cng_error(operation: &str, status: i32) -> String {
    format!(
        "Windows CNG could not {operation} (NTSTATUS 0x{:08X}).",
        status as u32
    )
}

fn handle_file_tag(handle: HANDLE) -> Result<FILE_ATTRIBUTE_TAG_INFO> {
    let mut info = FILE_ATTRIBUTE_TAG_INFO::default();
    // SAFETY: info is a live, correctly sized output buffer and handle is an owned open handle.
    if unsafe {
        GetFileInformationByHandleEx(
            handle,
            FileAttributeTagInfo,
            (&mut info as *mut FILE_ATTRIBUTE_TAG_INFO).cast(),
            std::mem::size_of::<FILE_ATTRIBUTE_TAG_INFO>() as u32,
        )
    } == 0
    {
        return Err(format!(
            "Cannot inspect file attributes (Windows error {}).",
            unsafe { GetLastError() }
        ));
    }
    Ok(info)
}

fn file_size(info: &BY_HANDLE_FILE_INFORMATION) -> u64 {
    (u64::from(info.nFileSizeHigh) << 32) | u64::from(info.nFileSizeLow)
}

fn stable_file_identity(
    before: &BY_HANDLE_FILE_INFORMATION,
    after: &BY_HANDLE_FILE_INFORMATION,
) -> bool {
    before.dwVolumeSerialNumber == after.dwVolumeSerialNumber
        && before.nFileIndexHigh == after.nFileIndexHigh
        && before.nFileIndexLow == after.nFileIndexLow
        && file_size(before) == file_size(after)
        && before.ftLastWriteTime.dwHighDateTime == after.ftLastWriteTime.dwHighDateTime
        && before.ftLastWriteTime.dwLowDateTime == after.ftLastWriteTime.dwLowDateTime
}

fn hydrate_placeholder_range(handle: HANDLE, offset: u64, length: u64) -> Result<()> {
    let mut overlapped = windows_sys::Win32::System::IO::OVERLAPPED::default();
    overlapped.Anonymous.Anonymous.Offset = offset as u32;
    overlapped.Anonymous.Anonymous.OffsetHigh = (offset >> 32) as u32;
    // SAFETY: the handle names the verified Cloud Files placeholder. The OVERLAPPED structure
    // remains live through GetOverlappedResult if the provider fetch completes asynchronously.
    let status = unsafe {
        windows_sys::Win32::Storage::CloudFilters::CfHydratePlaceholder(
            handle,
            offset as i64,
            length as i64,
            windows_sys::Win32::Storage::CloudFilters::CF_HYDRATE_FLAG_NONE,
            &mut overlapped,
        )
    };
    if status == 0x800703E5u32 as i32 {
        let mut transferred = 0;
        // SAFETY: this is the same handle and OVERLAPPED passed to CfHydratePlaceholder; waiting
        // keeps both alive until the range operation is complete.
        if unsafe {
            windows_sys::Win32::System::IO::GetOverlappedResult(
                handle,
                &overlapped,
                &mut transferred,
                1,
            )
        } == 0
        {
            return Err(format!(
                "Cloud Files hydration failed (Windows error {}).",
                unsafe { GetLastError() }
            ));
        }
    } else if status < 0 {
        return Err(format!(
            "Cloud Files hydration failed (HRESULT 0x{:08X}).",
            status as u32
        ));
    }
    Ok(())
}

fn hydrate_cloud_placeholder(handle: HANDLE, size: u64) -> Result<()> {
    const RANGE_BYTES: u64 = 64 * 1024;
    if size > i64::MAX as u64 {
        return Err("Cloud Files placeholder is too large to hydrate safely.".into());
    }
    let mut offset = 0u64;
    while offset < size {
        let length = RANGE_BYTES.min(size - offset);
        hydrate_placeholder_range(handle, offset, length)?;
        offset += length;
    }
    Ok(())
}

fn hash_cloud_placeholder(
    path: &Path,
    provider: &CngSha256Provider,
    buffer: &mut [u8],
) -> Result<String> {
    use std::os::windows::ffi::OsStrExt;
    let wide_path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    // Open the placeholder itself so hydration cannot follow a replaced final-component link.
    // Share-read excludes concurrent writes and deletion during hydration and hashing.
    let handle = unsafe {
        CreateFileW(
            wide_path.as_ptr(),
            FILE_GENERIC_READ,
            FILE_SHARE_READ,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT
                | windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OVERLAPPED,
            std::ptr::null_mut(),
        )
    };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(format!(
            "Cannot open Cloud Files placeholder {} (Windows error {}).",
            path.display(),
            unsafe { GetLastError() }
        ));
    }
    let placeholder = Win32ReadHandle(handle);
    if unsafe { GetFileType(handle) } != FILE_TYPE_DISK {
        return Err("Cloud Files hydration requires a regular disk file.".into());
    }
    let mut before = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(handle, &mut before) } == 0 {
        return Err(format!(
            "Cannot inspect Cloud Files placeholder {} (Windows error {}).",
            path.display(),
            unsafe { GetLastError() }
        ));
    }
    let tag = handle_file_tag(handle)?;
    if tag.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_ENCRYPTED)
        != FILE_ATTRIBUTE_REPARSE_POINT
        || !is_cloud_file_reparse_tag(tag.ReparseTag)
        || before.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE) != 0
    {
        return Err("The file changed or is not a Cloud Files placeholder.".into());
    }

    hydrate_cloud_placeholder(handle, file_size(&before))?;
    let mut hydrated = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(handle, &mut hydrated) } == 0
        || !stable_file_identity(&before, &hydrated)
    {
        return Err("Cloud Files placeholder metadata changed during hydration.".into());
    }
    drop(placeholder);

    // Reopen through the Cloud Files filter to read the hydrated data stream. The first handle's
    // volume/file identity and metadata must match, preventing a changed path from being hashed.
    let data_handle = unsafe {
        CreateFileW(
            wide_path.as_ptr(),
            FILE_GENERIC_READ,
            FILE_SHARE_READ,
            std::ptr::null(),
            OPEN_EXISTING,
            0,
            std::ptr::null_mut(),
        )
    };
    if data_handle.is_null() || data_handle == INVALID_HANDLE_VALUE {
        return Err(format!(
            "Cannot read hydrated Cloud Files placeholder {} (Windows error {}).",
            path.display(),
            unsafe { GetLastError() }
        ));
    }
    let mut file = Win32ReadHandle(data_handle);
    if unsafe { GetFileType(data_handle) } != FILE_TYPE_DISK {
        return Err("Hydrated Cloud Files data is not a regular disk file.".into());
    }
    let mut data_before = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(data_handle, &mut data_before) } == 0
        || !stable_file_identity(&before, &data_before)
    {
        return Err("The Cloud Files path changed before its hydrated data was read.".into());
    }
    if data_before.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        let data_tag = handle_file_tag(data_handle)?;
        if !is_cloud_file_reparse_tag(data_tag.ReparseTag) {
            return Err("Hydrated data resolved to an unsupported reparse point.".into());
        }
    }
    if data_before.dwFileAttributes
        & (FILE_ATTRIBUTE_ENCRYPTED | FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE)
        != 0
    {
        return Err("Hydrated Cloud Files data is not a regular, unencrypted file.".into());
    }
    let digest = provider.digest_reader(&mut file, buffer)?;
    let mut data_after = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(data_handle, &mut data_after) } == 0
        || !stable_file_identity(&data_before, &data_after)
    {
        return Err(
            "A Cloud Files placeholder changed while being hashed. Run preview again.".into(),
        );
    }
    Ok(digest)
}

fn hash(path: &Path, provider: &CngSha256Provider, buffer: &mut [u8]) -> Result<String> {
    guarded_copy_metadata(path)?;
    use std::os::windows::ffi::OsStrExt;

    let path_tag = cloud_file_reparse_tag(path)?;
    if is_cloud_file_reparse_tag(path_tag) {
        return hash_cloud_placeholder(path, provider, buffer);
    }

    let wide_path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    // Open the final reparse point itself and exclude concurrent writers/deletion, matching the
    // existing OpenOptions share mode while using the Win32 handle directly.
    let handle = unsafe {
        CreateFileW(
            wide_path.as_ptr(),
            FILE_GENERIC_READ,
            FILE_SHARE_READ,
            std::ptr::null(),
            OPEN_EXISTING,
            FILE_FLAG_OPEN_REPARSE_POINT,
            std::ptr::null_mut(),
        )
    };
    if handle.is_null() || handle == INVALID_HANDLE_VALUE {
        return Err(format!(
            "Cannot read {} (Windows error {}).",
            path.display(),
            unsafe { GetLastError() }
        ));
    }
    let mut file = Win32ReadHandle(handle);
    if unsafe { GetFileType(handle) } != FILE_TYPE_DISK {
        return Err("Hashing requires a regular disk file.".into());
    }
    let mut before = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(handle, &mut before) } == 0 {
        return Err(format!(
            "Cannot inspect {} (Windows error {}).",
            path.display(),
            unsafe { GetLastError() }
        ));
    }
    if before.dwFileAttributes
        & (REPARSE_OR_ENCRYPTED | FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_DEVICE)
        != 0
    {
        return Err("Hashing requires a regular, unencrypted file without reparse points.".into());
    }
    let digest = provider.digest_reader(&mut file, buffer)?;
    let mut after = BY_HANDLE_FILE_INFORMATION::default();
    if unsafe { GetFileInformationByHandle(handle, &mut after) } == 0 {
        return Err(format!(
            "Cannot recheck {} after hashing (Windows error {}).",
            path.display(),
            unsafe { GetLastError() }
        ));
    }
    if !stable_file_identity(&before, &after) || after.dwFileAttributes & REPARSE_OR_ENCRYPTED != 0
    {
        return Err("A file changed while being hashed. Run preview again.".into());
    }
    Ok(digest)
}

fn inside(path: &Path, root: &Path) -> Result<bool> {
    let path = path.components().collect::<Vec<_>>();
    let root = root.components().collect::<Vec<_>>();
    if path.len() < root.len() {
        return Ok(false);
    }
    for (a, b) in path.iter().zip(root) {
        if OrdinalPath::new(Path::new(a.as_os_str()))?
            .cmp(&OrdinalPath::new(Path::new(b.as_os_str()))?)
            != Ordering::Equal
        {
            return Ok(false);
        }
    }
    Ok(true)
}

fn plan_entries(pairs: &[CopyPair]) -> Result<Vec<Entry>> {
    const PAIR_LIMIT: usize = 64;
    if pairs.len() > PAIR_LIMIT {
        return Err(format!(
            "Copy plan has more than {PAIR_LIMIT} source pairs."
        ));
    }
    let mut normalized = Vec::with_capacity(pairs.len());
    let mut source_roots = Vec::with_capacity(pairs.len());
    for pair in pairs {
        validate_path(&pair.source)?;
        validate_path(&pair.destination)?;
        normalized.push((pair.source.clone(), pair.destination.clone()));
        source_roots.push(pair.source.as_path());
    }
    let mut queue = VecDeque::new();
    for (source, destination) in normalized {
        if OrdinalPath::new(&source)? == OrdinalPath::new(&destination)? {
            continue;
        }
        for root in &source_roots {
            if inside(&destination, root)? || inside(root, &destination)? {
                return Err(
                    "Copy source and destination trees overlap. Choose non-overlapping folders."
                        .into(),
                );
            }
        }
        if !guarded_copy_metadata(&source)?.is_some_and(|meta| meta.is_dir()) {
            return Err("Source folder is unavailable.".into());
        }
        guarded_copy_metadata(&destination)?;
        if queue.len() >= PAIR_LIMIT {
            return Err(format!(
                "Copy plan has more than {PAIR_LIMIT} source pairs."
            ));
        }
        queue.push_back((source, destination, 0usize));
    }

    let mut buffer = vec![0; 64 * 1024];
    let hash_provider = CngSha256Provider::new()?;
    let mut targets = BTreeMap::<OrdinalPath, (bool, Option<String>)>::new();
    let mut entries = Vec::new();
    let mut visited = 0usize;
    while let Some((source, destination, depth)) = queue.pop_front() {
        validate_path(&source)?;
        validate_path(&destination)?;
        if depth > DEPTH_LIMIT || visited >= ENTRY_LIMIT {
            return Err("Prototype planning limit reached (10,000 entries / 64 levels).".into());
        }
        visited += 1;
        let meta = guarded_copy_metadata(&source)?
            .ok_or("A source entry disappeared. Run preview again.")?;
        let directory = meta.is_dir();
        if !directory && !meta.is_file() {
            return Err("Only regular files and directories are supported.".into());
        }
        let digest = if directory {
            None
        } else {
            Some(hash(&source, &hash_provider, &mut buffer)?)
        };
        let target_key = OrdinalPath::new(&destination)?;
        if let Some((previous_directory, previous_hash)) = targets.get(&target_key) {
            if *previous_directory != directory || (!directory && previous_hash != &digest) {
                return Err(format!(
                    "Different source files map to the same destination: {}",
                    destination.display()
                ));
            }
        } else {
            let target = guarded_copy_metadata(&destination)?;
            let action = match target {
                Some(target) if directory && target.is_dir() => "SkipDirectory",
                Some(target)
                    if !directory
                        && target.is_file()
                        && Some(hash(&destination, &hash_provider, &mut buffer)?) == digest =>
                {
                    "SkipIdentical"
                }
                Some(_) => {
                    return Err(format!(
                        "Destination conflict: {}. Nothing will be overwritten.",
                        destination.display()
                    ));
                }
                None if directory => "CreateDirectory",
                None => "Copy",
            };
            targets.insert(target_key, (directory, digest.clone()));
            entries.push(Entry {
                source: text(&source)?,
                destination: text(&destination)?,
                directory,
                hash: digest,
                action,
            });
        }
        if directory {
            for child in fs::read_dir(&source).map_err(|error| error.to_string())? {
                let child = child.map_err(|error| error.to_string())?;
                if queue.len() >= ENTRY_LIMIT {
                    return Err("Prototype directory queue limit reached.".into());
                }
                queue.push_back((child.path(), destination.join(child.file_name()), depth + 1));
            }
        }
    }
    Ok(entries)
}

fn emit_plan(pairs: &[CopyPair], output: &mut impl Write) -> Result<usize> {
    // Nothing is emitted until every source, destination and conflict has passed preflight.
    let entries = plan_entries(pairs)?;
    let count = entries.len();
    for entry in entries {
        emit(
            output,
            &serde_json::json!({"version":1,"type":"entry","entry":entry}),
        )?;
    }
    emit(
        output,
        &serde_json::json!({"version":1,"type":"summary","entries":count}),
    )?;
    Ok(count)
}

fn emit_copy_plan(pairs: &[CopyPair], output: &mut impl Write) -> Result<usize> {
    let entries = plan_entries(pairs)?;
    emit(
        output,
        &serde_json::json!({"version":1,"type":"copy_pairs","pairs":pairs}),
    )?;
    let count = entries.len();
    for entry in entries {
        emit(
            output,
            &serde_json::json!({"version":1,"type":"entry","entry":entry}),
        )?;
    }
    emit(
        output,
        &serde_json::json!({"version":1,"type":"summary","entries":count}),
    )?;
    Ok(count)
}

fn run(input: impl Read, output: &mut impl Write) -> Result<bool> {
    let mut bytes = Vec::new();
    input
        .take(REQUEST_LIMIT + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() as u64 > REQUEST_LIMIT {
        return Err("Request exceeds 64 KiB.".into());
    }
    let request: Request =
        serde_json::from_slice(&bytes).map_err(|e| format!("Invalid request: {e}"))?;
    let mut read_only = !matches!(
        &request,
        Request::SetupApply { .. } | Request::ResetApply { .. } | Request::RestoreApply { .. }
    );
    let version = match &request {
        Request::Metadata { version }
        | Request::Inspect { version }
        | Request::Defaults { version }
        | Request::Resolve { version }
        | Request::Check { version, .. }
        | Request::Plan { version, .. }
        | Request::PlanMany { version, .. }
        | Request::CopyPlan { version, .. }
        | Request::CopyPairs { version, .. }
        | Request::SetupPreview { version, .. }
        | Request::SetupApply { version, .. }
        | Request::ResetPreview { version, .. }
        | Request::ResetApply { version, .. }
        | Request::ValidateBackup { version, .. }
        | Request::BackupSnapshot { version, .. }
        | Request::RestorePreview { version, .. }
        | Request::RestorePreviewFile { version, .. }
        | Request::RestoreApply { version, .. } => *version,
    };
    if version != 1 {
        return Err("Unsupported protocol version. Expected version 1.".into());
    }
    let map: Vec<Mapping> = serde_json::from_str(MAP)
        .map_err(|e| format!("Invalid build-time folder metadata: {e}"))?;
    match request {
        Request::Metadata { .. } => emit(
            output,
            &serde_json::json!({"version":1,"type":"metadata","mappings":map}),
        )?,
        Request::Inspect { .. } => {
            let _settings_mutex = acquire_settings_mutex()?;
            emit(
                output,
                &serde_json::json!({"version":1,"type":"inspection","values":inspect(&map)?}),
            )?;
        }
        Request::Defaults { .. } => emit(
            output,
            &serde_json::json!({"version":1,"type":"defaults","folders":defaults(&map)?}),
        )?,
        Request::Resolve { .. } => emit(
            output,
            &serde_json::json!({"version":1,"type":"resolved","folders":resolve(&map)?}),
        )?,
        Request::Check {
            root,
            include_music,
            folder_paths,
            ..
        } => {
            let _settings_mutex = acquire_settings_mutex()?;
            emit(
                output,
                &serde_json::json!({"version":1,"type":"check","check":check(&map, &root, include_music, &folder_paths)?}),
            )?;
        }
        Request::Plan {
            source,
            destination,
            ..
        } => {
            emit_plan(
                &[CopyPair {
                    source,
                    destination,
                }],
                output,
            )?;
        }
        Request::PlanMany { pairs, .. } => {
            emit_plan(&pairs, output)?;
        }
        Request::CopyPlan {
            root,
            include_music,
            folder_paths,
            ..
        } => {
            let _settings_mutex = acquire_settings_mutex()?;
            let pairs = copy_pairs(&map, &root, include_music, &folder_paths)?;
            emit_copy_plan(&pairs, output)?;
        }
        Request::CopyPairs {
            root,
            include_music,
            folder_paths,
            ..
        } => {
            let _settings_mutex = acquire_settings_mutex()?;
            let pairs = copy_pairs(&map, &root, include_music, &folder_paths)?;
            emit(
                output,
                &serde_json::json!({"version":1,"type":"copy_pairs","pairs":pairs}),
            )?;
        }
        Request::SetupPreview {
            root,
            include_music,
            allow_existing_content,
            verified_sync_root,
            folder_paths,
            ..
        } => {
            let _settings_mutex = acquire_settings_mutex()?;
            let preview = preview(
                &map,
                false,
                Some(&root),
                include_music,
                allow_existing_content,
                verified_sync_root,
                &folder_paths,
            )?;
            let token = approval_token(&preview)?;
            emit(
                output,
                &serde_json::json!({"version":1,"type":"folder_preview","preview":preview,"approval_token":token}),
            )?;
        }
        Request::SetupApply {
            root,
            include_music,
            allow_existing_content,
            verified_sync_root,
            folder_paths,
            confirmed,
            preview_token: expected_token,
            ..
        } => {
            read_only = false;
            let result = (|| {
                if !confirmed {
                    return Err(
                        "Explicit confirmation is required before applying folder settings.".into(),
                    );
                }
                let _settings_mutex = acquire_settings_mutex()?;
                let fresh = preview(
                    &map,
                    false,
                    Some(&root),
                    include_music,
                    allow_existing_content,
                    verified_sync_root,
                    &folder_paths,
                )?;
                if approval_token(&fresh)? != expected_token {
                    return Err(
                        "Folder settings changed after review. Preview again before applying."
                            .into(),
                    );
                }
                let sid = user_sid()?;
                apply_reviewed_preview(&map, &fresh, &sid)
            })();
            match result {
                Ok(backup_path) => emit(
                    output,
                    &serde_json::json!({"version":1,"type":"settings_apply","operation":"setup","recovery_backup":backup_path}),
                )?,
                Err(error) => {
                    emit(
                        output,
                        &serde_json::json!({"version":1,"type":"result","ok":false,"read_only":false,"message":error}),
                    )?;
                    return Ok(false);
                }
            }
        }
        Request::ResetPreview {
            allow_existing_content,
            ..
        } => {
            let _settings_mutex = acquire_settings_mutex()?;
            let preview = preview(
                &map,
                true,
                None,
                false,
                allow_existing_content,
                false,
                &BTreeMap::new(),
            )?;
            let token = approval_token(&preview)?;
            emit(
                output,
                &serde_json::json!({"version":1,"type":"folder_preview","preview":preview,"approval_token":token}),
            )?;
        }
        Request::ResetApply {
            allow_existing_content,
            confirmed,
            preview_token: expected_token,
            ..
        } => {
            read_only = false;
            let result = (|| {
                if !confirmed {
                    return Err(
                        "Explicit confirmation is required before resetting folder settings."
                            .into(),
                    );
                }
                let _settings_mutex = acquire_settings_mutex()?;
                let fresh = preview(
                    &map,
                    true,
                    None,
                    false,
                    allow_existing_content,
                    false,
                    &BTreeMap::new(),
                )?;
                if approval_token(&fresh)? != expected_token {
                    return Err(
                        "Folder settings changed after review. Preview again before resetting."
                            .into(),
                    );
                }
                let sid = user_sid()?;
                apply_reviewed_preview(&map, &fresh, &sid)
            })();
            match result {
                Ok(backup_path) => emit(
                    output,
                    &serde_json::json!({"version":1,"type":"settings_apply","operation":"reset","recovery_backup":backup_path}),
                )?,
                Err(error) => {
                    emit(
                        output,
                        &serde_json::json!({"version":1,"type":"result","ok":false,"read_only":false,"message":error}),
                    )?;
                    return Ok(false);
                }
            }
        }
        Request::RestorePreview { backup, .. } => {
            let _settings_mutex = acquire_settings_mutex()?;
            let sid = user_sid()?;
            validate_backup(&backup, &map, &sid)?;
            let current =
                read_named_folder_values(backup.values.iter().map(|value| value.name.as_str()))?;
            let preview =
                evaluate_restore_preview(&backup, &map, &sid, &current, &recovery_root()?)?;
            let token = approval_token(&preview)?;
            emit(
                output,
                &serde_json::json!({"version":1,"type":"restore_preview","preview":preview,"approval_token":token}),
            )?;
        }
        Request::RestorePreviewFile { path, .. } => {
            let _settings_mutex = acquire_settings_mutex()?;
            let sid = user_sid()?;
            let backup = read_backup_file(&path, &map, &sid)?;
            let current =
                read_named_folder_values(backup.values.iter().map(|value| value.name.as_str()))?;
            let preview =
                evaluate_restore_preview(&backup, &map, &sid, &current, &recovery_root()?)?;
            let token = approval_token(&preview)?;
            emit(
                output,
                &serde_json::json!({"version":1,"type":"restore_preview","preview":preview,"approval_token":token}),
            )?;
        }
        Request::RestoreApply {
            path,
            confirmed,
            preview_token: expected_token,
            ..
        } => {
            read_only = false;
            let result = (|| {
                if !confirmed {
                    return Err(
                        "Explicit confirmation is required before restoring folder settings."
                            .into(),
                    );
                }
                let _settings_mutex = acquire_settings_mutex()?;
                let sid = user_sid()?;
                let backup = read_backup_file(&path, &map, &sid)?;
                let current = read_named_folder_values(
                    backup.values.iter().map(|value| value.name.as_str()),
                )?;
                let fresh =
                    evaluate_restore_preview(&backup, &map, &sid, &current, &recovery_root()?)?;
                if approval_token(&fresh)? != expected_token {
                    return Err("Folder settings or recovery data changed after review. Preview again before restoring.".into());
                }
                apply_reviewed_restore(&map, &fresh, &sid)
            })();
            match result {
                Ok(backup_path) => emit(
                    output,
                    &serde_json::json!({"version":1,"type":"settings_apply","operation":"restore","recovery_backup":backup_path}),
                )?,
                Err(error) => {
                    emit(
                        output,
                        &serde_json::json!({"version":1,"type":"result","ok":false,"read_only":false,"message":error}),
                    )?;
                    return Ok(false);
                }
            }
        }
        Request::ValidateBackup { backup, .. } => {
            let sid = user_sid()?;
            let value_count = validate_backup(&backup, &map, &sid)?;
            emit(
                output,
                &serde_json::json!({"version":1,"type":"backup_validation","valid":true,"value_count":value_count}),
            )?;
        }
        Request::BackupSnapshot { include_music, .. } => {
            let _settings_mutex = acquire_settings_mutex()?;
            let values = read_folder_values(&map, include_music)?;
            let sid = user_sid()?;
            let mut timestamp = SYSTEMTIME::default();
            // SAFETY: GetSystemTime writes a complete SYSTEMTIME to this live local value.
            unsafe { GetSystemTime(&mut timestamp) };
            let backup = BackupRecord {
                version: 1,
                sid,
                key: SHELL_KEY.into(),
                _created_utc: Some(format!(
                    "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}0000Z",
                    timestamp.wYear,
                    timestamp.wMonth,
                    timestamp.wDay,
                    timestamp.wHour,
                    timestamp.wMinute,
                    timestamp.wSecond,
                    timestamp.wMilliseconds
                )),
                values: map
                    .iter()
                    .filter(|item| include_music || !item.optional)
                    .map(|item| {
                        let value = values.get(&item.value_name).expect("mapped value was read");
                        BackupValue {
                            name: item.value_name.clone(),
                            exists: value.exists,
                            kind: value.kind.map(str::to_owned),
                            data: value.data.clone(),
                        }
                    })
                    .collect(),
            };
            let value_count = backup.values.len();
            emit(
                output,
                &serde_json::json!({"version":1,"type":"backup_snapshot","backup":backup,"value_count":value_count}),
            )?;
        }
    }
    emit(
        output,
        &serde_json::json!({"version":1,"type":"result","ok":true,"read_only":read_only}),
    )?;
    Ok(true)
}

fn main() {
    let mut output = io::BufWriter::new(io::stdout().lock());
    let result = if std::env::args_os().len() != 1 {
        Err("Use one versioned JSON request on standard input; command-line actions are not supported.".into())
    } else {
        run(io::stdin().lock(), &mut output)
    };
    match result {
        Err(error) => {
            let _ = emit(
                &mut output,
                &serde_json::json!({"version":1,"type":"result","ok":false,"read_only":true,"message":error}),
            );
            let _ = output.flush();
            std::process::exit(1);
        }
        Ok(false) => {
            let _ = output.flush();
            std::process::exit(1);
        }
        Ok(true) => {}
    }
    if output.flush().is_err() {
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn check_folder_resolution_aggregates_failures_and_skips_optional_music() {
        let map = vec![
            Mapping {
                value_name: "Desktop".into(),
                relative_path: "Desktop".into(),
                optional: false,
                known_folder_id: "desktop-guid".into(),
            },
            Mapping {
                value_name: "DesktopAlias".into(),
                relative_path: "Desktop".into(),
                optional: false,
                known_folder_id: "desktop-guid".into(),
            },
            Mapping {
                value_name: "Personal".into(),
                relative_path: "Documents".into(),
                optional: false,
                known_folder_id: "documents-guid".into(),
            },
            Mapping {
                value_name: "Music".into(),
                relative_path: "Music".into(),
                optional: true,
                known_folder_id: "music-guid".into(),
            },
        ];
        let mut queried = Vec::<String>::new();
        let (folders, errors) = collect_folder_paths(&map, false, "current folder", |item| {
            queried.push(item.relative_path.clone());
            if item.relative_path == "Documents" {
                Err("fixture lookup failure".into())
            } else {
                Ok(format!("C:\\{}", item.relative_path))
            }
        });

        assert_eq!(queried, ["Desktop", "Documents"]);
        assert_eq!(folders.len(), 1);
        assert_eq!(folders[0].folder, "Desktop");
        assert_eq!(folders[0].path, "C:\\Desktop");
        assert_eq!(errors.len(), 1);
        assert!(errors[0].contains("current folder for Documents"));
        assert!(errors[0].contains("fixture lookup failure"));
    }

    #[test]
    fn unavailable_captures_path_matches_shell_namespace_null_semantics() {
        assert!(is_missing_captures_folder(
            "Cannot resolve the Windows current folder for Captures: SHGetKnownFolderPath failed (HRESULT 0x80070002)."
        ));
        assert!(!is_missing_captures_folder(
            "Cannot resolve the Windows current folder for Captures: SHGetKnownFolderPath failed (HRESULT 0x80004005)."
        ));
        assert!(!is_missing_captures_folder(
            "Cannot resolve the Windows current folder for Documents: SHGetKnownFolderPath failed (HRESULT 0x80070002)."
        ));
    }

    #[test]
    fn icloud_registration_reader_preserves_multiple_roots_and_refuses_malformed_paths() {
        let roots = collect_registered_icloud_roots(
            [
                (
                    "iCloudDrive!ProviderA".into(),
                    Some("C:\\Users\\Fixture\\iCloudDrive".into()),
                ),
                (
                    "ICLOUDDRIVE!ProviderB".into(),
                    Some("D:\\Fixture\\OtherCloudRoot".into()),
                ),
                ("OtherProvider!Ignored".into(), Some("C:\\Ignored".into())),
                ("iCloudDrive!NoUserRoot".into(), None),
            ],
            normalize_registered_root,
        )
        .unwrap();
        assert_eq!(
            roots,
            [
                "C:\\Users\\Fixture\\iCloudDrive",
                "D:\\Fixture\\OtherCloudRoot"
            ]
        );

        let relative = collect_registered_icloud_roots(
            [(
                "iCloudDrive!Relative".into(),
                Some("relative-registration-path".into()),
            )],
            normalize_registered_root,
        );
        assert!(relative.is_err(), "a relative registered root was accepted");

        let malformed = collect_registered_icloud_roots(
            [("iCloudDrive!Malformed".into(), Some("C:\\NUL".into()))],
            normalize_registered_root,
        );
        assert!(
            malformed.is_err(),
            "a malformed registered root was accepted"
        );
    }

    struct CfProtectedHandle(HANDLE);

    impl Drop for CfProtectedHandle {
        fn drop(&mut self) {
            // SAFETY: this value is constructed only from a successful CfOpenFileWithOplock call.
            unsafe { windows_sys::Win32::Storage::CloudFilters::CfCloseHandle(self.0) }
        }
    }

    struct CfHandleReference(HANDLE);

    impl Drop for CfHandleReference {
        fn drop(&mut self) {
            // SAFETY: construction follows a successful CfReferenceProtectedHandle call.
            unsafe { windows_sys::Win32::Storage::CloudFilters::CfReleaseProtectedHandle(self.0) }
        }
    }

    fn read_with_cfapi(path: &Path, expected: &[u8]) -> Result<Vec<u8>> {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::{
            Foundation::INVALID_HANDLE_VALUE,
            Storage::{
                CloudFilters::{
                    CF_OPEN_FILE_FLAG_FOREGROUND, CfGetWin32HandleFromProtectedHandle,
                    CfOpenFileWithOplock, CfReferenceProtectedHandle,
                },
                FileSystem::ReadFile,
            },
            System::IO::{GetOverlappedResult, OVERLAPPED},
        };

        let wide_path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        let mut protected = std::ptr::null_mut();
        // SAFETY: wide_path is NUL-terminated and protected points to writable HANDLE storage.
        let status = unsafe {
            CfOpenFileWithOplock(
                wide_path.as_ptr(),
                CF_OPEN_FILE_FLAG_FOREGROUND,
                &mut protected,
            )
        };
        if status < 0 || protected.is_null() || protected == INVALID_HANDLE_VALUE {
            return Err(format!(
                "CfOpenFileWithOplock failed (HRESULT 0x{:08X}).",
                status as u32
            ));
        }
        let protected = CfProtectedHandle(protected);

        // SAFETY: protected is a live handle returned by CfOpenFileWithOplock.
        if !unsafe { CfReferenceProtectedHandle(protected.0) } {
            return Err("CfReferenceProtectedHandle failed.".into());
        }
        let _reference = CfHandleReference(protected.0);
        // SAFETY: the protected handle is referenced until after ReadFile returns.
        let win32 = unsafe { CfGetWin32HandleFromProtectedHandle(protected.0) };
        if win32.is_null() || win32 == INVALID_HANDLE_VALUE {
            return Err("CfGetWin32HandleFromProtectedHandle returned an invalid handle.".into());
        }

        let mut buffer = vec![0u8; expected.len()];
        let mut bytes_read = 0u32;
        let mut overlapped = OVERLAPPED::default();
        // SAFETY: buffer and OVERLAPPED remain valid through GetOverlappedResult, and the borrowed
        // handle remains referenced until the operation has completed.
        let succeeded = unsafe {
            ReadFile(
                win32,
                buffer.as_mut_ptr(),
                buffer.len() as u32,
                std::ptr::null_mut(),
                &mut overlapped,
            )
        };
        if succeeded == 0
            && unsafe { GetLastError() } != windows_sys::Win32::Foundation::ERROR_IO_PENDING
        {
            return Err(format!(
                "ReadFile through the referenced CFAPI handle failed (Win32 error {}).",
                unsafe { GetLastError() }
            ));
        }
        // SAFETY: this is the same handle and OVERLAPPED passed to ReadFile; waiting keeps their
        // backing storage alive until the asynchronous read has completed.
        if unsafe { GetOverlappedResult(win32, &overlapped, &mut bytes_read, 1) } == 0 {
            return Err(format!(
                "GetOverlappedResult failed (Win32 error {}).",
                unsafe { GetLastError() }
            ));
        }
        buffer.truncate(bytes_read as usize);
        if buffer != expected {
            return Err("CFAPI handle read returned unexpected fixture bytes.".into());
        }
        Ok(buffer)
    }

    #[test]
    fn cfapi_protected_handle_reads_an_ordinary_temp_file() {
        let path = std::env::temp_dir().join(format!(
            "icloud-cfapi-handle-probe-{}-{}.bin",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock should be after Unix epoch")
                .as_nanos()
        ));
        let expected = b"ordinary local file; no cloud hydration";
        fs::write(&path, expected).expect("create disposable ordinary-file fixture");
        let result = read_with_cfapi(&path, expected);
        let cleanup = fs::remove_file(&path);
        assert!(cleanup.is_ok(), "remove disposable fixture: {cleanup:?}");
        assert_eq!(result.unwrap(), expected);
    }

    #[test]
    fn cng_sha256_matches_known_vectors_and_hashes_a_temp_file() {
        let provider = CngSha256Provider::new().expect("open Windows SHA-256 provider");
        let mut buffer = vec![0u8; 4096];
        for (bytes, expected) in [
            (
                &b""[..],
                "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
            ),
            (
                &b"abc"[..],
                "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD",
            ),
        ] {
            let actual = provider
                .digest_reader(&mut std::io::Cursor::new(bytes), &mut buffer)
                .expect("hash known-vector bytes");
            assert_eq!(actual, expected);
        }

        let million_as = vec![b'a'; 1_000_000];
        let streamed = provider
            .digest_reader(
                &mut std::io::Cursor::new(million_as.as_slice()),
                &mut buffer,
            )
            .expect("hash multi-buffer known vector");
        assert_eq!(
            streamed,
            "CDC76E5C9914FB9281A1C7E284D73E67F1809A48A497200E046D39CCC7112CD0"
        );

        let path = std::env::temp_dir().join(format!(
            "icloud-cng-hash-probe-{}-{}.bin",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock should be after Unix epoch")
                .as_nanos()
        ));
        fs::write(&path, b"abc").expect("create disposable hash fixture");
        let file_digest = hash(&path, &provider, &mut buffer);
        let cleanup = fs::remove_file(&path);
        assert!(cleanup.is_ok(), "remove disposable fixture: {cleanup:?}");
        assert_eq!(
            file_digest.unwrap(),
            "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        );

        let large_path = std::env::temp_dir().join(format!(
            "icloud-cng-hash-stream-probe-{}-{}.bin",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system clock should be after Unix epoch")
                .as_nanos()
        ));
        fs::write(&large_path, &million_as).expect("create multi-buffer hash fixture");
        let large_file_digest = hash(&large_path, &provider, &mut buffer);
        let cleanup = fs::remove_file(&large_path);
        assert!(cleanup.is_ok(), "remove disposable fixture: {cleanup:?}");
        assert_eq!(
            large_file_digest.unwrap(),
            "CDC76E5C9914FB9281A1C7E284D73E67F1809A48A497200E046D39CCC7112CD0"
        );
    }

    fn same_stored_value(
        left: Option<&StoredFolderValue>,
        right: Option<&StoredFolderValue>,
    ) -> bool {
        match (left, right) {
            (None, None) => true,
            (Some(left), Some(right)) => {
                left.exists == right.exists && left.kind == right.kind && left.data == right.data
            }
            _ => false,
        }
    }

    // The same checked transaction algorithm is exercised with a fake registry in unit tests.
    fn apply_fixture_transaction(
        registry: &mut impl FolderRegistry,
        before: &BTreeMap<String, StoredFolderValue>,
        desired: &[BackupValue],
    ) -> Result<()> {
        apply_checked_transaction(registry, before, desired)
    }

    #[derive(Default)]
    struct FakeRegistry {
        values: HashMap<String, StoredFolderValue>,
        fail_read: Option<String>,
        fail_write: Option<String>,
        fail_remove: Option<String>,
    }

    impl FolderRegistry for FakeRegistry {
        fn read(&mut self, name: &str) -> Result<Option<StoredFolderValue>> {
            if self.fail_read.as_deref() == Some(name) {
                self.fail_read = None;
                return Err("Injected registry read-back failure.".into());
            }
            Ok(Some(self.values.get(name).cloned().unwrap_or(
                StoredFolderValue {
                    exists: false,
                    kind: None,
                    data: None,
                },
            )))
        }
        fn write(&mut self, name: &str, kind: &'static str, data: &str) -> Result<()> {
            if self.fail_write.as_deref() == Some(name) {
                self.fail_write = None;
                return Err("Injected registry write failure.".into());
            }
            self.values.insert(
                name.to_owned(),
                StoredFolderValue {
                    exists: true,
                    kind: Some(kind),
                    data: Some(data.to_owned()),
                },
            );
            Ok(())
        }
        fn remove(&mut self, name: &str) -> Result<()> {
            if self.fail_remove.as_deref() == Some(name) {
                self.fail_remove = None;
                return Err("Injected registry removal failure.".into());
            }
            self.values.remove(name);
            Ok(())
        }
    }

    #[test]
    fn checked_transaction_rolls_back_exact_values_and_original_absence() {
        let before = BTreeMap::from([
            (
                "Documents".to_owned(),
                StoredFolderValue {
                    exists: true,
                    kind: Some("String"),
                    data: Some("C:\\Users\\Example\\Documents".into()),
                },
            ),
            (
                "Downloads".to_owned(),
                StoredFolderValue {
                    exists: false,
                    kind: None,
                    data: None,
                },
            ),
        ]);
        let desired = vec![
            BackupValue {
                name: "Documents".into(),
                exists: true,
                kind: Some("ExpandString".into()),
                data: Some("C:\\Cloud\\Documents".into()),
            },
            BackupValue {
                name: "Downloads".into(),
                exists: true,
                kind: Some("String".into()),
                data: Some("C:\\Cloud\\Downloads".into()),
            },
        ];
        let mut registry = FakeRegistry::default();
        registry
            .values
            .insert("Documents".into(), before["Documents"].clone());
        registry.fail_write = Some("Downloads".into());

        let error = apply_fixture_transaction(&mut registry, &before, &desired).unwrap_err();
        assert!(error.contains("Rollback verified."), "{error}");
        assert!(same_stored_value(
            registry.values.get("Documents"),
            Some(&before["Documents"])
        ));
        assert!(
            !registry.values.contains_key("Downloads"),
            "originally absent value must be removed during rollback"
        );
    }

    #[test]
    fn checked_transaction_rolls_back_when_readback_fails() {
        let before = BTreeMap::from([(
            "Documents".to_owned(),
            StoredFolderValue {
                exists: true,
                kind: Some("String"),
                data: Some("C:\\Before".into()),
            },
        )]);
        let desired = vec![BackupValue {
            name: "Documents".into(),
            exists: true,
            kind: Some("ExpandString".into()),
            data: Some("C:\\After".into()),
        }];
        let mut registry = FakeRegistry::default();
        registry
            .values
            .insert("Documents".into(), before["Documents"].clone());
        registry.fail_read = Some("Documents".into());

        let error = apply_fixture_transaction(&mut registry, &before, &desired).unwrap_err();
        assert!(error.contains("Rollback verified."), "{error}");
        assert!(same_stored_value(
            registry.values.get("Documents"),
            Some(&before["Documents"])
        ));
    }

    #[test]
    fn checked_transaction_reports_incomplete_rollback() {
        let before = BTreeMap::from([
            (
                "Documents".to_owned(),
                StoredFolderValue {
                    exists: true,
                    kind: Some("String"),
                    data: Some("C:\\Before".into()),
                },
            ),
            (
                "Downloads".to_owned(),
                StoredFolderValue {
                    exists: false,
                    kind: None,
                    data: None,
                },
            ),
        ]);
        let desired = vec![
            BackupValue {
                name: "Documents".into(),
                exists: true,
                kind: Some("String".into()),
                data: Some("C:\\After".into()),
            },
            BackupValue {
                name: "Downloads".into(),
                exists: true,
                kind: Some("String".into()),
                data: Some("C:\\New".into()),
            },
        ];
        let mut registry = FakeRegistry::default();
        registry
            .values
            .insert("Documents".into(), before["Documents"].clone());
        registry.fail_write = Some("Downloads".into());
        registry.fail_remove = Some("Downloads".into());

        let error = apply_fixture_transaction(&mut registry, &before, &desired).unwrap_err();
        assert!(error.contains("ROLLBACK INCOMPLETE"), "{error}");
        assert!(
            error.contains("Injected registry removal failure"),
            "{error}"
        );
    }

    #[test]
    fn approval_token_is_stable_and_covers_the_complete_preview() {
        let mut preview = serde_json::json!({
            "operation":"reset",
            "review_gates_passed":true,
            "rows":[{"folder":"Desktop","current":"D:\\Desktop","proposed":"C:\\Users\\Test\\Desktop"}]
        });
        let original = approval_token(&preview).expect("hash serialized preview");
        assert_eq!(original.len(), 64);
        assert_eq!(approval_token(&preview).unwrap(), original);
        preview["rows"][0]["proposed"] = "C:\\Users\\Other\\Desktop".into();
        assert_ne!(approval_token(&preview).unwrap(), original);
        preview["rows"][0]["proposed"] = "C:\\Users\\Test\\Desktop".into();
        preview["review_gates_passed"] = false.into();
        assert_ne!(approval_token(&preview).unwrap(), original);
    }

    #[test]
    fn rejects_bad_protocol_and_mutation() {
        assert!(
            run(
                br#"{"version":1,"operation":"metadata"}"#.as_slice(),
                &mut Vec::new()
            )
            .is_ok()
        );
        for request in [
            r#"{"version":2,"operation":"metadata"}"#,
            r#"{"version":1,"operation":"apply"}"#,
            r#"{"version":1,"operation":"metadata","apply":true}"#,
        ] {
            assert!(
                run(request.as_bytes(), &mut Vec::new()).is_err(),
                "{request}"
            );
        }
        assert!(run(vec![b' '; 65537].as_slice(), &mut Vec::new()).is_err());
    }

    #[test]
    fn all_settings_write_requests_fail_closed_without_explicit_confirmation() {
        let requests = [
            r#"{"version":1,"operation":"setup_apply","root":"C:\\Fixture\\Drive","preview_token":""}"#,
            r#"{"version":1,"operation":"reset_apply","preview_token":""}"#,
            r#"{"version":1,"operation":"restore_apply","path":"C:\\Fixture\\before.json","preview_token":""}"#,
        ];
        for request in requests {
            let mut output = Vec::new();
            assert_eq!(run(request.as_bytes(), &mut output).unwrap(), false);
            let records: Vec<serde_json::Value> = String::from_utf8(output)
                .unwrap()
                .lines()
                .map(|line| serde_json::from_str(line).unwrap())
                .collect();
            let terminal = records.last().unwrap();
            assert_eq!(terminal["type"], "result");
            assert_eq!(terminal["ok"], false);
            assert_eq!(terminal["read_only"], false);
            assert!(
                terminal["message"]
                    .as_str()
                    .unwrap()
                    .contains("Explicit confirmation is required")
            );
        }
    }

    #[test]
    fn backup_validation_preserves_present_and_absent_values_and_rejects_unsafe_records() {
        let map: Vec<Mapping> = serde_json::from_str(MAP).unwrap();
        let valid = BackupRecord {
            version: 1,
            sid: "S-1-5-21-1-2-3-1001".into(),
            key: SHELL_KEY.into(),
            _created_utc: Some("2026-10-26T12:00:00.0000000Z".into()),
            values: vec![
                BackupValue {
                    name: "Personal".into(),
                    exists: true,
                    kind: Some("ExpandString".into()),
                    data: Some("C:\\Users\\Example\\Documents".into()),
                },
                BackupValue {
                    name: "{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}".into(),
                    exists: false,
                    kind: None,
                    data: None,
                },
            ],
        };
        assert_eq!(
            validate_backup(&valid, &map, "S-1-5-21-1-2-3-1001").unwrap(),
            2
        );
        assert_eq!(
            validate_backup(&valid, &map, "s-1-5-21-1-2-3-1001").unwrap(),
            2
        );

        let mut invalid = vec![valid];
        let mut duplicate = invalid[0].values[0].clone();
        duplicate.name = "personal".into();
        invalid[0].values.push(duplicate);
        assert!(validate_backup(&invalid[0], &map, "S-1-5-21-1-2-3-1001").is_err());

        let mut wrong_sid = BackupRecord {
            version: 1,
            sid: "S-1-5-21-9".into(),
            key: SHELL_KEY.into(),
            _created_utc: None,
            values: vec![BackupValue {
                name: "Desktop".into(),
                exists: false,
                kind: None,
                data: None,
            }],
        };
        assert!(validate_backup(&wrong_sid, &map, "S-1-5-21-1").is_err());
        wrong_sid.sid = "S-1-5-21-1".into();
        wrong_sid.key = "Software\\Other".into();
        assert!(validate_backup(&wrong_sid, &map, "S-1-5-21-1").is_err());
        wrong_sid.key = SHELL_KEY.into();
        wrong_sid.values[0].kind = Some("Binary".into());
        wrong_sid.values[0].data = Some("C:\\Users\\Example\\Desktop".into());
        wrong_sid.values[0].exists = true;
        assert!(validate_backup(&wrong_sid, &map, "S-1-5-21-1").is_err());
        wrong_sid.values[0].kind = Some("ExpandString".into());
        wrong_sid.values[0].data = Some("C:\\".into());
        assert!(validate_backup(&wrong_sid, &map, "S-1-5-21-1").is_err());
    }

    #[test]
    fn backup_schema_accepts_powershell_property_casing() {
        let backup: BackupRecord = serde_json::from_str(
            r#"{"Version":1,"Sid":"S-1-5-21-1","Key":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","CreatedUtc":"2026-10-26T12:00:00Z","Extension":"ignored like PowerShell","Values":[{"Name":"Desktop","Exists":false,"Kind":null,"Data":null,"Extension":42}]}"#,
        )
        .unwrap();
        let map: Vec<Mapping> = serde_json::from_str(MAP).unwrap();
        assert_eq!(validate_backup(&backup, &map, "S-1-5-21-1").unwrap(), 1);

        let mixed_case: BackupRecord = serde_json::from_str(
            r#"{"vErSiOn":1,"sID":"S-1-5-21-1","kEy":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","_CREATED_UTC":"2026-10-26T12:00:00Z","vAlUeS":[{"nAmE":"Desktop","eXiStS":false,"kInD":null,"dAtA":null,"Extension":42}]}"#,
        )
        .unwrap();
        assert_eq!(validate_backup(&mixed_case, &map, "S-1-5-21-1").unwrap(), 1);
        let serialized = serde_json::to_value(&mixed_case).unwrap();
        assert_eq!(serialized["Version"], 1);
        assert_eq!(serialized["Values"][0]["Name"], "Desktop");

        let duplicate_case: std::result::Result<BackupRecord, _> = serde_json::from_str(
            r#"{"Version":1,"version":1,"Sid":"S-1-5-21-1","Key":"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\User Shell Folders","Values":[]}"#,
        );
        assert!(
            duplicate_case.is_err(),
            "case-insensitive duplicate fields must be rejected"
        );
    }

    #[test]
    fn durable_backup_test_helper_round_trips_and_never_overwrites_existing_files() {
        use std::os::windows::process::CommandExt;
        let map: Vec<Mapping> = serde_json::from_str(MAP).unwrap();
        let sid = "S-1-5-21-1-2-3-1001";
        let backup = BackupRecord {
            version: 1,
            sid: sid.into(),
            key: SHELL_KEY.into(),
            _created_utc: Some("2026-10-26T12:00:00.0000000Z".into()),
            values: vec![
                BackupValue {
                    name: "Personal".into(),
                    exists: true,
                    kind: Some("ExpandString".into()),
                    data: Some("C:\\Users\\Example\\Données".into()),
                },
                BackupValue {
                    name: "{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}".into(),
                    exists: false,
                    kind: None,
                    data: None,
                },
            ],
        };
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "ICloudNativeBackupTest-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&directory).unwrap();
        let backup_path = directory.join("before.json");
        persist_backup_new(&backup_path, &backup, &map, sid).unwrap();
        let saved = fs::read(&backup_path).unwrap();
        assert!(saved.starts_with(UTF8_BOM));
        let reopened: BackupRecord =
            serde_json::from_slice(saved.strip_prefix(UTF8_BOM).unwrap()).unwrap();
        assert_eq!(validate_backup(&reopened, &map, sid).unwrap(), 2);
        assert_eq!(
            serde_json::to_vec(&reopened).unwrap(),
            saved.strip_prefix(UTF8_BOM).unwrap()
        );
        let compatibility = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command",
                "$ErrorActionPreference='Stop'; $r=Get-Content -LiteralPath $env:ICLOUD_BACKUP_TEST_PATH -Raw|ConvertFrom-Json; if($r.Values[0].Data -cne $env:ICLOUD_BACKUP_TEST_DATA -or $r.Values[1].Exists -ne $false -or $null -ne $r.Values[1].Data){exit 2}"])
            .env("ICLOUD_BACKUP_TEST_PATH", &backup_path)
            .env("ICLOUD_BACKUP_TEST_DATA", backup.values[0].data.as_deref().unwrap())
            .creation_flags(0x08000000)
            .output().unwrap();
        assert!(
            compatibility.status.success(),
            "Windows PowerShell did not preserve the Unicode backup payload: {}",
            String::from_utf8_lossy(&compatibility.stderr)
        );

        let existing_path = directory.join("existing.json");
        fs::write(&existing_path, b"keeper bytes").unwrap();
        assert!(persist_backup_new(&existing_path, &backup, &map, sid).is_err());
        assert_eq!(fs::read(&existing_path).unwrap(), b"keeper bytes");

        let invalid = BackupRecord {
            version: 1,
            sid: sid.into(),
            key: SHELL_KEY.into(),
            _created_utc: None,
            values: Vec::new(),
        };
        let invalid_path = directory.join("invalid.json");
        assert!(persist_backup_new(&invalid_path, &invalid, &map, sid).is_err());
        assert!(!invalid_path.exists());
        let _ = fs::remove_dir_all(directory);
    }

    #[test]
    fn private_recovery_directory_is_current_user_scoped_and_rejects_files() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let parent = std::env::temp_dir().join(format!(
            "ICloudPrivateRecoveryTest-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&parent).unwrap();
        let sid = user_sid().unwrap();
        let recovery = parent.join("Recovery");
        ensure_private_recovery_directory(&recovery, &sid).unwrap();
        assert!(fs::metadata(&recovery).unwrap().is_dir());
        ensure_private_recovery_directory(&recovery, &sid)
            .expect("an existing recovery directory should be secured idempotently");

        let file = parent.join("not-a-directory");
        fs::write(&file, b"keeper").unwrap();
        assert!(ensure_private_recovery_directory(&file, &sid).is_err());
        assert_eq!(fs::read(&file).unwrap(), b"keeper");
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn restore_preview_preserves_exact_types_and_absence_and_checks_recovery_and_destinations() {
        let map: Vec<Mapping> = serde_json::from_str(MAP).unwrap();
        let sid = "S-1-5-21-1";
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "ICloudRestorePreview-{}-{unique}",
            std::process::id()
        ));
        let target = directory.join("target");
        fs::create_dir_all(&target).unwrap();
        let raw = text(&target).unwrap();
        let names = [
            "Personal",
            "Desktop",
            "My Video",
            "{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}",
        ];
        let mut backup = BackupRecord {
            version: 1,
            sid: sid.into(),
            key: SHELL_KEY.into(),
            _created_utc: None,
            values: names
                .iter()
                .enumerate()
                .map(|(index, name)| BackupValue {
                    name: (*name).into(),
                    exists: index != 3,
                    kind: (index != 3).then(|| "String".into()),
                    data: (index != 3).then(|| raw.clone()),
                })
                .collect(),
        };
        let mut current = BTreeMap::new();
        for (index, name) in names.iter().enumerate() {
            current.insert(
                (*name).into(),
                StoredFolderValue {
                    exists: index != 1,
                    kind: if index == 1 {
                        None
                    } else if index == 0 {
                        Some("ExpandString")
                    } else {
                        Some("String")
                    },
                    data: (index != 1).then(|| raw.clone()),
                },
            );
        }
        let recovery = directory.join("recovery");
        let preview = evaluate_restore_preview(&backup, &map, sid, &current, &recovery).unwrap();
        assert_eq!(
            preview
                .rows
                .iter()
                .map(|row| row.action)
                .collect::<Vec<_>>(),
            [
                "Update value",
                "Add missing value",
                "Already configured",
                "Remove value"
            ]
        );
        assert_eq!(preview.rows[0].proposed_kind.as_deref(), Some("String"));
        assert!(!preview.rows[3].proposed_exists);
        assert!(preview.rows[3].proposed.is_none() && preview.rows[3].proposed_kind.is_none());
        assert!(
            !recovery.exists(),
            "restore preview must not create recovery storage"
        );
        assert!(
            evaluate_restore_preview(&backup, &map, sid, &current, &target.join("recovery"))
                .is_err()
        );
        backup.values[0].data = Some(text(&directory.join("missing")).unwrap());
        assert!(
            evaluate_restore_preview(&backup, &map, sid, &current, &recovery)
                .err()
                .unwrap()
                .contains("Restore destination is unavailable")
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn recovery_file_reader_accepts_utf8_forms_and_refuses_invalid_or_oversized_files() {
        let map: Vec<Mapping> = serde_json::from_str(MAP).unwrap();
        let sid = "S-1-5-21-1";
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "ICloudBackupReadTest-{}-{unique}",
            std::process::id()
        ));
        fs::create_dir(&directory).unwrap();
        let backup = BackupRecord {
            version: 1,
            sid: sid.into(),
            key: SHELL_KEY.into(),
            _created_utc: Some("2026-10-26T12:00:00Z".into()),
            values: vec![BackupValue {
                name: "{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}".into(),
                exists: false,
                kind: None,
                data: None,
            }],
        };
        let json = serde_json::to_vec(&backup).unwrap();
        let bom_path = directory.join("with-bom.json");
        let mut bom_bytes = UTF8_SIGNATURE.to_vec();
        bom_bytes.extend_from_slice(&json);
        fs::write(&bom_path, &bom_bytes).unwrap();
        let loaded = read_backup_file(&bom_path, &map, sid).unwrap();
        assert_eq!(
            loaded.values[0].name,
            "{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}"
        );
        assert!(!loaded.values[0].exists);

        let plain_path = directory.join("without-bom.json");
        fs::write(&plain_path, &json).unwrap();
        assert_eq!(
            read_backup_file(&plain_path, &map, sid)
                .unwrap()
                .values
                .len(),
            1
        );

        let invalid_path = directory.join("invalid.json");
        fs::write(&invalid_path, [UTF8_SIGNATURE, &[0xff, 0xfe][..]].concat()).unwrap();
        assert!(
            read_backup_file(&invalid_path, &map, sid)
                .err()
                .unwrap()
                .contains("valid UTF-8 JSON")
        );

        let oversized_path = directory.join("oversized.json");
        let file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&oversized_path)
            .unwrap();
        file.set_len(BACKUP_FILE_LIMIT + 1).unwrap();
        drop(file);
        assert!(
            read_backup_file(&oversized_path, &map, sid)
                .err()
                .unwrap()
                .contains("4 MiB safety limit")
        );
        assert_eq!(fs::read(&bom_path).unwrap(), bom_bytes);
        assert_eq!(fs::read(&plain_path).unwrap(), json);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn generated_map_is_bounded_and_unique() {
        let map: Vec<Mapping> = serde_json::from_str(MAP).unwrap();
        assert!(map.len() <= 32 && !map.is_empty());
        let names: BTreeSet<_> = map.iter().map(|m| &m.value_name).collect();
        assert_eq!(names.len(), map.len());
        assert!(
            map.iter()
                .all(|item| parse_guid(&item.known_folder_id).is_ok())
        );
    }
    #[test]
    fn cloud_file_tag_mask_matches_only_cloud_file_variants() {
        for tag in [0x9000_001A, 0x9000_101A, 0x9000_201A, 0x9000_F01A] {
            assert!(is_cloud_file_reparse_tag(tag), "tag {tag:#010X}");
        }
        for tag in [0xA000_0003, 0xA000_000C, 0x9000_001C, 0x0000_001A] {
            assert!(!is_cloud_file_reparse_tag(tag), "tag {tag:#010X}");
        }
    }
    #[test]
    fn copy_pair_derivation_deduplicates_aliases_and_obeys_music_and_custom_paths() {
        let map: Vec<Mapping> = serde_json::from_str(MAP).unwrap();
        let root = Path::new("C:\\Fixture\\Cloud");
        let mut shell_paths = BTreeMap::new();
        for item in &map {
            let source = if item.relative_path == "Videos\\Captures" {
                "C:\\Fixture\\Old\\Videos\\Captures".to_owned()
            } else {
                format!("C:\\Fixture\\Old\\{}", item.relative_path)
            };
            shell_paths.insert(item.value_name.clone(), source);
        }
        let no_custom = BTreeMap::new();
        let standard = derive_copy_pairs(&map, root, false, &no_custom, &shell_paths).unwrap();
        assert_eq!(standard.len(), 6);
        assert!(
            !standard
                .iter()
                .any(|pair| pair.destination.ends_with("Music"))
        );
        let all = derive_copy_pairs(&map, root, true, &no_custom, &shell_paths).unwrap();
        assert_eq!(
            all.len(),
            7,
            "registry aliases should produce one pair per logical destination"
        );
        let custom_path = PathBuf::from("C:\\Fixture\\Cloud\\My Documents");
        let custom = BTreeMap::from([("documents".to_owned(), custom_path.clone())]);
        let customized = derive_copy_pairs(&map, root, true, &custom, &shell_paths).unwrap();
        let documents: Vec<_> = customized
            .iter()
            .filter(|pair| pair.destination == custom_path)
            .collect();
        assert_eq!(
            documents.len(),
            1,
            "custom Documents destination should retain alias deduplication"
        );
        let duplicate_custom = BTreeMap::from([
            (
                "Documents".to_owned(),
                PathBuf::from("C:\\Fixture\\Cloud\\Docs-A"),
            ),
            (
                "documents".to_owned(),
                PathBuf::from("C:\\Fixture\\Cloud\\Docs-B"),
            ),
        ]);
        assert!(folder_targets(&map, root, true, &duplicate_custom).is_err());
        let mut already_configured = shell_paths.clone();
        for item in &map {
            if item.relative_path == "Documents" {
                already_configured.insert(
                    item.value_name.clone(),
                    "C:\\Fixture\\Cloud\\Documents".to_owned(),
                );
            }
        }
        let skipped = derive_copy_pairs(&map, root, true, &no_custom, &already_configured).unwrap();
        assert_eq!(
            skipped.len(),
            6,
            "sources already at their destinations should be skipped"
        );
    }
    #[test]
    fn preview_rows_preserve_exact_values_and_report_actions_and_alias_labels() {
        let map: Vec<Mapping> = serde_json::from_str(MAP).unwrap();
        let root = Path::new("C:\\Fixture\\Cloud");
        let (_, targets) = folder_targets(&map, root, true, &BTreeMap::new()).unwrap();
        let mut values = BTreeMap::new();
        values.insert(
            "Desktop".to_owned(),
            StoredFolderValue {
                exists: true,
                kind: Some("ExpandString"),
                data: Some("C:\\Fixture\\Cloud\\Desktop".to_owned()),
            },
        );
        values.insert(
            "Personal".to_owned(),
            StoredFolderValue {
                exists: true,
                kind: Some("String"),
                data: Some("C:\\Fixture\\Cloud\\Documents".to_owned()),
            },
        );
        let rows = make_preview_rows(&map, true, &targets, &values).unwrap();
        let desktop = rows.iter().find(|row| row.value_name == "Desktop").unwrap();
        assert_eq!(desktop.action, "Already configured");
        let documents = rows
            .iter()
            .find(|row| row.value_name == "Personal")
            .unwrap();
        assert_eq!(
            documents.action, "Update value",
            "registry type must be preserved in action comparison"
        );
        let alias = rows
            .iter()
            .find(|row| row.value_name == "{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}")
            .unwrap();
        assert_eq!(alias.folder, "Desktop (local alias)");
        assert_eq!(alias.action, "Add missing value");
    }
    #[test]
    fn setup_preview_warns_without_creating_destinations_and_honors_explicit_acknowledgment() {
        let fixture = std::env::temp_dir().join(format!(
            "icloud-rust-preview-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let cloud = fixture.join("iCloudDrive");
        let source = fixture.join("OldDocuments");
        let recovery = fixture.join("Recovery");
        fs::create_dir_all(&cloud).unwrap();
        fs::create_dir_all(&source).unwrap();
        fs::write(source.join("keep.txt"), "fixture").unwrap();

        let result = std::panic::catch_unwind(|| {
            let map: Vec<Mapping> = serde_json::from_str(MAP).unwrap();
            let (root, targets) = folder_targets(&map, &cloud, true, &BTreeMap::new()).unwrap();
            let mut values = BTreeMap::new();
            for item in &map {
                values.insert(
                    item.value_name.clone(),
                    StoredFolderValue {
                        exists: false,
                        kind: None,
                        data: None,
                    },
                );
            }
            for name in ["Personal", "{F42EE2D3-909F-4907-8871-4C22FC0BF756}"] {
                values.insert(
                    name.to_owned(),
                    StoredFolderValue {
                        exists: true,
                        kind: Some("ExpandString"),
                        data: Some(text(&source).unwrap()),
                    },
                );
            }
            let blocked = finish_preview(
                &map,
                false,
                Some(root.clone()),
                true,
                false,
                true,
                targets.clone(),
                &values,
                Vec::new(),
                Some(false),
                true,
                &recovery,
            )
            .unwrap();
            assert_eq!(
                blocked.content_warnings.len(),
                1,
                "aliases should produce one content warning"
            );
            assert!(!blocked.review_gates_passed);
            assert!(
                !cloud.join("Documents").exists(),
                "preview must not create destination folders"
            );

            let acknowledged = finish_preview(
                &map,
                false,
                Some(root.clone()),
                true,
                true,
                true,
                targets.clone(),
                &values,
                Vec::new(),
                Some(false),
                true,
                &recovery,
            )
            .unwrap();
            assert!(acknowledged.content_warnings.is_empty());
            assert!(
                acknowledged.review_gates_passed,
                "verified no-registration acknowledgment plus content approval should unblock preview"
            );

            let registered_elsewhere = finish_preview(
                &map,
                false,
                Some(root),
                true,
                true,
                true,
                targets.clone(),
                &values,
                vec!["C:\\Other\\iCloudDrive".to_owned()],
                Some(false),
                false,
                &recovery,
            )
            .unwrap();
            assert!(
                !registered_elsewhere.review_gates_passed,
                "known registration mismatch cannot be overridden"
            );

            let nested_recovery = cloud
                .join("Documents")
                .join("ICloudFolderSettler")
                .join("Recovery");
            assert!(
                finish_preview(
                    &map,
                    false,
                    Some(cloud.clone()),
                    true,
                    true,
                    true,
                    targets.clone(),
                    &values,
                    Vec::new(),
                    Some(false),
                    true,
                    &nested_recovery,
                )
                .is_err(),
                "recovery storage inside a destination must be refused"
            );
            let nested_source_recovery = source.join("ICloudFolderSettler").join("Recovery");
            assert!(
                finish_preview(
                    &map,
                    false,
                    Some(cloud.clone()),
                    true,
                    true,
                    true,
                    targets.clone(),
                    &values,
                    Vec::new(),
                    Some(false),
                    true,
                    &nested_source_recovery,
                )
                .is_err(),
                "recovery storage inside a source must be refused"
            );
            let blocker = fixture.join("blocked-path");
            fs::write(&blocker, "fixture").unwrap();
            let mut obstructed_targets = targets;
            obstructed_targets.insert("Documents".to_owned(), blocker.join("Documents"));
            assert!(
                finish_preview(
                    &map,
                    false,
                    Some(cloud.clone()),
                    true,
                    true,
                    true,
                    obstructed_targets,
                    &values,
                    Vec::new(),
                    Some(false),
                    true,
                    &recovery,
                )
                .is_err(),
                "a file in a destination's ancestor chain must be refused"
            );
            Ok::<(), String>(())
        });
        let cleanup = std::env::temp_dir().join(fixture.file_name().unwrap());
        if cleanup == fixture
            && cleanup
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("icloud-rust-preview-")
        {
            let _ = fs::remove_dir_all(cleanup);
        }
        result.unwrap().unwrap();
    }
    #[test]
    fn known_folder_guid_parser_preserves_windows_guid_layout() {
        let id = parse_guid("B4BFCC3A-DB2C-424C-B029-7FE99A87C641").unwrap();
        assert_eq!(id.data1, 0xB4BFCC3A);
        assert_eq!(id.data2, 0xDB2C);
        assert_eq!(id.data3, 0x424C);
        assert_eq!(id.data4, [0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41]);
        assert!(parse_guid("B4BFCC3A-DB2C-424C-B029-7FE99A87C64Z").is_err());
    }
    #[test]
    fn windows_path_identity_and_overlap() {
        assert!(paths_equal("C:\\caf\u{00e9}", "c:\\CAF\u{00c9}"));
        assert_eq!(
            OrdinalPath::new(Path::new("C:\\É"))
                .unwrap()
                .cmp(&OrdinalPath::new(Path::new("c:\\é")).unwrap()),
            Ordering::Equal
        );
        assert!(inside(Path::new("C:\\Foo\\bar"), Path::new("c:\\foo")).unwrap());
        assert!(!inside(Path::new("C:\\Foobar"), Path::new("c:\\foo")).unwrap());
        for path in [
            "relative",
            "C:\\foo\\..\\bar",
            "C:\\NUL.txt",
            "C:\\x:stream",
            "C:\\foo.",
            "\\\\?\\C:\\foo",
        ] {
            assert!(validate_path(Path::new(path)).is_err());
        }
    }
}
