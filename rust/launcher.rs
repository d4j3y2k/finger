use finger_core::navigation::{Navigation, SearchIndex, drop_index, query_index};
use serde_json::{Value, json};
use std::ffi::{CStr, CString, c_char, c_void};
use std::path::Path;
use std::sync::{LazyLock, Mutex, MutexGuard};

static NAV: LazyLock<Mutex<Navigation>> = LazyLock::new(|| Mutex::new(Navigation::default()));
static SEARCH: LazyLock<Mutex<SearchIndex>> = LazyLock::new(|| Mutex::new(SearchIndex::default()));

type Request = extern "C" fn(i32, *const c_char) -> *mut c_char;
type Release = extern "C" fn(*mut c_char);
type EmitEntry = extern "C" fn(*mut c_void, *const u8, usize, u8, u8, i64, i64);
type Cancelled = extern "C" fn(*mut c_void) -> u8;
const PREVIEW: u8 = 1 << 7;
type List = extern "C" fn(
    *const c_char,
    u8,
    *mut c_void,
    EmitEntry,
    *mut *mut c_void,
    Option<Cancelled>,
) -> *mut c_char;
type Query = unsafe extern "C" fn(*mut c_void, *const c_char, *mut isize) -> *const usize;
type DropIndex = unsafe extern "C" fn(*mut c_void);

#[link(name = "FingerNative")]
unsafe extern "C" {
    fn finger_run(
        request: Request,
        release: Release,
        list: List,
        query: Query,
        drop_index: DropIndex,
    );
}

/// `request` catches a handler panic, which poisons the lock that handler held.
/// The state may be half-updated, so start it fresh instead of failing every
/// later navigation or search request for the rest of the session.
fn lock<T: Default>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| {
        let mut guard = poisoned.into_inner();
        *guard = T::default();
        mutex.clear_poison();
        guard
    })
}

extern "C" fn request(service: i32, payload: *const c_char) -> *mut c_char {
    if payload.is_null() {
        return std::ptr::null_mut();
    }
    let result = std::panic::catch_unwind(|| {
        let raw = unsafe { CStr::from_ptr(payload) }.to_str().unwrap_or("");
        if service == 0 {
            return finger_core::request_json(raw);
        }
        let p: Value = match serde_json::from_str(raw) {
            Ok(value) => value,
            Err(_) => return json!({"ok":false,"error":"Invalid request"}).to_string(),
        };
        let reply = match service {
            1 => lock(&NAV).handle(&p),
            2 => lock(&SEARCH).install(&p["names"]),
            3 => lock(&SEARCH).find(p["query"].as_str().unwrap_or("")),
            _ => json!({"ok":false,"error":"Unknown service"}),
        };
        reply.to_string()
    })
    .unwrap_or_else(|_| {
        json!({"ok":false,"error":"The file engine could not complete the request"}).to_string()
    });
    CString::new(result).unwrap().into_raw()
}

extern "C" fn release(pointer: *mut c_char) {
    if !pointer.is_null() {
        unsafe {
            drop(CString::from_raw(pointer));
        }
    }
}

