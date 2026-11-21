use serde::{Deserialize, Serialize};
use std::{
    cmp::Ordering,
    fs, io,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Entry {
    name: String,
    path: PathBuf,
    kind: &'static str,
    is_directory: bool,
    size: Option<u64>,
    modified: Option<i64>,
    #[serde(skip)]
    sort_key: String,
    #[serde(skip)]
    digit_width: u16,
}

#[derive(Serialize)]
pub(crate) struct Listing {
    entries: Vec<Entry>,
    total: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    media: Option<Vec<Entry>>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    warnings: Vec<String>,
}

#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SortOrder {
    #[default]
    NameAsc,
    NameDesc,
    ModifiedDesc,
    ModifiedAsc,
    SizeDesc,
    SizeAsc,
}

impl SortOrder {
    /// Mode numbers in the native listing callback's flags byte.
    pub fn from_mode(mode: u8) -> Option<Self> {
        match mode {
            0 => Some(Self::NameAsc),
            1 => Some(Self::NameDesc),
            2 => Some(Self::ModifiedDesc),
            3 => Some(Self::ModifiedAsc),
            4 => Some(Self::SizeDesc),
            5 => Some(Self::SizeAsc),
            _ => None,
        }
    }

    fn compare(self, a: &Entry, b: &Entry) -> Ordering {
        fn metadata<T: Ord>(a: Option<T>, b: Option<T>, descending: bool) -> Ordering {
            match (a, b) {
                (Some(a), Some(b)) if descending => b.cmp(&a),
                (Some(a), Some(b)) => a.cmp(&b),
                (Some(_), None) => Ordering::Less,
                (None, Some(_)) => Ordering::Greater,
                (None, None) => Ordering::Equal,
            }
        }
        let by_name = || {
            // With equal-width numeric runs, lexicographic and numeric order
            // coincide. A name without digits can never start a paired run.
            let aw = a.digit_width;
            let bw = b.digit_width;
            let order = if aw == 0 || bw == 0 || (aw == bw && aw != u16::MAX) {
                a.sort_key.cmp(&b.sort_key)
            } else {
                natural_cmp(&a.sort_key, &b.sort_key)
            };
            order.then_with(|| a.name.cmp(&b.name))
        };
        b.is_directory.cmp(&a.is_directory).then_with(|| {
            let primary = match self {
                Self::NameAsc => return by_name(),
                Self::NameDesc => return by_name().reverse(),
                Self::ModifiedDesc => metadata(a.modified, b.modified, true),
                Self::ModifiedAsc => metadata(a.modified, b.modified, false),
                Self::SizeDesc | Self::SizeAsc if a.is_directory => Ordering::Equal,
                Self::SizeDesc => metadata(a.size, b.size, true),
                Self::SizeAsc => metadata(a.size, b.size, false),
            };
            primary.then_with(by_name)
        })
    }
}

// Zero means no ASCII digits. MAX means widths vary and need numeric comparison.
fn digit_width(name: &str) -> u16 {
    let mut width = 0;
    for run in name
        .as_bytes()
        .split(|b| !b.is_ascii_digit())
        .filter(|s| !s.is_empty())
    {
        let next = u16::try_from(run.len()).unwrap_or(u16::MAX);
        if width != 0 && width != next {
            return u16::MAX;
        }
        width = next;
    }
    width
}

pub(super) fn check_cancelled(cancelled: &dyn Fn() -> bool) -> io::Result<()> {
    if cancelled() {
        Err(io::Error::new(
            io::ErrorKind::Interrupted,
            "Folder opening was canceled.",
        ))
    } else {
        Ok(())
    }
}

// Numeric runs compare by magnitude without integer conversion or overflow.
// Original names break ties between case variants and equal numeric values.
pub(super) fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let ai = i;
            let bj = j;
            while i < a.len() && a[i].is_ascii_digit() {
                i += 1;
            }
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            let an = &a[ai..i];
            let bn = &b[bj..j];
            let an = &an[an.iter().position(|d| *d != b'0').unwrap_or(an.len())..];
            let bn = &bn[bn.iter().position(|d| *d != b'0').unwrap_or(bn.len())..];
            let order = an.len().cmp(&bn.len()).then_with(|| an.cmp(bn));
            if order != Ordering::Equal {
                return order;
            }
        } else {
            let order = a[i].cmp(&b[j]);
            if order != Ordering::Equal {
                return order;
            }
            i += 1;
            j += 1;
        }
    }
    (a.len() - i).cmp(&(b.len() - j))
}

