#!/bin/bash

set -ouex pipefail

dnf5 remove -y \
  firefox.x86_64
  
sudo flatpak install flathub com.microsoft.Edge

systemctl enable podman.socket
