#!/bin/bash

set -ouex pipefail

# ---------------------------------------------------------------------------
# 1. Overlay
# Every file under system_files/ is copied into the final image. The tree
# mirrors the root filesystem, so system_files/usr/share/doc/distr0/README.md
# ends up at /usr/share/doc/distr0/README.md.
# ---------------------------------------------------------------------------
cp -avf "/ctx/system_files/." /

# ---------------------------------------------------------------------------
# 2. Host packages
# Keep this list as small as possible: GUI apps belong in Flatpaks, CLI tools in
# Homebrew, workloads in distrobox/toolbox. Everything already shipped by the
# Bluefin base does not need to be installed again.
#
# Italian language support: the glibc langpack provides the it_IT.UTF-8 locale
# set in /etc/locale.conf, the others are the Italian dictionaries.
# ---------------------------------------------------------------------------
# `install_weak_deps=False` keeps the package set deterministic: a weak
# dependency appearing upstream must not silently change what lands here.
dnf5 install -y --setopt=install_weak_deps=False \
    glibc-langpack-it \
    hunspell-it \
    hyphen-it \
    mythes-it

# COPRs, when a package is not in Fedora or RPM Fusion. Always disable the COPR
# again so it does not leak into the final image:
# dnf5 -y copr enable <user>/<copr>
# dnf5 -y install <package>
# dnf5 -y copr disable <user>/<copr>

# ---------------------------------------------------------------------------
# 3. Branding: rebrand os-release
# os-release has no drop-in directory, and shipping a static copy from git
# would freeze VERSION_ID. Rewrite the base file in place instead, keeping every
# field the base image set and overriding only the identity strings.
# ---------------------------------------------------------------------------
base_version_id="$(sed -n 's/^VERSION_ID=//p' /usr/lib/os-release | tr -d '"' | head -n1)"
if [[ -z "$base_version_id" ]]; then
    echo "Could not read VERSION_ID from /usr/lib/os-release" >&2
    exit 1
fi

# IMAGE_ID/IMAGE_VERSION are what modern bootc/Fedora tooling reads to identify
# the image itself rather than the distribution it derives from. The version is
# the base image's OSTREE_VERSION, which already tracks the build that produced
# the rootfs; it is lower-case and inside [a-z0-9._-] as systemd requires.
base_image_version="$(sed -n 's/^OSTREE_VERSION=//p' /usr/lib/os-release | head -n1)"
base_image_version="${base_image_version//\"/}"
base_image_version="${base_image_version//\'/}"
if [[ -z "$base_image_version" ]]; then
    echo "Could not read OSTREE_VERSION from /usr/lib/os-release" >&2
    exit 1
fi

cp /usr/lib/os-release /tmp/os-release.base

set_os_release() {
    local key="$1"
    local value="$2"
    if grep -q "^${key}=" /tmp/os-release.base; then
        sed -i "s|^${key}=.*|${key}=${value}|" /tmp/os-release.base
    else
        printf '%s=%s\n' "$key" "$value" >> /tmp/os-release.base
    fi
}

set_os_release NAME '"DISTR0"'
set_os_release PRETTY_NAME "\"DISTR0 ${base_version_id} (Bluefin)\""
set_os_release VARIANT '"DISTR0"'
set_os_release VARIANT_ID 'distr0'
set_os_release IMAGE_ID 'distr0'
set_os_release IMAGE_VERSION "${base_image_version}"
set_os_release LOGO 'distr0-logo'
set_os_release HOME_URL '"https://github.com/progliodario/DISTR0"'
set_os_release DOCUMENTATION_URL '"https://github.com/progliodario/DISTR0#readme"'
set_os_release SUPPORT_URL '"https://github.com/progliodario/DISTR0/issues"'
set_os_release BUG_REPORT_URL '"https://github.com/progliodario/DISTR0/issues"'

install -m 0644 /tmp/os-release.base /usr/lib/os-release
rm -f /tmp/os-release.base

# ---------------------------------------------------------------------------
# 4. Services
# dconf-update.service compiles /etc/dconf/db/distro.d (our branding and
# keyboard defaults) into the dconf database on boot.
# flatpak-preinstall.service and brew-preinstall.service are already enabled by
# the Bluefin base and pick up the files we ship under their preinstall.d paths.
# ---------------------------------------------------------------------------
systemctl enable podman.socket
systemctl enable dconf-update.service

# ---------------------------------------------------------------------------
# 5. Verified updates
# Teach containers/image that this repository's images are signed with the
# DISTR0 key, so `bootc switch --enforce-container-sigpolicy` works and every
# later `bootc upgrade` on such a deployment verifies the cosign signature
# before pulling. The policy is merged, never replaced: the scopes the base
# image ships (including Universal Blue's own key) stay untouched.
# ---------------------------------------------------------------------------
install -Dm0644 /ctx/cosign.pub /usr/share/distr0/cosign.pub

policy=/etc/containers/policy.json
if [[ ! -f "$policy" ]]; then
    printf '{"default":[{"type":"insecureAcceptAnything"}],"transports":{}}\n' > "$policy"
fi

# What the base image ships, measured before the merge: the merge must only add.
base_scope_count="$(jq -r '.transports.docker // {} | length' "$policy")"
merged_policy="$(mktemp)"
jq --arg key /usr/share/distr0/cosign.pub '
    .transports = (.transports // {})
    | .transports.docker = (.transports.docker // {})
    | .transports.docker["ghcr.io/progliodario/distr0"] = [{
        "type": "sigstoreSigned",
        "keyPath": $key,
        "signedIdentity": {"type": "matchRepository"}
    }]
' "$policy" > "$merged_policy"
install -m0644 "$merged_policy" "$policy"
rm -f "$merged_policy"

merged_scope_count="$(jq -r '.transports.docker | length' "$policy")"
if [[ ${merged_scope_count} -le ${base_scope_count} ]]; then
    echo "The policy merge lost scopes: ${base_scope_count} -> ${merged_scope_count}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Smoke tests
# Fail the build early if the overlay or the branding did not land, instead of
# shipping an image that silently lost them.
# ---------------------------------------------------------------------------
test -f /usr/share/doc/distr0/README.md
test -f /usr/share/backgrounds/distr0/distr0-wallpaper.png
test -f /usr/share/flatpak/preinstall.d/distr0.preinstall
test -f /usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile
test -f /usr/share/ublue-os/just/60-custom.just
test -L /etc/localtime
grep -q '^NAME="DISTR0"' /usr/lib/os-release
grep -q '^LOGO=distr0-logo' /usr/lib/os-release
grep -q '^IMAGE_ID=distr0' /usr/lib/os-release
grep -q '^IMAGE_VERSION=latest-4' /usr/lib/os-release
grep -q '^LANG=it_IT.UTF-8' /etc/locale.conf
test -f /usr/share/distr0/cosign.pub
test -f /etc/containers/registries.d/ghcr.io-progliodario.yaml
jq -e '.transports.docker["ghcr.io/progliodario/distr0"][0].type == "sigstoreSigned"' \
    /etc/containers/policy.json > /dev/null
jq -e '.default[0].type == "insecureAcceptAnything"' \
    /etc/containers/policy.json > /dev/null