fn portable_list(
    path: &Path,
    show_hidden: bool,
    limit: Option<usize>,
    query: Option<&str>,
    preview: bool,
    sort: SortOrder,
    cancelled: &dyn Fn() -> bool,
) -> io::Result<Listing> {
    check_cancelled(cancelled)?;
    let query = query.unwrap_or_default().to_lowercase();
    let mut warnings = Vec::new();
    let mut entries = Vec::new();
    for item in fs::read_dir(path)? {
        check_cancelled(cancelled)?;
        let item = match item {
            Ok(item) => item,
            Err(err) => {
                warnings.push(err.to_string());
                continue;
            }
        };
        let name = match item.file_name().into_string() {
            Ok(name) => name,
            Err(_) => {
                warnings.push("An item with an unrepresentable filename was omitted.".into());
                continue;
            }
        };
        if !show_hidden && name.starts_with('.') {
            continue;
        }
        let sort_key = name.to_lowercase();
        if !sort_key.contains(&query) {
            continue;
        }
        let metadata = item.metadata().ok();
        if !show_hidden
            && metadata.as_ref().is_some_and(|m| {
                std::os::macos::fs::MetadataExt::st_flags(m) & libc::UF_HIDDEN != 0
            })
        {
            continue;
        }
        let file_type = metadata
            .as_ref()
            .map(|m| m.file_type())
            .or_else(|| item.file_type().ok());
        let kind = match file_type {
            Some(t) if t.is_dir() => "folder",
            Some(t) if t.is_file() => "file",
            Some(t) if t.is_symlink() => "symlink",
            _ => "other",
        };
        let path = item.path();
        let is_directory = kind == "folder" || (kind == "symlink" && path.is_dir());
        let size = metadata.as_ref().filter(|m| !m.is_dir()).map(|m| m.len());
        let modified = metadata.as_ref().map(|m| m.mtime());
        entries.push(Entry {
            name,
            path,
            kind,
            is_directory,
            size,
            modified,
            digit_width: digit_width(&sort_key),
            sort_key,
        });
    }
    check_cancelled(cancelled)?;
    finish(entries, limit, warnings, preview, sort, cancelled)
}

fn is_media(item: &Entry) -> bool {
    if item.size == Some(0) {
        return false;
    }
    let is_visual = item.sort_key.rsplit_once('.').is_some_and(|(_, ext)| {
        matches!(
            ext,
            "png"
                | "jpg"
                | "jpeg"
                | "gif"
                | "heic"
                | "heif"
                | "avif"
                | "tif"
                | "tiff"
                | "bmp"
                | "webp"
                | "svg"
                | "pdf"
                | "psd"
                | "mov"
                | "mp4"
                | "m4v"
        )
    });
    is_visual
        && (item.kind == "file"
            || (item.kind == "symlink" && !item.is_directory && item.path.is_file()))
}

fn finish(
    mut entries: Vec<Entry>,
    limit: Option<usize>,
    warnings: Vec<String>,
    preview: bool,
    sort: SortOrder,
    cancelled: &dyn Fn() -> bool,
) -> io::Result<Listing> {
    let compare = |a: &Entry, b: &Entry| sort.compare(a, b);
    let media = if preview {
        let mut candidates = Vec::new();
        for group in entries.chunks(256) {
            check_cancelled(cancelled)?;
            candidates.extend(group.iter().filter(|item| is_media(item)));
        }
        if candidates.len() > 3 {
            candidates.select_nth_unstable_by(3, |a, b| compare(a, b));
            candidates.truncate(3);
        }
        candidates.sort_unstable_by(|a, b| compare(a, b));
        Some(candidates.into_iter().cloned().collect())
    } else {
        None
    };
    check_cancelled(cancelled)?;
    let total = entries.len();
    if let Some(count) = limit.filter(|count| *count < total) {
        entries.select_nth_unstable_by(count, compare);
        entries.truncate(count);
    }
    entries.sort_unstable_by(compare);
    Ok(Listing {
        entries,
        media,
        total,
        warnings,
    })
}

