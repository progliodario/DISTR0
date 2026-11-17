#!/bin/bash

set -ouex pipefail

# ---------------------------------------------------------------------------
# 1. Overlay
# Every file under system_files/ is copied into the final image. The tree
# mirrors the root filesystem, so system_files/usr/share/doc/distr0/README.md
# ends up at /usr/share/doc/distr0/README.md.
# ---------------------------------------------------------------------------
cp -avf "/ctx/system_files/." /

# ---------------------------------------------------------------------------
# 2. Host packages
# Keep this list as small as possible: GUI apps belong in Flatpaks, CLI tools in
# Homebrew, workloads in distrobox/toolbox. Everything already shipped by the
# Bluefin base does not need to be installed again.
# ---------------------------------------------------------------------------

# dnf5 install -y \
#     <package>

# COPRs, when a package is not in Fedora or RPM Fusion. Always disable the COPR
# again so it does not leak into the final image:
# dnf5 -y copr enable <user>/<copr>
# dnf5 -y install <package>
# dnf5 -y copr disable <user>/<copr>

# ---------------------------------------------------------------------------
# 3. Services
# ---------------------------------------------------------------------------
systemctl enable podman.socket

# ---------------------------------------------------------------------------
# 4. Smoke test
# Fail the build early if the system_files overlay did not land.
# ---------------------------------------------------------------------------
test -f /usr/share/doc/distr0/README.md
