//! Whole-item transfers. The destination name is claimed by an exclusive rename,
//! or exclusive creation on volumes that lack it. No existing item is overwritten.
#[path = "exclusive_copy.rs"]
mod exclusive_copy;
#[path = "receipts.rs"]
mod receipts;
use crate::absolute;
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    ffi::CString,
    fs, io,
    os::fd::{AsRawFd, FromRawFd},
    os::macos::fs::MetadataExt as MacMetadataExt,
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

#[derive(Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum Collision {
    #[default]
    Error,
    Skip,
    KeepBoth,
}

#[derive(Serialize)]
pub(crate) struct Batch {
    results: Vec<Outcome>,
}

#[derive(Serialize)]
struct Outcome {
    source: PathBuf,
    destination: PathBuf,
    status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    receipt: Option<String>,
}

fn input_error(message: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message.into())
}

fn c_path(path: &Path) -> io::Result<CString> {
    CString::new(path.as_os_str().as_bytes())
        .map_err(|_| input_error("A path contains a null character."))
}

fn exclusive_rename(from: &Path, to: &Path) -> io::Result<()> {
    let from = c_path(from)?;
    let to = c_path(to)?;
    // Both NUL-terminated strings live for the duration of the call.
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn rename_exact(source: &Path, destination: &Path) -> io::Result<()> {
    let name = destination
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| input_error("A destination filename is required."))?;
    let parent = source
        .parent()
        .ok_or_else(|| input_error("A volume root cannot be renamed here."))?;
    if source == destination {
        fs::symlink_metadata(source)?;
    } else if let Err(err) = exclusive_rename(source, destination) {
        if err.kind() != io::ErrorKind::Unsupported {
            return Err(err);
        }
        let meta = fs::symlink_metadata(source)?;
        if meta.is_dir() && fs::metadata(parent)?.dev() != meta.dev() {
            return Err(input_error("A mounted volume cannot be renamed here."));
        }
        let same_case_variant = source
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.eq_ignore_ascii_case(name))
            && fs::symlink_metadata(destination)
                .is_ok_and(|m| (m.dev(), m.ino()) == (meta.dev(), meta.ino()))
            && !fs::read_dir(parent)?
                .filter_map(Result::ok)
                .any(|e| e.file_name().as_bytes() == name.as_bytes());
        if same_case_variant {
            // On a case-insensitive volume these two spellings address one name.
            fs::rename(source, destination)?;
        } else {
            copy_publish(source, destination, true)?;
        }
    }
    Ok(())
}

#[derive(Serialize)]
pub(crate) struct Renamed {
    path: PathBuf,
    #[serde(skip_serializing_if = "Option::is_none")]
    receipt: Option<String>,
}

fn verify_selection(source: &Path, expected: Option<&str>) -> io::Result<()> {
    let Some(expected) = expected else {
        return Ok(());
    };
    let meta = fs::symlink_metadata(source)?;
    let current = format!(
        "{}:{}:{}:{}",
        meta.st_dev(),
        meta.ino(),
        meta.st_birthtime(),
        meta.st_birthtime_nsec()
    );
    if expected == current {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "{} is no longer the item you selected. Select it again to continue.",
            source.display()
        )))
    }
}

pub(crate) fn rename(source: &Path, name: &str, expected: Option<&str>) -> io::Result<Renamed> {
    let parent = source
        .parent()
        .ok_or_else(|| input_error("A volume root cannot be renamed here."))?;
    let path = parent.join(name);
    let mut history = receipts::lock();
    let prior = (source != path).then(|| history.prepare(source));
    verify_selection(source, expected)?;
    rename_exact(source, &path)?;
    let receipt = prior.map(|old| history.record(old, &path));
    Ok(Renamed { path, receipt })
}

pub(crate) fn restore(tokens: &[String]) -> Batch {
    receipts::apply(tokens)
}

const BLOCKING_FLAGS: u32 =
    libc::UF_IMMUTABLE | libc::UF_APPEND | libc::SF_IMMUTABLE | libc::SF_APPEND;

struct StagingDir {
    path: PathBuf,
    identity: (u64, u64),
}

