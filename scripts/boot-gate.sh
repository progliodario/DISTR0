#!/usr/bin/env bash
# Boot an image in QEMU and check what only a booted system can prove.
#
# The container build and the shipped self-test run without systemd, so neither
# can show that GDM reaches a login screen or that the desktop reads the files
# this repository ships. This script installs the image to a raw disk with the
# image's own installer, boots it, takes a screenshot of the framebuffer through
# QMP once the greeter is up, and runs scripts/boot-gate-checks.sh inside the
# guest at boot.
#
# Usage:
#   scripts/boot-gate.sh --image ghcr.io/progliodario/distr0:latest \
#       --expect-revision "$(git rev-parse HEAD)"
#   scripts/boot-gate.sh --disk output/disk.raw
#
# The first form is what `.github/workflows/boot-gate.yml` runs: it pulls the
# published image, refuses one whose OCI revision label is not the commit under
# test, and installs the image to a raw disk with the image's own installer.
# Needs podman with sudo for that, plus qemu and python3. The second form boots
# a disk that already carries the in-guest checks (one this script installed).
# KVM turns the boot into a couple of minutes; without it QEMU emulates, which
# works but is slow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# From QEMU starting to the guest's report being complete. With KVM a boot to
# GDM takes a minute or two; emulation needs far longer.
BOOT_TIMEOUT_KVM=900
BOOT_TIMEOUT_TCG=3600
# How long after the greeter is up the framebuffer may take to show it, and
# how long to let the greeter's fade-in finish before the first screenshot.
PAINT_TIMEOUT=180
PAINT_SETTLE=15
# The guest writes its report to this virtio-serial port, which QEMU saves to a
# file of its own: the serial console also carries kernel and systemd output,
# which could interleave with the report.
GATE_PORT=org.distr0.gate
GATE_DIR=/etc/distr0-boot-gate
GATE_UNIT=distr0-boot-gate.service

IMAGE=""
DISK=""
WORKDIR=""
EXPECT_REVISION=""
REQUIRE_KVM=""
QEMU_PID=""
ACCEL=""
SUDO=()

say() { printf '%s\n' "$*"; }
# The workflow turns these into notices while the gate runs, so a slow run
# reports the phase it reached before the job timeout cancels it.
phase() { printf 'PHASE %s\n' "$*"; }

die() {
    printf 'FAIL  %s\n' "$*" >&2
    exit 1
}

usage() {
    cat << 'EOF'
Boot an image in QEMU and check the running system.

  --image REF            registry image to pull and install to a disk
  --disk FILE            boot an existing disk image instead
  --expect-revision SHA  refuse an image whose OCI revision label is not SHA
  --workdir DIR          keep the log and the screenshot here (default: mktemp)
  --require-kvm          fail instead of falling back to slow TCG emulation
  -h, --help             show this text
EOF
}

need() {
    command -v "$1" > /dev/null 2>&1 || die "$1 is required but is not installed"
}

# The annotations are how a failure becomes readable: the job log needs
# permissions the repository's own automation may not have.
annotate_log() {
    local prefix="$1" log="$2" line
    tail -n 20 "${log}" 2> /dev/null | tr -d '\r' | while IFS= read -r line; do
        [[ -n ${line} ]] && printf 'FAIL  %s: %s\n' "${prefix}" "${line}"
    done
    return 0
}

stop_vm() {
    if [[ -n ${QEMU_PID} ]] && kill -0 "${QEMU_PID}" 2> /dev/null; then
        kill "${QEMU_PID}" 2> /dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "${QEMU_PID}" 2> /dev/null || break
            sleep 1
        done
        kill -9 "${QEMU_PID}" 2> /dev/null || true
    fi
    if [[ -n ${QEMU_PID} ]]; then
        wait "${QEMU_PID}" 2> /dev/null || true
    fi
}

qemu_running() {
    [[ -n ${QEMU_PID} ]] && kill -0 "${QEMU_PID}" 2> /dev/null
}

# --- Installing the disk ----------------------------------------------------

