#!/bin/bash

set -ouex pipefail

dnf5 remove -y \
  firefox.x86_64

sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
sudo flatpak remote-modify --enable flathub
sudo flatpak install flathub com.microsoft.Edge

systemctl enable podman.socket
