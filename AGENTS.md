# AGENTS.md

How to change this repository without breaking the machines it ships to. This
file is for humans and AI agents alike: the [README](README.md) says *what*
DISTR0 is, this says *how* to work on it. If this file and the code disagree,
the code and [`scripts/validate.py`](scripts/validate.py) win — fix the file
that is wrong.

## What this repository is

A [bootc](https://github.com/bootc-dev/bootc) image. `Containerfile` starts from
a pinned `ghcr.io/ublue-os/bluefin`, a `system_files/` tree is overlaid onto `/`
by `build_files/build.sh`, and GitHub Actions build, rechunk, sign and push
`ghcr.io/progliodario/distr0`. People run it with `bootc switch` and update with
`bootc upgrade` or Bluefin's `uupd` timer. Nothing here runs "live": every change
reaches a machine through a new image.

## The five-minute loop

```bash
just check    # every Justfile and *.just parses and is formatted
just lint     # shellcheck, scripts/validate.py, hadolint, actionlint
```

Both must pass before a commit; `.github/workflows/validate.yml` runs exactly
these two commands on every push and pull request. A change that fails them is
not finished, even if it "looks right".

These do not run the image build:

```bash
just build          # podman build -> localhost/distr0:latest (several minutes)
just rechunk        # chunkah, same split CI does
just build-iso      # installer ISO via bootc-image-builder
just run-vm-qcow2   # boot the qcow2 in a browser VM
just check-updates  # have the pinned upstream digests moved?
just clean          # remove build leftovers (_build*, _chunkah_*, output/)
```

Only the first is needed for a code change; none are needed for documentation.

## Invariants

Each of these is load-bearing, and most are enforced by `just lint`:

- **Base image pinned by digest** (`Containerfile`). Builds are reproducible and
  an upstream push cannot change what lands on a device. Bump it deliberately
  (see `just check-updates`); never replace the digest with a floating tag.
- **Every external image pinned by digest, every action pinned to a commit SHA.**
  chunkah appears in both `Justfile` and `.github/workflows/build.yml` with the
  same digest; bootc-image-builder in both the disk workflow and the `Justfile`.
  `validate.py` fails if they drift or if an action points at a branch.
- **`/etc/containers/policy.json` is merged, never replaced.** `build.sh` adds
  one `sigstoreSigned` scope for `ghcr.io/progliodario/distr0` with `jq`, keeping
  the scopes Bluefin ships. The key is always `cosign.pub` at the repository
  root, installed at `/usr/share/distr0/cosign.pub`.
- **The policy scope, the `registries.d` file and the workflow that tests them
  must stay consistent.** `verify-image.yml` re-uses
  `system_files/etc/containers/registries.d/` directly, so renaming that
  directory breaks the enforcement test.
- **`distr0.preinstall` is a systemd keyfile** (`[Flatpak Preinstall <app-id>]`)
  and `flatpak preinstall` *synchronizes*: adding an entry installs the app,
  **removing one uninstalls it on users' machines**. Firefox and Thunderbird are
  declared even though Bluefin also lists them, on purpose: re-declaring an
  installed app is idempotent, dropping the declaration is not.
- **`os-release` is rewritten in `build.sh`, not shipped as a file.** It has no
  drop-in directory, and a static copy from git would freeze `VERSION_ID`.
- **Nothing in `system_files/` is editable on a running system.** It is an
  overlay on a read-only `/`: changing a file means a new image.
- **Recipe bodies are bash**, so they must stay `bash -n`/`shellcheck` clean.
  Inside a recipe, `{{ ... }}` is Just interpolation, not shell — escape literal
  braces as `{{ '{{' }}`. The `run:` blocks of every workflow are parsed the
  same way by `validate.py`, with `${{ ... }}` replaced before the parse.
- **Documentation may only point at things that exist.** `validate.py` checks
  the `just`/`ujust` names used in the README, this file, `CONTRIBUTING.md` and
  the doc shipped inside the image against the Justfiles; every path cited in
  any `README.md` table (the changes table keeps its paths in the right-hand
  column, brace forms like `a/{b,c}` are expanded) and in the `## Map` table
  below; and every relative link and in-page anchor in those documents.
- **The result must stay a valid bootc image**: `bootc container lint` runs in
  the `Containerfile` and `build.sh` ends with smoke tests that fail the build
  rather than shipping a broken image.
- **The self-test is the contract.** `/usr/share/distr0/selftest.sh` ships inside
  the image and asserts what the image promises; `just test` and
  `ujust distr0-doctor` both run it. Adding a promise to the README without a
  check there means it is unverified.

## Map

| Path | Role |
| --- | --- |
| `Containerfile` | Base image (pinned), overlay copy, `bootc container lint` |
| `build_files/build.sh` | The whole delta: overlay, packages, `os-release`, services, policy merge, smoke tests |
| `system_files/` | Mirror of `/`; `system_files/etc/foo` becomes `/etc/foo`, symlinks preserved |
| `system_files/usr/share/flatpak/preinstall.d/distr0.preinstall` | GUI apps installed on first boot |
| `system_files/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile` | CLI tools installed on first login |
| `system_files/usr/share/ublue-os/just/60-custom.just` | `ujust distr0-*` recipes, run on the device |
| `system_files/usr/share/distr0/selftest.sh` | The image's own test: identity, overlay, policy, declarations, units |
| `tests/test_validate.py` | Unit tests for the checker itself (`just test-unit`) |
| `.github/copilot-instructions.md` | Symlink to `AGENTS.md`, so every agent reads one file |
| `system_files/etc/containers/` | Update-verification policy (`policy.json` scope + `registries.d`) |
| `disk_config/` | bootc-image-builder inputs; `iso.toml` also carries the installer's `bootc switch` |
| `Justfile` | Everything you run on the build host |
| `scripts/validate.py` | Cross-file invariants; the source of truth for `just lint` |
| `scripts/layer-diff.py` | What an update downloads, from two image manifests |
| `.github/workflows/build.yml` | Build → self-test → rechunk → push → sign → SBOM attestation on `main` (and weekly) |
| `.github/workflows/validate.yml` | `just check` + `just lint`, in about a minute |
| `.github/workflows/verify-image.yml` | Weekly: the published image must pass the shipped policy and fail with another key |
| `.github/workflows/build-disk.yml` | qcow2 / raw / ISO on demand |

## Recipes for common changes

| Want to | Do this |
| --- | --- |
| Ship a file on every machine | Put it under `system_files/`, mirroring `/` |
| Install a host package | `dnf5 install -y <pkg>` in `build.sh` (keep the list tiny) |
| Add a GUI app | One `[Flatpak Preinstall <app-id>]` block in `distr0.preinstall` |
| Add a CLI tool | One `brew "<formula>"` line in `distr0-cli.Brewfile` |
| Add a device command | A recipe in `60-custom.just`, then mention it in the README |
| Verify a built image | `just test` (self-test in a container); `just test-unit` for the checker |
| Bump the base or chunkah | `just check-updates`, then edit the digest in place |
| Change branding | `build.sh` for `os-release`, `system_files/usr/share/{backgrounds,icons}` for art |
| Change where the installer points | `disk_config/iso.toml` |

## Conventions

- Commit subjects are imperative and specific; the body explains *why* the change
  exists, not what the diff already shows. One logical change per commit.
- Comments in code explain reasoning and gotchas, not restatements of the line.
- Repository prose is English. The product's defaults (locale, timezone, keyboard,
  wallpaper) are Italian, and on-device text may be Italian.
- Prefer the smallest change that solves the problem. New dependencies, services
  or workflows are a maintenance cost someone has to carry.

## When something is red

- **`Validate` failed** → run `just check` and `just lint` locally; they are the
  same commands.
- **`Build container image` failed** → read the failing step. The signing step is
  last, so "no signatures found" immediately after a push is normal, not an error.
- **The rechunk step failed** → the image may not have been published at all; the
  digest in the registry stays at the previous build.
- **A device refuses an update** → the signature policy rejected it. On the
  machine, `ujust distr0-verify` shows the installed key, the policy scope and
  whether the booted deployment is `ostree-image-signed`.
- **A bad update landed anyway** → `sudo bootc rollback` returns to the previous
  deployment.

## What CI proves, and what only a machine can

CI proves: the image builds, the shipped self-test passes inside it, the image is
rechunked, it is signed, the signature verifies with `cosign.pub` and is enforced
against a throwaway key (`verify-image.yml`), and the SBOM attestation verifies
too. `bootc container lint --fatal-warnings` runs advisory: read its log instead
of assuming green.

CI cannot prove what the boot process does on real hardware — Flatpak
synchronization at boot, `brew-preinstall`, dconf defaults. If you claim one of
those works, say it was not verified here.
