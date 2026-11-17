#!/usr/bin/env bash
# DISTR0 self-test: asserts every promise the image makes about itself.
#
# It runs in two places, which is the point: in CI against the built image
# (`just test`, and in a VM e2e job) and on a device by hand
# (`/usr/share/distr0/selftest.sh`, or `ujust distr0-doctor`). Static lint cannot
# tell whether the overlay landed; this can.
#
# Exit status: 0 when every check passed, 1 otherwise.
set -uo pipefail

os_release=/usr/lib/os-release
policy=/etc/containers/policy.json
key=/usr/share/distr0/cosign.pub
registries=/etc/containers/registries.d/ghcr.io-progliodario.yaml
preinstall=/usr/share/flatpak/preinstall.d/distr0.preinstall
brewfile=/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile
recipes=/usr/share/ublue-os/just/60-custom.just
wallpaper=/usr/share/backgrounds/distr0/distr0-wallpaper.png

failures=0
checks=0

ok() {
    checks=$((checks + 1))
    printf 'ok    %s\n' "$1"
}

bad() {
    checks=$((checks + 1))
    failures=$((failures + 1))
    printf 'FAIL  %s%s\n' "$1" "${2:+ — $2}"
}

compare() { # compare <label> <actual> <expected>
    if [[ $2 == "$3" ]]; then
        ok "$1"
    else
        bad "$1" "got '${2}', want '${3}'"
    fi
}

expect() { # expect <label> <command...>
    local label="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        ok "$label"
    else
        bad "$label"
    fi
}

printf 'DISTR0 self-test\n\n'

# --- Identity ---------------------------------------------------------------
if [[ -r ${os_release} ]]; then
    # shellcheck disable=SC1090,SC1091
    . "${os_release}"
    compare 'os-release NAME is DISTR0' "${NAME:-}" DISTR0
    case ${PRETTY_NAME:-} in
        *DISTR0*) ok "os-release PRETTY_NAME mentions DISTR0 (${PRETTY_NAME})" ;;
        *) bad 'os-release PRETTY_NAME mentions DISTR0' "${PRETTY_NAME:-unset}" ;;
    esac
    compare 'VARIANT_ID is distr0' "${VARIANT_ID:-}" distr0
    compare 'IMAGE_ID is distr0' "${IMAGE_ID:-}" distr0
    if [[ -n ${IMAGE_VERSION:-} ]]; then
        ok "IMAGE_VERSION is set (${IMAGE_VERSION})"
    else
        bad 'IMAGE_VERSION is set'
    fi
    compare 'LOGO is distr0-logo' "${LOGO:-}" distr0-logo
    # The distribution fields must keep describing the base, not the fork.
    compare 'os-release ID still says bluefin' "${ID:-}" bluefin
else
    bad "reading ${os_release}"
fi

# --- Shipped files ----------------------------------------------------------
for file in \
    /usr/share/doc/distr0/README.md \
    "${wallpaper}" \
    /usr/share/icons/hicolor/scalable/apps/distr0-logo.svg \
    "${preinstall}" "${brewfile}" "${recipes}" "${key}"; do
    expect "shipped ${file}" test -s "${file}"
done

wallpaper_size="$(stat -c %s "${wallpaper}" 2> /dev/null || echo 0)"
if [[ ${wallpaper_size} -gt 10000 ]]; then
    ok "the wallpaper is a PNG of ${wallpaper_size} bytes"
else
    bad 'the wallpaper is a PNG of reasonable size' "${wallpaper_size} bytes"
fi

localtime_target="$(readlink /etc/localtime 2> /dev/null || true)"
case ${localtime_target} in
    *zoneinfo/Europe/Rome) ok '/etc/localtime points at Europe/Rome' ;;
    *) bad '/etc/localtime points at Europe/Rome' "${localtime_target:-not a symlink}" ;;
esac

