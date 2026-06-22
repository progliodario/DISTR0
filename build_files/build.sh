#!/bin/bash

set -ouex pipefail

# Install packages
dnf5 install -y tmux
dnf5 install -y edge

# Enabling services
systemctl enable podman.socket
