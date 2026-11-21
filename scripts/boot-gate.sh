#!/usr/bin/env bash
# Boot an image in QEMU and check what only a booted system can prove.
#
# The container build and the shipped self-test run without systemd, so neither
# can show that GDM reaches a login screen or that the desktop reads the files
# this repository ships. This script builds a disk image with
# bootc-image-builder, boots it, takes a screenshot of the framebuffer through
# QMP, and runs scripts/boot-gate-checks.sh inside the guest over SSH.
#
# Usage:
#   scripts/boot-gate.sh --image ghcr.io/progliodario/distr0:latest \
#       --expect-revision "$(git rev-parse HEAD)"
#   scripts/boot-gate.sh --qcow2 output/qcow2/disk.qcow2
#
# The first form is what `.github/workflows/boot-gate.yml` runs: it pulls the
# published image, refuses one whose OCI revision label is not the commit under
# test, and builds the disk with the same pinned bootc-image-builder the disk
# workflow uses. Needs podman with sudo for that, plus qemu, ssh and python3.
# KVM turns the boot into a couple of minutes; without it QEMU emulates, which
# works but is slow.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The same pin as Justfile and build-disk.yml; scripts/validate.py fails when
# the three drift apart.
DEFAULT_BIB_IMAGE="quay.io/centos-bootc/bootc-image-builder@sha256:dab86ee6b46dcade411b37f4e70b07d93b6a06da0dbfec6fe89247a220e0d9f8"
BIB_IMAGE="${BIB_IMAGE:-${DEFAULT_BIB_IMAGE}}"
SSH_USER="gate"
BOOT_TIMEOUT=900
LOGIN_TIMEOUT=420
PAINT_TIMEOUT=180

IMAGE=""
QCOW2=""
WORKDIR=""
EXPECT_REVISION=""
REQUIRE_KVM=""
SSH_PORT=""
QEMU_PID=""
SSH_OPTS=(
    -o BatchMode=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=5
    -o ServerAliveInterval=15
)
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

  --image REF            registry image to pull and turn into a qcow2
  --qcow2 FILE           boot an existing disk image instead
  --expect-revision SHA  refuse an image whose OCI revision label is not SHA
  --workdir DIR          keep the log and the screenshot here (default: mktemp)
  --timeout SECONDS      how long to wait for the guest to accept SSH
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
        --qcow2)
            QCOW2="${2:?--qcow2 needs a value}"
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
        --timeout)
            BOOT_TIMEOUT="${2:?--timeout needs a value}"
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

[[ -n ${IMAGE} || -n ${QCOW2} ]] || die "one of --image or --qcow2 is required"
[[ -z ${IMAGE} || -z ${QCOW2} ]] || die "use --image or --qcow2, not both"
[[ -z ${EXPECT_REVISION} || -n ${IMAGE} ]] || die "--expect-revision only applies to --image"

WORKDIR="${WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/distr0-boot-gate.XXXXXX")}"
mkdir -p "${WORKDIR}"

if [[ ${EUID} -ne 0 ]]; then
    command -v sudo > /dev/null 2>&1 || die "sudo is required to build the qcow2"
    SUDO=(sudo)
fi

need ssh
need ssh-keygen
need python3

ssh-keygen -q -t ed25519 -N '' -C "distr0-boot-gate" -f "${WORKDIR}/id_ed25519"

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

