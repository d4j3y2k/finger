#!/bin/bash
set -euo pipefail
# Prints what Finger's Working On would show on this Mac right now. Read-only:
# Spotlight, FSEvents history, the process table and git status. Nothing is
# written, sent or left running.
cd "$(realpath "$(dirname "$0")/..")"
stage="$(mktemp -d "${TMPDIR:-/tmp}/finger-probe.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
xcrun swiftc -swift-version 5 -O -module-cache-path "$PWD/build/ModuleCache" \
  native/*.swift bridge/AgentWire.swift bridge/AppEndpoint.swift tests/AwarenessProbe.swift -o "$stage/probe"
"$stage/probe" "$@"
