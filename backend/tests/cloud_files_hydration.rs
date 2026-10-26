#![cfg(windows)]

//! Explicitly ignored integration probe for Cloud Files range hydration.
//!
//! Run only through tests/Test-NativeCloudFiles.ps1 on a disposable Windows
//! environment. The ordinary Rust unit suite never registers a sync root.

use std::{
    ffi::c_void,
    fs,
    mem::{offset_of, size_of},
    os::windows::ffi::OsStrExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    ptr,
    sync::atomic::{AtomicUsize, Ordering},
};

use windows_sys::Win32::{
    Foundation::{
        CloseHandle, GENERIC_READ, GetLastError, HANDLE, INVALID_HANDLE_VALUE, STATUS_SUCCESS,
    },
    Storage::{
        CloudFilters::{
            CF_CALLBACK_INFO, CF_CALLBACK_PARAMETERS, CF_CALLBACK_REGISTRATION,
            CF_CALLBACK_TYPE_FETCH_DATA, CF_CALLBACK_TYPE_NONE, CF_CONNECT_FLAG_NONE,
            CF_CREATE_FLAG_NONE, CF_FS_METADATA, CF_HYDRATE_FLAG_NONE, CF_HYDRATION_POLICY,
            CF_HYDRATION_POLICY_MODIFIER_NONE, CF_HYDRATION_POLICY_PARTIAL, CF_INSYNC_POLICY_NONE,
            CF_OPERATION_INFO, CF_OPERATION_PARAMETERS, CF_OPERATION_PARAMETERS_0_0,
            CF_OPERATION_TRANSFER_DATA_FLAG_NONE, CF_OPERATION_TYPE_TRANSFER_DATA,
            CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC, CF_PLACEHOLDER_CREATE_INFO,
            CF_POPULATION_POLICY, CF_POPULATION_POLICY_ALWAYS_FULL,
            CF_POPULATION_POLICY_MODIFIER_NONE, CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT,
            CF_SYNC_POLICIES, CF_SYNC_REGISTRATION, CfConnectSyncRoot, CfCreatePlaceholders,
            CfDisconnectSyncRoot, CfExecute, CfHydratePlaceholder, CfRegisterSyncRoot,
            CfUnregisterSyncRoot,
        },
        FileSystem::{
            BY_HANDLE_FILE_INFORMATION, CreateFileW, FILE_ATTRIBUTE_NORMAL, FILE_FLAG_OVERLAPPED,
            FILE_SHARE_READ, GetFileInformationByHandle, OPEN_EXISTING, ReadFile,
        },
    },
    System::IO::{GetOverlappedResult, OVERLAPPED},
};

const RANGE_BYTES: usize = 64 * 1024;
const CONTENT_BYTES: usize = RANGE_BYTES * 3 + 997;

struct ProviderContext {
    content: Vec<u8>,
    callback_count: AtomicUsize,
    maximum_transfer: AtomicUsize,
    last_required_offset: AtomicUsize,
    execute_failure: AtomicUsize,
}

unsafe extern "system" fn fetch_data(
    info: *const CF_CALLBACK_INFO,
    parameters: *const CF_CALLBACK_PARAMETERS,
) {
    // Never unwind across the native callback boundary. Any malformed request
    // is completed with an error so the caller cannot wait forever.
    let outcome =
        std::panic::catch_unwind(|| unsafe { transfer_requested_range(info, parameters) });
    if outcome.is_err() {
        unsafe { complete_failed_request(info) };
    }
}

