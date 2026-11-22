#!/bin/bash
set -euo pipefail
# realpath gives the folder's on-disk capitalization. The shared Swift module
# cache breaks if one checkout is built as both ~/Developer and ~/developer.
cd "$(realpath "$(dirname "$0")/..")"
source scripts/rust-env.sh

./scripts/build.sh
cargo test --locked
cargo build --locked --release --bin finger-core

frameworks="$PWD/build/Finger.app/Contents/Frameworks"
CARGO_ENCODED_RUSTFLAGS="-Lnative=$frameworks"$'\x1f'"-Clink-arg=-Wl,-rpath,$frameworks" \
    cargo test --locked --features desktop --bin Finger

stage="$(mktemp -d "${TMPDIR:-/tmp}/finger-checks.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
swift=(xcrun swiftc -swift-version 5 -module-cache-path "$PWD/build/ModuleCache")
"${swift[@]}" native/FolderReferences.swift native/DestinationRanker.swift tests/DestinationRankerChecks.swift -o "$stage/ranking"
"$stage/ranking"
"${swift[@]}" native/FingerPreferences.swift native/FolderReferences.swift native/Engine.swift native/FileOrder.swift native/ResumeCatalog.swift tests/ResumeCatalogChecks.swift -o "$stage/worktable-ranking"
"$stage/worktable-ranking"
"${swift[@]}" native/OpenItems.swift tests/OpenItemsChecks.swift -o "$stage/opens"
"$stage/opens"
"${swift[@]}" native/*.swift bridge/AgentWire.swift bridge/AppEndpoint.swift tests/FindPanelChecks.swift -o "$stage/find"
"$stage/find" "${CARGO_TARGET_DIR:-target}/release/finger-core"
# Finger as a background utility: Open at Login, the Dock icon only while the
# window is open, the menu bar menu, and scripts/install.sh into a temp folder.
"${swift[@]}" native/*.swift bridge/AgentWire.swift bridge/AppEndpoint.swift tests/BackgroundChecks.swift -o "$stage/background"
"$stage/background" "$PWD"
# The panel's shortcut: parsing, saving, live re-registration and its recorder window.
"${swift[@]}" native/FingerPreferences.swift native/PanelShortcut.swift native/PanelHotKey.swift tests/PanelShortcutChecks.swift -o "$stage/shortcut"
"$stage/shortcut"
# The summonable panel, driven by keys over a fixture home. It writes light
# and dark PNGs of the main states to build/panel-checks.
"${swift[@]}" native/*.swift bridge/AgentWire.swift bridge/AppEndpoint.swift tests/PanelChecks.swift -o "$stage/panel"
mkdir -p build/panel-checks
"$stage/panel" "${CARGO_TARGET_DIR:-target}/release/finger-core" "$PWD/build/panel-checks"
# Working On: the awareness model with fake signal sources and a fake clock,
# its two menu switches and "What Finger knows", then the panel's Working On,
# blue dots and landing over a fixture home. PNGs go to build/awareness-checks.
"${swift[@]}" native/*.swift bridge/AgentWire.swift bridge/AppEndpoint.swift tests/AwarenessChecks.swift -o "$stage/awareness"
mkdir -p build/awareness-checks
"$stage/awareness" "${CARGO_TARGET_DIR:-target}/release/finger-core" "$PWD/build/awareness-checks"
# Renders ContentPreview offscreen and leaves PNGs in build/content-preview to review.
"${swift[@]}" native/*.swift bridge/AgentWire.swift bridge/AppEndpoint.swift tests/ContentPreviewChecks.swift -o "$stage/content-preview"
"$stage/content-preview" "$PWD/build/content-preview"

python3 -B bridge/tests/wire_check.py
python3 -B tests/gui-bench/run.py --entries 10000 --samples 3
