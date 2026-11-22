# Performance

These measurements cover the file browser window, taken on an Apple M4 Pro with 48 GiB RAM and macOS 26.5.2. The release-mode GUI benchmark uses Finger’s production Rust launcher, search index, AppKit window, table and text editor. Each run creates real folders and mixed PNG, SVG, text, JSON, CSV and Rust files. The window has isolated preferences and stays offscreen.

## Whole-window results

Each cell gives the warm median and p95 in milliseconds across nine runs. With nine samples, the nearest-rank p95 is the slowest sample. Folder entry includes reading files, installing the index, selecting rows and painting the table viewport. Search starts with a native text edit and ends at the same paint boundary.

| Visible entries | Open folder | Broad search | Exact filename | Clear filter |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 48.08 / 64.26 | 24.10 / 26.52 | 15.26 / 16.17 | 17.38 / 17.99 |
| 100,000 | 201.65 / 229.08 | 16.90 / 32.34 | 12.41 / 15.48 | 22.18 / 33.35 |

The broad query returned 2,828 and 28,286 rows. The harness verified the filenames of materialized rows and the selected search match. Going back restored both selected paths and exact table offsets of 389,525 and 3,899,525 points.

A subsequent nine-run release check measured **48.13 / 50.52 ms** median/p95 to open 10,000 files and **195.07 / 206.87 ms** to open 100,000. One-match search measured **14.49 / 15.86 ms** and **14.15 / 15.56 ms** respectively. The paired JSON baseline measured **63.70 / 67.30 ms** and **382.69 / 396.40 ms** for folder opening.

## Folder opening

The original interface encoded the complete listing as JSON. The desktop app now receives sorted entries through a typed callback from Rust. The same optimized benchmark binary exercised both paths in separate processes on the same fixtures.

| Entries | JSON first | Typed first | JSON warm median / p95 | Typed warm median / p95 |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 63.50 | 51.00 | 65.41 / 67.88 | 48.08 / 64.26 |
| 100,000 | 371.96 | 179.78 | 377.79 / 394.15 | 201.65 / 229.08 |

The first pass is the first visit to the large folder in that process. Creating the fixture warmed the filesystem cache. The warm median fell 26% at 10,000 entries and 47% at 100,000. A third run kept the typed rows and installed their search index through JSON. Its warm open medians were 48.48 and 194.60 ms. The shipping implementation builds the index on the listing worker so canceled opens cannot overwrite the current folder’s index.

An earlier full-window baseline recorded first opens of 56.46 and 381.98 ms. Its warm open medians/p95s were 55.54/56.87 and 383.41/413.56 ms. One-match searches took 14.45/15.58 and 14.48/16.49 ms. The paired comparison above controls for other app changes between builds.

### Rust enumeration and superseded opens

An independent release profile used a real APFS directory with 100,000 mixed entries. The complete Rust read, sort, callback loop, search index and cleanup took **181.82 ms median** over 11 warm samples. Metadata decoding and record construction below are estimates from paired reads of the same directory. Each table row has its own median.

| Stage | Median (ms) |
| --- | ---: |
| `getattrlistbulk` and record boundaries | 143.49 |
| Decode metadata | 0.55 |
| Construct row records | 12.42 |
| Natural sort, original / optimized | 27.24 / 13.77 |
| Typed callback loop inside Rust | 0.17 |
| Fold names into the search index | 1.72 |
| Release records and index | 8.10 |

Equal-width digit runs can use bytewise comparison and retain natural filename order. The profile compared every resulting row with the original comparator. Three visits issued 5 ms apart took **370.21 ms** median across seven warm trials. Canceling superseded reads reduced that to **198.14 ms**. The two abandoned visits each emitted zero rows. An outstanding filesystem call must return before its worker can observe cancellation.

This command creates and removes its own 100,000-entry fixture.

```sh
cargo test --locked --release --lib profile_mixed_directory -- --ignored --nocapture
```

## Drawing and inspection

At 100,000 entries the native edit produced a one-row result in 3.51 ms median. Layout took 0.67 ms, viewport drawing 0.96 ms and the Core Animation transaction flush 7.03 ms. Repainting the same unchanged viewport took 0.78 ms. The benchmark forces a real AppKit bitmap paint before recording completion.

On a separate 10,000-entry fixture, selecting a folder and laying out its 32 inspector rows took 34.86 ms median with the initial directory reader. Sharing Rust enumeration with the main list brought this to 26.14 ms. Reusing native row controls brought it to 17.03 ms.

The artwork stress test selected folders containing three 6,400 × 3,600 PNGs, then selected a small text file 25 ms into decoding. Nine trials took 71.98 ms median and 85.06 ms p95 to show the text. Giving inspector reads their own queue brought this to 6.61 and 18.75 ms. All three images appeared in 103 ms on the first folder. Every card and child row kept its original frame.

