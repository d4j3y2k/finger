# Finger 0.1.0

Open **`/Users/davidkim/Developer/finger/build/Finger.app`**. The portable copy is **`/Users/davidkim/Developer/finger/build/Finger-macOS-arm64.zip`**. Finger uses Rust for the executable, filesystem operations, search and history. The window uses AppKit and Quick Look.

## Try it in 60 seconds

1. Choose **File → Open Practice Project**. Press **↓** for the old blue print in **exports-old**, then **↑** for the vermilion print in **exports**.
2. Press **→**, **Space**, then **Escape** to inspect **Overlap 01.png**.
3. Press **Shift–Down** to add its SVG. Press **⇧⌘M**, then **Return** on **delivery**.
4. Press **←**. The original **exports** row is selected where you left it. Press **↑** to see both files in **delivery**. **⌘Z** moves them back.

With a pointer, click a contact-sheet thumbnail to enter at that file, Command-click its companion and click **Move…**. Each practice project is a fresh, writable copy.

## Verified on this Mac

- Back restored two selected files and their exact scroll position in a 10,000-entry folder. It also kept the same selected page in view after an exporter inserted twelve filenames above it.
- Across nine warm runs, opening 10,000 / 100,000 entries took **48 / 195 ms** median through table paint. Exact filename search took **14 / 14 ms**. The earlier JSON listing took **64 / 383 ms** in the same comparison. [Measurements and reproduction](PERFORMANCE.md)
- Hosted Codex CLI and Claude Code read the selected PNG/SVG and opened **Print delivery** and **Delivery pair** in this window. Each client read the resulting collection back. Both offline ranking and optional Jev selected **delivery** for the practice move. [Connection instructions and tested clients](AGENTS-CONNECTION.md)
- Verified new folders, rename, default-app opening, Quick Look, collisions and Undo/Redo. A 9,000-file copy matched byte for byte while browsing continued. On a mounted APFS image, moving the artwork through a collision, undoing it, and ejecting and remounting the volume preserved files and selections. exFAT and disk-full recovery also passed.
- Three overlapping endurance builds completed 1,446 cycles and observed 4,338 filesystem changes. File descriptor counts stayed constant. The 70-minute candidate’s live heap grew from 44.7 to 61.3 MiB. During a separate eleven-minute print run, Quick Look stayed on the selected SVG and a highlighted text passage survived new arrivals.

## Build and limits

Run `./scripts/build.sh` and `./scripts/package.sh` from the project root. The ZIP was extracted to a different directory, launched there and verified with its own MCP helper. The release is ad-hoc signed for Apple silicon, targets macOS 14+, and was tested on an M4 Pro with macOS 26.5.2. Physical multitouch and the separate Claude Desktop client remain unverified. Native drag/drop and swipe tests passed. [Build instructions](../README.md#build-and-package)

The requested window began at 2:54 p.m. EST on November 20. The app, ZIP, live client tests and endurance runs landed within three hours. A stalled window-control session delayed final packaging and handoff until November 21.
