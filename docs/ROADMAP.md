# Roadmap

Where DISTR0 stands and what comes next. Read it before starting new work;
update it in the same pull request that finishes or changes a step. The *why*
of each rule lives in [`AGENTS.md`](../AGENTS.md), the promises and their
checks in [`claims.md`](claims.md).

## What DISTR0 is for

An Italian Bluefin that works the moment it is installed: language, keyboard
(at the login screen too), time zone, dictionaries and the tools Italian public
services need (CIE, CNS, firma digitale). It changes as little of Bluefin as it
can, names itself DISTR0 everywhere it shows a name, and promises nothing a
check does not prove. Updates are signed, and nothing is published before it
has booted.

## Done

| Step | Where | Proven by |
| --- | --- | --- |
| The boot gate boots the published image and runs 24 checks in the guest | `scripts/boot-gate*.sh`, `.github/workflows/boot-gate.yml` | the gate itself, green on `main` |
| Nothing is published before it boots: the build runs the gate on the rechunked image | `.github/workflows/build.yml` | `validate.py` checks the step order |
| Signed by digest, checked right after signing in the format bootc reads | `.github/workflows/build.yml` | the signature step; `validate.py` refuses cosign v3 without the legacy format |
| `bootc container lint --fatal-warnings` | `Containerfile`, `build_files/build.sh` | the build |
| The system names itself DISTR0: `image-info.json`, hostname, `IMAGE_VERSION`, one greeting; Bluefin's `devmode`, `rebase-helper`, `changelogs`, `toggle-user-motd` replaced | `build_files/build.sh`, `60-custom.just` | self-test and boot gate |
| Italian keyboard at the login screen | `system_files/etc/X11/xorg.conf.d/00-keyboard.conf` | boot gate (`X11 Layout: it`) |
| Smart cards reach Flatpak browsers (p11-kit server), `ujust distr0-smartcard` | `build_files/build.sh`, `60-custom.just` | self-test for the parts; a real card is machine only |
| Italian user guide | `system_files/usr/share/doc/distr0/LEGGIMI.md` | self-test (shipped) |
| Wallpaper in Settings, wordmark that fits its canvas | `gnome-background-properties/distr0.xml`, `scripts/render-assets.py` | self-test, `tests/test_assets.py` |
| qcow2 and installer ISO build from the published image | `.github/workflows/build-disk.yml` | the workflow, on demand and on pull requests touching it |
| Unit tests in CI, Renovate only, least-privilege workflows, grype report | `.github/` | Validate |

## Next, in order

Each step is one pull request: `just check`, `just lint`, `just test-unit`
green; a self-test or boot-gate check for anything the image now promises; a
row in `docs/claims.md`; merged only when the build (with its boot gate) is
green.

### 1. Upgrade gate

Prove the core promise end to end: a machine on the previous image updates to
the new one, verifies its signature, and can roll back.

- Install the *previous* `latest` (by digest) with `scripts/boot-gate.sh`'s
  install code, boot it, and run `bootc switch --enforce-container-sigpolicy`
  to the new digest, then `bootc upgrade`, reboot, and check: booted digest is
  the new one, origin is `ostree-image-signed`, `bootc rollback` stages the old
  one. The guest needs network (QEMU user networking has it).
- Weekly or after each publish (`boot-gate.yml`), not on pull requests: it
  downloads the image inside the VM.
- Moves "verified updates" in `docs/claims.md` from registry check to boot.

### 2. First-boot gate

What a real first boot does, which the login-screen gate skips:
`gnome-initial-setup` appears in Italian (screenshot), `flatpak-preinstall`
installs Firefox, Thunderbird, LibreOffice and VLC with Italian translations,
and `ujust distr0-apps` / `distr0-cli` work. Weekly, because it downloads about
1.5 GB. Turns three `machine only` rows into checks.

### 3. NVIDIA variant

`distr0-nvidia` from `bluefin-nvidia-open:latest`: a matrix in `build.yml`
(build, self-test, boot gate, sign, SBOM per variant), `boot-gate.yml` for both,
and a recipe in `60-custom.just` that switches between them, always to
`ghcr.io/progliodario/distr0*` with the signature policy. The gate proves the
image boots in QEMU, not that the driver works on a GPU (machine only).

### 4. Boot splash

A DISTR0 Plymouth theme, and an initramfs regenerated in the build
(`dracut` with an explicit kernel version). It also makes the initrd say
DISTR0 instead of Bluefin, after which `/etc/hostname` could go back to
`DEFAULT_HOSTNAME` alone. Risky (it touches every boot): the gate covers it,
add a screenshot during the splash.

### 5. Installer people can download

The ISO builds; it is not published. GitHub release assets stop at 2 GB, the
ISO is larger, so it needs object storage (the `upload-to-s3` path in
`build-disk.yml` exists) or the documented route: install Bluefin's ISO, then
`bootc switch --enforce-container-sigpolicy ghcr.io/progliodario/distr0:latest`.
Either way, an automated install in a VM before publishing it.

### 6. Smaller items

- Flatpak languages: check on a booted system that `flatpak config` follows the
  system locale; pin `it;en` if it downloads every translation.
- `fastfetch` still shows Bluefin's logo through Bluefin's alias; point it at
  the DISTR0 preset.
- Release notes per build: the package difference against the previous image,
  as a GitHub release, which `ujust changelogs` can then show.
- Consider the CIE middleware from `italia/cie-middleware-linux` once its
  packaging and maintenance are checked; OpenSC covers the CIE today.

## Only the owner can do

- Register the repository on [Artifact Hub](https://artifacthub.io) and put the
  real `repositoryID` in `artifacthub-repo.yml`.
- Protect `main`: require a pull request and green `Lint configuration` and
  `Build and push image`, no force pushes.
- Move `SIGNING_SECRET` into an environment that only `main` can use.
- Install the Renovate app on the repository (it is the only update bot).
- Test a CIE or CNS card with a reader on a real machine, and tell the
  repository what happened (`docs/claims.md` lists it as machine only).

## Decided against, for now

- A `stable` stream from `bluefin:stable`: it doubles the builds for little
  gain while `latest` is the only stream people run.
- arm64: the published image is amd64 only.
- Flathub verified-only, hardened malloc and similar hardening (secureblue's
  choices): they change what users can install, which is not this image's job.

## Verifying without KVM

`just boot-gate-local` needs `/dev/kvm`. Where there is none (some cloud
sandboxes), the same checks ran by installing with `bootc install
to-filesystem` onto a loop-mounted btrfs, writing the gate's unit with
`write_guest_checks` (source `scripts/boot-gate.sh`; it does not run the gate
when sourced), and booting the btrfs root under TCG with QEMU's `-kernel` and
`-initrd` taken from the deployment's `/boot`. It takes about 5 minutes to the
greeter instead of 20 seconds, and does not cover the disk layout or OVMF/GRUB,
which the build's gate does.
