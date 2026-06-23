#!/bin/bash

set -ouex pipefail

# Installing packages
dnf5 install -y \
    microsoft-edge

# Enabling services
systemctl enable podman.socket
