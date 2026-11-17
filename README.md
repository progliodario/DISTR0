# DISTR0

DISTR0 is a custom [bootc](https://github.com/bootc-dev/bootc) image built on
**[Bluefin](https://projectbluefin.io/)** — Universal Blue's Fedora Atomic GNOME
desktop — with a small, reproducible customization layer of its own.

```bash
sudo bootc switch --transport registry ghcr.io/progliodario/distr0:latest
sudo systemctl reboot
```

## What DISTR0 changes compared to its base

DISTR0 inherits everything Bluefin ships: GNOME, `ujust`, Homebrew, Flatpak
preinstall, `uupd` scheduled updates, HWE/NVIDIA variants and the container
tooling. Its own delta:

| Change | Where |
| --- | --- |
| Identity: `os-release` rebrand, wallpaper, `distr0-logo` | `build_files/build.sh`, `system_files/usr/share/{backgrounds,icons}` |
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

Every build on `main` publishes `latest`, `latest.<YYYYMMDD>` and `<YYYYMMDD>`.
Pull requests only publish `sha-<short>` and `pr-<n>` tags and never move
`latest`.

## Verify the image

Images are signed with [cosign](https://docs.sigstore.dev/) using the key in
[`cosign.pub`](cosign.pub):

```bash
cosign verify \
  --key https://raw.githubusercontent.com/progliodario/DISTR0/main/cosign.pub \
  ghcr.io/progliodario/distr0:latest
```

Known gap: the signature is verified by you and by CI, not yet by `bootc`
itself on the device. Enforcing it needs a `sigstoreSigned` scope in
`/etc/containers/policy.json` plus a `registries.d` entry for this namespace;
until that exists, updates are pulled as `ostree-unverified-image`.

## Language, keyboard and timezone

The image ships Italian defaults, without locking anyone in:

```bash
ujust distr0-lang                     # back to Italian (it_IT.UTF-8)
ujust distr0-lang en_US.UTF-8         # or any locale the image carries
localectl set-keymap it2              # console keymap
```

The GNOME keyboard layout (`it`) and the wallpaper come from
`/etc/dconf/db/distro.d/99-distr0-branding`, compiled by Bluefin's
`dconf-update.service`. `ujust distr0-reset-desktop` re-applies them after you
change something by hand.

## Applications

GUI apps are declared, not baked in — the same mechanism Bluefin uses:

- `/usr/share/flatpak/preinstall.d/distr0.preinstall` is read by the
  `flatpak-preinstall.service` already shipped and enabled by Bluefin, so the
  listed apps install on first boot (and are removed again if the declaration is
  removed). `ujust distr0-apps` re-runs it on demand, which matters when the
  first boot happens without a network connection.
- `/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile` is consumed by
  Bluefin's `brew-preinstall.service`, which installs those Homebrew formulae on
  first login and re-syncs them on every OS update. `ujust distr0-cli` installs
  them immediately.

Adding an app is one line in the corresponding list. `ujust bbrew` covers
everything else on demand.

## Build locally

Requirements: `podman`, `just`, `jq` (all shipped on bootc desktops), plus
`shellcheck`/`shfmt` if you want `just lint` / `just format`.

```bash
just build                                            # -> localhost/distr0:latest
sudo bootc switch --transport containers-storage localhost/distr0:latest
```

Disk images (via [bootc-image-builder](https://osbuild.org/docs/bootc/)):

```bash
just build-qcow2    # output/qcow2/disk.qcow2
just build-raw      # output/raw/disk.raw
just build-iso      # output/bootiso/install.iso
just run-vm-qcow2   # boots the qcow2 in a browser VM on http://localhost:8006
```

The installer ISO points the installed system at `ghcr.io/progliodario/distr0`
(see `disk_config/iso.toml`).

On GitHub, `.github/workflows/build.yml` builds, signs and pushes the image on
every push to `main`, and `.github/workflows/build-disk.yml` builds qcow2 and
anaconda-iso images on demand (`workflow_dispatch`, default `amd64`).

## Repository layout

| Path | Purpose |
| --- | --- |
| `Containerfile` | Image definition: base image (pinned) + `build.sh` + `bootc container lint` |
| `build_files/build.sh` | The customization entrypoint: overlay, packages, `os-release` rebrand, services, smoke tests |
| `system_files/` | Tree mirrored onto `/` at build time (`system_files/etc/foo` → `/etc/foo`); symlinks are preserved |
| `disk_config/` | bootc-image-builder configs for disk images and the installer ISO |
| `Justfile` | Local build, VM and lint recipes |
| `.github/workflows/` | CI: container image build/push/sign, disk image build |
| `cosign.pub` | Public key used to verify published images |

## Customizing

1. **Files** — drop them under `system_files/`, mirroring the root filesystem.
   They are read-only in the running system: changing them means a new build.
2. **Host packages** — `dnf5 install` in `build_files/build.sh`. Keep this list
   minimal; prefer Flatpak, Homebrew or a container for everything else.
3. **Base image** — bump the digest in `Containerfile` on purpose:

   ```bash
   skopeo inspect docker://ghcr.io/ublue-os/bluefin:latest | jq -r .Digest
   ```

   Renovate opens this bump automatically. `bluefin:latest` tracks the current
   Fedora release (45 today); `bluefin:stable` is the GTS stream and is still on
   Fedora 44, which would be a major-version downgrade for this image.
4. **Branding** — the wallpaper and logo live under
   `system_files/usr/share/{backgrounds,icons}`; the `os-release` strings are set
   in `build_files/build.sh` so `VERSION_ID` keeps tracking the base image.

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
- `just clean` removes build artifacts (`output/`, `_build*`, manifests).

## Credits and licensing

Distributed under Apache-2.0 (see [`LICENSE`](LICENSE)). DISTR0 is built on
Universal Blue's Bluefin and on Fedora Atomic Desktops; Fedora, Bluefin and
Universal Blue are projects and trademarks of their respective owners, and this
repository is not affiliated with or endorsed by them.
