#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/Finger.iconset"
swift -module-cache-path "${TMPDIR:-/tmp}/finger-demo-swift-cache" scripts/render-svg.swift assets/mark.svg "$work/master.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$work/master.png" --out "$work/Finger.iconset/icon_${size}x${size}.png" >/dev/null
  scale=$(( size * 2 ))
  sips -z "$scale" "$scale" "$work/master.png" --out "$work/Finger.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 - "$work/Finger.iconset" assets/Finger.icns <<'PYTHON'
from pathlib import Path
import struct,sys
icons = Path(sys.argv[1])
parts = []
for key, size in [('icp4','16x16'),('icp5','32x32'),('icp6','32x32@2x'),('ic07','128x128'),('ic08','256x256'),('ic09','512x512'),('ic10','512x512@2x'),('ic11','16x16@2x'),('ic12','32x32@2x'),('ic13','128x128@2x'),('ic14','256x256@2x')]:
    data = (icons / ('icon_' + size + '.png')).read_bytes()
    parts.append(key.encode() + struct.pack('>I',len(data)+8) + data)
body = b''.join(parts)
Path(sys.argv[2]).write_bytes(b'icns' + struct.pack('>I',len(body)+8) + body)
PYTHON
