#!/usr/bin/env python3
"""Export the Flamez SVG for Linux, SDL and macOS using rsvg-convert.

Exports are committed so ordinary builds need no artwork tools or Python packages.
"""
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "packaging/linux/flamez.svg"
OUTPUT = ROOT / "packaging/icons"
LINUX_SIZES = (16, 24, 32, 48, 64, 96, 128, 256, 512, 1024)
# Standard and Retina representations use PNG payloads, as in Zimbr's exporter.
ICNS_SIZES = (
    (b"icp4", 16), (b"ic11", 32),
    (b"icp5", 32), (b"ic12", 64),
    (b"ic07", 128), (b"ic13", 256),
    (b"ic08", 256), (b"ic14", 512),
    (b"ic09", 512), (b"ic10", 1024),
)


def render(source, size):
    return subprocess.check_output([
        "rsvg-convert", "--width", str(size), str(source),
    ])


def main():
    if not shutil.which("rsvg-convert"):
        raise SystemExit("Install librsvg (rsvg-convert) to regenerate the icons.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    images = {size: render(SOURCE, size) for size in LINUX_SIZES}
    for size, image in images.items():
        (OUTPUT / f"flamez-{size}.png").write_bytes(image)
    chunks = b"".join(kind + struct.pack(">I", len(images[size]) + 8) + images[size]
                      for kind, size in ICNS_SIZES)
    mac_icon = ROOT / "packaging/macos/flamez.icns"
    mac_icon.parent.mkdir(parents=True, exist_ok=True)
    mac_icon.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)

    ET.register_namespace("", "http://www.w3.org/2000/svg")
    source = ET.parse(SOURCE).getroot()
    artwork = "".join(ET.tostring(child, encoding="unicode") for child in source)
    samples = "".join(
        f'<use href="#icon" x="{x}" y="{610 - size}" width="{size}" height="{size}"/>'
        f'<text x="{x + size / 2}" y="643" text-anchor="middle">{size}</text>'
        for x, size in ((160, 16), (244, 24), (336, 32), (436, 48), (552, 64), (684, 96))
    )
    preview = f'''<svg xmlns="http://www.w3.org/2000/svg" width="960" height="688" viewBox="0 0 960 688">
      <defs><symbol id="icon" viewBox="0 0 512 512">{artwork}</symbol></defs>
      <rect width="960" height="688" fill="#F4F0E8"/>
      <g font-family="sans-serif" fill="#27232A">
        <text x="40" y="58" font-size="28" font-weight="bold">Flamez</text>
        <text x="920" y="56" text-anchor="end" font-size="15">Zig orange #F7A41D · parent blue #5C97FF</text>
        <rect x="24" y="88" width="448" height="412" rx="16" fill="#FFFFFF"/>
        <rect x="488" y="88" width="448" height="412" rx="16" fill="#202127"/>
        <use href="#icon" x="60" y="94" width="376" height="376"/>
        <use href="#icon" x="524" y="94" width="376" height="376"/>
        <g font-size="13">{samples}</g>
      </g>
    </svg>'''
    with tempfile.TemporaryDirectory(prefix="flamez-icons-") as temporary:
        path = Path(temporary) / "preview.svg"
        path.write_text(preview)
        (OUTPUT / "preview.png").write_bytes(render(path, 960))
    print("Exported Linux PNGs, macOS ICNS, and light/dark preview.")


if __name__ == "__main__":
    main()
