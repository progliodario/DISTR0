# What DISTR0 promises, and what proves it

An image repository accumulates claims: this boots, that is branded, updates are
verified. Each one should point at the check that would catch it breaking, and
the ones only a real machine can confirm should say so out loud.

Every row ends with one verdict:

- **boot gate** — verified by booting the published image in QEMU
  (`.github/workflows/boot-gate.yml`, `scripts/boot-gate.sh`).
- **image self-test** — asserted inside the built image by
  `system_files/usr/share/distr0/selftest.sh`, which `just test` and CI run.
- **repository check** — cross-file invariants in `scripts/validate.py`, run by
  `just lint` and the Validate workflow.
- **registry check** — verified against the published image by
  `.github/workflows/verify-image.yml`.
- **measurement** — a number produced by a build, not an invariant.
- **machine only** — nobody has verified it here; do not present it as proven.

## The matrix

| Promise | Where it lives | Proven by | Verdict |
| --- | --- | --- | --- |
| The published image boots as an ostree/bootc deployment with `IMAGE_ID=distr0` and a version | `build_files/build.sh`, `Containerfile` | boot gate: `/run/ostree-booted` and `/etc/os-release` in the guest | boot gate |
| The boot reaches a GDM login screen | base image, `system_files/` overlay | boot gate: `gdm.service`, the greeter process, and a QMP screenshot of the framebuffer | boot gate |
| The login screen shows the shipped wordmark | `system_files/usr/share/pixmaps/distr0-gdm-logo.png`, `system_files/etc/dconf/db/gdm.d/01-distr0-gdm` | boot gate: SHA-256 of the file and the compiled gdm database read back through dconf | boot gate |
| Light mode selects the shipped light wallpaper, dark mode the original | `system_files/etc/dconf/db/distro.d/99-distr0-branding`, `system_files/usr/share/backgrounds/distr0` | boot gate for the light URI and file; the self-test for both URIs and their sizes | boot gate + image self-test |
| The login banner prints the shipped greeting, only in interactive shells, once per session, and `DISTR0_NO_BANNER=1` turns it off | `system_files/usr/share/distr0/banner.sh`, `system_files/etc/profile.d/zz-distr0-banner.sh` | boot gate: an interactive login shell, a second source of the hook, a silent non-interactive shell, and SHA-256 of both files | boot gate |
| Italian defaults are active on the booted system | `system_files/etc/locale.conf`, `system_files/etc/vconsole.conf`, `system_files/etc/localtime` | boot gate: `localectl status` and `timedatectl` in the guest | boot gate |
| Desktop defaults (accent colour, window buttons, touchpad, VRR) are compiled into the schema database | `system_files/usr/share/glib-2.0/schemas/zz0-distr0.gschema.override`, `build_files/build.sh` | image self-test: reads each value back with `GSETTINGS_BACKEND=memory gsettings get` | image self-test |
| `ujust distr0-*` recipes exist and are valid bash | `system_files/usr/share/ublue-os/just/60-custom.just` | image self-test lists and parses them; `scripts/validate.py` checks the names the docs use | image self-test + repository check |
| A kernel is installed | base image | image self-test | image self-test |
| Flatpaks are declared for first boot (Firefox, Thunderbird, LibreOffice, VLC) | `system_files/usr/share/flatpak/preinstall.d/distr0.preinstall` | image self-test parses the declarations; `scripts/validate.py` checks the exact set | image self-test + repository check |
| CLI tools are declared for Homebrew (`bottom`, `dust`, `lazygit`, `xh`) | `system_files/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile` | image self-test parses the Brewfile; `scripts/validate.py` checks every entry is a formula | image self-test + repository check |
| Every action is pinned to a commit and every external image to a digest | `Containerfile`, `Justfile`, `.github/workflows/` | `scripts/validate.py`, including that the two bootc-image-builder pins agree | repository check |
| Images are signed with `cosign.pub` and the policy enforces that key | `.github/workflows/build.yml`, `system_files/etc/containers/registries.d`, `build_files/build.sh` | registry check: the published image is accepted with this key and refused with a throwaway one | registry check |
| The SBOM attestation verifies and describes this image | `.github/workflows/build.yml`, `.github/workflows/verify-image.yml` | registry check: `cosign verify-attestation --insecure-ignore-tlog` with the shipped key | registry check |
| An update downloads only the chunks that changed | chunkah in `Justfile` and `.github/workflows/build.yml`, `scripts/layer-diff.py` | measurement printed on the build run summary and quoted in the README | measurement |
| Flatpaks install themselves on first boot | flatpak-preinstall service from the base image | nothing in this repository boots a machine to first boot | machine only |
| Homebrew formulae install at first login | brew-preinstall service from the base image | nothing here logs into a graphical user session | machine only |
| The installer ISO installs a system that enforces the signature policy | `disk_config/iso.toml`, `.github/workflows/build-disk.yml` | the ISO is built on demand; CI never installs it | machine only |
| Wi-Fi, GPU, suspend, printers and audio work | base image and hardware | there is no hardware in CI | machine only |

## Not verified here

These are the honest gaps. They are not failures, but they are also not checked
by this repository, and the README must not imply otherwise:

- a real first boot with a network: Flatpak synchronization and
  `brew-preinstall` run there, and the gate does not wait for them;
- hardware support of any kind — the gate uses QEMU's emulated VGA and network;
- an actual Anaconda installation from the ISO;
- a user logging into a GNOME session: the gate reads the compiled desktop
  defaults through dconf, it does not watch a session apply them;
- suspend, resume, external displays and anything that needs a physical machine.

## How the gate runs

The gate runs after every successful build on `main` and can be started by hand:

```bash
just boot-gate
just boot-gate ghcr.io/progliodario/distr0:latest "$(git rev-parse HEAD)"
```

It pulls the image, installs it to a raw disk with the image's own
`bootc install to-disk`, boots it with OVMF and QEMU's `-vga std`, waits for GDM,
screenshots the framebuffer, and runs `scripts/boot-gate-checks.sh` over SSH as
root, whose key the installer injects and whose sshd the gate enables on that
disk only. The screenshot and the log are uploaded
with the run; a failure is annotated per check, so it is visible without the job
log.

The gate compares the running system with the commit it checked out: it refuses
an image whose `org.opencontainers.image.revision` label is another commit, and
the SHA-256 of the wordmark, the light wallpaper and the banner comes from
`system_files/`. That is what makes "the files this commit ships" a statement
about this repository rather than about whatever was published last.
