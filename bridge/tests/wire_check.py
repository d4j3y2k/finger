#!/usr/bin/env python3
"""Run the isolated macOS stdio/socket tests with 10,000 disposable selected entries."""

from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack
import json
import os
from pathlib import Path
import socket
import statistics
import struct
import subprocess
import tempfile
import time

from roundtrip import Session, decode_tool_result, mcp


def main():
    bridge = Path(__file__).resolve().parents[1]
    with ExitStack() as cleanup:
        work = Path(cleanup.enter_context(tempfile.TemporaryDirectory(prefix="finger-wire-", dir="/private/tmp")))
        files = work / "files"
        files.mkdir()
        names = ["00 mountain\nmoon 🌕.png", "01 mountain\tmoon 🌕.svg"]
        for name in names:
            (files / name).touch()
        for index in range(9998):
            (files / f"asset-{index:05}.txt").touch()

        exe, host = work / "finger-mcp", work / "host"
        arguments = ["swiftc", "-O", "-D", "FINGER_BRIDGE_TESTS", "-module-cache-path", str(work / "cache"),
                     str(bridge / "AgentWire.swift")]
        subprocess.run(arguments + [str(bridge / "FingerMCP.swift"), "-o", str(exe)], check=True)
        subprocess.run(arguments + [str(bridge / "AppEndpoint.swift"), str(bridge / "tests/FixtureHost.swift"),
                                    "-o", str(host)], check=True)
        path = str(work / "socket/window.sock")
        env = dict(os.environ, FINGER_FIXTURE_SOCKET=path)

        def start_session():
            return Session([str(exe)], env)

        session = start_session()
        cleanup.callback(session.close)
        call = mcp(session)
        assert call("get_selection", {}).get("isError"), "expected a visible error before the app opens"
        fixture = subprocess.Popen([str(host), str(files)], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        def stop():
            fixture.terminate()
            fixture.wait(timeout=5)
        cleanup.callback(stop)
        assert fixture.stdout.readline().strip() == b"ready"
        assert os.stat(path).st_mode & 0o777 == 0o600
        assert os.stat(Path(path).parent).st_mode & 0o777 == 0o700
        snap = decode_tool_result(call("get_selection", {"limit": 2}))
        sid = snap["selection_id"]
        repeated = decode_tool_result(call("get_selection", {"limit": 1}))["selection_id"]
        assert repeated != sid
        assert snap["total"] == 10000 and snap["next_offset"] == 2
        assert [i["name"] for i in snap["items"]] == names and snap["folder"] == str(files)
        tail = decode_tool_result(call("get_selection", {"selection_id": sid, "offset": 9999}))
        assert tail["items"][0]["id"] == 9999 and tail["next_offset"] is None
        assert call("get_selection", {"offset": 1}).get("isError")
        assert call("get_selection", {"limit": 999}).get("isError")
        assert call("get_selection", {"selection_id": "unknown"}).get("isError")

        # A stalled peer and an invalid 4 GiB frame must not delay a normal read.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as stalled:
            stalled.connect(path)
            stalled.sendall(b"\0")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as malformed:
                malformed.settimeout(2)
                malformed.connect(path)
                malformed.sendall(struct.pack(">I", 2**32 - 1))
                with malformed.makefile("rb") as reader:
                    size = struct.unpack(">I", reader.read(4))[0]
                    assert "size" in json.loads(reader.read(size))["error"]
            started = time.monotonic()
            assert decode_tool_result(call("get_selection", {"selection_id": sid, "limit": 1}))["total"] == 10000
            assert time.monotonic() - started < 2

        def concurrent_page(_):
            client = start_session()
            try:
                read = mcp(client)
                timings = []
                for index in range(12):
                    started = time.monotonic()
                    page = decode_tool_result(read("get_selection", {"selection_id": sid, "offset": index, "limit": 1}))
                    assert page["items"][0]["id"] == index
                    timings.append(1000 * (time.monotonic() - started))
                return timings
            finally:
                client.close()
        with ThreadPoolExecutor(max_workers=8) as pool:
            elapsed = sorted(value for timings in pool.map(concurrent_page, range(8)) for value in timings)
        print(f"96 page reads / 8 clients: median {statistics.median(elapsed):.2f} ms, p95 {elapsed[90]:.2f} ms")

        def report_move(old, new):
            fixture.stdin.write(json.dumps({str(old): str(new)}).encode() + b"\n")
            fixture.stdin.flush()
            assert fixture.stdout.readline() == b"remapped\n"

        # Keep the old token and indices through a parent move and a leaf rename.
        # An unrelated occupant created under the abandoned name may never be used.
        archived = work / "archive"
        files.rename(archived)
        files.mkdir()
        (files / names[0]).write_bytes(b"replacement in the old directory")
        report_move(files, archived)
        mapped = decode_tool_result(call("get_selection", {"selection_id": sid, "limit": 2}))
        assert mapped["folder"] == str(archived)
        assert [(i["id"], i["path"]) for i in mapped["items"]] == [
            (i, str(archived / name)) for i, name in enumerate(names)]
        shared = decode_tool_result(call("get_selection", {"selection_id": repeated, "limit": 2}))
        assert shared["items"] == mapped["items"] and shared["folder"] == mapped["folder"]
        files = archived
        previous = files / names[0]
        names[0] = "Renamed 🌕.png"
        renamed = files / names[0]
        previous.rename(renamed)
        report_move(previous, renamed)
        previous.touch()
        renamed.write_bytes(b"an edit to the same file")
        mapped = decode_tool_result(call("get_selection", {"selection_id": sid, "limit": 1}))
        assert mapped["items"][0]["path"] == str(renamed)

        swapped = files / "asset-00000.txt"  # Item 2 in the original snapshot.
        swapped.rename(work / "original-item")
        swapped.touch()
        assert call("get_selection", {"selection_id": sid, "offset": 2, "limit": 1}).get("isError")
        assert call("show_collection", {"name": "Swapped", "selection_id": sid, "item_ids": [2]}).get("isError")
        swap_target = files / "later-name.txt"
        swapped.rename(swap_target)
        report_move(swapped, swap_target)
        assert call("show_collection", {"name": "Swapped", "selection_id": sid, "item_ids": [2]}).get("isError")

        # An old selection remains usable if a member disappears while the agent works.
        # The collection retains the original URL so Finger can label the missing row.
        (files / names[1]).unlink()
        bad_sets = [[7, 7], [-1], [10000], []]
        for ids in bad_sets:
            assert call("show_collection", {"name": "Pair", "selection_id": sid, "item_ids": ids}).get("isError")
        assert call("show_collection", {"name": "\t", "selection_id": sid}).get("isError")
        assert call("show_collection", {"name": "X" * 101, "selection_id": sid}).get("isError")
        result = decode_tool_result(call("show_collection", {"name": "Moon pair", "selection_id": sid, "item_ids": [1, 0]}))
        assert result["total"] == 2
        current = decode_tool_result(call("get_selection", {}))
        assert current["collection"] == "Moon pair" and current["folder"] is None
        assert [item["name"] for item in current["items"]] == list(reversed(names))
        for _ in range(17):
            call("get_selection", {})
        assert call("get_selection", {"selection_id": sid}).get("isError")

        for version in ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2099-01-01"]:
            client = start_session()
            try:
                reply = client.call("initialize", {"protocolVersion": version, "clientInfo": {}, "capabilities": {}})
                expected = version if version != "2099-01-01" else "2025-11-25"
                assert reply["protocolVersion"] == expected
                result = client.call("tools/call", {"name": "get_selection", "arguments": {"limit": 1}})
                assert ("structuredContent" in result) == (expected >= "2025-06-18")
            finally:
                client.close()

        # Discard an oversized line and recover for the next request in the same stream.
        payload = b" " * (6 * 1024 * 1024) + b'\n{"jsonrpc":"2.0","id":"pong","method":"ping"}\n'
        result = subprocess.run([str(exe)], env=env, input=payload, capture_output=True, check=True, timeout=10)
        replies = [json.loads(line) for line in result.stdout.splitlines()]
        assert replies[0]["error"]["code"] == -32600 and replies[1]["id"] == "pong"
        print("Passed transport versions, unavailable window, pagination, malformed frames, missing file, "
              "in-app remapping, external replacement, snapshot eviction, ordered subsets, and oversized-line recovery.")


if __name__ == "__main__":
    main()
