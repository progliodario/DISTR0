#!/bin/bash

set -ouex pipefail

rpm --import https://packages.microsoft.com/keys/microsoft.asc
cat > /etc/yum.repos.d/microsoft-edge.repo << 'REPOEOF'
[microsoft-edge]
name=microsoft-edge
baseurl=https://packages.microsoft.com/yumrepos/edge
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
REPOEOF
dnf install -y microsoft-edge-stable

#dnf5 remove -y \
  

#dnf5 install -y \
  

systemctl enable podman.socket
