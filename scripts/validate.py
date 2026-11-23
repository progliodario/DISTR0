#!/usr/bin/env python3
"""Cross-file checks for DISTR0 that do not need an image build.

The same values live in more than one place (image pins, signature policy,
declared Flatpaks, recipe names), and an image build is the slowest way to find
out that they drifted apart. `just lint` and the Validate workflow run this.

Only the repository is read; nothing is modified and no network is used.
"""

from __future__ import annotations

import json
import re
import struct
import subprocess
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

    # One update bot: Dependabot and Renovate both bumped the same actions and
    # doubled every pull request and branch. Renovate also tracks the digests
    # pinned in the Justfile and the workflows, which Dependabot cannot.
    check(
        "Renovate is the only update bot",
        (ROOT / ".github/renovate.json5").is_file() and not (ROOT / ".github/dependabot.yml").exists(),
        "keep .github/renovate.json5, do not add .github/dependabot.yml",
    )
    bootc_install = sorted((ROOT / "system_files/usr/lib/bootc/install").glob("*.toml"))
    for path in [*sorted((ROOT / "disk_config").glob("*.toml")), *bootc_install]:
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
        digests = {in_workflow.group(1), in_justfile.group(1)}
        check(
            "build-disk.yml and Justfile use the same bootc-image-builder digest",
            len(digests) == 1,
            f"{sorted(digests)}",
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
        "distr0-greeting",
        "distr0-update",
        "distr0-apps",
        "distr0-cli",
        "distr0-reset-desktop",
        "distr0-lang",
        "distr0-verify",
        "distr0-doctor",
        "distr0-rollback",
        "distr0-smartcard",
        # Bluefin's recipes that would leave DISTR0 or describe Bluefin; build.sh
        # imports 60-custom.just first so these definitions win.
        "toggle-devmode",
        "rebase-helper",
        "changelogs",
        "toggle-user-motd",
    ):
        check(
            f"60-custom.just defines {recipe}",
            re.search(rf"^{recipe}\b", custom, re.MULTILINE) is not None,
        )
    switches = [
        line.strip()
        for line in custom.splitlines()
        if "bootc switch" in line and not line.strip().startswith("#")
    ]
    check(
        "60-custom.just only ever switches to DISTR0, with the signature policy",
        "image=ghcr.io/progliodario/distr0" in custom
        and all(
            "--enforce-container-sigpolicy" in line
            and ("${image}" in line or "ghcr.io/progliodario/distr0" in line)
            for line in switches
        ),
        f"{switches}",
    )
    justfile = read("Justfile")
    # A local build must carry what CI's does, or `just boot-gate-local` tests
    # an image with another version and no revision to check.
    workflow = read(".github/workflows/build.yml")
    for arg in ("DISTR0_BUILD_DATE", "DISTR0_REVISION"):
        check(
            f"`just build` and CI both pass {arg}",
            f"{arg}=" in justfile and f"{arg}=" in workflow and arg in read("Containerfile"),
        )
    for recipe in (
        "build",
        "rechunk",
        "lint",
        "assets",
        "check-updates",
        "test",
        "test-unit",
        "boot-gate",
        "boot-gate-local",
    ):
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
# `devmode` is Bluefin's alias that calls toggle-devmode, which DISTR0 replaces.
UPSTREAM_UJUST = {"bbrew", "devmode"}


