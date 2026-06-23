#!/bin/bash

set -ouex pipefail

dnf5 remove -y \
  firefox.x86_64
  
sudo curl -sSL -O https://packages.microsoft.com/fedora/44/prod/Packages/p/packages-microsoft-prod-1.1-3.noarch.rpm
rpm -i packages-microsoft-prod-1.1-3.noarch.rpm
rm packages-microsoft-prod-1.1-3.noarch.rpm
dnf5 update
dnf5 install -y microsoft-edge.stable

systemctl enable podman.socket
