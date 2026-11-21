//! Small Core Foundation adapters for macOS package metadata and Unicode folding.
use std::{ffi::c_void, io, os::unix::ffi::OsStrExt, path::Path, ptr};

type Ref = *const c_void;
const UTF8: u32 = 0x0800_0100;
const QOS_CLASS_UTILITY: u32 = 0x11;
unsafe extern "C" {
    fn pthread_set_qos_class_self_np(class: u32, relative_priority: i32) -> i32;
}

pub(super) fn set_indexing_priority() {
    // A best-effort scheduling hint for this dedicated worker. AppKit event
    // handling and foreground directory opens retain their usual priority.
    unsafe { pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0) };
}

#[repr(C)]
struct Range {
    start: isize,
    length: isize,
}

#[link(name = "CoreFoundation", kind = "framework")]
unsafe extern "C" {
    fn CFRelease(value: Ref);
    fn CFStringCreateWithBytes(
        alloc: Ref,
        bytes: *const u8,
        count: isize,
        encoding: u32,
        external: u8,
    ) -> Ref;
    fn CFStringCreateMutableCopy(alloc: Ref, maximum: isize, source: Ref) -> Ref;
    fn CFStringFold(string: Ref, flags: usize, locale: Ref);
    fn CFStringNormalize(string: Ref, form: isize);
    fn CFStringGetLength(string: Ref) -> isize;
    fn CFStringGetMaximumSizeForEncoding(length: isize, encoding: u32) -> isize;
    fn CFStringGetBytes(
        string: Ref,
        range: Range,
        encoding: u32,
        loss: u8,
        external: u8,
        buffer: *mut u8,
        size: isize,
        used: *mut isize,
    ) -> isize;

    fn CFURLCreateFromFileSystemRepresentation(
        alloc: Ref,
        bytes: *const u8,
        count: isize,
        directory: u8,
    ) -> Ref;
    fn CFURLCopyResourcePropertyForKey(url: Ref, key: Ref, result: *mut Ref, error: *mut Ref)
    -> u8;
    fn CFBooleanGetValue(value: Ref) -> u8;
    static kCFURLIsPackageKey: Ref;
}

struct Owned(Ref);
impl Owned {
    fn new(value: Ref) -> Option<Self> {
        if value.is_null() {
            None
        } else {
            Some(Self(value))
        }
    }
}
impl Drop for Owned {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0) }
    }
}

// CFStringFold handles macOS case, accent and width equivalence. Canonical
// composition also makes decomposed and precomposed Hangul search identically.
pub fn fold_search_text(text: &str) -> String {
    if text.is_ascii() {
        return text.to_ascii_lowercase();
    }
    fn folded(text: &str) -> Option<String> {
        let input = Owned::new(unsafe {
            CFStringCreateWithBytes(ptr::null(), text.as_ptr(), text.len() as isize, UTF8, 0)
        })?;
        let work = Owned::new(unsafe { CFStringCreateMutableCopy(ptr::null(), 0, input.0) })?;
        unsafe {
            CFStringFold(work.0, 1 | 128 | 256, ptr::null());
            CFStringNormalize(work.0, 2);
        }
        let length = unsafe { CFStringGetLength(work.0) };
        let capacity = unsafe { CFStringGetMaximumSizeForEncoding(length, UTF8) };
        let mut buffer = vec![0u8; usize::try_from(capacity).ok()?];
        let mut used = 0;
        let converted = unsafe {
            CFStringGetBytes(
                work.0,
                Range { start: 0, length },
                UTF8,
                0,
                0,
                buffer.as_mut_ptr(),
                capacity,
                &mut used,
            )
        };
        if converted != length {
            return None;
        }
        buffer.truncate(usize::try_from(used).ok()?);
        String::from_utf8(buffer).ok()
    }
    folded(text).unwrap_or_else(|| text.to_lowercase())
}

pub(super) fn is_package(path: &Path) -> io::Result<bool> {
    let bytes = path.as_os_str().as_bytes();
    let url = Owned::new(unsafe {
        CFURLCreateFromFileSystemRepresentation(
            ptr::null(),
            bytes.as_ptr(),
            bytes.len() as isize,
            1,
        )
    })
    .ok_or_else(|| io::Error::other("Could not inspect a folder's package type."))?;
    let mut result: Ref = ptr::null();
    let ok = unsafe {
        CFURLCopyResourcePropertyForKey(url.0, kCFURLIsPackageKey, &mut result, ptr::null_mut())
    };
    let value = Owned::new(result);
    match value {
        Some(value) if ok != 0 => Ok(unsafe { CFBooleanGetValue(value.0) != 0 }),
        _ => Err(io::Error::other(
            "The filesystem did not supply a folder's package type.",
        )),
    }
}
