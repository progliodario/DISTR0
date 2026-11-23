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

# dnf leaves its repository state in /var/lib/dnf and a lock directory in /run.
# Neither belongs in an image: /var is the machine's own state and /run is a
# tmpfs at boot, and `bootc container lint --fatal-warnings` rejects both.
dnf5 clean all
rm -rf /var/lib/dnf /run/dnf

# ---------------------------------------------------------------------------
# 3. Branding: desktop defaults, then os-release
# A gschema override is part of the schema database, not of dconf: it only
# applies once /usr/share/glib-2.0/schemas/gschemas.compiled is rebuilt, which is
# a build-time job (the dconf drop-ins under /etc/dconf/db/distro.d are compiled
# at boot by dconf-update.service, so those need nothing here).
# ---------------------------------------------------------------------------
glib-compile-schemas /usr/share/glib-2.0/schemas

# os-release has no drop-in directory, and shipping a static copy from git
# would freeze VERSION_ID. Rewrite the base file in place instead, keeping every
# field the base image set and overriding only the identity strings.
# ---------------------------------------------------------------------------
# The build passes its date and commit in; a local `just build` without them
# still produces a valid, clearly local version.
build_date="${DISTR0_BUILD_DATE:-$(date -u +%Y%m%d)}"
build_revision="${DISTR0_REVISION:-local}"
if [[ ! ${build_date} =~ ^[0-9]{8}$ ]]; then
    echo "DISTR0_BUILD_DATE must be YYYYMMDD, got '${build_date}'" >&2
    exit 1
fi

base_version_id="$(sed -n 's/^VERSION_ID=//p' /usr/lib/os-release | tr -d '"' | head -n1)"
if [[ -z "$base_version_id" ]]; then
    echo "Could not read VERSION_ID from /usr/lib/os-release" >&2
    exit 1
fi

# IMAGE_ID/IMAGE_VERSION are what modern bootc/Fedora tooling reads to identify
# the image itself rather than the distribution it derives from, so the version
# is DISTR0's own build: <Fedora release>.<build date>, inside [a-z0-9._-] as
# systemd requires. The Bluefin build it starts from stays readable as
# BLUEFIN_VERSION (the base's OSTREE_VERSION, which Bluefin's tools parse and
# which is therefore left untouched).
base_image_version="$(sed -n 's/^OSTREE_VERSION=//p' /usr/lib/os-release | head -n1)"
base_image_version="${base_image_version//\"/}"
base_image_version="${base_image_version//\'/}"
if [[ -z "$base_image_version" ]]; then
    echo "Could not read OSTREE_VERSION from /usr/lib/os-release" >&2
    exit 1
fi
image_version="${base_version_id}.${build_date}"

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
set_os_release VERSION "\"${image_version} (DISTR0)\""
set_os_release PRETTY_NAME "\"DISTR0 ${base_version_id} (Bluefin)\""
set_os_release VARIANT '"DISTR0"'
set_os_release VARIANT_ID 'distr0'
set_os_release IMAGE_ID 'distr0'
set_os_release IMAGE_VERSION "${image_version}"
set_os_release BUILD_ID "\"${build_revision:0:12}\""
set_os_release BLUEFIN_VERSION "\"${base_image_version}\""
# The initramfs is still the base's, with Bluefin's os-release, and systemd
# keeps the hostname the initrd set unless /etc/hostname exists: the image
# therefore also ships /etc/hostname, written by a COPY in the Containerfile
# (a RUN step only sees the builder's own bind-mounted file). hostnamectl (or
# Settings → About) rewrites it, and ostree keeps a changed /etc file across
# updates.
set_os_release DEFAULT_HOSTNAME '"distr0"'
set_os_release LOGO 'distr0-logo'
set_os_release HOME_URL '"https://github.com/progliodario/DISTR0"'
set_os_release DOCUMENTATION_URL '"https://github.com/progliodario/DISTR0#readme"'
set_os_release SUPPORT_URL '"https://github.com/progliodario/DISTR0/issues"'
set_os_release BUG_REPORT_URL '"https://github.com/progliodario/DISTR0/issues"'

install -m 0644 /tmp/os-release.base /usr/lib/os-release
rm -f /tmp/os-release.base

# Bluefin's own tools do not read os-release to know which image they run on:
# the motd, `ujust changelogs`, `ujust devmode` and `ujust rebase-helper` read
# /usr/share/ublue-os/image-info.json. Left as the base ships it, that file
# names ghcr.io/ublue-os/bluefin, and `ujust devmode` would `bootc switch` a
# DISTR0 machine to bluefin-dx. Every field that names the image becomes
# DISTR0's; the others (Fedora version, flavor) stay the base's.
image_info=/usr/share/ublue-os/image-info.json
if [[ -f "$image_info" ]]; then
    merged_info="$(mktemp)"
    jq '. + {
        "image-name": "distr0",
        "image-vendor": "progliodario",
        "image-ref": "ostree-image-signed:docker://ghcr.io/progliodario/distr0",
        "image-tag": "latest",
        "base-image-name": "bluefin"
    }' "$image_info" > "$merged_info"
    install -m 0644 "$merged_info" "$image_info"
    rm -f "$merged_info"
