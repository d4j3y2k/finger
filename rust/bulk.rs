//! Darwin returns many directory entries and their metadata in one call. Records
//! use 4-byte packing, so decode integer fields from bytes (no unaligned casts).
use std::{
    fs::OpenOptions,
    io,
    os::{fd::AsRawFd, unix::fs::OpenOptionsExt},
    path::Path,
};

pub(super) struct Item<'a> {
    pub name: &'a str,
    pub kind: &'static str,
    pub hidden: bool,
    pub size: Option<u64>,
    pub modified: Option<i64>,
}

const ATTR_CMN_ERROR: u32 = 0x2000_0000;
const BUFFER_SIZE: usize = 128 * 1024;

fn layout_error() -> io::Error {
    io::Error::new(
        io::ErrorKind::InvalidData,
        "Unexpected directory metadata layout.",
    )
}

fn bytes<const N: usize>(data: &[u8], start: usize) -> io::Result<[u8; N]> {
    data.get(start..start.checked_add(N).ok_or_else(layout_error)?)
        .and_then(|part| part.try_into().ok())
        .ok_or_else(layout_error)
}

fn u32_at(data: &[u8], offset: usize) -> io::Result<u32> {
    Ok(u32::from_ne_bytes(bytes(data, offset)?))
}

fn decode(record: &[u8]) -> io::Result<Item<'_>> {
    // u32 length, then attribute_set_t (five u32 masks). With options=0 each
    // remaining field is present only if its returned bit is set.
    let common = u32_at(record, 4)?;
    let file = u32_at(record, 16)?;
    let mut cursor = 24;
    if common & ATTR_CMN_ERROR != 0 {
        let errno = u32_at(record, cursor)?;
        cursor += 4;
        if errno != 0 {
            return Err(io::Error::from_raw_os_error(errno as i32));
        }
    }
    if common & libc::ATTR_CMN_NAME == 0 {
        return Err(layout_error());
    }
    let offset = i32::from_ne_bytes(bytes(record, cursor)?);
    let length = u32_at(record, cursor + 4)? as usize;
    let start = cursor
        .checked_add_signed(offset as isize)
        .ok_or_else(layout_error)?;
    let end = start.checked_add(length).ok_or_else(layout_error)?;
    let raw = record
        .get(start..end)
        .and_then(|s| s.strip_suffix(&[0]))
        .ok_or_else(layout_error)?;
    let name = std::str::from_utf8(raw).map_err(|_| layout_error())?;
    cursor += 8;
    let kind = if common & libc::ATTR_CMN_OBJTYPE != 0 {
        let typ = u32_at(record, cursor)?;
        cursor += 4;
        // Darwin sys/vnode.h enum vtype.
        match typ {
            1 => "file",
            2 => "folder",
            5 => "symlink",
            _ => "other",
        }
    } else {
        // Without an object type folders could be mistaken for ordinary files.
        // Restart with read_dir on volumes that cannot vend it.
        return Err(layout_error());
    };
    let modified = if common & libc::ATTR_CMN_MODTIME != 0 {
        let seconds = i64::from_ne_bytes(bytes(record, cursor)?);
        cursor += size_of::<libc::timespec>();
        Some(seconds)
    } else {
        None
    };
    let hidden = if common & libc::ATTR_CMN_FLAGS != 0 {
        let flags = u32_at(record, cursor)?;
        cursor += 4;
        flags & libc::UF_HIDDEN != 0
    } else {
        false
    };
    let size = if file & libc::ATTR_FILE_DATALENGTH != 0 {
        u64::try_from(i64::from_ne_bytes(bytes(record, cursor)?)).ok()
    } else {
        None
    };
    if modified.is_none()
        || common & libc::ATTR_CMN_FLAGS == 0
        || (matches!(kind, "file" | "symlink") && size.is_none())
    {
        // Network and provider volumes may return a subset of the requested
        // groups. The caller can still recover dates, flags and sizes via lstat.
        return Err(layout_error());
    }
    Ok(Item {
        name,
        kind,
        modified,
        hidden,
        size,
    })
}

pub(super) fn visit(
    path: &Path,
    cancelled: &dyn Fn() -> bool,
    mut visit_item: impl FnMut(Item<'_>),
) -> io::Result<()> {
    records(path, cancelled, |bytes| {
        visit_item(decode(bytes)?);
        Ok(())
    })
}

pub(super) fn records(
    path: &Path,
    cancelled: &dyn Fn() -> bool,
    mut visit_record: impl FnMut(&[u8]) -> io::Result<()>,
) -> io::Result<()> {
    crate::listing::check_cancelled(cancelled)?;
    let dir = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY)
        .open(path)?;
    let mut attributes = libc::attrlist {
        bitmapcount: libc::ATTR_BIT_MAP_COUNT,
        reserved: 0,
        commonattr: libc::ATTR_CMN_RETURNED_ATTRS
            | ATTR_CMN_ERROR
            | libc::ATTR_CMN_NAME
            | libc::ATTR_CMN_OBJTYPE
            | libc::ATTR_CMN_MODTIME
            | libc::ATTR_CMN_FLAGS,
        volattr: 0,
        dirattr: 0,
        fileattr: libc::ATTR_FILE_DATALENGTH,
        forkattr: 0,
    };
    let mut data = vec![0u8; BUFFER_SIZE];
    loop {
        crate::listing::check_cancelled(cancelled)?;
        // The descriptor points to an open directory; the kernel receives the
        // complete writable buffer and a fully initialized attribute request.
        let count = unsafe {
            libc::getattrlistbulk(
                dir.as_raw_fd(),
                (&mut attributes as *mut libc::attrlist).cast(),
                data.as_mut_ptr().cast(),
                data.len(),
                0,
            )
        };
        if count < 0 {
            return Err(io::Error::last_os_error());
        }
        if count == 0 {
            return Ok(());
        }
        let mut rest = &data[..];
        for _ in 0..count {
            let length = u32_at(rest, 0)? as usize;
            if length < 24 || length > rest.len() {
                return Err(layout_error());
            }
            let (record, next) = rest.split_at(length);
            visit_record(record)?;
            rest = next;
        }
    }
}
