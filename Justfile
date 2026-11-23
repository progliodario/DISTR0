# Recipes run on the build host. `just --list` groups them; AGENTS.md says which
# ones a change needs (usually `just check`, `just lint`, `just test-unit`).
export image_name := env("IMAGE_NAME", "distr0")
export default_tag := env("DEFAULT_TAG", "latest")
export bib_image := env("BIB_IMAGE", "quay.io/centos-bootc/bootc-image-builder@sha256:dab86ee6b46dcade411b37f4e70b07d93b6a06da0dbfec6fe89247a220e0d9f8")

alias build-vm := build-qcow2
alias rebuild-vm := rebuild-qcow2
alias run-vm := run-vm-qcow2

[private]
default:
    @just --list

# Check that every Justfile and *.just parses and is formatted
[group('Lint')]
check:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt --check -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt --check -f Justfile

# Format every Justfile and *.just in place
[group('Lint')]
fix:
    #!/usr/bin/bash
    find . -type f -name "*.just" | while read -r file; do
    	echo "Checking syntax: $file"
    	just --unstable --fmt -f $file
    done
    echo "Checking syntax: Justfile"
    just --unstable --fmt -f Justfile || { exit 1; }

# Remove build leftovers (_build*, _chunkah_*, output/, local reports)
[group('Utility')]
clean:
    #!/usr/bin/bash
    set -eoux pipefail
    rm -rf _build* _chunkah_* output/
    rm -f sbom.spdx.json grype.json

# Sudo Clean Repo
[group('Utility')]
[private]
sudo-clean:
    just sudoif just clean

