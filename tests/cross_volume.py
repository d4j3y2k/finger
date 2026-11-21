#!/usr/bin/env python3
"""Exercise actual cross-device moves on disposable APFS and exFAT images.

Run after cargo build --release --bin finger-core. The image is mounted without
a Finder window below a unique temporary directory, then ejected and deleted.
"""
from pathlib import Path
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
import subprocess
import tempfile


def run(binary, op, sources, destination, **options):
    command = {"op": op, "sources": list(map(str, sources)), "destination": str(destination), **options}
    raw = subprocess.check_output([binary], input=json.dumps(command).encode(), timeout=30)
    response = json.loads(raw)
    assert response["ok"], response
    return response["results"]


def checks(binary, local, volume):
    assert local.stat().st_dev != volume.stat().st_dev
    source = local / "exports"
    source.mkdir()
    (source / "proof.png").write_bytes(bytes(range(256)))
    (source / "source.svg").write_text("<svg/>")
    os.link(source / "proof.png", source / "proof-copy.png")
    (source / "broken alias").symlink_to("../missing")
    source.chmod(0o750)
    for start, destination in [(source, volume), (volume / "exports", local)]:
        result = run(binary, "move", [start], destination)[0]
        assert result["status"] == "done", result
        assert not start.exists()
        actual = destination / "exports"
        assert (actual / "proof.png").read_bytes() == bytes(range(256))
        assert (actual / "source.svg").read_text() == "<svg/>"
        assert (actual / "proof.png").stat().st_ino == (actual / "proof-copy.png").stat().st_ino
        assert (actual / "proof.png").stat().st_nlink == 2
        assert os.readlink(actual / "broken alias") == "../missing"
        assert actual.stat().st_mode & 0o777 == 0o750
    print("Passed cross-device move in both directions, with preserved links, modes and data.")

    # A destination page already in use by a collision must never be overwritten.
    (volume / "proof.png").write_bytes(b"existing")
    collision = run(binary, "move", [source / "proof.png"], volume)[0]
    assert collision["status"] == "collision", collision
    assert (source / "proof.png").exists() and (volume / "proof.png").read_bytes() == b"existing"
    kept = run(binary, "move", [source / "proof.png"], volume, collision="keepBoth")[0]
    assert kept["status"] == "done" and (volume / "proof 2.png").read_bytes() == bytes(range(256))
    print("Passed cross-device collision and keep-both checks.")

    oversized = local / "larger-than-test-volume.bin"
    chunk = os.urandom(1 << 20)
    with oversized.open("wb") as stream:
        for _ in range(48):
            stream.write(chunk)
    full = run(binary, "move", [oversized], volume)[0]
    assert full["status"] == "error" and "space" in full["error"].lower(), full
    assert oversized.stat().st_size == 48 << 20 and not (volume / oversized.name).exists()
    with oversized.open("rb") as stream:
        assert all(stream.read(len(chunk)) == chunk for _ in range(48))
    assert not list(volume.glob(".finger-transfer-*"))
    print("Passed disk-full failure with every source byte intact and no published or staged copy.")

    fifo = source / "pipe"
    os.mkfifo(fifo)
    special = run(binary, "move", [source], volume)[0]
    assert special["status"] == "error" and fifo.exists() and not (volume / "exports").exists()
    root = run(binary, "move", [volume], local)[0]
    assert root["status"] == "error" and volume.is_mount()
    print("Passed special-file and mounted-volume checks.")

    variants = volume / "variants"
    variants.mkdir()
    (variants / "Logo").write_text("upper")
    (variants / "logo").write_text("lower")
    assert (variants / "Logo").read_text() == "upper"
    probe = local / "CaseProbe"
    probe.touch()
    if (local / "caseprobe").exists():
        result = run(binary, "move", [variants], local, collision="keepBoth")[0]
        assert result["status"] == "error", result
        assert not (local / "variants").exists() and not list(local.glob(".finger-transfer-*"))
        assert (variants / "Logo").read_text() == "upper" and (variants / "logo").read_text() == "lower"
        print("Passed case-sensitive to case-insensitive conflict without losing either source.")
    else:
        print("Local temporary volume is case-sensitive; inner case-fold collision is inapplicable.")