fi

# `ujust` resolves a recipe defined in several imported files to the *first*
# import, so DISTR0's recipes could never replace Bluefin's while
# 60-custom.just is imported last. Import it first instead: the recipes it
# redefines (devmode, rebase-helper, changelogs, toggle-user-motd) then point
# at DISTR0, and everything else stays Bluefin's.
entry=/usr/share/ublue-os/just/00-entry.just
custom_import='import? "/usr/share/ublue-os/just/60-custom.just"'
if [[ -f "$entry" ]]; then
    grep -vxF "$custom_import" "$entry" > /tmp/00-entry.just
    awk -v line="$custom_import" '
        !done && /^import/ { print line; done = 1 }
        { print }
        END { if (!done) print line }
    ' /tmp/00-entry.just > /tmp/00-entry.just.new
    install -m 0644 /tmp/00-entry.just.new "$entry"
    rm -f /tmp/00-entry.just /tmp/00-entry.just.new
fi

# One greeting per shell, and it is DISTR0's: Bluefin's motd names the base
# image and repeats what the DISTR0 banner says. The banner honours the same
# ~/.config/no-show-user-motd switch, so `ujust toggle-user-motd` keeps working.
rm -f /etc/profile.d/ublue-motd.sh

# ---------------------------------------------------------------------------
# 4. Services
# dconf-update.service compiles /etc/dconf/db/distro.d (our branding and
# keyboard defaults) into the dconf database on boot.
# flatpak-preinstall.service and brew-preinstall.service are already enabled by
# the Bluefin base and pick up the files we ship under their preinstall.d paths.
# ---------------------------------------------------------------------------
systemctl enable podman.socket
systemctl enable dconf-update.service

# Smart cards (CIE, CNS, firma digitale): pcscd and OpenSC come with the base.
# Flatpak browsers reach the host's PKCS#11 modules only through the p11-kit
# server socket, so enable it for every user session.
systemctl --global enable p11-kit-server.socket

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
base_default="$(jq -c '.default // null' "$policy")"
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

# The default entry is the base image's decision, whatever it is; the merge must
# leave it exactly as it was.
merged_default="$(jq -c '.default // null' "$policy")"
if [[ ${merged_default} != "${base_default}" ]]; then
    echo "The policy merge changed the default entry: ${base_default} -> ${merged_default}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 6. Smoke tests
# Fail the build early if the overlay or the branding did not land, instead of
# shipping an image that silently lost them.
# ---------------------------------------------------------------------------
test -f /usr/share/doc/distr0/README.md
test -f /usr/share/backgrounds/distr0/distr0-wallpaper.png
test -f /usr/share/backgrounds/distr0/distr0-wallpaper-light.png
test -f /usr/share/pixmaps/distr0-gdm-logo.png
test -f /etc/dconf/db/gdm.d/01-distr0-gdm
test -f /usr/share/distr0/banner.sh
test -f /etc/profile.d/zz-distr0-banner.sh
test -f /usr/share/distr0/ascii-logo.txt
test -f /usr/share/fastfetch/presets/distr0.jsonc
jq -e . /usr/share/fastfetch/presets/distr0.jsonc > /dev/null
test -f /usr/share/glib-2.0/schemas/zz0-distr0.gschema.override
grep -q 'accent-color' /usr/share/glib-2.0/schemas/zz0-distr0.gschema.override
test -f /usr/share/flatpak/preinstall.d/distr0.preinstall
test -f /usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile
test -f /usr/share/ublue-os/just/60-custom.just
test -L /etc/localtime
grep -q '^NAME="DISTR0"' /usr/lib/os-release
grep -q '^LOGO=distr0-logo' /usr/lib/os-release
grep -q '^IMAGE_ID=distr0' /usr/lib/os-release
grep -qE "^IMAGE_VERSION=${base_version_id}\.[0-9]{8}$" /usr/lib/os-release
grep -q '^DEFAULT_HOSTNAME="distr0"' /usr/lib/os-release
grep -q '^OSTREE_VERSION=' /usr/lib/os-release
jq -e '."image-name" == "distr0" and (."image-ref" | endswith("ghcr.io/progliodario/distr0"))' \
    /usr/share/ublue-os/image-info.json > /dev/null
test ! -e /etc/profile.d/ublue-motd.sh
head -n 20 /usr/share/ublue-os/just/00-entry.just | grep -qF "$custom_import"
test -f /etc/X11/xorg.conf.d/00-keyboard.conf
test -f /usr/share/gnome-background-properties/distr0.xml
test -L /etc/systemd/user/sockets.target.wants/p11-kit-server.socket
test ! -e /var/lib/dnf
test ! -e /run/dnf
grep -q '^LANG=it_IT.UTF-8' /etc/locale.conf
test -f /usr/share/distr0/cosign.pub
test -f /etc/containers/registries.d/ghcr.io-progliodario.yaml
jq -e '.transports.docker["ghcr.io/progliodario/distr0"][0].type == "sigstoreSigned"' \
    /etc/containers/policy.json > /dev/null

