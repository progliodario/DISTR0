# DISTR0 custom recipes.
#
# /usr/share/ublue-os/just/00-entry.just imports this file optionally, so `ujust`
# lists these next to the upstream Bluefin recipes.

# Show which image is booted and how it is configured
[group('DISTR0')]
distr0-info:
    #!/usr/bin/env bash
    set -uo pipefail
    . /etc/os-release
    printf 'DISTR0\n'
    printf '  OS:       %s\n' "${PRETTY_NAME:-unknown}"
    printf '  Kernel:   %s\n' "$(uname -r)"
    printf '  Locale:   %s\n' "${LANG:-unset}"
    printf '  Timezone: %s\n' "$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
    printf '  Flatpaks: %s system, %s user\n' \
        "$(flatpak list --system --app --columns=application 2>/dev/null | wc -l)" \
        "$(flatpak list --user --app --columns=application 2>/dev/null | wc -l)"
    printf '  Brew:     %s\n' "$(command -v brew || echo 'not installed')"
    printf '\n'
    sudo bootc status | sed -n '1,25p'

# Update the image, Flatpaks and containers in one go
[group('DISTR0')]
distr0-update:
    #!/usr/bin/env bash
    set -euo pipefail
    if systemctl is-enabled --quiet uupd.timer 2>/dev/null; then
        sudo systemctl start uupd.service
    else
        sudo bootc upgrade
        flatpak update -y
    fi
    echo "Done. If a new image was staged, reboot with: sudo systemctl reboot"

# Install the Flatpaks declared by the image
[group('DISTR0')]
distr0-apps:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo flatpak preinstall -y
    echo "The Flatpaks declared by DISTR0 are installed."

# Install the CLI tools declared by the image (Homebrew)
[group('DISTR0')]
distr0-cli:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v brew >/dev/null; then
        echo "Homebrew is not available on this system." >&2
        exit 1
    fi
    brew bundle --no-lock --file=/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile

# Re-apply the desktop defaults shipped by the image
[group('DISTR0')]
distr0-reset-desktop:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo dconf update
    dconf reset -f /org/gnome/desktop/background/
    echo "Desktop defaults re-applied. Log out and back in."

# Set the system language (Italian by default)
[group('DISTR0')]
distr0-lang lang="it_IT.UTF-8":
    #!/usr/bin/env bash
    set -euo pipefail
    sudo localectl set-locale LANG="{{ lang }}"
    echo "Language set to {{ lang }}. Log out and back in."
