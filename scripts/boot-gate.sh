#!/usr/bin/env bash
# Boot an image in QEMU and check what only a booted system can prove.
#
# The container build and the shipped self-test run without systemd, so neither
# can show that GDM reaches a login screen or that the desktop reads the files
# this repository ships. This script installs the image to a raw disk with the
# image's own installer, boots it, takes a screenshot of the framebuffer through
# QMP, and runs scripts/boot-gate-checks.sh inside the guest at boot.
#
# Usage:
#   scripts/boot-gate.sh --image ghcr.io/progliodario/distr0:latest \
#       --expect-revision "$(git rev-parse HEAD)"
#   scripts/boot-gate.sh --disk output/disk.raw
#
# The first form is what `.github/workflows/boot-gate.yml` runs: it pulls the
# published image, refuses one whose OCI revision label is not the commit under
# test, and installs the image to a raw disk with the image's own installer.
# Needs podman with sudo for that, plus qemu and python3.
# KVM turns the boot into a couple of minutes; without it QEMU emulates, which
# works but is slow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PAINT_TIMEOUT=300
POWEROFF_TIMEOUT=600

IMAGE=""
DISK=""
WORKDIR=""
EXPECT_REVISION=""
REQUIRE_KVM=""
QEMU_PID=""
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
    cat <<'EOF'
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

if [[ ${EUID} -ne 0 ]]; then
    command -v sudo > /dev/null 2>&1 || die "sudo is required to install the disk"
    SUDO=(sudo)
fi

need python3

say "Workdir: ${WORKDIR}"
say ""

stop_vm() {
    if [[ -n ${QEMU_PID} ]] && kill -0 "${QEMU_PID}" 2> /dev/null; then
        kill "${QEMU_PID}" 2> /dev/null || true
        for _ in $(seq 1 10); do
            kill -0 "${QEMU_PID}" 2> /dev/null || break
            sleep 1
        done
        kill -9 "${QEMU_PID}" 2> /dev/null || true
    fi
}

qemu_running() {
    [[ -n ${QEMU_PID} ]] && kill -0 "${QEMU_PID}" 2> /dev/null
}

trap stop_vm EXIT

build_disk() {
    need podman

    # The annotations are how this failure becomes readable: the job log needs
    # permissions the repository's own automation may not have.
    annotate_log() {
        local prefix="$1" log="$2" line
        tail -n 20 "${log}" | while IFS= read -r line; do
            [[ -n ${line} ]] && printf 'FAIL  %s: %s\n' "${prefix}" "${line}"
        done
        return 0
    }

    # Registry hiccups are common enough on shared runners that a single pull
    # attempt should not decide whether the image gets booted, and the retry
    # output is what a failed annotation shows.
    # A stalled connection hangs podman pull forever, which no retry would
    # reach; timeout makes a hung attempt a failed attempt.
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
    truncate -s 20G "${disk}"

    # bootc's own installer writes the image to a disk in a couple of minutes,
    # where bootc-image-builder assembles the same disk for the better part of
    # an hour. The checks are installed on the disk and run at boot.
    say "Installing ${IMAGE} to ${disk} with bootc install to-disk"
    phase "installing the image with bootc install to-disk"
    if ! timeout 1800 "${SUDO[@]}" podman run --rm --privileged --pid=host --ipc=host \
        --pull=missing "${selinux[@]}" \
        -v /dev:/dev \
        -v "${WORKDIR}/output:/output" \
        -v /var/lib/containers:/var/lib/containers \
        "${IMAGE}" bootc install to-disk --via-loopback --filesystem btrfs \
        --disable-selinux --karg=console=ttyS0,115200n8 \
        --skip-fetch-check /output/disk.raw \
        > "${WORKDIR}/install.log" 2>&1; then
        annotate_log "bootc install" "${WORKDIR}/install.log"
        die "bootc install failed, see ${WORKDIR}/install.log"
    fi
    "${SUDO[@]}" chown -R "$(id -u):$(id -g)" "${WORKDIR}/output"
    phase "installed the disk"

    install_guest_checks "${disk}"
    DISK="${disk}"
    [[ -s ${DISK} ]] || die "bootc install produced no disk at ${DISK}"
}

# Mount the root filesystem of the fresh disk. bootc lays it out as a btrfs
# subvolume, and composefs keeps /usr in an EROFS image rather than in the
# directory the host sees, so neither is assumed here.
ROOT_MOUNT=""
ROOT_LOOP=""

