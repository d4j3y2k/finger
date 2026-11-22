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
"${swift[@]}" native/FolderReferences.swift native/Engine.swift native/FileOrder.swift native/ResumeCatalog.swift tests/ResumeCatalogChecks.swift -o "$stage/worktable-ranking"
"$stage/worktable-ranking"
"${swift[@]}" native/OpenItems.swift tests/OpenItemsChecks.swift -o "$stage/opens"
"$stage/opens"
"${swift[@]}" native/*.swift bridge/AgentWire.swift bridge/AppEndpoint.swift tests/FindPanelChecks.swift -o "$stage/find"
"$stage/find" "${CARGO_TARGET_DIR:-target}/release/finger-core"
# Renders ContentPreview offscreen and leaves PNGs in build/content-preview to review.
"${swift[@]}" native/*.swift bridge/AgentWire.swift bridge/AppEndpoint.swift tests/ContentPreviewChecks.swift -o "$stage/content-preview"
"$stage/content-preview" "$PWD/build/content-preview"

python3 -B bridge/tests/wire_check.py
python3 -B tests/gui-bench/run.py --entries 10000 --samples 3