build_qcow2() {
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

    local config="${WORKDIR}/boot-gate.toml"
    local public_key
    public_key="$(cat "${WORKDIR}/id_ed25519.pub")"
    sed "s|__DISTR0_BOOT_GATE_SSH_KEY__|${public_key}|" \
        "${REPO_ROOT}/disk_config/boot-gate.toml" > "${config}"
    if grep -q '__DISTR0_BOOT_GATE_SSH_KEY__' "${config}"; then
        die "the generated disk config still contains the SSH key placeholder"
    fi

    say "Pulling ${IMAGE}"
    if ! pull_image "${IMAGE}" "${WORKDIR}/pull.log"; then
        annotate_log "podman pull" "${WORKDIR}/pull.log"
        die "could not pull ${IMAGE}"
    fi
    phase "pulled ${IMAGE}"

    say "Pulling bootc-image-builder"
    if ! pull_image "${BIB_IMAGE}" "${WORKDIR}/bib-pull.log"; then
        annotate_log "bootc-image-builder pull" "${WORKDIR}/bib-pull.log"
        die "could not pull ${BIB_IMAGE}"
    fi
    phase "pulled bootc-image-builder"

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

    # podman does not create a missing bind-mount source for a rootful
    # container, and bootc-image-builder reports the missing /output as a
    # statfs error that says nothing about the real cause.
    mkdir -p "${WORKDIR}/output"

    say "Building the qcow2 with bootc-image-builder (this takes a few minutes)"
    phase "building the qcow2 with bootc-image-builder"
    # BIB assembles a full disk image; an unbounded run would hit the job
    # timeout and report nothing. 45 minutes is generous for a shared runner.
    if ! timeout 2700 "${SUDO[@]}" podman run --rm --privileged --pull=missing --net=host \
        "${selinux[@]}" \
        -v "${config}:/config.toml:ro" \
        -v "${WORKDIR}/output:/output" \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        "${BIB_IMAGE}" \
        --type qcow2 --config /config.toml \
        --use-librepo=True --rootfs=btrfs "${IMAGE}" \
        > "${WORKDIR}/bib.log" 2>&1; then
        annotate_log "bootc-image-builder" "${WORKDIR}/bib.log"
        die "bootc-image-builder failed, see ${WORKDIR}/bib.log"
    fi
    "${SUDO[@]}" chown -R "$(id -u):$(id -g)" "${WORKDIR}/output"
    phase "built the qcow2"

    QCOW2="${WORKDIR}/output/qcow2/disk.qcow2"
    [[ -f ${QCOW2} ]] || die "bootc-image-builder produced no qcow2 at ${QCOW2}"
}

boot_vm() {
    need qemu-system-x86_64

    local accel=tcg cpu=max port code="" vars="" pflash=()
    if [[ -w /dev/kvm ]]; then
        accel=kvm
        cpu=host
    elif [[ -n ${REQUIRE_KVM} ]]; then
        # A GNOME desktop under TCG needs far longer than the boot budget, so a
        # gate that cannot accelerate is a gate that will fail slowly.
        die "KVM is not available (/dev/kvm is not writable): enable it or run the gate on a machine that has it"
    fi

    port="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

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
        -drive "file=${QCOW2},if=virtio,format=qcow2" \
        "${pflash[@]}" \
        -vga std \
        -display none \
        -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${port}-:22" \
        -qmp "unix:${WORKDIR}/qmp.sock,server=on,wait=off" \
        -serial "file:${WORKDIR}/console.log" \
        > "${WORKDIR}/qemu.log" 2>&1 &

    QEMU_PID=$!
    SSH_PORT=${port}
    say "Booting ${QCOW2} (${accel}) with SSH on 127.0.0.1:${port}"
    phase "booting the disk (${accel})"
}

# ConnectTimeout only covers the TCP connect: if the forwarded port accepts and
# then says nothing, ssh waits for the banner forever. Every call is bounded so
# a wait loop always reaches its deadline and can report why.
ssh_run() {
    local limit="$1"
    shift
    timeout "${limit}" ssh "${SSH_OPTS[@]}" -p "${SSH_PORT}" -i "${WORKDIR}/id_ed25519" \
        "${SSH_USER}@127.0.0.1" "$@"
}

ssh_do() { ssh_run 600 "$@"; }

ssh_probe() { ssh_run 20 "$@"; }

