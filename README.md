# Finger

Finger opens to a native Mac worktable with visual previews of files from your current project. It uses recent activity, matching sources and exports, and changes since your previous visit to decide what to show. Select a file to preview it or bring it into Codex.

![Finger’s Worktable showing the Fold Studies project and its Overlap artwork](docs/Worktable.png)

## Launch

Open **build/Finger.app**. Choose **Change project** to use your own folder. **Browse folders** (**⌘2**) opens the file browser, and **Worktable** (**⌘1**) brings you back.

```sh
open build/Finger.app
```

You can also drop a folder onto the app icon, or open a group of files with `open -a /path/to/Finger.app`. Files from one folder arrive selected together. Files from different folders open as a collection.

## A one-minute practice run

**File → Open Practice Project** opens a fresh, writable copy of **Fold Studies** on the Worktable.

1. Find **Overlap 01**. Its card pairs the PNG export with the editable SVG. Type **Overlap 01** to narrow the worktable to that study.
2. Click **PNG**, then **Preview** or **Space**. Press **Escape** to close Quick Look. Click **SVG** to select the source on its own.
3. Click the card to select both files, then choose **Hand to Codex**. A new Codex draft contains both paths, ready for your instructions. If the desktop app is unavailable, Finger copies the selection for you to paste.
4. Choose **Browse folders** to explore the project. Open **exports** to see the original files, or **exports-old** for the earlier blue print. Press **⌘1** to return to the Worktable.

## Folder browsing and file operations

Select a folder to see a contact sheet and filenames. Press **→** to enter it, or click a thumbnail to enter with that file selected. In the practice project, you can Command-click the PNG and SVG in **exports**, choose **Move…**, then choose **delivery**. **Edit → Undo Move** puts them back.

![Finger browsing the Fold Studies practice project, with exports selected and its artwork visible](docs/Finger.png)

| Action | Shortcut |
| --- | --- |
| Select, extend a range, select discontiguous rows | ↑ / ↓, Shift–arrow, Command–click |
| Enter a folder, visit its parent | →, ← |
| Open in the default app | Return or double-click |
| Back, Forward | ⌘[, ⌘] or horizontal trackpad swipe |
| Filter the current folder by name | Type, or ⌘F |
| Clear the filter and restore the earlier selection | Escape |
| Find a filename in subfolders | ⇧⌘F |
| Quick Look, then browse adjacent items | Space, then ↑ / ↓ |
| New folder, rename | ⇧⌘N, F2 or ⌘Return |
| Copy or move to a chosen folder | ⇧⌘C, ⇧⌘M |
| Copy, cut, paste files | ⌘C, ⌘X, ⌘V |
| Move copied files here | ⌥⌘V |
| Undo or redo a move or rename | ⌘Z, ⇧⌘Z |
| Show hidden files, refresh | ⇧⌘., ⌘R |

Drag a file onto a folder row or sidebar location to move it inside Finger. Hold Option to copy. Drag the divider to change how much room filenames and previews receive. The sidebar becomes a locations menu in narrow windows. Click a breadcrumb to visit an ancestor.

With several files selected, **Space** opens Quick Look and **↑ / ↓** walks just those files. **Escape** leaves the whole group selected for a move or copy.

A folder preview stays current when an exporter writes new files into it. Drag a preview thumbnail or filename straight onto a neighboring folder, or click it to enter with that item selected. The list header and **View → Sort By** offer name, modification date and size in either direction. The folder preview follows the same order. Collections keep their saved order.

Move and Copy suggest real folders in the current project first. **Keep Both** creates a unique name for the incoming item. Each successful move or rename has an in-session undo receipt. Finger checks the live item before applying it and reports conflicts. Quick Look, folder browsing, filename search and local destination suggestions work offline.

## Agent collections

Each build configures Codex and Claude Code for this checkout. Select files on the Worktable or in the file browser and ask the connected agent to make a named collection from the selection. Collections open in the same window. Each row shows its original folder so identically named files are distinguishable. Right-click a collection to rename or remove it.

**Help → Agent Connection** gives registration commands for the running bundle. The connection guide includes exact project settings, setup from other directories, Claude Desktop instructions and verification results. [Agent connection guide](docs/AGENTS-CONNECTION.md)

## Optional Jev ranking

When the app process has a TypeSafe credential in `FINGER_JEV_API_KEY` or `TYPESAFE_API_KEY`, **Rank with Jev** appears in the destination sheet. Clicking it sends selected basenames and candidate folder names to TypeSafe. You choose and confirm the destination. File contents and absolute paths stay local. To start Finger with that environment, quit any open copy and run the executable from your configured shell.

```sh
./build/Finger.app/Contents/MacOS/Finger
```

## Build and package

The source build uses a stable Rust toolchain with Cargo, Xcode command-line tools with a macOS SDK, and Python 3 for assembly. This checkout includes a project-local build toolchain under `build/toolchain` that the build script discovers when Cargo is absent from PATH. A clean checkout can use Rust from [rustup](https://rustup.rs/).

From the project folder:

```sh
./scripts/build.sh
open build/Finger.app
```

`Cargo.lock` pins the Rust dependencies. The Swift AppKit adapter uses system frameworks. The resulting bundle contains the Rust executable, native interface library, practice artwork, icon and MCP bridge. Running it requires no compiler, account or separately installed service.

The release was built with Rust/Cargo 1.100.0 and Apple Swift 6.3.3 using the macOS 26.5 SDK. The deployment target is macOS 14.0.

```sh
./scripts/package.sh
```

The packaging script verifies the ad-hoc signature, extracts the archive, and verifies the extracted app. It writes **build/Finger-macOS-arm64.zip** on Apple silicon. This build targets macOS 14 or later and was exercised on Apple silicon with macOS 26.5.2. Public notarization and Intel runtime testing are outside this local build.

## Reproduce the checks

Run the checks from a logged-in macOS desktop. The script builds the app, exercises the Rust filesystem engine, checks the native Find sheet and destination ranker, tests the MCP bridge, and runs the native window against 10,000 real entries.

```sh
./scripts/check.sh
```

For detailed filesystem and whole-window performance measurements, run the following after the checks.

```sh
source scripts/rust-env.sh
python3 tests/benchmark_core.py
python3 tests/gui-bench/run.py --entries 10000 100000 --samples 9 --compare --compare-index --profile
```

The GUI benchmark opens a separate AppKit window with isolated preferences and creates its own real mixed-file directories. The cross-volume suite creates temporary APFS and exFAT disk images, exercises transfers and recovery, and ejects the images.

```sh
python3 tests/cross_volume.py
python3 tests/gui-bench/run.py --volume-recovery
python3 -B tests/termination/run.py
```

The termination suite requests Quit while a real copy is in flight and verifies the published files after the app exits. It also exercises a collision that needs a decision before quitting.

The performance report records the hardware, data, measurement boundary and before/after timings. [Performance measurements](docs/PERFORMANCE.md)

The build report includes the delivery paths, one-minute practice run, verification results and remaining limits. [Build report](docs/BUILD-REPORT.md)
