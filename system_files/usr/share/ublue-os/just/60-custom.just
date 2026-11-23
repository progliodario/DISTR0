# DISTR0 custom recipes.
#
# build.sh moves the import of this file to the top of
# /usr/share/ublue-os/just/00-entry.just: `ujust` resolves a recipe defined in
# several imported files to the first import, so that is what lets the recipes
# below replace Bluefin's recipes of the same name (devmode, rebase-helper,
# changelogs, toggle-user-motd). Every other Bluefin recipe stays as it is.
#
# Messages are Italian, like the rest of the system; recipe names stay English
# so they match Bluefin's and the documentation.

# Mostra quale immagine è avviata e come è configurata
[group('DISTR0')]
distr0-info:
    #!/usr/bin/env bash
    set -uo pipefail
    . /etc/os-release
    printf 'DISTR0\n'
    printf '  Sistema:      %s\n' "${PRETTY_NAME:-sconosciuto}"
    printf '  Immagine:     %s %s (Bluefin %s)\n' "${IMAGE_ID:-?}" "${IMAGE_VERSION:-?}" "${BLUEFIN_VERSION:-?}"
    printf '  Kernel:       %s\n' "$(uname -r)"
    printf '  Lingua:       %s\n' "${LANG:-non impostata}"
    printf '  Fuso orario:  %s\n' "$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
    printf '  Flatpak:      %s di sistema, %s utente\n' \
        "$(flatpak list --system --app --columns=application 2>/dev/null | wc -l)" \
        "$(flatpak list --user --app --columns=application 2>/dev/null | wc -l)"
    printf '  Homebrew:     %s\n' "$(command -v brew || echo 'non installato')"
    update_timer='nessun timer'
    for unit in uupd.timer bootc-fetch-apply-updates.timer; do
        if systemctl is-enabled --quiet "${unit}" 2>/dev/null; then
            update_timer="${unit}"
        fi
    done
    printf '  Aggiornamenti: %s\n' "${update_timer}"
    printf '\n'
    sudo bootc status | sed -n '1,25p'

# Stampa il marchio DISTR0 e un riepilogo del sistema (fastfetch)
[group('DISTR0')]
distr0-greeting:
    #!/usr/bin/env bash
    set -euo pipefail
    preset=/usr/share/fastfetch/presets/distr0.jsonc
    if command -v fastfetch > /dev/null && [[ -r "${preset}" ]]; then
        fastfetch --config "${preset}"
    else
        /usr/share/distr0/banner.sh
    fi

# Aggiorna immagine, Flatpak e container in un colpo solo
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
    echo "Fatto. Se è stata preparata una nuova immagine, riavvia con: sudo systemctl reboot"

# Installa i Flatpak dichiarati dall'immagine
[group('DISTR0')]
distr0-apps:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo flatpak preinstall -y
    echo "I Flatpak dichiarati da DISTR0 sono installati."

# Installa gli strumenti da riga di comando dichiarati dall'immagine (Homebrew)
[group('DISTR0')]
distr0-cli:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v brew >/dev/null; then
        echo "Homebrew non è disponibile: si installa al primo accesso grafico." >&2
        exit 1
    fi
    # brew bundle no longer writes a lock file, and recent releases reject the
    # old --no-lock flag outright; the variable is harmless where it is unknown.
    HOMEBREW_BUNDLE_NO_LOCK=1 brew bundle --file=/usr/share/ublue-os/homebrew/preinstall.d/distr0-cli.Brewfile

# Riapplica le impostazioni del desktop fornite dall'immagine
[group('DISTR0')]
distr0-reset-desktop:
    #!/usr/bin/env bash
    set -euo pipefail
    sudo dconf update
    dconf reset -f /org/gnome/desktop/background/
    dconf reset -f /org/gnome/desktop/input-sources/
    echo "Impostazioni del desktop riapplicate. Esci e rientra nella sessione."

# Imposta la lingua del sistema (italiano se non indicata)
[group('DISTR0')]
distr0-lang lang="it_IT.UTF-8":
    #!/usr/bin/env bash
    set -euo pipefail
    sudo localectl set-locale LANG="{{ lang }}"
    echo "Lingua impostata a {{ lang }}. Esci e rientra nella sessione."

