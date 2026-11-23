# DISTR0 login banner.
#
# Sourced by bash login shells from /etc/profile.d. It stays quiet unless the
# shell is interactive, prints once per session (a second terminal, a tmux
# window or `sudo -i` must not repeat it), and never breaks the shell if
# something is missing. Set DISTR0_NO_BANNER=1 in ~/.profile or
# /etc/environment to turn it off permanently; `ujust toggle-user-motd` does
# the same per user with ~/.config/no-show-user-motd, the switch Bluefin's own
# motd used (DISTR0 replaces that motd, so one greeting is shown, not two).
#
# What it says lives in /usr/share/distr0/banner.sh, which is also what
# `ujust distr0-greeting` runs: one source of truth for both.
# shellcheck shell=bash

if [[ $- == *i* ]] \
    && [[ ${DISTR0_NO_BANNER:-0} != 1 ]] \
    && [[ -z ${DISTR0_BANNER_SHOWN:-} ]] \
    && [[ ! -e ${HOME:-/nonexistent}/.config/no-show-user-motd ]] \
    && [[ -r /usr/share/distr0/banner.sh ]]; then
    export DISTR0_BANNER_SHOWN=1
    # shellcheck disable=SC1091  # an image path, so shellcheck cannot follow it
    . /usr/share/distr0/banner.sh
    distr0_banner
fi
