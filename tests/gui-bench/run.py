#!/usr/bin/env python3
"""Build an isolated release-mode Finger benchmark and exercise a real AppKit window."""
import argparse
from contextlib import ExitStack
import hashlib
import math
import os
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

ROOT = Path(__file__).resolve().parents[2]


def rgb_png(width, height, compressed):
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", compressed) + chunk(b"IEND", b""))


def artwork_fixture(root):
    width, height = 6400, 3600
    folders = [root / f"Exports {i}" for i in range(10)]
    for folder in folders:
        folder.mkdir(parents=True)
    (root / "Notes.txt").write_text("Small local text after a busy image preview.")
    for panel in range(3):
        rows = []
        for band in range(13):
            row = bytearray([0])
            for x in range(width):
                row.extend(((x // 41 + band * 3 + panel * 17) % 256, (x // 71 + band * 7) % 256, 180 + band + panel))
            rows.append(row)
        encoder = zlib.compressobj(level=1)
        data = b"".join(encoder.compress(rows[y % len(rows)]) for y in range(height)) + encoder.flush()
        original = folders[0] / f"Panel-{panel + 1}.png"
        original.write_bytes(rgb_png(width, height, data))
        for folder in folders[1:]:
            os.link(original, folder / original.name)


def fixture(root, count):
    root.mkdir(parents=True)
    art = rgb_png(2, 2, zlib.compress((b"\0" + b"\xd5\xf5\x81" * 2) * 2))
    svg = b'<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><circle cx="16" cy="16" r="15" fill="coral"/></svg>'
    entries = [("brief", "md", b"# Printing notes\nUse the current approved edition.\n"),
               ("plate", "png", art), ("palette", "json", b'{"paper":"ivory","ink":"black"}'),
               ("source", "rs", b"fn main() {}\n"), ("measure", "csv", b"width,height\n720,540\n"),
               ("plate", "svg", svg), ("notes", "txt", b"Printer calibration targets\n")]
    (root / "000-open-me" / "next" / "empty").mkdir(parents=True)
    (root / "zzzz-proof-final.png").write_bytes(art)
    (root / "zzzz-proof-final.svg").write_bytes(svg)
    for i in range(count - 3):
        if i % 100 == 0:
            (root / f"folder-{i:06d}").mkdir()
        else:
            family, ext, data = entries[i % len(entries)]
            (root / f"{family}-{i:06d}.{ext}").write_bytes(data)


def build(work, bulk_selection=False, delegate_driver=None):
    bundle = work / "FingerGUIBench.app" / "Contents"
    framework = bundle / "Frameworks"
    macos = bundle / "MacOS"
    framework.mkdir(parents=True)
    macos.mkdir()
    identifier = "local.finger.gui-bench." + uuid.uuid4().hex
    (bundle / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleName": "Finger GUI Bench",
        "CFBundleExecutable": "FingerGUIBench", "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "LSUIElement": True, "NSHighResolutionCapable": True,
    }))
    swift_files = sorted(x for x in (ROOT / "native").glob("*.swift") if x.name != "Main.swift")
    swift_files += [ROOT / "bridge" / n for n in ["AgentWire.swift", "AppEndpoint.swift"]]
    if delegate_driver:
        swift_files.append(delegate_driver)
    else:
        swift_files.extend(sorted(Path(__file__).resolve().parent.glob("*.swift")))
    # Keep a long-running test pinned to the bytes it compiled, even when
    # development continues in the original checkout during the build.
    source = work / "source"
    digest = hashlib.sha256()
    inputs = swift_files + list((ROOT / "rust").rglob("*.rs")) + [ROOT / "Cargo.toml", ROOT / "Cargo.lock"]
    for path in sorted(inputs):
        relative = path.relative_to(ROOT)
        target_file = source / relative
        target_file.parent.mkdir(parents=True, exist_ok=True)
        data = path.read_bytes()
        target_file.write_bytes(data)
        digest.update(str(relative).encode("utf-8") + b"\0" + data + b"\0")
    if delegate_driver:
        # Put the test in the same source file as the private production app
        # delegate. The driver supplies the C entry point and isolated launch.
        target_file = source / delegate_driver.relative_to(ROOT)
        main = (ROOT / "native" / "Main.swift").read_bytes()
        original = b'@_cdecl("finger_run")'
        if main.count(original) != 1:
            raise RuntimeError("Could not isolate the application delegate")
        digest.update(main)
        target_file.write_bytes(main.replace(original, b'@_cdecl("finger_standard_run")') + b"\n" + target_file.read_bytes())
    swift = [str(source / p.relative_to(ROOT)) for p in swift_files]
    arch = platform.machine()
    target = f"{arch}-apple-macos14.0"
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0", CARGO_TARGET_DIR=str(work / "target"))
    fixture_flags = ["-D", "FINGER_BRIDGE_TESTS"] if bulk_selection else []
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-whole-module-optimization", *fixture_flags,
                    "-target", target, "-module-name", "FingerNative", "-emit-library",
                    "-module-cache-path", str(work / "ModuleCache"), "-Xlinker", "-install_name", "-Xlinker",
                    "@rpath/libFingerNative.dylib", *swift, "-o", str(framework / "libFingerNative.dylib")], check=True, env=env)
    if bulk_selection:
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", *fixture_flags,
                        "-module-cache-path", str(work / "ModuleCache"), str(ROOT / "bridge" / "AgentWire.swift"),
                        str(ROOT / "bridge" / "FingerMCP.swift"), "-o", str(work / "finger-mcp")], check=True, env=env)
    subprocess.run(["cargo", "rustc", "--locked", "--release", "--features", "desktop", "--bin", "Finger", "--",
                    "-L", "native=" + str(framework), "-C", "link-arg=-Wl,-rpath,@executable_path/../Frameworks"],
                   cwd=source, check=True, env=env)
    binary = macos / "FingerGUIBench"
    shutil.copy2(work / "target" / "release" / "Finger", binary)
    return binary, digest.hexdigest(), identifier