In another test, each of two sibling folders contained 100,000 files. Selecting each folder 18 ms apart and then selecting a text file took 116.21 ms median and 123.17 ms p95 to show the text. Canceling superseded folder scans between Rust directory batches reduced this to 4.93 and 11.23 ms on the same fixture over nine warm trials.

## Memory during navigation

In a separate visible window, a print job published 9,484 pages over eleven minutes in a directory that started with 10,404 entries. It retained the newest 300 pages. The first watcher waited for the writer to stop. The revised watcher showed an update after 183 ms in the native regression, then coalesced continuous changes to at most two full listings per second. Across matched 120-second samples with the same PNG selected, Finger used 24.34 CPU seconds before this final pacing and 15.17 after. During the longer run, filtering and clearing restored the PNG/SVG pair, a new earlier filename left the SVG open in Quick Look, highlighted text stayed selected in the inspector, and Move/Undo preserved both graphics byte for byte.

With two text files selected on a mounted APFS volume, the visible release app used 0.01 seconds of process CPU over 60.02 stationary seconds. Resident memory sampled at 0, 30 and 60 seconds was 147, 143 and 143 MiB.

The first paced run completed 80 cycles before allocation profiling identified a row-view retention problem. Two heap snapshots of the same process showed the number of file row views climbing from 882 to 2,754. Opening and filtering folders allocated new row views while AppKit held previous ones in its reuse pool. Both the browser and Find now request existing row views by identifier. In the paired build, the corresponding snapshots showed 183 and 207 file rows, exactly matching the reusable cells. After 60 accelerated cycles, live heap fell from 87.3 to 61.6 MiB with the same fixture and test.

In one offscreen run AppKit deferred animation completions and retained 134 image overlays. Finger now discards a previous transition on entry and clears the current image after 350 ms if the usual completion has not arrived. Each endurance cycle checks that the overlay has disappeared and the table still uses a reusable row.

Allocation stacks also showed the sidebar and breadcrumbs rebuilding controls during navigation. Reusing sidebar links and three breadcrumb buttons cut growth in live allocations over 70 accelerated cycles from 150,977 to 60,950 blocks. The final live heap dropped from 47.59 to 43.26 MiB in the same instrumented fixture.

### Paced endurance

Three release-mode binaries ran in separate offscreen windows with real 10,000-entry directories. All three ran concurrently for 51 minutes. Across 1,446 cycles, all search, preview, resize, selection, scroll and history checks passed. Finger observed all 4,338 external creates, renames and removals.

| Snapshot | Duration | Cycles | Live heap start / middle / end (MiB) | Heap range (MiB) | Resident memory start / middle / end (MiB) | Peak RSS (MiB) | Peak file descriptors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Row reuse, `7cc7414c` | 105 min | 573 | 39.6 / 64.9 / 90.5 | 37.6–91.5 | 155.5 / 172.3 / 192.2 | 202.0 | 5 |
| Sidebar and breadcrumb reuse, `9120b989` | 90 min | 491 | 44.5 / 52.7 / 64.0 | 42.7–65.0 | 199.9 / 165.6 / 192.8 | 215.3 | 10 |
| Shipping candidate, `db7d6cde` | 70 min | 382 | 44.7 / 51.0 / 61.3 | 42.8–62.3 | 195.9 / 167.6 / 202.25 | 213.7 | 10 |

Start, middle and end are medians of 12 cycles each. Descriptor counts stayed constant in all three processes. All three showed residual heap growth. In the first two, heap censuses traced most of that growth to AppKit observation records and their associated blocks. The test logger also retained roughly 4 KiB per cycle in these snapshots. Matched early and late censuses in the second run showed the same 10 table cells and rows, 32 inspector rows and 10 sidebar links. Its closing census found 348 detached transition views totaling 0.21 MiB. The app cleared their images and every cycle confirmed the overlay had left the window.

## Large selections

These are medians in milliseconds over three release-mode runs. Each run selected every row, requested one item through the stdio MCP bridge, filtered the list to two files, cleared the filter, entered a child folder, and went Back. UI timings include painting the visible table. A five-millisecond timer measured the longest gap in the main run loop during each MCP request.

| Selected items | Select All | Filter to two | Clear filter | Back | Fresh MCP page | Main-loop gap during MCP |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 5.2 | 18.3 | 19.0 | 45.3 | 25.9 | 5.8 |
| 100,000 | 5.7 | 22.4 | 20.4 | 238.1 | 213.1 | 6.0 |

