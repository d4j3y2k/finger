#!/usr/bin/env python3
"""Point this checkout's Codex and Claude Code configs at its Finger MCP bridge.

scripts/build.sh runs this after every build, so the project-level registrations
always name the bridge inside this checkout's build/Finger.app, wherever the
checkout lives. Both files are machine-specific and ignored by git. Only the
`finger` entry is replaced; other servers and settings are kept.
"""

import json
import os
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
bridge = str(root / "build/Finger.app/Contents/MacOS/finger-mcp")


def write_if_changed(path: Path, text: str) -> None:
    if path.exists() and path.read_text() == text:
        return
    path.parent.mkdir(exist_ok=True)
    staged = path.with_name(path.name + ".tmp")
    staged.write_text(text)
    os.replace(staged, path)


def register_claude_code() -> None:
    path = root / ".mcp.json"
    config = {}
    if path.exists():
        try:
            config = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            print(f"warning: left {path} unchanged; it isn't valid JSON ({error})", file=sys.stderr)
            return
    servers = config.setdefault("mcpServers", {})
    servers["finger"] = {"type": "stdio", "command": bridge, "args": [], "env": {}}
    write_if_changed(path, json.dumps(config, indent=2) + "\n")


def register_codex() -> None:
    path = root / ".codex/config.toml"
    kept, in_finger_table = [], False
    for line in path.read_text().splitlines() if path.exists() else []:
        header = line.strip()
        if header.startswith("["):
            in_finger_table = header == "[mcp_servers.finger]" or header.startswith("[mcp_servers.finger.")
        if not in_finger_table:
            kept.append(line)
    while kept and not kept[-1].strip():
        kept.pop()
    # A JSON string literal is also a valid TOML basic string.
    entry = ["[mcp_servers.finger]", f"command = {json.dumps(bridge)}"]
    write_if_changed(path, "\n".join(kept + ([""] if kept else []) + entry) + "\n")


register_claude_code()
register_codex()
