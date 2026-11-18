#!/usr/bin/env bash
# The DISTR0 greeting.
#
# Sourced by /etc/profile.d/zz-distr0-banner.sh, which decides *whether* to greet;
# this file only knows *what* to say, so `ujust distr0-greeting` and the login
# banner cannot drift apart. Run it directly to see the banner now.
#
# Everything it prints comes from the running system: the image version, the
# kernel and the commands are read, never hardcoded, so a version bump does not
# need an edit here.
# shellcheck shell=bash

distr0_banner() {
    local pretty_name=DISTR0 image_version=unknown base_id=fedora key value
    local kernel accent dim reset

    if [[ -r /etc/os-release ]]; then
        while IFS='=' read -r key value; do
            value=${value//\"/}
            case ${key} in
                PRETTY_NAME) pretty_name=${value} ;;
                IMAGE_VERSION) image_version=${value} ;;
                ID) base_id=${value} ;;
            esac
        done < /etc/os-release
    fi

    kernel="$(uname -r)"
    accent=''
    dim=''
    reset=''
    if [[ -z ${NO_COLOR:-} && ${TERM:-} != dumb && -t 1 ]]; then
        accent=$'\033[38;2;90;209;255m'
        dim=$'\033[2m'
        reset=$'\033[0m'
    fi

    printf '\n'
    printf '  %s%s%s %s·%s image %s\n' "${accent}" "${pretty_name}" "${reset}" "${dim}" "${reset}" "${image_version}"
    printf '  %s%s · kernel %s%s\n' "${dim}" "${base_id}" "${kernel}" "${reset}"
    printf '\n'
    printf '  %supdate%s   ujust distr0-update\n' "${accent}" "${reset}"
    printf '  %sverify%s   ujust distr0-verify\n' "${accent}" "${reset}"
    printf '  %shelp%s     ujust --list        %squiet: DISTR0_NO_BANNER=1%s\n' \
        "${accent}" "${reset}" "${dim}" "${reset}"
    printf '\n'
}

# Sourced by the login shell: define the function and say nothing.
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    return 0
fi

distr0_banner
