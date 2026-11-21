#!/usr/bin/env python3
"""Exercise the packaged MCP service on a disposable selection in the live Finger window."""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time


class Session:
    def __init__(self, command, environment):
        self.process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env=environment, bufsize=0
        )
        self.received = bytearray()
        self.sequence = 0

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode("utf-8") + b"\n")
        self.process.stdin.flush()

    def call(self, method, params, timeout=25):
        self.sequence += 1
        self.send({"jsonrpc": "2.0", "method": method, "params": params, "id": self.sequence})
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                while b"\n" in self.received:
                    line, _, self.received = self.received.partition(b"\n")
                    message = json.loads(line)
                    if message.get("id") != self.sequence:
                        continue
                    if "error" in message:
                        raise RuntimeError(message["error"])
                    return message["result"]
                if not selector.select(max(0, deadline - time.monotonic())):
                    break
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("Client exited before replying to " + method)
                self.received.extend(chunk)
        raise TimeoutError("No reply to " + method)

    def notify(self, method):
        self.send({"jsonrpc": "2.0", "method": method})

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)


def decode_tool_result(response):
    if response.get("isError"):
        raise RuntimeError(response["content"][0]["text"])
    return response.get("structuredContent") or json.loads(response["content"][0]["text"])


def mcp(session):
    session.call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                "clientInfo": {"name": "finger-roundtrip", "version": "1"}})
    session.notify("notifications/initialized")
    tools = session.call("tools/list", {})["tools"]
    assert {tool["name"] for tool in tools} == {"get_selection", "show_collection"}
    return lambda tool, args: session.call("tools/call", {"name": tool, "arguments": args})


def codex(session):
    session.call("initialize", {"clientInfo": {"name": "finger-roundtrip", "version": "1"},
                                "capabilities": {"experimentalApi": True}})
    session.notify("initialized")
    thread = session.call("thread/start", {"ephemeral": True, "approvalPolicy": "never",
                                          "sandbox": "read-only", "cwd": os.getcwd()})["thread"]["id"]
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        status = session.call("mcpServerStatus/list", {"threadId": thread})
        available = next((server for server in status["data"] if server["name"] == "finger"), {})
        if {"get_selection", "show_collection"} <= set(available.get("tools", {})):
            break
        time.sleep(.25)
    else:
        raise RuntimeError("Codex did not discover Finger's two tools.")
    return lambda tool, args: session.call("mcpServer/tool/call", {"threadId": thread, "server": "finger",
                                                                  "tool": tool, "arguments": args})


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", type=Path, default=root / "build/Finger.app/Contents/MacOS/finger-mcp")
    parser.add_argument("--codex", action="store_true", help="route calls through the installed Codex app-server")
    parser.add_argument("--expect", nargs="+", required=True,
                        help="require these exact selected basenames before changing the view")
    parser.add_argument("--name", default="Delivery pair", help="name for the collection shown in Finger")
    args = parser.parse_args()
    bridge = str(args.bridge.resolve(strict=True))
    with ExitStack() as resources:
        command = [bridge]
        environment = os.environ.copy()
        if args.codex:
            binary = shutil.which("codex")
            if not binary:
                parser.error("Codex CLI is required for --codex")
            environment["CODEX_HOME"] = resources.enter_context(tempfile.TemporaryDirectory(prefix="finger-codex-"))
            command = [binary, "app-server", "-c", "mcp_servers.finger.command=" + json.dumps(bridge)]
        session = Session(command, environment)
        resources.callback(session.close)
        call = codex(session) if args.codex else mcp(session)
        snapshot = decode_tool_result(call("get_selection", {"limit": 1}))
        items = list(snapshot["items"])
        offset = snapshot.get("next_offset")
        while offset is not None:
            page = decode_tool_result(call("get_selection", {"selection_id": snapshot["selection_id"],
                                                             "offset": offset, "limit": 150}))
            items.extend(page["items"])
            offset = page.get("next_offset")
        names = [item["name"] for item in items]
        if sorted(names) != sorted(args.expect):
            raise RuntimeError(f"Expected {args.expect!r}. The window selected {names!r}.")
        bad = call("show_collection", {"name": args.name, "selection_id": snapshot["selection_id"],
                                       "item_ids": [len(items)]})
        assert bad.get("isError"), "Window accepted an item outside the selection"
        result = decode_tool_result(call("show_collection", {"name": args.name,
                                    "selection_id": snapshot["selection_id"], "item_ids": [i["id"] for i in items]}))
        assert result == {"name": args.name, "total": len(items)}, result
        actual = decode_tool_result(call("get_selection", {}))
        assert actual["collection"] == args.name and actual["folder"] is None, actual
        captured = decode_tool_result(call("get_selection", {"selection_id": snapshot["selection_id"], "limit": 1}))
        assert captured["items"] == snapshot["items"] and captured["folder"] == snapshot["folder"]
        print(f"{'Codex app-server' if args.codex else 'Direct MCP'} selected {names!r} and verified the window now browses {args.name!r}.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, TimeoutError, OSError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