// Emit sorted entries synchronously into the native caller's private accumulator.
// A filename and its length are valid for the duration of this one callback.
extern "C" fn list(
    path: *const c_char,
    flags: u8,
    context: *mut c_void,
    emit: EmitEntry,
    out_index: *mut *mut c_void,
    cancelled: Option<Cancelled>,
) -> *mut c_char {
    if !out_index.is_null() {
        unsafe {
            *out_index = std::ptr::null_mut();
        }
    }
    let result = std::panic::catch_unwind(|| {
        if path.is_null() {
            return Err("A folder path is required.".to_owned());
        }
        let raw = unsafe { CStr::from_ptr(path) }
            .to_str()
            .map_err(|e| e.to_string())?;
        let sort = finger_core::SortOrder::from_mode((flags & !PREVIEW) >> 1)
            .ok_or_else(|| "Unknown folder sort order.".to_owned())?;
        let is_cancelled = || cancelled.is_some_and(|test| test(context) != 0);
        if flags & PREVIEW != 0 {
            return finger_core::preview_json_cancellable(
                0,
                Path::new(raw),
                flags & 1 != 0,
                sort,
                &is_cancelled,
            )
            .map(Some)
            .map_err(|error| error.to_string());
        }
        let mut index = (!out_index.is_null()).then(SearchIndex::default);
        let warnings = finger_core::visit_entries_cancellable(
            Path::new(raw),
            flags & 1 != 0,
            sort,
            &is_cancelled,
            |name, kind, directory, size, modified| {
                if let Some(index) = &mut index {
                    index.push_name(name);
                }
                let tag = match kind {
                    "folder" => 1,
                    "symlink" => 2,
                    "other" => 3,
                    _ => 0,
                };
                emit(
                    context,
                    name.as_ptr(),
                    name.len(),
                    tag,
                    u8::from(directory),
                    size.map(|n| n.min(i64::MAX as u64) as i64).unwrap_or(-1),
                    modified.unwrap_or(i64::MIN),
                );
            },
        )?;
        let report =
            (!warnings.is_empty()).then(|| json!({"ok":true,"warnings":warnings}).to_string());
        if let Some(index) = index {
            unsafe {
                *out_index = index.into_handle();
            }
        }
        Ok(report)
    })
    .unwrap_or_else(|_| Err("The file engine could not read the folder.".to_owned()));
    let report = match result {
        Ok(None) => return std::ptr::null_mut(),
        Ok(Some(report)) => report,
        Err(error) => json!({"ok":false,"error":error}).to_string(),
    };
    CString::new(report).unwrap().into_raw()
}
fn main() {
    unsafe {
        finger_run(request, release, list, query_index, drop_index);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ptr::{null, null_mut};
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn a_poisoned_lock_resets_its_state_instead_of_failing_forever() {
        let state = std::sync::Arc::new(Mutex::new(vec![1, 2, 3]));
        let held = state.clone();
        let _ = std::thread::spawn(move || {
            let _guard = held.lock().unwrap();
            panic!("handler failed mid-update");
        })
        .join();
        assert!(state.is_poisoned());
        assert!(super::lock(&state).is_empty());
        assert!(!state.is_poisoned());
        super::lock(&state).push(4);
        assert_eq!(*super::lock(&state), vec![4]);
    }

    extern "C" fn record(
        ctx: *mut c_void,
        name: *const u8,
        len: usize,
        _: u8,
        _: u8,
        _: i64,
        _: i64,
    ) {
        let names = unsafe { &mut *ctx.cast::<Vec<String>>() };
        let text = unsafe { std::slice::from_raw_parts(name, len) };
        names.push(std::str::from_utf8(text).unwrap().to_owned());
    }

    #[test]
    fn inspector_returns_only_bounded_json_and_aborts_superseded_reads() {
        #[derive(Default)]
        struct Inspector {
            polls: usize,
            stop_at: usize,
            emitted: usize,
        }
        extern "C" fn poll(context: *mut c_void) -> u8 {
            let context = unsafe { &mut *context.cast::<Inspector>() };
            context.polls += 1;
            u8::from(context.polls >= context.stop_at)
        }
        extern "C" fn emit(
            context: *mut c_void,
            _: *const u8,
            _: usize,
            _: u8,
            _: u8,
            _: i64,
            _: i64,
        ) {
            unsafe {
                (*context.cast::<Inspector>()).emitted += 1;
            }
        }
        let folder =
            std::env::temp_dir().join(format!("finger-native-preview-{}", std::process::id()));
        std::fs::create_dir(&folder).unwrap();
        for n in 0..600 {
            std::fs::write(folder.join(format!("sheet-{n}.png")), [n as u8]).unwrap();
        }
        std::fs::write(folder.join(".hidden"), []).unwrap();
        let cpath = CString::new(folder.to_str().unwrap()).unwrap();
        for stop_at in [1, 4, usize::MAX] {
            let mut context = Inspector {
                stop_at,
                ..Default::default()
            };
            let mut index = std::ptr::dangling_mut::<u8>().cast();
            let response = list(
                cpath.as_ptr(),
                PREVIEW | 1 | 2,
                (&mut context as *mut Inspector).cast(),
                emit,
                &mut index,
                Some(poll),
            );
            assert!(!response.is_null() && index.is_null());
            let json: Value =
                serde_json::from_slice(unsafe { CStr::from_ptr(response) }.to_bytes()).unwrap();
            release(response);
            assert_eq!(context.emitted, 0);
            if stop_at == usize::MAX {
                let normal: Value = serde_json::from_str(&finger_core::request_json(
                    &json!({"op":"preview", "path":folder, "showHidden":true,"sort":"nameDesc"})
                        .to_string(),
                ))
                .unwrap();
                assert_eq!(json, normal);
                assert_eq!(json["total"], 601);
                assert_eq!(json["entries"].as_array().unwrap().len(), 32);
                assert_eq!(json["media"].as_array().unwrap().len(), 3);
            } else {
                assert_eq!(json["ok"], false);
                assert!(json["error"].as_str().unwrap().contains("canceled"));
                assert!(json.get("entries").is_none());
            }
        }
        std::fs::remove_dir_all(folder).unwrap();
    }

    #[test]
    fn cancelled_native_scan_releases_partial_index_and_leaves_other_loads_alone() {
        struct Context {
            emitted: usize,
            stop_after: usize,
        }
        extern "C" fn count_rows(
            ctx: *mut c_void,
            _: *const u8,
            _: usize,
            _: u8,
            _: u8,
            _: i64,
            _: i64,
        ) {
            unsafe {
                (*ctx.cast::<Context>()).emitted += 1;
            }
        }
        extern "C" fn stop(ctx: *mut c_void) -> u8 {
            let ctx = unsafe { &*ctx.cast::<Context>() };
            u8::from(ctx.emitted >= ctx.stop_after)
        }
        let root =
            std::env::temp_dir().join(format!("finger-native-cancel-{}", std::process::id()));
        std::fs::create_dir(&root).unwrap();
        for i in 0..600 {
            std::fs::write(root.join(format!("export-{i}.png")), []).unwrap();
        }
        let path = CString::new(root.to_str().unwrap()).unwrap();
        for threshold in [0, 1, usize::MAX] {
            let mut ctx = Context {
                emitted: 0,
                stop_after: threshold,
            };
            let mut handle = null_mut();
            let status = list(
                path.as_ptr(),
                0,
                (&mut ctx as *mut Context).cast(),
                count_rows,
                &mut handle,
                Some(stop),
            );
            if threshold == usize::MAX {
                assert!(status.is_null() && !handle.is_null());
                assert_eq!(ctx.emitted, 600);
                unsafe {
                    drop_index(handle);
                }
            } else {
                assert!(!status.is_null() && handle.is_null());
                assert_eq!(ctx.emitted, if threshold == 0 { 0 } else { 256 });
                let msg = unsafe { CStr::from_ptr(status) }.to_str().unwrap();
                assert!(msg.contains("canceled"));
                release(status);
            }
        }
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn typed_list_only_hands_off_a_complete_matching_index() {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let folder = std::env::temp_dir().join(format!(
            "finger-native-index-{}-{suffix}",
            std::process::id()
        ));
        std::fs::create_dir(&folder).unwrap();
        std::fs::write(folder.join("frame 2.svg"), []).unwrap();
        std::fs::write(folder.join("frame 12.svg"), []).unwrap();
        std::fs::write(folder.join(".notes"), []).unwrap();
        let path = CString::new(folder.to_str().unwrap()).unwrap();
        let mut names = Vec::<String>::new();
        let ctx = (&mut names as *mut Vec<String>).cast();
        let mut index = null_mut();
        let response = list(path.as_ptr(), 2, ctx, record, &mut index, None);
        assert!(response.is_null() && !index.is_null());
        assert_eq!(names, ["frame 12.svg", "frame 2.svg"]);
        let mut count = 0;
        let hits = unsafe { query_index(index, c" 2.svg".as_ptr(), &mut count) };
        assert_eq!(count, 2); // both basenames end in 2.svg
        assert_eq!(unsafe { std::slice::from_raw_parts(hits, 2) }, &[0, 1]);
        let hits = unsafe { query_index(index, c"12".as_ptr(), &mut count) };
        assert_eq!(count, 1);
        assert_eq!(unsafe { *hits }, 0);
        unsafe {
            drop_index(index);
        }

        names.clear();
        assert!(list(path.as_ptr(), 1, ctx, record, null_mut(), None).is_null());
        assert_eq!(names, [".notes", "frame 2.svg", "frame 12.svg"]);
        std::fs::remove_dir_all(&folder).unwrap();
        // A stale value in the OUT slot must be cleared even on early returns.
        for (path, flags) in [
            (path.as_ptr(), 0),
            (null(), 0),
            (c"relative".as_ptr(), 0),
            (c"/".as_ptr(), 255),
        ] {
            index = std::ptr::dangling_mut::<u8>().cast();
            let error = list(path, flags, ctx, record, &mut index, None);
            assert!(index.is_null() && !error.is_null());
            let result: Value =
                serde_json::from_str(unsafe { CStr::from_ptr(error) }.to_str().unwrap()).unwrap();
            assert_eq!(result["ok"], false);
            release(error);
        }
    }
}
