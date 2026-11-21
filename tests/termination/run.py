#!/usr/bin/env python3
"""Quit an isolated, real NSApplication during a 96 MiB directory copy."""
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("finger_gui_test_builder", HERE.parent / "gui-bench" / "run.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def manifest(directory):
    tree = hashlib.sha256()
    count = size = 0
    for path in sorted(directory.rglob("*")):
        if path.is_file():
            payload = path.read_bytes()
            tree.update(os.fsencode(path.relative_to(directory)) + b"\0" + hashlib.sha256(payload).digest())
            count += 1
            size += len(payload)
    return count, size, tree.hexdigest()


def main():
    with tempfile.TemporaryDirectory(prefix="finger-termination-") as temporary:
        work = Path(temporary)
        binary, _ = builder.build(work, delegate_driver=HERE / "TerminationChecks.swift")
        root = work / "Practice"
        artwork = root / "Source" / "Artwork"
        for index in range(2048):
            parent = artwork / f"Chapter {index % 32:02}" / "Exports"
            parent.mkdir(parents=True, exist_ok=True)
            (parent / f"Plate {index:04}.bin").write_bytes(hashlib.shake_256(str(index).encode()).digest(48 * 1024))
        expected = manifest(artwork)
        incoming = b"Revised edition for delivery\n"
        original = b"Original published edition\n"
        (root / "Source" / "Edition.txt").write_bytes(incoming)
        for scenario in ["success", "collision"]:
            destination = root / scenario.title()
            destination.mkdir()
            if scenario == "collision":
                (destination / "Edition.txt").write_bytes(original)
            home = work / f"Preferences-{scenario}"
            home.mkdir()
            print(f"Before {scenario}: source={expected}, destination tree absent", flush=True)
            proc = subprocess.run([str(binary), str(root), scenario], env=dict(os.environ, CFFIXED_USER_HOME=str(home)),
                                  text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
            print(proc.stdout, end="", flush=True)
            print(f"After {scenario}: process status={proc.returncode}, "
                  f"published={manifest(destination / 'Artwork')}, "
                  f"temporary transfers={len(list(destination.glob('.finger-transfer-*')))}", flush=True)
            assert proc.returncode == 0 and "Application will terminate after the completed copy" in proc.stdout
            assert "busy=true reply=later" in proc.stdout
            assert manifest(artwork) == expected and manifest(destination / "Artwork") == expected
            assert not list(destination.glob(".finger-transfer-*"))
            if scenario == "collision":
                assert "usable collision sheet retained" in proc.stdout and "busy=false reply=now" in proc.stdout
                assert (destination / "Edition.txt").read_bytes() == original
                assert (destination / "Edition 2.txt").read_bytes() == incoming
                assert (root / "Source" / "Edition.txt").read_bytes() == incoming
                print("Both edition payloads verified after quit.", flush=True)


if __name__ == "__main__":
    main()