expect 'locale is it_IT.UTF-8' grep -q '^LANG=it_IT.UTF-8' /etc/locale.conf
expect 'console keymap is it2' grep -q '^KEYMAP=it2' /etc/vconsole.conf
expect 'dconf branding ships as 99-' test -f /etc/dconf/db/distro.d/99-distr0-branding

# --- Update verification ----------------------------------------------------
if [[ -r ${key} ]]; then
    key_header="$(head -c 26 "${key}" 2> /dev/null || true)"
    compare 'cosign.pub is a PEM public key' "${key_header}" '-----BEGIN PUBLIC KEY-----'
else
    bad 'cosign.pub is readable'
fi

scope="$(jq -c '.transports.docker["ghcr.io/progliodario/distr0"][0] // empty' "${policy}" 2> /dev/null)"
if [[ -n ${scope} ]]; then
    ok 'the policy has a scope for this repository'
else
    bad 'the policy has a scope for this repository'
fi
case ${scope} in
    *sigstoreSigned*) ok 'the scope is sigstoreSigned' ;;
    *) bad 'the scope is sigstoreSigned' "${scope:-empty}" ;;
esac
case ${scope} in
    *'/usr/share/distr0/cosign.pub'*) ok 'the scope points at the shipped key' ;;
    *) bad 'the scope points at the shipped key' "${scope:-empty}" ;;
esac

default_type="$(jq -r '.default[0].type // empty' "${policy}" 2> /dev/null)"
compare 'the policy default is still insecureAcceptAnything' "${default_type}" insecureAcceptAnything
# Whether the base image shipped two scopes or twenty is its business; the build
# fails if the merge ever loses one, so this is a number worth printing, not a
# second place to assert it.
policy_scopes="$(jq -r '.transports.docker | length' "${policy}" 2> /dev/null || echo 0)"
printf 'note  %s policy scopes are registered in total\n' "${policy_scopes:-0}"

expect 'registries.d enables sigstore attachments' grep -q 'use-sigstore-attachments: *true' "${registries}"

# --- Declarations -----------------------------------------------------------
expect 'the Flatpak list declares at least one app' grep -q '^\[Flatpak Preinstall ' "${preinstall}"
expect 'the Flatpak list declares Firefox' grep -q 'org.mozilla.firefox' "${preinstall}"
expect 'the Homebrew list declares formulae' grep -q '^brew "' "${brewfile}"
for recipe in distr0-info distr0-update distr0-apps distr0-cli distr0-verify distr0-doctor; do
    expect "ujust ${recipe} exists" grep -q "^${recipe}" "${recipes}"
done

# --- System -----------------------------------------------------------------
expect 'bootc is installed' command -v bootc
kernels="$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d 2> /dev/null | wc -l)"
if [[ ${kernels} -ge 1 ]]; then
    ok "a kernel is installed (${kernels} under /usr/lib/modules)"
else
    bad 'a kernel is installed' 'none under /usr/lib/modules'
fi

# The two units this repository enables itself must be enabled in the image.
# The base image owns how its preinstall services are wired, so those are only
# reported: asserting them would test Bluefin, not DISTR0.
for unit in dconf-update.service podman.socket; do
    expect "${unit} unit file is shipped" test -f "/usr/lib/systemd/system/${unit}"
    if find /etc/systemd/system -name "${unit}" -type l -print -quit 2> /dev/null | grep -q .; then
        ok "${unit} is enabled"
    else
        bad "${unit} is enabled" 'no enablement symlink under /etc/systemd/system'
    fi
done
for unit in flatpak-preinstall.service brew-preinstall.service; do
    state="$(systemctl --root=/ is-enabled "${unit}" 2> /dev/null || true)"
    printf 'note  %-28s %s\n' "${unit}" "${state:-unknown}"
done

printf '\n%d checks, %d failed\n' "${checks}" "${failures}"
if [[ ${failures} -ne 0 ]]; then
    exit 1
fi
