//! A disposable filename index owned by an explicit Find sheet. Published
//! chunks are immutable so queries never hold a lock while reading the disk,
//! and a directory scan never holds a lock while a query ranks results.
use crate::{absolute, fold_search_text};
use serde::Serialize;
use std::{
    cmp::Ordering,
    collections::{BinaryHeap, HashMap, HashSet, VecDeque},
    ffi::{CStr, CString},
    fs, io,
    os::{
        fd::{AsRawFd, FromRawFd, IntoRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    sync::{
        Arc, LazyLock, Mutex,
        atomic::{AtomicBool, Ordering as AtomicOrder},
    },
    time::{Duration, Instant},
};

const MAX_ITEMS: usize = 200_000;
const MAX_BYTES: usize = 48 * 1024 * 1024;
const MAX_SESSIONS: usize = 4;
const CHUNK_SIZE: usize = 256;
const DEFAULT_RESULTS: usize = 160;
const MAX_RESULTS: usize = 400;

#[derive(Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Progress {
    scanned: usize,
    folders: usize,
    errors: usize,
    permission_errors: usize,
    omitted: usize,
    limited: bool,
    complete: bool,
    elapsed_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    root_error: Option<String>,
}

impl Progress {
    fn error(&mut self, err: &io::Error) {
        self.errors += 1;
        if err.kind() == io::ErrorKind::PermissionDenied {
            self.permission_errors += 1;
        }
    }
}

struct Indexed {
    relative: Box<str>,
    folded: Box<str>,
    name_offset: usize,
    folded_name_offset: usize,
    depth: usize,
    kind: &'static str,
}

impl Indexed {
    fn name(&self) -> &str {
        &self.relative[self.name_offset..]
    }
    fn folded_name(&self) -> &str {
        &self.folded[self.folded_name_offset..]
    }
}

#[derive(Default)]
struct Published {
    chunks: Vec<Arc<[Indexed]>>,
    progress: Progress,
}

struct Session {
    root: PathBuf,
    hidden: bool,
    cancel: AtomicBool,
    published: Mutex<Published>,
    start: Instant,
}

impl Session {
    fn canceled(&self) -> bool {
        self.cancel.load(AtomicOrder::Acquire)
    }
    fn publish(&self, pending: &mut Vec<Indexed>, progress: &mut Progress) {
        progress.elapsed_ms = self.start.elapsed().as_millis() as u64;
        let mut shared = self.published.lock().unwrap_or_else(|e| e.into_inner());
        if self.canceled() {
            pending.clear();
            return;
        }
        if !pending.is_empty() {
            shared.chunks.push(Arc::from(std::mem::take(pending)));
        }
        shared.progress = progress.clone();
    }
}

#[derive(Default)]
struct Registry {
    sessions: HashMap<String, Arc<Session>>,
    workers: usize,
    next: u64,
}
static REGISTRY: LazyLock<Mutex<Registry>> = LazyLock::new(Default::default);

#[derive(Serialize)]
pub(crate) struct Started {
    session: String,
}

pub(crate) fn start(path: &Path, hidden: bool) -> io::Result<Started> {
    absolute(path)?;
    let session = Arc::new(Session {
        root: path.to_owned(),
        hidden,
        cancel: AtomicBool::new(false),
        published: Mutex::default(),
        start: Instant::now(),
    });
    let mut registry = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
    if registry.sessions.len() >= MAX_SESSIONS || registry.workers >= MAX_SESSIONS {
        return Err(io::Error::other(
            "Other folder searches are still running. Close an earlier Find sheet and try again.",
        ));
    }
    registry.next += 1;
    let token = format!("find-{:016x}", registry.next);
    registry.sessions.insert(token.clone(), session.clone());
    registry.workers += 1;
    let spawned = std::thread::Builder::new()
        .name("Finger folder Find".into())
        .spawn(move || {
            crate::search_macos::set_indexing_priority();
            let result = std::panic::catch_unwind(|| scan(&session, MAX_ITEMS, MAX_BYTES));
            if result.is_err() {
                let mut shared = session.published.lock().unwrap_or_else(|e| e.into_inner());
                shared.progress.complete = true;
                shared.progress.errors += 1;
                shared.progress.root_error = Some("The folder search stopped unexpectedly.".into());
            }
            let mut registry = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
            registry.workers -= 1;
        });
    if let Err(err) = spawned {
        registry.sessions.remove(&token);
        registry.workers -= 1;
        return Err(err);
    }
    Ok(Started { session: token })
}

pub(crate) fn end(token: &str) {
    let session = REGISTRY
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .sessions
        .remove(token);
    if let Some(session) = session {
        session.cancel.store(true, AtomicOrder::Release);
        // Release published pages even when a remote filesystem delays a worker.
        let mut shared = session.published.lock().unwrap_or_else(|e| e.into_inner());
        shared.chunks.clear();
    }
}

fn open_child(parent: &fs::File, name: &[u8]) -> io::Result<fs::File> {
    let name = CString::new(name)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(unsafe { fs::File::from_raw_fd(fd) })
    }
}