mount_installed_root() {
    local disk="$1" part fstype opts_list=() opt
    ROOT_MOUNT="$(mktemp -d)"
    ROOT_LOOP="$("${SUDO[@]}" losetup --find --show --partscan "${disk}")"
    "${SUDO[@]}" partprobe "${ROOT_LOOP}" 2> /dev/null || true
    "${SUDO[@]}" udevadm settle 2> /dev/null || true
    for part in "${ROOT_LOOP}"p*; do
        [[ -b ${part} ]] || continue
        fstype="$("${SUDO[@]}" blkid -o value -s TYPE "${part}" 2> /dev/null || true)"
        opts_list=()
        case "${fstype}" in
            # The installed root is normally the `root` subvolume; the default
            # one is the fallback when the image lays it out differently.
            btrfs) opts_list=("rw,subvol=root" "rw") ;;
            xfs | ext4) opts_list=("rw") ;;
            *) continue ;;
        esac
        for opt in "${opts_list[@]}"; do
            if "${SUDO[@]}" mount -t "${fstype}" -o "${opt}" "${part}" "${ROOT_MOUNT}" 2> /dev/null; then
                # The boot partition is ext4 too: only the root has /etc and
                # /usr, so a wrong guess is unmounted rather than used.
                if [[ -d ${ROOT_MOUNT}/etc && -d ${ROOT_MOUNT}/usr ]]; then
                    return 0
                fi
                "${SUDO[@]}" umount "${ROOT_MOUNT}"
            fi
        done
    done
    "${SUDO[@]}" losetup -d "${ROOT_LOOP}" || true
    rmdir "${ROOT_MOUNT}" 2> /dev/null || true
    ROOT_MOUNT=""
    die "could not mount the installed root (partitions: $("${SUDO[@]}" lsblk -rno NAME,FSTYPE "${ROOT_LOOP:-${disk}}" | tr '\n' ' '))"
}

umount_installed_root() {
    "${SUDO[@]}" umount "${ROOT_MOUNT}"
    "${SUDO[@]}" losetup -d "${ROOT_LOOP}" || true
    rmdir "${ROOT_MOUNT}" 2> /dev/null || true
    ROOT_MOUNT=""
}

# The checks run inside the booted system, started by a oneshot unit after the
# display manager and writing to a file on the root filesystem: SSH needs sshd
# (which this image does not enable) and the guest's own boot is the thing under
# test. One sleep gives the gate time to capture the login screen before the
# unit powers the machine off.
install_guest_checks() {
    local disk="$1" root
    local logo light banner hook
    logo="$(image_hash /usr/share/pixmaps/distr0-gdm-logo.png)"
    light="$(image_hash /usr/share/backgrounds/distr0/distr0-wallpaper-light.png)"
    banner="$(image_hash /usr/share/distr0/banner.sh)"
    hook="$(image_hash /etc/profile.d/zz-distr0-banner.sh)"

    mount_installed_root "${disk}"
    root="${ROOT_MOUNT}"
    "${SUDO[@]}" cp "${REPO_ROOT}/scripts/boot-gate-checks.sh" \
        "${root}/etc/distr0-boot-gate-checks-body.sh"
    "${SUDO[@]}" tee "${root}/etc/distr0-boot-gate-checks.sh" > /dev/null <<EOF
#!/bin/bash
exec > /distr0-boot-gate.log 2>&1
sleep 45
export EXPECT_GDM_LOGO_SHA256=${logo}
export EXPECT_LIGHT_WALLPAPER_SHA256=${light}
export EXPECT_BANNER_SHA256=${banner}
export EXPECT_BANNER_HOOK_SHA256=${hook}
bash /etc/distr0-boot-gate-checks-body.sh
echo "EXIT=\$?"
sync
poweroff -f
EOF
    "${SUDO[@]}" tee "${root}/etc/systemd/system/distr0-boot-gate-checks.service" > /dev/null <<'EOF'
[Unit]
Description=DISTR0 boot gate checks
After=display-manager.service
[Service]
Type=oneshot
ExecStart=/etc/distr0-boot-gate-checks.sh
TimeoutStartSec=300
[Install]
WantedBy=graphical.target
EOF
    "${SUDO[@]}" mkdir -p "${root}/etc/systemd/system/graphical.target.wants"
    "${SUDO[@]}" ln -sf /etc/systemd/system/distr0-boot-gate-checks.service \
        "${root}/etc/systemd/system/graphical.target.wants/distr0-boot-gate-checks.service"
    umount_installed_root
    phase "installed the in-guest checks"
}

wait_for_vm_exit() {
    local deadline=$((SECONDS + POWEROFF_TIMEOUT))
    while kill -0 "${QEMU_PID}" 2> /dev/null; do
        if ((SECONDS >= deadline)); then
            phase "the guest did not power off within ${POWEROFF_TIMEOUT}s"
            guest_down
            die "the guest did not finish the in-guest checks"
        fi
        sleep 5
    done
    wait "${QEMU_PID}" 2> /dev/null || true
}