def exfat_checks(binary, local, volume):
    assert local.stat().st_dev != volume.stat().st_dev
    exports = local / "exports"
    exports.mkdir()
    png = exports / "station.png"
    png.write_bytes(bytes(range(256)))
    (exports / "station.svg").write_text("<svg/>")
    subprocess.run(["xattr", "-w", "com.example.finger", "published", png], check=True)
    (exports / "._handwritten").write_text("user data")
    result = run(binary, "move", [exports], volume)[0]
    assert result["status"] == "done", result
    assert not exports.exists()
    moved = volume / "exports"
    assert (moved / "station.png").read_bytes() == bytes(range(256))
    assert (moved / "station.svg").read_text() == "<svg/>"
    assert subprocess.check_output(["xattr", "-p", "com.example.finger", moved / "station.png"],
                                   text=True).strip() == "published"
    for old, name in [("station.png", "STATION.png"), ("STATION.png", "poster.png")]:
        command = {"op": "rename", "path": str(moved / old), "name": name}
        renamed = json.loads(subprocess.check_output([binary], input=json.dumps(command).encode()))
        assert renamed["ok"] and name in os.listdir(moved), renamed
    delivery = volume / "delivery"
    delivery.mkdir()
    result = run(binary, "move", [moved], delivery)[0]
    assert result["status"] == "done", result
    result = run(binary, "move", [delivery / "exports"], local)[0]
    assert result["status"] == "done", result
    assert (exports / "poster.png").read_bytes() == bytes(range(256))
    assert (exports / "._handwritten").read_text() == "user data"
    assert not (exports / "._poster.png").exists()
    print("Passed exFAT round trip, case-only rename, folder move, and AppleDouble metadata checks.")

    destination = volume / "proofs"
    destination.mkdir()
    original = destination / "poster.png"
    original.write_text("existing")
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(lambda _: run(binary, "copy", [exports / "poster.png"],
                                               destination, collision="keepBoth")[0], range(10)))
    assert all(result["status"] == "done" for result in results), results
    assert len({result["destination"] for result in results}) == len(results)
    assert original.read_text() == "existing"
    assert all(Path(result["destination"]).read_bytes() == bytes(range(256)) for result in results)
    print("Passed ten concurrent exFAT keep-both copies with unique names and preserved existing bytes.")

    forked = local / "with-resource-fork"
    forked.write_text("ordinary data")
    (forked / "..namedfork" / "rsrc").write_text("resource data")
    subprocess.run(["xattr", "-w", "com.example.finger", "with fork", forked], check=True)
    result = run(binary, "move", [forked], volume)[0]
    if result["status"] == "done":
        assert (volume / forked.name / "..namedfork" / "rsrc").read_text() == "resource data"
    else:
        assert result["status"] == "error" and "APFS" in result["error"], result
        assert forked.read_text() == "ordinary data"
        assert (forked / "..namedfork" / "rsrc").read_text() == "resource data"
        assert not (volume / forked.name).exists() and not (volume / ("._" + forked.name)).exists()
    print("Passed exFAT resource-fork preservation or actionable refusal with complete originals.")

    # Force a failure after at least some destination content has been written.
    huge = local / "larger-than-exfat-volume"
    free = os.statvfs(volume)
    chunks = free.f_bavail * free.f_frsize // (1 << 20) + 2
    block = os.urandom(1 << 20)
    with huge.open("wb") as stream:
        for _ in range(chunks):
            stream.write(block)
    result = run(binary, "move", [huge], volume)[0]
    assert result["status"] == "error" and "space" in result["error"].lower(), result
    assert huge.stat().st_size == chunks << 20 and not (volume / huge.name).exists()
    assert not (volume / ("._" + huge.name)).exists()
    print("Passed exFAT disk-full rollback without an incomplete file or companion.")


def receipt_checks(binary, local, volume):
    # Receipts belong to one running engine, just as they do to the live window.
    with tempfile.TemporaryDirectory(dir=local) as a, tempfile.TemporaryDirectory(dir=volume) as b:
        source = Path(a) / "Artwork"
        source.mkdir()
        (source / "cover.svg").write_text("<svg/>")
        target = Path(b) / source.name
        engine = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

        def call(message):
            engine.stdin.write(json.dumps(message, default=str) + "\n")
            engine.stdin.flush()
            response = json.loads(engine.stdout.readline())
            assert response["ok"], response
            return response["results"][0]

        try:
            moved = call({"op": "move", "sources": [source], "destination": b})
            assert moved["status"] == "done", moved
            undone = call({"op": "restore", "receipts": [moved["receipt"]]})
            assert undone["status"] == "done", undone
            assert (source / "cover.svg").read_text() == "<svg/>" and not target.exists()
            redone = call({"op": "restore", "receipts": [undone["receipt"]]})
            assert redone["status"] == "done", redone
            assert (target / "cover.svg").read_text() == "<svg/>" and not source.exists()
            changed = target / "cover.svg"
            before = changed.stat()
            changed.write_text("<SVG/>")
            os.utime(changed, ns=(before.st_atime_ns, before.st_mtime_ns))
            refusal = call({"op": "restore", "receipts": [redone["receipt"]]})
            assert refusal["status"] == "error" and not source.exists() and changed.read_text() == "<SVG/>", refusal
            labeled = Path(a) / "labeled.svg"
            labeled.write_text("<svg/>")
            moved_label = call({"op": "move", "sources": [labeled], "destination": b})
            assert moved_label["status"] == "done", moved_label
            actual = Path(b) / labeled.name
            subprocess.run(["xattr", "-w", "com.example.finger", "new label", actual], check=True)
            refusal = call({"op": "restore", "receipts": [moved_label["receipt"]]})
            assert refusal["status"] == "error" and not labeled.exists() and actual.exists(), refusal
        finally:
            engine.stdin.close()
            engine.wait(timeout=5)
        print("Passed cross-volume Undo/Redo and refusal of changed content or Finder metadata.")


def exercise_image(binary, filesystem):
    with tempfile.TemporaryDirectory(prefix="finger-volumes-") as directory:
        test_root = Path(directory)
        local = test_root / "local"
        local.mkdir()
        volume = test_root / "mount"
        volume.mkdir()
        image = test_root / "fixture.dmg"
        size, format_name, exercise = (("32m", "Case-sensitive APFS", checks) if filesystem == "apfs"
                                        else ("128m", "ExFAT", exfat_checks))
        subprocess.run(["hdiutil", "create", "-size", size, "-fs", format_name,
                        "-volname", "FINGERTEST", "-type", "UDIF", image], check=True)
        subprocess.run(["hdiutil", "attach", "-nobrowse", "-noautoopen", "-mountpoint", volume, image],
                       check=True)
        try:
            exercise(binary, local, volume)
            receipt_checks(binary, local, volume)
        finally:
            subprocess.run(["hdiutil", "detach", volume], check=True)
            assert not volume.is_mount(), f"Test volume is still attached at {volume}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", type=Path, default=Path("target/release/finger-core"))
    parser.add_argument("--filesystem", choices=["all", "apfs", "exfat"], default="all")
    args = parser.parse_args()
    binary = args.bin.resolve(strict=True)
    for filesystem in (["apfs", "exfat"] if args.filesystem == "all" else [args.filesystem]):
        exercise_image(binary, filesystem)
