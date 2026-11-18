#!/usr/bin/env python3
"""Summarise a PPM screenshot, for the boot gate.

The gate has to tell a painted login screen from a black framebuffer without a
browser or an image library, so this parser is deliberately small and strict. It
samples every 97th pixel: enough to notice a wallpaper and a login panel, cheap
enough to run on a screenshot of a 4K console.

Exit status: 0 when the frame looks like a desktop, 1 when it does not.
"""

from __future__ import annotations

import sys


def main(path: str) -> int:
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        print(f"cannot read {path}: {exc}")
        return 1
    if not data.startswith(b"P6"):
        print("not a binary PPM screenshot")
        return 1
    parts = data.split(None, 4)
    if len(parts) < 5:
        print("truncated PPM header")
        return 1
    try:
        width, height = int(parts[1]), int(parts[2])
    except ValueError:
        print("invalid PPM dimensions")
        return 1
    pixels = parts[4]
    total = width * height
    if total == 0 or len(pixels) < total * 3:
        print(f"truncated PPM pixel data for {width}x{height}")
        return 1

    step = 3 * 97
    sampled = range(0, total * 3, step)
    lit = 0
    colours: set[tuple[int, int, int]] = set()
    for offset in sampled:
        red, green, blue = pixels[offset], pixels[offset + 1], pixels[offset + 2]
        if max(red, green, blue) > 16:
            lit += 1
        colours.add((red, green, blue))
    share = lit / max(len(sampled), 1)
    print(f"{width}x{height}, {share * 100:.0f}% lit, {len(colours)} sampled colours")
    return 0 if share >= 0.01 and len(colours) >= 8 else 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: screen-stats.py FRAME.ppm")
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