// Open every component relative to a held directory descriptor. If a queued
// directory is replaced by a symlink, it cannot redirect the walk elsewhere.
fn open_relative(root: &fs::File, relative: &str) -> io::Result<fs::File> {
    let mut dir = root.try_clone()?;
    for piece in relative.split('/').filter(|p| !p.is_empty()) {
        dir = open_child(&dir, piece.as_bytes())?;
    }
    Ok(dir)
}

struct Directory(*mut libc::DIR);
impl Drop for Directory {
    fn drop(&mut self) {
        unsafe {
            libc::closedir(self.0);
        }
    }
}
impl Directory {
    fn new(file: fs::File) -> io::Result<Self> {
        let raw = file.into_raw_fd();
        let ptr = unsafe { libc::fdopendir(raw) };
        if ptr.is_null() {
            let err = io::Error::last_os_error();
            unsafe {
                libc::close(raw);
            }
            Err(err)
        } else {
            Ok(Self(ptr))
        }
    }

    fn next(&mut self) -> io::Result<Option<&CStr>> {
        unsafe {
            *libc::__error() = 0;
            let item = libc::readdir(self.0);
            if item.is_null() {
                let errno = *libc::__error();
                if errno == 0 {
                    Ok(None)
                } else {
                    Err(io::Error::from_raw_os_error(errno))
                }
            } else {
                Ok(Some(CStr::from_ptr((*item).d_name.as_ptr())))
            }
        }
    }
}

struct Job {
    relative: String,
    identity: (u64, u64),
    depth: usize,
}

fn joined(prefix: &str, name: &str) -> String {
    if prefix.is_empty() {
        name.to_owned()
    } else {
        format!("{prefix}/{name}")
    }
}

