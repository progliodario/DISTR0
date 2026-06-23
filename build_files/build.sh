#!/bin/bash

set -ouex pipefail

# Installing packages
dnf5 install -y tmux

flatpak install flathub com.microsoft.Edge
flatpak uninstall flathub org.mozilla.firefox

# Enabling services
systemctl enable podman.socket