guest_down() {
    local status=unknown line
    if [[ -n ${QEMU_PID} ]]; then
        set +e
        wait "${QEMU_PID}" 2> /dev/null
        status=$?
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

wait_for_ssh() {
    # Two progress notices keep the step under GitHub's ten-notices budget while
    # still showing a stuck boot on the run page.
    local start=$SECONDS
    local deadline=$((start + BOOT_TIMEOUT)) next_report=240 detail
    while ((SECONDS < deadline)); do
        if ssh_probe true > /dev/null 2>&1; then
            say "The guest accepted SSH."
            phase "the guest accepted SSH (T+$((SECONDS - start))s)"
            return 0
        fi
        if ! qemu_running; then
            guest_down
            die "QEMU exited before the system came up"
        fi
        # A boot that never answers is otherwise indistinguishable from a slow
        # runner; the framebuffer says whether the system got anywhere.
        if ((SECONDS - start >= next_report)); then
            detail="unavailable"
            if screendump > /dev/null 2>&1; then
                detail="$(analyse_screen 2>&1)" || detail="not painted (${detail})"
            fi
            phase "T+$((SECONDS - start))s: no SSH yet (framebuffer: ${detail})"
            next_report=$((next_report + 360))
        fi
        sleep 5
    done
    # Did it boot and only fail to answer SSH? The display says so even when the
    # console log stopped at the kernel handover.
    printf 'FAIL  framebuffer: %s\n' \
        "$(screendump > /dev/null 2>&1 && analyse_screen 2>&1 || echo 'no screenshot')"
    guest_down
    die "the guest did not accept SSH within ${BOOT_TIMEOUT}s"
}

wait_for_login() {
    local deadline=$((SECONDS + LOGIN_TIMEOUT))
    while ((SECONDS < deadline)); do
        if ssh_probe 'systemctl is-active --quiet gdm.service && pgrep -u gdm -x gnome-shell > /dev/null' \
            > /dev/null 2>&1; then
            say "GDM is running the greeter."
            phase "GDM is running the greeter"
            return 0
        fi
        if ! qemu_running; then
            guest_down
            die "QEMU exited before the login screen"
        fi
        sleep 5
    done
    # The job log may be unreadable, so the reason travels as annotations.
    ssh_do 'systemctl status gdm.service --no-pager | tail -n 5' 2>&1 | while IFS= read -r line; do
        [[ -n ${line} ]] && printf 'FAIL  gdm: %s\n' "${line}"
    done
    ssh_do 'journalctl -u gdm.service --no-pager -n 5' 2>&1 | while IFS= read -r line; do
        [[ -n ${line} ]] && printf 'FAIL  gdm journal: %s\n' "${line}"
    done
    die "GDM did not reach the login screen within ${LOGIN_TIMEOUT}s"
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

run_guest_checks() {
    local logo light banner hook
    logo="$(image_hash /usr/share/pixmaps/distr0-gdm-logo.png)"
    light="$(image_hash /usr/share/backgrounds/distr0/distr0-wallpaper-light.png)"
    banner="$(image_hash /usr/share/distr0/banner.sh)"
    hook="$(image_hash /etc/profile.d/zz-distr0-banner.sh)"

    ssh_do "EXPECT_GDM_LOGO_SHA256=${logo} \
EXPECT_LIGHT_WALLPAPER_SHA256=${light} \
EXPECT_BANNER_SHA256=${banner} \
EXPECT_BANNER_HOOK_SHA256=${hook} \
bash -s" < "${REPO_ROOT}/scripts/boot-gate-checks.sh"
}

if [[ -n ${IMAGE} ]]; then
    build_qcow2
fi

[[ -f ${QCOW2} ]] || die "no disk image at ${QCOW2}"

boot_vm
wait_for_ssh
wait_for_login

paint_failures=0
wait_for_paint || paint_failures=1

set +e
run_guest_checks
guest_failures=$?
set -e

if ((guest_failures == 255)); then
    say "FAIL  the guest stopped answering SSH while the checks were running"
fi

failures=$((paint_failures + guest_failures))
say ""
if ((failures > 0)); then
    say "boot gate failed: ${failures} check(s) failed; log and screenshot in ${WORKDIR}"
    exit 1
fi
say "boot gate passed: the image booted, reached the login screen, and serves the files this commit ships."