impl StagingDir {
    fn create(parent: &Path) -> io::Result<Self> {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        loop {
            let path = parent.join(format!(
                ".finger-transfer-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match fs::DirBuilder::new().mode(0o700).create(&path) {
                Ok(()) => {
                    let m = fs::symlink_metadata(&path)?;
                    return Ok(Self {
                        path,
                        identity: (m.dev(), m.ino()),
                    });
                }
                Err(err) if err.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(err) => return Err(err),
            }
        }
    }
}

impl Drop for StagingDir {
    fn drop(&mut self) {
        let Ok(meta) = fs::symlink_metadata(&self.path) else {
            return;
        };
        if self.identity != (meta.dev(), meta.ino()) {
            return;
        }
        if fs::remove_dir_all(&self.path).is_err() {
            // Copies retain macOS lock flags and read-only directory modes. Only
            // relax the private staged copies when normal cleanup cannot proceed.
            relax_staged(&self.path);
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

fn relax_staged(root: &Path) {
    let mut pending = vec![root.to_owned()];
    while let Some(path) = pending.pop() {
        let Ok(m) = fs::symlink_metadata(&path) else {
            continue;
        };
        relax_owned(&path, &m);
        if m.is_dir() {
            if let Ok(children) = fs::read_dir(&path) {
                pending.extend(children.filter_map(Result::ok).map(|child| child.path()));
            }
        }
    }
}

fn relax_owned(path: &Path, meta: &fs::Metadata) {
    let flags = meta.st_flags();
    if flags & BLOCKING_FLAGS != 0 {
        if let Ok(name) = c_path(path) {
            unsafe { libc::lchflags(name.as_ptr(), flags & !BLOCKING_FLAGS) };
        }
    }
    if meta.is_dir() {
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o700));
    }
}

// An immutable source is copyable, but its staged clone cannot be renamed while
// the inherited lock is set. Restore the exact flags on the same open inode.
fn publish(staged: &Path, destination: &Path) -> io::Result<()> {
    let flags = fs::symlink_metadata(staged)?.st_flags();
    if flags & BLOCKING_FLAGS == 0 {
        return exclusive_rename(staged, destination);
    }
    let name = c_path(staged)?;
    let descriptor = unsafe {
        libc::open(
            name.as_ptr(),
            libc::O_EVTONLY | libc::O_SYMLINK | libc::O_CLOEXEC,
        )
    };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    let held = unsafe { fs::File::from_raw_fd(descriptor) };
    if unsafe { libc::fchflags(held.as_raw_fd(), flags & !BLOCKING_FLAGS) } < 0 {
        return Err(io::Error::last_os_error());
    }
    exclusive_rename(staged, destination)?;
    if unsafe { libc::fchflags(held.as_raw_fd(), flags) } < 0 {
        return Err(io::Error::other(format!(
            "Copied to {}, but restoring its lock failed: {}",
            destination.display(),
            io::Error::last_os_error()
        )));
    }
    Ok(())
}

fn copy_item(source: &Path, destination: &Path, directory_metadata: bool) -> io::Result<()> {
    let from = c_path(source)?;
    let to = c_path(destination)?;
    let metadata =
        libc::COPYFILE_ACL | libc::COPYFILE_STAT | libc::COPYFILE_XATTR | libc::COPYFILE_NOFOLLOW;
    // Directory contents are copied explicitly so hard links and error handling
    // remain intact. Apply the directory's restrictive metadata after its children.
    let flags = if directory_metadata {
        metadata
    } else {
        metadata | libc::COPYFILE_DATA | libc::COPYFILE_CLONE
    };
    // copyfile copies macOS ACLs, resource forks, xattrs, dates, and symbolic links.
    if unsafe { libc::copyfile(from.as_ptr(), to.as_ptr(), std::ptr::null_mut(), flags) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[derive(Debug, Eq, PartialEq)]
struct Stamp {
    device: u64,
    inode: u64,
    length: u64,
    changed: (i64, i64),
    modified: (i64, i64),
    links: u64,
    flags: u32,
    mode: u32,
    is_dir: bool,
}

fn stamp(path: &Path) -> io::Result<Stamp> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.is_dir() && !meta.is_file() && !meta.file_type().is_symlink() {
        return Err(input_error(format!(
            "{} is a special filesystem item that cannot be copied.",
            path.display()
        )));
    }
    Ok(Stamp {
        device: meta.dev(),
        inode: meta.ino(),
        length: meta.len(),
        changed: (meta.ctime(), meta.ctime_nsec()),
        modified: (meta.mtime(), meta.mtime_nsec()),
        links: meta.nlink(),
        flags: meta.st_flags(),
        mode: meta.mode(),
        is_dir: meta.is_dir(),
    })
}

// Record identities before a cross-volume copy. Remove only the entries actually
// copied, and use rmdir on directories so newly created content always survives.
fn inventory(source: &Path) -> io::Result<Vec<(PathBuf, Stamp)>> {
    let source_device = fs::symlink_metadata(source)?.dev();
    let mut stack = vec![source.to_path_buf()];
    let mut result = Vec::new();
    while let Some(path) = stack.pop() {
        let entry = stamp(&path)?;
        if entry.device != source_device {
            return Err(input_error(format!(
                "{} contains a separate mounted volume.",
                source.display()
            )));
        }
        if entry.is_dir {
            for item in fs::read_dir(&path)? {
                stack.push(item?.path());
            }
        }
        result.push((path, entry));
    }
    Ok(result)
}

fn check_unchanged(items: &[(PathBuf, Stamp)]) -> io::Result<()> {
    for (path, expected) in items {
        if stamp(path)? != *expected {
            return Err(io::Error::other(format!(
                "{} changed during the copy.",
                path.display()
            )));
        }
    }
    Ok(())
}

// macOS emulates forks and extended attributes on volumes such as exFAT
// using AppleDouble companions. copyfile transfers their logical attributes
// with the owner. Treat unrelated dot-underscore files as ordinary content.
fn apple_double_companion(path: &Path) -> bool {
    use std::{ffi::OsStr, io::Read};
    let Some(owner) = path
        .file_name()
        .and_then(|n| n.as_bytes().strip_prefix(b"._"))
    else {
        return false;
    };
    if owner.is_empty()
        || fs::symlink_metadata(path.with_file_name(OsStr::from_bytes(owner))).is_err()
    {
        return false;
    }
    let mut signature = [0u8; 8];
    fs::File::open(path)
        .and_then(|mut f| f.read_exact(&mut signature))
        .is_ok()
        && signature == [0, 5, 0x16, 7, 0, 2, 0, 0]
}

fn copy_tree(
    source: &Path,
    staged: &Path,
    manifest: &[(PathBuf, Stamp)],
    mut claims: Option<&mut exclusive_copy::Claims>,
) -> io::Result<()> {
    let mut hard_links = HashMap::new();
    let mut directories = Vec::new();
    let emulated =
        exclusive_copy::volume_supports(source, libc::VOL_CAP_INT_EXTENDED_ATTR) == Some(false);
    for (path, entry) in manifest {
        if emulated
            && path != source
            && entry.mode & libc::S_IFMT as u32 == libc::S_IFREG as u32
            && apple_double_companion(path)
        {
            continue;
        }
        let relative = path
            .strip_prefix(source)
            .expect("inventory is rooted at source");
        // Path::join("") appends a trailing slash, which changes copyfile's semantics.
        let target = if relative.as_os_str().is_empty() {
            staged.to_owned()
        } else {
            staged.join(relative)
        };
        let key = (entry.device, entry.inode);
        if entry.is_dir {
            fs::DirBuilder::new().mode(0o700).create(&target)?;
            if let Some(claims) = claims.as_deref_mut() {
                claims.new_item(&target, fs::symlink_metadata(&target)?);
            }
            directories.push((path, target));
        } else if let Some(first) = hard_links.get(&key) {
            fs::hard_link(first, &target)?;
            if let Some(claims) = claims.as_deref_mut() {
                claims.new_item(&target, fs::symlink_metadata(&target)?);
            }
        } else {
            if let Some(claims) = claims.as_deref_mut() {
                claims.copy_file(path, &target, entry.mode)?;
            } else {
                copy_item(path, &target, false)?;
            }
            if entry.links > 1 {
                hard_links.insert(key, target);
            }
        }
    }
    for (src, dst) in directories.into_iter().rev() {
        copy_item(src, &dst, true)?;
    }
    Ok(())
}

fn remove_copied_source(items: &[(PathBuf, Stamp)]) -> io::Result<()> {
    let mut removed_links = HashMap::new();
    for (path, expected) in items.iter().rev() {
        let actual = match stamp(path) {
            Ok(actual) => actual,
            // macOS can remove an AppleDouble sidecar together with its data
            // file on exFAT. An already-absent original needs no further work.
            Err(err) if err.kind() == io::ErrorKind::NotFound => continue,
            Err(err) => return Err(err),
        };
        let key = (expected.device, expected.inode);
        let removed = removed_links.get(&key).copied().unwrap_or(0);
        // Unlinking another member of this hard-link group increments ctime
        // and decrements nlink. All data and permissions must still match.
        let same_file = expected == &actual
            || (removed > 0
                && actual.links + removed == expected.links
                && actual.modified == expected.modified
                && actual.mode == expected.mode
                && actual.length == expected.length);
        if expected.device != actual.device
            || expected.inode != actual.inode
            || (!expected.is_dir && !same_file)
        {
            return Err(io::Error::other(format!(
                "{} changed after the copy.",
                path.display()
            )));
        }
        if expected.is_dir {
            fs::remove_dir(path)?;
        } else {
            fs::remove_file(path)?;
            if expected.links > 1 {
                removed_links.insert(key, removed + 1);
            }
        }
    }
    Ok(())
}

fn copy_publish(source: &Path, destination: &Path, moving: bool) -> io::Result<()> {
    let parent = destination
        .parent()
        .ok_or_else(|| input_error("Choose a destination folder."))?;
    let original = inventory(source)?;
    if moving {
        if let Some((path, _)) = original
            .iter()
            .find(|(_, item)| item.flags & BLOCKING_FLAGS != 0)
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!(
                    "{} is locked. Unlock it before moving across volumes.",
                    path.display()
                ),
            ));
        }
    }
    if exclusive_copy::volume_supports(parent, libc::VOL_CAP_INT_RENAME_EXCL) != Some(false) {
        let stage = StagingDir::create(parent)?;
        let staged = stage.path.join("item");
        // An EEXIST inside the tree, such as a case-folding collision, is a
        // copy error. Only an EEXIST claiming the root can be fixed by Keep Both.
        copy_tree(source, &staged, &original, None).map_err(|err| {
            io::Error::other(format!("Could not copy {}: {err}", source.display()))
        })?;
        check_unchanged(&original)?;
        match publish(&staged, destination) {
            Err(err) if err.kind() == io::ErrorKind::Unsupported => {
                drop(stage);
                exclusive_copy::copy(source, destination, &original)?;
            }
            result => result?,
        }
    } else {
        exclusive_copy::copy(source, destination, &original)?;
    }
    if moving {
        remove_copied_source(&original).map_err(|err| {
            io::Error::other(format!(
                "The copy is at {}. Finger could not finish removing the original: {err}",
                destination.display()
            ))
        })?;
    }
    Ok(())
}

