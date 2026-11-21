#!/usr/bin/env python3
"""Measure warmed local Rust directory reads including its stdio transport.

Run after cargo build --release. Give --folder PATH to reuse an existing
fixture. The default makes and removes its own 10,000-entry directory. Results
include response serialization and pipe transfer, ending before Python parsing.

For an apples-to-apples before/after comparison in the Rust library, run

    cargo test --locked --release --lib compare_filesystem_scans -- --ignored --nocapture

That check runs the original directory/metadata scan and the optimized Darwin
bulk scan on the same generated 10,000 filenames. Each timing includes JSON
serialization. It discards the first iteration and reports 25 warmed samples.

On the Apple M4 Pro Mac mini, macOS 26.5.2, on 2026-11-20, the full-folder
medians were 24.30 ms and 7.84 ms (p95 27.41 ms and 8.28 ms). For an eight-row
sorted preview prefix they were 22.64 ms and 5.19 ms (p95 24.47 ms and 6.55 ms).
The GUI trace measures additional work through AppKit table layout.
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile
import time


def measure(folder, executable, samples):
    process = subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        cases = [
            ("open", {}),
            ("preview (8 rows)", {"limit": 8}),
            ("folder preview (32 + media)", {"op": "preview"}),
            ("search (unique substring)", {"query": "9987"}),
        ]
        for label, arguments in cases:
            timings = []
            size = rows = 0
            for index in range(samples + 1):
                message = {"id": index, "op": "list", "path": str(folder), **arguments}
                start = time.perf_counter_ns()
                process.stdin.write(json.dumps(message).encode("utf-8") + b"\n")
                process.stdin.flush()
                wire = process.stdout.readline()
                elapsed = (time.perf_counter_ns() - start) / 1e6
                response = json.loads(wire)
                if not response["ok"]:
                    raise RuntimeError(response)
                size = len(wire)
                rows = len(response["entries"])
                if index:
                    timings.append(elapsed)
            ordered = sorted(timings)
            p95 = ordered[max(0, (95 * samples + 99) // 100 - 1)]
            print(f"{label:30} median {statistics.median(timings):7.2f} ms   "
                  f"p95 {p95:7.2f} ms   {rows:>5} rows   {size:>8} bytes")
    finally:
        process.stdin.close()
        process.wait(timeout=5)


def populate(folder):
    for n in range(10_000):
        path = folder / f"frame-{n:05}.png"
        path.touch()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--folder", type=Path)
    parser.add_argument("--bin", type=Path, default=Path("target/release/finger-core"))
    parser.add_argument("--samples", type=int, default=15)
    args = parser.parse_args()
    if args.folder:
        measure(args.folder.resolve(), args.bin.resolve(), args.samples)
    else:
        with tempfile.TemporaryDirectory(prefix="finger-10k-") as created:
            folder = Path(created)
            populate(folder)
            measure(folder, args.bin.resolve(), args.samples)