# Registry hiccups are common enough on shared runners that a single pull
# attempt should not decide whether the image gets booted, and the retry
# output is what a failed annotation shows. A stalled connection hangs podman
# pull forever, which no retry would reach; timeout makes a hung attempt a
# failed attempt.
pull_image() {
    local ref="$1" log="$2" attempt output
    for attempt in 1 2 3; do
        if output="$(timeout 900 "${SUDO[@]}" podman pull "${ref}" 2>&1)"; then
            printf '%s\n' "${output}" >> "${log}"
            return 0
        fi
        printf 'pull attempt %d failed:\n%s\n' "${attempt}" "${output}" >> "${log}"
        sleep 10
    done
    return 1
}

build_disk() {
    need podman

    say "Pulling ${IMAGE}"
    if ! pull_image "${IMAGE}" "${WORKDIR}/pull.log"; then
        annotate_log "podman pull" "${WORKDIR}/pull.log"
        die "could not pull ${IMAGE}"
    fi
    phase "pulled ${IMAGE}"

    if [[ -n ${EXPECT_REVISION} ]]; then
        local revision
        revision="$("${SUDO[@]}" podman image inspect \
            --format '{{ index .Labels "org.opencontainers.image.revision" }}' "${IMAGE}")"
        if [[ ${revision} != "${EXPECT_REVISION}" ]]; then
            die "the published image is labelled ${revision:-<none>}, not ${EXPECT_REVISION}: refusing to test a different commit"
        fi
        say "Image revision ${revision} matches the commit under test."
    fi

    # The label option is for SELinux hosts; Ubuntu runners have no SELinux and
    # podman rejects an explicitly requested label there.
    local selinux=()
    if [[ -e /sys/fs/selinux/enforce ]]; then
        selinux=(--security-opt label=type:unconfined_t)
    fi

    mkdir -p "${WORKDIR}/output"
    local disk="${WORKDIR}/output/disk.raw"
    rm -f "${disk}"
    truncate -s 20G "${disk}"

    # bootc's own installer writes the image to a disk in a couple of minutes,
    # where bootc-image-builder assembles the same disk for the better part of
    # an hour. SELinux stays as users get it: the installer labels the tree
    # from the image's own policy, which needs no SELinux on the host, while
    # disabling SELinux at install time would add selinux=0 and boot a system
    # nobody runs.
    say "Installing ${IMAGE} to ${disk} with bootc install to-disk"
    phase "installing the image with bootc install to-disk"
    if ! timeout 1800 "${SUDO[@]}" podman run --rm --privileged --pid=host --ipc=host \
        --pull=never "${selinux[@]}" \
        -v /dev:/dev \
        -v "${WORKDIR}/output:/output" \
        -v /var/lib/containers:/var/lib/containers \
        "${IMAGE}" bootc install to-disk --via-loopback --filesystem btrfs \
        --karg=console=tty0 --karg=console=ttyS0,115200n8 \
        --skip-fetch-check /output/disk.raw \
        > "${WORKDIR}/install.log" 2>&1; then
        annotate_log "bootc install" "${WORKDIR}/install.log"
        die "bootc install failed, see ${WORKDIR}/install.log"
    fi
    "${SUDO[@]}" chown -R "$(id -u):$(id -g)" "${WORKDIR}/output"
    [[ -s ${disk} ]] || die "bootc install produced no disk at ${disk}"
    phase "installed the disk"

    install_guest_checks "${disk}"
    DISK="${disk}"
}

# Find the ostree deployment on the fresh disk. bootc writes a *physical* root:
# the root partition holds only boot/ and ostree/, and the system's /etc is the
# deployment's, ostree/deploy/<stateroot>/deploy/<checksum>.<serial>/etc. That
# directory is bind-mounted as /etc at boot, so a file written there before the
# first boot is part of the running system.
ROOT_MOUNT=""
ROOT_LOOP=""
DEPLOYMENT=""

