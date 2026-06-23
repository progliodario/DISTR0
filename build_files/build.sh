#!/bin/bash

set -ouex pipefail

# Installing packages
dnf5 uninstall -y firefox.x86_64

# Enabling services
systemctl enable podman.socket
