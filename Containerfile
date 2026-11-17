# Allow build scripts to be referenced without being copied into the final image
FROM scratch AS ctx
COPY build_files /
COPY system_files /system_files

# Base Image
# DISTR0 is built on Bluefin (Universal Blue / Fedora Atomic GNOME).
# The base is pinned by digest so every build starts from a byte-identical image.
# Bump it on purpose (Renovate opens this bump automatically):
#   skopeo inspect docker://ghcr.io/ublue-os/bluefin:stable | jq -r .Digest
FROM ghcr.io/ublue-os/bluefin:stable@sha256:cb2e0f54caffb681ca4405d34236591a378430102e1704c6b2c78e3ff969f8bf

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache \
    --mount=type=cache,dst=/var/log \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build.sh

# Verify final image and contents are correct.
RUN bootc container lint
