# DISTR0 — guida per chi lo usa

DISTR0 è un sistema Linux basato su [Bluefin](https://projectbluefin.io/)
(Fedora Atomic con GNOME), preparato per l'Italia: lingua, tastiera, fuso
orario, dizionari e strumenti per CIE, CNS e firma digitale sono pronti dal
primo avvio.

Il sistema è *immutabile*: i file di sistema non si modificano a mano, si
aggiornano tutti insieme scaricando una nuova immagine firmata. Se un
aggiornamento non va, si torna indietro con un comando.

## I comandi da conoscere

Tutti si lanciano dal Terminale.

| Comando | A cosa serve |
| --- | --- |
| `ujust distr0-update` | Aggiorna sistema, applicazioni e container |
| `ujust distr0-info` | Mostra versione, lingua, applicazioni e stato degli aggiornamenti |
| `ujust distr0-verify` | Controlla che gli aggiornamenti vengano verificati con la firma di DISTR0 |
| `ujust distr0-doctor` | Autotest completo del sistema, servizi falliti e spazio su disco |
| `ujust distr0-rollback` | Torna alla versione precedente del sistema (al prossimo riavvio) |
| `ujust rebase-helper` | Passa a una build DISTR0 di una data precisa, o torna a `latest` |
| `ujust distr0-apps` | Installa le applicazioni previste, se al primo avvio mancava la rete |
| `ujust distr0-cli` | Installa gli strumenti da riga di comando previsti (Homebrew) |
| `ujust distr0-lang en_US.UTF-8` | Cambia la lingua del sistema (senza argomento torna all'italiano) |
| `ujust distr0-smartcard` | Controlla lettore, carta CIE/CNS e moduli per la firma |
| `ujust toggle-user-motd` | Attiva o disattiva il benvenuto nel terminale |
| `ujust --list` | Tutti i comandi disponibili |

## Aggiornamenti

Il sistema si aggiorna da solo in background e applica la nuova versione al
riavvio successivo. Ogni immagine è firmata: il sistema rifiuta un'immagine che
non porta la firma di DISTR0. `ujust distr0-verify` dice se questa protezione è
attiva sul tuo computer e, se non lo è, quale comando la attiva.

Se dopo un aggiornamento qualcosa non va, `ujust distr0-rollback` (oppure
`sudo bootc rollback`) ripristina la versione precedente al riavvio.

## Applicazioni

Al primo avvio con la rete vengono installati Firefox, Thunderbird, LibreOffice
e VLC. Le altre applicazioni si installano da **Bazaar**, il negozio di
applicazioni (Flatpak). Gli strumenti da terminale si installano con Homebrew
(`brew install ...`) e gli ambienti completi di un'altra distribuzione con
`distrobox`.

## Tastiera e lingua

La tastiera italiana è attiva anche nella schermata di accesso, quindi la
password si digita con il layout che vedi sui tasti. Per cambiarla per tutto il
sistema: `sudo localectl set-x11-keymap <layout>`; per la sola sessione:
Impostazioni → Tastiera.

## CIE, CNS e firma digitale

Il sistema include il servizio per i lettori di smart card (`pcscd`), OpenSC
(che riconosce CIE e molte CNS) e il server p11-kit, attraverso cui Firefox
installato come Flatpak vede la carta.

1. Collega il lettore e inserisci la carta.
2. Esegui `ujust distr0-smartcard`: deve elencare il lettore e la carta.
3. In Firefox: Impostazioni → Privacy e sicurezza → Dispositivi di sicurezza;
   la carta compare tramite il modulo p11-kit.

Per firmare documenti si può usare il software del proprio fornitore della
firma, quando ha una versione per Linux, oppure gli strumenti di OpenSC.
Questa parte richiede un lettore e una carta reali e non è verificata dai test
automatici di DISTR0.

## Se serve aiuto

- Problemi e richieste: <https://github.com/progliodario/DISTR0/issues>
- Documentazione tecnica e codice: <https://github.com/progliodario/DISTR0>
- La base, Bluefin: <https://docs.projectbluefin.io/>
