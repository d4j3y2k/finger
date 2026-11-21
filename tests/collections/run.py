#!/usr/bin/env python3
"""Check large live MCP collections and their exact membership after a real relaunch."""
from contextlib import ExitStack
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
spec = importlib.util.spec_from_file_location("finger_gui_test_builder", HERE.parent / "gui-bench" / "run.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
sys.path.insert(0, str(ROOT / "bridge" / "tests"))
from roundtrip import Session, codex, decode_tool_result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--entries", type=int, nargs="+", default=[10000, 100000])
    parser.add_argument("--profile-writes", action="store_true", help="Time JSON encoding and a same-sized isolated defaults write separately")
    args = parser.parse_args()
    installed = shutil.which("codex")
    if not installed:
        parser.error("The installed Codex CLI is needed for the real client check.")
    with ExitStack() as resources:
        work = Path(resources.enter_context(tempfile.TemporaryDirectory(prefix="finger-collections-")))
        sockdir = Path(resources.enter_context(tempfile.TemporaryDirectory(prefix="finger-set-", dir="/private/tmp")))
        binary, source_hash = builder.build(work, bulk_selection=True, delegate_driver=HERE / "CollectionChecks.swift")
        home = work / "Private preferences"
        home.mkdir()
        env = dict(os.environ, CFFIXED_USER_HOME=str(home), FINGER_FIXTURE_SOCKET=str(sockdir / "window.sock"),
                   FINGER_QA_PROFILE_WRITES="1" if args.profile_writes else "0")
        # The wrapper fixes the private endpoint even when a host filters the
        # environment it passes on to a local MCP server.
        wrapper = work / "fixture-mcp"
        wrapper.write_text("#!/bin/sh\nexport FINGER_FIXTURE_SOCKET=" + shlex.quote(env["FINGER_FIXTURE_SOCKET"]) +
                           "\nexec " + shlex.quote(str(work / "finger-mcp")) + "\n")
        wrapper.chmod(0o700)
        os.chdir(work)
        codex_home = work / "Codex"
        codex_home.mkdir()
        client = Session([installed, "app-server", "-c", "mcp_servers.finger.command=" + json.dumps(str(wrapper))],
                         dict(env, CODEX_HOME=str(codex_home)))
        resources.callback(client.close)
        call = codex(client)
        print(subprocess.check_output([installed, "--version"], text=True).strip(), "source", source_hash, flush=True)
        checks = []
        for n in args.entries:
            folder = work / f"Project {n}" / "Orchard Printing Studio" / "Delivery" / "2026 Autumn Release" / "Approved Art Sources"
            builder.fixture(folder, n)
            recorded = {}
            elapsed = {}
            modes = ["write", "read"] + (["fast-write", "fast-read"] if n == args.entries[-1] else [])
            for mode in modes:
                ready = work / f"ready-{mode}-{n}"
                result = work / f"{mode}-{n}.json"
                log = work / f"{mode}-{n}.log"
                with log.open("wb") as stream:
                    run_env = dict(env, FINGER_QA_CLEAR_DOMAIN="1" if mode == "fast-read" else "0")
                    process = subprocess.Popen([str(binary), mode, str(folder), str(n), str(result), str(ready)],
                                               env=run_env, stdout=stream, stderr=stream)
                    try:
                        if mode.endswith("write"):
                            deadline = time.monotonic() + 90
                            while not ready.exists():
                                if process.poll() is not None or time.monotonic() > deadline:
                                    raise RuntimeError("Window did not select its disposable fixture: " + log.read_text()[-2000:])
                                time.sleep(0.02)
                            start = time.perf_counter()
                            selection = decode_tool_result(call("get_selection", {"limit": 1}))
                            read = time.perf_counter()
                            # Prove this is the fixture before changing the window.
                            assert selection["folder"] == str(folder) and selection["total"] == n
                            name = f"Quick exit archive {n}" if mode == "fast-write" else f"Press archive {n}"
                            shown = decode_tool_result(call("show_collection", {"selection_id": selection["selection_id"], "name": name}))
                            stop = time.perf_counter()
                            assert shown["total"] == n
                            elapsed = {"getMs": round((read-start)*1000, 1), "showMs": round((stop-read)*1000, 1),
                                       "roundtripMs": round((stop-start)*1000, 1)}
                        process.wait(timeout=150)
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait()
                    if process.returncode or not result.is_file():
                        raise RuntimeError("Probe exited without a report: " + log.read_text()[-3000:])
                recorded[mode] = json.loads(result.read_text())
                print(n, mode, json.dumps(recorded[mode], sort_keys=True), json.dumps(elapsed) if mode == "write" else "", flush=True)
                for line in log.read_text(errors="replace").splitlines():
                    if "CFPreferences" in line or "UserDefaults" in line or "preferences" in line.lower():
                        print(line[:500], flush=True)
            written, readback = recorded["write"], recorded["read"]
            checks.append(all(written.get(key) == readback.get(key) for key in ["id", "count", "sha256"]) and
                          written.get("count") == n and readback.get("listedInOrder") is True)
            if "fast-write" in recorded:
                quit_report = json.loads((work / f"fast-write-{n}.json.quit").read_text())
                print("Queued write at Quit", json.dumps(quit_report), flush=True)
                fast = recorded["fast-read"]
                checks.append(quit_report["queuedAtQuit"] >= 2 and quit_report["waitMs"] >= 70 and
                              fast.get("id") == recorded["fast-write"].get("id") and fast.get("count") == n and
                              fast.get("sha256") == written.get("sha256") and fast.get("listedInOrder") is True)
        if not all(checks):
            raise SystemExit("At least one collection failed its cross-process membership check.")
        print("Every collection survived normal quit and fresh-process listing with exact ID and ordered path digest.")


if __name__ == "__main__":
    main()