def check_image_promises() -> None:
    """The promises the image makes about itself, checked against the sources."""
    build = read("build_files/build.sh")
    check(
        "build.sh sets IMAGE_ID to distr0",
        re.search(r"^set_os_release IMAGE_ID '?distr0'?$", build, re.MULTILINE) is not None,
    )
    check("build.sh sets IMAGE_VERSION to DISTR0's own build", 'set_os_release IMAGE_VERSION "${image_version}"' in build)
    check("build.sh keeps OSTREE_VERSION from the base", "OSTREE_VERSION" in build)
    check(
        "build.sh points image-info.json at DISTR0",
        "image-info.json" in build and '"image-name": "distr0"' in build,
        "Bluefin's motd, changelog and rebase helpers read the image from it",
    )
    check(
        "build.sh imports 60-custom.just first",
        "00-entry.just" in build and "custom_import" in build,
        "ujust keeps the first definition of a recipe; imported last, DISTR0 cannot override Bluefin",
    )
    check("build.sh sets the default hostname", 'DEFAULT_HOSTNAME \'"distr0"\'' in build)
    check(
        "the Containerfile writes /etc/hostname with COPY",
        "COPY --from=ctx /system_files/etc/hostname /etc/hostname" in read("Containerfile")
        and read("system_files/etc/hostname").strip() == "distr0",
        "a RUN step writes into the builder's bind-mounted /etc/hostname, which is never committed",
    )
    check(
        "build.sh leaves no dnf state in /var or /run",
        "rm -rf /var/lib/dnf /run/dnf" in build,
        "bootc container lint --fatal-warnings rejects it",
    )
    check(
        "the Containerfile lints with fatal warnings",
        "bootc container lint --fatal-warnings" in read("Containerfile"),
    )
    check(
        "build.sh installs packages without weak dependencies",
        "install_weak_deps=False" in build,
        "reproducibility: a new weak dependency upstream must not change the image",
    )

    selftest = ROOT / "system_files/usr/share/distr0/selftest.sh"
    check("the image ships a self-test", selftest.is_file())
    if selftest.is_file():
        text = selftest.read_text(encoding="utf-8")
        check(
            "the self-test is executable",
            bool(selftest.stat().st_mode & 0o111),
            "chmod +x system_files/usr/share/distr0/selftest.sh",
        )
        for claim in ("IMAGE_ID", "sigstoreSigned", "distr0-doctor", "distr0-greeting", "accent-color"):
            check(f"the self-test asserts {claim}", claim in text)
    check(
        "`just test` runs the self-test",
        "selftest.sh" in read("Justfile"),
        "the recipe exists but no longer runs the shipped test",
    )
    check("tests/test_validate.py exists", (ROOT / "tests/test_validate.py").is_file())


ASSET_ROOTS = (
    "system_files/usr/share/backgrounds",
    "system_files/usr/share/icons",
    "system_files/usr/share/pixmaps",
)


def image_path(path: str) -> Path:
    """An absolute path inside the image -> the file under system_files/."""
    return ROOT / "system_files" / path.lstrip("/")


def png_size(path: Path) -> tuple[int, int] | None:
    """Width and height from a PNG header, or None when it is not a PNG."""
    try:
        data = path.read_bytes()[:24]
    except OSError:
        return None
    if len(data) < 24 or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        return None
    return struct.unpack(">II", data[16:24])


