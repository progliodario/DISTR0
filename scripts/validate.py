#!/usr/bin/env python3
"""Cross-file checks for DISTR0 that do not need an image build.

The same values live in more than one place (image pins, signature policy,
declared Flatpaks, recipe names), and an image build is the slowest way to find
out that they drifted apart. `just lint` and the Validate workflow run this.

Only the repository is read; nothing is modified and no network is used.
"""

from __future__ import annotations

import re
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
        "distr0-doctor",
        "distr0-rollback",
    ):
        check(
            f"60-custom.just defines {recipe}",
            re.search(rf"^{recipe}\b", custom, re.MULTILINE) is not None,
        )
    justfile = read("Justfile")
    for recipe in ("build", "rechunk", "lint", "check-updates", "test", "test-unit"):
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


def check_image_promises() -> None:
    """The promises the image makes about itself, checked against the sources."""
    build = read("build_files/build.sh")
    check(
        "build.sh sets IMAGE_ID to distr0",
        re.search(r"^set_os_release IMAGE_ID '?distr0'?$", build, re.MULTILINE) is not None,
    )
    check("build.sh sets IMAGE_VERSION from the base image", "set_os_release IMAGE_VERSION" in build)
    check("build.sh keeps OSTREE_VERSION from the base", "OSTREE_VERSION" in build)
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
        for claim in ("IMAGE_ID", "sigstoreSigned", "distr0-doctor"):
            check(f"the self-test asserts {claim}", claim in text)
    check(
        "`just test` runs the self-test",
        "selftest.sh" in read("Justfile"),
        "the recipe exists but no longer runs the shipped test",
    )
    check("tests/test_validate.py exists", (ROOT / "tests/test_validate.py").is_file())


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
    check("CI keeps the bootc lint advisory", "continue-on-error: true" in build)

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
    copilot = ROOT / ".github/copilot-instructions.md"
    check(
        "copilot instructions are the same file as AGENTS.md",
        copilot.is_symlink() and copilot.readlink() == Path("AGENTS.md"),
        "ln -sfn AGENTS.md .github/copilot-instructions.md",
    )
    check(".gitignore ignores generated SBOMs", "sbom.spdx.json" in read(".gitignore"))


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
            path = target.split("#")[0].rstrip("/")
            if path and not (ROOT / path).exists():
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
    check_delivery()
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
