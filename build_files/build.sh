#!/bin/bash

set -ouex pipefail

dnf5 remove -y firefox.x86_64
dnf5 install -y microsoft-edge

systemctl enable podman.socket