fn transfer(source: &Path, destination: &Path, moving: bool) -> io::Result<()> {
    if moving {
        match exclusive_rename(source, destination) {
            Err(err)
                if err.raw_os_error() == Some(libc::EXDEV)
                    || err.kind() == io::ErrorKind::Unsupported => {}
            result => return result,
        }
    }
    copy_publish(source, destination, moving)
}

fn numbered_name(path: &Path, number: u64, is_dir: bool) -> PathBuf {
    if !is_dir {
        if let (Some(stem), Some(ext)) = (path.file_stem(), path.extension()) {
            return path.with_file_name(format!(
                "{} {number}.{}",
                stem.to_string_lossy(),
                ext.to_string_lossy()
            ));
        }
    }
    path.with_file_name(format!(
        "{} {number}",
        path.file_name().unwrap_or_default().to_string_lossy()
    ))
}

// Resolve parent aliases without following the selected item's final symlink.
fn resolved_item(path: &Path) -> io::Result<PathBuf> {
    absolute(path)?;
    let name = path
        .file_name()
        .ok_or_else(|| input_error("A volume root cannot be transferred."))?;
    let parent = path
        .parent()
        .ok_or_else(|| input_error("Choose a source item."))?;
    Ok(fs::canonicalize(parent)?.join(name))
}