/// Bounded inspector sample. The encoded body and errors match `op: preview`.
pub fn preview_json_cancellable(
    id: u64,
    path: &Path,
    show_hidden: bool,
    sort: SortOrder,
    cancelled: &dyn Fn() -> bool,
) -> io::Result<String> {
    let sample = list_cancellable(
        crate::absolute(path)?,
        show_hidden,
        Some(32),
        None,
        true,
        sort,
        cancelled,
    )?;
    check_cancelled(cancelled)?;
    crate::encode(id, sample)
}

pub(crate) fn list(
    path: &Path,
    show_hidden: bool,
    limit: Option<usize>,
    query: Option<&str>,
    preview: bool,
    sort: SortOrder,
) -> io::Result<Listing> {
    list_cancellable(path, show_hidden, limit, query, preview, sort, &|| false)
}

fn list_cancellable(
    path: &Path,
    show_hidden: bool,
    limit: Option<usize>,
    query: Option<&str>,
    preview: bool,
    sort: SortOrder,
    cancelled: &dyn Fn() -> bool,
) -> io::Result<Listing> {
    check_cancelled(cancelled)?;
    // Selective queries can filter directory names before fetching any metadata.
    // As typed search in the window is already indexed, this also keeps direct
    // one-off engine searches inexpensive.
    if query.is_some_and(|q| q.chars().count() >= 3) {
        return portable_list(path, show_hidden, limit, query, preview, sort, cancelled);
    }
    match bulk_entries(path, show_hidden, query, cancelled) {
        Ok(entries) => {
            check_cancelled(cancelled)?;
            finish(entries, limit, Vec::new(), preview, sort, cancelled)
        }
        Err(error) if cancelled() => Err(error),
        // Some server/file-provider volumes do not vend the requested attributes.
        // A fresh read_dir starts at the beginning and preserves any per-item errors.
        Err(_) => portable_list(path, show_hidden, limit, query, preview, sort, cancelled),
    }
}

fn bulk_entries(
    path: &Path,
    show_hidden: bool,
    query: Option<&str>,
    cancelled: &dyn Fn() -> bool,
) -> io::Result<Vec<Entry>> {
    let needle = query.unwrap_or_default().to_lowercase();
    let mut entries = Vec::new();
    crate::bulk::visit(path, cancelled, |item| {
        if !show_hidden && (item.hidden || item.name.starts_with('.')) {
            return;
        }
        let sort_key = item.name.to_lowercase();
        if !sort_key.contains(&needle) {
            return;
        }
        let path = path.join(item.name);
        let is_directory = item.kind == "folder" || (item.kind == "symlink" && path.is_dir());
        entries.push(Entry {
            name: item.name.to_owned(),
            path,
            kind: item.kind,
            is_directory,
            size: item.size,
            modified: item.modified,
            digit_width: digit_width(&sort_key),
            sort_key,
        });
    })?;
    Ok(entries)
}

/// Visit a complete, sorted folder for the native window. A callback borrows
/// the filename and kind for its call. Size is in bytes and modified is signed
/// Unix time in seconds. Non-fatal per-item warnings accompany a successful scan.
pub fn visit_entries(
    path: &Path,
    show_hidden: bool,
    visit: impl FnMut(&str, &str, bool, Option<u64>, Option<i64>),
) -> Result<Vec<String>, String> {
    visit_entries_sorted(path, show_hidden, SortOrder::NameAsc, visit)
}

/// Typed folder listing with the same ordering as list and preview requests.
pub fn visit_entries_sorted(
    path: &Path,
    show_hidden: bool,
    sort: SortOrder,
    visit: impl FnMut(&str, &str, bool, Option<u64>, Option<i64>),
) -> Result<Vec<String>, String> {
    visit_entries_cancellable(path, show_hidden, sort, &|| false, visit)
}