# Controlla che questo sistema verifichi la firma delle immagini prima di aggiornare
[group('DISTR0')]
distr0-verify:
    #!/usr/bin/env bash
    set -uo pipefail

    key=/usr/share/distr0/cosign.pub
    policy=/etc/containers/policy.json
    registries=/etc/containers/registries.d/ghcr.io-progliodario.yaml

    printf 'Verifica degli aggiornamenti DISTR0\n'
    if [[ -f "${key}" ]]; then
        printf '  chiave:      %s\n' "${key}"
    else
        printf "  chiave:      MANCANTE, questa non è l'immagine descritta nel README\n"
    fi

    scope="$(jq -c '.transports.docker["ghcr.io/progliodario/distr0"][0] // empty' "${policy}" 2>/dev/null)"
    if [[ -n "${scope}" ]]; then
        printf '  policy:      %s\n' "${scope}"
    else
        printf '  policy:      nessuna regola sigstoreSigned per ghcr.io/progliodario/distr0\n'
    fi

    if [[ -f "${registries}" ]]; then
        printf "  firme:       cercate accanto all'immagine (registries.d)\n"
    else
        printf '  firme:       %s manca\n' "${registries}"
    fi

    # The deployment origin records whether updates are checked against that
    # policy. Older references stay unverified until the image is switched once.
    ref="$(sudo ostree admin status 2>/dev/null | grep -oE 'ostree-[a-z-]*image:[^ ]+' | head -n1)"
    case "${ref}" in
        ostree-image-signed:*)
            printf '  deployment:  %s\n' "${ref}"
            printf "\nGli aggiornamenti sono verificati: un'immagine non firmata con questa chiave viene rifiutata.\n"
            ;;
        ostree-unverified-*|"")
            printf '  deployment:  %s\n' "${ref:-sconosciuto, vedi: sudo bootc status}"
            printf '\nGli aggiornamenti NON sono ancora verificati. Passa una volta al riferimento firmato:\n'
            printf '  sudo bootc switch --enforce-container-sigpolicy ghcr.io/progliodario/distr0:latest\n'
            ;;
        *)
            printf '  deployment:  %s\n' "${ref}"
            ;;
    esac

# Esegue l'autotest dell'immagine e controlla stato, servizi e disco
[group('DISTR0')]
distr0-doctor:
    #!/usr/bin/env bash
    set -uo pipefail

    failed=0

    printf '=== contenuto\n'
    /usr/share/distr0/selftest.sh || failed=1

    printf '\n=== deployment\n'
    sudo bootc status | sed -n '1,14p'

    printf '\n=== servizi falliti\n'
    systemctl --failed --no-legend --no-pager || true

    printf "\n=== software dichiarato dall'immagine\n"
    for unit in flatpak-preinstall.service brew-preinstall.service; do
        printf '  %-28s %s\n' "${unit}" "$(systemctl is-active "${unit}" 2>/dev/null || true)"
    done

    printf '\n=== disco\n'
    df -h / /var 2>/dev/null || df -h /

    exit "${failed}"

# Torna al deployment precedente (attivo dal prossimo riavvio)
[group('DISTR0')]
distr0-rollback:
    #!/usr/bin/env bash
    set -euo pipefail

    printf 'Questo prepara il ritorno al deployment precedente.\n'
    read -r -p 'Continuare? [s/N] ' reply
    if [[ ! "${reply}" =~ ^[sSyY]$ ]]; then
        echo 'Nessuna modifica.'
        exit 0
    fi
    sudo bootc rollback
    echo 'Rollback preparato. Riavvia per usarlo: sudo systemctl reboot'