# sudoif bash function
[group('Utility')]
[private]
sudoif command *args:
    #!/usr/bin/bash
    function sudoif(){
        if [[ "${UID}" -eq 0 ]]; then
            "$@"
        elif [[ "$(command -v sudo)" && -n "${SSH_ASKPASS:-}" ]] && [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
            /usr/bin/sudo --askpass "$@" || exit 1
        elif [[ "$(command -v sudo)" ]]; then
            /usr/bin/sudo "$@" || exit 1
        else
            exit 1
        fi
    }
    sudoif {{ command }} {{ args }}

# Build the image with podman (-> localhost/distr0:latest)
[group('Build')]
build $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    # The same inputs CI passes: today's date and the commit become
    # IMAGE_VERSION and BUILD_ID in os-release, and the revision label is what
    # the boot gate checks. A dirty tree is labelled as such, so a gate run
    # against it cannot pass for a commit.
    revision="$(git rev-parse HEAD)"
    if [[ -n "$(git status --porcelain)" ]]; then
        revision="${revision}-dirty"
    fi
    podman build \
        --build-arg "DISTR0_BUILD_DATE=$(date -u +%Y%m%d)" \
        --build-arg "DISTR0_REVISION=${revision}" \
        --label "org.opencontainers.image.revision=${revision}" \
        --pull=newer \
        --tag "${target_image}:${tag}" \
        .

# Make an image available to root's podman, which bootc-image-builder and the
# boot gate use: copied from the user's storage when it is there (podman image
# scp), pulled otherwise. Nothing to do when already root.

_rootful_load_image $target_image=image_name $tag=default_tag:
    #!/usr/bin/bash
    set -eoux pipefail

    # Check if already running as root or under sudo
    if [[ -n "${SUDO_USER:-}" || "${UID}" -eq "0" ]]; then
        echo "Already root or running under sudo, no need to load image from user podman."
        exit 0
    fi

    # Try to resolve the image tag using podman inspect
    set +e
    resolved_tag=$(podman inspect -t image "${target_image}:${tag}" | jq -r '.[].RepoTags.[0]')
    return_code=$?
    set -e

    USER_IMG_ID=$(podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")

    if [[ $return_code -eq 0 ]]; then
        # If the image is found, load it into rootful podman
        ID=$(just sudoif podman images --filter reference="${target_image}:${tag}" --format "'{{ '{{.ID}}' }}'")
        if [[ "$ID" != "$USER_IMG_ID" ]]; then
            # If the image ID is not found or different from user, copy the image from user podman to root podman
            COPYTMP=$(mktemp -p "${PWD}" -d -t _build_podman_scp.XXXXXXXXXX)
            just sudoif TMPDIR=${COPYTMP} podman image scp ${UID}@localhost::"${target_image}:${tag}" root@localhost::"${target_image}:${tag}"
            rm -rf "${COPYTMP}"
        fi
    else
        # If the image is not found, pull it from the repository
        just sudoif podman pull "${target_image}:${tag}"
    fi

# Turn a container image into a disk with bootc-image-builder (pinned by digest).
# type is a builder type (qcow2, raw, anaconda-iso); config a disk_config/ file.
# Same flags as .github/workflows/build-disk.yml.
_build-bib $target_image $tag $type $config: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail

    args="--type ${type} "
    args+="--use-librepo=True "
    args+="--rootfs=btrfs"

    BUILDTMP=$(mktemp -p "${PWD}" -d -t _build-bib.XXXXXXXXXX)

    sudo podman run \
      --rm \
      -it \
      --privileged \
      --pull=newer \
      --net=host \
      --security-opt label=type:unconfined_t \
      -v $(pwd)/${config}:/config.toml:ro \
      -v $BUILDTMP:/output \
      -v /var/lib/containers/storage:/var/lib/containers/storage \
      "${bib_image}" \
      ${args} \
      "${target_image}:${tag}"

    mkdir -p output
    sudo mv -f $BUILDTMP/* output/
    sudo rmdir $BUILDTMP
    sudo chown -R $USER:$USER output/

# Build the container image, then the disk from it.
_rebuild-bib $target_image $tag $type $config: (build target_image tag) && (_build-bib target_image tag type config)

# Build a QCOW2 virtual machine image
[group('Build Virtual Machine Image')]
build-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "qcow2" "disk_config/disk.toml")

# Build a RAW virtual machine image
[group('Build Virtual Machine Image')]
build-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "raw" "disk_config/disk.toml")

# Build the installer ISO (Anaconda; installs and then switches to the signed image)
[group('Build Virtual Machine Image')]
build-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_build-bib target_image tag "anaconda-iso" "disk_config/iso.toml")

# Rebuild a QCOW2 virtual machine image
[group('Build Virtual Machine Image')]
rebuild-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "qcow2" "disk_config/disk.toml")

# Rebuild a RAW virtual machine image
[group('Build Virtual Machine Image')]
rebuild-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "raw" "disk_config/disk.toml")

# Rebuild the container image, then the installer ISO
[group('Build Virtual Machine Image')]
rebuild-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_rebuild-bib target_image tag "anaconda-iso" "disk_config/iso.toml")

# Run a virtual machine with the specified image type and configuration
_run-vm $target_image $tag $type $config:
    #!/usr/bin/bash
    set -eoux pipefail

    # Determine the image file based on the type
    image_file="output/${type}/disk.${type}"
    if [[ $type == iso ]]; then
        image_file="output/bootiso/install.iso"
    fi

    # Build the image if it does not exist
    if [[ ! -f "${image_file}" ]]; then
        just "build-${type}" "$target_image" "$tag"
    fi

    # Determine an available port to use
    port=8006
    while grep -q :${port} <<< $(ss -tunalp); do
        port=$(( port + 1 ))
    done
    echo "Using Port: ${port}"
    echo "Connect to http://localhost:${port}"

    # Set up the arguments for running the VM
    run_args=()
    run_args+=(--rm --privileged)
    run_args+=(--pull=newer)
    run_args+=(--publish "127.0.0.1:${port}:8006")
    run_args+=(--env "CPU_CORES=4")
    run_args+=(--env "RAM_SIZE=8G")
    run_args+=(--env "DISK_SIZE=64G")
    run_args+=(--env "TPM=Y")
    run_args+=(--env "GPU=Y")
    run_args+=(--device=/dev/kvm)
    run_args+=(--volume "${PWD}/${image_file}":"/boot.${type}")
    run_args+=(docker.io/qemux/qemu)

    # Run the VM and open the browser to connect
    (sleep 30 && xdg-open http://localhost:"$port") &
    podman run "${run_args[@]}"

# Run a virtual machine from a QCOW2 image
[group('Run Virtual Machine')]
run-vm-qcow2 $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "qcow2" "disk_config/disk.toml")

# Run a virtual machine from a RAW image
[group('Run Virtual Machine')]
run-vm-raw $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "raw" "disk_config/disk.toml")

# Run a virtual machine from an ISO
[group('Run Virtual Machine')]
run-vm-iso $target_image=("localhost/" + image_name) $tag=default_tag: && (_run-vm target_image tag "iso" "disk_config/iso.toml")

# Run a virtual machine using systemd-vmspawn
[group('Run Virtual Machine')]
spawn-vm rebuild="0" type="qcow2" ram="6G":
    #!/usr/bin/env bash

    set -euo pipefail

    if [[ "{{ rebuild }}" -eq 1 ]]; then
        echo "Rebuilding the {{ type }} disk"
        just "build-{{ type }}"
    fi

    systemd-vmspawn \
      -M "bootc-image" \
      --console=gui \
      --cpus=2 \
      --ram=$(echo {{ ram }}| /usr/bin/numfmt --from=iec) \
      --network-user-mode \
      --vsock=false --pass-ssh-key=false \
      -i ./output/**/*.{{ type }}

# chunkah (https://github.com/coreos/chunkah), as CI runs it on the image just built.
# Split the image into up to 128 layers so an update downloads only what changed
[group('Rechunk')]
rechunk $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -xeuo pipefail

    # chunkah is pinned by digest like every other image input: bump it on purpose
    #   skopeo inspect docker://quay.io/coreos/chunkah:latest | jq -r .Digest
    CONFIG_FILE="$(mktemp)"
    OUTPUT_DIR="$(mktemp -d "${PWD}/_chunkah_XXXXXX")"
    trap 'rm -f "${CONFIG_FILE}"; rm -rf "${OUTPUT_DIR}"' EXIT

    podman inspect "${target_image}:${tag}" > "${CONFIG_FILE}"

    podman run --rm \
        --mount=type=image,src="${target_image}:${tag}",target=/chunkah \
        -v "${CONFIG_FILE}:/chunkah-config.json:ro,Z" \
        -v "${OUTPUT_DIR}:/run/out:Z" \
        quay.io/coreos/chunkah@sha256:71e593421c5de7dcc7c8c5c50e98d3bac572055a76f399f61a491d123c20a523 \
        build \
        --verbose \
        --compressed \
        --max-layers 128 \
        --prune /sysroot/ \
        --label ostree.commit- \
        --label ostree.final-diffid- \
        --config /chunkah-config.json \
        --output oci:/run/out/chunked

    CHUNKED_IMAGE="$(podman pull "oci:${OUTPUT_DIR}/chunked")"
    podman tag "${CHUNKED_IMAGE}" "${target_image}:${tag}"

# shellcheck, scripts/validate.py, hadolint and actionlint (the last two when installed)
[group('Lint')]
lint:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shellcheck is installed
    if ! command -v shellcheck &> /dev/null; then
        echo "shellcheck could not be found. Please install it."
        exit 1
    fi
    # Run shellcheck on all Bash scripts. `find -exec cmd \;` swallows the exit
    # status of cmd, so the status is collected explicitly; otherwise lint would
    # pass while shellcheck was reporting errors.
    shellcheck_status=0
    while IFS= read -r script; do
        shellcheck "${script}" || shellcheck_status=1
    done < <(/usr/bin/find . -iname "*.sh" -type f)
    if [[ ${shellcheck_status} -ne 0 ]]; then
        echo "shellcheck reported problems" >&2
        exit 1
    fi
    # Cross-file consistency: image pins, signature policy, declared apps
    python3 scripts/validate.py
    # The Containerfile linter, when it is installed
    if command -v hadolint &> /dev/null; then
        hadolint Containerfile
    fi
    # Workflow semantics (expressions, action inputs), when it is installed
    if command -v actionlint &> /dev/null; then
        actionlint -shellcheck= -pyflakes= .github/workflows/*.yml
    fi

# Regenerate the raster assets committed under system_files/ (needs Pillow)
[group('Utility')]
assets:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! python3 -c 'import PIL' 2> /dev/null; then
        echo "Pillow is required: python3 -m pip install pillow" >&2
        exit 1
    fi
    python3 scripts/render-assets.py

# Format every shell script with shfmt
[group('Lint')]
format:
    #!/usr/bin/env bash
    set -eoux pipefail
    # Check if shfmt is installed
    if ! command -v shfmt &> /dev/null; then
        echo "shfmt could not be found. Please install it."
        exit 1
    fi
    # Run shfmt on all Bash scripts
    /usr/bin/find . -iname "*.sh" -type f -exec shfmt --write "{}" ';'

# Report whether a pinned upstream digest has moved; exits non-zero when one is stale
[group('Utility')]
check-updates:
    #!/usr/bin/env bash
    set -uo pipefail

    if ! command -v skopeo >/dev/null; then
        echo "skopeo is required (it ships with the image)" >&2
        exit 1
    fi

    moved=0

    report() {
        local label="$1" repo="$2" tag="$3" pinned="$4"
        local live
        if [[ -z "${pinned}" ]]; then
            printf '  %-14s no pin found, check the repository\n' "${label}"
            return
        fi
        live="$(skopeo inspect "docker://${repo}:${tag}" 2>/dev/null | jq -r '.Digest // empty')"
        if [[ -z "${live}" ]]; then
            printf '  %-14s could not query %s:%s\n' "${label}" "${repo}" "${tag}"
            return
        fi
        if [[ "${live}" == "${pinned}" ]]; then
            printf '  %-14s up to date %s\n' "${label}" "${pinned:0:19}..."
        else
            printf '  %-14s moved %s... -> %s...\n' "${label}" "${pinned:0:19}" "${live:0:19}"
            moved=1
        fi
    }

    base_pin="$(grep -oE 'ghcr\.io/ublue-os/bluefin:[^@]+@sha256:[0-9a-f]{64}' Containerfile | head -n1 | sed 's/.*@//')"
    chunkah_pin="$(grep -oE 'quay\.io/coreos/chunkah@sha256:[0-9a-f]{64}' Justfile | head -n1 | sed 's/.*@//')"
    bib_pin="$(grep -oE 'bootc-image-builder@sha256:[0-9a-f]{64}' .github/workflows/build-disk.yml | head -n1 | sed 's/.*@//')"
    syft_pin="$(grep -oE 'anchore/syft@sha256:[0-9a-f]{64}' .github/workflows/build.yml | head -n1 | sed 's/.*@//')"
    grype_pin="$(grep -oE 'anchore/grype@sha256:[0-9a-f]{64}' .github/workflows/build.yml | head -n1 | sed 's/.*@//')"

    printf 'DISTR0 pins\n'
    report 'bluefin base' 'ghcr.io/ublue-os/bluefin' 'latest' "${base_pin}"
    report 'chunkah' 'quay.io/coreos/chunkah' 'latest' "${chunkah_pin}"
    report 'disk image' 'quay.io/centos-bootc/bootc-image-builder' 'latest' "${bib_pin}"
    report 'syft' 'ghcr.io/anchore/syft' 'latest' "${syft_pin}"
    report 'grype' 'ghcr.io/anchore/grype' 'latest' "${grype_pin}"

    if [[ "${moved}" -eq 1 ]]; then
        printf '\nBump the moved pin where it is used (Containerfile for the base;\n'
        printf 'Justfile and .github/workflows/ for the tools), or let Renovate do it.\n'
        printf 'The new digest comes from:\n'
        printf '  skopeo inspect docker://<image> | jq -r .Digest\n'
    else
        printf '\nNothing to do: every pin still matches the registry.\n'
    fi
    exit "${moved}"

# Run the image self-test in a container, building the image first if needed
[group('Test')]
test $target_image=image_name $tag=default_tag:
    #!/usr/bin/env bash
    set -euo pipefail
    image="${target_image}:${tag}"
    if ! podman image exists "${image}"; then
        just build "${target_image}" "${tag}"
    fi
    podman run --rm "${image}" /usr/share/distr0/selftest.sh

# Run the unit tests for the repository's own tooling
[group('Test')]
test-unit:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v pytest > /dev/null; then
        echo "pytest is required: python3 -m pip install pytest" >&2
        exit 1
    fi
    pytest -q tests

# Boot a published image in QEMU and check what only a booted system can prove
[group('Test')]
boot-gate image=("ghcr.io/progliodario/" + image_name + ":" + default_tag) revision="":
    #!/usr/bin/env bash
    set -euo pipefail
    args=(--image "{{ image }}")
    if [[ -n "{{ revision }}" ]]; then
        args+=(--expect-revision "{{ revision }}")
    fi
    scripts/boot-gate.sh "${args[@]}"

# Boot the image `just build` made, exactly as CI does before publishing
[group('Test')]
boot-gate-local $target_image=("localhost/" + image_name) $tag=default_tag: (_rootful_load_image target_image tag)
    #!/usr/bin/env bash
    set -euo pipefail
    scripts/boot-gate.sh --local "${target_image}:${tag}" --expect-revision "$(git rev-parse HEAD)"