At 100,000 items the earlier build took 90.0 ms for Select All, 130.4 ms to clear, and 394.3 ms to go Back. The inspector now receives a bounded sample. For large full-folder selections, history stores one parent path and the exact selected basenames. Both fixture sizes restored the original membership after a rename, a replacement and a new arrival.

MCP checks every selected file’s identity on a worker. The 100,000-item main-loop gap fell from 77.9 ms to 6.0 ms. The first snapshot added 5.4 MiB of live heap. Two subsequent snapshots of the same files each retained a distinct ID and showed less than 0.1 MiB of additional live heap. The earlier build added about 63 MiB per snapshot.

```sh
python3 tests/gui-bench/run.py --bulk-selection --entries 10000 100000 --samples 3
```

### Named collections

The installed Codex app-server requested one selection item, then sent the full selection to Finger as a named collection. Times below are single before-and-after runs in milliseconds with disposable files and private preferences. The callback runs on the main thread. “Rows ready” runs from callback entry until the complete ordered collection is available in the table. Relaunch listing starts when the fresh process opens its saved collection.

| Members | Main callback, before → after | Rows ready, before → after | Relaunch listing, before → after | Two Codex calls, before → after |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 16.9 → 11.0 | 174.4 → 42.4 | 191.4 → 93.4 | 92.9 → 81.8 |
| 100,000 | 157.5 → 22.1 | 1,728.8 → 305.8 | 1,525.6 → 287.3 | 735.5 → 494.7 |

At 10,000 items the revised `get_selection` took 50.1 ms and `show_collection` took 31.7 ms. An intermediate 100,000-item profile measured 72.4 ms encoding collection records and 13.4 ms writing preferences on the main thread. Finger now saves the same records on a serial worker, and Quit waits for the latest revision. Collection rows reuse checked paths and use a single filesystem metadata read for ordinary files and directories.

Fresh processes restored both collection IDs and every member in its original order from 21,719,098 bytes of preferences. In a separate immediate-Quit trial, two writes remained queued when AppKit began termination. The app waited 302 ms, including an 80 ms test delay, and a fresh process restored the additional 100,000-member collection from a combined 41,472,759-byte store.

```sh
python3 -B tests/collections/run.py
python3 -B tests/collections/run.py --profile-writes
```

### Choosing a Move destination

The table gives medians over five warm runs per case for both builds. Each disposable project had four sibling folders. Its `exports` folder contained distinct, empty `.png` and `.svg` files. `delivery`, `exports-old` and `references` were available destinations. The test invoked the real command, waited for the attached sheet to finish layout, checked its first destination and canceled. A two-millisecond main-loop timer measured the longest interval between callbacks. AppKit’s sheet-opening notification marked the end of preparation.

| Folder entries | Selected | Ready, original → revised (ms) | Longest main gap before sheet, original → revised (ms) | Longest main gap through layout, original → revised (ms) |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 2 | 312.1 → 297.4 | 27.6 → 26.2 | 299.8 → 297.4 |
| 10,000 | 10,000 | 455.2 → 328.7 | 22.7 → 22.6 | 298.8 → 306.4 |
| 100,000 | 2 | 398.4 → 313.3 | 25.7 → 27.6 | 295.9 → 313.3 |
| 100,000 | 100,000 | 1,935.4 → 460.1 | 72.4 → 26.4 | 302.5 → 297.9 |

At 100,000 selected files the command returned to AppKit in **0.05 ms**, down from **72.37 ms**. Folder suggestions reuse the loaded directory. Ranking reads up to 32 names while checking project membership and excluded destinations against the full selection. Finger captures each source’s identity before opening the sheet. A separate control measured **158 ms** to bind the 100,000 siblings through one directory descriptor. Presenting an already-built native Move sheet on the offscreen window took 279–297 ms in `beginSheet` with default animation behavior.

```sh
python3 tests/gui-bench/run.py --move-picker --entries 10000 100000 --samples 5
```

## Reproduce

Run from the project directory with Cargo and the Xcode command-line tools installed.

```sh
python3 tests/gui-bench/run.py --entries 10000 100000 --samples 9 --compare --compare-index --profile --capture /tmp/finger-demo.png
```

The PNG shows the demo project with **exports** selected. The fixture and benchmark bundle are removed on exit.

The endurance run exercises the same browser every 8–14 seconds. Each cycle resizes the window, checks a search and image preview, restores two selected rows and their scroll position, then verifies an external create, rename and removal through the directory watcher.

```sh
python3 tests/gui-bench/run.py --entries 10000 --samples 3 --soak-minutes 105 --soak-log /tmp/finger-endurance.jsonl
```

The JSON Lines log records per-cycle latency, resident memory, physical footprint, live heap, open file descriptors and five-minute summaries. A source fingerprint identifies the code compiled into the test process.