fn one(
    source: &Path,
    folder: &Path,
    resolved_folder: &Path,
    collision: Collision,
    outcome: &mut Outcome,
    mut history: Option<&mut receipts::History>,
    expected: Option<&str>,
) -> io::Result<()> {
    let moving = history.is_some();
    verify_selection(&outcome.source, expected)?;
    let meta = fs::symlink_metadata(source)?;
    if moving
        && meta.is_dir()
        && source.parent().is_some_and(|parent| {
            fs::metadata(parent).is_ok_and(|parent| parent.dev() != meta.dev())
        })
    {
        return Err(input_error(
            "A mounted volume cannot be moved. Select items inside it.",
        ));
    }
    let original = folder.join(source.file_name().expect("resolved item has a name"));
    if meta.is_dir() && resolved_folder.starts_with(fs::canonicalize(source)?) {
        return Err(input_error("A folder cannot be placed inside itself."));
    }
    if moving && source.parent() == Some(resolved_folder) {
        outcome.status = "skipped";
        outcome.error = Some("Already in this folder.".into());
        return Ok(());
    }
    let mut prior = None;
    let mut next = 2;
    loop {
        let target = &outcome.destination;
        // Catch ordinary collisions before copying, and races at publication.
        let attempt = match fs::symlink_metadata(target) {
            Ok(_) => Err(io::Error::from(io::ErrorKind::AlreadyExists)),
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                if prior.is_none() {
                    if let Some(ledger) = history.as_deref() {
                        prior = Some(ledger.prepare(&outcome.source));
                    }
                }
                verify_selection(&outcome.source, expected)?;
                if source != outcome.source {
                    verify_selection(source, expected)?;
                }
                transfer(source, target, moving)
            }
            Err(e) => Err(e),
        };
        match attempt {
            Ok(()) => {
                outcome.status = "done";
                if let (Some(ledger), Some(old)) = (history.as_deref_mut(), prior.take()) {
                    outcome.receipt = Some(ledger.record(old, target));
                }
                return Ok(());
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => match collision {
                Collision::Error | Collision::Skip => {
                    outcome.status = if matches!(collision, Collision::Skip) {
                        "skipped"
                    } else {
                        "collision"
                    };
                    outcome.error =
                        Some("An item with this name already exists in the destination.".into());
                    return Ok(());
                }
                Collision::KeepBoth => {
                    outcome.destination = numbered_name(&original, next, meta.is_dir());
                    next += 1;
                }
            },
            Err(e) => return Err(e),
        }
    }
}

