#!/usr/bin/env python3
"""Cross-file checks for DISTR0 that do not need an image build.

The same values live in more than one place (image pins, signature policy,
declared Flatpaks, recipe names), and an image build is the slowest way to find
out that they drifted apart. `just lint` and the Validate workflow run this.

Only the repository is read; nothing is modified and no network is used.
"""

from __future__ import annotations

import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILURES: list[str] = []
CHECKS = 0

PREINSTALL = "system_files/usr/share/flatpak/preinstall.d/distr0.preinstall"
EXPECTED_APPS = [
    "org.libreoffice.LibreOffice",
    "org.mozilla.Thunderbird",
    "org.mozilla.firefox",
    "org.videolan.VLC",
]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def check(label: str, ok: bool, detail: str = "") -> None:
    global CHECKS
    CHECKS += 1
    if ok:
        print(f"ok    {label}")
        return
    print(f"FAIL  {label}" + (f" — {detail}" if detail else ""))
    FAILURES.append(label)


def executable_lines(rel: str) -> list[str]:
    """Lines that actually run: comments are allowed to mention floating tags."""
    return [line for line in read(rel).splitlines() if not line.lstrip().startswith("#")]


def check_workflows() -> None:
    try:
        import yaml
    except ModuleNotFoundError:
        # Optional on a desktop, always installed in CI. TOML and every other
        # check below still run.
        print("skip  workflows parsed as YAML — PyYAML is not installed (CI installs it)")
        yaml = None

    paths = sorted((ROOT / ".github/workflows").glob("*.y*ml")) if yaml else []
    for path in paths:
        rel = path.relative_to(ROOT)
        try:
            doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as exc:
            check(f"{rel} is valid YAML", False, str(exc).splitlines()[0])
            continue
        # The trigger key parses as the boolean True under YAML 1.1, so it is
        # checked separately from the plain string keys.
        ok = (
            isinstance(doc, dict)
            and "jobs" in doc
            and "name" in doc
            and any(key in doc for key in ("on", True, "true"))
        )
        check(f"{rel} is a workflow", ok, "missing 'name', 'on' or 'jobs'")

    dependabot = ROOT / ".github/dependabot.yml"
    if yaml is not None and dependabot.exists():
        doc = yaml.safe_load(dependabot.read_text(encoding="utf-8")) or {}
        check(
            ".github/dependabot.yml is a dependabot config",
            isinstance(doc, dict) and "version" in doc and "updates" in doc,
        )
    for path in sorted((ROOT / "disk_config").glob("*.toml")):
        rel = path.relative_to(ROOT)
        try:
            tomllib.loads(path.read_text(encoding="utf-8"))
        except tomllib.TOMLDecodeError as exc:
            check(f"{rel} is valid TOML", False, str(exc))
            continue
        check(f"{rel} is valid TOML", True)


def check_pins() -> None:
    containerfile = read("Containerfile")
    check(
        "Containerfile pins the base image by digest",
        re.search(r"^FROM\s+\S+:\S+@sha256:[0-9a-f]{64}$", containerfile, re.MULTILINE) is not None,
        "expected FROM ghcr.io/…:tag@sha256:<64 hex>",
    )

    refs: set[str] = set()
    for rel in ("Justfile", ".github/workflows/build.yml"):
        found = [
            ref
            for line in executable_lines(rel)
            for ref in re.findall(r"quay\.io/coreos/chunkah[:@]([^\s\\'\"]*)", line)
        ]
        check(f"{rel} references chunkah", bool(found))
        refs.update(found)
    floating = sorted(ref for ref in refs if not ref.startswith("sha256:"))
    check("chunkah is never referenced by a floating tag", not floating, f"{floating}")
    check("Justfile and CI use the same chunkah digest", len(refs) == 1, f"{sorted(refs)}")


