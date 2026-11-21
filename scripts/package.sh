#!/bin/bash
set -euo pipefail
# realpath gives the folder's on-disk capitalization. The shared Swift module
# cache breaks if one checkout is built as both ~/Developer and ~/developer.
cd "$(realpath "$(dirname "$0")/..")"
./scripts/build.sh
build="$PWD/build"
archive="$build/Finger-macOS-$(uname -m).zip"
stage="$(mktemp -d "$build/.package.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto -c -k --keepParent --sequesterRsrc "$build/Finger.app" "$stage/Finger.zip"
ditto -x -k "$stage/Finger.zip" "$stage/extracted"
codesign --verify --deep --strict "$stage/extracted/Finger.app"
cmp "$build/Finger.app/Contents/MacOS/Finger" "$stage/extracted/Finger.app/Contents/MacOS/Finger"
mv "$stage/Finger.zip" "$archive"
echo "$archive"
