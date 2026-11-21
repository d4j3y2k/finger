#!/bin/bash
set -euo pipefail
# realpath gives the folder's on-disk capitalization. The shared Swift module
# cache breaks if one checkout is built as both ~/Developer and ~/developer.
cd "$(realpath "$(dirname "$0")/..")"
source scripts/rust-env.sh
export MACOSX_DEPLOYMENT_TARGET=14.0
arch="$(uname -m)"
case "$arch" in arm64) target="arm64-apple-macos14.0" ;; x86_64) target="x86_64-apple-macos14.0" ;; *) exit 1 ;; esac
command -v cargo >/dev/null || { echo "Install the stable Rust toolchain and ensure cargo is on PATH." >&2; exit 1; }
build="$PWD/build"
mkdir -p "$build"
stage="$(mktemp -d "$build/.finger.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
frameworks="$stage/Finger.app/Contents/Frameworks"
macos="$stage/Finger.app/Contents/MacOS"
resources="$stage/Finger.app/Contents/Resources"
sources="$stage/Swift"
mkdir -p "$frameworks" "$macos" "$resources" "$sources/native" "$sources/bridge"
cp native/*.swift "$sources/native/"
cp bridge/AgentWire.swift bridge/AppEndpoint.swift bridge/FingerMCP.swift "$sources/bridge/"
cp assets/Info.plist "$stage/Finger.app/Contents/Info.plist"
xcrun swiftc -swift-version 5 -O -whole-module-optimization -target "$target" -module-name FingerNative -emit-library \
  -module-cache-path "$build/ModuleCache" -Xlinker -install_name -Xlinker @rpath/libFingerNative.dylib \
  "$sources"/native/*.swift "$sources/bridge/AgentWire.swift" "$sources/bridge/AppEndpoint.swift" -o "$frameworks/libFingerNative.dylib"
cargo rustc --locked --release --features desktop --bin Finger -- -L "native=$frameworks" -C "link-arg=-Wl,-rpath,@executable_path/../Frameworks"
cp "${CARGO_TARGET_DIR:-target}/release/Finger" "$macos/Finger"
xcrun swiftc -swift-version 5 -O -target "$target" -module-cache-path "$build/ModuleCache" \
  "$sources/bridge/AgentWire.swift" "$sources/bridge/FingerMCP.swift" -o "$macos/finger-mcp"
cp assets/Finger.icns "$resources/Finger.icns"
ditto assets/Demo "$resources/Demo"
mkdir -p "$resources/Demo/Fold Studies/delivery"
cp docs/AGENTS-CONNECTION.md "$resources/AGENTS-CONNECTION.md"
codesign --force --sign - "$frameworks/libFingerNative.dylib"
codesign --force --sign - "$macos/finger-mcp"
codesign --force --sign - "$stage/Finger.app"
codesign --verify --deep --strict "$stage/Finger.app"
# Exchange complete bundles atomically. A running previous build keeps its mmap'd
# executable and native library until it exits. Old bundle resources never leak in.
python3 - "$stage/Finger.app" "$build/Finger.app" <<'PYTHON'
import ctypes, os, sys
src, dst = sys.argv[1:]
if os.path.exists(dst):
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.renamex_np(os.fsencode(src), os.fsencode(dst), 0x2) != 0:  # RENAME_SWAP
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err), dst)
else:
    os.rename(src, dst)
PYTHON
codesign --verify --deep --strict "$build/Finger.app"
echo "$build/Finger.app"
