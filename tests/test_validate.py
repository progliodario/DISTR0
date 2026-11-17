"""Unit tests for scripts/validate.py.

The checker is what keeps the repository honest, so its own classification rules
need tests: a rule that silently stops matching would turn checks into no-ops.
Run with `just test-unit` (or `pytest -q tests`).
"""

from __future__ import annotations

import importlib.util
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


def test_self_test_ships_with_the_image() -> None:
    script = ROOT / "system_files/usr/share/distr0/selftest.sh"
    assert script.is_file()
    text = script.read_text(encoding="utf-8")
    # The self-test must assert the same scope the build installs, otherwise the
    # two can drift apart without either failing.
    assert "ghcr.io/progliodario/distr0" in text
    assert "sigstoreSigned" in text
