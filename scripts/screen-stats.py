#!/usr/bin/env python3
"""Summarise a PPM screenshot, for the boot gate.

The gate has to tell a painted login screen from a black framebuffer without a
browser or an image library, so this parser is deliberately small and strict. It
samples every 97th pixel: enough to notice a wallpaper and a login panel, cheap
enough to run on a screenshot of a 4K console.

With --png, the frame is also written as a PNG next to the PPM, so the
screenshot uploaded with a run opens in a browser.

Exit status: 0 when the frame looks like a desktop, 1 when it does not.
"""

from __future__ import annotations

import struct
import sys
import zlib

WHITESPACE = b" \t\n\v\f\r"


def parse_ppm(data: bytes) -> tuple[int, int, bytes]:
    """Return width, height and the RGB bytes of a binary (P6) PPM.

    The header is read token by token: splitting the whole file on whitespace
    would also eat pixel bytes that happen to be 0x09-0x0d or 0x20.
    """
    if not data.startswith(b"P6"):
        raise ValueError("not a binary PPM screenshot")
    fields: list[int] = []
    pos = 2
    while len(fields) < 3:
        while pos < len(data) and data[pos] in WHITESPACE:
            pos += 1
        if pos < len(data) and data[pos] == ord("#"):
            while pos < len(data) and data[pos] not in b"\r\n":
                pos += 1
            continue
        start = pos
        while pos < len(data) and data[pos] not in WHITESPACE:
            pos += 1
        if start == pos:
            raise ValueError("truncated PPM header")
        try:
            fields.append(int(data[start:pos]))
        except ValueError as exc:
            raise ValueError("invalid PPM header") from exc
    # Exactly one whitespace byte separates the header from the pixels.
    pos += 1
    width, height, maxval = fields
    if maxval != 255:
        raise ValueError(f"unsupported PPM maxval {maxval}")
    pixels = data[pos:]
    if width <= 0 or height <= 0 or len(pixels) < width * height * 3:
        raise ValueError(f"truncated PPM pixel data for {width}x{height}")
    return width, height, pixels[: width * height * 3]


def write_png(path: str, width: int, height: int, pixels: bytes) -> None:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        body = kind + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    stride = width * 3
    raw = b"".join(b"\x00" + pixels[row * stride : (row + 1) * stride] for row in range(height))
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        handle.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        handle.write(chunk(b"IEND", b""))


def main(path: str, png: str | None = None) -> int:
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        print(f"cannot read {path}: {exc}")
        return 1
    try:
        width, height, pixels = parse_ppm(data)
    except ValueError as exc:
        print(exc)
        return 1
    if png:
        write_png(png, width, height, pixels)

    total = width * height
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
    args = sys.argv[1:]
    png_out = None
    if len(args) == 3 and args[1] == "--png":
        png_out = args[2]
        args = args[:1]
    if len(args) != 1:
        print("usage: screen-stats.py FRAME.ppm [--png FRAME.png]")
        raise SystemExit(2)
    raise SystemExit(main(args[0], png_out))