def check_identity() -> None:
    """The desktop identity: banner, fastfetch, schema defaults, GDM, art."""
    banner = "system_files/usr/share/distr0/banner.sh"
    hook = "system_files/etc/profile.d/zz-distr0-banner.sh"
    check(f"{banner} exists", (ROOT / banner).is_file())
    check(f"{hook} exists", (ROOT / hook).is_file())
    if (ROOT / hook).is_file():
        hook_text = read(hook)
        check("the login banner only greets interactive shells", "$- == *i*" in hook_text)
        check("the login banner greets once per session", "DISTR0_BANNER_SHOWN" in hook_text)
        check("the login banner can be disabled", "DISTR0_NO_BANNER" in hook_text)
    if (ROOT / banner).is_file():
        result = subprocess.run(
            ["bash", "-n", str(ROOT / banner)], capture_output=True, text=True, check=False
        )
        check("the banner text is valid bash", result.returncode == 0, result.stderr.strip())

    preset_path = "system_files/usr/share/fastfetch/presets/distr0.jsonc"
    preset: dict = {}
    try:
        loaded = json.loads(read(preset_path))
    except (OSError, json.JSONDecodeError) as exc:
        check("the fastfetch preset is valid JSON", False, str(exc))
    else:
        preset = loaded if isinstance(loaded, dict) else {}
        check("the fastfetch preset is valid JSON", bool(preset))
    mark = str((preset.get("logo") or {}).get("source", ""))
    check(
        "the fastfetch preset uses a mark that ships in the image",
        bool(mark) and image_path(mark).is_file(),
        f"logo.source: {mark or 'missing'}",
    )
    check("the fastfetch preset lists modules", bool(preset.get("modules")), f"{preset.get('modules')}")

    build = read("build_files/build.sh")
    check(
        "build.sh compiles the gschema overrides",
        "glib-compile-schemas /usr/share/glib-2.0/schemas" in build,
        "an override that is not compiled is ignored by the desktop",
    )
    override = "system_files/usr/share/glib-2.0/schemas/zz0-distr0.gschema.override"
    check(f"{override} exists", (ROOT / override).is_file())
    if (ROOT / override).is_file():
        text = read(override)
        check("the gschema override sets the accent colour", "accent-color='blue'" in text)
        check(
            "the gschema override sets the window buttons",
            "button-layout=':minimize,maximize,close'" in text,
        )
        check(
            "the override sorts after the schemas it overrides",
            Path(override).name.startswith("zz"),
            Path(override).name,
        )

    gdm = "system_files/etc/dconf/db/gdm.d/01-distr0-gdm"
    gdm_logo = "/usr/share/pixmaps/distr0-gdm-logo.png"
    check(f"{gdm} exists", (ROOT / gdm).is_file())
    if (ROOT / gdm).is_file():
        check(
            "GDM points at a wordmark that ships in the image",
            f"logo='{gdm_logo}'" in read(gdm) and image_path(gdm_logo).is_file(),
            gdm_logo,
        )

    branding = read("system_files/etc/dconf/db/distro.d/99-distr0-branding")
    light = "/usr/share/backgrounds/distr0/distr0-wallpaper-light.png"
    dark = "/usr/share/backgrounds/distr0/distr0-wallpaper.png"
    check("light mode uses the light wallpaper", f"picture-uri='file://{light}'" in branding, light)
    check("dark mode uses the dark wallpaper", f"picture-uri-dark='file://{dark}'" in branding, dark)
    for rel in (light, dark):
        size = png_size(image_path(rel))
        check(
            f"{rel} is a wallpaper-sized PNG",
            size is not None and size[0] >= 1920 and size[1] >= 1080,
            f"{size}",
        )

    shipped = sorted(
        str(path.relative_to(ROOT))
        for root in ASSET_ROOTS
        for path in (ROOT / root).rglob("*")
        if path.is_file()
    )
    assets = read("ASSETS.md")
    undocumented = [path for path in shipped if path not in assets]
    check("ASSETS.md documents every shipped image", not undocumented, f"undocumented: {undocumented}")


CLAIM_STATUSES = {
    "boot gate",
    "image self-test",
    "repository check",
    "registry check",
    "measurement",
    "machine only",
}

CLAIMS = "docs/claims.md"


def claim_rows(rel: str = CLAIMS) -> list[list[str]]:
    """The data rows of the promises table, without header and separator."""
    rows: list[list[str]] = []
    for line in read(rel).splitlines():
        if not line.startswith("|"):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if cells[0] == "Promise" or set(cells[0]) <= {"-", ":"}:
            continue
        rows.append(cells)
    return rows


