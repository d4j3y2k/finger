use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};

const HISTORY_LIMIT: usize = 128;

#[derive(Clone)]
struct Visit {
    key: String,
    state: Value,
}

#[derive(Default)]
pub struct Navigation {
    visits: Vec<Visit>,
    position: usize,
    remembered: VecDeque<(String, Value)>,
}

impl Navigation {
    pub fn handle(&mut self, request: &Value) -> Value {
        let command = request["op"].as_str().unwrap_or("");
        if let Some(visit) = self.visits.get_mut(self.position) {
            if let Some(state) = request.get("state") {
                visit.state = state.clone();
                self.remembered.retain(|(key, _)| key != &visit.key);
                self.remembered
                    .push_front((visit.key.clone(), state.clone()));
                self.remembered.truncate(HISTORY_LIMIT);
            }
        }
        match command {
            "visit" => {
                let Some(key) = request["key"].as_str() else {
                    return json!({"ok":false,"error":"Missing location"});
                };
                if self.visits.get(self.position).is_none_or(|v| v.key != key) {
                    self.visits.truncate(self.position.saturating_add(1));
                    self.visits.push(Visit {
                        key: key.to_string(),
                        state: self
                            .remembered
                            .iter()
                            .find(|(path, _)| path == key)
                            .map(|(_, state)| state.clone())
                            .unwrap_or(Value::Null),
                    });
                    if self.visits.len() > HISTORY_LIMIT {
                        self.visits.remove(0);
                    }
                    self.position = self.visits.len() - 1;
                }
            }
            "forget" => {
                let key = request["key"].as_str().unwrap_or("");
                let prior_count = self
                    .visits
                    .iter()
                    .take(self.position + 1)
                    .filter(|v| v.key != key)
                    .count();
                self.visits.retain(|v| v.key != key);
                self.remembered.retain(|(path, _)| path != key);
                if self.visits.is_empty() {
                    let fallback = request["fallback"].as_str().unwrap_or("/");
                    self.visits.push(Visit {
                        key: fallback.to_owned(),
                        state: Value::Null,
                    });
                }
                self.position = prior_count.saturating_sub(1).min(self.visits.len() - 1);
            }
            "remap" => {
                if let Some(map) = request["changes"].as_object() {
                    let changes: HashMap<_, _> = map
                        .iter()
                        .filter_map(|(from, to)| Some((Path::new(from), Path::new(to.as_str()?))))
                        .collect();
                    for visit in &mut self.visits {
                        remap_path(&mut visit.key, &changes);
                        remap_state(&mut visit.state, &changes);
                    }
                    for (key, state) in &mut self.remembered {
                        remap_path(key, &changes);
                        remap_state(state, &changes);
                    }
                }
            }
            "back" if self.position > 0 => self.position -= 1,
            "forward" if self.position + 1 < self.visits.len() => self.position += 1,
            "back" | "forward" | "where" => (),
            _ => return json!({"ok":false,"error":"Unknown navigation command"}),
        }
        match self.visits.get(self.position) {
            Some(visit) => json!({
                "ok":true, "key":visit.key, "state":visit.state,
                "back":self.position>0, "forward":self.position+1<self.visits.len(),
                "previous": self.position.checked_sub(1).map(|i| &self.visits[i].key)
            }),
            None => json!({"ok":false,"error":"No location"}),
        }
    }
}

fn mapped(old: &Path, changes: &HashMap<&Path, &Path>) -> Option<PathBuf> {
    if !old.is_absolute() {
        return None;
    }
    old.ancestors().find_map(|from| {
        let to = changes.get(from)?;
        let suffix = old.strip_prefix(from).ok()?;
        Some(if suffix.as_os_str().is_empty() {
            to.to_path_buf()
        } else {
            to.join(suffix)
        })
    })
}

fn remap_path(path: &mut String, changes: &HashMap<&Path, &Path>) {
    if let Some(next) = mapped(Path::new(path), changes) {
        if let Some(text) = next.to_str() {
            *path = text.to_owned();
        }
    }
}

