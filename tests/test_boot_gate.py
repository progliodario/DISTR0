"""Unit tests for the boot gate's scripts.

The gate itself needs KVM and a published image; these tests cover the parts
that decide what it reports: finding the ostree deployment, writing the guest's
unit, reading the report back, the CI wrapper's annotations, and the `ujust`
import order the recipe overrides rely on. Run with `just test-unit`.
"""

from __future__ import annotations

import subprocess

import pytest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


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


def test_boot_gate_local_mode_skips_the_pull_and_keeps_the_revision_check() -> None:
    text = (ROOT / "scripts/boot-gate.sh").read_text(encoding="utf-8")
    assert "--local)" in text and "podman image exists" in text
    # The revision check must apply to a local image too: CI passes the commit.
    assert '[[ -z ${EXPECT_REVISION} || -n ${IMAGE} ]]' in text
    result = subprocess.run(
        ["bash", str(ROOT / "scripts/boot-gate.sh"), "--local", "x", "--disk", "y"],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0 and "not both" in result.stderr


def test_boot_gate_ci_wrapper_annotates_failures(tmp_path: Path) -> None:
    # A fake gate that fails two checks: the wrapper must exit non-zero and turn
    # each FAIL line into an error annotation, and each PHASE into a notice.
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    wrapper = scripts / "boot-gate-ci.sh"
    wrapper.write_text((ROOT / "scripts/boot-gate-ci.sh").read_text(encoding="utf-8"))
    fake = scripts / "boot-gate.sh"
    fake.write_text("#!/usr/bin/env bash\necho 'PHASE booting'\necho 'FAIL  one'\necho 'FAIL  two'\nexit 1\n")
    fake.chmod(0o755)
    result = subprocess.run(
        ["bash", str(wrapper), str(tmp_path / "work")], check=False, capture_output=True, text=True
    )
    assert result.returncode == 1
    assert "::notice title=DISTR0 boot gate::booting" in result.stdout
    assert result.stdout.count("::error title=DISTR0 boot gate::FAIL") == 2


def test_custom_recipes_override_bluefin_when_imported_first(tmp_path: Path) -> None:
    # The mechanism build.sh relies on: with allow-duplicate-recipes, `just`
    # keeps the definition from the *first* import. Prove it with the real
    # 60-custom.just against a stand-in for Bluefin's system.just.
    just = subprocess.run(["bash", "-c", "command -v just"], capture_output=True, text=True).stdout.strip()
    if not just:
        pytest.skip("just is not installed")
    bluefin = tmp_path / "system.just"
    bluefin.write_text("toggle-devmode:\n    echo bluefin-dx\n")
    custom = ROOT / "system_files/usr/share/ublue-os/just/60-custom.just"
    entry = tmp_path / "00-entry.just"
    entry.write_text(
        f'set allow-duplicate-recipes := true\nimport? "{custom}"\nimport "{bluefin}"\n'
    )
    shown = subprocess.run(
        [just, "--justfile", str(entry), "--working-directory", str(tmp_path), "--show", "toggle-devmode"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    assert "DISTR0" in shown and "bluefin-dx" not in shown