def check_boot_gate() -> None:
    """The gate is the only place a promise about a *booted* system can live."""
    workflow = ROOT / ".github/workflows/boot-gate.yml"
    check(".github/workflows/boot-gate.yml exists", workflow.is_file())
    if workflow.is_file():
        text = workflow.read_text(encoding="utf-8")
        try:
            import yaml
        except ModuleNotFoundError:
            yaml = None
        if yaml is not None:
            doc = yaml.safe_load(text) or {}
            triggers = doc.get("on") or doc.get(True) or {}
            run = triggers.get("workflow_run") if isinstance(triggers, dict) else None
            check(
                "the boot gate follows a successful build on main",
                isinstance(run, dict)
                and "main" in (run.get("branches") or [])
                and "completed" in (run.get("types") or [])
                and "conclusion == 'success'" in text,
                f"workflow_run: {run}",
            )
        else:
            check(
                "the boot gate follows a successful build on main",
                "workflow_run" in text and "conclusion == 'success'" in text,
            )
        check(
            "the boot gate checks out the commit that was built",
            "workflow_run.head_sha" in text,
        )
        check("the boot gate runs the shipped script", "scripts/boot-gate-ci.sh" in text)
        gate_ci = ROOT / "scripts/boot-gate-ci.sh"
        check(
            "the CI wrapper runs scripts/boot-gate.sh",
            gate_ci.is_file() and "boot-gate.sh" in gate_ci.read_text(encoding="utf-8").replace("boot-gate-ci.sh", ""),
        )
        check("the boot gate can also be started by hand", "workflow_dispatch" in text)
        check("the boot gate keeps the login screen", "login-screen.ppm" in text)

    script = ROOT / "scripts/boot-gate.sh"
    check("scripts/boot-gate.sh exists", script.is_file())
    if script.is_file():
        text = script.read_text(encoding="utf-8")
        check("the gate boots QEMU", "qemu-system-x86_64" in text)
        check(
            "the gate installs the image with its own installer",
            "bootc install to-disk" in text,
            "bootc-image-builder takes long enough that a gate would time out",
        )
        check(
            "the gate waits for the login screen",
            "DISTR0-BOOT-GATE-GREETER" in text and "screendump" in text,
            "the screenshot is taken once the guest reports the greeter",
        )
        check(
            "the gate writes its checks into the ostree deployment",
            "ostree/deploy/" in text,
            "the root partition of a bootc disk has no /etc of its own",
        )
        check(
            "the gate boots with SELinux as users get it",
            "--disable-selinux" not in text,
            "--disable-selinux adds selinux=0 to the kernel command line",
        )
        check("the gate screenshots the framebuffer", "screendump" in text)
        check("the gate runs the in-guest checks", "scripts/boot-gate-checks.sh" in text)
        check(
            "the gate refuses an image built from another commit",
            "--expect-revision" in text and "org.opencontainers.image.revision" in text,
            "otherwise a green run can describe a different build",
        )
        check(
            "the gate falls back to emulation without KVM",
            "/dev/kvm" in text and "tcg" in text,
        )

    checks = ROOT / "scripts/boot-gate-checks.sh"
    check("scripts/boot-gate-checks.sh exists", checks.is_file())
    if checks.is_file():
        text = checks.read_text(encoding="utf-8")
        for label, marker in (
            ("GDM running in the guest", "gdm.service"),
            ("the GDM wordmark by hash", "EXPECT_GDM_LOGO_SHA256"),
            ("the light wallpaper by hash", "EXPECT_LIGHT_WALLPAPER_SHA256"),
            ("the banner by hash", "EXPECT_BANNER_SHA256"),
            ("the greeter's compiled dconf database", "/org/gnome/login-screen/logo"),
            ("the light wallpaper in dconf", "/org/gnome/desktop/background/picture-uri"),
            ("the banner's interactive-only guard", "DISTR0_NO_BANNER"),
            ("the Italian defaults", "localectl"),
        ):
            check(f"the boot gate checks {label}", marker in text)



def check_claims() -> None:
    """Every promise should name the check that would catch it breaking."""
    check(f"{CLAIMS} exists", (ROOT / CLAIMS).is_file())
    if not (ROOT / CLAIMS).is_file():
        return
    rows = claim_rows()
    check("the claims matrix lists at least a dozen promises", len(rows) >= 12, f"{len(rows)} rows")
    malformed = [row[0] for row in rows if len(row) != 4]
    check("every claim names a promise, a source, a check and a verdict", not malformed, f"{malformed}")
    unknown = sorted(
        {
            verdict.strip().lower()
            for row in rows
            if len(row) == 4
            for verdict in row[3].split("+")
            if verdict.strip().lower() not in CLAIM_STATUSES
        }
    )
    check("every claim verdict is one the matrix defines", not unknown, f"{unknown}")
    check("the claims matrix admits what is not verified", "## Not verified here" in read(CLAIMS))
    check(
        "README links the claims matrix from its documentation table",
        "[docs/claims.md](docs/claims.md)" in read("README.md"),
        "the table is where a reader looks for it",
    )
    check("AGENTS.md points at the claims matrix", "docs/claims.md" in read("AGENTS.md"))
    check(
        "the boot gate is described where it runs",
        "scripts/boot-gate.sh" in read(CLAIMS) and "scripts/boot-gate-checks.sh" in read(CLAIMS),
    )