fn remap_full_selection(
    packed: &mut serde_json::Map<String, Value>,
    changes: &HashMap<&Path, &Path>,
) {
    let Some(folder) = packed.get("folder").and_then(Value::as_str).map(Path::new) else {
        return;
    };
    let Some(names) = packed.get("names").and_then(Value::as_str) else {
        return;
    };
    let next = mapped(folder, changes);
    let parent = next.as_deref().unwrap_or(folder);
    // Moving the folder or an ancestor leaves every relative basename intact.
    // A member moved outside the folder is retained by absolute path so a later
    // move back inside can restore its original selection membership.
    let child_changed = changes.keys().any(|path| path.parent() == Some(folder));
    let external = names.starts_with('/') || names.contains("\0/");
    if child_changed || external {
        let mut updated = String::with_capacity(names.len());
        for (index, name) in names.split('\0').enumerate() {
            let old = folder.join(name);
            let path = mapped(&old, changes).unwrap_or(old);
            let member = if path.parent() == Some(parent) {
                path.file_name()
            } else {
                Some(path.as_os_str())
            };
            if index > 0 {
                updated.push('\0');
            }
            updated.push_str(member.and_then(|part| part.to_str()).unwrap_or(name));
        }
        packed.insert("names".into(), Value::String(updated));
    }
    if let Some(next) = next.and_then(|p| p.into_os_string().into_string().ok()) {
        packed.insert("folder".into(), Value::String(next));
    }
}

fn remap_state(state: &mut Value, changes: &HashMap<&Path, &Path>) {
    if let Some(Value::String(anchor)) = state.get_mut("anchorPath") {
        remap_path(anchor, changes);
    }
    if let Some(selected) = state.get_mut("selected").and_then(Value::as_array_mut) {
        for value in selected {
            if let Value::String(path) = value {
                remap_path(path, changes);
            }
        }
    }
    if let Some(packed) = state.get_mut("selected").and_then(Value::as_object_mut) {
        remap_full_selection(packed, changes);
    }
    if let Some(before_filter) = state.get_mut("beforeFilter") {
        remap_state(before_filter, changes);
    }
}

// AppKit keeps row views. This index keeps filenames folded once per directory.
#[derive(Default)]
pub struct SearchIndex {
    names: Vec<String>,
    last_query: String,
    last_hits: Vec<usize>,
}

impl SearchIndex {
    /// Add a filename in the same order its row was emitted to the native table.
    pub fn push_name(&mut self, name: &str) {
        self.last_query.clear();
        self.last_hits.clear();
        self.names.push(crate::fold_search_text(name));
    }

    pub fn install(&mut self, names: &Value) -> Value {
        *self = Self::default();
        if let Some(values) = names.as_array() {
            self.names.reserve(values.len());
            for value in values {
                self.push_name(value.as_str().unwrap_or(""));
            }
        }
        json!({"ok":true})
    }

    /// None means all rows. Matches are borrowed until the next mutable call.
    pub fn matching_rows(&mut self, query: &str) -> Option<&[usize]> {
        let folded = crate::fold_search_text(query);
        let words: Vec<_> = folded.split_whitespace().collect();
        if words.is_empty() {
            self.last_query.clear();
            self.last_hits.clear();
            return None;
        }
        if folded != self.last_query {
            let names = &self.names;
            let matches = |i: usize| words.iter().all(|word| names[i].contains(word));
            if !self.last_query.is_empty() && folded.starts_with(&self.last_query) {
                self.last_hits.retain(|i| matches(*i));
            } else {
                self.last_hits.clear();
                self.last_hits
                    .extend((0..names.len()).filter(|i| matches(*i)));
            }
            self.last_query = folded;
        }
        Some(&self.last_hits)
    }

    pub fn find(&mut self, query: &str) -> Value {
        match self.matching_rows(query) {
            None => json!({"ok":true,"all":true}),
            Some(rows) => json!({"ok":true,"rows":rows}),
        }
    }