def check_supply_chain() -> None:
    # A branch can move under us between builds, so actions are pinned to a
    # commit SHA; the tag/version lives in the comment next to it.
    for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        rel = path.relative_to(ROOT)
        unpinned: list[str] = []
        for line in path.read_text(encoding="utf-8").splitlines():
            match = re.search(r"^\s*-?\s*uses:\s*(\S+)", line)
            if match and not re.match(r"^[^@]+@[0-9a-f]{40}$", match.group(1)):
                unpinned.append(match.group(1))
        check(f"{rel} pins every action to a commit SHA", not unpinned, f"{unpinned}")

    workflow = read(".github/workflows/build-disk.yml")
    justfile = read("Justfile")
    in_workflow = re.search(r"bootc-image-builder@(sha256:[0-9a-f]{64})", workflow)
    in_justfile = re.search(r"bootc-image-builder@(sha256:[0-9a-f]{64})", justfile)
    check(
        "build-disk.yml pins bootc-image-builder by digest",
        in_workflow is not None,
        "expected quay.io/centos-bootc/bootc-image-builder@sha256:…",
    )
    check(
        "Justfile pins bootc-image-builder by digest",
        in_justfile is not None,
        "expected quay.io/centos-bootc/bootc-image-builder@sha256:…",
    )
    if in_workflow and in_justfile:
        check(
            "workflow and Justfile use the same bootc-image-builder digest",
            in_workflow.group(1) == in_justfile.group(1),
            f"{in_workflow.group(1)} vs {in_justfile.group(1)}",
        )

    verify = ROOT / ".github/workflows/verify-image.yml"
    check("verify-image.yml exists", verify.exists())
    if verify.exists():
        text = verify.read_text(encoding="utf-8")
        check(
            "verify-image.yml uses the registries.d file the image ships",
            "system_files/etc/containers/registries.d" in text,
            "it must test the shipped file, not a copy of it",
        )


def check_verification() -> None:
    build = read("build_files/build.sh")
    check(
        "build.sh merges a sigstoreSigned scope into the container policy",
        '"type": "sigstoreSigned"' in build
        and "/usr/share/distr0/cosign.pub" in build
        and "jq" in build,
    )
    registries = read("system_files/etc/containers/registries.d/ghcr.io-progliodario.yaml")
    check(
        "registries.d enables sigstore attachments for the image",
        re.search(r"use-sigstore-attachments:\s*true", registries) is not None,
        registries.strip(),
    )
    check(
        "the installer ISO installs with --enforce-container-sigpolicy",
        "--enforce-container-sigpolicy" in read("disk_config/iso.toml"),
    )
    check(
        "cosign.pub is a PEM public key",
        read("cosign.pub").startswith("-----BEGIN PUBLIC KEY-----"),
    )


def check_declarations() -> None:
    apps = sorted(
        re.findall(r"^\[Flatpak Preinstall (\S+)\]$", read(PREINSTALL), re.MULTILINE)
    )
    check(
        "preinstall declares exactly Firefox, Thunderbird, LibreOffice and VLC",
        apps == EXPECTED_APPS,
        f"{apps}",
    )

    brewfile = read(
        "system_files/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile"
    )
    entries = [line for line in brewfile.splitlines() if line.strip() and not line.lstrip().startswith("#")]
    check(
        "every Brewfile entry is a brew formula",
        bool(entries) and all(re.match(r'\s*brew\s+"[^"]+"', line) for line in entries),
        f"{entries[:3]}",
    )


def check_defaults() -> None:
    check(
        "locale defaults to it_IT.UTF-8",
        "it_IT.UTF-8" in read("system_files/etc/locale.conf"),
    )
    localtime = ROOT / "system_files/etc/localtime"
    check(
        "/etc/localtime points into zoneinfo/Europe/Rome",
        localtime.is_symlink() and "zoneinfo/Europe/Rome" in str(localtime.readlink()),
        str(localtime.readlink()) if localtime.is_symlink() else "not a symlink",
    )
    check(
        "console keymap defaults to it2",
        "it2" in read("system_files/etc/vconsole.conf"),
    )