fn scan(session: &Session, entry_limit: usize, byte_limit: usize) {
    if session.canceled() {
        return;
    }
    let mut progress = Progress::default();
    let mut pending = Vec::new();
    let mut bytes: usize = 0;
    let mut flushed = Instant::now();
    let run = (|| -> io::Result<()> {
        let physical = fs::canonicalize(&session.root)?;
        let root = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(&physical)?;
        if crate::search_macos::is_package(&physical)? {
            return Err(io::Error::other(
                "Search the containing folder to find this macOS package.",
            ));
        }
        let m = root.metadata()?;
        let mut queue = VecDeque::from([Job {
            relative: String::new(),
            identity: (m.dev(), m.ino()),
            depth: 0,
        }]);
        let mut visited = HashSet::new();
        while let Some(job) = queue.pop_front() {
            if session.canceled() {
                break;
            }
            let opened = open_relative(&root, &job.relative).and_then(|file| {
                let m = file.metadata()?;
                if (m.dev(), m.ino()) != job.identity {
                    return Err(io::Error::other("A folder changed while searching."));
                }
                Directory::new(file)
            });
            let mut dir = match opened {
                Ok(dir) => dir,
                Err(err) if job.relative.is_empty() => return Err(err),
                Err(err) => {
                    progress.error(&err);
                    continue;
                }
            };
            if !visited.insert(job.identity) {
                continue;
            }
            progress.folders += 1;
            let parent_folded = fold_search_text(&job.relative);
            let dirfd = unsafe { libc::dirfd(dir.0) };
            loop {
                if session.canceled() {
                    return Ok(());
                }
                let raw = match dir.next() {
                    Ok(Some(raw)) => raw,
                    Ok(None) => break,
                    Err(err) if job.relative.is_empty() => return Err(err),
                    Err(err) => {
                        progress.error(&err);
                        break;
                    }
                };
                let raw_bytes = raw.to_bytes();
                if raw_bytes == b"."
                    || raw_bytes == b".."
                    || (!session.hidden && raw_bytes.starts_with(b"."))
                {
                    continue;
                }
                let Ok(name) = raw.to_str() else {
                    progress.omitted += 1;
                    continue;
                };
                let mut stat: std::mem::MaybeUninit<libc::stat> = std::mem::MaybeUninit::uninit();
                if unsafe {
                    libc::fstatat(
                        dirfd,
                        raw.as_ptr(),
                        stat.as_mut_ptr(),
                        libc::AT_SYMLINK_NOFOLLOW,
                    )
                } != 0
                {
                    progress.error(&io::Error::last_os_error());
                    progress.omitted += 1;
                    continue;
                }
                let stat = unsafe { stat.assume_init() };
                if !session.hidden && stat.st_flags & libc::UF_HIDDEN != 0 {
                    continue;
                }
                let relative = joined(&job.relative, name);
                let folded = joined(&parent_folded, &fold_search_text(name));
                let directory = stat.st_mode & libc::S_IFMT == libc::S_IFDIR;
                // Budget for the record, allocations and (for folders) the
                // traversal queue and visited identity alongside the index.
                let cost = size_of::<Indexed>()
                    + relative.len()
                    + folded.len()
                    + 48
                    + if directory {
                        relative.len() + size_of::<Job>() + 48
                    } else {
                        0
                    };
                if progress.scanned >= entry_limit || bytes.saturating_add(cost) > byte_limit {
                    progress.limited = true;
                    return Ok(());
                }
                bytes += cost;
                let kind = if directory {
                    match crate::search_macos::is_package(&physical.join(&relative)) {
                        Ok(false) => {
                            queue.push_back(Job {
                                relative: relative.clone(),
                                identity: (stat.st_dev as u64, stat.st_ino),
                                depth: job.depth + 1,
                            });
                            "folder"
                        }
                        Ok(true) => "package",
                        Err(err) => {
                            progress.error(&err);
                            "folder"
                        }
                    }
                } else {
                    match stat.st_mode & libc::S_IFMT {
                        libc::S_IFREG => "file",
                        libc::S_IFLNK => "symlink",
                        _ => "other",
                    }
                };
                let name_offset = if job.relative.is_empty() {
                    0
                } else {
                    job.relative.len() + 1
                };
                let folded_name_offset = if parent_folded.is_empty() {
                    0
                } else {
                    parent_folded.len() + 1
                };
                pending.push(Indexed {
                    relative: relative.into(),
                    folded: folded.into(),
                    name_offset,
                    folded_name_offset,
                    depth: job.depth,
                    kind,
                });
                progress.scanned += 1;
                if pending.len() >= CHUNK_SIZE || flushed.elapsed() >= Duration::from_millis(30) {
                    session.publish(&mut pending, &mut progress);
                    flushed = Instant::now();
                }
            }
        }
        Ok(())
    })();
    if let Err(err) = run {
        progress.error(&err);
        progress.root_error = Some(format!(
            "Could not search {}: {err}",
            session.root.display()
        ));
    }
    progress.complete = true;
    if !session.canceled() {
        session.publish(&mut pending, &mut progress);
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Entry<'a> {
    name: &'a str,
    path: PathBuf,
    relative_path: &'a str,
    kind: &'static str,
    is_directory: bool,
}

struct Hit<'a> {
    score: (u8, usize, usize),
    item: &'a Indexed,
}
impl PartialEq for Hit<'_> {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}
impl Eq for Hit<'_> {}
impl PartialOrd for Hit<'_> {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
impl Ord for Hit<'_> {
    fn cmp(&self, other: &Self) -> Ordering {
        self.score
            .cmp(&other.score)
            .then_with(|| {
                crate::listing::natural_cmp(self.item.folded_name(), other.item.folded_name())
            })
            .then_with(|| crate::listing::natural_cmp(&self.item.folded, &other.item.folded))
            .then_with(|| self.item.relative.cmp(&other.item.relative))
    }
}

