#!/usr/bin/env python3
"""Create a fresh disposable print project with editable vector sources and rendered PNGs."""
import argparse
from pathlib import Path
import subprocess
import tempfile

def print_svg(old=False):
    paper, ink, accent = ("#dae6ee", "#124451", "#5291a8") if old else ("#f4ecd7", "#262a20", "#f05231")
    n = "00" if old else "01"
    # All text is also present as editable type in the source artwork.
    paths = []
    for i in range(12):
        x = 132 + i * 14
        top = 111 + i * 10
        width = 405 - i * 23
        radius = 100 - i * 6
        paths.append(f'<path d="M {x} 450 V {top+radius} Q {x} {top} {x+radius} {top} H {x+width}"/>')
    lines = ''.join(paths)
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="720" height="540" viewBox="0 0 720 540">
<rect width="720" height="540" fill="{paper}"/>
<g fill="{ink}" font-family="Helvetica Neue,Helvetica,sans-serif">
<text x="32" y="38" font-size="14" font-weight="bold" letter-spacing="2">FOLD STUDIES</text>
<text x="688" y="38" text-anchor="end" font-size="13" letter-spacing="2">PLATE {n}</text>
</g>
<path d="M32 56H688M32 474H688" stroke="{ink}" stroke-width="2"/>
<circle cx="514" cy="281" r="137" fill="{accent}"/>
<g fill="none" stroke="{ink}" stroke-width="8" stroke-linecap="square">{lines}</g>
<g fill="{ink}" font-family="Helvetica Neue,Helvetica,sans-serif">
<text x="32" y="511" font-size="22" font-weight="bold" letter-spacing="-1">Overlap / {n}</text>
<text x="688" y="509" text-anchor="end" font-size="13" letter-spacing="1.4">STUDIO EDITION</text>
</g></svg>'''

def asset(folder, old=False):
    name = "Overlap 00" if old else "Overlap 01"
    svg = folder / (name + ".svg")
    svg.write_text(print_svg(old))
    subprocess.run(["/usr/bin/swift", "-module-cache-path", str(Path(tempfile.gettempdir()) / "finger-demo-swift-cache"), str(Path(__file__).with_name("render-svg.swift")), str(svg), str(folder / (name + ".png"))], check=True, stdout=subprocess.DEVNULL)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", help="A new, previously unused project directory")
    args = parser.parse_args()
    root = Path(args.directory).expanduser().absolute() if args.directory else Path(tempfile.mkdtemp(prefix="finger-demo-")) / "Fold Studies"
    root.mkdir(parents=True, exist_ok=False)
    for name in ["exports","exports-old","delivery"]:
        (root/name).mkdir()
    asset(root/"exports")
    asset(root/"exports-old",old=True)
    (root/"exports"/"Print notes.txt").write_text("Overlap 01\n\nThe vermilion edition is approved for delivery. Keep the PNG proof with its editable SVG source.\n")
    (root/"exports-old"/"Revision notes.txt").write_text("Overlap 00\n\nFirst proof, cool blue ink. The approved revision lives in exports.\n")
    print(root)
if __name__ == "__main__":
    main()
