// A release-only diagnostic for directory open. All durations end inside Rust.
// Each record, decode, and assembled read is a separate pass over the same
// warmed directory. Paired differences estimate decode and allocation costs.
use super::*;
use crate::navigation::SearchIndex;
use std::{
    hint::black_box,
    time::{Duration, Instant},
};

fn measure<T>(f: impl FnOnce() -> T) -> (T, f64) {
    let start = Instant::now();
    let value = f();
    (value, start.elapsed().as_secs_f64() * 1000.0)
}

fn report(label: &str, values: &mut [f64]) {
    values.sort_by(f64::total_cmp);
    let median = (values[(values.len() - 1) / 2] + values[values.len() / 2]) / 2.0;
    println!(
        "{label:43} median {:7.2} ms   p95 {:7.2}",
        median,
        values[(values.len() * 95).div_ceil(100) - 1]
    );
}

fn emit_and_fold(root: &Path) -> usize {
    let mut rows = 0;
    let mut index = SearchIndex::default();
    let warnings = visit_entries_sorted(
        root,
        false,
        SortOrder::NameAsc,
        |name, kind, directory, size, modified| {
            index.push_name(name);
            black_box((name, kind, directory, size, modified));
            rows += 1;
        },
    )
    .unwrap();
    assert!(warnings.is_empty());
    black_box(index);
    rows
}

fn original_name_order(a: &Entry, b: &Entry) -> Ordering {
    b.is_directory
        .cmp(&a.is_directory)
        .then_with(|| natural_cmp(&a.sort_key, &b.sort_key))
        .then_with(|| a.name.cmp(&b.name))
}

struct Own(PathBuf);
impl Drop for Own {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
#[ignore = "release profile; creates 100,000 disposable entries"]
fn profile_mixed_directory() {
    let generated = std::env::temp_dir().join(format!("finger-open-phases-{}", std::process::id()));
    let mut owner = None;
    let root = std::env::var_os("FINGER_PROFILE_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            fs::create_dir(&generated).unwrap();
            owner = Some(Own(generated.clone()));
            let families = [
                ("brief", "md"),
                ("plate", "png"),
                ("palette", "json"),
                ("source", "rs"),
                ("measure", "csv"),
                ("plate", "svg"),
                ("notes", "txt"),
            ];
            for i in 0..100_000 {
                if i % 100 == 0 {
                    fs::create_dir(generated.join(format!("folder-{i:06}"))).unwrap();
                } else {
                    let (stem, ext) = families[i % families.len()];
                    fs::write(
                        generated.join(format!("{stem}-{i:06}.{ext}")),
                        ext.as_bytes(),
                    )
                    .unwrap();
                }
            }
            generated
        });
    let mut stages: [Vec<f64>; 10] = Default::default();
    for i in 0..12 {
        let (_, records) = measure(|| {
            crate::bulk::records(&root, &|| false, |r| {
                black_box(r);
                Ok(())
            })
            .unwrap()
        });
        let (_, decoded) = measure(|| {
            crate::bulk::visit(&root, &|| false, |r| {
                black_box((r.name, r.kind, r.hidden, r.size, r.modified));
            })
            .unwrap()
        });
        let (mut rows, assembled) =
            measure(|| bulk_entries(&root, false, None, &|| false).unwrap());
        assert_eq!(rows.len(), 100_000);
        let mut original = rows.clone();
        let (_, old_ordered) = measure(|| original.sort_unstable_by(original_name_order));
        let (_, ordered) =
            measure(|| rows.sort_unstable_by(|a, b| SortOrder::NameAsc.compare(a, b)));
        assert!(original.iter().zip(&rows).all(|(a, b)| a.name == b.name));
        drop(original);
        let (_, emitted) = measure(|| {
            for row in &rows {
                black_box((
                    &row.name,
                    row.kind,
                    row.is_directory,
                    row.size,
                    row.modified,
                ));
            }
        });
        let (index, folded) = measure(|| {
            let mut index = SearchIndex::default();
            for row in &rows {
                index.push_name(&row.name);
            }
            index
        });
        let (_, freed) = measure(|| drop((rows, index)));
        let (_, full) = measure(|| assert_eq!(emit_and_fold(&root), 100_000));
        if i > 0 {
            for (stage, sample) in stages.iter_mut().zip([
                records,
                decoded - records,
                assembled - decoded,
                assembled,
                old_ordered,
                ordered,
                emitted,
                folded,
                freed,
                full,
            ]) {
                stage.push(sample);
            }
        }
    }
    let labels = [
        "getattrlistbulk + record boundaries",
        "decode metadata (paired difference)",
        "construct Entry records (paired difference)",
        "all reads + assembled Entry records",
        "original natural sort",
        "width-aware natural sort",
        "typed emission loop (no Swift)",
        "fold into SearchIndex",
        "drop records and index",
        "whole typed visit + index + cleanup",
    ];
    for (label, timings) in labels.iter().zip(&mut stages) {
        report(label, timings);
    }

    let mut burst_times: [Vec<f64>; 2] = Default::default();
    for sample in 0..8 {
        for j in 0..2 {
            let i = (sample + j) % 2;
            let (counts, ms) = measure(|| burst(&root, i == 1));
            assert_eq!(*counts.last().unwrap(), 100_000);
            if sample == 0 {
                println!(
                    "Burst at 5 ms intervals, cancel {}: emitted {counts:?} rows",
                    i == 1
                );
            } else {
                burst_times[i].push(ms);
            }
        }
    }
    for (label, samples) in [
        "three visits, no cancellation",
        "three visits, cancellation",
    ]
    .iter()
    .zip(&mut burst_times)
    {
        report(label, samples);
    }
    drop(owner);
}

fn burst(root: &Path, cancel_previous: bool) -> Vec<usize> {
    std::thread::scope(|pool| {
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        };
        let mut tasks = Vec::new();
        let mut previous: Option<Arc<AtomicBool>> = None;
        for _ in 0..3 {
            if cancel_previous {
                if let Some(flag) = &previous {
                    flag.store(true, Ordering::Release);
                }
            }
            let token = Arc::new(AtomicBool::new(false));
            previous = Some(token.clone());
            let path = root;
            tasks.push(pool.spawn(move || {
                let mut count = 0;
                let mut index = SearchIndex::default();
                let result = visit_entries_cancellable(
                    path,
                    false,
                    SortOrder::NameAsc,
                    &|| token.load(Ordering::Acquire),
                    |name, kind, dir, size, modified| {
                        index.push_name(name);
                        black_box((kind, dir, size, modified));
                        count += 1;
                    },
                );
                if token.load(Ordering::Acquire) {
                    assert!(result.is_err());
                } else {
                    result.unwrap();
                }
                black_box(index);
                count
            }));
            std::thread::sleep(Duration::from_millis(5));
        }
        tasks
            .into_iter()
            .map(|t| t.join().unwrap())
            .collect::<Vec<_>>()
    })
}
