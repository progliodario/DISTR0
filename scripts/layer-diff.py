#!/usr/bin/env python3
"""Compare the layers of two image manifests and report what an update costs.

The point of rechunking is that an update downloads only the chunks that
changed. Two image manifests (OCI or Docker v2) carry exactly the information
needed to check that claim: the list of layer digests and their compressed
sizes. This script compares them without pulling anything.

Usage:
    scripts/layer-diff.py OLD.json NEW.json [--summary FILE]

Get the manifests with:
    skopeo inspect --raw docker://ghcr.io/OWNER/IMAGE:latest > manifest.json

`--summary` appends a Markdown table to FILE (GitHub's $GITHUB_STEP_SUMMARY).
Exit status: 0 on success, non-zero when an input is not a single image manifest.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

LAYER_KEYS = ("layers",)


def human(size: int) -> str:
    value = float(size)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1000 or unit == "TB":
            return f"{value:.0f} {unit}" if unit == "B" else f"{value:.1f} {unit}"
        value /= 1000
    return f"{value:.1f} TB"


def layers(manifest: dict, label: str) -> dict[str, int]:
    """Map layer digest -> compressed size."""
    if "manifests" in manifest:
        raise SystemExit(
            f"{label} is an image index, not a manifest: compare one architecture "
            "(skopeo inspect --raw --override-arch amd64 ...)"
        )
    found = {}
    for layer in manifest.get("layers", []):
        digest = layer.get("digest")
        if not digest:
            continue
        found[digest] = int(layer.get("size") or 0)
    if not found:
        raise SystemExit(f"{label} has no layers")
    return found


def load(path: str, label: str) -> dict[str, int]:
    text = Path(path).read_text(encoding="utf-8").strip()
    if not text or text == "{}":
        raise SystemExit(f"{label} is empty: there is no previous image to compare")
    return layers(json.loads(text), label)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("old", help="manifest of the image currently published")
    parser.add_argument("new", help="manifest of the image just built")
    parser.add_argument("--summary", help="append a Markdown table to this file")
    args = parser.parse_args()

    old = load(args.old, "the previous manifest")
    new = load(args.new, "the new manifest")

    shared = [digest for digest in new if digest in old]
    added = [digest for digest in new if digest not in old]
    removed = [digest for digest in old if digest not in new]

    old_size = sum(old.values())
    new_size = sum(new.values())
    shared_size = sum(new[digest] for digest in shared)
    download_size = sum(new[digest] for digest in added)
    share = 100.0 * len(shared) / len(new) if new else 0.0

    print(f"previous: {len(old):>4} layers, {human(old_size)} compressed")
    print(f"current:  {len(new):>4} layers, {human(new_size)} compressed")
    print(
        f"shared:   {len(shared):>4} layers, {human(shared_size)} "
        f"({share:.0f}% of the current layers)"
    )
    print(f"update:   downloads {human(download_size)} ({len(added)} new layers, {len(removed)} dropped)")

    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write("### Layer reuse\n\n")
            handle.write("| | layers | compressed |\n|---|---:|---:|\n")
            handle.write(f"| previous image | {len(old)} | {human(old_size)} |\n")
            handle.write(f"| this image | {len(new)} | {human(new_size)} |\n")
            handle.write(f"| shared | {len(shared)} ({share:.0f}%) | {human(shared_size)} |\n")
            handle.write(f"| **an update downloads** | **{len(added)} new** | **{human(download_size)}** |\n\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
