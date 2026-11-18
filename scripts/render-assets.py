#!/usr/bin/env python3
"""Regenerate DISTR0's raster assets deterministically.

The PNGs this writes are committed: the image build does not depend on Pillow,
and the same script produces the same pixels on any machine. It exists so the
assets can be changed without a design tool, and so their provenance is readable.

    python3 scripts/render-assets.py        # needs Pillow
    just assets                             # same, with a friendlier error

Outputs:
    system_files/usr/share/backgrounds/distr0/distr0-wallpaper-light.png
    system_files/usr/share/pixmaps/distr0-gdm-logo.png
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:  # pragma: no cover - developer convenience
    sys.exit("Pillow is required: python3 -m pip install pillow")

ROOT = Path(__file__).resolve().parent.parent
BACKGROUNDS = ROOT / "system_files/usr/share/backgrounds/distr0"
PIXMAPS = ROOT / "system_files/usr/share/pixmaps"

# The palette the SVG logo and the dconf defaults use.
INK = (7, 10, 24)
CYAN = (90, 209, 255)
INDIGO = (122, 107, 255)
PAPER = (244, 246, 251)

FONT_CANDIDATES = (
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf",
)


def font_candidates() -> list[str]:
    """DejaVu from the system, then the copy matplotlib ships for its plots."""
    candidates = list(FONT_CANDIDATES)
    try:
        import matplotlib
    except ImportError:
        return candidates
    candidates.append(str(Path(matplotlib.__file__).parent / "mpl-data/fonts/ttf/DejaVuSans-Bold.ttf"))
    return candidates


def font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for candidate in font_candidates():
        if Path(candidate).is_file():
            print(f"font: {candidate}")
            return ImageFont.truetype(candidate, size)
    print("font: Pillow default (no DejaVu found, wordmark will be plainer)")
    try:
        return ImageFont.load_default(size=size)
    except TypeError:  # Pillow < 10.1
        return ImageFont.load_default()


def gradient(width: int, height: int, start: tuple[int, int, int], end: tuple[int, int, int]) -> Image.Image:
    """Diagonal gradient, one pixel row at a time: no randomness, no numpy."""
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)
    for x in range(width):
        ratio = x / max(width - 1, 1)
        colour = tuple(round(a + (b - a) * ratio) for a, b in zip(start, end, strict=True))
        draw.line(((x, 0), (x, height)), fill=colour)
    return image


def light_wallpaper() -> Path:
    """The daytime companion to the existing dark wallpaper: same glow, inverted."""
    width, height = 2560, 1440
    base = Image.new("RGBA", (width, height), PAPER + (255,))

    glow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    draw.ellipse((1750, -180, 3100, 900), fill=INDIGO + (58,))
    draw.ellipse((2050, 20, 2950, 760), fill=CYAN + (52,))
    draw.ellipse((-420, 900, 700, 1800), fill=INDIGO + (22,))
    glow = glow.filter(ImageFilter.GaussianBlur(190))

    ring = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse((1960, 120, 2820, 980), outline=INDIGO + (52,), width=10)
    ring = ring.filter(ImageFilter.GaussianBlur(3))

    image = Image.alpha_composite(base, glow)
    image = Image.alpha_composite(image, ring)
    out = BACKGROUNDS / "distr0-wallpaper-light.png"
    image.convert("RGB").save(out, optimize=True)
    return out


def gdm_logo() -> Path:
    """Wordmark for the login screen: a square mark plus the name, on transparency."""
    width, height = 300, 128
    image = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    badge = gradient(96, 96, CYAN, INDIGO).convert("RGBA")
    mask = Image.new("L", (96, 96), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 95, 95), radius=26, fill=255)
    image.paste(badge, (6, 16), mask)

    badge_font = font(62)
    mark = "D"
    box = draw.textbbox((0, 0), mark, font=badge_font)
    draw.text(
        (6 + (96 - (box[2] - box[0])) / 2 - box[0], 16 + (96 - (box[3] - box[1])) / 2 - box[1]),
        mark,
        font=badge_font,
        fill=(255, 255, 255, 255),
    )

    word_font = font(46)
    box = draw.textbbox((0, 0), "DISTR0", font=word_font)
    draw.text((120, (height - (box[3] - box[1])) / 2 - box[1]), "DISTR0", font=word_font, fill=(255, 255, 255, 255))

    out = PIXMAPS / "distr0-gdm-logo.png"
    image.save(out, optimize=True)
    return out


def main() -> int:
    BACKGROUNDS.mkdir(parents=True, exist_ok=True)
    PIXMAPS.mkdir(parents=True, exist_ok=True)
    for path in (light_wallpaper(), gdm_logo()):
        size = path.stat().st_size
        print(f"wrote {path.relative_to(ROOT)} ({size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