    /// Transfer the index to one native owner, which eventually calls drop_index.
    pub fn into_handle(self) -> *mut std::ffi::c_void {
        Box::into_raw(Box::new(self)).cast()
    }
}

/// Filter one native folder. An empty query returns count -1 (all rows).
/// An absent index or invalid query returns zero. Result storage is borrowed.
///
/// # Safety
/// A non-null index must be a live pointer from SearchIndex::into_handle. The
/// caller serializes queries on each handle and copies returned rows before its
/// next query or drop. query must be a valid NUL-terminated buffer and count a
/// writable isize when non-null.
pub unsafe extern "C" fn query_index(
    index: *mut std::ffi::c_void,
    query: *const std::ffi::c_char,
    count: *mut isize,
) -> *const usize {
    if count.is_null() {
        return std::ptr::null();
    }
    unsafe { *count = 0 };
    if index.is_null() || query.is_null() {
        return std::ptr::null();
    }
    let result = std::panic::catch_unwind(|| {
        let Ok(text) = unsafe { std::ffi::CStr::from_ptr(query) }.to_str() else {
            return (0, std::ptr::null());
        };
        let index = unsafe { &mut *index.cast::<SearchIndex>() };
        match index.matching_rows(text) {
            None => (-1, std::ptr::null()),
            Some([]) => (0, std::ptr::null()),
            Some(rows) => (rows.len() as isize, rows.as_ptr()),
        }
    })
    .unwrap_or((0, std::ptr::null()));
    unsafe { *count = result.0 };
    result.1
}