def check_delivery() -> None:
    """What the workflows must keep doing for the published image."""
    build = read(".github/workflows/build.yml")
    check("CI runs the image self-test", "selftest.sh" in build)
    check(
        "CI generates an SBOM with syft pinned by digest",
        re.search(r"anchore/syft@sha256:[0-9a-f]{64}", build) is not None,
    )
    check("CI attests the SBOM", "cosign attest" in build)
    check("CI measures layer reuse", "layer-diff.py" in build)
    check(
        "CI boots the image before publishing it",
        "--local" in build
        and "scripts/boot-gate-ci.sh" in build
        and build.index("scripts/boot-gate-ci.sh") < build.index("- name: Push To GHCR"),
        "the gate must run between the rechunk and the push",
    )
    check(
        "CI signs and attests by digest",
        "@${DIGEST}" in build and "@${{ steps.push.outputs.digest }}" in build,
        "a tag can move between push and sign; a digest cannot",
    )
    check(
        "CI checks the signature is the attachment containers/image reads",
        "application/vnd.dev.cosign.simplesigning.v1+json" in build,
    )

    verify = read(".github/workflows/verify-image.yml")
    check("CI verifies the SBOM attestation", "cosign verify-attestation" in verify)
    # Signing without a transparency log only works if verification skips it too.
    check("CI signs without uploading to a transparency log", "--tlog-upload=false" in build)
    check(
        "CI verifies attestations without a transparency log",
        "--insecure-ignore-tlog" in verify,
        "signatures have no Rekor entry, so verify must not require one",
    )
    check(
        "the attestation check pins cosign",
        re.search(r"cosign-installer@[0-9a-f]{40}", verify) is not None,
    )

    check("scripts/layer-diff.py exists", (ROOT / "scripts/layer-diff.py").is_file())

    # The self-test's failures are annotations, not just text in a log: a
    # repository whose automation cannot read job logs still sees them.
    check("CI annotates DISTR0 self-test messages", "::error title=DISTR0 self-test" in build)
    gate_ci = ROOT / "scripts/boot-gate-ci.sh"
    check(
        "the CI wrapper annotates every failed boot gate check",
        gate_ci.is_file() and "::error title=DISTR0 boot gate" in gate_ci.read_text(encoding="utf-8"),
    )

    # cosign 3 writes a Sigstore bundle by default, which containers/image (and
    # so bootc on every device) cannot see: images signed that way install as
    # unsigned. Bluefin shipped exactly that for two months in 2026.
    for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        text = path.read_text(encoding="utf-8")
        release = re.search(r"cosign-release:\s*'?v(\d+)\.", text)
        if not release or int(release.group(1)) < 3:
            continue
        signing = [
            line.strip()
            for line in text.splitlines()
            if re.search(r"\bcosign (sign|attest)\b", line) and not line.strip().startswith("#")
        ]
        check(
            f"{path.relative_to(ROOT)} keeps cosign 3 on the format bootc verifies",
            all("--new-bundle-format=false" in line for line in signing),
            "cosign v3 needs --new-bundle-format=false (and --use-signing-config=false)",
        )

    # Publishing is the one thing a pull request must never do: a fork cannot
    # write packages here, and an unreviewed commit must not become a tag users
    # install. The gate is load-bearing, so it is checked rather than assumed.
    try:
        import yaml
    except ModuleNotFoundError:
        print("skip  pull requests never publish — PyYAML is not installed (CI installs it)")
    else:
        doc = yaml.safe_load(build) or {}
        for name in (
            "Push To GHCR",
            "Sign container image",
            "The signature is one bootc can verify",
            "Attest the SBOM",
        ):
            step = next(
                (
                    step
                    for job in (doc.get("jobs") or {}).values()
                    for step in job.get("steps") or []
                    if step.get("name") == name
                ),
                {},
            )
            condition = str(step.get("if", ""))
            check(
                f"'{name}' never runs for a pull request",
                "github.event_name != 'pull_request'" in condition and "refs/heads/" in condition,
                f"if: {condition or 'missing'}",
            )
    copilot = ROOT / ".github/copilot-instructions.md"
    check(
        "copilot instructions are the same file as AGENTS.md",
        copilot.is_symlink() and copilot.readlink() == Path("AGENTS.md"),
        "ln -sfn AGENTS.md .github/copilot-instructions.md",
    )
    check(".gitignore ignores generated SBOMs", "sbom.spdx.json" in read(".gitignore"))