find_deployment() {
    local root="$1"
    # shellcheck disable=SC2016  # expanded by the inner shell, which runs as root
    "${SUDO[@]}" bash -c '
        shopt -s nullglob
        for etc in "$1"/ostree/deploy/*/deploy/*/etc "$1"/*/ostree/deploy/*/deploy/*/etc; do
            [[ -d ${etc} ]] && printf "%s\n" "${etc%/etc}"
        done
    ' _ "${root}"
}

mount_deployment() {
    local disk="$1" part fstype layout last_err="none" deployments=() found=""
    ROOT_MOUNT="$(mktemp -d)"
    ROOT_LOOP="$("${SUDO[@]}" losetup --find --show --partscan "${disk}")"
    "${SUDO[@]}" partprobe "${ROOT_LOOP}" 2> /dev/null || true
    "${SUDO[@]}" udevadm settle 2> /dev/null || true
    for _ in $(seq 1 10); do
        compgen -G "${ROOT_LOOP}p*" > /dev/null && break
        sleep 1
    done
    layout="$("${SUDO[@]}" lsblk -rno NAME,FSTYPE,SIZE "${ROOT_LOOP}" 2> /dev/null | tr '\n' ' ')"
    phase "disk partitions: ${layout:-none}"

    # `-t auto` has mount(8) probe the superblock itself; lsblk's FSTYPE comes
    # from udev, which has not always seen a fresh loop device yet. The explicit
    # types are the fallback for a mount(8) that cannot probe. The ESP mounts
    # too, but holds no deployment, so it is skipped.
    for part in "${ROOT_LOOP}"p*; do
        [[ -b ${part} ]] || continue
        for fstype in auto btrfs xfs ext4; do
            if last_err="$("${SUDO[@]}" mount -t "${fstype}" "${part}" "${ROOT_MOUNT}" 2>&1)"; then
                mapfile -t deployments < <(find_deployment "${ROOT_MOUNT}")
                if [[ ${#deployments[@]} -gt 0 ]]; then
                    found="${part}"
                    break 2
                fi
                last_err="$(basename "${part}") mounted but holds no ostree deployment"
                "${SUDO[@]}" umount "${ROOT_MOUNT}"
                break
            fi
        done
    done
    if [[ -z ${found} ]]; then
        "${SUDO[@]}" losetup -d "${ROOT_LOOP}" || true
        die "found no ostree deployment on the disk (partitions: ${layout:-none}; last error: ${last_err})"
    fi
    if [[ ${#deployments[@]} -ne 1 ]]; then
        umount_deployment
        die "expected one ostree deployment on a fresh disk, found ${#deployments[@]}: ${deployments[*]}"
    fi
    DEPLOYMENT="${deployments[0]}"
    say "Deployment: ${DEPLOYMENT#"${ROOT_MOUNT}"/} on $(basename "${found}")"
}

umount_deployment() {
    sync
    "${SUDO[@]}" umount "${ROOT_MOUNT}" || true
    "${SUDO[@]}" losetup -d "${ROOT_LOOP}" || true
    rmdir "${ROOT_MOUNT}" 2> /dev/null || true
    ROOT_MOUNT=""
    DEPLOYMENT=""
}

# Give a file the SELinux label of a file the image shipped, so an enforcing
# guest treats it like its neighbours. The host needs no SELinux for this:
# security.selinux is an ordinary extended attribute on disk.
copy_label() {
    local reference="$1" target="$2"
    "${SUDO[@]}" python3 - "${reference}" "${target}" << 'PY'
import os
import sys

reference, target = sys.argv[1], sys.argv[2]
try:
    label = os.getxattr(reference, "security.selinux", follow_symlinks=False)
except OSError:
    raise SystemExit(0)  # an unlabelled tree: nothing to match
os.setxattr(target, "security.selinux", label, follow_symlinks=False)
PY
}

image_hash() {
    local path="${REPO_ROOT}/system_files/${1#/}"
    [[ -f ${path} ]] || die "the repository does not contain ${path}"
    sha256sum "${path}" | cut -d' ' -f1
}

# Write the in-guest checks into a deployment: a oneshot unit, started after the
# display manager, that waits for the greeter, tells the host to take the
# screenshot, runs scripts/boot-gate-checks.sh and writes its report to the
# gate's virtio-serial port. The host stops the machine once it has both, so
# nothing on the guest has to time a shutdown, and nothing depends on sshd,
# which this image does not enable.
write_guest_checks() {
    local deployment="$1" etc="$1/etc" dir unit wants
    local logo light banner hook
    logo="$(image_hash /usr/share/pixmaps/distr0-gdm-logo.png)"
    light="$(image_hash /usr/share/backgrounds/distr0/distr0-wallpaper-light.png)"
    banner="$(image_hash /usr/share/distr0/banner.sh)"
    hook="$(image_hash /etc/profile.d/zz-distr0-banner.sh)"

    dir="${etc}${GATE_DIR#/etc}"
    unit="${etc}/systemd/system/${GATE_UNIT}"
    wants="${etc}/systemd/system/graphical.target.wants"
    [[ -d ${etc}/systemd/system ]] || die "the deployment at ${deployment} has no /etc/systemd/system"

    "${SUDO[@]}" install -d -m 0755 "${dir}" "${wants}"
    "${SUDO[@]}" install -m 0755 "${REPO_ROOT}/scripts/boot-gate-checks.sh" "${dir}/checks.sh"
    "${SUDO[@]}" tee "${dir}/run.sh" > /dev/null << EOF
#!/usr/bin/bash
# Written by scripts/boot-gate.sh for one boot gate run; not part of the image.

# The port's device node is /dev/vportNpM; /sys says which one is ours, so this
# does not depend on the udev rule that adds /dev/virtio-ports/ symlinks.
port=""
for _ in \$(seq 1 60); do
    for name in /sys/class/virtio-ports/*/name; do
        if [[ -r \${name} && "\$(cat "\${name}")" == ${GATE_PORT} ]]; then
            port="/dev/\$(basename "\$(dirname "\${name}")")"
        fi
    done
    [[ -n \${port} && -w \${port} ]] && break
    sleep 1
done
exec > "\${port:-/dev/ttyS0}" 2>&1

echo "DISTR0-BOOT-GATE-BEGIN"
greeter_up() {
    local id
    pgrep -x gnome-shell > /dev/null || return 1
    for id in \$(loginctl list-sessions --no-legend 2> /dev/null | awk '{print \$1}'); do
        [[ "\$(loginctl show-session "\${id}" -p Class --value 2> /dev/null)" == greeter ]] && return 0
    done
    return 1
}
state=timeout
for _ in \$(seq 1 300); do
    if greeter_up; then
        state=up
        break
    fi
    sleep 1
done
# The host takes the screenshot once it reads this line.
echo "DISTR0-BOOT-GATE-GREETER \${state}"

export EXPECT_GDM_LOGO_SHA256=${logo}
export EXPECT_LIGHT_WALLPAPER_SHA256=${light}
export EXPECT_BANNER_SHA256=${banner}
export EXPECT_BANNER_HOOK_SHA256=${hook}
bash ${GATE_DIR}/checks.sh
echo "EXIT=\$?"
echo "DISTR0-BOOT-GATE-END"
EOF
    "${SUDO[@]}" chmod 0755 "${dir}/run.sh"
    "${SUDO[@]}" tee "${unit}" > /dev/null << EOF
[Unit]
Description=DISTR0 boot gate checks
After=display-manager.service systemd-user-sessions.service

[Service]
Type=oneshot
ExecStart=/usr/bin/bash ${GATE_DIR}/run.sh
TimeoutStartSec=900

[Install]
WantedBy=graphical.target
EOF
    "${SUDO[@]}" ln -sfn "../${GATE_UNIT}" "${wants}/${GATE_UNIT}"

    # The labels of what the image itself ships next to these files.
    copy_label "${etc}/profile.d" "${dir}"
    copy_label "${etc}/profile.d/zz-distr0-banner.sh" "${dir}/run.sh"
    copy_label "${etc}/profile.d/zz-distr0-banner.sh" "${dir}/checks.sh"
    copy_label "$(find_reference "${etc}/systemd/system" -maxdepth 1 -type f)" "${unit}"
    copy_label "$(find_reference "${etc}/systemd/system" -mindepth 2 -maxdepth 2 -type l)" \
        "${wants}/${GATE_UNIT}"

    show_login_screen "${etc}"
}

