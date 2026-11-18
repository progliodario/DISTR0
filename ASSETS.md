# Assets

Every image in this repository is generated here, from the palette and the mark
in `distr0-logo.svg`: nothing is copied from a third party, so the whole set is
distributed under the repository's Apache-2.0 license. This file exists because
an asset without provenance is an asset nobody can legally ship or safely change.

| File | Used by | Generated |
| --- | --- | --- |
| `system_files/usr/share/icons/hicolor/scalable/apps/distr0-logo.svg` | `LOGO=distr0-logo` in `os-release`, the app grid, `distr0-logo` lookups | Hand-written SVG, 512×512, safe area 112 px |
| `system_files/usr/share/backgrounds/distr0/distr0-wallpaper.png` | Dark-mode wallpaper (`picture-uri-dark`), screensaver | 2560×1440, radial glow on `#070a18` |
| `system_files/usr/share/backgrounds/distr0/distr0-wallpaper-light.png` | Light-mode wallpaper (`picture-uri`) | `scripts/render-assets.py` |
| `system_files/usr/share/pixmaps/distr0-gdm-logo.png` | `org.gnome.login-screen logo` | `scripts/render-assets.py`, 300×128 wordmark |
| `system_files/usr/share/distr0/ascii-logo.txt` | The `logo` of the fastfetch preset | Hand-written, the same mark in block characters |

## Regenerating

```bash
python3 scripts/render-assets.py     # needs Pillow; writes the two PNGs
just assets                          # same, with a check for Pillow first
```

The raster assets are committed on purpose: the image build must not depend on
Pillow or on a font being installed on the build host, and the committed PNG is
the one that ships. The script is deterministic (fixed colours, fixed geometry,
no randomness), so regenerating an unchanged script reproduces the same pixels.

The two wallpapers are one design in two modes: a soft glow in the upper right
over a ring, dark ink `#070a18` for dark mode and paper `#f4f6fb` for light mode.
The accent colours are `#5ad1ff` (cyan) and `#7a6bff` (indigo), the same pair the
SVG logo and `zz0-distr0.gschema.override` use.

## Rules

- Add a row for every new file under `system_files/usr/share/{backgrounds,icons,pixmaps}`;
  `just lint` fails when one is missing.
- Only add art that this repository may redistribute. No distro logos, no
  wallpapers of unknown origin, no stock images.
- Keep the SVG the master. Raster copies are rendered from its palette, so a
  palette change is one edit plus `just assets`.