fn score(item: &Indexed, needle: &str, words: &[&str]) -> Option<(u8, usize, usize)> {
    if !words.iter().all(|w| item.folded.contains(w)) {
        return None;
    }
    let name = item.folded_name();
    let name_hits = words.iter().filter(|w| name.contains(*w)).count();
    let tier = if name == needle || item.folded.as_ref() == needle {
        0
    } else if name
        .rsplit_once('.')
        .is_some_and(|(stem, _)| stem == needle)
    {
        1
    } else if name.starts_with(needle) {
        2
    } else if name.contains(needle) {
        3
    } else if name_hits == words.len() {
        4
    } else if name_hits != 0 {
        5
    } else {
        6
    };
    Some((tier, words.len() - name_hits, item.depth))
}

#[derive(Serialize)]
struct Results<'a> {
    #[serde(flatten)]
    progress: Progress,
    entries: Vec<Entry<'a>>,
    total: usize,
}

// Serialize borrowed rows while the immutable chunks are alive.
pub(crate) fn query(id: u64, token: &str, query: &str, limit: Option<usize>) -> io::Result<String> {
    let session = REGISTRY
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .sessions
        .get(token)
        .cloned()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "This folder search has ended."))?;
    let (progress, chunks) = {
        let shared = session.published.lock().unwrap_or_else(|e| e.into_inner());
        (shared.progress.clone(), shared.chunks.clone())
    };
    if query.len() > 4096 {
        return Err(io::Error::other(
            "Use a shorter filename or path to search.",
        ));
    }
    let needle = fold_search_text(query.trim());
    let mut words: Vec<_> = needle.split_whitespace().collect();
    // A long pasted query may repeat a word thousands of times. Each
    // distinct word needs only one comparison per indexed filename.
    if words.len() > 1 {
        let mut seen = HashSet::new();
        words.retain(|word| seen.insert(*word));
    }
    let cap = limit.unwrap_or(DEFAULT_RESULTS).min(MAX_RESULTS);
    let mut best = BinaryHeap::with_capacity(cap);
    let mut total = 0;
    if !words.is_empty() {
        for chunk in &chunks {
            if session.canceled() {
                return Err(io::Error::other("This folder search has ended."));
            }
            for item in chunk.iter() {
                let Some(score) = score(item, &needle, &words) else {
                    continue;
                };
                total += 1;
                let hit = Hit { score, item };
                if best.len() < cap {
                    best.push(hit);
                } else if best.peek().is_some_and(|worst| hit < *worst) {
                    best.pop();
                    best.push(hit);
                }
            }
        }
    }
    let entries = best
        .into_sorted_vec()
        .into_iter()
        .map(|h| Entry {
            name: h.item.name(),
            relative_path: &h.item.relative,
            path: session.root.join(&*h.item.relative),
            kind: h.item.kind,
            is_directory: matches!(h.item.kind, "folder" | "package"),
        })
        .collect();
    if session.canceled() {
        return Err(io::Error::other("This folder search has ended."));
    }
    crate::encode(
        id,
        Results {
            progress,
            entries,
            total,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entry_and_byte_caps_report_incomplete_coverage_with_bounded_pages() {
        let root = std::env::temp_dir().join(format!("finger-index-limits-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        for i in 0..50 {
            fs::File::create(root.join(format!("entry-{i}"))).unwrap();
        }
        for (entries, bytes) in [(7, usize::MAX), (100, 700)] {
            let s = Session {
                root: root.clone(),
                hidden: false,
                cancel: AtomicBool::new(false),
                published: Mutex::default(),
                start: Instant::now(),
            };
            scan(&s, entries, bytes);
            let p = s.published.lock().unwrap();
            assert!(p.progress.complete && p.progress.limited);
            assert!(p.progress.scanned > 0 && p.progress.scanned < 50);
            assert_eq!(
                p.progress.scanned,
                p.chunks.iter().map(|v| v.len()).sum::<usize>()
            );
            if entries == 7 {
                assert_eq!(p.progress.scanned, 7);
            }
        }
        fs::remove_dir_all(root).unwrap();
    }
}