/// Cancellation is checked between kernel batches, before sorting and during
/// emission. Callers publish rows only after the complete listing succeeds.
pub fn visit_entries_cancellable(
    path: &Path,
    show_hidden: bool,
    sort: SortOrder,
    cancelled: &dyn Fn() -> bool,
    mut visit: impl FnMut(&str, &str, bool, Option<u64>, Option<i64>),
) -> Result<Vec<String>, String> {
    let listing = crate::absolute(path)
        .and_then(|root| list_cancellable(root, show_hidden, None, None, false, sort, cancelled))
        .map_err(|err| err.to_string())?;
    for group in listing.entries.chunks(256) {
        check_cancelled(cancelled).map_err(|e| e.to_string())?;
        for item in group {
            visit(
                &item.name,
                item.kind,
                item.is_directory,
                item.size,
                item.modified,
            );
        }
    }
    check_cancelled(cancelled).map_err(|e| e.to_string())?;
    Ok(listing.warnings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{hint::black_box, time::Instant};

    #[test]
    fn numeric_fast_path_agrees_with_natural_comparison_for_every_name_pair() {
        let parts = [
            "", "x", "A", "-", "0", "00", "2", "02", "10", "0004", "a02b1", "é", "２",
        ];
        let mut rows = Vec::new();
        for first in parts {
            for second in parts {
                let name = format!("{first}{second}");
                let sort_key = name.to_lowercase();
                rows.push(Entry {
                    digit_width: digit_width(&sort_key),
                    sort_key,
                    name,
                    path: PathBuf::new(),
                    kind: "file",
                    is_directory: false,
                    size: None,
                    modified: None,
                });
            }
        }
        for a in &rows {
            for b in &rows {
                let natural =
                    natural_cmp(&a.sort_key, &b.sort_key).then_with(|| a.name.cmp(&b.name));
                for mode in [
                    SortOrder::NameAsc,
                    SortOrder::ModifiedDesc,
                    SortOrder::ModifiedAsc,
                    SortOrder::SizeDesc,
                    SortOrder::SizeAsc,
                ] {
                    assert_eq!(
                        mode.compare(a, b),
                        natural,
                        "{mode:?}: {:?} and {:?}",
                        a.name,
                        b.name
                    );
                }
                assert_eq!(SortOrder::NameDesc.compare(a, b), natural.reverse());
            }
        }
    }

    #[test]
    fn absent_metadata_is_last_for_each_direction_and_ties_use_natural_names() {
        let entries: Vec<_> = [
            ("item 1", None, None),
            ("item 12", Some(8), Some(-99)),
            ("item 2", Some(8), Some(-99)),
            ("item 3", Some(1), Some(22)),
            ("item 4", Some(0), Some(0)),
        ]
        .into_iter()
        .map(|(name, size, modified)| Entry {
            name: name.into(),
            path: PathBuf::from(name),
            kind: "file",
            is_directory: false,
            size,
            modified,
            sort_key: name.into(),
            digit_width: digit_width(name),
        })
        .collect();
        for (order, expected) in [
            (
                SortOrder::ModifiedDesc,
                ["item 3", "item 4", "item 2", "item 12", "item 1"],
            ),
            (
                SortOrder::ModifiedAsc,
                ["item 2", "item 12", "item 4", "item 3", "item 1"],
            ),
            (
                SortOrder::SizeDesc,
                ["item 2", "item 12", "item 3", "item 4", "item 1"],
            ),
            (
                SortOrder::SizeAsc,
                ["item 4", "item 3", "item 2", "item 12", "item 1"],
            ),
        ] {
            let result =
                finish(entries.clone(), None, Vec::new(), false, order, &|| false).unwrap();
            assert_eq!(
                result
                    .entries
                    .iter()
                    .map(|e| e.name.as_str())
                    .collect::<Vec<_>>(),
                expected
            );
        }
    }

    #[test]
    fn portable_fallback_observes_cancellation_before_returning_a_partial_folder() {
        let root =
            std::env::temp_dir().join(format!("finger-portable-stop-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        for name in ["one", "two", "three"] {
            fs::write(root.join(name), []).unwrap();
        }
        let checks = std::cell::Cell::new(0);
        let stopped = || {
            checks.set(checks.get() + 1);
            checks.get() >= 3
        };
        let result = portable_list(
            &root,
            false,
            None,
            None,
            false,
            SortOrder::NameAsc,
            &stopped,
        );
        assert_eq!(result.err().unwrap().kind(), io::ErrorKind::Interrupted);
        assert_eq!(
            list(&root, false, None, None, false, SortOrder::NameAsc)
                .unwrap()
                .total,
            3
        );
        fs::remove_dir_all(root).unwrap();
    }

    // This test also guards the optimized Darwin reader against layout changes.
    #[test]
    fn bulk_and_portable_scans_agree_on_real_metadata() {
        use std::os::unix::fs::symlink;
        let root = std::env::temp_dir().join(format!("finger-list-readers-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("Image 12.png"), [1, 2, 3]).unwrap();
        fs::File::open(root.join("Image 12.png"))
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH - std::time::Duration::from_secs(86_400))
            .unwrap();
        fs::write(root.join("Image 2.png"), [1, 2]).unwrap();
        fs::write(root.join(".hidden"), []).unwrap();
        fs::create_dir(root.join("Folder")).unwrap();
        symlink("Folder", root.join("Alias")).unwrap();
        symlink("missing", root.join("Broken")).unwrap();
        let fast = list(&root, false, None, None, false, SortOrder::NameAsc).unwrap();
        let ordinary = portable_list(&root, false, None, None, false, SortOrder::NameAsc, &|| {
            false
        })
        .unwrap();
        assert_eq!(
            fast.entries
                .iter()
                .find(|e| e.name == "Image 12.png")
                .unwrap()
                .modified,
            Some(-86_400)
        );
        let fast_json = serde_json::to_value(fast).unwrap();
        let ordinary_json = serde_json::to_value(ordinary).unwrap();
        fs::remove_dir_all(root).unwrap();
        assert_eq!(fast_json, ordinary_json);
    }

    // Reproduce the pre-optimization strategy (read_dir, stat for each match,
    // full natural sort before truncation) on the same fixture as the bulk scan.
    #[test]
    #[ignore = "release-only benchmark; creates its own 10,000-item fixture"]
    fn compare_filesystem_scans() {
        let root =
            std::env::temp_dir().join(format!("finger-scan-benchmark-{}", std::process::id()));
        fs::create_dir(&root).unwrap();
        for number in 0..10_000 {
            fs::File::create(root.join(format!("frame-{number:05}.png"))).unwrap();
        }
        for (label, limit) in [("open", None), ("preview prefix", Some(8))] {
            for bulk in [false, true] {
                let mut elapsed = Vec::new();
                for index in 0..26 {
                    let start = Instant::now();
                    let result = if bulk {
                        list(&root, false, limit, None, false, SortOrder::NameAsc).unwrap()
                    } else {
                        let mut full = portable_list(
                            &root,
                            false,
                            None,
                            None,
                            false,
                            SortOrder::NameAsc,
                            &|| false,
                        )
                        .unwrap();
                        if let Some(max) = limit {
                            full.entries.truncate(max);
                        }
                        full
                    };
                    let wire = serde_json::to_vec(&result).unwrap();
                    black_box(wire);
                    if index != 0 {
                        elapsed.push(start.elapsed().as_secs_f64() * 1000.0);
                    }
                }
                elapsed.sort_by(f64::total_cmp);
                println!(
                    "{label:15} {:24} median {:6.2} ms   p95 {:6.2} ms",
                    if bulk {
                        "bulk + bounded sort"
                    } else {
                        "read_dir + full sort"
                    },
                    elapsed[12],
                    elapsed[23]
                );
            }
        }
        let mut times = Vec::new();
        for index in 0..26 {
            let start = Instant::now();
            let warnings = visit_entries(&root, false, |name, kind, directory, size, modified| {
                black_box((name, kind, directory, size, modified));
            })
            .unwrap();
            black_box(warnings);
            if index != 0 {
                times.push(start.elapsed().as_secs_f64() * 1000.0);
            }
        }
        times.sort_by(f64::total_cmp);
        println!(
            "open            typed native visitor     median {:6.2} ms   p95 {:6.2} ms",
            times[12], times[23]
        );
        fs::remove_dir_all(&root).unwrap();
    }
}

#[cfg(all(test, not(debug_assertions)))]
#[path = "listing_profile.rs"]
mod profile;
