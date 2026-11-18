# DISTR0

This file is shipped by the `system_files/` overlay of the DISTR0 image.

Everything committed under `system_files/` in
https://github.com/progliodario/DISTR0 is copied verbatim to the root of the
image at build time, so a file placed in `system_files/etc/foo.conf` becomes
`/etc/foo.conf`. Files are installed read-only: changing them means changing the
repository and building a new image, not editing the running system.

What this image adds on top of [Bluefin](https://projectbluefin.io/):

- DISTR0 branding: `os-release` identity, a wallpaper per colour scheme (light
  and dark), `distr0-logo` and the login-screen wordmark
- Italian defaults: `it_IT.UTF-8`, `Europe/Rome`, console keymap `it2`,
  GNOME keyboard layout `it`
- Flatpaks declared in `/usr/share/flatpak/preinstall.d/distr0.preinstall`
- Homebrew formulae declared in
  `/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile`
- Desktop defaults compiled into the schema database: blue accent, dark
  preference, window buttons, tap-to-click, natural scrolling and variable
  refresh rate
- A quiet login banner (interactive shells, once per session, disabled with
  `DISTR0_NO_BANNER=1`), `ujust distr0-greeting` for the fastfetch summary, and
  `ujust distr0-*` commands from `/usr/share/ublue-os/just/60-custom.just`
- Verified updates: images are signed, the signature is enforced through
  `/etc/containers/policy.json` with the key at `/usr/share/distr0/cosign.pub`,
  and `ujust distr0-verify` reports the state on this machine
- A self-test of everything above: `/usr/share/distr0/selftest.sh`, or
  `ujust distr0-doctor` for the same test plus deployment, failed units and disk

DISTR0 is built on Bluefin, which is built on Fedora Atomic Desktops by the
Universal Blue project.