/// Release an independently owned native index. A null handle is ignored.
///
/// # Safety
/// A non-null handle must come from SearchIndex::into_handle and have exactly
/// one owner. Returned row pointers and the handle expire at this call.
pub unsafe extern "C" fn drop_index(index: *mut std::ffi::c_void) {
    if !index.is_null() {
        unsafe {
            drop(Box::from_raw(index.cast::<SearchIndex>()));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_search_handles_are_independent_and_validate_inputs() {
        use std::ffi::{CString, c_char, c_void};
        use std::ptr::{null, null_mut};
        fn query(handle: *mut c_void, text: *const c_char) -> (isize, Vec<usize>) {
            let mut count = 99;
            let result = unsafe { query_index(handle, text, &mut count) };
            let hits = if count > 0 {
                unsafe { std::slice::from_raw_parts(result, count as usize).to_vec() }
            } else {
                assert!(result.is_null());
                Vec::new()
            };
            (count, hits)
        }
        let mut old = SearchIndex::default();
        for name in ["Notes", "Café 2.png", "Café 12.svg"] {
            old.push_name(name);
        }
        let mut new = SearchIndex::default();
        new.push_name("Café 23.png");
        let old = old.into_handle();
        let new = new.into_handle();
        let cafe = CString::new("Cafe\u{301}").unwrap();
        assert_eq!(query(new, cafe.as_ptr()), (1, vec![0]));
        assert_eq!(query(old, cafe.as_ptr()), (2, vec![1, 2]));
        assert_eq!(query(old, c"cafe 2.png".as_ptr()), (1, vec![1]));
        assert_eq!(query(old, c"not here".as_ptr()), (0, vec![]));
        assert_eq!(query(old, c" \t ".as_ptr()), (-1, vec![]));
        assert_eq!(query(old, null()), (0, vec![]));
        assert_eq!(query(null_mut(), c"".as_ptr()), (0, vec![]));
        assert_eq!(query(old, [0xffu8, 0].as_ptr().cast()), (0, vec![]));
        assert!(unsafe { query_index(old, cafe.as_ptr(), null_mut()) }.is_null());
        unsafe {
            drop_index(old);
            drop_index(null_mut());
        }
        assert_eq!(query(new, c"23".as_ptr()), (1, vec![0]));
        unsafe {
            drop_index(new);
        }
    }
    #[test]
    fn restores_each_visit_independently_and_discards_forward_branch() {
        let mut n = Navigation::default();
        n.handle(&json!({"op":"visit","key":"one"}));
        n.handle(&json!({"op":"visit","key":"two","state":{"selected":["x","y"],"scroll":221.25}}));
        let old = n.handle(&json!({"op":"back","state":{"selected":["z"]}}));
        assert_eq!(old["state"]["scroll"], 221.25);
        assert_eq!(old["state"]["selected"], json!(["x", "y"]));
        assert_eq!(
            n.handle(&json!({"op":"forward"}))["state"]["selected"],
            json!(["z"])
        );
        n.handle(&json!({"op":"back"}));
        let branch = n.handle(&json!({"op":"visit","key":"three"}));
        assert_eq!(branch["forward"], false);
    }
    #[test]
    fn moved_folder_preserves_nested_visits_and_selected_paths() {
        let mut nav = Navigation::default();
        nav.handle(&json!({"op":"visit","key":"/project/exports"}));
        nav.handle(&json!({"op":"visit","key":"/project","state":{
            "scroll":90,"anchorPath":"/project/exports/plate.png",
            "selected":["/project/exports/plate.svg"],
            "beforeFilter":{"anchorPath":"/project/exports/notes.txt"}
        }}));
        nav.handle(&json!({"op":"remap","changes":{"/project/exports":"/project/ready"}}));
        let previous = nav.handle(&json!({"op":"back"}));
        assert_eq!(previous["key"], "/project/ready");
        assert_eq!(
            previous["state"]["selected"],
            json!(["/project/ready/plate.svg"])
        );
        assert_eq!(previous["state"]["scroll"], 90);
        assert_eq!(previous["state"]["anchorPath"], "/project/ready/plate.png");
        assert_eq!(
            previous["state"]["beforeFilter"]["anchorPath"],
            "/project/ready/notes.txt"
        );
    }

    #[test]
    fn full_selection_follows_ancestors_and_members_moved_out_and_back() {
        let mut nav = Navigation::default();
        nav.handle(&json!({"op":"visit","key":"/studio/exports"}));
        nav.handle(&json!({"op":"visit","key":"/studio/exports/child","state":{
            "beforeFilter":{"selected":{"folder":"/studio/exports","names":"ink.svg\0proof\n2.png\0child"}}
        }}));
        nav.handle(&json!({"op":"remap","changes":{
            "/studio/exports":"/press/final",
            "/studio/exports/ink.svg":"/press/final/new ink.svg",
            "/studio/exports/proof\n2.png":"/delivery/proof.png"
        }}));
        let back = nav.handle(&json!({"op":"back"}));
        assert_eq!(back["key"], "/press/final");
        assert_eq!(
            back["state"]["beforeFilter"]["selected"],
            json!({
                "folder":"/press/final","names":"new ink.svg\0/delivery/proof.png\0child"
            })
        );
        let again = nav.handle(&json!({"op":"remap","changes":{"/delivery":"/press/final"}}));
        assert_eq!(
            again["state"]["beforeFilter"]["selected"]["names"],
            "new ink.svg\0proof.png\0child"
        );
    }

    #[test]
    fn search_accepts_unaccented_and_decomposed_filename_queries() {
        let mut index = SearchIndex::default();
        index.install(&json!(["Résumé – Étude finale.txt", "readme.md"]));
        assert_eq!(index.find("resume etude")["rows"], json!([0]));
        assert_eq!(index.find("Re\u{301}sume\u{301}")["rows"], json!([0]));
    }

    #[test]
    fn incremental_search_can_broaden_and_replace_query() {
        let mut i = SearchIndex::default();
        i.install(&json!(["proof-1.PNG", "proof-2.SVG", "old.png"]));
        assert_eq!(i.find("proof")["rows"], json!([0, 1]));
        assert_eq!(i.find("proof PNG")["rows"], json!([0]));
        assert_eq!(i.find("png")["rows"], json!([0, 2]));
        assert_eq!(i.find("")["all"], true);
    }
}
