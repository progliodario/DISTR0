#!/bin/bash

set -ouex pipefail

# Installing packages
dnf5 install -y \
    microsoft-edge-stable

# Enabling services
systemctl enable podman.socket