# The installer leaves user creation to gnome-initial-setup, so on a disk with
# no account GDM runs the first-boot assistant instead of the login screen. Every
# later boot shows the login screen, which is what the wordmark promise is about
# and what the gate photographs: switch the assistant off on this disk only. The
# file is rewritten in place, so it keeps the SELinux label the image gave it.
show_login_screen() {
    local etc="$1" conf="$1/gdm/custom.conf" content=""
    if "${SUDO[@]}" test -f "${conf}"; then
        content="$("${SUDO[@]}" cat "${conf}")"
    else
        "${SUDO[@]}" install -d -m 0755 "${etc}/gdm"
        "${SUDO[@]}" touch "${conf}"
        copy_label "${etc}/gdm" "${conf}"
    fi
    if grep -q '^InitialSetupEnable=' <<< "${content}"; then
        # shellcheck disable=SC2001  # a per-line anchor, which ${//} cannot express
        content="$(sed 's/^InitialSetupEnable=.*/InitialSetupEnable=False/' <<< "${content}")"
    elif grep -q '^\[daemon\]' <<< "${content}"; then
        content="$(sed '/^\[daemon\]/a InitialSetupEnable=False' <<< "${content}")"
    else
        content="$(printf '%s\n[daemon]\nInitialSetupEnable=False' "${content}")"
    fi
    printf '%s\n' "${content}" | "${SUDO[@]}" tee "${conf}" > /dev/null
}

