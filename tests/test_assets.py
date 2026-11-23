"""Unit tests for the shipped art and the gate's screenshot parser.

Run with `just test-unit`.
"""

from __future__ import annotations

import struct
import subprocess
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def test_screen_stats_tell_a_desktop_from_a_black_frame(tmp_path: Path) -> None:
    script = ROOT / "scripts/screen-stats.py"
    header = b"P6\n64 64\n255\n"
    blank = tmp_path / "blank.ppm"
    blank.write_bytes(header + b"\x00" * (64 * 64 * 3))
    painted = tmp_path / "painted.ppm"
    painted.write_bytes(header + bytes((index * 7) % 256 for index in range(64 * 64 * 3)))

    # A black frame must fail, or the gate would call a dead display a login screen.
    assert subprocess.run([sys.executable, str(script), str(blank)], check=False).returncode == 1
    assert subprocess.run([sys.executable, str(script), str(painted)], check=False).returncode == 0


def test_screen_stats_keep_pixels_that_look_like_whitespace(tmp_path: Path) -> None:
    # Splitting the file on whitespace used to eat a first pixel of 0x0a or 0x20
    # and then call the frame truncated.
    script = ROOT / "scripts/screen-stats.py"
    frame = tmp_path / "frame.ppm"
    pixels = bytes([0x0A, 0x20, 0x09]) + bytes((index * 7) % 256 for index in range(64 * 64 * 3 - 3))
    frame.write_bytes(b"P6\n# a comment\n64 64\n255\n" + pixels)
    png = tmp_path / "frame.png"
    result = subprocess.run(
        [sys.executable, str(script), str(frame), "--png", str(png)],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout
    assert png.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")


def _rgba_png_alpha_columns(path: Path) -> tuple[int, int]:
    """Width and the right-most column with any opaque pixel, for an RGBA PNG.

    A few lines of PNG decoding instead of a Pillow dependency: the repository's
    checks must run on a bare runner.
    """
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, width = 8, b"", 0
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        kind = data[pos + 4 : pos + 8]
        body = data[pos + 8 : pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", body)
            assert (depth, colour, interlace) == (8, 6, 0), "expected 8-bit RGBA, not interlaced"
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = width * 4
    previous = bytearray(stride)
    right = -1
    for row in range(height):
        start = row * (stride + 1)
        kind, line = raw[start], bytearray(raw[start + 1 : start + 1 + stride])
        for i in range(stride):
            left = line[i - 4] if i >= 4 else 0
            up = previous[i]
            corner = previous[i - 4] if i >= 4 else 0
            if kind == 1:
                line[i] = (line[i] + left) & 0xFF
            elif kind == 2:
                line[i] = (line[i] + up) & 0xFF
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif kind == 4:
                guess = left + up - corner
                pa, pb, pc = abs(guess - left), abs(guess - up), abs(guess - corner)
                pred = left if pa <= pb and pa <= pc else up if pb <= pc else corner
                line[i] = (line[i] + pred) & 0xFF
        for x in range(width - 1, right, -1):
            if line[x * 4 + 3]:
                right = x
                break
        previous = line
    return width, right


def test_the_login_wordmark_fits_inside_its_canvas() -> None:
    # At a fixed 46 px the name ran past the right edge and GDM showed "DISTR"
    # with half a zero; render-assets.py now sizes it to leave a margin.
    width, right = _rgba_png_alpha_columns(ROOT / "system_files/usr/share/pixmaps/distr0-gdm-logo.png")
    assert right >= 0, "the wordmark is empty"
    assert right <= width - 4, f"the wordmark touches the right edge: last opaque column {right} of {width}"