def check_cosign_commands() -> None:
    """Signing skips Rekor, so every documented verification must skip it too.

    A command in the docs that omits `--insecure-ignore-tlog` fails with "signature
    not found in transparency log" against a real published image, so this is a
    promise users act on, not prose.
    """
    for rel in (
        "README.md",
        "AGENTS.md",
        "SECURITY.md",
        CLAIMS,
        "system_files/usr/share/doc/distr0/README.md",
    ):
        if not (ROOT / rel).exists():
            continue
        lines = read(rel).splitlines()
        for index, line in enumerate(lines):
            if "cosign verify" not in line:
                continue
            block = " ".join(lines[index : index + 5])
            check(
                f"{rel}:{index + 1} does not require a transparency log",
                "--insecure-ignore-tlog" in block,
                "images are signed with --tlog-upload=false, so this command fails as written",
            )


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
        "ASSETS.md",
        "docs/claims.md",
        "docs/ROADMAP.md",
        "system_files/usr/share/doc/distr0/README.md",
        "system_files/usr/share/doc/distr0/LEGGIMI.md",
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


def section_lines(rel: str, heading: str) -> list[str]:
    """Lines of one `## heading` section, without the heading itself."""
    out: list[str] = []
    inside = False
    for line in read(rel).splitlines():
        if line.startswith("## "):
            inside = line.strip() == heading
            continue
        if inside:
            out.append(line)
    return out


def expand_braces(token: str) -> list[str]:
    """`a/{b,c}/d` -> `a/b/d`, `a/c/d`; anything else is returned unchanged."""
    match = re.search(r"\{([^{}]*)\}", token)
    if not match:
        return [token]
    return [
        expanded
        for part in match.group(1).split(",")
        for expanded in expand_braces(token[: match.start()] + part + token[match.end() :])
    ]


def slug(heading: str) -> str:
    text = heading.lstrip("# ").strip().lower()
    return re.sub(r"[^a-z0-9 -]", "", text).replace(" ", "-")


# Backticked tokens in the docs that read like paths but are not: the README
# uses one as a worked example of the overlay.
ILLUSTRATIVE_PATHS = {"system_files/etc/foo"}

# `Europe/Rome` is a timezone, not a path.
TIMEZONE = re.compile(r"^[A-Z][A-Za-z_+-]*/[A-Z][A-Za-z_+-]*$")

PATH_EXTENSIONS = {
    "brewfile",
    "conf",
    "json5",
    "just",
    "md",
    "png",
    "preinstall",
    "pub",
    "py",
    "sh",
    "svg",
    "toml",
    "yaml",
    "yml",
}


def looks_like_path(token: str) -> bool:
    """True for repository paths, False for commands, image refs, timezones."""
    if not token or " " in token or token.startswith(("/", "~", ">", "#", "<")):
        return False
    if "://" in token or re.match(r"^[a-z0-9-]+(\.[a-z0-9-]+)+/", token):
        return False  # URL or registry reference such as ghcr.io/owner/image
    if TIMEZONE.match(token):
        return False
    if re.search(r"[^A-Za-z0-9._/{},-]", token):
        return False
    if "/" in token:
        return True
    name = token.rsplit("/", 1)[-1]
    extension = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    return name in {"Containerfile", "Justfile"} or extension in PATH_EXTENSIONS


def path_exists(rel: str) -> bool:
    target = ROOT / rel
    # A shipped symlink can point at something the base image provides (for
    # example /etc/localtime -> zoneinfo), so being a symlink is enough.
    return target.exists() or target.is_symlink()