def forget_preferences(identifier):
    """The bench app is a real bundle, so AppKit and Finger save preferences
    under its id, and CFFIXED_USER_HOME doesn't keep all of them out of
    ~/Library/Preferences. Once the app has quit, delete that domain through
    cfprefsd, which owns the file, so nothing is written back later. That
    leaves an empty plist behind; once it is removed nothing recreates it."""
    subprocess.run(["defaults", "delete", identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (Path.home() / "Library" / "Preferences" / (identifier + ".plist")).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entries", type=int, nargs="+", default=[10000], help="One or more fixture sizes (minimum 10000)")
    parser.add_argument("--samples", type=int, default=9, help="Measured runs after the first open")
    parser.add_argument("--compare", action="store_true", help="Run the original JSON listing transfer and the typed transfer in separate processes")
    parser.add_argument("--profile", action="store_true", help="Report input, layout and rendering costs separately")
    parser.add_argument("--compare-index", action="store_true", help="Include typed rows with a JSON-installed search index as the previous implementation")
    parser.add_argument("--transfers-only", action="store_true", help="Run native drag, clipboard, collision and Undo checks without the timing fixtures")
    parser.add_argument("--bulk-selection", action="store_true", help="Measure Select All, filter, Back and live MCP selection on large directories")
    parser.add_argument("--move-picker", action="store_true", help="Time Move sheet presentation for a pair and the full selection; cancel each sheet")
    parser.add_argument("--volume-recovery", action="store_true", help="Detach and remount a disposable APFS disk image while two files are selected")
    parser.add_argument("--soak-minutes", type=float, default=0, help="Run a paced endurance session after the benchmark")
    parser.add_argument("--memory-probe", type=int, default=0, metavar="CYCLES", help="Compare lifetime-pool and drained-idle runs using memory and view counters")
    parser.add_argument("--soak-log", type=Path, help="Write endurance samples and phase summaries to this JSON Lines file")
    parser.add_argument("--compact-capture", type=Path, help="Verify a long inspector filename and capture the 790×505-point window")
    parser.add_argument("--capture", type=Path, help="Write a PNG of the real browser window on the demo project")
    parser.add_argument("--worktable", action="store_true", help="Exercise two native Worktable visits to Fold Studies with an isolated MCP connection")
    args = parser.parse_args()
    if args.memory_probe < 0 or (args.memory_probe and (args.soak_minutes or args.compare or len(args.entries) != 1)):
        parser.error("Use one mixed-directory fixture for a memory probe, separately from --compare and --soak-minutes.")
    if not math.isfinite(args.soak_minutes) or args.soak_minutes < 0 or (args.soak_minutes and (args.compare or len(args.entries) != 1)):
        parser.error("A soak runs one typed-list fixture for a positive duration.")
    if any(n < 10000 for n in args.entries) or args.samples < 3:
        parser.error("Use at least 10,000 entries and 3 samples.")
    if platform.system() != "Darwin" or not shutil.which("cargo"):
        parser.error("Run on macOS with Xcode command-line tools and cargo on PATH.")
    with tempfile.TemporaryDirectory(prefix="finger-gui-bench-") as directory, ExitStack() as extras:
        work = Path(directory)
        binary, source_id, identifier = build(work, bulk_selection=args.bulk_selection or args.worktable)
        extras.callback(forget_preferences, identifier)
        fixed_home = work / "preferences"
        if args.worktable:
            fixed_home.mkdir()
            demo = fixed_home / "Studio" / "Fold Studies"
            shutil.copytree(ROOT / "assets" / "Demo" / "Fold Studies", demo)
            (demo / "delivery").mkdir(exist_ok=True)
            socket_dir = Path(extras.enter_context(tempfile.TemporaryDirectory(prefix="finger-work-", dir="/private/tmp")))
            env = dict(os.environ, CFFIXED_USER_HOME=str(fixed_home),
                       FINGER_FIXTURE_SOCKET=str(socket_dir / "window.sock"),
                       FINGER_QA_WORKTABLE_MCP=str(work / "finger-mcp"))
            if args.compact_capture:
                env["FINGER_QA_WORKTABLE_COMPACT"] = str(args.compact_capture.expanduser().resolve())
            capture = str(args.capture.expanduser().resolve()) if args.capture else ""
            for visit in ["first", "return"]:
                if visit == "return":
                    shutil.copyfile(demo / "exports" / "Overlap 01.png", demo / "exports" / "Overlap 02.png")
                subprocess.run([str(binary), str(demo), "0", "0", str(demo), capture],
                               check=True, env=dict(env, FINGER_QA_WORKTABLE_VISIT=visit), timeout=90)
            return
        if args.volume_recovery:
            fixed_home.mkdir()
            # Keep image cleanup separate from the auto-removed benchmark build.
            # If normal detachment fails, retain only this private fixture for recovery.
            fixture_dir = Path(tempfile.mkdtemp(prefix="finger-remount-test-", dir="/private/tmp"))
            image = fixture_dir / "test.dmg"
            mount = fixture_dir / "Project" / "Mounted disk"
            mount.mkdir(parents=True)
            try:
                subprocess.run(["hdiutil", "create", "-quiet", "-fs", "APFS", "-size", "32m", "-volname", "FingerQA-" + uuid.uuid4().hex[:8], str(image)], check=True)
                subprocess.run(["hdiutil", "attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(image)], check=True)
                folder = mount / "Exports"
                folder.mkdir()
                for index in range(70):
                    (folder / f"Page {index:02d}.txt").write_text(f"Page {index}\n")
                env = dict(os.environ, CFFIXED_USER_HOME=str(fixed_home), FINGER_GUI_VOLUME_RECOVERY=str(image))
                subprocess.run([str(binary), str(folder), "70", "0", str(mount), ""], check=True, env=env)
            finally:
                if os.path.ismount(mount):
                    subprocess.run(["hdiutil", "detach", "-quiet", str(mount)], check=True)
                if os.path.ismount(mount):
                    raise RuntimeError(f"Fixture volume remains attached at {mount}")
                shutil.rmtree(fixture_dir)
            print("Temporary APFS volume detached normally; image and mountpoint removed.")
            return
        if args.transfers_only:
            fixed_home.mkdir()
            root = work / "Transfer checks"
            root.mkdir()
            env = dict(os.environ, CFFIXED_USER_HOME=str(fixed_home), FINGER_GUI_BENCH_TRANSFERS_ONLY="1")
            subprocess.run([str(binary), str(root), "0", "0", str(root), ""], check=True, env=env)
            return
        for place in ["Desktop", "Documents", "Downloads", "Studio"]:
            (fixed_home / place).mkdir(parents=True)
        demo = fixed_home / "Studio" / "Fold Studies"
        subprocess.run([sys.executable, str(ROOT / "scripts" / "make-demo.py"), str(demo)], check=True, stdout=subprocess.DEVNULL)
        env = dict(os.environ, CFFIXED_USER_HOME=str(fixed_home), FINGER_GUI_BENCH_SOURCE_ID=source_id,
                   FINGER_GUI_BENCH_PROFILE="1" if args.profile else "0")
        artwork = work / "Artwork project"
        if args.profile and not args.bulk_selection:
            artwork_fixture(artwork)
        if args.bulk_selection:
            socket_dir = Path(extras.enter_context(tempfile.TemporaryDirectory(prefix="finger-bulk-", dir="/private/tmp")))
            env.update(FINGER_GUI_BULK_BRIDGE=str(work / "finger-mcp"), FINGER_FIXTURE_SOCKET=str(socket_dir / "window.sock"))
        if args.compact_capture:
            env["FINGER_GUI_BENCH_COMPACT_CAPTURE"] = str(args.compact_capture.expanduser().resolve())
        if args.soak_minutes or args.memory_probe:
            if args.soak_log:
                log_path = args.soak_log.expanduser().resolve()
            else:
                with tempfile.NamedTemporaryFile(prefix="finger-endurance-", suffix=".jsonl", delete=False) as log:
                    log_path = Path(log.name)
            env["FINGER_GUI_BENCH_SOAK_LOG"] = str(log_path)
            if args.soak_minutes:
                env["FINGER_GUI_BENCH_SOAK_MINUTES"] = str(args.soak_minutes)
            if args.memory_probe:
                env["FINGER_GUI_BENCH_PROBE_CYCLES"] = str(args.memory_probe)
            print(f"Resource log: {log_path}", flush=True)
        for n in args.entries:
            if args.move_picker:
                root = work / f"Project-{n}" / "exports"
                root.mkdir(parents=True)
                for name in ["delivery", "exports-old", "references"]:
                    (root.parent / name).mkdir()
                for i in range(n):
                    (root / f"plate-{i:06d}.{'svg' if i % 2 else 'png'}").touch()
                subprocess.run([str(binary), str(root), str(n), str(args.samples), str(demo), ""],
                               check=True, env=dict(env, FINGER_GUI_MOVE_PICKER="1"))
                continue
            root = work / f"Project-{n}" / "Mixed files"
            fixture(root, n)
            capture = str(args.capture.expanduser().resolve()) if args.capture else ""
            transports = (["json"] if args.compare else []) + (["typed-legacy-index"] if args.compare_index else []) + ["typed"]
            for transport in transports:
                run_env = dict(env, FINGER_GUI_BENCH_TRANSFER=transport)
                for mode in (["outer", "drained"] if args.memory_probe else ["normal"]):
                    run_env["FINGER_GUI_BENCH_PROBE_MODE"] = mode
                    if artwork.is_dir() and n == args.entries[-1] and transport == "typed" and mode != "outer":
                        run_env["FINGER_GUI_BENCH_ARTWORK"] = str(artwork)
                    subprocess.run([str(binary), str(root), str(n), str(args.samples), str(demo), capture], check=True, env=run_env)


if __name__ == "__main__":
    main()
