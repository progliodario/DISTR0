#!/bin/bash

set -ouex pipefail

dnf5 remove -y --skip-unavailable \
  firefox.x86_64 

systemctl enable podman.socket