def table_tokens(rel: str, heading: str | None = None) -> set[str]:
    """Backticked tokens from every table, or from the first column of one section."""
    lines = read(rel).splitlines() if heading is None else section_lines(rel, heading)
    tokens: set[str] = set()
    for line in lines:
        if not line.startswith("|"):
            continue
        cells = line.split("|")[1:-1] if heading is None else line.split("|")[1:2]
        for cell in cells:
            tokens.update(re.findall(r"`([^`]+)`", cell))
    return tokens


def check_doc_paths() -> None:
    # README: every table, because the changes table keeps its paths in the
    # right-hand column. AGENTS.md: only the path column of the map, because its
    # other tables use shorthand (`build.sh`, `60-custom.just`) on purpose.
    for rel, heading, minimum in (
        ("README.md", None, 10),
        ("AGENTS.md", "## Map", 10),
        (CLAIMS, None, 8),
    ):
        if not (ROOT / rel).exists():
            check(f"{rel} exists", False)
            continue
        cited: set[str] = set()
        for token in table_tokens(rel, heading):
            token = token.strip()
            if token in ILLUSTRATIVE_PATHS or not looks_like_path(token):
                continue
            cited.update(expand_braces(token.rstrip("/")))
        where = "tables" if heading is None else "map"
        check(
            f"paths to check in {rel} {where}",
            len(cited) >= minimum,
            f"only {len(cited)} path(s) found",
        )
        missing = sorted(path for path in cited if path and not path_exists(path))
        check(f"every path in the {rel} {where} exists", not missing, f"missing: {missing}")

    for rel in (
        "README.md",
        "AGENTS.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        CLAIMS,
        "docs/ROADMAP.md",
        "system_files/usr/share/doc/distr0/README.md",
    ):
        if not (ROOT / rel).exists():
            continue
        text = read(rel)
        headings = {slug(h) for h in re.findall(r"^#{2,6} .*$", text, re.MULTILINE)}
        broken: list[str] = []
        for target in re.findall(r"\]\(([^)\s]+)\)", text):
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            if target.startswith("#"):
                if target[1:].lower() not in headings:
                    broken.append(target)
                continue
            # Relative to the document, as GitHub resolves it: a link in
            # docs/ROADMAP.md to ../AGENTS.md is the file at the root.
            path = target.split("#")[0].rstrip("/")
            if path and not ((ROOT / rel).parent / path).exists():
                broken.append(target)
        check(f"{rel} has no broken internal links", not broken, f"{broken}")


def check_workflow_scripts() -> None:
    """Every `run:` block must be valid bash, so a typo fails in a minute."""
    try:
        import yaml
    except ModuleNotFoundError:
        print("skip  workflow run blocks are valid bash — PyYAML is not installed (CI installs it)")
        return
    for path in sorted((ROOT / ".github/workflows").glob("*.y*ml")):
        rel = path.relative_to(ROOT)
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        broken: list[str] = []
        checked = 0
        for job in (doc.get("jobs") or {}).values():
            for step in job.get("steps") or []:
                script = step.get("run")
                if not script:
                    continue
                checked += 1
                # The shell parser must only see shell: expressions become a word.
                body = re.sub(r"\$\{\{.*?\}\}", "EXPRESSION", script, flags=re.S)
                result = subprocess.run(
                    ["bash", "-n"], input=body, capture_output=True, text=True, check=False
                )
                if result.returncode != 0:
                    first = (result.stderr.strip().splitlines() or ["syntax error"])[0]
                    broken.append(f"{step.get('name', '<unnamed>')}: {first}")
        check(f"{rel}: {checked} run blocks are valid bash", not broken, f"{broken}")


def main() -> int:
    check_workflows()
    check_workflow_scripts()
    check_pins()
    check_supply_chain()
    check_verification()
    check_declarations()
    check_defaults()
    check_recipes()
    check_image_promises()
    check_identity()
    check_boot_gate()
    check_claims()
    check_delivery()
    check_cosign_commands()
    check_docs()
    check_doc_paths()

    print()
    if FAILURES:
        print(f"{len(FAILURES)} of {CHECKS} checks failed")
        return 1
    print(f"all {CHECKS} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