unsafe fn transfer_requested_range(
    info: *const CF_CALLBACK_INFO,
    parameters: *const CF_CALLBACK_PARAMETERS,
) {
    if info.is_null() || parameters.is_null() {
        return;
    }
    let info = unsafe { &*info };
    let parameters = unsafe { &*parameters };
    if info.CallbackContext.is_null() {
        unsafe { complete_failed_request(info) };
        return;
    }
    let context = unsafe { &*(info.CallbackContext.cast::<ProviderContext>()) };
    let request = unsafe { parameters.Anonymous.FetchData };
    let start = request.RequiredFileOffset;
    let length = request.RequiredLength;
    if start < 0 || length <= 0 {
        unsafe { complete_failed_request(info) };
        return;
    }
    let start = start as usize;
    let length = length as usize;
    let Some(end) = start.checked_add(length) else {
        unsafe { complete_failed_request(info) };
        return;
    };
    if end > context.content.len() {
        unsafe { complete_failed_request(info) };
        return;
    }

    context.callback_count.fetch_add(1, Ordering::Relaxed);
    context
        .maximum_transfer
        .fetch_max(length, Ordering::Relaxed);
    context.last_required_offset.store(start, Ordering::Relaxed);

    let transfer = CF_OPERATION_PARAMETERS_0_0 {
        Flags: CF_OPERATION_TRANSFER_DATA_FLAG_NONE,
        CompletionStatus: STATUS_SUCCESS,
        Buffer: context.content[start..end].as_ptr().cast(),
        Offset: start as i64,
        Length: length as i64,
    };
    let operation = CF_OPERATION_INFO {
        StructSize: size_of::<CF_OPERATION_INFO>() as u32,
        Type: CF_OPERATION_TYPE_TRANSFER_DATA,
        ConnectionKey: info.ConnectionKey,
        TransferKey: info.TransferKey,
        RequestKey: info.RequestKey,
        ..Default::default()
    };
    let mut parameters = CF_OPERATION_PARAMETERS {
        ParamSize: (size_of::<CF_OPERATION_PARAMETERS_0_0>()
            + offset_of!(CF_OPERATION_PARAMETERS, Anonymous)) as u32,
        Anonymous: unsafe { std::mem::zeroed() },
    };
    parameters.Anonymous.TransferData = transfer;
    let status = unsafe { CfExecute(&operation, &mut parameters) };
    if status < 0 {
        context
            .execute_failure
            .store(status as u32 as usize, Ordering::Relaxed);
    }
}

unsafe fn complete_failed_request(info: *const CF_CALLBACK_INFO) {
    if info.is_null() {
        return;
    }
    let info = unsafe { &*info };
    let transfer = CF_OPERATION_PARAMETERS_0_0 {
        Flags: CF_OPERATION_TRANSFER_DATA_FLAG_NONE,
        CompletionStatus: 0xC0000001u32 as i32, // STATUS_UNSUCCESSFUL
        Buffer: ptr::null(),
        Offset: 0,
        Length: 0,
    };
    let operation = CF_OPERATION_INFO {
        StructSize: size_of::<CF_OPERATION_INFO>() as u32,
        Type: CF_OPERATION_TYPE_TRANSFER_DATA,
        ConnectionKey: info.ConnectionKey,
        TransferKey: info.TransferKey,
        RequestKey: info.RequestKey,
        ..Default::default()
    };
    let mut parameters = CF_OPERATION_PARAMETERS {
        ParamSize: (size_of::<CF_OPERATION_PARAMETERS_0_0>()
            + offset_of!(CF_OPERATION_PARAMETERS, Anonymous)) as u32,
        Anonymous: unsafe { std::mem::zeroed() },
    };
    parameters.Anonymous.TransferData = transfer;
    let _ = unsafe { CfExecute(&operation, &mut parameters) };
}

struct RegisteredProvider {
    root: PathBuf,
    connection: i64,
    registered: bool,
}

