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

## Where things stand

[`docs/ROADMAP.md`](docs/ROADMAP.md) is the plan: what is done, what is next
and in which order, what each next step needs, and what only the owner can do.
Read it before starting new work and update it in the same pull request that
finishes or changes a step.

## The five-minute loop

```bash
just check      # every Justfile and *.just parses and is formatted
just lint       # shellcheck, scripts/validate.py, hadolint, actionlint
just test-unit  # pytest: the checker, the boot gate's helpers, the assets
```

All three must pass before a commit; `.github/workflows/validate.yml` runs
exactly these commands on every push and pull request. A change that fails
them is not finished, even if it "looks right".

These run the image build or need a VM:

```bash
just build            # podman build -> localhost/distr0:latest (several minutes)
just test             # the image self-test, in a container
just boot-gate-local  # the boot gate on the image `just build` made (needs KVM)
just boot-gate        # the boot gate on the published image
just rechunk          # chunkah, same split CI does
just build-iso        # installer ISO via bootc-image-builder
just run-vm-qcow2     # boot the qcow2 in a browser VM
just check-updates    # have the pinned upstream digests moved?
just clean            # remove build leftovers (_build*, _chunkah_*, output/)
```

A change to the image needs `just build` and `just test`; the pull request
runs the boot gate on it. None of these are needed for documentation.

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
- **Pull requests never publish.** The push, sign and attest steps are gated on
  `github.event_name != 'pull_request'` and the default branch, and the metadata
  step declares only the tags that are actually pushed. A fork cannot write to
  this repository's packages, and an unreviewed commit must not become a tag
  someone installs.
- **Desktop defaults are compiled, not assumed.** A `*.gschema.override` only
  takes effect after `glib-compile-schemas` runs in `build.sh`, so the self-test
  reads the value back through `gsettings` instead of trusting the file. dconf
  drop-ins under `/etc/dconf/db/distro.d` and `/etc/dconf/db/gdm.d` are compiled
  at boot by `dconf-update.service`, so they need nothing at build time.
- **The login banner stays quiet.** `/etc/profile.d/zz-distr0-banner.sh` greets
  interactive shells only, once per session, and can be turned off with
  `DISTR0_NO_BANNER=1`; the text lives in `/usr/share/distr0/banner.sh`, so the
  banner and `ujust distr0-greeting` cannot drift apart.
- **Every shipped image is documented in `ASSETS.md`.** `validate.py` fails when
  a file under `system_files/usr/share/{backgrounds,icons,pixmaps}` has no row:
  art without provenance cannot be licensed or safely replaced.
- **A promise is only as good as the check behind it.** `docs/claims.md` maps
  every claim the README makes to the check that would catch it breaking, and
  says which ones are only tested on a real machine. Adding a claim means adding
  a row and, where possible, a check; marking something `machine only` while the
  README presents it as proven is a documentation bug.
