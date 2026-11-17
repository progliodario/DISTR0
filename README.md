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
tooling. Its own delta is deliberately small:

| Change | Where |
| --- | --- |
| `podman.socket` enabled by default | `build_files/build.sh` |
| File overlay: everything in `system_files/` is copied to `/` | `Containerfile`, `build_files/build.sh` |
| Base image pinned by digest for reproducible builds | `Containerfile` |

Everything else is meant to arrive either as a file under `system_files/`, a
host package in `build_files/build.sh`, or a user-level install (Flatpak for GUI
apps, Homebrew for CLI tools, distrobox/toolbox for workloads).

## Images and tags

| Image | Base |
| --- | --- |
| `ghcr.io/progliodario/distr0:latest` | `ghcr.io/ublue-os/bluefin:stable` (pinned by digest) |

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
| `build_files/build.sh` | The customization entrypoint: overlay, host packages, services |
| `system_files/` | Tree mirrored onto `/` at build time (`system_files/etc/foo` → `/etc/foo`) |
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
   skopeo inspect docker://ghcr.io/ublue-os/bluefin:stable | jq -r .Digest
   ```

   Renovate opens this bump automatically.
4. **Desktop / apps** — Flatpaks declared for first-boot install, CLI tools in a
   Brewfile, commands in `/usr/share/ublue-os/just/60-custom.just`. These are the
   next milestones, not wired up yet.

## ArtifactHub

`artifacthub-repo.yml` is present but its `repositoryID` is still a placeholder:
Artifact Hub generates the real UUID when you create the repository there. Until
it is replaced, the repository will not be verified on
[artifacthub.io](https://artifacthub.io).

## Troubleshooting

- `sudo bootc status` shows the booted and staged image; `sudo bootc rollback`
  returns to the previous deployment if an update misbehaves.
- A build that fails at `bootc container lint` means the resulting image is not a
  valid bootc image — check the lint output above it.
- `just clean` removes build artifacts (`output/`, `_build*`, manifests).

## Credits and licensing

Distributed under Apache-2.0 (see [`LICENSE`](LICENSE)). DISTR0 is built on
Universal Blue's Bluefin and on Fedora Atomic Desktops; Fedora, Bluefin and
Universal Blue are projects and trademarks of their respective owners, and this
repository is not affiliated with or endorsed by them.
