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


def _gate(snippet: str, *args: str) -> subprocess.CompletedProcess[str]:
    """Run a snippet with scripts/boot-gate.sh sourced, without running the gate."""
    return subprocess.run(
        ["bash", "-c", f"source {ROOT / 'scripts/boot-gate.sh'}; SUDO=(); {snippet}", "_", *args],
        check=False,
        capture_output=True,
        text=True,
    )


def test_boot_gate_finds_the_deployment_under_the_physical_root(tmp_path: Path) -> None:
    # A bootc disk's root partition has no /etc of its own: the system's /etc
    # is the deployment's, which is where the gate must write its unit.
    deployment = tmp_path / "ostree/deploy/default/deploy/abc123.0"
    (deployment / "etc/systemd/system").mkdir(parents=True)
    (deployment / "etc/profile.d").mkdir()
    (deployment / "etc/gdm").mkdir()
    (deployment / "etc/gdm/custom.conf").write_text("# GDM configuration storage\n\n[daemon]\n\n[security]\n")
    (tmp_path / "boot/loader").mkdir(parents=True)
    result = _gate('find_deployment "$1"', str(tmp_path))
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines() == [str(deployment)]

    result = _gate('write_guest_checks "$1"', str(deployment))
    assert result.returncode == 0, result.stderr
    etc = deployment / "etc"
    unit = (etc / "systemd/system/distr0-boot-gate.service").read_text()
    assert "After=display-manager.service" in unit
    assert "WantedBy=graphical.target" in unit
    link = etc / "systemd/system/graphical.target.wants/distr0-boot-gate.service"
    assert link.is_symlink() and link.resolve() == (etc / "systemd/system/distr0-boot-gate.service")
    run = (etc / "distr0-boot-gate/run.sh").read_text()
    assert subprocess.run(["bash", "-n", str(etc / "distr0-boot-gate/run.sh")], check=False).returncode == 0
    assert "DISTR0-BOOT-GATE-GREETER" in run and "DISTR0-BOOT-GATE-END" in run
    assert "EXPECT_GDM_LOGO_SHA256=" in run
    assert (etc / "distr0-boot-gate/checks.sh").read_text() == (ROOT / "scripts/boot-gate-checks.sh").read_text()
    # A disk with no account would otherwise boot into gnome-initial-setup.
    gdm = (etc / "gdm/custom.conf").read_text()
    assert "[daemon]\nInitialSetupEnable=False\n" in gdm and "[security]" in gdm

    # Writing the checks twice (a rerun on the same disk) changes nothing.
    assert _gate('write_guest_checks "$1"', str(deployment)).returncode == 0
    assert (etc / "gdm/custom.conf").read_text() == gdm


def test_boot_gate_reads_the_report_between_its_markers(tmp_path: Path) -> None:
    (tmp_path / "console.log").write_text("kernel noise\r\n")
    (tmp_path / "guest-report.log").write_text(
        "DISTR0-BOOT-GATE-BEGIN\r\nDISTR0-BOOT-GATE-GREETER up\r\nok    a check\r\nEXIT=0\r\n"
        "DISTR0-BOOT-GATE-END\r\n"
    )
    result = _gate('WORKDIR="$1"; read_guest_log', str(tmp_path))
    assert result.returncode == 0, result.stdout
    assert result.stdout.splitlines() == ["ok    a check", "EXIT=0"]

    (tmp_path / "guest-report.log").write_text("DISTR0-BOOT-GATE-BEGIN\nFAIL  a check\nEXIT=1\nDISTR0-BOOT-GATE-END\n")
    assert _gate('WORKDIR="$1"; read_guest_log', str(tmp_path)).returncode == 1

    (tmp_path / "guest-report.log").write_text("")
    result = _gate('WORKDIR="$1"; read_guest_log', str(tmp_path))
    assert result.returncode == 1
    assert "left no check report" in result.stdout


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
