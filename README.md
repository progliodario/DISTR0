# DISTR0

DISTR0 is a custom [bootc](https://github.com/bootc-dev/bootc) image built on
**[Bluefin](https://projectbluefin.io/)** — Universal Blue's Fedora Atomic GNOME
desktop — with a small, reproducible customization layer of its own.

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/progliodario/distr0:latest
sudo systemctl reboot
```

**In italiano:** la guida per chi usa DISTR0 — comandi, aggiornamenti,
rollback, applicazioni, CIE/CNS e firma digitale — è
[`LEGGIMI.md`](system_files/usr/share/doc/distr0/LEGGIMI.md), installata anche
nel sistema in `/usr/share/doc/distr0/LEGGIMI.md`. Il resto di questo README è
per chi sviluppa l'immagine.

## Documentation

| File | For |
| --- | --- |
| [AGENTS.md](AGENTS.md) | Invariants, file map, recipes for common changes and the failure playbook. Read this before changing anything, whether you are a new maintainer or an AI agent (`CLAUDE.md` is a symlink to it). |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Setup, the verification loop, pull request checklist |
| [SECURITY.md](SECURITY.md) | Reporting a vulnerability, the trust model, signing-key rotation |
| [ASSETS.md](ASSETS.md) | Where every shipped image comes from, and how to regenerate it |
| [docs/claims.md](docs/claims.md) | Every promise the image makes, the check that proves it, and the gaps that are only tested on a real machine |

## What DISTR0 changes compared to its base

DISTR0 inherits everything Bluefin ships: GNOME, `ujust`, Homebrew, Flatpak
preinstall, `uupd` scheduled updates, HWE/NVIDIA variants and the container
tooling. Its own delta:

| Change | Where |
| --- | --- |
| Identity: `os-release` rebrand (own `IMAGE_VERSION`), hostname `distr0`, a wallpaper per colour scheme, `distr0-logo`, login-screen wordmark | `build_files/build.sh`, `system_files/etc/hostname`, `system_files/usr/share/{backgrounds,icons,pixmaps}` |
| Bluefin's tools name DISTR0 too: `image-info.json` rewritten, `ujust devmode`, `rebase-helper`, `changelogs` and `toggle-user-motd` replaced so none of them leaves DISTR0 | `build_files/build.sh`, `system_files/usr/share/ublue-os/just/60-custom.just` |
| Wallpaper selectable in Settings → Appearance | `system_files/usr/share/gnome-background-properties/distr0.xml` |
| Italian keyboard on the login screen, not only in the session | `system_files/etc/X11/xorg.conf.d/00-keyboard.conf`, `system_files/etc/vconsole.conf` |
| Smart cards (CIE, CNS, firma digitale) for Flatpak browsers: p11-kit server socket for every user, `ujust distr0-smartcard` | `build_files/build.sh`, `system_files/usr/share/ublue-os/just/60-custom.just` |
| A user guide in Italian | `system_files/usr/share/doc/distr0/LEGGIMI.md` |
| `bootc install` defaults to btrfs | `system_files/usr/lib/bootc/install/00-distr0.toml` |
| One quiet login banner in Italian, replacing Bluefin's motd, and `ujust distr0-greeting` (fastfetch) | `system_files/{etc/profile.d,usr/share/distr0,usr/share/fastfetch}` |
| Desktop defaults compiled into the schema database: accent, buttons, touchpad, VRR | `system_files/usr/share/glib-2.0/schemas/zz0-distr0.gschema.override`, `build_files/build.sh` |
| Italian defaults: locale `it_IT.UTF-8`, timezone `Europe/Rome`, console keymap `it2`, GNOME keyboard layout `it` | `system_files/etc/{locale.conf,vconsole.conf,localtime}`, `system_files/etc/dconf/db/distro.d/99-distr0-branding` |
| GUI apps declared for first boot: Firefox, Thunderbird, LibreOffice, VLC | `system_files/usr/share/flatpak/preinstall.d/distr0.preinstall` |
| CLI tools installed through Homebrew: `bottom`, `dust`, `lazygit`, `xh` | `system_files/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile` |
| `ujust distr0-*` commands | `system_files/usr/share/ublue-os/just/60-custom.just` |
| `podman.socket` enabled by default | `build_files/build.sh` |
| File overlay: everything in `system_files/` is copied to `/` | `Containerfile`, `build_files/build.sh` |
| Base image pinned by digest for reproducible builds | `Containerfile` |

Everything else is meant to arrive either as a file under `system_files/`, a
host package in `build_files/build.sh`, or a user-level install (Flatpak for GUI
apps, Homebrew for CLI tools, distrobox/toolbox for workloads).

## Images and tags

| Image | Base |
| --- | --- |
| `ghcr.io/progliodario/distr0:latest` | `ghcr.io/ublue-os/bluefin:latest` (pinned by digest, Fedora 45) |

Every build on `main` publishes `latest`, `latest.<YYYYMMDD>` and `<YYYYMMDD>`,
and only after the image it is about to push has booted in the boot gate (see
below): a build that does not reach the login screen publishes nothing. Pull
requests build the image, run the self-test and the boot gate, but publish
nothing: a fork cannot write to this repository's packages, and a commit nobody
has reviewed must not become a tag someone installs. The push, sign and attest steps are all
gated on the default branch. The scheduled rebuild runs weekly: because the base
image is pinned by digest, a rebuild republishes the same content — bumping the
pin is what brings new upstream packages in (see
[Keeping the pins current](#keeping-the-pins-current)).

Images are rechunked with [chunkah](https://github.com/coreos/chunkah), pinned by
digest, in CI
(`just rechunk` does the same locally): the build layer is split into up to 128
smaller layers, so an update downloads only the parts that changed instead of a
single multi-hundred-megabyte layer.

Measured on two consecutive published builds that differed only in configuration
files (128 layers each): **125 layers shared, about 60 MB to download** instead of
the full 3.4 GB. That is a floor rather than a promise — a base-image bump
invalidates most chunks, which is exactly why the base digest is bumped on
purpose.

## Verify the image

Images are signed with [cosign](https://docs.sigstore.dev/) using the key in
[`cosign.pub`](cosign.pub). The signatures are deliberately not uploaded to a
public transparency log, so verification asks for that explicitly:
`--insecure-ignore-tlog` skips the *log entry*, never the signature check — the
key is what is trusted, and a signature made by another key still fails.

```bash
cosign verify \
  --insecure-ignore-tlog \
  --key https://raw.githubusercontent.com/progliodario/DISTR0/main/cosign.pub \
  ghcr.io/progliodario/distr0:latest
```

Every build also gets an SBOM ([SPDX](https://spdx.dev/), generated by
[syft](https://github.com/anchore/syft) pinned by digest) attested with the same
key, so the inventory is as checkable as the image:

```bash
cosign verify-attestation \
  --key https://raw.githubusercontent.com/progliodario/DISTR0/main/cosign.pub \
  --insecure-ignore-tlog \
  --type spdxjson ghcr.io/progliodario/distr0:latest \
  | jq -r '.payload' | base64 -d | jq '.predicate.packages | length'
```

The attestation lists packages, not a hash of every file: that is what answers
"is this package in the image?" and what keeps it small enough to attach.
Signatures and attestations are key-based and deliberately not uploaded to a
public transparency log — the trust anchor is the key each machine already
verifies against, so a Rekor outage cannot block a release.
`verify-image.yml` runs this check weekly against the published image.

### What every build runs

- `just test` — `/usr/share/distr0/selftest.sh` inside the built image: the
  identity fields, the shipped files, the signature policy and key, the declared
  Flatpaks and formulae, the desktop defaults read back through `gsettings`, the
  banner and the art the desktop points at, the units this repository enables
  itself, and that a kernel is installed. It runs on pull requests too, before
  the image is rechunked.
- `bootc container lint --fatal-warnings` — in the `Containerfile`, so a
  warning fails the build. The two the image used to raise came from this
  repository's own `dnf5 install` (state left in `/var/lib/dnf` and `/run/dnf`);
  `build.sh` now removes it.
- the boot gate, on the rechunked image about to be pushed (see below).
- after signing, the check every device makes: the signature verifies with
  `cosign.pub` and is stored as the `sha256-<digest>.sig` simple-signing
  attachment containers/image reads. cosign v3's default bundle format is
  invisible to bootc, so a cosign that changed format fails the build that day.
- grype, pinned by digest, on the SBOM of the published image: the known
  vulnerabilities by severity, and the critical and high ones that already have
  a fix, on the run summary. A report, not a gate: most fixes arrive with the
  next Bluefin base bump, and this says when one is due.
- `scripts/layer-diff.py` — compares the manifest of the published image with
  the new one and writes what an update will download into the run summary. The
  numbers above were measured this way.

### The image is booted, not just built

A container build cannot show GDM starting or the desktop reading a dconf
database: that needs a systemd boot. The build runs the boot gate on the image
it is about to push — on pull requests too — and publishes nothing if it fails;
`.github/workflows/boot-gate.yml` runs it again after every build on `main`, on
the image as the registry serves it. The gate installs the image to a raw disk
with `bootc install to-disk` (SELinux enforcing, as installed) and boots it in
QEMU. It waits for the greeter, screenshots the framebuffer through QMP, and
runs `scripts/boot-gate-checks.sh` inside the guest at boot. Those checks compare the
running system with the commit under test: the GDM wordmark and the light
wallpaper by SHA-256, the greeter's and the desktop's compiled dconf databases,
the login banner in an interactive login shell (once per session, silent in
scripts, off with `DISTR0_NO_BANNER=1`, and the only greeting), that Bluefin's
tools see the DISTR0 image, the default hostname, and the Italian locale,
console keymap, login-screen keyboard layout and timezone. The screenshot and
the log are uploaded with the run.

```bash
just boot-gate                                   # the published image
just boot-gate ghcr.io/progliodario/distr0:latest "$(git rev-parse HEAD)"
sudo scripts/boot-gate.sh --local localhost/distr0:latest   # a local build in root's storage
```

It needs `podman` (to pull the image and install it), `qemu` and `python3`; KVM
makes the boot a couple of minutes, without it QEMU emulates. The gate refuses
an image whose `org.opencontainers.image.revision` label is not the commit it
checked out, so a green run cannot describe a different build. What the gate
proves, and what is still only tested on a machine, is in
[`docs/claims.md`](docs/claims.md).

## Verified updates on the device

The image ships everything `bootc` needs to check that signature itself before
applying an update:

- `/usr/share/distr0/cosign.pub` — the public key (the same file as `cosign.pub`)
- a `sigstoreSigned` scope for `ghcr.io/progliodario/distr0` merged into
  `/etc/containers/policy.json` (merged with `jq`, never replaced, so the
  policies the base image ships keep working)
- `/etc/containers/registries.d/ghcr.io-progliodario.yaml` with
  `use-sigstore-attachments: true`, so containers/image looks for the signature
  next to the image in the registry

That turns `--enforce-container-sigpolicy` on, which is what the installer ISO
uses. A machine that was switched before this existed keeps its old
`ostree-unverified-image` reference until it is switched again, once:

```bash
sudo bootc switch --enforce-container-sigpolicy \
  ghcr.io/progliodario/distr0:latest
```

After that, `sudo bootc upgrade` refuses any image whose signature does not
match the key — a bad or tampered update cannot land.

`ujust distr0-verify` reports all of this on the running system: which key and
policy are installed, and whether the booted deployment is an
`ostree-image-signed` reference (updates verified) or still an unverified one,
in which case it prints the switch command. `ujust distr0-doctor` runs the image
self-test plus the deployment state, failed units and disk usage, and
`ujust distr0-rollback` stages a return to the previous deployment.

### The policy is tested, not just declared

`.github/workflows/verify-image.yml` runs weekly (or on demand) and pulls the
published image through `skopeo` — the same containers/image libraries `bootc`
uses — with the `registries.d` file and the policy scope this repository ships.
It runs twice: with [`cosign.pub`](cosign.pub) the copy must succeed, with a
throwaway key it must be refused. That is the enforcement `bootc upgrade` relies
on, exercised against the real registry instead of asserted in prose.

## Language, keyboard and timezone

The image ships Italian defaults, without locking anyone in:

```bash
ujust distr0-lang                     # back to Italian (it_IT.UTF-8)
ujust distr0-lang en_US.UTF-8         # or any locale the image carries
localectl set-keymap it2              # console keymap
```

The GNOME keyboard layout (`it`) and the wallpapers come from
`/etc/dconf/db/distro.d/99-distr0-branding`, compiled by Bluefin's
`dconf-update.service`. `ujust distr0-reset-desktop` re-applies them after you
change something by hand.

The login screen does not read any user's dconf: GDM takes the layout from
`systemd-localed`, so the image also ships `/etc/X11/xorg.conf.d/00-keyboard.conf`
and `XKBLAYOUT=it` in `/etc/vconsole.conf` — without them the password is typed
on a US layout. `sudo localectl set-x11-keymap <layout>` changes it.

## Desktop defaults and the login banner

Two separate mechanisms, on purpose:

- **Schema defaults** are compiled into the schema database by `build.sh` from
  `system_files/usr/share/glib-2.0/schemas/zz0-distr0.gschema.override`: blue
  accent colour, dark preference, minimise/maximise/close buttons on the right,
  tap-to-click, natural scrolling, disable-while-typing and variable refresh
  rate. They are defaults, not locks — anything set in Settings wins, and
  `ujust distr0-reset-desktop` cannot undo them because no dconf key is involved.
- **dconf defaults** stay in `/etc/dconf/db/distro.d/99-distr0-branding`
  (wallpapers, keyboard layout, screensaver) because Bluefin already compiles
  that directory at boot.

The login screen has its own database: `/etc/dconf/db/gdm.d/01-distr0-gdm`
points `org.gnome.login-screen logo` at
`/usr/share/pixmaps/distr0-gdm-logo.png`.

In a terminal, `/etc/profile.d/zz-distr0-banner.sh` prints three lines, in
Italian — image version, base and kernel, the commands worth knowing. It
replaces Bluefin's motd (which named the base image), runs in interactive shells
only, once per session, and reads its text from `/usr/share/distr0/banner.sh`,
which is also what `ujust distr0-greeting` runs:

```bash
ujust toggle-user-motd      # per user, the same switch Bluefin's motd used
DISTR0_NO_BANNER=1          # in ~/.profile or /etc/environment, turns it off
ujust distr0-greeting       # the greeting plus fastfetch, on demand
```

## Bluefin's tools, pointed at DISTR0

Bluefin's motd, `ujust changelogs`, `ujust devmode` and `ujust rebase-helper`
learn which image they run on from `/usr/share/ublue-os/image-info.json`, not
from `os-release`. As the base ships it, that file names
`ghcr.io/ublue-os/bluefin`, and `ujust devmode` would `bootc switch` a DISTR0
machine to `bluefin-dx`. `build.sh` rewrites the fields that name the image, and
`60-custom.just` replaces four recipes: `toggle-devmode` explains that DISTR0
has no developer variant, `rebase-helper` (alias `rollback-helper`) picks a dated
DISTR0 build, `changelogs` shows DISTR0's history, `toggle-user-motd` switches
the DISTR0 banner. `ujust` keeps the *first* definition of a recipe it imports,
so `build.sh` moves the import of `60-custom.just` to the top of
`00-entry.just`; the self-test reads each winning recipe back.

## Smart cards: CIE, CNS, firma digitale

The base already has `pcscd`, the CCID driver and OpenSC, which reads the CIE
and many CNS cards. Browsers installed as Flatpaks reach a card only through the
host's p11-kit server, so the image enables `p11-kit-server.socket` for every
user. `ujust distr0-smartcard` lists the readers, the card and its PKCS#11 slots.
Nothing in CI has a card reader: this is marked `machine only` in
[`docs/claims.md`](docs/claims.md).

`ujust distr0-greeting` is the full picture: a fastfetch preset at
`/usr/share/fastfetch/presets/distr0.jsonc` with the DISTR0 mark in ASCII. The
wallpapers follow the colour scheme: light mode gets
`distr0-wallpaper-light.png`, dark mode the original.

## Applications

GUI apps are declared, not baked in — the same mechanism Bluefin uses:

- `/usr/share/flatpak/preinstall.d/distr0.preinstall` is read by the
  `flatpak-preinstall.service` already shipped and enabled by Bluefin, so the
  listed apps install on first boot (and are removed again if the declaration is
  removed). `ujust distr0-apps` re-runs it on demand, which matters when the
  first boot happens without a network connection. Firefox and Thunderbird are
  also in Bluefin's `system-flatpaks.Brewfile`, but they are declared here on
  purpose: declaring an already-installed app is idempotent, while removing the
  declaration would make the next synchronization uninstall the OS-managed copy.
- `/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile` is consumed by
  Bluefin's `brew-preinstall.service`, which installs those Homebrew formulae on
  first login and re-syncs them on every OS update. `ujust distr0-cli` installs
  them immediately.

Adding an app is one line in the corresponding list. `ujust bbrew` covers
everything else on demand.

## Build locally

Requirements: `podman`, `just`, `jq`, `skopeo` (all shipped on bootc desktops).
`just lint` needs `shellcheck`; `pyyaml`, `hadolint` and `actionlint` enable its
extra checks (CI installs all of them, pinned and checksum-verified). `just check`
verifies the recipe syntax on its own.

```bash
just build                                            # -> localhost/distr0:latest
just test                                             # run the image self-test in a container
just test-unit                                        # unit tests for the repository's own checks
just assets                                           # regenerate the shipped PNGs (needs Pillow)
sudo bootc switch --transport containers-storage localhost/distr0:latest
```

The image carries its own test — `/usr/share/distr0/selftest.sh` — which asserts
the identity fields, the overlay files, the signature policy and key, the
declared Flatpaks and formulae, the desktop defaults as the desktop itself reads
them back, the enabled units and that a kernel is installed. `just test` runs it against the image; `ujust distr0-doctor` runs it
on a device together with the deployment state, failed units and disk usage.

Disk images (via [bootc-image-builder](https://osbuild.org/docs/bootc/)):

```bash
just build-qcow2    # output/qcow2/disk.qcow2
just build-raw      # output/raw/disk.raw
just build-iso      # output/bootiso/install.iso
just run-vm-qcow2   # boots the qcow2 in a browser VM on http://localhost:8006
```

The disk-image build pins both sides of its toolchain — the action by commit and
the builder image `BIB_IMAGE` by digest — in the workflow and in the `Justfile`,
so an ISO is as reproducible as the container image.

The installer ISO points the installed system at `ghcr.io/progliodario/distr0`
(see `disk_config/iso.toml`).

On GitHub, `.github/workflows/build.yml` builds, signs and pushes the image on
every push to `main`, and `.github/workflows/build-disk.yml` builds qcow2 and
anaconda-iso images on demand (`workflow_dispatch`, default `amd64`).
`.github/workflows/validate.yml` runs `just check` and `just lint` on every push
and pull request, so a broken recipe or a drifted setting is caught in a minute
instead of ten minutes into an image build.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Containerfile` | Image definition: base image (pinned) + `build_files/build.sh` + `bootc container lint` |
| `build_files/build.sh` | The customization entrypoint: overlay, packages, `os-release` rebrand, services, smoke tests |
| `system_files/` | Tree mirrored onto `/` at build time (`system_files/etc/foo` → `/etc/foo`); symlinks are preserved |
| `disk_config/` | bootc-image-builder configs for disk images and the installer ISO |
| `Justfile` | Local build, VM, lint (`just lint`) and pin (`just check-updates`) recipes |
| `scripts/validate.py` | Cross-file consistency checks, run by `just lint` and CI |
| `.github/workflows/` | CI: image build/push/sign, disk images, fast validation, weekly policy enforcement test |
| `cosign.pub` | Public key used to verify published images |
| `ASSETS.md` | Provenance and regeneration of every shipped image asset |
| `scripts/render-assets.py` | Renders the wallpapers and the GDM wordmark (`just assets`) |
| `scripts/boot-gate.sh` | Boots an image in QEMU and checks the running system (`just boot-gate`) |
| `docs/claims.md` | Every promise, its mechanism, and the check that proves it — including the gaps |

## Customizing

1. **Files** — drop them under `system_files/`, mirroring the root filesystem.
   They are read-only in the running system: changing them means a new build.
2. **Host packages** — `dnf5 install` in `build_files/build.sh`. Keep this list
   minimal; prefer Flatpak, Homebrew or a container for everything else.
3. **Base image** — bump the digest in `Containerfile` on purpose:

   ```bash
   skopeo inspect docker://ghcr.io/ublue-os/bluefin:latest | jq -r .Digest
   ```

   Renovate opens this bump automatically, and `just check-updates` reports
   whether the pin (or the chunkah one) has moved. `bluefin:latest` tracks the current
   Fedora release (45 today); `bluefin:stable` is the GTS stream and is still on
   Fedora 44, which would be a major-version downgrade for this image.
4. **Branding** — the wallpapers, the logo and the GDM wordmark live under
   `system_files/usr/share/{backgrounds,icons,pixmaps}`, and [`ASSETS.md`](ASSETS.md)
   says where each comes from and how to regenerate it. The `os-release` strings
   are set in `build_files/build.sh` so `VERSION_ID` keeps tracking the base
   image; the desktop defaults are the gschema override.

## Keeping the pins current

Three external images are pinned by digest — the Bluefin base in `Containerfile`,
chunkah in `Justfile` and the build workflow, and bootc-image-builder in the
disk workflow and the `Justfile` — and every GitHub Action is pinned to a commit
SHA. So each build starts from byte-identical inputs and an upstream push cannot
change what lands on the device. The cost is that a pin never moves on its own.
To check:

```bash
just check-updates    # exits non-zero when a pin is stale
```

It compares all three pins with their registries and prints the
`skopeo inspect docker://<image> | jq -r .Digest` line to copy. Renovate (see
`.github/renovate.json5`, the only update bot) opens the base-image bump, the
grouped action updates and the build-tool digests as pull requests once a week
when the app is installed on the repository. A cosign major update is disabled
on purpose: v3 needs the signing flags changed by hand.

## ArtifactHub

`artifacthub-repo.yml` is present but its `repositoryID` is still a placeholder:
Artifact Hub generates the real UUID when you create the repository there. Until
it is replaced, the repository will not be verified on
[artifacthub.io](https://artifacthub.io).

## Troubleshooting

- `sudo bootc status` shows the booted and staged image; `sudo bootc rollback`
  returns to the previous deployment if an update misbehaves.
- No Flatpaks after the first boot? `flatpak-preinstall.service` needs a network
  connection; once you are online run `ujust distr0-apps`.
- No `brew`? `brew-preinstall.service` runs at first graphical login; check
  `systemctl --user status brew-preinstall.service`, then `ujust distr0-cli`.
- A build that fails at `bootc container lint` means the resulting image is not a
  valid bootc image — check the lint output above it. The smoke tests at the end
  of `build.sh` fail fast when the overlay or the branding did not land.
- The card is not seen? `ujust distr0-smartcard` shows whether the reader, the
  card and the p11-kit server are there; restart Firefox after inserting it.
- `just clean` removes build artifacts (`output/`, `_build*`, manifests).

## Credits and licensing

Distributed under Apache-2.0 (see [`LICENSE`](LICENSE)). DISTR0 is built on
Universal Blue's Bluefin and on Fedora Atomic Desktops; Fedora, Bluefin and
Universal Blue are projects and trademarks of their respective owners, and this
repository is not affiliated with or endorsed by them.
