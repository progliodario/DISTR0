#!/usr/bin/env bash
# Checks that run *inside* the booted image, over SSH, as the unprivileged
# `gate` user. Nothing here needs root: the point is to inspect what a user's
# desktop would read. scripts/boot-gate.sh runs this with the SHA-256 of the
# files this commit ships in the environment.
#
# DISTR0_GATE_ROOT exists only so the repository's own tests can run these
# checks against a fixture; the gate never sets it, and it defaults to /.
#
# The predicates below are called by name through `check`, which shellcheck
# cannot follow; without this it calls every one of them unreachable.
# shellcheck disable=SC2317
set -uo pipefail

root="${DISTR0_GATE_ROOT:-}"
checks=0
failures=0

ok() {
    printf 'ok    %s\n' "$1"
    checks=$((checks + 1))
}

bad() {
    printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}"
    checks=$((checks + 1))
    failures=$((failures + 1))
}

check() {
    local label="$1"
    shift
    if "$@"; then
        ok "${label}"
    else
        bad "${label}"
    fi
}

wait_for_file() {
    local path="$1" _
    for _ in $(seq 1 20); do
        [[ -e ${path} ]] && return 0
        sleep 1
    done
    return 1
}

hash_is() {
    local path="$1" expected="$2"
    [[ -r ${path} ]] || return 1
    [[ "$(sha256sum "${path}" | cut -d' ' -f1)" == "${expected}" ]]
}

# Read a key the way the desktop does: a throwaway profile that points at the
# compiled system database, so the value comes from dconf, not from the file in
# /etc/dconf/db that has not been compiled.
dconf_read() {
    local db="$1" key="$2" profile
    profile="$(mktemp)"
    printf 'user-db:user\nsystem-db:%s\n' "${db}" > "${profile}"
    DCONF_PROFILE="${profile}" dconf read "${key}" 2> /dev/null | tr -d "'"
    rm -f "${profile}"
}

have() {
    command -v "$1" > /dev/null 2>&1
}

# --- The system that booted -------------------------------------------------
check "the system booted an ostree/bootc deployment" test -f "${root}/run/ostree-booted"

image_id=""
image_version=""
if [[ -r ${root}/etc/os-release ]]; then
    # Read the two keys instead of sourcing: the file is data, not a script.
    image_id="$(sed -n 's/^IMAGE_ID=//p' "${root}/etc/os-release" | tr -d '"')"
    image_version="$(sed -n 's/^IMAGE_VERSION=//p' "${root}/etc/os-release" | tr -d '"')"
fi
is_distr0() { [[ ${image_id} == distr0 && -n ${image_version} ]]; }
check "the running system is DISTR0 with an image version" is_distr0

# --- The login screen -------------------------------------------------------
check "GDM is active" systemctl is-active --quiet gdm.service
check "GDM runs a greeter session" pgrep -u gdm -x gnome-shell
check "the gate can allocate a pty for an interactive shell" have script
check "dconf is available" have dconf

# --- Shipped identity, by content and by what the desktop reads -------------
check "the GDM wordmark is the shipped file" \
    hash_is "${root}/usr/share/pixmaps/distr0-gdm-logo.png" "${EXPECT_GDM_LOGO_SHA256:?}"
wait_for_file "${root}/etc/dconf/db/gdm" || true
check "the greeter's dconf database is compiled" test -r "${root}/etc/dconf/db/gdm"
check "the greeter points at the DISTR0 wordmark" \
    test "$(dconf_read gdm /org/gnome/login-screen/logo)" = /usr/share/pixmaps/distr0-gdm-logo.png

check "the light wallpaper is the shipped file" \
    hash_is "${root}/usr/share/backgrounds/distr0/distr0-wallpaper-light.png" "${EXPECT_LIGHT_WALLPAPER_SHA256:?}"
wait_for_file "${root}/etc/dconf/db/distro" || true
check "the desktop's dconf database is compiled" test -r "${root}/etc/dconf/db/distro"
check "light mode selects the shipped light wallpaper" \
    test "$(dconf_read distro /org/gnome/desktop/background/picture-uri)" = \
    file:///usr/share/backgrounds/distr0/distr0-wallpaper-light.png

# --- The login banner -------------------------------------------------------
check "the greeting text is the shipped file" \
    hash_is "${root}/usr/share/distr0/banner.sh" "${EXPECT_BANNER_SHA256:?}"
check "the login hook is the shipped file" \
    hash_is "${root}/etc/profile.d/zz-distr0-banner.sh" "${EXPECT_BANNER_HOOK_SHA256:?}"

interactive="$(script -qec 'bash -l -i -c true' /dev/null 2>&1 || true)"
noninteractive="$(bash -l -c true 2>&1 || true)"
quiet="$(DISTR0_NO_BANNER=1 script -qec 'bash -l -i -c true' /dev/null 2>&1 || true)"
twice="$(script -qec 'bash -l -i -c ". /etc/profile.d/zz-distr0-banner.sh; . /etc/profile.d/zz-distr0-banner.sh"' /dev/null 2>&1 || true)"

banner_shows() { grep -q 'ujust distr0-update' <<< "${interactive}"; }
banner_is_silent() { ! grep -q 'ujust distr0-update' <<< "${noninteractive}"; }
banner_can_be_disabled() { ! grep -q 'ujust distr0-update' <<< "${quiet}"; }
banner_greets_once() { [[ "$(grep -c 'ujust distr0-update' <<< "${twice}")" -eq 1 ]]; }

check "the login banner greets an interactive login shell" banner_shows
check "the login banner stays out of non-interactive shells" banner_is_silent
check "DISTR0_NO_BANNER=1 silences the login banner" banner_can_be_disabled
check "the login banner greets once per session" banner_greets_once

# --- Italian defaults, on the booted system ---------------------------------
locale_status="$(localectl status 2> /dev/null || true)"
locale_is_italian() { grep -q 'LANG=it_IT.UTF-8' <<< "${locale_status}"; }
keymap_is_italian() { grep -q 'VC Keymap: it2' <<< "${locale_status}"; }
timezone_is_rome() { [[ "$(timedatectl show -p Timezone --value 2> /dev/null)" == Europe/Rome ]]; }

check "the locale is it_IT.UTF-8" locale_is_italian
check "the console keymap is it2" keymap_is_italian
check "the timezone is Europe/Rome" timezone_is_rome

# --- Result -----------------------------------------------------------------
printf '\n'
if ((failures == 0)); then
    printf 'boot gate checks: all %d passed\n' "${checks}"
    exit 0
fi
printf 'boot gate checks: %d of %d failed\n' "${failures}" "${checks}"
exit 1