# A file of the given kind that the image ships under DIR carries the label such
# a file must have there; DIR's own label is the fallback.
find_reference() {
    local dir="$1" reference
    shift
    reference="$("${SUDO[@]}" find "${dir}" "$@" ! -name "${GATE_UNIT}" -print -quit 2> /dev/null || true)"
    printf '%s\n' "${reference:-${dir}}"
}

install_guest_checks() {
    mount_deployment "$1"
    write_guest_checks "${DEPLOYMENT}"
    umount_deployment
    phase "installed the in-guest checks"
}

# --- Booting ----------------------------------------------------------------

# qcow2 files start with "QFI\xfb"; anything else is a raw disk.
disk_format() {
    if [[ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" == "514649fb" ]]; then
        printf 'qcow2\n'
    else
        printf 'raw\n'
    fi
}

boot_vm() {
    need qemu-system-x86_64

    local cpu=max code="" vars="" pflash=() format base
    format="$(disk_format "${DISK}")"
    ACCEL=tcg
    if [[ -w /dev/kvm ]]; then
        ACCEL=kvm
        cpu=host
    elif [[ -n ${REQUIRE_KVM} ]]; then
        # A GNOME desktop under TCG needs far longer than the boot budget, so a
        # gate that cannot accelerate is a gate that will fail slowly.
        die "KVM is not available (/dev/kvm is not writable): enable it or run the gate on a machine that has it"
    fi

    # A bootc disk is UEFI-first. OVMF's code is read-only and its variable
    # store is copied per run, so two gates never share NVRAM.
    for base in /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd; do
        if [[ -f ${base} ]]; then
            code=${base}
            vars=${base/CODE/VARS}
            break
        fi
    done
    if [[ -n ${code} && -f ${vars:-} ]]; then
        cp "${vars}" "${WORKDIR}/OVMF_VARS.fd"
        pflash=(-drive "if=pflash,format=raw,readonly=on,file=${code}"
            -drive "if=pflash,format=raw,file=${WORKDIR}/OVMF_VARS.fd")
    else
        say "No OVMF firmware found: booting with QEMU's default firmware."
    fi

    : > "${WORKDIR}/guest-report.log"
    : > "${WORKDIR}/console.log"

    # -vga std is the one display device QEMU can always screenshot through QMP;
    # GNOME falls back to llvmpipe, which is all a login screen needs.
    #
    # Kept in the foreground of a background job rather than -daemonize: when it
    # dies, wait gives the exit status (137 is the OOM killer) and qemu.log has
    # the reason, which is what the gate has to report.
    qemu-system-x86_64 \
        -machine "q35,accel=${ACCEL}" \
        -cpu "${cpu}" \
        -m 4096 -smp 2 \
        -drive "file=${DISK},if=virtio,format=${format}" \
        "${pflash[@]}" \
        -vga std \
        -display none \
        -nic "user,model=virtio-net-pci" \
        -device virtio-serial-pci,id=gate-serial \
        -chardev "file,id=gate,path=${WORKDIR}/guest-report.log" \
        -device "virtserialport,bus=gate-serial.0,chardev=gate,name=${GATE_PORT}" \
        -qmp "unix:${WORKDIR}/qmp.sock,server=on,wait=off" \
        -serial "file:${WORKDIR}/console.log" \
        > "${WORKDIR}/qemu.log" 2>&1 &

    QEMU_PID=$!
    say "Booting ${DISK} (${format}, ${ACCEL})"
    phase "booting the disk (${ACCEL})"
}

guest_down() {
    local status line
    set +e
    wait "${QEMU_PID}" 2> /dev/null
    status=$?
    set -e
    printf 'FAIL  QEMU exited early with status %s\n' "${status}"
    annotate_log qemu "${WORKDIR}/qemu.log"
    tail -n 8 "${WORKDIR}/console.log" 2> /dev/null | tr -d '\r' | while IFS= read -r line; do
        [[ -n ${line} ]] && printf 'FAIL  guest console: %s\n' "${line}"
    done
    return 0
}

screendump() {
    python3 - "${WORKDIR}/qmp.sock" "${WORKDIR}/login-screen.ppm" << 'PY'
import json
import socket
import sys

sock_path, out = sys.argv[1], sys.argv[2]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(30)
sock.connect(sock_path)
stream = sock.makefile("rwb")


def read_message():
    while True:
        line = stream.readline()
        if not line:
            raise SystemExit("QEMU closed the QMP socket")
        message = json.loads(line)
        if "event" not in message:
            return message


read_message()  # the QMP greeting
for command in (
    {"execute": "qmp_capabilities"},
    {"execute": "screendump", "arguments": {"filename": out}},
):
    stream.write((json.dumps(command) + "\n").encode())
    stream.flush()
    response = read_message()
    if "error" in response:
        raise SystemExit(str(response["error"]))
PY
}

analyse_screen() {
    python3 "${REPO_ROOT}/scripts/screen-stats.py" "${WORKDIR}/login-screen.ppm" \
        --png "${WORKDIR}/login-screen.png"
}

# The report as the guest wrote it: on the gate's port, or on the serial console
# when the port never appeared in the guest.
report_text() {
    local source
    for source in "${WORKDIR}/guest-report.log" "${WORKDIR}/console.log"; do
        if tr -d '\r' < "${source}" 2> /dev/null | grep -q '^DISTR0-BOOT-GATE-BEGIN$'; then
            tr -d '\r' < "${source}"
            return 0
        fi
    done
    return 1
}

report_has() {
    report_text | grep -q "$1"
}

# Wait for the guest: the greeter marker starts the screenshot attempts, the end
# marker closes the report. One deadline bounds the whole boot, and a QEMU that
# dies ends the wait at once instead of at the deadline.
PAINTED=0
wait_for_guest() {
    local timeout=${BOOT_TIMEOUT_KVM} deadline paint_deadline=0 paint_start=0 greeter=0 finished=0
    local detail="the guest never reported the greeter" started=${SECONDS}
    [[ ${ACCEL} == kvm ]] || timeout=${BOOT_TIMEOUT_TCG}
    deadline=$((SECONDS + timeout))

    while ((SECONDS < deadline)); do
        if ! qemu_running; then
            guest_down
            return 1
        fi
        if ((greeter == 0)) && report_has '^DISTR0-BOOT-GATE-GREETER'; then
            greeter=1
            paint_start=$((SECONDS + PAINT_SETTLE))
            paint_deadline=$((SECONDS + PAINT_TIMEOUT))
            detail="no screenshot yet"
            phase "the guest reported the greeter after $((SECONDS - started))s"
        fi
        if ((greeter == 1 && PAINTED == 0 && SECONDS >= paint_start && SECONDS < paint_deadline)); then
            if screendump > "${WORKDIR}/qmp.log" 2>&1 && detail="$(analyse_screen 2>&1)"; then
                PAINTED=1
                say "ok    the login screen painted (${detail})"
                phase "the login screen painted"
            fi
        fi
        if ((finished == 0)) && report_has '^DISTR0-BOOT-GATE-END$'; then
            finished=1
            phase "the guest finished its checks after $((SECONDS - started))s"
        fi
        if ((finished == 1 && (PAINTED == 1 || SECONDS >= paint_deadline))); then
            break
        fi
        sleep 5
    done

    if ((PAINTED == 0)); then
        # Keep whatever the screen shows: it is the clue to why it never painted.
        if screendump > "${WORKDIR}/qmp.log" 2>&1; then
            detail="$(analyse_screen 2>&1 || true)"
        fi
        say "FAIL  the login screen never painted a recognisable desktop (${detail})"
    fi
    if ((finished == 0)); then
        phase "the guest did not finish its checks within ${timeout}s"
        say "FAIL  the guest did not finish the in-guest checks within ${timeout}s"
        annotate_log "guest console" "${WORKDIR}/console.log"
    fi
    stop_vm
    ((finished == 1))
}

# The report is the text between the markers on the gate's port; a missing
# report is itself a failure, and the tail of the console says why.
read_guest_log() {
    local log="${WORKDIR}/guest-checks.log"
    { report_text || true; } \
        | sed -n '/^DISTR0-BOOT-GATE-BEGIN$/,/^DISTR0-BOOT-GATE-END$/p' > "${log}"
    if ! grep -q '^DISTR0-BOOT-GATE-BEGIN$' "${log}" 2> /dev/null; then
        say "FAIL  the guest left no check report on the ${GATE_PORT} port"
        return 1
    fi
    grep -v '^DISTR0-BOOT-GATE-' "${log}" || true
    grep -q '^EXIT=0$' "${log}"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image)
                IMAGE="${2:?--image needs a value}"
                shift 2
                ;;
            --disk)
                DISK="${2:?--disk needs a value}"
                shift 2
                ;;
            --expect-revision)
                EXPECT_REVISION="${2:?--expect-revision needs a value}"
                shift 2
                ;;
            --workdir)
                WORKDIR="${2:?--workdir needs a value}"
                shift 2
                ;;
            --require-kvm)
                REQUIRE_KVM=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                printf 'unknown argument: %s\n' "$1" >&2
                usage >&2
                exit 2
                ;;
        esac
    done

    [[ -n ${IMAGE} || -n ${DISK} ]] || die "one of --image or --disk is required"
    [[ -z ${IMAGE} || -z ${DISK} ]] || die "use --image or --disk, not both"
    [[ -z ${EXPECT_REVISION} || -n ${IMAGE} ]] || die "--expect-revision only applies to --image"

    WORKDIR="${WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/distr0-boot-gate.XXXXXX")}"
    mkdir -p "${WORKDIR}"
    WORKDIR="$(cd "${WORKDIR}" && pwd)"

    if [[ ${EUID} -ne 0 ]]; then
        command -v sudo > /dev/null 2>&1 || die "sudo is required to install the disk"
        SUDO=(sudo)
    fi

    need python3

    say "Workdir: ${WORKDIR}"
    say ""

    trap stop_vm EXIT

    if [[ -n ${IMAGE} ]]; then
        build_disk
    fi
    [[ -f ${DISK} ]] || die "no disk image at ${DISK}"

    boot_vm

    local guest_ok=0 checks_ok=0
    wait_for_guest && guest_ok=1
    read_guest_log && checks_ok=1

    say ""
    if ((PAINTED == 1 && guest_ok == 1 && checks_ok == 1)); then
        say "boot gate passed: the image booted, reached the login screen, and serves the files this commit ships."
        return 0
    fi
    say "boot gate failed; the log, the report and the screenshot are in ${WORKDIR}"
    return 1
}

# Sourcing the script gives the functions without running the gate, which is
# how the repository's tests and a manual debugging session reuse them.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
