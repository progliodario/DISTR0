# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files
# The public half of the image signing key: installed into the image so that
# bootc can verify future updates on the device.
COPY cosign.pub /cosign.pub

# Base Image
# DISTR0 is built on Bluefin (Universal Blue / Fedora Atomic GNOME).
# `latest` tracks the current Fedora release (45 as of this pin); `stable` is the
# GTS stream and is still on Fedora 44, which would be a major-version downgrade.
# The base is pinned by digest so every build starts from a byte-identical image.
# Bump it on purpose (Renovate opens this bump automatically):
#   skopeo inspect docker://ghcr.io/ublue-os/bluefin:latest | jq -r .Digest
FROM ghcr.io/ublue-os/bluefin:latest@sha256:813d7fc3a4d0fdce6620b471b109f7f8ccf921ffbc2d1dac3749d3d0e17ea615

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Verify final image and contents are correct.
RUN bootc container lint