def check_recipes() -> None:
    custom = read("system_files/usr/share/ublue-os/just/60-custom.just")
    for recipe in (
        "distr0-info",
        "distr0-update",
        "distr0-apps",
        "distr0-cli",
        "distr0-reset-desktop",
        "distr0-lang",
        "distr0-verify",
    ):
        check(
            f"60-custom.just defines {recipe}",
            re.search(rf"^{recipe}\b", custom, re.MULTILINE) is not None,
        )
    justfile = read("Justfile")
    for recipe in ("build", "rechunk", "lint", "check-updates"):
        check(
            f"Justfile defines {recipe}",
            re.search(rf"^{recipe}\b", justfile, re.MULTILINE) is not None,
        )


def recipe_names(rel: str) -> set[str]:
    names: set[str] = set()
    for line in read(rel).splitlines():
        match = re.match(r"^([a-zA-Z_][a-zA-Z0-9_-]*)(?:\s[^:]*)?:", line)
        if match:
            names.add(match.group(1))
    return names


# A command reference ends in a letter or digit and is not the prefix of a glob,
# so `ujust distr0-*` (prose) is not mistaken for a recipe name.
COMMAND = r"([a-zA-Z][a-zA-Z0-9-]*[a-zA-Z0-9])(?![\w*-])"

# Recipes that Bluefin ships and we only point at; they are not in 60-custom.just.
UPSTREAM_UJUST = {"bbrew"}


def check_docs() -> None:
    agents = ROOT / "AGENTS.md"
    check("AGENTS.md exists", agents.exists())
    claude = ROOT / "CLAUDE.md"
    check(
        "CLAUDE.md is a symlink to AGENTS.md",
        claude.is_symlink() and claude.resolve() == agents.resolve(),
        "one source of truth beats two copies that drift",
    )
    for rel in (".editorconfig", ".gitattributes", ".github/PULL_REQUEST_TEMPLATE.md"):
        check(f"{rel} exists", (ROOT / rel).exists())
    if not agents.exists():
        return

    text = read("AGENTS.md")
    for topic in ("## Invariants", "## Map", "just lint", "just check"):
        check(f"AGENTS.md documents {topic}", topic in text)

    just_recipes = recipe_names("Justfile") | set(
        re.findall(r"^alias\s+([a-zA-Z0-9_-]+)\s*:=", read("Justfile"), re.MULTILINE)
    )
    ujust_recipes = recipe_names("system_files/usr/share/ublue-os/just/60-custom.just")

    for rel in (
        "README.md",
        "AGENTS.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "system_files/usr/share/doc/distr0/README.md",
    ):
        if not (ROOT / rel).exists():
            check(f"{rel} exists", False)
            continue
        doc = read(rel)
        named_just = set(re.findall(rf"`just {COMMAND}", doc))
        named_just |= set(re.findall(rf"^(?:sudo )?just {COMMAND}", doc, re.MULTILINE))
        named_ujust = set(re.findall(rf"`ujust {COMMAND}", doc))
        named_ujust |= set(re.findall(rf"^(?:sudo )?ujust {COMMAND}", doc, re.MULTILINE))
        check(
            f"{rel} only mentions real just recipes",
            named_just <= just_recipes,
            f"{sorted(named_just - just_recipes)}",
        )
        check(
            f"{rel} only mentions real ujust recipes",
            named_ujust <= ujust_recipes | UPSTREAM_UJUST,
            f"{sorted(named_ujust - ujust_recipes - UPSTREAM_UJUST)}",
        )


def main() -> int:
    check_workflows()
    check_pins()
    check_supply_chain()
    check_verification()
    check_declarations()
    check_defaults()
    check_recipes()
    check_docs()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} of {CHECKS} checks failed")
        return 1
    print(f"all {CHECKS} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