pub(crate) fn batch(
    sources: &[PathBuf],
    folder: &Path,
    collision: Collision,
    moving: bool,
    expected: &HashMap<PathBuf, String>,
) -> io::Result<Batch> {
    let mut history = moving.then(receipts::lock);
    let resolved_folder = fs::canonicalize(folder)?;
    if !resolved_folder.is_dir() {
        return Err(input_error("The destination must be a folder."));
    }
    let resolved: Vec<_> = sources.iter().map(|p| resolved_item(p)).collect();
    let selected_dirs: HashSet<_> = resolved
        .iter()
        .filter_map(|v| v.as_ref().ok())
        .filter(|p| fs::symlink_metadata(p).is_ok_and(|m| m.is_dir()))
        .filter_map(|p| fs::canonicalize(p).ok())
        .collect();
    let mut seen = HashSet::new();
    let mut results = Vec::with_capacity(sources.len());
    for (source, path) in sources.iter().zip(resolved) {
        let mut outcome = Outcome {
            source: source.clone(),
            destination: folder.join(source.file_name().unwrap_or_default()),
            status: "error",
            error: None,
            receipt: None,
        };
        let result = path.and_then(|path| {
            if !seen.insert(path.clone())
                || path.ancestors().skip(1).any(|p| selected_dirs.contains(p))
            {
                outcome.status = "skipped";
                outcome.error = Some("Included in another selected item.".into());
                return Ok(());
            }
            one(
                &path,
                folder,
                &resolved_folder,
                collision,
                &mut outcome,
                history.as_deref_mut(),
                expected.get(source).map(String::as_str),
            )
        });
        if let Err(err) = result {
            outcome.error = Some(err.to_string());
        }
        results.push(outcome);
    }
    Ok(Batch { results })
}
