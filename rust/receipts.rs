//! Process-local Undo/Redo tokens. File paths and identity proofs never leave
//! the process as part of a token. All move/rename/restore mutations serialize
//! around the same ledger; directory reads and copies remain independent.
use super::*;
use std::{
    collections::{
        BTreeMap, BTreeSet,
        hash_map::{DefaultHasher, RandomState},
    },
    hash::{BuildHasher, Hash, Hasher},
    io::Read,
    sync::{LazyLock, Mutex, MutexGuard},
};

const CAPACITY: usize = 32_768;

static HISTORY: LazyLock<Mutex<History>> = LazyLock::new(|| Mutex::new(History::new(CAPACITY)));

struct Digest(DefaultHasher, DefaultHasher);

impl Digest {
    fn new() -> Self {
        static KEYS: LazyLock<(RandomState, RandomState)> =
            LazyLock::new(|| (RandomState::new(), RandomState::new()));
        Self(KEYS.0.build_hasher(), KEYS.1.build_hasher())
    }
    fn add(&mut self, data: impl Hash) {
        data.hash(&mut self.0);
        data.hash(&mut self.1);
    }
    fn finish(&self) -> [u64; 2] {
        [self.0.finish(), self.1.finish()]
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
struct Identity(u64, u64, i64, i64);

impl Identity {
    fn of(meta: &fs::Metadata) -> Self {
        Self(
            meta.dev(),
            meta.ino(),
            meta.st_birthtime(),
            meta.st_birthtime_nsec(),
        )
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct RootState {
    identity: Identity,
    length: u64,
    links: u64,
    directory: bool,
    changed: (i64, i64),
    modified: (i64, i64),
}

impl RootState {
    fn of(meta: &fs::Metadata) -> Self {
        Self {
            identity: Identity::of(meta),
            length: meta.len(),
            links: meta.nlink(),
            directory: meta.is_dir(),
            changed: (meta.ctime(), meta.ctime_nsec()),
            modified: (meta.mtime(), meta.mtime_nsec()),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Proof {
    root: RootState,
    digest: [u64; 2],
}

// APFS exposes nanosecond change times and inode identities. Less capable
// removable volumes can reuse timestamps within one write interval. Include
// file bytes there so a same-size edit cannot silently pass the Undo guard.
fn hash_file(
    path: &Path,
    meta: &fs::Metadata,
    digest: &mut Digest,
    buffer: &mut [u8],
) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    let mut remaining = meta.len();
    while remaining > 0 {
        let count = remaining.min(buffer.len() as u64) as usize;
        file.read_exact(&mut buffer[..count])?;
        digest.add(&buffer[..count]);
        remaining -= count as u64;
    }
    if RootState::of(&file.metadata()?) != RootState::of(meta) {
        return Err(io::Error::other(
            "An item changed while it was being checked.",
        ));
    }
    Ok(())
}

fn fingerprint(root: &Path) -> io::Result<Proof> {
    let root_meta = fs::symlink_metadata(root)?;
    let volume_path = if root_meta.file_type().is_symlink() {
        root.parent().unwrap_or(root)
    } else {
        root
    };
    let read_contents =
        exclusive_copy::volume_supports(volume_path, libc::VOL_CAP_INT_RENAME_EXCL) == Some(false);
    let mut digest = Digest::new();
    let mut pending = vec![root.to_owned()];
    let mut buffer = vec![0u8; if read_contents { 64 * 1024 } else { 0 }];
    while let Some(path) = pending.pop() {
        let meta = fs::symlink_metadata(&path)?;
        if meta.dev() != root_meta.dev() {
            return Err(input_error(
                "This folder contains a separate mounted volume.",
            ));
        }
        let relative = path
            .strip_prefix(root)
            .expect("proof is rooted at the selected item");
        digest.add(relative.as_os_str().as_bytes());
        digest.add((
            meta.dev(),
            meta.ino(),
            meta.mode(),
            meta.uid(),
            meta.gid(),
            meta.nlink(),
            meta.len(),
        ));
        digest.add((
            meta.mtime(),
            meta.mtime_nsec(),
            meta.ctime(),
            meta.ctime_nsec(),
            meta.st_flags(),
        ));
        digest.add((meta.st_birthtime(), meta.st_birthtime_nsec()));
        if meta.is_dir() {
            let mut children = fs::read_dir(&path)?
                .map(|entry| entry.map(|e| e.path()))
                .collect::<io::Result<Vec<_>>>()?;
            // Directory enumeration order is not stable across repeated reads.
            children.sort_unstable();
            pending.extend(children);
        } else if meta.file_type().is_symlink() {
            digest.add(fs::read_link(&path)?.as_os_str().as_bytes());
        } else if read_contents && meta.is_file() {
            hash_file(&path, &meta, &mut digest, &mut buffer)?;
        }
    }
    // Named forks and Finder tags of a top-level item can live alongside
    // it in a volume-managed AppleDouble companion, outside the walked tree.
    if read_contents {
        if let Some(name) = root.file_name() {
            let mut companion_name = std::ffi::OsString::from("._");
            companion_name.push(name);
            let companion = root.with_file_name(companion_name);
            if apple_double_companion(&companion) {
                digest.add("AppleDouble");
                hash_file(
                    &companion,
                    &fs::symlink_metadata(&companion)?,
                    &mut digest,
                    &mut buffer,
                )?;
            }
        }
    }
    let root_state = RootState::of(&root_meta);
    if RootState::of(&fs::symlink_metadata(root)?) != root_state {
        return Err(io::Error::other(
            "The item changed while it was being checked.",
        ));
    }
    Ok(Proof {
        root: root_state,
        digest: digest.finish(),
    })
}

#[derive(Clone)]
pub(super) struct Endpoint {
    path: PathBuf,
    parent: Option<Identity>,
    proof: Result<Proof, String>,
}

impl Endpoint {
    pub(super) fn capture(path: &Path) -> Self {
        let parent = path
            .parent()
            .and_then(|p| fs::metadata(p).ok())
            .map(|m| Identity::of(&m));
        Self {
            path: path.to_owned(),
            parent,
            proof: fingerprint(path).map_err(|e| e.to_string()),
        }
    }

    fn verify_parent(&self) -> io::Result<()> {
        let observed = self
            .path
            .parent()
            .and_then(|p| fs::metadata(p).ok())
            .filter(|m| m.is_dir())
            .map(|m| Identity::of(&m));
        if self.parent.is_none() || self.parent != observed {
            return Err(io::Error::other(format!(
                "The folder containing {} has moved, was replaced, or is unavailable.",
                self.path.display()
            )));
        }
        Ok(())
    }

    fn slot(&self) -> Option<(Identity, std::ffi::OsString)> {
        Some((self.parent?, self.path.file_name()?.to_os_string()))
    }
}

#[derive(Clone)]
struct Receipt {
    from: Endpoint,
    to: Endpoint,
}

pub(super) struct History {
    prefix: u64,
    next: u64,
    capacity: usize,
    // Monotonic IDs make pop_first the oldest receipt. Renewed IDs never alias
    // a consumed Undo token, and expired IDs carry no filesystem details.
    items: BTreeMap<u64, Receipt>,
    slots: HashMap<(Identity, std::ffi::OsString), BTreeSet<u64>>,
}

pub(super) fn lock() -> MutexGuard<'static, History> {
    HISTORY
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl History {
    fn new(capacity: usize) -> Self {
        let mut random = RandomState::new().build_hasher();
        random.write_u32(std::process::id());
        Self {
            prefix: random.finish(),
            next: 0,
            capacity,
            items: BTreeMap::new(),
            slots: HashMap::new(),
        }
    }

    fn insert(&mut self, item: Receipt) -> String {
        self.next += 1;
        let id = self.next;
        if let Some(slot) = item.from.slot() {
            self.slots.entry(slot).or_default().insert(id);
        }
        self.items.insert(id, item);
        if self.items.len() > self.capacity {
            if let Some(oldest) = self.items.keys().next().copied() {
                self.remove(oldest);
            }
        }
        format!("{:016x}-{:016x}", self.prefix, id)
    }

    fn remove(&mut self, id: u64) {
        if let Some(slot) = self.items.remove(&id).and_then(|item| item.from.slot()) {
            if let Some(ids) = self.slots.get_mut(&slot) {
                ids.remove(&id);
                if ids.is_empty() {
                    self.slots.remove(&slot);
                }
            }
        }
    }

    pub(super) fn prepare(&self, path: &Path) -> Endpoint {
        let parent = path
            .parent()
            .and_then(|p| fs::metadata(p).ok())
            .map(|m| Identity::of(&m));
        let mut endpoint = Endpoint {
            path: path.to_owned(),
            parent,
            // Pre-move proofs exist solely to reconnect earlier history after
            // Undo. The new location is always fully verified when recorded.
            proof: Err("This name has no earlier move to reconnect.".into()),
        };
        let same_slot = endpoint
            .slot()
            .is_some_and(|slot| self.slots.contains_key(&slot));
        let has_alias = fs::symlink_metadata(path).is_ok_and(|m| {
            !m.is_dir()
                && m.nlink() > 1
                && self.items.values().any(|r| {
                    r.from
                        .proof
                        .as_ref()
                        .is_ok_and(|p| p.root.identity == Identity::of(&m))
                })
        });
        if same_slot || has_alias {
            endpoint.proof = fingerprint(path).map_err(|e| e.to_string());
        }
        endpoint
    }

    fn key(&self, token: &str) -> Option<u64> {
        let (prefix, counter) = token.split_once('-')?;
        if prefix.len() != 16
            || counter.len() != 16
            || u64::from_str_radix(prefix, 16).ok()? != self.prefix
        {
            return None;
        }
        u64::from_str_radix(counter, 16).ok()
    }

    fn rebase_link_aliases(&mut self, before: &Endpoint, after: &Endpoint) {
        let (Ok(old), Ok(new)) = (&before.proof, &after.proof) else {
            return;
        };
        if new.root.directory || new.root.links < 2 || old.root.identity != new.root.identity {
            return;
        }
        // A rename updates the ctime of every hardlink to the same inode.
        // Rebase only live aliases whose complete pre-move proof matched.
        for prior in self.items.values_mut() {
            if prior.from.proof.as_ref() == Ok(old)
                && prior.from.slot() != before.slot()
                && fs::symlink_metadata(&prior.from.path)
                    .is_ok_and(|m| Identity::of(&m) == new.root.identity && !m.is_dir())
            {
                prior.from.proof = Ok(new.clone());
            }
        }
    }

    pub(super) fn record(&mut self, original: Endpoint, new: &Path) -> String {
        let target = Endpoint::capture(new);
        self.rebase_link_aliases(&original, &target);
        self.insert(Receipt {
            from: target,
            to: original,
        })
    }

    fn apply(&mut self, token: &str) -> Outcome {
        let mut result = Outcome {
            source: PathBuf::new(),
            destination: PathBuf::new(),
            status: "error",
            error: None,
            receipt: None,
        };
        let Some((key, ticket)) = self
            .key(token)
            .and_then(|key| self.items.get(&key).cloned().map(|ticket| (key, ticket)))
        else {
            result.error = Some("This Undo or Redo has expired in this session.".into());
            return result;
        };
        result.source = ticket.from.path.clone();
        result.destination = ticket.to.path.clone();
        match restore_one(&ticket) {
            Ok(restored) => {
                self.remove(key);
                self.rebase_link_aliases(&ticket.from, &restored);
                // Restoring a previous move/rename changes ctime, and a volume
                // crossing creates a new inode. Rebase only receipts that match
                // the complete, previously captured state at that exact slot.
                if ticket.to.proof.is_ok() {
                    if let Some(ids) = ticket.to.slot().and_then(|slot| self.slots.get(&slot)) {
                        for id in ids {
                            if let Some(prior) = self.items.get_mut(id) {
                                if prior.from.proof == ticket.to.proof {
                                    prior.from.proof = restored.proof.clone();
                                }
                            }
                        }
                    }
                }
                let reverse = Receipt {
                    from: restored,
                    to: ticket.from,
                };
                result.receipt = Some(self.insert(reverse));
                result.status = "done";
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                result.status = "collision";
                result.error = Some(
                    "The return name is occupied. Move or rename that item, then retry.".into(),
                );
            }
            Err(e) => result.error = Some(e.to_string()),
        }
        result
    }
}

fn restore_one(ticket: &Receipt) -> io::Result<Endpoint> {
    ticket.from.verify_parent()?;
    ticket.to.verify_parent()?;
    let expected = ticket.from.proof.as_ref().map_err(|reason| {
        io::Error::other(format!(
            "This item could not be verified when it moved: {reason}"
        ))
    })?;
    let current = fingerprint(&ticket.from.path).map_err(|e| {
        io::Error::other(format!(
            "The moved item is missing or cannot be verified: {e}"
        ))
    })?;
    if current != *expected {
        return Err(io::Error::other(
            "The moved item has changed or was replaced. Its current version was left in place.",
        ));
    }
    let source = &ticket.from.path;
    let target = &ticket.to.path;
    let source_meta = fs::symlink_metadata(source)?;
    let parent = target
        .parent()
        .ok_or_else(|| input_error("The return folder is unavailable."))?;
    if source_meta.is_dir() {
        if source
            .parent()
            .and_then(|p| fs::metadata(p).ok())
            .is_some_and(|p| p.dev() != source_meta.dev())
        {
            return Err(input_error("A mounted volume cannot be moved."));
        }
        if fs::canonicalize(parent)?.starts_with(fs::canonicalize(source)?) {
            return Err(input_error(
                "The return folder is inside the item being moved.",
            ));
        }
    }
    match fs::symlink_metadata(target) {
        Ok(occupied) => {
            // A case-only rename can make both spellings refer to the one
            // directory entry. A separate hardlink at the exact return name
            // is an occupied target just like an unrelated file.
            let case_spelling = ticket.from.parent == ticket.to.parent
                && Identity::of(&occupied) == Identity::of(&source_meta)
                && !fs::read_dir(parent)?
                    .filter_map(Result::ok)
                    .any(|e| Some(e.file_name().as_os_str()) == target.file_name());
            if !case_spelling {
                return Err(io::Error::from(io::ErrorKind::AlreadyExists));
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    if RootState::of(&fs::symlink_metadata(source)?) != expected.root {
        return Err(io::Error::other(
            "The item changed during verification. Its current version was left in place.",
        ));
    }
    if ticket.from.parent == ticket.to.parent {
        rename_exact(source, target)?;
    } else {
        transfer(source, target, true)?;
    }
    Ok(Endpoint::capture(target))
}

pub(super) fn apply(tokens: &[String]) -> Batch {
    let mut history = lock();
    Batch {
        results: tokens.iter().map(|token| history.apply(token)).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ledger_bounds_tokens_and_session_prefixes() {
        let root = std::env::temp_dir().join(format!("finger-token-limit-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        let path = root.join("sample");
        fs::write(&path, "file").unwrap();
        let mut ledger = History::new(2);
        let mut keys = Vec::new();
        for _ in 0..3 {
            keys.push(ledger.record(ledger.prepare(&path), &path));
        }
        assert_eq!(ledger.items.len(), 2);
        assert_eq!(ledger.slots.values().map(BTreeSet::len).sum::<usize>(), 2);
        let expired = ledger.apply(&keys[0]);
        assert_eq!(expired.status, "error");
        assert!(expired.error.unwrap().contains("expired"));
        let mut other_session = History::new(2);
        assert_eq!(other_session.apply(&keys[1]).status, "error");
        fs::remove_dir_all(root).unwrap();
    }
}
