use serde_json::{Value, json};
use std::{
    ffi::CString,
    fs,
    os::unix::{
        ffi::OsStrExt,
        fs::{PermissionsExt, symlink},
    },
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        loop {
            let path = std::env::temp_dir().join(format!(
                "finger-find-check-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Self(path),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => panic!("fixture: {e}"),
            }
        }
    }
    fn file(&self, name: &str) {
        let path = self.0.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "fixture").unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn call(request: Value) -> Value {
    serde_json::from_str(&finger_core::request_json(&request.to_string())).unwrap()
}
struct Find(String);
impl Find {
    fn start(root: &Path, hidden: bool) -> Self {
        let r = call(json!({"op":"startFind","path":root,"showHidden":hidden}));
        assert_eq!(r["ok"], true, "{r}");
        Self(r["session"].as_str().unwrap().to_owned())
    }
    fn query(&self, text: &str, limit: usize) -> Value {
        let r = call(json!({"op":"find","session":self.0,"query":text,"limit":limit}));
        assert_eq!(r["ok"], true, "{r}");
        r
    }
    fn finish(&self) -> Value {
        let start = Instant::now();
        loop {
            let r = self.query("", 1);
            if r["complete"] == true {
                return r;
            }
            assert!(
                start.elapsed() < Duration::from_secs(30),
                "index timeout: {r}"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
    }
}
impl Drop for Find {
    fn drop(&mut self) {
        call(json!({"op":"endFind","session":self.0}));
    }
}

#[test]
fn deep_find_ranks_names_and_paths_and_keeps_bundles_and_links_leaf_items() {
    let f = Fixture::new();
    let outside = Fixture::new();
    for name in [
        "exports/reference/Café 11.png",
        "exports/reference/Café 2.png",
        "exports/reference/Café.png",
        "exports/reference/New Café.png",
        "exports-old/Café.png",
        "delivery/CAFE poster.png",
        "delivery/Cafe\u{301} map.svg",
        "design/보고서.svg",
        ".draft/Café-secret.svg",
        "Assets.app/Contents/Café-bundle.svg",
        "contents-only.txt",
    ] {
        f.file(name);
    }
    fs::write(
        f.0.join("contents-only.txt"),
        "needle-only-in-file-contents",
    )
    .unwrap();
    outside.file("should-never-escape.svg");
    symlink(&outside.0, f.0.join("linked library")).unwrap();
    symlink(&f.0, f.0.join("exports/loop home")).unwrap();
    f.file("Café hiddenflag.svg");
    let flagged = CString::new(f.0.join("Café hiddenflag.svg").as_os_str().as_bytes()).unwrap();
    assert_eq!(
        unsafe { libc::chflags(flagged.as_ptr(), libc::UF_HIDDEN) },
        0
    );

    let search = Find::start(&f.0, false);
    assert_eq!(search.finish()["errors"], 0);
    let result = search.query("cafe", 400);
    assert_eq!(result["total"], 7, "{result}");
    let hits = result["entries"].as_array().unwrap();
    assert_eq!(hits[0]["relativePath"], "exports-old/Café.png");
    assert_eq!(hits[1]["relativePath"], "exports/reference/Café.png");
    let two = hits.iter().position(|e| e["name"] == "Café 2.png").unwrap();
    let eleven = hits
        .iter()
        .position(|e| e["name"] == "Café 11.png")
        .unwrap();
    assert!(two < eleven);
    let selected = search.query("REFERENCE cafe 11", 100);
    assert_eq!(selected["total"], 1);
    assert_eq!(
        selected["entries"][0]["relativePath"],
        "exports/reference/Café 11.png"
    );
    assert_eq!(search.query("cafe\u{301} map", 100)["total"], 1);
    assert_eq!(search.query("보고서", 100)["total"], 1);
    assert_eq!(
        search.query("needle-only-in-file-contents", 100)["total"],
        0
    );
    assert_eq!(search.query("should-never-escape", 100)["total"], 0);
    assert_eq!(search.query("cafe-bundle", 100)["total"], 0);
    assert_eq!(
        search.query("assets.app", 100)["entries"][0]["kind"],
        "package"
    );
    assert_eq!(
        search.query("linked library", 100)["entries"][0]["kind"],
        "symlink"
    );
    assert_eq!(
        search.query("cafe", 2)["entries"].as_array().unwrap().len(),
        2
    );
    assert_eq!(search.query("cafe", 2)["total"], 7);
    assert_eq!(search.query("cafe cafe cafe cafe", 2)["total"], 7);
    drop(search);
    let hidden = Find::start(&f.0, true);
    hidden.finish();
    assert_eq!(hidden.query("cafe", 400)["total"], 9);
    drop(hidden);
    let package = Find::start(&f.0.join("Assets.app"), true);
    let blocked = package.finish();
    assert_eq!(blocked["scanned"], 0);
    assert!(blocked["rootError"].as_str().unwrap().contains("package"));
}

#[test]
fn unreadable_folders_are_counted_and_closed_sessions_cannot_serve_results() {
    let f = Fixture::new();
    f.file("blocked/inside.txt");
    f.file("available.txt");
    let locked = f.0.join("blocked");
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    let search = Find::start(&f.0, false);
    let status = search.finish();
    let inside = search.query("inside", 100);
    let available = search.query("available", 100);
    let handle = search.0.clone();
    drop(search);
    let denied_root = Find::start(&locked, false);
    let root_status = denied_root.finish();
    drop(denied_root);
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o700)).unwrap();
    if unsafe { libc::geteuid() } != 0 {
        assert!(
            status["permissionErrors"].as_u64().unwrap() >= 1,
            "{status}"
        );
        assert!(status["errors"].as_u64().unwrap() >= status["permissionErrors"].as_u64().unwrap());
        assert_eq!(inside["total"], 0);
        assert_eq!(root_status["scanned"], 0);
        assert_eq!(root_status["permissionErrors"], 1);
        assert!(root_status["rootError"].is_string());
    }
    assert_eq!(available["total"], 1);
    assert_eq!(
        call(json!({"op":"find","session":handle,"query":"available"}))["ok"],
        false
    );
    let missing = Find::start(&f.0.join("missing-root"), false);
    let failed = missing.finish();
    assert_eq!(failed["complete"], true);
    assert!(
        failed["rootError"].is_string() && failed["errors"] == 1,
        "{failed}"
    );
}

#[test]
fn cancellation_releases_the_sheet_before_a_tree_finishes() {
    let f = Fixture::new();
    for i in 0..600 {
        f.file(&format!("branch-{}/nested/file-{i}.png", i % 20));
    }
    let search = Find::start(&f.0, false);
    let id = search.0.clone();
    let start = Instant::now();
    drop(search);
    assert!(start.elapsed() < Duration::from_secs(1));
    assert_eq!(
        call(json!({"op":"find","session":id,"query":"file"}))["ok"],
        false
    );
    let again = Find::start(&f.0, false);
    assert_eq!(again.finish()["complete"], true);
    assert_eq!(again.query("file", 4)["total"], 600);
}

#[test]
#[ignore = "release benchmark with a disposable 10,000-file tree"]
fn benchmark_ten_thousand_nested_files() {
    let f = Fixture::new();
    for i in 0..10_000 {
        f.file(&format!("project-{}/art/source-{i:05}.svg", i % 40));
    }
    f.file("delivery/final/approved-cover.png");
    let start = Instant::now();
    let search = Find::start(&f.0, false);
    let start_ms = start.elapsed().as_secs_f64() * 1000.;
    let open_start = Instant::now();
    let listing = call(json!({"op":"list","path":f.0.join("delivery/final")}));
    assert_eq!(listing["entries"].as_array().unwrap().len(), 1);
    let folder_open_ms = open_start.elapsed().as_secs_f64() * 1000.;
    let status = search.finish();
    let scan_ms = start.elapsed().as_secs_f64() * 1000.;
    assert_eq!(status["scanned"], 10083);
    let mut broad = Vec::new();
    let mut narrow = Vec::new();
    for i in 0..26 {
        let t = Instant::now();
        let r = search.query("source", 100);
        let b = t.elapsed().as_secs_f64() * 1000.;
        assert_eq!(r["total"], 10000);
        let t = Instant::now();
        let r = search.query("delivery approved", 100);
        let n = t.elapsed().as_secs_f64() * 1000.;
        assert_eq!(r["total"], 1);
        if i > 0 {
            broad.push(b);
            narrow.push(n);
        }
    }
    broad.sort_by(f64::total_cmp);
    narrow.sort_by(f64::total_cmp);
    println!(
        "startFind returned in {start_ms:.2} ms; indexed {} entries across {} folders in {scan_ms:.2} ms.",
        status["scanned"], status["folders"]
    );
    println!(
        "10k matches, top 100 rows including JSON: median {:.2} ms, p95 {:.2} ms",
        broad[12], broad[23]
    );
    println!("Foreground listing of a small folder during indexing: {folder_open_ms:.2} ms");
    println!(
        "One path + basename match including JSON: median {:.2} ms, p95 {:.2} ms",
        narrow[12], narrow[23]
    );
}
