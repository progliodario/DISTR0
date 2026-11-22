"""Unit tests for scripts/validate.py.

The checker is what keeps the repository honest, so its own classification rules
need tests: a rule that silently stops matching would turn checks into no-ops.
Run with `just test-unit` (or `pytest -q tests`).
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("validate", ROOT / "scripts/validate.py")
validate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validate)  # type: ignore[union-attr]


@pytest.mark.parametrize(
    "token",
    [
        "system_files/etc/locale.conf",
        "Containerfile",
        "Justfile",
        "cosign.pub",
        "scripts/validate.py",
        "system_files/usr/share/{backgrounds,icons}",
    ],
)
def test_recognises_paths(token: str) -> None:
    assert validate.looks_like_path(token)


@pytest.mark.parametrize(
    "token",
    [
        "Europe/Rome",  # timezone
        "dnf5 install -y <pkg>",  # command
        "ghcr.io/progliodario/distr0:latest",  # registry reference
        "https://github.com/progliodario/DISTR0",  # URL
        "/etc/containers/policy.json",  # absolute path, not in the repo
        "podman.socket",  # unit name
        "sigstoreSigned",  # bare identifier
    ],
)
def test_rejects_non_paths(token: str) -> None:
    assert not validate.looks_like_path(token)


def test_expands_braces() -> None:
    assert validate.expand_braces("a/{b,c}/d") == ["a/b/d", "a/c/d"]
    assert validate.expand_braces("a/{b,c}/{d,e}") == ["a/b/d", "a/b/e", "a/c/d", "a/c/e"]
    assert validate.expand_braces("plain/path") == ["plain/path"]


def test_slug_matches_github_anchors() -> None:
    assert validate.slug("## Keeping the pins current") == "keeping-the-pins-current"
    assert validate.slug("### The policy is tested, not just declared") == (
        "the-policy-is-tested-not-just-declared"
    )


def test_recipe_names_reads_the_justfiles() -> None:
    justfile = validate.recipe_names("Justfile")
    assert {"build", "lint", "check-updates", "test", "test-unit"} <= justfile
    custom = validate.recipe_names("system_files/usr/share/ublue-os/just/60-custom.just")
    assert {"distr0-info", "distr0-verify", "distr0-doctor", "distr0-rollback"} <= custom


def test_every_shipped_asset_is_documented() -> None:
    """Provenance is part of shipping art: an undocumented file is unlicensed."""
    assets = (ROOT / "ASSETS.md").read_text(encoding="utf-8")
    shipped = [
        str(path.relative_to(ROOT))
        for root in validate.ASSET_ROOTS
        for path in (ROOT / root).rglob("*")
        if path.is_file()
    ]
    assert shipped
    assert [path for path in shipped if path not in assets] == []


def test_fastfetch_preset_is_json_and_points_at_the_mark() -> None:
    preset = json.loads(
        (ROOT / "system_files/usr/share/fastfetch/presets/distr0.jsonc").read_text(
            encoding="utf-8"
        )
    )
    source = preset["logo"]["source"]
    assert source == "/usr/share/distr0/ascii-logo.txt"
    assert (ROOT / "system_files" / source.lstrip("/")).is_file()
    assert preset["modules"][:3] == ["title", "os", "kernel"]


def test_banner_is_valid_bash_and_stays_quiet() -> None:
    banner = ROOT / "system_files/usr/share/distr0/banner.sh"
    assert subprocess.run(["bash", "-n", str(banner)], check=False).returncode == 0
    hook = (ROOT / "system_files/etc/profile.d/zz-distr0-banner.sh").read_text(encoding="utf-8")
    # Both guards are what keep the greeting out of scripts and second terminals.
    assert "$- == *i*" in hook
    assert "DISTR0_BANNER_SHOWN" in hook


def test_png_size_rejects_non_png(tmp_path: Path) -> None:
    fake = tmp_path / "fake.png"
    fake.write_bytes(b"not a png at all, but long enough")
    assert validate.png_size(fake) is None
    assert validate.png_size(tmp_path / "missing.png") is None


def test_self_test_ships_with_the_image() -> None:
    script = ROOT / "system_files/usr/share/distr0/selftest.sh"
    assert script.is_file()
    text = script.read_text(encoding="utf-8")
    # The self-test must assert the same scope the build installs, otherwise the
    # two can drift apart without either failing.
    assert "ghcr.io/progliodario/distr0" in text
    assert "sigstoreSigned" in text


def test_claim_matrix_uses_known_verdicts() -> None:
    rows = validate.claim_rows()
    assert len(rows) >= 12
    assert all(len(row) == 4 for row in rows)
    verdicts = {verdict.strip().lower() for row in rows for verdict in row[3].split("+")}
    assert verdicts <= validate.CLAIM_STATUSES
    # The gaps stay visible on purpose: an all-green matrix would be a lie.
    assert "machine only" in verdicts


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


def test_boot_gate_checks_are_valid_bash_and_cover_the_identity() -> None:
    script = ROOT / "scripts/boot-gate-checks.sh"
    assert subprocess.run(["bash", "-n", str(script)], check=False).returncode == 0
    text = script.read_text(encoding="utf-8")
    for marker in (
        "EXPECT_GDM_LOGO_SHA256",
        "EXPECT_LIGHT_WALLPAPER_SHA256",
        "EXPECT_BANNER_SHA256",
        "DISTR0_NO_BANNER",
        "/org/gnome/login-screen/logo",
        "/org/gnome/desktop/background/picture-uri",
    ):
        assert marker in text
