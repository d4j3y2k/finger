//! Filesystem operations shared by the native window and the command-line harness.
mod bulk;
mod find;
mod listing;
pub mod navigation;
mod search_macos;
mod transfer;

pub use listing::{
    SortOrder, preview_json_cancellable, visit_entries, visit_entries_cancellable,
    visit_entries_sorted,
};
pub use search_macos::fold_search_text;

use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    io,
    path::{Path, PathBuf},
};

#[derive(Deserialize)]
struct Request {
    #[serde(default)]
    id: u64,
    #[serde(flatten)]
    operation: Operation,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
enum Operation {
    StartFind {
        path: PathBuf,
        #[serde(default, rename = "showHidden")]
        show_hidden: bool,
    },
    Find {
        session: String,
        query: String,
        limit: Option<usize>,
    },
    EndFind {
        session: String,
    },
    List {
        path: PathBuf,
        #[serde(default, rename = "showHidden")]
        show_hidden: bool,
        limit: Option<usize>,
        query: Option<String>,
        #[serde(default)]
        sort: SortOrder,
    },
    Restore {
        receipts: Vec<String>,
    },
    Preview {
        path: PathBuf,
        #[serde(default, rename = "showHidden")]
        show_hidden: bool,
        #[serde(default)]
        sort: SortOrder,
    },
    NewFolder {
        path: PathBuf,
        name: String,
    },
    Rename {
        path: PathBuf,
        name: String,
        #[serde(default, rename = "expectedSources")]
        expected: HashMap<PathBuf, String>,
    },
    Copy {
        sources: Vec<PathBuf>,
        destination: PathBuf,
        #[serde(default, rename = "expectedSources")]
        expected: HashMap<PathBuf, String>,
        #[serde(default)]
        collision: transfer::Collision,
    },
    Move {
        sources: Vec<PathBuf>,
        destination: PathBuf,
        #[serde(default, rename = "expectedSources")]
        expected: HashMap<PathBuf, String>,
        #[serde(default)]
        collision: transfer::Collision,
    },
}

#[derive(Serialize)]
struct Response<T> {
    id: u64,
    ok: bool,
    #[serde(flatten)]
    body: T,
}

#[derive(Serialize)]
struct NewPath {
    path: PathBuf,
}

#[derive(Serialize)]
struct ErrorBody {
    error: String,
}

fn encode<T: Serialize>(id: u64, body: T) -> io::Result<String> {
    Ok(serde_json::to_string(&Response { id, ok: true, body })?)
}

fn error(id: u64, message: String) -> String {
    serde_json::to_string(&Response {
        id,
        ok: false,
        body: ErrorBody { error: message },
    })
    .expect("an error message is JSON-serializable")
}

fn absolute(path: &Path) -> io::Result<&Path> {
    if !path.is_absolute()
        || path
            .components()
            .any(|part| part == std::path::Component::ParentDir)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Choose an absolute path without .. components.",
        ));
    }
    Ok(path)
}

fn valid_name(name: &str) -> io::Result<()> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\0') {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Enter a single filename without a slash.",
        ))
    } else {
        Ok(())
    }
}

fn name_error(err: io::Error, name: &str, parent: &Path) -> io::Error {
    if err.kind() == io::ErrorKind::AlreadyExists {
        return io::Error::new(
            err.kind(),
            format!(
                "“{name}” already exists in {}. Choose another name.",
                parent.display()
            ),
        );
    }
    err
}

fn run(request: Request) -> io::Result<String> {
    let id = request.id;
    match request.operation {
        Operation::StartFind { path, show_hidden } => encode(id, find::start(&path, show_hidden)?),
        Operation::Find {
            session,
            query,
            limit,
        } => find::query(id, &session, &query, limit),
        Operation::EndFind { session } => {
            find::end(&session);
            encode(id, serde_json::json!({}))
        }
        Operation::List {
            path,
            show_hidden,
            limit,
            query,
            sort,
        } => encode(
            id,
            listing::list(
                absolute(&path)?,
                show_hidden,
                limit,
                query.as_deref(),
                false,
                sort,
            )?,
        ),
        Operation::Restore { receipts } => encode(id, transfer::restore(&receipts)),
        Operation::Preview {
            path,
            show_hidden,
            sort,
        } => preview_json_cancellable(id, &path, show_hidden, sort, &|| false),
        Operation::NewFolder { path, name } => {
            valid_name(&name)?;
            let target = absolute(&path)?.join(&name);
            std::fs::create_dir(&target).map_err(|err| name_error(err, &name, &path))?;
            encode(id, NewPath { path: target })
        }
        Operation::Rename {
            path,
            name,
            expected,
        } => {
            valid_name(&name)?;
            absolute(&path)?;
            encode(
                id,
                transfer::rename(&path, &name, expected.get(&path).map(String::as_str))
                    .map_err(|err| name_error(err, &name, path.parent().unwrap_or(&path)))?,
            )
        }
        Operation::Copy {
            sources,
            destination,
            collision,
            expected,
        } => encode(
            id,
            transfer::batch(
                &sources,
                absolute(&destination)?,
                collision,
                false,
                &expected,
            )?,
        ),
        Operation::Move {
            sources,
            destination,
            collision,
            expected,
        } => encode(
            id,
            transfer::batch(
                &sources,
                absolute(&destination)?,
                collision,
                true,
                &expected,
            )?,
        ),
    }
}

/// Run a single JSON request. Each call owns its state and may run on any thread.
pub fn request_json(request: &str) -> String {
    let request: Request = match serde_json::from_str(request) {
        Ok(request) => request,
        Err(err) => {
            let id = serde_json::from_str::<serde_json::Value>(request)
                .ok()
                .and_then(|value| value["id"].as_u64())
                .unwrap_or(0);
            return error(id, format!("Invalid request: {err}"));
        }
    };
    let id = request.id;
    run(request).unwrap_or_else(|err| error(id, err.to_string()))
}