# The log lives on the root filesystem; the machine is off, so a read-only
# mount is enough. A missing log is itself a failure.
read_guest_log() {
    local disk="$1" log="${WORKDIR}/guest-checks.log" root
    mount_installed_root "${disk}"
    root="${ROOT_MOUNT}"
    if [[ -f ${root}/distr0-boot-gate.log ]]; then
        "${SUDO[@]}" cat "${root}/distr0-boot-gate.log" > "${log}"
    fi
    umount_installed_root
    if [[ ! -f ${log} ]]; then
        say "FAIL  the guest wrote no check log (serial console:)"
        tail -n 5 "${WORKDIR}/console.log" 2> /dev/null | while IFS= read -r line; do
            [[ -n ${line} ]] && printf 'FAIL  guest console: %s\n' "${line}"
        done
        return 1
    fi
    cat "${log}"
    grep -q '^EXIT=0$' "${log}"
}

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

    local accel=tcg cpu=max code="" vars="" pflash=()
    local format
    format="$(disk_format "${DISK}")"
    if [[ -w /dev/kvm ]]; then
        accel=kvm
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

    # -vga std is the one display device QEMU can always screenshot through QMP;
    # GNOME falls back to llvmpipe, which is all a login screen needs.
    #
    # Kept in the foreground of a background job rather than -daemonize: when it
    # dies, wait gives the exit status (137 is the OOM killer) and qemu.log has
    # the reason, which is what the gate has to report.
    qemu-system-x86_64 \
        -machine "q35,accel=${accel}" \
        -cpu "${cpu}" \
        -m 4096 -smp 2 \
        -drive "file=${DISK},if=virtio,format=${format}" \
        "${pflash[@]}" \
        -vga std \
        -display none \
        -nic "user,model=virtio-net-pci" \
        -qmp "unix:${WORKDIR}/qmp.sock,server=on,wait=off" \
        -serial "file:${WORKDIR}/console.log" \
        > "${WORKDIR}/qemu.log" 2>&1 &

    QEMU_PID=$!
    say "Booting ${DISK} (${format}, ${accel})"
    phase "booting the disk (${accel})"
}

guest_down() {
    local status=unknown line
    if [[ -n ${QEMU_PID} ]]; then
        set +e
        # QEMU may still be running (the guest is just silent). Waiting on it
        # here blocked the gate until the job timeout.
        if kill -0 "${QEMU_PID}" 2> /dev/null; then
            stop_vm
            status=143
        else
            wait "${QEMU_PID}" 2> /dev/null
            status=$?
        fi
        set -e
    fi
    printf 'FAIL  QEMU exit status: %s\n' "${status}"
    tail -n 3 "${WORKDIR}/qemu.log" 2> /dev/null | while IFS= read -r line; do
        [[ -n ${line} ]] && printf 'FAIL  qemu: %s\n' "${line}"
    done
    tail -n 3 "${WORKDIR}/console.log" 2> /dev/null | while IFS= read -r line; do
        [[ -n ${line} ]] && printf 'FAIL  guest console: %s\n' "${line}"
    done
    return 0
}

screendump() {
    python3 - "${WORKDIR}/qmp.sock" "${WORKDIR}/login-screen.ppm" <<'PY'
import json
import socket
import sys

sock_path, out = sys.argv[1], sys.argv[2]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
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
    python3 "${REPO_ROOT}/scripts/screen-stats.py" "${WORKDIR}/login-screen.ppm"
}

wait_for_paint() {
    local deadline=$((SECONDS + PAINT_TIMEOUT)) detail="no screenshot yet"
    while ((SECONDS < deadline)); do
        if screendump > "${WORKDIR}/qmp.log" 2>&1 && detail="$(analyse_screen 2>&1)"; then
            say "ok    the login screen painted (${detail})"
            phase "the login screen painted"
            return 0
        fi
        sleep 5
    done
    say "FAIL  the login screen never painted a recognisable desktop (${detail})"
    return 1
}

image_hash() {
    local path="${REPO_ROOT}/system_files/${1#/}"
    [[ -f ${path} ]] || die "the repository does not contain ${path}"
    sha256sum "${path}" | cut -d' ' -f1
}

if [[ -n ${IMAGE} ]]; then
    build_disk
fi

[[ -f ${DISK} ]] || die "no disk image at ${DISK}"

boot_vm

paint_failures=0
wait_for_paint || paint_failures=1

wait_for_vm_exit

set +e
read_guest_log "${DISK}"
guest_failures=$?
set -e

failures=$((paint_failures + guest_failures))
say ""
if ((failures > 0)); then
    say "boot gate failed: ${failures} check(s) failed; log and screenshot in ${WORKDIR}"
    exit 1
fi
say "boot gate passed: the image booted, reached the login screen, and serves the files this commit ships."