impl Drop for RegisteredProvider {
    fn drop(&mut self) {
        if self.connection != 0 {
            let _ = unsafe { CfDisconnectSyncRoot(self.connection) };
        }
        if self.registered {
            let wide = wide_path(&self.root);
            let status = unsafe { CfUnregisterSyncRoot(wide.as_ptr()) };
            if status >= 0 {
                let _ = fs::remove_dir_all(&self.root);
            } else {
                eprintln!(
                    "CLEANUP REQUIRED: CfUnregisterSyncRoot failed for {} (HRESULT 0x{:08X}); retained the directory",
                    self.root.display(),
                    status as u32
                );
            }
        } else {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

fn wide_path(path: &Path) -> Vec<u16> {
    path.as_os_str().encode_wide().chain(Some(0)).collect()
}

fn assert_hresult(status: i32, operation: &str) {
    assert!(
        status >= 0,
        "{operation} failed (HRESULT 0x{:08X})",
        status as u32
    );
}

fn open_overlapped(path: &Path) -> HANDLE {
    let wide = wide_path(path);
    let handle = unsafe {
        CreateFileW(
            wide.as_ptr(),
            GENERIC_READ,
            FILE_SHARE_READ,
            ptr::null(),
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
            ptr::null_mut(),
        )
    };
    assert!(
        !handle.is_null() && handle != INVALID_HANDLE_VALUE,
        "CreateFileW failed (Win32 error {})",
        unsafe { GetLastError() }
    );
    handle
}

fn file_identity(handle: HANDLE) -> (u32, u64, u64, u64) {
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    assert_ne!(unsafe { GetFileInformationByHandle(handle, &mut info) }, 0);
    let index = ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64;
    let size = ((info.nFileSizeHigh as u64) << 32) | info.nFileSizeLow as u64;
    let last_write = ((info.ftLastWriteTime.dwHighDateTime as u64) << 32)
        | info.ftLastWriteTime.dwLowDateTime as u64;
    (info.dwVolumeSerialNumber, index, size, last_write)
}

fn hydrate_range(handle: HANDLE, offset: usize, length: usize) {
    let mut overlapped = OVERLAPPED::default();
    overlapped.Anonymous.Anonymous.Offset = offset as u32;
    overlapped.Anonymous.Anonymous.OffsetHigh = (offset as u64 >> 32) as u32;
    let status = unsafe {
        CfHydratePlaceholder(
            handle,
            offset as i64,
            length as i64,
            CF_HYDRATE_FLAG_NONE,
            &mut overlapped,
        )
    };
    // S_OK means the range is present. ERROR_IO_PENDING is HRESULT_FROM_WIN32(997).
    if status == 0x800703E5u32 as i32 {
        let mut transferred = 0;
        assert_ne!(
            unsafe { GetOverlappedResult(handle, &overlapped, &mut transferred, 1) },
            0,
            "GetOverlappedResult failed (Win32 error {})",
            unsafe { GetLastError() }
        );
    } else {
        assert_hresult(status, "CfHydratePlaceholder");
    }
}

fn hydrate_ranges_until<F>(handle: HANDLE, total_bytes: usize, mut should_cancel: F) -> usize
where
    F: FnMut(usize) -> bool,
{
    let mut offset = 0;
    while offset < total_bytes {
        // Cancellation is observed only after the previous range has completed.
        if should_cancel(offset) {
            break;
        }
        let length = RANGE_BYTES.min(total_bytes - offset);
        hydrate_range(handle, offset, length);
        offset += length;
    }
    offset
}

fn read_range(handle: HANDLE, offset: usize, output: &mut [u8]) {
    let mut overlapped = OVERLAPPED::default();
    overlapped.Anonymous.Anonymous.Offset = offset as u32;
    overlapped.Anonymous.Anonymous.OffsetHigh = (offset as u64 >> 32) as u32;
    let mut read = 0;
    let success = unsafe {
        ReadFile(
            handle,
            output.as_mut_ptr(),
            output.len() as u32,
            &mut read,
            &mut overlapped,
        )
    };
    if success == 0 {
        assert_ne!(
            unsafe { GetOverlappedResult(handle, &overlapped, &mut read, 1) },
            0,
            "ReadFile/GetOverlappedResult failed (Win32 error {})",
            unsafe { GetLastError() }
        );
    }
    assert_eq!(read as usize, output.len(), "short fixture read");
}

fn create_placeholder(root: &Path, filename: &str, content: &[u8]) -> PathBuf {
    let wide_name: Vec<u16> = filename.encode_utf16().chain(Some(0)).collect();
    let identity = b"hydration-probe-v1";
    let mut entry = CF_PLACEHOLDER_CREATE_INFO {
        RelativeFileName: wide_name.as_ptr(),
        FsMetadata: CF_FS_METADATA {
            FileSize: content.len() as i64,
            ..Default::default()
        },
        FileIdentity: identity.as_ptr().cast(),
        FileIdentityLength: identity.len() as u32,
        Flags: CF_PLACEHOLDER_CREATE_FLAG_MARK_IN_SYNC,
        ..Default::default()
    };
    let wide_root = wide_path(root);
    let mut processed = 0;
    assert_hresult(
        unsafe {
            CfCreatePlaceholders(
                wide_root.as_ptr(),
                &mut entry,
                1,
                CF_CREATE_FLAG_NONE,
                &mut processed,
            )
        },
        "CfCreatePlaceholders",
    );
    assert_eq!(
        processed, 1,
        "provider did not create exactly one placeholder"
    );
    root.join(filename)
}

fn register_provider(root: PathBuf, context: &ProviderContext) -> RegisteredProvider {
    fs::create_dir_all(&root).expect("create disposable sync-root directory");
    let mut provider = RegisteredProvider {
        root: root.clone(),
        connection: 0,
        registered: false,
    };
    let provider_name: Vec<u16> = "iCloud Folder Settler Test Provider"
        .encode_utf16()
        .chain(Some(0))
        .collect();
    let version: Vec<u16> = "1".encode_utf16().chain(Some(0)).collect();
    let registration = CF_SYNC_REGISTRATION {
        StructSize: size_of::<CF_SYNC_REGISTRATION>() as u32,
        ProviderName: provider_name.as_ptr(),
        ProviderVersion: version.as_ptr(),
        ..Default::default()
    };
    let policies = CF_SYNC_POLICIES {
        StructSize: size_of::<CF_SYNC_POLICIES>() as u32,
        Hydration: CF_HYDRATION_POLICY {
            Primary: CF_HYDRATION_POLICY_PARTIAL,
            Modifier: CF_HYDRATION_POLICY_MODIFIER_NONE,
        },
        Population: CF_POPULATION_POLICY {
            Primary: CF_POPULATION_POLICY_ALWAYS_FULL,
            Modifier: CF_POPULATION_POLICY_MODIFIER_NONE,
        },
        InSync: CF_INSYNC_POLICY_NONE,
        ..Default::default()
    };
    let wide_root = wide_path(&root);
    assert_hresult(
        unsafe {
            CfRegisterSyncRoot(
                wide_root.as_ptr(),
                &registration,
                &policies,
                CF_REGISTER_FLAG_MARK_IN_SYNC_ON_ROOT,
            )
        },
        "CfRegisterSyncRoot",
    );
    provider.registered = true;
    let callbacks = [
        CF_CALLBACK_REGISTRATION {
            Type: CF_CALLBACK_TYPE_FETCH_DATA,
            Callback: Some(fetch_data),
        },
        CF_CALLBACK_REGISTRATION {
            Type: CF_CALLBACK_TYPE_NONE,
            Callback: None,
        },
    ];
    let mut connection = 0;
    assert_hresult(
        unsafe {
            CfConnectSyncRoot(
                wide_root.as_ptr(),
                callbacks.as_ptr(),
                (context as *const ProviderContext).cast::<c_void>(),
                CF_CONNECT_FLAG_NONE,
                &mut connection,
            )
        },
        "CfConnectSyncRoot",
    );
    provider.connection = connection;
    provider
}

#[test]
#[ignore = "registers a disposable Cloud Files sync root; run via Test-NativeCloudFiles.ps1"]
fn explicit_hydration_uses_bounded_ranges_and_stable_file_identity() {
    let content: Vec<u8> = (0..CONTENT_BYTES)
        .map(|n| ((n * 31 + 7) % 251) as u8)
        .collect();
    let context = ProviderContext {
        content: content.clone(),
        callback_count: AtomicUsize::new(0),
        maximum_transfer: AtomicUsize::new(0),
        last_required_offset: AtomicUsize::new(0),
        execute_failure: AtomicUsize::new(0),
    };
    let root = std::env::temp_dir().join(format!(
        "icloud-cfapi-provider-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock should be after Unix epoch")
            .as_nanos()
    ));
    let provider = register_provider(root.clone(), &context);
    let placeholder = create_placeholder(&root, "bounded-hydration.bin", &content);
    let handle = open_overlapped(&placeholder);
    let before = file_identity(handle);

    let completed = hydrate_ranges_until(handle, content.len(), |_| false);

    let mut actual = vec![0; content.len()];
    for (chunk_index, chunk) in actual.chunks_mut(RANGE_BYTES).enumerate() {
        read_range(handle, chunk_index * RANGE_BYTES, chunk);
    }
    let after = file_identity(handle);
    unsafe { CloseHandle(handle) };

    assert_eq!(completed, content.len());
    assert_eq!(
        actual, content,
        "hydrated fixture content differs from provider data"
    );
    assert_eq!(
        before, after,
        "file identity or metadata changed during range hydration/read"
    );
    assert!(context.callback_count.load(Ordering::Relaxed) >= 4);
    assert!(context.maximum_transfer.load(Ordering::Relaxed) <= RANGE_BYTES);
    assert_eq!(context.execute_failure.load(Ordering::Relaxed), 0);
    drop(provider);
}

#[test]
#[ignore = "registers a disposable Cloud Files sync root; run via Test-NativeCloudFiles.ps1"]
fn cancellation_boundary_stops_before_the_next_hydration_range() {
    let content: Vec<u8> = (0..CONTENT_BYTES)
        .map(|n| ((n * 17 + 3) % 239) as u8)
        .collect();
    let context = ProviderContext {
        content: content.clone(),
        callback_count: AtomicUsize::new(0),
        maximum_transfer: AtomicUsize::new(0),
        last_required_offset: AtomicUsize::new(0),
        execute_failure: AtomicUsize::new(0),
    };
    let root = std::env::temp_dir().join(format!(
        "icloud-cfapi-cancel-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock should be after Unix epoch")
            .as_nanos()
    ));
    let provider = register_provider(root.clone(), &context);
    let placeholder = create_placeholder(&root, "cancel-boundary.bin", &content);
    let handle = open_overlapped(&placeholder);

    // Cancellation is intentionally cooperative: finish the current range,
    // then observe cancellation before requesting the next range.
    let completed = hydrate_ranges_until(handle, content.len(), |offset| offset >= RANGE_BYTES);
    let callbacks_after_stop = context.callback_count.load(Ordering::Relaxed);
    unsafe { CloseHandle(handle) };

    assert_eq!(completed, RANGE_BYTES);
    assert!(callbacks_after_stop >= 1);
    assert_eq!(
        context.last_required_offset.load(Ordering::Relaxed),
        0,
        "a later range was requested after the cancellation boundary"
    );
    drop(provider);
}

#[test]
#[ignore = "registers a disposable Cloud Files sync root; run via Test-NativeCloudFiles.ps1"]
fn worker_plan_hydrates_and_hashes_a_cloud_placeholder() {
    let content: Vec<u8> = (0..CONTENT_BYTES)
        .map(|n| ((n * 31 + 7) % 251) as u8)
        .collect();
    let context = ProviderContext {
        content: content.clone(),
        callback_count: AtomicUsize::new(0),
        maximum_transfer: AtomicUsize::new(0),
        last_required_offset: AtomicUsize::new(0),
        execute_failure: AtomicUsize::new(0),
    };
    let root = std::env::temp_dir().join(format!(
        "icloud-cfapi-worker-source-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock should be after Unix epoch")
            .as_nanos()
    ));
    let destination = root.with_file_name(format!(
        "icloud-cfapi-worker-destination-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock should be after Unix epoch")
            .as_nanos()
    ));
    let provider = register_provider(root.clone(), &context);
    let placeholder = create_placeholder(&root, "worker-plan.bin", &content);
    let identity_handle = open_overlapped(&placeholder);
    let before = file_identity(identity_handle);

    let request = serde_json::json!({
        "version": 1,
        "operation": "plan",
        "source": root,
        "destination": destination
    });
    let mut child = Command::new(env!("CARGO_BIN_EXE_icloud-folder-worker"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start the compiled read-only worker");
    let mut stdin = child.stdin.take().expect("worker stdin should be piped");
    use std::io::Write;
    writeln!(stdin, "{request}").expect("send the plan request");
    drop(stdin);
    let output = child.wait_with_output().expect("wait for worker plan");
    assert!(
        output.status.success(),
        "worker plan failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.stderr.is_empty(), "worker wrote unexpected stderr");
    let records: Vec<serde_json::Value> = String::from_utf8(output.stdout)
        .expect("worker output should be UTF-8")
        .lines()
        .map(|line| serde_json::from_str(line).expect("worker should emit valid NDJSON"))
        .collect();
    assert_eq!(records.last().unwrap()["type"], "result");
    assert_eq!(records.last().unwrap()["ok"], true);
    let file_entry = records
        .iter()
        .find(|record| {
            record["type"] == "entry"
                && record["entry"]["source"] == placeholder.to_string_lossy().as_ref()
        })
        .expect("the cloud placeholder should be present in the plan");
    assert_eq!(file_entry["entry"]["action"], "Copy");
    assert_eq!(
        file_entry["entry"]["hash"],
        "08AC44692A0086A216193A0FFF1AABC933F370566B7F41025A03F0145B5BE2B4"
    );
    assert!(
        !destination.exists(),
        "read-only planning created its target"
    );
    assert!(context.callback_count.load(Ordering::Relaxed) >= 4);
    assert!(context.maximum_transfer.load(Ordering::Relaxed) <= RANGE_BYTES);
    assert_eq!(context.execute_failure.load(Ordering::Relaxed), 0);
    let after = file_identity(identity_handle);
    unsafe { CloseHandle(identity_handle) };
    assert_eq!(before, after, "worker changed placeholder file identity");
    drop(provider);
}
