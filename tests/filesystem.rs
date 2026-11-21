use serde_json::{Value, json};
use std::{
    collections::HashSet,
    ffi::CString,
    fs,
    os::unix::{
        ffi::OsStrExt,
        fs::{PermissionsExt, symlink},
    },
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

struct Fixture(PathBuf);

impl Fixture {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        loop {
            let path = std::env::temp_dir().join(format!(
                "finger-core-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match fs::create_dir(&path) {
                Ok(()) => return Self(path),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => panic!("could not make fixture at {}: {e}", path.display()),
            }
        }
    }

    fn dir(&self, name: &str) -> PathBuf {
        let path = self.0.join(name);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn file(&self, name: &str, data: impl AsRef<[u8]>) -> PathBuf {
        let path = self.0.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, data).unwrap();
        path
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn ask(q: Value) -> Value {
    serde_json::from_str(&finger_core::request_json(&q.to_string())).unwrap()
}

fn ok(q: Value) -> Value {
    let response = ask(q);
    assert_eq!(response["ok"], true, "{response}");
    response
}

fn entries(directory: &Path) -> Vec<Value> {
    ok(json!({"op":"list","id":301,"path":directory}))["entries"]
        .as_array()
        .unwrap()
        .clone()
}

fn names(entries: &[Value]) -> Vec<&str> {
    entries
        .iter()
        .map(|e| e["name"].as_str().unwrap())
        .collect()
}

#[test]
fn listing_describes_real_files_and_directories_through_the_protocol() {
    let f = Fixture::new();
    f.dir("exports-old");
    f.dir("exports");
    f.dir("delivery");
    let png = f.file("exports/frame-12.png", b"twelve bytes");
    let svg = f.file("exports/frame-2.svg", b"<svg/>");
    let missing = f.0.join("exports/unresolved");
    symlink("missing-target", &missing).unwrap();
    symlink("exports", f.0.join("current")).unwrap();
    f.file("exports/.notes", b"hidden");
    let parent = entries(&f.0);
    assert_eq!(
        names(&parent),
        ["current", "delivery", "exports", "exports-old"]
    );
    assert_eq!(parent[0]["kind"], "symlink");
    assert_eq!(parent[0]["isDirectory"], true);
    let children = entries(&f.0.join("exports"));
    assert_eq!(
        names(&children),
        ["frame-2.svg", "frame-12.png", "unresolved"]
    );
    assert_eq!(children[0]["path"], svg.to_str().unwrap());
    assert_eq!(children[0]["size"], 6);
    assert_eq!(children[1]["path"], png.to_str().unwrap());
    assert_eq!(children[2]["isDirectory"], false);
    assert!(children[1]["modified"].is_i64());
    let preview =
        ok(json!({"op":"list","path":f.0.join("exports"),"limit":1,"showHidden":true,"id":3}));
    assert_eq!(preview["id"], 3);
    assert_eq!(preview["total"], 4);
    assert_eq!(preview["entries"].as_array().unwrap().len(), 1);
    assert_eq!(preview["entries"][0]["name"], ".notes");
    let filtered = ok(json!({"op":"list","path":f.0.join("exports"),"query":"FRAME-2"}));
    assert_eq!(filtered["total"], 1);
    assert_eq!(filtered["entries"][0]["path"], svg.to_str().unwrap());
}

#[test]
fn names_survive_unicode_spaces_newlines_and_protocol_characters() {
    let f = Fixture::new();
    let filename = "한 글 🐾 & \"quote\"\nrow.png";
    f.file(filename, b"test");
    let out = entries(&f.0);
    assert_eq!(out[0]["name"], filename);
    assert!(Path::new(out[0]["path"].as_str().unwrap()).is_file());
}

#[test]
fn finder_hidden_flag_is_respected() {
    let f = Fixture::new();
    let path = f.file("invisible", b"flagged");
    let c_path = CString::new(path.as_os_str().as_bytes()).unwrap();
    assert_eq!(
        unsafe { libc::chflags(c_path.as_ptr(), libc::UF_HIDDEN) },
        0
    );
    assert!(entries(&f.0).is_empty());
    let all = ok(json!({"op":"list","path":f.0,"showHidden":true}));
    assert_eq!(all["entries"][0]["name"], "invisible");
}

#[test]
fn create_and_rename_are_exclusive_and_reject_dot_components() {
    let f = Fixture::new();
    let folder = ok(json!({"op":"newFolder","path":f.0,"name":"new folder"}));
    let path = folder["path"].as_str().unwrap();
    assert!(Path::new(path).is_dir());
    assert!(
        !ask(json!({"op":"newFolder","path":f.0,"name":"new folder"}))["ok"]
            .as_bool()
            .unwrap()
    );
    for name in ["", ".", "..", "a/b", "../away", "a\0b"] {
        assert_eq!(
            ask(json!({"op":"rename","path":path,"name":name}))["ok"],
            false
        );
        assert_eq!(
            ask(json!({"op":"newFolder","path":f.0,"name":name}))["ok"],
            false
        );
    }
    let file = f.file("logo.svg", "original");
    f.file("occupied.svg", "occupied");
    assert_eq!(
        ask(json!({"op":"rename","path":file,"name":"occupied.svg"}))["ok"],
        false
    );
    assert_eq!(fs::read_to_string(&file).unwrap(), "original");
    let out = ok(json!({"op":"rename","path":file,"name":"Logo.svg"}));
    let renamed = out["path"].as_str().unwrap();
    assert_eq!(fs::read_to_string(renamed).unwrap(), "original");
    assert!(names(&entries(&f.0)).contains(&"Logo.svg"));
}

#[test]
fn moves_a_png_and_its_source_and_reports_partial_results() {
    let f = Fixture::new();
    let dest = f.dir("delivery");
    let a = f.file("exports/poster.png", [0x89, b'P', b'N', b'G']);
    let b = f.file("exports/poster.svg", "<svg/>");
    let absent = f.0.join("exports/no-such-file");
    let reply = ok(json!({"op":"move","sources":[a,absent,b],"destination":dest}));
    let outcomes = reply["results"].as_array().unwrap();
    assert_eq!(
        outcomes
            .iter()
            .map(|x| x["status"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["done", "error", "done"]
    );
    assert_eq!(
        fs::read(dest.join("poster.png")).unwrap(),
        [0x89, b'P', b'N', b'G']
    );
    assert_eq!(
        fs::read_to_string(dest.join("poster.svg")).unwrap(),
        "<svg/>"
    );
    assert!(!a.exists() && !b.exists());
    assert!(outcomes[1]["error"].is_string());
}

#[test]
fn collision_choices_preserve_existing_data_and_report_the_chosen_path() {
    let f = Fixture::new();
    let dest = f.dir("delivery");
    let src = f.file("exports/poster.png", "new");
    f.file("delivery/poster.png", "original");
    for (collision, expected) in [("error", "collision"), ("skip", "skipped")] {
        let r = ok(json!({"op":"move","sources":[src],"destination":dest,"collision":collision}));
        assert_eq!(r["results"][0]["status"], expected);
        assert_eq!(fs::read_to_string(&src).unwrap(), "new");
        assert_eq!(
            fs::read_to_string(dest.join("poster.png")).unwrap(),
            "original"
        );
    }
    let r = ok(json!({"op":"move","sources":[src],"destination":dest,"collision":"keepBoth"}));
    assert_eq!(r["results"][0]["status"], "done", "{r}");
    assert_eq!(
        r["results"][0]["destination"],
        dest.join("poster 2.png").to_str().unwrap()
    );
    assert_eq!(
        fs::read_to_string(dest.join("poster 2.png")).unwrap(),
        "new"
    );
    assert_eq!(
        fs::read_to_string(dest.join("poster.png")).unwrap(),
        "original"
    );
}

#[test]
fn copy_preserves_links_inside_directories_and_reports_covered_selections() {
    let f = Fixture::new();
    let dest = f.dir("delivery");
    let src = f.dir("art.pkg");
    let original = f.file("art.pkg/design.svg", "source");
    symlink("../missing", src.join("link")).unwrap();
    let r = ok(json!({"op":"copy","sources":[original,src,src],"destination":dest}));
    assert_eq!(r["results"][0]["status"], "skipped", "{r}");
    assert_eq!(r["results"][1]["status"], "done", "{r}");
    assert_eq!(r["results"][2]["status"], "skipped", "{r}");
    assert_eq!(
        fs::read_to_string(dest.join("art.pkg/design.svg")).unwrap(),
        "source"
    );
    assert_eq!(
        fs::read_link(dest.join("art.pkg/link")).unwrap(),
        Path::new("../missing")
    );
    assert!(original.exists());
    let both = ok(json!({"op":"copy","sources":[src],"destination":dest,"collision":"keepBoth"}));
    assert_eq!(
        both["results"][0]["destination"],
        dest.join("art.pkg 2").to_str().unwrap()
    );
}

#[test]
fn cross_alias_descendants_and_same_folder_moves_are_handled_without_mutation() {
    let f = Fixture::new();
    let src = f.dir("exports");
    f.file("exports/inner/frame.png", "source");
    let inner_alias = f.0.join("elsewhere");
    symlink(src.join("inner"), &inner_alias).unwrap();
    for op in ["copy", "move"] {
        let r = ok(json!({"op":op,"sources":[src],"destination":inner_alias}));
        assert_eq!(r["results"][0]["status"], "error");
        assert!(
            r["results"][0]["error"]
                .as_str()
                .unwrap()
                .contains("inside itself")
        );
    }
    let same = ok(json!({"op":"move","sources":[src],"destination":f.0,"collision":"keepBoth"}));
    assert_eq!(same["results"][0]["status"], "skipped");
    assert_eq!(
        fs::read_to_string(src.join("inner/frame.png")).unwrap(),
        "source"
    );
}

#[test]
fn concurrent_copies_publish_distinct_complete_files() {
    let f = Fixture::new();
    let src = f.file("source/poster.png", vec![0x7b; 8192]);
    let dest = f.dir("delivery");
    let message = json!({"op":"copy","sources":[src],"destination":dest,"collision":"keepBoth"});
    let threads: Vec<_> = (0..12)
        .map(|_| {
            let command = message.clone();
            std::thread::spawn(move || ok(command))
        })
        .collect();
    let mut published = HashSet::new();
    for thread in threads {
        let r = thread.join().unwrap();
        let result = &r["results"][0];
        assert_eq!(result["status"], "done", "{r}");
        let path = result["destination"].as_str().unwrap().to_string();
        assert_eq!(fs::read(&path).unwrap(), vec![0x7b; 8192]);
        assert!(published.insert(path));
    }
    assert_eq!(fs::read_dir(&dest).unwrap().count(), 12);
}

#[test]
fn copy_keeps_extended_attributes_permissions_and_broken_top_level_symlinks() {
    let f = Fixture::new();
    let src = f.file("source/swatch.tiff", "RGB");
    fs::set_permissions(&src, fs::Permissions::from_mode(0o640)).unwrap();
    let key = c"com.example.finger-fixture";
    let value = b"ok";
    let source = CString::new(src.as_os_str().as_bytes()).unwrap();
    assert_eq!(
        unsafe {
            libc::setxattr(
                source.as_ptr(),
                key.as_ptr(),
                value.as_ptr().cast(),
                value.len(),
                0,
                0,
            )
        },
        0
    );
    let link = f.0.join("source/broken");
    symlink("does-not-exist", &link).unwrap();
    let dest = f.dir("delivery");
    let r = ok(json!({"op":"copy","sources":[src,link],"destination":dest}));
    for result in r["results"].as_array().unwrap() {
        assert_eq!(result["status"], "done", "{r}");
    }
    let copied = dest.join("swatch.tiff");
    assert_eq!(
        fs::metadata(&copied).unwrap().permissions().mode() & 0o777,
        0o640
    );
    let copied = CString::new(copied.as_os_str().as_bytes()).unwrap();
    let mut buf = [0; 2];
    assert_eq!(
        unsafe {
            libc::getxattr(
                copied.as_ptr(),
                key.as_ptr(),
                buf.as_mut_ptr().cast(),
                buf.len(),
                0,
                0,
            )
        },
        2
    );
    assert_eq!(&buf, value);
    assert_eq!(
        fs::read_link(dest.join("broken")).unwrap(),
        Path::new("does-not-exist")
    );
}

#[test]
fn protocol_recovers_from_invalid_requests() {
    let bad: Value = serde_json::from_str(&finger_core::request_json("{")).unwrap();
    assert_eq!(bad["ok"], false);
    assert_eq!(ask(json!({"id":42,"op":"unknown"}))["id"], 42);
    assert_eq!(
        ask(json!({"op":"list","path":"a/relative/path"}))["ok"],
        false
    );
    let f = Fixture::new();
    let p = f.file("regular", "test");
    assert_eq!(ask(json!({"op":"list","path":p}))["ok"], false);
    assert_eq!(
        ok(json!({"op":"list","path":f.0}))["entries"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn preview_finds_real_media_beyond_the_first_page() {
    let f = Fixture::new();
    for n in 0..50 {
        f.dir(&format!("Folder {n}"));
    }
    f.file("z-after.png", b"png");
    f.file("A source.svg", b"svg");
    f.file("z-1.pdf", b"pdf");
    f.file("z-2.TIFF", b"tiff");
    f.file(".unused.jpg", b"jpg");
    f.file("0-placeholder.png", b"");
    let preview = ok(json!({"op":"preview", "path": f.0}));
    assert_eq!(preview["total"], 55);
    let entries = preview["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 32);
    assert!(entries.iter().all(|e| e["isDirectory"] == true));
    assert_eq!(
        names(preview["media"].as_array().unwrap()),
        ["A source.svg", "z-1.pdf", "z-2.TIFF"]
    );
}

#[test]
fn each_sort_agrees_across_native_listing_preview_media_and_filtered_fallback() {
    let f = Fixture::new();
    f.dir("bin-12");
    f.dir("bin-2");
    for n in 1..=45 {
        let path = f.file(&format!("frame-{n}.png"), vec![0; n % 7 + 1]);
        fs::File::open(path)
            .unwrap()
            .set_modified(
                std::time::UNIX_EPOCH + std::time::Duration::from_secs((n as u64 % 5) * 10),
            )
            .unwrap();
    }
    let modes = [
        ("nameAsc", 1),
        ("nameDesc", 45),
        ("modifiedDesc", 4),
        ("modifiedAsc", 5),
        ("sizeDesc", 6),
        ("sizeAsc", 7),
    ];
    for (mode, (sort, first)) in modes.into_iter().enumerate() {
        let full = ok(json!({"op":"list","path":f.0,"sort":sort}));
        let all = full["entries"].as_array().unwrap();
        assert!(all[..2].iter().all(|e| e["isDirectory"] == true));
        assert_eq!(all[2]["name"], format!("frame-{first}.png"), "{sort}");
        let filtered = ok(json!({"op":"list","path":f.0,"query":"frame","sort":sort}));
        assert_eq!(filtered["entries"].as_array().unwrap(), &all[2..]);
        let preview = ok(json!({"op":"preview","path":f.0,"sort":sort}));
        assert_eq!(preview["entries"].as_array().unwrap(), &all[..32]);
        assert_eq!(preview["media"].as_array().unwrap(), &all[2..5]);
        let typed_mode = finger_core::SortOrder::from_mode(mode as u8).unwrap();
        let mut typed = Vec::new();
        let warnings =
            finger_core::visit_entries_sorted(&f.0, false, typed_mode, |name, _, _, _, _| {
                typed.push(name.to_owned())
            })
            .unwrap();
        assert!(warnings.is_empty());
        assert_eq!(typed, names(all));
    }
    assert!(finger_core::SortOrder::from_mode(6).is_none());
    assert_eq!(
        ask(json!({"op":"list","path":f.0,"sort":"somethingElse"}))["ok"],
        false
    );
}

#[test]
fn copying_locked_files_preserves_lock_and_move_failure_leaves_no_debris() {
    let f = Fixture::new();
    let src = f.file("locked.txt", "original");
    let dest = f.dir("destination");
    let c_src = CString::new(src.as_os_str().as_bytes()).unwrap();
    let target = dest.join("locked.txt");
    let c_target = CString::new(target.as_os_str().as_bytes()).unwrap();
    assert_eq!(
        unsafe { libc::chflags(c_src.as_ptr(), libc::UF_IMMUTABLE) },
        0
    );
    let copied = ok(json!({"op":"copy","sources":[src],"destination":dest}));
    let moved = ok(json!({"op":"move","sources":[src],"destination":dest,"collision":"keepBoth"}));
    let target_flags = fs::symlink_metadata(&target)
        .ok()
        .map(|m| std::os::macos::fs::MetadataExt::st_flags(&m));
    // Unlock only disposable fixture items before any assertions unwind.
    unsafe {
        libc::chflags(c_src.as_ptr(), 0);
        libc::chflags(c_target.as_ptr(), 0);
    }
    assert_eq!(copied["results"][0]["status"], "done", "{copied}");
    assert_eq!(
        target_flags.unwrap() & libc::UF_IMMUTABLE,
        libc::UF_IMMUTABLE
    );
    assert_eq!(moved["results"][0]["status"], "error");
    assert_eq!(fs::read_to_string(&src).unwrap(), "original");
    assert_eq!(fs::read_to_string(&target).unwrap(), "original");
    assert_eq!(fs::read_dir(dest).unwrap().count(), 1);
}

#[test]
fn copying_a_hardlinked_pair_keeps_a_single_destination_inode() {
    use std::os::unix::fs::MetadataExt;
    let f = Fixture::new();
    let src = f.dir("exports");
    let file = f.file("exports/image.png", "PNG");
    fs::hard_link(&file, src.join("image-link.png")).unwrap();
    let dest = f.dir("delivery");
    let result = ok(json!({"op":"copy","sources":[src],"destination":dest}));
    assert_eq!(result["results"][0]["status"], "done", "{result}");
    let target = dest.join("exports");
    let first = fs::metadata(target.join("image.png")).unwrap();
    let second = fs::metadata(target.join("image-link.png")).unwrap();
    assert_eq!(first.ino(), second.ino());
    assert_eq!(first.nlink(), 2);
    assert_ne!(fs::metadata(file).unwrap().ino(), first.ino());
}

#[test]
fn native_listing_and_json_agree_for_hidden_names_links_and_signed_dates() {
    let f = Fixture::new();
    f.dir("exports/子");
    f.file("exports/Frame 11.png", [1, 2, 3]);
    let old = f.file("exports/Frame 2.svg", "<svg/>");
    fs::File::open(old)
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH - std::time::Duration::from_secs(10))
        .unwrap();
    f.file("exports/.draft", "hidden");
    f.file("exports/line\nbreak 🫧", "two lines");
    let root = f.0.join("exports");
    symlink("子", root.join("alias")).unwrap();
    symlink("absent", root.join("broken")).unwrap();
    for hidden in [false, true] {
        let json = ok(json!({"op":"list", "path":root, "showHidden":hidden}));
        let mut typed = Vec::new();
        let warnings =
            finger_core::visit_entries(&root, hidden, |name, kind, is_dir, size, modified| {
                typed.push(json!({"name":name, "path":root.join(name), "kind":kind,
                              "isDirectory":is_dir, "size":size, "modified":modified}));
            })
            .unwrap();
        assert_eq!(json!(&typed), json["entries"]);
        assert_eq!(warnings, Vec::<String>::new());
    }
    let mut visits = 0;
    let error =
        finger_core::visit_entries(Path::new("relative"), true, |_, _, _, _, _| visits += 1)
            .unwrap_err();
    assert!(error.contains("absolute"));
    assert_eq!(visits, 0);
}

fn receipt(result: &Value) -> &str {
    result["receipt"]
        .as_str()
        .expect("successful mutation must issue a receipt")
}

#[test]
fn undo_and_redo_keep_both_use_the_two_exact_names() {
    let f = Fixture::new();
    let source = f.file("exports/logo.svg", "fresh");
    let dest = f.dir("delivery");
    let prior = f.file("delivery/logo.svg", "prior");
    let moved =
        ok(json!({"op":"move","sources":[source],"destination":dest,"collision":"keepBoth"}));
    let token = receipt(&moved["results"][0]);
    let renamed_target = dest.join("logo 2.svg");
    assert_eq!(fs::read_to_string(&renamed_target).unwrap(), "fresh");
    let undone = ok(json!({"op":"restore","receipts":[token]}));
    assert_eq!(undone["results"][0]["status"], "done", "{undone}");
    let redo = receipt(&undone["results"][0]);
    assert_eq!(
        undone["results"][0]["destination"],
        source.to_str().unwrap()
    );
    assert_eq!(fs::read_to_string(&source).unwrap(), "fresh");
    assert!(!renamed_target.exists());
    assert_eq!(fs::read_to_string(&prior).unwrap(), "prior");
    let replay = ok(json!({"op":"restore","receipts":[token]}));
    assert_eq!(replay["results"][0]["status"], "error");
    let redone = ok(json!({"op":"restore","receipts":[redo]}));
    assert_eq!(redone["results"][0]["status"], "done", "{redone}");
    assert_ne!(receipt(&redone["results"][0]), token);
    assert_eq!(fs::read_to_string(renamed_target).unwrap(), "fresh");
    assert_eq!(fs::read_to_string(prior).unwrap(), "prior");
    assert!(!source.exists());
}

#[test]
fn multi_undo_preserves_occupied_names_and_remaining_receipt_retries() {
    let f = Fixture::new();
    let a = f.file("out/a.png", "png");
    let b = f.file("out/b.svg", "svg");
    let dest = f.dir("delivery");
    let r = ok(json!({"op":"move","sources":[a,b],"destination":dest}));
    let ta = receipt(&r["results"][0]);
    let tb = receipt(&r["results"][1]);
    fs::write(&b, "somebody else").unwrap();
    let u = ok(json!({"op":"restore","receipts":[ta,tb]}));
    assert_eq!(u["results"][0]["status"], "done", "{u}");
    assert_eq!(u["results"][1]["status"], "collision", "{u}");
    assert_eq!(fs::read_to_string(&a).unwrap(), "png");
    assert_eq!(fs::read_to_string(&b).unwrap(), "somebody else");
    assert_eq!(fs::read_to_string(dest.join("b.svg")).unwrap(), "svg");
    fs::rename(&b, b.with_extension("saved")).unwrap();
    assert_eq!(
        ok(json!({"op":"restore","receipts":[tb]}))["results"][0]["status"],
        "done"
    );
    assert_eq!(fs::read_to_string(b).unwrap(), "svg");
}

#[test]
fn undo_rejects_changed_or_replaced_files_and_nested_folder_edits() {
    let f = Fixture::new();
    let dest = f.dir("delivery");
    let a = f.file("source/a.txt", "one");
    let b = f.file("source/b.txt", "two");
    let folder = f.dir("source/assets");
    f.file("source/assets/deep/child", "leaf");
    let r = ok(json!({"op":"move","sources":[a,b,folder],"destination":dest}));
    fs::write(dest.join("a.txt"), "NEW").unwrap();
    fs::rename(dest.join("b.txt"), dest.join("old-b")).unwrap();
    fs::write(dest.join("b.txt"), "two").unwrap();
    fs::write(dest.join("assets/deep/child"), "twig").unwrap();
    let tokens: Vec<_> = r["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(receipt)
        .collect();
    let u = ok(json!({"op":"restore","receipts":tokens}));
    assert!(
        u["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|outcome| outcome["status"] == "error"),
        "{u}"
    );
    assert!(!a.exists() && !b.exists() && !folder.exists());
    assert_eq!(
        fs::read_to_string(dest.join("assets/deep/child")).unwrap(),
        "twig"
    );
}

#[test]
fn undo_checks_parent_identity_and_handles_case_only_rename() {
    let f = Fixture::new();
    let f1 = f.file("source/Mark.svg", "art");
    let rename = ok(json!({"op":"rename","path":f1,"name":"mark.svg"}));
    let u = ok(json!({"op":"restore","receipts":[receipt(&rename)]}));
    assert_eq!(u["results"][0]["status"], "done", "{u}");
    assert!(names(&entries(f1.parent().unwrap())).contains(&"Mark.svg"));
    let dest = f.dir("delivery");
    let m = ok(json!({"op":"move","sources":[f1],"destination":dest}));
    fs::rename(f.0.join("source"), f.0.join("old-source")).unwrap();
    f.dir("source");
    let refused = ok(json!({"op":"restore","receipts":[receipt(&m["results"][0])]}));
    assert_eq!(refused["results"][0]["status"], "error", "{refused}");
    assert!(!f1.exists() && dest.join("Mark.svg").exists());
}

#[test]
fn undo_chains_renames_and_moves_without_invalidating_prior_steps() {
    let f = Fixture::new();
    let file = f.file("source/first.txt", "v1");
    let dest = f.dir("delivery");
    let moved = ok(json!({"op":"move","sources":[file],"destination":dest}));
    let renamed = ok(json!({"op":"rename","path":dest.join("first.txt"),"name":"second.txt"}));
    let undo_rename = ok(json!({"op":"restore","receipts":[receipt(&renamed)]}));
    assert_eq!(undo_rename["results"][0]["status"], "done", "{undo_rename}");
    let undo_move = ok(json!({"op":"restore","receipts":[receipt(&moved["results"][0])]}));
    assert_eq!(undo_move["results"][0]["status"], "done", "{undo_move}");
    let redo_move = ok(json!({"op":"restore","receipts":[receipt(&undo_move["results"][0])]}));
    assert_eq!(redo_move["results"][0]["status"], "done", "{redo_move}");
    let redo_rename = ok(json!({"op":"restore","receipts":[receipt(&undo_rename["results"][0])]}));
    assert_eq!(redo_rename["results"][0]["status"], "done", "{redo_rename}");
    assert_eq!(fs::read_to_string(dest.join("second.txt")).unwrap(), "v1");
}

#[test]
fn optional_selection_identity_prevents_mutating_replacements() {
    use std::os::macos::fs::MetadataExt;
    let f = Fixture::new();
    let path = f.file("source/art.png", "old");
    let dest = f.dir("delivery");
    let m = fs::symlink_metadata(&path).unwrap();
    let stamp = format!(
        "{}:{}:{}:{}",
        m.st_dev(),
        m.st_ino(),
        m.st_birthtime(),
        m.st_birthtime_nsec()
    );
    let old = path.with_extension("retired");
    fs::rename(&path, &old).unwrap();
    fs::write(&path, "replacement").unwrap();
    let expected = json!({path.to_str().unwrap():stamp});
    for op in ["copy", "move"] {
        let r = ok(json!({"op":op,"sources":[path],"destination":dest,"expectedSources":expected}));
        assert_eq!(r["results"][0]["status"], "error", "{r}");
        assert!(!dest.join("art.png").exists());
    }
    let r = ask(json!({"op":"rename","path":path,"name":"new.png","expectedSources":expected}));
    assert_eq!(r["ok"], false, "{r}");
    let missing = json!({path.to_str().unwrap():"missing"});
    let r = ask(json!({"op":"rename","path":path,"name":"new.png","expectedSources":missing}));
    assert_eq!(r["ok"], false, "{r}");
    assert_eq!(fs::read_to_string(&path).unwrap(), "replacement");
    assert_eq!(fs::read_to_string(old).unwrap(), "old");
}

#[test]
fn named_collisions_identify_both_the_name_and_parent_in_the_request_reply() {
    let f = Fixture::new();
    let folder = f.dir("Fold Studies");
    f.dir("Fold Studies/delivery");
    let from = f.dir("Fold Studies/exports");
    for request in [
        json!({"op":"newFolder","path":folder,"name":"delivery"}),
        json!({"op":"rename","path":from,"name":"delivery"}),
    ] {
        let response = ask(request);
        assert_eq!(response["ok"], false);
        let message = response["error"].as_str().unwrap();
        assert!(
            message.contains("“delivery”")
                && message.contains("Fold Studies")
                && message.contains("Choose another name."),
            "{message}"
        );
    }
    assert!(from.is_dir() && folder.join("delivery").is_dir());
}

#[test]
fn undoing_two_hardlinked_selections_survives_their_shared_ctime_changes() {
    use std::os::unix::fs::MetadataExt;
    let f = Fixture::new();
    let a = f.file("exports/a.bin", "bytes");
    let b = f.0.join("exports/b.bin");
    fs::hard_link(&a, &b).unwrap();
    let dest = f.dir("delivery");
    let moved = ok(json!({"op":"move","sources":[a,b],"destination":dest}));
    let tokens: Vec<_> = moved["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(receipt)
        .collect();
    let undone = ok(json!({"op":"restore","receipts":tokens}));
    assert!(
        undone["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|v| v["status"] == "done"),
        "{undone}"
    );
    assert_eq!(
        fs::metadata(&a).unwrap().ino(),
        fs::metadata(&b).unwrap().ino()
    );
    assert_eq!(fs::metadata(&b).unwrap().nlink(), 2);
    let redo: Vec<_> = undone["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(receipt)
        .collect();
    let redone = ok(json!({"op":"restore","receipts":redo}));
    assert!(
        redone["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|v| v["status"] == "done"),
        "{redone}"
    );
}