# Controlla lettore di smart card, CIE/CNS e moduli PKCS#11 per firma e accesso ai servizi
[group('DISTR0')]
distr0-smartcard:
    #!/usr/bin/env bash
    set -uo pipefail

    printf 'Smart card (CIE, CNS, firma digitale)\n\n'
    printf '  pcscd:           %s\n' "$(systemctl is-active pcscd.socket 2>/dev/null || true)"
    printf '  p11-kit server:  %s\n' "$(systemctl --user is-active p11-kit-server.socket 2>/dev/null || true)"
    opensc_module=""
    for candidate in /usr/lib64/pkcs11/opensc-pkcs11.so /usr/lib64/opensc-pkcs11.so; do
        [[ -e "${candidate}" ]] && opensc_module="${candidate}" && break
    done
    printf '  modulo OpenSC:   %s\n' "${opensc_module:-non trovato}"

    printf '\n=== lettori\n'
    if ! opensc-tool --list-readers 2>&1; then
        echo 'Nessun lettore trovato: collega il lettore e riprova.'
        exit 1
    fi

    printf '\n=== carta\n'
    if opensc-tool --name 2>/dev/null; then
        pkcs11-tool --module "${opensc_module:-opensc-pkcs11.so}" --list-slots 2>/dev/null | sed -n '1,20p'
    else
        echo 'Nessuna carta nel lettore, oppure carta non riconosciuta da OpenSC.'
    fi

    printf '\nFirefox (Flatpak) usa le smart card tramite il server p11-kit: dopo aver\n'
    printf 'inserito la carta, riavvia Firefox e cercala in Impostazioni > Privacy e\n'
    printf 'sicurezza > Dispositivi di sicurezza.\n'

# DISTR0 has no developer variant: replaces Bluefin's toggle-devmode, which
# would `bootc switch` this machine to bluefin-dx and leave DISTR0.
# Modalità sviluppatore: non disponibile in DISTR0
[group('System')]
toggle-devmode:
    #!/usr/bin/env bash
    echo "DISTR0 non ha una variante per sviluppatori: questo comando non cambia immagine."
    echo "Gli strumenti di sviluppo si installano senza cambiare sistema:"
    echo "  ujust bbrew            applicazioni e strumenti da Homebrew"
    echo "  distrobox create       un ambiente Fedora/Ubuntu completo in un container"

# Replaces Bluefin's rebase-helper (and its alias rollback-helper), which only
# knows Bluefin's images: this one picks a dated DISTR0 build or goes back to
# following `latest`, always through the signed reference.
# Passa a una build DISTR0 di una data precisa, o torna a seguire latest
[group('System')]
rebase-helper:
    #!/usr/bin/env bash
    set -euo pipefail
    image=ghcr.io/progliodario/distr0
    echo "Immagine attuale: $(jq -r '"\(."image-name"):\(."image-tag")"' /usr/share/ublue-os/image-info.json)"
    mapfile -t tags < <(skopeo list-tags "docker://${image}" \
        | jq -r '.Tags[]' | grep -E '^latest\.[0-9]{8}$' | sort -rV | head -n 30)
    choice="$(gum choose --header="Scegli la build" latest "${tags[@]}" annulla)"
    [[ -z "${choice}" || "${choice}" == annulla ]] && exit 0
    gum confirm "Passare a ${image}:${choice}?" || exit 0
    pkexec bootc switch --enforce-container-sigpolicy "${image}:${choice}"
    echo "Fatto. Riavvia per usare la nuova immagine."

# Replaces Bluefin's changelogs (and its alias changelog), which shows Bluefin's
# release notes for the image named in image-info.json.
# Mostra le ultime modifiche a DISTR0
[group('System')]
changelogs:
    #!/usr/bin/env bash
    set -euo pipefail
    . /etc/os-release
    echo "DISTR0 ${IMAGE_VERSION:-?} (commit ${BUILD_ID:-?}), su Bluefin ${BLUEFIN_VERSION:-?}"
    echo
    echo "Ultime modifiche a DISTR0:"
    curl -fsSL "https://api.github.com/repos/progliodario/DISTR0/commits?per_page=15" \
        | jq -r '.[] | "  \(.commit.author.date[:10])  \(.commit.message | split("\n")[0])"' \
        || echo "  non raggiungibili ora: https://github.com/progliodario/DISTR0/commits/main"
    echo
    echo "Le novità di Bluefin, la base: https://github.com/ublue-os/bluefin/releases"

# Replaces Bluefin's toggle-user-motd: DISTR0 shows its own banner instead of
# Bluefin's motd, and the banner honours the same per-user switch.
# Attiva o disattiva il messaggio di benvenuto nel terminale
[group('System')]
toggle-user-motd:
    #!/usr/bin/env bash
    set -euo pipefail
    flag="${HOME}/.config/no-show-user-motd"
    if [[ -e "${flag}" ]]; then
        rm -f "${flag}"
        echo "Il benvenuto DISTR0 verrà mostrato nei nuovi terminali."
    else
        mkdir -p "${HOME}/.config"
        touch "${flag}"
        echo "Il benvenuto DISTR0 non verrà più mostrato."
    fi