- **The boot gate tests the image users get.** In the build it boots the
  rechunked image that is about to be pushed; after publishing,
  `boot-gate.yml` pulls the tag and boots that. Both refuse an image whose
  `org.opencontainers.image.revision` label is not the commit checked out, and
  compare the booted files with this repository by SHA-256. Do not make it succeed when the registry is slow or the boot times
  out: a skipped boot is not a boot. The disk keeps SELinux enforcing (never
  `--disable-selinux`, which adds `selinux=0`); the gate's only changes are its
  unit in the deployment's `/etc` (the root partition has none of its own) and
  `InitialSetupEnable=False`, so GDM shows the login screen.
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
- **The result must stay a valid bootc image**: `bootc container lint
  --fatal-warnings` runs in the `Containerfile` and `build.sh` ends with smoke
  tests that fail the build rather than shipping a broken image. A package
  install must not leave state in `/var` or `/run` (`build.sh` removes dnf's).
- **Nothing is published before it boots.** The build runs the boot gate
  (`scripts/boot-gate.sh --local`) on the rechunked image between the rechunk
  and the push; `validate.py` checks that order. Do not move the push above it.
- **Signatures are made by digest, in the format bootc reads.** cosign stays on
  v2, or on v3 with `--new-bundle-format=false --use-signing-config=false`:
  cosign v3's default bundle is invisible to containers/image, and every device
  would install updates as unsigned. The build checks the `.sig` attachment
  right after signing; `validate.py` refuses v3 without the flag.
- **The system names itself DISTR0 everywhere.** Bluefin's tools read
  `/usr/share/ublue-os/image-info.json`; `build.sh` rewrites it. `ujust` keeps
  the *first* definition of a recipe across imports, so `build.sh` imports
  `60-custom.just` first, which is how DISTR0 replaces `toggle-devmode`,
  `rebase-helper`, `changelogs` and `toggle-user-motd`. A recipe may only
  `bootc switch` to `ghcr.io/progliodario/distr0`, with the signature policy.
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
| `system_files/usr/share/distr0/selftest.sh` | The image's own test: identity, overlay, policy, declarations, desktop defaults, units |
| `system_files/usr/share/distr0/banner.sh` | The greeting text, shared by the login banner and `ujust distr0-greeting` |
| `system_files/etc/profile.d/zz-distr0-banner.sh` | Login hook: interactive shells only, once per session |
| `system_files/usr/share/fastfetch/presets/distr0.jsonc` | fastfetch preset with the DISTR0 mark, shown on demand |
| `system_files/usr/share/glib-2.0/schemas/zz0-distr0.gschema.override` | Desktop defaults, compiled by `build.sh` |
| `system_files/etc/dconf/db/gdm.d/01-distr0-gdm` | Login-screen wordmark for GDM |
| `ASSETS.md` | Provenance and regeneration of the shipped art |
| `docs/claims.md` | Every promise, the mechanism behind it and the check that proves it |
| `docs/ROADMAP.md` | What is done, what is next, and what only the owner can do |
| `scripts/boot-gate.sh` | Installs an image to a disk, boots it in QEMU, screenshots the login screen, runs the in-guest checks (`--image`, `--local`, `--disk`) |
| `scripts/boot-gate-checks.sh` | The checks that run inside the booted image, at boot |
| `scripts/boot-gate-ci.sh` | Runs the gate on a runner: a notice per phase, an annotation per failed check |
| `system_files/usr/share/doc/distr0/LEGGIMI.md` | The user guide, in Italian, shipped in the image |
| `.github/workflows/boot-gate.yml` | Boots every image published on `main`, as the registry serves it |
| `scripts/render-assets.py` | Renders the raster assets (`just assets`, needs Pillow) |
| `tests/` | Unit tests (`just test-unit`): `test_validate.py` for the checker, `test_boot_gate.py` for the gate's scripts, `test_assets.py` for the screenshot parser and the wordmark |
| `system_files/usr/lib/bootc/install/00-distr0.toml` | `bootc install` defaults (btrfs) |
| `system_files/etc/X11/xorg.conf.d/00-keyboard.conf` | The login screen's keyboard layout |
| `.github/copilot-instructions.md` | Symlink to `AGENTS.md`, so every agent reads one file |
| `system_files/etc/containers/` | Update-verification policy (`policy.json` scope + `registries.d`) |
| `disk_config/` | bootc-image-builder inputs; `iso.toml` also carries the installer's `bootc switch` |
| `Justfile` | Everything you run on the build host |
| `scripts/validate.py` | Cross-file invariants; the source of truth for `just lint` |
| `scripts/layer-diff.py` | What an update downloads, from two image manifests |
| `.github/workflows/build.yml` | Build → self-test → rechunk → boot gate → push → sign by digest → signature check → SBOM, attestation, vulnerability report; pull requests stop after the boot gate |
| `.github/workflows/validate.yml` | `just check` + `just lint` + `just test-unit`, in about a minute |
| `.github/renovate.json5` | The only update bot: actions, the base digest, the tool digests, cosign |
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
| Change branding | `build.sh` for `os-release`, `system_files/usr/share/{backgrounds,icons,pixmaps}` for art, then `ASSETS.md` |
| Change the greeting or the summary | `system_files/usr/share/distr0/banner.sh`, the fastfetch preset, or `ujust distr0-greeting` |
| Prove a new promise | Add the check to `system_files/usr/share/distr0/selftest.sh` or `scripts/boot-gate-checks.sh`, then a row in `docs/claims.md` |
| Replace a Bluefin `ujust` recipe | Define it with the same name in `60-custom.just` (imported first, so it wins), then add the name to `check_recipes` in `scripts/validate.py` |
| Change what Bluefin's tools think the image is | The `image-info.json` merge in `build.sh` |
| Write a file under `/etc/hostname`, `/etc/hosts` or `/etc/resolv.conf` | A `COPY` in the `Containerfile`: a `RUN` step only sees the builder's own bind-mounted file |
| Test an image change in a VM before pushing | `just build`, then `just boot-gate-local` |
| Tell users something | `system_files/usr/share/doc/distr0/LEGGIMI.md` (Italian), and a recipe message in `60-custom.just` |
| Change where the installer points | `disk_config/iso.toml` |

## Conventions

- Commit subjects are imperative and specific; the body explains *why* the change
  exists, not what the diff already shows. One logical change per commit.
- Comments in code explain reasoning and gotchas, not restatements of the line.
- Repository prose is English. The product's defaults (locale, timezone, keyboard,
  wallpaper) are Italian, and on-device text may be Italian.
- Prefer the smallest change that solves the problem. New dependencies, services
  or workflows are a maintenance cost someone has to carry.
- Work on a branch and open a pull request; never push to `main` directly. The
  pull request runs Validate, the build, the self-test and the boot gate, so a
  change is proven before it can reach a machine. Merge only when all are green.
- Renovate is the only update bot. Do not add Dependabot back: both bumped the
  same actions and doubled every pull request.

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

CI proves: the image builds and passes `bootc container lint --fatal-warnings`,
the shipped self-test passes inside it, it is rechunked, the rechunked image
boots to the login screen, it is signed by digest, the signature verifies with
`cosign.pub` and sits where bootc looks for it, it is enforced against a
throwaway key (`verify-image.yml`), and the SBOM attestation verifies too.
Failures are run annotations: read those on the summary, since the job log may
need permissions the repository's automation does not have.

The boot gate proves — in the build before publishing, and again in
`boot-gate.yml` on the published image — that the image boots to a GDM login
screen, that the greeter reads the shipped wordmark and wallpaper, that the
banner, the Italian defaults and the login keyboard are live on the running
system, and that Bluefin's tools see the DISTR0 image.

CI cannot prove what the boot process does on real hardware — Flatpak
synchronization at boot, `brew-preinstall`, a user logging into a GNOME session,
or anything about Wi-Fi and GPUs. `docs/claims.md` lists those gaps; if you
claim one works, say it was not verified here.
